#!/usr/bin/env python3
"""Fine-tune a local Laya checkpoint on the pi-os-intent-v1 questions (laya.md §10).

Never run by pi-os, its installer or its tests. A user runs it by hand, in a venv with
laya 0.3.5 + torch, against LOCAL checkpoint files (no hub download; network kill-switch on).

Device policy:
  * CPU by default. MPS stays hidden so nothing silently lands on the GPU.
  * --device mps ONLY together with --gpu-lock-path PATH. Before torch is even imported the
    script takes a NON-BLOCKING exclusive flock on that file (gpu_lock.py) and holds it until
    it exits. If another tenant holds it the run refuses (exit 75) instead of waiting.
    A free lock is not permission: agree on the window with the lock owner first.

Method (supervised, small and auditable rather than the upstream RL recipe):
  * one row per (utterance, question), built with laya's own build_sequence, choice options
    shuffled per row so the head cannot learn option positions;
  * soft-target cross-entropy over the option markers (label smoothing), intent rows weighted
    by inverse class frequency (the templated set has many more fast-path rows than agent tasks);
  * AdamW, separate encoder/head learning rates, linear warm-up and decay, grad-clip 1.0;
  * temperatures fitted on the calibration split (grid search on NLL per question bucket,
    clamped to laya's [0.5, 5.0]) and written as calibration.json for the sidecar.

Outputs in --out: model/ (configs, tokenizer, model.safetensors), calibration.json, manifest.json.
Promote nothing by hand: run eval.py on the frozen test fixtures and follow its gates.

  python train.py --base-model /path/to/laya/multilingual --train data/train.jsonl \
      --calib data/calib.jsonl --out runs/v1 [--epochs 3] [--threads 4] [--dry-run]
"""
import argparse
import json
import math
import os
import random
import shutil
import sys
import time

sys.dont_write_bytecode = True  # importing the sidecar module must not litter __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import gpu_lock  # noqa: E402
import laya_intent_sidecar as sidecar  # noqa: E402

