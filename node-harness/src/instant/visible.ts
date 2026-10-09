import {
  parseVisibleItemsResult,
  type FileCandidate, type VisibleItemsRequest, type VisibleItemsResult, type VisibleSource, type VisibleSourceKind,
} from "../contracts/launcher.js";
import { SPOKEN, type AppMatch } from "./apps.js";
import type { ItemRow } from "./cards.js";
import type { OpenStrength } from "./grammar/launch.js";
import { editSimilarity, firstSound, phoneticKeys, phoneticSimilarity, type PhoneticKeys } from "./phonetic.js";

/**
 * Visible items (protocol.md "Visible items"): what the user sees in the take's target context — the desktop
 * icons, or the items of the target Finder window — as host file tokens (POST /tools/launcher.visibleItems).
 * "öffne Radfotos" on the desktop opens the desktop folder before any app or file search is tried.
 *
 *   - `VisibleItemsCache`: one fetch per contextId, cached ≤ 3 s; an older host (HTTP 404) or one that does not
 *     serve the route (`not_found`, `unsupported`: the Windows host) is remembered as unsupported for the host.
 *   - `visibleTarget`: the open target's words without folder/file nouns, articles and a trailing location.
 *   - `matchVisible` / `decideVisible`: exact matching keys first (fold, no diacritics, ß → ss, lowercase, no
 *     file extension, no non-alphanumerics: "Rad Fotos" = "Rad-Fotos" = "Radfotos"), then the spoken matcher's
 *     sound-alike score (½ edit + ½ phonetic similarity on the joined and spaced forms, Kölner Phonetik for
 *     German speech) under the same thresholds (SPOKEN).
 *
 * Pure apart from the cache's fetch; nothing here logs (names and paths are user content).
 */

export const VISIBLE = Object.freeze({
  /** A context's visible items are fetched once and reused this long. */
  ttlMs: 3_000,
  /** A transient failure (busy, unknown_context, transport) counts as "no visible items" this long, then is retried. */
  failureTtlMs: 500,
  /** A host that does not serve the route is not asked again for this long (an update restarts the harness anyway). */
  unsupportedTtlMs: 10 * 60_000,
  /** Items asked for (the host's cap; `truncated` says more were visible). */
  maxResults: 200,
  /** A fetch Node gave up waiting for still fills the cache, up to this long. */
  fetchTimeoutMs: 2_000,
  /** Contexts kept (latest first out). */
  maxContexts: 32,
  /** Rows of a visible did-you-mean / choice list. */
  maxRows: 3,
});

export type VisibleItemsFetch = (request: VisibleItemsRequest, signal: AbortSignal) => Promise<VisibleItemsResult>;

/** A visible item (or a Spotlight candidate, without `source`) with its matching forms (computed once per fetch). */
export interface VisibleEntry {
  item: FileCandidate & { source?: VisibleSourceKind };
  /** Matching key without the file extension ("radfotos", "radtour2026"). */
  key: string;
  /** Matching key of the whole name ("notizentxt"). */
  fullKey: string;
  /** Folded words of the name without extension (the spaced form). */
  words: readonly string[];
  /** A folder the user opens as a folder (a directory that is not a package). */
  folder: boolean;
  /** Display name of the containing folder ("Desktop"). */
  parent: string;
  keys?: PhoneticKeys;
}

/** What the host showed for one context. */
export interface VisibleSnapshot {
  /** The host serves `launcher.visibleItems` (it answered for this context): gates the new open_item steps. */
  supported: boolean;
  sources: readonly VisibleSource[];
  entries: readonly VisibleEntry[];
}

export const NO_VISIBLE: VisibleSnapshot = Object.freeze({ supported: false, sources: [], entries: [] });

// ---------------------------------------------------------------------------------------------
// Matching keys

/** Fold for matching: NFD without diacritics, ß → ss, lowercase. */
function fold(text: string): string {
  return text.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ß/g, "ss").toLowerCase();
}

/** Letters and digits only ("Rad-Tour 2026" → "radtour2026"). */
export function matchKey(text: string): string {
  return fold(text).replace(/[^\p{L}\p{N}]+/gu, "");
}

function words(text: string): string[] {
  return fold(text).split(/[^\p{L}\p{N}]+/u).filter(Boolean);
}

const EXTENSION = /\.[\p{L}\p{N}]{1,8}$/u;

