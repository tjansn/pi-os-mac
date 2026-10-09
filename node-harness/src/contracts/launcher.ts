import type { HostAction } from "./actions.js";
import { isAbsoluteHostPath } from "./attachments.js";

/**
 * Host launcher routes (protocol.md "Launcher routes"). Same envelope as the
 * other host tools: request `{ arguments: … }`, response
 * `{ ok: true, result: … } | { ok: false, error: { code, message } }`.
 *
 *   POST /tools/launcher.searchFiles  (read)   FileSearchRequest -> FileSearchResult
 *   POST /tools/launcher.listApps     (read)   ListAppsRequest   -> AppIndexResult
 *   POST /tools/launcher.open         (effect) LauncherOpenRequest -> LauncherOpenResult
 *   POST /tools/launcher.visibleItems (read)   VisibleItemsRequest -> VisibleItemsResult
 *
 * File tokens are minted by the host per search (random, TTL 10 min). Node
 * never sends a path back for an effect; it sends the token.
 *
 * `launcher.visibleItems` is macOS only and newer than the other three: the Windows host never
 * serves it and an older Mac host answers HTTP 404. Node treats 404, `not_found` and `unsupported`
 * as "no visible items" and remembers that per host. Swift mirror: `PiOSCore/LauncherPolicy.swift`;
 * fixtures: `shared/fixtures/launcher/visible-items.*.json` (invalid ones in `launcher/invalid/`).
 */

export const LAUNCHER_ROUTES = ["launcher.searchFiles", "launcher.listApps", "launcher.open", "launcher.visibleItems"] as const;
export type LauncherRoute = (typeof LAUNCHER_ROUTES)[number];

export interface FileSearchRequest {
  contextId?: string;
  /** OR of AND-groups of name terms, e.g. [["invoice"], ["rechnung"]]; ≤ 6 terms total, ≤ 64 chars each. */
  nameGroups: string[][];
  /** UTI the results must conform to (kMDItemContentTypeTree), e.g. "com.adobe.pdf". */
  contentType?: string;
  /** Default ["home"]. */
  scopes?: ("home" | "applications" | "icloud")[];
  /** ≤ 200; default 100. */
  maxResults?: number;
}

export interface FileCandidate {
  token: string;
  name: string;
  /** Absolute path, for display and ranking only (never logged). */
  path: string;
  contentType?: string;
  createdMs?: number;
  modifiedMs?: number;
  lastUsedMs?: number;
  useCount?: number;
  isDirectory: boolean;
  isPackage: boolean;
}

export interface FileSearchResult {
  items: FileCandidate[];
  /** True when the host stopped at maxResults. */
  truncated: boolean;
  elapsedMs: number;
}

export interface ListAppsRequest {
  contextId?: string;
}

export interface AppRecord {
  bundleId: string;
  name: string;
  /** Localized/alternate names (CFBundleDisplayName, CFBundleName, file name). */
  aliases: string[];
  path: string;
  running: boolean;
}

export interface AppIndexResult {
  /** Changes whenever the index changes; Node caches by it. */
  version: string;
  apps: AppRecord[];
}

/** Agent-initiated effects are limited to these; the UI path calls LauncherService directly. */
export interface LauncherOpenRequest {
  contextId?: string;
  action: Extract<HostAction, { type: "openApp" | "openURL" | "openFile" | "revealFile" }>;
}

export interface LauncherOpenResult {
  /** User-visible status, e.g. "Opened Figma". */
  status: string;
  /** "revealFile" when an executable/script/installer was downgraded from openFile. */
  performed: "openApp" | "openURL" | "openFile" | "revealFile";
}

// ---------------------------------------------------------------------------------------------
// Visible items (protocol.md "Launcher routes", "Visible items")

/** Enforced on both sides. Lengths are UTF-16 code units (JS `length`, Swift `utf16.count`). */
export const VISIBLE_ITEMS_LIMITS = {
  /** Upper bound of `maxResults` and of `items`. */
  maxResults: 200,
  defaultMaxResults: 100,
  /** `FileCandidate.name` (a macOS file name is at most 255 UTF-16 units). */
  maxNameChars: 255,
  /** `FileCandidate.contentType` (a UTI). */
  maxContentTypeChars: 255,
} as const;

