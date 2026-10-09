import type { Normalized } from "../normalize.js";

/**
 * Whole-utterance policy checks that run before any intent grammar.
 *
 * Deletion: file deletion, Move to Trash and Empty Trash are prohibited
 * (AGENTS.md). Such requests get an instant refusal in every phase and are
 * never forwarded to the agent as a task. Ordinary text editing ("delete the
 * last sentence", "remove the bold formatting") is not file deletion and is
 * left alone, mirroring DeletionPolicy.swift.
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
  /^(?:sudo )?(?:rm|rmdir|unlink|del|erase|shred|trash)(?: -\S+)* \S/,
  // Emptying a folder deletes its files ("empty folders", "leere Ordner finden" are searches, not requests).
  /^(?:empty|empty out) (?:the|my|this|that|all|everything in)\b.*\b(?:folder|directory|downloads|desktop|documents)\b/,
  /^(?:leere|entleere) (?:den|die|das|meinen|meine|mein|diesen|diese|dieses)\b.*\b(?:ordner|verzeichnis|downloads|schreibtisch)\b/,
  /\b(?:ordner|verzeichnis|downloads|schreibtisch)\b.*\b(?:leeren|ausleeren|entleeren)$/,
];

// Uninstalling an app moves its bundle to the Trash.
const DELETE_VERB_START = /^(?:delete|remove|erase|trash|wipe|shred|purge|get rid of|destroy|uninstall|losch|losche|loschen|entferne|entfernen|vernichte|beseitige|deinstalliere)\b/;
const DELETE_VERB_END = /\b(?:loschen|entfernen|vernichten|wegwerfen|wegschmeissen|deinstallieren|delete|remove|erase|uninstall)$/;
const QUESTION = /^(?:wie|warum|wieso|weshalb|was|wann|kann|konnen|darf|soll|how|why|what|when|can|could|should|is|are|do|does)\b/;
const DELETE_INTENT =/^(?:i want to|i'd like to|i need to|help me|let's|lets|ich (?:will|mochte|muss|wurde gern(?:e)?)|hilf mir)\b.*\b(?:delete|erase|wipe|shred|trash|losch\w*|entfern\w*)\b/;

/** Objects that are text editing or in-app content, not files (DeletionPolicy "delete text/word/line"). */
const EDIT_OBJECT = new RegExp(
  "\\b(?:text|word|words|line|lines|sentence|sentences|paragraph|paragraphs|character|characters|letter|letters|" +
    "formatting|format|bold|italic|underline|highlight|highlighting|spaces?|whitespace|typos?|emoji|emojis|" +
    "background|watermark|red eye|noise|filter|duplicates?|blank rows?|empty rows?|rows?|columns?|cells?|comments?|" +
    "selection|bullet|bullets|indent|indentation|link|links|hyperlinks?|tag|tags|label|labels|" +
    "wort|worter|zeile|zeilen|satz|satze|absatz|absatze|zeichen|buchstaben|leerzeichen|tippfehler|formatierung|" +
    "fett|kursiv|unterstreichung|hintergrund|wasserzeichen|duplikate|spalten?|zellen?|kommentare?|markierung|einzug)\\b",
);

/** An edit-object word used as an adjective of files ("duplicate files", "doppelte Fotos") is still file deletion. */
const FILE_OBJECT = new RegExp(
  "\\b(?:duplicates?|duplicated|doppelte[nrs]?|empty|blank|leere[nrs]?|old|alte[nrs]?|large|grosse[nrs]?)\\s+" +
    "(?:files?|folders?|director(?:y|ies)|photos?|pictures?|images?|screenshots?|videos?|downloads|documents|apps?|" +
    "dateien|datei|ordner|verzeichnisse?|fotos?|bilder|bildschirmfotos|dokumente|programme?)\\b",
);

export function isDeletionRequest(n: Normalized): boolean {
  const text = fold(n.lower);
  if (TRASH_PHRASES.some((pattern) => pattern.test(text))) return true;
  const verbFirst = DELETE_VERB_START.test(text) || DELETE_INTENT.test(text);
  // German verb-final imperatives ("die alten Downloads löschen"); questions ("wie kann ich … löschen") are not requests.
  const verbLast = !verbFirst && DELETE_VERB_END.test(text) && text.split(" ").length <= 8 && !QUESTION.test(text);
  if (!verbFirst && !verbLast) return false;
  return FILE_OBJECT.test(text) || !EDIT_OBJECT.test(text);
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
    "offne|starte|erstelle|schreib|schreibe|sende|schick|schicke|such|suche|finde|geh|gehe|schliess|schliesse|spiel|spiele|klick|klicke|" +
    "speicher|speichere|antworte|fuge|mach|mache|kopiere|verschiebe|benenne|teile|buche|bestelle|kaufe|schalte|zeig|zeige|lies|ubersetze|fasse)\\b",
);

export function isCompound(n: Normalized): boolean {
  const text = fold(n.lower);
  return COMPOUND_JOINER.test(text) || COMPOUND_VERB.test(text);
}