/** The name without a file extension ("Rad-Tour 2026.pdf" → "Rad-Tour 2026"); a plain folder keeps its name. */
function baseName(name: string, keepExtension: boolean): string {
  if (keepExtension) return name;
  const base = name.replace(EXTENSION, "");
  return base.trim() ? base : name;
}

/** The containing folder's display name ("/Users/x/Desktop/Radfotos" → "Desktop"); "/" for the volume root. */
export function parentName(path: string): string {
  const parts = path.split("/").filter(Boolean);
  return parts.length >= 2 ? parts[parts.length - 2]! : "/";
}

export function visibleEntry(item: FileCandidate & { source?: VisibleSourceKind }): VisibleEntry {
  const folder = item.isDirectory && !item.isPackage;
  const base = baseName(item.name, folder);
  return { item, key: matchKey(base), fullKey: matchKey(item.name), words: words(base), folder, parent: parentName(item.path) };
}

/** A card row for an entry: the token, the name and "in <folder>" (never the path). */
export function itemRow(entry: VisibleEntry): ItemRow {
  return { token: entry.item.token, name: entry.item.name, folder: entry.parent, ...(entry.item.contentType ? { contentType: entry.item.contentType } : {}) };
}

/** The snapshot of a parsed result: hidden names and empty keys dropped. */
export function snapshotOf(result: VisibleItemsResult): VisibleSnapshot {
  const entries: VisibleEntry[] = [];
  for (const item of result.items) {
    if (item.name.startsWith(".")) continue;
    const entry = visibleEntry(item);
    if (entry.key) entries.push(entry);
  }
  return { supported: true, sources: result.sources, entries };
}

// ---------------------------------------------------------------------------------------------
// The open target

/** What the user asked to open, ready for matching. */
export interface VisibleTarget {
  /** Matching key without a file extension. */
  key: string;
  /** Matching key with the extension ("notizentxt"). */
  fullKey: string;
  /** Folded words (the spaced form). */
  words: readonly string[];
  /** The key of the target as said, before nouns and articles were dropped ("my photos" for a folder "My Photos"). */
  rawKey?: string;
  /** The key with a possessive "'s" kept ("tomsfotos" for a folder "Tom's Fotos"; `key` drops it). */
  possessiveKey?: string;
  /** The target as heard, folded and spaced (≤ 80): `voice.heard`. */
  heard: string;
  /** "the Radfotos folder" / "die Datei Notizen": only folders, or only files, match. */
  kind?: "folder" | "file";
  keys?: PhoneticKeys;
}

