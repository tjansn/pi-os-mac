import { isHttpUrl, type HostAction } from "./actions.js";
import { isPageUrl } from "./attachments.js";
import {
  DICTIONARY_ENTRY_ID_PATTERN, INSTANT_LIMITS, isRecognizerId, isVoiceText, RECOGNIZERS,
  type FallthroughReason, type InstantDecision, type VoiceHypothesis, type VoiceVia,
} from "./instant.js";

/**
 * Personal dictionary contracts (protocol.md "Personal dictionary", DESIGN4 §6): the schema of
 * `<support>/dictionary.json` (Node is its single writer: 0600 in a 0700 directory, atomic writes,
 * a `revision` that changes on every write), the token-authed `/dictionary/*` routes, the closed
 * `SafeTarget` vocabulary learned rules may act on, and the Node-internal `DictionaryLookup` and
 * `TakeMemo` interfaces the instant lane and the routes share. Swift mirror:
 * `PiOSCore/DictionaryContracts.swift`; fixtures: `shared/fixtures/dictionary/*.json`.
 *
 * Everything in the dictionary is user content (what Tom says, app names, corrections): it is never
 * logged, never sent to a remote classifier, and no agent tool can reach these routes. Log lines are
 * content-free (`learn kind=pick status=learned`). Parsers name fields and codes, never values.
 *
 * Load-time validation is learn-time validation (DESIGN4 §6.8 #8): a hand-edited entry that would be
 * refused by `/dictionary/learn` is dropped on load with a content-free issue.
 */

export const DICTIONARY_VERSION = 1 as const;
export const DICTIONARY_FILE = "dictionary.json";

export const DICTIONARY_LISTS = ["terms", "appNames", "aliases", "fixes"] as const;
/** `terms`: words that bias the recognizers. `appNames`: heard name → app. `aliases`: whole utterance → target. `fixes`: heard → intended text. */
export type DictionaryList = (typeof DICTIONARY_LISTS)[number];

/** Enforced on both sides. Lengths are UTF-16 code units. */
export const DICTIONARY_LIMITS = {
  terms: 500,
  appNames: 300,
  aliases: 200,
  fixes: 300,
  /**
   * Raw `dictionary.json` bytes (checked before parsing). Full lists of long entries can exceed it, so the
   * store keeps every write within it as well (LRU eviction of unpinned entries, else `limit_reached`).
   */
  fileBytes: 262_144,
  /** A heard phrase (appNames.heard, aliases.phrase, fixes.heard, terms.soundsLike). */
  phraseWords: 6,
  phraseChars: 64,
  /** terms.text and fixes.intended. */
  textChars: 64,
  soundsLike: 4,
  /** appNames.display. */
  displayChars: 80,
  /** SafeTarget openURL. */
  urlChars: 512,
  /** User-visible copy in write responses ("Learned: "recast" → Raycast"). */
  lineChars: 160,
  /** count, rejections, uses. */
  maxCounter: 1_000_000,
  /** Disabled entries are kept this long for Undo, then removed. */
  disabledRetentionDays: 30,
  /** POST /dictionary/learn body (the regression texts); the other bodies are ≤ bodyBytes. */
  learnBodyBytes: 16_384,
  bodyBytes: 4_096,
  /** The journal's regression check sent with a learn: ≤ 50 takes whose texts total ≤ 10 KB of UTF-8. */
  regressionTakes: 50,
  regressionTextBytes: 10_240,
  /** GET /dictionary/recognizer-terms?max= (1..100, default 100; Apple's contextual-strings cap). */
  recognizerTerms: 100,
  /** recognizer-terms text (VoiceContext.maximumStringLength on the host). */
  recognizerTermChars: 80,
  correctedTextChars: INSTANT_LIMITS.maxText,
  /** Undo tokens live this long (in memory, the newest 20). */
  undoTtlMs: 600_000,
} as const;

export const LEARN_MODES = ["off", "ask", "picks"] as const;
/** Settings → Dictionary "Learn from my corrections": Off / Ask / Picks learn immediately (default). */
export type LearnMode = (typeof LEARN_MODES)[number];

export interface DictionarySettings {
  learn: LearnMode;
  /** Bias the recognizers with the dictionary (recognizer-terms). */
  applyToRecognizer: boolean;
  /** Tell the agent about matching entries for a misheard voice take (≤ 5, never logged). */
  explainToAgent: boolean;
}

export const DEFAULT_DICTIONARY_SETTINGS: Readonly<DictionarySettings> = { learn: "picks", applyToRecognizer: true, explainToAgent: true };

export const TERM_LANGS = ["any", "en", "de"] as const;
export type TermLang = (typeof TERM_LANGS)[number];
export const TERM_KINDS = ["word", "app"] as const;
export type TermKind = (typeof TERM_KINDS)[number];

/** How an entry came to be (content-free; shown in Settings, used in log lines). */
export const DICTIONARY_SOURCES = ["did-you-mean", "list-pick", "confirm", "no-i-meant", "transcript-edit", "journal-fix", "manual"] as const;
export type DictionarySource = (typeof DICTIONARY_SOURCES)[number];

// ---------------------------------------------------------------------------------------------
// Closed targets

export const SAFE_SYSTEM_OPS = ["volume.set", "volume.step", "volume.mute"] as const;
export type SafeSystemOp = (typeof SAFE_SYSTEM_OPS)[number];

/**
 * What a learned alias may do (DESIGN4 §6.1): open an app from the host index, open an http(s) URL
 * without userinfo (≤ 512), or change the volume (`volume.set` 0..1, `volume.step` nonzero within ±1,
 * `volume.mute` true/false/absent — the same ranges as the host's LauncherPolicy). Checked on load, on
 * learn and on use; the host checks the resulting HostAction again. No file, delete or agent target.
 */
export type SafeTarget =
  | { kind: "openApp"; bundleId: string }
  | { kind: "openURL"; url: string }
  | { kind: "system"; op: SafeSystemOp; value?: number | boolean };

const BUNDLE_ID = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;

export function isBundleId(value: unknown): value is string {
  return typeof value === "string" && value.length <= 255 && BUNDLE_ID.test(value);
}

