import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { EcbRateStore } from "../src/instant/index.js";
import { createInstantDispatcher } from "../src/instant/index.js";
import { validateCard } from "../src/ui/validate.js";
import { HOST_ACTION_TYPES } from "../src/contracts/actions.js";
import type { AppIndexResult, FileSearchResult } from "../src/contracts/launcher.js";
import { LiveAgentSession } from "../src/agent/liveSession.js";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { captureLogs, fakeHost, start } from "./integrationFixtures.js";

const apps = (JSON.parse(await readFile(resolve("../shared/fixtures/launcher/list-apps-response.json"), "utf8")) as { result: AppIndexResult }).result;
const files = (JSON.parse(await readFile(resolve("../shared/fixtures/launcher/search-files-response.json"), "utf8")) as { result: FileSearchResult }).result;
// ECB fetches are injected and fail closed: the guard would block the real endpoint anyway.
const noRates = () => new EcbRateStore({ fetch: (async () => { throw new Error("offline fixture"); }) as typeof fetch, file: "/nonexistent-dir/fx.json", log: () => {} });

/** Minimal transport: answers every prompt with a fixed text (no SDK, no model). */
class EchoSession {
  listener?: (event: AgentSessionEvent) => void;
  prompts: string[] = [];
  subscribe(listener: (event: AgentSessionEvent) => void) { this.listener = listener; return () => { this.listener = undefined; }; }
  async prompt(text: string) {
    this.prompts.push(text);
    this.listener?.({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "agent answer" }], stopReason: "stop" } } as AgentSessionEvent);
  }
  async abort() {}
  dispose() {}
}

function sessions() {
  const created: EchoSession[] = [];
  return {
    created,
    createSession: async (options: { log: (line: string) => void }) => {
      const transport = new EchoSession();
      created.push(transport);
      return new LiveAgentSession(transport, new AbortController(), options);
    },
  };
}

test("POST /instant answers, lists, acts and refuses with valid cards; typing never acts", async () => {
  const host = fakeHost({ apps, searchFiles: async () => files });
  const f = await start({ host, instant: { fx: noRates() } });
  const instant = async (body: Record<string, unknown>) => {
    const response = await f.post("/instant", { seq: 1, phase: "final", ...body });
    assert.equal(response.status, 200, JSON.stringify(body));
    return response.json() as Promise<any>;
  };
  try {
    const calc = await instant({ text: "what is 12 * 7" });
    assert.equal(calc.decision, "answer");
    assert.equal(calc.intent, "calc");
    assert.equal(calc.title, "84");
    assert.equal(calc.seq, 1);
    assert.equal(calc.source, "grammar");
    assert.equal(calc.card.format, "pi-os-ui/1");

    const refuse = await instant({ text: "delete all files in my downloads folder" });
    assert.equal(refuse.decision, "refuse");
    assert.equal(refuse.code, "file_deletion_blocked");
    assert.match(refuse.message, /delet/i);

    const web = await instant({ text: "open github.com" });
    assert.equal(web.decision, "act");
    assert.deepEqual(web.action, { type: "openURL", url: "https://github.com" });
    // Partials and typing only preview: never an action.
    for (const phase of ["typing", "partial"]) {
      const preview = await instant({ text: "open github.com", phase, seq: 2 });
      assert.notEqual(preview.decision, "act", phase);
    }

    const app = await instant({ text: "open figma", takeId: "take-app" });
    assert.equal(app.decision, "act");
    assert.deepEqual(app.action, { type: "openApp", bundleId: "com.figma.Desktop" });

    const list = await instant({ text: "find invoice pdfs", takeId: "take-files" });
    assert.equal(list.decision, "list");
    assert.equal(list.intent, "file_search");
    assert.ok(host.calls.includes("searchFiles"));
    // File rows bind host tokens only; the card never carries absolute paths.
    assert.ok(!JSON.stringify(list.card).includes("/Users/fixture/"));
    assert.match(JSON.stringify(list.card), /tok_3fa8c2d1e9b0/);

    const deictic = await instant({ text: "summarize this", takeId: "take-deictic" });
    assert.equal(deictic.decision, "fallthrough");
    assert.equal(deictic.reason, "deictic");
    assert.equal(deictic.hints.needsScreen, 0.9);

    for (const result of [calc, refuse, list]) {
      assert.equal(validateCard(result.card, { mode: "strict", allowedActions: HOST_ACTION_TYPES }).ok, true);
    }
  } finally { await f.close(); }
});

