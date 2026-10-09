/**
 * Context scope contracts (protocol.md "Context scope"): whether a hotkey turn is a general
 * question or a question about the pinned active window, who decided that, and whether the agent
 * may pull the window in by itself (`use_active_window`). Swift mirror: `PiOSCore/ContextChoice.swift`;
 * wire fixtures: `shared/fixtures/context/*.json`.
 *
 * The host is authoritative: what its context chip shows at Return is what it sends, and Node never
 * widens that choice. A request WITHOUT `context` keeps the legacy behaviour (window scope, today's
 * prompt and tools): the Windows host and older Mac builds send none.
 *
 * The full pi session's working directory is a sibling of `context` on /invoke and /invocations/prepare
 * (`workingDirectory`, not a member of ContextWire, so it never rides on a follow-up): see piSession.ts.
 */

import { INSTANT_FIELD_KINDS, type InstantFieldKind } from "./instant.js";

export const CONTEXT_SCOPES = ["general", "window"] as const;
export type ContextScope = (typeof CONTEXT_SCOPES)[number];

export const CONTEXT_PULLS = ["allowed", "denied"] as const;
export type ContextPull = (typeof CONTEXT_PULLS)[number];

/**
 * Why the scope is what it is: `default` (chip untouched, nothing suggested), `suggested` (the score
 * lit the chip), `user` (Tab, click, the ⇧ chord, the menu or the drag tether), `setting` (Settings
 * "Always include" / "Only when I ask"), `followup` (inherited from the thread).
 */
export const CONTEXT_SOURCES = ["default", "suggested", "user", "setting", "followup"] as const;
export type ContextSource = (typeof CONTEXT_SOURCES)[number];

/** `context` on POST /invoke and POST /invocations/{id}/followup. */
export interface ContextWire {
  scope: ContextScope;
  /** May the agent call `use_active_window`? Only meaningful in general scope (window scope already includes it). */
  pull: ContextPull;
  source: ContextSource;
  /** Advisory 0..1 score the host's chip used (rules fused with its local scorer). Telemetry and labels only. */
  scopeHint?: number;
  /**
   * Continuity (DESIGN5 §8.4), macOS only: content-free facts about the pinned target, rendered as at most one
   * prompt sentence. Never a name, title, URL, label or value; it grants no tool or authority. Absent: today.
   */
  target?: ContextTarget;
}

/** `context.target`: the bound focused field's kind at the final, and whether pi-os's own open put the app in front. */
export interface ContextTarget {
  field?: InstantFieldKind;
  anchored?: boolean;
}

export type ContextParse = { ok: true; context?: ContextWire } | { ok: false; error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUnit(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}

function oneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}

/**
 * Strict validation of `context` (400 `invalid_arguments` on failure; errors never echo values).
 * Absent or null → `{ok: true, context: undefined}`, which means legacy window behaviour. Unknown keys
 * are dropped (also inside `target`) and null on an optional member counts as absent (protocol
 * convention, as Swift's Codable decodes it); the returned object is a normalized copy.
 */
export function parseContext(value: unknown): ContextParse {
  if (value === undefined || value === null) return { ok: true };
  if (!isRecord(value)) return { ok: false, error: "context must be an object" };
  if (!oneOf(CONTEXT_SCOPES, value.scope)) return { ok: false, error: "context.scope must be general or window" };
  if (!oneOf(CONTEXT_PULLS, value.pull)) return { ok: false, error: "context.pull must be allowed or denied" };
  if (!oneOf(CONTEXT_SOURCES, value.source)) return { ok: false, error: "context.source must be default, suggested, user, setting or followup" };
  const context: ContextWire = { scope: value.scope, pull: value.pull, source: value.source };
  if (value.scopeHint !== undefined && value.scopeHint !== null) {
    if (!isUnit(value.scopeHint)) return { ok: false, error: "context.scopeHint must be 0..1" };
    context.scopeHint = value.scopeHint;
  }
  if (value.target !== undefined && value.target !== null) {
    const target = value.target;
    if (!isRecord(target)) return { ok: false, error: "context.target must be an object" };
    const parsed: ContextTarget = {};
    if (target.field !== undefined && target.field !== null) {
      if (!oneOf(INSTANT_FIELD_KINDS, target.field)) return { ok: false, error: "context.target.field must be a field kind" };
      parsed.field = target.field;
    }
    if (target.anchored !== undefined && target.anchored !== null) {
      if (typeof target.anchored !== "boolean") return { ok: false, error: "context.target.anchored must be a boolean" };
      parsed.anchored = target.anchored;
    }
    context.target = parsed;
  }
  return { ok: true, context };
}

/** Content-free context summary on the invocation record (`GET /invocations/{id}`). */
export interface ContextRecord {
  scope: ContextScope;
  source: ContextSource;
  /** The agent called `use_active_window` during the thread. Sticky: it drives the host's "Looked at <app>" note. */
  pulled: boolean;
  /**
   * The window is part of the thread right now: window scope, or pulled in and not narrowed since.
   * Unlike `pulled` it turns false when the user narrows the thread. The host's follow-up chip inherits it.
   */
  included: boolean;
}

