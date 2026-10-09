import assert from "node:assert/strict";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { resolve, join } from "node:path";
import { loadAgentResources, registerResourceProviders } from "../src/agent/resources.js";
import { HarnessServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";
import type { HostClient } from "../src/hostClient.js";
import { LiveAgentSession, type SessionTransport } from "../src/agent/liveSession.js";
import { activeToolsFor, promptFollowup, spokenInputNote } from "../src/agent/agentRunner.js";

class FixtureSession implements SessionTransport {
  listener?: (event: AgentSessionEvent) => void;
  history: string[] = []; disposed = 0; aborted = 0;
  hold?: Promise<void>; release?: () => void; fail = false;
  subscribe(listener: (event: AgentSessionEvent) => void) { this.listener = listener; return () => { this.listener = undefined; }; }
  async prompt(text: string) {
    this.history.push(text);
    if (this.hold) await this.hold;
    this.listener?.({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: `Answer ${this.history.length}` }], stopReason: this.fail ? "error" : "stop", ...(this.fail ? { errorMessage: "fixture provider failure" } : {}) } } as AgentSessionEvent);
  }
  async abort() { this.aborted++; this.release?.(); }
  dispose() { this.disposed++; }
  pause() { this.hold = new Promise(resolve => { this.release = resolve; }); }
}
const snapshot = { id: "ctx-pinned", capturedAt: "fixture", targetWindow: null, foregroundWindow: null, windowUnderCursor: null, cursor: { x: 0, y: 0 }, monitors: [] };
async function fixture(timeout = 0, startup?: Promise<void>) {
  const transports: FixtureSession[] = [];
  let unavailable = false, control = true, now = Date.now();
  const host = {
    getSnapshot: async (id: string) => { assert.equal(id, "ctx-pinned"); return unavailable ? { ok: false, error: { code: "unknown_context", message: "revoked" } } : { ok: true, result: snapshot }; },
    getToolNames: async () => control ? ["window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll"] : [],
  } as unknown as HostClient;
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "fixture-token", agentEnabled: true, invokeTimeoutMs: timeout }, {
    hostClient: host, now: () => now,
    createSession: async options => {
      if (startup) await startup;
      const session = new FixtureSession(); transports.push(session);
      return new LiveAgentSession(session, new AbortController(), options);
    },
  });
  const base = `http://127.0.0.1:${await server.listen()}`;
  async function request(path: string, body?: unknown) {
    return fetch(base + path, { method: body === undefined ? "GET" : "POST", headers: { "X-Harness-Token": "fixture-token", "Content-Type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  }
  async function terminal(id = "thread") {
    for (let i = 0; i < 200; i++) {
      const status = await (await request(`/invocations/${id}`)).json() as any;
      if (!["queued", "running"].includes(status.state)) return status;
      await delay(5);
    }
    throw new Error("Fixture did not settle");
  }
  return { server, transports, request, terminal, revoke: () => { unavailable = true; }, denyControl: () => { control = false; }, elapse: (ms: number) => { now += ms; } };
}
const invoke = { invocationId: "thread", contextId: "ctx-pinned", prompt: "first question", retainSession: true };

test("sequential HTTP follow-ups reuse history/identity, reset results and close idempotently", async () => {
  const f = await fixture();
  try {
    assert.equal((await f.request("/invoke", invoke)).status, 202);
    assert.equal((await f.terminal()).followupAvailable, true);
    const session = f.transports[0]!;
    session.pause();
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "second question" })).status, 202);
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "duplicate" })).status, 409);
    const running = await (await f.request("/invocations/thread")).json() as any;
    assert.equal(running.responseText, undefined);
    session.release!(); session.hold = undefined;
    const result = await f.terminal();
    assert.equal(result.responseText, "Answer 2"); assert.equal(result.contextId, "ctx-pinned");
    assert.equal(f.transports.length, 1); assert.equal(session.history.length, 2);
    assert.match(session.history[0]!, /first question/); assert.match(session.history[1]!, /second question/);
    assert.equal(session.disposed, 0);
    for (let i = 0; i < 2; i++) assert.equal((await f.request("/invocations/thread/close", {})).status, 200);
    assert.equal(session.disposed, 1);
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "no resurrection" })).status, 404);
  } finally { await f.server.close(); }
});

