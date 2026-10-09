/**
 * Latency instrumentation: one console line per measured stage,
 *   [perf] stage=<stage> ms=<n> key=value ...
 * Fields carry kinds, counts, durations and model ids only. Never pass prompts,
 * transcripts, typed text, classifier inputs or file paths (DESIGN.md §1.6).
 * Values are reduced to a single-token charset and capped, so one call is always
 * one parseable line even if a caller slips.
 */

export type PerfFields = Record<string, string | number | boolean>;

const MAX_VALUE_LENGTH = 80;
const RESERVED = new Set(["stage", "ms"]);

/** Monotonic elapsed/lap timer (performance.now; injectable clock for tests). */
export class Stopwatch {
  private readonly started: number;
  private last: number;
  constructor(private readonly clock: () => number = () => performance.now()) {
    this.started = this.last = clock();
  }
  /** Milliseconds since construction. */
  elapsed(): number { return this.clock() - this.started; }
  /** Milliseconds since the previous lap (or construction); starts the next lap. */
  lap(): number {
    const now = this.clock();
    const ms = now - this.last;
    this.last = now;
    return ms;
  }
}

function token(value: string, fallback: string): string {
  const cleaned = value.replace(/[^A-Za-z0-9_.:/@+-]/g, "_").slice(0, MAX_VALUE_LENGTH);
  return cleaned || fallback;
}

function formatNumber(value: number): string {
  return Number.isFinite(value) ? String(Math.round(value * 10) / 10) : "NaN";
}

export function formatPerfLine(stage: string, ms: number, fields: PerfFields = {}): string {
  const parts = [`[perf] stage=${token(stage, "unknown")}`, `ms=${formatNumber(ms)}`];
  for (const [key, value] of Object.entries(fields)) {
    const name = token(key, "_");
    if (RESERVED.has(name)) continue;
    parts.push(`${name}=${typeof value === "number" ? formatNumber(value) : typeof value === "boolean" ? String(value) : token(value, "")}`);
  }
  return parts.join(" ");
}

export function perfLog(stage: string, ms: number, fields?: PerfFields): void {
  console.log(formatPerfLine(stage, ms, fields));
}