/**
 * Where a visible item is shown. `desktop`: an icon on the Finder desktop surface (the take's target
 * is the desktop). `finderWindow`: an item of the take's target Finder window.
 */
export const VISIBLE_SOURCE_KINDS = ["desktop", "finderWindow"] as const;
export type VisibleSourceKind = (typeof VISIBLE_SOURCE_KINDS)[number];

/**
 * How the host read a source. `ax`: the Accessibility tree (desktop icons, a Finder window's items,
 * each with its file URL). `spotlight`: a Spotlight query for the direct children of the folder (the
 * desktop with its icons hidden, or a Finder window whose items AX could not read). Never FileManager
 * enumeration: that would raise the Desktop-folder privacy prompt.
 */
export const VISIBLE_SOURCE_VIAS = ["ax", "spotlight"] as const;
export type VisibleSourceVia = (typeof VISIBLE_SOURCE_VIAS)[number];

/** One source the host read for this context (at most one entry per kind). */
export interface VisibleSource {
  kind: VisibleSourceKind;
  via: VisibleSourceVia;
  /** False when the host stopped early (AX budget, Spotlight deadline): a miss may be a false negative. */
  complete: boolean;
}

/** A file or folder the user can see in the take's target context, as a host file token. */
export type VisibleItem = FileCandidate & { source: VisibleSourceKind };

/**
 * POST /tools/launcher.visibleItems `{arguments: VisibleItemsRequest}`: read-only (allowed in read-only
 * invocations), no prompt, no focus change. The host captured the context's visible items at key-down;
 * tokens are minted with this `contextId` only when returned.
 */
export interface VisibleItemsRequest {
  /** The take's context (required, `^[A-Za-z0-9_-]{1,128}$`). */
  contextId: string;
  /** 1..200; default 100. */
  maxResults?: number;
}

/**
 * `launcher.visibleItems` result. No sources and no items when the target is neither the desktop nor a
 * Finder window. Hidden files are never listed. `path` is for display and ranking only and never logged.
 */
export interface VisibleItemsResult {
  sources: VisibleSource[];
  /** At most `maxResults` (≤ 200); each item's `source` is one of `sources[].kind`; tokens are unique. */
  items: VisibleItem[];
  /** True when the host stopped at `maxResults`. */
  truncated: boolean;
  elapsedMs: number;
}

// Strict parsers in the style of contracts/instant.ts and contracts/browser.ts: unknown keys are dropped,
// JSON null on an optional member is absent (Swift decodeIfPresent), errors never echo values.

export type LauncherParse<T> = { ok: true; value: T } | { ok: false; error: string };

const CONTEXT_ID = /^[A-Za-z0-9_-]{1,128}$/;
/** HostAction's token rule (contracts/actions.ts). */
const TOKEN = /^[A-Za-z0-9_-]{8,128}$/;
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function present(value: unknown): boolean {
  return value !== undefined && value !== null;
}
function oneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}
/** 1..max UTF-16 units, not blank, no control characters, well-formed. */
function isLine(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length <= max && value.trim().length > 0 && !CONTROL.test(value) && !LONE_SURROGATE.test(value);
}

/**
 * Structural check of one host file candidate (`launcher.searchFiles` and `launcher.visibleItems` items):
 * a host token, a single-line name (≤ 255), an absolute path (≤ 1024 UTF-8 bytes, no `.`/`..`/empty
 * components), optional UTI and finite timestamps, a non-negative integer `useCount`, and the two flags.
 */
