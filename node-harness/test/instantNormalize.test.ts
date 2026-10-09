import assert from "node:assert/strict";
import { test } from "node:test";
import {
  canonicalMath, cleanUtterance, decimalConvention, detectLang, fixDecimalSeparators, normalize, normalizeSpokenUrl,
} from "../src/instant/normalize.js";
import { applyDigitScales, deWordsToDigits, deWordToNumber, enWordsToDigits } from "../src/instant/numberWords.js";

test("EN number words → digits (raycast §23.2 + phrase boundaries)", () => {
  const cases: [string, string][] = [
    ["thirty two", "32"],
    ["three hundred and forty", "340"],
    ["one point five", "1.5"],
    ["a million divided by 8", "1000000 divided by 8"],
    ["two to the power of thirty two", "2 to the power of 32"],
    ["twelve hundred", "1200"],
    ["one hundred thousand", "100000"],
    ["two million three hundred thousand", "2300000"],
    ["one thousand and one", "1001"],
    ["thirty-two", "32"],
    ["zero point two five", "0.25"],
    // Adjacent numbers never merge into a sum, and "and" only joins after hundred/scale.
    ["five six", "5 6"],
    ["five and six", "5 and 6"],
    ["3 million", "3 million"],
    ["set volume to thirty percent", "set volume to 30 percent"],
    ["the one with the dog", "the 1 with the dog"],
  ];
  for (const [input, expected] of cases) assert.equal(enWordsToDigits(input), expected, input);
});

test("DE number words → digits incl. compounds, komma, Millionen (raycast §23.2)", () => {
  assert.equal(deWordToNumber("zweiunddreißig"), 32);
  assert.equal(deWordToNumber("dreihundertvierzig"), 340);
  assert.equal(deWordToNumber("eintausendzweihundertfünfunddreißig"), 1235);
  assert.equal(deWordToNumber("dreissig"), 30);
  assert.equal(deWordToNumber("sechzehn"), 16);
  assert.equal(deWordToNumber("zweitausendsechsundzwanzig"), 2026);
  assert.equal(deWordToNumber("hundertundeins"), 101);
  assert.equal(deWordToNumber("tausend"), 1000);
  assert.equal(deWordToNumber("fuenfundzwanzig"), 25);
  assert.equal(deWordToNumber("zwo"), 2);
  // Standalone teen hundreds (years, amounts); next to "tausend" only 1–9 hundreds are valid.
  assert.equal(deWordToNumber("zwölfhundert"), 1200);
  assert.equal(deWordToNumber("neunzehnhundertvierundachtzig"), 1984);
  assert.equal(deWordToNumber("einhundertzwölf"), 112);
  assert.equal(deWordToNumber("zweitausendzwölfhundert"), null);
  assert.equal(normalize("zwölfhundert minus einhundertzwölf").numeric, "1200 minus 112");
  // "eins" is not English, so it marks the utterance German and "null" converts with it.
  assert.equal(normalize("null plus eins").numeric, "0 plus 1");
  for (const word of ["achtung", "hundertwasser", "tausendfüßler", "rechnung", "neunte", ""]) assert.equal(deWordToNumber(word), null, word);
  assert.equal(deWordsToDigits("zwei komma fünf"), "2.5");
  assert.equal(deWordsToDigits("drei millionen"), "3000000");
  assert.equal(deWordsToDigits("zwei millionen dreihunderttausend"), "2300000");
  assert.equal(deWordsToDigits("zwei hoch sechzehn minus tausend"), "2 hoch 16 minus 1000");
  // Collisions with English stay words when skipped (English utterances).
  assert.equal(deWordsToDigits("elf null acht", new Set(["elf", "null", "acht"])), "elf null acht");
  assert.equal(applyDigitScales("10 thousand and 1.5 million, 3 millionen"), "10000 and 1500000, 3000000");
});

test("language detection: keyword vote, locale hint breaks ties", () => {
  assert.equal(detectLang("was ist zwei hoch zweiunddreißig"), "de");
  assert.equal(detectLang("what's two to the power of thirty two"), "en");
  assert.equal(detectLang("hundert dollar in euro"), "de");
  assert.equal(detectLang("5 meilen in km"), "de");
  assert.equal(detectLang("1.000 * 3"), "en");
  assert.equal(detectLang("1.000 * 3", "de-DE"), "de");
});

