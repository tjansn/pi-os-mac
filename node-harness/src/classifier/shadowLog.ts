import { appendFile, mkdir, stat } from "node:fs/promises";
import { dirname } from "node:path";
import { type AgentIntent, type ClassifierHints, type IntentClassifier, type Tier, TIERS } from "../contracts/instant.js";

/**
 * Opt-in shadow log (`shadowLog: true` in classifier.json): one JSON line per
 * classification with labels, probabilities and latency, for judging whether
 * an advisory classifier is worth promoting (laya.md §10). Never the
 * utterance, a hash of it, titles or paths: every field is whitelisted,
 * enum-checked and rounded, so a careless caller cannot leak content.
 * Stops (does not rotate or delete) once the file reaches its size cap.
 */

export const DEFAULT_SHADOW_LOG_MAX_BYTES = 5 * 1024 * 1024;

const AGENT_INTENTS: readonly AgentIntent[] = [
  "calculate", "search_computer", "open_launch", "answer", "write", "act_in_app", "browse_web", "code", "other",
];
const SOURCES: readonly ClassifierHints["source"][] = ["laya", "pi-classifier", "heuristic"];

export interface ShadowRecord {
  /** Classifier name, e.g. "laya" or "pi:cloudflare-workers-ai/typesafe/jev". */
  classifier: string;
  latencyMs: number;
  hints: ClassifierHints | null;
  /** Optional rule-derived decision for comparison (labels only). */
  reference?: { intent?: AgentIntent; tier?: Tier };
}

const probability = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? Math.round(Math.min(1, Math.max(0, value)) * 10_000) / 10_000 : undefined;
const intentOf = (value: unknown): AgentIntent | undefined =>
  AGENT_INTENTS.includes(value as AgentIntent) ? value as AgentIntent : undefined;
const tierOf = (value: unknown): Tier | undefined => TIERS.includes(value as Tier) ? value as Tier : undefined;
const name = (value: string): string => value.replace(/[^A-Za-z0-9_.:/@+-]/gu, "_").slice(0, 80) || "unknown";

/** One sanitized JSON line (with trailing newline). Undefined fields are omitted. */
export function formatShadowLine(record: ShadowRecord, now: Date = new Date()): string {
  const hints = record.hints;
  const latency = Number.isFinite(record.latencyMs) ? Math.min(600_000, Math.max(0, Math.round(record.latencyMs * 10) / 10)) : 0;
  const line: Record<string, unknown> = {
    ts: now.toISOString(),
    classifier: name(record.classifier),
    latencyMs: latency,
    outcome: hints ? "hints" : "null",
  };
  if (hints) {
    const source = SOURCES.includes(hints.source) ? hints.source : undefined;
    Object.assign(line, {
      source,
      intent: intentOf(hints.intent),
      intentP: probability(hints.intentP),
      tier: tierOf(hints.tier),
      tierP: probability(hints.tierP),
      needsScreen: probability(hints.needsScreen),
      complete: probability(hints.complete),
    });
  }
  if (record.reference) {
    line.reference = { intent: intentOf(record.reference.intent), tier: tierOf(record.reference.tier) };
  }
  return `${JSON.stringify(line)}\n`;
}

export class ShadowLogWriter {
  private written: number | undefined;
  private full = false;
  private queue: Promise<void> = Promise.resolve();
  private readonly maxBytes: number;
  private readonly log: (line: string) => void;

  constructor(readonly path: string, private readonly options: { maxBytes?: number; log?: (line: string) => void; now?: () => Date } = {}) {
    this.maxBytes = options.maxBytes ?? DEFAULT_SHADOW_LOG_MAX_BYTES;
    this.log = options.log ?? ((line) => console.log(line));
  }

  /** Fire-and-forget append; writes are serialized and failures never reach the caller. */
  record(record: ShadowRecord): void {
    if (this.full) return;
    const line = formatShadowLine(record, this.options.now?.() ?? new Date());
    this.queue = this.queue.then(() => this.append(line)).catch(() => {
      this.log("[classifier] shadow log write failed");
    });
  }

  /** Resolves once every queued record is written (tests, shutdown). */
  flush(): Promise<void> {
    return this.queue;
  }

  private async append(line: string): Promise<void> {
    if (this.written === undefined) {
      await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
      this.written = await stat(this.path).then((info) => info.size, () => 0);
    }
    const bytes = Buffer.byteLength(line);
    if (this.written + bytes > this.maxBytes) {
      if (!this.full) this.log("[classifier] shadow log reached its size cap; shadow logging paused");
      this.full = true;
      return;
    }
    await appendFile(this.path, line, { encoding: "utf8", mode: 0o600 });
    this.written += bytes;
  }
}

/** Decorate a classifier so every call (hint or null) lands in the shadow log. */
export function withShadowLog(
  classifier: IntentClassifier,
  writer: ShadowLogWriter,
  clock: () => number = () => performance.now(),
): IntentClassifier {
  return {
    name: classifier.name,
    async classify(text: string, signal: AbortSignal): Promise<ClassifierHints | null> {
      const started = clock();
      const hints = await classifier.classify(text, signal);
      writer.record({ classifier: classifier.name, latencyMs: clock() - started, hints });
      return hints;
    },
  };
}
