import { lstat, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join, posix, resolve } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { isUnderBlockedRoot, isWorkingDirectory } from "../contracts/piSession.js";
import { classifyUtterance, intrinsicTier, type Classification, type SurfaceClass, type Tier } from "./routing/index.js";
import { effectiveResourceMode, type ResourceSelection } from "./resourceSettings.js";

/**
 * Full pi session (protocol.md "Full pi session (macOS)"): the resource mode `trustedGlobal` on macOS acts like a
 * normal terminal pi session. Its folder is what the user was looking at, its project resources follow pi's own
 * trust resolution, its thread is a regular pi session file, and its first turn picks the system prompt.
 *
 * Isolated macOS sessions and every Windows session never reach this module's decisions: their working directory,
 * prompts, tools and in-memory history stay exactly as before. Nothing here logs; working directories and session
 * paths are user content.
 */

/** A session on this host and selection is a full pi session: macOS and the effective mode `trustedGlobal`. */
export function isFullSession(platform: NodeJS.Platform, readOnly: boolean, selection?: ResourceSelection): boolean {
  return platform === "darwin" && effectiveResourceMode(platform, readOnly, selection) === "trustedGlobal";
}

// ---------------------------------------------------------------------------------------------
// Working directory

/** Home-relative folders whose contents macOS guards with a privacy prompt (TCC), plus removable and network volumes. */
export const PRIVACY_PROTECTED_HOME_FOLDERS = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"] as const;
export const PRIVACY_PROTECTED_ROOTS = ["/Volumes"] as const;

const asciiLower = (value: string) => value.replace(/[A-Z]/g, letter => letter.toLowerCase());
const within = (path: string, root: string) => {
  const lower = asciiLower(path), base = asciiLower(root);
  return lower === base || lower.startsWith(`${base}/`);
};

/**
 * `path` is, or lies inside, a folder whose contents macOS shows a privacy prompt for (Desktop, Documents,
 * Downloads, iCloud Drive, File Provider storage, /Volumes). Lexical and ASCII case-insensitive like APFS; reads
 * nothing. Project context of such a folder (AGENTS.md, `.pi`) is read only once the user submitted (/invoke).
 */
export function isPrivacyProtected(path: string, home: string): boolean {
  return PRIVACY_PROTECTED_ROOTS.some(root => within(path, root))
    // macOS paths on every Node host (tests run this on Windows runners too).
    || PRIVACY_PROTECTED_HOME_FOLDERS.some(folder => within(path, posix.join(home, folder)));
}

/**
 * The folder a full session runs in: the requested working directory when it is a valid wire value whose real
 * path is an existing directory owned by the user and outside the blocked roots; otherwise the home folder. The
 * real path is used because terminal pi keys its session bucket on `process.cwd()`, which is the real path too.
 */
export async function resolveWorkingDirectory(requested: string | undefined, home: string = homedir()): Promise<string> {
  const uid = process.getuid?.();
  if (requested !== undefined && isWorkingDirectory(requested)) {
    try {
      const real = await realpath(requested);
      const info = await stat(real);
      if (info.isDirectory() && isWorkingDirectory(real) && !isUnderBlockedRoot(real) && (uid === undefined || info.uid === uid)) return real;
    } catch { /* gone, unreadable or not a directory: the home folder */ }
  }
  try { return await realpath(home); } catch { return home; }
}

/**
 * Whether building this full session now would read inside a privacy-protected folder (protocol.md: Node never
 * reads there while preparing at key-down). The candidate is the requested folder (else home); a symbolic link
 * anywhere on its path is not followed before /invoke because its target may be protected (a terminal reports its
 * logical `$PWD`, e.g. `~/dev/x` with `~/dev` linking into Documents or Dropbox). Only `lstat` runs, component by
 * component from the root: every prefix of a lexically unprotected path is unprotected too, so each `lstat` reads
 * an unprotected parent, and the walk stops at the first link.
 */
export async function readsProtectedFolder(requested: string | undefined, home: string = homedir()): Promise<boolean> {
  const candidate = requested !== undefined && isWorkingDirectory(requested) ? requested : home;
  if (isPrivacyProtected(candidate, home)) return true;
  let prefix = "";
  for (const part of candidate.split("/").filter(Boolean)) {
    prefix += `/${part}`;
    try { if ((await lstat(prefix)).isSymbolicLink()) return true; } catch { return false; /* missing: the session falls back to home */ }
  }
  return false;
}

// ---------------------------------------------------------------------------------------------
// Saved sessions

/** pi's own session bucket for a folder (`getDefaultSessionDir`): `<agentDir>/sessions/--<cwd with / as ->--`. */
export function piSessionBucket(cwd: string, agentDir: string): string {
  return join(resolve(agentDir), "sessions", `--${resolve(cwd).replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`);
}

/** pi's environment override of the session folder (`PI_CODING_AGENT_SESSION_DIR`). */
export const PI_SESSION_DIR_ENV = "PI_CODING_AGENT_SESSION_DIR";

