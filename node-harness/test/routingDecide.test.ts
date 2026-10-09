import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { Api, Model } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  BASE_TIERS, buildRouteInput, buildRoutingCatalog, decide, DEFAULT_ROUTING_SETTINGS, distinctThinkingLevels,
  isLocalModel, PRIOR_PROFILES, quickestTarget, sizeClass, targetKey,
  type AgentIntent, type Classification, type LatencyView, type RouteInput, type RoutingCatalog, type RoutingSettings,
  type StatEntry,
} from "../src/agent/routing/index.js";

// Catalogs come from the installed pi-ai 1.0 built-ins (no auth, no network): exactly what
// runtime.getAvailable() returns for a user signed in to that provider only.
const dir = mkdtempSync(join(tmpdir(), "pi-os-routing-catalog-"));
const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing-models.json"), modelsStorePath: join(dir, "models-store.json") });
const codexModels = runtime.getModels("openai-codex");
const anthropicModels = runtime.getModels("anthropic");
const googleModels = runtime.getModels("google");

/** Loopback fixture models shaped like Tom's models.json providers (never contacted). */
function fixtureModel(provider: string, id: string, overrides: Partial<Model<Api>> = {}): Model<Api> {
  return {
    id, name: id, api: "openai-completions", provider, baseUrl: "http://127.0.0.1:8002/v1", reasoning: true,
    input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 131_072, maxTokens: 16_384,
    ...overrides,
  };
}
const localModels = [
  fixtureModel("splash", "incoai/Qwen3.8-27B-Splash"),
  fixtureModel("mesh", "unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_M", { baseUrl: "http://localhost:9337/v1", reasoning: false, input: ["text"], contextWindow: 32_768 }),
];

const TOM = buildRoutingCatalog([...codexModels, ...localModels]);
const ANTHROPIC = buildRoutingCatalog(anthropicModels);
const GOOGLE = buildRoutingCatalog(googleModels);
const S = DEFAULT_ROUTING_SETTINGS;
const settings = (patch: Partial<RoutingSettings>): RoutingSettings => ({ ...S, ...patch });

function input(text: string, extra: Partial<RouteInput> & { surface?: RouteInput["surface"] } = {}): RouteInput {
  const surface = extra.surface ?? "other";
  return { ...buildRouteInput(text, { surface, hasScreenshot: extra.hasScreenshot ?? true, browserCdp: extra.browserCdp ?? false }), ...extra };
}
const pick = (text: string, catalog: RoutingCatalog, s = S, extra: Partial<RouteInput> = {}) => decide(input(text, extra), catalog, s);
const label = (text: string, catalog: RoutingCatalog, s = S, extra: Partial<RouteInput> = {}) => {
  const d = pick(text, catalog, s, extra);
  return `${d.tier} ${d.model ? targetKey(d.model) : "none"}`;
};

test("Tom's openai-codex auth: EN/DE utterances map to the documented ladder (balanced)", () => {
  const table: [string, string][] = [
    ["what's 18% of 240", "quick openai-codex/gpt-6-luna@off"],
    ["what's the capital of france", "quick openai-codex/gpt-6-luna@off"],
    ["wer hat die wm 2014 gewonnen", "quick openai-codex/gpt-6-luna@off"],
    ["kurz: was ist eine wärmepumpe", "quick openai-codex/gpt-6-luna@off"],
    ["why is the sky blue", "fast openai-codex/gpt-6-sol@off"],
    ["click the blue submit button", "fast openai-codex/gpt-6-sol@off"],
    ["klick auf den blauen button", "fast openai-codex/gpt-6-sol@off"],
    ["hmm", "fast openai-codex/gpt-6-sol@off"],
    ["write a python function that parses iso dates", "standard openai-codex/gpt-6.1-sol@low"],
    ["think hard about how to restructure my week", "deep openai-codex/gpt-6.1-sol@medium"],
    ["denk gründlich nach: wie sollte ich meine finanzen planen", "deep openai-codex/gpt-6.1-sol@medium"],
    ["ultrathink: prove that the square root of two is irrational", "max openai-codex/gpt-6-astra@high"],
  ];
  for (const [text, expected] of table) assert.equal(label(text, TOM), expected, text);
});