test("POST /instant is authenticated, bounded (4 KB body, 500 chars) and strictly validated", async () => {
  const f = await start({ instant: { fx: noRates() } });
  try {
    assert.equal((await f.post("/instant", { text: "1+1", phase: "final", seq: 0 }, "wrong")).status, 401);
    assert.equal((await f.post("/instant", { text: "x".repeat(4_200), phase: "final", seq: 0 })).status, 413);
    for (const body of [
      { text: "x".repeat(501), phase: "final", seq: 0 }, { text: "1+1", phase: "done", seq: 0 }, { text: "1+1", phase: "final", seq: -1 },
      { text: "1+1", phase: "final", seq: 1.5 }, { text: 5, phase: "final", seq: 0 }, { text: "1+1", phase: "final", seq: 0, takeId: "../x" },
      { text: "1+1", phase: "final", seq: 0, locale: "not a locale" }, { text: "1+1", phase: "final", seq: 0, inputMode: "telepathy" },
    ]) {
      assert.equal((await f.post("/instant", body)).status, 400, JSON.stringify(body).slice(0, 80));
    }
    assert.equal((await f.post("/instant", "{")).status, 400);
  } finally { await f.close(); }
});

test("POST /instant is latest-wins per take: a newer seq aborts the older dispatch; a stale seq is answered as superseded", async () => {
  let started = 0;
  const host = fakeHost({
    searchFiles: (_request, signal) => new Promise((_resolve, reject) => {
      started++;
      signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
    }),
  });
  const f = await start({ host, instant: { fx: noRates(), budgets: { fileSearchMs: 5_000 } } });
  try {
    const older = f.post("/instant", { text: "find invoice pdfs", phase: "partial", seq: 5, takeId: "take-1" });
    while (started === 0) await delay(2);
    const newer = await (await f.post("/instant", { text: "what is 2 + 3", phase: "partial", seq: 6, takeId: "take-1" })).json() as any;
    assert.equal(newer.decision, "answer");
    const superseded = await (await older).json() as any;
    assert.deepEqual([superseded.seq, superseded.decision, superseded.reason], [5, "fallthrough", "timeout"]);
    const stale = await (await f.post("/instant", { text: "what is 2 + 3", phase: "partial", seq: 4, takeId: "take-1" })).json() as any;
    assert.deepEqual([stale.seq, stale.decision, stale.reason], [4, "fallthrough", "timeout"]);
    // Other takes are independent.
    const other = await (await f.post("/instant", { text: "what is 2 + 3", phase: "partial", seq: 1, takeId: "take-2" })).json() as any;
    assert.equal(other.decision, "answer");
  } finally { await f.close(); }
});

test("POST /instant: the final wins over late partials of its take; requests without take or context stand alone", async () => {
  let started = 0;
  const host = fakeHost({
    searchFiles: async (_request, signal) => {
      started++;
      await delay(100);
      signal?.throwIfAborted();
      return files;
    },
  });
  const f = await start({ host, instant: { fx: noRates(), budgets: { fileSearchMs: 5_000 } } });
  const json = async (body: Record<string, unknown>) => (await f.post("/instant", body)).json() as Promise<any>;
  try {
    // A debounced partial that fires (or a connection that delivers it) after the release is stale.
    const final = json({ text: "find invoice pdfs", phase: "final", seq: 3, takeId: "take-f" });
    while (started === 0) await delay(2);
    const late = await json({ text: "find invoice pdfs and", phase: "partial", seq: 4, takeId: "take-f" });
    assert.deepEqual([late.seq, late.decision, late.reason], [4, "fallthrough", "timeout"]);
    assert.equal((await final).decision, "list", "the final was not aborted by the late partial");

    // A final is never stale because of partials: with a lower seq it still runs and supersedes them.
    started = 0;
    const partial = json({ text: "find invoice pdfs", phase: "partial", seq: 9, takeId: "take-g" });
    while (started === 0) await delay(2);
    assert.equal((await json({ text: "what is 2 + 3", phase: "final", seq: 8, takeId: "take-g" })).decision, "answer");
    assert.equal((await partial).reason, "timeout");

    // Keyless requests carry no take identity, so an earlier session's seq never makes them stale.
    assert.equal((await json({ text: "what is 2 + 3", phase: "partial", seq: 50 })).decision, "answer");
    assert.equal((await json({ text: "what is 2 + 3", phase: "partial", seq: 1 })).decision, "answer");
  } finally { await f.close(); }
});

