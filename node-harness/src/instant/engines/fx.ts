import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { supportDirectory } from "../../platformPaths.js";
import { dayNumber, easterSunday, fromDayNumber, isoDate, weekday, ymdNumber, type YMD } from "./dates.js";
import { wallTime } from "./timezones.js";

/**
 * ECB euro foreign exchange reference rates (daily XML, ~1.5 KB, EUR base).
 *
 * This is pi-os's only non-provider egress from Node, so it is strictly on
 * demand: nothing is fetched until the first currency query, every fetch is a
 * conditional GET (If-Modified-Since → 304), the result is cached on disk and
 * a Settings toggle can disable it. Rates are labelled as ECB reference rates
 * for information only; the ECB discourages using them for transactions.
 * Logs carry the HTTP status only.
 */

export const ECB_DAILY_URL = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml";
const MAX_XML_BYTES = 256 * 1024;
const HOUR_MS = 3_600_000;

export interface FxSnapshot {
  source: "ecb-eurofxref-daily";
  base: "EUR";
  /** <Cube time='YYYY-MM-DD'> */
  asOf: string;
  /** ISO time of the last successful fetch (200 or 304). */
  fetchedAt: string;
  /** HTTP Last-Modified, replayed as If-Modified-Since. */
  lastModified?: string;
  /** Units per 1 EUR; includes EUR: 1. */
  rates: Record<string, number>;
}

export type FxFreshness = "fresh" | "aging" | "stale" | "missing";
export type FxRefreshOutcome = "updated" | "not_modified" | "failed" | "disabled";

export interface FxConversion {
  amount: number;
  from: string;
  to: string;
  value: number;
  /** 1 `from` in `to`. */
  rate: number;
  asOf: string;
  freshness: FxFreshness;
  label: string;
}

export interface EcbRateStoreOptions {
  /** Cache file; default `<support dir>/cache/fx-ecb.json`. */
  file?: string;
  /** Injected in tests; production uses the global fetch at call time. */
  fetch?: typeof fetch;
  now?: () => Date;
  /** Settings: "Fetch currency rates from the ECB". Default on. */
  enabled?: () => boolean;
  url?: string;
  timeoutMs?: number;
  /** After a failed download, no new attempt for this long (default 60 s), so typing never re-fetches per keystroke. */
  retryAfterFailureMs?: number;
  log?: (line: string) => void;
}

export function defaultFxCacheFile(): string {
  return join(supportDirectory(), "cache", "fx-ecb.json");
}

/** Tiny tolerant parser for eurofxref-daily.xml. Null when no date or no valid rate is present. */
/**
 * The body as text, or null when it is (or announces itself as) larger than `max` bytes. Reads
 * the stream with a byte cap instead of buffering an arbitrarily large response first.
 */
async function readCapped(response: Response, max: number): Promise<string | null> {
  const declared = Number(response.headers.get("content-length") ?? "");
  if (Number.isFinite(declared) && declared > max) {
    await response.body?.cancel().catch(() => {});
    return null;
  }
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > max) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } catch {
    return null;
  }
  return Buffer.concat(chunks).toString("utf8");
}

