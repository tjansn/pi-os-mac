import type { AgentSession, AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage, ImageContent } from "@earendil-works/pi-ai";
import type { CardSpec } from "../contracts/cards.js";
import type { FileLedger } from "../ui/ledger.js";
import { ESCALATE_TOOL_NAME } from "./routing/escalate.js";
import { classifyProviderError, type ProviderErrorKind } from "./routing/latencyStats.js";
import type { AutoModelHandle, RouteEvent } from "./routing/autoModel.js";
import type { RoutingCatalog } from "./routing/types.js";
import { abortError, assistantMessageText, type AgentRunResult } from "./agentRunner.js";

export type SessionTransport = Pick<AgentSession, "prompt" | "subscribe" | "abort" | "dispose">;

/** One finished assistant response: ids, timings and counts only (never content). */
export interface ResponseSample {
  provider: string;
  model: string;
  thinkingLevel?: string;
  /** Request start (turn_start) → first text/thinking/tool-call delta. */
  ttftMs?: number;
  /** First delta → message end. */
  streamMs?: number;
  outputTokens?: number;
  ok: boolean;
  /** Classified provider error for failed responses (rate_limit, quota, …). */
  errorKind?: ProviderErrorKind;
}

/**
 * Per-prompt listeners. A prepared session is built before its invocation
 * exists, so the server rebinds these with observe() before each prompt.
 */
export interface SessionObserver {
  log: (line: string) => void;
  onToolCall?: (name: string) => void;
  onActivity?: (name: string | undefined) => void;
  /** Accumulated visible text of the assistant message currently streaming. */
  onPartialText?: (text: string) => void;
  /** show_result cards: partial (complete=false) while streaming, then the validated final one. */
  onCard?: (spec: CardSpec, complete: boolean) => void;
  /** A model-issued (top-level) tool finished. */
  onToolEnd?: (name: string, isError: boolean) => void;
  /** Auto routing step (user decision, escalation, failover). */
  onRoute?: (event: RouteEvent) => void;
  onResponse?: (sample: ResponseSample) => void;
}

/** Session parts the server needs between prompts (all optional: fixture transports have none). */
export interface SessionControls {
  /** Decision slot of the session's `pi-os/auto` registration; present only when the session runs on Auto. */
  auto?: AutoModelHandle;
  /** Routing catalog over the session runtime's available models (sync snapshot). */
  catalog?: () => RoutingCatalog;
  /** The session's thinking level (for Auto: the routing bias). */
  thinkingLevel?: () => string;
  /** The manually selected model, for the record's `route` when not on Auto. */
  manual?: { provider: string; model: string; thinkingLevel: string };
  /** Every tool this session may declare; per-turn narrowing selects from these. */
  toolNames?: readonly string[];
  setActiveTools?: (names: string[]) => void;
  /** Withdraw the coordinate authority seeded from the request screenshot (it was not attached). */
  revokeInitialScreenshot?: () => void;
  /** The screenshot the session was built with (its seeded coordinate authority), if any. */
  initialScreenshotId?: string;
  /** The thread's file-ref ledger (find_files refs ↔ host tokens, show_result rows). */
  ledger?: FileLedger;
  /** Build-time identity of a prepared session; reused only when it matches the invocation. */
  setupKey?: string;
}

const now = () => performance.now();

/** Owns one in-memory SDK history and its resources; never queues concurrent prompts. */
export class LiveAgentSession {
  private capture?: { responseText: string; toolCalls: number; providerError?: string };
  private closing?: Promise<void>;
  private closed = false;
  private readonly unsubscribe: () => void;
  private callbacks: SessionObserver;
  /** Per assistant response: request start, first delta, streamed text. */
  private response: { requestAt?: number; firstAt?: number; text: string } = { text: "" };
  constructor(
    private readonly session: SessionTransport,
    readonly lifetime: AbortController,
    callbacks: SessionObserver,
    private readonly cleanup: () => Promise<void> = async () => {},
    private readonly beforeTurn: () => void = () => {},
    readonly controls: SessionControls = {},
  ) {
    this.callbacks = callbacks;
    this.unsubscribe = session.subscribe(event => this.event(event));
  }

  /** Replace the listeners for the next prompt (e.g. a prepared session adopted by an invocation). */
  observe(callbacks: SessionObserver): void {
    this.callbacks = callbacks;
  }

  /** Extension hooks created with the session forward here, so they reach the current observer. */
  emitCard(spec: CardSpec, complete: boolean): void {
    if (this.closed) return;
    try { this.callbacks.onCard?.(spec, complete); } catch { /* Display problems never break the stream. */ }
  }

  emitRoute(event: RouteEvent): void {
    if (this.closed) return;
    try { this.callbacks.onRoute?.(event); } catch { /* Observers never break routing. */ }
  }

  get isClosed(): boolean {
    return this.closed;
  }