export function parseSafeTarget(value: unknown): SafeTarget | null {
  if (!isRecord(value)) return null;
  switch (value.kind) {
    case "openApp":
      return isBundleId(value.bundleId) ? { kind: "openApp", bundleId: value.bundleId } : null;
    case "openURL":
      return typeof value.url === "string" && value.url.length <= DICTIONARY_LIMITS.urlChars && isHttpUrl(value.url) && isPageUrl(value.url)
        ? { kind: "openURL", url: value.url }
        : null;
    case "system": {
      const v = value.value;
      switch (value.op) {
        case "volume.set":
          return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1 ? { kind: "system", op: "volume.set", value: v } : null;
        case "volume.step":
          return typeof v === "number" && Number.isFinite(v) && v !== 0 && Math.abs(v) <= 1 ? { kind: "system", op: "volume.step", value: v } : null;
        case "volume.mute":
          if (!present(v)) return { kind: "system", op: "volume.mute" };
          return typeof v === "boolean" ? { kind: "system", op: "volume.mute", value: v } : null;
        default:
          return null;
      }
    }
    default:
      return null;
  }
}

/** The HostAction a target becomes (the host validates it with LauncherPolicy before acting). */
export function safeTargetToHostAction(target: SafeTarget): Extract<HostAction, { type: "openApp" | "openURL" | "system" }> {
  switch (target.kind) {
    case "openApp": return { type: "openApp", bundleId: target.bundleId };
    case "openURL": return { type: "openURL", url: target.url };
    case "system": return target.value === undefined ? { type: "system", op: target.op } : { type: "system", op: target.op, value: target.value };
  }
}

// ---------------------------------------------------------------------------------------------
// Phrases: folding and refused words

/**
 * Canonical form of a heard phrase (DESIGN4 §6.1 "Folding"): NFD, combining marks removed, ß → ss,
 * lowercase per code point (no context rules, so Swift folds identically), apostrophes removed, every
 * other non-letter/non-number a space, spaces collapsed. Wrapper particles ("bitte", "please") are the
 * instant lane's job (spokenCore) before a phrase is stored or looked up.
 */
export function foldPhrase(text: string): string {
  let out = "";
  for (const char of text.normalize("NFD")) {
    if (/\p{M}/u.test(char)) continue;
    if (char === "ß" || char === "ẞ") { out += "ss"; continue; }
    if (char === "'" || char === "’") continue;
    const lower = char.toLowerCase();
    out += /^[\p{L}\p{N}]+$/u.test(lower) ? lower : " ";
  }
  return out.split(" ").filter(Boolean).join(" ");
}

/**
 * Deletion vocabulary (EN/DE, folded): a phrase, intended text or term containing any of these words is
 * refused (DESIGN4 §6.8 #2). The instant lane's full deletion policy runs on top; this list is the part
 * both the store and the host can check without the grammar.
 */
export const DELETION_WORDS: readonly string[] = [
  "delete", "deletes", "deleted", "deleting", "deletion", "del", "remove", "removes", "removed", "removing",
  "erase", "erases", "erased", "erasing", "trash", "trashes", "trashed", "rm", "rmdir", "unlink", "shred", "shredded",
  "wipe", "wipes", "wiped", "purge", "purged", "destroy", "destroyed", "uninstall", "uninstalled", "recycle",
  "loschen", "losche", "losch", "loscht", "geloscht", "loschung", "entfernen", "entferne", "entfern", "entfernt",
  "papierkorb", "mulleimer", "vernichten", "vernichte", "deinstallieren", "deinstalliere", "deinstalliert",
  "leeren", "leere", "leert", "wegwerfen", "wegschmeissen", "schreddern",
  "discard", "discards", "discarded", "discarding", "binned", "verwerfen", "verwerfe", "verwirf", "verwirft", "verworfen",
  "mulltonne", "abfalleimer", "weggeworfen", "weggeschmissen",
];

/**
 * Deletion phrasings that no single word gives away (EN/DE): "throw … away", "get rid of", "bin the …",
 * "in the bin", "wirf/schmeiß … weg", "in den Müll". Matched against ` ${folded} ` (spaces as word
 * boundaries, so both runtimes agree); "Bin ich da" is German, not "bin the". The Swift mirror
 * (`DictionaryPhrase.deletionPhrases`) uses the same sources.
 */
export const DELETION_PHRASES: readonly string[] = [
  " (?:throw|throws|threw|thrown|throwing|toss|tosses|tossed|tossing|chuck|chucks|chucked)(?: [^ ]+){0,4} (?:away|out) ",
  " (?:get|gets|got|getting) rid of ",
  "^ bin (?:the|my|this|that|these|those|all|it|them|everything) ",
  " (?:in|into|to) (?:the |my )?(?:bin|wastebasket|garbage|rubbish) ",
  " (?:wirf|wirft|werfe|werfen|werf|schmeiss|schmeisst|schmeisse|schmeissen)(?: [^ ]+){0,4} weg ",
  " (?:in|ins|zum|in den|in die|in meinen|in meine) (?:mull|mulleimer|mulltonne|abfall|abfalleimer|tonne) ",
];

/**
 * Cancel/confirm words (EN/DE, folded): a phrase made only of these is refused, so a learned rule can
 * never take over "yes", "nein" or "undo" (they answer the bar's own prompts).
 */
export const CONTROL_WORDS: readonly string[] = [
  "yes", "yeah", "yep", "no", "nope", "ok", "okay", "cancel", "stop", "abort", "confirm", "undo",
  "ja", "jawohl", "nein", "abbrechen", "abbruch", "stopp", "bestatigen", "bestatige", "ruckgangig",
];

const DELETION = new Set(DELETION_WORDS);
const DELETION_PHRASE_PATTERNS = DELETION_PHRASES.map((source) => new RegExp(source));
const CONTROL_ONLY = new Set(CONTROL_WORDS);

/** True when a text (folded or not) contains a deletion word or a deletion phrasing (EN/DE). */
export function mentionsDeletionVocabulary(text: string): boolean {
  const folded = foldPhrase(text);
  if (folded.split(" ").some((word) => DELETION.has(word))) return true;
  const padded = ` ${folded} `;
  return DELETION_PHRASE_PATTERNS.some((pattern) => pattern.test(padded));
}

/** True when a phrase (folded or not) contains deletion vocabulary or consists only of cancel/confirm words. */
export function isRefusedPhrase(text: string): boolean {
  const words = foldPhrase(text).split(" ").filter(Boolean);
  return mentionsDeletionVocabulary(text) || (words.length > 0 && words.every((word) => CONTROL_ONLY.has(word)));
}

