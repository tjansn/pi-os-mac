import type { AgentIntent, Classification, SurfaceClass } from "./types.js";

/**
 * Deterministic EN/DE utterance classifier (routing.md §6.4). Always available,
 * sub-millisecond, no I/O. Its output only steers model choice; it never
 * authorizes anything (native policy stays authoritative).
 *
 * Privacy: callers pass the utterance in and get labels out. Nothing here
 * logs, stores or echoes the text.
 */

// Unicode-aware word boundaries (\b is ASCII-only and breaks on umlauts).
const B = "(?<![\\p{L}\\p{N}_])";
const E = "(?![\\p{L}\\p{N}_])";
/** Fillers before the actual request ("please", "kannst du", "quick question:"). */
const FILLERS = "please|pls|hey|ok(?:ay)?|so|now|quick(?: question)?|bitte|jetzt|dann|nun|schnell|kurze frage|can you|could you|would you|will you|kannst du|könntest du|koenntest du|würdest du|wuerdest du|mal";

/** Whole-word match anywhere. */
const anywhere = (alternatives: string) => new RegExp(`${B}(?:${alternatives})${E}`, "iu");
/** Imperative/question word at the start (fillers and style prefixes are stripped first). */
const leading = (alternatives: string) => new RegExp(`^(?:${alternatives})${E}`, "iu");

// --- calculate -------------------------------------------------------------
const ARITHMETIC_ONLY = /^[\d\s.,+\-*/^()%×÷=x]+$/u;
const OPERATOR = /[+\-*/^×÷%]|\d\s*x\s*\d/u;
const DIGIT = /\d/u;
const PERCENT_OF = new RegExp(`\\d+(?:[.,]\\d+)?\\s*(?:%|percent|per cent|prozent)\\s+(?:of|von)${E}`, "iu");
const MATH_WORDS = anywhere("plus|minus|times|multiplied by|divided by|squared|cubed|to the power of|sqrt|square root|mal|geteilt durch|hoch|wurzel(?: aus)?|percent|prozent");
const CALC_LEAD = leading("what(?:'s| is)|whats|calculate|compute|how much is|was (?:ist|sind|ergibt|macht)|wie ?viel (?:ist|sind|ergibt|macht)|rechne|berechne");
const UNITS = "km|kilometers?|kilometres?|mi|miles?|m|meters?|metres?|cm|mm|ft|feet|foot|inch(?:es)?|yards?|kg|kilos?|kilograms?|g|grams?|lbs?|pounds?|oz|ounces?|°\\s?[cf]|degrees?|celsius|fahrenheit|grad|l|liters?|litres?|ml|gal(?:lons?)?|cups?|usd|eur|euros?|chf|gbp|jpy|dollars?|franken|pfund|mph|km/h|kmh|kb|mb|gb|tb|bytes?|hours?|minutes?|seconds?|stunden?|minuten?|sekunden?|days?|tage?|weeks?|wochen?";
const UNIT_CONVERSION = new RegExp(`(?:[$€£¥]\\s*\\d+(?:[.,]\\d+)?|\\d+(?:[.,]\\d+)?\\s*(?:${UNITS}|[$€£¥]))\\s+(?:in|to|into|nach|zu|as|als)${E}`, "iu");
const CONVERT_LEAD = leading("convert|umrechnen|rechne|wandle?|konvertier\\p{L}*");

// --- search / open ---------------------------------------------------------
const SEARCH_LEAD = leading("find|search(?: for)?|look for|locate|where(?:'s| is| are)|show me|list|finde?|such(?:e)?|wo (?:ist|sind|liegt|liegen)|zeig(?:e)? mir");
const DOC_OBJECTS = anywhere("files?|documents?|docs?|pdfs?|folders?|directories?|photos?|pictures?|images?|screenshots?|downloads?|presentations?|spreadsheets?|notes?|e-?mails?|mails?|attachments?|invoices?|receipts?|contracts?|dateien?|dokumente?|ordner|verzeichnis(?:se)?|fotos?|bilder?|bildschirmfotos?|anhänge?|anhaenge?|präsentation(?:en)?|praesentation(?:en)?|tabellen?|notizen?|rechnung(?:en)?|quittung(?:en)?|verträge?|vertraege?|vertrag|\\.?(?:pdf|docx?|xlsx?|pptx?|key|pages|numbers|png|jpe?g|heic|mov|mp4|zip|csv|txt|md)");
const APP_OBJECTS = anywhere("apps?|applications?|programme?");
const OPEN_LEAD = leading("open|launch|start|switch to|bring up|öffne|oeffne|starte|wechsel(?:e)? zu|mach(?:e)? .{1,40}? auf");

