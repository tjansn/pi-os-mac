import { separators } from "./format.js";
import { applyDigitScales, deWordsToDigits, deWordToNumber, DE_EN_COLLISIONS, enWordsToDigits } from "./numberWords.js";

/**
 * Instant-lane text normalization (EN + DE), shared by typed input and speech
 * transcripts. Pure and allocation-light: it runs on every keystroke.
 *
 *   raw      as received (never logged)
 *   text     cleaned: wake word, politeness and trailing punctuation removed
 *   lower    text lowercased (used for phrase grammar, names and queries)
 *   numeric  lower with spoken numbers as digits and decimal separators fixed
 */

export type Lang = "en" | "de";

export interface Normalized {
  raw: string;
  text: string;
  lower: string;
  numeric: string;
  lang: Lang;
}

const DE_MARKERS = new Set([
  "wie", "was", "ist", "sind", "von", "vom", "öffne", "oeffne", "starte", "such", "suche", "finde", "nach", "meinem", "meine", "meiner",
  "uhr", "spät", "spaet", "tage", "bis", "prozent", "mal", "geteilt", "durch", "hoch", "lautstärke", "lautstaerke", "bildschirm",
  "dunkelmodus", "papierkorb", "lösche", "loesche", "rechnung", "wechsle", "zeig", "zeige", "meilen", "wurzel", "rechne", "berechne",
  "ergibt", "macht", "viel", "viele", "der", "die", "das", "den", "dem", "und", "im", "zum", "zur", "auf", "aus", "wochentag", "heute",
  "gestern", "woche", "wochen", "monat", "jahr", "leiser", "lauter", "stumm", "ton", "weihnachten", "silvester", "neujahr", "ostern",
  "komma", "quadrat", "fakultät", "geh", "gehe", "ruf", "zeitunterschied", "uhrzeit", "datum", "welcher", "welche", "schalte", "mach",
  "noch", "gerade", "jetzt", "ich", "mir", "mich", "nicht", "ein", "eine", "einen", "kilometer", "stunden", "minuten", "sekunden",
  "diese", "dieser", "dieses", "diesen", "zusammen", "fasse", "bitte", "mein", "dein", "für", "mit", "über", "wo", "welches",
]);
const EN_MARKERS = new Set([
  "what", "whats", "what's", "how", "much", "many", "is", "are", "of", "the", "my", "for", "from", "to", "into", "times", "divided",
  "by", "percent", "power", "squared", "root", "point", "and", "open", "launch", "switch", "find", "search", "where", "show", "time",
  "days", "until", "till", "set", "volume", "turn", "mute", "sleep", "display", "convert", "calculate", "compute", "today", "week",
  "weeks", "tomorrow", "louder", "quieter", "go", "please", "me", "it", "a", "an", "miles", "hours", "minutes", "seconds",
]);

