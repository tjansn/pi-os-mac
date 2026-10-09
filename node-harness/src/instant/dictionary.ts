import { randomBytes } from "node:crypto";
import { chmodSync, copyFileSync, readFileSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import {
  DEFAULT_DICTIONARY_SETTINGS, DICTIONARY_FILE, DICTIONARY_LIMITS, DICTIONARY_LISTS, emptyDictionary, foldPhrase,
  isEntryActive, isRefusedPhrase, parseDictionary, recognizerApplies, ruleKey,
  type DictionaryDocument, type DictionaryEntry, type DictionaryEntryBase, type DictionaryEntryRef, type DictionaryIssue,
  type DictionaryList, type DictionaryLookup, type DictionaryMatch, type DictionarySettings, type DictionarySource,
  type DictionaryTerm, type DictionaryWriteCode, type LearnedAlias, type LearnedAppName, type LearnedFix,
  type RecognizerTerm, type RecognizerTermsResponse, type SafeTarget,
} from "../contracts/dictionary.js";
import { isVoiceText } from "../contracts/instant.js";
import { supportDirectory } from "../platformPaths.js";
import { writeFileAtomic } from "../settingsFile.js";

/**
 * The personal dictionary store (DESIGN4 §6.1): `<support>/dictionary.json`, owned by Node alone. It is
 * loaded synchronously once, validated exactly like learn-time input (contracts `parseDictionary`, plus
 * the content-word floor below), and kept in memory; every write builds a new document, keeps it within
 * the list caps and the 256 KB file cap (LRU eviction of unpinned entries, else `limit_reached`), bumps
 * `revision` and replaces the file atomically (0600 in a 0700 directory). Learned names and aliases are
 * looked up exactly (DictionaryLookup, for the instant lane); nothing here feeds the fuzzy matcher.
 *
 * Content-free logging only: the log callback receives counts, codes and statuses, never a phrase.
 */

// ---------------------------------------------------------------------------------------------
// Phrase canonicalization (shared with learned.ts)

/** Leading particles the open grammar leaves in a heard target ("Öffne mir bitte X", "Open up X"). */
const NAME_LEADING = /^(?:(?:up|the|please|mal|bitte|mir|doch|eben|schnell|kurz|die|das|den|der|dem|des) )+/;
/** Trailing wrapper words a heard target may still carry ("pace for me", "pace now"). */
const NAME_TRAILING = /(?: (?:for me|now|please|bitte|mal|app|application|window|fenster|fur mich|jetzt))+$/;
/** Leading fillers and request wrappers of a whole utterance ("okay can you …", "ich möchte …"). */
const UTTERANCE_LEADING = new RegExp(
  "^(?:(?:okay|ok|hey|hi|hallo|hello|um|uh|ah|ahm|ahh|ehm|also|so|well|ja|please|bitte|mal|doch|eben|" +
    "can you|could you|would you|will you|would you mind|kannst du|konntest du|wurdest du|ich mochte|ich will|" +
    "i d like to|id like to|i want to|i wanna|lets) )+",
);
const UTTERANCE_TRAILING = /(?: (?:please|bitte|for me|fur mich|now|jetzt|mal|thanks|thank you|danke|danke schon))+$/;

/** The canonical heard name of an app-name rule: folded, wrapper particles removed ("" when nothing is left). */
export function nameCore(text: string): string {
  let folded = foldPhrase(text);
  for (let round = 0; round < 3; round++) {
    const next = folded.replace(NAME_TRAILING, "").replace(NAME_LEADING, "").trim();
    if (next === folded) break;
    folded = next;
  }
  return folded;
}

/** The canonical phrase of an utterance alias: folded, leading fillers/wrappers and trailing politeness removed. */
export function utteranceCore(text: string): string {
  let folded = foldPhrase(text);
  for (let round = 0; round < 3; round++) {
    const next = folded.replace(UTTERANCE_TRAILING, "").replace(UTTERANCE_LEADING, "").trim();
    if (next === folded) break;
    folded = next;
  }
  return folded;
}

/**
 * Words that never count as content (DESIGN4 §6.5 alias guard, measured in design4 M4): function words,
 * command verbs ("Open", "Oben", "öffne"), politeness ("Bitte", "Please"), small numbers ("Drei"),
 * confirm/cancel words and UI nouns. Tokens of ≤ 2 characters never count either.
 */
export const GUARD_STOP_WORDS: ReadonlySet<string> = new Set([
  // design4 M4's set
  "open", "oben", "offen", "offne", "oeffne", "start", "starte", "the", "a", "an", "and", "und", "bitte", "please", "mal", "app", "apps",
  "file", "datei", "page", "seite", "ja", "yes", "no", "nein", "okay", "ok", "so", "also", "drei", "zwei", "eins", "one", "two", "three",
  "keine", "kein", "nicht", "not", "that", "das", "this", "dies", "guten", "next", "nachste", "read",
  // bare verbs, politeness and fillers named by §6.5
  "launch", "run", "show", "switch", "offnen", "starten", "zeig", "zeige", "thanks", "thank", "danke", "hey", "hallo", "hello", "hmm",
  "ahm", "ehm", "the", "der", "die", "den", "dem", "des", "ein", "eine", "einen", "for", "fur", "mir", "mich", "my", "mein", "meine",
  "you", "it", "es", "ist", "is", "now", "jetzt", "four", "five", "six", "seven", "eight", "nine", "ten", "zero", "vier", "funf",
  "sechs", "sieben", "acht", "neun", "zehn", "null", "yeah", "yep", "nope", "cancel", "stop", "stopp", "undo", "abbrechen",
]);

/** UI nouns and deixis that are never an app's name ("open the window", "öffne die Datei"). */
const NOT_A_NAME = new Set([
  "window", "tab", "door", "link", "file", "folder", "document", "source", "sleep", "home", "over", "again", "back", "fenster", "tur",
  "datei", "ordner", "seite", "camera", "kamera", "it", "this", "that", "them", "es", "das", "dies", "den", "die", "der",
]);

function words(folded: string): string[] {
  return folded.split(" ").filter(Boolean);
}

/** Content words of a folded phrase (≥ 3 characters, not a guard stop word, not a number). */
export function contentWords(folded: string): string[] {
  return words(folded).filter((word) => word.length >= 3 && !/^\d+$/.test(word) && !GUARD_STOP_WORDS.has(word));
}

/** The floor every alias and app name meets, learned or typed in Settings: at least one content word. */
export function hasContentWord(folded: string): boolean {
  return contentWords(folded).length > 0;
}

/** A heard target that names a thing on screen, not an app ("window", "this"). */
export function isNotAName(folded: string): boolean {
  const parts = words(folded);
  return parts.length === 0 || parts.every((word) => NOT_A_NAME.has(word) || GUARD_STOP_WORDS.has(word));
}

/**
 * The same lookups without usage counting: for dispatchers that are not the host's /instant (the learn
 * lane's resolve, /invoke's direct answers, the regression check), whose decisions are not uses.
 */
export function nonCountingLookup(lookup: DictionaryLookup): DictionaryLookup {
  return {
    revision: () => lookup.revision(),
    settings: () => lookup.settings(),
    alias: (phrase, recognizer) => lookup.alias(phrase, recognizer),
    appName: (heard, recognizer) => lookup.appName(heard, recognizer),
    fixes: (recognizer) => lookup.fixes(recognizer),
    noteUse: () => {},
  };
}

// ---------------------------------------------------------------------------------------------
// Store

export type DictionaryLoadStatus = "ok" | "missing" | "corrupt" | "oversized" | "invalid" | "unreadable";

export interface DictionaryLoadReport {
  status: DictionaryLoadStatus;
  /** Entries dropped on load (content-free). */
  issues: DictionaryIssue[];
  /** Entries kept. */
  entries: number;
}

/** The result of a store write. `ok: false` changes nothing. */
export type WriteOutcome =
  | { ok: true; revision: number; ref?: DictionaryEntryRef; code?: DictionaryWriteCode; undoToken?: string }
  | { ok: false; revision: number; code: DictionaryWriteCode };

export interface DictionaryStoreOptions {
  /** Default `<support>/dictionary.json`. */
  path?: string;
  /** Epoch ms (default Date.now). */
  clock?: () => number;
  /** Content-free log lines. */
  log?: (line: string) => void;
  /** Whether a bundle id is in the host's app index (undefined: index unknown). Lookups skip uninstalled targets. */
  installed?: (bundleId: string) => boolean | undefined;
  /** Delay of the lazy usage write (default 2 s). */
  flushDelayMs?: number;
  /** Tests: never touch the file system. */
  persist?: boolean;
}

/** What a learn or Settings write binds: the list, its content and the scope. */
export type EntryContent =
  | { list: "terms"; text: string; soundsLike: string[]; lang: DictionaryTerm["lang"]; kind: DictionaryTerm["kind"]; bundleId?: string }
  | { list: "appNames"; heard: string; bundleId: string; display: string; shadows?: string }
  | { list: "aliases"; phrase: string; target: SafeTarget }
  | { list: "fixes"; heard: string; intended: string };

export interface BindOptions {
  recognizer: string;
  source: DictionarySource;
  pinned?: boolean;
  /** Update this entry (Settings edit) instead of adding or reinforcing a rule. */
  id?: string;
}

interface UndoRecord {
  token: string;
  expires: number;
  changes: { list: DictionaryList; id: string; before: DictionaryEntry | undefined }[];
}

interface LookupIndex {
  aliases: Map<string, LearnedAlias[]>;
  aliasCores: Map<string, LearnedAlias[]>;
  appNames: Map<string, LearnedAppName[]>;
  appNameCores: Map<string, LearnedAppName[]>;
  fixes: Map<string, readonly DictionaryMatch<{ heard: string; intended: string }>[]>;
}

const ID_PREFIX: Record<DictionaryList, string> = { terms: "t_", appNames: "n_", aliases: "a_", fixes: "f_" };
const MAX_UNDO = 20;
const DAY_MS = 86_400_000;
/** Names that start with a command verb bias recognizers toward hearing the verb as the app ("Open Design"). */
const VERB_INITIAL = /^(?:open|launch|start|run|show|go|switch|find|search|close|quit|play|offne|oeffne|starte|zeig|zeige|such|suche|mach|geh|wechsel|wechsle|hol|spiel)(?: |$)/;

function lists(document: DictionaryDocument): Record<DictionaryList, DictionaryEntry[]> {
  return document as unknown as Record<DictionaryList, DictionaryEntry[]>;
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function lastUse(entry: DictionaryEntryBase): number {
  const stamp = Date.parse(entry.lastUsedAt ?? entry.createdAt);
  return Number.isFinite(stamp) ? stamp : 0;
}

function sameTarget(a: SafeTarget, b: SafeTarget): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function contentOf(entry: DictionaryEntry, list: DictionaryList): EntryContent {
  switch (list) {
    case "terms": {
      const term = entry as DictionaryTerm;
      return { list, text: term.text, soundsLike: [...term.soundsLike], lang: term.lang, kind: term.kind, ...(term.bundleId ? { bundleId: term.bundleId } : {}) };
    }
    case "appNames": {
      const name = entry as LearnedAppName;
      return { list, heard: name.heard, bundleId: name.bundleId, display: name.display, ...(name.shadows ? { shadows: name.shadows } : {}) };
    }
    case "aliases": {
      const alias = entry as LearnedAlias;
      return { list, phrase: alias.phrase, target: alias.target };
    }
    case "fixes": {
      const fix = entry as LearnedFix;
      return { list, heard: fix.heard, intended: fix.intended };
    }
  }
}

/** Two bindings of one rule key that do the same thing (a re-teaching, not a replacement). */
function sameMeaning(a: EntryContent, b: EntryContent): boolean {
  if (a.list !== b.list) return false;
  switch (a.list) {
    case "terms": return true;
    case "appNames": return a.bundleId === (b as typeof a).bundleId;
    case "aliases": return sameTarget(a.target, (b as typeof a).target);
    case "fixes": return a.intended === (b as typeof a).intended;
  }
}

/** Load-time checks beyond the contract parser (learn-time validation, DESIGN4 §6.8 #8). */
function storeIssue(list: DictionaryList, entry: DictionaryEntry): DictionaryIssue["code"] | null {
  if (list === "aliases" && !hasContentWord((entry as LearnedAlias).phrase)) return "invalid_phrase";
  if (list === "appNames" && (!hasContentWord((entry as LearnedAppName).heard) || isNotAName((entry as LearnedAppName).heard))) return "invalid_phrase";
  return null;
}

export class DictionaryStore implements DictionaryLookup {
  readonly path: string;
  private doc: DictionaryDocument = emptyDictionary();
  private index?: { doc: DictionaryDocument; value: LookupIndex };
  private readonly undos: UndoRecord[] = [];
  private readonly clock: () => number;
  private readonly log: (line: string) => void;
  private readonly persistToDisk: boolean;
  private readonly flushDelayMs: number;
  private installedCheck: ((bundleId: string) => boolean | undefined) | undefined;
  /** The file on disk could not be used as is: keep its bytes as `<file>.corrupt` before the first rewrite. */
  private backupPending = false;
  /** False after the file could not be read (permissions): it is never replaced, changes stay in memory. */
  private writable = true;
  private directoryChecked = false;
  private flushTimer: NodeJS.Timeout | undefined;
  private usageDirty = false;

  constructor(options: DictionaryStoreOptions = {}) {
    this.path = options.path ?? join(supportDirectory(), DICTIONARY_FILE);
    this.clock = options.clock ?? (() => Date.now());
    this.log = options.log ?? ((line) => console.log(line));
    this.persistToDisk = options.persist !== false;
    this.flushDelayMs = options.flushDelayMs ?? 2_000;
    this.installedCheck = options.installed;
  }

  /** The host index check used by lookups (the server sets it once it knows the index). */
  setInstalledCheck(check: ((bundleId: string) => boolean | undefined) | undefined): void {
    this.installedCheck = check;
  }

  /**
   * Reads the file (synchronously; ≤ 256 KB). A missing file is an empty dictionary. A file that is too
   * large, unparsable or of the wrong shape starts empty and is kept as `<file>.corrupt` on the next write;
   * bad entries are dropped with content-free issues (and the original kept the same way).
   */
  load(): DictionaryLoadReport {
    this.doc = emptyDictionary();
    this.index = undefined;
    this.backupPending = false;
    this.writable = true;
    const report = (status: DictionaryLoadStatus, issues: DictionaryIssue[] = []): DictionaryLoadReport => {
      const entries = DICTIONARY_LISTS.reduce((sum, list) => sum + lists(this.doc)[list].length, 0);
      const codes = [...new Set(issues.map((issue) => issue.code))].join(",") || "none";
      if (status !== "missing") this.log(`[dictionary] loaded status=${status} entries=${entries} dropped=${issues.length} codes=${codes}`);
      return { status, issues, entries };
    };
    if (!this.persistToDisk) return report("missing");
    let raw: Buffer;
    try {
      if (statSync(this.path).size > DICTIONARY_LIMITS.fileBytes) {
        this.backupPending = true;
        return report("oversized");
      }
      raw = readFileSync(this.path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code === "ENOENT") return report("missing");
      this.writable = false;
      return report("unreadable");
    }
    let value: unknown;
    try {
      value = JSON.parse(raw.toString("utf8"));
    } catch {
      this.backupPending = true;
      return report("corrupt");
    }
    const parsed = parseDictionary(value);
    if (!parsed.ok) {
      this.backupPending = true;
      return report("invalid");
    }
    const issues = [...parsed.issues];
    const now = this.clock();
    for (const list of DICTIONARY_LISTS) {
      // Issue paths index the file's own list (the contract parser dropped some entries already).
      const dropped = new Set(parsed.issues.filter((issue) => issue.path.startsWith(`${list}[`)).map((issue) => Number(issue.path.slice(list.length + 1, -1))));
      const stored = (value as Record<string, unknown>)[list];
      const positions = Array.from({ length: Array.isArray(stored) ? stored.length : 0 }, (_, index) => index).filter((index) => !dropped.has(index));
      const kept: DictionaryEntry[] = [];
      lists(parsed.value)[list].forEach((entry, index) => {
        const code = storeIssue(list, entry);
        if (code) issues.push({ path: `${list}[${positions[index] ?? index}]`, code });
        else kept.push(this.settle(entry, now));
      });
      lists(parsed.value)[list] = kept;
    }
    // One order for both checks: by list, then by position in the file.
    const at = (issue: DictionaryIssue): [number, number] => {
      const match = /^(\w+)\[(\d+)\]$/.exec(issue.path);
      return match ? [DICTIONARY_LISTS.indexOf(match[1] as DictionaryList), Number(match[2])] : [-1, -1];
    };
    issues.sort((a, b) => at(a)[0] - at(b)[0] || at(a)[1] - at(b)[1]);
    this.doc = this.purgeExpired(parsed.value, now);
    if (issues.length) this.backupPending = true;
    return report("ok", issues);
  }

  /** A rule rejected out (rejections ≥ max(2, count)) is disabled, so the 30-day retention applies. */
  private settle(entry: DictionaryEntry, now: number): DictionaryEntry {
    if (entry.disabledAt === undefined && !isEntryActive(entry)) return { ...entry, disabledAt: iso(now) };
    return entry;
  }

  // ------------------------------------------------------------------ reads

  revision(): number {
    return this.doc.revision;
  }

  settings(): DictionarySettings {
    return { ...this.doc.settings };
  }

  /** A deep copy of the document (GET /dictionary; Settings). */
  document(): DictionaryDocument {
    return structuredClone(this.doc);
  }

  entry(ref: DictionaryEntryRef): DictionaryEntry | undefined {
    const found = lists(this.doc)[ref.list].find((entry) => entry.id === ref.id);
    return found ? structuredClone(found) : undefined;
  }

  /** The active entry with the rule key of `content` in exactly this scope (`any` is its own scope). */
  activeRule(content: EntryContent, recognizer: string): DictionaryEntry | undefined {
    const key = contentKey(content, recognizer);
    return lists(this.doc)[content.list].find((entry) => isEntryActive(entry) && ruleKey(content.list, entry) === key);
  }

  private installed(target: SafeTarget): boolean {
    return target.kind !== "openApp" || this.installedCheck?.(target.bundleId) !== false;
  }

  private lookupIndex(): LookupIndex {
    if (this.index?.doc === this.doc) return this.index.value;
    const push = <T>(map: Map<string, T[]>, key: string, value: T): void => {
      if (!key) return;
      const bucket = map.get(key);
      if (bucket) { if (!bucket.includes(value)) bucket.push(value); } else map.set(key, [value]);
    };
    const value: LookupIndex = { aliases: new Map(), aliasCores: new Map(), appNames: new Map(), appNameCores: new Map(), fixes: new Map() };
    for (const alias of this.doc.aliases) {
      if (!isEntryActive(alias)) continue;
      push(value.aliases, alias.phrase, alias);
      push(value.aliasCores, utteranceCore(alias.phrase), alias);
    }
    for (const name of this.doc.appNames) {
      if (!isEntryActive(name)) continue;
      push(value.appNames, name.heard, name);
      push(value.appNameCores, nameCore(name.heard), name);
    }
    this.index = { doc: this.doc, value };
    return value;
  }

  /** The most specific rule of the candidates: the recognizer's own before `any`, then the most taught. */
  private pick<T extends DictionaryEntryBase>(candidates: readonly (T[] | undefined)[], recognizer: string, usable: (entry: T) => boolean): T | undefined {
    for (const bucket of candidates) {
      const matches = (bucket ?? []).filter((entry) => recognizerApplies(entry.recognizer, recognizer) && usable(entry));
      if (!matches.length) continue;
      return matches.sort((a, b) => Number(b.recognizer === recognizer) - Number(a.recognizer === recognizer) || b.count - a.count)[0];
    }
    return undefined;
  }

  /** Step 1: an exact utterance alias (the phrase as folded, or without wrapper particles). */
  alias(phrase: string, recognizer: string): DictionaryMatch<SafeTarget> | null {
    if (typeof phrase !== "string" || typeof recognizer !== "string") return null;
    const folded = foldPhrase(phrase);
    if (!folded || isRefusedPhrase(folded)) return null;
    const core = utteranceCore(folded);
    const index = this.lookupIndex();
    const found = this.pick([index.aliases.get(folded), index.aliases.get(core), index.aliasCores.get(folded), index.aliasCores.get(core)],
      recognizer, (entry) => this.installed(entry.target));
    return found ? { ref: { list: "aliases", id: found.id }, value: structuredClone(found.target) } : null;
  }

  /** Step 2: an exact learned app name for the open target as heard. */
  appName(heard: string, recognizer: string): DictionaryMatch<{ bundleId: string; display: string }> | null {
    if (typeof heard !== "string" || typeof recognizer !== "string") return null;
    const folded = foldPhrase(heard);
    if (!folded || isRefusedPhrase(folded)) return null;
    const core = nameCore(folded);
    const index = this.lookupIndex();
    const found = this.pick([index.appNames.get(folded), index.appNames.get(core), index.appNameCores.get(folded), index.appNameCores.get(core)],
      recognizer, (entry) => this.installed({ kind: "openApp", bundleId: entry.bundleId }));
    return found ? { ref: { list: "appNames", id: found.id }, value: { bundleId: found.bundleId, display: found.display } } : null;
  }

  /** Step 4 (voice only): the fixes that apply, longest heard phrase first. */
  fixes(recognizer: string): readonly DictionaryMatch<{ heard: string; intended: string }>[] {
    const index = this.lookupIndex();
    const cached = index.fixes.get(recognizer);
    if (cached) return cached;
    const value = this.doc.fixes
      .filter((fix) => isEntryActive(fix) && recognizerApplies(fix.recognizer, recognizer))
      .sort((a, b) => words(b.heard).length - words(a.heard).length || b.heard.length - a.heard.length
        || Number(b.recognizer === recognizer) - Number(a.recognizer === recognizer))
      .map((fix) => Object.freeze({ ref: Object.freeze({ list: "fixes" as const, id: fix.id }), value: Object.freeze({ heard: fix.heard, intended: fix.intended }) }));
    const frozen = Object.freeze(value);
    // Recognizer ids come from requests: keep the per-recognizer cache small.
    if (index.fixes.size >= 16) index.fixes.clear();
    index.fixes.set(recognizer, frozen);
    return frozen;
  }

  /**
   * Agent note (DESIGN4 §5.5): up to `max` active entries whose heard phrase occurs in the utterance, as
   * "heard → meaning" pairs. Empty when Settings switched `explainToAgent` off. Never logged.
   */
  explain(text: string, recognizer: string, max = 5): { heard: string; meaning: string }[] {
    if (!this.doc.settings.explainToAgent) return [];
    const haystack = ` ${foldPhrase(text)} `;
    const out: { heard: string; meaning: string }[] = [];
    const add = (heard: string, meaning: string): void => {
      if (out.length < max && haystack.includes(` ${heard} `) && !out.some((item) => item.heard === heard)) out.push({ heard, meaning });
    };
    for (const name of this.doc.appNames) if (isEntryActive(name) && recognizerApplies(name.recognizer, recognizer)) add(name.heard, `the ${name.display} app (${name.bundleId})`);
    for (const fix of this.doc.fixes) if (isEntryActive(fix) && recognizerApplies(fix.recognizer, recognizer)) add(fix.heard, fix.intended);
    for (const term of this.doc.terms) if (isEntryActive(term)) for (const form of term.soundsLike) add(form, term.text);
    return out;
  }

  /** Records that a rule decided (uses, lastUsedAt); written lazily. Never throws. */
  noteUse(ref: DictionaryEntryRef): void {
    try {
      const entry = lists(this.doc)[ref.list]?.find((candidate) => candidate.id === ref.id);
      if (!entry) return;
      entry.uses = Math.min(entry.uses + 1, DICTIONARY_LIMITS.maxCounter);
      entry.lastUsedAt = iso(this.clock());
      this.usageDirty = true;
      if (!this.flushTimer && this.persistToDisk) {
        this.flushTimer = setTimeout(() => { this.flushTimer = undefined; this.flush(); }, this.flushDelayMs);
        this.flushTimer.unref?.();
      }
    } catch {
      // Usage is a ranking hint; never fail a decision over it.
    }
  }

  /** Writes pending usage now (server shutdown). */
  flush(): void {
    if (this.flushTimer) { clearTimeout(this.flushTimer); this.flushTimer = undefined; }
    if (!this.usageDirty) return;
    this.usageDirty = false;
    const next = structuredClone(this.doc);
    next.revision = this.doc.revision + 1;
    this.persist(next);
    this.doc = next;
  }

  /**
   * Ranked strings for the recognizers (DESIGN4 §6.4), after the host's pinned app name and window title:
   * pinned dictionary terms; then terms, learned app names and fix targets by uses; then frecent apps;
   * then the remaining installed apps. Verb-initial names ("Open Design") and refused phrases are left
   * out, `soundsLike` forms are never given to a recognizer, and duplicates fold together. With
   * `applyToRecognizer` off the dictionary's own entries are left out (apps still rank).
   */
  recognizerTerms(max: number = DICTIONARY_LIMITS.recognizerTerms, context: RankingContext = {}): RecognizerTermsResponse {
    return { revision: this.doc.revision, terms: rankRecognizerTerms(this.doc, max, context) };
  }

  // ------------------------------------------------------------------ writes

  /**
   * Binds a rule (learn or Settings). With `options.id` the entry is updated in place (`unknown_entry` when
   * it does not exist). Otherwise an active rule with the same key and scope is reinforced when it means the
   * same (`count` + 1), or disabled (kept for Undo) and replaced (`replaced`).
   */
  bind(content: EntryContent, options: BindOptions): WriteOutcome {
    const list = content.list;
    return this.mutate((draft, now) => {
      const entries = lists(draft)[list];
      if (options.id !== undefined) {
        const existing = entries.find((entry) => entry.id === options.id);
        if (!existing) return { ok: false, code: "unknown_entry" };
        const updated = { ...existing, ...this.materialize(content, options, existing), id: existing.id } as DictionaryEntry;
        entries[entries.indexOf(existing)] = updated;
        this.disableConflicts(draft, list, updated, now);
        return { ok: true, ref: { list, id: existing.id } };
      }
      const key = contentKey(content, options.recognizer);
      const existing = entries.find((entry) => isEntryActive(entry) && ruleKey(list, entry) === key);
      if (existing && sameMeaning(contentOf(existing, list), content)) {
        const reinforced = {
          ...existing, ...(list === "terms" ? this.materialize(content, { ...options, source: existing.source }, existing) : {}),
          count: Math.min(existing.count + 1, DICTIONARY_LIMITS.maxCounter), lastUsedAt: iso(now),
          ...(options.pinned !== undefined ? { pinned: options.pinned } : {}),
        } as DictionaryEntry;
        entries[entries.indexOf(existing)] = reinforced;
        return { ok: true, ref: { list, id: existing.id } };
      }
      if (existing) entries[entries.indexOf(existing)] = { ...existing, disabledAt: iso(now) };
      const id = this.newId(draft, list);
      entries.push({ ...this.materialize(content, options), id } as DictionaryEntry);
      return { ok: true, ref: { list, id }, ...(existing ? { code: "replaced" as const } : {}) };
    }, { undoable: true });
  }

  /** delete · disable · enable · pin · unpin (Settings). Enabling resets rejections and replaces a conflicting rule. */
  setState(ref: DictionaryEntryRef, op: "delete" | "disable" | "enable" | "pin" | "unpin"): WriteOutcome {
    return this.mutate((draft, now) => {
      const entries = lists(draft)[ref.list];
      const index = entries.findIndex((entry) => entry.id === ref.id);
      if (index < 0) return { ok: false, code: "unknown_entry" };
      const entry = entries[index]!;
      switch (op) {
        case "delete":
          entries.splice(index, 1);
          return { ok: true };
        case "disable":
          entries[index] = { ...entry, disabledAt: entry.disabledAt ?? iso(now) };
          return { ok: true, ref };
        case "enable": {
          const { disabledAt: _disabled, ...rest } = entry;
          const enabled = { ...rest, rejections: 0 } as DictionaryEntry;
          entries[index] = enabled;
          const replaced = this.disableConflicts(draft, ref.list, enabled, now);
          return { ok: true, ref, ...(replaced ? { code: "replaced" as const } : {}) };
        }
        case "pin":
        case "unpin": {
          const { pinned: _pinned, ...rest } = entry;
          entries[index] = (op === "pin" ? { ...rest, pinned: true } : rest) as DictionaryEntry;
          return { ok: true, ref };
        }
      }
    }, { undoable: true });
  }

  /** "Not this" after the rule acted: one rejection; the rule is disabled once rejections reach max(2, count). */
  reject(ref: DictionaryEntryRef): WriteOutcome {
    return this.mutate((draft, now) => {
      const entries = lists(draft)[ref.list];
      const index = entries.findIndex((entry) => entry.id === ref.id);
      if (index < 0) return { ok: false, code: "unknown_entry" };
      const entry = entries[index]!;
      const rejected = { ...entry, rejections: Math.min(entry.rejections + 1, DICTIONARY_LIMITS.maxCounter) } as DictionaryEntry;
      const disabled = rejected.disabledAt === undefined && !isEntryActive(rejected);
      entries[index] = disabled ? { ...rejected, disabledAt: iso(now) } : rejected;
      return { ok: true, ref, code: disabled ? "rule_disabled" : "rejection_recorded" };
    }, { undoable: true });
  }

  /** Reverses exactly the write that issued `token` (10 minutes, newest 20); `undo_expired` otherwise. */
  undo(token: string): WriteOutcome {
    const now = this.clock();
    const index = this.undos.findIndex((record) => record.token === token);
    const record = index >= 0 ? this.undos[index] : undefined;
    if (!record || record.expires < now) {
      if (record) this.undos.splice(index, 1);
      return { ok: false, revision: this.doc.revision, code: "undo_expired" };
    }
    const outcome = this.mutate((draft) => {
      for (const change of record.changes) {
        const entries = lists(draft)[change.list];
        const at = entries.findIndex((entry) => entry.id === change.id);
        if (change.before === undefined) { if (at >= 0) entries.splice(at, 1); }
        else if (at >= 0) entries[at] = structuredClone(change.before);
        else entries.push(structuredClone(change.before));
      }
      // A later write may have bound the same rule again: two active rules of one key cannot be restored.
      for (const list of DICTIONARY_LISTS) {
        const keys = new Set<string>();
        for (const entry of lists(draft)[list]) {
          if (!isEntryActive(entry)) continue;
          const key = ruleKey(list, entry);
          if (keys.has(key)) return { ok: false, code: "undo_expired" };
          keys.add(key);
        }
      }
      return { ok: true, code: "undone" };
    }, { undoable: false });
    if (outcome.ok) this.undos.splice(this.undos.findIndex((candidate) => candidate.token === token), 1);
    return outcome;
  }

  /** "Forget everything": every list emptied (settings kept), Undo history dropped, the old backup removed. */
  reset(): WriteOutcome {
    const outcome = this.mutate((draft) => {
      for (const list of DICTIONARY_LISTS) lists(draft)[list] = [];
      return { ok: true, code: "reset" };
    }, { undoable: false });
    this.undos.length = 0;
    this.usageDirty = false;
    if (this.persistToDisk) {
      this.backupPending = false;
      try { rmSync(`${this.path}.corrupt`, { force: true }); } catch { /* best effort */ }
    }
    return outcome;
  }

  updateSettings(change: Partial<DictionarySettings>): WriteOutcome {
    return this.mutate((draft) => {
      draft.settings = { ...DEFAULT_DICTIONARY_SETTINGS, ...draft.settings, ...change };
      return { ok: true };
    }, { undoable: false });
  }

  // ------------------------------------------------------------------ internals

  private materialize(content: EntryContent, options: BindOptions, existing?: DictionaryEntry): Omit<DictionaryEntry, "id"> {
    const now = iso(this.clock());
    const base = {
      recognizer: options.recognizer,
      source: options.source,
      count: existing?.count ?? 1,
      rejections: existing?.rejections ?? 0,
      uses: existing?.uses ?? 0,
      createdAt: existing?.createdAt ?? now,
      ...(existing?.lastUsedAt ? { lastUsedAt: existing.lastUsedAt } : {}),
      ...(existing?.disabledAt ? { disabledAt: existing.disabledAt } : {}),
      ...((options.pinned ?? existing?.pinned) !== undefined ? { pinned: (options.pinned ?? existing?.pinned)! } : {}),
    };
    const { list: _list, ...rest } = content;
    return { ...base, ...rest } as Omit<DictionaryEntry, "id">;
  }

  /** Disables other active entries of `list` with `entry`'s rule key; true when one was disabled. */
  private disableConflicts(draft: DictionaryDocument, list: DictionaryList, entry: DictionaryEntry, now: number): boolean {
    if (!isEntryActive(entry)) return false;
    const key = ruleKey(list, entry);
    let replaced = false;
    lists(draft)[list] = lists(draft)[list].map((other) => {
      if (other.id === entry.id || !isEntryActive(other) || ruleKey(list, other) !== key) return other;
      replaced = true;
      return { ...other, disabledAt: iso(now) };
    });
    return replaced;
  }

  private newId(draft: DictionaryDocument, list: DictionaryList): string {
    const taken = new Set(lists(draft)[list].map((entry) => entry.id));
    for (;;) {
      const id = `${ID_PREFIX[list]}${randomBytes(5).toString("hex")}`;
      if (!taken.has(id)) return id;
    }
  }

  private purgeExpired(document: DictionaryDocument, now: number): DictionaryDocument {
    const cutoff = now - DICTIONARY_LIMITS.disabledRetentionDays * DAY_MS;
    for (const list of DICTIONARY_LISTS) {
      lists(document)[list] = lists(document)[list].filter((entry) => {
        if (entry.disabledAt === undefined) return true;
        const at = Date.parse(entry.disabledAt);
        return !Number.isFinite(at) || at >= cutoff;
      });
    }
    return document;
  }

  /**
   * Keeps every list within its cap and the file within 256 KB by evicting unpinned entries the write did
   * not touch: disabled ones first, then the least recently used. False when that is impossible.
   */
  private enforceLimits(draft: DictionaryDocument, protect: ReadonlySet<string>): boolean {
    const evictable = (list: DictionaryList): DictionaryEntry[] => lists(draft)[list]
      .filter((entry) => !entry.pinned && !protect.has(`${list}:${entry.id}`))
      .sort((a, b) => Number(b.disabledAt !== undefined) - Number(a.disabledAt !== undefined) || lastUse(a) - lastUse(b));
    for (const list of DICTIONARY_LISTS) {
      const entries = lists(draft)[list];
      const excess = entries.length - DICTIONARY_LIMITS[list];
      if (excess <= 0) continue;
      const victims = evictable(list).slice(0, excess);
      if (victims.length < excess) return false;
      lists(draft)[list] = entries.filter((entry) => !victims.includes(entry));
    }
    while (Buffer.byteLength(serialize(draft)) > DICTIONARY_LIMITS.fileBytes) {
      const victim = DICTIONARY_LISTS.flatMap((list) => evictable(list).slice(0, 1).map((entry) => ({ list, entry })))
        .sort((a, b) => Number(b.entry.disabledAt !== undefined) - Number(a.entry.disabledAt !== undefined) || lastUse(a.entry) - lastUse(b.entry))[0];
      if (!victim) return false;
      lists(draft)[victim.list] = lists(draft)[victim.list].filter((entry) => entry !== victim.entry);
    }
    return true;
  }

  private mutate(
    change: (draft: DictionaryDocument, now: number) => { ok: true; ref?: DictionaryEntryRef; code?: DictionaryWriteCode } | { ok: false; code: DictionaryWriteCode },
    options: { undoable: boolean },
  ): WriteOutcome {
    const now = this.clock();
    const before = this.doc;
    const draft = structuredClone(before);
    const result = change(draft, now);
    if (!result.ok) return { ok: false, revision: before.revision, code: result.code };
    this.purgeExpired(draft, now);
    const touched = this.changedEntries(before, draft);
    if (!this.enforceLimits(draft, new Set(touched.filter((item) => item.after).map((item) => `${item.list}:${item.id}`)))) {
      return { ok: false, revision: before.revision, code: "limit_reached" };
    }
    // Usage noted since the last flush rides along with this write.
    this.usageDirty = false;
    draft.revision = before.revision + 1;
    this.persist(draft);
    this.doc = draft;
    let undoToken: string | undefined;
    if (options.undoable) {
      const changes = this.changedEntries(before, draft).map(({ list, id, before: previous }) => ({ list, id, before: previous }));
      if (changes.length) {
        undoToken = `u_${randomBytes(12).toString("base64url")}`;
        this.undos.push({ token: undoToken, expires: now + DICTIONARY_LIMITS.undoTtlMs, changes });
        while (this.undos.length > MAX_UNDO) this.undos.shift();
      }
    }
    return { ok: true, revision: draft.revision, ...(result.ref ? { ref: result.ref } : {}), ...(result.code ? { code: result.code } : {}), ...(undoToken ? { undoToken } : {}) };
  }

  private changedEntries(before: DictionaryDocument, after: DictionaryDocument):
    { list: DictionaryList; id: string; before: DictionaryEntry | undefined; after: DictionaryEntry | undefined }[] {
    const out: { list: DictionaryList; id: string; before: DictionaryEntry | undefined; after: DictionaryEntry | undefined }[] = [];
    for (const list of DICTIONARY_LISTS) {
      const old = new Map(lists(before)[list].map((entry) => [entry.id, entry]));
      const next = new Map(lists(after)[list].map((entry) => [entry.id, entry]));
      for (const id of new Set([...old.keys(), ...next.keys()])) {
        const a = old.get(id);
        const b = next.get(id);
        if (JSON.stringify(a) !== JSON.stringify(b)) out.push({ list, id, before: a ? structuredClone(a) : undefined, after: b });
      }
    }
    return out;
  }

  /** Atomic 0600 write in a 0700 directory. A failed write keeps the change in memory (logged, content-free). */
  private persist(document: DictionaryDocument): void {
    if (!this.persistToDisk) return;
    if (!this.writable) {
      this.log("[dictionary] not written: the file could not be read; kept in memory");
      return;
    }
    try {
      this.secureDirectory();
      if (this.backupPending) {
        try {
          copyFileSync(this.path, `${this.path}.corrupt`);
          chmodSync(`${this.path}.corrupt`, 0o600);
          this.log("[dictionary] kept the unusable file as dictionary.json.corrupt");
        } catch {
          // Nothing to keep (the file vanished or cannot be read).
        }
        this.backupPending = false;
      }
      writeFileAtomic(this.path, serialize(document), 0o600);
    } catch (error) {
      this.log(`[dictionary] write failed code=${(error as NodeJS.ErrnoException)?.code ?? "unknown"}; kept in memory`);
    }
  }

  private secureDirectory(): void {
    if (this.directoryChecked || process.platform === "win32") return;
    this.directoryChecked = true;
    try {
      const dir = dirname(this.path);
      if ((statSync(dir).mode & 0o077) !== 0) chmodSync(dir, 0o700);
    } catch {
      // Created by writeFileAtomic with 0700.
    }
  }
}

/** The contract's rule key (recognizer + folded phrase) of content about to be bound. */
export function contentKey(content: EntryContent, recognizer: string): string {
  return ruleKey(content.list, { ...content, recognizer } as unknown as DictionaryEntry);
}

function serialize(document: DictionaryDocument): string {
  return `${JSON.stringify(document)}\n`;
}

// ---------------------------------------------------------------------------------------------
// Recognizer terms (DESIGN4 §6.4)

export interface RankingContext {
  /** The host's app index, in its order. */
  apps?: readonly { name: string; bundleId: string }[];
  /** 0..1 usage weight per bundle id (FileFrecencyStore.score). */
  frecency?: (bundleId: string) => number;
}

/** Ranked recognizer strings for a document (exported for tests; the store's `recognizerTerms` wraps it). */
export function rankRecognizerTerms(document: DictionaryDocument, max: number, context: RankingContext = {}): RecognizerTerm[] {
  const out: RecognizerTerm[] = [];
  const seen = new Set<string>();
  const add = (text: string, lang: RecognizerTerm["lang"]): void => {
    if (out.length >= max) return;
    const trimmed = text.trim();
    const folded = foldPhrase(trimmed);
    if (!folded || seen.has(folded) || VERB_INITIAL.test(folded) || isRefusedPhrase(folded)
      || !isVoiceText(trimmed, DICTIONARY_LIMITS.recognizerTermChars)) return;
    seen.add(folded);
    out.push({ text: trimmed, lang });
  };
  if (document.settings.applyToRecognizer) {
    const terms = document.terms.filter(isEntryActive);
    const byUses = (a: DictionaryEntryBase, b: DictionaryEntryBase) => b.uses - a.uses || lastUse(b) - lastUse(a);
    for (const term of terms.filter((entry) => entry.pinned).sort(byUses)) add(term.text, term.lang);
    const learned: { text: string; lang: RecognizerTerm["lang"]; entry: DictionaryEntryBase }[] = [
      ...terms.filter((entry) => !entry.pinned).map((entry) => ({ text: entry.text, lang: entry.lang, entry })),
      ...document.appNames.filter(isEntryActive).map((entry) => ({ text: entry.display, lang: "any" as const, entry })),
      ...document.fixes.filter(isEntryActive).map((entry) => ({ text: entry.intended, lang: "any" as const, entry })),
    ];
    for (const item of learned.sort((a, b) => Number(Boolean(b.entry.pinned)) - Number(Boolean(a.entry.pinned)) || byUses(a.entry, b.entry))) add(item.text, item.lang);
  }
  const apps = context.apps ?? [];
  const score = (bundleId: string): number => {
    try { return context.frecency?.(bundleId) ?? 0; } catch { return 0; }
  };
  const frecent = apps.map((app, index) => ({ app, index, score: score(app.bundleId) })).filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score || a.index - b.index);
  for (const { app } of frecent) add(app.name, "any");
  for (const app of apps) add(app.name, "any");
  return out;
}
