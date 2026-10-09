import { contextScope } from "../agent/routing/contextScope.js";
import { classifyUtterance } from "../agent/routing/heuristics.js";
import { isOneLineText } from "../contracts/actions.js";
import type { InstantScope } from "../contracts/context.js";
import { foldPhrase } from "../contracts/dictionary.js";
import {
  accepts, FILL_IMPLICIT_KINDS, FILL_NEVER_KINDS, FILL_OPT_IN_KINDS, fillSubmitAllowed, INSTANT_LIMITS,
  type InstantAppClass, type InstantFieldKind, type InstantRequest, type VoiceHypothesis, type VoiceMeta,
} from "../contracts/instant.js";
import { truncate } from "./format.js";
import { bareSearchQuery } from "./grammar/launch.js";
import type { InstantBody } from "./types.js";
import { VOICE, wordsDisagree } from "./voice.js";

/**
 * Continuity's Node lane (DESIGN5 §4.6, §5.3–§5.4, §5.10–§5.11 with Tom's binding answers of 2026-10-08):
 * voice goes into the field the user sees focused — "everything except commands".
 *
 * The decision order for a final that carries `accept: "fill"` and a `target` (dispatcher.ts wires it):
 *   1. policy: a deletion request is refused as today; deletion vocabulary never reaches a field on its own
 *      (an implicit take with such a word keeps today's path; an explicit "tippe …" remainder with one is held
 *      for one Return and never submits); deixis, compound and bare edits keep today's path;
 *   2. escapes: "frag pi …/ask pi …/hey pi …" always goes to pi (nothing is typed); "tippe …/type …/diktiere …/
 *      gib … ein" always types its remainder (Tier E, voice and typed);
 *      "nein, X" right after pi-os's own fill (≤ 30 s, the field still holds it: `ownFill`) replaces it;
 *      "such nach X / search for X" with a browser target fills X and submits (a browser without a search box
 *      searches the anchored search site, else the web; outside a browser the commands decide first and a miss
 *      fills a focused search field in step 6), and "google X" fills the anchored Google page's own box;
 *   3. instant commands as today: any act, answer, refusal or list wins, except the "Did you mean …?" of a
 *      name said alone that only resembles an app (an installed app's exact name said alone stays a command,
 *      DESIGN5 A4), and a command that missed (a strong open, a currency, a file search) is never typed;
 *   4. page and window questions stay with pi: deictic words, the contextScope window band, "what does it
 *      say" / "was steht da";
 *   5. explicit pi tasks with a task head (EN/DE) and requests addressed to pi ("kannst du …") stay with pi;
 *   6. everything else is typed (voice only: typing in the bar addresses pi): plain questions and phrases into
 *      `search`, `address`, `text` and `multiline` fields while `ready`, empty or not; Return only in search
 *      boxes and the address bar. Recognizer doubt (lowest word confidence < 0.2, or disagreeing first-tier
 *      readings at a low mean confidence) turns that into the check card with `voice.fill: "offer"`; a
 *      terminal always gets the offer (one Return, never submitted); credential and sensitive fields never
 *      get implicit text, and such a take is answered without classifier hints or a check card (the heard
 *      text may be the secret: DESIGN5 C5) — the host shows its own masked card.
 *
 * Pure: no I/O, no logging. Texts are user content and never leave the response.
 */

/** "nein, X" replaces pi-os's own fill only this soon after it (DESIGN5 H0, C8). */
export const FILL_REPLACE_MS = 30_000;

/** The continuity facts of a final that may fill (`accept: "fill"` and a `target`). */
export interface Continuity {
  app: InstantAppClass;
  field?: { kind: InstantFieldKind; ready: boolean; ownFill: boolean };
  /** The instant take whose open put the pinned app in front (Node's memo knows what it opened). */
  anchorTakeId?: string;
}

/**
 * The request's continuity, or null: only finals that declare `accept: "fill"` and carry a `target`. Without
 * either, every decision is exactly today's (an older host, Windows, the fill switch off).
 */
export function continuityOf(request: InstantRequest): Continuity | null {
  if (request.phase !== "final" || !accepts(request, "fill") || !request.target) return null;
  const { app, field, anchor } = request.target;
  return {
    app,
    ...(field ? { field: { kind: field.kind, ready: field.ready, ownFill: field.ownFill === true } } : {}),
    ...(anchor?.takeId ? { anchorTakeId: anchor.takeId } : {}),
  };
}

/**
 * The take's bound field is a credential or sensitive one (any `accept`): its words may be a secret, so they
 * never reach a classifier, the take memo keeps none of them, and a non-command take is not forwarded.
 */
export function secretTarget(request: Pick<InstantRequest, "target">): boolean {
  const kind = request.target?.field?.kind;
  return kind === "credential" || kind === "sensitive";
}

/** How a field kind may be typed into (contracts FILL_*): implicit, explicit only, explicit with the opt-in, never. */
export type FieldTier = "implicit" | "explicit" | "optIn" | "never";

