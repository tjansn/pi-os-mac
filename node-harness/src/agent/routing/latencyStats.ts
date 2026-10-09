import { join } from "node:path";
import { getOverflowPatterns } from "@earendil-works/pi-ai";
import { supportDirectory } from "../../platformPaths.js";
import { readJsonObjectFile, writeJsonFileAtomic } from "../../settingsFile.js";
import { targetKey, type LatencyView, type StatEntry, type TierChoice } from "./types.js";

/**
 * Local latency telemetry and provider health for the Auto router
 * (routing.md §6.9). Ranking uses the EWMA of a model@level once it has
 * TRUSTED_SAMPLES samples, or at once when it is far worse than the prior
 * (decide.ts expectedTtft), otherwise the prior.
 *
 * Persisted to <supportDir>/routing-stats.json: model ids, sample counts,
 * EWMAs, error counts and health blocks. Never prompts, outputs or any content.
 */

export type HealthReason = "rate_limit" | "overloaded" | "quota" | "auth" | "context" | "error";

export interface HealthBlock {
  provider: string;
  /** Omitted: the whole provider is blocked (quota/auth). */
  model?: string;
  /** Epoch ms. */
  until: number;
  reason: HealthReason;
}

/** Default penalties (routing.md §6.6): transient throttles briefly, exhausted quota for a while. */
export const HEALTH_PENALTY_MS: Readonly<Record<HealthReason, number>> = {
  rate_limit: 60_000,
  overloaded: 60_000,
  quota: 30 * 60_000,
  auth: 10 * 60_000,
  context: 0,
  error: 0,
};

export interface LatencySample {
  provider: string;
  model: string;
  thinkingLevel: string;
  /** Request start → first text/thinking delta. */
  ttftMs?: number;
  /** Measured output throughput; or derive it from outputTokens / streamMs. */
  tokensPerSecond?: number;
  outputTokens?: number;
  /** First delta → message end. */
  streamMs?: number;
}

interface StoredEntry extends StatEntry {
  errors: number;
  lastErrorAt: number;
  updatedAt: number;
}

interface StoredFile {
  version: 1;
  models: Record<string, StoredEntry>;
  blocks: HealthBlock[];
}

export interface LatencyStatsOptions {
  /** routing-stats.json path; undefined keeps the stats in memory only. */
  path?: string;
  now?: () => number;
  /** EWMA weight of a new sample (default DEFAULT_STATS_ALPHA). */
  alpha?: number;
  /** Debounce for disk writes; 0 writes synchronously on every change. */
  persistDelayMs?: number;
  maxEntries?: number;
  log?: (line: string) => void;
}

export const DEFAULT_STATS_FILE = "routing-stats.json";
/** Backend latency moves within hours (latency.md §7: Sol 1.7 s one day, 2.3–11 s the next): weigh new samples heavily. */
export const DEFAULT_STATS_ALPHA = 0.5;
const KEY = /^[A-Za-z0-9._:/@+-]{1,240}$/;
const MAX_FILE_BYTES = 262_144;
/** Throughput from tiny answers is mostly overhead; ignore it. */
const MIN_TOKENS_FOR_TPS = 16;
const MAX_TTFT_MS = 15 * 60_000;
const REASONS: readonly HealthReason[] = ["rate_limit", "overloaded", "quota", "auth", "context", "error"];

export function defaultStatsPath(): string {
  return join(supportDirectory(), DEFAULT_STATS_FILE);
}

const finite = (value: unknown, min = 0, max = Number.MAX_SAFE_INTEGER): value is number =>
  typeof value === "number" && Number.isFinite(value) && value >= min && value <= max;

export class LatencyStats implements LatencyView {
  private readonly entries = new Map<string, StoredEntry>();
  private blocks: HealthBlock[] = [];
  private readonly now: () => number;
  private readonly alpha: number;
  private readonly persistDelayMs: number;
  private readonly maxEntries: number;
  private readonly log: (line: string) => void;
  private timer?: ReturnType<typeof setTimeout>;

