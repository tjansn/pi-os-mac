import type { Normalized } from "../normalize.js";
import { isFileSearchPhrase } from "./files.js";
import { isWebSearchPhrase } from "./launch.js";

/**
 * Whole-utterance policy checks that run before any intent grammar.
 *
 * Deletion: file deletion, Move to Trash and Empty Trash are prohibited
 * (AGENTS.md). Such requests get an instant refusal in every phase and are
 * never forwarded to the agent as a task. The rule is deliberately narrow,
 * because ordinary text editing and in-app edits must keep working:
 *   - Trash phrases ("empty the trash", "move … to the trash", "Papierkorb
 *     leeren"), shell commands with a flag or a path ("rm -rf ~", "del a.pdf")
 *     and strong verbs (trash/shred with an object, wipe, purge, destroy,
 *     uninstall, deinstallieren) are refused.
 *   - Weak verbs (delete, remove, erase, get rid of, löschen, entfernen) are
 *     refused only when the object is evidently a file: a file noun ("the zip
 *     files", "Dateien", "my documents") that is not an edit object, a file
 *     adjective + noun ("old screenshots"), a file name or path, or an
 *     uninstall phrasing ("remove Zoom from my Mac"). Unknown objects ("delete
 *     the comma", "lösche den Termin") are not refused; the dispatcher still
 *     refuses a bare object that is exactly an installed app ("delete Slack").
 *   - Information questions ("how do I empty the trash") and read-only
 *     requests (web search, file search, reminders) are never refused unless a
 *     follow-on clause asks for the deletion itself.
 * This is a refusal grammar, not a filesystem sandbox: the host's native
 * checks stay the enforcement layer.
 */

export const DELETION_REFUSAL_MESSAGE = "pi-os never deletes files, moves them to the Trash or empties the Trash.";

function fold(text: string): string {
  return text.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ß/g, "ss");
}

const TRASH_PHRASES: readonly RegExp[] = [
  /\b(?:empty|clear|clean out|clean up|purge|flush)(?: out)?(?: the| my)? (?:trash|trash can|bin|recycle bin|wastebasket)\b/,
  /\b(?:trash|bin|recycle bin)(?: can)? (?:empty|emptied)\b/,
  /\b(?:papierkorb|mulleimer|mull)\b.*\b(?:leeren|ausleeren|entleeren|leer machen|loschen)\b/,
  /\b(?:leere|leer|entleere|lehre)\b.*\b(?:papierkorb|mulleimer)\b/,
  /\b(?:move|put|send|drag|throw|toss)\b.*\b(?:to|in|into) (?:the |my )?(?:trash|bin|recycle bin|wastebasket)\b/,
  /\b(?:in den|in meinen|zum|in) papierkorb\b/,
  /\b(?:permanently delete|delete permanently|endgultig loschen|sofort loschen)\b/,
  // Emptying a folder deletes its files ("empty folders", "leere Ordner finden" are searches, not requests).
  /^(?:empty|empty out) (?:the|my|this|that|all|everything in)\b.*\b(?:folder|directory|downloads|desktop|documents)\b/,
  /^(?:leere|entleere) (?:den|die|das|meinen|meine|mein|diesen|diese|dieses)\b.*\b(?:ordner|verzeichnis|downloads|schreibtisch)\b/,
  /\b(?:ordner|verzeichnis|downloads|schreibtisch)\b.*\b(?:leeren|ausleeren|entleeren)$/,
];

/** Shell deletion commands need a flag or a path/filename argument ("del taco …", "rm williams boots" are not commands). */
const COMMAND_FLAG = /^(?:sudo )?(?:rm|rmdir|unlink|del|erase|shred|trash)(?: -\S+)+ \S/;
const COMMAND_PATH = /^(?:sudo )?(?:rm|rmdir|unlink|del|erase|shred|trash) (?:\S*[/~*]|\S+\.[a-z0-9]{1,5}\b)|^(?:sudo )?rmdir \S/;

