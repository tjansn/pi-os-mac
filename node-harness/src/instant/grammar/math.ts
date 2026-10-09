import { canonicalMath, stripCalcPrefix, type Normalized } from "../normalize.js";
import type { BaseName, Parsed } from "../types.js";

/**
 * Calculator, unit, currency and base-conversion phrasing (EN + DE) → fend
 * syntax or a currency request. Every rule is anchored to the whole
 * utterance; anything left over means "not math".
 */

/** Spoken/typed unit names → fend unit tokens. "pounds" is mass (lb); £/GBP is currency. */
export const UNIT_WORDS: Readonly<Record<string, string>> = (() => {
  const table: Record<string, string> = {};
  const add = (unit: string, names: string[]): void => {
    for (const name of names) table[name] = unit;
  };
  add("mm", ["mm", "millimeter", "millimeters", "millimetre", "millimetres", "millimetern"]);
  add("cm", ["cm", "centimeter", "centimeters", "centimetre", "centimetres", "zentimeter", "zentimetern"]);
  add("m", ["m", "meter", "meters", "metre", "metres", "metern"]);
  add("km", ["km", "kilometer", "kilometers", "kilometre", "kilometres", "kilometern"]);
  add("inches", ["inch", "inches", "zoll", "\""]);
  add("ft", ["ft", "foot", "feet", "fuß", "fuss"]);
  add("yards", ["yd", "yds", "yard", "yards"]);
  add("miles", ["mi", "mile", "miles", "meile", "meilen"]);
  add("nmi", ["nmi", "nautical mile", "nautical miles", "seemeile", "seemeilen"]);
  add("mg", ["mg", "milligram", "milligrams", "milligramm"]);
  add("g", ["g", "gram", "grams", "gramm", "grammes"]);
  add("kg", ["kg", "kilo", "kilos", "kilogram", "kilograms", "kilogramm", "kilogramme"]);
  add("tonne", ["tonne", "tonnes", "tonnen", "metric ton", "metric tons"]);
  add("lb", ["lb", "lbs", "pound", "pounds", "pfund"]);
  add("oz", ["oz", "ounce", "ounces", "unze", "unzen"]);
  add("stone", ["stone", "stones"]);
  add("°C", ["c", "°c", "celsius", "degrees celsius", "degree celsius", "grad celsius", "grad"]);
  add("°F", ["f", "°f", "fahrenheit", "degrees fahrenheit", "degree fahrenheit", "grad fahrenheit"]);
  add("kelvin", ["kelvin"]);
  add("ml", ["ml", "milliliter", "milliliters", "millilitre", "millilitres", "millilitern"]);
  add("l", ["l", "liter", "liters", "litre", "litres", "litern"]);
  add("gal", ["gal", "gallon", "gallons", "gallone", "gallonen"]);
  add("cups", ["cup", "cups", "tasse", "tassen"]);
  add("pint", ["pint", "pints"]);
  add("tbsp", ["tbsp", "tablespoon", "tablespoons", "esslöffel", "el"]);
  add("tsp", ["tsp", "teaspoon", "teaspoons", "teelöffel", "tl"]);
  add("floz", ["fl oz", "floz", "fluid ounce", "fluid ounces"]);
  add("ms", ["ms", "millisecond", "milliseconds", "millisekunde", "millisekunden"]);
  add("seconds", ["s", "sec", "secs", "second", "seconds", "sekunde", "sekunden"]);
  add("minutes", ["min", "mins", "minute", "minutes", "minuten"]);
  add("hours", ["h", "hr", "hrs", "hour", "hours", "stunde", "stunden", "std"]);
  add("days", ["day", "days", "tag", "tage", "tagen"]);
  add("weeks", ["week", "weeks", "woche", "wochen"]);
  add("months", ["month", "months", "monat", "monate", "monaten"]);
  add("years", ["year", "years", "jahr", "jahre", "jahren"]);
  add("bits", ["bit", "bits"]);
  add("bytes", ["b", "byte", "bytes"]);
  add("kB", ["kb", "kilobyte", "kilobytes"]);
  add("MB", ["mb", "megabyte", "megabytes"]);
  add("GB", ["gb", "gigabyte", "gigabytes"]);
  add("TB", ["tb", "terabyte", "terabytes"]);
  add("KiB", ["kib", "kibibyte", "kibibytes"]);
  add("MiB", ["mib", "mebibyte", "mebibytes"]);
  add("GiB", ["gib", "gibibyte", "gibibytes"]);
  add("TiB", ["tib", "tebibyte", "tebibytes"]);
  add("mph", ["mph", "miles per hour", "meilen pro stunde"]);
  add("km/h", ["km/h", "kmh", "kph", "kilometers per hour", "kilometres per hour", "kilometer pro stunde", "stundenkilometer"]);
  add("m/s", ["m/s", "meters per second", "metres per second", "meter pro sekunde"]);
  add("knots", ["kn", "knot", "knots", "knoten"]);
  add("m^2", ["m2", "m²", "sqm", "square meter", "square meters", "square metre", "square metres", "quadratmeter"]);
  add("km^2", ["km2", "km²", "square kilometer", "square kilometers", "square kilometre", "square kilometres", "quadratkilometer"]);
  add("ft^2", ["sqft", "sq ft", "ft2", "ft²", "square foot", "square feet"]);
  add("acres", ["acre", "acres"]);
  add("hectares", ["ha", "hectare", "hectares", "hektar"]);
  add("kcal", ["kcal", "kilocalorie", "kilocalories", "kalorien", "kilokalorien"]);
  add("calories", ["cal", "calorie", "calories"]);
  add("kJ", ["kj", "kilojoule", "kilojoules"]);
  add("J", ["j", "joule", "joules"]);
  add("kWh", ["kwh", "kilowatt hour", "kilowatt hours", "kilowattstunde", "kilowattstunden"]);
  add("W", ["w", "watt", "watts"]);
  add("kW", ["kw", "kilowatt", "kilowatts"]);
  add("hp", ["hp", "horsepower"]);
  add("bar", ["bar"]);
  add("psi", ["psi"]);
  add("Pa", ["pa", "pascal"]);
  add("atm", ["atm", "atmosphere", "atmospheres"]);
  return table;
})();

