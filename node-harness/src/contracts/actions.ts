/**
 * Host actions: the closed vocabulary of launcher effects (protocol.md "Host actions").
 *
 * Node never performs these itself. Instant responses and result cards carry
 * them as descriptors; the native host validates each one against its own
 * launcher policy before acting. There is deliberately no delete, trash, move,
 * rename, write, power, lock or logout action (AGENTS.md computer-use policy).
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
  | { type: "askAgent"; prompt: string };

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
      return typeof value.bundleId === "string" && value.bundleId.length <= 255 && BUNDLE_ID.test(value.bundleId)
        ? { type: "openApp", bundleId: value.bundleId }
        : null;
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
    default:
      return null;
  }
}