export function fieldTier(kind: InstantFieldKind): FieldTier {
  if ((FILL_IMPLICIT_KINDS as readonly string[]).includes(kind)) return "implicit";
  if ((FILL_OPT_IN_KINDS as readonly string[]).includes(kind)) return "optIn";
  if ((FILL_NEVER_KINDS as readonly string[]).includes(kind)) return "never";
  return "explicit";
}

// ---------------------------------------------------------------------------------------------
// Closed phrase lists (EN/DE). Matched on the NFC text after leading fillers; never logged.

const B = "(?<![\\p{L}\\p{N}_])";
const E = "(?![\\p{L}\\p{N}_])";
/** Recognizer fillers before the words ("Okay, …", "Äh, …"). Not "hey": "hey pi" is an escape. */
const LEAD_FILLER = /^(?:(?:okay|ok|alright|um+|uh+|uhm+|erm|hm+|äh+m?|ähm|eh|so|also|well|na|ja|yes|yeah)(?:[,.!]\s*|\s+))+/iu;
/** Trailing politeness ASR keeps after a command ("…, bitte.", "… please", "…, danke"). */
const TAIL_POLITE = /(?:[,\s]+(?:please|bitte|danke|thanks))+[\s.!]*$/iu;
/** The same after an explicit dictation, only when set off by a comma ("tippe Hallo, bitte"): "Bis morgen, danke" is the user's text. */
const TAIL_PLEASE = /(?:,\s*(?:please|bitte))+[\s.!]*$/iu;

function lead(text: string): string {
  return text.normalize("NFC").replace(/\s+/g, " ").trim().replace(LEAD_FILLER, "").trim();
}

const PI = "(?:pi|pie|pai|py|π)";
/** "frag pi …", "ask pi …", "hey pi …", "Pi, …": the words are for pi, never typed (DESIGN5 §5.11). */
const PI_PREFIX = new RegExp(
  `^(?:(?:(?:hey|hi|hallo|hello|ok(?:ay)?)[\\s,]+${PI}${E})|(?:${PI}\\s*[,:])|(?:(?:frag|frage|fragt|ask)(?:\\s+(?:mal|doch|bitte))*\\s+${PI}${E}))`,
  "iu",
);

export function hasPiPrefix(text: string): boolean {
  return PI_PREFIX.test(lead(text));
}

/** "type …", "type in …", "dictate …" (EN). Not "write" (the agent's write intent). */
const EXPLICIT_EN = /^(?:(?:please|pls)[,\s]+)?(?:type(?:\s+in(?=[\s:,]))?|dictate)(?:[\s:,]+)(.+)$/iu;
/** "tippe …", "tipp …", "diktiere …" (DE). */
const EXPLICIT_DE = /^(?:bitte[,\s]+)?(?:tipp(?:e|en)?|diktier(?:e|en)?)(?:\s+(?:mal|bitte|doch|jetzt|noch))*(?:[\s:,]+)(.+)$/iu;
/** "gib … ein" (DE, separable): the remainder sits between. */
const EXPLICIT_GIB = /^(?:bitte[,\s]+)?gib(?:\s+(?:mal|bitte|doch|jetzt))*\s+(.+?)\s+ein[\s.!]*$/iu;
/**
 * A remainder that is no dictation: "of"/a number after the noun "type" ("type of cancer", "type 2 diabetes"), the
 * DE "tippe auf/an …" (tap on …), and a bare pronoun ("type this", "tippe das": what "this" is lives on screen).
 * Those keep today's path (the agent). Articles stay: "Tippe: Das ist ein Test." types "Das ist ein Test."
 */
const NOT_DICTATION = new RegExp(
  `^(?:(?:of|1|2|one|two|i|ii|auf|an)${E}|(?:it|this|that|these|those|here|das|dies|dieses|es|das hier|das da|this one|that one|this text|den text)[\\s.!?]*$)`,
  "iu",
);
/** "… into the search box", "… ins Suchfeld": the remainder names its own destination (agent). */
const NAMES_DESTINATION = new RegExp(
  `${B}(?:in(?:to)?|on) (?:the|this|that|my) (?:[\\p{L}-]+ )?(?:field|box|bar|search|input|textbox|address bar)${E}`
    + `|${B}(?:ins|in das|in die|in den|in dieses|in diese) (?:[\\p{L}-]+)?(?:feld|suche|suchfeld|leiste|adressleiste|eingabe|textfeld|box)${E}`,
  "iu",
);
/** "… and press enter", "… und drück Enter": a second action (agent). */
const SECOND_ACTION = new RegExp(
  `${B}(?:and|und|then|dann)\\s+(?:then\\s+|dann\\s+)?(?:press|hit|send|submit|click|tap|drück\\p{L}*|drueck\\p{L}*|schick\\p{L}*|sende|klick\\p{L}*|tipp\\p{L}* auf)${E}`,
  "iu",
);

/**
 * The remainder of an explicit dictation form ("tippe Hallo Welt" → "Hallo Welt"), original case, or null.
 * Null also for a remainder that describes, names a destination or adds an action (today's path).
 */