// --- code / write / act / browse -------------------------------------------
const NOT_CODE = anywhere("zip code|postal code|post code|area code|country code|promo code|discount code|voucher code|coupon code|qr code|dress code|postleitzahl|gutscheincode|rabattcode");
const CODE_WORDS = anywhere("code|coding|source code|function|regex(?:p)?|regular expression|stack ?trace|traceback|compiler|compil(?:e|es|ed|ing)|unit tests?|failing tests?|git|github|gitlab|git commit|commit message|pull request|merge conflict|rebase|npm|yarn|pnpm|pip install|cargo|docker|dockerfile|kubernetes|kubectl|typescript|javascript|kotlin|golang|c\\+\\+|sql|json|yaml|html|css|api|endpoint|repo|repository|segfault|syntax error|linter|debug(?:ging)?|refactor(?:ing)?|bugs?|shell script|bash script|python script|applescript|quellcode|programmier\\p{L}*|kompilier\\p{L}*");
/** Language names are ordinary words too ("Taylor Swift", "rust stains"); count them only in a code context. */
const CODE_LANGUAGE = anywhere("in (?:python|java|swift|rust|ruby|bash|go|php|perl|lua|zsh|powershell)|(?:python|java|swift|rust|ruby|bash|php|perl|lua|zsh|powershell) (?:code|script|program|function|error|library|package|syntax|class|module|app|project|file)");
const CODE_SURFACE_LEAD = leading("fix|add|refactor|rename|implement|run|build|test|debug|explain|create|make|change|update|install|deploy|behebe?|füge?|fuege?|implementier\\p{L}*|teste?|erstell\\p{L}*|änder\\p{L}*|aender\\p{L}*|bau(?:e)?");
const WRITE = anywhere("rewrite|re-write|rephrase|reword|paraphrase|summari[sz]e|summary of|translate|translation|reply|respond to|draft|compose|write|proofread|polish|shorten|make (?:it|this|that) (?:shorter|longer|more formal|more casual|friendlier|nicer|clearer)|fix (?:the |my )?(?:grammar|spelling|typos?|wording)|schreib\\p{L}*|formulier\\p{L}*|umformulier\\p{L}*|übersetz\\p{L}*|uebersetz\\p{L}*|zusammenfass\\p{L}*|fass\\p{L}* .{0,40}?zusammen|antworte?|beantworte?|korrigier\\p{L}*|kürz\\p{L}*|kuerz\\p{L}*|entwirf|entwurf|verfass\\p{L}*");
const ACT_LEAD = leading("click|double[- ]click|right[- ]click|tap|press|hit|type|enter|fill(?: in| out)?|scroll|select|choose|pick|check(?: the)? (?:box|checkbox)|uncheck|tick|untick|toggle|enable|disable|turn (?:on|off)|drag|drop|close|minimi[sz]e|maximi[sz]e|resize|move|send|post|share|save|like|follow|unfollow|subscribe|mute|unmute|play|pause|add|insert|paste|copy|highlight|zoom (?:in|out)|go back|undo|redo|accept|decline|dismiss|klick\\p{L}*|drück\\p{L}*|drueck\\p{L}*|tipp\\p{L}*|gib .{1,40}? ein(?=[?!.]*$|,(?! ?zwei)| und | dann )|füll\\p{L}*|fuell\\p{L}*|scroll\\p{L}*|wähl\\p{L}*|waehl\\p{L}*|markier\\p{L}*|aktivier\\p{L}*|deaktivier\\p{L}*|schalt\\p{L}*|schließ\\p{L}*|schliess\\p{L}*|sende|schick\\p{L}*|speicher\\p{L}*|teile|füge?|fuege?|kopier\\p{L}*|spiel\\p{L}* .{1,40}? ab|pausier\\p{L}*|akzeptier\\p{L}*|bestätig\\p{L}*|bestaetig\\p{L}*|lehn\\p{L}* .{1,40}? ab");
/**
 * Edits of what is shown that ACT_LEAD misses ("make the first line bold", "format the table", "rename this",
 * "set my status to away", "change the title to …"). Checked after the editor/terminal code rule, where
 * "rename …" is a refactoring.
 */
