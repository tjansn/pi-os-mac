import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { LAYA_INTENT_LABELS, LAYA_TIER_LEVELS } from "../src/classifier/questions.js";

// Pure-Python parts of sidecars/laya/finetune only: no torch, no model, no training.
// train.py is parsed (ast) and inspected, never executed.
const FINETUNE = join(import.meta.dirname, "..", "..", "sidecars", "laya", "finetune");
const FIXTURES = join(FINETUNE, "fixtures", "pi-os-intent-v1.test.jsonl");

function findPython(): string | undefined {
  for (const candidate of [process.env.PI_OS_TEST_PYTHON, "python3", "python"]) {
    if (!candidate) continue;
    const probe = spawnSync(candidate, ["-I", "-B", "-c", "import sys; assert sys.version_info >= (3, 8); print(sys.executable)"], {
      encoding: "utf8", timeout: 10_000,
    });
    const path = probe.stdout?.trim();
    if (probe.status === 0 && path && isAbsolute(path)) return path;
  }
  return undefined;
}
const PYTHON = findPython();
const skip = PYTHON ? false : "python3 >= 3.8 is not available";

interface Row { id: string; lang?: string; utterance: string; app?: string; template?: string; split?: string;
  labels: { intent: string; tier: number; screen: boolean; surface: string } }

const readRows = (path: string): Row[] => readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Row);
const python = (args: string[]) => spawnSync(PYTHON!, ["-B", ...args], { encoding: "utf8", timeout: 60_000, cwd: FINETUNE });

test("frozen fixtures: 49 EN/DE rows with valid pi-os-intent-v1 labels", () => {
  const rows = readRows(FIXTURES);
  assert.equal(rows.length, 49);
  assert.deepEqual(new Set(rows.map((row) => row.lang)), new Set(["en", "de"]));
  for (const row of rows) {
    assert.ok((LAYA_INTENT_LABELS as readonly string[]).includes(row.labels.intent), row.id);
    assert.ok(row.labels.tier >= 0 && row.labels.tier < LAYA_TIER_LEVELS.length, row.id);
    assert.ok(["browser", "native_app", "none"].includes(row.labels.surface), row.id);
  }
});

test("generate_dataset.py is deterministic, covers every label and never leaks test fixtures", { skip }, () => {
  const out = mkdtempSync(join(tmpdir(), "pi-os-laya-data-"));
  const first = python(["generate_dataset.py", "--out-dir", join(out, "a"), "--seed", "7"]);
  const again = python(["generate_dataset.py", "--out-dir", join(out, "b"), "--seed", "7"]);
  const other = python(["generate_dataset.py", "--out-dir", join(out, "c"), "--seed", "8"]);
  for (const run of [first, again, other]) assert.equal(run.status, 0, run.stderr);
  for (const split of ["train.jsonl", "calib.jsonl"]) {
    assert.equal(readFileSync(join(out, "a", split), "utf8"), readFileSync(join(out, "b", split), "utf8"));
  }
  assert.notEqual(readFileSync(join(out, "a", "train.jsonl"), "utf8"), readFileSync(join(out, "c", "train.jsonl"), "utf8"));
  const summary = JSON.parse(first.stdout) as { rows: number; splits: Record<string, number> };
  const train = readRows(join(out, "a", "train.jsonl"));
  const calib = readRows(join(out, "a", "calib.jsonl"));
  assert.equal(train.length + calib.length, summary.rows);
  assert.ok(calib.length > 0 && train.length > calib.length);
  // Calibration rows come from held-out templates, not just held-out fills.
  const trainTemplates = new Set(train.map((row) => row.template));
  assert.ok(calib.every((row) => !trainTemplates.has(row.template)));
  const all = [...train, ...calib];
  for (const label of LAYA_INTENT_LABELS) assert.ok(train.some((row) => row.labels.intent === label), label);
  assert.deepEqual(new Set(all.map((row) => row.labels.tier)), new Set([0, 1, 2, 3]));
  assert.deepEqual(new Set(all.map((row) => row.lang)), new Set(["en", "de"]));
  assert.ok(all.some((row) => row.labels.screen) && all.every((row) => row.utterance.length <= 500));
  const fixtureTexts = new Set(readRows(FIXTURES).map((row) => row.utterance.toLowerCase().split(/\s+/u).join(" ")));
  assert.ok(all.every((row) => !fixtureTexts.has(row.utterance.toLowerCase().split(/\s+/u).join(" "))));
  assert.ok(!first.stdout.includes(all[0]!.utterance)); // counts only on stdout
});

const TIERS = ["none", "little", "moderate", "heavy"];
function prediction(id: string, intent: string, p: number, tier: number, screen: boolean, surface: string) {
  const probs = Object.fromEntries(LAYA_INTENT_LABELS.map((label) => [label, label === intent ? p : Math.round(((1 - p) / 9) * 10_000) / 10_000]));
  return {
    id,
    result: {
      advisory: true, questions: "pi-os-intent-v1", intent: { label: intent, p, probs },
      tier: { label: TIERS[tier], p: 0.85, expected: tier, probs: Object.fromEntries(TIERS.map((name, i) => [name, i === tier ? 0.85 : 0.05])) },
      screen: { p: screen ? 0.95 : 0.02 },
      surface: { label: surface, p: 0.9, probs: { browser: 0.05, native_app: 0.05, none: 0.9 } },
      usage: { input_tokens: 0, state_tokens: 0 },
    },
  };
}

const jsonl = (path: string, rows: unknown[]) => writeFileSync(path, rows.map((row) => JSON.stringify(row)).join("\n") + "\n");

