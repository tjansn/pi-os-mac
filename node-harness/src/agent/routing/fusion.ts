import { BASE_TIERS, intrinsicTier } from "./decide.js";
import { isModelTier, tierRank, type AgentIntent, type Classification, type ClassifierHints, type ModelTier } from "./types.js";

/**
 * Fuse advisory classifier hints (Laya, a pi catalog classifier such as Jev or
 * Clef) into the heuristic classification. Advisory output may only RAISE the
 * tier or the need for a screenshot; it never lowers a rule-derived tier, never
 * clears explicit words, and never authorizes or triggers anything.
 *
 * Monotonicity: decide() maps a higher starting tier to an equal or higher
 * final tier (every later modifier is non-decreasing), so raising the starting
 * point through `tierFloor` cannot lower the result.
 */

export interface HintThresholds {
  /** Minimum intentP before a hinted intent may raise the tier. */
  intent: number;
  /** Minimum tierP before a hinted tier becomes a floor. */
  tier: number;
}

export const DEFAULT_HINT_THRESHOLDS: HintThresholds = { intent: 0.7, tier: 0.6 };

const probability = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : undefined;

const higher = (a: ModelTier | undefined, b: ModelTier): ModelTier => (a && tierRank(a) >= tierRank(b) ? a : b);

/**
 * Labels a hint may adopt when no rule matched. Never calculate/open/search:
 * those can select the instant lane, and a hint must not trigger an action.
 */
const ADOPTABLE = new Set<AgentIntent>(["answer", "write", "act_in_app", "browse_web", "code"]);

export function classificationFromHints(
  heuristic: Classification,
  hints: ClassifierHints | null | undefined,
  thresholds: HintThresholds = DEFAULT_HINT_THRESHOLDS,
): Classification {
  if (!hints) return heuristic;
  const fused: Classification = { ...heuristic };
  const raised: string[] = [];

  const screen = probability(hints.needsScreen);
  if (screen !== undefined && screen > fused.needsScreen) {
    fused.needsScreen = screen;
    raised.push("screen");
  }

  const intentP = probability(hints.intentP) ?? 0;
  const intent = hints.intent;
  if (intent && Object.hasOwn(BASE_TIERS, intent) && intentP >= thresholds.intent && intent !== heuristic.intent) {
    const hinted = BASE_TIERS[intent][heuristic.complexity];
    const before = intrinsicTier(heuristic);
    if (heuristic.intent === "other" && ADOPTABLE.has(intent)) {
      // No rule matched: adopt the label, but pin the floor so the change cannot lower the tier.
      fused.intent = intent;
      fused.intentConfidence = Math.max(heuristic.intentConfidence, intentP);
      fused.tierFloor = higher(higher(heuristic.tierFloor, before), hinted);
      raised.push("intent");
    } else if (tierRank(hinted) > tierRank(before)) {
      fused.tierFloor = higher(heuristic.tierFloor, hinted);
      raised.push("tier");
    }
    if (intent === "act_in_app" && fused.needsScreen < 0.6) {
      fused.needsScreen = 0.6;
      if (!raised.includes("screen")) raised.push("screen");
    }
  }

  const tierP = probability(hints.tierP) ?? 0;
  if (isModelTier(hints.tier) && tierP >= thresholds.tier && tierRank(hints.tier) > tierRank(intrinsicTier(fused))) {
    fused.tierFloor = higher(fused.tierFloor, hints.tier);
    if (!raised.includes("tier")) raised.push("tier");
  }

  const latencyMs = typeof hints.latencyMs === "number" && Number.isFinite(hints.latencyMs) ? Math.max(0, hints.latencyMs) : 0;
  fused.advisory = { source: hints.source, latencyMs, raised };
  return fused;
}
