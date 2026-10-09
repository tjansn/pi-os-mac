import { parseHostAction } from "../contracts/actions.js";
import type { FileCandidate, FileSearchRequest, FileSearchResult } from "../contracts/launcher.js";
import { AppIndexCache, type AppMatch } from "./apps.js";
import {
  addCalendar, daysBetween, formatDate, isoDate, localToday, nextOccurrence, weekdayIn, type YMD,
} from "./engines/dates.js";
import { FEND_DEFAULT_TIMEOUT_MS, FEND_MAX_INPUT, FendEngine } from "./engines/fend.js";
import { EcbRateStore, type FxFreshness } from "./engines/fx.js";
import { convertWallTime, localZone as systemZone, resolvePlace, zoneDiff, zonedTime, type PlaceZone, type ZonedTime } from "./engines/timezones.js";
import { buildFileSearchRequest } from "./files/query.js";
import { rankFiles, type RankedFile } from "./files/rank.js";
import { currencyDigits, displayValue, formatNumber, leadingNumber, roundLeadingNumber } from "./format.js";
import { matchFileSearch } from "./grammar/files.js";
import { CURRENCY_WORDS } from "./grammar/math.js";
import { matchDate } from "./grammar/time.js";
import { applyPercentSemantics, normalize } from "./normalize.js";
import type { DateQuery, FileQuery } from "./types.js";

/**
 * Structured instant engines shared by the instant dispatcher and the agent's
 * pi tools (instant_calc, instant_convert_currency, instant_time_in,
 * find_files, list_apps). All methods resolve; none throws.
 */

export interface FendLoader {
  /** Loads once (compile + instantiate); retries after a failure; waits out a rebuild after a trap. */
  get(): Promise<FendEngine>;
  /** The loaded engine, if any (no waiting). */
  peek(): FendEngine | null;
}

export function createFendLoader(load: () => Promise<FendEngine> = () => FendEngine.load()): FendLoader {
  let engine: FendEngine | null = null;
  let pending: Promise<FendEngine> | undefined;
  return {
    get() {
      const current = engine;
      if (current) return current.ready ? Promise.resolve(current) : current.settled().then(() => current);
      pending ??= load().then((loaded) => {
        engine = loaded;
        return loaded;
      }, (error: unknown) => {
        pending = undefined;
        throw error;
      });
      return pending;
    },
    peek: () => engine,
  };
}

export type SearchFiles = (request: FileSearchRequest, signal: AbortSignal) => Promise<FileSearchResult | readonly FileCandidate[]>;

/** Dependencies shared by createInstantEngines and createInstantDispatcher (pass the same objects to both). */
export interface InstantDeps {
  fend?: FendLoader;
  /** ECB rates; without it currency questions answer "unavailable". */
  fx?: EcbRateStore;
  /** Host app index (POST /tools/launcher.listApps) behind a version cache. */
  apps?: AppIndexCache;
  /** Host file search (POST /tools/launcher.searchFiles). */
  searchFiles?: SearchFiles;
  now?: () => Date;
  /** The user's IANA zone (default: the process zone). */
  localZone?: () => string;
  /** Display locale for engine text (default "en-US"). */
  locale?: string;
  calcTimeoutMs?: number;
}

// ---------------------------------------------------------------- results

export type CalcResult =
  | { ok: true; expression: string; text: string; approximate: boolean; display: string; copy: string }
  | { ok: false; error: string };

export type CurrencyError = "unknown_currency" | "rates_unavailable" | "rates_disabled" | "invalid_amount";

export type CurrencyResult =
  | {
    ok: true; amount: number; from: string; to: string; value: number; rate: number; asOf: string; freshness: FxFreshness;
    /** "ECB reference rate YYYY-MM-DD · info only" */
    label: string;
    /** "85.93 EUR" */
    display: string;
    /** "85.93" */
    copy: string;
    /** "100 USD" */
    amountDisplay: string;
    /** "1 USD = 0.8593 EUR" */
    rateDisplay: string;
  }
  | { ok: false; error: CurrencyError; message: string };

