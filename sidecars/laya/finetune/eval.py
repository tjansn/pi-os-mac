#!/usr/bin/env python3
"""Promotion gates for a Laya checkpoint on pi-os-intent-v1 (laya.md §8.6 and §10).

Laya stays advisory until a question passes its gate on the FROZEN test fixtures
(fixtures/pi-os-intent-v1.test.jsonl, never used for training or thresholds):

  intent   per fast-path class c: threshold tau_c = smallest top-p with calibration precision
           >= 0.97 AND Wilson lower bound >= 0.90; promoted when test precision at tau_c is
           >= 0.97. Gate: false fast-path rate on agent tasks <= 1% and >= 1 promoted class.
  tier     AUC of P(moderate)+P(heavy) for gold tier >= 2 is >= 0.90 (may only RAISE a tier).
  screen   AUC >= 0.90 and better than the deixis rule.
  surface  accuracy >= rule baseline + 5 points.

Rule baselines use the gold intent as a stand-in for the deterministic parsers, which makes
them optimistic and the gates stricter. Inputs:
  --predictions  JSONL of {"id": ..., "result": <sidecar classify result>} for the gold rows, or
  --model-dir    run the real sidecar engine on CPU (loads ~5 GB; offline kill-switch on).
Thresholds come from --calib-gold + --calib-predictions (or the same --model-dir); without a
calibration set they are fitted on the test rows and the report says so.

Prints a JSON report (labels and numbers only, never utterances). Pure Python unless
--model-dir is used. --require-all exits 1 when any gate fails.
"""
import argparse
import json
import math
import os
import re
import sys

sys.dont_write_bytecode = True  # importing the sidecar module must not litter __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import laya_intent_sidecar as sidecar  # noqa: E402

FAST_PATH = [i for i in sidecar.INTENT_IDS if i != "agent_task"]
PRECISION_TARGET, WILSON_TARGET, FALSE_FAST_PATH_MAX, AUC_TARGET, SURFACE_MARGIN = 0.97, 0.90, 0.01, 0.90, 0.05
BROWSERS = {"Safari", "Google Chrome", "Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Orion"}
DEIXIS = re.compile(r"\b(?:this|these|that|here|selected|highlighted|on screen|dies(?:e|en|er|em|es)?|hier|"
                    r"markiert(?:e|en)?|ausgewählt(?:e|en)?|auf dem bildschirm)\b")
DICTATION = re.compile(r"^(?:type|dictate|write exactly|schreib|tippe ein|diktiere)\s*:")
WEBWORDS = re.compile(r"\b(?:web|website|online|internet|google|book|buy|order|flight|flights|restaurant|"
                      r"recherchier\w*|research|bestell\w*|buch\w*|kauf\w*|reservier\w*)\b")
APPWORDS = re.compile(r"\b(?:e-?mail|mail|calendar|kalender|termin|message|nachricht|note|notiz|folder|ordner|"
                      r"finder|slack|file|datei)\b")


def load_jsonl(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def wilson_lower(successes, total, z=1.96):
    if total == 0:
        return 0.0
    p = successes / float(total)
    denominator = 1 + z * z / total
    centre = p + z * z / (2 * total)
    margin = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total))
    return (centre - margin) / denominator


def auc(scores, labels):
    """Mann-Whitney AUC with ties counted half; None when a class is missing."""
    positives = [s for s, y in zip(scores, labels) if y]
    negatives = [s for s, y in zip(scores, labels) if not y]
    if not positives or not negatives:
        return None
    wins = 0.0
    for p in positives:
        for n in negatives:
            wins += 1.0 if p > n else 0.5 if p == n else 0.0
    return wins / (len(positives) * len(negatives))


def fit_thresholds(pairs):
    """pairs: (gold intent, predicted label, top-p). Returns {class: tau or None}."""
    thresholds = {}
    for label in FAST_PATH:
        predicted = sorted((p, gold == label) for gold, pred, p in pairs if pred == label)
        thresholds[label] = None
        for index, (tau, _) in enumerate(predicted):
            kept = predicted[index:]
            correct = sum(1 for _, ok in kept if ok)
            if correct / float(len(kept)) >= PRECISION_TARGET and wilson_lower(correct, len(kept)) >= WILSON_TARGET:
                thresholds[label] = tau
                break
    return thresholds