  private event(event: AgentSessionEvent) {
    const capture = this.capture;
    if (!capture || this.closed) return;
    if (event.type === "turn_start") {
      this.response = { requestAt: now(), text: "" };
    } else if (event.type === "message_start" && event.message.role === "assistant") {
      this.response = { ...(this.response.requestAt !== undefined ? { requestAt: this.response.requestAt } : {}), text: "" };
    } else if (event.type === "tool_execution_start") {
      // pi >= 0.99: calls a tool makes through ctx.executeTool() (e.g. codemode scripts) carry
      // parentToolCallId. They stay in the step log, but only model-issued calls are counted
      // and drive the activity marker (the parent call already shows as running).
      const nested = Boolean(event.parentToolCallId);
      if (!nested) capture.toolCalls++;
      this.callbacks.log(`[agent] tool -> ${event.toolName}${nested ? " (nested)" : ""}`);
      this.callbacks.onToolCall?.(event.toolName);
      if (!nested) this.callbacks.onActivity?.(event.toolName);
    } else if (event.type === "tool_execution_end") {
      if (!event.parentToolCallId) {
        this.callbacks.onActivity?.(undefined);
        this.callbacks.onToolEnd?.(event.toolName, event.isError);
        // A hand-off to a stronger model also restores tools a light lane left out (codemode).
        if (event.toolName === ESCALATE_TOOL_NAME && !event.isError && this.controls.toolNames) {
          this.controls.setActiveTools?.([...this.controls.toolNames]);
        }
      }
    } else if (event.type === "message_update") {
      const update = event.assistantMessageEvent;
      if (update.type === "thinking_delta" || update.type === "text_delta" || update.type === "toolcall_delta") {
        this.response.firstAt ??= now();
      }
      if (update.type === "thinking_delta") this.callbacks.onActivity?.("thinking");
      if (update.type === "text_delta") {
        this.callbacks.onActivity?.(undefined);
        this.response.text += update.delta;
        this.callbacks.onPartialText?.(this.response.text);
      }
    } else if (event.type === "message_end" && event.message.role === "assistant") {
      capture.responseText = assistantMessageText(event.message);
      // pi auto-retries transient provider errors; the latest assistant message decides the outcome.
      capture.providerError = event.message.stopReason === "error"
        ? event.message.errorMessage ?? "Provider failed" : undefined;
      this.report(event.message);
    }
  }

  private report(message: AssistantMessage): void {
    if (!this.callbacks.onResponse || message.stopReason === "aborted") return;
    if (typeof message.provider !== "string" || !message.provider || typeof message.model !== "string" || !message.model) return;
    const { requestAt, firstAt } = this.response;
    const end = now();
    const ok = message.stopReason !== "error";
    const sample: ResponseSample = {
      provider: message.provider,
      model: message.model,
      ...(message.thinkingLevel ? { thinkingLevel: message.thinkingLevel } : {}),
      ...(ok && requestAt !== undefined && firstAt !== undefined ? { ttftMs: firstAt - requestAt, streamMs: end - firstAt } : {}),
      ...(ok && Number.isFinite(message.usage?.output) ? { outputTokens: message.usage.output } : {}),
      ok,
      ...(ok ? {} : { errorKind: classifyProviderError(message.errorMessage) }),
    };
    try { this.callbacks.onResponse(sample); } catch { /* Telemetry never breaks a turn. */ }
  }

  async prompt(text: string, signal?: AbortSignal, image?: ImageContent): Promise<AgentRunResult> {
    if (this.closed) throw new Error("session_closed: Start a new task");
    if (this.capture) throw new Error("not_idle: A prompt is already running");
    if (signal?.aborted) throw abortError(signal);
    this.lifetime.signal.throwIfAborted();
    const capture = { responseText: "", toolCalls: 0, providerError: undefined as string | undefined };
    this.capture = capture;
    this.response = { text: "" };
    const abort = () => { this.lifetime.abort(); void this.session.abort().catch(() => {}); };
    signal?.addEventListener("abort", abort, { once: true });
    try {
      this.beforeTurn();
      await this.session.prompt(text, { expandPromptTemplates: false, ...(image ? { images: [image] } : {}) });
      if (signal?.aborted) throw abortError(signal);
      this.lifetime.signal.throwIfAborted();
      if (this.closed) throw new Error("session_closed: Reader was closed");
      if (capture.providerError) throw new Error(capture.providerError);
      return { responseText: capture.responseText.trim(), toolCalls: capture.toolCalls };
    } finally {
      signal?.removeEventListener("abort", abort);
      this.capture = undefined;
      // A decision is consumed by the first routed request; one left over (prompt failed before
      // any request) must never apply to a later message of this session.
      this.controls.auto?.clearDecision();
    }
  }
  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closed = true;
    this.unsubscribe();
    // Active closure revokes browser authority before awaiting SDK cancellation.
    if (this.capture) { this.lifetime.abort(); void this.session.abort().catch(() => {}); }
    try { this.session.dispose(); } catch { /* Still release browser/provider resources. */ }
    this.controls.ledger?.clear();
    this.closing = this.cleanup().finally(() => this.lifetime.abort());
    return this.closing;
  }
}
