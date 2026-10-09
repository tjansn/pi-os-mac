import { localToday, monthRange, relativeRange, yearRange, type RelativeRangeKey } from "../engines/dates.js";
import type { Normalized } from "../normalize.js";
import type { FileQuery, MatchContext, Parsed } from "../types.js";
import { MONTHS } from "./time.js";

/**
 * File-search phrasing (EN + DE) → a structured name query. A rule needs an
 * explicit file scope ("on my computer", "auf dem Mac"), a file-implying verb
 * (find, locate, where is, finde, wo ist) or a file kind ("pdfs"); a bare
 * "search X" stays ambiguous and is left to the agent.
 */

const FILE_EN = /^(?:search|look|find|locate|where is|where's|where are|show me|get me)(?: on| in| through)?(?: my| the)?(?: (?:computer|mac|files|disk|drive|documents|downloads|desktop))?(?: for)?(?: (?:my|the|a|an|all|some))? (.+)$/;
const FILE_DE = /^(?:such|suche|such mal|find|finde|zeig|zeige|zeig mir|zeige mir|wo ist|wo sind|wo liegt|wo liegen)(?: (?:auf|in) (?:meinem|dem|meinen|den) (?:computer|mac|rechner|dateien|downloads|dokumenten|schreibtisch))?(?: nach)?(?: (?:der|die|das|den|dem|meiner|meinem|meine|meinen|einer|einem|eine|einen|alle))? (.+)$/;
const EXPLICIT_SCOPE = /\b(?:computer|mac|files|disk|drive|rechner|festplatte|dateien|finder)\b/;
/** Verbs that imply a file by themselves; "where is …" / "show me …" need evidence ("where is my order" is not a file). */
const STRONG_FILE_VERB = /^(?:find|locate|finde)\b/;
const NOT_FILES = /\b(?:page|website|web|internet|online|google|youtube|wikipedia|seite|webseite|nearby|nearest|closest|near me|in der nähe|nächste[nrs]?|restaurants?|hotels?|flights?|flüge|weather|wetter|recipes?|rezepte?|news|nachrichten|email|e-mail|emails|mail|mails|messages?)\b|^(?:find|finde) (?:out|heraus)\b/;
const QUESTION_WORDS = /\b(?:who|what|why|how|when|which|wer|warum|wieso|wann|welche[nrs]?)\b/;
/** Nouns that make a weak verb a file search. */
const DOC_NOUNS = new Set([
  "file", "files", "document", "documents", "doc", "docs", "invoice", "invoices", "rechnung", "rechnungen", "contract", "contracts",
  "vertrag", "verträge", "receipt", "receipts", "quittung", "beleg", "belege", "resume", "cv", "lebenslauf", "report", "reports",
  "bericht", "berichte", "datei", "dateien", "dokument", "dokumente", "notes", "notizen", "letter", "brief", "offer", "angebot",
  "scan", "scans", "draft", "drafts", "entwurf", "recording", "recordings", "aufnahme", "aufnahmen", "payslip", "gehaltsabrechnung",
  "lease", "mietvertrag", "statement", "kontoauszug",
]);

/** Kind head words → UTI. Screenshot words also stay as name terms. */
const KINDS: Readonly<Record<string, { uti: string; keepTerm?: string }>> = {
  pdf: { uti: "com.adobe.pdf" }, pdfs: { uti: "com.adobe.pdf" },
  screenshot: { uti: "public.image", keepTerm: "screenshot" }, screenshots: { uti: "public.image", keepTerm: "screenshot" },
  bildschirmfoto: { uti: "public.image", keepTerm: "bildschirmfoto" }, bildschirmfotos: { uti: "public.image", keepTerm: "bildschirmfoto" },
  image: { uti: "public.image" }, images: { uti: "public.image" }, picture: { uti: "public.image" }, pictures: { uti: "public.image" },
  photo: { uti: "public.image" }, photos: { uti: "public.image" }, bild: { uti: "public.image" }, bilder: { uti: "public.image" },
  foto: { uti: "public.image" }, fotos: { uti: "public.image" },
  folder: { uti: "public.folder" }, folders: { uti: "public.folder" }, ordner: { uti: "public.folder" }, directory: { uti: "public.folder" },
  presentation: { uti: "public.presentation" }, presentations: { uti: "public.presentation" }, "präsentation": { uti: "public.presentation" },
  "präsentationen": { uti: "public.presentation" }, slides: { uti: "public.presentation" }, keynote: { uti: "public.presentation" },
  keynotes: { uti: "public.presentation" }, spreadsheet: { uti: "public.spreadsheet" }, spreadsheets: { uti: "public.spreadsheet" },
  tabelle: { uti: "public.spreadsheet" }, tabellen: { uti: "public.spreadsheet" }, video: { uti: "public.movie" },
  videos: { uti: "public.movie" }, movie: { uti: "public.movie" }, movies: { uti: "public.movie" }, film: { uti: "public.movie" },
  filme: { uti: "public.movie" }, audio: { uti: "public.audio" }, song: { uti: "public.audio" }, songs: { uti: "public.audio" },
};

const STOPWORDS = new Set([
  "the", "a", "an", "my", "our", "your", "his", "her", "their", "of", "for", "about", "from", "with", "on", "in", "to", "i", "me",
  "called", "named", "titled", "file", "files", "document", "documents", "doc", "docs", "some", "any", "all", "that", "which", "where",
  "downloaded", "saved", "created", "got", "received", "made", "wrote", "written", "sent", "edited", "opened", "is", "are", "was",
  "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "mein", "meine", "meinen", "meinem", "meiner",
  "über", "von", "vom", "zu", "zum", "zur", "mit", "für", "namens", "datei", "dateien", "dokument", "dokumente", "ich", "habe", "hab",
  "heruntergeladen", "gespeichert", "erstellt", "bekommen", "geschickt", "aus", "im", "auf",
]);

const RANGE_WORDS: Readonly<Record<string, RelativeRangeKey>> = {
  today: "today", yesterday: "yesterday", "this week": "this week", "last week": "last week", "this month": "this month",
  "last month": "last month", "this year": "this year", "last year": "last year", heute: "today", gestern: "yesterday",
  "diese woche": "this week", "letzte woche": "last week", "letzter woche": "last week", "dieser woche": "this week",
  "diesen monat": "this month", "diesem monat": "this month", "letzten monat": "last month", "letztem monat": "last month",
  "dieses jahr": "this year", "diesem jahr": "this year", "letztes jahr": "last year", "letztem jahr": "last year",
};

const MONTH_TAIL = /\s+(?:from|in|of|during|since|vom|von|im|aus dem|aus|seit)\s+([a-zäöü]+)(?:\s+(\d{4}))?$/;
const YEAR_TAIL = /\s+(?:from|in|of|vom|von|im|aus dem jahr|aus)\s+(\d{4})$/;
const RELATIVE_TAIL = /\s+(?:(?:from|in|of|during|since|von|vom|aus|seit|in der|aus der|von der|im)\s+)?(today|yesterday|this week|last week|this month|last month|this year|last year|heute|gestern|diese woche|dieser woche|letzte woche|letzter woche|diesen monat|diesem monat|letzten monat|letztem monat|dieses jahr|diesem jahr|letztes jahr|letztem jahr)$/;

function dateTail(query: string, ctx: MatchContext): { rest: string; range?: FileQuery["range"]; rangeLabel?: string } {
  const today = localToday(ctx.now);
  const month = MONTH_TAIL.exec(query);
  const monthNumber = month ? MONTHS[month[1]!] : undefined;
  if (month && monthNumber !== undefined) {
    const range = monthRange(monthNumber, month[2] ? Number(month[2]) : undefined, today);
    const label = new Intl.DateTimeFormat(ctx.locale, { month: "long", year: "numeric" }).format(new Date(range.year, monthNumber - 1, 15));
    return { rest: query.slice(0, month.index), range: { fromMs: range.fromMs, toMs: range.toMs }, rangeLabel: label };
  }
  const year = YEAR_TAIL.exec(query);
  if (year) return { rest: query.slice(0, year.index), range: yearRange(Number(year[1])), rangeLabel: year[1]! };
  const relative = RELATIVE_TAIL.exec(query);
  const key = relative ? RANGE_WORDS[relative[1]!] : undefined;
  if (relative && key) return { rest: query.slice(0, relative.index), range: relativeRange(key, today), rangeLabel: relative[1]! };
  return { rest: query };
}

/** True when the utterance starts like a file search ("find …", "wo ist …"), whether or not it parses as one. */
export function isFileSearchPhrase(lower: string): boolean {
  return FILE_EN.test(lower) || FILE_DE.test(lower);
}

export function matchFileSearch(n: Normalized, ctx: MatchContext): Parsed | null {
  const lower = n.lower;
  const m = FILE_EN.exec(lower) ?? FILE_DE.exec(lower);
  if (!m || NOT_FILES.test(lower)) return null;
  const tail = dateTail(m[1]!.trim(), ctx);
  const words = tail.rest.split(/\s+/).filter(Boolean);
  let contentType: string | undefined;
  const terms: string[] = [];
  for (const word of words) {
    const kind = KINDS[word];
    if (kind && !contentType) {
      contentType = kind.uti;
      if (kind.keepTerm) terms.push(kind.keepTerm);
      continue;
    }
    if (!STOPWORDS.has(word)) terms.push(word.replace(/^["']|["']$/g, ""));
  }
  const evidence = contentType !== undefined || tail.range !== undefined || EXPLICIT_SCOPE.test(lower)
    || words.some((word) => DOC_NOUNS.has(word) || /\.[a-z0-9]{2,5}$/.test(word));
  const explicit = evidence || (STRONG_FILE_VERB.test(lower) && !QUESTION_WORDS.test(m[1]!));
  const cleaned = terms.filter((term) => term.length > 0 && term.length <= 64 && !/[\u0000-\u001f]/.test(term));
  if (!explicit || cleaned.length === 0 || cleaned.length > 5) return null;
  return {
    kind: "file_search",
    query: {
      terms: cleaned,
      label: cleaned.join(" "),
      ...(contentType ? { contentType } : {}),
      ...(tail.range ? { range: tail.range, rangeLabel: tail.rangeLabel ?? "" } : {}),
    },
  };
}