const ACT_EDIT_LEAD = leading([
  // A determiner: "make the heading bigger", never "make a bigger plan" (no screenshot for that on legacy hosts).
  "make (?:the|this|that|these|those|it|them|my) .{0,40}?(?:bold|italic|underlined|bigger|smaller|larger|uppercase|lowercase)",
  "(?:format|rename) (?:the|this|that|these|those|it|them|my)",
  "(?:set|change) (?:the|this|that|these|those|it|them|my) .{0,40}?(?:to|as)",
  "formatier\\p{L}*|benenn\\p{L}* .{1,40}? um|mach\\p{L}* .{1,40}? (?:fett|kursiv|größer|groesser|kleiner)",
].join("|"));
const DEICTIC_EDIT_LEAD = leading("do|fix|change|edit|update|correct|mach(?:e)?|ändere?|aendere?|bearbeite?|korrigiere?");
const WEB = anywhere("go to|navigate(?: to)?|visit|website|web ?page|web site|webseite|site|page|tab|tabs|link|url|book|order|buy|purchase|checkout|check out|add to cart|log ?in|sign ?in|sign up|search (?:for|on|the web)|google|geh(?:e)? (?:auf|zu)|seite|bestell\\p{L}*|buch\\p{L}*|kauf\\p{L}*|anmeld\\p{L}*|einloggen|warenkorb");

// --- answer ----------------------------------------------------------------
const QUESTION_LEAD = leading("what|what's|whats|why|how|who|whom|whose|when|where|which|is|are|was|were|does|do|did|can|could|should|would|will|explain|tell me|define|describe|meaning of|warum|wieso|weshalb|wie|wer|wem|wen|wessen|wann|wo|woher|wohin|welche\\p{L}*|ist|sind|war|hat|haben|kann|können|koennen|soll|sollte|erklär\\p{L}*|erklaer\\p{L}*|beschreib\\p{L}*|definier\\p{L}*|sag mir|bedeutet|weißt du|weisst du");

// --- screen deixis ---------------------------------------------------------
const SCREEN_NOUNS = "window|page|tab|screen|button|field|form|dialog|popup|error|message|email|e-mail|mail|text|paragraph|sentence|image|picture|photo|chart|graph|diagram|table|code|file|document|line|link|video|post|tweet|list|cell|column|row|slide|menu|icon|sheet|spreadsheet|website|site|article|chat|thread|comment|screenshot";
const SCREEN_NOUNS_DE = "fenster|seite|tab|bildschirm|knopf|button|schaltfläche|schaltflaeche|feld|formular|dialog|fehler|fehlermeldung|meldung|nachricht|mail|e-mail|text|absatz|satz|bild|foto|diagramm|grafik|tabelle|code|datei|dokument|zeile|link|video|post|liste|zelle|spalte|folie|menü|menue|symbol|artikel|chat|kommentar";
/**
 * Strong deixis comes in two kinds with the same weight (STRONG_DEIXIS = SCREEN ∪ CONTENT):
 * SCREEN_DEIXIS points at the screen itself ("this page", "on my screen", "what do you see");
 * CONTENT_DEIXIS can just as well point at content the user attached ("the selection", "this image",
 * "what is this?"), so a host whose shelf holds such content lets the shelf take the reference
 * (contextScope's `deixis-content` reason). Nouns of either kind belong to exactly one list.
 */