/** Currency words and symbols → ISO 4217 (the ECB table plus EUR). Bare "dollar" means USD. */
export const CURRENCY_WORDS: Readonly<Record<string, string>> = (() => {
  const table: Record<string, string> = {};
  const add = (code: string, names: string[]): void => {
    table[code.toLowerCase()] = code;
    for (const name of names) table[name] = code;
  };
  add("USD", ["$", "us$", "dollar", "dollars", "bucks", "us dollar", "us dollars", "us-dollar", "american dollars"]);
  add("EUR", ["€", "euro", "euros", "eur"]);
  add("GBP", ["£", "quid", "pound sterling", "pounds sterling", "british pound", "british pounds", "pfund sterling", "britische pfund", "britischen pfund"]);
  add("JPY", ["¥", "yen", "japanese yen", "japanische yen"]);
  add("CHF", ["franken", "schweizer franken", "swiss franc", "swiss francs", "francs", "franc"]);
  add("CAD", ["canadian dollar", "canadian dollars", "kanadische dollar", "kanadischen dollar"]);
  add("AUD", ["australian dollar", "australian dollars", "australische dollar", "australischen dollar"]);
  add("NZD", ["new zealand dollar", "new zealand dollars", "neuseeland-dollar", "neuseeländische dollar"]);
  add("HKD", ["hong kong dollar", "hong kong dollars", "hongkong-dollar"]);
  add("SGD", ["singapore dollar", "singapore dollars", "singapur-dollar"]);
  add("CNY", ["yuan", "renminbi", "rmb", "chinese yuan"]);
  add("INR", ["rupee", "rupees", "rupie", "rupien", "indian rupees", "indische rupien"]);
  add("KRW", ["won", "korean won"]);
  add("SEK", ["swedish krona", "swedish kronor", "schwedische kronen", "schwedischen kronen"]);
  add("NOK", ["norwegian krone", "norwegian kroner", "norwegische kronen", "norwegischen kronen"]);
  add("DKK", ["danish krone", "danish kroner", "dänische kronen", "dänischen kronen"]);
  add("PLN", ["zloty", "złoty", "zlotys"]);
  add("CZK", ["czech koruna", "czech crowns", "tschechische kronen", "tschechischen kronen"]);
  add("HUF", ["forint", "forints"]);
  add("TRY", ["lira", "turkish lira", "türkische lira", "türkischen lira"]);
  add("BRL", ["real", "reais", "brazilian real"]);
  add("MXN", ["mexican peso", "mexican pesos", "mexikanische pesos"]);
  add("ZAR", ["rand", "south african rand"]);
  add("ILS", ["shekel", "shekels", "schekel"]);
  add("IDR", ["rupiah"]);
  add("MYR", ["ringgit"]);
  add("PHP", ["philippine peso", "philippine pesos"]);
  add("THB", ["baht"]);
  add("ISK", ["icelandic krona", "isländische kronen"]);
  add("RON", ["leu", "lei", "romanian leu"]);
  return table;
})();