export type TimeInResult = ({ ok: true; place: string } & ZonedTime) | { ok: false; error: "unknown_place" };

export type TimeConvertResult =
  | ({ ok: true; fromPlace: string; toPlace: string; from: ZonedTime } & ZonedTime)
  | { ok: false; error: "unknown_place" | "invalid_time" };

export type TimeDiffResult = { ok: true; fromPlace: string; toPlace: string; hours: number } | { ok: false; error: "unknown_place" };

export type DateResult =
  | { ok: true; op: DateQuery["op"]; date: string; display: string; weekday: string; days?: number; label?: string }
  | { ok: false; error: "invalid_date" | "unparsed" };

export type FilesResult =
  | { ok: true; files: RankedFile[]; relaxed: boolean; truncated: boolean }
  | { ok: false; error: "unavailable" | "timeout" | "invalid_query" };

export type AppsResult = { ok: true; matches: AppMatch[] } | { ok: false; error: "unavailable" };

// ---------------------------------------------------------------- shared helpers (also used by the dispatcher)

/** Runs fend and shapes display/copy text. Unit results that are approximate are rounded for display. */
export function evaluateWith(engine: FendEngine, expression: string, locale: string, timeoutMs: number, unit = false): CalcResult {
  const result = engine.evaluate(expression, timeoutMs);
  if (!result.ok) return { ok: false, error: result.error };
  const text = unit && result.approximate ? roundLeadingNumber(result.text, 4) : result.text;
  return {
    ok: true,
    expression,
    text: result.text,
    approximate: result.approximate,
    display: displayValue(text, locale, result.approximate),
    copy: unit ? leadingNumber(text) : text,
  };
}

const ISO_CODE = /^[A-Za-z]{3}$/;

export function currencyCode(text: string): string | null {
  const lower = text.trim().toLowerCase();
  return CURRENCY_WORDS[lower] ?? (ISO_CODE.test(lower) ? lower.toUpperCase() : null);
}

/**
 * Converts with ECB rates; on the first query it starts the (on-demand)
 * download and waits up to `waitMs`. After a failed download the store backs
 * off, so repeated queries (every keystroke of a preview) do not re-fetch.
 */
export async function convertCurrencyWith(
  fx: EcbRateStore | undefined, amount: number, fromText: string, toText: string, locale: string,
  options: { signal?: AbortSignal; waitMs?: number } = {},
): Promise<CurrencyResult> {
  const from = currencyCode(fromText);
  const to = currencyCode(toText);
  if (!from || !to) return { ok: false, error: "unknown_currency", message: "Unknown currency." };
  if (!Number.isFinite(amount) || Math.abs(amount) > 1e15) return { ok: false, error: "invalid_amount", message: "Amount out of range." };
  if (!fx) return { ok: false, error: "rates_unavailable", message: "Currency rates are not available." };
  await fx.load();
  let outcome: Awaited<ReturnType<EcbRateStore["refresh"]>> | undefined;
  if (fx.needsRefresh()) {
    const pending = fx.refresh();
    if (!fx.snapshot() && (options.waitMs ?? 0) > 0) outcome = await waitFor(pending, options.waitMs ?? 0, options.signal);
  }
  const conversion = fx.convert(amount, from, to);
  if (!conversion) {
    if (!fx.snapshot()) {
      if (!fx.isEnabled) return { ok: false, error: "rates_disabled", message: "Currency rates are turned off in Settings." };
      return outcome === "failed" || fx.recentlyFailed()
        ? { ok: false, error: "rates_unavailable", message: "ECB reference rates could not be downloaded." }
        : { ok: false, error: "rates_unavailable", message: "Downloading ECB reference rates. Try again in a moment." };
    }
    const missing = fx.convert(1, from, "EUR") ? to : from;
    return { ok: false, error: "unknown_currency", message: `No ECB reference rate for ${missing}.` };
  }
  const digits = currencyDigits(to);
  return {
    ok: true,
    amount,
    from,
    to,
    value: conversion.value,
    rate: conversion.rate,
    asOf: conversion.asOf,
    freshness: conversion.freshness,
    label: conversion.label,
    display: `${formatNumber(conversion.value, locale, digits, digits)} ${to}`,
    copy: conversion.value.toFixed(digits),
    amountDisplay: `${formatNumber(amount, locale, 2)} ${from}`,
    rateDisplay: `1 ${from} = ${formatNumber(conversion.rate, locale, 4)} ${to}`,
  };
}