test("POST /instant: ordinary text edits are never refused (typing and final)", async () => {
  const f = await start({ instant: { fx: noRates() } });
  try {
    for (const text of ["delete the comma", "lösch das"]) {
      for (const phase of ["typing", "final"]) {
        const result = await (await f.post("/instant", { text, phase, seq: 1, takeId: `take-edit-${phase}`, inputMode: "voice" })).json() as any;
        assert.equal(result.decision, "fallthrough", `${text} (${phase})`);
      }
    }
  } finally { await f.close(); }
});

test("POST /instant: a final file search slower than 250 ms still lists (default budgets)", async () => {
  const host = fakeHost({ searchFiles: async () => { await delay(350); return files; } });
  const f = await start({ host, instant: { fx: noRates() } });
  try {
    const result = await (await f.post("/instant", { text: "find invoice pdfs", phase: "final", seq: 1, takeId: "take-slow" })).json() as any;
    assert.equal(result.decision, "list");
  } finally { await f.close(); }
});

test("POST /instant typing: per-keystroke requests; only the query that survives 150 ms of quiet reaches the host", async () => {
  const searched: string[] = [];
  const host = fakeHost({ searchFiles: async (request) => { searched.push(request.nameGroups.flat().join(" ")); return files; } });
  const f = await start({ host, instant: { fx: noRates() } });
  try {
    const pending: Promise<any>[] = [];
    for (const [seq, text] of [[1, "find invoice"], [2, "find invoice pd"], [3, "find invoice pdfs"]] as const) {
      pending.push(f.post("/instant", { text, phase: "typing", seq, takeId: "take-typing" }).then((response) => response.json()));
      await delay(20);
    }
    const results = await Promise.all(pending);
    assert.deepEqual(results.slice(0, 2).map((r) => r.reason), ["timeout", "timeout"]);
    assert.equal(results[2].decision, "list");
    assert.equal(searched.length, 1, "superseded keystrokes never reach the host search queue");
    const started = performance.now();
    const calc = await (await f.post("/instant", { text: "15% of 340", phase: "typing", seq: 4, takeId: "take-typing-2" })).json() as any;
    assert.equal(calc.decision, "answer");
    assert.ok(calc.elapsedMs < 50 && performance.now() - started < 500);
  } finally { await f.close(); }
});

