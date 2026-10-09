import {
  closeSync, fchmodSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, statSync, writeSync,
} from "node:fs";
import { basename, dirname } from "node:path";

/**
 * Key-scoped JSON settings files (settings.json and friends).
 *
 * Several stores share one file (`model`, `routing`, ...). Every update is a
 * read-modify-write of exactly one top-level key against the CURRENT file
 * contents, so one store never clobbers another store's key or keys this
 * build does not know (newer hosts, hand edits). Writes are atomic: a private
 * temp file is written, fsynced and renamed over the target, so readers see
 * either the old or the new file, never a torn one. A failed write throws and
 * leaves the previous file untouched; callers decide whether to fall back to
 * memory-only state (and log that they did).
 *
 * Reads are tolerant: a missing file is the normal first-run case and a
 * corrupt one reads as empty. Before an update replaces a corrupt file, its raw
 * bytes are copied to `<file>.corrupt` so hand-edited content is recoverable.
 */

export type JsonObject = Record<string, unknown>;

export type SettingsReadStatus = "ok" | "missing" | "corrupt";

export interface SettingsReadResult {
  data: JsonObject;
  status: SettingsReadStatus;
  /** Raw bytes of a corrupt file (kept for the backup on the next write). */
  raw?: Buffer;
}

/** Settings files are tiny; anything larger is treated as corrupt. */
export const MAX_SETTINGS_FILE_BYTES = 1_048_576;

/** Owner-only, like resources.json (settings carry provider/model preferences). */
const FILE_MODE = 0o600;
const DIR_MODE = 0o700;

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Tolerant read: missing → {} ("missing"); unparsable/non-object/oversized → {} ("corrupt"). */
export function readJsonObjectFile(path: string, maxBytes = MAX_SETTINGS_FILE_BYTES): SettingsReadResult {
  let raw: Buffer;
  try {
    const oversized = statSync(path).size > maxBytes;
    raw = readFileSync(path);
    if (oversized) return { data: {}, status: "corrupt", raw };
  } catch (error) {
    if ((error as NodeJS.ErrnoException)?.code === "ENOENT") return { data: {}, status: "missing" };
    // EISDIR, EACCES, ...: reads as empty, but without `raw` an update refuses to replace it.
    return { data: {}, status: "corrupt" };
  }
  if (raw.length === 0) return { data: {}, status: "corrupt", raw };
  try {
    const parsed: unknown = JSON.parse(raw.toString("utf8"));
    return isJsonObject(parsed) ? { data: parsed, status: "ok" } : { data: {}, status: "corrupt", raw };
  } catch {
    return { data: {}, status: "corrupt", raw };
  }
}

function writeAllSync(fd: number, bytes: Buffer): void {
  let offset = 0;
  while (offset < bytes.length) offset += writeSync(fd, bytes, offset, bytes.length - offset);
}

/** Best-effort directory fsync so the rename itself is durable (unsupported on Windows). */
function fsyncDirectory(dir: string): void {
  let fd: number | undefined;
  try {
    fd = openSync(dir, "r");
    fsyncSync(fd);
  } catch {
    // Not supported everywhere; the file contents are already durable.
  } finally {
    if (fd !== undefined) try { closeSync(fd); } catch { /* ignore */ }
  }
}

/**
 * Atomically replace `path` with `bytes` (temp file + fsync + rename). Throws on
 * failure; the previous file is never truncated. The temp name is stable per
 * process, so a failed attempt's leftover is simply overwritten by the next one.
 */
export function writeFileAtomic(path: string, bytes: Buffer | string, mode = FILE_MODE): void {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true, mode: DIR_MODE });
  const temporary = `${path}.${process.pid}.tmp`;
  const fd = openSync(temporary, "w", mode);
  try {
    // `mode` only applies on creation; tighten a pre-existing leftover too.
    try { fchmodSync(fd, mode); } catch { /* Windows: ACLs, not modes */ }
    writeAllSync(fd, typeof bytes === "string" ? Buffer.from(bytes, "utf8") : bytes);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(temporary, path);
  fsyncDirectory(dir);
}

/** Atomically write a JSON value (2-space indented, trailing newline). */
export function writeJsonFileAtomic(path: string, value: unknown, mode = FILE_MODE): void {
  writeFileAtomic(path, `${JSON.stringify(value, null, 2)}\n`, mode);
}

export type KeyUpdate = unknown | ((current: unknown) => unknown);

/** One settings.json shared by several key-scoped stores. */
export class SettingsFile {
  constructor(
    readonly path: string,
    private readonly log: (line: string) => void = (line) => console.log(line),
  ) {}

  /** Whole file (tolerant). Callers must treat the result as untrusted input. */
  read(): JsonObject {
    return readJsonObjectFile(this.path).data;
  }

  get(key: string): unknown {
    return this.read()[key];
  }

  /**
   * Read-modify-write one top-level key. `undefined` (or an updater returning
   * undefined) removes the key; every other key is preserved exactly. Throws
   * when the file cannot be written (the old file stays intact).
   */
  update(key: string, next: KeyUpdate): JsonObject {
    const current = readJsonObjectFile(this.path);
    if (current.status === "corrupt") {
      // Never replace content we could not even read; it may hold other stores' keys.
      if (!current.raw) throw new Error(`settings_unreadable: ${basename(this.path)} exists but cannot be read`);
      // Keep the unparsable bytes recoverable before the rewrite drops them.
      if (current.raw.length > 0) {
        writeFileAtomic(`${this.path}.corrupt`, current.raw);
        this.log(`[settings] ${basename(this.path)} was unreadable; kept a copy as ${basename(this.path)}.corrupt`);
      }
    }
    const data: JsonObject = { ...current.data };
    const value = typeof next === "function" ? (next as (current: unknown) => unknown)(data[key]) : next;
    if (value === undefined) delete data[key];
    else data[key] = value;
    writeJsonFileAtomic(this.path, data);
    return data;
  }
}
