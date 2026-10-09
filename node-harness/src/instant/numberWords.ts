/**
 * Spoken EN/DE number words → digits, for speech transcripts and typed text
 * ("three hundred and forty" → 340, "zweiunddreißig" → 32,
 * "zwei hoch sechzehn minus tausend" → "2 hoch 16 minus 1000").
 *
 * Pure string functions; no locale data. German compounds are decomposed
 * around "tausend" and "hundert"; English phrases are parsed with a small
 * state machine so adjacent numbers ("five six") never merge into a sum.
 */

const EN_SMALL: Readonly<Record<string, number>> = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19,
};
const EN_TENS: Readonly<Record<string, number>> = {
  twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90,
};
const EN_SCALES: Readonly<Record<string, number>> = { thousand: 1e3, million: 1e6, billion: 1e9, trillion: 1e12 };

type EnKind = "none" | "small" | "teen" | "tens" | "hundred" | "scale";

function enValue(word: string | undefined): { kind: "small" | "teen" | "tens" | "hundred" | "scale"; value: number } | null {
  if (word === undefined) return null;
  const small = EN_SMALL[word];
  if (small !== undefined) return { kind: small < 10 ? "small" : "teen", value: small };
  const tens = EN_TENS[word];
  if (tens !== undefined) return { kind: "tens", value: tens };
  if (word === "hundred") return { kind: "hundred", value: 100 };
  const scale = EN_SCALES[word];
  if (scale !== undefined) return { kind: "scale", value: scale };
  return null;
}

/** Splits into words and the separators between them (kept verbatim). */
function tokenize(text: string): string[] {
  return text.split(/(\s+)/).filter((part) => part !== "");
}

function isSpace(token: string | undefined): boolean {
  return token !== undefined && /^\s+$/.test(token);
}

/** "thirty-two" → ["thirty", "two"] when both halves are number words. */
function splitHyphenated(tokens: string[]): string[] {
  const out: string[] = [];
  for (const token of tokens) {
    const halves = token.split("-");
    if (halves.length === 2 && halves.every((half) => enValue(half.toLowerCase()) !== null)) {
      out.push(halves[0]!, " ", halves[1]!);
    } else {
      out.push(token);
    }
  }
  return out;
}

/** Index of the next word token after `index` (skipping one separator), or -1. */
function nextWord(tokens: string[], index: number): number {
  let i = index + 1;
  if (isSpace(tokens[i])) i++;
  return i < tokens.length ? i : -1;
}

/**
 * English number phrases → digits. Recognises units, teens, tens, "hundred",
 * scales up to trillion, "and" joiners after hundred/scales, "point" decimals
 * and "a hundred/thousand/million". Everything else is copied unchanged.
 */
