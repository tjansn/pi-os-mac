/**
 * Sound-alike helpers for spoken app names (DESIGN4 §5.2). Pure, allocation-light, microseconds per
 * call; inputs are folded ASCII ("a-z0-9"), never raw user text, and nothing here logs.
 *
 *   - Double Metaphone (English pronunciation): "notion"/"nation" → NXN, "calender"/"calendar" → KLNTR.
 *   - Kölner Phonetik (German pronunciation): "Spotifei"/"Spotify", "Kalender"/"Calendar".
 *   - Optimal-string-alignment Damerau-Levenshtein, on folded text and on phonetic keys.
 *
 * Vendored (DESIGN4 §5.2 [D]: no new runtime dependencies), ported to strict TypeScript with the
 * behaviour unchanged (test/instantSpoken.test.ts pins golden codes from the original packages):
 *   - `doubleMetaphone`: double-metaphone@2.0.1, Copyright (c) 2014 Titus Wormer, MIT License,
 *     https://github.com/words/double-metaphone (after Lawrence Philips' algorithm).
 *   - `colognePhonetic`: cologne-phonetic@1.1.1, Copyright (c) 2019 Max Dancau, MIT License,
 *     https://github.com/maxwellium/cologne-phonetic.
 *
 * MIT License text (applies to both vendored functions): Permission is hereby granted, free of charge,
 * to any person obtaining a copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation the rights to use, copy,
 * modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
 * persons to whom the Software is furnished to do so, subject to the following conditions: The above
 * copyright notice and this permission notice shall be included in all copies or substantial portions
 * of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
 * OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

// ---------------------------------------------------------------- edit distance

/** Optimal-string-alignment Damerau-Levenshtein distance (adjacent transpositions cost 1). */
export function damerau(a: string, b: string): number {
  if (a === b) return 0;
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  const cols = b.length + 1;
  const d = new Array<number>((a.length + 1) * cols);
  for (let i = 0; i <= a.length; i++) d[i * cols] = i;
  for (let j = 0; j < cols; j++) d[j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let v = Math.min(d[(i - 1) * cols + j]! + 1, d[i * cols + j - 1]! + 1, d[(i - 1) * cols + j - 1]! + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) v = Math.min(v, d[(i - 2) * cols + j - 2]! + 1);
      d[i * cols + j] = v;
    }
  }
  return d[a.length * cols + b.length]!;
}

/** 1 − normalized edit distance (0..1); 1 for two empty strings. */
export function editSimilarity(a: string, b: string): number {
  const max = Math.max(a.length, b.length);
  return max === 0 ? 1 : 1 - damerau(a, b) / max;
}

// ---------------------------------------------------------------- phonetic keys

export interface PhoneticKeys {
  /** Double Metaphone primary and secondary (one entry when they agree). */
  dm: string[];
  /** Kölner Phonetik code. */
  koeln: string;
}

/** Keys of a compact folded name ("pagescreatorstudio"); digits are ignored. */
export function phoneticKeys(compact: string): PhoneticKeys {
  const letters = compact.replace(/[0-9]+/g, "");
  if (!letters) return { dm: [], koeln: "" };
  const [primary, secondary] = doubleMetaphone(letters);
  return { dm: primary === secondary ? [primary] : [primary, secondary], koeln: colognePhonetic(letters) };
}

/**
 * Best phonetic similarity (0..1); 0 when either side has no key. Kölner Phonetik is coarse (m = n,
 * b = p, d = t) and models German spelling, so it counts only for German utterances ("öffne Spotifei",
 * "Nouschen"); English utterances use Double Metaphone alone.
 */
export function phoneticSimilarity(a: PhoneticKeys, b: PhoneticKeys, german = false): number {
  let best = 0;
  for (const x of a.dm) for (const y of b.dm) if (x && y) best = Math.max(best, editSimilarity(x, y));
  if (german && a.koeln && b.koeln) best = Math.max(best, editSimilarity(a.koeln, b.koeln));
  return best;
}

/** The first Double Metaphone sound ("" when there is none): the dictionary-word guard's "same first sound". */
export function firstSound(keys: PhoneticKeys): string {
  return keys.dm[0]?.[0] ?? "";
}

// ---------------------------------------------------------------- Kölner Phonetik (vendored)

