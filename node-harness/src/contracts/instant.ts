import type { HostAction } from "./actions.js";
import type { CardSpec } from "./cards.js";

/**
 * Instant lane contracts (protocol.md "POST /instant") and the classifier /
 * routing vocabulary shared by the instant engine, the Auto router and the
 * optional local classifier.
 */

export type InstantPhase = "typing" | "partial" | "final";

export interface InstantRequest {
  text: string;
  phase: InstantPhase;
  /** Monotonic per take/composer; responses echo it so hosts drop stale ones. */
  seq: number;
  takeId?: string;
  contextId?: string;
  /** BCP 47 hint from the host (keyboard or speech locale). */
  locale?: string;
  inputMode?: "text" | "voice";
  /** Voice only: silence since the transcript last changed. */
  silenceMs?: number;
}

export type InstantIntent =
  | "calc"
  | "unit"
  | "currency"
  | "base"
  | "time"
  | "time_convert"
  | "date"
  | "file_search"
  | "open_app"
  | "url"
  | "web"
  | "system"
  | "refuse";

export type FallthroughReason =
  | "no_match"
  | "deictic"
  | "compound"
  | "low_confidence"
  | "timeout"
  | "unknown_place"
  | "disabled";

interface InstantBase {
  seq: number;
  elapsedMs: number;
  source: "grammar" | "classifier";
}

export type InstantResponse = InstantBase &
  (
    | { decision: "answer"; intent: InstantIntent; title: string; subtitle?: string; card: CardSpec }
    | { decision: "list"; intent: "file_search" | "open_app"; title: string; card: CardSpec; relaxed?: boolean }
    | { decision: "act"; intent: InstantIntent; title: string; action: HostAction; confirm: boolean; card?: CardSpec }
    | { decision: "refuse"; code: "file_deletion_blocked"; message: string; card: CardSpec }
    | { decision: "fallthrough"; reason: FallthroughReason; hints?: ClassifierHints }
  );

export type InstantDecision = InstantResponse["decision"];

/** Router tiers; "instant" means no model at all. */
export const TIERS = ["instant", "quick", "fast", "standard", "deep", "max"] as const;
export type Tier = (typeof TIERS)[number];

export type AgentIntent =
  | "calculate"
  | "search_computer"
  | "open_launch"
  | "answer"
  | "write"
  | "act_in_app"
  | "browse_web"
  | "code"
  | "other";

/**
 * Advisory output of any classifier (Laya sidecar, a pi catalog classifier
 * such as Cloudflare-hosted Jev/Clef, or the built-in heuristics). It may raise
 * a tier or request a screenshot; it never authorizes or triggers an action.
 */
export interface ClassifierHints {
  source: "laya" | "pi-classifier" | "heuristic";
  latencyMs: number;
  intent?: AgentIntent;
  intentP?: number;
  tier?: Tier;
  tierP?: number;
  needsScreen?: number;
  complete?: number;
}

export interface IntentClassifier {
  readonly name: string;
  /**
   * False for classifiers that send text off this machine (kind "pi", e.g. a cloud model). Those
   * are consulted only for a final utterance, never for typing/voice partials. Default: local.
   */
  readonly local?: boolean;
  /** Never throws; resolves null when unavailable, timed out or aborted. */
  classify(text: string, signal: AbortSignal): Promise<ClassifierHints | null>;
}

export const NO_CLASSIFIER: IntentClassifier = {
  name: "off",
  classify: async () => null,
};
