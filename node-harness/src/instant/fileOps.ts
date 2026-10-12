import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { accessSync, constants, realpathSync, statSync } from "node:fs";
import { lstat, realpath } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, delimiter, isAbsolute, join } from "node:path";
import { FILE_OP_LIMITS, type FileOpOutcome } from "../contracts/actions.js";
import { isAbsoluteHostPath } from "../contracts/attachments.js";
import { truncate } from "./format.js";

/**
 * Staged file operations and their executor (DESIGN6 §4–§5 with BUILD6): what a file command's `fileOp {opId}` runs.
 *
 *   - Plans: one op as argv with an absolute binary, `--` always, never `-f` or `-p`: `/bin/rm -r -- <abs>` (a
 *     directory on disk), `/bin/rm -- <abs>` (a file or symlink), `/bin/mkdir -- <abs>`, `/usr/bin/touch -- <abs>`,
 *     `/bin/cp -R -n -- <abs> <destDir>/<name>`, `/bin/mv -n -- <abs> <destDir>/<name>`. dcg reviews the same argv
 *     shell-quoted with the bare binary name.
 *   - FileOpStore: ops staged for one take (takeId, contextId), single-use, 2 minutes. Staging reads the source's
 *     identity (device, inode, mtime, kind) at once and never blocks the decision on it (a Desktop item may raise the
 *     privacy prompt once); the run awaits it. Running one op of a take drops the take's other ops (the rest of a
 *     "which one?" list), and a newer take's final in the same context drops the older takes' ops there.
 *   - runFileOp (POST /fileops/run): expiry → still on → safety rules (as named and through real folders) → identity
 *     unchanged → target free → dcg's review exactly as Tom's pi bridge asks it (`~/.pi/agent/extensions/dcg-guard.ts`)
 *     → identity unchanged again (the dialog may have been open for minutes) → the argv in its own process group,
 *     within the run's budget → the effect verified. Every failure fails closed.
 *   - Safety (§4.1): only paths that are not the shown folder or one of its ancestors, not the home folder, its
 *     standard folders or ~/Library, not `/` or one of its direct children, a volume root, a system root (`/System`,
 *     `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/etc`, `/var`, `/tmp`, `/dev`, `/cores`), `/Applications` or
 *     `/opt` except inside the user's temp folder, nothing under `/Users` but the user's own home, and never a path
 *     with a hidden component (`~/.Trash`).
 *
 * Logs are content-free: the caller's `log` gets the op kind, the outcome, dcg's verdict and the time, never a name,
 * path, command or dcg reason. User copy (`line`) is in the take's language.
 */

export type FileOpKind = "delete" | "create" | "copy" | "move" | "rename";

/** What the user copy names (display only; the take's language). */
export interface FileOpWords {
  german: boolean;
  /** The item acted on (create: the new name). */
  name: string;
  /** rename: the new name; copy: the copy's name. */
  newName?: string;
  /** copy/move: the destination as shown ("Dokumente", "„Archiv“"). */
  dest?: string;
  /** copy next to the item ("dupliziere"). */
  duplicate?: boolean;
  /** create: a folder (else a file). */
  folder?: boolean;
}

export interface FileOpPlan {
  kind: FileOpKind;
  /** argv with an absolute binary first. */
  argv: readonly string[];
  /** The folder the take shows: dcg's `cwd` and the process's. */
  cwd: string;
  /** The existing item (absent for create). */
  source?: string;
  /**
   * The source is a directory on disk — a folder or a package (`.rtfd`, `.key`, `.photoslibrary`) — so `rm -r`
   * (checked against its identity before a delete runs).
   */
  sourceDir?: boolean;
  /** What exists afterwards (create, copy, move, rename); it must not exist before. */
  target?: string;
  /** create: mkdir (else touch). */
  targetDir?: boolean;
  words: FileOpWords;
}

export const FILE_OPS = Object.freeze({
  /** A staged op runs within this long (DESIGN6 §4.4). */
  ttlMs: 2 * 60_000,
  /** Staged ops kept (oldest out). */
  maxOps: 64,
  /** dcg's review, its dialog included (the pi bridge's 140 s). */
  dcgTimeoutMs: 140_000,
  /** dcg's stdout cap (the pi bridge's 1 MB). */
  maxDcgOutput: 1024 * 1024,
  /**
   * The whole run — checks, dcg's review and the op — answers within this long: the host waits 180 s (FILE_OP_LIMITS
   * .hostTimeoutMs), and the 10 s left cover the checks around the op and the answer itself.
   */
  runBudgetMs: 170_000,
  /**
   * The op gets what dcg's review left of the run's budget (a large folder copy may take a while), never less than
   * this: a review that took its full 140 s still leaves the op 30 s within the budget.
   */
  minExecMs: 30_000,
});

export const BINARIES = Object.freeze({ rm: "/bin/rm", mkdir: "/bin/mkdir", touch: "/usr/bin/touch", cp: "/bin/cp", mv: "/bin/mv" });

