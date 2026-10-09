import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import { resolveSessionModel } from "../src/agent/agentRunner.js";

function tempStore(): string {
  return join(mkdtempSync(join(tmpdir(), "pi-os-settings-")), "settings.json");
}

function quietLog(): (line: string) => void {
  return () => {};
}

test("missing file -> no preference", () => {
  const store = new AgentModelSettings(tempStore(), quietLog);
  assert.equal(store.get(), null);
});

test("set persists a readable selection and returns the previous one", () => {
  const path = tempStore();
  const store = new AgentModelSettings(path, quietLog);

  const first = store.set({ provider: "openai", modelId: "gpt-5.2", thinkingLevel: "high" });
  assert.equal(first, null);

  // Reload from disk in a fresh instance to prove persistence.
  const reloaded = new AgentModelSettings(path, quietLog);
  assert.deepEqual(reloaded.get(), { provider: "openai", modelId: "gpt-5.2", thinkingLevel: "high" });

  const previous = store.set({ provider: "xai", modelId: "grok-4", thinkingLevel: "off" });
  assert.deepEqual(previous, { provider: "openai", modelId: "gpt-5.2", thinkingLevel: "high" });
  assert.equal(
    JSON.parse(readFileSync(path, "utf8")).model.modelId,
    "grok-4",
  );
});

test("malformed or incomplete files degrade to no preference", () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-settings-"));

  for (const [name, content] of [
    ["broken.json", "{not json"],
    ["incomplete.json", JSON.stringify({ model: { provider: "openai" } })],
    ["empty.json", ""],
  ] as const) {
    const path = join(dir, name);
    writeFileSync(path, content, "utf8");
    const store = new AgentModelSettings(path, quietLog);
    assert.equal(store.get(), null, name);
  }
});

test("saving a model is an atomic read-modify-write of the model key: routing and unknown keys survive", () => {
  const path = tempStore();
  writeFileSync(path, JSON.stringify({ routing: { bias: "speed", maxAutoTier: "deep", allowLocalModels: false }, future: [1, 2] }), "utf8");
  const store = new AgentModelSettings(path, quietLog);
  assert.equal(store.get(), null);
  store.set({ provider: "pi-os", modelId: "auto", thinkingLevel: "low" });
  const saved = JSON.parse(readFileSync(path, "utf8"));
  assert.deepEqual(saved, {
    routing: { bias: "speed", maxAutoTier: "deep", allowLocalModels: false }, future: [1, 2],
    model: { provider: "pi-os", modelId: "auto", thinkingLevel: "low" },
  });
});

test("resolveSessionModel: Auto is the default on macOS only; Windows keeps pi's default unless Auto is chosen", () => {
  const known = new Map([["pi-os/auto", { provider: "pi-os", id: "auto" }], ["fx/fast", { provider: "fx", id: "fast" }]]);
  const runtime = { getModel: (provider: string, id: string) => known.get(`${provider}/${id}`) as never };
  const gone = { provider: "gone", modelId: "removed", thinkingLevel: "high" };
  const manual = { provider: "fx", modelId: "fast", thinkingLevel: "low" };
  const auto = { provider: "pi-os", modelId: "auto", thinkingLevel: "high" };

  // Windows: nothing stored → no explicit model (pi resolves defaultProvider/defaultModel); a lost model too.
  assert.deepEqual(resolveSessionModel(runtime, null, "balanced", "win32"), { auto: false });
  const lost = resolveSessionModel(runtime, gone, "balanced", "win32");
  assert.deepEqual([lost.auto, lost.model, lost.thinkingLevel], [false, undefined, undefined]);
  assert.match(lost.fallbackReason ?? "", /gone\/removed is not registered/);
  const chosen = resolveSessionModel(runtime, auto, "balanced", "win32");
  assert.deepEqual([chosen.auto, chosen.model?.id, chosen.thinkingLevel], [true, "auto", "high"]);
  assert.deepEqual(resolveSessionModel(runtime, manual, "balanced", "win32").model?.id, "fast");

  // macOS: Auto at the routing bias for nothing stored and for a lost model; a stored Auto keeps its level.
  const none = resolveSessionModel(runtime, null, "balanced", "darwin");
  assert.deepEqual([none.auto, none.model?.id, none.thinkingLevel], [true, "auto", "medium"]);
  const lostMac = resolveSessionModel(runtime, gone, "speed", "darwin");
  assert.deepEqual([lostMac.auto, lostMac.model?.id, lostMac.thinkingLevel], [true, "auto", "low"]);
  assert.match(lostMac.fallbackReason ?? "", /not registered/);
  const storedAuto = resolveSessionModel(runtime, auto, "balanced", "darwin");
  assert.deepEqual([storedAuto.auto, storedAuto.thinkingLevel], [true, "high"]);
  assert.deepEqual(resolveSessionModel(runtime, manual, "balanced", "darwin"), { auto: false, model: known.get("fx/fast"), thinkingLevel: "low" });
});
