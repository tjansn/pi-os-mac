import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { parseHostAction } from "../contracts/actions.js";
import type { AppIndexResult, AppRecord } from "../contracts/launcher.js";
import { supportDirectory } from "../platformPaths.js";
import type { OpenStrength } from "./grammar/launch.js";
import { isCommonWord as lexiconWord } from "./lexicon.js";
import { editSimilarity, firstSound, phoneticKeys, phoneticSimilarity, type PhoneticKeys } from "./phonetic.js";

/**
 * App matching over the host's app index (POST /tools/launcher.listApps).
 * Raycast-style: exact name/alias, prefix, whole word, initials ("vsc"),
 * word prefixes, then scattered-letter fuzzy; small boosts for frecency and
 * running apps. Built-in EN/DE aliases apply only to bundles the host lists.
 *
 * Speech (`matchSpoken`, `decideSpoken`, `resolveSpoken`; DESIGN4 §5.2) has its own literal tiers
 * (exact/alias, whole words and whole-word prefixes covering at least half the name; a single word of a
 * longer name is only ever offered) plus a sound-alike tier: query variants (possessive, plural, "app" /
 * "browser" words, spelled letters "ex code" → "x code", number words "one password" → "1password") and
 * 0.95 × (½ edit similarity + ½ phonetic similarity: Double Metaphone, maxed with Kölner Phonetik for
 * German speech). Learned names never enter this matcher (DESIGN4 §6.3: exact dictionary lookups only).
 */

export type AppMatchReason = "exact" | "alias" | "prefix" | "word" | "initials" | "word-prefix" | "fuzzy" | "sound";

export interface AppMatch {
  app: AppRecord;
  /** Match quality 0..1 before boosts. */
  score: number;
  /** Ranking score including frecency/running boosts. */
  rank: number;
  reason: AppMatchReason;
  /**
   * Spoken matching only: the name to show ("Did you mean Pages?"): the app's name, or the shorter proper
   * alias that matched ("Pages" for "Pages Creator Studio").
   */
  label?: string;
}

export interface FrecencyStore {
  /** 0..1 usage weight for a bundle id. */
  score(key: string, nowMs: number): number;
  record?(key: string, nowMs: number): void;
}

/** Spoken EN/DE names → bundle ids. */
export const BUILTIN_APP_ALIASES: Readonly<Record<string, readonly string[]>> = {
  "com.apple.calculator": ["rechner", "taschenrechner", "calculator", "calc"],
  "com.apple.systempreferences": ["systemeinstellungen", "systemeinstellung", "system settings", "system preferences", "systemeinstellungen app", "einstellungen", "settings", "preferences"],
  "com.apple.iCal": ["kalender", "calendar"],
  "com.apple.Notes": ["notizen", "notes"],
  "com.apple.reminders": ["erinnerungen", "reminders"],
  "com.apple.Photos": ["fotos", "photos"],
  "com.apple.Music": ["musik", "music", "apple music"],
  "com.apple.Maps": ["karten", "maps", "apple maps"],
  "com.apple.MobileSMS": ["nachrichten", "messages", "imessage"],
  "com.apple.AddressBook": ["kontakte", "contacts"],
  "com.apple.Preview": ["vorschau", "preview"],
  "com.apple.ActivityMonitor": ["aktivitätsanzeige", "activity monitor", "task manager"],
  "com.apple.finder": ["finder"],
  "com.apple.mail": ["mail", "apple mail", "e-mail", "email"],
  "com.apple.Safari": ["safari"],
  "com.apple.Terminal": ["terminal"],
  "com.apple.TextEdit": ["textedit", "text edit"],
  "com.apple.clock": ["uhr", "clock"],
  "com.apple.weather": ["wetter", "weather"],
  "com.apple.FaceTime": ["facetime"],
  "com.apple.AppStore": ["app store"],
  "com.apple.Home": ["home"],
  "com.apple.podcasts": ["podcasts"],
  "com.apple.dt.Xcode": ["xcode"],
  // iWork: the classic ids and the Creator Studio ids (com.apple.Pages …) the 2026 bundles use.
  "com.apple.iWork.Pages": ["pages"],
  "com.apple.iWork.Numbers": ["numbers"],
  "com.apple.iWork.Keynote": ["keynote"],
  "com.apple.Pages": ["pages"],
  "com.apple.Numbers": ["numbers"],
  "com.apple.Keynote": ["keynote"],
  "com.apple.shortcuts": ["kurzbefehle", "shortcuts"],
  "com.apple.VoiceMemos": ["sprachmemos", "voice memos"],
  "com.apple.findmy": ["find my"],
  "com.apple.QuickTimePlayerX": ["quicktime"],
  "com.apple.SystemProfiler": ["systeminformationen"],
  "com.apple.DiskUtility": ["festplattendienstprogramm"],
  "com.apple.screenshot.launcher": ["bildschirmfoto"],
  "com.google.Chrome": ["chrome", "google chrome"],
  "com.microsoft.VSCode": ["vs code", "vscode", "code", "visual studio code"],
  "com.brave.Browser": ["brave"],
  "org.mozilla.firefox": ["firefox"],
  "com.tinyspeck.slackmacgap": ["slack"],
  "com.spotify.client": ["spotify"],
  "com.figma.Desktop": ["figma"],
  "notion.id": ["notion"],
  "us.zoom.xos": ["zoom"],
  "com.microsoft.teams2": ["teams", "microsoft teams"],
  "com.microsoft.Word": ["word", "microsoft word"],
  "com.microsoft.Excel": ["excel", "microsoft excel"],
  "com.microsoft.Powerpoint": ["powerpoint", "microsoft powerpoint"],
  "com.microsoft.Outlook": ["outlook"],
  "net.whatsapp.WhatsApp": ["whatsapp"],
  "com.googlecode.iterm2": ["iterm", "iterm2"],
  "com.openai.chat": ["chatgpt", "chat gpt"],
};

