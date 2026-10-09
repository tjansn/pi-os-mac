import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { ClassifierModel, ClassifierResult } from "@earendil-works/pi-ai";
import { createClassifier } from "../src/classifier/factory.js";
import type { ClassifierRuntime } from "../src/classifier/piClassifier.js";
import {
  ClassifierSettingsStore, defaultSidecarScript, parseClassifierSettings, resolveLayaLaunch,
} from "../src/classifier/settings.js";
import { formatShadowLine, ShadowLogWriter, withShadowLog } from "../src/classifier/shadowLog.js";

const temp = (prefix: string) => mkdtempSync(join(tmpdir(), prefix));
const PYTHON = "/opt/venvs/laya/bin/python";
const MODEL_DIR = "/opt/models/laya/multilingual";

test("classifier settings validation: closed kinds, absolute paths, catalog ids, defaults off", () => {
  assert.deepEqual(parseClassifierSettings({ kind: "off" }), { ok: true, settings: { kind: "off", shadowLog: false } });
  const full = parseClassifierSettings({
    kind: "laya", python: PYTHON, modelDir: MODEL_DIR, sha256: "AB".repeat(32), threads: 6, shadowLog: true,
    provider: "", model: null, extra: "ignored",
  });
  assert.deepEqual(full, {
    ok: true, settings: { kind: "laya", python: PYTHON, modelDir: MODEL_DIR, sha256: "ab".repeat(32), threads: 6, shadowLog: true },
  });
  assert.deepEqual(parseClassifierSettings({ kind: "pi", provider: "cloudflare-workers-ai", model: "typesafe/jev" }), {
    ok: true, settings: { kind: "pi", provider: "cloudflare-workers-ai", model: "typesafe/jev", shadowLog: false },
  });
  const rejected: unknown[] = [
    null, [], {}, { kind: "gpu" }, { kind: "laya", python: "python3" }, { kind: "laya", modelDir: "models/laya" },
    { kind: "laya", python: `${PYTHON}\n--fake` }, { kind: "laya", sha256: "xyz" }, { kind: "laya", threads: 0 },
    { kind: "laya", threads: 2.5 }, { kind: "pi", provider: " typesafe" }, { kind: "pi", model: "x".repeat(201) },
    { kind: "off", shadowLog: "yes" },
  ];
  for (const value of rejected) assert.equal(parseClassifierSettings(value).ok, false, JSON.stringify(value));
});

test("ClassifierSettingsStore: missing/malformed files mean off; writes are atomic, private and path-free in logs", () => {
  const dir = temp("pi-os-classifier-settings-");
  const path = join(dir, "nested", "classifier.json");
  const logs: string[] = [];
  const store = new ClassifierSettingsStore(path, (line) => logs.push(line));
  assert.deepEqual(store.get(), { kind: "off", shadowLog: false });

  const saved = store.set({ kind: "laya", python: PYTHON, modelDir: MODEL_DIR, shadowLog: true });
  assert.deepEqual(saved, { kind: "laya", python: PYTHON, modelDir: MODEL_DIR, shadowLog: true });
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), saved);
  if (process.platform !== "win32") assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.equal(existsSync(`${path}.tmp`), false);
  assert.deepEqual(new ClassifierSettingsStore(path, () => {}).get(), saved);
  assert.throws(() => store.set({ kind: "laya", python: "relative/python" }), /absolute path/u);
  assert.deepEqual(store.get(), saved); // invalid input never replaces the stored choice

  writeFileSync(path, "{not json");
  assert.deepEqual(new ClassifierSettingsStore(path, (line) => logs.push(line)).get(), { kind: "off", shadowLog: false });
  writeFileSync(path, JSON.stringify({ kind: "laya", note: "x".repeat(20_000) }));
  assert.deepEqual(new ClassifierSettingsStore(path, (line) => logs.push(line)).get(), { kind: "off", shadowLog: false });
  assert.ok(!logs.some((line) => line.includes(dir) || line.includes(PYTHON)), logs.join("\n"));
});