/** pi's path rule for a session folder: `~` expands to home, and a relative path is relative to the session's folder
 * (terminal pi's process cwd), never to the harness's own directory. */
function expandHome(path: string, home: string, cwd: string): string {
  if (path === "~") return home;
  return path.startsWith("~/") ? join(home, path.slice(2)) : resolve(cwd, path);
}

export interface SessionDirectoryOptions {
  /** The `sessionDir` the session's settings name (global settings, or a trusted project's). */
  configured?: string;
  /** pi's environment; consulted only for the user's own agent dir (never for a test fixture). */
  env?: NodeJS.ProcessEnv;
  /** The agent dir is pi's default one (no override): the environment override applies like in terminal pi. */
  defaultAgentDir?: boolean;
  home?: string;
}

/**
 * Where a full session's file goes, as terminal pi decides it: `PI_CODING_AGENT_SESSION_DIR`, else the settings'
 * `sessionDir`, else pi's bucket for the folder under the agent dir. `pi --resume` in that folder finds it there.
 */
export function sessionDirectory(cwd: string, agentDir: string, options: SessionDirectoryOptions = {}): string {
  const home = options.home ?? homedir();
  const env = options.defaultAgentDir ? options.env?.[PI_SESSION_DIR_ENV] : undefined;
  if (env) return expandHome(env, home, cwd);
  if (options.configured) return expandHome(options.configured, home, cwd);
  return piSessionBucket(cwd, agentDir);
}

/**
 * The session manager of a full session: a new pi session file (written once the first message exists), or, for an
 * explicit "continue my last pi session", the folder's most recent one (`resumed` when it had history; pi starts a
 * new file when there is none).
 */
export function openFullSession(cwd: string, directory: string, resume: boolean): { manager: SessionManager; resumed: boolean } {
  if (!resume) return { manager: SessionManager.create(cwd, directory), resumed: false };
  const manager = SessionManager.continueRecent(cwd, directory);
  return { manager, resumed: manager.getEntryCount() > 0 };
}

// "Continue my last pi session" (EN/DE). Both a continuation verb and an explicit pi session are required, so a
// question about a session ("what did my last pi session do?") or another verb never resumes one.
const PI_SESSION = /(?<![\p{L}\p{N}_])(?:my|the|meine[nmrs]?|die|der|den)\s+(?:(?:last|previous|latest|most recent|letzte[nmrs]?|vorherige[nmrs]?|neueste[nmrs]?)\s+)?pi(?:[-\s]?)(?:session|sitzung|conversation|chat)(?![\p{L}\p{N}_])/iu;
const CONTINUE = /(?<![\p{L}\p{N}_])(?:continue|resume|reopen|pick up|carry on|go on|go back to|back to|weiter\p{L}*|fortsetz\p{L}*|fortführ\p{L}*|fortfuehr\p{L}*|fort|zurück zu|zurueck zu)(?![\p{L}\p{N}_])/iu;

/** An explicit request to continue the folder's most recent pi session ("continue my last pi session", "mach mit der letzten pi-Session weiter"). */
export function continuesLastSession(text: string): boolean {
  const bounded = text.slice(0, 600).normalize("NFC").replace(/[’‘]/g, "'");
  return PI_SESSION.test(bounded) && CONTINUE.test(bounded);
}

// ---------------------------------------------------------------------------------------------
// System prompt variant

/**
 * A full thread's system prompt, chosen by its first turn and kept by its follow-ups (prompt caching): `lean`
 * (PI_OS_SYSTEM_PROMPT) for quick asks, `coding` (pi's own coding prompt with project context) otherwise.
 */
export type FullPromptVariant = "lean" | "coding";

export interface PromptVariantInput {
  /** Auto's decided tier for the first turn; without it (a manual model) the classification's own tier counts. */
  tier?: Tier;
  /** The first turn's (fused) classification; computed from the words when absent. */
  classification?: Classification;
  surface?: SurfaceClass;
  /** The thread continues a saved pi session (always the coding prompt it ran on). */
  resume?: boolean;
}

/**
 * Quick and fast lanes (and short general questions on a manually chosen model) keep the lean prompt; standard, deep
 * and max, every coding request, a pi command ("/…") and a continued pi session get pi's coding prompt with project
 * context.
 */
export function fullPromptVariant(text: string, input: PromptVariantInput = {}): FullPromptVariant {
  // A pi command (`/skill:…`, a prompt template, an extension command) runs on pi's own prompt, as in terminal pi.
  if (input.resume || text.trim().startsWith("/")) return "coding";
  const classification = input.classification ?? classifyUtterance(text, input.surface ? { surface: input.surface } : {});
  if (classification.intent === "code") return "coding";
  const tier = input.tier ?? intrinsicTier(classification);
  return tier === "instant" || tier === "quick" || tier === "fast" ? "lean" : "coding";
}