export function explicitRemainder(text: string): string | null {
  const said = lead(text);
  const m = EXPLICIT_EN.exec(said) ?? EXPLICIT_DE.exec(said) ?? EXPLICIT_GIB.exec(said);
  const remainder = m?.[1]?.replace(TAIL_PLEASE, "").trim();
  if (!remainder || NOT_DICTATION.test(remainder) || NAMES_DESTINATION.test(remainder) || SECOND_ACTION.test(remainder)) return null;
  return remainder;
}

/**
 * The query of a bare search form ("such nach X", "search for X": grammar/launch.ts `bareSearchQuery`), original
 * case, without trailing politeness; null when the words are no such form.
 */
export function searchQuery(text: string): string | null {
  const query = bareSearchQuery(lead(text))?.replace(TAIL_POLITE, "").trim();
  return query || null;
}

/**
 * Whole utterances that answer pi-os, cancel or submit (EN/DE, folded). Never typed implicitly: the host's own
 * prompts take them (a bare "nein" ≤ 5 s after a fill is the host's undo; "tippe nein" types the word).
 */
const CONTROL = new Set([
  "yes", "yeah", "yep", "yup", "no", "nope", "nah", "ok", "okay", "thanks", "thank you", "cancel", "never mind", "nevermind",
  "forget it", "stop", "abort", "undo", "redo", "enter", "return", "submit", "send", "go", "search", "done", "again", "back", "next",
  "confirm", "ja", "jep", "jo", "nein", "nee", "noe", "danke", "danke schon", "abbrechen", "abbruch", "vergiss es", "egal", "stopp",
  "ruckgangig", "los", "suchen", "senden", "abschicken", "absenden", "fertig", "zuruck", "weiter", "nochmal", "noch mal", "bestatigen",
  "ok danke", "okay danke", "alles klar", "passt", "gut", "genau", "richtig", "falsch",
  "hm", "hmm", "hmmm", "ah", "ahh", "oh", "eh", "uh", "um", "uhm", "ahm", "ahem", "aeh", "wait", "warte", "moment", "einen moment",
  "why", "warum", "wieso", "weshalb", "how", "wie", "what", "was", "really", "wirklich",
  // Key names said alone press a key, they are no text.
  "escape", "esc", "tab", "tabulator", "space", "leertaste",
]);

export function isControlUtterance(text: string): boolean {
  const folded = foldPhrase(text);
  return folded.length > 0 && CONTROL.has(folded);
}

/** "nein, X" / "No, I meant X" with a separator or the "I meant" words: addressed to pi-os, never typed as is. */
const CORRECTION_LIKE = /^(?:no|nope|nah|nein|nee|nö|noe)\s*(?:[,.!:;—–-]|\s+(?:i|ich)\s+(?:meant|mean|said|meinte|meine|sagte|wollte|hab(?:e)?\s+(?:gemeint|gesagt))(?![\p{L}]))/iu;

export function isCorrectionLike(text: string): boolean {
  return CORRECTION_LIKE.test(lead(text));
}

/**
 * "What does it say" / "was steht da": page questions the scope rules score low. Deixis ("this page", "diese
 * Seite", "hier") is the grammar's and the scope's; this list adds the pronoun-free ones Tom named.
 */
const PAGE_QUESTION = new RegExp([
  `^what(?:'s| does| is) (?:it|this|that|the page|the text|the article)(?: say| saying| about)`,
  `^what (?:does|did) (?:it|this|that|he|she|they) (?:say|mean)`,
  `^read (?:it|this|that|me this|me that|the (?:page|text|article))(?: to me| aloud| out)?[?!.]*$`,
  `^was steht (?:da|hier|dort|drin|darin|dabei|auf der seite|im text)`,
  `^worum geht(?:'s| es)`,
  `^was (?:bedeutet|heißt|heisst|meint|sagt) (?:das|es|er|sie|der text|die seite|der artikel)[?!.]*$`,
  `^lies (?:es|das|mir das|mir das vor|vor|das vor)[?!.]*$`,
].join("|"), "iu");

/** Scope reasons that point at the window (contracts KNOWN_SCOPE_REASONS). */
const WINDOW_REASONS: ReadonlySet<string> = new Set(["deixis-strong", "deixis-content", "deixis-weak", "pronoun", "ui-verb", "act-in-app", "bare-transform"]);

/** A page or window question (never typed): deictic or UI wording, the window band, or a named page question. */
export function isPageQuestion(text: string, scope: InstantScope = contextScope(text)): boolean {
  if (scope.window >= 0.7) return true;
  if (scope.window >= 0.5 && scope.reasons.some((reason) => WINDOW_REASONS.has(reason))) return true;
  return namesPageQuestion(text) || pointsAtScreenDe(text);
}