/** The record's `context` before the agent runs: what the host chose, nothing pulled yet. */
export function requestedContextRecord(context: ContextWire): ContextRecord {
  return { scope: context.scope, source: context.source, pulled: false, included: context.scope === "window" };
}

// ---------------------------------------------------------------------------------------------
// /instant scope (rules score) and scorers

/**
 * `scope` on every InstantResponse phase (typing, partial, final): how likely the text refers to
 * the active window. Advisory: the host fuses it with its own score and decides; Node never acts on it.
 */
export interface InstantScope {
  /** 0..1 probability that the request refers to the active window. */
  window: number;
  /** Content-free reason codes (open set, kebab-case, at most 8), e.g. "pronoun", "ui-verb", "inline-content". */
  reasons: string[];
}

export const SCOPE_REASON_PATTERN = /^[a-z][a-z0-9-]{0,31}$/;
export const MAX_SCOPE_REASONS = 8;
/** Codes rules v2 emits today (DESIGN2 §5.5); receivers must accept unknown codes that match the pattern. */
export const KNOWN_SCOPE_REASONS = [
  "deixis-strong",
  /**
   * Follows "deixis-strong" when the strong deixis names user content ("the selection", "this image",
   * "what is this?") and nothing on screen: the host lets its own shelf content take that reference.
   */
  "deixis-content",
  "deixis-weak",
  "act-in-app",
  "definite-noun",
  "pronoun",
  "bare-transform",
  "ui-verb",
  "inline-content",
  "act-not-ui",
  "not-screen-noun",
  "short-unclear",
] as const;

/** Pre-registered thresholds (DESIGN2 §4.2): not tuned until Tom's own utterances are labelled. */
export const SCOPE_THRESHOLDS = {
  /** First turn, Suggest setting: the chip lights at or above this fused score. */
  suggest: 0.5,
  /** Follow-up: a general thread is upgraded to window at or above this score; never auto-downgraded. */
  followupUpgrade: 0.7,
  /** Bands for logs and labels: window ≥ 0.7, general ≤ 0.2, uncertain otherwise. */
  windowBand: 0.7,
  generalBand: 0.2,
} as const;

export type ScopeBand = "general" | "uncertain" | "window";

export function scopeBand(window: number): ScopeBand {
  return window >= SCOPE_THRESHOLDS.windowBand ? "window" : window <= SCOPE_THRESHOLDS.generalBand ? "general" : "uncertain";
}

/** Structural check for an InstantScope; null when invalid (hosts then ignore the advisory field). */
export function parseInstantScope(value: unknown): InstantScope | null {
  if (!isRecord(value) || !isUnit(value.window) || !Array.isArray(value.reasons)) return null;
  if (value.reasons.length > MAX_SCOPE_REASONS) return null;
  if (!value.reasons.every((reason) => typeof reason === "string" && SCOPE_REASON_PATTERN.test(reason))) return null;
  return { window: value.window, reasons: [...(value.reasons as string[])] };
}

/**
 * A synchronous, on-device scorer: text → scope, or null when unavailable. Never throws, never logs
 * or sends the text. Node's rules v2 implement it for /instant (injected into the dispatcher); the
 * Swift host has its own (`ContextScorer` protocol, NLContextualEmbedding + LR) and reports the fused
 * result only as `ContextWire.scopeHint`.
 */
export type ContextScorer = (text: string) => InstantScope | null;

export const NO_CONTEXT_SCORER: ContextScorer = () => null;

// ---------------------------------------------------------------------------------------------
// Host settings (macOS UserDefaults; Node never stores them). Listed here so both sides share names.

export const ACTIVE_WINDOW_MODES = ["off", "suggest", "always"] as const;
/** Settings → Active window: "Only when I ask" (off) / "Suggest" (default) / "Always include". */
export type ActiveWindowMode = (typeof ACTIVE_WINDOW_MODES)[number];

export const BRAVE_ACCESS_MODES = ["ax", "cdp"] as const;
/** Settings → Brave access: Accessibility (default, no prompts) or the DevTools (CDP) opt-in. */
export type BraveAccess = (typeof BRAVE_ACCESS_MODES)[number];

export interface HostContextSettings {
  activeWindow: ActiveWindowMode;
  braveAccess: BraveAccess;
  /** "Act in Brave without bringing it to the front" (stage B, `browser.axAct`). */
  braveBackgroundActions: boolean;
}

/** UserDefaults keys. The legacy `braveConnectionEnabled = true` does NOT migrate to `braveAccess: "cdp"`. */
export const HOST_CONTEXT_SETTING_KEYS = {
  activeWindow: "activeWindow",
  braveAccess: "braveAccess",
  braveBackgroundActions: "braveBackgroundActions",
} as const satisfies Record<keyof HostContextSettings, string>;

export const DEFAULT_HOST_CONTEXT_SETTINGS: Readonly<HostContextSettings> = {
  activeWindow: "suggest",
  braveAccess: "ax",
  braveBackgroundActions: true,
};

export { ATTACHMENT_LIMITS as SHELF_CAPS } from "./attachments.js";
/** The in-memory shelf empties itself after this much idle time (host-side). */
export const SHELF_IDLE_EXPIRY_MS = 15 * 60_000;
