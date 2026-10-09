import {
  MAX_SCOPE_REASONS, SCOPE_THRESHOLDS, type ContextScope, type ContextScorer, type InstantScope,
} from "../../contracts/context.js";
import { boundedUtterance, classifyUtterance, CONTENT_DEIXIS, SCREEN_DEIXIS, screenEvidence, type ClassifyContext } from "./heuristics.js";

/**
 * Context scope rules v2 (DESIGN2 §5.5, r2/classifier.md §4): how likely an utterance refers to the
 * user's active window. A port of the frozen prototype `heuristic_v2.frozen.mjs` (sha256 bd5a43c8…),
 * plus the pre-registered "v2 additions" below (the context report's misses and Tom's examples),
 * gated by test/contextScope.test.ts on the blind holdout2 set.
 *
 * Advisory only: /instant reports the score, the host's chip decides what is sent (contracts/context.ts),
 * and nothing here authorizes or triggers anything. Pure, ~2 µs, no I/O; never logs, stores or echoes
 * the text: the output is a number and content-free reason codes.
 */

const B = "(?<![\\p{L}\\p{N}_])";
const E = "(?![\\p{L}\\p{N}_])";
const anywhere = (alternatives: string) => new RegExp(`${B}(?:${alternatives})${E}`, "iu");
const leading = (alternatives: string) => new RegExp(`^(?:${alternatives})${E}`, "iu");

/** Leading fillers (v2 keeps its own list: depth/speed words are content here). */
const FILLERS = /^(?:(?:please|pls|hey|ok(?:ay)?|so|now|quick(?: question)?|bitte|jetzt|dann|nun|schnell|kurz|can you|could you|would you|kannst du|könntest du|mal)[,:\s]+)+/iu;