/** Verbs that mean deletion whatever the object; uninstalling an app moves its bundle to the Trash. */
const STRONG_VERB_START = /^(?:trash|shred|wipe|purge|destroy|uninstall|vernichte|deinstalliere)\b/;
const STRONG_VERB_END = /\b(?:deinstallieren|vernichten|wegwerfen|wegschmeissen)$/;
/** "trash talk", "shred guitar lessons": a leading trash/shred is a verb only before a determiner, pronoun or file object. */
const NOUN_COMPOUND_LEAD = /^(?:trash|shred)(?:\s+(.*))?$/;
const DELETION_NEXT = /^(?:the|my|this|that|these|those|all|every|everything|it|them|old|older|alte[nrs]?|die|das|den|meine[nrs]?|alle|diese[nrs]?)$/;

/** Verbs that are deletion only with a file object (text editing uses them all the time). */
const WEAK_VERB_START = /^(?:delete|remove|erase|get rid of|losch|losche|loschen|entferne|entfernen|beseitige)\b/;
const WEAK_VERB_END = /\b(?:loschen|entfernen|delete|remove|erase)$/;
const QUESTION = /^(?:wie|warum|wieso|weshalb|was|wann|kann|konnen|darf|soll|how|why|what|when|can|could|should|is|are|do|does)\b/;
const DELETE_INTENT = new RegExp(
  "^(?:i want to|i'd like to|i need to|help me|let's|lets|please|can you|could you|how about(?: you)?|what about|why don'?t you|why not|" +
    "ich (?:will|mochte|muss|wurde gern(?:e)?)|hilf mir)\\b.*\\b(?:delete|erase|remove|wipe|shred|trash|uninstall|losch\\w*|entfern\\w*)\\b",
);
const INTENT_UNINSTALL = /^(?:i want to|i'd like to|i need to|help me|let's|lets|please|can you|could you|how about(?: you)?|why don'?t you|ich (?:will|mochte|muss|wurde gern(?:e)?)|hilf mir)\b.*\b(?:uninstall|deinstallier\w*)\b/;
/** "remove Zoom from my Mac", "entferne Zoom vom Mac". */
const UNINSTALL_PHRASE = /\bfrom (?:my|the|this) (?:mac|computer|laptop|macbook)\b|\bvom (?:mac|computer|rechner|macbook)\b/;

/** Information questions are answered, not refused ("how do I empty the trash", "wie leere ich den Papierkorb"). */
const INFO_QUESTION = /^(?:how|why|what|what's|whats|when|where|which|who|wie|warum|wieso|weshalb|was|wann|wo|welche[nrsm]?)\b|\b(?:how to|how do i|how can i|wie man)\b/;
/** Request idioms that start like questions but ask for the action. */
const REQUEST_IDIOM = /^(?:how about|what about|why don'?t you|why not|wie war(?:e)? es|wie wars)\b/;
const REMINDER_PREFIX = /^(?:remind me|set a reminder|create a reminder|add a reminder|erinnere mich|erinner mich)\b/;
/** A follow-on clause that asks for the deletion ("find old screenshots and delete them"). */
const DELETE_CLAUSE = /\b(?:and|und|then|dann)(?: then| dann)? (?:delete|remove|erase|trash|shred|losche|losch|loschen|entferne|entfernen)\b/;

/** Objects that are text editing or in-app content, not files (DeletionPolicy "delete text/word/line"). */
const EDIT_OBJECT = new RegExp(
  "\\b(?:text|word|words|line|lines|sentence|sentences|paragraph|paragraphs|character|characters|letter|letters|" +
    "formatting|format|bold|italic|underline|highlight|highlighting|spaces?|whitespace|typos?|emoji|emojis|" +
    "background|watermark|red eye|noise|filter|duplicates?|blank rows?|empty rows?|rows?|columns?|cells?|comments?|" +
    "selection|bullet|bullets|indent|indentation|link|links|hyperlinks?|tag|tags|label|labels|" +
    "wort|worter|zeile|zeilen|satz|satze|absatz|absatze|zeichen|buchstaben|leerzeichen|tippfehler|formatierung|" +
    "fett\\w*|kursiv|unterstreichung|hintergrund|wasserzeichen|duplikate|spalten?|zellen?|kommentare?|markierung|einzug)\\b",
);
/** "… from the document / aus der Präsentation" at the end: the object lives inside an app. */
const IN_APP_CONTEXT = new RegExp(
  "\\b(?:from|in|on|of) (?:the|this|my|that) (?:document|doc|slide|slides|presentation|deck|email|mail|message|note|page|post|draft|" +
    "spreadsheet|sheet|text|chat|thread|story|reel|profile)$|" +
    "\\b(?:aus|in|von|auf) (?:der|dem|diesem|dieser|meiner|meinem) (?:dokument|folie|prasentation|mail|e-mail|nachricht|notiz|seite|text|tabelle|chat)$",
);

/** An edit-object word used as an adjective of files ("duplicate files", "doppelte Fotos") is still file deletion. */
const FILE_OBJECT = new RegExp(
  "\\b(?:duplicates?|duplicated|doppelte[nrs]?|empty|blank|leere[nrs]?|old|alte[nrs]?|large|grosse[nrs]?)\\s+" +
    "(?:files?|folders?|director(?:y|ies)|photos?|pictures?|images?|screenshots?|videos?|downloads|documents|apps?|" +
    "dateien|datei|ordner|verzeichnisse?|fotos?|bilder|bildschirmfotos|dokumente|programme?)\\b",
);
/** Nouns that name files, folders, apps or disks. "documents" only in the plural: "the document" is an edit context. */
const FILE_TARGET = new RegExp(
  "\\b(?:files?|folders?|director(?:y|ies)|downloads?|desktop|documents|photos?|pictures|screenshots?|videos?|movies?|" +
    "recordings?|songs?|music|mp3s?|pdfs?|zips?|dmgs?|installers?|backups?|invoices?|receipts?|logs|caches?|archives?|" +
    "attachments?|apps?|applications?|programs?|disk|drive|hard drive|volume|time machine|" +
    "dateien|datei|ordner|verzeichnis(?:se)?|schreibtisch|dokumente|fotos?|bilder|bildschirmfotos|aufnahmen?|sicherungen|" +
    "rechnungen?|programme?|anwendungen?|festplatte|laufwerk)\\b",
);
const FILENAME = /(?:^|\s)[\w-]+\.[a-z][a-z0-9]{1,4}\b|(?:^|\s)[~/]/;
const PATHLIKE = /^(?:[~/*]|\S*\/|[\w-]+\.[a-z][a-z0-9]{1,4}$)/;

/** Text editing and in-app edits on a bare pronoun or the whole text: the agent handles them with the screen. */
const BARE_EDIT = new RegExp(
  "^(?:delete|remove|erase|clear|losch\\w*|entfern\\w*)\\s+(?:it|this|that|everything(?: (?:that )?i(?: just)? (?:typed|wrote))?|" +
    "all of it|all of that|all that|the rest|what i(?: just)? (?:typed|wrote)|das|es|alles(?: was ich(?: gerade)? (?:getippt|geschrieben) habe)?|" +
    "das alles|den rest)$",
);

function fileEvidence(text: string): boolean {
  if (FILE_OBJECT.test(text) || FILENAME.test(text)) return true;
  return FILE_TARGET.test(text) && !EDIT_OBJECT.test(text) && !IN_APP_CONTEXT.test(text);
}

function strongVerb(text: string): boolean {
  if (STRONG_VERB_START.test(text)) {
    const lead = NOUN_COMPOUND_LEAD.exec(text);
    if (!lead) return true;
    const rest = lead[1] ?? "";
    if (!rest) return false;
    const next = rest.split(" ")[0] ?? "";
    return DELETION_NEXT.test(next) || PATHLIKE.test(next) || FILE_OBJECT.test(rest) || FILE_TARGET.test(next);
  }
  return STRONG_VERB_END.test(text) && !QUESTION.test(text);
}

function compound(text: string): boolean {
  return COMPOUND_JOINER.test(text) || COMPOUND_VERB.test(text);
}

export function isDeletionRequest(n: Normalized): boolean {
  const text = fold(n.lower);
  const followOn = compound(text);
  if (!followOn) {
    if (INFO_QUESTION.test(text) && !REQUEST_IDIOM.test(text)) return false;
    if (REMINDER_PREFIX.test(text) || isWebSearchPhrase(n.lower) || isFileSearchPhrase(n.lower)) return false;
  } else if (DELETE_CLAUSE.test(text) && fileEvidence(text)) {
    return true;
  }
  if (TRASH_PHRASES.some((pattern) => pattern.test(text))) return true;
  if (COMMAND_FLAG.test(text) || COMMAND_PATH.test(text)) return true;
  if (strongVerb(text) || INTENT_UNINSTALL.test(text)) return true;
  const verbFirst = WEAK_VERB_START.test(text) || DELETE_INTENT.test(text);
  // German verb-final imperatives ("die alten Downloads löschen"); questions ("wie kann ich … löschen") are not requests.
  const verbLast = !verbFirst && WEAK_VERB_END.test(text) && text.split(" ").length <= 8 && !QUESTION.test(text);
  if (!verbFirst && !verbLast) return false;
  return fileEvidence(text) || UNINSTALL_PHRASE.test(text);
}

/** "delete it", "lösche alles was ich getippt habe": deictic text editing, never a file request. */
export function isBareEdit(n: Normalized): boolean {
  return BARE_EDIT.test(fold(n.lower));
}

const DETERMINER = /^(?:the|a|an|my|your|our|this|that|these|those|all|every|some|der|die|das|den|dem|des|ein|eine|einen|mein|meine|meinen|meinem|alle|diese[nrsm]?)$/;
const TARGET_VERB_FIRST = /^(?:delete|remove|erase|get rid of|losch|losche|loschen|entferne|entfernen|beseitige) (.+)$/;
const TARGET_VERB_LAST = /^(.+) (?:loschen|entfernen)$/;

/**
 * The bare object of a weak deletion verb ("delete Slack", "Zoom löschen"), for the dispatcher's
 * installed-app check. Null for determiners ("delete my notes" is in-app content), edits and
 * anything longer than three words.
 */
export function deletionTarget(n: Normalized): string | null {
  const text = fold(n.lower);
  const m = TARGET_VERB_FIRST.exec(text) ?? TARGET_VERB_LAST.exec(text);
  const object = m?.[1]?.trim();
  if (!object || object.length > 40 || EDIT_OBJECT.test(object)) return null;
  const words = object.split(" ");
  if (words.length > 3 || DETERMINER.test(words[0] ?? "")) return null;
  return object;
}

/**
 * Deixis: the request is about something on screen (this page, the selected
 * text, hier, markiert …). Instant grammar never answers those; the agent
 * gets them with screen context. Calendar phrases ("this week", "diese
 * Woche") are not deixis.
 */
const TEMPORAL_THIS = /\b(?:this|next|last) (?:morning|afternoon|evening|week|weekend|month|year|quarter)\b|\b(?:diese[nrsm]?|dieses|nachste[nrs]?|letzte[nrs]?) (?:woche|wochenende|monat|jahr|quartal|morgen|abend|nachmittag)\b|\bheute (?:morgen|abend|nachmittag)\b/g;
const DEICTIC = /\b(?:this|that|these|those|here|selected|highlighted|hovered|on screen|on the screen|on my screen|current (?:page|window|tab|document|file|app|selection|email|mail)|dies|diese|dieser|dieses|diesem|diesen|hier|markiert\w*|ausgewahlt\w*|selektiert\w*|aktuelle[nrs]? (?:seite|fenster|tab|dokument|datei|app|mail))\b/;

export function isDeictic(n: Normalized): boolean {
  return DEICTIC.test(fold(n.lower).replace(TEMPORAL_THIS, " "));
}

/**
 * Compound requests ("open figma and create a new file", "…und dann…") go to
 * the agent as a whole; instant grammar handles exactly one intent.
 */
const COMPOUND_JOINER = /\b(?:and then|and also|then|afterwards|after that|und dann|und danach|danach|anschliessend|und auch|ausserdem)\b|,\s*(?:then|dann|and|und)\b/;
const COMPOUND_VERB = new RegExp(
  "\\b(?:and|und)\\s+(?:open|launch|start|create|make|write|send|type|search|find|go|close|quit|play|click|save|reply|tell|add|" +
    "copy|paste|move|rename|share|email|book|order|buy|turn|set|show|read|summari[sz]e|translate|" +
    "delete|remove|erase|trash|empty|shred|wipe|destroy|uninstall|" +
    "offne|starte|erstelle|schreib|schreibe|sende|schick|schicke|such|suche|finde|geh|gehe|schliess|schliesse|spiel|spiele|klick|klicke|" +
    "speicher|speichere|antworte|fuge|mach|mache|kopiere|verschiebe|benenne|teile|buche|bestelle|kaufe|schalte|zeig|zeige|lies|ubersetze|fasse|" +
    "losche|loschen|entferne|leere|wirf)\\b",
);

export function isCompound(n: Normalized): boolean {
  return compound(fold(n.lower));
}