def rule_screen(row):
    text = row["utterance"].lower()
    return bool(DEIXIS.search(text)) and not DICTATION.match(text)


def rule_surface(row):
    intent, text = row["labels"]["intent"], row["utterance"].lower()
    front = "browser" if row.get("app") in BROWSERS else "native_app"
    if intent in ("web_search", "open_url"):
        return "browser"
    if intent == "app_launch":
        return "native_app"
    if intent == "dictation":
        return front
    if intent != "agent_task":
        return "none"
    if rule_screen(row):
        return front
    if WEBWORDS.search(text):
        return "browser"
    if APPWORDS.search(text):
        return "native_app"
    return "none"


def check_result(result):
    if sidecar.QSET_VERSION != result.get("questions", sidecar.QSET_VERSION):
        raise SystemExit("predictions were made with another question set")
    for key in ("intent", "tier", "screen", "surface"):
        if key not in result:
            raise SystemExit("prediction result lacks %r" % key)
    return result


def join(gold_rows, predictions):
    by_id = {}
    for prediction in predictions:
        by_id[prediction["id"]] = check_result(prediction["result"])
    missing = [row["id"] for row in gold_rows if row["id"] not in by_id]
    if missing:
        raise SystemExit("%d gold rows have no prediction" % len(missing))
    return [(row, by_id[row["id"]]) for row in gold_rows]


def evaluate(gold_rows, predictions, calib=None):
    joined = join(gold_rows, predictions)
    warnings = []
    pairs = [(row["labels"]["intent"], res["intent"]["label"], res["intent"]["p"]) for row, res in joined]
    if calib:
        calib_pairs = [(row["labels"]["intent"], res["intent"]["label"], res["intent"]["p"])
                       for row, res in join(calib[0], calib[1])]
    else:
        calib_pairs = pairs
        warnings.append("thresholds fitted on the test rows (no calibration set): optimistic")
    thresholds = fit_thresholds(calib_pairs)

    per_class, promoted = {}, []
    for label in sidecar.INTENT_IDS:
        predicted = [(gold, p) for gold, pred, p in pairs if pred == label]
        support = sum(1 for gold, _, _ in pairs if gold == label)
        correct = sum(1 for gold, _ in predicted if gold == label)
        entry = {"support": support, "predicted": len(predicted),
                 "precision": round(correct / float(len(predicted)), 4) if predicted else None,
                 "recall": round(correct / float(support), 4) if support else None}
        if label in FAST_PATH:
            tau = thresholds[label]
            kept = [(gold, p) for gold, p in predicted if tau is not None and p >= tau]
            kept_correct = sum(1 for gold, _ in kept if gold == label)
            test_precision = kept_correct / float(len(kept)) if kept else None
            entry.update({"threshold": tau, "kept": len(kept),
                          "precision_at_threshold": round(test_precision, 4) if test_precision is not None else None})
            entry["promoted"] = tau is not None and test_precision is not None and test_precision >= PRECISION_TARGET
            if entry["promoted"]:
                promoted.append(label)
        per_class[label] = entry

    agent_rows = [(gold, pred, p) for gold, pred, p in pairs if gold == "agent_task"]
    false_fast = sum(1 for _, pred, p in agent_rows
                     if pred in FAST_PATH and thresholds.get(pred) is not None and p >= thresholds[pred])
    false_fast_rate = false_fast / float(len(agent_rows)) if agent_rows else None
    if not agent_rows:
        warnings.append("no agent_task rows: false fast-path rate unknown")
    intent_pass = bool(promoted) and false_fast_rate is not None and false_fast_rate <= FALSE_FAST_PATH_MAX

    tier_scores = [res["tier"]["probs"].get("moderate", 0.0) + res["tier"]["probs"].get("heavy", 0.0) for _, res in joined]
    tier_auc = auc(tier_scores, [row["labels"]["tier"] >= 2 for row, _ in joined])

    screen_gold = [bool(row["labels"]["screen"]) for row, _ in joined]
    screen_auc = auc([res["screen"]["p"] for _, res in joined], screen_gold)
    rule_auc = auc([1.0 if rule_screen(row) else 0.0 for row, _ in joined], screen_gold)
    screen_pass = screen_auc is not None and screen_auc >= AUC_TARGET and (rule_auc is None or screen_auc > rule_auc)

    n = float(len(joined))
    surface_acc = sum(1 for row, res in joined if res["surface"]["label"] == row["labels"]["surface"]) / n
    rule_acc = sum(1 for row, _ in joined if rule_surface(row) == row["labels"]["surface"]) / n

    report = {
        "questions": sidecar.QSET_VERSION,
        "n": len(joined),
        "intent": {"accuracy": round(sum(1 for g, p, _ in pairs if g == p) / n, 4), "per_class": per_class,
                   "false_fast_path_rate": round(false_fast_rate, 4) if false_fast_rate is not None else None,
                   "promoted_classes": promoted, "pass": intent_pass},
        "tier": {"auc_moderate_or_heavy": round(tier_auc, 4) if tier_auc is not None else None,
                 "pass": tier_auc is not None and tier_auc >= AUC_TARGET, "use": "raise-only"},
        "screen": {"auc": round(screen_auc, 4) if screen_auc is not None else None,
                   "rule_auc": round(rule_auc, 4) if rule_auc is not None else None, "pass": screen_pass},
        "surface": {"accuracy": round(surface_acc, 4), "rule_accuracy": round(rule_acc, 4),
                    "pass": surface_acc >= rule_acc + SURFACE_MARGIN},
        "warnings": warnings,
    }
    report["promote"] = {name: report[name]["pass"] for name in ("intent", "tier", "screen", "surface")}
    return report