/** German questions: verb-first or a W-word. */
const DE_QUESTION_HEAD = /^(?:ist|sind|war|wäre|waren|kann|könnte|kannst|soll|sollte|sollen|sollten|darf|muss|müsste|hat|haben|wird|würde|macht|ergibt|gibt|lohnt|stimmt|klingt|wirkt|taugt|reicht|passt|geht|was|wie|wer|wem|wen|warum|wieso|weshalb|wozu|woher|wo|wann|welche\p{L}*)$/iu;
/** Pronominal adverbs point at something said or shown ("Was ist daran falsch?"). */
const DE_POINTING_ADVERB = /^(?:daran|darüber|darueber|davon|dazu|darauf|damit|daraus|darin)$/iu;
const DE_ARTICLE = /^(?:ein|eine|einen|einem|einer|eines|kein|keine|keinen|keinem|keiner|der|die|den|des)$/iu;
/** "macht das Sinn", "ergibt das überhaupt Sinn"; "ist es wahr" (the English "is it true" is the scope's pronoun reason). */
const DE_POINTING_PHRASE = /^(?:(?:macht|ergibt|hat) (?:das|es|dies)(?: \p{L}+)? sinn|(?:ist|war|wäre|klingt|wirkt) es(?: \p{L}+)? (?:wahr|richtig|korrekt|echt|seriös|serioes|sicher|legal|legit|ok|okay|glaubwürdig|glaubwuerdig|vertrauenswürdig|vertrauenswuerdig))$/iu;

/**
 * A German question that names what is on screen with a pronoun ("ist das wahr", "ist das ein Betrug", "sollte ich das
 * kaufen", "kann ich dem trauen", "gibt es das auch in blau", "macht das Sinn"): the English "is that true" and "should I
 * buy this" are deictic, but "das"/"dem" is also the article. German nouns are capitalized, so "das Universum", "das
 * iPhone" and "das neue Handy" stay articles and their questions are typed; a pronoun ends the question, or an article
 * or lowercase words follow it. At most 8 words. Ambiguous wording keeps the safe default: pi answers.
 */
export function pointsAtScreenDe(text: string): boolean {
  const said = lead(text).replace(/[?!.…]+$/u, "").trim();
  const words = said.split(" ").map((word) => word.replace(/[,;:]+$/u, ""));
  if (words.length < 2 || words.length > 8 || !DE_QUESTION_HEAD.test(words[0]!)) return false;
  if (DE_POINTING_PHRASE.test(said.toLowerCase())) return true;
  return words.some((word, i) => {
    if (i === 0) return false;
    if (DE_POINTING_ADVERB.test(word)) return true;
    if (!/^(?:das|dem)$/iu.test(word)) return false;
    const next = words[i + 1];
    if (next === undefined || DE_ARTICLE.test(next)) return true;
    if (/\p{Lu}/u.test(next)) return false;
    const after = words[i + 2];
    return after === undefined || !/\p{Lu}/u.test(after);
  });
}

/** One of the named page questions ("what does it say", "was steht da", "worum geht es"): the narrow list a secret field lets through. */
export function namesPageQuestion(text: string): boolean {
  return PAGE_QUESTION.test(lead(text).toLowerCase());
}

/**
 * Explicit pi tasks (TOM-ANSWERS 1): a task head at the start (EN/DE imperatives: write/schreib, summarize/fasse
 * zusammen, translate/übersetze, explain/erkläre, create/erstelle, remind/erinnere, plan, draft/entwirf,
 * reply/antworte and the other everyday assistant verbs), a request addressed to pi ("can you …", "kannst du
 * …", "hilf mir …", "lass uns …"), or a German verb-final command ("eine Mail an Anna schreiben").
 */