// ---------------------------------------------------------------------------------------------
// Plans

/** A child of `dir` ("/" has no trailing separator to add). */
export function childPath(dir: string, name: string): string {
  return dir === "/" ? `/${name}` : `${dir}/${name}`;
}

/** The folder a path is in ("/" for a top-level item). */
export function parentPath(path: string): string {
  const at = path.lastIndexOf("/");
  return at <= 0 ? "/" : path.slice(0, at);
}

export interface PlanItem { path: string; isDirectory: boolean }

/**
 * `rm -r` for a directory on disk (a package is one: the caller passes `isDirectory` for it, and dcg reviews `rm -r`
 * with its own dialog), `rm` for a file or symlink.
 */
export function deletePlan(item: PlanItem, shown: string, words: FileOpWords): FileOpPlan {
  const argv = item.isDirectory ? [BINARIES.rm, "-r", "--", item.path] : [BINARIES.rm, "--", item.path];
  return { kind: "delete", argv, cwd: shown, source: item.path, sourceDir: item.isDirectory, words };
}

export function createPlan(folder: string, name: string, isFolder: boolean, words: FileOpWords): FileOpPlan {
  const target = childPath(folder, name);
  const argv = isFolder ? [BINARIES.mkdir, "--", target] : [BINARIES.touch, "--", target];
  return { kind: "create", argv, cwd: folder, target, targetDir: isFolder, words: { ...words, folder: isFolder } };
}

export function copyPlan(item: PlanItem, destDir: string, targetName: string, shown: string, words: FileOpWords): FileOpPlan {
  const target = childPath(destDir, targetName);
  return { kind: "copy", argv: [BINARIES.cp, "-R", "-n", "--", item.path, target], cwd: shown, source: item.path, sourceDir: item.isDirectory, target, words };
}

export function movePlan(item: PlanItem, destDir: string, shown: string, words: FileOpWords): FileOpPlan {
  const target = childPath(destDir, basename(item.path));
  return { kind: "move", argv: [BINARIES.mv, "-n", "--", item.path, target], cwd: shown, source: item.path, sourceDir: item.isDirectory, target, words };
}

export function renamePlan(item: PlanItem, newName: string, shown: string, words: FileOpWords): FileOpPlan {
  const target = childPath(parentPath(item.path), newName);
  return { kind: "rename", argv: [BINARIES.mv, "-n", "--", item.path, target], cwd: shown, source: item.path, sourceDir: item.isDirectory, target, words };
}

/** A file or symlink delete: dcg allows `rm` without asking, so pi-os asks first (BUILD6 §2). */
export function needsOwnConfirm(plan: FileOpPlan): boolean {
  return plan.kind === "delete" && plan.sourceDir !== true;
}

const SHELL_SAFE = /^[A-Za-z0-9_@%+=:,./-]+$/;

/** POSIX single quotes when needed ("/Users/x/my test" → '/Users/x/my test'). */
export function shellQuote(arg: string): string {
  return arg.length > 0 && SHELL_SAFE.test(arg) ? arg : `'${arg.replace(/'/g, "'\\''")}'`;
}

/** The command dcg reviews: the same argv, shell-quoted, with the bare binary name ("rm -r -- /Users/x/Desktop/test"). */
export function reviewCommand(argv: readonly string[]): string {
  const [binary = "", ...args] = argv;
  return [basename(binary), ...args].map(shellQuote).join(" ");
}

// ---------------------------------------------------------------------------------------------
// New names (create, rename; DESIGN6 §3)

export type NameProblem = "empty" | "separator" | "dot" | "hidden" | "control" | "too_long";

/**
 * A new name must be one path component: no "/", NUL or control character, not "." or "..", no leading "." (a hidden
 * item is never shown again), at most 255 UTF-8 bytes.
 */
export function nameProblem(name: string): NameProblem | null {
  if (!name.trim()) return "empty";
  if (name.includes("/")) return "separator";
  if (name === "." || name === "..") return "dot";
  if (name.startsWith(".")) return "hidden";
  if (/[\u0000-\u001f\u007f-\u009f\u{2028}\u{2029}]/u.test(name)) return "control";
  if (Buffer.byteLength(name, "utf8") > 255) return "too_long";
  return null;
}

// ---------------------------------------------------------------------------------------------
// Safety (DESIGN6 §4.1)

export type PathProblem =
  | "invalid" | "root" | "top_level" | "home" | "other_user" | "shown_folder" | "standard_folder" | "system" | "volume_root" | "trash" | "hidden";

export interface PathGuard {
  home: string;
  /** The home folder's real path when it differs (a symlinked home): it is the home folder too. */
  realHome?: string;
  /** The user's temp folder (and its real path): the only place below a system root an op may touch. */
  temp: readonly string[];
}

