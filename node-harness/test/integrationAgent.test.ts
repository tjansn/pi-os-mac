import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { FileSearchResult } from "../src/contracts/launcher.js";
import type { DesktopContextSnapshot } from "../src/hostClient.js";
import { captureLogs, fakeHost, fauxRuntimes, readEvents, snapshot, start } from "./integrationFixtures.js";

/**
 * End to end through HarnessServer with real pi sessions on an in-process provider:
 * Auto default and routing, screenshot gating, prepared sessions, SSE, show_result cards.
 */

type Context = { messages: { role: string; content: unknown }[] };
/** Parts of the latest user message (earlier turns stay in the history). */
const userParts = (context: Context) => context.messages.filter(m => m.role === "user").slice(-1)
  .flatMap(m => typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content as { type: string; text?: string }[]);
const hasImage = (context: Context) => userParts(context).some(part => part.type === "image");
const userText = (context: Context) => userParts(context).filter(part => part.type === "text").map(part => part.text).join("\n");

test("Auto is the default: decide() routes before the prompt, the record shows the route, and latency stats learn TTFT", async () => {
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes });
  const seen: { model: string; image: boolean; text: string }[] = [];
  runtimes.respond([(context, _options, _state, model) => {
    seen.push({ model: `${model.provider}/${model.id}`, image: hasImage(context as Context), text: userText(context as Context) });
    return fauxAssistantMessage("Paris is the capital of France.");
  }]);
  try {
    // Windows-shaped request; nothing stored in settings.json.
    await f.post("/invoke", { invocationId: "auto-1", contextId: "ctx-pinned", prompt: "what is the capital of france" });
    const record = await f.terminal("auto-1");
    assert.equal(record.state, "completed", record.failureMessage);
    assert.equal(record.responseText, "Paris is the capital of France.");
    assert.equal(record.route.auto, true);
    assert.equal(record.route.provider, "fx");
    assert.ok(["quick", "fast", "standard"].includes(record.route.tier));
    assert.ok(record.route.reasons.some((reason: string) => reason.startsWith("intent=answer")));
    assert.equal(seen.length, 1);
    assert.equal(seen[0]!.model, `fx/${record.route.model}`, "the physical model is the one decide() picked");
    // A plain question needs no screenshot: none attached, the summary says so, the request text is unwrapped.
    assert.equal(seen[0]!.image, false);
    assert.match(seen[0]!.text, /No screenshot is attached to this request/);
    assert.match(seen[0]!.text, /## Request\nwhat is the capital of france/);
    for (const key of ["contextMs", "sessionMs", "routeMs", "ttftMs", "totalMs"]) assert.equal(typeof record.timings[key], "number", key);
    const sample = f.stats.get(`fx/${record.route.model}@${record.route.thinkingLevel}`);
    assert.equal(sample?.n, 1, "TTFT recorded per physical model@level");
    assert.equal(record.partialText, undefined, "partial text is cleared when the turn ends");
    // Windows contract (nodemap §10): legacy keys keep their meaning and types; everything new is additive.
    assert.equal(typeof record.invocationId, "string");
    assert.equal(record.contextId, "ctx-pinned");
    assert.equal(typeof record.startedAt, "string");
    assert.equal(typeof record.finishedAt, "string");
    assert.ok(Array.isArray(record.steps));
    assert.equal(record.activity, undefined);
    assert.equal(record.failureMessage, undefined);
    assert.equal(record.followupAvailable, false);
    assert.equal(record.input, undefined);
    assert.equal(record.card, undefined);
  } finally { await f.close(); }
});

test("screenshot gating: deixis attaches the pinned screenshot, a plain request does not; advisory /instant hints are fused", async () => {
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes });
  const images: boolean[] = [];
  const answer = (context: unknown) => { images.push(hasImage(context as Context)); return fauxAssistantMessage("ok"); };
  try {
    runtimes.respond([answer]);
    await f.post("/invoke", { invocationId: "deictic", contextId: "ctx-pinned", prompt: "what does this error mean" });
    const deictic = await f.terminal("deictic");
    assert.equal(deictic.state, "completed", deictic.failureMessage);
    assert.ok(deictic.route.reasons.includes("screenshot"));

    runtimes.respond([answer]);
    await f.post("/invoke", { invocationId: "plain", contextId: "ctx-pinned", prompt: "write a haiku about autumn" });
    assert.equal((await f.terminal("plain")).state, "completed");

    // The host's final /instant left a deixis hint for this take; /invoke fuses it (raise-only).
    const hint = await (await f.post("/instant", { text: "summarize it here", phase: "final", seq: 1, takeId: "take-h" })).json() as any;
    runtimes.respond([answer]);
    await f.post("/invoke", { invocationId: "hinted", contextId: "ctx-pinned", prompt: "summarize it here", takeId: "take-h" });
    const hinted = await f.terminal("hinted");
    assert.equal(hinted.state, "completed", hinted.failureMessage);
    assert.deepEqual(images, [true, false, hint.reason === "deictic"]);
  } finally { await f.close(); }
});