test("decimal separators by language", () => {
  assert.equal(fixDecimalSeparators("1,5 mal 2", "de"), "1.5 mal 2");
  assert.equal(fixDecimalSeparators("1.000 * 3", "de"), "1000 * 3");
  assert.equal(fixDecimalSeparators("1.234.567,89", "de"), "1234567.89");
  assert.equal(fixDecimalSeparators("1.5 * 2", "de"), "1.5 * 2");
  assert.equal(fixDecimalSeparators("1,000 * 3", "en"), "1000 * 3");
  assert.equal(fixDecimalSeparators("1,000,000.5", "en"), "1000000.5");
  assert.equal(normalize("1,5 mal 2", "de").numeric, "1.5 mal 2");
  assert.equal(normalize("1.000 * 3", "de").numeric, "1000 * 3");
});

test("decimal separators follow the format locale's region (en-DE from an rg override parses 2,5)", () => {
  assert.equal(decimalConvention("en", "en-DE"), "comma");
  assert.equal(decimalConvention("en", "en-US"), "point");
  assert.equal(decimalConvention("en", "de-CH"), "point");
  assert.equal(decimalConvention("de", "en-US"), "comma");
  assert.equal(decimalConvention("en", undefined), "point");
  assert.equal(decimalConvention("en", "not a locale"), "point");
  assert.equal(normalize("2,5 * 4", "en-DE").numeric, "2.5 * 4");
  assert.equal(normalize("1.000 + 1", "en-DE").numeric, "1000 + 1");
  assert.equal(normalize("1,250 * 4", "en-US").numeric, "1250 * 4");
  assert.equal(fixDecimalSeparators("1,5 mal 2", "comma"), "1.5 mal 2");
  assert.equal(fixDecimalSeparators("1,000 * 3", "point"), "1000 * 3");
});

test("cleanUtterance strips wake word, politeness and trailing punctuation but keeps factorials", () => {
  assert.equal(cleanUtterance("  Hey pi, what's 2+2?  "), "what's 2+2");
  assert.equal(cleanUtterance("pi: open figma please!"), "open figma");
  assert.equal(cleanUtterance("pi times 2"), "pi times 2");
  assert.equal(cleanUtterance("Bitte öffne Figma."), "öffne Figma");
  assert.equal(cleanUtterance("can you open spotify, thanks"), "open spotify");
  assert.equal(cleanUtterance("reply and say thanks"), "reply and say thanks");
  assert.equal(cleanUtterance("5!"), "5!");
  assert.equal(cleanUtterance("=2+2"), "2+2");
  assert.equal(cleanUtterance("„Rechnung“"), "\"Rechnung\"");
});

test("spoken operators → fend syntax with Raycast percent semantics", () => {
  const math = (text: string, locale?: string) => canonicalMath(normalize(text, locale).numeric);
  assert.deepEqual(math("what is fifteen percent of three hundred and forty"), { expression: "15% of 340", display: "15% of 340" });
  assert.equal(math("was ergibt zwei hoch sechzehn minus tausend").expression, "2 ^ 16 - 1000");
  assert.equal(math("zweihundertfünfzig geteilt durch fünf").expression, "250 / 5");
  assert.equal(math("one point five times four").expression, "1.5 * 4");
  assert.equal(math("seven squared").expression, "7 ^2");
  assert.equal(math("rechne 7 mal 6").expression, "7 * 6");
  assert.equal(math("square root of 1764 divided by 6").expression, "sqrt(1764) / 6");
  assert.equal(math("wurzel aus 144").display, "√144");
  assert.equal(math("5 factorial").expression, "5!");
  assert.equal(math("12 x 12").expression, "12*12");
  assert.equal(math("0x1f + 1").expression, "0x1f + 1");
  assert.equal(math("2 to the 10th power").expression, "2 ^10");
  assert.equal(math("20% off 80").expression, "80*(1-20/100)");
  assert.equal(math("15% tip on 42").expression, "42*15/100");
  assert.equal(math("80 + 15%").expression, "(80)*(1+15/100)");
  assert.equal(math("340 - 15 prozent").expression, "(340)*(1-15/100)");
  assert.equal(math("340 * 15%").expression, "340 * (15/100)");
  assert.equal(math("(3 + 4) * 12 / 2").display, "(3 + 4) × 12 ÷ 2");
});

test("spoken URLs (jev normalizeSpokenUrl, EN + DE)", () => {
  assert.equal(normalizeSpokenUrl("github dot com"), "github.com");
  assert.equal(normalizeSpokenUrl("spiegel punkt de"), "spiegel.de");
  assert.equal(normalizeSpokenUrl("example dot com slash docs"), "example.com/docs");
  assert.equal(normalizeSpokenUrl("w w w dot example dot org"), "www.example.org");
  assert.equal(normalizeSpokenUrl("h t t p s colon slash slash example dot com"), "https://example.com");
  assert.equal(normalizeSpokenUrl("my dash site dot io"), "my-site.io");
});