test("Windows-shaped /invoke: pure-answer intents complete with responseText + card and never start the agent", async () => {
  const s = sessions();
  const f = await start({ instant: { fx: noRates() }, createSession: s.createSession as never });
  try {
    // Exactly what the Windows host sends: no takeId, no input, no retainSession.
    const response = await f.post("/invoke", { invocationId: "win-calc", contextId: "ctx-pinned", prompt: "what is 12 * 7", invokedAt: "2026-10-02T12:00:00Z" });
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { accepted: true, invocationId: "win-calc" });
    const record = await f.terminal("win-calc");
    assert.equal(record.state, "completed");
    assert.match(record.responseText, /84/);
    assert.equal(record.cardComplete, true);
    assert.equal(record.card.format, "pi-os-ui/1");
    assert.equal(record.followupAvailable, false);
    assert.equal(record.input, undefined);
    assert.ok(record.steps.some((step: any) => step.tool === "instant" && step.detail === "answer intent=calc"));
    assert.equal(s.created.length, 0, "no agent session for an instant answer");

    // act/list need host effects the Windows host cannot perform: they fall through to the agent.
    await f.post("/invoke", { invocationId: "win-act", contextId: "ctx-pinned", prompt: "open github.com" });
    const acted = await f.terminal("win-act");
    assert.equal(s.created.length, 1, "act decisions go to the agent on /invoke");
    assert.equal(acted.responseText, "agent answer");

    // A Notice-only answer (no ECB rates yet) is not an answer to this request: the agent takes it.
    await f.post("/invoke", { invocationId: "win-fx", contextId: "ctx-pinned", prompt: "100 usd in eur" });
    const fx = await f.terminal("win-fx");
    assert.equal(fx.responseText, "agent answer");
    assert.equal(fx.card, undefined);
    assert.equal(s.created.length, 2);

    // App and file intents can never answer on /invoke, so it never calls the launcher read routes
    // (the Windows host has none).
    const before = f.host.calls.length;
    for (const [id, prompt] of [["win-app", "open figma"], ["win-file", "find invoice pdfs"]]) {
      await f.post("/invoke", { invocationId: id, contextId: "ctx-pinned", prompt });
      assert.equal((await f.terminal(id!)).responseText, "agent answer", prompt);
    }
    assert.ok(!f.host.calls.slice(before).some(call => call === "listApps" || call === "searchFiles"), f.host.calls.slice(before).join(","));
    assert.equal(s.created.length, 4);

    // Refusals stay with the agent (same deletion prohibition, native host checks), so Windows
    // keeps its previous behaviour for every request the grammar refuses.
    for (const [id, prompt] of [["win-trash", "empty the trash"], ["win-message", "delete this message"], ["win-typed", "delete everything I typed"]]) {
      await f.post("/invoke", { invocationId: id, contextId: "ctx-pinned", prompt });
      const record = await f.terminal(id!);
      assert.equal(record.responseText, "agent answer", prompt);
      assert.equal(record.card, undefined, prompt);
    }
    assert.equal(s.created.length, 7);

    // A retained thread answered instantly has no session: follow-ups are refused, never resurrected.
    await f.post("/invoke", { invocationId: "mac-calc", contextId: "ctx-pinned", prompt: "15% of 80", retainSession: true });
    const retained = await f.terminal("mac-calc");
    assert.equal(retained.followupAvailable, false);
    assert.equal((await f.post("/invocations/mac-calc/followup", { prompt: "and 20%?" })).status, 404);
  } finally { await f.close(); }
});

test("/invoke with a takeId skips the instant lane (the host ran /instant itself, or chose ⌥↵ Ask pi)", async () => {
  const s = sessions();
  const f = await start({ instant: { fx: noRates() }, createSession: s.createSession as never });
  try {
    await f.post("/invoke", { invocationId: "ask-pi", contextId: "ctx-pinned", prompt: "what is 12 * 7", takeId: "take-1", input: { mode: "text" } });
    const record = await f.terminal("ask-pi");
    assert.equal(record.responseText, "agent answer");
    assert.equal(s.created.length, 1);
    assert.equal(record.card, undefined);
    assert.deepEqual(record.input, { mode: "text" });
    assert.ok(!record.steps.some((step: any) => step.tool === "instant"));
  } finally { await f.close(); }
});

test("instant cards from the dispatcher validate strictly against the catalog (B1 × B2)", async () => {
  const dispatcher = createInstantDispatcher({
    fx: new EcbRateStore({ fetch: (async () => new Response(await readFile(resolve("../shared/fixtures/instant-cases/ecb-2026-10-02.xml"), "utf8"))) as typeof fetch,
      file: "/nonexistent-dir/fx.json", log: () => {} }),
    searchFiles: async () => files,
    budgets: { networkMs: 2_000 },
  });
  const utterances = [
    "what is 12 * 7", "15% of 80", "5 ft to cm", "0xff to decimal", "100 usd in eur", "time in tokyo", "5pm london in sf",
    "days until christmas", "in 3 weeks", "find invoice pdfs", "delete my downloads folder", "open github.com", "search the web for pi os",
    "set volume to 30%", "zwei hoch sechzehn minus tausend", "wie viel uhr ist es in new york",
  ];
  let cards = 0;
  for (const phase of ["typing", "final"] as const) {
    for (const text of utterances) {
      const response = await dispatcher.dispatch({ text, phase, seq: 0 });
      if (!("card" in response) || !response.card) continue;
      cards++;
      const checked = validateCard(response.card, { mode: "strict", allowedActions: HOST_ACTION_TYPES });
      assert.ok(checked.ok, `${phase} ${text}: ${checked.ok ? "" : checked.issues.map(issue => issue.code).join(",")}`);
    }
  }
  assert.ok(cards >= 20, `exercised ${cards} cards`);
});

