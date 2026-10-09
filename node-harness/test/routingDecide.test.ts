import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { Api, Model } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  BAD_NEWS_FACTOR, BASE_TIERS, buildRouteInput, buildRoutingCatalog, classifyUtterance, decide, DEFAULT_ROUTING_SETTINGS,
  classificationFromHints, distinctThinkingLevels, expectedSeconds, expectedTtft, INTENT_TOOL_HINTS, isLocalModel, PRIOR_PROFILES,
  quickestTarget, routeContextFromSnapshot, sizeClass, targetKey, TRUSTED_SAMPLES, utteranceWords, VOICE_OPTION_TOOLS,
  type AgentIntent, type Classification, type LatencyView, type RouteInput, type RoutingCatalog, type RoutingSettings,
  type StatEntry,
} from "../src/agent/routing/index.js";
import type { DesktopContextSnapshot } from "../src/hostClient.js";

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
    // Ordinary answers, writing and simple UI work stay on Luna (r2/latency.md §5.1).
    ["why is the sky blue", "quick openai-codex/gpt-6-luna@off"],
    ["explain the difference between TCP and UDP", "quick openai-codex/gpt-6-luna@off"],
    ["write an email to my boss asking for friday off", "quick openai-codex/gpt-6-luna@off"],
    ["click the blue submit button", "quick openai-codex/gpt-6-luna@off"],
    ["klick auf den blauen button", "quick openai-codex/gpt-6-luna@off"],
    ["make the first line bold", "quick openai-codex/gpt-6-luna@off"],
    ["hmm", "quick openai-codex/gpt-6-luna@off"],
    // Multi-step UI work: the fast tier is gpt-6.1-sol@low, never gpt-6-sol@off.
    ["click the settings tab and then turn on dark mode", "fast openai-codex/gpt-6.1-sol@low"],
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
    ["click the blue submit button", "quick anthropic/claude-haiku-4-5@off"],
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

test("tier ordering: low confidence is no floor (only logged), explicit fast/speed lower one tier, quality raises", () => {
  for (const intent of INTENTS) {
    const d = decide({ ...input("x"), classification: classification(intent, 0, { intentConfidence: 0.3 }) }, TOM, S);
    assert.equal(d.tier, BASE_TIERS[intent][0], intent);
    assert.ok(d.reasons.includes("low-confidence"), intent);
  }
  assert.equal(pick("hmm", TOM).tier, "quick", "an unmatched utterance is not sent to a slower tier");
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
  assert.equal(pick("no, that's wrong", TOM, S, { followup: false }).tier, "quick", "correction only counts for follow-ups");
});