function waitFor<T>(promise: Promise<T>, ms: number, signal?: AbortSignal): Promise<T | undefined> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(undefined), ms);
    const onAbort = (): void => resolve(undefined);
    signal?.addEventListener("abort", onAbort, { once: true });
    promise.then((value) => resolve(value), () => resolve(undefined)).finally(() => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    });
  });
}

export function timeAt(place: PlaceZone, now: Date, locale: string, homeZone: string): TimeInResult {
  return { ok: true, place: place.place, ...zonedTime(place.zone, now, locale, homeZone) };
}

export function convertTimeWith(
  hour: number, minute: number, from: PlaceZone | null, to: PlaceZone, now: Date, locale: string, homeZone: string,
): TimeConvertResult {
  const fromZone = from?.zone ?? homeZone;
  const converted = convertWallTime(hour, minute, fromZone, to.zone, now, locale);
  return { ok: true, fromPlace: from?.place ?? "local time", toPlace: to.place, ...converted };
}

export function timeDiffWith(from: PlaceZone | null, to: PlaceZone, now: Date, homeZone: string): TimeDiffResult {
  return { ok: true, fromPlace: from?.place ?? "local time", toPlace: to.place, hours: zoneDiff(from?.zone ?? homeZone, to.zone, now) };
}

const weekdayFormatters = new Map<string, Intl.DateTimeFormat>();

function weekdayName(date: YMD, locale: string): string {
  let formatter = weekdayFormatters.get(locale);
  if (!formatter) {
    try {
      formatter = new Intl.DateTimeFormat(locale, { weekday: "long", timeZone: "UTC" });
    } catch {
      formatter = new Intl.DateTimeFormat("en-US", { weekday: "long", timeZone: "UTC" });
    }
    if (weekdayFormatters.size >= 128) weekdayFormatters.clear();
    weekdayFormatters.set(locale, formatter);
  }
  return formatter.format(new Date(Date.UTC(date.year, date.month - 1, date.day)));
}

export function evaluateDate(query: DateQuery, now: Date, locale: string): DateResult {
  const today = localToday(now);
  const shape = (date: YMD, extra: { days?: number; label?: string } = {}): DateResult => ({
    ok: true, op: query.op, date: isoDate(date), display: formatDate(date, locale), weekday: weekdayName(date, locale), ...extra,
  });
  switch (query.op) {
    case "today":
      return shape(today);
    case "days_until": {
      const date = nextOccurrence(query.target, today);
      return date ? shape(date, { days: daysBetween(today, date), label: query.label }) : { ok: false, error: "invalid_date" };
    }
    case "offset":
      return shape(addCalendar(today, query.amount, query.unit));
    case "weekday_in":
      return shape(weekdayIn(query.weekday, query.weeks, today));
    case "weekday_of": {
      const date = nextOccurrence(query.target, today);
      return date ? shape(date, { label: query.label }) : { ok: false, error: "invalid_date" };
    }
  }
}

