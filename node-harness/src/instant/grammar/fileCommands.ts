import { INNER_PUNCTUATION, normalize, spokenCore, type Normalized } from "../normalize.js";
import { isBareEdit, isCompound, isDeictic, isInAppObject } from "./policy.js";

/**
 * File commands on what the take shows (DESIGN6 §2 with BUILD6): closed EN/DE forms over the whole utterance.
 *
 *   delete     "lösche test", "lösch test", "entferne test", "delete test", "remove test", "test löschen"
 *   create     "erstelle (einen neuen) Ordner test", "lege einen Ordner test an", "neuer Ordner test", "neue Datei
 *              notes.txt", "create (a new) folder test", "make a folder test", "new file notes.txt" (the noun decides
 *              folder or file); the name first too ("create teast folder", "erstelle einen test Ordner", "test Ordner
 *              anlegen"), and a plain-text file by its extension alone ("erstelle notes.txt", "create todo.md")
 *   copy       "kopiere test nach Dokumente", "test nach Downloads kopieren", "copy test to Downloads"; without a
 *              destination ("kopiere test") the lane asks where to
 *   duplicate  "dupliziere test", "test duplizieren", "duplicate test" (next to it)
 *   move       "verschiebe test nach Dokumente", "test nach Downloads verschieben", "move test into Archive"
 *   rename     "benenne test in test-alt um", "nenne test in test-alt um", "test in test-alt umbenennen",
 *              "rename test to test-alt"
 *   close      "schließe test", "schliesse test", "close test", "beende Safari", "quit Safari" (and "X schließen",
 *              "X beenden")
 *
 * A standard folder after the object is its place ("lösche test in Downloads", "kopiere test aus Dokumente nach …",
 * "delete test from my Downloads", "erstelle Ordner test in Dokumente"): `place` as said, the name without it, and
 * `whole` (the object with its place words), which the lane tries first on what the take shows.
 *
 * Open is not here: it stays the visible-first open of the open grammar. Policy first: compounds, bare edits and
 * deixis ("lösche das", "close this", "schließe das Fenster"), anything about the Trash (there is no trash op),
 * uninstall phrasing, wildcards and paths as the object, quantifiers and age words ("alle", "all", "everything",
 * "alte", "old"), text and in-app objects ("lösche den letzten Satz"), UI objects ("move the window"), the clipboard
 * and questions are no file command: they keep today's handling (the deletion policy, the agent).
 *
 * The parse only finds the op and the names (original case, quotes and trailing punctuation off). Whether it decides
 * is the lane's call (instant/fileLane.ts: a full pi session with dcg as the bash guard and visible items from the
 * desktop or a Finder window). Voice also parses the spoken command core ("äh, kannst du test löschen"). Pure and
 * synchronous; nothing here logs (names are user content).
 */

export type FileCommandOp = "delete" | "create" | "copy" | "duplicate" | "move" | "rename" | "close";

/**
 * A standard folder said after an object ("test in Downloads"): `place` the folder word as said ("Downloads"), `whole`
 * the object with its place words ("test in Downloads").
 */
export interface FileCommandPlace {
  place?: string;
  whole?: string;
  /**
   * Several names in one object (DESIGN8 B1: "lösche a und b", "copy a, b and c to …"): each a name; `name` stays the
   * object as said, which the lane tries first ("Fotos und Videos" may be one folder). Delete, copy and move only.
   */
  names?: readonly string[];
}

/** One reading of "X nach Y": the object and the destination as said ("" when none was said). */
export interface FileCommandSplit extends FileCommandPlace {
  name: string;
  dest: string;
}

export type FileCommand =
  | ({ op: "delete"; name: string } & FileCommandPlace)
  /** `place`: the standard folder to create in ("erstelle Ordner test in Dokumente"). */
  | { op: "create"; name: string; kind: "folder" | "file"; place?: string }
  /** Readings from the last preposition to the first ("kopiere Fotos in Rom nach Archiv": "nach" first). */
  | { op: "copy" | "move"; splits: readonly FileCommandSplit[] }
  | ({ op: "duplicate"; name: string } & FileCommandPlace)
  /** "rückgängig", "undo" (DESIGN8 C1): the last op pi-os ran, from Node's journal — never what was said. */
  | { op: "undo" }
  | { op: "rename"; name: string; newName: string }
  /**
   * `quit`: said with beende/quit (else schließe/close); the lane resolves both the same way (BUILD6 §5). `window`: a
   * window or folder noun was said ("das Safari-Fenster", "den Ordner Downloads"): only a Finder window closes.
   */
  | { op: "close"; name: string; quit: boolean; window?: true };

