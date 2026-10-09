import {
  MODEL_TIERS, modelKey, sameTarget, targetKey, tierRank,
  type AgentIntent, type Classification, type LatencyView, type ModelTier, type Profile, type RouteDecision,
  type RouteInput, type RouteTarget, type RoutingCatalog, type RoutingSettings, type TierChoice,
} from "./types.js";

/**
 * Pure, deterministic model choice (routing.md §6.5). No SDK, no I/O, no
 * classifier calls: server.ts runs it before prompt() and the virtual model's
 * route() consumes the result.
 */

/** Base tier by intent for complexity 0/1/2. */
export const BASE_TIERS: Readonly<Record<AgentIntent, readonly [ModelTier, ModelTier, ModelTier]>> = {
  calculate: ["quick", "quick", "fast"],
  search_computer: ["quick", "quick", "fast"],
  open_launch: ["quick", "quick", "fast"],
  answer: ["quick", "fast", "standard"],
  write: ["quick", "fast", "standard"],
  act_in_app: ["fast", "standard", "standard"],
  browse_web: ["fast", "standard", "standard"],
  code: ["standard", "standard", "deep"],
  other: ["fast", "fast", "standard"],
};

/** Expected answer length per intent, for ranking by end-to-end time. */
const OUT_TOKENS: Partial<Record<AgentIntent, number>> = { answer: 150, write: 300, act_in_app: 80, browse_web: 80, code: 400 };

/** Tool-name hints for the agent lane (names from DESIGN.md B5); callers intersect with their allowlist. */
export const INTENT_TOOL_HINTS: Readonly<Partial<Record<AgentIntent, readonly string[]>>> = {
  calculate: ["instant_calc", "instant_convert_currency"],
  search_computer: ["find_files"],
  open_launch: ["list_apps", "open_item"],
};

/** Local measurements are trusted from this many samples on. */
export const TRUSTED_SAMPLES = 3;
const LOW_CONFIDENCE = 0.5;
const CORRECTION_THRESHOLD = 0.6;
const SCREEN_THRESHOLD = 0.5;
const MAX_ALTERNATES = 3;

const tierAt = (rank: number): ModelTier => MODEL_TIERS[Math.min(MODEL_TIERS.length - 1, Math.max(0, rank - 1))]!;

/**
 * Tier implied by the classification alone, before settings/bias/follow-up
 * modifiers: base(intent, complexity), uncertainty floor, advisory floor.
 */
export function intrinsicTier(c: Classification, selectionChars = 0): ModelTier {
  let base = BASE_TIERS[c.intent][c.complexity];
  if (c.intent === "write" && selectionChars > 2_000 && base === "quick") base = "fast";
  let rank = tierRank(base);
  if (c.intentConfidence < LOW_CONFIDENCE) rank = Math.max(rank, tierRank("fast"));
  if (c.tierFloor) rank = Math.max(rank, tierRank(c.tierFloor));
  return tierAt(rank);
}

export interface DecideOptions {
  stats?: LatencyView;
  /** Instant-lane gate (the instant engine can answer without a model). */
  instantOk?: (input: RouteInput) => boolean;
}

interface Need {
  vision: boolean;
  minContext: number;
  outTokens: number;
}