/** The home folder's own folders: never a target themselves (an item inside them is fine). */
const STANDARD_FOLDERS = new Set(["desktop", "documents", "downloads", "library", "pictures", "music", "movies", "public", "applications", "sites"]);
/** Top-level folders nothing inside of is a target: the system's, the apps' (`/Applications`) and third-party tools' (`/opt`). */
const SYSTEM_ROOTS = new Set(["system", "library", "usr", "bin", "sbin", "private", "etc", "var", "tmp", "dev", "cores", "applications", "opt"]);

/** Compared as the file system compares (NFC, case-insensitive APFS/HFS+). */
function pathKey(path: string): string {
  return path.normalize("NFC").toLowerCase();
}

/** A folder without trailing slashes ("/Users/x/" is "/Users/x"; "/" stays). */
function withoutTrailingSlash(path: string): string {
  return path.replace(/\/+$/u, "") || "/";
}

/** The home folder as given (trailing slashes off) and, read once here, its real path when that differs. */
export function defaultPathGuard(home = homedir()): PathGuard {
  const given = withoutTrailingSlash(home);
  let realHome: string | undefined;
  try {
    const real = realpathSync(given);
    if (real !== given) realHome = real;
  } catch {
    // No such home: only the given path is compared.
  }
  const temp = new Set<string>();
  try {
    const dir = tmpdir();
    temp.add(dir);
    temp.add(realpathSync(dir));
  } catch {
    // No temp folder: nothing below a system root is allowed.
  }
  return { home: given, ...(realHome ? { realHome } : {}), temp: [...temp] };
}

/**
 * Why `path` may not be acted on, or null. `shown`: the folder the take shows (never itself or an ancestor of it).
 * Lexical: runFileOp checks the real path through the folders on the way as well (`realPathProblem`).
 */
export function pathProblem(path: string, guard: PathGuard, shown?: string): PathProblem | null {
  if (!isAbsoluteHostPath(path)) return "invalid";
  const key = pathKey(path);
  if (key === "/") return "root";
  const homes = [guard.home, guard.realHome].flatMap((home) => (home ? [pathKey(withoutTrailingSlash(home))] : []));
  if (homes.some((home) => key === home || home.startsWith(`${key}/`))) return "home";
  if (shown !== undefined) {
    const folder = pathKey(shown);
    if (key === folder || folder.startsWith(`${key}/`)) return "shown_folder";
  }
  const parts = key.slice(1).split("/");
  if (parts.some((part) => part === ".trash" || part === ".trashes")) return "trash";
  if (parts.some((part) => part.startsWith("."))) return "hidden";
  if (parts[0] === "volumes" && parts.length <= 2) return "volume_root";
  const home = homes.find((candidate) => key.startsWith(`${candidate}/`));
  if (home !== undefined) {
    const rest = key.slice(home.length + 1).split("/");
    if (rest.length === 1 && STANDARD_FOLDERS.has(rest[0]!)) return "standard_folder";
    return rest[0] === "library" ? "system" : null;
  }
  if (guard.temp.some((dir) => key.startsWith(`${pathKey(dir)}/`))) return null;
  // "delete Applications" in a Finder window on the startup disk: no direct child of "/", nothing in another user's
  // home or /Users/Shared, nothing under a system root, /Applications or /opt.
  if (parts.length === 1) return "top_level";
  if (parts[0] === "users") return "other_user";
  return SYSTEM_ROOTS.has(parts[0]!) ? "system" : null;
}

/** The first problem of a plan's source and target (each checked against the shown folder too). */
export function planProblem(plan: FileOpPlan, guard: PathGuard): PathProblem | null {
  for (const path of [plan.source, plan.target]) {
    if (path === undefined) continue;
    const problem = pathProblem(path, guard, plan.cwd);
    if (problem) return problem;
  }
  if (plan.target !== undefined && plan.source !== undefined) {
    // Never into itself ("kopiere test nach test/sub").
    const source = pathKey(plan.source);
    if (pathKey(plan.target).startsWith(`${source}/`)) return "invalid";
  }
  return isAbsoluteHostPath(plan.cwd) || plan.cwd === "/" ? null : "invalid";
}

export type RealPathFn = (path: string) => Promise<string>;

/**
 * `planProblem` on the real paths: each path's folder through its symlinks ("~/Desktop/Link" to /Applications is
 * /Applications), the item itself as it is (a symlink is acted on as a link). Null when every real path passes too;
 * "unreadable" when a folder cannot be resolved.
 */
export async function realPathProblem(plan: FileOpPlan, guard: PathGuard, resolve: RealPathFn = realpath): Promise<PathProblem | "unreadable" | null> {
  try {
    const shown = await resolve(plan.cwd);
    for (const path of [plan.source, plan.target]) {
      if (path === undefined) continue;
      const real = childPath(await resolve(parentPath(path)), basename(path));
      if (real === path && shown === plan.cwd) continue;
      const problem = pathProblem(real, guard, shown);
      if (problem) return problem;
    }
    return null;
  } catch {
    return "unreadable";
  }
}