/** A stored heard phrase: already folded, 1..64 characters, 1..6 words. */
export function isFoldedPhrase(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= DICTIONARY_LIMITS.phraseChars
    && foldPhrase(value) === value && value.split(" ").length <= DICTIONARY_LIMITS.phraseWords;
}

/** Display text (terms.text, fixes.intended): single-line, 1..64, ≤ 6 words. */
function isShortText(value: unknown): value is string {
  return isVoiceText(value, DICTIONARY_LIMITS.textChars) && foldPhrase(value).length > 0
    && foldPhrase(value).split(" ").length <= DICTIONARY_LIMITS.phraseWords;
}

// ---------------------------------------------------------------------------------------------
// Document

export interface DictionaryEntryBase {
  /** DICTIONARY_ENTRY_ID_PATTERN; unique within its list. */
  id: string;
  /** `any` (typed and manual entries) or the recognizer id the rule was learned from (DESIGN4 C8). */
  recognizer: string;
  source: DictionarySource;
  /** Explicit teachings (picks, confirms, Remember), 1..1,000,000. */
  count: number;
  /** "Not this", Esc or "no" after the rule acted, 0..1,000,000. */
  rejections: number;
  /** Times the rule decided, 0..1,000,000. */
  uses: number;
  /** ISO-8601 with offset. */
  createdAt: string;
  lastUsedAt?: string;
  /** Set when replaced, undone or switched off; kept 30 days for Undo, inactive meanwhile. */
  disabledAt?: string;
  /** Pinned entries survive LRU eviction and rank first for the recognizers. */
  pinned?: boolean;
}

export interface DictionaryTerm extends DictionaryEntryBase {
  /** As shown and as given to the recognizers ("Ghostty"). */
  text: string;
  /** Folded post-ASR alias forms ("gousti"), ≤ 4; never given to a recognizer. */
  soundsLike: string[];
  lang: TermLang;
  kind: TermKind;
  /** `kind: "app"`: the app this word names. */
  bundleId?: string;
}

export interface LearnedAppName extends DictionaryEntryBase {
  /** Folded open target as heard ("recast"). */
  heard: string;
  bundleId: string;
  /** The app's proper name ("Raycast"), ≤ 80. */
  display: string;
  /** Bundle id of an installed app whose exact name `heard` is: the rule shadows it (explicitly confirmed). */
  shadows?: string;
}

export interface LearnedAlias extends DictionaryEntryBase {
  /** Folded whole utterance ("mach kein note auf"). */
  phrase: string;
  target: SafeTarget;
}

export interface LearnedFix extends DictionaryEntryBase {
  /** Folded span as heard ("clod"). */
  heard: string;
  /** What was meant ("Claude"). */
  intended: string;
}

export interface DictionaryDocument {
  version: typeof DICTIONARY_VERSION;
  revision: number;
  settings: DictionarySettings;
  terms: DictionaryTerm[];
  appNames: LearnedAppName[];
  aliases: LearnedAlias[];
  fixes: LearnedFix[];
}

export type DictionaryEntry = DictionaryTerm | LearnedAppName | LearnedAlias | LearnedFix;

export interface DictionaryEntryRef { list: DictionaryList; id: string }

/** A rule decides only while enabled and not rejected out (DESIGN4 §6.1 lifecycle). */
export function isEntryActive(entry: Pick<DictionaryEntryBase, "disabledAt" | "count" | "rejections">): boolean {
  return entry.disabledAt === undefined && entry.rejections < Math.max(2, entry.count);
}

/** Entry scope `any` applies to every request; otherwise only to that recognizer's hypotheses. */
export function recognizerApplies(entryRecognizer: string, recognizer: string): boolean {
  return entryRecognizer === RECOGNIZERS.any || entryRecognizer === recognizer;
}

export function emptyDictionary(): DictionaryDocument {
  return { version: DICTIONARY_VERSION, revision: 0, settings: { ...DEFAULT_DICTIONARY_SETTINGS }, terms: [], appNames: [], aliases: [], fixes: [] };
}

/** Content-free reasons an entry was dropped on load (or a write refused). */
export const DICTIONARY_ISSUE_CODES = [
  "invalid_entry",
  "invalid_id",
  "invalid_phrase",
  "refused_phrase",
  "unsafe_target",
  "invalid_recognizer",
  "invalid_counter",
  "invalid_timestamp",
  "invalid_settings",
  "duplicate_id",
  "duplicate_rule",
  "over_limit",
] as const;
export type DictionaryIssueCode = (typeof DICTIONARY_ISSUE_CODES)[number];

/** `path` is a list and index (`aliases[3]`) or `settings`, never a value. */
export interface DictionaryIssue { path: string; code: DictionaryIssueCode }

export type DictionaryParse =
  | { ok: true; value: DictionaryDocument; issues: DictionaryIssue[] }
  | { ok: false; error: string };

const ISO_TIMESTAMP = /^\d{4}-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-](\d{2}):(\d{2}))$/;

/** `YYYY-MM-DDTHH:MM:SS[.f{1,9}](Z|±HH:MM)` with month 1–12, day 1–31, hour ≤ 23, minute and second ≤ 59 (Swift checks the same). */
export function isTimestamp(value: unknown): value is string {
  const match = typeof value === "string" ? ISO_TIMESTAMP.exec(value) : null;
  if (!match) return false;
  const [month, day, hour, minute, second] = match.slice(1, 6).map(Number) as [number, number, number, number, number];
  const offsetOk = match[6] === undefined || (Number(match[6]) <= 23 && Number(match[7]) <= 59);
  return month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour <= 23 && minute <= 59 && second <= 59 && offsetOk;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function present(value: unknown): boolean {
  return value !== undefined && value !== null;
}
function oneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}
function counter(value: unknown, min: number): value is number {
  return Number.isSafeInteger(value) && (value as number) >= min && (value as number) <= DICTIONARY_LIMITS.maxCounter;
}
export function isEntryId(value: unknown): value is string {
  return typeof value === "string" && DICTIONARY_ENTRY_ID_PATTERN.test(value);
}

type Content<T extends DictionaryEntry> = Omit<T, keyof DictionaryEntryBase>;
type ContentResult<T extends DictionaryEntry> = { ok: true; value: Content<T> } | { ok: false; code: DictionaryIssueCode };

