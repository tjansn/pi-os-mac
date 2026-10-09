import { LEXICON_CHUNKS } from "./lexiconData.js";

/**
 * Common-word check for the spoken app matcher's dictionary-word guard (DESIGN4 §5.2): a heard name that
 * is itself an ordinary English or German word ("feather", "nation", "Mehl", "Telegramm") is never opened
 * on sound alone, and its sound-alikes must share its first sound. The word list is the generated
 * `lexiconData.ts` (frequent EN + DE words from Tatoeba, CC BY 2.0 FR). The set is built once, on the
 * first check or on `warmLexicon()`, in a few milliseconds; nothing here does I/O or logs.
 */

let words: Set<string> | null = null;

function lexicon(): Set<string> {
  if (words) return words;
  const set = new Set<string>();
  for (const chunk of LEXICON_CHUNKS) for (const word of chunk.split(" ")) if (word) set.add(word);
  words = set;
  return set;
}

/** Builds the word set now (off the first spoken final); idempotent. */
export function warmLexicon(): void {
  lexicon();
}

/**
 * True when a single folded word (a-z; "telegramm", not "Telegramm") is a common EN/DE word, including
 * English plurals of listed words ("pages" → "page", "batteries" → "battery"). Words shorter than three
 * letters are never common: they carry too little sound to guard.
 */
export function isCommonWord(word: string): boolean {
  const w = word.toLowerCase();
  if (w.length < 3 || w.includes(" ")) return false;
  const set = lexicon();
  if (set.has(w)) return true;
  if (w.endsWith("ies") && set.has(`${w.slice(0, -3)}y`)) return true;
  if (w.endsWith("es") && set.has(w.slice(0, -2))) return true;
  return w.endsWith("s") && set.has(w.slice(0, -1));
}
