/**
 * Voice corpus evaluation (DESIGN4 §9.1, §9.2): scores recognizer output in the shared bench JSONL schema
 * against the gold labels of the r3/asr corpus, through the REAL instant dispatcher (the voice decision
 * pipeline: hypotheses arbitration, the spoken matcher, did-you-mean, confirm, the check gate) and, for the
 * cross-take learning check, the real DictionaryStore and learn lane in a temporary directory.
 *
 * It is a port of r3/asr/eval/score.mjs (WER, keyword and intent per recognizer) and r3/design4/stack*.mts
 * (stacks, "at once", "with one Return", wrong acts) plus r3/design4/repeat.mts (one correction on clean
 * audio, tested on another take). test/voiceCorpus.test.ts imports these functions and gates on them.
 *
 *   npx tsx scripts/voice-eval.mts [options] <bench.jsonl>...      one bench run (files are merged per take)
 *     --corpus <corpus.json>   gold (default test/fixtures/voice/corpus.json)
 *     --stack <list>           asis,phaseA,phaseB,single,legacy (default: all that the run's sources allow)
 *     --learn <from:to>        cross-take learning per recognizer, e.g. clean:ptt2
 *     --details                per-item outcome classes (ids, categories; no text, no app choices)
 *     --show-content           --details plus each item's decision signature and gold label (app choices; never
 *                              transcripts; synthetic corpora only)
 *   npx tsx scripts/voice-eval.mts import-r3 --r3 <dir> [--lid <lid-map.json>] --out <dir>
 *                            regenerates test/fixtures/voice/{corpus.json,bench/*.jsonl} from r3/asr
 *
 * Output is content-free by default (counts and percentages only): bench files may hold Tom's journal
 * transcripts one day, and transcripts, heard text and app choices are never printed without
 * --show-content. Nothing here performs effects, calls a model or touches the network.
 *
 * Bench JSONL (one line per utterance × audio variant × recognizer; S5's pi-os-voice-bench writes it):
 *   {"id": string (WAV basename = corpus id), "variant": "clean"|"tail"|"room"|"ptt2"|string,
 *    "source": recognizer id ("parakeet-v3", "apple-dt/en-US", "apple-dt/de-DE", "apple-st/<locale>", …),
 *    "role": "primary"|"peer"|"secondary", "text": string ("" when the take produced nothing),
 *    "confidence"?: 0..1, "minConfidence"?: 0..1, "nbest"?: string[] (≤ 2), "finalMs"?: number (key-up → final),
 *    "firstPartialMs"?: number, "locale"?: BCP 47 (the hypothesis language; optional, additive)}
 * Lines of one take are in the arbiter's order (first tier best first, then secondaries).
 */
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { bindingToHostAction, type CardSpec } from "../src/contracts/cards.js";
import { NO_CONTEXT_SCORER } from "../src/contracts/context.js";
import { NO_DICTIONARY, type DictionaryLearnRequest, type DictionaryLookup } from "../src/contracts/dictionary.js";
import {
  INSTANT_ACCEPTS, INSTANT_LIMITS, isRecognizerId, LOCALE_PATTERN,
  type InstantRequest, type InstantResponse, type VoiceHypothesis, type VoiceHypothesisRole,
} from "../src/contracts/instant.js";
import type { AppRecord, FileSearchRequest } from "../src/contracts/launcher.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { DictionaryStore, nonCountingLookup } from "../src/instant/dictionary.js";
import { createInstantDispatcher, type InstantDispatcher } from "../src/instant/dispatcher.js";
import { createLearnLane, learnFromGesture } from "../src/instant/learned.js";
import { isCommonWord } from "../src/instant/lexicon.js";
import { DE_EN_COLLISIONS, deWordsToDigits, enWordsToDigits } from "../src/instant/numberWords.js";
import { InMemoryTakeMemo, takeDetailsOf, takeRecordFor } from "../src/instant/takeMemo.js";

const HERE = import.meta.dirname;
export const VOICE_FIXTURES = join(HERE, "..", "test", "fixtures", "voice");
/** The categories DESIGN4 calls Tom-mix: German-accented EN (F, G), German (H), mixed DE/EN (I). */
export const TOM_MIX = ["F", "G", "H", "I"] as const;
/** The evaluation clock (gold labels depend on it: "how many days until Christmas"). */
export const EVAL_NOW = new Date(2026, 9, 7, 10, 0);

// ---------------------------------------------------------------------------------------------
// The fixture app index: instantSpoken.test.ts's 104-app table (r3/mapping apps.json without Tom's
// personal apps), read from its source so it is not duplicated (importing a test file runs its tests).

const SPOKEN_TESTS = join(HERE, "..", "test", "instantSpoken.test.ts");
let spokenSource: string | undefined;

/** One top-level `const NAME… = <literal>;` table of test/instantSpoken.test.ts, evaluated as data. */
export function spokenTable<T>(name: string): T {
  spokenSource ??= readFileSync(SPOKEN_TESTS, "utf8");
  const source = spokenSource;
  const start = source.search(new RegExp(`^const ${name}\\b`, "m"));
  if (start < 0) throw new Error(`instantSpoken.test.ts declares no table ${name}`);
  let i = source.indexOf("= ", start) + 2;
  const from = i;
  let depth = 0;
  for (; i < source.length; i++) {
    const c = source[i]!;
    if (c === "\"" || c === "'" || c === "`") {
      for (i++; i < source.length && source[i] !== c; i++) if (source[i] === "\\") i++;
      continue;
    }
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (c === ";" && depth === 0) break;
  }
  return Function(`"use strict"; return (${source.slice(from, i)});`)() as T;
}

type AppRow = readonly [bundleId: string, name: string, dir: string, aliases?: readonly string[], running?: boolean];
let fixtureAppsCache: AppRecord[] | undefined;

/** The 104-app fixture index (no personal app names; ~/Applications paths moved to /Applications). */
export function fixtureApps(): AppRecord[] {
  if (!fixtureAppsCache) {
    const dirs = spokenTable<Readonly<Record<string, string>>>("DIRS");
    fixtureAppsCache = spokenTable<readonly AppRow[]>("APP_ROWS").map(([bundleId, name, dir, aliases = [], running = false]) => ({
      bundleId, name, aliases: [...aliases], path: `${dirs[dir]}/${name}.app`, running,
    }));
  }
  return fixtureAppsCache;
}

// ---------------------------------------------------------------------------------------------
// Gold corpus (r3/asr corpus.json + the instant-able label)

export interface CorpusItem {
  id: string;
  /** A native EN · B DE-accented EN (several voices) · C German · D mixed · E phonetic DE-accented EN ·
   *  F/G/H/I the same with one natural German voice (Anna): F EN, G phonetic EN, H German, I mixed. */
  cat: string;
  lang: "en" | "de" | "mixed";
  voice: string;
  rate: number;
  /** What the speaker means (the label). */
  gold: string;
  /** What `say` was given (phonetic spellings for accents). */
  say: string;
  /** Intent keywords (score.mjs kwOK): every group must occur; `|` separates alternatives. */
  kw: string[];
  /**
   * The gold text's decision through the real dispatcher (a voice final): `app:<bundleId>`, `url:<host>`,
   * `sys:<op>`, `answer:<intent>`, `files`, `refuse`, or `none` (agent-bound). Instant-able ⇔ not `none`.
   */
  expect: string;
}

export interface CorpusFile { version: 1; items: CorpusItem[] }