export function enWordsToDigits(text: string): string {
  const tokens = splitHyphenated(tokenize(text));
  const out: string[] = [];
  let i = 0;
  while (i < tokens.length) {
    const token = tokens[i]!;
    const lower = token.toLowerCase();
    const startsWithA = lower === "a" && ["hundred", "thousand", "million", "billion", "trillion"].includes(tokens[nextWord(tokens, i)]?.toLowerCase() ?? "");
    // A bare scale ("3 million", "hundred") is left to applyDigitScales / the German pass.
    const first = enValue(lower);
    const canStart = first !== null && first.kind !== "hundred" && first.kind !== "scale";
    if (!canStart && !startsWithA) {
      out.push(token);
      i++;
      continue;
    }

    let total = 0;
    let group = 0;
    let kind: EnKind = "none";
    let lastScale = Number.POSITIVE_INFINITY;
    let decimals = "";
    let end = i; // last consumed token index
    let j = i;
    if (startsWithA) {
      group = 1;
      kind = "small";
      end = j;
      j = nextWord(tokens, j);
    }
    while (j >= 0 && j < tokens.length) {
      const word = tokens[j]!.toLowerCase();
      const value = enValue(word);
      if (value) {
        let accepted = true;
        switch (value.kind) {
          case "small":
          case "teen":
            if (kind === "none" || kind === "hundred" || kind === "scale" || (kind === "tens" && value.kind === "small")) {
              group += value.value;
              kind = value.kind;
            } else accepted = false;
            break;
          case "tens":
            if (kind === "none" || kind === "hundred" || kind === "scale") {
              group += value.value;
              kind = "tens";
            } else accepted = false;
            break;
          case "hundred":
            if ((kind === "small" || kind === "teen") && group > 0 && group < 100) { group *= 100; kind = "hundred"; }
            else accepted = false;
            break;
          case "scale":
            if (value.value < lastScale && group > 0) {
              total += (group || 1) * value.value;
              group = 0;
              lastScale = value.value;
              kind = "scale";
            } else accepted = false;
            break;
        }
        if (!accepted) break;
        end = j;
        j = nextWord(tokens, j);
        continue;
      }
      if (word === "and" && (kind === "hundred" || kind === "scale")) {
        const after = enValue(tokens[nextWord(tokens, j)]?.toLowerCase());
        if (after && (after.kind === "small" || after.kind === "teen" || after.kind === "tens")) {
          j = nextWord(tokens, j);
          continue;
        }
      }
      if (word === "point" && kind !== "none") {
        let k = nextWord(tokens, j);
        let digits = "";
        let last = -1;
        while (k >= 0) {
          const digit = EN_SMALL[tokens[k]!.toLowerCase()];
          if (digit === undefined || digit > 9) break;
          digits += String(digit);
          last = k;
          k = nextWord(tokens, k);
        }
        if (digits) {
          decimals = digits;
          end = last;
        }
      }
      break;
    }
    out.push(decimals ? `${total + group}.${decimals}` : String(total + group));
    i = end + 1;
  }
  return out.join("");
}

// ---------------------------------------------------------------- German

const DE_UNITS: Readonly<Record<string, number>> = {
  null: 0, ein: 1, eins: 1, eine: 1, einen: 1, einem: 1, einer: 1, zwei: 2, zwo: 2, drei: 3, vier: 4, "fünf": 5, sechs: 6, sieben: 7, acht: 8, neun: 9,
};
const DE_TEENS: Readonly<Record<string, number>> = {
  zehn: 10, elf: 11, "zwölf": 12, dreizehn: 13, vierzehn: 14, "fünfzehn": 15, sechzehn: 16, siebzehn: 17, achtzehn: 18, neunzehn: 19,
};
const DE_TENS: Readonly<Record<string, number>> = {
  zwanzig: 20, "dreißig": 30, vierzig: 40, "fünfzig": 50, sechzig: 60, siebzig: 70, achtzig: 80, neunzig: 90,
};
const DE_COMPOUND = /^(ein|zwei|drei|vier|fünf|sechs|sieben|acht|neun)und(zwanzig|dreißig|vierzig|fünfzig|sechzig|siebzig|achtzig|neunzig)$/;

/** German words that are also English words; converted only when the utterance is German. */
export const DE_EN_COLLISIONS: ReadonlySet<string> = new Set(["elf", "null", "ein", "eine", "einen", "einem", "einer", "acht"]);

function deBelow100(word: string): number | null {
  const direct = DE_UNITS[word] ?? DE_TEENS[word] ?? DE_TENS[word];
  if (direct !== undefined) return direct;
  const compound = DE_COMPOUND.exec(word);
  if (!compound) return null;
  return (DE_UNITS[compound[1]!] ?? 0) + (DE_TENS[compound[2]!] ?? 0);
}

/**
 * "<n>hundert<m>". `maxHundreds` 99 admits the standalone teen/tens hundreds
 * German uses for years and amounts ("neunzehnhundertvierundachtzig" 1984,
 * "zwölfhundert" 1200); next to "tausend" only 1–9 hundreds are valid.
 */