const OBJ = "(?:the|this|that|it|my|a|an|these|those|all)";
/** Not a verb but a title or a phrase after these words ("Call of Duty", "Hide and Seek", "Take On Me"). */
const NOT_OBJ = "(?! (?:of|and|on|to|me|in)(?![\\p{L}]))";
const TASK_EN = [
  // Writing and thinking for the user.
  "write", "rewrite", "re-write", "paraphrase", `polish ${OBJ}`, "summari[sz]e", "translate", "explain", "describe", "create", "generate", "compose",
  `draft (?:a|an|the|my|me|some)`, "reply", "respond", "remind", `plan (?:a|an|my|the|our|me|some)`, "schedule", "compare", "analy[sz]e",
  `review ${OBJ}`, `fix ${OBJ}`, `correct ${OBJ}`, "proofread", "debug", "refactor", "implement", "calculate", "compute", `convert ${OBJ}`,
  "rephrase", "reword", "shorten", `improve ${OBJ}`, "brainstorm", `outline ${OBJ}`, `research (?:the|a|how|on|my)`, "suggest", "recommend",
  "organi[sz]e", "prepare", "remember (?:that|to|this|me)", "note (?:that|down|this|to self)", "tell (?:me|us|him|her|them)", "give (?:me|us)",
  "help (?:me|us)", "help", "answer (?:the|this|that|my|her|him|them|it)", "get (?:me|us)", "focus(?: on)?",
  // Operating apps, the system and media.
  "open", "launch", `quit${NOT_OBJ}`, `exit${NOT_OBJ}`, `close ${OBJ}`, `hide${NOT_OBJ}`, "unhide", "restart", "reboot", "shut down", "shutdown", "power off",
  "log (?:out|off|in)", "logout", "sign (?:out|in)", `lock (?:${OBJ}|screen|computer|mac)`, "unlock",
  "next (?:song|track|slide|page|tab|window|video|episode|one|field|input)", "reload", "refresh", "print[.!]*$",
  "(?:go |enter |exit |leave )?full ?screen", "(?:accept|reject|decline|deny) (?:all|cookies|the cookies|everything)",
  "previous", "skip", "rewind", "replay", "shuffle", `play (?:some|a|the|my|me|music|it|this|that)`, "pause", "resume", "mute", "unmute",
  `take (?:${OBJ}|me)`, `call${NOT_OBJ}`, `email (?:${OBJ}|him|her|them)`, `mail (?:${OBJ}|him|her|them)`, `text (?:me|him|her|them|mom|dad)`,
  `run (?:${OBJ}|new)`, "pull up", "bring up", "go (?:to|back|home|forward|up|down)", `scroll`, `extract ${OBJ}`, "zoom (?:in|out)", "maximi[sz]e", "minimi[sz]e", "send", `share ${OBJ}`,
  `save ${OBJ}`, `copy ${OBJ}`, `paste ${OBJ}`, `print ${OBJ}`, `export ${OBJ}`, `download ${OBJ}`, `install ${OBJ}`, `update ${OBJ}`,
  `archive ${OBJ}`, `forward ${OBJ}`, `record ${OBJ}`, "screenshot", "enable", "disable", `connect${NOT_OBJ}`, "disconnect",
  "make (?:a|an|me|us|the|my|it|this|that|some)", "add (?:a|an|the|my|this|that|it|to|some)", "set (?:a|an|the|my|up)",
  "start (?:a|an|the|my)", "find (?:me|out|a|an|the|my|some|all)", "show (?:me|us|the|my|all|desktop)", "list (?:all|the|my)",
  "check (?:the|my|if|whether|this|that|out)", "read (?:me|it|this|that|the|my|aloud|out)",
  "call (?:me|him|her|mom|dad|my|the)", "book (?:a|an|the|me|us|my)", "order (?:a|an|the|me|us|my|some)", "buy (?:a|an|the|me|us|my|some)",
  "new (?:private |incognito )?(?:note|document|doc|file|tab|window|mail|email|e-mail|message|event|reminder|folder|list|presentation|spreadsheet)",
  "turn (?:on|off|up|down|the|it)", "switch (?:to|on|off)", "search", "look (?:for|up)",
  // Requests addressed to pi, and the continuations of a conversation ("and now in German").
  "and (?:now|then|also|what|in|how)", "let'?s", "please", "can you", "could you", "would you", "will you", "would you mind", "i want you to", "i need you to",
];
const DET_DE = "(?:mir|uns|ihm|ihr|ein|eine|einen|einem|den|die|das|dem|es|mal|bitte|meine?n?|diese?n?|alle)";
const TASK_DE = [
  // Schreiben und Denken für den Nutzer.
  "schreib(?:e|t)?", "formulier(?:e)?", "fass(?:e)?", "übersetz(?:e)?", "uebersetz(?:e)?", "erklär(?:e)?", "erklaer(?:e)?",
  "beschreib(?:e)?", "erstell(?:e)?", "erzeug(?:e)?", "generier(?:e)?", "verfass(?:e)?", "entwirf", "entwerfe", "antworte",
  "beantworte", "erinnere?", "plane", `plan ${DET_DE}`, "vergleiche", "analysier(?:e)?", "prüf(?:e)?", "pruef(?:e)?",
  "überprüf(?:e)?", "ueberpruef(?:e)?", "korrigier(?:e)?", "behebe", "repariere", "berechne", "rechne", "konvertier(?:e)?",
  "wandle", "recherchier(?:e)?", "empfiehl", `schlag(?:e)? (?:mir|uns|vor|etwas|was)`, "organisier(?:e)?", "sortier(?:e)?",
  "kürz(?:e)?", "kuerz(?:e)?", "verbesser(?:e)?", "notier(?:e)?", "merk(?:e)? dir", "hilf", "hilfe", `sag(?:e)? (?:mir|uns)`,
  "erzähl(?:e)?", "erzaehl(?:e)?", `gib (?:mir|uns)`,
  // Apps, System und Medien bedienen.
  "öffne", "oeffne", "starte", "beende", "schließ(?:e)?", "schliess(?:e)?", "versteck(?:e)?", "blende", "fahr(?:e)?", "melde",
  "sperr(?:e)?", "entsperr(?:e)?", "nächste[rsn]? (?:song|titel|lied|track|folie|seite|tab|video|folge)", "naechste[rsn]? (?:song|titel|lied|track)",
  "vorherige[rsn]?", "überspring(?:e)?", "ueberspring(?:e)?", "wiederhol(?:e)?", `spiel(?:e)? (?:${DET_DE}|etwas|was|musik)`, "pausier(?:e)?",
  "stopp(?:e)?", "schalte?", `stell(?:e)? ${DET_DE}`, `nimm ${DET_DE}`, `ruf(?:e)? (?:\\p{L}+ )?an`, `mail(?:e)? ${DET_DE}`, "navigier(?:e)?",
  "scroll(?:e)?", "zoom(?:e)?", "vergrößer(?:e)?", "vergroesser(?:e)?", "verkleiner(?:e)?", "maximier(?:e)?", "minimier(?:e)?",
  "aktivier(?:e)?", "deaktivier(?:e)?", "verbind(?:e)?", "trenn(?:e)?", "lad(?:e)? (?:\\p{L}+ )*(?:herunter|hoch)", "installier(?:e)?",
  "aktualisier(?:e)?", "synchronisier(?:e)?", `sicher(?:e)? ${DET_DE}`, "exportier(?:e)?", "importier(?:e)?", "archivier(?:e)?",
  "markier(?:e)?", "wähl(?:e)?", "waehl(?:e)?", "verschieb(?:e)?", "bestell(?:e)?", "buche", "kaufe", `kauf ${DET_DE}`, "storniere",
  `schick(?:e)? (?:${DET_DE}|an)`, "sende", `teile ${DET_DE}`, `speicher(?:e)? ${DET_DE}`, `kopier(?:e)? ${DET_DE}`, `druck(?:e)? ${DET_DE}`,
  `trag(?:e)? ${DET_DE}`, `mach(?:e)? ${DET_DE}`, "füg(?:e)?", "fueg(?:e)?", "lies", "lese", "zeig(?:e)?", "finde", "such(?:e)?", "liste",
  "neue[rsn]? (?:private[rsn]? |privat |inkognito[- ]?)?(?:notiz|dokument|datei|tab|fenster|mail|e-mail|nachricht|termin|erinnerung|ordner|liste|präsentation|tabelle)",
  "nächste[rsn]? (?:feld|eingabe)", "geh(?:e)? (?:zu|zur|zum|auf|zurück|zurueck|nach)", "(?:zurück|zurueck) (?:zu|zur|zum|nach|auf)", "wechsle", "vollbild(?:modus)?",
  // An pi gerichtet, und Fortsetzungen eines Gesprächs ("und jetzt auf Englisch", "noch kürzer").
  "und (?:jetzt|dann|nun|noch|was|wie|in|auf)", "noch (?:kürzer|kuerzer|länger|laenger|einfacher|einmal|mal)", "mach(?:e)? aus",
  "lass uns", "bitte", "kannst du", "könntest du", "koenntest du", "würdest du", "wuerdest du", "ich möchte,? dass du", "ich moechte,? dass du",
  "ich will,? dass du",
];
const TASK_HEAD = new RegExp(`^(?:${[...TASK_EN, ...TASK_DE].join("|")})${E}`, "iu");
/**
 * Verb-final commands of up to 8 words ("einen Termin erstellen", "Spotify pause", "Mach Numbers open"), not
 * W-questions: German infinitives and the English verbs mixed speech puts last.
 */