export const APP_ACT_SCORE = 0.85;
export const APP_ACT_MARGIN = 0.1;
const MIN_LIST_SCORE = 0.6;

/**
 * Voice thresholds (DESIGN4 §5.2), calibrated on the r3/mapping corpus (3,216 open-app phrasings, 665
 * negatives; replayed in test/instantSpoken.test.ts). Recalibrated on the voice journal (N5), not here.
 */
export const SPOKEN = Object.freeze({
  /** A sound-alike match acts only at or above this score… */
  actScore: 0.82,
  /** …with at least this lead (rank) over the runner-up… */
  actMargin: 0.08,
  /** …and only for a heard name of at least this many letters (compact, folded). */
  minActLength: 4,
  /** Matches at or above this (and within `offerWindow` of the best) are offered: "Did you mean …?". */
  offerScore: 0.66,
  offerWindow: 0.15,
  /** At most this many offers. */
  maxOffers: 3,
  /** Weak verbs ("show me X") and bare names are offered only matches at or above this. */
  weakOfferScore: 0.8,
  /** A single word of a longer name ("file" of "Bluetooth File Exchange") never scores above this: offered, never opened. */
  partialWordCap: 0.8,
  /** Exact/alias evidence ("1 − variant penalty" can dip just below 1). */
  exactScore: 0.995,
  /** Sound-alike candidates below this combined similarity are not kept at all. */
  soundFloor: 0.6,
  /** The sound tier's weight: 0.95 × (½ edit + ½ phonetic). */
  soundWeight: 0.95,
  /** Shorter/longer compact length ratio below which two names cannot sound alike. */
  minLengthRatio: 0.5,
});

export function foldName(text: string): string {
  return text.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ß/g, "ss").toLowerCase()
    .replace(/\.app$/, "").replace(/[^a-z0-9]+/g, " ").trim();
}

interface NameForm {
  text: string;
  words: string[];
  initials: string;
  compact: string;
  alias: boolean;
  /** As the app or alias spells it ("Pages"), for spoken labels. */
  display: string;
  /** Speech only (digit words "one password" for "1Password"); typing never sees it. */
  spokenOnly: boolean;
  /** Phonetic keys of `compact`, computed on the first spoken match. */
  keys?: PhoneticKeys;
}

interface Entry { app: AppRecord; forms: NameForm[] }