export function parseEcbXml(xml: string): { asOf: string; rates: Record<string, number> } | null {
  if (xml.length > MAX_XML_BYTES) return null;
  const time = /<Cube\s+time=['"](\d{4}-\d{2}-\d{2})['"]/.exec(xml);
  if (!time) return null;
  const rates: Record<string, number> = { EUR: 1 };
  let count = 0;
  for (const match of xml.matchAll(/<Cube\s+currency=['"]([A-Z]{3})['"]\s+rate=['"]([0-9]+(?:\.[0-9]+)?)['"]\s*\/>/g)) {
    const rate = Number(match[2]);
    if (Number.isFinite(rate) && rate > 0) {
      rates[match[1]!] = rate;
      count++;
    }
  }
  return count ? { asOf: time[1]!, rates } : null;
}

function isSnapshot(value: unknown): value is FxSnapshot {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Partial<FxSnapshot>;
  return v.source === "ecb-eurofxref-daily" && v.base === "EUR" && typeof v.asOf === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v.asOf)
    && typeof v.fetchedAt === "string" && typeof v.rates === "object" && v.rates !== null
    && Object.values(v.rates).every((rate) => typeof rate === "number" && Number.isFinite(rate) && rate > 0);
}

/** TARGET2 closing days: weekends, New Year, Good Friday, Easter Monday, 1 May, 25/26 December. */
export function isTargetDay(date: YMD): boolean {
  const day = weekday(date);
  if (day === 0 || day === 6) return false;
  const md = `${date.month}-${date.day}`;
  if (md === "1-1" || md === "5-1" || md === "12-25" || md === "12-26") return false;
  const easter = ymdNumber(easterSunday(date.year));
  const n = ymdNumber(date);
  return n !== easter - 2 && n !== easter + 1;
}

function berlinDay(now: Date): YMD & { minutes: number } {
  const w = wallTime("Europe/Berlin", now);
  return { year: w.year, month: w.month, day: w.day, minutes: w.hour * 60 + w.minute };
}

function parseIsoDay(value: string): number {
  const [y, m, d] = value.split("-").map(Number);
  return dayNumber(y ?? 1970, m ?? 1, d ?? 1);
}

/**
 * fresh: published today or on the previous TARGET day (weekends/holidays
 * keep Friday's rate fresh) · aging: 2–4 calendar days · stale: older.
 */
export function fxFreshness(snapshot: FxSnapshot | null, now: Date): FxFreshness {
  if (!snapshot) return "missing";
  const today = berlinDay(now);
  const todayN = ymdNumber(today);
  let previous = todayN - 1;
  while (!isTargetDay(fromDayNumber(previous))) previous--;
  const asOf = parseIsoDay(snapshot.asOf);
  if (asOf >= previous) return "fresh";
  return todayN - asOf <= 4 ? "aging" : "stale";
}

export function fxFreshnessLabel(snapshot: FxSnapshot | null): string {
  return snapshot ? `ECB reference rate ${snapshot.asOf} · info only` : "ECB reference rates not downloaded yet";
}

/**
 * Whether a currency query should trigger a (background) conditional GET:
 * no snapshot; last fetch ≥ 6 h ago; or a TARGET day after the ~16:00 CET
 * publication while the snapshot is not today's (at most hourly).
 */
export function fxNeedsRefresh(snapshot: FxSnapshot | null, now: Date): boolean {
  if (!snapshot) return true;
  const age = now.getTime() - Date.parse(snapshot.fetchedAt);
  if (!Number.isFinite(age) || age >= 6 * HOUR_MS) return true;
  const today = berlinDay(now);
  return isTargetDay(today) && today.minutes >= 16 * 60 + 15 && snapshot.asOf !== isoDate(today) && age >= HOUR_MS;
}

export class EcbRateStore {
  private readonly file: string;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => Date;
  private readonly enabled: () => boolean;
  private readonly url: string;
  private readonly timeoutMs: number;
  private readonly retryAfterFailureMs: number;
  private readonly log: (line: string) => void;
  private current: FxSnapshot | null = null;
  private loading: Promise<FxSnapshot | null> | undefined;
  private inflight: Promise<FxRefreshOutcome> | undefined;
  private failedAtMs: number | undefined;
  private changes = 0;

  constructor(options: EcbRateStoreOptions = {}) {
    this.file = options.file ?? defaultFxCacheFile();
    this.fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
    this.now = options.now ?? (() => new Date());
    this.enabled = options.enabled ?? (() => true);
    this.url = options.url ?? ECB_DAILY_URL;
    this.timeoutMs = options.timeoutMs ?? 5_000;
    this.retryAfterFailureMs = options.retryAfterFailureMs ?? 60_000;
    this.log = options.log ?? ((line) => console.log(line));
  }

  /** Increments whenever the rate table changes (callers rebuild derived engines). */
  get version(): number {
    return this.changes;
  }

  get isEnabled(): boolean {
    return this.enabled();
  }

  snapshot(): FxSnapshot | null {
    return this.current;
  }

  /** Reads the cache file once. Never throws; a missing or corrupt file means no snapshot. */
  load(): Promise<FxSnapshot | null> {
    this.loading ??= readFile(this.file, "utf8")
      .then((text) => {
        const parsed: unknown = JSON.parse(text);
        if (isSnapshot(parsed) && !this.current) {
          this.current = parsed;
          this.changes++;
        }
        return this.current;
      })
      .catch(() => this.current);
    return this.loading;
  }

  freshness(snapshot: FxSnapshot | null = this.current, now: Date = this.now()): FxFreshness {
    return fxFreshness(snapshot, now);
  }

  /** The last download failed less than `retryAfterFailureMs` ago. */
  recentlyFailed(now: Date = this.now()): boolean {
    return this.failedAtMs !== undefined && now.getTime() - this.failedAtMs < this.retryAfterFailureMs;
  }

  /** Due for a conditional GET and not backing off after a failure. */
  needsRefresh(now: Date = this.now()): boolean {
    return !this.recentlyFailed(now) && fxNeedsRefresh(this.current, now);
  }

  /**
   * Conditional GET; concurrent callers share one request. `signal` only stops
   * this caller from waiting (the shared fetch has its own timeout). Never throws.
   */
  refresh(signal?: AbortSignal): Promise<FxRefreshOutcome> {
    if (!this.enabled()) return Promise.resolve("disabled");
    if (!this.inflight) {
      const run = this.fetchOnce().catch((): FxRefreshOutcome => "failed");
      this.inflight = run;
      void run.then((outcome) => {
        this.failedAtMs = outcome === "failed" ? this.now().getTime() : undefined;
        if (this.inflight === run) this.inflight = undefined;
      });
    }
    const shared = this.inflight;
    if (!signal) return shared;
    if (signal.aborted) return Promise.resolve("failed");
    return new Promise((resolve) => {
      const onAbort = (): void => resolve("failed");
      signal.addEventListener("abort", onAbort, { once: true });
      shared.then((outcome) => {
        signal.removeEventListener("abort", onAbort);
        resolve(outcome);
      }, () => resolve("failed"));
    });
  }

  convert(amount: number, from: string, to: string): FxConversion | null {
    const snapshot = this.current;
    const fromRate = snapshot?.rates[from.toUpperCase()];
    const toRate = snapshot?.rates[to.toUpperCase()];
    if (!snapshot || fromRate === undefined || toRate === undefined || !Number.isFinite(amount)) return null;
    return {
      amount,
      from: from.toUpperCase(),
      to: to.toUpperCase(),
      value: (amount / fromRate) * toRate,
      rate: toRate / fromRate,
      asOf: snapshot.asOf,
      freshness: fxFreshness(snapshot, this.now()),
      label: fxFreshnessLabel(snapshot),
    };
  }

  private async fetchOnce(): Promise<FxRefreshOutcome> {
    await this.load();
    const previous = this.current;
    const headers: Record<string, string> = { accept: "application/xml, text/xml;q=0.9" };
    if (previous?.lastModified) headers["if-modified-since"] = previous.lastModified;
    let response: Response;
    try {
      response = await this.fetchImpl(this.url, { headers, signal: AbortSignal.timeout(this.timeoutMs) });
    } catch {
      this.log("[instant] ecb fx refresh status=error");
      return "failed";
    }
    const fetchedAt = this.now().toISOString();
    if (response.status === 304 && previous) {
      this.current = { ...previous, fetchedAt };
      this.log("[instant] ecb fx refresh status=304");
      await this.persist();
      return "not_modified";
    }
    if (response.status !== 200) {
      this.log(`[instant] ecb fx refresh status=${response.status}`);
      return "failed";
    }
    const body = await readCapped(response, MAX_XML_BYTES);
    const parsed = body === null ? null : parseEcbXml(body);
    if (!parsed) {
      this.log("[instant] ecb fx refresh status=200 parse=failed");
      return "failed";
    }
    const lastModified = response.headers.get("last-modified") ?? undefined;
    const changed = !previous || previous.asOf !== parsed.asOf || JSON.stringify(previous.rates) !== JSON.stringify(parsed.rates);
    this.current = { source: "ecb-eurofxref-daily", base: "EUR", asOf: parsed.asOf, fetchedAt, ...(lastModified ? { lastModified } : {}), rates: parsed.rates };
    if (changed) this.changes++;
    this.log(`[instant] ecb fx refresh status=200 currencies=${Object.keys(parsed.rates).length}`);
    await this.persist();
    return changed ? "updated" : "not_modified";
  }

  /** Atomic write (temp file + rename), owner-only permissions. Failure is logged, never thrown. */
  private async persist(): Promise<void> {
    if (!this.current) return;
    const temp = `${this.file}.${process.pid}.tmp`;
    try {
      await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
      await writeFile(temp, `${JSON.stringify(this.current)}\n`, { mode: 0o600 });
      await rename(temp, this.file);
    } catch {
      this.log("[instant] ecb fx cache write failed");
    }
  }
}
