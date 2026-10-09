import { randomUUID } from "node:crypto";
import type { CardSpec } from "./contracts/cards.js";

/**
 * In-memory invocation registry backing GET /invocations/{id} and the SSE
 * stream GET /invocations/{id}/events (protocol.md: state machine
 * queued -> running -> completed | failed, plus the A.3 terminal states
 * aborted | timed_out).
 *
 * Every mutation bumps `revision` and notifies that record's subscribers, so
 * streaming hosts can send each change once; polling hosts (Windows) keep
 * reading the same record. All fields added for voice magic are optional.
 */

export type InvocationState =
  | "queued"
  | "running"
  | "completed"
  | "failed"
  | "aborted"
  | "timed_out";

export const TERMINAL_STATES: ReadonlySet<InvocationState> = new Set(["completed", "failed", "aborted", "timed_out"]);

export interface InvocationStep {
  tool: string;
  at: string;
  ok: boolean;
  detail?: string;
}

/** Model the turn actually ran on (ids and content-free labels only). */
export interface InvocationRoute {
  /** Router tier; absent for a manually selected model. */
  tier?: string;
  provider: string;
  model: string;
  thinkingLevel: string;
  reasons: string[];
  /** True when the session runs on the `pi-os/auto` virtual model. */
  auto: boolean;
}

export interface InvocationRecord {
  invocationId: string;
  contextId: string;
  prompt: string;
  invokedAt: string;
  state: InvocationState;
  startedAt?: string;
  finishedAt?: string | null;
  steps: InvocationStep[];
  /** Increases with every change of this record (SSE / change detection). */
  revision: number;
  /** Live activity line for the host pill ("thinking", tool name); absent when idle. */
  activity?: string;
  /** Visible text of the assistant message currently streaming; cleared when the turn ends. */
  partialText?: string;
  /** Final agent answer, capped; present once completed. */
  responseText?: string;
  /** Result card (pi-os-ui/1). Partial while `cardComplete` is false; buttons stay disabled until then. */
  card?: CardSpec;
  cardComplete?: boolean;
  route?: InvocationRoute;
  /** How the request was entered; never the transcript metadata itself. */
  input?: { mode: "text" | "voice" };
  /** Per-stage milliseconds (contextMs, sessionMs, ttftMs, totalMs, …). */
  timings?: Record<string, number>;
  /** Why the invocation failed/aborted/timed out; terminal failure states only. */
  failureMessage?: string;
  /** True only while this record owns an open thread. */
  followupAvailable?: boolean;
}

const MAX_RECORDS = 200;
const MAX_RESPONSE_CHARS = 8_000;
const MAX_PARTIAL_CHARS = 8_000;

const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;

/** Replaces lone UTF-16 surrogates with U+FFFD (String.prototype.toWellFormed, which ES2023 lib typings lack). */
export function wellFormed(text: string): string {
  return text.replace(LONE_SURROGATE, "\uFFFD");
}

/**
 * At most `max` UTF-16 units (plus `suffix` when cut), never ending inside a surrogate pair and
 * always well-formed: hosts decode records strictly, and a lone surrogate (a split emoji) would
 * fail the whole record in Swift's JSONDecoder.
 */
export function clip(text: string, max: number, suffix = ""): string {
  if (text.length <= max) return wellFormed(text);
  const code = text.charCodeAt(max - 1);
  const end = code >= 0xd800 && code <= 0xdbff ? max - 1 : max;
  return wellFormed(text.slice(0, end)) + suffix;
}
const MAX_ROUTE_REASONS = 16;

type Listener = () => void;

export class InvocationStore {
  private readonly records = new Map<string, InvocationRecord>();
  private readonly listeners = new Map<string, Set<Listener>>();

  create(contextId: string, prompt: string, invokedAt: string, invocationId = `inv-${randomUUID().replaceAll("-", "")}`): InvocationRecord {
    const record: InvocationRecord = {
      invocationId,
      contextId,
      prompt: wellFormed(prompt),
      invokedAt,
      state: "queued",
      steps: [],
      revision: 1,
    };
    this.records.set(record.invocationId, record);
    if (this.records.size > MAX_RECORDS) {
      const oldest = this.records.keys().next().value;
      if (oldest !== undefined) {
        this.records.delete(oldest);
        this.notify(oldest);
      }
    }

    return record;
  }

  get(id: string): InvocationRecord | undefined {
    return this.records.get(id);
  }

  /** Called after every change of `id` (and once when it is evicted). Returns the unsubscribe function. */
  subscribe(id: string, listener: Listener): () => void {
    let set = this.listeners.get(id);
    if (!set) this.listeners.set(id, set = new Set());
    set.add(listener);
    return () => {
      const current = this.listeners.get(id);
      current?.delete(listener);
      if (current?.size === 0) this.listeners.delete(id);
    };
  }