export async function searchFilesWith(
  searchFiles: SearchFiles | undefined, query: FileQuery, now: Date, signal: AbortSignal,
  options: { contextId?: string; maxResults?: number } = {},
): Promise<FilesResult> {
  if (!searchFiles) return { ok: false, error: "unavailable" };
  if (!query.terms.length) return { ok: false, error: "invalid_query" };
  let raw: FileSearchResult | readonly FileCandidate[];
  try {
    raw = await searchFiles(buildFileSearchRequest(query, options), signal);
  } catch {
    return { ok: false, error: signal.aborted ? "timeout" : "unavailable" };
  }
  const items = Array.isArray(raw) ? raw as readonly FileCandidate[] : (raw as FileSearchResult)?.items;
  if (!Array.isArray(items)) return { ok: false, error: "unavailable" };
  // Rows bind openFile/revealFile/copyPath to the token, so a malformed one would make the whole card invalid.
  const usable = items.filter((item) => parseHostAction({ type: "openFile", token: (item as Partial<FileCandidate> | null)?.token }) !== null);
  const ranked = rankFiles(usable, {
    terms: query.terms,
    ...(query.contentType ? { contentType: query.contentType } : {}),
    ...(query.range ? { range: query.range } : {}),
  }, now.getTime());
  return { ok: true, files: ranked.files, relaxed: ranked.relaxed, truncated: !Array.isArray(raw) && (raw as FileSearchResult).truncated === true };
}

// ---------------------------------------------------------------- string API for tools

export interface InstantEngines {
  /** Exact calculator (fend): arithmetic, %, units, bases. Raycast percent forms ("80 + 15%") apply. */
  calc(expression: string): Promise<CalcResult>;
  /** ECB reference-rate conversion; `from`/`to` are ISO codes or names ("dollars"). */
  convertCurrency(amount: number, from: string, to: string, options?: { signal?: AbortSignal; waitMs?: number }): Promise<CurrencyResult>;
  /** Current time in a city/country/zone ("tokyo", "Asia/Kolkata", "pst"). */
  timeIn(place: string): Promise<TimeInResult>;
  /** Wall time in `from` (null = the user's zone) → `to`; time like "17:00", "5pm", "5:30 pm". */
  convertTime(time: string, from: string | null, to: string): Promise<TimeConvertResult>;
  /** Hours `to` is ahead of `from` (null = the user's zone). */
  timeDifference(from: string | null, to: string): Promise<TimeDiffResult>;
  /** "days until christmas", "in 3 weeks", "monday in 2 weeks", "welcher Wochentag ist der 3. Oktober". */
  dateMath(question: string): Promise<DateResult>;
  /** Host Spotlight search ranked in Node. Results carry host tokens; callers must not expose paths to models. */
  findFiles(query: string, options?: { contentType?: string; contextId?: string; maxResults?: number; signal?: AbortSignal }): Promise<FilesResult>;
  /** Apps from the host index matching a name/alias/initials. */
  matchApps(query: string, options?: { limit?: number; signal?: AbortSignal }): Promise<AppsResult>;
  /** Preloads fend and the rate cache (no network). */
  warm(): Promise<void>;
}

const CLOCK_TEXT = /^(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|uhr)?$/i;