test("perf and request logs carry kinds, counts and durations only: never the request text", async () => {
  const s = sessions();
  const f = await start({ instant: { fx: noRates() }, createSession: s.createSession as never });
  const marker = "zebracornflake";
  try {
    const { lines } = await captureLogs(async () => {
      await f.post("/instant", { text: `what is 3 * 3 ${marker}`, phase: "final", seq: 1 });
      await f.post("/instant", { text: `find ${marker} pdf`, phase: "final", seq: 2 });
      await f.post("/instant", { text: "what is 3 * 3", phase: "final", seq: 3 });
      await f.post("/invoke", { invocationId: "private", contextId: "ctx-pinned", prompt: `please summarize ${marker}`,
        input: { mode: "voice", locale: "de-DE", confidence: 0.8, durationMs: 1200, engine: "speech-analyzer" } });
      await f.terminal("private");
      await f.post("/invoke", { invocationId: "private-calc", contextId: "ctx-pinned", prompt: "what is 3 * 3" });
      await f.terminal("private-calc");
    });
    const perf = lines.filter(line => line.startsWith("[perf] "));
    assert.ok(perf.some(line => line.includes("stage=instant.dispatch")), "instant dispatch timings are logged");
    assert.ok(perf.some(line => line.includes("stage=invoke.total")));
    assert.ok(perf.some(line => line.includes("stage=invoke.instant")));
    for (const line of lines) {
      assert.ok(!line.includes(marker), `log line leaks request text: ${line.slice(0, 60)}`);
      assert.ok(!line.includes("speech-analyzer") && !line.includes("de-DE"), "voice metadata is never logged");
    }
  } finally { await f.close(); }
});

test("voice input is validated and recorded as mode only; invalid input is a 400", async () => {
  const s = sessions();
  const f = await start({ instant: { fx: noRates() }, createSession: s.createSession as never });
  try {
    for (const input of [{ mode: "shout" }, { mode: "voice", confidence: 2 }, { mode: "voice", locale: "x y" }, { mode: "voice", durationMs: -1 },
      { mode: "voice", engine: "bad engine!" }, "voice", ["voice"]]) {
      assert.equal((await f.post("/invoke", { contextId: "ctx-pinned", prompt: "hello there", input })).status, 400, JSON.stringify(input));
    }
    await f.post("/invoke", { invocationId: "spoken", contextId: "ctx-pinned", prompt: "tell me a joke", takeId: "take-v",
      input: { mode: "voice", confidence: 0.91, locale: "en-US", durationMs: 1800, engine: "speech-analyzer" } });
    const record = await f.terminal("spoken");
    assert.deepEqual(record.input, { mode: "voice" });
    const prompt = s.created[0]!.prompts[0]!;
    assert.match(prompt, /## Input\nThe request was spoken and transcribed by speech recognition \(en-US\)/);
    assert.ok(prompt.indexOf("## Input") < prompt.indexOf("## Request"));
    assert.doesNotMatch(prompt, /0\.91|speech-analyzer|1800/, "only the language reaches the model");
  } finally { await f.close(); }
});

test("POST /instant fallthrough hints for a take reach the router only if they already arrived", async () => {
  const f = await start({ instant: { fx: noRates() } });
  try {
    const hinted = await (await f.post("/instant", { text: "summarize this", phase: "final", seq: 1, takeId: "take-h" })).json() as any;
    assert.equal(hinted.hints.source, "heuristic");
    // Garbage takes are rejected.
    assert.equal((await f.post("/instant", { text: "summarize this", phase: "final", seq: 1, takeId: "" })).status, 400);
  } finally { await f.close(); }
});