export interface FileCommandOptions {
  /** Push-to-talk transcript: the spoken command core is parsed too. */
  voice?: boolean;
}

/** The text as matched (`lower`) and the same characters in their original case (`cased`, same length). */
interface Form {
  lower: string;
  cased: string;
}

const PARTICLES = "(?:\\s+(?:mal|bitte|doch|jetzt|kurz|schnell|einfach|eben|please|just))*";
const NOUN = "(ordner|verzeichnis|datei|folder|directory|file)";
const NAMED = "(?:\\s+(?:namens|mit\\s+dem\\s+namen|called|named))?";
const ARTICLE = "(?:\\s+(?:einen|eine|ein|den|die|das|a|an|the))?";
const NEW = "(?:\\s+(?:neuen|neue|neues|new))?";

const DELETE_FIRST = new RegExp(`^(?:lösche|lösch|loesche|loesch|entferne|entfern|delete|remove)${PARTICLES}\\s+(.+)$`, "du");
const DELETE_LAST = /^(.+?)\s+(?:löschen|loeschen|entfernen)$/du;
const CREATE_VERB = new RegExp(`^(?:erstelle|erstell|create|make)${PARTICLES}${ARTICLE}${NEW}\\s+${NOUN}${NAMED}\\s+(.+)$`, "du");
const CREATE_LEGE = new RegExp(`^(?:lege|leg)${PARTICLES}${ARTICLE}${NEW}\\s+${NOUN}${NAMED}\\s+(.+?)\\s+an$`, "du");
const CREATE_NEW = new RegExp(`^(?:neuer|neuen|neue|neues|new)\\s+${NOUN}${NAMED}\\s+(.+)$`, "du");
/** German verb-final: "(einen neuen) Ordner test erstellen/anlegen". */
const CREATE_LAST = new RegExp(`^(?:(?:einen|eine|ein)\\s+)?(?:(?:neuen|neue|neues)\\s+)?${NOUN}${NAMED}\\s+(.+?)\\s+(?:erstellen|anlegen)$`, "du");
/** "neue Datei test erstellen": the verb at the end is no part of the name. */
const CREATE_TAIL_VERB = /\s*\b(?:erstellen|anlegen|machen)$/u;
// The name first, the noun as the last word ("create teast folder", "erstelle einen test Ordner", "neuer test Ordner",
// "lege einen test Ordner an", "test Ordner anlegen"). The noun stands alone: "Foto-Ordner" stays a name.
const CREATE_VERB_NAME_FIRST = new RegExp(`^(?:erstelle|erstell|create|make)${PARTICLES}${ARTICLE}${NEW}\\s+(.+?)\\s+${NOUN}$`, "du");
const CREATE_LEGE_NAME_FIRST = new RegExp(`^(?:lege|leg)${PARTICLES}${ARTICLE}${NEW}\\s+(.+?)\\s+${NOUN}\\s+an$`, "du");
const CREATE_NEW_NAME_FIRST = new RegExp(`^(?:neuer|neuen|neue|neues|new)\\s+(.+?)\\s+${NOUN}$`, "du");
const CREATE_LAST_NAME_FIRST = new RegExp(`^(?:(?:einen|eine|ein|den|die|das)\\s+)?(?:(?:neuen|neue|neues)\\s+)?(.+?)\\s+${NOUN}\\s+(?:erstellen|anlegen)$`, "du");
/**
 * A plain-text file by its extension alone ("erstelle notes.txt", "create todo.md", "notes.txt anlegen"): one word, and only
 * text formats, where an empty file is a valid one (an empty .zip, .docx or .pages is not).
 */
const TEXT_FILE = "(\\S+\\.(?:txt|text|md|markdown|csv|tsv|json|yaml|yml|toml|ini|xml|html|htm|css|js|mjs|ts|py|sh|swift|rb|go|rs|java|c|h|cpp|sql|log|tex))";
const CREATE_BY_EXTENSION = new RegExp(`^(?:erstelle|erstell|create|make)${PARTICLES}${ARTICLE}${NEW}\\s+${TEXT_FILE}$`, "du");
const CREATE_BY_EXTENSION_LAST = new RegExp(`^${TEXT_FILE}\\s+(?:erstellen|anlegen)$`, "du");
/**
 * A name that is only articles, "new" words and plain adjectives ("create a new folder" names no folder "a new",
 * "erstelle einen leeren Ordner" none called "leeren").
 */