export function loadCorpus(path = join(VOICE_FIXTURES, "corpus.json")): CorpusItem[] {
  const file = JSON.parse(readFileSync(path, "utf8")) as CorpusFile;
  if (file.version !== 1 || !Array.isArray(file.items)) throw new Error("corpus.json: version 1 with items expected");
  return file.items;
}

export const goldLocale = (item: Pick<CorpusItem, "lang">): string => (item.lang === "de" ? "de-DE" : "en-US");
export const isInstantItem = (item: Pick<CorpusItem, "expect">): boolean => item.expect !== "none";

// ---------------------------------------------------------------------------------------------
// Bench JSONL

export const BENCH_ROLES: readonly VoiceHypothesisRole[] = ["primary", "peer", "secondary"];
export interface BenchLine {
  id: string;
  variant: string;
  source: string;
  role: VoiceHypothesisRole;
  text: string;
  confidence?: number;
  minConfidence?: number;
  nbest?: string[];
  finalMs?: number;
  firstPartialMs?: number;
  locale?: string;
}

const ID = /^[A-Za-z0-9._-]{1,64}$/;
const VARIANT = /^[A-Za-z0-9._-]{1,32}$/;
const unit = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
const millis = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0;

/** One bench line, validated; a string is the (content-free) reason it was rejected. */
export function parseBenchLine(value: unknown): BenchLine | string {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return "not an object";
  const v = value as Record<string, unknown>;
  if (typeof v.id !== "string" || !ID.test(v.id)) return "id";
  if (typeof v.variant !== "string" || !VARIANT.test(v.variant)) return "variant";
  if (!isRecognizerId(v.source)) return "source";
  if (typeof v.role !== "string" || !(BENCH_ROLES as readonly string[]).includes(v.role)) return "role";
  if (typeof v.text !== "string" || v.text.length > 20_000) return "text";
  const line: BenchLine = { id: v.id, variant: v.variant, source: v.source, role: v.role as VoiceHypothesisRole, text: v.text };
  for (const key of ["confidence", "minConfidence"] as const) {
    if (v[key] === undefined || v[key] === null) continue;
    if (!unit(v[key])) return key;
    line[key] = v[key];
  }
  for (const key of ["finalMs", "firstPartialMs"] as const) {
    if (v[key] === undefined || v[key] === null) continue;
    if (!millis(v[key])) return key;
    line[key] = v[key];
  }
  if (v.nbest !== undefined && v.nbest !== null) {
    if (!Array.isArray(v.nbest) || v.nbest.length > 2 || !v.nbest.every((text) => typeof text === "string")) return "nbest";
    line.nbest = (v.nbest as string[]).filter((text) => text.trim());
  }
  if (v.locale !== undefined && v.locale !== null) {
    if (typeof v.locale !== "string" || !LOCALE_PATTERN.test(v.locale)) return "locale";
    line.locale = v.locale;
  }
  return line;
}

export interface BenchRun {
  lines: BenchLine[];
  /** Lines rejected by the schema (content-free reasons). */
  rejected: Record<string, number>;
  /** Lines whose (id, variant, source) was already given (the first one is kept). */
  duplicates: number;
}

/** Reads bench JSONL files as one run: takes are merged across files, first occurrence wins. */
export function readBench(paths: readonly string[]): BenchRun {
  const lines: BenchLine[] = [];
  const rejected: Record<string, number> = {};
  const seen = new Set<string>();
  let duplicates = 0;
  for (const path of paths) {
    for (const raw of readFileSync(path, "utf8").split("\n")) {
      if (!raw.trim()) continue;
      let parsed: BenchLine | string;
      try {
        parsed = parseBenchLine(JSON.parse(raw));
      } catch {
        parsed = "json";
      }
      if (typeof parsed === "string") {
        rejected[parsed] = (rejected[parsed] ?? 0) + 1;
        continue;
      }
      const key = `${parsed.variant}\u0000${parsed.id}\u0000${parsed.source}`;
      if (seen.has(key)) {
        duplicates++;
        continue;
      }
      seen.add(key);
      lines.push(parsed);
    }
  }
  return { lines, rejected, duplicates };
}

/** One utterance in one audio variant: its recognizer lines in bench order. */
export interface Take { id: string; variant: string; lines: BenchLine[] }

export function groupTakes(lines: readonly BenchLine[]): Take[] {
  const takes = new Map<string, Take>();
  for (const line of lines) {
    const key = `${line.variant}\u0000${line.id}`;
    let take = takes.get(key);
    if (!take) takes.set(key, (take = { id: line.id, variant: line.variant, lines: [] }));
    take.lines.push(line);
  }
  return [...takes.values()];
}

// ---------------------------------------------------------------------------------------------
// Stacks: what the host sends to /instant for one take (DESIGN4 §4.1, §4.2, §4.5)

/**
 * - `asis`: the lines with their recorded roles (the bench's own stack).
 * - `phaseA`: Apple only: the DictationTranscriber languages (else SpeechTranscriber) as peers + their n-best.
 * - `phaseB`: Parakeet primary; the Apple finals and n-best as secondaries; two-step final (Parakeet alone
 *   first; the take is done when that acts, answers or refuses).
 * - `single:<source>`: one recognizer as the primary (+ its n-best), as the learn lane replays a take.
 * - `legacy:<source>`: one recognizer's text without hypotheses (today's host).
 */
export type StackName = "asis" | "phaseA" | "phaseB" | `single:${string}` | `legacy:${string}`;

/** The /instant finals of one take (in order) and its locale hint; null when nothing was heard. */
export interface TakeAttempt {
  locale: string;
  finals: { text: string; hypotheses?: VoiceHypothesis[] }[];
}

const clip = (text: string): string => {
  const collapsed = text.replace(/\s+/g, " ").trim();
  return collapsed.length <= INSTANT_LIMITS.maxHypothesisChars ? collapsed : collapsed.slice(0, INSTANT_LIMITS.maxHypothesisChars).trim();
};
const roleTier = (role: VoiceHypothesisRole): number => (role === "primary" ? 0 : role === "peer" ? 1 : 2);
const isApple = (source: string, engine: "apple-dt" | "apple-st"): boolean => source.startsWith(`${engine}/`);

/** The hypotheses of `lines` with `roles` applied: first tier, then other finals, then n-best (VoiceArbiter.final). */
export function hypothesesOf(lines: readonly BenchLine[], roles: (line: BenchLine) => VoiceHypothesisRole | null): VoiceHypothesis[] {
  const chosen = lines.flatMap((line, index) => {
    const role = roles(line);
    return role && clip(line.text) ? [{ line, role, index }] : [];
  }).sort((a, b) => roleTier(a.role) - roleTier(b.role) || a.index - b.index);
  const out: VoiceHypothesis[] = chosen.map(({ line, role }) => ({
    text: clip(line.text), source: line.source, role,
    ...(line.confidence !== undefined ? { confidence: line.confidence } : {}),
    ...(line.minConfidence !== undefined ? { minConfidence: line.minConfidence } : {}),
    ...(line.locale ? { locale: line.locale } : {}),
  }));
  for (const { line } of chosen) {
    for (const alternative of line.nbest ?? []) {
      const text = clip(alternative);
      if (text) out.push({ text, source: line.source, role: "secondary", ...(line.locale ? { locale: line.locale } : {}) });
    }
  }
  return out.slice(0, INSTANT_LIMITS.maxHypotheses);
}

