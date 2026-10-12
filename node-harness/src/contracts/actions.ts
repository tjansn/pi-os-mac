/**
 * Host actions: the closed vocabulary of launcher effects (protocol.md "Host actions").
 *
 * Node never performs these itself. Instant responses and result cards carry
 * them as descriptors; the native host validates each one against its own
 * launcher policy before acting. There is deliberately no delete, trash, move,
 * rename, write, power, lock or logout action (AGENTS.md computer-use policy).
 *
 * File commands (DESIGN6/BUILD6, instant lane only, full pi sessions): `fileOp` names an operation Node
 * staged for one take, never a path or a command. The host only asks Node to run it (POST /fileops/run);
 * Node runs it as argv after the user's command guard (dcg) reviewed it. `quitApp` terminates an app
 * gracefully and `closeFinderWindow` closes the take's captured Finder window. None of the three is ever a
 * model-card or agent binding (MODEL_CARD_ACTION_TYPES, AGENT_OPEN_ACTION_TYPES).
 */

export const SYSTEM_OPS = [
  "appearance.set",
  "appearance.toggle",
  "volume.set",
  "volume.step",
  "volume.mute",
  "display.sleep",
] as const;
export type SystemOp = (typeof SYSTEM_OPS)[number];

export type HostAction =
  | { type: "copyText"; text: string }
  /**
   * Instant lane only; the host routes it through input.typeText and InputPolicy. `submit: true` (continuity
   * fills only, `act` intent `fill`): after the text the host presses Return once as a SEPARATE gated
   * `pressKey enter` (LauncherPolicy plan: identity/focus re-check and the destructive-control check), never
   * as a newline inside the text, so the text must then be single-line (and an `act` with intent `fill` is
   * single-line whether or not it submits: fillActConsistent). A literal `true`; `false` and null read as
   * absent. The ⌘↩ answer-card path and card bindings never set it.
   */
  | { type: "typeIntoPinned"; text: string; submit?: true }
  /** http/https only; the host re-validates the scheme. */
  | { type: "openURL"; url: string }
  | { type: "openApp"; bundleId: string }
  /** Tokens are minted by the host's file search; Node never fabricates them. */
  | { type: "openFile" | "revealFile" | "copyPath"; token: string }
  /** Instant lane only. */
  | { type: "system"; op: SystemOp; value?: number | boolean | "dark" | "light" }
  | { type: "askAgent"; prompt: string }
  /** Instant lane only: run the operation Node staged for the take (POST /fileops/run {opId}). */
  | { type: "fileOp"; opId: string }
  /** Instant lane only: graceful terminate of the app with this bundle id (never a force quit). */
  | { type: "quitApp"; bundleId: string }
  /** Instant lane only: close the take's captured Finder window, only while it is still that Finder window. */
  | { type: "closeFinderWindow"; contextId: string };

export type HostActionType = HostAction["type"];

export const HOST_ACTION_TYPES: readonly HostActionType[] = [
  "copyText",
  "typeIntoPinned",
  "openURL",
  "openApp",
  "openFile",
  "revealFile",
  "copyPath",
  "system",
  "askAgent",
  "fileOp",
  "quitApp",
  "closeFinderWindow",
];

/** Actions a model-authored card may bind. File actions additionally need a ledger token. */
export const MODEL_CARD_ACTION_TYPES: readonly HostActionType[] = [
  "copyText",
  "openURL",
  "openApp",
  "openFile",
  "revealFile",
  "copyPath",
  "askAgent",
];

/** Actions an agent tool may ask the host to perform through POST /tools/launcher.open. */
export const AGENT_OPEN_ACTION_TYPES: readonly HostActionType[] = ["openApp", "openURL", "openFile", "revealFile"];

export const MAX_ACTION_TEXT = 4_000;
export const MAX_ACTION_PROMPT = 500;
/** Control and line-separator characters: a `submit` text is one line (each CR/LF would be a Return of its own). */
const CONTROL_TEXT = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;

/**
 * One line: no control or line-separator character (Swift `AttachmentValidation.hasControl`). Every continuity
 * fill and every `submit` text must be one: a CR/LF would be a Return of its own and a Tab would move focus.
 */
export function isOneLineText(text: string): boolean {
  return !CONTROL_TEXT.test(text);
}
const TOKEN = /^[A-Za-z0-9_-]{8,128}$/;
const BUNDLE_ID = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;
/** A staged file operation's id (Node mints it per take; the host only hands it back). */
export const FILE_OP_ID = /^[A-Za-z0-9_-]{16,64}$/;
/** The take's context (the visible-items route's rule). */
const CONTEXT_ID = /^[A-Za-z0-9_-]{1,128}$/;

