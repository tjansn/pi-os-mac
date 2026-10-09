# Laya intent sidecar (optional, advisory)

pi-os can ask a small local classifier what an utterance is about before the agent runs:
which kind of request it is, how much reasoning it needs, whether it refers to something on
screen and which interface it touches. This directory holds that classifier's sidecar and
the toolkit to fine-tune it. **It is off by default and it never decides anything on its own.**

| File | Purpose |
|---|---|
| `laya_intent_sidecar.py` | stdio JSON-lines child process of node-harness (CPU-only, offline) |
| `finetune/generate_dataset.py` | templated EN/DE training and calibration data for the pi-os questions |
| `finetune/train.py` | fine-tune on CPU (MPS only in a coordinated, locked GPU window) |
| `finetune/eval.py` | promotion gates on the frozen test fixtures |
| `finetune/gpu_lock.py` | non-blocking exclusive `flock` helper used by `train.py --device mps` |
| `finetune/fixtures/pi-os-intent-v1.test.jsonl` | 49 frozen EN/DE test utterances (never train on them) |

Node side: `node-harness/src/classifier/` (`laya.ts` supervisor, `provider.ts` pi provider,
`piClassifier.ts` catalog classifiers, `settings.ts`, `factory.ts`, `shadowLog.ts`).

## What Laya is