const BASE_WORDS: Readonly<Record<string, BaseName>> = {
  hex: "hex", hexadecimal: "hex", hexadezimal: "hex", decimal: "decimal", dezimal: "decimal", binary: "binary",
  "binär": "binary", binaer: "binary", octal: "octal", oktal: "octal",
};

const SEPARATOR = String.raw`(?:in|to|into|as|nach|zu|auf|in to)`;
const AMOUNT = String.raw`(-?\d+(?:\.\d+)?)\s*(k\b)?`;
const UNIT_PHRASE = String.raw`([a-zäöüß°$€£¥/²"' .-]+?)`;
const ONE = String.raw`(?:(a|an|one|ein|eine|einem|einer|einen)\s+)`;

const FORWARD = new RegExp(String.raw`^${AMOUNT}\s*${UNIT_PHRASE}\s+${SEPARATOR}\s+${UNIT_PHRASE}$`);
const FORWARD_ONE = new RegExp(String.raw`^${ONE}${UNIT_PHRASE}\s+${SEPARATOR}\s+${UNIT_PHRASE}$`);
const REVERSE_EN = new RegExp(String.raw`^how (?:many|much) ${UNIT_PHRASE} (?:is|are|in|is in|are in|make|makes|equals?|is there in|are there in|for) (?:${AMOUNT}|${ONE})\s*${UNIT_PHRASE}$`);
const REVERSE_DE = new RegExp(String.raw`^wie ?viele? ${UNIT_PHRASE} (?:sind|ist|ergeben|ergibt|macht|machen|hat|haben|entsprechen|entspricht|sind in|ist in|in) (?:${AMOUNT}|${ONE})\s*${UNIT_PHRASE}$`);

function lookup(table: Readonly<Record<string, string>>, phrase: string): string | null {
  const p = phrase.trim().replace(/\s+/g, " ").replace(/^(?:of |in |the |der |die |das |den )/, "").replace(/\.$/, "");
  return table[p] ?? null;
}

function amountOf(digits: string | undefined, k: string | undefined, one: string | undefined): number | null {
  if (one !== undefined && digits === undefined) return 1;
  if (digits === undefined) return null;
  const value = Number(digits) * (k ? 1000 : 1);
  return Number.isFinite(value) ? value : null;
}

/** "$100" → "100 $", "50€" → "50 €" so symbols read like unit words. */
function spaceCurrencySymbols(text: string): string {
  return text.replace(/([$€£¥])\s*(\d+(?:\.\d+)?k?)/g, "$2 $1").replace(/(\d)([$€£¥])/g, "$1 $2");
}