function isBundleIdValue(value: unknown): value is string {
  return typeof value === "string" && value.length <= 255 && BUNDLE_ID.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function boundedString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

/**
 * Characters WHATWG URL parsing silently repairs (whitespace, backslashes, controls, invisible
 * format characters) but the Swift host's URL(string:) may reject: such a binding would pass
 * here and fail the whole card there, so both sides refuse it up front.
 */
const URL_UNSAFE = /[\s\\\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\u2060\ufeff]/u;

export function isHttpUrl(value: unknown): value is string {
  if (!boundedString(value, 2_048) || URL_UNSAFE.test(value)) return false;
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") && url.hostname.length > 0;
  } catch {
    return false;
  }
}

/**
 * Structural check for one action descriptor. Returns a normalized copy
 * (unknown keys dropped) or null. Policy beyond shape (allowed subsets,
 * token provenance) is the caller's job.
 */
export function parseHostAction(value: unknown): HostAction | null {
  if (!isRecord(value) || typeof value.type !== "string") return null;
  switch (value.type) {
    case "copyText":
      return boundedString(value.text, MAX_ACTION_TEXT) ? { type: "copyText", text: value.text } : null;
    case "typeIntoPinned": {
      if (!boundedString(value.text, MAX_ACTION_TEXT)) return null;
      if (value.submit === undefined || value.submit === null || value.submit === false) return { type: "typeIntoPinned", text: value.text };
      if (value.submit !== true || !isOneLineText(value.text)) return null;
      return { type: "typeIntoPinned", text: value.text, submit: true };
    }
    case "openURL":
      return isHttpUrl(value.url) ? { type: "openURL", url: value.url } : null;
    case "openApp":
      return isBundleIdValue(value.bundleId) ? { type: "openApp", bundleId: value.bundleId } : null;
    case "openFile":
    case "revealFile":
    case "copyPath":
      return typeof value.token === "string" && TOKEN.test(value.token) ? { type: value.type, token: value.token } : null;
    case "system": {
      if (typeof value.op !== "string" || !(SYSTEM_OPS as readonly string[]).includes(value.op)) return null;
      const op = value.op as SystemOp;
      const v = value.value;
      if (v === undefined) return { type: "system", op };
      if (typeof v === "number" && Number.isFinite(v)) return { type: "system", op, value: v };
      if (typeof v === "boolean" || v === "dark" || v === "light") return { type: "system", op, value: v };
      return null;
    }
    case "askAgent":
      return boundedString(value.prompt, MAX_ACTION_PROMPT) ? { type: "askAgent", prompt: value.prompt } : null;
    case "fileOp":
      return typeof value.opId === "string" && FILE_OP_ID.test(value.opId) ? { type: "fileOp", opId: value.opId } : null;
    case "quitApp":
      return isBundleIdValue(value.bundleId) ? { type: "quitApp", bundleId: value.bundleId } : null;
    case "closeFinderWindow":
      return typeof value.contextId === "string" && CONTEXT_ID.test(value.contextId) ? { type: "closeFinderWindow", contextId: value.contextId } : null;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------------------------
// File operations (protocol.md "POST /fileops/run"; DESIGN6 §5, BUILD6)

/** Outcome of POST /fileops/run: `denied` = dcg said no (or the user declined its dialog); `expired` = unknown, used or expired opId, or the source changed. */
export const FILE_OP_OUTCOMES = ["done", "denied", "failed", "expired"] as const;
export type FileOpOutcome = (typeof FILE_OP_OUTCOMES)[number];

export interface FileOpRunRequest { opId: string }

/** 200 body: one line of user copy (≤ 300 UTF-16 units, no control characters). A 400 is `{ok: false, error}` (never echoes the input). */
export interface FileOpRunResponse { ok: true; outcome: FileOpOutcome; line: string }

export const FILE_OP_LIMITS = {
  /** `line` (one line of user copy). */
  maxLine: 300,
  /** dcg's reason inside a `denied` line. */
  maxReason: 200,
  /** The host waits this long for an answer (dcg's dialog may stay open up to 140 s). */
  hostTimeoutMs: 180_000,
} as const;

export type FileOpParse<T> = { ok: true; value: T } | { ok: false; error: string };

/** Strict `{opId}` (unknown keys dropped). The error never echoes a value. */
export function parseFileOpRunRequest(value: unknown): FileOpParse<FileOpRunRequest> {
  if (!isRecord(value) || typeof value.opId !== "string" || !FILE_OP_ID.test(value.opId)) return { ok: false, error: "opId is required" };
  return { ok: true, value: { opId: value.opId } };
}

/** Structural check of a 200 body (hosts drop anything else and show a generic failure). */
export function parseFileOpRunResponse(value: unknown): FileOpRunResponse | null {
  if (!isRecord(value) || value.ok !== true || typeof value.outcome !== "string" || !(FILE_OP_OUTCOMES as readonly string[]).includes(value.outcome)) return null;
  if (!boundedString(value.line, FILE_OP_LIMITS.maxLine) || !isOneLineText(value.line)) return null;
  return { ok: true, outcome: value.outcome as FileOpOutcome, line: value.line };
}