function deBelow1000(word: string, maxHundreds = 9): number | null {
  if (word === "") return 0;
  const h = word.indexOf("hundert");
  if (h < 0) return deBelow100(word);
  const left = word.slice(0, h);
  const right = word.slice(h + 7).replace(/^und/, "");
  const l = left === "" ? 1 : deBelow100(left);
  const r = right === "" ? 0 : deBelow100(right);
  return l === null || r === null || l < 1 || l > maxHundreds ? null : l * 100 + r;
}

/** Folds spoken/typed spellings: ss → ß, ae/oe/ue → umlauts (only used for number lookup). */
function foldGerman(word: string): string {
  return word.toLowerCase().replace(/ss/g, "ß").replace(/ae/g, "ä").replace(/oe/g, "ö").replace(/ue/g, "ü");
}

/** One German number word (incl. compounds below one million) → value, else null. */
export function deWordToNumber(word: string): number | null {
  const w = foldGerman(word);
  if (!/^[a-zäöüß]+$/.test(w)) return null;
  const t = w.indexOf("tausend");
  if (t >= 0) {
    const left = w.slice(0, t);
    const right = w.slice(t + 7).replace(/^und/, "");
    const l = left === "" ? 1 : deBelow1000(left);
    const r = deBelow1000(right);
    return l === null || r === null || l < 1 ? null : l * 1000 + r;
  }
  return deBelow1000(w, 99);
}

const DE_SCALES: Readonly<Record<string, number>> = { million: 1e6, millionen: 1e6, milliarde: 1e9, milliarden: 1e9 };

/**
 * German number words → digits: single compound words, "<n> millionen <m>",
 * and "komma" decimals ("zwei komma fünf" → "2.5"). Words in `skip` are left
 * alone (used for EN/DE collisions in English utterances).
 */
export function deWordsToDigits(text: string, skip: ReadonlySet<string> = new Set()): string {
  const tokens = tokenize(text).map((token) => {
    const lower = token.toLowerCase();
    if (isSpace(token) || skip.has(lower) || DE_SCALES[lower] !== undefined) return token;
    const value = deWordToNumber(lower);
    return value === null ? token : String(value);
  });
  // "<n> millionen [<m>]" (n, m already digits)
  const merged: string[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i]!;
    const scale = DE_SCALES[token.toLowerCase()];
    const previous = merged.length >= 2 && isSpace(merged[merged.length - 1]) ? merged[merged.length - 2] : undefined;
    if (scale !== undefined && previous !== undefined && /^\d+$/.test(previous)) {
      let value = Number(previous) * scale;
      const next = nextWord(tokens, i);
      const tail = next >= 0 ? tokens[next]! : "";
      if (/^\d+$/.test(tail) && Number(tail) < scale) {
        value += Number(tail);
        i = next;
      }
      merged.splice(merged.length - 2, 2, String(value));
      continue;
    }
    merged.push(token);
  }
  return merged.join("").replace(/(\d+)\s+komma\s+(\d+)/gi, "$1.$2");
}

const DIGIT_SCALES: Readonly<Record<string, number>> = {
  hundred: 100, thousand: 1e3, million: 1e6, billion: 1e9, trillion: 1e12, hundert: 100, tausend: 1e3, millionen: 1e6, milliarde: 1e9, milliarden: 1e9,
};

/** "10 thousand" → 10000, "1.5 million" → 1500000, "3 millionen" → 3000000. */
export function applyDigitScales(text: string): string {
  return text.replace(/(\d+(?:\.\d+)?)\s+(hundred|thousand|million|billion|trillion|hundert|tausend|millionen|milliarden|milliarde)\b/gi, (match, digits: string, word: string) => {
    const scale = DIGIT_SCALES[word.toLowerCase()];
    if (scale === undefined) return match;
    return String(Number((Number(digits) * scale).toPrecision(15)));
  });
}