test("anthropic-only auth: the same utterances route to Claude models", () => {
  const table: [string, string][] = [
    ["what's the capital of france", "quick anthropic/claude-haiku-4-5@off"],
    ["click the blue submit button", "fast anthropic/claude-sonnet-5-5@low"],
    ["write a python function that parses iso dates", "standard anthropic/claude-sonnet-5-5@medium"],
    ["denk gründlich nach: wie sollte ich meine finanzen planen", "deep anthropic/claude-opus-5-5@medium"],
    ["ultrathink: prove that the square root of two is irrational", "max anthropic/claude-opus-5-5@high"],
  ];
  for (const [text, expected] of table) assert.equal(label(text, ANTHROPIC), expected, text);
});

test("instant lane only through the injected gate, never for follow-ups", () => {
  const instantOk = () => true;
  assert.equal(decide(input("what's 18% of 240"), TOM, S, { instantOk }).lane, "instant");
  assert.equal(decide(input("what's 18% of 240", { followup: true }), TOM, S, { instantOk }).lane, "agent");
  assert.equal(decide(input("what's the capital of france"), TOM, S, { instantOk }).lane, "agent");
});

test("act_in_app attaches the screenshot and needs an image-capable model; plain questions do not", () => {
  const click = pick("click the blue submit button", TOM);
  assert.equal(click.attachScreenshot, true);
  assert.ok(click.reasons.includes("screenshot"));
  assert.equal(pick("click the blue submit button", TOM, S, { hasScreenshot: false }).attachScreenshot, false);
  assert.equal(pick("what's the capital of france", TOM).attachScreenshot, false);
  assert.equal(pick("what is this error", TOM).attachScreenshot, true);
  // CDP browser: DOM snapshots instead of pixels.
  assert.equal(pick("go to the pricing page", TOM, S, { surface: "browser", browserCdp: true }).attachScreenshot, false);
  assert.equal(pick("go to the pricing page", TOM, S, { surface: "browser", browserCdp: false }).attachScreenshot, true);
});

test("Codex facts: gpt-6.1-sol/gpt-6-astra have no off, minimal collapses into low, spark is never auto-selected", () => {
  const byId = (id: string) => codexModels.find(m => m.id === id)!;
  assert.deepEqual(distinctThinkingLevels(byId("gpt-6.1-sol")), ["low", "medium", "high", "xhigh", "max"]);
  assert.deepEqual(distinctThinkingLevels(byId("gpt-6-astra")), ["low", "medium", "high", "xhigh", "max"]);
  assert.deepEqual(distinctThinkingLevels(byId("gpt-6-luna")), ["off", "low", "medium", "high", "xhigh", "max"]);
  for (const p of TOM.profiles.filter(p => p.provider === "openai-codex")) {
    assert.notEqual(p.thinkingLevel, "minimal", `${targetKey(p)} minimal is just low on Codex`);
    if (["gpt-6.1-sol", "gpt-6-astra"].includes(p.id)) assert.notEqual(p.thinkingLevel, "off", targetKey(p));
    assert.notEqual(p.id, "gpt-5.3-codex-spark");
    assert.ok(!["xhigh", "max"].includes(p.thinkingLevel), "xhigh/max only through overrides");
  }
});

const INTENTS = Object.keys(BASE_TIERS) as AgentIntent[];
function classification(intent: AgentIntent, complexity: 0 | 1 | 2, flags: Partial<Classification> = {}): Classification {
  return { source: "heuristic", intent, intentConfidence: 0.8, complexity, needsScreen: 0.1, explicitDeep: false,
    explicitMax: false, explicitFast: false, correction: 0, ...flags };
}
function* everyCase(): Generator<[RouteInput, RoutingSettings]> {
  const flagSets: Partial<Classification>[] = [{}, { explicitFast: true }, { explicitDeep: true }, { explicitDeep: true, explicitMax: true },
    { intentConfidence: 0.3 }, { needsScreen: 0.9 }, { correction: 0.9 }];
  for (const intent of INTENTS) for (const complexity of [0, 1, 2] as const) for (const flags of flagSets)
    for (const bias of ["speed", "balanced", "quality"] as const) for (const followup of [false, true]) {
      yield [{ classification: classification(intent, complexity, flags), followup, surface: "other", hasScreenshot: true,
        selectionChars: 0, browserCdp: false, estimatedPromptTokens: 8_000, ...(followup ? { lastTier: "fast" as const } : {}) },
      settings({ bias })];
    }
}