test("eval.py gates: thresholds from calibration, false fast-path rate blocks promotion", { skip }, () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-laya-eval-"));
  const gold = readRows(FIXTURES);
  const calibGold: Row[] = LAYA_INTENT_LABELS.flatMap((label) => Array.from({ length: 60 }, (_, i) => ({
    id: `k-${label}-${i}`, utterance: "calibration row", labels: { intent: label, tier: label === "agent_task" ? 2 : 0, screen: false, surface: "none" },
  })));
  jsonl(join(dir, "calib-gold.jsonl"), calibGold);
  jsonl(join(dir, "calib-pred.jsonl"), calibGold.map((row) => prediction(row.id, row.labels.intent, 0.99, row.labels.tier, false, "none")));
  jsonl(join(dir, "perfect.jsonl"), gold.map((row) => prediction(row.id, row.labels.intent, 0.99, row.labels.tier, row.labels.screen, row.labels.surface)));
  jsonl(join(dir, "overconfident.jsonl"), gold.map((row) => prediction(
    row.id, row.labels.intent === "agent_task" ? "dictation" : row.labels.intent, 0.999, row.labels.tier, row.labels.screen, row.labels.surface)));
  const calibArgs = ["--calib-gold", join(dir, "calib-gold.jsonl"), "--calib-predictions", join(dir, "calib-pred.jsonl")];

  const perfect = python(["eval.py", "--predictions", join(dir, "perfect.jsonl"), ...calibArgs]);
  assert.equal(perfect.status, 0, perfect.stderr);
  const good = JSON.parse(perfect.stdout) as Record<string, Record<string, unknown>>;
  assert.deepEqual([good.intent!.pass, good.intent!.false_fast_path_rate, good.tier!.pass], [true, 0, true]);
  assert.ok((good.intent!.promoted_classes as string[]).includes("calculate"));
  assert.deepEqual(good.warnings, []);

  const over = python(["eval.py", "--predictions", join(dir, "overconfident.jsonl"), ...calibArgs, "--require-all"]);
  assert.equal(over.status, 1);
  const bad = JSON.parse(over.stdout) as Record<string, Record<string, unknown>>;
  assert.equal(bad.intent!.pass, false);
  assert.equal(bad.intent!.false_fast_path_rate, 1);
  assert.ok(!(bad.intent!.promoted_classes as string[]).includes("dictation"));
  for (const row of gold) assert.ok(!over.stdout.includes(row.utterance), "reports carry labels and numbers only");

  const uncalibrated = JSON.parse(python(["eval.py", "--predictions", join(dir, "perfect.jsonl")]).stdout) as { warnings: string[] };
  assert.match(uncalibrated.warnings[0] ?? "", /fitted on the test rows/u);
  const incomplete = python(["eval.py", "--predictions", join(dir, "calib-pred.jsonl")]);
  assert.notEqual(incomplete.status, 0);
});

test("gpu_lock.py takes a non-blocking exclusive flock: free, busy (refuse, never wait), missing (never create)",
  { skip: process.platform === "win32" ? "flock is POSIX-only" : skip }, async (t) => {
    const dir = mkdtempSync(join(tmpdir(), "pi-os-gpu-lock-"));
    const lock = join(dir, "test.lock"); // a private temp file; never the shared GPU lock
    writeFileSync(lock, "");
    assert.equal(python(["gpu_lock.py", "--check", lock]).status, 0);

    const holder = spawn(PYTHON!, ["-B", "-c",
      "import sys; sys.path.insert(0, sys.argv[1]); import gpu_lock; fd = gpu_lock.acquire(sys.argv[2]); print('held', flush=True); sys.stdin.read()",
      FINETUNE, lock]);
    const exited = new Promise<number | null>((resolve) => holder.once("exit", (code) => resolve(code)));
    t.after(async () => { if (holder.exitCode === null) { holder.stdin.end(); await exited; } });
    await new Promise<void>((resolve) => createInterface({ input: holder.stdout }).once("line", () => resolve()));
    const started = Date.now();
    const busy = python(["gpu_lock.py", "--check", lock]);
    assert.deepEqual([busy.status, busy.stdout.trim()], [75, "busy"]);
    assert.ok(Date.now() - started < 5_000); // refused immediately instead of waiting
    holder.stdin.end();
    assert.equal(await exited, 0);
    assert.equal(python(["gpu_lock.py", "--check", lock]).status, 0);

    const missing = join(dir, "absent.lock");
    assert.deepEqual([python(["gpu_lock.py", "--check", missing]).status], [66]);
    assert.throws(() => readFileSync(missing));
  });

test("train.py parses, defaults to CPU, gates MPS behind the lock and hard-codes no lock path", { skip }, () => {
  for (const file of ["generate_dataset.py", "train.py", "eval.py", "gpu_lock.py", "../laya_intent_sidecar.py"]) {
    const parsed = python(["-c", "import ast, sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())", file]);
    assert.equal(parsed.status, 0, `${file}: ${parsed.stderr}`);
  }
  const source = readFileSync(join(FINETUNE, "train.py"), "utf8");
  assert.match(source, /choices=\["cpu", "mps"\], default="cpu"/u);
  assert.match(source, /--device mps requires --gpu-lock-path/u);
  assert.ok(source.indexOf("gpu_lock.acquire(") < source.indexOf("    import torch"), "lock before torch");
  assert.ok(source.indexOf("sidecar.offline_guard()") < source.indexOf("    import torch"), "kill-switch before torch");
  for (const file of ["train.py", "eval.py", "gpu_lock.py", "generate_dataset.py", "../laya_intent_sidecar.py"]) {
    const text = readFileSync(join(FINETUNE, file), "utf8");
    assert.doesNotMatch(text, /_LOCAL_AI|local-inference\.lock|\/Users\//u, file);
    assert.doesNotMatch(text, /os\.(remove|unlink|rmdir)|shutil\.rmtree|send2trash/u, file);
  }
});