function words(lower: string): string[] {
  return lower.split(/[^a-zäöüß']+/).filter(Boolean);
}

/** Keyword vote, tie → host locale hint, else English. */
export function detectLang(lower: string, localeHint?: string): Lang {
  let de = 0;
  let en = 0;
  for (const word of words(lower)) {
    if (DE_MARKERS.has(word)) de++;
    else if (EN_MARKERS.has(word)) en++;
    else if (!DE_EN_COLLISIONS.has(word) && deWordToNumber(word) !== null) de++;
  }
  if (de !== en) return de > en ? "de" : "en";
  return localeHint?.toLowerCase().startsWith("de") ? "de" : "en";
}

/** Decimal convention of the input: "comma" (1.000,5) or "point" (1,000.5). */
export type DecimalConvention = "comma" | "point";

/**
 * The convention an utterance is parsed with: comma-decimal when the request's format
 * locale uses a decimal comma ("de-DE", "en-DE" from an rg override) or the utterance is
 * German; otherwise point-decimal.
 */
export function decimalConvention(lang: Lang, localeHint?: string): DecimalConvention {
  if (lang === "de") return "comma";
  return localeHint && separators(localeHint).decimal === "," ? "comma" : "point";
}

/**
 * Decimal/thousands separators by convention ("de" = comma, "en" = point). Comma: "1.000" → 1000,
 * "1,5" → 1.5. Point: "1,000" → 1000. The calculator always receives "." decimals.
 */
export function fixDecimalSeparators(text: string, convention: Lang | DecimalConvention): string {
  if (convention === "de" || convention === "comma") {
    return text
      .replace(/\b\d{1,3}(?:\.\d{3})+(?![\d.])/g, (group) => group.replace(/\./g, ""))
      .replace(/(\d),(\d)/g, "$1.$2");
  }
  return text.replace(/\b\d{1,3}(?:,\d{3})+(?![\d,])/g, (group) => group.replace(/,/g, ""));
}

const WAKE = /^(?:(?:hey|ok|okay|hi|hallo) (?:pi|π)[,:]?|(?:pi|π)[,:])\s+/i;
const POLITE_PREFIX = /^(?:(?:please|bitte|can you|could you|would you|will you|kannst du|könntest du|koenntest du|würdest du|wuerdest du)(?: please| bitte| mal)?,?\s+)+/i;
const POLITE_SUFFIX = /(?:,?\s+(?:please|bitte)|,\s*(?:thanks|thank you|danke))+$/i;

/** Wake word, politeness, trailing punctuation; keeps a factorial "5!". */
export function cleanUtterance(raw: string): string {
  let text = raw.normalize("NFC").replace(/[“”„«»]/g, "\"").replace(/[‘’‚]/g, "'").replace(/\s+/g, " ").trim();
  text = text.replace(WAKE, "");
  for (let i = 0; i < 2; i++) {
    text = text.replace(/[?.,;:]+$/, "").replace(/(?<![\d)])!+$/, "").trim();
    text = text.replace(POLITE_PREFIX, "").replace(POLITE_SUFFIX, "").trim();
  }
  return text.replace(/^=\s*/, "");
}

export function normalize(raw: string, localeHint?: string): Normalized {
  const text = cleanUtterance(raw);
  const lower = text.toLowerCase();
  const lang = detectLang(lower, localeHint);
  // Both converters always run: transcripts mix languages ("hundert dollar in euro").
  // German words that collide with English convert only in German utterances.
  let numeric = fixDecimalSeparators(lower, decimalConvention(lang, localeHint));
  numeric = enWordsToDigits(numeric);
  numeric = deWordsToDigits(numeric, lang === "de" ? new Set() : DE_EN_COLLISIONS);
  numeric = applyDigitScales(numeric);
  return { raw, text, lower, numeric, lang };
}

// ---------------------------------------------------------------- spoken command core

/** Discourse fillers a recognizer keeps at the start ("Okay, open Pages", "Äh, öffne Pages", "Hey, …"). */
const FILLER_LEAD = /^(?:(?:okay|ok|alright|all right|um+|uh+|uhm+|erm|hm+|so|now|well|yeah|yes|right|hey|hi|hello|hallo|äh+m?|ähm|eh|also|ja|na|nun|jetzt|und|and|then|dann)\b[,.!]?\s+)+/;
/** Request wrappers before the verb ("can you", "I want to", "kannst du", "ich möchte"). */
const REQUEST_LEAD = new RegExp(
  "^(?:(?:please|bitte|just|quickly|kindly|go ahead and|can you|could you|would you mind|would you|will you|can u|do you mind|"
    + "i want to|i wanna|i'd like to|i would like to|i need to|i need you to|let's|lets|let me|you can|"
    + "kannst du|könntest du|koenntest du|würdest du|wuerdest du|kannste|ich will|ich möchte|ich moechte|ich würde gerne?|"
    + "ich wuerde gerne?|ich muss|schnell|mal|doch|kurz|einfach)\\b,?\\s+)+",
);
/** Trailing politeness and softeners ("… for me", "… bitte", "… a bit", "… jetzt"). */
const TAIL_WRAP = /(?:[,\s]+(?:please|bitte|for me|für mich|fuer mich|now|right now|jetzt|mal|thanks|thank you|danke|real quick|quickly|again|nochmal|noch mal|schnell|a bit|a little|a little bit|ein bisschen|etwas))+$/;
const GERUND = /^(?:mind |minding )?(opening|launching|starting|running|switching to|pulling up|bringing up)\b/;
const GERUND_BASE: Readonly<Record<string, string>> = {
  opening: "open", launching: "launch", starting: "start", running: "run", "switching to": "switch to", "pulling up": "pull up", "bringing up": "bring up",
};
/** German modal particles between the verb and its object ("öffne mir bitte mal Pages" → "öffne Pages"). */
const DE_PARTICLES = /^(öffne|oeffne|starte|start|mach|mache|hol|hole|zeig|zeige|ruf|rufe|geh|gehe|wechsel|wechsle|open|launch)((?:\s+(?:mir|mal|bitte|doch|kurz|schnell|einfach|eben|jetzt|uns|gleich))+)\s+/;
/**
 * ASR punctuation inside a command ("Open, Pages."). A comma between digits is a decimal or group separator
 * and stays; so do a URL's "://", a port or clock colon ("example.com:8080", "10:30") and a "?" inside a URL.
 */
const INNER_PUNCTUATION = /[;!…]+|:(?!\/\/|\d)|\?(?!\w)|(?<!\d),|,(?!\d)/g;

/**
 * The command core of a spoken request (DESIGN4 §5.1): up to three rounds of leading fillers, request
 * wrappers and trailing politeness; ASR commas inside the command ("Open, Pages"); gerunds ("would you
 * mind opening Pages" → "open pages"); stutters ("open open Pages") and doubled takes ("open pages open
 * pages"); German particles after the verb. Input and output are `Normalized.lower`-style text. The voice
 * grammar parses the raw text first and the core second; policy checks run on both.
 */
export function spokenCore(lower: string): string {
  let text = lower.replace(INNER_PUNCTUATION, " ").replace(/\s+-\s+/g, " ").replace(/\s+/g, " ").trim();
  for (let round = 0; round < 3; round++) {
    const before = text;
    text = text.replace(FILLER_LEAD, "").replace(REQUEST_LEAD, "").replace(TAIL_WRAP, "").trim();
    text = text.replace(GERUND, (_match, verb: string) => GERUND_BASE[verb] ?? verb);
    if (text === before) break;
  }
  text = text.replace(/^(\S+)(?:\s+\1\b)+/, "$1");
  const words = text.split(" ");
  if (words.length >= 4 && words.length % 2 === 0) {
    const half = words.length / 2;
    const first = words.slice(0, half).join(" ");
    if (first === words.slice(half).join(" ")) text = first;
  }
  return text.replace(DE_PARTICLES, "$1 ").trim();
}

// ---------------------------------------------------------------- spoken math → fend syntax

const CALC_PREFIX = new RegExp(
  "^(?:what'?s|whats|what is|what are|calculate|compute|evaluate|solve|how much is|how much are|" +
    "wie ?viel (?:ist|sind|macht|ergibt|gibt)|was (?:ist|sind|ergibt|ergeben|macht|gibt)|rechne(?: aus)?|berechne)\\s+",
);

export function stripCalcPrefix(text: string): string {
  return text.replace(CALC_PREFIX, "");
}

const OPERAND = String.raw`(\d+(?:\.\d+)?|\([^()]*\))`;
type Rewrite = readonly [RegExp, string | ((...groups: string[]) => string)];

const OPERATOR_REWRITES: readonly Rewrite[] = [
  [new RegExp(String.raw`\b(?:the )?(?:square root|sqrt) of\s+${OPERAND}`, "g"), "sqrt($1)"],
  [new RegExp(String.raw`\b(?:die )?(?:quadrat)?wurzel (?:aus|von)\s+${OPERAND}`, "g"), "sqrt($1)"],
  [new RegExp(String.raw`\b(?:the )?cube root of\s+${OPERAND}`, "g"), "cbrt($1)"],
  [new RegExp(String.raw`\b(?:die )?(?:kubikwurzel|dritte wurzel) (?:aus|von)\s+${OPERAND}`, "g"), "cbrt($1)"],
  [new RegExp(String.raw`√\s*${OPERAND}`, "g"), "sqrt($1)"],
  [new RegExp(String.raw`∛\s*${OPERAND}`, "g"), "cbrt($1)"],
  [/\bto the (\d+)(?:st|nd|rd|th)(?: power)?\b/g, "^$1"],
  [/\b(?:raised )?to the power(?: of)?\b|\bto the\b(?= \d)|\bhoch\b|\bpower\b|\*\*/g, "^"],
  [/\bsquared\b|\bzum quadrat\b|\bim quadrat\b|\bquadrat\b/g, "^2"],
  [/\bcubed\b/g, "^3"],
  [/\b(?:multiplied by|times|mal)\b/g, "*"],
  // "12 x 12" → "12*12", but never the "0x" of a hex literal.
  [/(\d+(?:\.\d+)?)(\s*)x\s*(?=\d)/g, (m: string, num: string, gap: string) => (num === "0" && !gap ? m : `${num}*`)],
  [/[×·]/g, "*"],
  [/\b(?:divided by|geteilt durch|dividiert durch|durch|over)\b/g, "/"],
  [/÷/g, "/"],
  [/\bplus\b/g, "+"],
  [/\bminus\b|−/g, "-"],
  [/\s*\b(?:per ?cent|percent|prozent)\b/g, "%"],
  [/(\d)\s+%/g, "$1%"],
  [/%\s+(?:of|von|vom)\b/g, "% of"],
  [/\b(\d+) (?:factorial|fakultät)\b/g, "$1!"],
];

/** Raycast percent semantics, applied to the whole expression only. */
const PERCENT_REWRITES: readonly Rewrite[] = [
  [/^(\d+(?:\.\d+)?)% (?:off|discount on|rabatt auf|nachlass auf|rabatt von) (\d+(?:\.\d+)?)$/i, "$2*(1-$1/100)"],
  [/^(\d+(?:\.\d+)?)% (?:tip on|tip for|trinkgeld auf|trinkgeld für|trinkgeld von) (\d+(?:\.\d+)?)$/i, "$2*$1/100"],
  [/^(.*[\d)!])\s*([+-])\s*(\d+(?:\.\d+)?)%$/, (_m, left: string, op: string, pct: string) => `(${left.trim()})*(1${op}${pct}/100)`],
];