test("Laya launch resolution: settings first, then PI_OS_LAYA_* env, absolute paths only", () => {
  const present = new Set([PYTHON, join(MODEL_DIR, "rl_agent_config.json"), defaultSidecarScript(), "/env/python", join("/env/model", "rl_agent_config.json")]);
  const exists = (path: string) => present.has(path);
  assert.ok(existsSync(defaultSidecarScript()), "the sidecar ships next to node-harness");

  assert.deepEqual(resolveLayaLaunch({ kind: "laya", python: PYTHON, modelDir: MODEL_DIR, threads: 2 }, {}, exists), {
    ok: true, launch: { python: PYTHON, script: defaultSidecarScript(), modelDir: MODEL_DIR, threads: 2 },
  });
  const fromEnv = resolveLayaLaunch({ kind: "laya" }, { PI_OS_LAYA_PYTHON: "/env/python", PI_OS_LAYA_MODEL_DIR: "/env/model" }, exists);
  assert.deepEqual(fromEnv.ok && [fromEnv.launch.python, fromEnv.launch.modelDir, fromEnv.launch.threads], ["/env/python", "/env/model", 4]);
  const reason = (settings: Parameters<typeof resolveLayaLaunch>[0], env: NodeJS.ProcessEnv = {}) => {
    const resolved = resolveLayaLaunch(settings, env, exists);
    return resolved.ok ? "ok" : resolved.reason;
  };
  assert.equal(reason({ kind: "laya" }), "python_not_configured");
  assert.equal(reason({ kind: "laya" }, { PI_OS_LAYA_PYTHON: "python3", PI_OS_LAYA_MODEL_DIR: MODEL_DIR }), "python_not_configured");
  assert.equal(reason({ kind: "laya", python: "/missing/python" }), "python_not_found");
  assert.equal(reason({ kind: "laya", python: PYTHON }), "model_dir_not_configured");
  assert.equal(reason({ kind: "laya", python: PYTHON, modelDir: "/no/model" }), "model_dir_not_found");
  assert.equal(reason({ kind: "laya", python: PYTHON, modelDir: MODEL_DIR, script: "/no/sidecar.py" }), "script_not_found");
  assert.equal(reason({ kind: "laya", python: PYTHON, modelDir: MODEL_DIR, calibration: "/no/cal.json" }), "calibration_not_found");
});

test("factory: off and unusable configurations stay inert and never spawn anything", async () => {
  const logs: string[] = [];
  const signal = new AbortController().signal;
  const off = createClassifier({ kind: "off" });
  assert.deepEqual(off.status(), { kind: "off", state: "off", shadowLog: false });
  assert.equal(await off.classify("open Spotify", signal), null);
  assert.equal(off.sidecar, undefined);

  const unconfigured = createClassifier({ kind: "laya" }, { env: {}, log: (line) => logs.push(line) });
  assert.deepEqual(unconfigured.status(), { kind: "laya", state: "unavailable", shadowLog: false, reason: "python_not_configured" });
  assert.equal(unconfigured.sidecar, undefined);
  assert.equal(await unconfigured.classify("open Spotify", signal), null);

  const killSwitch = createClassifier({ kind: "laya", python: PYTHON, modelDir: MODEL_DIR }, { env: { PI_OS_LAYA: "0" }, exists: () => true });
  assert.equal(killSwitch.status().reason, "disabled_by_env");
  assert.equal(killSwitch.sidecar, undefined);

  const configured = createClassifier({ kind: "laya", python: PYTHON, modelDir: MODEL_DIR }, {
    env: {}, exists: () => true, supportDir: temp("pi-os-classifier-support-"), log: (line) => logs.push(line),
  });
  assert.equal(configured.status().state, "stopped"); // created, not started
  assert.equal(configured.sidecar?.pid, undefined);
  await configured.dispose();

  assert.equal(createClassifier({ kind: "pi" }).status().reason, "model_not_configured");
  assert.equal(createClassifier({ kind: "pi", provider: "typesafe", model: "jev-latest" }).status().reason, "runtime_unavailable");
  assert.ok(!logs.some((line) => line.includes(PYTHON) || line.includes(MODEL_DIR)), logs.join("\n"));
});