function attemptOf(hypotheses: VoiceHypothesis[], steps?: VoiceHypothesis[][]): TakeAttempt | null {
  if (!hypotheses.length) return null;
  const locale = hypotheses.find((hypothesis) => hypothesis.role !== "secondary")?.locale ?? hypotheses[0]!.locale ?? "en-US";
  const finals = [...(steps ?? []), hypotheses].map((list) => ({ text: list[0]!.text, hypotheses: list }));
  return { locale, finals };
}

export function buildAttempt(take: Take, stack: StackName): TakeAttempt | null {
  const lines = take.lines;
  if (stack === "asis") return attemptOf(hypothesesOf(lines, (line) => line.role));
  if (stack === "phaseA") {
    const engine = lines.some((line) => isApple(line.source, "apple-dt")) ? "apple-dt" : "apple-st";
    return attemptOf(hypothesesOf(lines, (line) => (isApple(line.source, engine) ? "peer" : null)));
  }
  if (stack === "phaseB") {
    const engine = lines.some((line) => isApple(line.source, "apple-dt")) ? "apple-dt" : "apple-st";
    const role = (line: BenchLine): VoiceHypothesisRole | null => (line.source === "parakeet-v3" ? "primary" : isApple(line.source, engine) ? "secondary" : null);
    const all = hypothesesOf(lines, role);
    const first = hypothesesOf(lines, (line) => (line.source === "parakeet-v3" ? "primary" : null));
    // Parakeet heard something: send it alone first; Apple only joins when that did not settle the take.
    return attemptOf(all, first.length && first.length < all.length ? [first] : undefined);
  }
  const [kind, source] = stack.split(/:(.*)/s) as [string, string];
  const line = lines.find((candidate) => candidate.source === source);
  if (!line) return null;
  if (kind === "legacy") {
    const text = clip(line.text);
    return text ? { locale: line.locale ?? "en-US", finals: [{ text }] } : null;
  }
  return attemptOf(hypothesesOf([line], () => "primary"));
}

// ---------------------------------------------------------------------------------------------
// The real instant lane

/** Host stand-in for file search (as r3/design4: one matching PDF), so file questions can answer. */
const searchFiles = async (request: FileSearchRequest) => ({
  items: [{ token: `tok_${"a".repeat(32)}`, name: `${(request.nameGroups[0] ?? ["file"]).join(" ")}.pdf`, path: "/Users/fixture/Documents/file.pdf", isDirectory: false, isPackage: false }],
  truncated: false, elapsedMs: 1,
});

export interface EvalLaneOptions {
  apps?: readonly AppRecord[];
  dictionary?: DictionaryLookup;
  takeMemo?: InMemoryTakeMemo;
  now?: Date;
}

export interface EvalLane {
  dispatcher: InstantDispatcher;
  /** Sends one take's finals (latest wins; a final that acts, answers or refuses ends the take). */
  run(attempt: TakeAttempt, takeId?: string): Promise<{ response: InstantResponse; request: InstantRequest; finals: number }>;
}