function conversionText(n: Normalized): string {
  let s = stripCalcPrefix(n.numeric).replace(/^(?:convert|umrechnen|konvertiere|rechne|wandle)\s+/, "");
  s = s.replace(/\s+(?:um|umrechnen|konvertieren|umwandeln|convert)$/, "");
  return spaceCurrencySymbols(s).replace(/\s+/g, " ").trim();
}

const MASS_POUNDS = new Set(["pound", "pounds", "pfund"]);

function formatAmount(value: number): string {
  return String(Number(value.toPrecision(15)));
}

function resolveConversion(amount: number, fromPhrase: string, toPhrase: string): Parsed | null {
  let fromCurrency = lookup(CURRENCY_WORDS, fromPhrase);
  let toCurrency = lookup(CURRENCY_WORDS, toPhrase);
  // "100 pounds in euro": with a currency on the other side, pounds are sterling.
  if (fromCurrency && !toCurrency && MASS_POUNDS.has(toPhrase.trim())) toCurrency = "GBP";
  if (toCurrency && !fromCurrency && MASS_POUNDS.has(fromPhrase.trim())) fromCurrency = "GBP";
  if (fromCurrency && toCurrency) return { kind: "currency", amount, from: fromCurrency, to: toCurrency };
  if (fromCurrency || toCurrency) return null;
  const from = lookup(UNIT_WORDS, fromPhrase);
  const to = lookup(UNIT_WORDS, toPhrase);
  if (!from || !to) return null;
  const value = formatAmount(amount);
  return { kind: "unit", expression: `${value} ${from} to ${to}`, display: `${value} ${from} in ${to}` };
}

export function matchConversion(n: Normalized): Parsed | null {
  const s = conversionText(n);
  let m = FORWARD.exec(s);
  if (m) {
    const amount = amountOf(m[1], m[2], undefined);
    return amount === null ? null : resolveConversion(amount, m[3]!, m[4]!);
  }
  m = FORWARD_ONE.exec(s);
  if (m) return resolveConversion(1, m[2]!, m[3]!);
  m = REVERSE_EN.exec(s) ?? REVERSE_DE.exec(s);
  if (m) {
    const amount = amountOf(m[2], m[3], m[4]);
    return amount === null ? null : resolveConversion(amount, m[5]!, m[1]!);
  }
  return null;
}

const BASE_TARGET = String.raw`(hex|hexadecimal|hexadezimal|decimal|dezimal|binary|binär|binaer|octal|oktal|base \d{1,2}|basis \d{1,2})`;
const BARE_BASE = new RegExp(String.raw`^(0x[0-9a-f]+|0b[01]+|0o[0-7]+|\d+)\s+${SEPARATOR}\s+${BASE_TARGET}$`);
const NAMED_BASE = new RegExp(String.raw`^([0-9a-f]+)\s+(hex|hexadecimal|hexadezimal|binary|binär|binaer|octal|oktal|decimal|dezimal)\s+${SEPARATOR}\s+${BASE_TARGET}$`);

function baseName(word: string): BaseName | null {
  const direct = BASE_WORDS[word];
  if (direct) return direct;
  const m = /^(?:base|basis) (\d{1,2})$/.exec(word);
  const radix = m ? Number(m[1]) : NaN;
  return radix >= 2 && radix <= 36 ? `base ${radix}` : null;
}

const PREFIX: Readonly<Record<string, string>> = { hex: "0x", binary: "0b", octal: "0o", decimal: "" };