function fakeRuntime(): ClassifierRuntime {
  const model: ClassifierModel<string> = {
    type: "classifier", id: "jev-latest", name: "Jev", api: "typesafe-system-one", provider: "typesafe",
    baseUrl: "https://api.invalid/v1/", input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 64_000,
  };
  return {
    getModelOfType: (() => model) as ClassifierRuntime["getModelOfType"],
    classify: async (): Promise<ClassifierResult> => ({
      api: model.api, provider: model.provider, model: model.id, stopReason: "stop", timestamp: 0,
      answers: { intent: { type: "choice", choice: "agent_task", probabilities: { agent_task: 0.66 }, confidence: 0.5 } },
    }),
  };
}

test("factory kind pi + opt-in shadow log records labels and latency, never the utterance", async () => {
  const support = temp("pi-os-classifier-shadow-");
  const managed = createClassifier({ kind: "pi", provider: "typesafe", model: "jev-latest", shadowLog: true }, {
    supportDir: support, modelRuntime: async () => fakeRuntime(), log: () => {},
  });
  assert.deepEqual(managed.status(), { kind: "pi", state: "configured", name: "pi:typesafe/jev-latest", shadowLog: true });
  const hints = await managed.classify("reply to SENTINEL4711 about the lease", new AbortController().signal);
  assert.deepEqual([hints?.source, hints?.intent, hints?.intentP], ["pi-classifier", "other", 0.66]);
  managed.shadow?.record({ classifier: "heuristic", latencyMs: 0.2, hints: null, reference: { intent: "write", tier: "quick" } });
  await managed.dispose();
  const text = readFileSync(join(support, "logs", "classifier-shadow.jsonl"), "utf8");
  assert.doesNotMatch(text, /SENTINEL4711|lease|reply/u);
  const [first, second] = text.trim().split("\n");
  assert.deepEqual((JSON.parse(second!) as Record<string, unknown>).reference, { intent: "write", tier: "quick" });
  const line = JSON.parse(first!) as Record<string, unknown>;
  assert.deepEqual(Object.keys(line).sort(), ["classifier", "intent", "intentP", "latencyMs", "outcome", "source", "ts"]);
  assert.deepEqual([line.classifier, line.outcome, line.intent, line.intentP], ["pi:typesafe/jev-latest", "hints", "other", 0.66]);

  const off = createClassifier({ kind: "pi", provider: "typesafe", model: "jev-latest" }, { supportDir: support, modelRuntime: async () => fakeRuntime() });
  assert.equal(off.status().shadowLog, false);
  assert.equal(off.shadow, undefined);
});

test("shadow lines are whitelisted and sanitized; the writer stops at its size cap without deleting", async () => {
  const line = JSON.parse(formatShadowLine({
    classifier: "laya; rm -rf ~ \"quoted\"",
    latencyMs: 113.84,
    hints: {
      source: "laya", latencyMs: 1, intent: "type my password" as never, intentP: 1.7, tier: "ultra" as never,
      tierP: 0.12346, needsScreen: -1, utterance: "SECRET" } as never,
    reference: { intent: "write", tier: "fast" },
  }, new Date(0))) as Record<string, unknown>;
  assert.deepEqual(line, {
    ts: "1970-01-01T00:00:00.000Z", classifier: "laya__rm_-rf____quoted_", latencyMs: 113.8, outcome: "hints",
    source: "laya", intentP: 1, tierP: 0.1235, needsScreen: 0, reference: { intent: "write", tier: "fast" },
  });

  const dir = temp("pi-os-classifier-cap-");
  const path = join(dir, "shadow.jsonl");
  const logs: string[] = [];
  const writer = new ShadowLogWriter(path, { maxBytes: 300, log: (entry) => logs.push(entry) });
  const classifier = withShadowLog({ name: "laya", classify: async () => null }, writer);
  for (let i = 0; i < 10; i++) await classifier.classify("anything", new AbortController().signal);
  await writer.flush();
  const lines = readFileSync(path, "utf8").trim().split("\n");
  assert.ok(lines.length >= 1 && lines.length < 10);
  assert.ok(statSync(path).size <= 300);
  assert.deepEqual(logs, ["[classifier] shadow log reached its size cap; shadow logging paused"]);
  assert.equal((JSON.parse(lines[0]!) as Record<string, unknown>).outcome, "null");
});