/** A heard phrase field: folded, in bounds, not refused. */
function phraseCode(value: unknown): DictionaryIssueCode | null {
  if (!isFoldedPhrase(value)) return "invalid_phrase";
  return isRefusedPhrase(value) ? "refused_phrase" : null;
}

function termContent(v: Record<string, unknown>): ContentResult<DictionaryTerm> {
  if (!isShortText(v.text)) return { ok: false, code: "invalid_phrase" };
  if (isRefusedPhrase(v.text)) return { ok: false, code: "refused_phrase" };
  const soundsLike = present(v.soundsLike) ? v.soundsLike : [];
  if (!Array.isArray(soundsLike) || soundsLike.length > DICTIONARY_LIMITS.soundsLike) return { ok: false, code: "invalid_phrase" };
  for (const form of soundsLike) {
    const code = phraseCode(form);
    if (code) return { ok: false, code };
  }
  if (!oneOf(TERM_LANGS, v.lang) || !oneOf(TERM_KINDS, v.kind)) return { ok: false, code: "invalid_entry" };
  if (present(v.bundleId) && !isBundleId(v.bundleId)) return { ok: false, code: "unsafe_target" };
  return {
    ok: true,
    value: { text: v.text, soundsLike: [...soundsLike as string[]], lang: v.lang, kind: v.kind, ...(present(v.bundleId) ? { bundleId: v.bundleId as string } : {}) },
  };
}

function appNameContent(v: Record<string, unknown>): ContentResult<LearnedAppName> {
  const code = phraseCode(v.heard);
  if (code) return { ok: false, code };
  if (!isBundleId(v.bundleId)) return { ok: false, code: "unsafe_target" };
  if (!isVoiceText(v.display, DICTIONARY_LIMITS.displayChars)) return { ok: false, code: "invalid_entry" };
  if (present(v.shadows) && !isBundleId(v.shadows)) return { ok: false, code: "invalid_entry" };
  return {
    ok: true,
    value: { heard: v.heard as string, bundleId: v.bundleId, display: v.display, ...(present(v.shadows) ? { shadows: v.shadows as string } : {}) },
  };
}

function aliasContent(v: Record<string, unknown>): ContentResult<LearnedAlias> {
  const code = phraseCode(v.phrase);
  if (code) return { ok: false, code };
  const target = parseSafeTarget(v.target);
  if (!target) return { ok: false, code: "unsafe_target" };
  return { ok: true, value: { phrase: v.phrase as string, target } };
}

function fixContent(v: Record<string, unknown>): ContentResult<LearnedFix> {
  const code = phraseCode(v.heard);
  if (code) return { ok: false, code };
  if (!isShortText(v.intended)) return { ok: false, code: "invalid_phrase" };
  if (isRefusedPhrase(v.intended)) return { ok: false, code: "refused_phrase" };
  return { ok: true, value: { heard: v.heard as string, intended: v.intended } };
}

const CONTENT: { [L in DictionaryList]: (v: Record<string, unknown>) => ContentResult<DictionaryEntry> } = {
  terms: termContent,
  appNames: appNameContent,
  aliases: aliasContent,
  fixes: fixContent,
};

/** The folded key two active rules of one list may not share (with the recognizer). */
export function ruleKey(list: DictionaryList, entry: DictionaryEntry): string {
  const phrase = list === "terms" ? foldPhrase((entry as DictionaryTerm).text)
    : list === "aliases" ? (entry as LearnedAlias).phrase
    : (entry as LearnedAppName | LearnedFix).heard;
  return `${entry.recognizer}\u0000${phrase}`;
}

/** One stored entry of `list`, checked in a fixed order (Swift checks in the same order). */
export function parseDictionaryEntry(list: DictionaryList, value: unknown): { ok: true; value: DictionaryEntry } | { ok: false; code: DictionaryIssueCode } {
  if (!isRecord(value)) return { ok: false, code: "invalid_entry" };
  if (!isEntryId(value.id)) return { ok: false, code: "invalid_id" };
  const content = CONTENT[list](value);
  if (!content.ok) return content;
  if (!isRecognizerId(value.recognizer)) return { ok: false, code: "invalid_recognizer" };
  if (!oneOf(DICTIONARY_SOURCES, value.source)) return { ok: false, code: "invalid_entry" };
  if (!counter(value.count, 1) || !counter(value.rejections, 0) || !counter(value.uses, 0)) return { ok: false, code: "invalid_counter" };
  if (!isTimestamp(value.createdAt) || (present(value.lastUsedAt) && !isTimestamp(value.lastUsedAt))
    || (present(value.disabledAt) && !isTimestamp(value.disabledAt))) return { ok: false, code: "invalid_timestamp" };
  if (present(value.pinned) && typeof value.pinned !== "boolean") return { ok: false, code: "invalid_entry" };
  const entry = {
    id: value.id,
    ...content.value,
    recognizer: value.recognizer,
    source: value.source,
    count: value.count,
    rejections: value.rejections,
    uses: value.uses,
    createdAt: value.createdAt,
    ...(present(value.lastUsedAt) ? { lastUsedAt: value.lastUsedAt as string } : {}),
    ...(present(value.disabledAt) ? { disabledAt: value.disabledAt as string } : {}),
    ...(present(value.pinned) ? { pinned: value.pinned as boolean } : {}),
  } as DictionaryEntry;
  return { ok: true, value: entry };
}

export function parseDictionarySettings(value: unknown): DictionarySettings | null {
  if (!present(value)) return { ...DEFAULT_DICTIONARY_SETTINGS };
  if (!isRecord(value)) return null;
  const settings = { ...DEFAULT_DICTIONARY_SETTINGS };
  if (present(value.learn)) {
    if (!oneOf(LEARN_MODES, value.learn)) return null;
    settings.learn = value.learn;
  }
  for (const key of ["applyToRecognizer", "explainToAgent"] as const) {
    if (!present(value[key])) continue;
    if (typeof value[key] !== "boolean") return null;
    settings[key] = value[key];
  }
  return settings;
}

/**
 * Parses `dictionary.json` (and `GET /dictionary`). The document fails as a whole only for a wrong
 * shape (not an object, `version` ≠ 1, a bad `revision`, a list that is not an array). Bad entries are
 * dropped with an issue, in this order per list: entry checks, duplicate ids, two active rules with the
 * same folded key and recognizer (the later is dropped), then entries beyond the list's cap. Bad
 * settings fall back to the defaults with an `invalid_settings` issue. Absent settings or lists are
 * defaults/empty.
 */