test("one-shot Windows-compatible clients do not retain sessions; new threads do not share history", async () => {
  const f = await fixture();
  try {
    assert.equal((await f.request("/invoke", { ...invoke, retainSession: false })).status, 202);
    assert.equal((await f.terminal()).followupAvailable, false);
    assert.equal(f.transports[0]!.disposed, 1);
    await f.request("/invoke", { ...invoke, invocationId: "other" }); await f.terminal("other");
    assert.equal(f.transports.length, 2); assert.equal(f.transports[1]!.history.length, 1);
  } finally { await f.server.close(); }
  assert.equal(f.transports[1]!.disposed, 1);
});

test("invalid/blank follow-ups are rejected; provider failure preserves idle thread for explicit retry", async () => {
  const f = await fixture();
  try {
    await f.request("/invoke", invoke); await f.terminal();
    for (const body of [{}, { prompt: " \n " }, { prompt: "x".repeat(20_001) }]) assert.equal((await f.request("/invocations/thread/followup", body)).status, 400);
    f.transports[0]!.fail = true;
    await f.request("/invocations/thread/followup", { prompt: "fail" });
    const failed = await f.terminal(); assert.equal(failed.state, "failed"); assert.equal(failed.followupAvailable, true);
    f.transports[0]!.fail = false;
    await f.request("/invocations/thread/followup", { prompt: "explicit retry" });
    assert.equal((await f.terminal()).responseText, "Answer 3");
  } finally { await f.server.close(); }
});

test("retained sessions have bounded capacity and lazy TTL, with no expiry-based input renewal", async () => {
  const f = await fixture();
  try {
    for (let i = 0; i < 20; i++) {
      await f.request('/invoke', { ...invoke, invocationId: 'thread-' + i }); await f.terminal('thread-' + i);
    }
    assert.equal((await f.request('/invoke', { ...invoke, invocationId: 'overflow' })).status, 409);
    f.elapse(30 * 60_000 + 1);
    assert.equal((await f.request('/invocations/thread-0/followup', { prompt: 'expired' })).status, 404);
    assert(f.transports.every(s => s.disposed === 1));
    assert.equal((await f.request('/invoke', { ...invoke, invocationId: 'new-thread' })).status, 202);
    await f.terminal('new-thread'); assert.equal(f.transports.length, 21);
  } finally { await f.server.close(); }
});

test("closing during async session startup cannot resurrect a session", async () => {
  let release!: () => void;
  const f = await fixture(0, new Promise<void>(resolve => { release = resolve; }));
  try {
    await f.request("/invoke", invoke);
    await f.request("/invocations/thread/close", {}); release();
    assert.equal((await f.terminal()).followupAvailable, false);
    assert.equal(f.transports[0]!.disposed, 1); assert.equal(f.transports[0]!.history.length, 0);
    assert.equal((await f.request("/invocations/thread/followup", { prompt: "no" })).status, 404);
  } finally { release(); await f.server.close(); }
});

test("cancel/timeout during follow-up closes input authority; context revocation prevents another prompt", async () => {
  for (const mode of (["cancel", "timeout", "revoke", ...(process.platform === "darwin" ? ["control"] : [])] as const)) {
    const f = await fixture(mode === "timeout" ? 200 : 0);
    try {
      await f.request("/invoke", invoke); await f.terminal();
      const s = f.transports[0]!;
      if (mode === "revoke") f.revoke();
      else if (mode === "control") f.denyControl();
      else s.pause();
      await f.request("/invocations/thread/followup", { prompt: "second" });
      if (mode === "cancel") await f.request("/invocations/thread/cancel", {});
      const end = await f.terminal(); assert.equal(end.followupAvailable, false, mode);
      assert.equal(s.disposed, 1, mode);
      if (["revoke", "control"].includes(mode)) assert.equal(s.history.length, 1, "No model prompt after revoked native authority");
      assert.equal((await f.request("/invocations/thread/followup", { prompt: "retry" })).status, 404);
    } finally { await f.server.close(); }
  }
});

