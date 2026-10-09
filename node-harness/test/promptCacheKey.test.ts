import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { loadAgentResources, sessionExtensions } from "../src/agent/agentRunner.js";
import { stabilizePromptCacheKey } from "../src/agent/promptCacheKey.js";
import type { HostClient } from "../src/hostClient.js";

const TOOLS = [{ type: "function", name: "desktop_get_context", description: "Return context.", parameters: { type: "object", properties: {} } }];
const body = (input: string, key: string, instructions = "You are pi-os. ".repeat(50), tools: unknown[] = TOOLS) => ({
  model: "gpt-6-luna", instructions, tools, tool_choice: "auto", prompt_cache_key: key, stream: true,
  input: [{ role: "user", content: [{ type: "input_text", text: input }] }],
});

test("stabilizePromptCacheKey: one key per prompt variant, never derived from the request content", () => {
  const a = stabilizePromptCacheKey(body("what is the capital of france", randomUUID())) as Record<string, unknown>;
  const b = stabilizePromptCacheKey(body("summarize my unread mail please", randomUUID())) as Record<string, unknown>;
  assert.equal(typeof a.prompt_cache_key, "string");
  assert.equal(a.prompt_cache_key, b.prompt_cache_key, "same instructions + tools → same key across invocations");
  assert.match(String(a.prompt_cache_key), /^pi-os-[0-9a-f]{32}$/);
  assert.ok(String(a.prompt_cache_key).length <= 64);
  assert.ok(!String(a.prompt_cache_key).includes("france"));
  // Only the key changes; the rest of the body is untouched.
  const original = body("what is the capital of france", "thread-1");
  assert.deepEqual({ ...(stabilizePromptCacheKey(original) as object), prompt_cache_key: "thread-1" }, original);

  const otherInstructions = stabilizePromptCacheKey(body("q", "k", "Different system prompt.")) as Record<string, unknown>;
  const otherTools = stabilizePromptCacheKey(body("q", "k", undefined, [])) as Record<string, unknown>;
  assert.notEqual(otherInstructions.prompt_cache_key, a.prompt_cache_key);
  assert.notEqual(otherTools.prompt_cache_key, a.prompt_cache_key);

  // No key (cacheRetention "none"), non-objects and other APIs stay untouched.
  const { prompt_cache_key: _dropped, ...noKey } = body("q", "k");
  assert.equal(stabilizePromptCacheKey(noKey), undefined);
  for (const payload of [null, "text", 42, [body("q", "k")]]) assert.equal(stabilizePromptCacheKey(payload), undefined);
  assert.equal(stabilizePromptCacheKey({ model: "claude", system: "x", messages: [], max_tokens: 1 }), undefined);
  assert.equal(stabilizePromptCacheKey({ prompt_cache_key: "k", messages: [] }), undefined, "chat-completions shape");
});

test("wire level (codex SSE, stubbed fetch): the body key is stable, session headers stay per thread", async () => {
  const { streamSimple } = await import("@earendil-works/pi-ai/api/openai-codex-responses");
  const catalog = JSON.parse(readFileSync(join(import.meta.dirname, "..", "node_modules", "@earendil-works", "pi-ai", "dist", "providers", "data", "openai-codex.json"), "utf8"));
  const model = catalog["openai-codex-responses"]["chat:gpt-6-luna"];
  assert.ok(model, "catalog entry");
  const b64 = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  // Dummy credential: a JWT that only carries the account-id claim pi reads.
  const jwt = `${b64({ alg: "none" })}.${b64({ "https://api.openai.com/auth": { chatgpt_account_id: "acct-fixture" } })}.sig`;
  const sent: { key: unknown; sessionHeader: string | null; requestId: string | null }[] = [];
  const stub = (async (_url: unknown, init: RequestInit) => {
    const raw = Buffer.from(init.body as Uint8Array);
    const headers = new Headers(init.headers);
    const json = headers.get("content-encoding") === "zstd" ? zstdDecompressSync(raw).toString() : raw.toString();
    sent.push({ key: JSON.parse(json).prompt_cache_key, sessionHeader: headers.get("session-id"), requestId: headers.get("x-client-request-id") });
    return new Response("bad request (stub)", { status: 400 });
  }) as typeof fetch;
  const sessions = [randomUUID(), randomUUID()];
  for (const [i, sessionId] of sessions.entries()) {
    const context = { systemPrompt: "You are pi-os. ".repeat(100), messages: [{ role: "user" as const, content: `question ${i}`, timestamp: Date.now() }],
      tools: [{ name: "desktop_get_context", description: "Return context.", parameters: { type: "object", properties: {} } as never }] };
    const stream = streamSimple(model, context as never, { apiKey: jwt, sessionId, transport: "sse", fetch: stub, maxRetries: 0, onPayload: stabilizePromptCacheKey } as never);
    for await (const _event of stream) { /* drain until the stubbed 400 ends it */ }
  }
  assert.equal(sent.length, 2);
  assert.equal(sent[0]!.key, sent[1]!.key, "same prompt variant → same body key");
  assert.match(String(sent[0]!.key), /^pi-os-/);
  assert.deepEqual(sent.map(s => s.sessionHeader), sessions, "session-id header stays the per-thread id");
  assert.deepEqual(sent.map(s => s.requestId), sessions, "x-client-request-id stays the per-thread id");
});

test("every session (isolated and trusted resources) registers the before_provider_request hook", async () => {
  const agentDir = resolve("test/fixtures/global-agent-dir");
  for (const isolated of [true, false]) {
    const { extensions } = sessionExtensions({ contextId: "ctx", hostClient: {} as HostClient, capturesDir: "/captures", readOnly: true, platform: "darwin" });
    const loader = await loadAgentResources(extensions, process.cwd(), agentDir, isolated);
    const hooked = loader.getExtensions().extensions.filter(extension => extension.handlers.has("before_provider_request"));
    assert.ok(hooked.length >= 1, `isolated=${isolated}`);
  }
});