test("prepared sessions: reused when take + context match; discarded on expiry, mismatch and cancel", async () => {
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes, prepareTtlMs: 1_500 });
  const ok = () => fauxAssistantMessage("done");
  const settle = async (count: number) => { for (let i = 0; i < 400 && runtimes.created < count; i++) await delay(5); };
  try {
    assert.equal((await f.post("/invocations/prepare", { contextId: "ctx-pinned" })).status, 400);
    assert.equal((await f.post("/invocations/prepare", { takeId: "take-1" })).status, 400);
    assert.equal((await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-1" }, "wrong")).status, 401);

    const { lines } = await captureLogs(async () => {
      const accepted = await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-1" });
      assert.equal(accepted.status, 202);
      assert.deepEqual(await accepted.json(), { accepted: true, takeId: "take-1" });
      await settle(1);
      runtimes.respond([ok]);
      await f.post("/invoke", { invocationId: "prepared", contextId: "ctx-pinned", prompt: "write a haiku", takeId: "take-1" });
      assert.equal((await f.terminal("prepared")).state, "completed");
    });
    assert.equal(runtimes.created, 1, "the prepared session (runtime, resources, Auto) was reused");
    assert.ok(lines.some(line => line.includes("stage=invoke.session") && line.includes("prepared=true")));

    // Expiry: the take is gone after its TTL, so the invocation builds its own session.
    await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-2" });
    await settle(2);
    await delay(1_600);
    runtimes.respond([ok]);
    await f.post("/invoke", { invocationId: "expired", contextId: "ctx-pinned", prompt: "write a haiku", takeId: "take-2" });
    assert.equal((await f.terminal("expired")).state, "completed");
    assert.equal(runtimes.created, 3);

    // Mismatch: prepared for another context → discarded, fresh session.
    await f.post("/invocations/prepare", { contextId: "ctx-other", takeId: "take-3" });
    await settle(4);
    runtimes.respond([ok]);
    await f.post("/invoke", { invocationId: "mismatch", contextId: "ctx-pinned", prompt: "write a haiku", takeId: "take-3" });
    assert.equal((await f.terminal("mismatch")).state, "completed");
    assert.equal(runtimes.created, 5);

    // Cancel: the host abandoned the take (released without a request).
    await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-4" });
    await settle(6);
    const cancelled = await f.post("/invocations/prepare", { takeId: "take-4", cancel: true });
    assert.deepEqual(await cancelled.json(), { cancelled: true, takeId: "take-4" });
    runtimes.respond([ok]);
    await f.post("/invoke", { invocationId: "cancelled", contextId: "ctx-pinned", prompt: "write a haiku", takeId: "take-4" });
    assert.equal((await f.terminal("cancelled")).state, "completed");
    assert.equal(runtimes.created, 7);

    // Unknown context: prepare is best effort (202) and builds nothing.
    assert.equal((await f.post("/invocations/prepare", { contextId: "ctx-gone", takeId: "take-5" })).status, 202);
    await delay(50);
    assert.equal(runtimes.created, 7);
  } finally { await f.close(); }
});