QUESTIONS = sidecar.QUESTIONS
INTENT_DISPLAY = list(QUESTIONS["intent"]["criteria"])  # model-facing labels, option order
DISPLAY_FOR_ID = {stable: display for display, stable in sidecar.INTENT_LABELS.items()}
SURFACE_ORDER = list(QUESTIONS["surface"]["criteria"])
TEMP_GRID = [round(0.5 * (10 ** (i / 40.0)), 4) for i in range(41)]  # 0.5 .. 5.0, log-spaced
EXIT_BUSY = 75


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Fine-tune Laya on pi-os-intent-v1 (CPU by default)")
    parser.add_argument("--base-model", required=True, help="local Laya checkpoint directory (multilingual)")
    parser.add_argument("--train", required=True)
    parser.add_argument("--calib", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--device", choices=["cpu", "mps"], default="cpu")
    parser.add_argument("--gpu-lock-path", help="required with --device mps: shared GPU coordination lock file")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--lr", type=float, default=2.5e-5, help="encoder learning rate")
    parser.add_argument("--head-lr", type=float, default=1e-4)
    parser.add_argument("--batch", type=int, default=8, help="utterances per step (x4 question rows)")
    parser.add_argument("--label-smoothing", type=float, default=0.05)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--seed", type=int, default=1729)
    parser.add_argument("--max-steps", type=int, default=0, help="stop early (smoke runs)")
    parser.add_argument("--save-fp32", action="store_true", help="keep fp32 weights (default: fp16 like upstream)")
    parser.add_argument("--dry-run", action="store_true", help="validate data and arguments; no torch, no model")
    args = parser.parse_args(argv)
    if args.device == "mps" and not args.gpu_lock_path:
        parser.error("--device mps requires --gpu-lock-path (coordinated GPU window)")
    if args.device == "cpu" and args.gpu_lock_path:
        parser.error("--gpu-lock-path is only used with --device mps; CPU runs never touch the GPU lock")
    if not 1 <= args.threads <= 64 or args.epochs < 1 or args.batch < 1:
        parser.error("invalid --threads/--epochs/--batch")
    return args


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            labels = row.get("labels", {})
            text = row.get("utterance")
            if not isinstance(text, str) or not 0 < len(text) <= sidecar.MAX_TEXT_CHARS:
                raise SystemExit("%s:%d: utterance missing or over %d chars" % (path, number, sidecar.MAX_TEXT_CHARS))
            if labels.get("intent") not in DISPLAY_FOR_ID or labels.get("tier") not in (0, 1, 2, 3) or \
                    not isinstance(labels.get("screen"), bool) or labels.get("surface") not in SURFACE_ORDER:
                raise SystemExit("%s:%d: invalid labels" % (path, number))
            rows.append(row)
    if not rows:
        raise SystemExit("%s: no rows" % path)
    return rows


def sha256_path(path):
    return sidecar.sha256_file(path)


def one_hot(size, index, smoothing):
    return [(1.0 - smoothing) * (1.0 if i == index else 0.0) + smoothing / size for i in range(size)]


def targets_for(labels, smoothing):
    return {
        "intent": one_hot(len(INTENT_DISPLAY), INTENT_DISPLAY.index(DISPLAY_FOR_ID[labels["intent"]]), smoothing),
        "tier": one_hot(len(sidecar.TIER_LEVELS), labels["tier"], smoothing),
        "screen": one_hot(2, 1 if labels["screen"] else 0, smoothing),  # noul options: [false, true]
        "surface": one_hot(len(SURFACE_ORDER), SURFACE_ORDER.index(labels["surface"]), smoothing),
    }


def shuffled(rng, size):
    order = list(range(size))
    for i in range(size - 1, 0, -1):  # Fisher-Yates on Random.random() only
        j = int(rng.random() * (i + 1))
        order[i], order[j] = order[j], order[i]
    return order


def intent_weights(rows):
    counts = {}
    for row in rows:
        counts[row["labels"]["intent"]] = counts.get(row["labels"]["intent"], 0) + 1
    mean = len(rows) / float(len(counts))
    return {label: mean / count for label, count in counts.items()}


def build_items(agent, rows, rng, smoothing, shuffle_options, weights):
    from laya.common import QTYPES, build_sequence, render_options, serialize_state

    max_len, head_max_len = agent.cfg.get("max_len", 512), agent.cfg.get("head_max_len", 192)
    items, skipped = [], 0
    for row in rows:
        state = {"utterance": row["utterance"]}
        target = targets_for(row["labels"], smoothing)
        state_tokens = len(agent.tok(serialize_state(state).replace(agent.tok.mask_token, " "),
                                     add_special_tokens=False)["input_ids"])
        for qid, question in QUESTIONS.items():
            internal = agent._to_internal(question)
            size = len(render_options(internal))
            order = shuffled(rng, size) if shuffle_options and internal["t"] == "choice" else list(range(size))
            empty, _ = build_sequence(agent.tok, "", internal, max_len, head_max_len, option_order=order)
            ids, markers = build_sequence(agent.tok, state, internal, max_len, head_max_len, option_order=order)
            if len(markers) != size or state_tokens > max_len - len(empty):  # never train on truncated rows
                skipped += 1
                continue
            items.append({"ids": ids, "markers": markers, "qtype": QTYPES[internal["t"]], "qid": qid,
                          "target": [target[qid][j] for j in order], "order": order,
                          "weight": weights.get(row["labels"]["intent"], 1.0) if qid == "intent" else 1.0})
    return items, skipped


def batches(items, size):
    for start in range(0, len(items), size):
        yield items[start:start + size]


def forward(torch, model, batch_items, pad_id, device):
    from laya.common import collate_items

    b = collate_items([batch_items], pad_id)
    logits, _ = model(b["input_ids"].to(device), b["attention_mask"].to(device), b["marker_pos"].to(device),
                      b["marker_mask"].to(device), b["qtype"].to(device))
    return logits.float(), b["target"].to(device), b["marker_mask"].to(device)


def collect_logits(torch, model, items, pad_id, device, size=32):
    """Raw (untempered) marker logits in original option order, per item, on the CPU."""
    model.eval()
    out = []
    with torch.no_grad():
        for chunk in batches(items, size):
            logits, _, mask = forward(torch, model, chunk, pad_id, device)
            for row, item in enumerate(chunk):
                k = int(mask[row].sum())
                values = logits[row, :k].cpu().tolist()
                original = [0.0] * k
                for position, option in enumerate(item["order"]):
                    original[option] = values[position]
                out.append((item, original))
    model.train()
    return out


def softmax(values, temperature):
    scaled = [v / temperature for v in values]
    top = max(scaled)
    exps = [math.exp(v - top) for v in scaled]
    total = sum(exps)
    return [e / total for e in exps]


def bucket(qtype, size):
    from laya.common import temp_bucket

    return temp_bucket(qtype, size)


def fit_temperatures(scored):
    """Per (question type, option-count bucket): T minimising NLL of the gold option."""
    groups = {}
    for item, logits in scored:
        gold = max(range(len(item["target"])), key=lambda j: item["target"][j])
        gold_option = item["order"][gold]
        groups.setdefault(bucket(item["qtype"], len(logits)), []).append((logits, gold_option))
    fitted = {}
    for name, rows in sorted(groups.items()):
        best = min(TEMP_GRID, key=lambda t: -sum(math.log(max(softmax(l, t)[g], 1e-12)) for l, g in rows))
        fitted[name] = best
    return fitted


def accuracy(scored):
    hits, totals = {}, {}
    for item, logits in scored:
        gold = item["order"][max(range(len(item["target"])), key=lambda j: item["target"][j])]
        predicted = max(range(len(logits)), key=lambda j: logits[j])
        totals[item["qid"]] = totals.get(item["qid"], 0) + 1
        hits[item["qid"]] = hits.get(item["qid"], 0) + (1 if predicted == gold else 0)
    return {qid: round(hits[qid] / float(totals[qid]), 4) for qid in sorted(totals)}


def main(argv=None):
    args = parse_args(argv)
    train_rows, calib_rows = read_rows(args.train), read_rows(args.calib)
    print(json.dumps({"train_rows": len(train_rows), "calib_rows": len(calib_rows), "device": args.device}))
    if args.dry_run:
        return 0

    lock_fd = None
    if args.device == "mps":  # take the coordination lock before torch can touch the GPU
        try:
            lock_fd = gpu_lock.acquire(args.gpu_lock_path)
        except gpu_lock.GpuLockBusy:
            print("GPU lock is held by another process; refusing to train on MPS", file=sys.stderr)
            return EXIT_BUSY
        except gpu_lock.GpuLockMissing:
            print("GPU lock file not found; coordinate with its owner instead of creating it", file=sys.stderr)
            return gpu_lock.EXIT_MISSING
    sidecar.offline_guard()
    import functools

    import torch

    if args.device == "cpu" and hasattr(torch.backends, "mps"):
        def hide(fn):
            @functools.wraps(fn)  # torch._dynamo introspects __wrapped__
            def unavailable(*_args, **_kwargs):
                return False
            return unavailable

        torch.backends.mps.is_available = hide(torch.backends.mps.is_available)
        torch.backends.mps.is_built = hide(torch.backends.mps.is_built)
    elif args.device == "mps" and not torch.backends.mps.is_available():
        print("MPS requested but not available; refusing (no silent CPU fallback)", file=sys.stderr)
        return 2
    torch.manual_seed(args.seed)
    torch.set_num_threads(args.threads)
    from laya import Agent, __version__ as laya_version
    from safetensors.torch import save_file

    os.makedirs(args.out, exist_ok=True)
    base_weights = os.path.realpath(os.path.join(args.base_model, "model.safetensors"))
    stage = sidecar.stage_model_dir(args.base_model, os.path.join(args.out, "stage-base"))
    agent = Agent(stage, device=args.device)
    device = torch.device(args.device)
    model = agent.model
    rng = random.Random(args.seed)
    weights = intent_weights(train_rows)
    train_items, skipped_train = build_items(agent, train_rows, rng, args.label_smoothing, True, weights)
    calib_items, skipped_calib = build_items(agent, calib_rows, rng, 0.0, False, {})
    print(json.dumps({"train_items": len(train_items), "calib_items": len(calib_items),
                      "skipped": skipped_train + skipped_calib}))

    encoder = [p for n, p in model.named_parameters() if n.startswith("encoder.")]
    head = [p for n, p in model.named_parameters() if not n.startswith("encoder.")]
    optimizer = torch.optim.AdamW([{"params": encoder, "lr": args.lr}, {"params": head, "lr": args.head_lr}],
                                  weight_decay=0.01)
    per_epoch = int(math.ceil(len(train_items) / float(args.batch * len(QUESTIONS))))
    total = args.max_steps or per_epoch * args.epochs
    warmup = max(1, int(0.06 * total))
    scheduler = torch.optim.lr_scheduler.LambdaLR(
        optimizer, lambda step: min(1.0, (step + 1) / float(warmup)) * max(0.0, (total - step) / float(total)))
    model.train()
    step, started = 0, time.time()
    for epoch in range(args.epochs):
        order = shuffled(rng, len(train_items))
        epoch_items = [train_items[i] for i in order]
        for chunk in batches(epoch_items, args.batch * len(QUESTIONS)):
            logits, target, _ = forward(torch, model, chunk, agent.tok.pad_token_id, device)
            per_row = -(target * torch.log_softmax(logits, -1)).sum(-1)
            row_weights = torch.tensor([item["weight"] for item in chunk], dtype=per_row.dtype, device=device)
            loss = (per_row * row_weights).sum() / row_weights.sum()
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            scheduler.step()
            step += 1
            if step % 25 == 0:
                print(json.dumps({"epoch": epoch, "step": step, "loss": round(float(loss), 4),
                                  "elapsed_s": round(time.time() - started, 1)}))
            if args.max_steps and step >= args.max_steps:
                break
        calib_scored = collect_logits(torch, model, calib_items, agent.tok.pad_token_id, device)
        print(json.dumps({"epoch": epoch, "calib_accuracy": accuracy(calib_scored)}))
        if args.max_steps and step >= args.max_steps:
            break

    calib_scored = collect_logits(torch, model, calib_items, agent.tok.pad_token_id, device)
    fitted = fit_temperatures(calib_scored)
    by_type = {}
    for name, value in fitted.items():
        by_type.setdefault(name.split(":")[0], value)
    calibration = {"questions": sidecar.QSET_VERSION,
                   "temperature": [by_type.get("choice", 1.0), by_type.get("score", 1.0), by_type.get("noul", 1.0)],
                   "temperature_by_options": fitted}

    model_dir = os.path.join(args.out, "model")
    os.makedirs(model_dir, exist_ok=True)
    for name in ("rl_agent_config.json",):
        shutil.copyfile(os.path.join(stage, name), os.path.join(model_dir, name))
    for name in ("tokenizer", "encoder"):
        if os.path.isdir(os.path.join(stage, name)):
            shutil.copytree(os.path.join(stage, name), os.path.join(model_dir, name), dirs_exist_ok=True)
    config_path = os.path.join(model_dir, "rl_agent_config.json")
    with open(config_path, encoding="utf-8") as handle:
        config = json.load(handle)
    config["temperature"], config["temperature_by_options"] = calibration["temperature"], fitted
    with open(config_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
    state = {}
    for key, tensor in model.state_dict().items():
        tensor = tensor.detach().cpu().clone().contiguous()
        state[key] = tensor if args.save_fp32 or not tensor.is_floating_point() else tensor.half()
    weights_path = os.path.join(model_dir, "model.safetensors")
    save_file(state, weights_path)
    with open(os.path.join(args.out, "calibration.json"), "w", encoding="utf-8") as handle:
        json.dump(calibration, handle, indent=2)
    manifest = {
        "questions": sidecar.QSET_VERSION, "laya": laya_version, "torch": torch.__version__, "device": args.device,
        "base_sha256": sha256_path(base_weights), "model_sha256": sha256_path(weights_path),
        "train_sha256": sha256_path(args.train), "calib_sha256": sha256_path(args.calib),
        "args": {k: v for k, v in vars(args).items() if k not in ("gpu_lock_path",)},
        "steps": step, "calib_accuracy": accuracy(calib_scored), "temperatures": fitted,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
    print(json.dumps({"done": True, "steps": step, "calib_accuracy": manifest["calib_accuracy"]}))
    if lock_fd is not None:
        gpu_lock.release(lock_fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