const CONTENT_NOUNS = "text|paragraph|sentence|image|picture|photo|code|line|chart|graph|diagram|table|list";
const CONTENT_NOUNS_DE = "text|absatz|satz|bild|foto|code|zeile|diagramm|grafik|tabelle|liste";
const SCREEN_ONLY_NOUNS = SCREEN_NOUNS.split("|").filter(noun => !CONTENT_NOUNS.split("|").includes(noun)).join("|");
const SCREEN_ONLY_NOUNS_DE = SCREEN_NOUNS_DE.split("|").filter(noun => !CONTENT_NOUNS_DE.split("|").includes(noun)).join("|");
const DEMONSTRATIVE_DE = "dies|diese|dieser|dieses|diesen|diesem";
const SCREEN_DEIXIS_ALTERNATIVES = [
  `on (?:the |my |this )?screen`, `(?:this|that|these|those) (?:${SCREEN_ONLY_NOUNS})s?`,
  `look at (?:this|that|it|the screen)`, `see (?:this|that|here)`, `what do you see`, `what am i looking at`, `currently open`,
  `auf dem bildschirm`, `(?:${DEMONSTRATIVE_DE}) (?:${SCREEN_ONLY_NOUNS_DE})`, `siehst du`, `das hier`, `hier oben`, `hier unten`,
];
const CONTENT_DEIXIS_ALTERNATIVES = [
  `(?:this|that|these|those) (?:${CONTENT_NOUNS})s?`, `what(?:'s| is| are) (?:this|that|these|those)(?: here)?`,
  `(?:the )?(?:selected|highlighted)(?: \\p{L}+)?`, `selection`,
  `(?:${DEMONSTRATIVE_DE}) (?:${CONTENT_NOUNS_DE})`, `was ist (?:das|dies)(?: hier| da)?(?=[?!.]*$)`,
  `markierte\\p{L}*`, `ausgewählte\\p{L}*`, `ausgewaehlte\\p{L}*`, `auswahl`,
];
export const SCREEN_DEIXIS = anywhere(SCREEN_DEIXIS_ALTERNATIVES.join("|"));
export const CONTENT_DEIXIS = anywhere(CONTENT_DEIXIS_ALTERNATIVES.join("|"));
const STRONG_DEIXIS = anywhere([...SCREEN_DEIXIS_ALTERNATIVES, ...CONTENT_DEIXIS_ALTERNATIVES].join("|"));
const WEAK_DEIXIS = anywhere("this|these|those|here|dies|diese|dieser|dieses|diesen|diesem|hier|das da");
/**
 * A definite on-screen noun ("summarize the page", "reply to the email", "fasse die Seite
 * zusammen", "was sagt die Fehlermeldung") points at the pinned window as much as "this" does.
 */
const DEFINITE_SCREEN = anywhere([
  `the (?:${SCREEN_NOUNS})s?`,
  `(?:die|der|das|den|dem) (?:${SCREEN_NOUNS_DE})(?:n|en|s|e)?`,
].join("|"));
/**
 * German "das" as an object pronoun ("fass das zusammen", "übersetz das ins Englische", "kannst du
 * das übersetzen"), the DE counterpart of "summarize this". Only utterance-final forms count: "das"
 * as an article ("das Wetter morgen") is followed by its noun.
 */
const DAS_PARTICLES = "hier|da|mal|bitte|doch|nochmal|noch mal|kurz|schnell|zusammen|um|durch|ab|vor|ein|aus|nach";
const DAS_VERBS = "übersetzen|uebersetzen|zusammenfassen|erklären|erklaeren|korrigieren|kürzen|kuerzen|umschreiben|umformulieren|vorlesen|lesen|prüfen|pruefen|überprüfen|ueberpruefen|verbessern|beantworten|kopieren";
const DAS_PRONOUN = new RegExp(
  `${B}das(?: (?:${DAS_PARTICLES}))*(?: (?:ins|auf|in) \\p{L}+| (?:${DAS_VERBS}))?[?!.]*$`, "iu");
const NON_DEICTIC = anywhere("this (?:morning|afternoon|evening|night|week|weekend|month|year|time|quarter|summer|winter|spring|fall|autumn|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|these days|here is|here are|here's|diese(?:s|n|r)? (?:woche|monat|jahr|mal|wochenende|morgen|abend|sommer|winter|frühling|herbst)|hier ist|hier sind");