[Laya](https://github.com/NandhaKishorM/laya) (Apache-2.0) is a non-autoregressive encoder with
a typed decision head. One forward pass answers typed questions (`choice`, `score`, yes/no) about
a JSON state with probabilities; it never generates text. pi-os pins the reviewed **0.3.5**
release and the **multilingual** checkpoint (English and German).

The sidecar asks one batched question set, `pi-os-intent-v1`, per utterance:

| Question | Answers |
|---|---|
| intent | calculate, convert, time_date, file_search, app_launch, web_search, open_url, system_toggle, dictation, agent_task |
| tier | none / little / moderate / heavy AI reasoning |
| screen | probability that the utterance refers to something visible on screen |
| surface | browser, native_app, none |

node-harness maps the answers to advisory `ClassifierHints` (`source: "laya"`) for the Auto
router, and registers the same model as the pi classifier `laya/multilingual`, so
`runtime.classify()` (and codemode's `models.classify()` once models are enabled there) can
ask it arbitrary typed questions.

## Why it is advisory only

Zero-shot, Laya is not good enough to route on:

- **45–55% intent accuracy** on 49 realistic EN/DE pi-os commands (random 10%, majority 24.5%).
- Tier, surface and screen answers were at or below majority-class baselines.
- It is confidently wrong: at top-p ≥ 0.95, 4–6 of 12 genuine agent tasks would still have been
  sent to a fast path. Upstream says so itself: "a fast base to specialise, not a zero-shot
  decision engine".

So pi-os uses it like this:

- Deterministic grammars produce every executable slot. Laya never creates, authorizes or
  triggers an action, and its output never relaxes a policy (no deletion/Trash, credential-field
  rule, identity/focus/ownership checks all stay as they are).
- The router may use a hint only to **raise** a tier or request a screenshot, never to lower a
  rule-derived tier.
- A question is promoted only after a pi-os fine-tune passes its gate in `finetune/eval.py`
  (false fast-path rate ≤ 1%, per-class precision ≥ 0.97 with a Wilson bound ≥ 0.90, AUC ≥ 0.90…).

## CPU, not MPS

The sidecar runs on the **CPU only**: it hides MPS from torch, loads with `device="cpu"` and
refuses to start unless every parameter and buffer is on the CPU. Measured on an M5 Max
(4 threads, background load): load 18.4 s, one question p50 60 ms, the 4-question batch p50
114 ms. That is fine off the hot path: pi-os never waits for Laya (250 ms budget, null on miss).

MPS would be 5–10× faster, but the local GPU is coordinated through
`_LOCAL_AI/.local-inference.lock`, an exclusive, process-lifetime `flock` held by the DRACO
benchmark and the resident model services. A resident MPS tenant would either block them or
violate the lock. Therefore:

- The sidecar never opens, locks or touches that lock file and never uses MPS.
- pi-os makes no Ollama or other local-GPU calls for Laya; tests use a fake engine only.
- GPU use is limited to an explicit fine-tune: `train.py --device mps --gpu-lock-path PATH`
  takes a **non-blocking** exclusive `flock` before torch is imported and refuses if it is busy.
  A free lock is not permission: agree on the window with the lock owner first.

## Memory

Peak RSS is about **5.2 GiB** while loading (the F16 weights are upcast to fp32); steady state
was not measured (estimated 1.5–2.5 GiB). The sidecar stops after 10 idle minutes and dies with
node-harness (stdin EOF), so on macOS it is warm only while the Node child is; the next start
pays the ~18 s load again, during which pi-os routes on heuristics alone.

## Guards

- Socket kill-switch: any non-`AF_UNIX` connect, `sendto`/`sendmsg`, `bind` (no listeners either)
  or name lookup ends the process with exit code 97; the supervisor then keeps Laya off.
  HF/transformers offline variables are forced and proxy/token variables removed. It patches
  Python's `socket` API and the C-level `_socket` module (new sockets made through it get a
  guarded subclass; its lookups are denied). That is defense in depth: native code that opens
  sockets by itself is outside its reach.
- The sidecar script is never a setting: node-harness runs the copy shipped with pi-os (or
  `PI_OS_LAYA_SCRIPT`, for development from Terminal), and the interpreter must be named
  `python`, `python3` or `python3.x`, so a settings write cannot choose code to run.
- The checkpoint is **staged**: configs and tokenizer are copied into a pi-os-owned directory,
  weights are symlinked. laya 0.3.5 rewrites `tokenizer_config.json` in place; staging keeps
  your model directory untouched. Optional sha256 check of the weights before loading.
- Utterances are capped at 500 characters and refused, never truncated; a token-room check
  refuses states laya would silently cut.
- fd 1 carries protocol lines only; library `print()` output goes to stderr.
- Queued requests past their `deadline_ms` return `expired`; superseded requests are cancelled.
- Inputs never reach logs. Node logs states, error codes, PIDs and durations.
- Shutdown is stdin EOF first, then a kill of exactly the child's own PID. Unexpected exits
  restart lazily with backoff, at most 3 times; then the classifier stays off until the
  configuration changes.

## Protocol (proto 1)

One UTF-8 JSON object per line.

```jsonc
// child -> parent once loaded
{"type":"ready","proto":1,"model":{"name":"laya-multilingual","questions":"pi-os-intent-v1","device":"cpu","threads":4,"calibrated":false,"fake":false,...},"load_ms":18900}
{"type":"fatal","error":{"code":"sha256_mismatch","kind":"LoadError","message":"..."}}      // then exit 2
// parent -> child
{"id":"c1","op":"classify","text":"was ergibt zwei hoch sechzehn minus tausend","deadline_ms":250}
{"id":"p1","op":"predict","state":{...},"questions":{...pi ClassifierContext questions...},"deadline_ms":2000}
{"id":"x1","op":"cancel","target":"c1"}      {"id":"h1","op":"health"}      {"id":"s1","op":"shutdown"}
// child -> parent
{"id":"c1","ok":true,"result":{"advisory":true,"questions":"pi-os-intent-v1","intent":{"label":"calculate","p":0.99,"probs":{...}},"tier":{"label":"little","p":0.84,"expected":0.98,"probs":{...}},"screen":{"p":0.06},"surface":{"label":"none","p":0.98,"probs":{...}},"usage":{...}},"timing":{"queue_ms":0.05,"infer_ms":113.8}}
{"id":"c2","ok":false,"error":{"code":"state_too_long|bad_request|expired|cancelled|internal","message":"..."}}
```

Fake engine for tests and manual checks (no torch, no model; keep stdin open until it is ready):

```sh
(sleep 0.5; printf '{"id":"c1","op":"classify","text":"what time is it in Tokyo"}\n'; sleep 0.5) \
  | python3 -I -B laya_intent_sidecar.py --fake
```

## Enabling it

1. Use a Python environment with `laya==0.3.5` and a CPU build of `torch` (for example the
   reviewed venv next to your local Laya checkout). pi-os never installs packages.
2. Point pi-os at it. In the Mac app: Settings → Classifier, choose the environment's Python
   interpreter (`.venv/bin/python`) and the Laya model folder (the one holding
   `rl_agent_config.json`), then turn the switch on. The page names what is still missing
   (`status.layaLaunch` from `GET /settings/classifier`) before the switch does anything.
   The same fields live in `classifier.json` in the pi-os support directory
   (`~/Library/Application Support/pi-os/` on macOS):

   ```json
   { "kind": "laya", "python": "/abs/path/.venv/bin/python", "modelDir": "/abs/path/laya/multilingual",
     "sha256": "<64 hex chars, optional>", "threads": 4, "shadowLog": false }
   ```

   Fallbacks for missing `python`/`modelDir`, in order: `PI_OS_LAYA_PYTHON` and
   `PI_OS_LAYA_MODEL_DIR` (absolute paths; environment variables only reach an app started
   from Terminal or `run-dev.sh`, never one started from Finder, the hotkey or a login item),
   then `laya/venv/bin/python` and `laya/model` inside the support directory when they exist.
   `PI_OS_LAYA_SCRIPT` overrides the sidecar location for development. `PI_OS_LAYA=0`
   disables the real engine whatever the settings say.
3. Optional: `"calibration": "/abs/path/runs/v1/calibration.json"` from a fine-tune run.
4. The installed app is a snapshot: re-publish (refresh-install) so the bundled
   `sidecars/laya/laya_intent_sidecar.py` matches this repository.

`"shadowLog": true` appends one line per classification to `logs/classifier-shadow.jsonl` in the
support directory: labels, probabilities and latency only, never the utterance. It stops at 5 MiB.

## Laya, Clef and Jev

All three answer the same typed-question contract, so pi-os reaches the cloud ones through pi's
catalog with classifier kind `"pi"` (`provider` + `model` in `classifier.json`), no extra code:

```json
{ "kind": "pi", "provider": "cloudflare-workers-ai", "model": "typesafe/jev", "shadowLog": false }
```

A classifier of kind `"pi"` sends text to its provider, so pi-os consults it for the **final**
utterance only (the released hotkey, a typed Return): voice partials and typed previews,
including takes the user then cancels, never leave the Mac. Laya, being local, also sees
partials.

| | Laya (this sidecar) | Jev (TypeSafe) | Clef / Clef-flash (Cloudflare) |
|---|---|---|---|
| Where it runs | local CPU, private | cloud | cloud (Workers AI) |
| Availability in pi-os | now, opt-in | **now** via pi 1.0's catalog with credentials: `cloudflare-workers-ai` / `typesafe/jev` (`CLOUDFLARE_API_KEY` + `CLOUDFLARE_ACCOUNT_ID`) or `typesafe` / `jev-latest` (`TYPESAFE_API_KEY`) | open-weight decision models **released 2026-10-01** on Workers AI (`@cf/cloudflare/clef`, `@cf/cloudflare/clef-flash`); not in pi 1.0.0's catalog, already in pi main, so they **arrive with the next pi release** |
| Weights | 0.6 GB checkpoint | hosted only | Apache-2.0, 27B / 9.4B, CUDA-tested only (no GGUF/MLX): **cloud-only** for pi-os |
| Latency | ~114 ms per utterance on CPU | ~300 ms p50 (TypeSafe), ~524 ms median (Workers AI) | clef-flash ~39 ms median, Clef ~209 ms (Cloudflare's figures) |
| Zero-shot quality on pi-os | weak (45–55% intent) | not measured here (no live calls) | not measured here; strong public benchmarks |
| Privacy | utterance stays on the Mac | utterance sent to the provider | utterance sent to Cloudflare |

Whichever is chosen, hints stay advisory. Whether `@cf/cloudflare/clef-flash` works unchanged
through pi's Workers AI classifier transport is unverified (no live calls were made).

**Recommendation.** ("clev" in the original request was read as Cloudflare Clef / Clef-flash;
that reading is still unconfirmed.) Clef is not better than Laya for pi-os's local hot path:
it is cloud-only (Workers AI; CUDA-tested weights, no GGUF/MLX build), is not in pi 1.0.0's
catalog and has no credentials configured here. Keep Laya as the opt-in local classifier, and
plug Clef in later through kind `"pi"` once the next pi release ships it. The full verdicts
(pi-durable, Clef, macbrow/jev ideas) and the deferred scope are in
[VOICE_MAGIC.md](../../VOICE_MAGIC.md).

## Fine-tuning (manual, never run by pi-os)

```sh
cd sidecars/laya/finetune
python3 generate_dataset.py --out-dir data            # deterministic (seed 1729), counts only on stdout
python3 train.py --dry-run --base-model /abs/laya/multilingual --train data/train.jsonl --calib data/calib.jsonl --out runs/v1
python train.py --base-model /abs/laya/multilingual --train data/train.jsonl --calib data/calib.jsonl --out runs/v1   # CPU
python eval.py --model-dir runs/v1/model --stage-dir runs/v1/stage-eval --calibration runs/v1/calibration.json \
  --calib-gold data/calib.jsonl --require-all
```

- `train.py` runs on the CPU unless you pass `--device mps --gpu-lock-path <shared lock>` inside an
  agreed window; it refuses when the lock is busy (exit 75) or missing, never waits and never
  creates the lock file.
- `gpu_lock.py --check PATH` briefly takes and releases the lock, so it is not a passive probe:
  never point it at the shared lock while another tenant's reservation is active.
- The templated set is a start, not enough: add reviewed paraphrases. Keep the 49 fixtures frozen
  as the test set; thresholds come from the calibration split (held-out templates).
- Promote a question only when `eval.py` says so, then point `modelDir`/`calibration` at the run
  and record the result. Version the question set (`pi-os-intent-vN`) when questions change.
