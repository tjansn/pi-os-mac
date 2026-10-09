/**
 * Full pi session contracts (protocol.md "Full pi session (macOS)"): the working directory a full session runs
 * in, the content-free resource status Settings shows, and the names pi's coding tools carry in invocation
 * records. Swift mirror: `PiOSCore/PiSessionContracts.swift`; wire fixtures: `shared/fixtures/pi-session/*.json`.
 *
 * A full pi session is the existing resource mode `trustedGlobal` on macOS. Isolated macOS sessions and the
 * Windows host never send or use any of this: their requests, prompts, tools and records stay byte-identical.
 * Nothing here grants authority. The working-directory checks are lexical hygiene for the request, not a
 * filesystem sandbox: bash in a full session can reach any folder the user can.
 */

// ---------------------------------------------------------------------------------------------
// `workingDirectory` on POST /invoke and POST /invocations/prepare

/** Limits shared with the Swift host. Lengths are UTF-8 bytes (macOS PATH_MAX), so never more than 1024 characters. */
export const WORKING_DIRECTORY_LIMITS = {
  maxBytes: 1_024,
} as const;

/**
 * Folders a working directory may not be, or be inside (compared ASCII case-insensitively, as APFS does by
 * default). `/var/db` is the `/private/var/db` firmlink spelling. The host strips a `/System/Volumes/Data`
 * prefix before sending, so a data-volume folder is sent under its usual path, never under `/System`.
 */
export const WORKING_DIRECTORY_BLOCKED_ROOTS = ["/System", "/private/var/db", "/var/db", "/dev"] as const;

/**
 * Why a `workingDirectory` value is refused, checked in this order (the first failing check names the issue):
 * - `not_string`: not a JSON string;
 * - `not_absolute`: empty or not starting with `/` (no `~`, no relative path);
 * - `invalid_character`: NUL, a line break or any other C0/C1 control, DEL, U+2028/U+2029, or an unpaired surrogate;
 * - `too_long`: more than 1024 UTF-8 bytes;
 * - `not_normalized`: an empty (`//`, trailing `/`), `.` or `..` component; the root `/` itself is not a working directory;
 * - `blocked_root`: `/System`, `/private/var/db`, `/var/db`, `/dev`, or a folder inside one of them.
 */
export const WORKING_DIRECTORY_ISSUES = [
  "not_string", "not_absolute", "invalid_character", "too_long", "not_normalized", "blocked_root",
] as const;
export type WorkingDirectoryIssue = (typeof WORKING_DIRECTORY_ISSUES)[number];

const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;
/** An unpaired UTF-16 surrogate (no `u` flag: code units). Swift strings cannot hold one; JSON can. */
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

/** ASCII-only lowercasing: identical on both sides, whatever the Unicode tables say. */
function asciiLower(value: string): string {
  return value.replace(/[A-Z]/g, (letter) => letter.toLowerCase());
}

/** `path` is one of WORKING_DIRECTORY_BLOCKED_ROOTS or inside one (ASCII case-insensitive, lexical). */
export function isUnderBlockedRoot(path: string): boolean {
  const lower = asciiLower(path);
  return WORKING_DIRECTORY_BLOCKED_ROOTS.some((root) => {
    const blocked = asciiLower(root);
    return lower === blocked || lower.startsWith(`${blocked}/`);
  });
}

/** The first issue of a `workingDirectory` value, or undefined when it is valid. Never echoes the value. */
export function workingDirectoryIssue(value: unknown): WorkingDirectoryIssue | undefined {
  if (typeof value !== "string") return "not_string";
  if (!value.startsWith("/")) return "not_absolute";
  if (CONTROL.test(value) || LONE_SURROGATE.test(value)) return "invalid_character";
  if (Buffer.byteLength(value, "utf8") > WORKING_DIRECTORY_LIMITS.maxBytes) return "too_long";
  if (!value.slice(1).split("/").every((part) => part !== "" && part !== "." && part !== "..")) return "not_normalized";
  if (isUnderBlockedRoot(value)) return "blocked_root";
  return undefined;
}

export function isWorkingDirectory(value: unknown): value is string {
  return workingDirectoryIssue(value) === undefined;
}

export type WorkingDirectoryParse =
  | { ok: true; workingDirectory?: string }
  | { ok: false; code: WorkingDirectoryIssue; error: string };

/**
 * Strict `workingDirectory` of /invoke and /invocations/prepare (400 `invalid_arguments` on failure). Absent or
 * null → `{ok: true}` without a value: the session keeps today's directory. The error names the field and the
 * issue code only, never the value; the path itself is never logged, traced or put in a record.
 */
export function parseWorkingDirectory(value: unknown): WorkingDirectoryParse {
  if (value === undefined || value === null) return { ok: true };
  const code = workingDirectoryIssue(value);
  if (code) return { ok: false, code, error: `workingDirectory is invalid (${code})` };
  return { ok: true, workingDirectory: value as string };
}