  constructor(private readonly options: LatencyStatsOptions = {}) {
    this.now = options.now ?? Date.now;
    this.alpha = options.alpha ?? DEFAULT_STATS_ALPHA;
    this.persistDelayMs = options.persistDelayMs ?? 2_000;
    this.maxEntries = options.maxEntries ?? 200;
    this.log = options.log ?? ((line) => console.log(line));
    if (options.path) this.load(options.path);
  }

  private load(path: string): void {
    const { data, status } = readJsonObjectFile(path, MAX_FILE_BYTES);
    if (status === "corrupt") this.log("[route] ignoring unreadable routing stats");
    const models = data.models;
    if (typeof models === "object" && models !== null && !Array.isArray(models)) {
      for (const [key, raw] of Object.entries(models as Record<string, unknown>)) {
        if (!KEY.test(key) || typeof raw !== "object" || raw === null) continue;
        const e = raw as Record<string, unknown>;
        if (!finite(e.n) || !finite(e.ttftMs, 0, MAX_TTFT_MS) || !finite(e.tpsN) || !finite(e.tps, 0, 100_000)) continue;
        this.entries.set(key, {
          n: Math.floor(e.n), ttftMs: e.ttftMs, tpsN: Math.floor(e.tpsN), tps: e.tps,
          errors: finite(e.errors) ? Math.floor(e.errors) : 0,
          lastErrorAt: finite(e.lastErrorAt) ? e.lastErrorAt : 0,
          updatedAt: finite(e.updatedAt) ? e.updatedAt : 0,
        });
      }
    }
    if (Array.isArray(data.blocks)) {
      const now = this.now();
      for (const raw of data.blocks as unknown[]) {
        if (typeof raw !== "object" || raw === null) continue;
        const b = raw as Record<string, unknown>;
        if (typeof b.provider !== "string" || !KEY.test(b.provider)) continue;
        if (b.model !== undefined && (typeof b.model !== "string" || !KEY.test(b.model))) continue;
        if (!finite(b.until) || b.until <= now || !REASONS.includes(b.reason as HealthReason)) continue;
        this.blocks.push({ provider: b.provider, ...(b.model ? { model: b.model as string } : {}), until: b.until, reason: b.reason as HealthReason });
      }
    }
    this.trim();
  }

  get(key: string): StatEntry | undefined {
    const e = this.entries.get(key);
    return e && { n: e.n, ttftMs: e.ttftMs, tpsN: e.tpsN, tps: e.tps };
  }

  getFor(choice: TierChoice): StatEntry | undefined {
    return this.get(targetKey(choice));
  }

  /** One successful response's timings (ids and numbers only). */
  record(sample: LatencySample): void {
    const key = `${sample.provider}/${sample.model}@${sample.thinkingLevel}`;
    if (!KEY.test(key)) return;
    const entry = this.entries.get(key) ?? { n: 0, ttftMs: 0, tpsN: 0, tps: 0, errors: 0, lastErrorAt: 0, updatedAt: 0 };
    let changed = false;
    if (finite(sample.ttftMs, 0, MAX_TTFT_MS)) {
      entry.ttftMs = entry.n === 0 ? sample.ttftMs : entry.ttftMs + this.alpha * (sample.ttftMs - entry.ttftMs);
      entry.n++;
      changed = true;
    }
    const tps = finite(sample.tokensPerSecond, 0.1, 100_000) ? sample.tokensPerSecond
      : finite(sample.outputTokens, MIN_TOKENS_FOR_TPS) && finite(sample.streamMs, 1) ? sample.outputTokens / (sample.streamMs / 1_000)
        : undefined;
    if (tps !== undefined && tps <= 100_000) {
      entry.tps = entry.tpsN === 0 ? tps : entry.tps + this.alpha * (tps - entry.tps);
      entry.tpsN++;
      changed = true;
    }
    if (!changed) return;
    entry.updatedAt = this.now();
    this.entries.set(key, entry);
    this.trim();
    this.schedule();
  }