/** "255 in hex", "0xff in decimal", "ff hex to decimal", "255 to base 3". */
export function matchBase(n: Normalized): Parsed | null {
  const s = conversionText(n);
  let value: string | undefined;
  let target: BaseName | null = null;
  const bare = BARE_BASE.exec(s);
  if (bare) {
    value = bare[1]!;
    target = baseName(bare[2]!);
  } else {
    const named = NAMED_BASE.exec(s);
    const fromBase = named ? BASE_WORDS[named[2]!] : undefined;
    if (named && fromBase) {
      const digits = named[1]!;
      const valid = fromBase === "hex" ? /^[0-9a-f]+$/ : fromBase === "binary" ? /^[01]+$/ : fromBase === "octal" ? /^[0-7]+$/ : /^\d+$/;
      if (!valid.test(digits)) return null;
      value = `${PREFIX[fromBase] ?? ""}${digits}`;
      target = baseName(named[3]!);
    }
  }
  if (!value || !target) return null;
  return { kind: "base", expression: `${value} to ${target}`, display: `${value} in ${target}`, base: target };
}

/**
 * Tokens a calculator expression may consist of after canonicalMath. Anything
 * else (letters, words, punctuation) means the utterance is not math.
 */
const CALC_TOKEN = new RegExp(
  String.raw`\s+|0x[0-9a-f]+|0b[01]+|0o[0-7]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?|` +
    String.raw`(?:sqrt|cbrt|sin|cos|tan|asin|acos|atan|ln|log10|log2|log|exp|abs|floor|ceil|round)(?=\s*\()|` +
    String.raw`pi\b|π|of\b|[-+*/^%!()°]|` +
    String.raw`(?:km\/h|m\/s|km|cm|mm|mi|miles|ft|feet|inches|yards|kg|mg|lbs?|oz|ml|gal|min|mins|hours|seconds|days|weeks|kB|MB|GB|TB|KiB|MiB|GiB|TiB|°C|°F|m|g|l|h|s)\b`,
  "iy",
);
const UNIT_TOKEN = /^(?:km\/h|m\/s|km|cm|mm|mi|miles|ft|feet|inches|yards|kg|mg|lbs?|oz|ml|gal|min|mins|hours|seconds|days|weeks|kb|mb|gb|tb|kib|mib|gib|tib|°c|°f|m|g|l|h|s)$/i;
const OPERATOR = /[-+*/^!]|%|\bof\b|sqrt|cbrt|sin|cos|tan|ln|log|exp|abs|floor|ceil|round|pi|π/;
const NUMBER = /^(?:0x[0-9a-f]+|0b[01]+|0o[0-7]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)$/i;

function tokens(expression: string): string[] | null {
  const out: string[] = [];
  CALC_TOKEN.lastIndex = 0;
  while (CALC_TOKEN.lastIndex < expression.length) {
    const start = CALC_TOKEN.lastIndex;
    const m = CALC_TOKEN.exec(expression);
    if (!m || m.index !== start || m[0].length === 0) return null;
    if (m[0].trim()) out.push(m[0]);
  }
  return out;
}

/** Arithmetic in words or symbols ("15% of 340", "zwei hoch sechzehn minus tausend", "5 km + 300 m"). */
export function matchCalc(n: Normalized): Parsed | null {
  const { expression, display } = canonicalMath(n.numeric);
  if (!expression || expression.length > 300 || !/\d/.test(expression)) return null;
  // A bare (signed) number, percentage or ISO date is not a calculation.
  if (/^[-+]?\s*\d+(?:\.\d+)?%?$/.test(expression) || /^\d{4}-\d{1,2}-\d{1,2}$/.test(expression)) return null;
  const parts = tokens(expression);
  if (!parts || !parts.some((part) => OPERATOR.test(part))) return null;
  // Juxtaposed plain numbers ("+49 176 1234") would be implicit multiplication in fend.
  if (parts.some((part, i) => i > 0 && NUMBER.test(part) && NUMBER.test(parts[i - 1]!))) return null;
  let depth = 0;
  for (const part of parts) {
    if (part === "(") depth++;
    if (part === ")" && --depth < 0) return null;
  }
  if (depth !== 0) return null;
  return { kind: "calc", expression, display, units: parts.some((part) => UNIT_TOKEN.test(part)) };
}