test("a take prepared before its capture landed is reused when the turn attaches no screenshot, rebuilt when it does", async () => {
  const runtimes = fauxRuntimes();
  // Key-down pins the context; the host's capture is still running when the prepare reads it.
  const contexts: Record<string, DesktopContextSnapshot> = { "ctx-pinned": snapshot("ctx-pinned", false) };
  const f = await start({ runtimes, host: fakeHost({ contexts }) });
  const images: boolean[] = [];
  const answer = (context: unknown) => { images.push(hasImage(context as Context)); return fauxAssistantMessage("ok"); };
  const settle = async (count: number) => { for (let i = 0; i < 400 && runtimes.created < count; i++) await delay(5); };
  try {
    await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-a" });
    await settle(1);
    contexts["ctx-pinned"] = snapshot("ctx-pinned", true);
    runtimes.respond([answer]);
    await f.post("/invoke", { invocationId: "plain", contextId: "ctx-pinned", prompt: "write a haiku about autumn", takeId: "take-a" });
    assert.equal((await f.terminal("plain")).state, "completed");
    assert.equal(runtimes.created, 1, "no screenshot attached: the prepared session is used as is");

    contexts["ctx-pinned"] = snapshot("ctx-pinned", false);
    await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-b" });
    await settle(2);
    contexts["ctx-pinned"] = snapshot("ctx-pinned", true);
    runtimes.respond([answer]);
    const { lines } = await captureLogs(async () => {
      await f.post("/invoke", { invocationId: "deictic", contextId: "ctx-pinned", prompt: "what does this error mean", takeId: "take-b" });
      assert.equal((await f.terminal("deictic")).state, "completed");
    });
    // The attached image must carry coordinate authority, so the session is rebuilt with it as its seed.
    assert.equal(runtimes.created, 3);
    assert.ok(lines.some(line => line.includes("[prepare] discarded reason=screenshot")));
    assert.deepEqual(images, [false, true]);
  } finally { await f.close(); }
});

test("SSE: a reader that stops reading gets the latest record once it drains, not a backlog of every revision", async () => {
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const f = await start({ sseCoalesceMs: 0, onInvocation: async () => { await gate; } });
  try {
    await f.post("/invoke", { invocationId: "stalled", contextId: "ctx-pinned", prompt: "write something long" });
    const response = await f.get("/invocations/stalled/events");
    const updates = 1_000;
    const filler = "y".repeat(7_900);
    for (let i = 0; i < updates; i++) {
      f.server.invocations.setPartialText("stalled", `${i} ${filler}`);
      await new Promise(resolve => setImmediate(resolve));
    }
    release();
    const { records } = await readEvents(response);
    assert.equal(records.at(-1).state, "completed");
    for (let i = 1; i < records.length; i++) assert.ok(records[i].revision > records[i - 1].revision, "revisions strictly increase");
    assert.ok(records.length < updates / 2, `${records.length} records written for ${updates} revisions`);
  } finally { await f.close(); }
});

test("SSE: event: record on every revision (coalesced), streaming partialText, terminal record then close; pings; auth", async () => {
  const runtimes = fauxRuntimes(400);
  const f = await start({ runtimes, sseCoalesceMs: 10, sseKeepAliveMs: 25 });
  const long = Array.from({ length: 60 }, (_, i) => `word${i}`).join(" ");
  runtimes.respond([fauxAssistantMessage(long)]);
  try {
    assert.equal((await fetch(`${f.base}/invocations/x/events`)).status, 401);
    assert.equal((await f.get("/invocations/missing/events")).status, 404);

    await f.post("/invoke", { invocationId: "sse", contextId: "ctx-pinned", prompt: "write a long poem" });
    const response = await f.get("/invocations/sse/events");
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") ?? "", /^text\/event-stream/);
    const { records, comments } = await readEvents(response);
    assert.ok(records.length >= 3, `got ${records.length} records`);
    for (let i = 1; i < records.length; i++) assert.ok(records[i].revision > records[i - 1].revision, "revisions strictly increase");
    const partials = records.filter(record => typeof record.partialText === "string").map(record => record.partialText as string);
    assert.ok(partials.length >= 2, "partial text streams while the model answers");
    for (let i = 1; i < partials.length; i++) assert.ok(partials[i]!.startsWith(partials[i - 1]!), "partial text only grows");
    const last = records.at(-1);
    assert.equal(last.state, "completed");
    assert.equal(last.responseText, long);
    assert.equal(last.partialText, undefined);
    assert.ok(comments >= 1, "keep-alive comments are sent");

    // Polling still works and agrees; a finished invocation streams its terminal record once and closes.
    const polled = await (await f.get("/invocations/sse")).json() as any;
    assert.equal(polled.revision, last.revision);
    const replay = await readEvents(await f.get("/invocations/sse/events"));
    assert.equal(replay.records.length, 1);
    assert.equal(replay.records[0].revision, last.revision);
  } finally { await f.close(); }
});