function form(text: string, alias: boolean, spokenOnly = false): NameForm | null {
  const folded = foldName(text);
  if (!folded) return null;
  const words = folded.split(" ");
  return {
    text: folded, words, initials: words.map((w) => w[0]).join(""), compact: words.join(""), alias,
    display: text.trim().replace(/\.app$/i, ""), spokenOnly,
  };
}

function keysOf(f: NameForm): PhoneticKeys {
  return (f.keys ??= phoneticKeys(f.compact));
}

const NUMBER_WORDS: Readonly<Record<string, string>> = {
  one: "1", two: "2", three: "3", four: "4", five: "5", six: "6", seven: "7", eight: "8", nine: "9", ten: "10",
  eins: "1", zwei: "2", drei: "3", vier: "4", funf: "5",
};
const DIGIT_WORDS: Readonly<Record<string, string>> = { "1": "one", "2": "two", "3": "three", "4": "four", "5": "five" };
/** A leading "app" word the typed open grammar no longer strips ("open the app Figma", "öffne die App Figma"). */
const TYPED_APP_LEAD = /^app (?=\S)/;

function isSubsequence(needle: string, haystack: string): boolean {
  let i = 0;
  for (const ch of haystack) if (ch === needle[i]) i++;
  return i === needle.length;
}

function containsWords(words: string[], query: string[]): boolean {
  for (let i = 0; i + query.length <= words.length; i++) {
    if (query.every((q, k) => words[i + k] === q)) return true;
  }
  return false;
}

function wordPrefixes(words: string[], query: string[]): boolean {
  let at = 0;
  for (const q of query) {
    while (at < words.length && !words[at]!.startsWith(q)) at++;
    if (at === words.length) return false;
    at++;
  }
  return true;
}

function scoreForm(query: string, queryWords: string[], f: NameForm): { score: number; reason: AppMatchReason } | null {
  if (f.text === query || f.compact === query.replace(/ /g, "")) return { score: 1, reason: f.alias ? "alias" : "exact" };
  if (query.length >= 2 && f.text.startsWith(query)) return { score: 0.8 + 0.1 * (query.length / f.text.length), reason: "prefix" };
  if (query.length >= 3 && containsWords(f.words, queryWords)) return { score: 0.88, reason: "word" };
  if (!query.includes(" ") && query.length >= 2 && f.words.length >= 2 && f.initials === query) return { score: 0.85, reason: "initials" };
  if (queryWords.length >= 2 && wordPrefixes(f.words, queryWords)) return { score: 0.8, reason: "word-prefix" };
  if (!query.includes(" ") && query.length >= 3 && query.length <= 16 && isSubsequence(query, f.compact)) {
    return { score: Math.min(0.75, 0.5 + 0.25 * (query.length / f.compact.length)), reason: "fuzzy" };
  }
  return null;
}

// ---------------------------------------------------------------- spoken names

/** Words a recognizer or speaker wraps around a name ("the Brave browser", "Pages app", "das Programm Pages"). */
const NAME_LEAD = /^(?:the|my|die|das|den|der|dem|meine[nm]?|mein|app|application|programm|program|apple|microsoft|google)\s+/;
const NAME_TAIL = /\s+(?:app|application|apps|browser|editor|window|windows|program|programm|anwendung|fenster)$/;
/** Spelled letters as recognizers write them ("ex code", "see mux", "vau es code"). */
const LETTER_NAMES: Readonly<Record<string, string>> = {
  ex: "x", ecks: "x", eks: "x", ix: "x", see: "c", cee: "c", si: "c", tse: "c", vee: "v", vau: "v", fau: "v", es: "s", ess: "s",
  zee: "z", zett: "z", jay: "j", kay: "k", ka: "k", pee: "p", tee: "t", tea: "t", dee: "d", gee: "g", ge: "g", em: "m", en: "n", el: "l",
  ef: "f", are: "r", er: "r", cue: "q", ku: "q", why: "y", wy: "y", eye: "i", oh: "o", you: "u", be: "b", bee: "b", de: "d",
};
/** Single words that are app names but are often said alone for other reasons: offered, never opened bare. */
const BARE_ASK = new Set(["home", "apps", "tips", "hot", "games", "phone", "buzz", "clock", "news", "chess", "siri", "screenshot", "console"]);