const TASK_FINAL = new RegExp(
  `${B}(?:schreiben|erstellen|erzeugen|anlegen|zusammenfassen|übersetzen|uebersetzen|erklären|erklaeren|beantworten|planen|buchen|`
    + `bestellen|kaufen|schicken|senden|anrufen|vergleichen|analysieren|berechnen|umrechnen|prüfen|pruefen|überprüfen|ueberpruefen|`
    + `korrigieren|merken|notieren|speichern|vorlesen|abspielen|öffnen|oeffnen|starten|beenden|schließen|schliessen|eintragen|`
    + `hinzufügen|hinzufuegen|pausieren|stoppen|herunterfahren|neustarten|sperren|ausblenden|open|close|quit|pause|play|stop|start|`
    // Operating the page, the browser and the system ("Seite neu laden", "nach unten scrollen", "Formular absenden").
    + `scrollen|neu ?laden|aktualisieren|drucken|ausdrucken|einfügen|einfuegen|kopieren|markieren|einschalten|ausschalten|anschalten|`
    + `abschalten|aktivieren|deaktivieren|stummschalten|minimieren|maximieren|vergrößern|vergroessern|verkleinern|abmelden|ausloggen|`
    + `absenden|abschicken|akzeptieren|ablehnen)[?!.]*$`,
  "iu",
);
/**
 * Device and page switches said without a verb ("WLAN aus", "dark mode on", "Nicht stören an", "Bildschirm heller"),
 * "mach … an/aus", and a timer or alarm with a number ("Timer 5 Minuten", "Wecker auf 7 Uhr"): closed nouns only.
 */
const SWITCH = new RegExp(
  `^(?:(?:the|den|die|das)\\s+)?(?:wlan|wi-?fi|bluetooth|dark mode|light mode|dunkelmodus|dunkler modus|heller modus|nachtmodus|night shift|`
    + `nicht stören|nicht stoeren|do not disturb|fokus|focus mode|flugmodus|airplane mode|flight mode|hotspot|vpn|airdrop|ton|sound|musik|music|`
    + `licht|lights?|mikrofon|microphone|mic|kamera|camera|untertitel|subtitles|captions|energiesparmodus|low power mode|vollbild|fullscreen)`
    + `\\s+(?:on|off|an|aus|ein|einschalten|ausschalten|anschalten)[.!]*$`
    + `|^(?:bildschirm|display|screen|helligkeit|brightness)\\s+(?:heller|dunkler|brighter|dimmer|hoch|runter|up|down)[.!]*$`
    + `|^mach(?:e)?\\s+(?:\\S+\\s+){0,3}(?:an|aus)[.!]*$`
    + `|^(?:timer|wecker|alarm|countdown)(?:\\s+(?:für|fuer|auf|um|for|at|in|on))?\\s+\\d`,
  "iu",
);
const W_QUESTION = /^(?:wie|was|wo|wann|warum|wieso|weshalb|wer|wem|wen|welche\p{L}*|kann|kannst|soll|sollte|darf|muss|ist|sind|gibt|how|what|where|when|why|who|which|can|should|is|are|do|does)(?![\p{L}])/iu;