// ---------------------------------------------------------------------------------------------
// Identity (DESIGN6 §4.4: an op whose source changed since staging is refused)

export interface SourceIdentity {
  dev: string;
  ino: string;
  mtimeNs: string;
  kind: "dir" | "file" | "symlink" | "other";
}

export type IdentityRead = { ok: true; identity: SourceIdentity } | { ok: false; code: "gone" | "unreadable" };

export type LstatFn = (path: string) => Promise<{ dev: bigint; ino: bigint; mtimeNs: bigint; isDirectory(): boolean; isFile(): boolean; isSymbolicLink(): boolean }>;

const defaultLstat: LstatFn = (path) => lstat(path, { bigint: true });

/** lstat (a symlink is the link itself). Never rejects. */
export async function identityOf(path: string, read: LstatFn = defaultLstat): Promise<IdentityRead> {
  try {
    const stats = await read(path);
    const kind = stats.isSymbolicLink() ? "symlink" : stats.isDirectory() ? "dir" : stats.isFile() ? "file" : "other";
    return { ok: true, identity: { dev: String(stats.dev), ino: String(stats.ino), mtimeNs: String(stats.mtimeNs), kind } };
  } catch (error) {
    const code = (error as { code?: unknown } | null)?.code;
    return { ok: false, code: code === "ENOENT" || code === "ENOTDIR" ? "gone" : "unreadable" };
  }
}

function sameIdentity(a: SourceIdentity, b: SourceIdentity): boolean {
  return a.dev === b.dev && a.ino === b.ino && a.mtimeNs === b.mtimeNs && a.kind === b.kind;
}

// ---------------------------------------------------------------------------------------------
// The store

export interface StagedFileOp {
  readonly opId: string;
  readonly plan: FileOpPlan;
  readonly takeId?: string;
  readonly contextId?: string;
  readonly stagedAt: number;
  /** The source's identity, read when the op was staged. */
  readonly snapshot?: Promise<IdentityRead>;
}

export interface FileOpStoreOptions {
  ttlMs?: number;
  maxOps?: number;
  /** Epoch ms (default Date.now). */
  clock?: () => number;
  lstat?: LstatFn;
  /** Tests: deterministic ids (must match FILE_OP_ID). */
  mintId?: () => string;
}

export type FileOpClaim = { ok: true; op: StagedFileOp } | { ok: false; op?: StagedFileOp };

/** Ops staged for takes, in memory only (never logged, never written to disk). */
export class FileOpStore {
  private readonly ops = new Map<string, StagedFileOp>();
  private readonly ttlMs: number;
  private readonly maxOps: number;
  private readonly clock: () => number;
  readonly lstat: LstatFn;
  private readonly mintId: () => string;

  constructor(options: FileOpStoreOptions = {}) {
    this.ttlMs = options.ttlMs ?? FILE_OPS.ttlMs;
    this.maxOps = options.maxOps ?? FILE_OPS.maxOps;
    this.clock = options.clock ?? (() => Date.now());
    this.lstat = options.lstat ?? defaultLstat;
    this.mintId = options.mintId ?? (() => `op_${randomBytes(18).toString("base64url")}`);
  }

  get size(): number {
    return this.ops.size;
  }

  /**
   * Stages `plans` for one take and returns their ids in order. Each source's identity is read now (one read per
   * path), without waiting for it.
   */
  stage(plans: readonly FileOpPlan[], binding: { takeId?: string; contextId?: string } = {}): string[] {
    const at = this.clock();
    const reads = new Map<string, Promise<IdentityRead>>();
    return plans.map((plan) => {
      let opId = this.mintId();
      while (this.ops.has(opId)) opId = this.mintId();
      const snapshot = plan.source === undefined ? undefined
        : reads.get(plan.source) ?? identityOf(plan.source, this.lstat);
      if (plan.source !== undefined && snapshot) reads.set(plan.source, snapshot);
      this.ops.set(opId, {
        opId, plan, stagedAt: at,
        ...(binding.takeId ? { takeId: binding.takeId } : {}), ...(binding.contextId ? { contextId: binding.contextId } : {}),
        ...(snapshot ? { snapshot } : {}),
      });
      while (this.ops.size > this.maxOps) {
        const oldest = this.ops.keys().next().value;
        if (oldest === undefined) break;
        this.ops.delete(oldest);
      }
      return opId;
    });
  }