export function parseDictionary(value: unknown): DictionaryParse {
  if (!isRecord(value)) return { ok: false, error: "dictionary must be an object" };
  if (value.version !== DICTIONARY_VERSION) return { ok: false, error: "unsupported dictionary version" };
  if (!Number.isSafeInteger(value.revision) || (value.revision as number) < 0) return { ok: false, error: "revision must be a non-negative integer" };
  const issues: DictionaryIssue[] = [];
  let settings = parseDictionarySettings(value.settings);
  if (!settings) {
    issues.push({ path: "settings", code: "invalid_settings" });
    settings = { ...DEFAULT_DICTIONARY_SETTINGS };
  }
  const document: DictionaryDocument = { ...emptyDictionary(), revision: value.revision as number, settings };
  for (const list of DICTIONARY_LISTS) {
    const raw = present(value[list]) ? value[list] : [];
    if (!Array.isArray(raw)) return { ok: false, error: `${list} must be an array` };
    const ids = new Set<string>();
    const keys = new Set<string>();
    const kept: DictionaryEntry[] = [];
    raw.forEach((item, index) => {
      const path = `${list}[${index}]`;
      const parsed = parseDictionaryEntry(list, item);
      if (!parsed.ok) { issues.push({ path, code: parsed.code }); return; }
      const key = isEntryActive(parsed.value) ? ruleKey(list, parsed.value) : undefined;
      if (ids.has(parsed.value.id)) { issues.push({ path, code: "duplicate_id" }); return; }
      if (key !== undefined && keys.has(key)) { issues.push({ path, code: "duplicate_rule" }); return; }
      if (kept.length >= DICTIONARY_LIMITS[list]) { issues.push({ path, code: "over_limit" }); return; }
      ids.add(parsed.value.id);
      if (key !== undefined) keys.add(key);
      kept.push(parsed.value);
    });
    (document as unknown as Record<DictionaryList, DictionaryEntry[]>)[list] = kept;
  }
  return { ok: true, value: document, issues };
}

// ---------------------------------------------------------------------------------------------
// Routes (token-authed like /instant; no agent tool reaches them)

export const DICTIONARY_ROUTES = {
  learn: "POST /dictionary/learn",
  get: "GET /dictionary",
  edit: "POST /dictionary/edit",
  recognizerTerms: "GET /dictionary/recognizer-terms",
} as const;

export const LEARN_KINDS = ["pick", "confirm", "no_i_meant", "edit", "reject"] as const;
/**
 * `pick`: a did-you-mean or ambiguity-list row (explicit, learns at once). `confirm`: Return on a
 * one-Return confirm (explicit). `no_i_meant`: "No, I meant X" after a wrong act (inferred, asks once).
 * `edit`: the check state's corrected transcript (inferred, asks once). `reject`: "Not this", Esc or "no"
 * after a sound-tier, learned or peer act (two rejections disable a rule).
 */
export type LearnKind = (typeof LEARN_KINDS)[number];

/** One accepted journal take for the regression check (DESIGN4 §6.7): heard text and what it did. */
export interface RegressionTake {
  /** The heard text, 1..200. */
  text: string;
  /** The recognizer that heard it. */
  source: string;
  /** What the take did and the user kept; absent for an agent hand-off. */
  target?: SafeTarget;
}

/**
 * POST /dictionary/learn (≤ 16 KB). `takeId` must be in Node's take memo (the last 20 takes, 2 minutes);
 * `pick` and `confirm` accept only a bundle id that take offered or acted on; `edit` and `no_i_meant`
 * only a target the lane itself resolves from `correctedText`.
 */
export interface DictionaryLearnRequest {
  takeId: string;
  kind: LearnKind;
  /** `pick` (required), `confirm` (optional: the acted app). Forbidden otherwise. */
  bundleId?: string;
  /** `edit` and `no_i_meant` (required, ≤ 500). Forbidden otherwise. */
  correctedText?: string;
  /** `reject` only (optional): the learned rule that acted (`voice.learnedEntryId`). */
  entryId?: string;
  /** The user already answered this take's "Remember …?" with Remember. */
  confirmed?: boolean;
  /**
   * Accepted journal takes (opt-in journal only; ≤ 50, texts ≤ 10 KB of UTF-8): Node reports which ones the
   * new rule would change. The host drops the oldest takes until the body fits 16 KB.
   */
  regression?: RegressionTake[];
}

export const DICTIONARY_WRITE_STATUSES = ["learned", "updated", "needs_confirmation", "refused"] as const;
/** `learned` (learn), `updated` (edit), `needs_confirmation` (ask the user once, then resend with `confirmed`), `refused`. */
export type DictionaryWriteStatus = (typeof DICTIONARY_WRITE_STATUSES)[number];

/** Content-free outcome codes of learn and edit (open set for receivers; DICTIONARY_ISSUE_CODES may appear too). */
export const DICTIONARY_WRITE_CODES = [
  // refused
  "unknown_take", "not_offered", "unresolved", "nothing_to_learn", "alias_guard", "learning_off",
  "unknown_entry", "undo_expired", "limit_reached",
  // needs_confirmation
  "ask_mode", "inferred", "common_word", "shadows_app", "regression",
  // learned / updated (informational)
  "rejection_recorded", "rule_disabled", "replaced", "undone", "reset",
] as const;
export type DictionaryWriteCode = (typeof DICTIONARY_WRITE_CODES)[number] | DictionaryIssueCode;

/**
 * Response of learn and edit (HTTP 200; a bad body is 400 `invalid_arguments`). The "learned footer"
 * is `line` plus `undoToken`: *Learned: "recast" → Raycast · Undo*; Undo sends edit `{op: "undo"}`.
 */
export interface DictionaryWriteResponse {
  status: DictionaryWriteStatus;
  code?: DictionaryWriteCode;
  /** The entry learned, changed or awaiting confirmation. */
  entry?: DictionaryEntryRef;
  /** User-visible copy, ≤ 160 (learn always sets it). May quote heard text: shown, never logged. */
  line?: string;
  /** `learned`/`updated` only: undoes exactly this write for 10 minutes. */
  undoToken?: string;
  /** `needs_confirmation` `regression`: indices into the request's `regression` the rule would change. */
  conflicts?: number[];
  /** The document revision after the call (unchanged when nothing was written). */
  revision: number;
}