function stripPossessive(raw: string): string {
  return raw.replace(/['’]s\b/gi, "").replace(/['’]/g, "");
}

function stripWrappers(folded: string): string {
  let core = folded;
  for (let round = 0; round < 3; round++) core = core.replace(NAME_LEAD, "").replace(NAME_TAIL, "");
  return core;
}

/**
 * The name part of a spoken open target, folded, without possessive, articles and "app"/"browser" words
 * ("the Brave browser" → "brave", "Notion's" → "notion"): the "heard" name for did-you-mean subtitles, the
 * dictionary-word guard, and the take memo.
 */
export function spokenHead(raw: string): string {
  return stripWrappers(foldName(stripPossessive(raw)));
}

export interface SpokenVariant {
  /** Folded variant text. */
  text: string;
  /** Subtracted from scores matched through this variant (0 = as heard). */
  penalty: number;
}

/** Folded variants of a spoken app phrase, most literal first (the penalty grows with each rewrite). */
export function spokenVariants(raw: string): SpokenVariant[] {
  const out = new Map<string, number>();
  const add = (text: string, penalty: number): void => {
    const t = text.replace(/\s+/g, " ").trim();
    if (t && (out.get(t) ?? Infinity) > penalty) out.set(t, penalty);
  };
  // Possessive or contraction before folding ("Notion's", "Pages's", "Claude's").
  const base = foldName(stripPossessive(raw));
  add(foldName(raw), 0);
  add(base, 0.01);
  const core = stripWrappers(base);
  add(core, 0.01);
  for (const v of [base, core]) {
    const words = v.split(" ");
    const last = words[words.length - 1] ?? "";
    // A stray "s" or a plural ("pages s", "notions", "terminals", "activities").
    if (words.length > 1 && last === "s") add(words.slice(0, -1).join(" "), 0.02);
    if (last.length > 3 && last.endsWith("s")) add([...words.slice(0, -1), last.slice(0, -1)].join(" "), 0.03);
    if (last.length > 4 && last.endsWith("ies")) add([...words.slice(0, -1), `${last.slice(0, -3)}y`].join(" "), 0.03);
    // Singular for plural ("open number", "open note").
    if (last.length >= 4 && !last.endsWith("s")) add([...words.slice(0, -1), `${last}s`].join(" "), 0.03);
    if (words.length > 1) add(words.map((w) => (w.length > 4 && w.endsWith("ies") ? `${w.slice(0, -3)}y` : w)).join(" "), 0.03);
    // Spelled letters and number words.
    if (words.length > 1 && words.some((w) => LETTER_NAMES[w])) add(words.map((w) => LETTER_NAMES[w] ?? w).join(" "), 0.03);
    if (words.some((w) => NUMBER_WORDS[w])) add(words.map((w) => NUMBER_WORDS[w] ?? w).join(" "), 0.02);
  }
  return [...out].map(([text, penalty]) => ({ text, penalty })).sort((a, b) => a.penalty - b.penalty);
}

/**
 * The literal tiers that hold up for speech, with the score speech gives them (null = ignore). Partial
 * names count only when they cover at least half of the name's words, and a single word of a longer name
 * ("file" of "Bluetooth File Exchange", "activity" of "Activity Monitor") is capped so it is only offered.
 * Typing aids are dropped: subsequence fuzzy ("word" → Passwords), partial-word prefixes ("new" → News).
 */
function spokenLiteral(literal: { score: number; reason: AppMatchReason }, query: string, f: NameForm): number | null {
  const words = query.split(" ");
  const coverage = words.length / f.words.length;
  switch (literal.reason) {
    case "exact":
    case "alias":
      return literal.score;
    case "word":
    case "word-prefix":
    case "prefix": {
      if (literal.reason === "prefix" && !f.text.startsWith(`${query} `)) return null;
      if (literal.reason === "word-prefix" && !words.every((w) => f.words.includes(w))) return null;
      if (coverage < 0.5) return null;
      return words.length === 1 ? Math.min(literal.score, SPOKEN.partialWordCap) : literal.score;
    }
    case "initials":
      return query.length <= 4 && /^(?:[a-z] )+[a-z]$/.test(query) ? literal.score : null;
    default:
      return null;
  }
}