export function decide(input: RouteInput, catalog: RoutingCatalog, settings: RoutingSettings, options: DecideOptions = {}): RouteDecision {
  const c = input.classification;
  const reasons = [`intent=${c.intent}`, `conf=${c.intentConfidence.toFixed(2)}`, `cx=${c.complexity}`];
  if (c.advisory) reasons.push(`advisory=${c.advisory.source}${c.advisory.raised.length ? `:${c.advisory.raised.join("+")}` : ""}`);

  // Only a rule-derived label may select the instant lane (advisory hints never trigger actions).
  if (!input.followup && (c.intent === "calculate" || c.intent === "open_launch") && c.intentConfidence >= 0.6
      && !c.advisory?.raised.includes("intent") && options.instantOk?.(input)) {
    return { lane: "instant", tier: "instant", alternates: [], ladder: [], toolsAdd: [], attachScreenshot: false,
      bias: settings.bias, reasons: [...reasons, "instant"] };
  }

  let rank = tierRank(intrinsicTier(c, input.selectionChars));
  if (c.intentConfidence < LOW_CONFIDENCE) reasons.push("low-confidence");
  if (c.tierFloor) reasons.push(`floor=${c.tierFloor}`);
  if (!c.explicitDeep && (c.explicitFast || settings.bias === "speed")) {
    rank = Math.max(tierRank("quick"), rank - 1);
    reasons.push(c.explicitFast ? "explicit-fast" : "bias=speed");
  } else if (settings.bias === "quality") {
    rank = Math.max(rank, Math.min(tierRank("deep"), rank + 1));
    reasons.push("bias=quality");
  }
  if (input.followup) {
    if (input.lastTier) rank = Math.max(rank, tierRank(input.lastTier));
    if (c.correction >= CORRECTION_THRESHOLD) {
      rank = Math.max(rank, tierRank(input.lastTier ?? "quick")) + 1;
      reasons.push("correction");
    }
  }
  if (c.explicitDeep) { rank = Math.max(rank, tierRank("deep")); reasons.push("explicit-deep"); }
  if (c.explicitMax) { rank = tierRank("max"); reasons.push("explicit-max"); }
  const cap: ModelTier = c.explicitDeep || c.explicitMax ? "max" : settings.maxAutoTier;
  if (rank > tierRank(cap)) reasons.push(`cap=${cap}`);
  const tier = tierAt(Math.min(rank, tierRank(cap)));

  const wantsScreenshot = input.hasScreenshot && (c.needsScreen >= SCREEN_THRESHOLD
    || c.intent === "act_in_app" || (c.intent === "browse_web" && !input.browserCdp));
  const need: Need = {
    vision: wantsScreenshot,
    minContext: Math.ceil(Math.max(0, input.estimatedPromptTokens) * 1.25),
    outTokens: OUT_TOKENS[c.intent] ?? 150,
  };

  // Preference order: healthy + image-capable, healthy text-only (run without the screenshot rather
  // than not at all), then the same ignoring health blocks. A block only demotes: when every
  // candidate is blocked (e.g. a provider-wide quota block for a single-provider user), Auto still
  // routes and the provider reports its real error instead of a false "no model with credentials".
  const measured = options.stats;
  const unblocked: LatencyView | undefined = measured && { get: key => measured.get(key), blocked: () => false };
  let stats = measured;
  let model: RouteTarget | undefined;
  for (const view of unblocked ? [measured, unblocked] : [measured]) {
    for (const vision of wantsScreenshot ? [true, false] : [false]) {
      model = pickNearest(tier, cap, { ...need, vision }, catalog, settings, view, reasons);
      if (!model) continue;
      need.vision = vision;
      stats = view;
      if (wantsScreenshot && !vision) reasons.push("no-vision-model");
      if (view === unblocked) reasons.push("health-blocked");
      break;
    }
    if (model) break;
  }
  if (!model) reasons.push("no-usable-model");
  const attachScreenshot = !!model && need.vision;

  const ladder: RouteTarget[] = [];
  for (let r = tierRank(tier) + 1; r <= tierRank(cap); r++) {
    const rung = pickTier(tierAt(r), need, catalog, settings, stats);
    if (rung && !sameTarget(rung, model) && !ladder.some(l => sameTarget(l, rung))) ladder.push(rung);
  }
  const alternates = model
    ? rankTier(model.tier, need, catalog, settings, stats).filter(t => !sameTarget(t, model)).slice(0, MAX_ALTERNATES)
    : [];

  if (attachScreenshot) reasons.push("screenshot");
  reasons.push(`tier=${tier}`);
  if (model) reasons.push(`model=${targetKey(model)}`);
  return {
    lane: "agent", tier, model, alternates, ladder,
    toolsAdd: [...(INTENT_TOOL_HINTS[c.intent] ?? [])],
    attachScreenshot, bias: settings.bias, reasons,
  };
}

/** The decided tier, else walk up to the cap, then down to quick, then above the cap as a last resort. */
function pickNearest(tier: ModelTier, cap: ModelTier, need: Need, catalog: RoutingCatalog, settings: RoutingSettings,
  stats: LatencyView | undefined, reasons: string[]): RouteTarget | undefined {
  const order: number[] = [tierRank(tier)];
  for (let r = tierRank(tier) + 1; r <= tierRank(cap); r++) order.push(r);
  for (let r = tierRank(tier) - 1; r >= tierRank("quick"); r--) order.push(r);
  for (let r = Math.max(tierRank(cap), tierRank(tier)) + 1; r <= tierRank("max"); r++) order.push(r);
  for (const r of order) {
    const picked = pickTier(tierAt(r), need, catalog, settings, stats);
    if (picked) {
      if (picked.tier !== tier) reasons.push(`nearest=${picked.tier}`);
      return picked;
    }
  }
  return undefined;
}

