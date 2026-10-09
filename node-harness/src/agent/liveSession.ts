import type { AgentSession, AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";
import { abortError, assistantMessageText, type AgentRunResult } from "./agentRunner.js";

export type SessionTransport = Pick<AgentSession, "prompt" | "subscribe" | "abort" | "dispose">;

/** Owns one in-memory SDK history and its resources; never queues concurrent prompts. */
export class LiveAgentSession {
  private capture?: { responseText: string; toolCalls: number; providerError?: string };
  private closing?: Promise<void>;
  private closed = false;
  private readonly unsubscribe: () => void;
  constructor(
    private readonly session: SessionTransport,
    readonly lifetime: AbortController,
    private readonly callbacks: {
      log: (line: string) => void;
      onToolCall?: (name: string) => void;
      onActivity?: (name: string | undefined) => void;
    },
    private readonly cleanup: () => Promise<void> = async () => {},
    private readonly beforeTurn: () => void = () => {},
  ) {
    this.unsubscribe = session.subscribe(event => this.event(event));
  }
  private event(event: AgentSessionEvent) {
    const capture = this.capture;
    if (!capture || this.closed) return;
    if (event.type === "tool_execution_start") {
      // pi >= 0.99: calls a tool makes through ctx.executeTool() (e.g. codemode scripts) carry
      // parentToolCallId. They stay in the step log, but only model-issued calls are counted
      // and drive the activity marker (the parent call already shows as running).
      const nested = Boolean(event.parentToolCallId);
      if (!nested) capture.toolCalls++;
      this.callbacks.log(`[agent] tool -> ${event.toolName}${nested ? " (nested)" : ""}`);
      this.callbacks.onToolCall?.(event.toolName);
      if (!nested) this.callbacks.onActivity?.(event.toolName);
    } else if (event.type === "tool_execution_end") {
      if (!event.parentToolCallId) this.callbacks.onActivity?.(undefined);
    } else if (event.type === "message_update") {
      if (event.assistantMessageEvent.type === "thinking_delta") this.callbacks.onActivity?.("thinking");
      if (event.assistantMessageEvent.type === "text_delta") this.callbacks.onActivity?.(undefined);
    } else if (event.type === "message_end" && event.message.role === "assistant") {
      capture.responseText = assistantMessageText(event.message);
      // pi auto-retries transient provider errors; the latest assistant message decides the outcome.
      capture.providerError = event.message.stopReason === "error"
        ? event.message.errorMessage ?? "Provider failed" : undefined;
    }
  }
  async prompt(text: string, signal?: AbortSignal, image?: ImageContent): Promise<AgentRunResult> {
    if (this.closed) throw new Error("session_closed: Start a new task");
    if (this.capture) throw new Error("not_idle: A prompt is already running");
    if (signal?.aborted) throw abortError(signal);
    this.lifetime.signal.throwIfAborted();
    const capture = { responseText: "", toolCalls: 0, providerError: undefined as string | undefined };
    this.capture = capture;
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
    }
  }
  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closed = true;
    this.unsubscribe();
    // Active closure revokes browser authority before awaiting SDK cancellation.
    if (this.capture) { this.lifetime.abort(); void this.session.abort().catch(() => {}); }
    try { this.session.dispose(); } catch { /* Still release browser/provider resources. */ }
    this.closing = this.cleanup().finally(() => this.lifetime.abort());
    return this.closing;
  }
}
