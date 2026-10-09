import {
  MODEL_TIERS, modelKey, sameTarget, targetKey, tierRank,
  type AgentIntent, type Classification, type LatencyView, type ModelTier, type Profile, type RouteDecision,
  type RouteInput, type RouteTarget, type RoutingCatalog, type RoutingSettings, type StatEntry, type TierChoice,
} from "./types.js";

/**
 * Pure, deterministic model choice (routing.md §6.5). No SDK, no I/O, no
 * classifier calls: server.ts runs it before prompt() and the virtual model's
 * route() consumes the result.
 */

/**
 * Base tier by intent for complexity 0/1/2 (DESIGN2 §5.4, r2/latency.md §5.1). Ordinary answers,
 * writing and simple UI work stay on quick: a fast-tier turn costs ~1 s more per turn and Sol@off ~3.3 s.
 * Misses are caught by escalation (pi_os_escalate, ≥ 2 tool errors, > 8 tool results, corrections).
 */
export const BASE_TIERS: Readonly<Record<AgentIntent, readonly [ModelTier, ModelTier, ModelTier]>> = {
  calculate: ["quick", "quick", "fast"],
  search_computer: ["quick", "quick", "fast"],
  open_launch: ["quick", "quick", "fast"],
  answer: ["quick", "quick", "standard"],
  write: ["quick", "quick", "standard"],
  act_in_app: ["quick", "fast", "standard"],
  browse_web: ["quick", "fast", "standard"],
  code: ["standard", "standard", "deep"],
  other: ["quick", "quick", "fast"],
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
/** Bad news is believed at once: a single measurement this many times worse than the prior is trusted. */
export const BAD_NEWS_FACTOR = 2;
/**
 * Cross-tier latency guard: a tier raised only by a soft signal (complexity 1) falls back to the tier
 * without the signal when its model's expected TTFT is > DEMOTE_FACTOR× that tier's AND more than
 * DEMOTE_MIN_S slower, or > DEMOTE_EXTRA_S above it. Sub-second gaps (Haiku 0.6 s vs Sonnet 1.3 s)
 * never demote; Codex Sol@off (5 s) vs Luna (1.7 s) does.
 */
export const DEMOTE_FACTOR = 2;
export const DEMOTE_MIN_S = 1;
export const DEMOTE_EXTRA_S = 2;
const LOW_CONFIDENCE = 0.5;
const CORRECTION_THRESHOLD = 0.6;
const SCREEN_THRESHOLD = 0.5;
const MAX_ALTERNATES = 3;

const tierAt = (rank: number): ModelTier => MODEL_TIERS[Math.min(MODEL_TIERS.length - 1, Math.max(0, rank - 1))]!;

/**
 * Tier implied by the classification alone, before settings/bias/follow-up
 * modifiers: base(intent, complexity), advisory floor. Low confidence is no
 * floor (it sent every unmatched request to the slow fast tier, r2/latency.md §4).
 */
export function intrinsicTier(c: Classification, selectionChars = 0): ModelTier {
  let base = BASE_TIERS[c.intent][c.complexity];
  if (c.intent === "write" && selectionChars > 2_000 && base === "quick") base = "fast";
  let rank = tierRank(base);
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

/** The decided tier and its cap: base tier plus settings, follow-up and explicit-word modifiers. */
function tierFor(c: Classification, input: RouteInput, settings: RoutingSettings, reasons?: string[]): { tier: ModelTier; cap: ModelTier } {
  let rank = tierRank(intrinsicTier(c, input.selectionChars));
  if (c.intentConfidence < LOW_CONFIDENCE) reasons?.push("low-confidence");
  if (c.tierFloor) reasons?.push(`floor=${c.tierFloor}`);
  if (!c.explicitDeep && (c.explicitFast || settings.bias === "speed")) {
    rank = Math.max(tierRank("quick"), rank - 1);
    reasons?.push(c.explicitFast ? "explicit-fast" : "bias=speed");
  } else if (settings.bias === "quality") {
    rank = Math.max(rank, Math.min(tierRank("deep"), rank + 1));
    reasons?.push("bias=quality");
  }
  if (input.followup) {
    if (input.lastTier) rank = Math.max(rank, tierRank(input.lastTier));
    if (c.correction >= CORRECTION_THRESHOLD) {
      rank = Math.max(rank, tierRank(input.lastTier ?? "quick")) + 1;
      reasons?.push("correction");
    }
  }
  if (c.explicitDeep) { rank = Math.max(rank, tierRank("deep")); reasons?.push("explicit-deep"); }
  if (c.explicitMax) { rank = tierRank("max"); reasons?.push("explicit-max"); }
  const cap: ModelTier = c.explicitDeep || c.explicitMax ? "max" : settings.maxAutoTier;
  if (rank > tierRank(cap)) reasons?.push(`cap=${cap}`);
  return { tier: tierAt(Math.min(rank, tierRank(cap))), cap };
}

/**
 * Screenshot need. With a host scope: window attaches the screenshot when there is one, general never
 * does. Without one (legacy requests): today's formula over the classification, unchanged.
 */
function wantsScreenshotFor(input: RouteInput): boolean {
  if (!input.hasScreenshot) return false;
  if (input.scope) return input.scope === "window";
  const c = input.classification;
  return c.needsScreen >= SCREEN_THRESHOLD || c.intent === "act_in_app" || (c.intent === "browse_web" && !input.browserCdp);
}

export function decide(input: RouteInput, catalog: RoutingCatalog, settings: RoutingSettings, options: DecideOptions = {}): RouteDecision {
  const c = input.classification;
  const reasons = [`intent=${c.intent}`, `conf=${c.intentConfidence.toFixed(2)}`, `cx=${c.complexity}`];
  if (c.advisory) reasons.push(`advisory=${c.advisory.source}${c.advisory.raised.length ? `:${c.advisory.raised.join("+")}` : ""}`);
  if (input.scope) reasons.push(`scope=${input.scope}`);
  const scope = input.scope ? { scope: input.scope } : {};

  // Only a rule-derived label may select the instant lane (advisory hints never trigger actions).
  if (!input.followup && (c.intent === "calculate" || c.intent === "open_launch") && c.intentConfidence >= 0.6
      && !c.advisory?.raised.includes("intent") && options.instantOk?.(input)) {
    return { lane: "instant", tier: "instant", alternates: [], ladder: [], toolsAdd: [], attachScreenshot: false, vision: false,
      ...scope, bias: settings.bias, reasons: [...reasons, "instant"] };
  }

  const decided = tierFor(c, input, settings, reasons);
  const cap = decided.cap;
  let tier = decided.tier;

  const wantsScreenshot = wantsScreenshotFor(input);
  if (input.hasImageAttachment) reasons.push("image-attachment");
  // A window thread sees window images (attached now or captured by its tools); attachments are images too.
  const wantsVision = wantsScreenshot || input.hasImageAttachment === true || input.scope === "window";
  const need: Need = {
    vision: wantsVision,
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
    for (const vision of wantsVision ? [true, false] : [false]) {
      model = pickNearest(tier, cap, { ...need, vision }, catalog, settings, view, reasons);
      if (!model) continue;
      need.vision = vision;
      stats = view;
      if (wantsVision && !vision) reasons.push("no-vision-model");
      if (view === unblocked) reasons.push("health-blocked");
      break;
    }
    if (model) break;
  }
  if (!model) reasons.push("no-usable-model");

  // Cross-tier latency guard: never pay a much slower model for a soft signal alone.
  if (model && c.complexity === 1) {
    const plain = tierFor({ ...c, complexity: 0 }, input, settings).tier;
    if (tierRank(plain) < tierRank(tier)) {
      const notes: string[] = [];
      const alternative = pickNearest(plain, cap, need, catalog, settings, stats, notes);
      const raisedTtft = targetTtft(model, catalog, measured);
      const plainTtft = alternative && targetTtft(alternative, catalog, measured);
      if (alternative && !sameTarget(alternative, model) && raisedTtft !== undefined && plainTtft !== undefined
          && ((raisedTtft > DEMOTE_FACTOR * plainTtft && raisedTtft - plainTtft > DEMOTE_MIN_S) || raisedTtft - plainTtft > DEMOTE_EXTRA_S)) {
        reasons.push(...notes, "latency-demote");
        tier = plain;
        model = alternative;
      }
    }
  }
  const attachScreenshot = !!model && need.vision && wantsScreenshot;

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
    attachScreenshot, vision: !!model && (catalog.candidates.get(modelKey(model.provider, model.id))?.vision ?? false),
    ...scope, bias: settings.bias, reasons,
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

/**
 * Expected TTFT in seconds: the local EWMA once it has TRUSTED_SAMPLES samples, or from the first sample
 * when that is ≥ BAD_NEWS_FACTOR× the prior (r2/latency.md §5.1: Tom's first 7.5 s Sol turn should have
 * counted at once); good news waits for TRUSTED_SAMPLES.
 */
export function expectedTtft(p: Pick<Profile, "ttftS">, measured?: StatEntry): number {
  if (!measured || measured.n < 1) return p.ttftS;
  const ttft = measured.ttftMs / 1_000;
  return measured.n >= TRUSTED_SAMPLES || ttft >= BAD_NEWS_FACTOR * p.ttftS ? ttft : p.ttftS;
}

/** Expected seconds to a complete short answer: TTFT + output / throughput (same trust rule, slower = worse). */
export function expectedSeconds(p: Profile, outTokens: number, stats?: LatencyView): number {
  const measured = stats?.get(targetKey(p));
  const ttft = expectedTtft(p, measured);
  const trustedTps = measured && measured.tpsN >= 1 && (measured.tpsN >= TRUSTED_SAMPLES || measured.tps * BAD_NEWS_FACTOR <= p.tps);
  const tps = trustedTps ? measured.tps : p.tps;
  return ttft + outTokens / Math.max(1, tps);
}

/**
 * Expected TTFT of a routed target (also a tier override or a pin-only model): its prior with the trust
 * rule, else any local measurement, else undefined (unknown: the latency guard then stays out of it).
 */
function targetTtft(target: TierChoice, catalog: RoutingCatalog, stats?: LatencyView): number | undefined {
  const measured = stats?.get(targetKey(target));
  const profile = catalog.profiles.find(p => sameTarget(p, target));
  if (profile) return expectedTtft(profile, measured);
  return measured && measured.n >= 1 ? measured.ttftMs / 1_000 : undefined;
}

/** All usable profiles of one tier, best first (curated before generic; pin-only priors never). */
function rankTier(tier: ModelTier, need: Need, catalog: RoutingCatalog, settings: RoutingSettings, stats?: LatencyView): RouteTarget[] {
  const usable = catalog.profiles.filter(p => p.tier === tier && !p.pinOnly && usableFor(p, need, catalog, settings, stats));
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