export function createInstantEngines(deps: InstantDeps = {}): InstantEngines {
  const fend = deps.fend ?? createFendLoader();
  const now = deps.now ?? (() => new Date());
  const homeZone = deps.localZone ?? systemZone;
  const locale = deps.locale ?? "en-US";
  const timeoutMs = deps.calcTimeoutMs ?? FEND_DEFAULT_TIMEOUT_MS;

  const safe = async <T>(run: () => Promise<T> | T, fallback: T): Promise<T> => {
    try {
      return await run();
    } catch {
      return fallback;
    }
  };

  return {
    calc: (expression) => safe(async () => {
      if (typeof expression !== "string" || !expression.trim()) return { ok: false, error: "empty" };
      if (expression.length > FEND_MAX_INPUT) return { ok: false, error: "too_long" };
      const engine = await fend.get();
      return evaluateWith(engine, applyPercentSemantics(expression.trim()), locale, timeoutMs);
    }, { ok: false, error: "engine_unavailable" } as CalcResult),

    convertCurrency: (amount, from, to, options = {}) => safe(
      () => convertCurrencyWith(deps.fx, Number(amount), String(from), String(to), locale, { waitMs: options.waitMs ?? 3_000, ...(options.signal ? { signal: options.signal } : {}) }),
      { ok: false, error: "rates_unavailable", message: "Currency rates are not available." } as CurrencyResult,
    ),

    timeIn: (place) => safe(() => {
      const zone = resolvePlace(String(place));
      return zone ? timeAt(zone, now(), locale, homeZone()) : { ok: false, error: "unknown_place" };
    }, { ok: false, error: "unknown_place" } as TimeInResult),

    convertTime: (time, from, to) => safe(() => {
      const m = CLOCK_TEXT.exec(String(time).trim());
      if (!m) return { ok: false, error: "invalid_time" };
      let hour = Number(m[1]);
      const minute = Number(m[2] ?? 0);
      const marker = m[3]?.toLowerCase();
      if (marker === "pm" && hour < 12) hour += 12;
      if (marker === "am" && hour === 12) hour = 0;
      if (hour > 23 || minute > 59) return { ok: false, error: "invalid_time" };
      const fromPlace = from === null ? null : resolvePlace(String(from));
      const toPlace = resolvePlace(String(to));
      if ((from !== null && !fromPlace) || !toPlace) return { ok: false, error: "unknown_place" };
      return convertTimeWith(hour, minute, fromPlace, toPlace, now(), locale, homeZone());
    }, { ok: false, error: "invalid_time" } as TimeConvertResult),

    timeDifference: (from, to) => safe(() => {
      const fromPlace = from === null ? null : resolvePlace(String(from));
      const toPlace = resolvePlace(String(to));
      if ((from !== null && !fromPlace) || !toPlace) return { ok: false, error: "unknown_place" };
      return timeDiffWith(fromPlace, toPlace, now(), homeZone());
    }, { ok: false, error: "unknown_place" } as TimeDiffResult),

    dateMath: (question) => safe(() => {
      const parsed = matchDate(normalize(String(question)));
      return parsed?.kind === "date" ? evaluateDate(parsed.query, now(), locale) : { ok: false, error: "unparsed" };
    }, { ok: false, error: "unparsed" } as DateResult),

    findFiles: (query, options = {}) => safe(async () => {
      const text = String(query).trim();
      if (!text || text.length > 200) return { ok: false, error: "invalid_query" };
      const at = now();
      const parsed = matchFileSearch(normalize(`find ${text}`), { now: at, locale, webSearchTemplate: "" });
      const fileQuery: FileQuery = parsed?.kind === "file_search"
        ? parsed.query
        : { terms: text.toLowerCase().split(/\s+/).filter((term) => term.length <= 64).slice(0, 6), label: text };
      if (options.contentType) fileQuery.contentType = options.contentType;
      const signal = options.signal ?? AbortSignal.timeout(2_000);
      return searchFilesWith(deps.searchFiles, fileQuery, at, signal, {
        ...(options.contextId ? { contextId: options.contextId } : {}),
        ...(options.maxResults ? { maxResults: options.maxResults } : {}),
      });
    }, { ok: false, error: "unavailable" } as FilesResult),

    matchApps: (query, options = {}) => safe(async () => {
      if (!deps.apps) return { ok: false, error: "unavailable" };
      const matcher = await deps.apps.get(options.signal ?? AbortSignal.timeout(2_000));
      return matcher ? { ok: true, matches: matcher.match(String(query), options.limit ?? 8) } : { ok: false, error: "unavailable" };
    }, { ok: false, error: "unavailable" } as AppsResult),

    warm: () => safe(async () => {
      await Promise.all([fend.get(), deps.fx?.load()]);
    }, undefined),
  };
}