const COLOGNE_RULES: readonly (readonly [RegExp, string])[] = [
  // substitutions
  [/ä/g, "a"],
  [/ö/g, "o"],
  [/ü/g, "u"],
  [/ß/g, "ss"],
  [/[^a-z]/g, ""],
  // complex rules ([csz] are replaced soon, so these run early)
  [/[dt](?![csz])/g, "2"],
  [/[dt](?=[csz])/g, "8"],
  [/[ckq]x/g, "88"],
  [/[sz]c/g, "88"],
  [/^c(?=[ahkloqrux])/, "4"],
  [/^c/, "8"],
  [/c(?=[ahkoqux])/g, "4"],
  [/c$/, "4"],
  [/x/g, "48"],
  [/p(?!h)/g, "1"],
  [/p(?=h)/g, "3"],
  // simple rules
  [/h/g, ""],
  [/[aeijouy]/g, "0"],
  [/b/g, "1"],
  [/[fvw]/g, "3"],
  [/[gkq]/g, "4"],
  [/l/g, "5"],
  [/[mn]/g, "6"],
  [/r/g, "7"],
  [/[csz]/g, "8"],
  // modifiers: collapse consecutive duplicates, then drop 0s except a leading one
  [/([^\w\s])|(.)(?=\2)/g, ""],
  [/\B0/g, ""],
];

/** Kölner Phonetik code of a word ("Müller" → "657"). */
export function colognePhonetic(phrase: string): string {
  return COLOGNE_RULES.reduce((code, [search, replace]) => code.replace(search, replace), phrase.toLowerCase());
}

// ---------------------------------------------------------------- Double Metaphone (vendored)

/** Vowels, including `Y`. */
const VOWELS = /[AEIOUY]/;
/** A few Slavo-Germanic values. */
const SLAVO_GERMANIC = /W|K|CZ|WITZ/;
/** A few Germanic values. */
const GERMANIC = /^(VAN |VON |SCH)/;
/** Initial values whose first character is skipped. */
const INITIAL_EXCEPTIONS = /^(GN|KN|PN|WR|PS)/;
/** Initial Greek-like values where `CH` sounds like `K`. */
const INITIAL_GREEK_CH = /^CH(IA|EM|OR([^E])|YM|ARAC|ARIS)/;
/** Greek-like values where `CH` sounds like `K`. */
const GREEK_CH = /ORCHES|ARCHIT|ORCHID/;
/** Values after `CH` that turn it into `K`. */
const CH_FOR_KH = /[ BFHLMNRVW]/;
/** Values before a vowel and `UGH` that make it sound like `F`. */
const G_FOR_F = /[CGLRT]/;
/** Initial values that sound like either `K` or `J`. */
const INITIAL_G_FOR_KJ = /Y[\s\S]|E[BILPRSY]|I[BELN]/;
const INITIAL_ANGER_EXCEPTION = /^[DMR]ANGER/;
/** Values after `GY` that do not sound like `K` or `J`. */
const G_FOR_KJ = /[EGIR]/;
/** Values after `J` that do not sound like `J`. */
const J_FOR_J_EXCEPTION = /[LTKSNMBZ]/;
/** Values that might sound like `L`. */
const ALLE = /AS|OS/;
/** Germanic values before `SH` that sound like `S`. */
const H_FOR_S = /EIM|OEK|OLM|OLZ/;
/** Dutch values after `SCH` that sound like `X` and `SK`, or `SK`. */
const DUTCH_SCH = /E[DMNR]|UY|OO/;

/** `RegExp.test` on a possibly missing character (the original tests `undefined`, which never matches these classes). */
function at(pattern: RegExp, value: string | undefined): boolean {
  return pattern.test(value ?? "");
}

/**
 * Double Metaphone codes `[primary, secondary]` of a value (Lawrence Philips' algorithm as implemented
 * by double-metaphone@2.0.1, including its documented quirks).
 */