const FILLER_NAME = new RegExp("^(?:(?:einen|eine|ein|den|die|das|der|a|an|the|neuen|neue|neues|neuer|new|leer|leere|leeren|leeres|leerer|empty|blank|"
  + "weiteren|weitere|weiteres|weiterer|another|additional|extra|zusätzlichen|zusätzliche|zusätzliches|zusaetzlichen)\\s*)+$", "u");
/** A possessive before a new name: whose it is, not its name ("create my project folder"); today's. */
const POSSESSIVE_NAME = /^(?:my|your|our|mein|meine|meinen|meinem|dein|deine|deinen|unser|unsere|unseren)(?=\s|$)/u;
/**
 * A name said before its noun is a few name words, never a phrase: "make a backup of the folder" and "erstelle eine Kopie
 * vom Ordner" are no folders "backup of the" or "Kopie vom".
 */
const NAME_FIRST_PROSE = /(?:^|\s)(?:of|the|for|with|from|to|in|on|at|and|or|this|that|von|vom|für|fuer|mit|aus|zu|zum|zur|im|am|der|die|das|den|dem|des|und|oder|diesen|diese|dieses)(?=\s|$)/u;
const MAX_NAME_FIRST_WORDS = 3;

/** The standard folders the lane resolves (fileLane.ts STANDARD_FOLDERS keys), as a place after an object. */
const PLACE_KEYS = "schreibtisch|desktop|dokumente|dokumenten|documents|downloads|download|bilder|pictures|musik|music|filme|movies|"
  + "benutzerordner|home|homeordner|privatordner";
/**
 * "… in Downloads", "… aus dem Ordner Dokumente", "… auf dem Schreibtisch", "… from my Downloads", "… im Downloads-Ordner":
 * a standard folder at the end of an object (group 1 the folder word).
 */
const PLACE_TAIL = new RegExp(
  `\\s+(?:in|im|aus|von|vom|auf|from|on|inside)(?:\\s+(?:dem|den|der|die|the|my|meinem|meinen|meiner))?(?:\\s+(?:ordner|folder))?\\s+(${PLACE_KEYS})`
    + "(?:[\\s-]+(?:ordner|folder))?$",
  "diu",
);
/** One word of a folder's name in a place: no path, wildcard or home sign, and never a place preposition itself. */
const PLACE_WORD = "(?!(?:in|im|aus|von|vom|from|inside|out|of)(?:\\s|$))[^\\s/\\\\*?~]+";
/**
 * Any folder by name (DESIGN8 A1): "… in Projekte", "… aus dem Ordner Rechnungen 2026", "… from my Archive folder" —
 * 1–3 words after the last place preposition (group 1). "auf"/"on" stay the desktop's (PLACE_TAIL).
 */
const NAMED_PLACE_TAIL = new RegExp(
  `\\s+(?:in|im|aus|von|vom|from|inside|out\\s+of)(?:\\s+(?:dem|den|der|die|the|my|meinem|meinen|meiner))?(?:\\s+(?:ordner|folder))?`
    + `\\s+(${PLACE_WORD}(?:\\s+${PLACE_WORD}){0,2}?)(?:[\\s-]+(?:ordner|folder))?$`,
  "diu",
);
const COPY_FIRST = new RegExp(`^(?:kopiere|kopier|copy)${PARTICLES}\\s+(.+)$`, "du");
const COPY_LAST = /^(.+)\s+kopieren$/du;
const DUPLICATE_FIRST = new RegExp(`^(?:dupliziere|duplizier|duplicate)${PARTICLES}\\s+(.+)$`, "du");
const DUPLICATE_LAST = /^(.+)\s+duplizieren$/du;
const MOVE_FIRST = new RegExp(`^(?:verschiebe|verschieb|move)${PARTICLES}\\s+(.+)$`, "du");
const MOVE_LAST = /^(.+)\s+verschieben$/du;
const RENAME_DE = new RegExp(`^(?:benenne|benenn|nenne|nenn)${PARTICLES}\\s+(.+)\\s+(?:in|zu)\\s+(.+?)\\s+um$`, "du");
const RENAME_DE_UM = new RegExp(`^(?:benenne|benenn|nenne|nenn)${PARTICLES}\\s+(.+?)\\s+um\\s+(?:in|zu)\\s+(.+)$`, "du");
const RENAME_DE_LAST = /^(.+)\s+(?:in|zu)\s+(.+?)\s+umbenennen$/du;
const RENAME_EN = new RegExp(`^rename${PARTICLES}\\s+(.+)\\s+(?:to|as|into)\\s+(.+)$`, "du");
const CLOSE_FIRST = new RegExp(`^(?:schließe|schließ|schliesse|schliess|close)${PARTICLES}\\s+(.+)$`, "du");
const QUIT_FIRST = new RegExp(`^(?:beende|beend|quit)${PARTICLES}\\s+(.+)$`, "du");
const CLOSE_LAST = /^(.+?)\s+(?:schließen|schliessen)$/du;
const QUIT_LAST = /^(.+?)\s+beenden$/du;