export function hasTaskHead(text: string): boolean {
  const said = lead(text).replace(/^(?:(?:hey|hallo|hi)[,\s]+)/iu, "");
  if (TASK_HEAD.test(said) || SWITCH.test(said)) return true;
  return said.split(/\s+/).length <= 8 && TASK_FINAL.test(said) && !W_QUESTION.test(said);
}

/**
 * Router intents that are commands, never dictation (routing heuristics; all anchored at the start). Not `write`:
 * the router finds its words anywhere ("Danke für die schnelle Antwort", "thanks for the quick reply"), so pi
 * tasks are recognized by their head instead (`hasTaskHead`).
 */
const COMMAND_INTENTS: ReadonlySet<string> = new Set(["act_in_app", "open_launch", "search_computer", "browse_web"]);

/**
 * Not a command, a pi task or a page question: what an eligible field receives implicitly (step 6). The caller
 * has already ruled out policy, grammar commands, deletion vocabulary and correction-like words.
 */
export function isDictation(text: string, scope?: InstantScope): boolean {
  if (isControlUtterance(text) || hasPiPrefix(text) || hasTaskHead(text) || isPageQuestion(text, scope)) return false;
  return !COMMAND_INTENTS.has(classifyUtterance(text).intent);
}

// ---------------------------------------------------------------------------------------------
// Recognizer doubt (the check gate's doubt signals; "the router cannot place it" is no doubt with a field, policy A5)

export function voiceDoubt(sent: VoiceHypothesis, firstTier: readonly VoiceHypothesis[]): boolean {
  if (sent.minConfidence !== undefined && sent.minConfidence < VOICE.checkMinConfidence) return true;
  if (!(sent.confidence !== undefined && sent.confidence < VOICE.checkDisagreeConfidence)) return false;
  return firstTier.some((a, i) => firstTier.some((b, j) => j > i && wordsDisagree(a.text, b.text)));
}

// ---------------------------------------------------------------------------------------------
// What is typed (DESIGN5 §5.5, policy E1)

/**
 * Spoken punctuation (EN/DE), attached to the word before. Never after an article or a demonstrative ("remove the
 * comma", "das Komma" are nouns); a comma, colon or semicolon never as the last word, and "Punkt" only as the last
 * word ("auf den Punkt gebracht" stays).
 */
const SPOKEN_PUNCTUATION: readonly (readonly [readonly string[], string, "any" | "last" | "inner"])[] = [
  [["komma"], ",", "inner"], [["comma"], ",", "inner"],
  [["fragezeichen"], "?", "any"], [["question", "mark"], "?", "any"],
  [["ausrufezeichen"], "!", "any"], [["exclamation", "mark"], "!", "any"], [["exclamation", "point"], "!", "any"],
  [["doppelpunkt"], ":", "inner"], [["semikolon"], ";", "inner"], [["semicolon"], ";", "inner"],
  [["full", "stop"], ".", "any"], [["punkt"], ".", "last"],
];
const NOUN_BEFORE = new Set([
  "the", "a", "an", "this", "that", "every", "no", "der", "die", "das", "dem", "den", "des", "ein", "eine", "einem", "einen", "kein", "keine",
  "jedes", "dieses", "diesem", "dieser", "welches", "ans", "am", "im",
]);

function spokenPunctuation(text: string): string {
  const tokens = text.split(" ");
  const out: string[] = [];
  for (let i = 0; i < tokens.length; i++) {
    let matched = false;
    const before = out.length ? out[out.length - 1]!.toLowerCase().replace(/[.,;:!?]+$/u, "") : "";
    if (out.length && !NOUN_BEFORE.has(before)) {
      for (const [words, symbol, where] of SPOKEN_PUNCTUATION) {
        const end = i + words.length;
        if (end > tokens.length || (where === "last" && end !== tokens.length) || (where === "inner" && end === tokens.length)) continue;
        if (!words.every((word, k) => tokens[i + k]!.toLowerCase().replace(/[.,;:!?]+$/u, "") === word)) continue;
        out[out.length - 1] = out[out.length - 1]!.replace(/[.,;:!?]+$/u, "") + symbol;
        i = end - 1;
        matched = true;
        break;
      }
    }
    if (!matched) out.push(tokens[i]!);
  }
  return out.join(" ");
}