// --- depth / speed / correction -------------------------------------------
const EXPLICIT_MAX = anywhere("ultra ?think|think (?:really|very|super|extremely) hard|think as hard as (?:you )?(?:can|possible)|max(?:imum)? (?:effort|reasoning|thinking)|hardest you can|so gründlich wie möglich|so gruendlich wie moeglich|maximal gründlich|maximal gruendlich|denk (?:richtig|extrem|maximal|so) (?:gründlich |gruendlich |gut |scharf |hart )?nach");
const EXPLICIT_DEEP = anywhere("think (?:hard|harder|carefully|deeply|deep|it through|this through|long)|take your time|be (?:thorough|careful|meticulous|rigorous)|thoroughly|in depth|in-depth|deep ?dive|deep-dive|reason carefully|gründlich|gruendlich|denk (?:gut|genau|scharf|lange|tief) nach|sorgfältig|sorgfaeltig|in ruhe|nimm dir (?:zeit|ruhe)|tiefgehend|tiefgründig|tiefgruendig");
const EXPLICIT_FAST = anywhere("quick(?:ly)?|briefly|brief|in short|short answer|tl;?dr|asap|just (?:the|a) (?:quick )?(?:answer|number)|one (?:word|sentence|line)|schnell|kurz|kurze|kurzer|kurzes|knapp|auf die schnelle|in einem satz|nur kurz");
const CORRECTION_LEAD = leading("no|nope|wrong|incorrect|not (?:quite|right|that)|that'?s (?:not|wrong|incorrect)|that (?:is|was) (?:not|wrong)|try again|again|redo|do it again|still (?:wrong|not|broken)|nein|falsch|stimmt nicht|nicht richtig|nochmal|noch ?mal|versuch(?:s|e)? es (?:nochmal|noch ?mal|erneut)");
const CORRECTION_ANYWHERE = anywhere("that'?s (?:wrong|incorrect|not (?:it|right|what i))|(?:didn'?t|doesn'?t|does not|did not) work|not working|still (?:wrong|broken)|you (?:misunderstood|got it wrong)|das (?:ist|war) falsch|stimmt (?:so )?nicht|funktioniert (?:immer noch |noch )?nicht|klappt (?:immer noch |noch )?nicht|geht (?:immer noch |noch )?nicht|du hast (?:mich )?falsch verstanden");

/**
 * Leading fillers and depth/speed phrases ("please", "think hard about", "kurz:") say
 * how, not what: strip them once before intent detection (one linear pass).
 */
const STYLE = "ultra ?think|think (?:hard|harder|carefully|deeply|really hard)(?: about)?|take your time(?: and)?|briefly|quickly|in short|max(?:imum)? effort|deep ?dive(?: into)?|denk (?:gut |genau |gründlich |gruendlich |richtig |scharf )?nach|so gründlich wie möglich|gründlich|gruendlich|kurz";
const PREFIX = new RegExp(`^(?:(?:${FILLERS}|${STYLE})[,:\\s]+)+`, "iu");

// --- complexity ------------------------------------------------------------
const CONNECTIVES = /(?<![\p{L}\p{N}_])(?:and then|then|afterwards|after that|finally|und dann|dann|danach|anschließend|anschliessend|als nächstes|als naechstes|zum schluss|außerdem|ausserdem)(?![\p{L}\p{N}_])/giu;
const HARD = anywhere("plan|planning|compare|comparison|analy[sz]e|analysis|debug|investigate|research|evaluate|assess|review|audit|pros and cons|trade-?offs?|optimi[sz]e|architecture|design (?:a|an|the)|strategy|step[- ]by[- ]step|in detail|detailed|vergleich\\p{L}*|analys\\p{L}*|untersuch\\p{L}*|recherchier\\p{L}*|bewert\\p{L}*|überprüf\\p{L}*|ueberpruef\\p{L}*|vor- und nachteile|planen|plane|strategie|optimier\\p{L}*|schritt für schritt|schritt fuer schritt|ausführlich|ausfuehrlich|detailliert");
const MEDIUM = anywhere("explain|why|how does|how do|how can|how to|erklär\\p{L}*|erklaer\\p{L}*|warum|wieso|weshalb|wie funktioniert|wie kann|wie geht");

export interface ClassifyContext {
  surface?: SurfaceClass;
  browserCdp?: boolean;
}