// On-screen nouns (EN/DE), a superset of heuristics.ts SCREEN_NOUNS. v2 addition: "bug".
const NOUNS_EN = "window|page|tab|screen|button|field|form|dialog|popup|pop-up|banner|error|message|messages|email|e-mail|mail|text|paragraph|sentence|image|picture|photo|chart|graph|diagram|table|code|function|file|document|doc|line|link|video|post|tweet|list|cell|column|row|slide|menu|icon|sheet|spreadsheet|website|site|article|chat|thread|comment|screenshot|invoice|invite|invitation|paper|diff|pr|pull request|sender|author|console|terminal output|stack ?trace|traceback|log|order|offer|cart|essay|draft|subtitles|transcript|grammar|typos?|spelling|wording|question|selection|cookie banner|download button|results?|search results|flights?|options?|numbers|price|total|bug";
const NOUNS_DE = "fenster|seite|tab|bildschirm|knopf|button|schaltfläche|feld|formular|dialog|popup|banner|fehler|fehlermeldung|meldung|nachricht|nachrichten|mail|e-mail|text|absatz|satz|bild|foto|diagramm|grafik|tabelle|code|funktion|datei|dokument|zeile|link|video|post|liste|zelle|spalte|folie|menü|symbol|artikel|chat|thread|kommentar|rechnung|einladung|termin|angebot|versand|bestellung|warenkorb|stacktrace|konsole|log|absender|autor|entwurf|aufsatz|untertitel|grammatik|tippfehler|rechtschreibung|formulierung|frage|auswahl|ergebnisse?|flüge?|optionen|zahlen|preis|summe|kunde|kundin";
/** "the [up to two modifiers] noun": "the last message", "the download button", "den blauen Knopf". */
const DEFINITE = new RegExp(`${B}(?:the|this|that|these|those|my|die|der|das|den|dem|des|diese[mnrs]?|meine[mnrs]?)(?: [\\p{L}-]+){0,2}? (?:${NOUNS_EN}|${NOUNS_DE})(?:s|n|en|e)?${E}`, "iu");
/** A determiner straight after a comma is a German relative pronoun ("ein Skript, das Dateien …"). */
const RELATIVE = /,\s*(?:das|die|der|den|dem)\s/giu;
/** Named-site navigation: "the page of/on/von <Name>", any domain. */
const NAMED_SITE = anywhere("(?:page|seite|website|site|webseite) (?:of|on|from|von|auf|bei) \\p{L}+|[a-z0-9-]+\\.(?:com|de|org|net|io|ai|dev|app|co)");
/** Generic "the X of Y" knowledge phrases that are not on screen. */
const NOT_SCREEN = anywhere("the (?:page cache|error rate|screen size|history|meaning|population|difference|weather)|die (?:seite eines|geschichte|handlung|hauptstadt|bedeutung)|error code \\S+|fehlercode \\S+|(?:lock|sperr\\p{L}*) (?:the |den )?(?:screen|bildschirm)|(?:screen|bildschirm) (?:time|zeit|size|größe)");
/** Inline content: a colon followed by ≥ 3 words, or a quoted span. */
const INLINE = /:\s*(?:\S+\s+){2,}\S+|["'„“‚‘«»][^"'„“‚‘«»]{2,}["'„“‚‘«»]/u;
const INLINE_ABOUT_WINDOW = /(?:this|the) (?:page|email|mail|window|screen)|(?:diese|die) (?:seite|mail)/iu;
/** Pronouns that need an antecedent; at the first turn it can only be on screen. */
const PRONOUN_OBJ = anywhere("(?:make|rewrite|fix|translate|shorten|summari[sz]e|explain|check|proofread|improve|reply to|answer|send|read) (?:it|that|them)|(?:is|was|does|did) (?:it|that) (?:right|correct|true|ok|okay|good|legit|safe|real)|(?:google|search(?: for)?|look up) (?:it|that|this)|that[?!.]*$|it[?!.]*$|what (?:does|did) (?:he|she|they) mean|darauf|damit|dazu|daraus|davon|dem eine|der eine|worum geht'?s|worum geht es|was meint (?:er|sie)");
/** A German "das" that ends the utterance after a participle: "wer hat mir das geschickt". */
const DAS_PARTICIPLE = /(?<![\p{L}])das(?: \p{L}+){0,2} ge\p{L}+(?:t|en)[?!.]*$/iu;
/** A transform verb with no object at all: "summarize", "proofread", "tl;dr", "fass zusammen", "reply and say thanks". */
const BARE_TRANSFORM = leading("(?:summari[sz]e|proofread|translate|tl;?dr|tldr|rephrase|reword|shorten|reply(?: and .*)?|respond(?: and .*)?|explain|fass(?:e)? zusammen|zusammenfassen|übersetz(?:e|en)?|korrigier(?:e|en)?|antworte?(?: und .*)?|erklär(?:e)?)[?!.]*$");
/** Pure UI verbs (operate the window). Media/system/messaging verbs ("play", "turn on", "send a message") are not. */
const UI_VERB = leading("click|double[- ]click|right[- ]click|tap|press|scroll|type|fill(?: in| out)?|select|check the box|uncheck|tick|drag|close|accept|decline|dismiss|go back|go to the next|open the (?:first|second|third|next|last|\\d+(?:st|nd|rd|th)) |zoom (?:in|out)|klick\\p{L}*|drück\\p{L}*|scroll\\p{L}*|tipp\\p{L}*|füll\\p{L}*|wähl\\p{L}*|schließ\\p{L}*|akzeptier\\p{L}*|lehn\\p{L}* ab|markier\\p{L}*");
const WRITE_NEW = anywhere("write (?:a|an|me a|me an)|draft (?:a|an)|compose (?:a|an)|create (?:a|an)|make (?:a|an|me a)|schreib\\p{L}* (?:eine?n?|mir eine?n?)|erstell\\p{L}* (?:eine?n?)|plane?");
const SHORT_UNCLEAR = /^(?:what'?s the|what is the|is it|how much|wann|wie viel|was ist|ist das|help|hilfe)/iu;
/** "…, das/die/der …" without an on-screen noun: a relative clause, not an article. */
const COMMA_ARTICLE = /, *(?:das|die|der) /iu;
const TLDR = /^(?:tl;?dr|tldr)$/iu;

// --- v2 additions (pre-registered: r2/context.md misses and Tom's examples; never tuned on holdout2) ---------
/** "mach das (etwas) kürzer", "kannst du es freundlicher formulieren": the DE "make it shorter". */
const DE_SOFTENERS = "(?: (?:bitte|mal|noch|etwas|ein bisschen|ein wenig|viel|deutlich))*";
const DE_COMPARATIVES = "kürzer|kuerzer|länger|laenger|knapper|einfacher|klarer|freundlicher|höflicher|hoeflicher|formeller|förmlicher|foermlicher|lockerer|verständlicher|verstaendlicher|professioneller";
/**
 * Implicit references the frozen rules missed: "stimmt das so", "does that look right", "what I wrote",
 * "the second one", "mach das kürzer". Same weight as PRONOUN_OBJ; in a follow-up they refer to the
 * answer (followupScope).
 */
const ANAPHORA = anywhere([
  `mach(?:e)?(?:'?s| es| das)${DE_SOFTENERS} (?:${DE_COMPARATIVES})`,
  `(?:es|das)${DE_SOFTENERS} (?:${DE_COMPARATIVES}) (?:machen|fassen|formulieren|schreiben)`,
  "(?:stimmt|passt) das(?: so)?(?: (?:jetzt|wirklich|auch|denn))?[?!.]*$",
  "(?:ist|wäre|waere) das (?:so )?(?:richtig|korrekt|ok|okay|gut|verständlich|verstaendlich)[?!.]*$",
  "(?:klingt|liest sich) das (?:so )?(?:gut|ok|okay|richtig|natürlich|natuerlich)[?!.]*$",
  "(?:does|do) (?:it|that|this) (?:look|sound|read) (?:right|ok|okay|good|correct|fine|natural)",
  "what (?:i|i've|i have) (?:just )?(?:wrote|written|typed|selected|highlighted|pasted)",
  "was ich (?:hier |da |gerade |eben )?(?:geschrieben|getippt|markiert|eingefügt|eingefuegt|ausgewählt|ausgewaehlt)",
  "the (?:first|second|third|fourth|fifth|last|next|previous|top|bottom|other) ones?(?: (?:here|there|above|below|on the (?:left|right)))?[?!.]*$",
  "(?:das|die|der|den|dem) (?:erste|zweite|dritte|vierte|letzte|nächste|naechste|obere|untere|andere)[nmrs]?[?!.]*$",
].join("|"));
/** Edits of what is shown (DESIGN2 §5.4 ACT_LEAD gaps) and the separable "gib … ein" (type into a field). */
const UI_EDIT = leading([
  "make (?:the|this|that|these|those|it|them|my) .{0,40}?(?:bold|italic|underlined|bigger|smaller|larger|uppercase|lowercase)",
  "(?:format|rename) (?:the|this|that|these|those|it|them)",
  "change (?:the|this|that|these|those|it|them) .{0,40}?to",
  "mach\\p{L}* (?:den|die|das|diese[nmrs]?) .{0,40}?(?:fett|kursiv|größer|groesser|kleiner)",
  // "ein" closes the clause, as in heuristics.ts ACT_LEAD: "gib die Nummer ein und drück Enter", not "gib mir ein Rezept".
  "formatier\\p{L}*|benenn\\p{L}* .{1,40}? um|gib .{1,60}? ein(?=[?!.]*$|,(?! ?zwei)| und | dann )",
].join("|"));

/** Reasons that point at the screen itself (not at an antecedent a thread's answer could supply). */
/**
 * What may widen a GENERAL thread to the window. "definite-noun" alone does not: in a general thread
 * "make the email more formal" or "fix the bug" usually refer to what the agent itself just wrote.
 */
const SCREEN_ANCHORED: ReadonlySet<string> = new Set(["deixis-strong", "act-in-app", "ui-verb"]);

/**
 * Score one utterance: `window` is the probability that it refers to the active window (window band
 * ≥ 0.7, general ≤ 0.2: scopeBand), `reasons` are content-free codes for logs and labels.
 * `ctx` is the routing context when known; /instant has none (the host keeps the pin).
 */
export function contextScope(text: string, ctx: ClassifyContext = {}): InstantScope {
  const c = classifyUtterance(text, ctx);
  const normalized = boundedUtterance(text);
  const s = normalized.replace(FILLERS, "");
  const words = s.split(" ").filter(Boolean).length;
  const base = screenEvidence(normalized, c.intent);
  const reasons: string[] = base.reason ? [base.reason] : [];
  let p = c.needsScreen; // 0.9 strong deixis, 0.8 act_in_app, 0.6 weak/definite, 0.1 none
  const inline = INLINE.test(text.slice(0, 4_000));
  const definite = DEFINITE.test(s.replace(RELATIVE, ", ")) && !NOT_SCREEN.test(s) && !NAMED_SITE.test(s);
  const uiVerb = UI_VERB.test(s) || UI_EDIT.test(s);
  const pronoun = PRONOUN_OBJ.test(s) || DAS_PARTICIPLE.test(s) || ANAPHORA.test(s);

  // Lower: things that look screen-bound but are not.
  if (inline && !INLINE_ABOUT_WINDOW.test(s)) {
    p = Math.min(p, 0.1);
    reasons.push("inline-content");
  } else if (c.intent === "act_in_app" && !uiVerb && c.needsScreen < 0.9 && !definite && !pronoun) {
    p = 0.15;
    reasons.push("act-not-ui");
  } else if (p >= 0.5 && p < 0.9 && (NOT_SCREEN.test(s) || NAMED_SITE.test(s) || (!definite && COMMA_ARTICLE.test(s)))) {
    p = 0.15;
    reasons.push("not-screen-noun");
  }

  // Raise: missed screen references.
  if (!inline && p < 0.7) {
    if (uiVerb) {
      p = 0.85;
      reasons.push("ui-verb");
    } else if (BARE_TRANSFORM.test(s) || TLDR.test(s)) {
      p = 0.75;
      reasons.push("bare-transform");
    } else if (pronoun) {
      p = 0.75;
      reasons.push("pronoun");
    } else if (definite && !WRITE_NEW.test(s)) {
      p = Math.max(p, 0.7);
      if (!reasons.includes("definite-noun")) reasons.push("definite-noun");
    }
  }
  // Uncertain band: short no-noun questions that are neither clearly general nor deictic.
  if (p < 0.5 && !inline && words <= 4 && c.intent !== "open_launch" && c.intent !== "calculate" && c.intent !== "search_computer"
      && SHORT_UNCLEAR.test(s)) {
    p = 0.5;
    reasons.push("short-unclear");
  }
  // Strong deixis that only names user content ("the selection", "this image", "what is this?"): the
  // score stays, and the host lets its shelf content (if any) take the reference instead of the window.
  // Never with a UI verb ("select this text", "click this image"): operating the window needs it.
  if (base.reason === "deixis-strong" && !uiVerb && !reasons.includes("ui-verb") && !reasons.includes("act-in-app")
      && CONTENT_DEIXIS.test(normalized) && !SCREEN_DEIXIS.test(normalized)) {
    reasons.splice(reasons.indexOf("deixis-strong") + 1, 0, "deixis-content");
  }
  return { window: p, reasons: reasons.slice(0, MAX_SCOPE_REASONS) };
}

/** The default /instant scorer (contracts/context.ts ContextScorer): rules v2, no routing context. */
export const rulesContextScorer: ContextScorer = (text) => contextScope(text);

/** Fixed utterances (no user text) that run every rule and heuristic branch at least once. */
const WARM_UP: readonly (readonly [string, ClassifyContext?])[] = [
  ["please summarize this page"], ["15% of 340"], ["what is 15 times 17"], ["convert 5 km to miles"], ["$20 in euro"],
  ["find my invoice pdf"], ["list my apps"], ["open figma"], ["fix the failing unit tests in python"], ["fix this", { surface: "editor" }],
  ["click the blue button and then press ok"], ["make the first line bold"], ["ändere das"], ["mach das licht aus"],
  ["go to the pricing page", { surface: "browser" }], ["click the login button", { surface: "browser", browserCdp: true }],
  ["why is the sky blue?"], ["fix this sentence: their going to the park"], ["think hard: no, that's wrong"],
  ["ultrathink about it, it didn't work"], ["quick: ein skript, das dateien umbenennt"], ["what's the deal"], ["stimmt das so"],
  ["wer hat mir das geschickt"], ["tl;dr"], ["play some jazz"], ["the page of spiegel.de"], ["what should I cook this evening"],
  ["was ist die hauptstadt von frankreich"], ["write a haiku about autumn"], ["reply to the email from anna"], ["hmm"],
];
let warmed = false;

/**
 * Compile the rules now: V8 compiles each regex on its first use (~45 ms for all of them on an M5 Max),
 * which would otherwise land on the first keystrokes. Idempotent; once per process.
 */
export function warmContextScope(): void {
  if (warmed) return;
  warmed = true;
  for (const [text, ctx] of WARM_UP) contextScope(text, ctx);
}

/**
 * A follow-up's scope (DESIGN2 §4.2): the thread's scope, upgraded from general to window only by a
 * strong reference to the screen itself (score ≥ followupUpgrade with a screen-anchored reason; "make it
 * shorter" refers to the previous answer). Never downgraded automatically. Follow-ups are not classified
 * on their own words: "and now in German" means whatever the thread was about.
 */
export function followupScope(thread: ContextScope, scope: InstantScope | null | undefined): ContextScope {
  if (thread === "window" || !scope) return thread;
  const anchored = scope.reasons.some((reason) => SCREEN_ANCHORED.has(reason));
  return anchored && scope.window >= SCOPE_THRESHOLDS.followupUpgrade ? "window" : "general";
}
