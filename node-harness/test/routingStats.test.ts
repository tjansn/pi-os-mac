import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { classifyProviderError, DEFAULT_STATS_ALPHA, HEALTH_PENALTY_MS, LatencyStats } from "../src/agent/routing/index.js";

const quiet = () => {};
const tempPath = () => join(mkdtempSync(join(tmpdir(), "pi-os-routing-stats-")), "routing-stats.json");

test("EWMA starts at the first sample and moves by alpha; throughput needs enough tokens", () => {
  const stats = new LatencyStats({ alpha: 0.5, log: quiet });
  const luna = { provider: "openai-codex", model: "gpt-6-luna", thinkingLevel: "off" };
  stats.record({ ...luna, ttftMs: 1_000, outputTokens: 200, streamMs: 2_000 });
  assert.deepEqual(stats.get("openai-codex/gpt-6-luna@off"), { n: 1, ttftMs: 1_000, tpsN: 1, tps: 100 });
  stats.record({ ...luna, ttftMs: 2_000, tokensPerSecond: 200 });
  assert.deepEqual(stats.get("openai-codex/gpt-6-luna@off"), { n: 2, ttftMs: 1_500, tpsN: 2, tps: 150 });
  stats.record({ ...luna, ttftMs: 500, outputTokens: 3, streamMs: 10 }); // tiny answer: TTFT only
  assert.equal(stats.get("openai-codex/gpt-6-luna@off")?.tpsN, 2);
  stats.record({ ...luna, ttftMs: Number.NaN });
  stats.record({ ...luna, ttftMs: -5 });
  assert.equal(stats.get("openai-codex/gpt-6-luna@off")?.n, 3, "invalid samples are ignored");
  assert.equal(stats.getFor({ provider: "openai-codex", id: "gpt-6-luna", thinkingLevel: "off" })?.n, 3);
});

test("the default EWMA weighs a new sample at 0.5: backend latency moves within hours", () => {
  assert.equal(DEFAULT_STATS_ALPHA, 0.5);
  const stats = new LatencyStats({ log: quiet });
  const sol = { provider: "openai-codex", model: "gpt-6.1-sol", thinkingLevel: "low" };
  stats.record({ ...sol, ttftMs: 2_000 });
  stats.record({ ...sol, ttftMs: 6_000 });
  assert.equal(stats.get("openai-codex/gpt-6.1-sol@low")?.ttftMs, 4_000);
});

test("health blocks cover a model or a whole provider and expire", () => {
  let now = 1_000_000;
  const lines: string[] = [];
  const stats = new LatencyStats({ now: () => now, log: line => lines.push(line) });
  stats.block("openai-codex", HEALTH_PENALTY_MS.rate_limit, "rate_limit", "gpt-6-luna");
  assert.equal(stats.blocked("openai-codex", "gpt-6-luna"), true);
  assert.equal(stats.blocked("openai-codex", "gpt-6-sol"), false);
  stats.block("anthropic", HEALTH_PENALTY_MS.quota, "quota");
  assert.equal(stats.blocked("anthropic", "claude-haiku-4-5"), true);
  now += 61_000;
  assert.equal(stats.blocked("openai-codex", "gpt-6-luna"), false);
  assert.equal(stats.blocked("anthropic", "claude-haiku-4-5"), true);
  now += 30 * 60_000;
  assert.equal(stats.blocked("anthropic", "claude-haiku-4-5"), false);
  assert.deepEqual(stats.active(), []);
  assert.match(lines[0]!, /^\[route\] health block provider=openai-codex model=gpt-6-luna reason=rate_limit s=60$/);
});