test("auth filtering: Codex-only availability never yields another provider, an unsupported level or a local model", () => {
  let count = 0;
  for (const [routeInput, s] of everyCase()) {
    const d = decide(routeInput, TOM, s);
    for (const target of [d.model, ...d.ladder, ...d.alternates]) {
      assert.ok(target, "Tom's catalog covers every case");
      assert.equal(target.provider, "openai-codex", JSON.stringify(routeInput.classification));
      assert.ok(TOM.candidates.get(`${target.provider}/${target.id}`)!.levels.includes(target.thinkingLevel));
      if (["gpt-6.1-sol", "gpt-6-astra"].includes(target.id)) assert.notEqual(target.thinkingLevel, "off");
      assert.notEqual(target.thinkingLevel, "minimal");
    }
    count++;
  }
  assert.ok(count > 1_000);
  for (const [routeInput, s] of everyCase()) {
    for (const target of [decide(routeInput, ANTHROPIC, s).model]) assert.equal(target?.provider, "anthropic");
  }
});

test("tier ordering: low confidence is never quick, explicit fast/speed lower one tier, quality raises", () => {
  for (const intent of INTENTS) {
    const d = decide({ ...input("x"), classification: classification(intent, 0, { intentConfidence: 0.3 }) }, TOM, S);
    assert.notEqual(d.tier, "quick", intent);
  }
  assert.equal(pick("click the blue submit button", TOM, settings({ bias: "speed" })).tier, "quick");
  assert.equal(pick("what's the capital of france", TOM, settings({ bias: "quality" })).tier, "fast");
  assert.equal(pick("quick: click the submit button", TOM).tier, "quick");
  assert.equal(pick("think hard and quickly: click submit", TOM, settings({ bias: "speed" })).tier, "deep", "depth beats speed");
});

test("maxAutoTier caps automatic tiers; explicit depth words exceed it", () => {
  const capped = settings({ maxAutoTier: "standard" });
  const code = pick("compare these two regex implementations and debug the failing one", TOM);
  assert.equal(code.tier, "deep");
  const codeCapped = pick("compare these two regex implementations and debug the failing one", TOM, capped);
  assert.equal(codeCapped.tier, "standard");
  assert.ok(codeCapped.reasons.includes("cap=standard"));
  assert.equal(pick("ultrathink: prove it", TOM, capped).model?.id, "gpt-6-astra");
  assert.equal(pick("denk gründlich nach", TOM, settings({ maxAutoTier: "quick" })).tier, "deep");
  assert.equal(pick("what's 2+2", TOM, settings({ maxAutoTier: "quick" })).ladder.length, 0, "no rungs above the cap");
});

test("follow-ups never downgrade mid-thread; a correction goes one tier above the last", () => {
  assert.equal(pick("thanks, and what about spain", TOM, S, { followup: true, lastTier: "standard" }).tier, "standard");
  assert.equal(pick("no, that's wrong", TOM, S, { followup: true, lastTier: "standard" }).tier, "deep");
  assert.equal(pick("nein, das stimmt nicht", TOM, S, { followup: true, lastTier: "fast" }).tier, "standard");
  assert.equal(pick("no, that's wrong", TOM, S, { followup: false }).tier, "fast", "correction only counts for follow-ups");
});

test("ladder rises above the decided tier up to the cap; alternates stay in the tier", () => {
  const d = pick("what's the capital of france", TOM);
  assert.deepEqual(d.ladder.map(targetKey), [
    "openai-codex/gpt-6-sol@off", "openai-codex/gpt-6.1-sol@low", "openai-codex/gpt-6.1-sol@medium",
  ]);
  assert.ok(d.ladder.every(r => r.tier !== "quick"));
  assert.equal(d.alternates[0] && targetKey(d.alternates[0]), "openai-codex/gpt-5.6-luna@off");
  assert.ok(d.alternates.every(a => a.tier === "quick"));
});

test("quality bias picks the higher-intelligence model within a tier", () => {
  assert.equal(label("denk gründlich nach", TOM), "deep openai-codex/gpt-6.1-sol@medium");
  assert.equal(label("denk gründlich nach", TOM, settings({ bias: "quality" })), "deep openai-codex/gpt-6-astra@medium");
});