const PREPOSITION = "\\s(?:nach|in|ins|zu|zum|zur|auf|aufs|to|into|onto)\\s";
/** "… nach Y", "… in den Ordner Y", "… to Y": where the destination starts (every occurrence is a reading). */
const DEST_PREPOSITION = new RegExp(PREPOSITION, "gu");
const HAS_PREPOSITION = new RegExp(PREPOSITION, "u");
/** "kopiere test hierher", "copy test here": the destination without a preposition. */
const DEST_HERE = /\s((?:over\s+)?here|hierher|hierhin)$/du;

const WORD_END = "(?=\\s|$)";
const WORD_START = "(?:^|\\s)";
/** The Trash, the bin, the rubbish: no trash op (BUILD6 §1), today's refusal or pi. */
const TRASH = new RegExp(`${WORD_START}(?:papierkorb|trash|müll|mull|muell|mülleimer|mulleimer|muelleimer|mülltonne|mulltonne|abfall|abfalleimer|wastebasket|garbage|rubbish|recycle)${WORD_END}`, "u");
/** "remove Zoom from my Mac", "entferne Zoom vom Mac": uninstalling, the policy's case. */
const UNINSTALL = /\bfrom (?:my|the|this) (?:mac|computer|laptop|macbook)\b|\bvom (?:mac|computer|rechner|macbook)\b/u;
const CLIPBOARD = new RegExp(`${WORD_START}(?:clipboard|zwischenablage)${WORD_END}`, "u");
/** Pronouns, quantifiers and age words: a set of things or something on screen, never one visible name. */
const NOT_A_NAME = new RegExp(
  `${WORD_START}(?:es|it|them|sie|ihn|alle|allen|alles|all|every|everything|each|jede|jeden|jedes|jeder|sämtliche|samtliche|saemtliche|`
    + `irgendwas|something|anything|alte|alten|alter|altes|old|older|ältere|älteren|aeltere|aelteren)${WORD_END}`,
  "u",
);
/** An object that is only an article or a demonstrative ("kopiere das nach …"). */
const ONLY_ARTICLE = /^(?:das|der|die|den|dem|des|dies|this|that|the|a|an|ein|eine|einen)$/u;
/** UI objects are moved, closed or copied in apps, not in the file system ("move the window to the left"). */
const UI_OBJECT = new RegExp(`${WORD_START}(?:window|windows|fenster|tab|tabs|cursor|mouse|maus|screen|bildschirm|monitor|display)${WORD_END}`, "u");
/** A verb-final head that slid into the object ("wie kann ich test löschen", "ich will test löschen"). */
const QUESTION_OR_SUBJECT = /^(?:wie|was|warum|wieso|weshalb|wo|wann|welche[nrsm]?|how|what|why|where|when|which|can|could|should|kann|kannst|soll|sollte|darf|ich|i|we|wir|du|you)(?=\s|$)/u;
/** A source object that starts with a preposition is a phrase, not a name ("move to the next field"). */
const LEADING_PREPOSITION = /^(?:to|on|in|into|onto|at|from|nach|zu|zum|zur|auf|aus|von|vom|im)(?=\s|$)/u;
/** New names that are prose, not names ("erstelle eine Datei mit einer Einkaufsliste", "create a file for my notes"). */
const NEW_NAME_PROSE = /^(?:mit|für|fuer|über|ueber|zum|zur|zu|in|im|auf|an|am|von|vom|aus|with|for|about|on|at|to|from|of|that|which|where|wo|der|die|das|den|dem|des|the|containing|enthält|enthaelt)(?=\s|$)/u;
const MAX_NAME_WORDS = 8;
const MAX_NEW_NAME_WORDS = 6;
const WRAPPING_QUOTES = /^["'](.+)["']$/su;

/** Words that are a place or a relation, so a missed object is more likely a phrase than a name (the lane's not-found guard). */
const PREPOSITION_WORD = new RegExp(`${WORD_START}(?:in|im|aus|from|on|auf|von|vom|nach|to|at|bei|unter|under|inside|innerhalb)${WORD_END}`, "u");

/**
 * A comma before "and" that ends a list of names ("Plan, Notes, and Budget", as dictation writes it). A second command
 * still shows as one by its verb or a "then" ("delete test, and open Safari", "delete test, and then Notes").
 */
const LIST_COMMA = /,\s*(?=(?:and|und)\s)/gu;

/**
 * The file command an utterance asks for, or null. `n` is the normalized request (normalize.ts); `voice` also parses
 * the spoken command core.
 */
export function matchFileCommand(n: Normalized, options: FileCommandOptions = {}): FileCommand | null {
  if (!n.lower || n.lower.length > 300) return null;
  if (isCompound({ ...n, lower: n.lower.replace(LIST_COMMA, " ") })) return null;
  if (isBareEdit(n) || TRASH.test(n.lower) || UNINSTALL.test(n.lower)) return null;
  const forms: Form[] = [{ lower: n.lower, cased: n.text.length === n.lower.length ? n.text : n.lower }];
  if (options.voice) {
    // The core first, as the spoken open grammar does: on the raw text a filler or wrapper would end up in the name
    // ("äh, test löschen").
    const core = spokenCore(n.lower);
    if (core && core !== n.lower) forms.unshift(...coreForms(n, core));
  }
  for (const form of forms) {
    const command = undoForm(form) ?? deleteForm(form) ?? createForm(form) ?? copyMoveForm(form) ?? renameForm(form) ?? closeForm(form);
    if (command) return command;
  }
  return null;
}

/** `matchFileCommand` on raw text (normalized here). */
export function fileCommandOf(text: string, locale?: string, voice = true): FileCommand | null {
  try {
    return matchFileCommand(normalize(text, locale), { voice });
  } catch {
    return null;
  }
}

// The command verbs of the forms above, by language (the "neu" and "new" adjectives of CREATE_NEW included).
const GERMAN_VERB = new RegExp(`${WORD_START}(?:lösche|lösch|loesche|loesch|löschen|loeschen|entferne|entfern|entfernen|erstelle|erstell|erstellen|` +
  `anlegen|neuer|neuen|neue|neues|kopiere|kopier|kopieren|dupliziere|duplizier|duplizieren|verschiebe|verschieb|verschieben|` +
  `benenne|benenn|nenne|nenn|umbenennen|schließe|schließ|schliesse|schliess|schließen|schliessen|beende|beend|beenden|`
  + `rückgängig|ruckgangig|rueckgaengig)${WORD_END}`, "u");
const ENGLISH_VERB = new RegExp(`${WORD_START}(?:delete|remove|create|make|new|copy|duplicate|move|rename|close|quit|undo)${WORD_END}`, "u");

/**
 * The language of a file command's verb ("erstelle Ordner a/b" is German whatever the name reads like), or null when
 * the text holds verbs of both languages or of neither: the lane's copy then follows the whole text's language.
 */
export function fileCommandLanguage(n: Normalized): "de" | "en" | null {
  const german = GERMAN_VERB.test(n.lower), english = ENGLISH_VERB.test(n.lower);
  return german === english ? null : german ? "de" : "en";
}

/** True when a missed name reads like a phrase (it holds a place or relation word): the lane then claims nothing. */
export function phraseLike(name: string): boolean {
  return PREPOSITION_WORD.test(name.toLowerCase());
}

/**
 * The spoken core's forms, in their original case: first the stretch of the text whose words are the core's, its
 * commas kept ("Äh, lösche Rechnung, Angebot und Notizen" → "lösche Rechnung, Angebot und Notizen": several names stay
 * several), then that stretch without them, as the core reads (an ASR comma after the verb: "Lösche, test."). When the
 * core changed a word ("deleting", "öffne mir mal"), the core itself.
 */
function coreForms(n: Normalized, core: string): Form[] {
  const plain = (text: string) => text.replace(INNER_PUNCTUATION, " ").replace(/\s+-\s+/g, " ").replace(/\s+/g, " ").trim();
  if (n.text.length === n.lower.length) {
    // spokenCore's word breaks, blanked in place so every word keeps its offset in the text.
    const blank = (m: string) => " ".repeat(m.length);
    const words = [...n.lower.replace(INNER_PUNCTUATION, blank).replace(/\s+-\s+/g, blank).matchAll(/\S+/gu)];
    const want = core.split(" ");
    for (let i = 0; i + want.length <= words.length; i++) {
      if (!want.every((word, k) => words[i + k]![0] === word)) continue;
      const last = words[i + want.length - 1]!;
      const start = words[i]!.index, end = last.index + last[0].length;
      const said = { lower: n.lower.slice(start, end), cased: n.text.slice(start, end) };
      const bare = { lower: plain(said.lower), cased: plain(said.cased) };
      return said.lower === bare.lower ? [said] : [said, bare];
    }
  }
  return [{ lower: core, cased: core }];
}

function group(form: Form, m: RegExpExecArray, index: number): string {
  const span = m.indices?.[index];
  return span ? form.cased.slice(span[0], span[1]) : (m[index] ?? "");
}

/** Trimmed, wrapping quotes and trailing punctuation off ("„Mein Projekt“." → "Mein Projekt"). */
export function cleanName(raw: string): string {
  return unquote(raw).name;
}

function unquote(raw: string): { name: string; quoted: boolean } {
  let name = raw.normalize("NFC").replace(/[“”„«»]/gu, "\"").replace(/[‘’‚]/gu, "'").replace(/\s+/gu, " ").trim();
  name = name.replace(/[.,;:!?…]+$/u, "").trim();
  const quoted = WRAPPING_QUOTES.exec(name);
  return { name: (quoted ? quoted[1]! : name).trim(), quoted: quoted !== null };
}

/**
 * An object the lane may look up among the visible items: one name, at most 8 words, no path or wildcard, no
 * deixis, pronoun, quantifier, age word, text or in-app object, UI object or question head.
 */
function sourceName(raw: string): string | null {
  const name = cleanName(raw);
  const lower = name.toLowerCase();
  if (!name || name.length > 120 || name.split(" ").length > MAX_NAME_WORDS) return null;
  if (/[*?/\\~]/u.test(name) || ONLY_ARTICLE.test(lower) || NOT_A_NAME.test(lower) || UI_OBJECT.test(lower)) return null;
  if (QUESTION_OR_SUBJECT.test(lower) || LEADING_PREPOSITION.test(lower) || isInAppObject(lower)) return null;
  return isDeictic(normalize(name)) ? null : name;
}

/**
 * A new name as said (create, rename): one name, not prose. A quoted name is taken as written ("erstelle Ordner „Die
 * Ärzte“"). Its file-system rules are the lane's (fileOps.ts nameProblem).
 */
function newName(raw: string): string | null {
  const { name, quoted } = unquote(raw);
  const lower = name.toLowerCase();
  if (!name || name.length > 255) return null;
  if (quoted) return name;
  if (name.split(" ").length > MAX_NEW_NAME_WORDS) return null;
  if (NEW_NAME_PROSE.test(lower) || QUESTION_OR_SUBJECT.test(lower) || ONLY_ARTICLE.test(lower)) return null;
  return isDeictic(normalize(name)) ? null : name;
}

/**
 * An object with a folder at its end ("test in Downloads", "test in Projekte"): the name before it, the folder's name
 * as said and the whole object. A standard folder first (its "auf dem Schreibtisch" too), then any folder name that is
 * a name (no pronoun, quantifier, deixis or in-app object: "test in it" has no place).
 */
function placed(raw: string): { name: string; place?: string; whole?: string } {
  const whole = cleanName(raw);
  for (const pattern of [PLACE_TAIL, NAMED_PLACE_TAIL]) {
    const m = pattern.exec(whole);
    const span = m?.indices?.[1];
    if (!m || !span || m.index === 0) continue;
    const name = whole.slice(0, m.index).trim();
    const place = whole.slice(span[0], span[1]);
    if (name && (pattern === PLACE_TAIL || sourceName(place) === place)) return { name, place, whole };
  }
  return { name: whole };
}

/** "a und b", "a, b und c", "a and b": where one name ends and the next starts. */
const NAME_LIST = /\s*,\s*(?:(?:und|and)\s+)?|\s+(?:und|and)\s+/iu;
const MAX_LISTED_NAMES = 5;

/** 2–5 distinct names joined by "und"/"and"/commas, each a source name; else undefined (one name). */
function listedNames(text: string): string[] | undefined {
  const parts = text.split(NAME_LIST).map((part) => part.trim()).filter(Boolean);
  if (parts.length < 2 || parts.length > MAX_LISTED_NAMES) return undefined;
  const names = parts.map(sourceName);
  if (!names.every((name): name is string => name !== null)) return undefined;
  return new Set(names.map((name) => name.toLowerCase())).size === names.length ? names : undefined;
}

/** A source object (sourceName) with its place, if one was said, and its several names (`many`: delete, copy, move). */
function sourceObject(raw: string, many = false): ({ name: string } & FileCommandPlace) | null {
  const object = placed(raw);
  const name = sourceName(object.name);
  if (!name) return null;
  // The whole object passes the same checks: "delete the intro from the presentation" stays a text edit.
  if (object.whole !== undefined && sourceName(object.whole) === null) return null;
  const names = many ? listedNames(object.name) : undefined;
  return { name, ...(object.place ? { place: object.place, whole: object.whole! } : {}), ...(names ? { names } : {}) };
}

function deleteForm(form: Form): FileCommand | null {
  const m = DELETE_FIRST.exec(form.lower) ?? DELETE_LAST.exec(form.lower);
  if (!m) return null;
  const object = sourceObject(group(form, m, 1), true);
  return object ? { op: "delete", ...object } : null;
}

/** "rückgängig", "mach das rückgängig", "das rückgängig machen", "undo", "undo that" — nothing else on the line. */
const UNDO = /^(?:(?:bitte\s+)?mach(?:e)?\s+(?:das\s+|es\s+|dies\s+)?(?:bitte\s+)?r(?:ü|u|ue)ckg(?:ä|a|ae)ngig|(?:das\s+|es\s+)?r(?:ü|u|ue)ckg(?:ä|a|ae)ngig(?:\s+machen)?|undo(?:\s+(?:that|it|this|the\s+last\s+(?:change|one|thing)))?(?:\s+please)?)$/u;

function undoForm(form: Form): FileCommand | null {
  return UNDO.test(form.lower.replace(/[.!?…]+$/u, "").trim()) ? { op: "undo" } : null;
}

function kindOf(noun: string): "folder" | "file" {
  return /^(?:datei|file)$/u.test(noun) ? "file" : "folder";
}

/** A new name for create: newName, and never only articles and "new" words. */
function createName(raw: string): string | null {
  const name = newName(raw);
  return name && !FILLER_NAME.test(name.toLowerCase()) ? name : null;
}

/** A create form on the whole text (its name may end in a place: "erstelle Ordner test in Dokumente"). */
function createParsed(form: Form): Extract<FileCommand, { op: "create" }> | null {
  const withPlace = (name: string | null, kind: "folder" | "file"): Extract<FileCommand, { op: "create" }> | null => {
    if (!name) return null;
    const object = placed(name);
    const inner = object.place ? createName(object.name) : name;
    if (!inner) return null;
    return object.place ? { op: "create", name: inner, kind, place: object.place } : { op: "create", name, kind };
  };
  const nounFirst = CREATE_VERB.exec(form.lower) ?? CREATE_LEGE.exec(form.lower) ?? CREATE_LAST.exec(form.lower) ?? CREATE_NEW.exec(form.lower);
  if (nounFirst) return withPlace(createName(group(form, nounFirst, 2).replace(CREATE_TAIL_VERB, "")), kindOf(nounFirst[1]!));
  const nameFirst = CREATE_VERB_NAME_FIRST.exec(form.lower) ?? CREATE_LEGE_NAME_FIRST.exec(form.lower)
    ?? CREATE_LAST_NAME_FIRST.exec(form.lower) ?? CREATE_NEW_NAME_FIRST.exec(form.lower);
  if (nameFirst) {
    const said = group(form, nameFirst, 1);
    const lower = said.toLowerCase().trim();
    if (POSSESSIVE_NAME.test(lower) || NAME_FIRST_PROSE.test(lower) || lower.split(/\s+/u).length > MAX_NAME_FIRST_WORDS) return null;
    return withPlace(createName(said), kindOf(nameFirst[2]!));
  }
  const byExtension = CREATE_BY_EXTENSION.exec(form.lower) ?? CREATE_BY_EXTENSION_LAST.exec(form.lower);
  return byExtension ? withPlace(createName(group(form, byExtension, 1)), "file") : null;
}

function createForm(form: Form): FileCommand | null {
  const direct = createParsed(form);
  if (direct) return direct;
  // The place after the noun ("erstelle einen test Ordner in Dokumente", "create notes.txt in Projects").
  for (const pattern of [PLACE_TAIL, NAMED_PLACE_TAIL]) {
    const m = pattern.exec(form.lower);
    const span = m?.indices?.[1];
    if (!m || !span || m.index === 0) continue;
    const place = form.cased.slice(span[0], span[1]);
    if (pattern !== PLACE_TAIL && sourceName(place) !== place) continue;
    const inner = createParsed({ lower: form.lower.slice(0, m.index), cased: form.cased.slice(0, m.index) });
    if (inner && !inner.place) return { ...inner, place };
  }
  return null;
}

/** Every "object → destination" reading of a copy/move remainder, the last preposition first. */
function splits(form: Form, start: number, end: number): FileCommandSplit[] {
  const lower = form.lower.slice(start, end);
  const cased = form.cased.slice(start, end);
  const here = DEST_HERE.exec(lower);
  if (here) {
    const object = sourceObject(cased.slice(0, here.index), true);
    return object ? [{ ...object, dest: here[1]! }] : [];
  }
  const out: FileCommandSplit[] = [];
  for (const m of [...lower.matchAll(DEST_PREPOSITION)].reverse()) {
    const at = m.index ?? 0;
    const object = sourceObject(cased.slice(0, at), true);
    const dest = cleanName(cased.slice(at + m[0].length));
    if (object && dest) out.push({ ...object, dest });
  }
  // No destination said ("kopiere test", "kopiere test aus Downloads"): the lane asks where to. A remainder with a
  // preposition that gave no reading is no command.
  if (!out.length && !HAS_PREPOSITION.test(lower)) {
    const object = sourceObject(cased, true);
    if (object) out.push({ ...object, dest: "" });
  }
  return out;
}

function copyMoveForm(form: Form): FileCommand | null {
  const duplicate = DUPLICATE_FIRST.exec(form.lower) ?? DUPLICATE_LAST.exec(form.lower);
  if (duplicate) {
    const object = sourceObject(group(form, duplicate, 1));
    return object ? { op: "duplicate", ...object } : null;
  }
  const copy = COPY_FIRST.exec(form.lower) ?? COPY_LAST.exec(form.lower);
  const move = copy ? null : MOVE_FIRST.exec(form.lower) ?? MOVE_LAST.exec(form.lower);
  const m = copy ?? move;
  if (!m || CLIPBOARD.test(form.lower)) return null;
  const span = m.indices?.[1];
  if (!span) return null;
  const readings = splits(form, span[0], span[1]);
  return readings.length ? { op: copy ? "copy" : "move", splits: readings } : null;
}

function renameForm(form: Form): FileCommand | null {
  const m = RENAME_DE.exec(form.lower) ?? RENAME_DE_UM.exec(form.lower) ?? RENAME_DE_LAST.exec(form.lower) ?? RENAME_EN.exec(form.lower);
  if (!m) return null;
  const name = sourceName(group(form, m, 1));
  const renamed = newName(group(form, m, 2));
  return name && renamed ? { op: "rename", name, newName: renamed } : null;
}

const CLOSE_LEAD = /^(?:(?:the|das|den|die|dem|my|mein|meine|meinen)\s+)?(?:(fenster|window|app|programm|ordner|folder)\s+)?/u;
const CLOSE_TAIL = /(?:[\s-]+(fenster|window|app|programm))$/u;
/** Nouns that name a window (a folder's window too), never an app to quit. */
const WINDOW_NOUN = /^(?:fenster|window|ordner|folder)$/u;

function closeForm(form: Form): FileCommand | null {
  const quit = QUIT_FIRST.exec(form.lower) ?? QUIT_LAST.exec(form.lower);
  const m = quit ?? CLOSE_FIRST.exec(form.lower) ?? CLOSE_LAST.exec(form.lower);
  if (!m) return null;
  // "schließe das Downloads-Fenster", "close the Downloads window", "schließe das Fenster Downloads": the name only.
  const said = cleanName(group(form, m, 1));
  const lead = CLOSE_LEAD.exec(said.toLowerCase());
  let core = said.slice(lead?.[0].length ?? 0);
  const tail = CLOSE_TAIL.exec(core.toLowerCase());
  const nouns = [lead?.[1]];
  if (tail && tail.index > 0) {
    core = core.slice(0, tail.index);
    nouns.push(tail[1]);
  }
  const name = sourceName(core);
  if (!name) return null;
  // "den Downloads-Ordner" keeps its noun in the name (a folder may be called "Foto-Ordner"), and still names a window.
  const window = nouns.some((noun) => noun !== undefined && WINDOW_NOUN.test(noun)) || /[\s-](?:ordner|folder)$/u.test(core.toLowerCase());
  return { op: "close", name, quit: quit !== null, ...(window ? { window: true } : {}) };
}