  /** Count a failed response (diagnostics; ranking uses health blocks, not error counts). */
  recordError(choice: Pick<LatencySample, "provider" | "model" | "thinkingLevel">): void {
    const key = `${choice.provider}/${choice.model}@${choice.thinkingLevel}`;
    if (!KEY.test(key)) return;
    const entry = this.entries.get(key) ?? { n: 0, ttftMs: 0, tpsN: 0, tps: 0, errors: 0, lastErrorAt: 0, updatedAt: 0 };
    entry.errors++;
    entry.lastErrorAt = entry.updatedAt = this.now();
    this.entries.set(key, entry);
    this.trim();
    this.schedule();
  }

  /** Keep the router off a model (or a whole provider) until the block expires. */
  block(provider: string, durationMs: number, reason: HealthReason, model?: string): void {
    if (!KEY.test(provider) || (model !== undefined && !KEY.test(model)) || !finite(durationMs, 1)) return;
    const until = this.now() + durationMs;
    this.blocks = this.active().filter(b => !(b.provider === provider && b.model === model));
    this.blocks.push({ provider, ...(model ? { model } : {}), until, reason });
    this.log(`[route] health block provider=${provider}${model ? ` model=${model}` : ""} reason=${reason} s=${Math.round(durationMs / 1_000)}`);
    this.schedule();
  }

  blocked(provider: string, id: string): boolean {
    const now = this.now();
    return this.blocks.some(b => b.until > now && b.provider === provider && (b.model === undefined || b.model === id));
  }

  /** Unexpired blocks (diagnostics). */
  active(): HealthBlock[] {
    const now = this.now();
    return this.blocks.filter(b => b.until > now);
  }

  snapshot(): StoredFile {
    return {
      version: 1,
      models: Object.fromEntries([...this.entries].sort(([a], [b]) => a.localeCompare(b))),
      blocks: this.active(),
    };
  }

  /** Write pending changes now (also called by the debounce timer). */
  flush(): void {
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    if (!this.options.path) return;
    try {
      writeJsonFileAtomic(this.options.path, this.snapshot());
    } catch (error) {
      this.log(`[route] failed saving routing stats: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private schedule(): void {
    if (!this.options.path) return;
    if (this.persistDelayMs <= 0) { this.flush(); return; }
    if (this.timer) return;
    this.timer = setTimeout(() => { this.timer = undefined; this.flush(); }, this.persistDelayMs);
    this.timer.unref?.();
  }

  private trim(): void {
    if (this.entries.size <= this.maxEntries) return;
    const oldest = [...this.entries].sort(([, a], [, b]) => a.updatedAt - b.updatedAt);
    for (const [key] of oldest.slice(0, this.entries.size - this.maxEntries)) this.entries.delete(key);
  }
}

export type ProviderErrorKind = "rate_limit" | "overloaded" | "context" | "quota" | "auth" | "transient" | "other";

const QUOTA = /insufficient_quota|quota exceeded|out of budget|billing|usage.?limit|subscription_sharing_usage_limit_exceeded|monthly usage limit|available balance/i;
const RATE_LIMIT = /rate.?limit|too many requests|\b429\b|resourceexhausted/i;
const OVERLOADED = /overloaded|high demand|at capacity|\b50[23]\b|\b529\b|service.?unavailable/i;
/** pi-ai's own provider overflow messages ("context deadline exceeded" or "took too long" are not overflows). */
const CONTEXT = getOverflowPatterns();
const AUTH = /\b40[13]\b|unauthori[sz]ed|forbidden|invalid api key|authentication|expired token|re-?authenticate|\/login/i;
const TRANSIENT = /network|connection|timed? ?out|timeout|deadline exceeded|socket|fetch failed|websocket|ECONN|ENOTFOUND|EAI_AGAIN|terminated|ended without|\b50[04]\b|\b52[04]\b|internal.?error|server.?error/i;

/** Map a provider errorMessage to a failover class (quota first: it is not retryable). */
export function classifyProviderError(message: string | undefined): ProviderErrorKind {
  const text = message ?? "";
  if (QUOTA.test(text)) return "quota";
  if (RATE_LIMIT.test(text)) return "rate_limit";
  if (OVERLOADED.test(text)) return "overloaded";
  if (CONTEXT.some(pattern => pattern.test(text))) return "context";
  if (AUTH.test(text)) return "auth";
  if (TRANSIENT.test(text)) return "transient";
  return "other";
}