export const DICTIONARY_EDIT_OPS = ["upsert", "delete", "disable", "enable", "pin", "unpin", "undo", "reset", "settings"] as const;
export type DictionaryEditOp = (typeof DICTIONARY_EDIT_OPS)[number];

/** Settings → Dictionary entry input (Node folds phrases, sets source "manual", counters and times). */
export type DictionaryEntryInput =
  | { list: "terms"; id?: string; text: string; soundsLike?: string[]; lang?: TermLang; kind?: TermKind; bundleId?: string; recognizer?: string; pinned?: boolean }
  | { list: "appNames"; id?: string; heard: string; bundleId: string; display: string; recognizer?: string; pinned?: boolean }
  | { list: "aliases"; id?: string; phrase: string; target: SafeTarget; recognizer?: string; pinned?: boolean }
  | { list: "fixes"; id?: string; heard: string; intended: string; recognizer?: string; pinned?: boolean };

/**
 * POST /dictionary/edit (≤ 4 KB). Settings and the bar's Undo. `upsert` with an `id` updates that
 * entry; without one it adds (a "journal-fix" source marks a Settings → Recent takes → Fix).
 * `delete` forgets one entry now; `reset` ("Forget everything") empties every list and needs
 * `confirmed: true`; `undo` reverses the write that issued the token.
 */
export type DictionaryEditRequest =
  | { op: "upsert"; entry: DictionaryEntryInput; source?: "manual" | "journal-fix"; confirmed?: boolean }
  | { op: "delete" | "disable" | "enable" | "pin" | "unpin"; list: DictionaryList; id: string }
  | { op: "undo"; undoToken: string }
  | { op: "reset"; confirmed: true }
  | { op: "settings"; settings: Partial<DictionarySettings> };

/** GET /dictionary/recognizer-terms?max=N: ranked strings for the recognizers (DESIGN4 §6.4). */
export interface RecognizerTerm { text: string; lang: TermLang }
export interface RecognizerTermsResponse { revision: number; terms: RecognizerTerm[] }

export type DictionaryWireParse<T> = { ok: true; value: T } | { ok: false; error: string };

const UNDO_TOKEN = /^[A-Za-z0-9_-]{16,128}$/;
const UTF8 = new TextEncoder();
const TAKE_ID = /^[A-Za-z0-9_-]{1,128}$/;

export function isUndoToken(value: unknown): value is string {
  return typeof value === "string" && UNDO_TOKEN.test(value);
}

function parseRegression(value: unknown): DictionaryWireParse<RegressionTake[] | undefined> {
  if (!present(value)) return { ok: true, value: undefined };
  if (!Array.isArray(value) || value.length > DICTIONARY_LIMITS.regressionTakes) return { ok: false, error: "regression must be an array of at most 50 takes" };
  const takes: RegressionTake[] = [];
  let bytes = 0;
  for (const [index, item] of value.entries()) {
    if (!isRecord(item) || !isVoiceText(item.text) || !isRecognizerId(item.source)) return { ok: false, error: `regression[${index}] is invalid` };
    const take: RegressionTake = { text: item.text, source: item.source };
    if (present(item.target)) {
      const target = parseSafeTarget(item.target);
      if (!target) return { ok: false, error: `regression[${index}].target is invalid` };
      take.target = target;
    }
    bytes += UTF8.encode(item.text).length;
    takes.push(take);
  }
  if (bytes > DICTIONARY_LIMITS.regressionTextBytes) return { ok: false, error: "regression texts exceed 10 KB" };
  return { ok: true, value: takes };
}

/** Strict validation of a learn body (400 on failure). Fields that do not belong to `kind` are errors. */
export function parseLearnRequest(value: unknown): DictionaryWireParse<DictionaryLearnRequest> {
  if (!isRecord(value)) return { ok: false, error: "Body must be a JSON object" };
  if (typeof value.takeId !== "string" || !TAKE_ID.test(value.takeId)) return { ok: false, error: "takeId is required" };
  if (!oneOf(LEARN_KINDS, value.kind)) return { ok: false, error: "kind must be pick, confirm, no_i_meant, edit or reject" };
  const kind = value.kind;
  const request: DictionaryLearnRequest = { takeId: value.takeId, kind };
  if (present(value.bundleId)) {
    if (kind !== "pick" && kind !== "confirm") return { ok: false, error: "bundleId is only allowed with pick or confirm" };
    if (!isBundleId(value.bundleId)) return { ok: false, error: "bundleId is invalid" };
    request.bundleId = value.bundleId;
  } else if (kind === "pick") {
    return { ok: false, error: "pick needs bundleId" };
  }
  if (present(value.correctedText)) {
    if (kind !== "edit" && kind !== "no_i_meant") return { ok: false, error: "correctedText is only allowed with edit or no_i_meant" };
    if (!isVoiceText(value.correctedText, DICTIONARY_LIMITS.correctedTextChars)) return { ok: false, error: "correctedText must be 1..500 characters of single-line text" };
    request.correctedText = value.correctedText;
  } else if (kind === "edit" || kind === "no_i_meant") {
    return { ok: false, error: `${kind} needs correctedText` };
  }
  if (present(value.entryId)) {
    if (kind !== "reject") return { ok: false, error: "entryId is only allowed with reject" };
    if (!isEntryId(value.entryId)) return { ok: false, error: "entryId is invalid" };
    request.entryId = value.entryId;
  }
  if (present(value.confirmed)) {
    if (typeof value.confirmed !== "boolean") return { ok: false, error: "confirmed must be a boolean" };
    request.confirmed = value.confirmed;
  }
  const regression = parseRegression(value.regression);
  if (!regression.ok) return regression;
  if (regression.value) request.regression = regression.value;
  return { ok: true, value: request };
}