test("tier overrides are honored only for available, capable models", () => {
  const astra = settings({ tierOverrides: { deep: { provider: "openai-codex", id: "gpt-6-astra", thinkingLevel: "xhigh" } } });
  assert.equal(label("denk gründlich nach", TOM, astra), "deep openai-codex/gpt-6-astra@xhigh");
  const unavailable = settings({ tierOverrides: { deep: { provider: "anthropic", id: "claude-opus-5-5", thinkingLevel: "medium" } } });
  assert.equal(label("denk gründlich nach", TOM, unavailable), "deep openai-codex/gpt-6.1-sol@medium");
  const unsupported = settings({ tierOverrides: { deep: { provider: "openai-codex", id: "gpt-6.1-sol", thinkingLevel: "off" } } });
  assert.equal(label("denk gründlich nach", TOM, unsupported), "deep openai-codex/gpt-6.1-sol@medium");
  // Text-only Spark pinned for quick: used for text, skipped when the screenshot must go along.
  const spark = settings({ tierOverrides: { quick: { provider: "openai-codex", id: "gpt-5.3-codex-spark", thinkingLevel: "off" } } });
  assert.equal(label("what's the capital of france", TOM, spark), "quick openai-codex/gpt-5.3-codex-spark@off");
  assert.equal(label("translate this to german", TOM, spark), "quick openai-codex/gpt-6-luna@off");
});

test("loopback models are excluded unless allowLocalModels", () => {
  const splash = { provider: "splash", id: "incoai/Qwen3.8-27B-Splash", thinkingLevel: "off" as const };
  assert.equal(isLocalModel(localModels[0]!), true);
  assert.equal(isLocalModel(codexModels[0]!), false);
  const pinned = settings({ tierOverrides: { quick: splash } });
  assert.equal(pick("what's the capital of france", TOM, pinned).model?.provider, "openai-codex");
  assert.equal(pick("what's the capital of france", TOM, { ...pinned, allowLocalModels: true }).model?.provider, "splash");
  const localOnly = buildRoutingCatalog(localModels);
  assert.equal(pick("what's the capital of france", localOnly).model, undefined);
  assert.ok(pick("what's the capital of france", localOnly, settings({ allowLocalModels: true })).model);
});

test("no available model → no model (callers fall back); no image model → run text-only", () => {
  const empty = decide(input("what's the capital of france"), buildRoutingCatalog([]), S);
  assert.equal(empty.model, undefined);
  assert.ok(empty.reasons.includes("no-usable-model"));
  const textOnly = buildRoutingCatalog([fixtureModel("acme", "acme-text-1", { baseUrl: "https://api.acme.invalid/v1", input: ["text"] })]);
  const d = pick("click the blue submit button", textOnly);
  assert.equal(d.model?.id, "acme-text-1");
  assert.equal(d.attachScreenshot, false);
  assert.ok(d.reasons.includes("no-vision-model"));
});

test("context window filter skips models too small for the prompt", () => {
  const small = fixtureModel("acme", "acme-mini", { baseUrl: "https://api.acme.invalid/v1", contextWindow: 8_000 });
  const big = fixtureModel("acme", "acme-pro", { baseUrl: "https://api.acme.invalid/v1", contextWindow: 400_000, cost: { input: 3, output: 30, cacheRead: 0, cacheWrite: 0 } });
  const catalog = buildRoutingCatalog([small, big]);
  assert.equal(pick("what's the capital of france", catalog, S, { estimatedPromptTokens: 2_000 }).model?.id, "acme-mini");
  assert.equal(pick("what's the capital of france", catalog, S, { estimatedPromptTokens: 20_000 }).model?.id, "acme-pro");
});

class FixtureStats implements LatencyView {
  constructor(private readonly entries: Record<string, StatEntry>, private readonly blockedIds: string[] = []) {}
  get(key: string) { return this.entries[key]; }
  blocked(provider: string, id: string) { return this.blockedIds.includes(`${provider}/${id}`); }
}

test("local measurements re-rank within a tier once trusted (n >= 3); health blocks skip a model", () => {
  const slowLuna = { n: 5, ttftMs: 4_000, tpsN: 5, tps: 130 };
  assert.equal(decide(input("what's the capital of france"), TOM, S, { stats: new FixtureStats({ "openai-codex/gpt-6-luna@off": slowLuna }) }).model?.id, "gpt-5.6-luna");
  assert.equal(decide(input("what's the capital of france"), TOM, S, { stats: new FixtureStats({ "openai-codex/gpt-6-luna@off": { ...slowLuna, n: 2, tpsN: 2 } }) }).model?.id, "gpt-6-luna");
  const blocked = new FixtureStats({}, ["openai-codex/gpt-6-luna"]);
  assert.equal(decide(input("what's the capital of france"), TOM, S, { stats: blocked }).model?.id, "gpt-5.6-luna");
});