/**
 * "20% off 80" → 80*(1-20/100), "15% tip on 42" → 42*15/100, "80 + 15%" →
 * (80)*(1+15/100), and any other bare "N%" → (N/100); "X% of Y" stays native
 * fend. Also maps ×, ÷, − and ** for typed or model-written expressions.
 */
export function applyPercentSemantics(expression: string): string {
  let out = expression.replace(/[×·]/g, "*").replace(/÷/g, "/").replace(/−/g, "-").replace(/\*\*/g, "^").replace(/(\d)\s+%/g, "$1%").trim();
  out = applyRewrites(out, PERCENT_REWRITES);
  return out.replace(/(\d+(?:\.\d+)?)%(?!\s*of\b)/gi, "($1/100)").replace(/\s+/g, " ").trim();
}

export interface MathText {
  /** fend syntax. */
  expression: string;
  /** Human form for subtitles ("15% of 340", "(3 + 4) × 12 ÷ 2"). */
  display: string;
}

function applyRewrites(text: string, rewrites: readonly Rewrite[]): string {
  let out = text;
  for (const [pattern, replacement] of rewrites) {
    out = typeof replacement === "string" ? out.replace(pattern, replacement) : out.replace(pattern, replacement as (...args: string[]) => string);
  }
  return out;
}