test("ladder rises above the decided tier up to the cap; alternates stay in the tier", () => {
  const d = pick("what's the capital of france", TOM);
  // fast and standard are the same target: the duplicate rung is skipped.
  assert.deepEqual(d.ladder.map(targetKey), ["openai-codex/gpt-6.1-sol@low", "openai-codex/gpt-6.1-sol@medium"]);
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

test("local measurements re-rank within a tier once trusted (n >= 3, or at once when ≥ 2× the prior); health blocks skip a model", () => {
  const capital = (entries: Record<string, StatEntry>) => decide(input("what's the capital of france"), TOM, S, { stats: new FixtureStats(entries) }).model?.id;
  const luna = "openai-codex/gpt-6-luna@off";
  assert.equal(capital({ [luna]: { n: 5, ttftMs: 4_000, tpsN: 5, tps: 60 } }), "gpt-5.6-luna");
  // Bad news is believed from the first sample (4.0 s ≥ 2 × 1.7 s); milder news waits for n = 3.
  assert.equal(capital({ [luna]: { n: 1, ttftMs: 4_000, tpsN: 0, tps: 0 } }), "gpt-5.6-luna");
  assert.equal(capital({ [luna]: { n: 2, ttftMs: 3_000, tpsN: 0, tps: 0 } }), "gpt-6-luna");
  assert.equal(capital({ [luna]: { n: 3, ttftMs: 3_000, tpsN: 0, tps: 0 } }), "gpt-5.6-luna");
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
  const partial = new FixtureStats({}, ["openai-codex/gpt-6-luna"]);
  const click = decide(input("click the blue submit button"), TOM, S, { stats: partial });
  assert.equal(click.model?.id, "gpt-5.6-luna");
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

// --- pass 2: tier table, fast tier, trust rule, latency guard, scope and image attachments ---------------------

test("tier table (DESIGN2 §5.4): answers, writing, other and simple UI work are quick; complexity 1 UI work is fast", () => {
  assert.deepEqual(BASE_TIERS, {
    calculate: ["quick", "quick", "fast"],
    search_computer: ["quick", "quick", "fast"],
    open_launch: ["quick", "quick", "fast"],
    answer: ["quick", "quick", "standard"],
    write: ["quick", "quick", "standard"],
    act_in_app: ["quick", "fast", "standard"],
    browse_web: ["quick", "fast", "standard"],
    code: ["standard", "standard", "deep"],
    other: ["quick", "quick", "fast"],
  });
});

test("the Codex fast tier is gpt-6.1-sol@low for every bias; gpt-6-sol@off is out of Auto unless a tier override pins it", () => {
  // Each bias reaches the fast tier from a different starting point: act cx1, code cx0 lowered, answer cx0 raised.
  const onFast: [RoutingSettings["bias"], Classification][] = [
    ["balanced", classification("act_in_app", 1)], ["speed", classification("code", 0)], ["quality", classification("answer", 0)]];
  for (const [bias, c] of onFast) {
    const d = decide({ ...input("x"), classification: c }, TOM, settings({ bias }));
    assert.equal(`${d.tier} ${d.model && targetKey(d.model)}`, "fast openai-codex/gpt-6.1-sol@low", bias);
  }
  assert.ok(TOM.profiles.some(p => targetKey(p) === "openai-codex/gpt-6-sol@off" && p.pinOnly), "the measured prior stays for overrides");
  for (const [routeInput, s] of everyCase()) {
    const d = decide(routeInput, TOM, s);
    for (const target of [d.model, ...d.ladder, ...d.alternates]) {
      assert.notEqual(target && targetKey(target), "openai-codex/gpt-6-sol@off", JSON.stringify(routeInput.classification));
    }
  }
  const pinned = settings({ tierOverrides: { fast: { provider: "openai-codex", id: "gpt-6-sol", thinkingLevel: "off" } } });
  assert.equal(label("plan my week", TOM, pinned), "fast openai-codex/gpt-6-sol@off", "a hard signal (complexity 2 on other) reaches the pinned model");
  // The public OpenAI API keeps its Artificial Analysis priors.
  assert.ok(PRIOR_PROFILES.some(p => targetKey(p) === "openai/gpt-6-sol@off" && p.tier === "fast" && !p.pinOnly));
});

test("Codex priors are the 2026-10-05 measurements (r2/latency.md): Luna 1.7 s / 60 tok/s, Sol@off 5.0 s / 40, 6.1-Sol@low 2.6 s", () => {
  const prior = (key: string, tier: string) => PRIOR_PROFILES.find(p => targetKey(p) === key && p.tier === tier)!;
  assert.deepEqual([prior("openai-codex/gpt-6-luna@off", "quick").ttftS, prior("openai-codex/gpt-6-luna@off", "quick").tps], [1.7, 60]);
  assert.deepEqual([prior("openai-codex/gpt-6-sol@off", "fast").ttftS, prior("openai-codex/gpt-6-sol@off", "fast").tps], [5.0, 40]);
  assert.equal(prior("openai-codex/gpt-6.1-sol@low", "fast").ttftS, 2.6);
  assert.equal(prior("openai-codex/gpt-6.1-sol@low", "standard").ttftS, 2.6);
  // Unmeasured Codex models in the same tiers never outrank the measured ones on a public-API median.
  assert.ok(prior("openai-codex/gpt-5.6-luna@off", "quick").ttftS >= 1.7);
  assert.ok(prior("openai-codex/gpt-5.6-terra@low", "fast").ttftS >= 2.6);
});

test("trust rule: a measurement counts from n = 1 when ≥ 2× the prior, otherwise from n = 3", () => {
  const p = { ttftS: 2, tps: 60 };
  assert.equal(expectedTtft(p), 2);
  assert.equal(expectedTtft(p, { n: 1, ttftMs: 4_000, tpsN: 0, tps: 0 }), 4, "bad news at once");
  assert.equal(expectedTtft(p, { n: 1, ttftMs: 3_900, tpsN: 0, tps: 0 }), 2);
  assert.equal(expectedTtft(p, { n: 2, ttftMs: 500, tpsN: 0, tps: 0 }), 2, "good news waits");
  assert.equal(expectedTtft(p, { n: TRUSTED_SAMPLES, ttftMs: 500, tpsN: 0, tps: 0 }), 0.5);
  assert.equal(BAD_NEWS_FACTOR, 2);
  const profile = TOM.profiles.find(q => targetKey(q) === "openai-codex/gpt-6-luna@off")!;
  const stats = (entry: StatEntry) => new FixtureStats({ "openai-codex/gpt-6-luna@off": entry });
  assert.equal(expectedSeconds(profile, 60), 1.7 + 1);
  assert.equal(expectedSeconds(profile, 60, stats({ n: 0, ttftMs: 0, tpsN: 1, tps: 30 })), 1.7 + 2, "half the prior throughput counts at once");
  assert.equal(expectedSeconds(profile, 60, stats({ n: 0, ttftMs: 0, tpsN: 1, tps: 120 })), 1.7 + 1);
});

test("latency guard: a tier raised only by complexity 1 falls back when its model is > 2× and > 1 s (or > 2 s) slower", () => {
  const multiStep = "click the settings tab and then turn on dark mode";
  // Both fast-tier candidates measured slow once (≥ 2× their priors: believed at once).
  const slowSol = new FixtureStats({
    "openai-codex/gpt-6.1-sol@low": { n: 1, ttftMs: 6_000, tpsN: 0, tps: 0 },
    "openai-codex/gpt-5.6-terra@low": { n: 1, ttftMs: 6_000, tpsN: 0, tps: 0 },
  });
  const demoted = decide(input(multiStep), TOM, S, { stats: slowSol });
  assert.equal(demoted.tier, "quick");
  assert.equal(demoted.model && targetKey(demoted.model), "openai-codex/gpt-6-luna@off");
  assert.ok(demoted.reasons.includes("latency-demote"));
  assert.deepEqual(demoted.ladder.map(targetKey).slice(0, 1), ["openai-codex/gpt-6.1-sol@low"], "escalation still reaches the fast tier");
  // Measured priors alone keep 6.1-Sol@low (2.6 s vs 1.7 s); a pinned Sol@off (5.0 s) is demoted.
  assert.equal(label(multiStep, TOM), "fast openai-codex/gpt-6.1-sol@low");
  const pinned = settings({ tierOverrides: { fast: { provider: "openai-codex", id: "gpt-6-sol", thinkingLevel: "off" } } });
  assert.equal(label(multiStep, TOM, pinned), "quick openai-codex/gpt-6-luna@off");
  // Never for hard signals, explicit words, a follow-up's tier or the quality bias.
  assert.equal(decide(input("fix the failing unit tests"), TOM, S, { stats: slowSol }).tier, "standard");
  assert.equal(decide(input(`think hard: ${multiStep}`), TOM, S, { stats: slowSol }).tier, "deep");
  assert.equal(decide(input(multiStep, { followup: true, lastTier: "fast" }), TOM, S, { stats: slowSol }).tier, "fast");
  assert.ok(!decide(input(multiStep), TOM, settings({ bias: "quality" }), { stats: slowSol }).reasons.includes("latency-demote"));
  // Anthropic priors: Sonnet@low 1.31 s is > 2× Haiku's 0.58 s but only 0.73 s slower: no demotion.
  const anthropic = decide(input(multiStep), ANTHROPIC, S);
  assert.notEqual(anthropic.model && targetKey(anthropic.model), "anthropic/claude-haiku-4-5@off");
  assert.ok(!anthropic.reasons.includes("latency-demote"));
});

const SNAPSHOT = {
  id: "ctx", capturedAt: "2026-10-05T00:00:00Z", cursor: { x: 0, y: 0 }, monitors: [], foregroundWindow: null, windowUnderCursor: null,
  targetWindow: { hwnd: "1", processId: 1, processName: "Brave Browser", title: "Fixture", bounds: { x: 0, y: 0, width: 1, height: 1 } },
  browser: { name: "Brave", mode: "ax", pinned: true },
  screenshot: { kind: "file", filePath: "/tmp/fixture.png" },
} as unknown as DesktopContextSnapshot;
const SPARK_QUICK = settings({ tierOverrides: { quick: { provider: "openai-codex", id: "gpt-5.3-codex-spark", thinkingLevel: "off" } } });

test("scope: general never attaches a screenshot or needs vision; window attaches it and needs a vision model", () => {
  const general = routeContextFromSnapshot(SNAPSHOT, "general");
  assert.deepEqual(general, { surface: "browser", hasScreenshot: false, browserCdp: false, scope: "general" });
  const deictic = buildRouteInput("what does this error mean", general);
  assert.equal(deictic.scope, "general");
  assert.ok(deictic.estimatedPromptTokens < 6_000 + 1_500, "no image tokens are estimated");
  for (const extra of [{}, { hasScreenshot: true }]) {
    const d = decide({ ...deictic, ...extra }, TOM, SPARK_QUICK);
    assert.equal(d.attachScreenshot, false);
    assert.equal(d.scope, "general");
    assert.ok(d.reasons.includes("scope=general"));
    assert.equal(d.model && targetKey(d.model), "openai-codex/gpt-5.3-codex-spark@off", "a text-only model is fine for a general turn");
    assert.equal(d.vision, false);
  }
  const window = buildRouteInput("what's the capital of france", routeContextFromSnapshot(SNAPSHOT, "window"));
  const attached = decide(window, TOM, SPARK_QUICK);
  assert.equal(attached.attachScreenshot, true, "window scope attaches whatever the words say");
  assert.equal(attached.model && targetKey(attached.model), "openai-codex/gpt-6-luna@off");
  assert.equal(attached.vision, true);
  // Window scope without a screenshot (no Screen Recording): text-only turn, still on a vision model.
  const noCapture = decide({ ...window, hasScreenshot: false }, TOM, SPARK_QUICK);
  assert.equal(noCapture.attachScreenshot, false);
  assert.equal(noCapture.model?.id, "gpt-6-luna");
});

test("scope: the agent pulling the window in routes the general thread as window; legacy requests have no scope", () => {
  const general = routeContextFromSnapshot(SNAPSHOT, "general");
  assert.equal(buildRouteInput("and now in german", general, { followup: true, pulled: true }).scope, "window");
  assert.equal(buildRouteInput("and now in german", general, { followup: true, pulled: false }).scope, "general");
  const legacy = buildRouteInput("and now in german", routeContextFromSnapshot(SNAPSHOT), { pulled: true });
  assert.equal(legacy.scope, undefined);
  assert.equal(decide(legacy, TOM, S).scope, undefined);
  const pulled = decide(buildRouteInput("and now in german", { ...general, hasScreenshot: false }, { followup: true, pulled: true }), TOM, SPARK_QUICK);
  assert.equal(pulled.model?.id, "gpt-6-luna", "the thread holds window images: a vision model");
});

test("legacy requests (no scope): the screenshot formula is exactly today's", () => {
  const texts = ["what's the capital of france", "what is this error", "click the blue submit button", "summarize the page", "make it shorter",
    "go to the pricing page", "translate this to german", "write an email to my boss", "fass das zusammen", "hmm", "gib mir ein rezept",
    "gib deine adresse ein", "make the first line bold"];
  for (const surface of ["other", "browser"] as const) for (const browserCdp of [false, true]) for (const text of texts) {
    const routeInput = input(text, { surface, browserCdp });
    const c = classifyUtterance(text, { surface, browserCdp });
    const formula = c.needsScreen >= 0.5 || c.intent === "act_in_app" || (c.intent === "browse_web" && !browserCdp);
    assert.equal(decide(routeInput, TOM, S).attachScreenshot, formula, `${text} ${surface} cdp=${browserCdp}`);
    assert.equal(decide({ ...routeInput, hasScreenshot: false }, TOM, S).attachScreenshot, false);
  }
});

test("image attachments force a vision-capable model and never attach the screenshot by themselves", () => {
  const general = routeContextFromSnapshot(SNAPSHOT, "general");
  const routeInput = buildRouteInput("what's in this picture", general, { hasImageAttachment: true });
  assert.equal(routeInput.hasImageAttachment, true);
  assert.ok(routeInput.estimatedPromptTokens >= 6_000 + 1_500, "the image is estimated");
  const d = decide(routeInput, TOM, SPARK_QUICK);
  assert.equal(d.model?.id, "gpt-6-luna", "the text-only override is skipped");
  assert.equal(d.vision, true);
  assert.equal(d.attachScreenshot, false);
  assert.ok(d.reasons.includes("image-attachment"));
  // No image-capable model at all: run text-only, and say so (callers then drop the image).
  const textOnly = buildRoutingCatalog([fixtureModel("acme", "acme-text-1", { baseUrl: "https://api.acme.invalid/v1", input: ["text"] })]);
  const blind = decide(routeInput, textOnly, S);
  assert.equal(blind.model?.id, "acme-text-1");
  assert.equal(blind.vision, false);
  assert.ok(blind.reasons.includes("no-vision-model"));
  // The legacy path too: an attachment needs vision even when no screenshot is wanted.
  assert.equal(decide({ ...input("what's the capital of france"), hasImageAttachment: true }, TOM, SPARK_QUICK).model?.id, "gpt-6-luna");
});

// --- voice fallback (DESIGN4 §5.5) ---------------------------------------------------------------------------------

/** decide() for a request that was spoken (POST /invoke input.mode "voice"), as planTurn calls it. */
const spoken = (text: string, s = S, extra: Partial<RouteInput> = {}) => decide(input(text, extra), TOM, s, { spoken: { words: utteranceWords(text) } });

test("voice: a short spoken request no rule places runs on the quick lane with the option tools, whatever the bias or complexity", () => {
  assert.deepEqual([...VOICE_OPTION_TOOLS], ["list_apps", "open_item", "show_result"]);
  // Complexity 0 ("page is"), 1 (a connective) and 2 (a HARD word in the garble).
  for (const text of ["page is", "Oh, then kind order.", "plan the kind order", "Ja dann mal das Dings"]) {
    for (const bias of ["speed", "balanced", "quality"] as const) {
      const d = spoken(text, settings({ bias }));
      assert.equal(d.lane, "agent");
      assert.equal(d.tier, "quick", `${text} ${bias}`);
      assert.equal(d.model?.tier, "quick");
      if (bias === "balanced") assert.equal(targetKey(d.model!), "openai-codex/gpt-6-luna@off");
      assert.deepEqual(d.toolsAdd, [...VOICE_OPTION_TOOLS], text);
      assert.ok(d.reasons.includes("voice-unclear"), text);
      assert.equal(d.attachScreenshot, false, "a garble is no reason to show the window");
    }
  }
  // Typed, the same words keep today's table: complexity 2 is fast, quality raises one tier, no tool hints.
  assert.equal(pick("plan the kind order", TOM).tier, "fast");
  assert.equal(pick("Oh, then kind order.", TOM, settings({ bias: "quality" })).tier, "fast");
  assert.deepEqual(pick("Oh, then kind order.", TOM).toolsAdd, []);
  assert.ok(!pick("Oh, then kind order.", TOM).reasons.includes("voice-unclear"));
});

test("voice: placed or long spoken requests route exactly as typed ones", () => {
  for (const text of [
    "open page is", "öffne Pages", "what is kind order?", "fass das zusammen", "click the blue submit button",
    "oh then kind order and the other thing too", "plan the kind order and the other thing for next week please",
  ]) {
    for (const bias of ["speed", "balanced", "quality"] as const) {
      const typed = pick(text, TOM, settings({ bias }));
      const voice = spoken(text, settings({ bias }));
      assert.deepEqual(voice, typed, `${text} ${bias}`);
    }
  }
  assert.deepEqual(spoken("open page is").toolsAdd, [...INTENT_TOOL_HINTS.open_launch!]);
  // The instant gate is the caller's: a spoken final that reached decide() with an instant-able rule label still may use it.
  assert.equal(decide(input("what's 18% of 240"), TOM, S, { instantOk: () => true, spoken: { words: 4 } }).lane, "instant");
});

test("voice: explicit depth words, advisory floors and the thread's tier still raise an unclear spoken request", () => {
  const deep = spoken("think hard about kind order");
  assert.equal(deep.tier, "deep", "the user's own depth words win");
  assert.ok(deep.reasons.includes("voice-unclear") && deep.reasons.includes("explicit-deep"));
  assert.deepEqual(deep.toolsAdd, [...VOICE_OPTION_TOOLS]);

  // A confident tier-only hint is a floor; the label stays unplaced.
  const hinted = classificationFromHints(input("kein note").classification, { source: "pi-classifier", latencyMs: 30, tier: "standard", tierP: 0.9 });
  const floored = decide({ ...input("kein note"), classification: hinted }, TOM, settings({ bias: "speed" }), { spoken: { words: 2 } });
  assert.equal(floored.tier, "standard");
  assert.ok(floored.reasons.includes("voice-unclear") && floored.reasons.includes("floor=standard"));
  // A hint that adopted a label places the request: today's routing, no option tools.
  const adopted = classificationFromHints(input("kein note").classification, { source: "laya", latencyMs: 30, intent: "answer", intentP: 0.9 });
  assert.ok(!decide({ ...input("kein note"), classification: adopted }, TOM, S, { spoken: { words: 2 } }).reasons.includes("voice-unclear"));

  // Follow-ups never downgrade mid-thread; a spoken correction still goes one tier above the last.
  assert.equal(spoken("kind order", S, { followup: true, lastTier: "standard" }).tier, "standard");
  assert.equal(spoken("nein, kind order", S, { followup: true, lastTier: "fast" }).tier, "standard");
  assert.equal(spoken("kind order", settings({ maxAutoTier: "quick" })).tier, "quick");
});

test("voice: the route carries content-free labels only", () => {
  const d = spoken("copper robin secret");
  assert.ok(d.reasons.includes("voice-unclear"));
  assert.doesNotMatch(JSON.stringify(d), /copper|robin|secret/);
});