  /**
   * Single-use: the op is gone after this, whatever the answer. `ok: false` for an unknown or expired op. A claimed op
   * also takes its take's other ops with it (the other rows of a "which one?" list are no longer what the user means).
   */
  claim(opId: string): FileOpClaim {
    const op = this.ops.get(opId);
    if (!op) return { ok: false };
    this.ops.delete(opId);
    const age = this.clock() - op.stagedAt;
    if (age < 0 || age > this.ttlMs) return { ok: false, op };
    const sibling = (other: StagedFileOp): boolean => (op.takeId !== undefined
      ? other.takeId === op.takeId
      : op.contextId !== undefined && other.takeId === undefined && other.contextId === op.contextId);
    for (const [id, other] of this.ops) if (sibling(other)) this.ops.delete(id);
    return { ok: true, op };
  }

  /**
   * A newer take's final in `contextId`: the ops older takes staged there go (their list or confirm was replaced).
   * The same take's ops stay — a voice take's second final (Phase B) must not take the first one's act away.
   */
  supersede(binding: { takeId?: string; contextId?: string }): void {
    const { takeId, contextId } = binding;
    if (takeId === undefined || contextId === undefined) return;
    for (const [id, op] of this.ops) if (op.contextId === contextId && op.takeId !== takeId) this.ops.delete(id);
  }

  /** Staged ops of one take (tests, diagnostics). */
  forTake(takeId: string): StagedFileOp[] {
    return [...this.ops.values()].filter((op) => op.takeId === takeId);
  }

  clear(): void {
    this.ops.clear();
  }
}

// ---------------------------------------------------------------------------------------------
// dcg (the pi bridge's protocol, ~/.pi/agent/extensions/dcg-guard.ts)

export type DcgVerdict = { kind: "allow" } | { kind: "deny"; reason: string } | { kind: "error" };

function isExecutable(path: string): boolean {
  try {
    if (!statSync(path).isFile()) return false;
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * The dcg executable: `PI_OS_DCG` when set (absolute and executable, else none: an explicit choice never falls back),
 * else `~/.local/bin/dcg`, else `dcg` on `PATH` (absolute entries only). Null when none resolves.
 */
export function resolveDcg(env: NodeJS.ProcessEnv = process.env, home = homedir()): string | null {
  const explicit = env.PI_OS_DCG;
  if (explicit !== undefined && explicit.trim() !== "") return isAbsolute(explicit) && isExecutable(explicit) ? explicit : null;
  const local = join(home, ".local", "bin", "dcg");
  if (isExecutable(local)) return local;
  for (const dir of (env.PATH ?? "").split(delimiter)) {
    if (!dir || !isAbsolute(dir)) continue;
    const candidate = join(dir, "dcg");
    if (isExecutable(candidate)) return candidate;
  }
  return null;
}

/** One line of dcg's reason (no control characters, ≤ 200). */
function oneLine(reason: string): string {
  return truncate(reason.replace(/[\u0000-\u001f\u007f-\u009f\u{2028}\u{2029}]+/gu, " ").replace(/\s+/gu, " ").trim(), FILE_OP_LIMITS.maxReason) || "Blocked by DCG";
}

export interface DcgOptions {
  timeoutMs?: number;
  maxOutput?: number;
  signal?: AbortSignal;
}

/**
 * Asks dcg exactly as the pi bridge does: `dcg --desktop-review --no-color --agent pi` in `cwd`, no shell, the request
 * as JSON on stdin. Allowed only on exit 0 with `dcg_verdict: "allow"`; `hookSpecificOutput.permissionDecision: "deny"`
 * is a denial with its reason; anything else (spawn error, timeout, too much output, garbage, an abort) fails closed.
 * stderr is drained and never read.
 */
export function reviewWithDcg(dcg: string, command: string, cwd: string, options: DcgOptions = {}): Promise<DcgVerdict> {
  const timeoutMs = options.timeoutMs ?? FILE_OPS.dcgTimeoutMs;
  const maxOutput = options.maxOutput ?? FILE_OPS.maxDcgOutput;
  const signal = options.signal;
  return new Promise((resolve) => {
    let settled = false;
    let stdout = "";
    let timer: NodeJS.Timeout | undefined;
    let child: ChildProcess | undefined;
    const kill = (): void => {
      try {
        child?.kill("SIGKILL");
      } catch {
        // Already gone.
      }
    };
    const onAbort = (): void => {
      kill();
      finish({ kind: "error" });
    };
    const finish = (verdict: DcgVerdict): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      resolve(verdict);
    };
    if (signal?.aborted) return finish({ kind: "error" });
    try {
      child = spawn(dcg, ["--desktop-review", "--no-color", "--agent", "pi"], { cwd, shell: false, stdio: ["pipe", "pipe", "pipe"] });
    } catch {
      return finish({ kind: "error" });
    }
    timer = setTimeout(() => {
      kill();
      finish({ kind: "error" });
    }, timeoutMs);
    signal?.addEventListener("abort", onAbort, { once: true });
    child.on("error", () => finish({ kind: "error" }));
    child.stdin?.on("error", () => finish({ kind: "error" }));
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      if (stdout.length > maxOutput) {
        kill();
        finish({ kind: "error" });
      }
    });
    child.stderr?.on("data", () => {});
    child.on("close", (code) => {
      try {
        const result = JSON.parse(stdout) as { dcg_verdict?: unknown; hookSpecificOutput?: { permissionDecision?: unknown; permissionDecisionReason?: unknown } } | null;
        if (code === 0 && result?.dcg_verdict === "allow") return finish({ kind: "allow" });
        if (result?.hookSpecificOutput?.permissionDecision === "deny") {
          const reason = result.hookSpecificOutput.permissionDecisionReason;
          return finish({ kind: "deny", reason: oneLine(typeof reason === "string" && reason ? reason : "Blocked by DCG") });
        }
        finish({ kind: "error" });
      } catch {
        finish({ kind: "error" });
      }
    });
    if (!child.stdin || !child.stdout) {
      kill();
      return finish({ kind: "error" });
    }
    child.stdin.end(JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd, dcg_explicit_verdict: true }));
  });
}