export function doubleMetaphone(value: string): [string, string] {
  let primary = "";
  let secondary = "";
  let index = 0;
  const length = value.length;
  const last = length - 1;
  const normalized = String(value).toUpperCase() + "     ";
  const isSlavoGermanic = SLAVO_GERMANIC.test(normalized);
  const isGermanic = GERMANIC.test(normalized);
  const characters = normalized.split("");
  const char = (i: number): string | undefined => characters[i];

  // Skip this at the beginning of a word.
  if (INITIAL_EXCEPTIONS.test(normalized)) index++;

  // Initial X is pronounced Z, which maps to S ("Xavier").
  if (characters[0] === "X") {
    primary += "S";
    secondary += "S";
    index++;
  }

  while (index < length) {
    const previous = char(index - 1);
    const next = char(index + 1);
    const nextnext = char(index + 2);
    let subvalue: string | undefined;

    switch (characters[index]) {
      case "A":
      case "E":
      case "I":
      case "O":
      case "U":
      case "Y":
      case "À":
      case "Ê":
      case "É":
        // All initial vowels map to `A`.
        if (index === 0) {
          primary += "A";
          secondary += "A";
        }
        index++;
        break;
      case "B":
        primary += "P";
        secondary += "P";
        if (next === "B") index++;
        index++;
        break;
      case "Ç":
        primary += "S";
        secondary += "S";
        index++;
        break;
      case "C":
        // Various Germanic.
        if (
          previous === "A" &&
          next === "H" &&
          nextnext !== "I" &&
          !at(VOWELS, char(index - 2)) &&
          (nextnext !== "E" ||
            ((subvalue = normalized.slice(index - 2, index + 4)) && (subvalue === "BACHER" || subvalue === "MACHER")))
        ) {
          primary += "K";
          secondary += "K";
          index += 2;
          break;
        }
        // Special case for `Caesar`.
        if (index === 0 && normalized.slice(index + 1, index + 6) === "AESAR") {
          primary += "S";
          secondary += "S";
          index += 2;
          break;
        }
        // Italian `Chianti`.
        if (normalized.slice(index + 1, index + 4) === "HIA") {
          primary += "K";
          secondary += "K";
          index += 2;
          break;
        }
        if (next === "H") {
          // `Michael`.
          if (index > 0 && nextnext === "A" && char(index + 3) === "E") {
            primary += "K";
            secondary += "X";
            index += 2;
            break;
          }
          // Greek roots such as `chemistry`, `chorus`.
          if (index === 0 && INITIAL_GREEK_CH.test(normalized)) {
            primary += "K";
            secondary += "K";
            index += 2;
            break;
          }
          // Germanic, Greek, or otherwise `CH` for a `KH` sound.
          if (
            isGermanic ||
            // Such as `architect` but not `arch`, `orchestra`, `orchid`.
            GREEK_CH.test(normalized.slice(index - 2, index + 4)) ||
            nextnext === "T" ||
            nextnext === "S" ||
            ((index === 0 || previous === "A" || previous === "E" || previous === "O" || previous === "U") &&
              // Such as `wachtler`, `weschsler`, but not `tichner`.
              at(CH_FOR_KH, nextnext))
          ) {
            primary += "K";
            secondary += "K";
          } else if (index === 0) {
            primary += "X";
            secondary += "X";
          } else if (normalized.slice(0, 2) === "MC") {
            // Such as `McHugh`.
            primary += "K";
            secondary += "K";
          } else {
            primary += "X";
            secondary += "K";
          }
          index += 2;
          break;
        }
        // Such as `Czerny`.
        if (next === "Z" && normalized.slice(index - 2, index) !== "WI") {
          primary += "S";
          secondary += "X";
          index += 2;
          break;
        }
        // Such as `Focaccia`.
        if (normalized.slice(index + 1, index + 4) === "CIA") {
          primary += "X";
          secondary += "X";
          index += 3;
          break;
        }
        // Double `C`, but not `McClellan`.
        if (next === "C" && !(index === 1 && characters[0] === "M")) {
          // Such as `Bellocchio`, but not `Bacchus`.
          if ((nextnext === "I" || nextnext === "E" || nextnext === "H") && normalized.slice(index + 2, index + 4) !== "HU") {
            subvalue = normalized.slice(index - 1, index + 4);
            // Such as `Accident`, `Accede`, `Succeed`.
            if ((index === 1 && previous === "A") || subvalue === "UCCEE" || subvalue === "UCCES") {
              primary += "KS";
              secondary += "KS";
            } else {
              // Such as `Bacci`, `Bertucci`, other Italian.
              primary += "X";
              secondary += "X";
            }
            index += 3;
            break;
          }
          // Pierce's rule.
          primary += "K";
          secondary += "K";
          index += 2;
          break;
        }
        if (next === "G" || next === "K" || next === "Q") {
          primary += "K";
          secondary += "K";
          index += 2;
          break;
        }
        // Italian.
        if (next === "I" && (nextnext === "E" || nextnext === "O")) {
          primary += "S";
          secondary += "X";
          index += 2;
          break;
        }
        if (next === "I" || next === "E" || next === "Y") {
          primary += "S";
          secondary += "S";
          index += 2;
          break;
        }
        primary += "K";
        secondary += "K";
        // Skip two extra characters ahead in `Mac Caffrey`, `Mac Gregor`.
        if (next === " " && (nextnext === "C" || nextnext === "G" || nextnext === "Q")) {
          index += 3;
          break;
        }
        index++;
        break;
      case "D":
        if (next === "G") {
          if (nextnext === "E" || nextnext === "I" || nextnext === "Y") {
            // Such as `edge`.
            primary += "J";
            secondary += "J";
            index += 3;
          } else {
            // Such as `Edgar`.
            primary += "TK";
            secondary += "TK";
            index += 2;
          }
          break;
        }
        if (next === "T" || next === "D") {
          primary += "T";
          secondary += "T";
          index += 2;
          break;
        }
        primary += "T";
        secondary += "T";
        index++;
        break;
      case "F":
        if (next === "F") index++;
        index++;
        primary += "F";
        secondary += "F";
        break;
      case "G":
        if (next === "H") {
          if (index > 0 && !at(VOWELS, previous)) {
            primary += "K";
            secondary += "K";
            index += 2;
            break;
          }
          // Such as `Ghislane`, `Ghiradelli`.
          if (index === 0) {
            if (nextnext === "I") {
              primary += "J";
              secondary += "J";
            } else {
              primary += "K";
              secondary += "K";
            }
            index += 2;
            break;
          }
          // Parker's rule (with some further refinements): `Hugh`, `bough`, `Broughton`.
          {
            const two = char(index - 2);
            const three = char(index - 3);
            const four = char(index - 4);
            if (two === "B" || two === "H" || two === "D" || three === "B" || three === "H" || three === "D" || four === "B" || four === "H") {
              index += 2;
              break;
            }
          }
          // Such as `laugh`, `McLaughlin`, `cough`, `gough`, `rough`, `tough`.
          if (index > 2 && previous === "U" && at(G_FOR_F, char(index - 3))) {
            primary += "F";
            secondary += "F";
          } else if (index > 0 && previous !== "I") {
            primary += "K";
            secondary += "K";
          }
          index += 2;
          break;
        }
        if (next === "N") {
          if (index === 1 && at(VOWELS, characters[0]) && !isSlavoGermanic) {
            primary += "KN";
            secondary += "N";
          } else if (normalized.slice(index + 2, index + 4) !== "EY" && normalized.slice(index + 1) !== "Y" && !isSlavoGermanic) {
            // Not like `Cagney`.
            primary += "N";
            secondary += "KN";
          } else {
            primary += "KN";
            secondary += "KN";
          }
          index += 2;
          break;
        }
        // Such as `Tagliaro`.
        if (normalized.slice(index + 1, index + 3) === "LI" && !isSlavoGermanic) {
          primary += "KL";
          secondary += "L";
          index += 2;
          break;
        }
        // -ges-, -gep-, -gel- at the beginning.
        if (index === 0 && INITIAL_G_FOR_KJ.test(normalized.slice(1, 3))) {
          primary += "K";
          secondary += "J";
          index += 2;
          break;
        }
        // -ger-, -gy-.
        if (
          (normalized.slice(index + 1, index + 3) === "ER" &&
            previous !== "I" &&
            previous !== "E" &&
            !INITIAL_ANGER_EXCEPTION.test(normalized.slice(0, 6))) ||
          (next === "Y" && !at(G_FOR_KJ, previous))
        ) {
          primary += "K";
          secondary += "J";
          index += 2;
          break;
        }
        // Italian such as `biaggi`.
        if (next === "E" || next === "I" || next === "Y" || ((previous === "A" || previous === "O") && next === "G" && nextnext === "I")) {
          if (normalized.slice(index + 1, index + 3) === "ET" || isGermanic) {
            // Obvious Germanic.
            primary += "K";
            secondary += "K";
          } else {
            primary += "J";
            // Always soft with a French ending.
            secondary += normalized.slice(index + 1, index + 5) === "IER " ? "J" : "K";
          }
          index += 2;
          break;
        }
        if (next === "G") index++;
        index++;
        primary += "K";
        secondary += "K";
        break;
      case "H":
        // Only keep if first and before a vowel, or between two vowels.
        if (at(VOWELS, next) && (index === 0 || at(VOWELS, previous))) {
          primary += "H";
          secondary += "H";
          index++;
        }
        index++;
        break;
      case "J":
        // Obvious Spanish: `jose`, `San Jacinto`.
        if (normalized.slice(index, index + 4) === "JOSE" || normalized.slice(0, 4) === "SAN ") {
          if (normalized.slice(0, 4) === "SAN " || (index === 0 && char(index + 4) === " ")) {
            primary += "H";
            secondary += "H";
          } else {
            primary += "J";
            secondary += "H";
          }
          index++;
          break;
        }
        if (index === 0) {
          primary += "J";
          // Such as `Yankelovich` or `Jankelowicz`.
          secondary += "A";
        } else if (!isSlavoGermanic && (next === "A" || next === "O") && at(VOWELS, previous)) {
          // Spanish pronunciation of such as `bajador`.
          primary += "J";
          secondary += "H";
        } else if (index === last) {
          primary += "J";
        } else if (previous !== "S" && previous !== "K" && previous !== "L" && !at(J_FOR_J_EXCEPTION, next)) {
          primary += "J";
          secondary += "J";
        } else if (next === "J") {
          index++;
        }
        index++;
        break;
      case "K":
        if (next === "K") index++;
        primary += "K";
        secondary += "K";
        index++;
        break;
      case "L":
        if (next === "L") {
          // Spanish such as `cabrillo`, `gallegos`.
          if (
            (index === length - 3 &&
              ((previous === "A" && nextnext === "E") || (previous === "I" && (nextnext === "O" || nextnext === "A")))) ||
            (previous === "A" &&
              nextnext === "E" &&
              (characters[last] === "A" || characters[last] === "O" || ALLE.test(normalized.slice(last - 1, length))))
          ) {
            primary += "L";
            index += 2;
            break;
          }
          index++;
        }
        primary += "L";
        secondary += "L";
        index++;
        break;
      case "M":
        // Such as `dumb`, `thumb`.
        if (next === "M" || (previous === "U" && next === "B" && (index + 1 === last || normalized.slice(index + 2, index + 4) === "ER"))) {
          index++;
        }
        index++;
        primary += "M";
        secondary += "M";
        break;
      case "N":
        if (next === "N") index++;
        index++;
        primary += "N";
        secondary += "N";
        break;
      case "Ñ":
        index++;
        primary += "N";
        secondary += "N";
        break;
      case "P":
        if (next === "H") {
          primary += "F";
          secondary += "F";
          index += 2;
          break;
        }
        // Also account for `campbell` and `raspberry`.
        if (next === "P" || next === "B") index++;
        index++;
        primary += "P";
        secondary += "P";
        break;
      case "Q":
        if (next === "Q") index++;
        index++;
        primary += "K";
        secondary += "K";
        break;
      case "R":
        // French such as `Rogier`, but exclude `Hochmeier`.
        if (
          index === last &&
          !isSlavoGermanic &&
          previous === "E" &&
          char(index - 2) === "I" &&
          char(index - 4) !== "M" &&
          char(index - 3) !== "E" &&
          char(index - 3) !== "A"
        ) {
          secondary += "R";
        } else {
          primary += "R";
          secondary += "R";
        }
        if (next === "R") index++;
        index++;
        break;
      case "S":
        // Special cases `island`, `isle`, `carlisle`, `carlysle`.
        if (next === "L" && (previous === "I" || previous === "Y")) {
          index++;
          break;
        }
        // Special case `sugar-`.
        if (index === 0 && normalized.slice(1, 5) === "UGAR") {
          primary += "X";
          secondary += "S";
          index++;
          break;
        }
        if (next === "H") {
          if (H_FOR_S.test(normalized.slice(index + 1, index + 5))) {
            // Germanic.
            primary += "S";
            secondary += "S";
          } else {
            primary += "X";
            secondary += "X";
          }
          index += 2;
          break;
        }
        if (next === "I" && (nextnext === "O" || nextnext === "A")) {
          if (isSlavoGermanic) {
            primary += "S";
            secondary += "S";
          } else {
            primary += "S";
            secondary += "X";
          }
          index += 3;
          break;
        }
        // German and anglicizations, such as `Smith` matching `Schmidt`, `snider` matching `Schneider`;
        // also -sz- in Slavic languages (Hungarian pronounces it `s`).
        if (next === "Z" || (index === 0 && (next === "L" || next === "M" || next === "N" || next === "W"))) {
          primary += "S";
          secondary += "X";
          if (next === "Z") index++;
          index++;
          break;
        }
        if (next === "C") {
          // Schlesinger's rule.
          if (nextnext === "H") {
            subvalue = normalized.slice(index + 3, index + 5);
            // Dutch origin, such as `school`, `schooner`.
            if (DUTCH_SCH.test(subvalue)) {
              if (subvalue === "ER" || subvalue === "EN") {
                // Such as `schermerhorn`, `schenker`.
                primary += "X";
                secondary += "SK";
              } else {
                primary += "SK";
                secondary += "SK";
              }
              index += 3;
              break;
            }
            if (index === 0 && !at(VOWELS, char(3)) && char(3) !== "W") {
              primary += "X";
              secondary += "S";
            } else {
              primary += "X";
              secondary += "X";
            }
            index += 3;
            break;
          }
          if (nextnext === "I" || nextnext === "E" || nextnext === "Y") {
            primary += "S";
            secondary += "S";
            index += 3;
            break;
          }
          primary += "SK";
          secondary += "SK";
          index += 3;
          break;
        }
        subvalue = normalized.slice(index - 2, index);
        // French such as `resnais`, `artois`.
        if (index === last && (subvalue === "AI" || subvalue === "OI")) {
          secondary += "S";
        } else {
          primary += "S";
          secondary += "S";
        }
        if (next === "S") index++;
        index++;
        break;
      case "T":
        if (next === "I" && nextnext === "O" && char(index + 3) === "N") {
          primary += "X";
          secondary += "X";
          index += 3;
          break;
        }
        if ((next === "I" && nextnext === "A") || (next === "C" && nextnext === "H")) {
          primary += "X";
          secondary += "X";
          index += 3;
          break;
        }
        if (next === "H" || (next === "T" && nextnext === "H")) {
          // Special case `Thomas`, `Thames`, or Germanic.
          if (isGermanic || ((nextnext === "O" || nextnext === "A") && char(index + 3) === "M")) {
            primary += "T";
            secondary += "T";
          } else {
            primary += "0";
            secondary += "T";
          }
          index += 2;
          break;
        }
        if (next === "T" || next === "D") index++;
        index++;
        primary += "T";
        secondary += "T";
        break;
      case "V":
        if (next === "V") index++;
        primary += "F";
        secondary += "F";
        index++;
        break;
      case "W":
        // Can also be in the middle of a word (initial is handled below).
        if (next === "R") {
          primary += "R";
          secondary += "R";
          index += 2;
          break;
        }
        if (index === 0) {
          if (at(VOWELS, next)) {
            // `Wasserman` should match `Vasserman`.
            primary += "A";
            secondary += "F";
          } else if (next === "H") {
            // `Uomo` should match `Womo`.
            primary += "A";
            secondary += "A";
          }
        }
        // `Arnow` should match `Arnoff`.
        if (
          ((previous === "E" || previous === "O") &&
            next === "S" &&
            nextnext === "K" &&
            (char(index + 3) === "I" || char(index + 3) === "Y")) ||
          normalized.slice(0, 3) === "SCH" ||
          (index === last && at(VOWELS, previous))
        ) {
          secondary += "F";
          index++;
          break;
        }
        // Polish such as `Filipowicz`.
        if (next === "I" && (nextnext === "C" || nextnext === "T") && char(index + 3) === "Z") {
          primary += "TS";
          secondary += "FX";
          index += 4;
          break;
        }
        index++;
        break;
      case "X":
        // French such as `breaux`.
        if (!(index === last && previous === "U" && (char(index - 2) === "A" || char(index - 2) === "O"))) {
          primary += "KS";
          secondary += "KS";
        }
        if (next === "C" || next === "X") index++;
        index++;
        break;
      case "Z":
        // Chinese pinyin such as `Zhao`.
        if (next === "H") {
          primary += "J";
          secondary += "J";
          index += 2;
          break;
        } else if ((next === "Z" && (nextnext === "A" || nextnext === "I" || nextnext === "O")) || (isSlavoGermanic && index > 0 && previous !== "T")) {
          primary += "S";
          secondary += "TS";
        } else {
          primary += "S";
          secondary += "S";
        }
        if (next === "Z") index++;
        index++;
        break;
      default:
        index++;
    }
  }

  return [primary, secondary];
}