test("SSE clients that disconnect are cleaned up; the invocation is unaffected", async () => {
  const runtimes = fauxRuntimes(300);
  const f = await start({ runtimes, sseCoalesceMs: 5, sseKeepAliveMs: 10 });
  runtimes.respond([fauxAssistantMessage(Array.from({ length: 40 }, (_, i) => `token${i}`).join(" "))]);
  try {
    await f.post("/invoke", { invocationId: "gone", contextId: "ctx-pinned", prompt: "write something" });
    const controller = new AbortController();
    const response = await fetch(`${f.base}/invocations/gone/events`, { headers: f.headers, signal: controller.signal });
    const reader = response.body!.getReader();
    await reader.read();
    controller.abort();
    await reader.read().catch(() => undefined);
    const record = await f.terminal("gone");
    assert.equal(record.state, "completed");
  } finally { await f.close(); }
});

test("show_result: the validated card lands on the record (complete), responseText = lead text + card text", async () => {
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes });
  try {
    runtimes.respond([
      fauxAssistantMessage([fauxText("Here is the result."), fauxToolCall("show_result", {
        summary: "The answer",
        blocks: [{ type: "result", kind: "math", input: "6 × 7", value: "42" }, { type: "suggestions", prompts: ["Explain the steps"] }],
      })], { stopReason: "toolUse" }),
    ]);
    await f.post("/invoke", { invocationId: "card", contextId: "ctx-pinned", prompt: "what is six times seven, show it as a card" });
    const record = await f.terminal("card");
    assert.equal(record.state, "completed", record.failureMessage);
    assert.equal(record.cardComplete, true);
    assert.equal(record.card.format, "pi-os-ui/1");
    assert.ok(Object.values(record.card.elements).some((element: any) => element.type === "ResultCard" && element.props.value === "42"));
    assert.match(record.responseText, /^Here is the result\.\n\n/);
    assert.match(record.responseText, /6 × 7 = 42/);
    assert.equal(runtimes.core.getPendingResponseCount(), 0, "terminate: no second model round-trip after the card");

    // An invalid card is an error result: no card stays on the record and the model answers in text.
    runtimes.respond([
      fauxAssistantMessage([fauxToolCall("show_result", { blocks: [{ type: "files", refs: ["f99"] }] })], { stopReason: "toolUse" }),
      fauxAssistantMessage("I could not build the card; the answer is 42."),
    ]);
    await f.post("/invoke", { invocationId: "bad-card", contextId: "ctx-pinned", prompt: "show my files as a card" });
    const bad = await f.terminal("bad-card");
    assert.equal(bad.state, "completed", bad.failureMessage);
    assert.equal(bad.card, undefined);
    assert.equal(bad.cardComplete, undefined);
    assert.equal(bad.responseText, "I could not build the card; the answer is 42.");
  } finally { await f.close(); }
});

test("find_files refs flow into show_result file rows bound to host tokens (macOS launcher routes)", { skip: process.platform !== "darwin" }, async () => {
  const files = (JSON.parse(await readFile(resolve("../shared/fixtures/launcher/search-files-response.json"), "utf8")) as { result: FileSearchResult }).result;
  const host = fakeHost();
  const searches: unknown[] = [];
  host.invokeTool = (async (name: string, args: unknown) => {
    host.calls.push(`tool:${name}`);
    if (name === "launcher.searchFiles") { searches.push(args); return { ok: true, result: files }; }
    return { ok: false, error: { code: "unsupported", message: "fixture" } };
  }) as typeof host.invokeTool;
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes, host });
  let toolResult = "";
  try {
    runtimes.respond([
      fauxAssistantMessage([fauxToolCall("find_files", { nameGroups: [["invoice"]], kind: "pdf" })], { stopReason: "toolUse" }),
      (context) => {
        const results = (context as Context).messages.filter(m => m.role === "toolResult");
        toolResult = JSON.stringify(results.at(-1)?.content ?? "");
        return fauxAssistantMessage([fauxToolCall("show_result", { blocks: [{ type: "files", title: "Invoices", refs: ["f1", "f2"] }] })], { stopReason: "toolUse" });
      },
    ]);
    await f.post("/invoke", { invocationId: "files", contextId: "ctx-pinned", prompt: "show me my invoices", retainSession: true });
    const record = await f.terminal("files");
    assert.equal(record.state, "completed", record.failureMessage);
    assert.equal(searches.length, 1);
    // The model saw refs and names only: never host tokens or absolute paths.
    assert.match(toolResult, /f1/);
    assert.ok(!toolResult.includes("tok_") && !toolResult.includes("/Users/fixture"));
    const card = JSON.stringify(record.card);
    assert.equal(record.cardComplete, true);
    assert.ok(card.includes("tok_3fa8c2d1e9b0") || card.includes("tok_9be0a7c4d2f1"), "rows bind the host tokens the ledger holds");
    // Rows show a name and a folder; the full path stays with the host (token), never in the card.
    for (const item of files.items) assert.ok(!card.includes(item.path), "no file paths in cards");
    assert.equal((await f.post("/invocations/files/close", {})).status, 200);
  } finally { await f.close(); }
});