// ---------------------------------------------------------------------------------------------
// Running an op (POST /fileops/run)

export type DcgLogVerdict = "allow" | "deny" | "error" | "none";

export interface FileOpResult {
  outcome: FileOpOutcome;
  /** One line of user copy (≤ 300). */
  line: string;
  verdict: DcgLogVerdict;
}

/** Content-free log fields (perf line): op kind, outcome, dcg's verdict. */
export interface FileOpLogFields {
  op: FileOpKind | "unknown";
  outcome: FileOpOutcome;
  verdict: DcgLogVerdict;
}

export interface FileOpRunOptions {
  /** The dcg executable now (resolveDcg), or null: nothing runs. */
  dcg: () => string | null;
  /** File commands are still on (a full pi session). Default: on. */
  enabled?: () => boolean;
  guard?: PathGuard;
  signal?: AbortSignal;
  dcgTimeoutMs?: number;
  /** The op's own limit (default: what dcg's review left of FILE_OPS.runBudgetMs, at least FILE_OPS.minExecMs). */
  execTimeoutMs?: number;
  /** Monotonic ms for the log and the run's budget (default performance.now). */
  clock?: () => number;
  /** Real paths of the folders on the way (default fs.realpath). */
  realpath?: RealPathFn;
  log?: (fields: FileOpLogFields, ms: number) => void;
}

interface ExecResult {
  /** The exit code; -1: it did not run or was killed. */
  code: number;
  /** The time limit stopped it: part of the op may have happened. */
  killed: boolean;
}

/** SIGKILL to the op's whole process group (`mv` across volumes runs a `cp` of its own), else to the op itself. */
function killGroup(child: ChildProcess): void {
  try {
    if (child.pid === undefined) throw new Error("no pid");
    process.kill(-child.pid, "SIGKILL");
  } catch {
    try {
      child.kill("SIGKILL");
    } catch {
      // Already gone.
    }
  }
}

/**
 * Runs one argv (absolute binary, no shell, a fixed minimal environment) as the leader of its own process group, so the
 * time limit stops everything it started and a harness stop never cuts it off half-way. Output is discarded.
 */
function execArgv(argv: readonly string[], cwd: string, timeoutMs: number): Promise<ExecResult> {
  const [binary, ...args] = argv;
  if (!binary || !isAbsolute(binary)) return Promise.resolve({ code: -1, killed: false });
  return new Promise((resolve) => {
    let killed = false;
    let settled = false;
    let timer: NodeJS.Timeout | undefined;
    const done = (code: number): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({ code, killed });
    };
    let child: ChildProcess;
    try {
      child = spawn(binary, args, {
        cwd, detached: true, shell: false, stdio: "ignore", windowsHide: true, env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LC_ALL: "C" },
      });
    } catch {
      return done(-1);
    }
    timer = setTimeout(() => {
      killed = true;
      killGroup(child);
    }, timeoutMs);
    child.on("error", () => done(-1));
    child.on("close", (code) => done(typeof code === "number" ? code : -1));
  });
}

/** The op did what it says: the source is gone (delete, move, rename) and the target is there with the right kind. */
async function verified(plan: FileOpPlan, read: LstatFn): Promise<boolean> {
  const source = plan.source === undefined ? undefined : await identityOf(plan.source, read);
  const target = plan.target === undefined ? undefined : await identityOf(plan.target, read);
  switch (plan.kind) {
    case "delete":
      return source?.ok === false && source.code === "gone";
    case "create":
      return target?.ok === true && target.identity.kind === (plan.targetDir ? "dir" : "file");
    case "copy":
      return target?.ok === true && source?.ok === true;
    case "move":
    case "rename":
      return target?.ok === true && source?.ok === false && source.code === "gone";
  }
}

/**
 * POST /fileops/run: the staged op, at most once. Never throws; every failure is an outcome with a line. The host may
 * disconnect while dcg's dialog is open (`signal`): dcg is killed and nothing runs.
 */