/** Lowercase, NFC, straight apostrophes, single spaces. */
export function normalizeUtterance(text: string): string {
  return text.normalize("NFC").replace(/[’‘`´]/g, "'").replace(/\s+/g, " ").trim().toLowerCase();
}

function countWords(text: string): number {
  return text.length === 0 ? 0 : text.split(" ").filter(Boolean).length;
}

// --- spoken requests -------------------------------------------------------
/** The `other` label's confidence: no rule placed the utterance. */
export const UNPLACED_CONFIDENCE = 0.3;
/**
 * A spoken request of at most this many words that no rule places is most likely misheard
 * (DESIGN4 §4.5: the same bound as the instant lane's check gate).
 */
export const SHORT_SPOKEN_WORDS = 8;

/** Words in an utterance as the classifier counts them (boundedUtterance, split on spaces). */
export function utteranceWords(text: string): number {
  return countWords(boundedUtterance(text));
}

/**
 * A short utterance no rule could place: intent `other` at ≤ UNPLACED_CONFIDENCE and 1..8 words. For
 * speech this is the garbled-transcript case ("Oh, then kind order."): decide() routes it to the quick
 * lane with the option tools, and the spoken-input note asks for concrete choices, never an open
 * question (DESIGN4 §5.5). A confident advisory hint that adopted a label (fusion.ts) places it.
 */
export function isUnclearShortUtterance(words: number, c: Pick<Classification, "intent" | "intentConfidence">): boolean {
  return c.intent === "other" && c.intentConfidence <= UNPLACED_CONFIDENCE && words >= 1 && words <= SHORT_SPOKEN_WORDS;
}

function intentOf(text: string, words: number, ctx: ClassifyContext): { intent: AgentIntent; confidence: number } {
  const strip = text.replace(/[?!.]+$/u, "");
  const hasDigit = DIGIT.test(strip);
  if ((ARITHMETIC_ONLY.test(strip) && hasDigit && OPERATOR.test(strip)) || PERCENT_OF.test(strip)
      || UNIT_CONVERSION.test(strip)
      || (CALC_LEAD.test(strip) && hasDigit && (OPERATOR.test(strip) || MATH_WORDS.test(strip)))
      || (CONVERT_LEAD.test(strip) && hasDigit)) {
    return { intent: "calculate", confidence: 0.95 };
  }
  const docObject = DOC_OBJECTS.test(strip);
  if (SEARCH_LEAD.test(strip) && (docObject || APP_OBJECTS.test(strip))) return { intent: "search_computer", confidence: 0.85 };
  if (OPEN_LEAD.test(strip)) {
    if (docObject && words > 3) return { intent: "search_computer", confidence: 0.75 }; // find, then open
    if (words <= 6) return { intent: "open_launch", confidence: 0.85 };
  }
  const code = (CODE_WORDS.test(strip) || CODE_LANGUAGE.test(strip)) && !NOT_CODE.test(strip);
  if (code) return { intent: "code", confidence: 0.8 };
  if (WRITE.test(strip)) return { intent: "write", confidence: 0.8 };
  const browser = ctx.surface === "browser" || ctx.browserCdp === true;
  // A CDP-pinned browser is driven by DOM snapshots, not pixels.
  const act = (confidence: number) => ctx.browserCdp
    ? { intent: "browse_web" as const, confidence } : { intent: "act_in_app" as const, confidence };
  if (ACT_LEAD.test(strip)) return act(0.8);
  if ((ctx.surface === "editor" || ctx.surface === "terminal") && CODE_SURFACE_LEAD.test(strip)) {
    return { intent: "code", confidence: 0.6 };
  }
  if (ACT_EDIT_LEAD.test(strip)) return act(0.75);
  if (DEICTIC_EDIT_LEAD.test(strip) && (STRONG_DEIXIS.test(strip) || WEAK_DEIXIS.test(strip) || DAS_PRONOUN.test(strip))) return act(0.7);
  if (browser && WEB.test(strip)) return { intent: "browse_web", confidence: 0.75 };
  if (text.endsWith("?")) return { intent: "answer", confidence: 0.75 };
  if (QUESTION_LEAD.test(strip)) return { intent: "answer", confidence: 0.65 };
  return { intent: "other", confidence: UNPLACED_CONFIDENCE };
}

function complexityOf(text: string, words: number): 0 | 1 | 2 {
  const connectives = text.match(CONNECTIVES)?.length ?? 0;
  const sentences = text.split(/[.!?]+\s+(?=\p{L})/u).length;
  if (words > 40 || connectives >= 2 || HARD.test(text)) return 2;
  if (words >= 13 || connectives >= 1 || sentences >= 2 || MEDIUM.test(text)) return 1;
  return 0;
}

/** needsScreen and why (reason codes from contracts/context.ts KNOWN_SCOPE_REASONS; none at 0.1). */
export interface ScreenEvidence {
  p: number;
  reason?: "deixis-strong" | "act-in-app" | "deixis-weak" | "definite-noun";
}

/** needsScreen with its cause, over boundedUtterance() text (contextScope.ts reports the cause). */
export function screenEvidence(text: string, intent: AgentIntent): ScreenEvidence {
  if (STRONG_DEIXIS.test(text)) return { p: 0.9, reason: "deixis-strong" };
  if (intent === "act_in_app") return { p: 0.8, reason: "act-in-app" };
  const cleaned = text.replace(NON_DEICTIC, " ");
  if (WEAK_DEIXIS.test(cleaned) || DAS_PRONOUN.test(cleaned)) return { p: 0.6, reason: "deixis-weak" };
  if (DEFINITE_SCREEN.test(cleaned)) return { p: 0.6, reason: "definite-noun" };
  return { p: 0.1 };
}

function correctionOf(text: string): number {
  if (CORRECTION_LEAD.test(text)) return 0.9;
  if (CORRECTION_ANYWHERE.test(text)) return 0.7;
  return 0;
}

/** normalizeUtterance over a bounded input: requests beyond ~170 words are complex anyway, and the bound bounds regex time. */
export function boundedUtterance(text: string): string {
  return normalizeUtterance(text.slice(0, 4_000)).slice(0, 1_000);
}

/** Classify one utterance (EN/DE). Pure; < 1 ms. */
export function classifyUtterance(text: string, ctx: ClassifyContext = {}): Classification {
  const normalized = boundedUtterance(text);
  const words = countWords(normalized);
  const subject = normalized.replace(PREFIX, "");
  const { intent, confidence } = intentOf(subject, countWords(subject), ctx);
  const explicitMax = EXPLICIT_MAX.test(normalized);
  const explicitDeep = explicitMax || EXPLICIT_DEEP.test(normalized);
  return {
    source: "heuristic",
    intent,
    intentConfidence: confidence,
    complexity: complexityOf(normalized, words),
    needsScreen: screenEvidence(normalized, intent).p,
    explicitDeep,
    explicitMax,
    explicitFast: !explicitDeep && EXPLICIT_FAST.test(normalized),
    correction: correctionOf(subject),
  };
}

const SURFACES: readonly [SurfaceClass, RegExp][] = [
  ["browser", /^(?:safari|google chrome|chrome|chromium|brave browser|brave|firefox|microsoft edge|msedge|arc|opera|vivaldi|orion|zen|zen browser|dia|duckduckgo|safari technology preview)$/i],
  ["terminal", /^(?:terminal|iterm2?|warp|ghostty|alacritty|kitty|wezterm|wezterm-gui|hyper|cmd|powershell|pwsh|conhost|windowsterminal)$/i],
  ["editor", /^(?:code|code - insiders|visual studio code|devenv|cursor|windsurf|xcode|sublime text|sublime_text|intellij idea|idea|idea64|pycharm|pycharm64|webstorm|goland|clion|rider|android studio|zed|nova|bbedit|textmate|macvim|vim|nvim|emacs|notepad\+\+)$/i],
  ["finder", /^(?:finder|explorer|path finder|forklift)$/i],
  ["mail_chat", /^(?:mail|microsoft outlook|outlook|olk|thunderbird|spark|spark desktop|airmail|mimestream|slack|discord|messages|whatsapp|telegram|signal|microsoft teams|teams|ms-teams|zoom|zoom.us|skype)$/i],
  ["office", /^(?:microsoft word|winword|word|microsoft excel|excel|microsoft powerpoint|powerpnt|powerpoint|pages|numbers|keynote|libreoffice|soffice|notion|obsidian|bear|notes|onenote|textedit|notepad)$/i],
];

/** Coarse surface class from the pinned process name (no titles or paths are used). */
export function surfaceFromProcess(processName: string | undefined, options: { finderDesktop?: boolean } = {}): SurfaceClass {
  if (options.finderDesktop) return "finder";
  const name = (processName ?? "").replace(/\.(?:exe|app)$/i, "").trim();
  if (!name) return "other";
  return SURFACES.find(([, pattern]) => pattern.test(name))?.[0] ?? "other";
}

/**
 * The request part of a pi-os prompt. agentRunner wraps the user's words in
 * "## Desktop context … ## Request <prompt>"; classifying the wrapper would
 * read window JSON as the utterance.
 */
export function extractRequestText(promptText: string): string {
  // The first marker LINE is agentRunner's (the context above it is JSON, so a title cannot form
  // one); a later "## Request" line belongs to the user's own words.
  const marker = /^## Request[ \t]*$/m.exec(promptText);
  return marker ? promptText.slice(marker.index + marker[0].length).trim() : promptText;
}
