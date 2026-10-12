import { normalize, spokenCore, type Normalized } from "../normalize.js";
import { isBareEdit, isCompound, isDeictic, isInAppObject } from "./policy.js";

/**
 * File commands on what the take shows (DESIGN6 §2 with BUILD6): closed EN/DE forms over the whole utterance.
 *
 *   delete     "lösche test", "lösch test", "entferne test", "delete test", "remove test", "test löschen"
 *   create     "erstelle (einen neuen) Ordner test", "lege einen Ordner test an", "neuer Ordner test", "neue Datei
 *              notes.txt", "create (a new) folder test", "make a folder test", "new file notes.txt" (the noun decides
 *              folder or file)
 *   copy       "kopiere test nach Dokumente", "test nach Downloads kopieren", "copy test to Downloads"; without a
 *              destination ("kopiere test") the lane asks where to
 *   duplicate  "dupliziere test", "test duplizieren", "duplicate test" (next to it)
 *   move       "verschiebe test nach Dokumente", "test nach Downloads verschieben", "move test into Archive"
 *   rename     "benenne test in test-alt um", "nenne test in test-alt um", "test in test-alt umbenennen",
 *              "rename test to test-alt"
 *   close      "schließe test", "schliesse test", "close test", "beende Safari", "quit Safari" (and "X schließen",
 *              "X beenden")
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

/** One reading of "X nach Y": the object and the destination as said ("" when none was said). */
export interface FileCommandSplit {
  name: string;
  dest: string;
}

export type FileCommand =
  | { op: "delete"; name: string }
  | { op: "create"; name: string; kind: "folder" | "file" }
  /** Readings from the last preposition to the first ("kopiere Fotos in Rom nach Archiv": "nach" first). */
  | { op: "copy" | "move"; splits: readonly FileCommandSplit[] }
  | { op: "duplicate"; name: string }
  | { op: "rename"; name: string; newName: string }
  /** `quit`: said with beende/quit (else schließe/close); the lane resolves both the same way (BUILD6 §5). */
  | { op: "close"; name: string; quit: boolean };

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
const ARTICLE = "(?:\\s+(?:einen|eine|ein|a|an))?";
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
 * The file command an utterance asks for, or null. `n` is the normalized request (normalize.ts); `voice` also parses
 * the spoken command core.
 */
export function matchFileCommand(n: Normalized, options: FileCommandOptions = {}): FileCommand | null {
  if (!n.lower || n.lower.length > 300) return null;
  if (isCompound(n) || isBareEdit(n) || TRASH.test(n.lower) || UNINSTALL.test(n.lower)) return null;
  const forms: Form[] = [{ lower: n.lower, cased: n.text.length === n.lower.length ? n.text : n.lower }];
  if (options.voice) {
    // The core first, as the spoken open grammar does: on the raw text a filler or wrapper would end up in the name
    // ("äh, test löschen").
    const core = spokenCore(n.lower);
    if (core && core !== n.lower) forms.unshift({ lower: core, cased: casedCore(n, core) });
  }
  for (const form of forms) {
    const command = deleteForm(form) ?? createForm(form) ?? copyMoveForm(form) ?? renameForm(form) ?? closeForm(form);
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

/** True when a missed name reads like a phrase (it holds a place or relation word): the lane then claims nothing. */
export function phraseLike(name: string): boolean {
  return PREPOSITION_WORD.test(name.toLowerCase());
}

/** The original-case characters of the spoken core (the whole text's when the core is not a substring of it). */
function casedCore(n: Normalized, core: string): string {
  if (n.text.length !== n.lower.length) return core;
  const at = n.lower.indexOf(core);
  return at >= 0 ? n.text.slice(at, at + core.length) : core;
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

function deleteForm(form: Form): FileCommand | null {
  const m = DELETE_FIRST.exec(form.lower) ?? DELETE_LAST.exec(form.lower);
  if (!m) return null;
  const name = sourceName(group(form, m, 1));
  return name ? { op: "delete", name } : null;
}

function createForm(form: Form): FileCommand | null {
  const m = CREATE_VERB.exec(form.lower) ?? CREATE_LEGE.exec(form.lower) ?? CREATE_LAST.exec(form.lower) ?? CREATE_NEW.exec(form.lower);
  if (!m) return null;
  const noun = m[1]!;
  const name = newName(group(form, m, 2).replace(CREATE_TAIL_VERB, ""));
  if (!name) return null;
  return { op: "create", name, kind: /^(?:datei|file)$/u.test(noun) ? "file" : "folder" };
}

/** Every "object → destination" reading of a copy/move remainder, the last preposition first. */
function splits(form: Form, start: number, end: number): FileCommandSplit[] {
  const lower = form.lower.slice(start, end);
  const cased = form.cased.slice(start, end);
  const here = DEST_HERE.exec(lower);
  if (here) {
    const name = sourceName(cased.slice(0, here.index));
    return name ? [{ name, dest: here[1]! }] : [];
  }
  const out: FileCommandSplit[] = [];
  for (const m of [...lower.matchAll(DEST_PREPOSITION)].reverse()) {
    const at = m.index ?? 0;
    const name = sourceName(cased.slice(0, at));
    const dest = cleanName(cased.slice(at + m[0].length));
    if (name && dest) out.push({ name, dest });
  }
  // No destination said ("kopiere test"): the lane asks where to. A remainder with a preposition that gave no
  // reading is no command.
  if (!out.length && !HAS_PREPOSITION.test(lower)) {
    const name = sourceName(cased);
    if (name) out.push({ name, dest: "" });
  }
  return out;
}

function copyMoveForm(form: Form): FileCommand | null {
  const duplicate = DUPLICATE_FIRST.exec(form.lower) ?? DUPLICATE_LAST.exec(form.lower);
  if (duplicate) {
    const name = sourceName(group(form, duplicate, 1));
    return name ? { op: "duplicate", name } : null;
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

const CLOSE_LEAD = /^(?:(?:the|das|den|die|dem|my|mein|meine|meinen)\s+)?(?:(?:fenster|window|app|programm|ordner|folder)\s+)?/u;
const CLOSE_TAIL = /(?:[\s-]+(?:fenster|window|app|programm))$/u;

function closeForm(form: Form): FileCommand | null {
  const quit = QUIT_FIRST.exec(form.lower) ?? QUIT_LAST.exec(form.lower);
  const m = quit ?? CLOSE_FIRST.exec(form.lower) ?? CLOSE_LAST.exec(form.lower);
  if (!m) return null;
  // "schließe das Downloads-Fenster", "close the Downloads window", "schließe das Fenster Downloads": the name only.
  const said = cleanName(group(form, m, 1));
  const lead = CLOSE_LEAD.exec(said.toLowerCase())?.[0].length ?? 0;
  let core = said.slice(lead);
  const tail = CLOSE_TAIL.exec(core.toLowerCase());
  if (tail && tail.index > 0) core = core.slice(0, tail.index);
  const name = sourceName(core);
  return name ? { op: "close", name, quit: quit !== null } : null;
}