function prettyMath(expression: string): string {
  return expression
    .replace(/\bsqrt\((\d+(?:\.\d+)?)\)/g, "√$1")
    .replace(/\bcbrt\((\d+(?:\.\d+)?)\)/g, "∛$1")
    .replace(/\s*\^\s*/g, "^")
    .replace(/(?<=[\d)%!])\s*([+\-*/])\s*(?=[\d(a-z√-])/g, " $1 ")
    .replace(/\*/g, "×")
    .replace(/(?<= )\/(?= )/g, "÷")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Spoken EN/DE operators → fend syntax ("fifteen percent of three hundred and
 * forty" arrives as "15 percent of 340" and becomes "15% of 340"). Input is a
 * Normalized.numeric string. The caller decides whether the result is math.
 */
export function canonicalMath(numeric: string): MathText {
  let text = stripCalcPrefix(numeric).replace(/\s*(?:=|equals|ergibt)\s*$/, "");
  text = applyRewrites(text, OPERATOR_REWRITES).replace(/\s+/g, " ").trim();
  return { expression: applyPercentSemantics(text), display: prettyMath(text) };
}

// ---------------------------------------------------------------- spoken URLs

/**
 * "github dot com" → "github.com", "spiegel punkt de" → "spiegel.de",
 * "example dot com slash docs" → "example.com/docs". After jev-voice-browser
 * `normalizeSpokenUrl` (MIT), extended for German.
 */
export function normalizeSpokenUrl(text: string): string {
  return text
    .toLowerCase()
    .replace(/\bh\s*t\s*t\s*p\s*(s?)\s*(?::|colon|doppelpunkt)\s*(?:\/\s*\/|(?:slash|schrägstrich)\s+(?:slash|schrägstrich))\s*/g, (_m, s: string) => (s ? "https://" : "http://"))
    .replace(/\bw\s*w\s*w\b\s*(?:dot|punkt|\.)?\s*/g, "www.")
    .replace(/\s+(?:dot|punkt)\s+/g, ".")
    .replace(/\s*\.\s*/g, ".")
    .replace(/\s+(?:slash|schrägstrich)\s*/g, "/")
    .replace(/\s+(?:dash|hyphen|bindestrich)\s+/g, "-")
    .trim();
}