export interface SpokenMatchOptions {
  /** German utterance or speech locale: Kölner Phonetik also counts. */
  german?: boolean;
  /**
   * The heard name is one dictionary word ("lotion", "feather", "nation"): sound-alikes must then start
   * with its first sound (Double Metaphone), so "lotion" no longer offers Notion while "nation" still
   * does. `decideSpoken` also never lets such a word act on sound alone.
   */
  heardIsWord?: boolean;
  /** At most this many matches (default 8). */
  limit?: number;
  nowMs?: number;
}

/** A voice decision for one open target: open now, offer up to three ("Did you mean …?"), or nothing. */
export type SpokenDecision = { kind: "act"; match: AppMatch } | { kind: "offer"; matches: AppMatch[] } | null;

export interface SpokenOpenOptions {
  /** German utterance or speech locale. */
  german?: boolean;
  /** Dictionary check for the heard name (default: lexicon.ts). */
  isCommonWord?: (word: string) => boolean;
  nowMs?: number;
}

export interface SpokenOpenResult {
  /** The open target as heard (`spokenHead`): folded, ≤ 80 characters ("page is"). */
  heard: string;
  /** The heard name is one common EN/DE word (it never acts on sound alone). */
  heardIsWord: boolean;
  /** Ranked candidates (≤ 8), best first: offers, near-miss memo. */
  matches: AppMatch[];
  /** The best match when it is an exact name or alias (a known site name yields to it). */
  exact?: AppMatch;
  decision: SpokenDecision;
}

/** The `VoiceMeta.via` of a spoken act ("exact" also covers whole-word literal names). */
export function spokenVia(match: AppMatch): "exact" | "alias" | "sound" {
  return match.reason === "sound" ? "sound" : match.reason === "alias" ? "alias" : "exact";
}

export class AppMatcher {
  private readonly entries: Entry[];
  private readonly byBundle = new Map<string, AppRecord>();

  constructor(apps: readonly AppRecord[], private readonly frecency?: FrecencyStore) {
    this.entries = apps.map((app) => {
      this.byBundle.set(app.bundleId, app);
      const names = [app.name, ...app.aliases, ...(BUILTIN_APP_ALIASES[app.bundleId] ?? []), app.path.split("/").pop() ?? ""];
      const forms: NameForm[] = [];
      const seen = new Set<string>();
      const push = (name: string, alias: boolean, spokenOnly = false): void => {
        const f = form(name, alias, spokenOnly);
        if (f && !seen.has(f.text)) {
          seen.add(f.text);
          forms.push(f);
        }
      };
      names.forEach((name, index) => push(name, index > 0));
      // "1Password" is also "one password" when spoken.
      for (const f of [...forms]) {
        if (/\d/.test(f.text)) push(f.text.replace(/\d/g, (d) => ` ${DIGIT_WORDS[d] ?? d} `), true, true);
      }
      return { app, forms };
    });
  }

  get size(): number {
    return this.entries.length;
  }

  /** The indexed app with this bundle id. */
  app(bundleId: string): AppRecord | undefined {
    return this.byBundle.get(bundleId);
  }

  private boost(app: AppRecord, nowMs: number): number {
    return Math.min(0.1, Math.max(0, this.frecency?.score(app.bundleId, nowMs) ?? 0) * 0.1) + (app.running ? 0.02 : 0);
  }

  /** Typed (and today's voice) matching: every Raycast-style tier. */
  match(query: string, limit = 8, nowMs = Date.now()): AppMatch[] {
    const q = foldName(query);
    if (!q || q.length > 60) return [];
    // "open the app Figma": the leading "app" belongs to the request unless it is part of the name ("App Store").
    const queries = TYPED_APP_LEAD.test(q) ? [q, q.replace(TYPED_APP_LEAD, "")] : [q];
    const out: AppMatch[] = [];
    for (const { app, forms } of this.entries) {
      let best: { score: number; reason: AppMatchReason } | null = null;
      for (const text of queries) {
        const queryWords = text.split(" ");
        for (const f of forms) {
          if (f.spokenOnly) continue;
          const scored = scoreForm(text, queryWords, f);
          if (scored && (!best || scored.score > best.score)) best = scored;
        }
      }
      if (!best || best.score < MIN_LIST_SCORE) continue;
      out.push({ app, score: best.score, rank: best.score + this.boost(app, nowMs), reason: best.reason });
    }
    return out.sort((a, b) => b.rank - a.rank || a.app.name.length - b.app.name.length).slice(0, limit);
  }

