import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import type { ContextScope } from "../../contracts/context.js";
import { TIERS, type AgentIntent, type ClassifierHints, type Tier } from "../../contracts/instant.js";

/**
 * Auto model router vocabulary (DESIGN.md §3.4, routing.md §6–7).
 *
 * Everything here is plain JSON data: decisions travel from server.ts into the
 * virtual model's route() and parts of them are persisted as pi router state.
 * Nothing in these shapes carries prompt text, transcripts or file paths.
 */

export { TIERS };
export type { AgentIntent, ClassifierHints, Tier };

/** Tiers that run a model ("instant" never does). */
export type ModelTier = Exclude<Tier, "instant">;
export const MODEL_TIERS: readonly ModelTier[] = ["quick", "fast", "standard", "deep", "max"];

export function tierRank(tier: Tier): number {
  return TIERS.indexOf(tier);
}

export function isModelTier(value: unknown): value is ModelTier {
  return typeof value === "string" && (MODEL_TIERS as readonly string[]).includes(value);
}

/** User preference; also the virtual model's thinking level (low/medium/high). */
export type RoutingBias = "speed" | "balanced" | "quality";
export const ROUTING_BIASES: readonly RoutingBias[] = ["speed", "balanced", "quality"];

/** Coarse class of the pinned app, derived from its process name. */
export type SurfaceClass = "browser" | "editor" | "terminal" | "finder" | "mail_chat" | "office" | "other";

/**
 * Router input distilled from the utterance. The heuristic classifier always
 * produces one; advisory classifiers can only raise it (fusion.ts).
 */
export interface Classification {
  source: "heuristic";
  intent: AgentIntent;
  /** 0..1; < 0.5 is logged as low-confidence (no longer a tier floor: escalation covers misses). */
  intentConfidence: number;
  complexity: 0 | 1 | 2;
  /** 0..1 probability that the request needs the screenshot (deixis, screen words). */
  needsScreen: number;
  /** "think hard", "gründlich", "deep dive" … → at least deep, ignores the auto-tier cap. */
  explicitDeep: boolean;
  /** "ultrathink", "max effort" … → max tier. Implies explicitDeep. */
  explicitMax: boolean;
  /** "quick", "schnell", "kurz" … → one tier lower (ignored when explicitDeep). */
  explicitFast: boolean;
  /** 0..1 that a follow-up says the previous answer was wrong (only used for follow-ups). */
  correction: number;
  /** Advisory raise from an optional classifier; never lowers the rule-derived tier. */
  tierFloor?: ModelTier;
  advisory?: { source: ClassifierHints["source"]; latencyMs: number; raised: string[] };
}

export interface RouteInput {
  classification: Classification;
  /** A further prompt in an existing thread. */
  followup: boolean;
  surface: SurfaceClass;
  /** A host screenshot is available to attach to the first prompt. */
  hasScreenshot: boolean;
  /**
   * The host's context scope (contracts/context.ts). general: never a screenshot, no vision need;
   * window: the screenshot when there is one, and a vision-capable model (window threads see images).
   * Absent: legacy (Windows, older Mac builds), screenshot by the classification exactly as before.
   */
  scope?: ContextScope;
  /** An image attachment rides along (context shelf): a vision-capable model is required. */
  hasImageAttachment?: boolean;
  /** Length of selected text supplied with the request, if the host provides it. */
  selectionChars: number;
  /** The pinned browser is driven through CDP snapshots rather than pixels. */
  browserCdp: boolean;
  /** Rough size of the first request (system prompt + context + image), for context-window filtering. */
  estimatedPromptTokens: number;
  /** Tier the thread ran on last (no downgrade mid-thread). */
  lastTier?: ModelTier;
}

export interface TierChoice {
  provider: string;
  id: string;
  thinkingLevel: ModelThinkingLevel;
}

/** A concrete model + level and the tier it serves. */
export interface RouteTarget extends TierChoice {
  tier: ModelTier;
}

/** Per available (auth-checked) chat model; what decide() may route to. */
export interface CandidateInfo {
  provider: string;
  id: string;
  vision: boolean;
  contextWindow: number;
  /** Loopback/local inference server: excluded unless allowLocalModels. */
  local: boolean;
  reasoning: boolean;
  /** pi-supported thinking levels (getSupportedThinkingLevels). */
  levels: readonly ModelThinkingLevel[];
}

/** Latency/quality prior for one model@level in one tier. */
export interface Profile extends TierChoice {
  tier: ModelTier;
  /** Time to first token, seconds (includes thinking). */
  ttftS: number;
  /** Output tokens per second. */
  tps: number;
  /** Intelligence index (Artificial Analysis scale) used for quality ranking. */
  ii: number;
  /** Curated priors win over generic family estimates within a tier. */
  source: "prior" | "generic";
  /** Never picked by Auto on its own; the prior only estimates the latency when a tier override pins it. */
  pinOnly?: boolean;
}

export interface RoutingCatalog {
  /** Keyed by modelKey(provider, id). */
  candidates: ReadonlyMap<string, CandidateInfo>;
  profiles: readonly Profile[];
}

export interface RoutingSettings {
  bias: RoutingBias;
  /** Highest tier Auto picks on its own; explicit depth words may exceed it. */
  maxAutoTier: ModelTier;
  /** Pin a model@level per tier (validated against the available set at save time). */
  tierOverrides?: Partial<Record<ModelTier, TierChoice>>;
  /** Route to loopback providers (GPU coordination: off by default). */
  allowLocalModels: boolean;
}

export interface RouteDecision {
  lane: "instant" | "agent";
  /** Decided tier (the model may come from a neighbouring tier when this one is empty). */
  tier: Tier;
  /** undefined when nothing usable is available (callers fall back / report). */
  model?: RouteTarget;
  /** Same-tier alternatives for failover, best first. */
  alternates: RouteTarget[];
  /** Escalation rungs above the decided tier, ascending, up to the cap. */
  ladder: RouteTarget[];
  /** Tool-name hints for the agent lane; callers intersect them with their allowlist. */
  toolsAdd: string[];
  attachScreenshot: boolean;
  /** The routed model accepts images (false: send no image, including image attachments). */
  vision: boolean;
  /** RouteInput.scope, echoed (absent for legacy requests). */
  scope?: ContextScope;
  bias: RoutingBias;
  /** Short labels (no content) for logs and the invocation record. */
  reasons: string[];
}

/** One model@level's local measurements (latencyStats.ts). */
export interface StatEntry {
  /** Samples with a TTFT. */
  n: number;
  ttftMs: number;
  /** Samples with a throughput. */
  tpsN: number;
  tps: number;
}

/** What decide()/route() need from LatencyStats. */
export interface LatencyView {
  get(key: string): StatEntry | undefined;
  blocked(provider: string, id: string): boolean;
}

export function modelKey(provider: string, id: string): string {
  return `${provider}/${id}`;
}

/** "provider/id@level", the latency-stats key and the log label. */
export function targetKey(choice: TierChoice): string {
  return `${choice.provider}/${choice.id}@${choice.thinkingLevel}`;
}

export function sameTarget(a: TierChoice | undefined, b: TierChoice | undefined): boolean {
  return !!a && !!b && a.provider === b.provider && a.id === b.id && a.thinkingLevel === b.thinkingLevel;
}