const FOLDER_NOUN = "folder|folders|ordner|directory|verzeichnis";
const FILE_NOUN = "file|datei|document|dokument";
const LEAD_WORD = /^(?:the|my|this|that|den|die|das|der|dem|mein|meine|meinen|meinem|diesen|diese|dieses)\s+/;
const LEAD_KIND = new RegExp(`^(${FOLDER_NOUN}|${FILE_NOUN})(?:\\s+(?:called|named|namens|mit dem namen))?\\s+`);
// "Radfotos-Ordner" too: a folder really called "Foto-Ordner" still matches as said (rawKey).
const TAIL_KIND = new RegExp(`[\\s-]+(${FOLDER_NOUN}|${FILE_NOUN})$`);
const TAIL_PLACE = /\s+(?:on|from|in) (?:the|my) desktop$|\s+(?:auf dem|auf meinem|vom|im) (?:schreibtisch|desktop)$/;
const POSSESSIVE = /['’]s\b/g;

function kindOf(noun: string): "folder" | "file" {
  return new RegExp(`^(?:${FOLDER_NOUN})$`).test(noun) ? "folder" : "file";
}

/**
 * The open grammar's target as a visible-item target: articles, folder/file nouns ("öffne den Ordner
 * Radfotos", "open the Radfotos folder") and a trailing desktop location are dropped. Null when nothing
 * is left or the target is too long to be a name.
 */
export function visibleTarget(raw: string): VisibleTarget | null {
  // The possessive stays in the text (a folder may be called "Tom's Fotos"); `key` drops it, `possessiveKey` keeps it.
  let text = raw.normalize("NFC").toLowerCase().replace(/\s+/g, " ").trim();
  if (!text || text.length > 120) return null;
  const said = text.replace(POSSESSIVE, "");
  let kind: VisibleTarget["kind"];
  for (let round = 0; round < 3; round++) {
    const before = text;
    text = text.replace(TAIL_PLACE, "").replace(LEAD_WORD, "");
    const lead = LEAD_KIND.exec(text);
    if (lead && text.length > lead[0].length) {
      kind ??= kindOf(lead[1]!);
      text = text.slice(lead[0].length);
    }
    const tail = TAIL_KIND.exec(text);
    if (tail && tail.index > 0) {
      kind ??= kindOf(tail[1]!);
      text = text.slice(0, tail.index);
    }
    if (text === before) break;
  }
  const kept = text;
  text = text.replace(POSSESSIVE, "").replace(/\s+/g, " ").trim();
  const spaced = words(text);
  if (!spaced.length || spaced.length > 8) return null;
  const withoutExtension = (value: string): string => {
    const extension = EXTENSION.exec(value);
    return extension && extension.index > 0 ? value.slice(0, extension.index) : value;
  };
  const key = matchKey(withoutExtension(text));
  const fullKey = matchKey(text);
  if (!key) return null;
  const base = words(withoutExtension(text));
  const rawKey = said === text ? undefined : matchKey(said);
  const possessiveKey = kept === text ? undefined : matchKey(withoutExtension(kept));
  return {
    key, fullKey, words: spaced, heard: base.join(" ").slice(0, 80).trim(), ...(rawKey && rawKey !== key ? { rawKey } : {}),
    ...(possessiveKey && possessiveKey !== key ? { possessiveKey } : {}), ...(kind ? { kind } : {}),
  };
}

// ---------------------------------------------------------------------------------------------
// Matching

export interface VisibleMatch {
  entry: VisibleEntry;
  /** 1 for an exact key; else the sound-alike score (0.95 × combined similarity). */
  score: number;
  exact: boolean;
}

/** ASCII letters and digits only: the phonetic keys' input (other scripts have no sound-alike). */
function ascii(key: string): string {
  return key.replace(/[^a-z0-9]/g, "");
}

function keysOf(holder: { keys?: PhoneticKeys }, key: string): PhoneticKeys {
  return (holder.keys ??= phoneticKeys(ascii(key)));
}

function combined(a: string, b: string, ka: PhoneticKeys, kb: PhoneticKeys, german: boolean): number {
  return 0.5 * editSimilarity(a, b) + 0.5 * phoneticSimilarity(ka, kb, german);
}

/** The spoken matcher's sound-alike score of `target` for `entry` (0 when they cannot sound alike). */
function soundScore(target: VisibleTarget, entry: VisibleEntry, german: boolean, heardIsWord: boolean): number {
  const a = ascii(target.key);
  const b = ascii(entry.key);
  if (a.length < 3 || b.length < 2 || a.length !== target.key.length || b.length !== entry.key.length) return 0;
  // "Rad 2" is not "Radfotos": numbers belong to the request, not to a sound-alike name.
  if (/\d/.test(a) && !/\d/.test(b)) return 0;
  if (Math.min(a.length, b.length) / Math.max(a.length, b.length) < SPOKEN.minLengthRatio) return 0;
  const ka = keysOf(target, a);
  const kb = keysOf(entry, b);
  if (heardIsWord && firstSound(ka) !== firstSound(kb)) return 0;
  let best = combined(a, b, ka, kb, german);
  // The spaced form: the same number of words, word by word ("rat fotos" for "Rad Fotos").
  if (target.words.length >= 2 && target.words.length === entry.words.length) {
    let sum = 0;
    for (let i = 0; i < target.words.length; i++) {
      const x = ascii(target.words[i]!);
      const y = ascii(entry.words[i]!);
      sum += x && y ? combined(x, y, phoneticKeys(x), phoneticKeys(y), german) : 0;
    }
    best = Math.max(best, sum / target.words.length);
  }
  return best >= SPOKEN.soundFloor ? SPOKEN.soundWeight * best : 0;
}

/** The entry's name is the target's (with or without its extension, or as said with its articles and nouns). */
function exactKey(target: VisibleTarget, entry: VisibleEntry): boolean {
  return entry.key === target.key || entry.fullKey === target.key || entry.key === target.fullKey || entry.fullKey === target.fullKey
    || (target.rawKey !== undefined && (entry.key === target.rawKey || entry.fullKey === target.rawKey))
    || (target.possessiveKey !== undefined && entry.key === target.possessiveKey);
}

function kindAllows(target: VisibleTarget, entry: VisibleEntry): boolean {
  return target.kind === undefined || (target.kind === "folder") === entry.folder;
}

export interface VisibleMatchOptions {
  /** German speech or locale: Kölner Phonetik also counts. */
  german?: boolean;
  /** The heard name is one common EN/DE word: sound-alikes must share its first sound, and never act. */
  heardIsWord?: boolean;
  /** Also score sound-alikes (bare utterances match exact keys only). */
  sound?: boolean;
}

/** Exact matches first (finder window before desktop), then sound-alikes by score; ≤ 8. */
export function matchVisible(snapshot: VisibleSnapshot, target: VisibleTarget, options: VisibleMatchOptions = {}): VisibleMatch[] {
  if (!snapshot.entries.length) return [];
  const out: VisibleMatch[] = [];
  for (const entry of snapshot.entries) {
    if (!kindAllows(target, entry) && !(target.rawKey && entry.key === target.rawKey)) continue;
    if (exactKey(target, entry)) {
      out.push({ entry, score: 1, exact: true });
      continue;
    }
    if (!options.sound) continue;
    const score = soundScore(target, entry, options.german === true, options.heardIsWord === true);
    if (score > 0) out.push({ entry, score, exact: false });
  }
  return out.sort(compareMatches).slice(0, 8);
}

const SOURCE_ORDER: Readonly<Record<VisibleSourceKind, number>> = { finderWindow: 0, desktop: 1 };

function sourceOrder(entry: VisibleEntry): number {
  return entry.item.source ? SOURCE_ORDER[entry.item.source] : 2;
}

function compareMatches(a: VisibleMatch, b: VisibleMatch): number {
  return Number(b.exact) - Number(a.exact) || b.score - a.score
    || sourceOrder(a.entry) - sourceOrder(b.entry) || a.entry.item.name.length - b.entry.item.name.length;
}

/** A path compared as the file system does (no trailing slash, NFC, case-insensitive APFS/HFS+). */
function pathKey(path: string): string {
  return path.replace(/\/+$/, "").normalize("NFC").toLowerCase();
}

/**
 * Matches without the items that are an indexed app's own bundle (`appPaths`: AppRecord paths): an
 * Applications Finder window's "Safari.app" is the app Safari, not a second candidate next to it.
 */
export function withoutApps(matches: readonly VisibleMatch[], appPaths: readonly string[]): VisibleMatch[] {
  if (!appPaths.length) return [...matches];
  const known = new Set(appPaths.map(pathKey));
  return matches.filter((match) => !known.has(pathKey(match.entry.item.path)));
}

/** Visible offers of several hypotheses merged: the best score per token, ordered as matchVisible orders them. */
export function mergeVisibleOffers(lists: readonly (readonly VisibleMatch[])[]): VisibleMatch[] {
  const best = new Map<string, VisibleMatch>();
  for (const list of lists) for (const match of list) {
    const previous = best.get(match.entry.item.token);
    if (!previous || compareMatches(match, previous) < 0) best.set(match.entry.item.token, match);
  }
  return [...best.values()].sort(compareMatches);
}

/**
 * What the visible items decide for one open target (design C, steps 1 and 2), before the apps:
 *   - `act`: one exact item (finder window before desktop) and no exact app; or one sound-alike ≥ 0.82 with a
 *     0.08 lead over every other visible item, ≥ 4 letters, not a common word, a strong open form, and no app
 *     candidate at or above it (`confirm`: one Return).
 *   - `offer` with `decides`: several exact items, or an exact FOLDER and an exact app (the caller adds the app
 *     rows): a did-you-mean list now. An exact app beats exact files (installers, documents): null, the apps decide.
 *   - `offer` without `decides`: sound-alikes ≥ 0.66 (weak forms: ≥ 0.80) within 0.15 of the best; they join
 *     the apps' did-you-mean rows (visible first), or stand alone when the apps have none. An app act wins.
 */
export type VisibleDecision =
  | { kind: "act"; match: VisibleMatch; confirm: boolean }
  | { kind: "offer"; matches: VisibleMatch[]; decides: boolean }
  | null;

export interface VisibleDecideOptions {
  strength: OpenStrength;
  /** An app matched the target exactly (name or alias, ≥ 0.995). */
  appExact: boolean;
  /** The best app candidate's score (0 when none). */
  appTop: number;
  heardIsWord: boolean;
}

export function decideVisible(matches: readonly VisibleMatch[], target: VisibleTarget, options: VisibleDecideOptions): VisibleDecision {
  // An app said by its exact name beats a file of the same name (an installer "Spotify.dmg", a "Notes.txt" note):
  // only a folder named like the app is a real question.
  const exact = matches.filter((match) => match.exact && (!options.appExact || match.entry.folder));
  if (!exact.length && options.appExact) return null;
  if (exact.length) {
    const window = exact.filter((match) => match.entry.item.source === "finderWindow");
    const chosen = exact.length === 1 ? exact : window.length === 1 ? window : window.length ? window : exact;
    // A name said alone opens only when it is unmistakably a name (the app rule, AppMatcher.decideSpoken): a
    // dictionary word or a name under 4 letters ("Bilder.", "Neu.") is what a truncated transcript leaves, so it is offered.
    const ask = options.strength === "bare" && (options.heardIsWord || target.key.length < SPOKEN.minActLength);
    if (chosen.length === 1 && !options.appExact && !ask) return { kind: "act", match: chosen[0]!, confirm: false };
    return { kind: "offer", matches: chosen.slice(0, VISIBLE.maxRows), decides: true };
  }
  if (options.strength === "bare") return null;
  const [best, second] = matches;
  if (!best) return null;
  const lead = best.score - (second?.score ?? 0);
  if (options.strength === "strong" && !options.heardIsWord && best.score >= SPOKEN.actScore && lead >= SPOKEN.actMargin
    && target.key.length >= SPOKEN.minActLength && options.appTop < best.score) {
    return { kind: "act", match: best, confirm: true };
  }
  const floor = options.strength === "strong" ? SPOKEN.offerScore : SPOKEN.weakOfferScore;
  const offers = matches.filter((match) => match.score >= floor && match.score >= best.score - SPOKEN.offerWindow).slice(0, VISIBLE.maxRows);
  return offers.length ? { kind: "offer", matches: offers, decides: false } : null;
}

// ---------------------------------------------------------------------------------------------
// Spotlight did-you-mean (design C step 4)

/** A path the user would recognize: no hidden component, nothing in a Library folder (iCloud Drive's excepted). */
export function userVisible(path: string): boolean {
  const parts = path.split("/").filter(Boolean);
  if (parts.some((part) => part.startsWith("."))) return false;
  return !parts.includes("Library") || path.includes("/Library/Mobile Documents/");
}

/**
 * Found candidates for a target: names whose key equals or starts with the target's key (≥ 3 letters),
 * exact first, then folders, the closer length, the recently used; ≤ 3, one row per token.
 */
export function foundMatches(entries: readonly VisibleEntry[], target: VisibleTarget): VisibleMatch[] {
  if (target.key.length < 3) return [];
  const out: VisibleMatch[] = [];
  const seen = new Set<string>();
  for (const entry of entries) {
    if (seen.has(entry.item.token) || !kindAllows(target, entry)) continue;
    const exact = exactKey(target, entry);
    if (!exact && !entry.key.startsWith(target.key)) continue;
    seen.add(entry.item.token);
    out.push({ entry, score: exact ? 1 : target.key.length / entry.key.length, exact });
  }
  return out.sort((a, b) => Number(b.exact) - Number(a.exact) || Number(b.entry.folder) - Number(a.entry.folder) || b.score - a.score
    || (b.entry.item.lastUsedMs ?? 0) - (a.entry.item.lastUsedMs ?? 0)).slice(0, VISIBLE.maxRows);
}

/** Visible rows first, then app rows, ≤ 3; an app keeps one row whenever there is one. */
export function choiceRows(items: readonly VisibleMatch[], apps: readonly AppMatch[]): { items: VisibleMatch[]; apps: AppMatch[] } {
  const keep = Math.max(0, VISIBLE.maxRows - Math.min(1, apps.length));
  const shown = items.slice(0, keep);
  return { items: shown, apps: apps.slice(0, VISIBLE.maxRows - shown.length) };
}

// ---------------------------------------------------------------------------------------------
// The per-host cache

type FailureKind = "unsupported" | "invalid" | "transient";

/** HTTP 404 (an older Mac host), `not_found` / `unsupported` (a host without the route) → unsupported. */
export function visibleFailureKind(error: unknown): FailureKind {
  const value = error as { code?: unknown; status?: unknown } | null;
  if (value?.status === 404 || value?.code === "unsupported" || value?.code === "not_found") return "unsupported";
  if (value?.code === "invalid_result") return "invalid";
  return "transient";
}

interface CacheEntry { at: number; ttl: number; snapshot?: VisibleSnapshot; inflight?: Promise<VisibleSnapshot> }

export interface VisibleItemsCacheOptions {
  ttlMs?: number;
  failureTtlMs?: number;
  unsupportedTtlMs?: number;
  fetchTimeoutMs?: number;
  maxResults?: number;
  clock?: () => number;
}

/**
 * One host's visible items per contextId: fetched once, reused ≤ 3 s, the in-flight fetch shared. Never
 * rejects: a host without the route is remembered as unsupported (NO_VISIBLE without a request), any other
 * failure is "no visible items" for this context until the entry expires.
 */
export class VisibleItemsCache {
  private readonly entries = new Map<string, CacheEntry>();
  private unsupportedUntil = 0;
  private readonly ttlMs: number;
  private readonly failureTtlMs: number;
  private readonly unsupportedTtlMs: number;
  private readonly fetchTimeoutMs: number;
  private readonly maxResults: number;
  private readonly clock: () => number;

  constructor(private readonly fetch: VisibleItemsFetch, options: VisibleItemsCacheOptions = {}) {
    this.ttlMs = options.ttlMs ?? VISIBLE.ttlMs;
    this.failureTtlMs = options.failureTtlMs ?? VISIBLE.failureTtlMs;
    this.unsupportedTtlMs = options.unsupportedTtlMs ?? VISIBLE.unsupportedTtlMs;
    this.fetchTimeoutMs = options.fetchTimeoutMs ?? VISIBLE.fetchTimeoutMs;
    this.maxResults = options.maxResults ?? VISIBLE.maxResults;
    this.clock = options.clock ?? (() => Date.now());
  }

  /** The host is known not to serve the route. */
  get unsupported(): boolean {
    return this.clock() < this.unsupportedUntil;
  }

  /** The cached snapshot without waiting (NO_VISIBLE for an unsupported host); undefined when none is fresh. */
  peek(contextId: string): VisibleSnapshot | undefined {
    if (this.unsupported) return NO_VISIBLE;
    const entry = this.entries.get(contextId);
    return entry?.snapshot && this.clock() - entry.at < entry.ttl ? entry.snapshot : undefined;
  }

  /** Starts a fetch for `contextId` unless one is fresh or in flight. */
  prefetch(contextId: string): void {
    if (this.peek(contextId)) return;
    void this.start(contextId);
  }

  /** The snapshot, waiting for a fetch until `signal` aborts (then NO_VISIBLE; the fetch still fills the cache). */
  get(contextId: string, signal: AbortSignal): Promise<VisibleSnapshot> {
    const fresh = this.peek(contextId);
    if (fresh) return Promise.resolve(fresh);
    const pending = this.start(contextId);
    if (signal.aborted) return Promise.resolve(NO_VISIBLE);
    return new Promise((resolve) => {
      const onAbort = (): void => resolve(NO_VISIBLE);
      signal.addEventListener("abort", onAbort, { once: true });
      void pending.then((snapshot) => {
        signal.removeEventListener("abort", onAbort);
        resolve(snapshot);
      });
    });
  }

  private start(contextId: string): Promise<VisibleSnapshot> {
    const existing = this.entries.get(contextId);
    if (existing?.inflight) return existing.inflight;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.fetchTimeoutMs);
    timer.unref?.();
    let ttl = this.ttlMs;
    const run = this.fetch({ contextId, maxResults: this.maxResults }, controller.signal)
      .then((result): VisibleSnapshot => {
        // Strict at the boundary (HostClient parses too): one bad source or item discards the whole result.
        const parsed = parseVisibleItemsResult(result);
        // The host answers complete:false while its key-down read is still running: keep that only briefly, so the
        // take's final asks again instead of deciding on a partial view for 3 s.
        if (parsed.ok && parsed.value.sources.some((source) => !source.complete)) ttl = this.failureTtlMs;
        return parsed.ok ? snapshotOf(parsed.value) : { ...NO_VISIBLE, supported: true };
      }, (error: unknown) => {
        const kind = visibleFailureKind(error);
        if (kind === "unsupported") this.unsupportedUntil = this.clock() + this.unsupportedTtlMs;
        if (kind === "transient") ttl = this.failureTtlMs;
        return kind === "invalid" ? { ...NO_VISIBLE, supported: true } : NO_VISIBLE;
      })
      .then((snapshot) => {
        clearTimeout(timer);
        this.store(contextId, { at: this.clock(), ttl, snapshot });
        return snapshot;
      });
    this.store(contextId, { at: this.clock(), ttl, inflight: run });
    return run;
  }

  private store(contextId: string, entry: CacheEntry): void {
    this.entries.delete(contextId);
    this.entries.set(contextId, entry);
    while (this.entries.size > VISIBLE.maxContexts) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }
}