  /** The single app to open without asking, or null (show a list instead). */
  static decisive(matches: readonly AppMatch[]): AppMatch | null {
    const [best, second] = matches;
    if (!best || best.score < APP_ACT_SCORE) return null;
    return !second || best.rank - second.rank >= APP_ACT_MARGIN ? best : null;
  }

  /**
   * Spoken app phrase → ranked matches. The speech literal tiers run on every variant; the sound tier
   * (edit + phonetic similarity on the compact form) adds candidates the literal tiers miss ("page is" →
   * Pages, "calender" → Calendar, "nation" → Notion). Scores are 0..1 before frecency/running boosts.
   */
  matchSpoken(query: string, options: SpokenMatchOptions = {}): AppMatch[] {
    const nowMs = options.nowMs ?? Date.now();
    const variants = spokenVariants(query).filter((v) => v.text.length <= 60);
    if (!variants.length) return [];
    const best = new Map<string, { score: number; reason: AppMatchReason; label: string }>();
    const offer = (bundleId: string, score: number, reason: AppMatchReason, label: string): void => {
      const prev = best.get(bundleId);
      if (!prev || score > prev.score) best.set(bundleId, { score, reason, label });
    };
    for (const v of variants) {
      const words = v.text.split(" ");
      const compact = words.join("");
      const keys = phoneticKeys(compact);
      const digits = /\d/.test(compact);
      for (const { app, forms } of this.entries) {
        for (const f of forms) {
          const literal = scoreForm(v.text, words, f);
          const spoken = literal ? spokenLiteral(literal, v.text, f) : null;
          if (literal && spoken !== null) offer(app.bundleId, spoken - v.penalty, literal.reason, f.display);
          if (compact.length < 3 || f.compact.length < 2) continue;
          // "page 2", "tab 3": numbers belong to the request, not to a sound-alike name.
          if (digits && !/\d/.test(f.compact)) continue;
          const ratio = Math.min(compact.length, f.compact.length) / Math.max(compact.length, f.compact.length);
          if (ratio < SPOKEN.minLengthRatio) continue;
          const fKeys = keysOf(f);
          if (options.heardIsWord && firstSound(keys) !== firstSound(fKeys)) continue;
          const combined = 0.5 * editSimilarity(compact, f.compact) + 0.5 * phoneticSimilarity(keys, fKeys, options.german === true);
          if (combined >= SPOKEN.soundFloor) offer(app.bundleId, SPOKEN.soundWeight * combined - v.penalty, "sound", f.display);
        }
      }
    }
    const out: AppMatch[] = [];
    for (const [bundleId, { score, reason, label }] of best) {
      const app = this.byBundle.get(bundleId)!;
      // Show the app's own name unless the match came through a shorter proper alias of it ("Pages").
      const shown = label.length < app.name.length && /^[A-Z]/.test(label) ? label : app.name;
      out.push({ app, score, rank: score + this.boost(app, nowMs), reason, label: shown });
    }
    return out.sort((a, b) => b.rank - a.rank || a.app.name.length - b.app.name.length).slice(0, options.limit ?? 8);
  }