export async function runFileOp(store: FileOpStore, opId: string, options: FileOpRunOptions): Promise<FileOpResult> {
  const clock = options.clock ?? (() => performance.now());
  const started = clock();
  const read = store.lstat;
  let kind: FileOpKind | "unknown" = "unknown";
  const finish = (outcome: FileOpOutcome, line: string, verdict: DcgLogVerdict = "none"): FileOpResult => {
    const result = { outcome, line: truncate(line, FILE_OP_LIMITS.maxLine), verdict };
    try {
      options.log?.({ op: kind, outcome, verdict }, clock() - started);
    } catch {
      // Logging never fails a run.
    }
    return result;
  };
  try {
    const claimed = store.claim(opId);
    if (!claimed.ok) return finish("expired", expiredLine(claimed.op?.plan.words, "time"));
    const { plan, snapshot } = claimed.op;
    kind = plan.kind;
    const words = plan.words;
    if (options.enabled && !options.enabled()) return finish("failed", failedLine(plan, "off"));
    const guard = options.guard ?? defaultPathGuard();
    if (planProblem(plan, guard)) return finish("failed", failedLine(plan, "protected"));
    /** The safety rules on the real paths (a symlinked folder on the way), before dcg's review and again before the op. */
    const realProblem = async (): Promise<FailedWhy | null> => {
      const problem = await realPathProblem(plan, guard, options.realpath);
      return problem === null ? null : problem === "unreadable" ? "unreadable" : "protected";
    };

    // The source as staged: still there, still the same item.
    let staged: SourceIdentity | undefined;
    if (plan.source !== undefined) {
      const before = snapshot ? await snapshot : await identityOf(plan.source, read);
      if (!before.ok) return before.code === "gone" ? finish("expired", expiredLine(words, "gone")) : finish("failed", failedLine(plan, "unreadable"));
      staged = before.identity;
      // A delete runs rm with or without -r as staged: the item must still be of that kind.
      if (plan.kind === "delete" && (staged.kind === "dir") !== (plan.sourceDir === true)) return finish("expired", expiredLine(words, "changed"));
      const now = await identityOf(plan.source, read);
      if (!now.ok) return now.code === "gone" ? finish("expired", expiredLine(words, "gone")) : finish("failed", failedLine(plan, "unreadable"));
      if (!sameIdentity(staged, now.identity)) return finish("expired", expiredLine(words, "changed"));
    }
    if (plan.target !== undefined) {
      const target = await identityOf(plan.target, read);
      if (target.ok) return finish("failed", failedLine(plan, "exists"));
      if (target.code !== "gone") return finish("failed", failedLine(plan, "unreadable"));
    }
    const real = await realProblem();
    if (real) return finish("failed", failedLine(plan, real));

    // dcg reviews every op (BUILD6 §3): missing or failing, nothing runs.
    const dcg = options.dcg();
    if (!dcg) return finish("failed", failedLine(plan, "no_dcg"));
    if (options.signal?.aborted) return finish("failed", failedLine(plan, "aborted"));
    const verdict = await reviewWithDcg(dcg, reviewCommand(plan.argv), plan.cwd, {
      ...(options.dcgTimeoutMs !== undefined ? { timeoutMs: options.dcgTimeoutMs } : {}), ...(options.signal ? { signal: options.signal } : {}),
    });
    if (options.signal?.aborted) return finish("failed", failedLine(plan, "aborted"), verdict.kind);
    if (verdict.kind === "deny") return finish("denied", deniedLine(plan, verdict.reason), "deny");
    if (verdict.kind !== "allow") return finish("failed", failedLine(plan, "dcg_error"), "error");

    // The dialog may have been open for minutes: the same item, the target still free.
    if (plan.source !== undefined && staged) {
      const again = await identityOf(plan.source, read);
      if (!again.ok || !sameIdentity(staged, again.identity)) return finish("expired", expiredLine(words, !again.ok && again.code === "gone" ? "gone" : "changed"), "allow");
    }
    if (plan.target !== undefined && (await identityOf(plan.target, read)).ok) return finish("failed", failedLine(plan, "exists"), "allow");
    const realAfter = await realProblem();
    if (realAfter) return finish("failed", failedLine(plan, realAfter), "allow");

    // The host waits 180 s in all: the op gets what the review left of the run's budget, at least FILE_OPS.minExecMs.
    const execMs = options.execTimeoutMs ?? Math.max(FILE_OPS.minExecMs, FILE_OPS.runBudgetMs - (clock() - started));
    const ran = await execArgv(plan.argv, plan.cwd, execMs);
    if (ran.killed) return finish("failed", failedLine(plan, "killed"), "allow");
    if (ran.code === 0 && await verified(plan, read)) return finish("done", doneLine(plan), "allow");
    return finish("failed", failedLine(plan, "op"), "allow");
  } catch {
    return finish("failed", failedLine(undefined, "op"));
  }
}

// ---------------------------------------------------------------------------------------------
// User copy (one line, the take's language)

