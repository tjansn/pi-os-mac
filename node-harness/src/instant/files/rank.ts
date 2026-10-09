import type { FileCandidate } from "../../contracts/launcher.js";
import type { MsRange } from "../engines/dates.js";
import { FILE_SYNONYMS } from "./query.js";

/**
 * Node-side ranking of host file-search candidates (raycast research §12.3):
 *
 *   0.65·name + (range ? 0.10 : 0.25)·exp(−age/45 d) + 0.15·[kind] + 0.05·[Desktop|Documents|Downloads|iCloud]
 *   + min(0.1, log2(1+useCount)/50) + 0.10·[name mentions the requested month/year]
 *
 * Trash, node_modules, .git, ~/Library (except iCloud Drive), hidden paths and
 * bundle internals are never returned. Paths are used for ranking/display
 * only and are never logged.
 */

export interface RankRequest {
  terms: readonly string[];
  contentType?: string;
  range?: MsRange;
}

export interface RankedFile extends FileCandidate {
  score: number;
}

export interface RankResult {
  files: RankedFile[];
  /** The date range matched nothing, so all name hits are shown. */
  relaxed: boolean;
}

const DAY_MS = 86_400_000;

const EXCLUDED: readonly RegExp[] = [
  /\/node_modules\//,
  /\/\.git\//,
  /\/\.Trash(?:es)?(?:\/|$)/,
  /^\/Users\/[^/]+\/Library\/(?!Mobile Documents\/com~apple~CloudDocs\/)/,
  /^\/(?:System|Library|private|usr|bin|sbin|var|opt|Volumes\/[^/]+\/\.Trashes)\//,
  /\/\.[^/]+(?:\/|$)/,
  /\.(?:app|photoslibrary|musiclibrary|bundle|framework|plugin|kext|xcassets)\//,
];
const PREFERRED: readonly RegExp[] = [/\/Desktop\//, /\/Documents\//, /\/Downloads\//, /\/Mobile Documents\/com~apple~CloudDocs\//];

/** UTI families for the kind bonus (the host already filtered by content type tree). */
const KIND_FAMILIES: Readonly<Record<string, RegExp>> = {
  "public.image": /^(?:public\.(?:image|png|jpeg|heic|heif|tiff|webp|svg-image)|com\.compuserve\.gif|com\.apple\.icns|org\.webmproject\.webp)$/,
  "public.presentation": /^(?:public\.presentation|com\.apple\.(?:iwork\.keynote\.sffkey|keynote\.key)|com\.microsoft\.powerpoint\.ppt|org\.openxmlformats\.presentationml\.presentation)$/,
  "public.spreadsheet": /^(?:public\.spreadsheet|public\.comma-separated-values-text|com\.apple\.iwork\.numbers\.sffnumbers|com\.microsoft\.excel\.xls|org\.openxmlformats\.spreadsheetml\.sheet)$/,
  "public.movie": /^(?:public\.(?:movie|mpeg-4|avi)|com\.apple\.quicktime-movie)$/,
  "public.audio": /^(?:public\.(?:audio|mp3|aiff-audio)|com\.apple\.m4a-audio|com\.microsoft\.waveform-audio)$/,
};

const MONTH_NAMES: readonly (readonly string[])[] = [
  ["january", "januar", "jan"], ["february", "februar", "feb"], ["march", "marz", "maerz", "mar"], ["april", "apr"], ["may", "mai"],
  ["june", "juni", "jun"], ["july", "juli", "jul"], ["august", "aug"], ["september", "sept", "sep"], ["october", "oktober", "oct", "okt"],
  ["november", "nov"], ["december", "dezember", "dec", "dez"],
];

function fold(text: string): string {
  return text.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ß/g, "ss").toLowerCase();
}

function tokens(text: string): string[] {
  return fold(text).split(/[^a-z0-9]+/).filter(Boolean);
}

/** Synonyms keyed and valued in folded form ("präsentation" → "prasentation"). */
const SYNONYMS: ReadonlyMap<string, readonly string[]> = new Map(
  Object.entries(FILE_SYNONYMS).map(([term, synonyms]) => [fold(term), synonyms.map(fold)]),
);