/** The production dispatcher on the fixture app index (no classifier, no network, no host). */
export function createEvalLane(options: EvalLaneOptions = {}): EvalLane {
  const apps = [...(options.apps ?? fixtureApps())];
  const now = options.now ?? EVAL_NOW;
  const dispatcher = createInstantDispatcher({
    apps: new AppIndexCache(async () => ({ version: "fixture", apps })),
    searchFiles,
    localZone: () => "Europe/Berlin",
    homeDir: "/Users/fixture",
    now: () => now,
    scorer: NO_CONTEXT_SCORER,
    ...(options.dictionary ? { dictionary: options.dictionary } : {}),
    ...(options.takeMemo ? { takeMemo: options.takeMemo } : {}),
  });
  let seq = 0;
  const memo = options.takeMemo;
  return {
    dispatcher,
    async run(attempt, takeId) {
      let response: InstantResponse | undefined;
      let request: InstantRequest | undefined;
      let finals = 0;
      for (const final of attempt.finals) {
        request = {
          text: final.text, phase: "final", seq: ++seq, locale: attempt.locale, inputMode: "voice", accept: [...INSTANT_ACCEPTS],
          ...(final.hypotheses ? { hypotheses: final.hypotheses } : {}), ...(takeId ? { takeId } : {}),
        };
        response = await dispatcher.dispatch(request);
        finals++;
        if (memo && takeId) {
          const record = takeRecordFor(request, response, now.getTime(), takeDetailsOf(response));
          if (record) memo.remember(record);
        }
        if (response.decision === "act" || response.decision === "answer" || response.decision === "refuse") break;
      }
      return { response: response!, request: request!, finals };
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Outcomes and scores (r3/design4 stack.mts, stack2.mts)

/** The decision's content-free class plus its target: `app:<bundleId>`, `url:<host>`, `sys:<op>`, … or `none`. */
export function signatureOf(response: InstantResponse): string {
  switch (response.decision) {
    case "act": {
      const action = response.action;
      if (action.type === "openApp") return `app:${action.bundleId}`;
      if (action.type === "openURL") {
        try {
          return `url:${new URL(action.url).hostname}`;
        } catch {
          return "url:?";
        }
      }
      if (action.type === "system") return `sys:${action.op}`;
      return `act:${response.intent}`;
    }
    case "answer": return `answer:${response.intent}`;
    case "list": return response.intent === "file_search" ? "files" : "none";
    case "refuse": return "refuse";
    case "fallthrough": return "none";
  }
}

/** The app rows of an open-app list (a did-you-mean or ambiguity card), in order. */
export function appRows(response: InstantResponse): string[] {
  if (response.decision !== "list" || response.intent !== "open_app") return [];
  const card: CardSpec = response.card;
  const rows: string[] = [];
  for (const element of Object.values(card.elements)) {
    if (element.type !== "Item" || !element.on?.primary) continue;
    const action = bindingToHostAction(element.on.primary);
    if (action?.type === "openApp") rows.push(action.bundleId);
  }
  return rows;
}

const ACTS = /^(app|url|sys):/;

export interface ItemOutcome {
  id: string;
  cat: string;
  /** The gold is instant-able (its decision is not `none`). */
  instant: boolean;
  expect: string;
  /** No final was sent: every recognizer heard nothing ("Didn't catch that"). */
  empty: boolean;
  sig: string;
  decision: InstantResponse["decision"] | "empty";
  confirm: boolean;
  check: boolean;
  rows: string[];
  via?: string;
  learnedEntryId?: string;
  atOnce: boolean;
  withReturn: boolean;
  offered: boolean;
  /** An app/url/system act without a Return that is not the gold's. */
  wrongAtOnce: boolean;
  wrongBehindConfirm: boolean;
  /** An agent-bound item the lane acted on at once / held for a Return, a list or the check state. */
  hijack: boolean;
  nag: boolean;
}

export function judge(item: CorpusItem, response: InstantResponse | null): ItemOutcome {
  const instant = isInstantItem(item);
  const base = { id: item.id, cat: item.cat, instant, expect: item.expect };
  if (!response) {
    return { ...base, empty: true, sig: "none", decision: "empty", confirm: false, check: false, rows: [], atOnce: false, withReturn: false, offered: false, wrongAtOnce: false, wrongBehindConfirm: false, hijack: false, nag: false };
  }
  const sig = signatureOf(response);
  const confirm = response.decision === "act" && response.confirm === true;
  const check = response.decision === "fallthrough" && response.reason === "low_confidence";
  const rows = appRows(response);
  const voice = response.decision === "act" || response.decision === "list" || response.decision === "fallthrough" ? response.voice : undefined;
  const goldApp = item.expect.startsWith("app:") ? item.expect.slice(4) : undefined;
  const right = instant && sig === item.expect;
  const atOnce = right && !confirm;
  const withReturn = atOnce || (right && confirm) || (goldApp !== undefined && rows[0] === goldApp);
  const offered = goldApp !== undefined && rows.slice(0, 3).includes(goldApp);
  const acts = ACTS.test(sig);
  return {
    ...base, empty: false, sig, decision: response.decision, confirm, check, rows,
    ...(voice?.via ? { via: voice.via } : {}), ...(voice?.learnedEntryId ? { learnedEntryId: voice.learnedEntryId } : {}),
    atOnce, withReturn, offered,
    wrongAtOnce: acts && !confirm && sig !== item.expect,
    wrongBehindConfirm: acts && confirm && sig !== item.expect,
    hijack: !instant && acts && !confirm,
    nag: !instant && (confirm || check || rows.length > 0),
  };
}

export interface CategoryScore { instant: number; atOnce: number; withReturn: number; offered: number }

export interface StackScore {
  stack: string;
  variant: string;
  items: number;
  instant: number;
  categories: Record<string, CategoryScore>;
  /** Mean of the F/G/H/I percentages over instant-able items (DESIGN4's "Tom-mix"). */
  tomMixAtOnce: number;
  tomMixWithReturn: number;
  tomMixOffered: number;
  allAtOnce: number;
  allWithReturn: number;
  wrongAtOnce: number;
  wrongBehindConfirm: number;
  hijacked: number;
  nagged: number;
  agentItems: number;
  empty: number;
  checks: number;
  outcomes: ItemOutcome[];
}

const pct = (part: number, whole: number): number => (whole ? (100 * part) / whole : Number.NaN);

export function summarize(stack: string, variant: string, outcomes: ItemOutcome[]): StackScore {
  const categories: Record<string, CategoryScore> = {};
  for (const o of outcomes) {
    const c = (categories[o.cat] ??= { instant: 0, atOnce: 0, withReturn: 0, offered: 0 });
    if (!o.instant) continue;
    c.instant++;
    if (o.atOnce) c.atOnce++;
    if (o.withReturn) c.withReturn++;
    if (o.withReturn || o.offered) c.offered++;
  }
  const mix = (key: keyof Omit<CategoryScore, "instant">): number => {
    const values = TOM_MIX.map((cat) => categories[cat]).filter((c): c is CategoryScore => !!c && c.instant > 0).map((c) => pct(c[key], c.instant));
    return values.length ? values.reduce((a, b) => a + b, 0) / values.length : Number.NaN;
  };
  const instant = outcomes.filter((o) => o.instant);
  return {
    stack, variant, items: outcomes.length, instant: instant.length, categories,
    tomMixAtOnce: mix("atOnce"), tomMixWithReturn: mix("withReturn"), tomMixOffered: mix("offered"),
    allAtOnce: pct(instant.filter((o) => o.atOnce).length, instant.length),
    allWithReturn: pct(instant.filter((o) => o.withReturn).length, instant.length),
    wrongAtOnce: outcomes.filter((o) => o.wrongAtOnce).length,
    wrongBehindConfirm: outcomes.filter((o) => o.wrongBehindConfirm).length,
    hijacked: outcomes.filter((o) => o.hijack).length,
    nagged: outcomes.filter((o) => o.nag).length,
    agentItems: outcomes.length - instant.length,
    empty: outcomes.filter((o) => o.empty).length,
    checks: outcomes.filter((o) => o.check).length,
    outcomes,
  };
}

/** Replays every take of `variant` through `stack` on a fresh lane and scores it against the gold. */
export async function scoreStack(corpus: readonly CorpusItem[], takes: readonly Take[], stack: StackName, variant: string, lane = createEvalLane()): Promise<StackScore> {
  const byId = new Map(takes.filter((take) => take.variant === variant).map((take) => [take.id, take]));
  const outcomes: ItemOutcome[] = [];
  for (const item of corpus) {
    const take = byId.get(item.id);
    if (!take) continue;
    const attempt = buildAttempt(take, stack);
    outcomes.push(judge(item, attempt ? (await lane.run(attempt, `${variant}-${item.id}`)).response : null));
  }
  return summarize(stack, variant, outcomes);
}

// ---------------------------------------------------------------------------------------------
// Cross-take learning (r3/design4 repeat.mts with the real store, learn lane and gestures)

export interface LearningScore {
  source: string;
  from: string;
  to: string;
  /** Open-app items with both takes (the gain is measured on these). */
  takes: number;
  /** Items with a test take of any kind (open-app, other instant, agent-bound): the safety count's base. */
  checked: number;
  /** Learn takes that were not right at once and got a gesture. */
  corrections: number;
  /** Rules the store holds afterwards (active). */
  rules: number;
  /** Learn requests by outcome (`learned`, `refused:<code>`, …). */
  learnOutcomes: Record<string, number>;
  /** Test-take acts at once before and after learning. */
  before: number;
  after: number;
  gainPoints: number;
  /**
   * Wrong acts at once after learning that were not the same wrong act before (a rule changed the outcome), over
   * every checked item: a learned rule must not hijack an agent-bound request or another instant item either.
   */
  learningCausedWrong: number;
  /** Wrong acts at once over the checked items, before and after learning. */
  wrongBefore: number;
  wrongAfter: number;
  causedIds: string[];
}

/**
 * The user's gesture after a take that was not right at once: a did-you-mean/list pick, Return on a
 * one-Return confirm, "No, I meant …" after a wrong act, else the check state's edit with the gold text.
 * Inferred corrections ask once; the simulated user answers Remember.
 */
export function gestureFor(item: CorpusItem, outcome: ItemOutcome, takeId: string): DictionaryLearnRequest | null {
  const goldApp = item.expect.startsWith("app:") ? item.expect.slice(4) : undefined;
  if (!goldApp || outcome.atOnce || outcome.empty) return null;
  if (outcome.rows.includes(goldApp)) return { takeId, kind: "pick", bundleId: goldApp };
  if (outcome.confirm && outcome.sig === item.expect) return { takeId, kind: "confirm", bundleId: goldApp };
  if (outcome.decision === "act") return { takeId, kind: "no_i_meant", correctedText: item.gold };
  return { takeId, kind: "edit", correctedText: item.gold };
}

export async function crossTakeLearning(corpus: readonly CorpusItem[], takes: readonly Take[], source: string, from: string, to: string,
  options: { dir?: string } = {}): Promise<LearningScore> {
  const apps = fixtureApps();
  const stack: StackName = `single:${source}`;
  const items = corpus.filter((item) => item.expect.startsWith("app:"));
  const pick = (variant: string) => new Map(takes.filter((take) => take.variant === variant && take.lines.some((line) => line.source === source)).map((take) => [take.id, take]));
  const learnTakes = pick(from);
  const testTakes = pick(to);
  const paired = items.filter((item) => learnTakes.has(item.id) && testTakes.has(item.id));
  // The safety count replays every item with a test take (r3's repeat.mts only looked at the open-app takes).
  const checked = corpus.filter((item) => testTakes.has(item.id));

  const dir = options.dir ?? mkdtempSync(join(tmpdir(), "pi-os-voice-eval-"));
  const owned = options.dir === undefined;
  try {
    const store = new DictionaryStore({ path: join(dir, "dictionary.json"), clock: () => EVAL_NOW.getTime(), log: () => {}, installed: (bundleId) => apps.some((app) => app.bundleId === bundleId) });
    store.load();
    const memo = new InMemoryTakeMemo({ clock: () => EVAL_NOW.getTime() });
    const lane = createEvalLane({ dictionary: store, takeMemo: memo });
    const uncounted = nonCountingLookup(store);
    const learnLane = createLearnLane({ dispatcher: createEvalLane({ dictionary: uncounted }).dispatcher, apps: () => apps, dictionary: uncounted, isCommonWord });
    const fresh = createEvalLane({ dictionary: NO_DICTIONARY });

    const testRun = async (run: EvalLane) => {
      const out = new Map<string, ItemOutcome>();
      for (const item of checked) {
        const attempt = buildAttempt(testTakes.get(item.id)!, stack);
        out.set(item.id, judge(item, attempt ? (await run.run(attempt)).response : null));
      }
      return out;
    };
    const before = await testRun(fresh);

    let corrections = 0;
    const learnOutcomes: Record<string, number> = {};
    for (const item of paired) {
      const attempt = buildAttempt(learnTakes.get(item.id)!, stack);
      if (!attempt) continue;
      const takeId = `learn-${from}-${item.id}`;
      const { response } = await lane.run(attempt, takeId);
      const gesture = gestureFor(item, judge(item, response), takeId);
      if (!gesture) continue;
      corrections++;
      let result = await learnFromGesture(gesture, { store, memo, lane: learnLane });
      if (result.status === "needs_confirmation") result = await learnFromGesture({ ...gesture, confirmed: true }, { store, memo, lane: learnLane });
      const key = result.status === "refused" || result.status === "needs_confirmation" ? `${result.status}:${result.code ?? "?"}` : result.status;
      learnOutcomes[key] = (learnOutcomes[key] ?? 0) + 1;
    }
    memo.clear();
    const after = await testRun(lane);
    store.flush();

    const causedIds: string[] = [];
    for (const item of checked) {
      const a = after.get(item.id)!;
      const b = before.get(item.id)!;
      // A rule that now decides the same wrong act the grammar made before changed nothing.
      if (a.wrongAtOnce && !(b.wrongAtOnce && b.sig === a.sig)) causedIds.push(item.id);
    }
    const document = store.document();
    const active = (list: readonly { disabledAt?: string }[]) => list.filter((entry) => !entry.disabledAt).length;
    const count = (map: Map<string, ItemOutcome>, key: "atOnce" | "wrongAtOnce", ids?: readonly CorpusItem[]) =>
      (ids ? ids.map((item) => map.get(item.id)!) : [...map.values()]).filter((o) => o[key]).length;
    const beforeOk = count(before, "atOnce", paired);
    const afterOk = count(after, "atOnce", paired);
    return {
      source, from, to, takes: paired.length, checked: checked.length, corrections, learnOutcomes,
      rules: active(document.appNames) + active(document.aliases) + active(document.fixes),
      before: beforeOk, after: afterOk, gainPoints: pct(afterOk, paired.length) - pct(beforeOk, paired.length),
      learningCausedWrong: causedIds.length, wrongBefore: count(before, "wrongAtOnce"), wrongAfter: count(after, "wrongAtOnce"), causedIds,
    };
  } finally {
    if (owned) rmSync(dir, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------------------------
// Per-recognizer transcript metrics (r3/asr/eval/score.mjs)

const COMPOUNDS: readonly (readonly [RegExp, string])[] = [
  [/\bv\.? ?s\.? code\b/g, "vscode"], [/\bvs code\b/g, "vscode"], [/\bvisual studio code\b/g, "vscode"],
  [/\bx code\b/g, "xcode"], [/\bex code\b/g, "xcode"], [/\bkey note\b/g, "keynote"], [/\bchat ?g ?p ?t\b/g, "chatgpt"],
  [/\bwhats ?app\b/g, "whatsapp"], [/\bwhat s app\b/g, "whatsapp"], [/\bray ?cast\b/g, "raycast"], [/\bgit ?hub\b/g, "github"],
  [/\bp ?m\b/g, "pm"], [/\ba ?m\b(?= |$)/g, "am"], [/\bsystem einstellungen\b/g, "systemeinstellungen"],
  [/\bsummarise\b/g, "summarize"], [/\be ?mail\b/g, "email"],
];
const CONTRACTIONS: readonly (readonly [RegExp, string])[] = [
  [/\bwhat's\b/g, "what is"], [/\bit's\b/g, "it is"], [/\bi'll\b/g, "i will"], [/\bdon't\b/g, "do not"],
  [/\blet's\b/g, "let us"], [/\bwhat're\b/g, "what are"], [/\bhow's\b/g, "how is"], [/\bwhere's\b/g, "where is"], [/\bi'm\b/g, "i am"],
];

/** score.mjs `norm`: case, punctuation, contractions, spoken numbers → digits, %, app-name compounds. */
export function normalizeTranscript(text: string, lang: string): string {
  let t = (text ?? "").normalize("NFC").toLowerCase().replace(/[’`]/g, "'");
  for (const [re, to] of CONTRACTIONS) t = t.replace(re, to);
  t = t.replace(/(\d)[.,](\d{3})\b/g, "$1$2");
  t = t.replace(/\b([a-z0-9-]+)\.(com|de|org|net|io)\b/g, "$1 dot $2");
  t = t.replace(/%/g, " % ").replace(/\b(percent|per cent|prozent)\b/g, " % ");
  t = t.replace(/[-_/]/g, " ").replace(/[^\p{L}\p{N}%' ]+/gu, " ").replace(/'/g, "").replace(/\s+/g, " ").trim();
  t = enWordsToDigits(t);
  t = deWordsToDigits(t, lang === "en" ? DE_EN_COLLISIONS : new Set());
  t = t.replace(/\btwenty (\d{2})\b/g, (_m, d: string) => String(2000 + Number(d))).replace(/\b20 (\d{2})\b/g, (_m, d: string) => String(2000 + Number(d)));
  for (const [re, to] of COMPOUNDS) t = t.replace(re, to);
  return t.replace(/\s+/g, " ").trim();
}

const fold = (s: string): string => s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/ß/g, "ss");

export function wordErrors(reference: string, hypothesis: string): { errors: number; words: number } {
  const r = reference.split(" ").filter(Boolean);
  const h = hypothesis.split(" ").filter(Boolean);
  let previous = Array.from({ length: h.length + 1 }, (_, j) => j);
  for (let i = 1; i <= r.length; i++) {
    const row = [i];
    for (let j = 1; j <= h.length; j++) row[j] = Math.min(previous[j]! + 1, row[j - 1]! + 1, previous[j - 1]! + (r[i - 1] === h[j - 1] ? 0 : 1));
    previous = row;
  }
  return { errors: previous[h.length]!, words: r.length };
}

/** Every keyword group occurs in the normalized hypothesis (diacritics folded). */
export function keywordsOk(normalized: string, kw: readonly string[]): boolean {
  const words = ` ${fold(normalized)} `;
  return kw.every((group) => group.split("|").some((k) => {
    const f = fold(normalizeTranscript(k, "x"));
    return f === "%" ? words.includes(" % ") : words.includes(` ${f} `) || (f.length >= 5 && words.includes(f));
  }));
}

const quantile = (values: number[], q: number): number => {
  if (!values.length) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * (sorted.length - 1) + 0.5))]!;
};

export interface RecognizerScore {
  source: string;
  variant: string;
  n: number;
  wer: number;
  exact: number;
  /** Instant-able: the recognizer alone (as primary) decides the gold; agent-bound: keywords kept. */
  intent: number;
  wrongActs: number;
  empty: number;
  finalP50: number;
  finalP90: number;
  firstPartialP50: number;
}

export async function scoreRecognizers(corpus: readonly CorpusItem[], lines: readonly BenchLine[], lane = createEvalLane()): Promise<RecognizerScore[]> {
  const byId = new Map(corpus.map((item) => [item.id, item]));
  const groups = new Map<string, BenchLine[]>();
  for (const line of lines) {
    if (!byId.has(line.id)) continue;
    const key = `${line.source}\u0000${line.variant}`;
    (groups.get(key) ?? groups.set(key, []).get(key)!).push(line);
  }
  const out: RecognizerScore[] = [];
  for (const [key, group] of groups) {
    const [source, variant] = key.split("\u0000") as [string, string];
    let errors = 0, words = 0, exact = 0, intent = 0, wrong = 0, empty = 0;
    for (const line of group) {
      const item = byId.get(line.id)!;
      const lang = item.lang === "mixed" ? "de" : item.lang;
      const g = normalizeTranscript(item.gold, lang);
      const h = normalizeTranscript(line.text, lang);
      const w = wordErrors(g, h);
      errors += w.errors;
      words += w.words;
      if (g === h) exact++;
      if (!clip(line.text)) empty++;
      const attempt = buildAttempt({ id: line.id, variant, lines: [line] }, `single:${source}`);
      const o = judge(item, attempt ? (await lane.run(attempt)).response : null);
      if (o.wrongAtOnce) wrong++;
      if (isInstantItem(item) ? o.atOnce : keywordsOk(h, item.kw)) intent++;
    }
    const finals = group.map((line) => line.finalMs).filter((v): v is number => v !== undefined);
    const partials = group.map((line) => line.firstPartialMs).filter((v): v is number => v !== undefined);
    out.push({
      source, variant, n: group.length, wer: pct(errors, words), exact: pct(exact, group.length), intent: pct(intent, group.length),
      wrongActs: wrong, empty, finalP50: quantile(finals, 0.5), finalP90: quantile(finals, 0.9), firstPartialP50: quantile(partials, 0.5),
    });
  }
  return out.sort((a, b) => a.source.localeCompare(b.source) || a.variant.localeCompare(b.variant));
}

// ---------------------------------------------------------------------------------------------
// Tables (content-free)

const f0 = (value: number): string => (Number.isNaN(value) ? "–" : value.toFixed(0));
const f1 = (value: number): string => (Number.isNaN(value) ? "–" : value.toFixed(1));

export function recognizerTable(rows: readonly RecognizerScore[]): string {
  const lines = ["| recognizer | variant | n | WER % | exact % | intent % | wrong acts | empty | final p50/p90 ms | first partial p50 ms |", "|---|---|---|---|---|---|---|---|---|---|"];
  for (const r of rows) lines.push(`| ${r.source} | ${r.variant} | ${r.n} | ${f1(r.wer)} | ${f0(r.exact)} | ${f0(r.intent)} | ${r.wrongActs} | ${r.empty} | ${f0(r.finalP50)}/${f0(r.finalP90)} | ${f0(r.firstPartialP50)} |`);
  return lines.join("\n");
}

export function stackTable(rows: readonly StackScore[]): string {
  const cell = (s: StackScore, cat: string) => {
    const c = s.categories[cat];
    return c && c.instant ? f0(pct(c.atOnce, c.instant)) : "–";
  };
  const lines = [
    "| stack | variant | A | F | G | H | I | Tom-mix at once | Tom-mix incl. one Return | Tom-mix incl. offered | all at once | all incl. Return | wrong at once | wrong behind Return | agent items acted/held | empty | check |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
  ];
  for (const s of rows) {
    lines.push(`| ${s.stack} | ${s.variant} | ${["A", ...TOM_MIX].map((cat) => cell(s, cat)).join(" | ")} | **${f0(s.tomMixAtOnce)}** | ${f0(s.tomMixWithReturn)} | ${f0(s.tomMixOffered)} | ${f0(s.allAtOnce)} | ${f0(s.allWithReturn)} | ${s.wrongAtOnce} | ${s.wrongBehindConfirm} | ${s.hijacked}/${s.nagged} of ${s.agentItems} | ${s.empty} | ${s.checks} |`);
  }
  return lines.join("\n");
}

export function learningTable(rows: readonly LearningScore[]): string {
  const lines = ["| recognizer | learned on → tested on | open-app takes | corrections | rules | at once before | after | gain (points) | learning-caused wrong acts (all items) | wrong before/after (all items) |", "|---|---|---|---|---|---|---|---|---|---|"];
  for (const r of rows) {
    lines.push(`| ${r.source} | ${r.from} → ${r.to} | ${r.takes} | ${r.corrections} | ${r.rules} | ${r.before} (${f0(pct(r.before, r.takes))} %) | ${r.after} (${f0(pct(r.after, r.takes))} %) | ${r.gainPoints >= 0 ? "+" : ""}${f1(r.gainPoints)} | ${r.learningCausedWrong} | ${r.wrongBefore}/${r.wrongAfter} |`);
  }
  return lines.join("\n");
}

/** Per-item outcome classes (ids and categories only); `content` adds signatures (synthetic corpora only). */
export function itemDetails(score: StackScore, content = false): string {
  const lines: string[] = [];
  for (const o of score.outcomes) {
    const cls = o.empty ? "empty" : o.atOnce ? "ok" : o.withReturn ? "return" : o.offered ? "offered" : o.wrongAtOnce ? "WRONG" : o.wrongBehindConfirm ? "wrong-held"
      : o.instant ? `miss:${o.decision}${o.check ? ":check" : ""}` : o.hijack ? "HIJACK" : o.nag ? "held" : "agent";
    if (cls === "ok" || cls === "agent") continue;
    lines.push(`  ${score.stack} ${score.variant} ${o.id} [${o.cat}] ${cls}${o.via ? ` via=${o.via}` : ""}${content ? ` ${o.sig} expected ${o.expect}` : ""}`);
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------------------------
// import-r3: regenerate the fixtures from r3/asr (developer tool; the r3 scratch data is not in the repo)

interface R3Row { id: string; hyp?: string; hypDe?: string; confidence?: number | null; confidenceDe?: number | null; alternatives?: string[][]; finalLatencyMs?: number; firstPartialMs?: number; mode?: string }
type LidMap = Record<string, { en: number; de: number }>;

const readJsonl = (path: string): R3Row[] => readFileSync(path, "utf8").split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l) as R3Row);
const keyOf = (text: string): string => text.split(/\s+/).filter(Boolean).join(" ").toLowerCase();
const joinSegments = (texts: readonly string[]): string => texts.map((t) => t.trim()).filter(Boolean).join(" ").replace(/\s+([.,!?;:])/g, "$1").replace(/\s+/g, " ").trim();

/**
 * Whole-take n-best of an Apple DictationTranscriber final, as PiOSMac VoiceModuleTranscript.alternatives builds it:
 * the take's final segments are the shortest suffix of the per-result alternative lists whose first entries spell the
 * transcript (DictationTranscriber re-finalizes ranges, so r3's lists repeat); one segment is swapped for one of its
 * alternatives at a time (≤ 4 per segment, best rank first), distinct from the text and each other, ≤ 2.
 */
export function wholeTakeAlternatives(text: string, perResult: readonly (readonly string[])[], limit = 2): string[] {
  const target = keyOf(text);
  if (!target) return [];
  let segments: (readonly string[])[] | undefined;
  for (let start = perResult.length - 1; start >= 0; start--) {
    const suffix = perResult.slice(start);
    if (keyOf(joinSegments(suffix.map((alts) => alts[0] ?? ""))) === target) {
      segments = suffix;
      break;
    }
  }
  if (!segments) return [];
  const own = segments.map((alts) => (alts[0] ?? "").trim());
  const alternatives = segments.map((alts, index) => {
    const seen = new Set([keyOf(own[index]!)]);
    const out: string[] = [];
    for (const raw of alts) {
      const trimmed = raw.trim();
      if (!trimmed || seen.has(keyOf(trimmed))) continue;
      seen.add(keyOf(trimmed));
      out.push(trimmed);
      if (out.length === 4) break;
    }
    return out;
  });
  const out: string[] = [];
  const seen = new Set([target]);
  for (let rank = 0; rank < 4; rank++) {
    for (let index = 0; index < segments.length; index++) {
      const alt = alternatives[index]![rank];
      if (alt === undefined) continue;
      const texts = [...own];
      texts[index] = alt;
      const joined = joinSegments(texts);
      if (!joined || seen.has(keyOf(joined))) continue;
      seen.add(keyOf(joined));
      out.push(joined);
      if (out.length === limit) return out;
    }
  }
  return out;
}

/** VoiceArbiter.score: P(own language | text) × confidence (0.5 when unknown); NL constrained to en/de. */
function arbiterScore(text: string, locale: string, confidence: number | undefined, lid: LidMap | undefined): number {
  if (!text.trim()) return -1;
  const p = lid ? lid[text]?.[locale.startsWith("de") ? "de" : "en"] ?? 0 : 1;
  return p * Math.min(1, Math.max(0, confidence ?? 0.5));
}

/** NLLanguageRecognizer's pick for a multilingual engine's text (ties → en, the earlier language). */
function nlLocale(text: string, lid: LidMap | undefined): string | undefined {
  const p = lid?.[text];
  if (!p) return undefined;
  return p.de > p.en ? "de-DE" : "en-US";
}

const conf = (value: number | null | undefined): number | undefined => (typeof value === "number" && Number.isFinite(value) ? Math.round(Math.min(1, Math.max(0, value)) * 1e4) / 1e4 : undefined);
const ms = (value: number | undefined): number | undefined => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.round(value * 10) / 10 : undefined);

function benchLine(line: BenchLine): string {
  const out: Record<string, unknown> = { id: line.id, variant: line.variant, source: line.source, role: line.role, text: line.text };
  for (const key of ["confidence", "minConfidence", "nbest", "finalMs", "firstPartialMs", "locale"] as const) if (line[key] !== undefined) out[key] = line[key];
  return JSON.stringify(out);
}

/** Two Apple locales of one take in arbiter order (VoiceArbiter.final: score desc, then module order en, de). */
function appleTakeLines(id: string, variant: string, engine: "apple-dt" | "apple-st", modules: { locale: string; row: R3Row | undefined; text: string; confidence?: number; nbest?: string[] }[],
  lid: LidMap | undefined, timing: boolean): BenchLine[] {
  const lines = modules.map((m, index) => ({
    index,
    score: arbiterScore(m.text, m.locale, m.confidence, lid),
    line: {
      id, variant, source: `${engine}/${m.locale}`, role: "peer", text: m.text.trim(), locale: m.locale,
      ...(m.confidence !== undefined ? { confidence: m.confidence } : {}),
      ...(m.nbest?.length ? { nbest: m.nbest } : {}),
      ...(timing && ms(m.row?.finalLatencyMs) !== undefined ? { finalMs: ms(m.row?.finalLatencyMs) } : {}),
      ...(timing && ms(m.row?.firstPartialMs) !== undefined ? { firstPartialMs: ms(m.row?.firstPartialMs) } : {}),
    } as BenchLine,
  }));
  return lines.sort((a, b) => b.score - a.score || a.index - b.index).map((entry) => entry.line);
}

/**
 * The gold label of every item: the gold text's own decision through the real lane, sent as today's hosts send a
 * voice final (text only; r3/design4 stack.mts: "what the pipeline does with the gold"). Instant-able ⇔ not `none`.
 */
export async function labelGold(items: readonly Omit<CorpusItem, "expect">[], lane = createEvalLane()): Promise<CorpusItem[]> {
  const out: CorpusItem[] = [];
  for (const item of items) {
    const { response } = await lane.run({ locale: goldLocale(item), finals: [{ text: item.gold }] });
    out.push({ id: item.id, cat: item.cat, lang: item.lang, voice: item.voice, rate: item.rate, gold: item.gold, say: item.say, kw: item.kw, expect: signatureOf(response) });
  }
  return out;
}

const writeCorpus = (path: string, items: readonly CorpusItem[]): void => writeFileSync(path, `${JSON.stringify({ version: 1, items }, null, 1)}\n`);

/** Recomputes `expect` in a corpus file after a deliberate mapping change; returns the ids whose label changed. */
export async function relabelCorpus(path = join(VOICE_FIXTURES, "corpus.json")): Promise<string[]> {
  const items = loadCorpus(path);
  const relabeled = await labelGold(items);
  writeCorpus(path, relabeled);
  return relabeled.filter((item, index) => item.expect !== items[index]!.expect).map((item) => item.id);
}

export async function importR3(r3: string, out: string, lid?: LidMap): Promise<{ files: Record<string, number>; instant: number }> {
  const asr = join(r3, "asr");
  const items = await labelGold(JSON.parse(readFileSync(join(asr, "corpus", "corpus.json"), "utf8")) as Omit<CorpusItem, "expect">[]);
  mkdirSync(join(out, "bench"), { recursive: true });
  writeCorpus(join(out, "corpus.json"), items);
  const ids = items.map((item) => item.id);
  const files: Record<string, number> = {};
  const write = (name: string, lines: BenchLine[]) => {
    writeFileSync(join(out, "bench", name), lines.map(benchLine).join("\n") + "\n");
    files[name] = lines.length;
  };
  const byId = (path: string) => new Map(readJsonl(path).map((row) => [row.id, row]));
  const results = join(asr, "results");

  // Phase A engine: DictationTranscriber en-US + de-DE in one analyzer, 117 app names as contextual strings, realtime.
  const dual = byId(join(results, "lat-apple-dtdual-apps.jsonl"));
  write("apple-dt-dual.clean.jsonl", ids.flatMap((id) => {
    const row = dual.get(id);
    return appleTakeLines(id, "clean", "apple-dt", [
      { locale: "en-US", row, text: row?.hyp ?? "", confidence: conf(row?.confidence), nbest: wholeTakeAlternatives(row?.hyp ?? "", row?.alternatives ?? []) },
      { locale: "de-DE", row, text: row?.hypDe ?? "", confidence: conf(row?.confidenceDe) },
    ], lid, true);
  }));
  for (const variant of ["clean", "tail", "room", "ptt2"]) {
    // DictationTranscriber per locale without contextual strings (clean realtime, the degraded variants in batch).
    const en = byId(join(results, "merged", `apple-dt-en-${variant}.jsonl`));
    const de = byId(join(results, "merged", `apple-dt-de-${variant}.jsonl`));
    write(`apple-dt.${variant}.jsonl`, ids.flatMap((id) => appleTakeLines(id, variant, "apple-dt", [
      { locale: "en-US", row: en.get(id), text: en.get(id)?.hyp ?? "" },
      { locale: "de-DE", row: de.get(id), text: de.get(id)?.hyp ?? "" },
    ], lid, en.get(id)?.mode === "realtime")));
    // Today's engine: SpeechTranscriber en-US with pi-os's options.
    const st = byId(join(results, "merged", `apple-st-en-pios-${variant}.jsonl`));
    write(`apple-st-en.${variant}.jsonl`, ids.map((id) => {
      const row = st.get(id);
      const realtime = row?.mode === "realtime";
      return {
        id, variant, source: "apple-st/en-US", role: "peer", text: (row?.hyp ?? "").trim(), locale: "en-US",
        ...(realtime && ms(row?.finalLatencyMs) !== undefined ? { finalMs: ms(row?.finalLatencyMs) } : {}),
        ...(realtime && ms(row?.firstPartialMs) !== undefined ? { firstPartialMs: ms(row?.firstPartialMs) } : {}),
      } as BenchLine;
    }));
    // Multilingual engines (CoreML on CPU/ANE in r3): Parakeet TDT v3, Whisper large-v3-turbo (auto language).
    for (const [name, file, source] of [["parakeet-v3", `fa-v3-${variant}`, "parakeet-v3"], ["whisper-turbo", `wk-turbo-auto-${variant}`, "whisper-turbo"]] as const) {
      const rows = byId(join(results, "merged", `${file}.jsonl`));
      write(`${name}.${variant}.jsonl`, ids.map((id) => {
        const row = rows.get(id);
        const text = (row?.hyp ?? "").trim();
        const locale = nlLocale(row?.hyp ?? "", lid);
        return {
          id, variant, source, role: "primary", text,
          ...(locale ? { locale } : {}),
          ...(ms(row?.finalLatencyMs) !== undefined ? { finalMs: ms(row?.finalLatencyMs) } : {}),
          ...(ms(row?.firstPartialMs) !== undefined ? { firstPartialMs: ms(row?.firstPartialMs) } : {}),
        } as BenchLine;
      }));
    }
  }
  // Whisper with the dictionary as the prompt (clean only in r3).
  const prompt = byId(join(results, "merged", "wk-turbo-auto-prompt-clean.jsonl"));
  write("whisper-turbo-prompt.clean.jsonl", ids.map((id) => {
    const row = prompt.get(id);
    const locale = nlLocale(row?.hyp ?? "", lid);
    return { id, variant: "clean", source: "whisper-turbo", role: "primary", text: (row?.hyp ?? "").trim(), ...(locale ? { locale } : {}), ...(ms(row?.finalLatencyMs) !== undefined ? { finalMs: ms(row?.finalLatencyMs) } : {}) } as BenchLine;
  }));
  return { files, instant: items.filter(isInstantItem).length };
}

// ---------------------------------------------------------------------------------------------
// CLI

function argValue(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index < 0) return undefined;
  const value = args[index + 1];
  args.splice(index, 2);
  return value;
}

/** The CLI; `log` receives every output line (tests check that it stays content-free). */
export async function main(argv: readonly string[], log: (line: string) => void = (line) => console.log(line)): Promise<number> {
  const args = [...argv];
  if (args[0] === "relabel") {
    const changed = await relabelCorpus(argValue(args, "--corpus"));
    log(`relabeled corpus: ${changed.length} labels changed${changed.length ? ` (${changed.join(", ")})` : ""}`);
    return 0;
  }
  if (args[0] === "import-r3") {
    args.shift();
    const r3 = argValue(args, "--r3");
    const out = argValue(args, "--out") ?? VOICE_FIXTURES;
    const lidPath = argValue(args, "--lid");
    if (!r3) {
      console.error("usage: voice-eval.mts import-r3 --r3 <dir> [--lid <lid-map.json>] [--out <dir>]");
      return 2;
    }
    const lid = lidPath ? (JSON.parse(readFileSync(lidPath, "utf8")) as LidMap) : undefined;
    const result = await importR3(r3, out, lid);
    log(`wrote ${Object.keys(result.files).length} bench files (${Object.values(result.files).reduce((a, b) => a + b, 0)} lines), ${result.instant} instant-able gold items`);
    return 0;
  }
  const corpusPath = argValue(args, "--corpus");
  const stackArg = argValue(args, "--stack");
  const learnArg = argValue(args, "--learn");
  const details = args.includes("--details");
  const content = args.includes("--show-content");
  const files = args.filter((arg) => !arg.startsWith("--"));
  if (!files.length) {
    console.error("usage: voice-eval.mts [--corpus <file>] [--stack asis,phaseA,phaseB,single,legacy] [--learn clean:ptt2] [--details] [--show-content] <bench.jsonl>...");
    return 2;
  }
  const corpus = loadCorpus(corpusPath);
  const run = readBench(files);
  const known = new Set(corpus.map((item) => item.id));
  const unknown = new Set(run.lines.filter((line) => !known.has(line.id)).map((line) => line.id)).size;
  log(`bench: ${run.lines.length} lines, ${unknown} ids without gold (skipped), ${run.duplicates} duplicates, rejected ${JSON.stringify(run.rejected)}`);
  const takes = groupTakes(run.lines.filter((line) => known.has(line.id)));
  const sources = [...new Set(run.lines.map((line) => line.source))].sort();
  const variants = [...new Set(takes.map((take) => take.variant))].sort();

  log("\nPer recognizer (alone, as the primary):\n");
  log(recognizerTable(await scoreRecognizers(corpus, run.lines)));

  const wanted = (stackArg ?? "asis,phaseA,phaseB,single,legacy").split(",");
  const stacks: StackName[] = [];
  if (wanted.includes("asis")) stacks.push("asis");
  if (wanted.includes("phaseA") && sources.some((s) => s.startsWith("apple-"))) stacks.push("phaseA");
  if (wanted.includes("phaseB") && sources.includes("parakeet-v3")) stacks.push("phaseB");
  if (wanted.includes("single")) for (const source of sources) stacks.push(`single:${source}`);
  if (wanted.includes("legacy")) for (const source of sources) stacks.push(`legacy:${source}`);
  const scores: StackScore[] = [];
  for (const variant of variants) for (const stack of stacks) scores.push(await scoreStack(corpus, takes, stack, variant));
  log("\nStacks (instant-able items per category, % at once; wrong acts over all items):\n");
  log(stackTable(scores));
  if (details || content) for (const score of scores) {
    const text = itemDetails(score, content);
    if (text) log(text);
  }
  if (learnArg) {
    const [from, to] = learnArg.split(":") as [string, string];
    const rows: LearningScore[] = [];
    for (const source of sources) rows.push(await crossTakeLearning(corpus, takes, source, from, to));
    log("\nCross-take learning (one correction per missed take, real dictionary + learn lane):\n");
    log(learningTable(rows));
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then((code) => { process.exitCode = code; }, (error: unknown) => {
    // A JSON parse error quotes the input it failed on (a corpus or lid file may hold transcripts): never print it.
    console.error(error instanceof SyntaxError ? "voice-eval: an input file is not valid JSON" : error instanceof Error ? error.message : "voice-eval failed");
    process.exitCode = 1;
  });
}