function parseEntryInput(value: unknown): DictionaryWireParse<DictionaryEntryInput> {
  if (!isRecord(value) || !oneOf(DICTIONARY_LISTS, value.list)) return { ok: false, error: "entry.list must be terms, appNames, aliases or fixes" };
  if (present(value.id) && !isEntryId(value.id)) return { ok: false, error: "entry.id is invalid" };
  if (present(value.recognizer) && !isRecognizerId(value.recognizer)) return { ok: false, error: "entry.recognizer is invalid" };
  if (present(value.pinned) && typeof value.pinned !== "boolean") return { ok: false, error: "entry.pinned must be a boolean" };
  const common = {
    ...(present(value.id) ? { id: value.id as string } : {}),
    ...(present(value.recognizer) ? { recognizer: value.recognizer as string } : {}),
    ...(present(value.pinned) ? { pinned: value.pinned as boolean } : {}),
  };
  // Input phrases may be unfolded (typed in Settings): they must fold to a valid, unrefused phrase.
  const phrase = (field: string, raw: unknown): DictionaryWireParse<string> => {
    if (!isVoiceText(raw, DICTIONARY_LIMITS.textChars)) return { ok: false, error: `entry.${field} is invalid` };
    const folded = foldPhrase(raw);
    if (!isFoldedPhrase(folded)) return { ok: false, error: `entry.${field} is invalid` };
    if (isRefusedPhrase(folded)) return { ok: false, error: `entry.${field} is refused` };
    return { ok: true, value: folded };
  };
  switch (value.list) {
    case "terms": {
      // Settings input may be unfolded: soundsLike forms are folded first, then checked like stored ones.
      const soundsLike = Array.isArray(value.soundsLike) ? value.soundsLike.map((form) => (typeof form === "string" ? foldPhrase(form) : form)) : value.soundsLike;
      const content = termContent({ ...value, soundsLike, lang: value.lang ?? "any", kind: value.kind ?? "word" });
      if (!content.ok) return { ok: false, error: `entry is invalid (${content.code})` };
      return { ok: true, value: { list: "terms", ...common, ...content.value } };
    }
    case "appNames": {
      const heard = phrase("heard", value.heard);
      if (!heard.ok) return heard;
      if (!isBundleId(value.bundleId)) return { ok: false, error: "entry.bundleId is invalid" };
      if (!isVoiceText(value.display, DICTIONARY_LIMITS.displayChars)) return { ok: false, error: "entry.display is invalid" };
      return { ok: true, value: { list: "appNames", ...common, heard: heard.value, bundleId: value.bundleId, display: value.display } };
    }
    case "aliases": {
      const phraseValue = phrase("phrase", value.phrase);
      if (!phraseValue.ok) return phraseValue;
      const target = parseSafeTarget(value.target);
      if (!target) return { ok: false, error: "entry.target is not a safe target" };
      return { ok: true, value: { list: "aliases", ...common, phrase: phraseValue.value, target } };
    }
    case "fixes": {
      const heard = phrase("heard", value.heard);
      if (!heard.ok) return heard;
      if (!isShortText(value.intended)) return { ok: false, error: "entry.intended is invalid" };
      if (isRefusedPhrase(value.intended)) return { ok: false, error: "entry.intended is refused" };
      return { ok: true, value: { list: "fixes", ...common, heard: heard.value, intended: value.intended } };
    }
  }
}

/** Strict validation of an edit body (400 on failure; never echoes values). */
export function parseEditRequest(value: unknown): DictionaryWireParse<DictionaryEditRequest> {
  if (!isRecord(value) || !oneOf(DICTIONARY_EDIT_OPS, value.op)) return { ok: false, error: "op must be upsert, delete, disable, enable, pin, unpin, undo, reset or settings" };
  switch (value.op) {
    case "upsert": {
      const entry = parseEntryInput(value.entry);
      if (!entry.ok) return entry;
      if (present(value.source) && value.source !== "manual" && value.source !== "journal-fix") return { ok: false, error: "source must be manual or journal-fix" };
      if (present(value.confirmed) && typeof value.confirmed !== "boolean") return { ok: false, error: "confirmed must be a boolean" };
      return {
        ok: true,
        value: {
          op: "upsert", entry: entry.value,
          ...(present(value.source) ? { source: value.source as "manual" | "journal-fix" } : {}),
          ...(present(value.confirmed) ? { confirmed: value.confirmed as boolean } : {}),
        },
      };
    }
    case "delete":
    case "disable":
    case "enable":
    case "pin":
    case "unpin":
      if (!oneOf(DICTIONARY_LISTS, value.list)) return { ok: false, error: "list must be terms, appNames, aliases or fixes" };
      if (!isEntryId(value.id)) return { ok: false, error: "id is invalid" };
      return { ok: true, value: { op: value.op, list: value.list, id: value.id } };
    case "undo":
      return isUndoToken(value.undoToken) ? { ok: true, value: { op: "undo", undoToken: value.undoToken } } : { ok: false, error: "undoToken is invalid" };
    case "reset":
      return value.confirmed === true ? { ok: true, value: { op: "reset", confirmed: true } } : { ok: false, error: "reset needs confirmed: true" };
    case "settings": {
      if (!isRecord(value.settings)) return { ok: false, error: "settings must be an object" };
      const settings: Partial<DictionarySettings> = {};
      if (present(value.settings.learn)) {
        if (!oneOf(LEARN_MODES, value.settings.learn)) return { ok: false, error: "settings.learn must be off, ask or picks" };
        settings.learn = value.settings.learn;
      }
      for (const key of ["applyToRecognizer", "explainToAgent"] as const) {
        if (!present(value.settings[key])) continue;
        if (typeof value.settings[key] !== "boolean") return { ok: false, error: `settings.${key} must be a boolean` };
        settings[key] = value.settings[key];
      }
      if (Object.keys(settings).length === 0) return { ok: false, error: "settings must change something" };
      return { ok: true, value: { op: "settings", settings } };
    }
  }
}