/** Real SDK session against an in-process provider; the stream function is replaced per test. */
async function sdkFixture(settings: Parameters<typeof SettingsManager.inMemory>[0]) {
  const dir = resolve("test/fixtures/global-agent-dir");
  const loader = await loadAgentResources([{ name: "history-fixture", factory(pi) {
    pi.registerProvider("history-fixture", { api: "openai-completions", baseUrl: "https://never-called.invalid/v1", apiKey: "dummy-fixture-key",
      models: [{ id: "dummy", name: "Dummy", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  } }], process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing-models.json") });
  const cleanup = await registerResourceProviders(loader, runtime);
  const { session } = await createAgentSession({ modelRuntime: runtime, resourceLoader: loader, model: runtime.getModel("history-fixture", "dummy"),
    tools: [], sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(settings) });
  return { session, cleanup };
}
const zeroUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

test("real SDK retains finalized conversation between sequential prompts using an in-memory stream fixture", async () => {
  const { session, cleanup } = await sdkFixture({ retry: { enabled: false }, compaction: { enabled: false } });
  const seen: string[] = [];
  session.agent.streamFunction = (model, context) => {
    seen.push(JSON.stringify(context.messages));
    const stream = createAssistantMessageEventStream();
    const answer: AssistantMessage = { role: "assistant", content: [{ type: "text", text: `Fixture answer ${seen.length}` }], provider: model.provider, model: model.id,
      api: model.api, stopReason: "stop", timestamp: Date.now(), usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
    stream.push({ type: "done", reason: "stop", message: answer }); stream.end(); return stream;
  };
  const live = new LiveAgentSession(session, new AbortController(), { log() {} }, async () => { cleanup(); });
  try {
    assert.equal((await live.prompt("Remember this dummy phrase: copper robin")).responseText, "Fixture answer 1");
    assert.equal((await promptFollowup(live, "What did I say?")).responseText, "Fixture answer 2");
    assert.match(seen[1]!, /copper robin/); assert.match(seen[1]!, /Fixture answer 1/);
    assert.equal(session.messages.filter(m => m.role === "user").length, 2);
    assert.equal(session.sessionFile, undefined, "Desktop conversation must remain in memory");
  } finally { await live.close(); }
});

test("per-turn abort listeners do not survive an idle prompt and busy prompts are not queued", async () => {
  const transport = new FixtureSession(), lifetime = new AbortController();
  const live = new LiveAgentSession(transport, lifetime, { log() {} });
  const first = new AbortController(); await live.prompt("first", first.signal); first.abort();
  assert.equal(transport.aborted, 0); assert.equal(lifetime.signal.aborted, false);
  transport.pause(); const pending = promptFollowup(live, "second");
  await assert.rejects(live.prompt("concurrent"), /not_idle/);
  transport.release!(); await pending;
  await live.close(); await live.close(); assert.equal(transport.disposed, 1);
});

/** Replays a fixed pi event sequence for each prompt (shapes as emitted by pi 1.0). */
class ScriptedSession implements SessionTransport {
  listener?: (event: AgentSessionEvent) => void;
  constructor(private readonly script: AgentSessionEvent[]) {}
  subscribe(listener: (event: AgentSessionEvent) => void) { this.listener = listener; return () => { this.listener = undefined; }; }
  async prompt() { for (const event of this.script) this.listener?.(event); }
  async abort() {}
  dispose() {}
}
const assistantEnd = (text: string, error?: string) => ({ type: "message_end", message: { role: "assistant", content: text ? [{ type: "text", text }] : [],
  stopReason: error ? "error" : "stop", ...(error ? { errorMessage: error } : {}) } }) as AgentSessionEvent;

test("a provider error followed by a successful automatic retry resolves with the retried answer", async () => {
  // Order observed in pi 0.83 and 1.0: error message_end, agent_end(willRetry), auto_retry_start, success.
  const retried = new LiveAgentSession(new ScriptedSession([
    assistantEnd("", "529 overloaded_error: Overloaded"),
    { type: "agent_end", messages: [], willRetry: true } as AgentSessionEvent,
    { type: "auto_retry_start", attempt: 1, maxAttempts: 3, delayMs: 1, errorMessage: "529 overloaded_error: Overloaded" },
    assistantEnd("ok after retry"),
    { type: "auto_retry_end", success: true, attempt: 1 },
  ]), new AbortController(), { log() {} });
  assert.deepEqual(await retried.prompt("hello"), { responseText: "ok after retry", toolCalls: 0 });
  await retried.close();
  const failed = new LiveAgentSession(new ScriptedSession([assistantEnd("partial"), assistantEnd("", "529 overloaded_error: Overloaded")]),
    new AbortController(), { log() {} });
  await assert.rejects(failed.prompt("hello"), /529 overloaded_error/);
  await failed.close();
});

test("real SDK automatic retry success is reported as success; exhausted retries still fail", async () => {
  for (const succeedOn of [2, Infinity]) {
    const { session, cleanup } = await sdkFixture({ retry: { enabled: true, maxRetries: 1, baseDelayMs: 1 }, compaction: { enabled: false } });
    let calls = 0;
    session.agent.streamFunction = (model) => {
      const stream = createAssistantMessageEventStream();
      const fail = ++calls < succeedOn;
      const message: AssistantMessage = { role: "assistant", content: fail ? [] : [{ type: "text", text: "ok after retry" }], provider: model.provider,
        model: model.id, api: model.api, stopReason: fail ? "error" : "stop", ...(fail ? { errorMessage: "529 overloaded_error: Overloaded" } : {}),
        timestamp: Date.now(), usage: zeroUsage };
      stream.push(fail ? { type: "error", reason: "error", error: message } : { type: "done", reason: "stop", message }); stream.end();
      return stream;
    };
    const live = new LiveAgentSession(session, new AbortController(), { log() {} }, async () => { cleanup(); });
    try {
      if (succeedOn === 2) assert.equal((await live.prompt("hello")).responseText, "ok after retry");
      else await assert.rejects(live.prompt("hello"), /529 overloaded_error/);
      assert.equal(calls, 2, "one automatic retry");
    } finally { await live.close(); }
  }
});

test("nested tool calls (parentToolCallId) are logged but neither counted nor allowed to churn activity", async () => {
  const activity: (string | undefined)[] = [], steps: string[] = [], logs: string[] = [];
  const tool = (type: "tool_execution_start" | "tool_execution_end", toolCallId: string, toolName: string, parentToolCallId?: string) =>
    ({ type, toolCallId, toolName, ...(type === "tool_execution_start" ? { args: {} } : { result: {}, isError: false }),
      ...(parentToolCallId ? { parentToolCallId } : {}) }) as AgentSessionEvent;
  const live = new LiveAgentSession(new ScriptedSession([
    tool("tool_execution_start", "call_1", "codemode"),
    tool("tool_execution_start", "n1", "desktop_get_context", "call_1"),
    tool("tool_execution_start", "n2", "desktop_refresh_context", "call_1"),
    tool("tool_execution_end", "n1", "desktop_get_context", "call_1"),
    tool("tool_execution_end", "n2", "desktop_refresh_context", "call_1"),
    tool("tool_execution_end", "call_1", "codemode"),
    tool("tool_execution_start", "call_2", "desktop_capture_window"),
    tool("tool_execution_end", "call_2", "desktop_capture_window"),
    assistantEnd("done"),
  ]), new AbortController(), { log: line => logs.push(line), onToolCall: name => steps.push(name), onActivity: value => activity.push(value) });
  assert.deepEqual(await live.prompt("hello"), { responseText: "done", toolCalls: 2 });
  assert.deepEqual(activity, ["codemode", undefined, "desktop_capture_window", undefined]);
  assert.deepEqual(steps, ["codemode", "desktop_get_context", "desktop_refresh_context", "desktop_capture_window"]);
  assert.deepEqual(logs.filter(line => line.includes("(nested)")), ["[agent] tool -> desktop_get_context (nested)", "[agent] tool -> desktop_refresh_context (nested)"]);
  await live.close();
});

test("observers: partial text accumulates per assistant message; responses report ids and timings only; escalation restores light-lane tools", async () => {
  const partials: string[] = [], samples: unknown[] = [], ends: string[] = [];
  const restored: string[][] = [];
  const update = (type: "text_delta" | "thinking_delta", delta: string) =>
    ({ type: "message_update", message: {}, assistantMessageEvent: { type, delta, contentIndex: 0, partial: {} } }) as unknown as AgentSessionEvent;
  const tool = (type: "tool_execution_start" | "tool_execution_end", toolName: string, isError = false) =>
    ({ type, toolCallId: `c-${toolName}`, toolName, ...(type === "tool_execution_start" ? { args: {} } : { result: {}, isError }) }) as AgentSessionEvent;
  const assistant = (text: string) => ({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text }], provider: "fx", model: "fast",
    thinkingLevel: "off", usage: { output: 20 }, stopReason: "stop" } }) as AgentSessionEvent;
  const live = new LiveAgentSession(new ScriptedSession([
    { type: "turn_start" } as AgentSessionEvent,
    { type: "message_start", message: { role: "assistant" } } as AgentSessionEvent,
    update("thinking_delta", "hmm"), update("text_delta", "Let me "), update("text_delta", "check."),
    assistant("Let me check."),
    tool("tool_execution_start", "pi_os_escalate"), tool("tool_execution_end", "pi_os_escalate"),
    tool("tool_execution_start", "show_result"), tool("tool_execution_end", "show_result", true),
    { type: "turn_start" } as AgentSessionEvent,
    { type: "message_start", message: { role: "assistant" } } as AgentSessionEvent,
    update("text_delta", "Done."),
    assistant("Done."),
  ]), new AbortController(), { log() {} }, undefined, undefined, {
    toolNames: ["desktop_get_context", "codemode"], setActiveTools: names => restored.push(names),
  });
  live.observe({
    log() {}, onPartialText: text => partials.push(text), onResponse: sample => samples.push(sample),
    onToolEnd: (name, isError) => ends.push(`${name}:${isError}`),
  });
  assert.deepEqual(await live.prompt("hello"), { responseText: "Done.", toolCalls: 2 });
  assert.deepEqual(partials, ["Let me ", "Let me check.", "Done."], "a new assistant message starts a new partial text");
  assert.deepEqual(ends, ["pi_os_escalate:false", "show_result:true"]);
  assert.deepEqual(restored, [["desktop_get_context", "codemode"]], "a successful hand-off re-activates every session tool");
  assert.equal(samples.length, 2);
  for (const sample of samples as { provider: string; model: string; thinkingLevel: string; ok: boolean; outputTokens: number; ttftMs: number }[]) {
    assert.deepEqual([sample.provider, sample.model, sample.thinkingLevel, sample.ok, sample.outputTokens], ["fx", "fast", "off", true, 20]);
    assert.equal(typeof sample.ttftMs, "number");
    assert.ok(!JSON.stringify(sample).includes("Let me") && !JSON.stringify(sample).includes("Done"), "samples never carry content");
  }
  await live.close();
});

test("provider errors are classified for health penalties; a leftover Auto decision never outlives its prompt", async () => {
  const samples: { ok: boolean; errorKind?: string }[] = [];
  let cleared = 0;
  const live = new LiveAgentSession(new ScriptedSession([
    { type: "message_end", message: { role: "assistant", content: [], provider: "fx", model: "fast", stopReason: "error",
      errorMessage: "You exceeded your current quota, please check your plan and billing details" } } as unknown as AgentSessionEvent,
  ]), new AbortController(), { log() {} }, undefined, undefined, {
    auto: { clearDecision: () => { cleared++; } } as never,
  });
  live.observe({ log() {}, onResponse: sample => samples.push(sample) });
  await assert.rejects(live.prompt("hello"), /quota/);
  assert.deepEqual(samples, [{ provider: "fx", model: "fast", ok: false, errorKind: "quota" }]);
  assert.equal(cleared, 1);
  await live.close();
});

test("light lanes leave codemode inactive unless hinted; standard and above get every session tool", () => {
  const all = ["desktop_get_context", "instant_calc", "find_files", "show_result", "codemode", "pi_os_escalate"];
  assert.deepEqual(activeToolsFor(all, { tier: "quick", toolsAdd: ["instant_calc"] }), all.filter(name => name !== "codemode"));
  assert.deepEqual(activeToolsFor(all, { tier: "fast", toolsAdd: [] }), all.filter(name => name !== "codemode"));
  assert.deepEqual(activeToolsFor(all, { tier: "fast", toolsAdd: ["codemode"] }), all);
  assert.deepEqual(activeToolsFor(all, { tier: "standard", toolsAdd: [] }), all);
  // Hints name tools by B5's names; anything not in the session's allowlist stays out.
  assert.deepEqual(activeToolsFor(["desktop_get_context"], { tier: "deep", toolsAdd: ["open_item"] }), ["desktop_get_context"]);
  assert.deepEqual(spokenInputNote({ mode: "text" }), []);
  assert.match(spokenInputNote({ mode: "voice", locale: "de-DE", confidence: 0.4, engine: "x" }).join("\n"), /^## Input\n.*\(de-DE\)/);
});