function q(words: Pick<FileOpWords, "german">, text: string): string {
  const shown = truncate(text, 60);
  return words.german ? `„${shown}“` : `“${shown}”`;
}

const VERBS: Readonly<Record<FileOpKind, { de: string; en: string; gerund: string }>> = {
  delete: { de: "Löschen", en: "delete", gerund: "deleting" },
  create: { de: "Erstellen", en: "create", gerund: "creating" },
  copy: { de: "Kopieren", en: "copy", gerund: "copying" },
  move: { de: "Verschieben", en: "move", gerund: "moving" },
  rename: { de: "Umbenennen", en: "rename", gerund: "renaming" },
};

export function doneLine(plan: FileOpPlan): string {
  const w = plan.words;
  const name = q(w, w.name);
  switch (plan.kind) {
    case "delete":
      return w.german ? `${name} gelöscht.` : `Deleted ${name}.`;
    case "create":
      return w.german ? `${w.folder ? "Ordner" : "Datei"} ${name} erstellt.` : `Created ${w.folder ? "folder" : "file"} ${name}.`;
    case "copy":
      if (w.duplicate) return w.german ? `${name} dupliziert: ${q(w, w.newName ?? "")}.` : `Duplicated ${name} as ${q(w, w.newName ?? "")}.`;
      return w.german ? `${name} nach ${w.dest ?? ""} kopiert.` : `Copied ${name} to ${w.dest ?? ""}.`;
    case "move":
      return w.german ? `${name} nach ${w.dest ?? ""} verschoben.` : `Moved ${name} to ${w.dest ?? ""}.`;
    case "rename":
      return w.german ? `${name} in ${q(w, w.newName ?? "")} umbenannt.` : `Renamed ${name} to ${q(w, w.newName ?? "")}.`;
  }
}

export function deniedLine(plan: FileOpPlan, reason: string): string {
  const w = plan.words;
  const verb = VERBS[plan.kind];
  return w.german ? `dcg hat das ${verb.de} abgelehnt: ${reason}` : `dcg blocked ${verb.gerund} ${q(w, w.name)}: ${reason}`;
}

type FailedWhy = "op" | "killed" | "exists" | "protected" | "no_dcg" | "dcg_error" | "aborted" | "off" | "unreadable";

export function failedLine(plan: FileOpPlan | undefined, why: FailedWhy): string {
  const w = plan?.words ?? { german: false, name: "" };
  const de = w.german;
  switch (why) {
    case "exists": {
      const taken = q(w, plan?.target ? basename(plan.target) : w.name);
      return de ? `${taken} gibt es dort schon – nichts überschrieben.` : `${taken} already exists there — nothing was overwritten.`;
    }
    case "protected":
      return de ? `pi-os rührt ${q(w, w.name)} nicht an.` : `pi-os won't touch ${q(w, w.name)}.`;
    case "no_dcg":
      return de ? "Kein Befehlswächter (dcg) gefunden – nichts ausgeführt." : "No command guard (dcg) found — nothing ran.";
    case "dcg_error":
      return de ? "dcg konnte den Befehl nicht prüfen – nichts ausgeführt." : "dcg couldn't review the command — nothing ran.";
    case "aborted":
      return de ? "Abgebrochen – nichts ausgeführt." : "Cancelled — nothing ran.";
    case "off":
      return de ? "Datei-Befehle sind aus (keine volle pi-Sitzung) – nichts ausgeführt." : "File commands are off (no full pi session) — nothing ran.";
    case "unreadable":
      return de ? `pi-os kann ${q(w, w.name)} nicht lesen – nichts ausgeführt.` : `pi-os can't read ${q(w, w.name)} — nothing ran.`;
    case "op":
      if (!plan) return "That didn't work.";
      return de ? `${VERBS[plan.kind].de} von ${q(w, w.name)} hat nicht geklappt.` : `Couldn't ${VERBS[plan.kind].en} ${q(w, w.name)}.`;
    case "killed":
      // The time limit stopped it part-way: the user checks the folder.
      if (!plan) return "That was stopped — it may be incomplete.";
      return de ? `${VERBS[plan.kind].de} von ${q(w, w.name)} wurde abgebrochen – möglicherweise unvollständig.`
        : `Stopped ${VERBS[plan.kind].gerund} ${q(w, w.name)} — it may be incomplete.`;
  }
}

export function expiredLine(words: FileOpWords | undefined, why: "time" | "changed" | "gone"): string {
  const de = words?.german === true;
  if (!words || why === "time") return de ? "Abgelaufen – bitte noch einmal sagen." : "That expired — please say it again.";
  const name = q(words, words.name);
  if (why === "gone") return de ? `${name} gibt es nicht mehr.` : `${name} isn't there anymore.`;
  return de ? `${name} hat sich inzwischen geändert – nichts ausgeführt.` : `${name} changed in the meantime — nothing ran.`;
}