def run_engine(args, rows):
    engine = sidecar.LayaEngine(args.model_dir, args.stage_dir, args.threads, args.sha256, args.calibration)
    return [{"id": row["id"], "result": engine.classify(sidecar.normalize_text(row["utterance"]))} for row in rows], engine


def main(argv=None):
    parser = argparse.ArgumentParser(description="Laya promotion gates for pi-os-intent-v1")
    parser.add_argument("--gold", default=os.path.join(HERE, "fixtures", "pi-os-intent-v1.test.jsonl"))
    parser.add_argument("--predictions")
    parser.add_argument("--calib-gold")
    parser.add_argument("--calib-predictions")
    parser.add_argument("--model-dir", help="run the real engine on CPU instead of reading predictions")
    parser.add_argument("--stage-dir", help="staging directory for --model-dir")
    parser.add_argument("--calibration")
    parser.add_argument("--sha256")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--out")
    parser.add_argument("--require-all", action="store_true")
    args = parser.parse_args(argv)
    if bool(args.predictions) == bool(args.model_dir):
        parser.error("pass exactly one of --predictions or --model-dir")
    gold = load_jsonl(args.gold)
    calib = None
    if args.model_dir:
        sidecar.offline_guard()
        predictions, engine = run_engine(args, gold)
        if args.calib_gold:
            calib_rows = load_jsonl(args.calib_gold)
            calib = (calib_rows, [{"id": r["id"], "result": engine.classify(sidecar.normalize_text(r["utterance"]))}
                                  for r in calib_rows])
    else:
        predictions = load_jsonl(args.predictions)
        if args.calib_gold and args.calib_predictions:
            calib = (load_jsonl(args.calib_gold), load_jsonl(args.calib_predictions))
        elif args.calib_gold or args.calib_predictions:
            parser.error("--calib-gold and --calib-predictions go together")
    report = evaluate(gold, predictions, calib)
    text = json.dumps(report, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    print(text)
    return 1 if args.require_all and not all(report["promote"].values()) else 0


if __name__ == "__main__":
    sys.exit(main())