  /**
   * Voice acceptance (DESIGN4 §5.2). `strength`: "strong" for an explicit open/launch/switch verb, "weak"
   * for show/get/focus verbs, "bare" for a name said alone. `heardLength` is the heard name's compact
   * length; `heardIsWord` marks a common EN/DE word.
   *
   *   exact/alias, unique                   → act (bare: not a word, ≥ 4 letters, not generic; else offer)
   *   two apps with the same exact name     → offer
   *   strong: literal ≥ 0.85, lead ≥ 0.10   → act
   *   strong: sound ≥ 0.82, lead ≥ 0.08, ≥ 4 letters, not a word → act
   *   anything ≥ 0.66 within 0.15 of best   → offer ≤ 3 (weak and bare: ≥ 0.80; bare: literal only)
   */
  static decideSpoken(matches: readonly AppMatch[], strength: OpenStrength, heardLength: number, heardIsWord = false): SpokenDecision {
    const [best, second] = matches;
    if (!best) return null;
    const lead = second ? best.rank - second.rank : 1;
    const literal = best.reason !== "sound";
    const offers = matches.filter((m) => m.score >= SPOKEN.offerScore && m.score >= best.score - SPOKEN.offerWindow).slice(0, SPOKEN.maxOffers);
    if (best.score >= SPOKEN.exactScore && (best.reason === "exact" || best.reason === "alias")) {
      // Two apps answering to the same name: ask.
      if (second && second.score >= SPOKEN.exactScore) return { kind: "offer", matches: offers };
      // A name said alone opens only when it is unmistakably a name: not a dictionary word ("Calendar",
      // "Pages", "TV" are offered), since a truncated transcript often leaves exactly such a word.
      const ask = strength === "bare" && (heardIsWord || heardLength < SPOKEN.minActLength || BARE_ASK.has(foldName(best.app.name)));
      return ask ? { kind: "offer", matches: offers } : { kind: "act", match: best };
    }
    if (strength === "strong") {
      if (literal && best.score >= APP_ACT_SCORE && lead >= APP_ACT_MARGIN) return { kind: "act", match: best };
      if (!literal && !heardIsWord && best.score >= SPOKEN.actScore && lead >= SPOKEN.actMargin && heardLength >= SPOKEN.minActLength) {
        return { kind: "act", match: best };
      }
    }
    const floor = strength === "strong" ? SPOKEN.offerScore : SPOKEN.weakOfferScore;
    // A bare utterance is offered literal names only ("Weiter" is not "Wetter").
    const offered = offers.filter((m) => m.score >= floor && (strength !== "bare" || m.reason !== "sound"));
    return offered.length ? { kind: "offer", matches: offered } : null;
  }

  /**
   * The whole voice open step for one parsed target: heard name, dictionary-word guard, `matchSpoken`,
   * `decideSpoken`. The caller turns the decision into act / did-you-mean list / fallthrough, lets an
   * exact installed name win over a known site name (`exact`), and keeps `matches` for the near-miss memo.
   */
  resolveSpoken(target: string, strength: OpenStrength, options: SpokenOpenOptions = {}): SpokenOpenResult {
    const heard = spokenHead(target).slice(0, 80).trim();
    const isWord = options.isCommonWord ?? lexiconWord;
    const heardIsWord = heard.length > 0 && !heard.includes(" ") && isWord(heard);
    const matches = this.matchSpoken(target, {
      ...(options.german ? { german: true } : {}), heardIsWord, ...(options.nowMs !== undefined ? { nowMs: options.nowMs } : {}),
    });
    const top = matches[0];
    const exact = top && top.score >= SPOKEN.exactScore && (top.reason === "exact" || top.reason === "alias") ? top : undefined;
    const decision = AppMatcher.decideSpoken(matches, strength, heard.replace(/ /g, "").length, heardIsWord);
    return { heard, heardIsWord, matches, ...(exact ? { exact } : {}), decision };
  }
}

/**
 * Caches the host app index. The host bumps `version` when apps change; the
 * matcher is rebuilt only then. Stale data is served immediately while a
 * background refresh runs, so app matching never waits on the host twice.
 */
export class AppIndexCache {
  private matcher: AppMatcher | null = null;
  private version: string | undefined;
  private fetchedAt = 0;
  private inflight: Promise<AppMatcher | null> | undefined;
  private readonly ttlMs: number;
  private readonly clock: () => number;
  private readonly frecency: FrecencyStore | undefined;

  constructor(
    private readonly listApps: (signal: AbortSignal) => Promise<AppIndexResult>,
    options: { ttlMs?: number; clock?: () => number; frecency?: FrecencyStore } = {},
  ) {
    this.ttlMs = options.ttlMs ?? 15_000;
    this.clock = options.clock ?? (() => Date.now());
    this.frecency = options.frecency;
  }