  start(id: string): void {
    this.mutate(id, (r) => {
      r.state = "running";
      r.startedAt = new Date().toISOString();
    });
  }

  addStep(id: string, tool: string, ok: boolean, detail?: string): void {
    this.mutate(id, (r) => {
      r.steps.push({ tool, at: new Date().toISOString(), ok, ...(detail !== undefined ? { detail: wellFormed(detail) } : {}) });
    });
  }

  requeueForFollowup(id: string, prompt: string): boolean {
    const record = this.records.get(id);
    if (!record || record.state === "queued" || record.state === "running") return false;
    this.mutate(id, (r) => {
      r.prompt = wellFormed(prompt); r.state = "queued";
      delete r.startedAt; delete r.finishedAt; delete r.activity; delete r.partialText;
      delete r.responseText; delete r.failureMessage; delete r.card; delete r.cardComplete;
      delete r.route; delete r.timings; delete r.input;
    });
    return true;
  }

  /** Publish/clear the live activity line (result-surfacing pill). An unchanged value is no new revision. */
  setActivity(id: string, activity: string | undefined): void {
    const next = activity === undefined ? undefined : clip(activity, 80);
    if (this.records.get(id)?.activity === next) return;
    this.mutate(id, (r) => {
      if (next === undefined) delete r.activity;
      else r.activity = next;
    });
  }

  /** Streaming answer text (already accumulated by the caller); capped like responseText. */
  setPartialText(id: string, text: string | undefined): void {
    const next = text ? clip(text, MAX_PARTIAL_CHARS, "…") : undefined;
    if (this.records.get(id)?.partialText === next) return;
    this.mutate(id, (r) => {
      if (next === undefined) delete r.partialText;
      else r.partialText = next;
    });
  }

  /** Persist the final answer, capped so records stay small. */
  setResponse(id: string, text: string): void {
    this.mutate(id, (r) => {
      r.responseText = clip(text.trim(), MAX_RESPONSE_CHARS, "… [truncated]");
    });
  }

  /** Show a card; `complete` false marks a streaming partial whose actions must stay disabled. */
  setCard(id: string, card: CardSpec, complete: boolean): void {
    this.mutate(id, (r) => {
      r.card = card;
      r.cardComplete = complete;
    });
  }

  clearCard(id: string): void {
    const record = this.records.get(id);
    if (!record || (record.card === undefined && record.cardComplete === undefined)) return;
    this.mutate(id, (r) => {
      delete r.card;
      delete r.cardComplete;
    });
  }

  setRoute(id: string, route: InvocationRoute): void {
    this.mutate(id, (r) => {
      r.route = { ...route, reasons: route.reasons.slice(0, MAX_ROUTE_REASONS) };
    });
  }

  setInput(id: string, input: { mode: "text" | "voice" } | undefined): void {
    this.mutate(id, (r) => {
      if (input) r.input = { mode: input.mode };
      else delete r.input;
    });
  }

  /** Merge stage timings (rounded to 0.1 ms). */
  setTimings(id: string, timings: Record<string, number>): void {
    const entries = Object.entries(timings).filter(([, ms]) => Number.isFinite(ms));
    if (!entries.length) return;
    this.mutate(id, (r) => {
      r.timings = { ...r.timings, ...Object.fromEntries(entries.map(([key, ms]) => [key, Math.round(ms * 10) / 10])) };
    });
  }

  setFollowupAvailable(id: string, available: boolean): void {
    const record = this.records.get(id);
    if (!record || record.followupAvailable === available) return;
    this.mutate(id, (r) => { r.followupAvailable = available; });
  }

  finish(
    id: string,
    state: Extract<InvocationState, "completed" | "failed" | "aborted" | "timed_out">,
    failureMessage?: string,
  ): void {
    this.mutate(id, (r) => {
      r.state = state;
      r.finishedAt = new Date().toISOString();
      delete r.activity;
      delete r.partialText;
      if (failureMessage !== undefined && state !== "completed") {
        r.failureMessage = clip(failureMessage, 2_000);
      }
    });
  }

  private mutate(id: string, mutate: (record: InvocationRecord) => void): void {
    const record = this.records.get(id);
    if (record) {
      mutate(record);
      record.revision++;
      this.notify(id);
    }
  }

  private notify(id: string): void {
    for (const listener of [...(this.listeners.get(id) ?? [])]) {
      try { listener(); } catch { /* A broken stream must never fail the invocation. */ }
    }
  }
}