test("stats persist atomically with ids and numbers only, and reload (dropping expired blocks)", () => {
  const path = tempPath();
  let now = 5_000_000;
  const stats = new LatencyStats({ path, now: () => now, persistDelayMs: 0, log: quiet });
  stats.record({ provider: "openai-codex", model: "gpt-6-sol", thinkingLevel: "off", ttftMs: 900, tokensPerSecond: 80 });
  stats.recordError({ provider: "openai-codex", model: "gpt-6-sol", thinkingLevel: "off" });
  stats.block("openai-codex", 60_000, "overloaded", "gpt-6-sol");
  stats.block("anthropic", 1_000, "rate_limit");
  const file = JSON.parse(readFileSync(path, "utf8"));
  assert.deepEqual(Object.keys(file).sort(), ["blocks", "models", "version"]);
  assert.deepEqual(Object.keys(file.models), ["openai-codex/gpt-6-sol@off"]);
  assert.deepEqual(Object.keys(file.models["openai-codex/gpt-6-sol@off"]).sort(), ["errors", "lastErrorAt", "n", "tps", "tpsN", "ttftMs", "updatedAt"]);
  now += 2_000;
  const reloaded = new LatencyStats({ path, now: () => now, log: quiet });
  assert.deepEqual(reloaded.get("openai-codex/gpt-6-sol@off"), { n: 1, ttftMs: 900, tpsN: 1, tps: 80 });
  assert.equal(reloaded.blocked("openai-codex", "gpt-6-sol"), true);
  assert.equal(reloaded.blocked("anthropic", "x"), false, "expired block dropped on load");
});

test("hostile or corrupt stats files are ignored entry by entry", () => {
  const path = tempPath();
  writeFileSync(path, JSON.stringify({
    version: 1,
    models: { "ok/m@off": { n: 3, ttftMs: 700, tpsN: 3, tps: 90 }, "bad key with spaces": { n: 1, ttftMs: 1, tpsN: 0, tps: 0 },
      "neg/m@off": { n: -1, ttftMs: 1, tpsN: 0, tps: 0 }, "huge/m@off": { n: 1, ttftMs: 1e12, tpsN: 0, tps: 0 } },
    blocks: [{ provider: "p", until: Date.now() + 60_000, reason: "nonsense" }, "x"],
  }));
  const stats = new LatencyStats({ path, log: quiet });
  assert.deepEqual(stats.snapshot().models, { "ok/m@off": { n: 3, ttftMs: 700, tpsN: 3, tps: 90, errors: 0, lastErrorAt: 0, updatedAt: 0 } });
  assert.deepEqual(stats.active(), []);
  writeFileSync(path, "{broken");
  const lines: string[] = [];
  assert.equal(new LatencyStats({ path, log: line => lines.push(line) }).get("ok/m@off"), undefined);
  assert.deepEqual(lines, ["[route] ignoring unreadable routing stats"]);
});

test("debounced persistence writes once on flush; the entry count is bounded", () => {
  const path = tempPath();
  const stats = new LatencyStats({ path, persistDelayMs: 60_000, maxEntries: 3, log: quiet });
  for (let i = 0; i < 5; i++) stats.record({ provider: "p", model: `m${i}`, thinkingLevel: "off", ttftMs: 100 + i });
  assert.throws(() => readFileSync(path), /ENOENT/, "nothing written before the debounce fires");
  stats.flush();
  assert.equal(Object.keys(JSON.parse(readFileSync(path, "utf8")).models).length, 3);
});

test("provider errors are classified for failover and health penalties", () => {
  const cases: [string, string][] = [
    ["429 Too Many Requests", "rate_limit"],
    ["Rate limit reached for requests", "rate_limit"],
    ["529 overloaded_error: Overloaded", "overloaded"],
    ["503 Service Unavailable", "overloaded"],
    ["We're currently experiencing high demand", "overloaded"],
    ["subscription_sharing_usage_limit_exceeded", "quota"],
    ["insufficient_quota: You exceeded your current quota", "quota"],
    ["prompt is too long: 250000 tokens > 200000 maximum", "context"],
    ["401 Unauthorized", "auth"],
    ["fetch failed", "transient"],
    ["websocket closed before response", "transient"],
    ["something odd", "other"],
    // pi-ai's overflow patterns decide "context"; the word alone does not.
    ["context deadline exceeded", "transient"],
    ["Request took too long to complete", "other"],
    ["Your input exceeds the context window of this model", "context"],
  ];
  for (const [message, kind] of cases) assert.equal(classifyProviderError(message), kind, message);
  assert.equal(classifyProviderError(undefined), "other");
});