  peek(): AppMatcher | null {
    return this.matcher;
  }

  /** Current matcher; refreshes when stale (awaited only when nothing is cached yet). */
  get(signal: AbortSignal): Promise<AppMatcher | null> {
    const stale = this.clock() - this.fetchedAt >= this.ttlMs;
    if (this.matcher && !stale) return Promise.resolve(this.matcher);
    const refresh = this.refresh();
    return this.matcher ? Promise.resolve(this.matcher) : abortable(refresh, signal);
  }

  refresh(): Promise<AppMatcher | null> {
    if (this.inflight) return this.inflight;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5_000);
    timer.unref?.();
    const run = this.listApps(controller.signal)
      .then((index) => {
        this.fetchedAt = this.clock();
        if (!Array.isArray(index?.apps)) return this.matcher;
        if (index.version !== this.version || !this.matcher) {
          this.version = index.version;
          this.matcher = new AppMatcher(index.apps.filter(isAppRecord), this.frecency);
        }
        return this.matcher;
      })
      .catch(() => this.matcher)
      .finally(() => {
        clearTimeout(timer);
        if (this.inflight === run) this.inflight = undefined;
      });
    this.inflight = run;
    return run;
  }
}

/** Shape check plus a bundle id that openApp accepts (cards and acts must carry valid host actions). */
function isAppRecord(value: unknown): value is AppRecord {
  if (typeof value !== "object" || value === null) return false;
  const app = value as Partial<AppRecord>;
  return typeof app.bundleId === "string" && typeof app.name === "string" && typeof app.path === "string"
    && Array.isArray(app.aliases) && app.aliases.every((alias) => typeof alias === "string")
    && parseHostAction({ type: "openApp", bundleId: app.bundleId }) !== null;
}

function abortable<T>(promise: Promise<T>, signal: AbortSignal): Promise<T | null> {
  if (signal.aborted) return Promise.resolve(null);
  return new Promise((resolve) => {
    const onAbort = (): void => resolve(null);
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then((value) => {
      signal.removeEventListener("abort", onAbort);
      resolve(value);
    }, () => resolve(null));
  });
}

/**
 * Optional app frecency: `{bundleId: {count, lastMs}}` in
 * `<support dir>/instant-usage.json`, weight count × 0.5^(age / 14 d)
 * squashed to 0..1. Stores bundle ids only, never file paths or text.
 */
export class FileFrecencyStore implements FrecencyStore {
  private entries = new Map<string, { count: number; lastMs: number }>();
  private loaded = false;

  constructor(private readonly file: string = join(supportDirectory(), "instant-usage.json")) {}

  async load(): Promise<void> {
    if (this.loaded) return;
    this.loaded = true;
    try {
      const parsed: unknown = JSON.parse(await readFile(this.file, "utf8"));
      if (typeof parsed !== "object" || parsed === null) return;
      for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
        const v = value as { count?: unknown; lastMs?: unknown };
        if (typeof v?.count === "number" && typeof v.lastMs === "number" && /^[A-Za-z0-9.-]{1,255}$/.test(key)) {
          this.entries.set(key, { count: v.count, lastMs: v.lastMs });
        }
      }
    } catch {
      // Missing or corrupt: start empty.
    }
  }

  score(key: string, nowMs: number): number {
    const entry = this.entries.get(key);
    if (!entry) return 0;
    const weight = entry.count * 0.5 ** (Math.max(0, nowMs - entry.lastMs) / (14 * 86_400_000));
    return weight / (weight + 3);
  }

  record(key: string, nowMs: number): void {
    if (!/^[A-Za-z0-9.-]{1,255}$/.test(key)) return;
    const entry = this.entries.get(key);
    this.entries.set(key, { count: (entry?.count ?? 0) + 1, lastMs: nowMs });
    void this.save();
  }

  private async save(): Promise<void> {
    const temp = `${this.file}.${process.pid}.tmp`;
    try {
      await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
      await writeFile(temp, `${JSON.stringify(Object.fromEntries(this.entries))}\n`, { mode: 0o600 });
      await rename(temp, this.file);
    } catch {
      // Frecency is a convenience; losing a write is harmless.
    }
  }
}
