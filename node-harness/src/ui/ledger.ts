import { homedir } from "node:os";
import { parseHostAction } from "../contracts/actions.js";
import type { FileCandidate } from "../contracts/launcher.js";

/**
 * Per-thread file reference ledger (CRITIC C12).
 *
 * Host searches return candidates carrying host-minted tokens. The model only
 * ever sees short refs ("f1", "f2", …) plus a display name and a ~-abbreviated
 * folder; Node maps refs back to tokens when it builds card bindings, so the
 * model can neither write tokens nor point a card at a path. The absolute path
 * is never stored here. Refs are never reused within a ledger, so a stale ref
 * cannot alias a newer file.
 */

export const FILE_LEDGER_CAPACITY = 500;
/** Host tokens live 10 minutes (protocol.md "Launcher routes"); expired refs stop resolving. */
export const FILE_TOKEN_TTL_MS = 10 * 60_000;
export const FILE_REF_PATTERN = /^f[1-9][0-9]{0,8}$/;

export interface FileRef {
  ref: string;
  /** Host token for openFile / revealFile / copyPath. Never shown to the model. */
  token: string;
  name: string;
  /** Containing folder, home-abbreviated ("~/Documents/Finance"). */
  displayDir: string;
  contentType?: string;
  modifiedMs?: number;
  lastUsedMs?: number;
  isDirectory: boolean;
  isPackage: boolean;
}

/** What card validation needs from a ledger. */
export interface FileTokenSource {
  hasToken(token: string): boolean;
}

export interface FileLedgerOptions {
  capacity?: number;
  ttlMs?: number;
  now?: () => number;
  /** Home folder used for "~" abbreviation; defaults to os.homedir(). */
  homeDir?: string;
}

interface Entry { file: FileRef; registeredAt: number }

export class FileLedger implements FileTokenSource {
  private readonly byRef = new Map<string, Entry>();
  private readonly refByToken = new Map<string, string>();
  private readonly capacity: number;
  private readonly ttlMs: number;
  private readonly now: () => number;
  private readonly homeDir: string;
  private next = 1;

  constructor(options: FileLedgerOptions = {}) {
    this.capacity = Math.max(1, options.capacity ?? FILE_LEDGER_CAPACITY);
    this.ttlMs = options.ttlMs ?? FILE_TOKEN_TTL_MS;
    this.now = options.now ?? Date.now;
    this.homeDir = options.homeDir ?? homedir();
  }

  /**
   * Adds host search results and returns their refs in input order. A token
   * that is already live keeps its ref (and its expiry) and counts as recently
   * listed; malformed candidates are skipped. Beyond capacity the least
   * recently listed refs are evicted.
   */
  register(candidates: readonly FileCandidate[]): FileRef[] {
    this.prune();
    const out: FileRef[] = [];
    for (const candidate of candidates) {
      if (!isUsableCandidate(candidate)) continue;
      const known = this.refByToken.get(candidate.token);
      const existing = known === undefined ? undefined : this.byRef.get(known);
      if (existing) {
        // Re-insert so a ref just shown to the model is not the next one evicted.
        this.byRef.delete(existing.file.ref);
        this.byRef.set(existing.file.ref, existing);
        out.push(existing.file);
        continue;
      }
      const file: FileRef = {
        ref: `f${this.next++}`,
        token: candidate.token,
        name: displayText(candidate.name),
        displayDir: displayText(abbreviateDir(candidate.path, this.homeDir)),
        ...(typeof candidate.contentType === "string" ? { contentType: candidate.contentType } : {}),
        ...(isTime(candidate.modifiedMs) ? { modifiedMs: candidate.modifiedMs } : {}),
        ...(isTime(candidate.lastUsedMs) ? { lastUsedMs: candidate.lastUsedMs } : {}),
        isDirectory: candidate.isDirectory === true,
        isPackage: candidate.isPackage === true,
      };
      this.byRef.set(file.ref, { file, registeredAt: this.now() });
      this.refByToken.set(file.token, file.ref);
      out.push(file);
      while (this.byRef.size > this.capacity) this.evictOldest();
    }
    return out;
  }

  /** Live entry for a model-facing ref, or undefined (unknown, evicted or expired). */
  resolve(ref: string): FileRef | undefined {
    if (!FILE_REF_PATTERN.test(ref)) return undefined;
    const entry = this.byRef.get(ref);
    if (!entry) return undefined;
    if (this.expired(entry)) { this.remove(entry.file); return undefined; }
    return entry.file;
  }

  hasToken(token: string): boolean {
    const ref = this.refByToken.get(token);
    return ref !== undefined && this.resolve(ref) !== undefined;
  }

  /** Live entry count. */
  get size(): number {
    this.prune();
    return this.byRef.size;
  }

  clear(): void {
    this.byRef.clear();
    this.refByToken.clear();
  }

  private expired(entry: Entry): boolean {
    return this.now() - entry.registeredAt >= this.ttlMs;
  }

  private prune(): void {
    for (const entry of this.byRef.values()) if (this.expired(entry)) this.remove(entry.file);
  }

  private evictOldest(): void {
    const oldest = this.byRef.values().next().value;
    if (oldest) this.remove(oldest.file);
  }

  private remove(file: FileRef): void {
    this.byRef.delete(file.ref);
    if (this.refByToken.get(file.token) === file.ref) this.refByToken.delete(file.token);
  }
}

/** Epoch milliseconds a Date can represent. */
function isTime(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= 8.64e15;
}

/** Control characters (e.g. a newline in a file name) must not forge extra listing lines. */
function displayText(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, " ");
}

function isUsableCandidate(candidate: FileCandidate): boolean {
  return typeof candidate?.name === "string" && candidate.name.length > 0
    && typeof candidate.path === "string"
    && parseHostAction({ type: "openFile", token: candidate.token }) !== null;
}

/** Containing folder of a POSIX host path with the home prefix shown as "~". */
export function abbreviateDir(path: string, homeDir: string = homedir()): string {
  const trimmed = path.length > 1 ? path.replace(/\/+$/, "") : path;
  const slash = trimmed.lastIndexOf("/");
  const dir = slash > 0 ? trimmed.slice(0, slash) : slash === 0 ? "/" : "";
  const home = homeDir.replace(/\/+$/, "");
  if (home.length > 1 && (dir === home || dir.startsWith(`${home}/`))) return `~${dir.slice(home.length)}`;
  return dir;
}

/**
 * Model-facing listing, one line per file:
 *   f3  Invoice-2026-03.pdf — ~/Documents/Finance · com.adobe.pdf · modified 2026-03-14
 * Dates are UTC calendar days so the text is deterministic.
 */
export function describeFileRefs(files: readonly FileRef[]): string {
  return files.map((file) => {
    const parts = [file.displayDir || "/"];
    if (file.isDirectory) parts.push("folder");
    else if (file.contentType) parts.push(file.contentType);
    if (file.modifiedMs !== undefined) parts.push(`modified ${new Date(file.modifiedMs).toISOString().slice(0, 10)}`);
    return `${file.ref}  ${file.name} — ${parts.join(" · ")}`;
  }).join("\n");
}