/** POST /invocations/prepare body. `workingDirectory` is additive, like on /invoke; a cancel ignores it. */
export interface PrepareRequest {
  contextId?: string;
  takeId: string;
  cancel?: boolean;
  workingDirectory?: string;
}

// ---------------------------------------------------------------------------------------------
// GET /settings/resources `status`

/**
 * Whether a loaded global pi extension guards the bash tool: `dcg` (the dcg hook, which shows its own approval
 * dialog and fails closed), `other` (some other global extension handles `tool_call`), `none` (no global
 * extension does, or no full session loads global extensions).
 */
export const BASH_GUARDS = ["dcg", "other", "none"] as const;
export type BashGuard = (typeof BASH_GUARDS)[number];

/** Read-only and content-free: never a path, extension name or command. Determined in Node. */
export interface ResourceStatus {
  /** New agent sessions run as full pi sessions: macOS, `trustedGlobal` stored and not suppressed (read-only launch, no computer control). */
  fullSession: boolean;
  /** Global extensions a full session loads, classified by bashGuardOf. `none` whenever `fullSession` is false. */
  guard: BashGuard;
}

/** The whole GET /settings/resources body. `status` is absent on older harnesses. */
export interface ResourceSettingsResponse {
  current: { mode: "isolated" | "trustedGlobal" };
  warning: string;
  status?: ResourceStatus;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Strict check of a `status` object: null when invalid. Unknown keys are dropped (normalized copy). */
export function parseResourceStatus(value: unknown): ResourceStatus | null {
  if (!isRecord(value) || typeof value.fullSession !== "boolean") return null;
  if (typeof value.guard !== "string" || !(BASH_GUARDS as readonly string[]).includes(value.guard)) return null;
  return { fullSession: value.fullSession, guard: value.guard as BashGuard };
}

/** What bashGuardOf needs from one loaded pi extension (pi's `Extension`: `path`, `sourceInfo.scope`, `handlers` keys). */
export interface GuardCandidate {
  /** A file path, or a synthetic one (`<inline:…>`, `builtin:…`) for code pi-os or pi supplies. */
  path: string;
  /** pi's source scope: `user` is global (`~/.pi/agent`), else `project` or `temporary`. */
  scope: string;
  /** The events it subscribed to. */
  events: Iterable<string>;
}

/** The pi event a guard subscribes to: it sees every bash call before it runs and may block it. */
export const GUARD_EVENT = "tool_call";
/** `dcg` as a whole word of an extension's name: `dcg-guard.ts`, `pi-dcg/index.ts`, `dcg.js`; not `dcguard.ts`. */
const DCG_NAME = /(?:^|[^a-z0-9])dcg(?:[^a-z0-9]|$)/i;

/** An extension's name: its file name without the extension, or its folder's name for an `index.*` entry. */
function extensionName(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean);
  const file = (parts.at(-1) ?? "").replace(/\.[^.]*$/, "");
  return file.toLowerCase() === "index" ? parts.at(-2) ?? file : file;
}

/**
 * Classify the bash guard from the extensions a full session loaded. Only file-backed global (`user`) extensions
 * count, so pi-os's own inline extensions (which also handle `tool_call`) never do. Pure: reads no file, runs no
 * code and logs nothing; Node calls it on the loader's extensions after a full-session or catalog load.
 */
export function bashGuardOf(extensions: Iterable<GuardCandidate>): BashGuard {
  let guard: BashGuard = "none";
  for (const extension of extensions) {
    if (extension.scope !== "user" || extension.path.startsWith("<") || extension.path.startsWith("builtin:")) continue;
    if (![...extension.events].includes(GUARD_EVENT)) continue;
    if (DCG_NAME.test(extensionName(extension.path))) return "dcg";
    guard = "other";
  }
  return guard;
}

// ---------------------------------------------------------------------------------------------
// Record `activity` and `steps[].tool` names of pi's coding tools

/**
 * pi's built-in coding tools (pi-coding-agent `allToolNames`). In a full session the record's `activity` and
 * `steps[].tool` carry these names verbatim while they run, like every other tool; the host labels them
 * (Swift `PiCodingTool.activityLabel`). Never their arguments: no command, path or file content.
 */
export const PI_CODING_TOOLS = ["read", "bash", "edit", "write", "grep", "find", "ls", "powershell"] as const;
export type PiCodingTool = (typeof PI_CODING_TOOLS)[number];

/** pi's `DEFAULT_TOOL_NAMES`: active in a full session unless the user's own `defaultTools` setting changes them. */
export const PI_DEFAULT_ACTIVE_TOOLS = ["read", "bash", "edit", "write"] as const satisfies readonly PiCodingTool[];

export function isPiCodingTool(name: unknown): name is PiCodingTool {
  return typeof name === "string" && (PI_CODING_TOOLS as readonly string[]).includes(name);
}

/** Prefix of the record step the harness adds per agent tool execution (`agent.bash`, `agent.read`, …). */
export const AGENT_STEP_PREFIX = "agent.";

/** The record `steps[].tool` of one agent tool execution. */
export function agentStepName(tool: string): string {
  return `${AGENT_STEP_PREFIX}${tool}`;
}