export function parseFileCandidate(value: unknown): LauncherParse<FileCandidate> {
  if (!isRecord(value)) return { ok: false, error: "item must be an object" };
  if (typeof value.token !== "string" || !TOKEN.test(value.token)) return { ok: false, error: "item.token must be a host token" };
  if (!isLine(value.name, VISIBLE_ITEMS_LIMITS.maxNameChars)) return { ok: false, error: "item.name must be 1..255 characters of single-line text" };
  if (!isAbsoluteHostPath(value.path) || LONE_SURROGATE.test(value.path)) return { ok: false, error: "item.path must be an absolute path" };
  if (typeof value.isDirectory !== "boolean" || typeof value.isPackage !== "boolean") return { ok: false, error: "item.isDirectory and item.isPackage must be booleans" };
  const candidate: FileCandidate = { token: value.token, name: value.name, path: value.path, isDirectory: value.isDirectory, isPackage: value.isPackage };
  if (present(value.contentType)) {
    if (!isLine(value.contentType, VISIBLE_ITEMS_LIMITS.maxContentTypeChars)) return { ok: false, error: "item.contentType must be a type identifier" };
    candidate.contentType = value.contentType;
  }
  for (const key of ["createdMs", "modifiedMs", "lastUsedMs"] as const) {
    if (!present(value[key])) continue;
    if (typeof value[key] !== "number" || !Number.isFinite(value[key])) return { ok: false, error: `item.${key} must be a finite number` };
    candidate[key] = value[key];
  }
  if (present(value.useCount)) {
    if (!Number.isSafeInteger(value.useCount) || (value.useCount as number) < 0) return { ok: false, error: "item.useCount must be a non-negative integer" };
    candidate.useCount = value.useCount as number;
  }
  return { ok: true, value: candidate };
}

/** `{arguments}` of POST /tools/launcher.visibleItems (the host answers 400 on failure). */
export function parseVisibleItemsRequest(value: unknown): LauncherParse<VisibleItemsRequest> {
  if (!isRecord(value) || typeof value.contextId !== "string" || !CONTEXT_ID.test(value.contextId)) return { ok: false, error: "contextId is required" };
  const request: VisibleItemsRequest = { contextId: value.contextId };
  if (present(value.maxResults)) {
    if (!Number.isInteger(value.maxResults) || (value.maxResults as number) < 1 || (value.maxResults as number) > VISIBLE_ITEMS_LIMITS.maxResults) {
      return { ok: false, error: `maxResults must be 1..${VISIBLE_ITEMS_LIMITS.maxResults}` };
    }
    request.maxResults = value.maxResults as number;
  }
  return { ok: true, value: request };
}

/**
 * Structural check of a `launcher.visibleItems` result (the `result` of an `ok: true` envelope). One bad
 * source or item rejects the whole result: Node then treats the context as having no visible items.
 */
export function parseVisibleItemsResult(value: unknown): LauncherParse<VisibleItemsResult> {
  if (!isRecord(value)) return { ok: false, error: "result must be an object" };
  const { sources, items, truncated, elapsedMs } = value;
  if (!Array.isArray(sources) || sources.length > VISIBLE_SOURCE_KINDS.length) return { ok: false, error: "sources must be an array of at most 2 sources" };
  if (!Array.isArray(items) || items.length > VISIBLE_ITEMS_LIMITS.maxResults) return { ok: false, error: `items must be an array of at most ${VISIBLE_ITEMS_LIMITS.maxResults} items` };
  if (typeof truncated !== "boolean") return { ok: false, error: "truncated must be a boolean" };
  if (typeof elapsedMs !== "number" || !Number.isFinite(elapsedMs) || elapsedMs < 0) return { ok: false, error: "elapsedMs must be a non-negative number" };
  const result: VisibleItemsResult = { sources: [], items: [], truncated, elapsedMs };
  const kinds = new Set<VisibleSourceKind>();
  for (const [index, source] of sources.entries()) {
    if (!isRecord(source) || !oneOf(VISIBLE_SOURCE_KINDS, source.kind) || !oneOf(VISIBLE_SOURCE_VIAS, source.via) || typeof source.complete !== "boolean") {
      return { ok: false, error: `sources[${index}] must be {kind, via, complete}` };
    }
    if (kinds.has(source.kind)) return { ok: false, error: `sources[${index}] repeats a kind` };
    kinds.add(source.kind);
    result.sources.push({ kind: source.kind, via: source.via, complete: source.complete });
  }
  const tokens = new Set<string>();
  for (const [index, item] of items.entries()) {
    const candidate = parseFileCandidate(item);
    if (!candidate.ok) return { ok: false, error: `items[${index}]: ${candidate.error}` };
    const source = (item as Record<string, unknown>).source;
    if (!oneOf(VISIBLE_SOURCE_KINDS, source) || !kinds.has(source)) return { ok: false, error: `items[${index}].source must be one of the sources` };
    if (tokens.has(candidate.value.token)) return { ok: false, error: `items[${index}] repeats a token` };
    tokens.add(candidate.value.token);
    result.items.push({ ...candidate.value, source });
  }
  return { ok: true, value: result };
}