function usableFor(choice: TierChoice, need: Need, catalog: RoutingCatalog, settings: RoutingSettings, stats?: LatencyView): boolean {
  const info = catalog.candidates.get(modelKey(choice.provider, choice.id));
  return !!info
    && info.levels.includes(choice.thinkingLevel)
    && (!info.local || settings.allowLocalModels)
    && (!need.vision || info.vision)
    && info.contextWindow >= need.minContext
    && !stats?.blocked(choice.provider, choice.id);
}

/** Expected seconds to a complete short answer: TTFT + output / throughput (local EWMA once trusted). */
export function expectedSeconds(p: Profile, outTokens: number, stats?: LatencyView): number {
  const measured = stats?.get(targetKey(p));
  const ttft = measured && measured.n >= TRUSTED_SAMPLES ? measured.ttftMs / 1_000 : p.ttftS;
  const tps = measured && measured.tpsN >= TRUSTED_SAMPLES ? measured.tps : p.tps;
  return ttft + outTokens / Math.max(1, tps);
}

/** All usable profiles of one tier, best first (curated before generic). */
function rankTier(tier: ModelTier, need: Need, catalog: RoutingCatalog, settings: RoutingSettings, stats?: LatencyView): RouteTarget[] {
  const usable = catalog.profiles.filter(p => p.tier === tier && usableFor(p, need, catalog, settings, stats));
  const cost = new Map(usable.map(p => [p, expectedSeconds(p, need.outTokens, stats)] as const));
  // The max tier is only reached on explicit request: there, intelligence comes first.
  const byQuality = settings.bias === "quality" || tier === "max";
  const sorted = (list: Profile[]) => [...list].sort((a, b) => byQuality
    ? b.ii - a.ii || cost.get(a)! - cost.get(b)!
    : cost.get(a)! - cost.get(b)! || b.ii - a.ii);
  const ordered = [
    ...sorted(usable.filter(p => p.source === "prior")),
    ...sorted(usable.filter(p => p.source === "generic")),
  ];
  if (settings.bias === "balanced" && !byQuality && ordered.length > 1) {
    // Balanced: a clearly smarter model (≥ +5 II) wins if it is at most 1.5× slower.
    const best = ordered[0]!;
    const smarter = ordered.find(p => p.source === best.source && p.ii >= best.ii + 5 && cost.get(p)! <= cost.get(best)! * 1.5);
    if (smarter) {
      ordered.splice(ordered.indexOf(smarter), 1);
      ordered.unshift(smarter);
    }
  }
  const unique: RouteTarget[] = [];
  for (const p of ordered) {
    const target: RouteTarget = { provider: p.provider, id: p.id, thinkingLevel: p.thinkingLevel, tier };
    if (!unique.some(u => sameTarget(u, target))) unique.push(target);
  }
  return unique;
}

function pickTier(tier: ModelTier, need: Need, catalog: RoutingCatalog, settings: RoutingSettings, stats?: LatencyView): RouteTarget | undefined {
  const override = settings.tierOverrides?.[tier];
  if (override && usableFor(override, need, catalog, settings, stats)) {
    return { provider: override.provider, id: override.id, thinkingLevel: override.thinkingLevel, tier };
  }
  return rankTier(tier, need, catalog, settings, stats)[0];
}

/** Cheapest usable quick-tier target (compaction summaries and other `direct` requests). */
export function quickestTarget(catalog: RoutingCatalog, settings: RoutingSettings, minContext = 0, stats?: LatencyView): RouteTarget | undefined {
  const need: Need = { vision: false, minContext, outTokens: 300 };
  for (const tier of MODEL_TIERS) {
    const ranked = rankTier(tier, need, catalog, { ...settings, bias: "speed", tierOverrides: undefined }, stats);
    if (ranked[0]) return ranked[0];
  }
  return undefined;
}
