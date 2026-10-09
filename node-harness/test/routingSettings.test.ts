import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import {
  candidateInfo, DEFAULT_ROUTING_SETTINGS, parseRoutingSettings, RoutingSettingsStore, validateRoutingPatch,
  validateTierOverrides, type CandidateInfo,
} from "../src/agent/routing/index.js";
import type { Api, Model } from "@earendil-works/pi-ai";

const quiet = () => {};
const tempPath = () => join(mkdtempSync(join(tmpdir(), "pi-os-routing-settings-")), "settings.json");

test("missing or garbage routing settings fall back to defaults field by field", () => {
  assert.deepEqual(new RoutingSettingsStore(tempPath(), quiet).get(), DEFAULT_ROUTING_SETTINGS);
  assert.deepEqual(DEFAULT_ROUTING_SETTINGS, { bias: "balanced", maxAutoTier: "deep", allowLocalModels: false });
  assert.deepEqual(parseRoutingSettings({ bias: "turbo", maxAutoTier: "instant", allowLocalModels: "yes", tierOverrides: { deep: { provider: "p" }, bogus: {} } }),
    DEFAULT_ROUTING_SETTINGS);
  assert.deepEqual(parseRoutingSettings({ bias: "speed", tierOverrides: { quick: { provider: "openai-codex", modelId: "gpt-6-luna", thinkingLevel: "off" } } }), {
    ...DEFAULT_ROUTING_SETTINGS, bias: "speed",
    tierOverrides: { quick: { provider: "openai-codex", id: "gpt-6-luna", thinkingLevel: "off" } },
  });
});

test("set merges a patch under the routing key and preserves the model selection and unknown keys", () => {
  const path = tempPath();
  writeFileSync(path, JSON.stringify({ model: { provider: "pi-os", modelId: "auto", thinkingLevel: "medium" }, hostOnly: { x: 1 } }));
  const store = new RoutingSettingsStore(path, quiet);
  store.set({ bias: "quality", tierOverrides: { deep: { provider: "openai-codex", id: "gpt-6-astra", thinkingLevel: "medium" } } });
  store.set({ allowLocalModels: true });
  const file = JSON.parse(readFileSync(path, "utf8"));
  assert.deepEqual(file.model, { provider: "pi-os", modelId: "auto", thinkingLevel: "medium" });
  assert.deepEqual(file.hostOnly, { x: 1 });
  assert.deepEqual(file.routing, {
    bias: "quality", maxAutoTier: "deep", allowLocalModels: true,
    tierOverrides: { deep: { provider: "openai-codex", id: "gpt-6-astra", thinkingLevel: "medium" } },
  });
  // The existing model store still reads its key from the shared file.
  assert.deepEqual(new AgentModelSettings(path, quiet).get(), { provider: "pi-os", modelId: "auto", thinkingLevel: "medium" });
  // null clears one tier / all overrides.
  assert.equal(store.set({ tierOverrides: { deep: null } }).tierOverrides, undefined);
  store.set({ tierOverrides: { quick: { provider: "a", id: "b", thinkingLevel: "off" } } });
  assert.equal(store.set({ tierOverrides: null }).tierOverrides, undefined);
  assert.equal(new RoutingSettingsStore(path, quiet).get().bias, "quality", "persisted across instances");
});

test("a failed write keeps the new settings in memory, logs, and leaves the file intact", () => {
  const path = tempPath();
  writeFileSync(path, JSON.stringify({ model: { provider: "keep" } }));
  mkdirSync(`${path}.${process.pid}.tmp`);
  const lines: string[] = [];
  const store = new RoutingSettingsStore(path, line => lines.push(line));
  assert.equal(store.set({ bias: "speed" }).bias, "speed");
  assert.equal(store.get().bias, "speed");
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), { model: { provider: "keep" } });
  assert.ok(lines.some(line => line.includes("failed saving routing settings")));
});

test("POST bodies are validated strictly", () => {
  assert.deepEqual(validateRoutingPatch({ bias: "speed", maxAutoTier: "standard", allowLocalModels: false }),
    { ok: true, patch: { bias: "speed", maxAutoTier: "standard", allowLocalModels: false } });
  for (const body of [null, [], { bias: "turbo" }, { maxAutoTier: "instant" }, { allowLocalModels: 1 }, { mode: "auto" },
    { tierOverrides: [] }, { tierOverrides: { ultra: null } }, { tierOverrides: { deep: { provider: "x", id: "y" } } },
    { tierOverrides: { deep: { provider: "x", id: "y", thinkingLevel: "turbo" } } },
    { tierOverrides: { deep: { provider: "../x", id: "y", thinkingLevel: "low" } } }]) {
    assert.equal(validateRoutingPatch(body).ok, false, JSON.stringify(body));
  }
  const cleared = validateRoutingPatch({ tierOverrides: { deep: null } });
  assert.deepEqual(cleared, { ok: true, patch: { tierOverrides: { deep: null } } });
});

test("overrides are checked against the available catalog and supported levels", () => {
  const sol: Model<Api> = {
    id: "gpt-6.1-sol", name: "GPT-6.1 Sol", api: "openai-codex-responses", provider: "openai-codex", baseUrl: "https://chatgpt.com/backend-api",
    reasoning: true, input: ["text", "image"], cost: { input: 2, output: 10, cacheRead: 0, cacheWrite: 0 }, contextWindow: 272_000, maxTokens: 128_000,
    thinkingLevelMap: { off: null, minimal: "low", low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max" },
  };
  const candidates = new Map<string, CandidateInfo>([["openai-codex/gpt-6.1-sol", candidateInfo(sol)]]);
  assert.equal(validateTierOverrides({ deep: { provider: "openai-codex", id: "gpt-6.1-sol", thinkingLevel: "medium" }, quick: null }, candidates), undefined);
  assert.match(validateTierOverrides({ deep: { provider: "openai-codex", id: "gpt-6.1-sol", thinkingLevel: "off" } }, candidates) ?? "", /does not support thinking level off/);
  assert.match(validateTierOverrides({ max: { provider: "anthropic", id: "claude-opus-5-5", thinkingLevel: "high" } }, candidates) ?? "", /not available/);
});