/** Characters that never reach a field: controls, line/paragraph separators, BOM, zero-width space and bidi controls. */
const INVISIBLE = /[\p{Cc}\u2028\u2029\u200B\u200E\u200F\u061C\u202A-\u202E\u2066-\u2069\uFEFF]/gu;
const WRAPPING_QUOTES = /^["“„«‚'‹](.+)["”“»‘'›]$/u;

/**
 * The one line a fill types: invisible and control characters out (a CR/LF would be a Return of its own, a Tab
 * would move focus), whitespace collapsed, spoken punctuation, wrapping quotes off; case, umlauts, ß and emoji
 * kept. ASR's trailing "." goes for search boxes, the address bar, code and password fields, and a single-line
 * fragment; a sentence in a text area keeps it. Null when nothing typeable is left or it is longer than an instant request (500).
 */
export function shapeFillText(raw: string, kind: InstantFieldKind): string | null {
  let text = raw.normalize("NFC").replace(INVISIBLE, " ").replace(/\s+/g, " ").trim();
  text = spokenPunctuation(text);
  text = text.replace(WRAPPING_QUOTES, "$1").trim();
  const fragment = kind === "text" && !/[.!?…]\s/u.test(text);
  const bare = kind === "search" || kind === "address" || kind === "credential" || kind === "sensitive" || fragment;
  // One ASR period goes; an initialism keeps its own ("U.S.A.", "z.B."), and so does an ellipsis.
  if (bare && /[^.\s]\.$/u.test(text) && !/^(?:\p{L}{1,2}\.)+$/u.test(text.slice(text.lastIndexOf(" ") + 1))) {
    text = text.slice(0, -1).trimEnd();
  }
  if (!text || !/[\p{L}\p{N}\p{S}]/u.test(text) || text.length > INSTANT_LIMITS.maxText || !isOneLineText(text)) return null;
  return text;
}

// ---------------------------------------------------------------------------------------------
// Responses

const FIELD_LABELS: Readonly<Record<InstantFieldKind, string>> = {
  search: "search field", address: "address bar", text: "text field", multiline: "text area", terminal: "terminal",
  sensitive: "code field", credential: "password field", confirm: "confirmation field", rename: "name field",
};

export interface FillOptions {
  /** Return after the text (search boxes and the address bar only; contracts fillSubmitAllowed). */
  submit?: boolean;
  /** Hold for one Return before typing (a sensitive field, deletion words in an explicit remainder). */
  confirm?: boolean;
  /** Recognizer of the deciding hypothesis (`voice.source`). */
  source?: string;
  /** "nein, X": the fill take this one replaces (the host undoes it first). */
  replaces?: string;
}

/**
 * `act` intent `fill`: `typeIntoPinned` with one line, `submit` only where the contract allows it, `voice.via:
 * "field"` (no "Not this", nothing learned). The title is display copy: the field kind, never the text, except a
 * search ("Search for X"; never a code or password field, which never submit).
 */
export function fillBody(text: string, kind: InstantFieldKind, options: FillOptions = {}): InstantBody {
  const submit = options.submit === true && fillSubmitAllowed(kind, false);
  const title = submit ? `Search for ${truncate(text, 120)}` : `Type into the ${FIELD_LABELS[kind]}`;
  const voice: VoiceMeta = { ...(options.source ? { source: options.source } : {}), via: "field", ...(options.replaces ? { correctsTakeId: options.replaces } : {}) };
  return {
    decision: "act", intent: "fill", title,
    action: { type: "typeIntoPinned", text, ...(submit ? { submit: true as const } : {}) },
    confirm: options.confirm === true, voice,
  };
}

/** The check card with ↩ = type it (never with Return), ⌥↩ = ask pi: `fallthrough low_confidence`, `check`, `fill: "offer"`. */
export function fillOfferBody(source?: string): InstantBody {
  return { decision: "fallthrough", reason: "low_confidence", voice: { ...(source ? { source } : {}), check: true, fill: "offer" } };
}

/** A credential or sensitive field's non-command take: no check card (it would echo the heard text), no hints, no near miss. */
export function secretMissBody(source?: string): InstantBody {
  return { decision: "fallthrough", reason: "no_match", ...(source ? { voice: { source } } : {}) };
}

/** Closed perf label of a continuity decision (logs carry it with the field kind only, never text). */
export type FillLabel = "implicit" | "explicit" | "held" | "replace" | "search" | "offer" | "secret" | "web" | "pi";

/** An explicit "tippe …" into a "type DELETE to confirm" field (DESIGN5 §5.3, policy T6). */
export const CONFIRM_FIELD_MESSAGE = "This field confirms a deletion, so pi-os won't type into it.";

let warmed = false;

/**
 * Compile the closed lists now (V8 compiles a regex on its first use), so the first take with a focused field does
 * not pay for it. Fixed strings only; idempotent.
 */
export function warmContinuity(): void {
  if (warmed) return;
  warmed = true;
  for (const text of ["frag pi wie spät ist es", "tippe Hallo Welt", "gib Albert Einstein ein", "such nach Katzen", "search for cats", "nein, Marie Curie",
    "schreib eine Mail an Anna", "Quit Spotify", "einen Termin erstellen", "was steht da", "Albert Einstein", "Hallo Komma wie geht's Fragezeichen",
    "ist das wahr"]) {
    hasPiPrefix(text);
    explicitRemainder(text);
    searchQuery(text);
    isCorrectionLike(text);
    isDictation(text);
    shapeFillText(text, "search");
  }
}