test("health blocks demote but never refuse: a provider-wide block on the only provider still routes", () => {
  const quota = new FixtureStats({}, codexModels.map(m => `${m.provider}/${m.id}`));
  const d = decide(input("what's the capital of france"), TOM, S, { stats: quota });
  assert.equal(d.model && targetKey(d.model), "openai-codex/gpt-6-luna@off");
  assert.ok(d.reasons.includes("health-blocked"));
  assert.ok(d.ladder.length > 0, "the ladder is kept for the router's own health checks");
  // A healthy model still wins over a blocked better-ranked one, and vision is kept when possible.
  const partial = new FixtureStats({}, ["openai-codex/gpt-6-sol"]);
  const click = decide(input("click the blue submit button"), TOM, S, { stats: partial });
  assert.notEqual(click.model?.id, "gpt-6-sol");
  assert.equal(click.attachScreenshot, true);
  assert.ok(!click.reasons.includes("health-blocked"));
});

test("generic family heuristics let other providers' auth work (google-only, unknown provider)", () => {
  const byId = (id: string) => googleModels.find(m => m.id === id)!;
  assert.equal(sizeClass(byId("gemini-2.5-pro")), "large");
  assert.equal(sizeClass(byId("gemini-3.1-flash-lite")), "small");
  assert.equal(sizeClass(byId("gemini-3.8-flash")), "medium");
  for (const text of ["what's the capital of france", "click the blue submit button", "write a python function", "denk gründlich nach", "ultrathink: why"]) {
    const d = pick(text, GOOGLE);
    assert.equal(d.model?.provider, "google", text);
    assert.ok(!["xhigh", "max"].includes(d.model!.thinkingLevel), text);
    assert.ok(!/image|live|deep-research|computer-use|customtools/.test(d.model!.id), `${text}: ${d.model!.id}`);
  }
  assert.ok(tierOf(pick("what's the capital of france", GOOGLE)) <= tierOf(pick("ultrathink: why", GOOGLE)));
  const custom = buildRoutingCatalog([
    fixtureModel("acme", "acme-small-2", { baseUrl: "https://api.acme.invalid/v1", reasoning: false, cost: { input: 0.1, output: 0.4, cacheRead: 0, cacheWrite: 0 } }),
    fixtureModel("acme", "acme-large-2", { baseUrl: "https://api.acme.invalid/v1", cost: { input: 5, output: 40, cacheRead: 0, cacheWrite: 0 } }),
  ]);
  assert.equal(pick("what's the capital of france", custom).model?.id, "acme-small-2");
  assert.equal(pick("denk gründlich nach", custom).model?.id, "acme-large-2");
  assert.ok(custom.profiles.every(p => p.source === "generic"));
});
const tierOf = (d: ReturnType<typeof decide>) => ["instant", "quick", "fast", "standard", "deep", "max"].indexOf(d.tier);

test("priors only apply at levels the installed catalog supports; the cheapest quick target serves direct requests", () => {
  for (const p of PRIOR_PROFILES) {
    const model = [...codexModels, ...anthropicModels].find(m => m.provider === p.provider && m.id === p.id);
    if (model) assert.ok(TOM.candidates.get(`${p.provider}/${p.id}`)?.levels.includes(p.thinkingLevel) ?? ANTHROPIC.candidates.get(`${p.provider}/${p.id}`)?.levels.includes(p.thinkingLevel), targetKey(p));
  }
  assert.equal(quickestTarget(TOM, S) && targetKey(quickestTarget(TOM, S)!), "openai-codex/gpt-6-luna@off");
  assert.equal(quickestTarget(TOM, S, 1_000_000), undefined, "nothing fits a 1M-token conversation");
});

test("decide is fast (< 1 ms per call) and carries no request text in its reasons", () => {
  const text = "please summarize the secret fixture phrase copper robin";
  const start = performance.now();
  let d = pick(text, TOM);
  for (let i = 0; i < 500; i++) d = pick(text, TOM);
  assert.ok((performance.now() - start) / 501 < 1);
  assert.doesNotMatch(JSON.stringify(d), /copper|robin|secret/);
});