/** Structural check of a learn/edit response (hosts and tests). */
export function parseWriteResponse(value: unknown): DictionaryWireParse<DictionaryWriteResponse> {
  if (!isRecord(value) || !oneOf(DICTIONARY_WRITE_STATUSES, value.status)) return { ok: false, error: "invalid status" };
  if (!Number.isSafeInteger(value.revision) || (value.revision as number) < 0) return { ok: false, error: "invalid revision" };
  const response: DictionaryWriteResponse = { status: value.status, revision: value.revision as number };
  if (present(value.code)) {
    if (typeof value.code !== "string" || !/^[a-z][a-z0-9_]{0,63}$/.test(value.code)) return { ok: false, error: "invalid code" };
    response.code = value.code as DictionaryWriteCode;
  }
  if (present(value.entry)) {
    const entry = value.entry;
    if (!isRecord(entry) || !oneOf(DICTIONARY_LISTS, entry.list) || !isEntryId(entry.id)) return { ok: false, error: "invalid entry" };
    response.entry = { list: entry.list, id: entry.id };
  }
  if (present(value.line)) {
    if (!isVoiceText(value.line, DICTIONARY_LIMITS.lineChars)) return { ok: false, error: "invalid line" };
    response.line = value.line;
  }
  if (present(value.undoToken)) {
    if (!isUndoToken(value.undoToken) || (value.status !== "learned" && value.status !== "updated")) return { ok: false, error: "invalid undoToken" };
    response.undoToken = value.undoToken;
  }
  if (present(value.conflicts)) {
    if (!Array.isArray(value.conflicts) || value.conflicts.length > DICTIONARY_LIMITS.regressionTakes
      || !value.conflicts.every((index) => Number.isSafeInteger(index) && index >= 0 && index < DICTIONARY_LIMITS.regressionTakes)) {
      return { ok: false, error: "invalid conflicts" };
    }
    response.conflicts = [...value.conflicts as number[]];
  }
  return { ok: true, value: response };
}

/** `?max=` of recognizer-terms: absent → 100; otherwise a decimal integer 1..100. */
export function parseRecognizerTermsMax(raw: string | null | undefined): DictionaryWireParse<number> {
  if (raw === null || raw === undefined) return { ok: true, value: DICTIONARY_LIMITS.recognizerTerms };
  if (!/^[1-9][0-9]{0,2}$/.test(raw) || Number(raw) > DICTIONARY_LIMITS.recognizerTerms) return { ok: false, error: "max must be 1..100" };
  return { ok: true, value: Number(raw) };
}

export function parseRecognizerTerms(value: unknown): DictionaryWireParse<RecognizerTermsResponse> {
  if (!isRecord(value) || !Number.isSafeInteger(value.revision) || (value.revision as number) < 0) return { ok: false, error: "invalid revision" };
  if (!Array.isArray(value.terms) || value.terms.length > DICTIONARY_LIMITS.recognizerTerms) return { ok: false, error: "terms must be an array of at most 100" };
  const terms: RecognizerTerm[] = [];
  for (const term of value.terms) {
    if (!isRecord(term) || !isVoiceText(term.text, DICTIONARY_LIMITS.recognizerTermChars) || !oneOf(TERM_LANGS, term.lang)) return { ok: false, error: "invalid term" };
    terms.push({ text: term.text, lang: term.lang });
  }
  return { ok: true, value: { revision: value.revision as number, terms } };
}

// ---------------------------------------------------------------------------------------------
// Node-internal interfaces (the instant lane calls DictionaryLookup; the routes use TakeMemo)

/** A learned rule that matched, for the instant lane (§6.3 steps 1, 2 and 4). */
export interface DictionaryMatch<T> { ref: DictionaryEntryRef; value: T }

/**
 * Read side of the dictionary for the instant lane (N2 calls it, N3 implements it). Every lookup is
 * exact on the folded phrase (callers fold with `foldPhrase` after spokenCore) and considers only
 * active entries whose recognizer applies (`recognizerApplies`). Learned names are never merged into
 * the fuzzy matcher (DESIGN4 §6.3). Targets are re-validated by the caller with the policy.
 */
export interface DictionaryLookup {
  /** The document revision (changes on every write). */
  revision(): number;
  settings(): DictionarySettings;
  /** Step 1: an exact utterance alias. */
  alias(phrase: string, recognizer: string): DictionaryMatch<SafeTarget> | null;
  /** Step 2: an exact learned app name for the open target as heard. */
  appName(heard: string, recognizer: string): DictionaryMatch<{ bundleId: string; display: string }> | null;
  /** Step 4 (voice only): fixes that apply, longest `heard` first. */
  fixes(recognizer: string): readonly DictionaryMatch<{ heard: string; intended: string }>[];
  /** Records that a rule decided (uses, lastUsedAt; written lazily). Never throws. */
  noteUse(ref: DictionaryEntryRef): void;
}

export const NO_DICTIONARY: DictionaryLookup = {
  revision: () => 0,
  settings: () => ({ ...DEFAULT_DICTIONARY_SETTINGS, learn: "off" }),
  alias: () => null,
  appName: () => null,
  fixes: () => [],
  noteUse: () => {},
};

export const TAKE_MEMO_LIMITS = { maxTakes: 20, ttlMs: 120_000 } as const;

/** What `/invoke` may tell the agent about a misheard take (DESIGN4 §5.5); never logged. */
export interface TakeNearMiss {
  /** The open target as heard (≤ 80). */
  heard: string;
  /** Top candidates (≤ 3), best first. */
  candidates: readonly { bundleId: string; display: string; score: number }[];
  /** The other hypotheses' texts (≤ 3). */
  others: readonly string[];
}

/** One take in the memo (in memory only). */
export interface TakeMemoRecord {
  takeId: string;
  /** Epoch ms of the take's first final. */
  at: number;
  inputMode: "text" | "voice";
  /** The first voice final's hypotheses; kept when the take's id is reused by later finals. */
  hypotheses: readonly VoiceHypothesis[];
  /** The latest decision for the take. */
  decision: InstantDecision;
  reason?: FallthroughReason;
  via?: VoiceVia;
  /** Recognizer of the deciding hypothesis (`any` for typed text). */
  recognizer: string;
  /** Folded open target as heard, when an open form decided or nearly did. */
  heard?: string;
  /** Bundle ids offered (list rows) or acted on, accumulated over the take's finals. */
  offered: readonly string[];
  /** What the take's act did. */
  acted?: SafeTarget;
  /** The learned rule that decided. */
  learnedEntryId?: string;
  nearMiss?: TakeNearMiss;
}

/**
 * The last 20 finals' takes for 2 minutes (DESIGN4 §6.2). `/dictionary/learn` accepts only a memo take;
 * `/invoke` reads the near-miss for its `takeId`. `remember` on a known take id merges: the first
 * voice hypotheses and the earliest `at` stay, `offered` accumulates, the rest is the latest final's.
 */
export interface TakeMemo {
  remember(record: TakeMemoRecord): void;
  /** Undefined when unknown or older than the TTL. */
  get(takeId: string, now?: number): TakeMemoRecord | undefined;
  /** The newest take that acted within the TTL (for "No, I meant X"). */
  latestActed(now?: number): TakeMemoRecord | undefined;
  forget(takeId: string): void;
}