test("Auto follow-ups route again (sticky floor, explicit depth words raise the tier) without re-attaching the screenshot", async () => {
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes });
  const seen: { model: string; image: boolean }[] = [];
  const answer = (text: string) => (context: unknown, _options: unknown, _state: unknown, model: { provider: string; id: string }) => {
    seen.push({ model: `${model.provider}/${model.id}`, image: hasImage(context as Context) });
    return fauxAssistantMessage(text);
  };
  try {
    runtimes.respond([answer("Paris.")]);
    await f.post("/invoke", { invocationId: "thread", contextId: "ctx-pinned", prompt: "what does this chart show", retainSession: true });
    const first = await f.terminal("thread");
    assert.equal(first.state, "completed", first.failureMessage);
    assert.equal(first.followupAvailable, true);

    runtimes.respond([answer("Let me think about it properly.")]);
    assert.equal((await f.post("/invocations/thread/followup", { prompt: "that's wrong, think hard about it", input: { mode: "voice" } })).status, 202);
    const second = await f.terminal("thread");
    assert.equal(second.state, "completed", second.failureMessage);
    assert.deepEqual(second.input, { mode: "voice" });
    assert.ok(["deep", "max"].includes(second.route.tier), `explicit depth words raise the tier (${second.route.tier})`);
    assert.ok(second.route.reasons.includes("explicit-deep"));
    assert.equal(seen.length, 2);
    assert.equal(seen[0]!.image, true, "the first turn needed the screen");
    assert.equal(seen[1]!.image, false, "follow-ups never re-attach the pinned screenshot");
    assert.equal(seen[1]!.model, `fx/${second.route.model}`);
    assert.equal((await f.post("/invocations/thread/close", {})).status, 200);
  } finally { await f.close(); }
});

test("Auto with no authenticated model fails clearly (no_authenticated_model), never with a provider call", async () => {
  const f = await start({ agentServices: { modelRuntime: async () => {
    const dir = mkdtempSync(join(tmpdir(), "pi-os-int-empty-"));
    return ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing.json"), modelsStorePath: join(dir, "store.json") });
  } } });
  try {
    await f.post("/invoke", { invocationId: "nomodel", contextId: "ctx-pinned", prompt: "write a haiku" });
    const record = await f.terminal("nomodel");
    assert.equal(record.state, "failed");
    assert.match(record.failureMessage, /no_authenticated_model/);
    assert.equal(record.route, undefined, "no route was decided without candidates");
  } finally { await f.close(); }
});

test("SSE shows partial show_result cards (cardComplete false) before the validated card; partials never outlive the turn", async () => {
  const runtimes = fauxRuntimes(400);
  const f = await start({ runtimes, sseCoalesceMs: 5 });
  const prose = Array.from({ length: 16 }, (_, i) => `Point ${i} explains part of the answer.`).join(" ");
  runtimes.respond([fauxAssistantMessage([fauxToolCall("show_result", {
    blocks: [{ type: "markdown", text: prose }, { type: "keyValue", title: "Facts", items: [{ key: "Answer", value: "42" }] }],
  })], { stopReason: "toolUse" })]);
  try {
    await f.post("/invoke", { invocationId: "partial", contextId: "ctx-pinned", prompt: "explain it as a card" });
    const { records } = await readEvents(await f.get("/invocations/partial/events"));
    const partial = records.filter(record => record.card && record.cardComplete === false);
    assert.ok(partial.length >= 1, "partial cards stream while the tool call is generated");
    const keys = (record: any) => Object.keys(record.card.elements);
    for (const record of partial) assert.ok(keys(record).includes("root"), "partial cards are complete trees with stable keys");
    const last = records.at(-1);
    assert.equal(last.state, "completed", last.failureMessage);
    assert.equal(last.cardComplete, true);
    assert.ok(Object.values(last.card.elements).some((element: any) => element.type === "KeyValue"));
    assert.match(last.responseText, /Answer/);
  } finally { await f.close(); }
});