export function isExcludedPath(path: string): boolean {
  return EXCLUDED.some((pattern) => pattern.test(path));
}

/**
 * 1.0 exact basename · 0.9 basename prefix · else 0.8 × the weakest term:
 * word prefix 1, synonym word prefix 0.75, substring (≥ 4 chars) 0.55;
 * any term missing → 0.
 */
export function nameScore(terms: readonly string[], fileName: string): number {
  const base = fileName.replace(/\.[^./]{1,8}$/, "");
  const query = terms.flatMap((term) => tokens(term));
  const words = tokens(base);
  if (!query.length || !words.length) return 0;
  const flat = words.join(" ");
  const q = query.join(" ");
  if (flat === q) return 1;
  if (flat.startsWith(q)) return 0.9;
  const compact = words.join("");
  let weakest = 1;
  for (const term of query) {
    let best = 0;
    if (words.some((word) => word.startsWith(term))) best = 1;
    else if ((SYNONYMS.get(term) ?? []).some((synonym) => words.some((word) => word.startsWith(synonym)))) best = 0.75;
    else if (term.length >= 4 && compact.includes(term)) best = 0.55;
    if (best === 0) return 0;
    weakest = Math.min(weakest, best);
  }
  return 0.8 * weakest;
}

function kindMatches(candidate: FileCandidate, contentType: string | undefined): boolean {
  if (!contentType) return false;
  if (contentType === "public.folder") return candidate.isDirectory && !candidate.isPackage;
  if (candidate.contentType === contentType) return true;
  const family = KIND_FAMILIES[contentType];
  return family !== undefined && candidate.contentType !== undefined && family.test(candidate.contentType);
}

function nameMentionsRange(name: string, range: MsRange): boolean {
  const start = new Date(range.fromMs);
  const year = String(start.getFullYear());
  const month = start.getMonth();
  const mm = String(month + 1).padStart(2, "0");
  const words = tokens(name);
  return (words.includes(year) && (words.includes(mm) || words.includes(String(month + 1))))
    || words.some((word) => MONTH_NAMES[month]!.includes(word))
    || name.includes(`${year}${mm}`) || name.includes(`${year}-${mm}`);
}

function inRange(candidate: FileCandidate, range: MsRange): boolean {
  return [candidate.createdMs, candidate.modifiedMs].some((ms) => ms !== undefined && ms >= range.fromMs && ms < range.toMs);
}

function score(candidate: FileCandidate, name: number, req: RankRequest, nowMs: number, dated: boolean): number {
  const touched = Math.max(candidate.lastUsedMs ?? 0, candidate.modifiedMs ?? 0);
  const recency = touched ? Math.exp(-Math.max(0, nowMs - touched) / (45 * DAY_MS)) : 0;
  const kind = kindMatches(candidate, req.contentType) ? 0.15 : 0;
  const location = PREFERRED.some((pattern) => pattern.test(candidate.path)) ? 0.05 : 0;
  const use = Math.min(0.1, Math.log2(1 + Math.max(0, candidate.useCount ?? 0)) / 50);
  const mention = dated && req.range && nameMentionsRange(candidate.name, req.range) ? 0.1 : 0;
  return 0.65 * name + (dated ? 0.1 : 0.25) * recency + kind + location + use + mention;
}

export function rankFiles(candidates: readonly FileCandidate[], req: RankRequest, nowMs: number): RankResult {
  const named: { candidate: FileCandidate; name: number }[] = [];
  for (const candidate of candidates) {
    if (typeof candidate?.path !== "string" || typeof candidate.name !== "string" || isExcludedPath(candidate.path)) continue;
    const name = nameScore(req.terms, candidate.name);
    if (name > 0) named.push({ candidate, name });
  }
  const range = req.range;
  const dated = range ? named.filter(({ candidate }) => inRange(candidate, range)) : named;
  const relaxed = range !== undefined && dated.length === 0 && named.length > 0;
  const pool = relaxed ? named : dated;
  const files = pool
    .map(({ candidate, name }) => ({ ...candidate, score: score(candidate, name, req, nowMs, range !== undefined && !relaxed) }))
    .sort((a, b) => b.score - a.score || (b.modifiedMs ?? 0) - (a.modifiedMs ?? 0));
  return { files, relaxed };
}
