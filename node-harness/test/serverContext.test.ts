import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fauxAssistantMessage, fauxText, fauxToolCall, type AssistantMessage, type JsonObject } from "@earendil-works/pi-ai";
import { USE_ACTIVE_WINDOW_TOOL } from "../src/agent/computerUseExtension.js";
import { PAGE_HEADING } from "../src/agent/desktopTools.js";
import { PAGE_SECTION_HEADING } from "../src/browser/axTransport.js";
import { ATTACHMENTS_HEADING } from "../src/contracts/attachments.js";
import type { BrowserPageResult } from "../src/contracts/browser.js";
import type { ContextWire } from "../src/contracts/context.js";
import type { DesktopContextSnapshot, ScreenshotRef } from "../src/hostClient.js";
import { WINDOW_TOOLS } from "../src/agent/agentRunner.js";
import {
  agentHost, captureLogs, fakeHost, fauxRuntimes, pngFile, seen, start, tempCaptures, type HostRoute, type SeenRequest,
} from "./integrationFixtures.js";

/**
 * The server's side of context scope and the context shelf (r2/DESIGN2 §5.8/§5.9, DESIGN3): strict
 * `context` / `attachments` parsing on /invoke and /followup, general vs window turns through the
 * HTTP surface, a general turn that survives a lost window, attachments end to end, the Brave AX page
 * digest staged from the host's `browser.page`, the record's content-free `context`/`attachments`,
 * prepared sessions across scopes, and telemetry that never carries content. Real pi sessions on the
 * in-process faux provider and a fake host; no network, no model.
 */

const FIXTURES = resolve("../shared/fixtures");
const FIXTURE_CAPTURES = "/Users/fixture/Library/Application Support/pi-os/captures";
const page = (JSON.parse(readFileSync(join(FIXTURES, "browser-ax/page-response.json"), "utf8")) as { result: BrowserPageResult }).result;
const general = (source: ContextWire["source"] = "default", pull: ContextWire["pull"] = "allowed"): ContextWire => ({ scope: "general", pull, source });
const windowScope = (source: ContextWire["source"] = "user"): ContextWire => ({ scope: "window", pull: "allowed", source });
const brave = (pinned: DesktopContextSnapshot): DesktopContextSnapshot => ({
  ...pinned, browser: { name: "Brave", mode: "ax", pinned: true },
  targetWindow: { ...pinned.targetWindow!, processName: "Brave Browser", title: "Fixture feed – pi-os QA" },
});
const say = (text: string) => () => fauxAssistantMessage(text);
const call = (name: string, args: JsonObject = {}) => () => fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });

interface HarnessOptions {
  pinned?: (snapshot: DesktopContextSnapshot) => DesktopContextSnapshot;
  routes?: Record<string, HostRoute>;
  server?: Parameters<typeof start>[0];
}

/** A server on its own captures dir with a fake macOS host (agentHost) and a recorder of provider requests. */
async function harness(options: HarnessOptions = {}) {
  const captures = tempCaptures();
  const pinned = (options.pinned ?? (snapshot => snapshot))(captures.snapshot());
  const host = agentHost(captures.dir, pinned, options.routes);
  const order: string[] = [];
  const invoke = host.invokeTool.bind(host);
  host.invokeTool = async (name: string, args: Record<string, unknown> = {}) => { order.push(name); return invoke(name, args); };
  const listTools = host.getToolNames.bind(host);
  host.getToolNames = async () => { order.push("tools"); return listTools(); };
  const runtimes = fauxRuntimes();
  const f = await start({
    runtimes, ...options.server, host: host as unknown as ReturnType<typeof fakeHost>,
    config: { capturesDir: captures.dir, ...options.server?.config },
  });
  const requests: SeenRequest[] = [];
  const reply = (answer: (request: SeenRequest) => AssistantMessage) =>
    (context: unknown, _options: unknown, _state: unknown, model: { provider: string; id: string }) => {
      const request = seen(context, model);
      requests.push(request);
      return answer(request);
    };
  const invokeTurn = async (id: string, body: Record<string, unknown>) => {
    const accepted = await f.post("/invoke", { invocationId: id, contextId: "ctx-pinned", ...body });
    assert.equal(accepted.status, 202, await accepted.clone().text());
    return f.terminal(id);
  };
  const followup = async (id: string, body: Record<string, unknown>) => {
    const accepted = await f.post(`/invocations/${id}/followup`, body);
    assert.equal(accepted.status, 202, await accepted.clone().text());
    return f.terminal(id);
  };
  return {
    f, host, order, captures, pinned, runtimes, requests, reply, invokeTurn, followup,
    async close() { await f.close(); await captures.close(); },
  };
}

type Part = { type: string; text?: string };
const toolText = (request: SeenRequest) => {
  const result = request.messages.findLast(message => message.role === "toolResult");
  return ((result?.content ?? []) as Part[]).filter(part => part.type === "text").map(part => part.text).join("\n");
};

test("context and attachments are strict on /invoke and /followup: 400 with field names and issue codes, never a value", async () => {
  const s = await harness();
  try {
    const bad = async (path: string, body: Record<string, unknown>) => {
      const response = await s.f.post(path, body);
      assert.equal(response.status, 400, path);
      const raw = await response.text();
      const { error } = JSON.parse(raw) as { error: { code: string; message: string; details?: { issues: { path: string; code: string }[] } } };
      return { raw, error: { ...error, issues: error.details?.issues } };
    };
    const base = { contextId: "ctx-pinned", prompt: "what is this" };
    for (const [context, message] of [
      [{ scope: "everything-secret", pull: "allowed", source: "default" }, /context\.scope must be general or window/],
      ["general", /context must be an object/],
      [{ scope: "general", pull: "allowed", source: "default", scopeHint: 2 }, /scopeHint must be 0\.\.1/],
      [{ scope: "general", source: "default" }, /context\.pull/],
    ] as const) {
      const { raw, error } = await bad("/invoke", { ...base, invocationId: "bad-context", context });
      assert.equal(error.code, "invalid_arguments");
      assert.match(error.message, message);
      assert(!raw.includes("everything-secret"), "the value is never echoed");
    }
    const secretPath = join(s.captures.dir, "..", "secret-folder", "shelf-x.png");
    const outside = await bad("/invoke", { ...base, invocationId: "bad-attachments",
      attachments: [{ kind: "text", text: "fixture-secret-text" }, { kind: "image", path: secretPath, width: 10, height: 10 }] });
    assert.deepEqual(outside.error.issues, [{ path: "attachments[1].path", code: "outside_captures" }]);
    assert(!outside.raw.includes("secret-folder") && !outside.raw.includes("fixture-secret-text"));
    const long = await bad("/invoke", { ...base, invocationId: "bad-attachments", attachments: [{ kind: "text", text: "s".repeat(20_001) }] });
    assert.deepEqual(long.error.issues, [{ path: "attachments[0].text", code: "text_too_long" }]);
    const foreign = await bad("/invoke", { ...base, invocationId: "bad-attachments",
      attachments: [{ kind: "window", contextId: "ctx-other", app: "Notes", title: "", actionable: true }] });
    assert.deepEqual(foreign.error.issues, [{ path: "attachments[0].contextId", code: "actionable_window_mismatch" }]);
    assert.equal((await s.f.get("/invocations/bad-context")).status, 404, "nothing was created");
    assert.equal((await s.f.get("/invocations/bad-attachments")).status, 404);

    // A follow-up is held to the same rules; the thread stays open and usable.
    s.runtimes.respond([s.reply(say("TCP is reliable, UDP is not."))]);
    assert.equal((await s.invokeTurn("thread", { prompt: "explain TCP vs UDP", retainSession: true, context: general() })).state, "completed");
    assert.equal((await bad("/invocations/thread/followup", { prompt: "and this", context: { scope: "nearby" } })).error.code, "invalid_arguments");
    const mismatch = await bad("/invocations/thread/followup", { prompt: "and this",
      attachments: [{ kind: "window", contextId: "ctx-other", app: "Notes", title: "", actionable: true }] });
    assert.deepEqual(mismatch.error.issues, [{ path: "attachments[0].contextId", code: "actionable_window_mismatch" }]);
    const thread = await (await s.f.get("/invocations/thread")).json() as { followupAvailable: boolean; state: string };
    assert.deepEqual([thread.state, thread.followupAvailable], ["completed", true]);
  } finally { await s.close(); }
});

test("every shared context and attachment fixture: valid ones are accepted by /invoke, invalid ones refused with their issue code", async () => {
  const f = await start({ config: { capturesDir: FIXTURE_CAPTURES }, onInvocation: async () => {} });
  try {
    let n = 0;
    for (const folder of ["context", "attachments"]) {
      for (const name of readdirSync(join(FIXTURES, folder)).filter(file => file.startsWith("invoke-"))) {
        const body = JSON.parse(readFileSync(join(FIXTURES, folder, name), "utf8"));
        const response = await f.post("/invoke", { ...body, invocationId: `fixture-${++n}` });
        assert.equal(response.status, 202, `${folder}/${name}: ${await response.clone().text()}`);
      }
      for (const name of readdirSync(join(FIXTURES, folder, "invalid")).filter(file => file.startsWith("invoke-") || folder === "attachments")) {
        const { _expect: expected, ...body } = JSON.parse(readFileSync(join(FIXTURES, folder, "invalid", name), "utf8"));
        const response = await f.post("/invoke", { ...body, invocationId: `fixture-${++n}` });
        assert.equal(response.status, 400, `${folder}/invalid/${name}`);
        const error = (await response.json() as { error: { code: string; details?: { issues: { code: string }[] } } }).error;
        assert.equal(error.code, "invalid_arguments");
        if (expected) assert(error.details?.issues.some(issue => issue.code === expected), `${name}: expected ${expected}`);
      }
    }
    assert(n > 40);
  } finally { await f.close(); }
});

test("general vs window first turns through the server: what the model sees, which tools exist, and the record's context", async () => {
  const s = await harness();
  try {
    s.runtimes.respond([s.reply(say("TCP retransmits; UDP does not."))]);
    const plain = await s.invokeTurn("general", { prompt: "explain the difference between TCP and UDP", context: general("default") });
    assert.equal(plain.state, "completed", plain.failureMessage);
    const g = s.requests[0]!;
    assert.equal(g.requestImages, 0);
    assert.doesNotMatch(g.request, /## Desktop context/);
    assert.match(g.request, /Active app: "TextEdit" \(its window is not included\)\. Call use_active_window only if/);
    assert(!g.request.includes("Fixture"), "never the window title");
    assert(g.tools.includes(USE_ACTIVE_WINDOW_TOOL) && !g.tools.includes("desktop_act") && !g.tools.includes("desktop_capture_window"));
    assert.deepEqual(plain.context, { scope: "general", source: "default", pulled: false, included: false });
    assert(plain.route.reasons.includes("scope=general"), "the host's scope reaches the router");
    assert.equal(plain.attachments, undefined);

    s.runtimes.respond([s.reply(say("Leaves fall."))]);
    const shown = await s.invokeTurn("window", { prompt: "write a haiku about autumn", context: windowScope("user") });
    assert.equal(shown.state, "completed", shown.failureMessage);
    const w = s.requests[1]!;
    assert.equal(w.requestImages, 1, "an explicitly included window is always shown");
    assert.match(w.request, /^## Desktop context/);
    assert(w.tools.includes("desktop_act") && !w.tools.includes(USE_ACTIVE_WINDOW_TOOL));
    assert.deepEqual(shown.context, { scope: "window", source: "user", pulled: false, included: true });
    assert(shown.route.reasons.includes("scope=window") && shown.route.reasons.includes("screenshot"));

    s.runtimes.respond([s.reply(say("Not included."))]);
    const denied = await s.invokeTurn("denied", { prompt: "what is on my screen", context: general("setting", "denied") });
    assert.equal(denied.state, "completed");
    assert.match(s.requests[2]!.request, /the user chose not to share it/);
    assert(!s.requests[2]!.tools.includes(USE_ACTIVE_WINDOW_TOOL));
  } finally { await s.close(); }
});

test("use_active_window: the record says pulled once the agent looked, and the window tools follow in the next model turn", async () => {
  const s = await harness();
  try {
    s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(say("The error says the disk is full."))]);
    const record = await s.invokeTurn("pull", { prompt: "what does this error mean", context: general("default"), retainSession: true });
    assert.equal(record.state, "completed", record.failureMessage);
    assert.deepEqual(record.context, { scope: "general", source: "default", pulled: true, included: true });
    assert(s.host.names().includes("desktop.getContext") && s.host.names().includes("desktop.captureWindow"));
    assert(s.requests[1]!.tools.includes("desktop_act") && !s.requests[1]!.tools.includes(USE_ACTIVE_WINDOW_TOOL));
    assert(record.route.reasons.includes("scope=general"));

    // The pulled thread routes as window from now on; the record keeps the thread's scope across follow-ups.
    s.runtimes.respond([s.reply(say("Delete some files you no longer need."))]);
    const next = await s.followup("pull", { prompt: "how do I fix it" });
    assert.equal(next.state, "completed", next.failureMessage);
    assert.deepEqual(next.context, { scope: "general", source: "default", pulled: true, included: true });
    assert(next.route.reasons.includes("scope=window"), "a pull routes the thread as window");
  } finally { await s.close(); }
});

test("a general turn survives a lost window (named by the app it was pinned on); window and legacy turns fail as before", async () => {
  const s = await harness({ server: { prepareTtlMs: 10_000 } });
  const real = s.host.getSnapshot.bind(s.host);
  const fail = (code: string) => {
    s.host.getSnapshot = async () => ({ ok: false, result: undefined as never, error: { code, message: "Window 'Secret Doc' is gone" } }) as never;
  };
  try {
    // The take was pinned (prepare read the context) before the window closed.
    await s.f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-lost" });
    for (let i = 0; i < 400 && s.runtimes.created < 1; i++) await delay(5);
    fail("target_gone");
    s.runtimes.respond([s.reply(say("A general answer."))]);
    const { lines, result: gone } = await captureLogs(() => s.invokeTurn("gone", { prompt: "explain DNS", context: general(), takeId: "take-lost" }));
    assert.equal(gone.state, "completed", gone.failureMessage);
    assert.match(s.requests[0]!.request, /Active app: "TextEdit" \(its window is not included\)/);
    assert.doesNotMatch(s.requests[0]!.request, /Fixture|Secret Doc|## Desktop context/);
    assert.equal(s.requests[0]!.requestImages, 0);
    assert(gone.steps.some((step: { tool: string; ok: boolean }) => step.tool === "desktop.getContext" && !step.ok));
    assert(!lines.some(line => line.includes("Secret Doc")), "host messages never reach the log");
    assert(lines.some(line => line.includes("stage=invoke.context") && line.includes("window=false") && line.includes("code=target_gone")));

    for (const code of ["no_target", "permission_denied", "unknown_context"]) {
      fail(code);
      s.runtimes.respond([s.reply(say("Still fine."))]);
      const record = await s.invokeTurn(`general-${code}`, { prompt: "explain DNS", context: general() });
      assert.equal(record.state, "completed", `${code}: ${record.failureMessage}`);
    }
    s.host.getSnapshot = async () => { throw new Error("Host returned HTTP 500 for desktop.getContext"); };
    s.runtimes.respond([s.reply(say("Still fine."))]);
    assert.equal((await s.invokeTurn("general-host-error", { prompt: "explain DNS", context: general() })).state, "completed");

    fail("target_gone");
    const strict = await s.invokeTurn("window-gone", { prompt: "click the button", context: windowScope() });
    assert.equal(strict.state, "failed");
    assert.match(strict.failureMessage, /Pinned context unavailable \(target_gone\)/);
    const legacy = await s.invokeTurn("legacy-gone", { prompt: "click the button" });
    assert.equal(legacy.state, "failed");
    assert.match(legacy.failureMessage, /Pinned context unavailable \(target_gone\)/);

    // A general thread's follow-up also continues; widening it to the lost window does not.
    s.host.getSnapshot = real;
    s.runtimes.respond([s.reply(say("First."))]);
    assert.equal((await s.invokeTurn("thread", { prompt: "explain DNS", context: general(), retainSession: true })).state, "completed");
    fail("target_gone");
    s.runtimes.respond([s.reply(say("Second."))]);
    const later = await s.followup("thread", { prompt: "and DHCP?" });
    assert.equal(later.state, "completed", later.failureMessage);
    assert.match(s.requests.at(-1)!.request, /Active app: "TextEdit"|## Request\nand DHCP\?/);
    const widened = await s.followup("thread", { prompt: "now look at it", context: windowScope() });
    assert.equal(widened.state, "failed");
  } finally { await s.close(); }
});

test("attachments end to end: fenced text, a shelf image after the request, the pointed-at element; the record keeps summaries only", async () => {
  const s = await harness();
  const shelf = join(s.captures.dir, "shelf-a1.png");
  pngFile(shelf, 640, 400);
  const attachments = [
    { kind: "text", text: "Quarterly numbers: 4711 fixture units", origin: "selection", source: { app: "Notes", title: "Budget fixture" } },
    { kind: "image", path: shelf, width: 640, height: 400, origin: "region" },
    { kind: "element", contextId: "ctx-pinned", role: "AXButton", label: "Like", bounds: { x: 412, y: 300, width: 64, height: 28 } },
  ];
  try {
    s.runtimes.respond([s.reply(say("Those are the Q3 numbers."))]);
    const record = await s.invokeTurn("shelf", { prompt: "summarize these", context: general(), attachments });
    assert.equal(record.state, "completed", record.failureMessage);
    const request = s.requests[0]!;
    assert(request.request.includes(ATTACHMENTS_HEADING));
    assert.match(request.request, /<attachment-[a-z0-9]+ id="1">\nQuarterly numbers: 4711 fixture units\n<\/attachment-[a-z0-9]+>/);
    assert.match(request.request, /The user is pointing at button "Like" \(attachment \[3\]\)\./);
    assert(request.request.indexOf(ATTACHMENTS_HEADING) < request.request.indexOf("## Request"));
    assert.equal(request.requestImages, 0, "no window screenshot in a general turn");
    assert.equal(request.extras.filter(part => part.type === "image").length, 1, "the shelf image follows the request");
    assert(!request.request.includes(shelf) && !request.request.includes("shelf-a1"), "paths never reach the model");
    assert(record.route.reasons.includes("image-attachment"), "an image needs a vision-capable model");
    assert.deepEqual(record.attachments, [
      { kind: "text", origin: "selection", chars: 37 },
      { kind: "image", origin: "region", width: 640, height: 400 },
      { kind: "element" },
    ]);
    const raw = JSON.stringify(record);
    for (const secret of ["4711", "Budget fixture", "Like", "shelf-a1"]) assert(!raw.includes(secret), `the record never carries ${secret}`);

    // A request that carries attachments is never answered by the instant lane (it is for the agent).
    s.runtimes.respond([s.reply(say("It is 9."))]);
    const math = await s.invokeTurn("math", { prompt: "4 + 5", attachments: [{ kind: "text", text: "context fixture" }] });
    assert.equal(math.state, "completed");
    assert.equal(math.responseText, "It is 9.");
  } finally { await s.close(); }
});

test("follow-ups carry their own attachments and context; the record replaces the summaries per turn and keeps the scope", async () => {
  const s = await harness();
  try {
    s.runtimes.respond([s.reply(say("Here it is."))]);
    assert.equal((await s.invokeTurn("thread", { prompt: "translate hello", context: general(), retainSession: true,
      attachments: [{ kind: "text", text: "Guten Morgen", origin: "clipboard" }] })).state, "completed");
    s.runtimes.respond([s.reply(say("Good evening."))]);
    const second = await s.followup("thread", { prompt: "and this", attachments: [{ kind: "text", text: "Guten Abend", origin: "selection" }] });
    assert.equal(second.state, "completed", second.failureMessage);
    assert.match(s.requests[1]!.request, /Guten Abend/);
    assert.deepEqual(second.attachments, [{ kind: "text", origin: "selection", chars: 11 }]);
    assert.deepEqual(second.context, { scope: "general", source: "default", pulled: false, included: false });

    s.runtimes.respond([s.reply(say("It shows a document."))]);
    const widened = await s.followup("thread", { prompt: "now look at the window", context: { scope: "window", pull: "allowed", source: "user", scopeHint: 0.9 } });
    assert.equal(widened.state, "completed", widened.failureMessage);
    assert.equal(widened.attachments, undefined, "summaries belong to their turn");
    assert.deepEqual(widened.context, { scope: "window", source: "user", pulled: false, included: true });
    assert.match(s.requests[2]!.request, /^## Follow-up: the user included the active window/);
    assert(s.requests[2]!.tools.includes("desktop_act"));
  } finally { await s.close(); }
});

test("a follow-up that brings the window into a general thread shows a fresh capture of the pin, never a missing or key-down image", async () => {
  // A general take is never captured: the host's snapshot has no screenshot (or an old one) when the chip turns on later.
  for (const [label, pinned] of [
    ["uncaptured", (snapshot: DesktopContextSnapshot) => ({ ...snapshot, screenshot: null })],
    ["key-down image", (snapshot: DesktopContextSnapshot) => snapshot],
  ] as const) {
    const s = await harness({ pinned });
    try {
      s.runtimes.respond([s.reply(say("DNS maps names to addresses."))]);
      assert.equal((await s.invokeTurn("thread", { prompt: "explain DNS", context: general(), retainSession: true })).state, "completed");
      assert(!s.host.names().includes("desktop.captureWindow"), `${label}: a general turn captures nothing`);
      s.runtimes.respond([s.reply(say("It shows a document."))]);
      const widened = await s.followup("thread", { prompt: "now look at the window", context: windowScope("user") });
      assert.equal(widened.state, "completed", `${label}: ${widened.failureMessage}`);
      const calls = s.host.calls.filter(call => call.name === "desktop.captureWindow");
      assert.equal(calls.length, 1, `${label}: one fresh capture of the pin`);
      assert.equal(calls[0]!.args.contextId, "ctx-pinned");
      assert.equal(s.requests[1]!.requestImages, 1, `${label}: the fresh capture is shown`);
      assert.match(s.requests[1]!.request, /The current screenshot of the window is attached for viewing/);
      assert(widened.steps.some((step: { tool: string; ok: boolean; detail?: string }) => step.tool === "desktop.captureWindow" && step.ok && step.detail === "imageId=shot-2"));

      // An inherited window thread's follow-up does not capture again (the model captures before acting).
      s.runtimes.respond([s.reply(say("Still a document."))]);
      assert.equal((await s.followup("thread", { prompt: "and now?" })).state, "completed");
      assert.equal(s.host.calls.filter(call => call.name === "desktop.captureWindow").length, 1, `${label}: no capture without an upgrade`);
      if (label === "key-down image") {
        // Nor does the follow-up chip's inherited window wire when the pinned snapshot already has a screenshot.
        s.runtimes.respond([s.reply(say("Still the same document."))]);
        assert.equal((await s.followup("thread", { prompt: "and now?", context: windowScope("followup") })).state, "completed");
        assert.equal(s.host.calls.filter(call => call.name === "desktop.captureWindow").length, 1, `${label}: a screenshot exists, no capture`);
        assert.equal(s.requests.at(-1)!.requestImages, 0);
      }
    } finally { await s.close(); }
  }

  // Without Screen Recording the widened follow-up goes on text-only; the record keeps the code, never the host's message.
  const s = await harness({
    pinned: snapshot => ({ ...snapshot, screenshot: null }),
    routes: { "desktop.captureWindow": async () => ({ ok: false, error: { code: "permission_denied", message: "Cannot capture 'Secret Doc'" } }) },
  });
  try {
    s.runtimes.respond([s.reply(say("First."))]);
    assert.equal((await s.invokeTurn("thread", { prompt: "explain DNS", context: general(), retainSession: true })).state, "completed");
    s.runtimes.respond([s.reply(say("Text only."))]);
    const widened = await s.followup("thread", { prompt: "now look at the window", context: windowScope("user") });
    assert.equal(widened.state, "completed", widened.failureMessage);
    assert.equal(s.requests[1]!.requestImages, 0);
    assert.match(s.requests[1]!.request, /No screenshot is attached; call desktop_capture_window/);
    const step = widened.steps.find((entry: { tool: string }) => entry.tool === "desktop.captureWindow");
    assert.deepEqual([step?.ok, step?.detail], [false, "permission_denied"]);
  } finally { await s.close(); }
});

test("a widening whose fresh capture fails goes on text-only: an older key-down image is never passed off as current", async () => {
  const s = await harness({
    routes: { "desktop.captureWindow": async () => ({ ok: false, error: { code: "permission_denied", message: "Cannot capture 'Secret Doc'" } }) },
  });
  try {
    assert(s.pinned.screenshot?.filePath, "the pin holds the take's key-down image");
    s.runtimes.respond([s.reply(say("First."))]);
    assert.equal((await s.invokeTurn("thread", { prompt: "explain DNS", context: general(), retainSession: true })).state, "completed");
    s.runtimes.respond([s.reply(say("Text only."))]);
    const widened = await s.followup("thread", { prompt: "now look at the window", context: windowScope("user") });
    assert.equal(widened.state, "completed", widened.failureMessage);
    assert.equal(s.requests[1]!.requestImages, 0);
    assert.match(s.requests[1]!.request, /No screenshot is attached; call desktop_capture_window/);
    assert.doesNotMatch(s.requests[1]!.request, /"screenshot":\{/, "the summary names no screenshot either");
  } finally { await s.close(); }
});

/** The host's context keeps its latest capture (DesktopService: a capture updates the pinned snapshot's screenshot). */
function latestCaptureHost(s: Awaited<ReturnType<typeof harness>>, initial: ScreenshotRef | null): void {
  let latest = initial;
  const invoke = s.host.invokeTool.bind(s.host);
  s.host.invokeTool = async (name: string, args: Record<string, unknown> = {}) => {
    const outcome = await invoke(name, args) as { ok: boolean; result?: unknown };
    if (name === "desktop.captureWindow" && outcome.ok) latest = outcome.result as ScreenshotRef;
    return outcome;
  };
  s.host.getSnapshot = async () => ({ ok: true, result: { ...s.pinned, screenshot: latest } });
}

test("the harness is the only party that captures for a follow-up: a window thread without a screenshot gets one fresh capture, shown for viewing", async () => {
  // A window turn whose capture failed: the host's context has no screenshot until something captures.
  const s = await harness({ pinned: snapshot => ({ ...snapshot, screenshot: null }) });
  latestCaptureHost(s, null);
  const captures = () => s.host.calls.filter(call => call.name === "desktop.captureWindow");
  try {
    s.runtimes.respond([s.reply(say("I cannot see the window."))]);
    const first = await s.invokeTurn("thread", { prompt: "what does this say", context: windowScope("user"), retainSession: true });
    assert.equal(first.state, "completed", first.failureMessage);
    assert.equal(s.requests[0]!.requestImages, 0);
    assert.equal(captures().length, 0);

    // The follow-up chip's wire {window, allowed, followup}: one capture of the pin, in parallel with the session, shown.
    s.runtimes.respond([s.reply(call("desktop_act", { action: "click", x: 3, y: 3 })), s.reply(say("Clicked."))]);
    const next = await s.followup("thread", { prompt: "click the button", context: windowScope("followup") });
    assert.equal(next.state, "completed", next.failureMessage);
    const names = s.host.names();
    assert.deepEqual(names.slice(0, names.indexOf("input.click")).filter(name => name === "desktop.captureWindow"), ["desktop.captureWindow"],
      "exactly one capture before the model acted (the click's own post-action capture follows it)");
    assert.equal(captures()[0]!.args.contextId, "ctx-pinned");
    const request = s.requests[1]!;
    assert.equal(request.requestImages, 1, "the fresh capture is shown");
    assert.match(request.request, /^## Follow-up on the same pinned target\n[\s\S]*\nThe current screenshot of the window is attached for viewing; call desktop_capture_window before the first coordinate action\.\n## Request\nclick the button$/);
    assert(next.route.reasons.includes("screenshot"), "routed like a request with the window image");
    assert.deepEqual(next.context, { scope: "window", source: "user", pulled: false, included: true });
    // Viewing only: a click right after it carries no screenshot authority.
    assert.equal(s.host.calls.find(call => call.name === "input.click")?.args.screenshotId, undefined);

    // The host's context now holds a capture: the next window follow-up takes none and shows none.
    const before = captures().length;
    s.runtimes.respond([s.reply(say("Done."))]);
    assert.equal((await s.followup("thread", { prompt: "and now?", context: windowScope("followup") })).state, "completed");
    assert.equal(captures().length, before);
    assert.equal(s.requests.at(-1)!.requestImages, 0);
    assert.match(s.requests.at(-1)!.request, /^## Follow-up on the same pinned target\n[^\n]*\n[^\n]*\n## Request\nand now\?$/);
  } finally { await s.close(); }
});

test("the record's included follows the live thread: a pull includes the window, the chip inherits it, Tab narrows it, a widening captures afresh", async () => {
  const s = await harness();
  const captures = () => s.host.calls.filter(call => call.name === "desktop.captureWindow").length;
  try {
    s.runtimes.respond([s.reply(say("Paris."))]);
    const plain = await s.invokeTurn("plain", { prompt: "capital of France", context: general() });
    assert.deepEqual(plain.context, { scope: "general", source: "default", pulled: false, included: false });

    s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(say("A disk-full error."))]);
    const pulled = await s.invokeTurn("thread", { prompt: "what does this error mean", context: general(), retainSession: true });
    assert.deepEqual(pulled.context, { scope: "general", source: "default", pulled: true, included: true });
    const afterPull = captures();

    // The follow-up chip inherits `included` and sends {window, allowed, followup}: the pull's capture is the thread's.
    s.runtimes.respond([s.reply(say("Free some disk space."))]);
    const inherited = await s.followup("thread", { prompt: "how do I fix it", context: windowScope("followup") });
    assert.equal(inherited.state, "completed", inherited.failureMessage);
    assert.deepEqual(inherited.context, { scope: "window", source: "default", pulled: true, included: true });
    assert(inherited.route.reasons.includes("scope=window"));
    assert.match(s.requests.at(-1)!.request, /^## Follow-up on the same pinned target\n/);
    assert(s.requests.at(-1)!.tools.includes("desktop_act"));
    assert.equal(captures(), afterPull, "no second capture");

    // One Tab: {general, user} narrows it; `pulled` stays for the note, `included` turns false.
    s.runtimes.respond([s.reply(say("DNS maps names."))]);
    const narrowed = await s.followup("thread", { prompt: "unrelated: what is DNS", context: general("user") });
    assert.deepEqual(narrowed.context, { scope: "general", source: "user", pulled: true, included: false });
    // The chip is off now and sends {general, allowed, followup}: the thread stays general.
    s.runtimes.respond([s.reply(say("DHCP hands out addresses."))]);
    const kept = await s.followup("thread", { prompt: "and DHCP?", context: general("followup") });
    assert.equal(kept.context.included, false);
    assert.equal(s.requests.at(-1)!.request, "## Request\nand DHCP?");

    s.runtimes.respond([s.reply(say("Looking again."))]);
    const widened = await s.followup("thread", { prompt: "look at it again", context: windowScope("user") });
    assert.deepEqual(widened.context, { scope: "window", source: "user", pulled: true, included: true });
    assert.equal(captures(), afterPull + 1, "one fresh capture for the widening");
  } finally { await s.close(); }
});

test("a follow-up whose pulled-in window is gone goes on general instead of ending the thread; a window the host chose still fails", async () => {
  const gone = (s: Awaited<ReturnType<typeof harness>>, code: string) => {
    s.host.getSnapshot = async () => ({ ok: false, result: undefined as never, error: { code, message: "Window 'Secret Doc' is gone" } }) as never;
  };
  for (const [label, code, context] of [
    ["chip on (inherited)", "target_gone", windowScope("followup")],
    ["chip off (older host)", "no_target", general("followup")],
    ["no context", "target_gone", undefined],
  ] as const) {
    const s = await harness();
    try {
      s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(say("A disk-full error."))]);
      assert.equal((await s.invokeTurn("thread", { prompt: "what does this error mean", context: general(), retainSession: true })).state, "completed");
      const before = s.host.calls.length;
      gone(s, code);
      s.runtimes.respond([s.reply(say("Free some disk space; the dialog itself is closed."))]);
      const { lines, result: next } = await captureLogs(() => s.followup("thread", { prompt: "how do I fix it", ...(context ? { context } : {}) }));
      assert.equal(next.state, "completed", `${label}: ${next.failureMessage}`);
      assert.equal(next.followupAvailable, true, `${label}: the thread stays open`);
      const request = s.requests.at(-1)!;
      assert.match(request.request, /^## Follow-up: the window is no longer available\nThe window looked at earlier in this thread was closed/, label);
      assert.equal(request.requestImages, 0);
      assert(!request.tools.some(tool => WINDOW_TOOLS.includes(tool)) && !request.tools.includes(USE_ACTIVE_WINDOW_TOOL), `${label}: no window tools, no loader`);
      assert.deepEqual(next.context, { scope: "general", source: "default", pulled: true, included: false }, label);
      assert.deepEqual(s.host.calls.slice(before).map(call => call.name), [], `${label}: no capture or page read of a gone window`);
      assert(next.steps.some((step: { tool: string; ok: boolean }) => step.tool === "desktop.getContext" && !step.ok));
      assert(!lines.some(line => line.includes("Secret Doc")), "host messages never reach the log");
      assert(lines.some(line => line.includes("stage=invoke.context") && line.includes("general=true") && line.includes(`code=${code}`)));

      // The thread goes on general: the chip is off now.
      s.runtimes.respond([s.reply(say("You're welcome."))]);
      const later = await s.followup("thread", { prompt: "thanks", context: general("followup") });
      assert.equal(later.state, "completed", `${label}: ${later.failureMessage}`);
      assert.equal(s.requests.at(-1)!.request, "## Request\nthanks");
    } finally { await s.close(); }
  }

  const s = await harness();
  try {
    // Other host codes keep failing: only a gone window is released.
    s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(say("A disk-full error."))]);
    assert.equal((await s.invokeTurn("denied", { prompt: "what does this error mean", context: general(), retainSession: true })).state, "completed");
    gone(s, "permission_denied");
    const denied = await s.followup("denied", { prompt: "how do I fix it", context: windowScope("followup") });
    assert.equal(denied.state, "failed");
    assert.match(denied.failureMessage, /Pinned context unavailable \(permission_denied\)/);

    // A pulled thread the host then widened explicitly is a window thread it chose: strict, as before.
    s.host.getSnapshot = async () => ({ ok: true, result: s.pinned });
    s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(say("A disk-full error."))]);
    assert.equal((await s.invokeTurn("chosen", { prompt: "what does this error mean", context: general(), retainSession: true })).state, "completed");
    s.runtimes.respond([s.reply(say("Still the error."))]);
    assert.equal((await s.followup("chosen", { prompt: "keep it included", context: windowScope("user") })).state, "completed");
    gone(s, "target_gone");
    const strict = await s.followup("chosen", { prompt: "how do I fix it", context: windowScope("followup") });
    assert.equal(strict.state, "failed");
    assert.match(strict.failureMessage, /Pinned context unavailable \(target_gone\)/);
    assert.equal(strict.followupAvailable, false);
  } finally { await s.close(); }
});

test("a thread the user narrows after a pull is general again: its follow-ups survive a lost window and a later widening captures afresh", async () => {
  const s = await harness();
  try {
    s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(say("A disk-full error."))]);
    assert.equal((await s.invokeTurn("thread", { prompt: "what does this error mean", context: general(), retainSession: true })).state, "completed");
    s.runtimes.respond([s.reply(say("General again."))]);
    const narrowed = await s.followup("thread", { prompt: "leave the window out", context: general("user") });
    assert.equal(narrowed.state, "completed", narrowed.failureMessage);
    assert.deepEqual(narrowed.context, { scope: "general", source: "user", pulled: true, included: false }, "pulled stays: the agent looked once; the window is out");

    const real = s.host.getSnapshot.bind(s.host);
    s.host.getSnapshot = async () => ({ ok: false, result: undefined as never, error: { code: "target_gone", message: "gone" } }) as never;
    s.runtimes.respond([s.reply(say("Still fine."))]);
    const inherited = await s.followup("thread", { prompt: "and DHCP?" });
    assert.equal(inherited.state, "completed", inherited.failureMessage);
    s.host.getSnapshot = real;

    const before = s.host.calls.filter(call => call.name === "desktop.captureWindow").length;
    s.runtimes.respond([s.reply(say("Looking again."))]);
    const widened = await s.followup("thread", { prompt: "look at it again", context: windowScope("user") });
    assert.equal(widened.state, "completed", widened.failureMessage);
    assert.match(s.requests.at(-1)!.request, /^## Follow-up: the user included the active window/);
    assert.equal(s.host.calls.filter(call => call.name === "desktop.captureWindow").length, before + 1);
    assert.equal(s.requests.at(-1)!.requestImages, 1);
  } finally { await s.close(); }
});

test("Brave AX digest: staged into a window turn from browser.page (started before the session), read only on a pull in a general turn, never via DevTools", async () => {
  let reads = 0;
  const s = await harness({
    pinned: brave,
    routes: { "browser.page": async () => { reads++; await delay(30); return { ok: true, result: page }; } },
  });
  try {
    s.runtimes.respond([s.reply(say("A fixture feed with two posts."))]);
    const staged = await s.invokeTurn("staged", { prompt: "summarize this page", context: windowScope("suggested") });
    assert.equal(staged.state, "completed", staged.failureMessage);
    const request = s.requests[0]!;
    assert.equal(s.requests.length, 1, "one model turn: the page is already in it");
    assert(request.request.includes(PAGE_SECTION_HEADING), "the AX transport's digest, whose refs the turn can act on");
    assert.match(request.request, /A harmless post used by pi-os QA\./);
    assert.equal(reads, 1);
    assert.equal(typeof staged.timings.pageMs, "number");
    assert(s.order.indexOf("browser.page") < s.order.indexOf("tools"), "the page read starts before the session is negotiated and built");
    assert.deepEqual(s.order.filter(name => name.startsWith("browser.") && name !== "browser.page"), [], "no DevTools route");

    s.order.length = 0;
    s.runtimes.respond([s.reply(say("Paris."))]);
    assert.equal((await s.invokeTurn("general", { prompt: "what is the capital of France", context: general() })).state, "completed");
    assert.equal(reads, 1, "a general turn never reads the page");
    assert(!s.requests[1]!.request.includes("harmless post"));

    s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(say("The first post is liked."))]);
    const pulled = await s.invokeTurn("pulled", { prompt: "which post did I like", context: general() });
    assert.equal(pulled.state, "completed", pulled.failureMessage);
    assert.equal(reads, 2, "the pull reads the page once");
    assert.match(toolText(s.requests[3]!), /A harmless post used by pi-os QA\./);
    assert.equal(pulled.context.pulled, true);
  } finally { await s.close(); }
});

test("Brave in the background through the server: the staged read's refs act via browser.axAct in turn 1; a take prepared with other background acting is rebuilt", async () => {
  const acted = JSON.parse(readFileSync(join(FIXTURES, "browser-ax/axact-response.json"), "utf8"));
  let hint: NonNullable<DesktopContextSnapshot["browser"]> = { name: "Brave", mode: "ax", pinned: true, background: true };
  const s = await harness({
    pinned: pinned => ({ ...brave(pinned), browser: hint }),
    routes: { "browser.page": async () => ({ ok: true, result: page }), "browser.axAct": async () => acted },
    server: { prepareTtlMs: 10_000 },
  });
  s.host.getSnapshot = async () => ({ ok: true, result: { ...s.pinned, browser: hint } });
  try {
    s.runtimes.respond([s.reply(call("browser_act", { action: "press", ref: "e3" })), s.reply(say("Liked the first post."))]);
    const record = await s.invokeTurn("like", { prompt: "like the first post", context: windowScope() });
    assert.equal(record.state, "completed", record.failureMessage);
    assert.deepEqual(s.host.calls.filter(c => c.name === "browser.axAct").map(c => c.args), [{ contextId: "ctx-pinned", ref: "e3", action: "press" }]);
    assert.equal(s.order.filter(name => name === "browser.page").length, 1, "the staged read only: no browser_snapshot before acting");
    assert.match(toolText(s.requests[1]!), /^Performed once: press on e3\./);
    assert.deepEqual(s.order.filter(name => name.startsWith("browser.") && !["browser.page", "browser.axAct"].includes(name)), [], "no DevTools route");
    assert(!s.order.some(name => name.startsWith("input.") || name === "window.focus"), "Brave was never brought to the front");

    // Key-down built a session that may act in the background; the user turned that off before sending.
    const before = s.runtimes.created;
    await s.f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-bg" });
    for (let i = 0; i < 400 && s.runtimes.created < before + 1; i++) await delay(5);
    hint = { ...hint, background: false };
    s.runtimes.respond([s.reply(say("Click Like on the first post."))]);
    const { lines, result } = await captureLogs(() => s.invokeTurn("take-bg", { prompt: "like the first post", context: windowScope(), takeId: "take-bg" }));
    assert.equal(result.state, "completed", result.failureMessage);
    assert(lines.some(line => line.includes("[prepare] discarded reason=mismatch")), "the prepared session is not reused");
    const tools = s.requests.at(-1)!.tools;
    assert(tools.includes("browser_snapshot") && tools.includes("desktop_act") && !tools.includes("browser_act"));
  } finally { await s.close(); }
});

test("a page that fails the contract, errs or hangs is left out: the turn goes on without it, never waiting past the bound", async () => {
  const leaked = JSON.parse(readFileSync(join(FIXTURES, "browser-ax/invalid/page-response-secure-value.json"), "utf8"));
  for (const [label, route] of [
    ["invalid", async () => leaked],
    ["stale", async () => JSON.parse(readFileSync(join(FIXTURES, "browser-ax/page-response-stale.json"), "utf8"))],
    ["hung", () => new Promise(() => {})],
  ] as const) {
    const s = await harness({ pinned: brave, routes: { "browser.page": route as HostRoute } });
    try {
      s.runtimes.respond([s.reply(say("I could not read the page, but here is what I see."))]);
      const started = performance.now();
      const record = await s.invokeTurn(label, { prompt: "summarize this page", context: windowScope() });
      assert.equal(record.state, "completed", `${label}: ${record.failureMessage}`);
      assert(!s.requests[0]!.request.includes(PAGE_SECTION_HEADING) && !s.requests[0]!.request.includes(PAGE_HEADING), `${label}: no digest`);
      assert.equal(s.requests[0]!.requestImages, 1, `${label}: the screenshot still goes`);
      assert(performance.now() - started < 4_000, `${label}: bounded`);
    } finally { await s.close(); }
  }
});

test("legacy and Windows invokes are unchanged: no context means today's window turn, no record context or attachments, no page read", async () => {
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes, platform: "win32" });
  const requests: SeenRequest[] = [];
  runtimes.respond([(context, _options, _state, model) => { requests.push(seen(context, model)); return fauxAssistantMessage("Summary."); }]);
  try {
    await f.post("/invoke", { invocationId: "win", contextId: "ctx-pinned", prompt: "summarize the document" });
    const record = await f.terminal("win");
    assert.equal(record.state, "completed", record.failureMessage);
    assert.equal(requests[0]!.requestImages, 1, "every Windows first prompt keeps its screenshot");
    assert.match(requests[0]!.request, /^## Desktop context/);
    assert.doesNotMatch(requests[0]!.request, /Active app:|use_active_window/);
    assert(!requests[0]!.tools.includes(USE_ACTIVE_WINDOW_TOOL));
    assert.equal("context" in record, false);
    assert.equal("attachments" in record, false);
    assert.equal(f.host.calls.filter(name => name.startsWith("tool:")).length, 0, "no page or browser route");
  } finally { await f.close(); }

  const s = await harness();
  try {
    s.runtimes.respond([s.reply(say("It is a fixture."))]);
    const legacy = await s.invokeTurn("legacy", { prompt: "what does this error mean" });
    assert.equal(legacy.state, "completed");
    assert.equal(legacy.context, undefined);
    assert(!legacy.route.reasons.some((reason: string) => reason.startsWith("scope=")), "legacy routing uses no scope");
    assert(s.requests[0]!.tools.includes("desktop_act") && !s.requests[0]!.tools.includes(USE_ACTIVE_WINDOW_TOOL));
  } finally { await s.close(); }
});

test("prepared sessions serve every scope, and a take prepared before its capture adopts the screenshot instead of rebuilding", async () => {
  const s = await harness({ server: { prepareTtlMs: 10_000 } });
  const settle = async (count: number) => { for (let i = 0; i < 400 && s.runtimes.created < count; i++) await delay(5); };
  // Key-down pins the context; the host's capture lands only after the prepare read it.
  let captured = false;
  s.host.getSnapshot = async () => ({ ok: true, result: captured ? s.pinned : { ...s.pinned, screenshot: null } });
  try {
    for (const [take, context, prompt] of [
      ["take-g", general(), "explain DNS"],
      ["take-w", windowScope(), "write a haiku about autumn"],
    ] as const) {
      const before = s.runtimes.created;
      captured = false;
      await s.f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: take });
      await settle(before + 1);
      captured = true;
      s.runtimes.respond([s.reply(say("Done."))]);
      const { lines, result } = await captureLogs(() => s.invokeTurn(take, { prompt, context, takeId: take }));
      assert.equal(result.state, "completed", result.failureMessage);
      assert.equal(s.runtimes.created, before + 1, `${context.scope}: the prepared session is used`);
      assert(lines.some(line => line.includes("stage=invoke.session") && line.includes("prepared=true")));
      assert(!lines.some(line => line.includes("[prepare] discarded")), `${context.scope}: no rebuild`);
    }
    assert.equal(s.requests[0]!.requestImages, 0);
    assert.equal(s.requests[1]!.requestImages, 1, "the window turn shows the capture the prepared session adopted");
  } finally { await s.close(); }
});

test("telemetry is content-free: no prompt, attachment, page or path text in any log line; scope, page and totals as codes and counts", async () => {
  const s = await harness({ pinned: brave, routes: { "browser.page": async () => ({ ok: true, result: page }) } });
  const shelf = join(s.captures.dir, "shelf-t1.png");
  pngFile(shelf, 320, 200);
  const prompt = "zebra-quokka summarize this page for me";
  try {
    s.runtimes.respond([s.reply(() => fauxAssistantMessage([fauxText("Two posts.")]))]);
    const { lines, result } = await captureLogs(() => s.invokeTurn("telemetry", {
      prompt, context: { ...windowScope("user"), scopeHint: 0.35 }, input: { mode: "voice", locale: "en-US" },
      attachments: [
        { kind: "text", text: "marmot-ledger 9917", origin: "clipboard", source: { app: "Numbers", title: "Ledger fixture" } },
        { kind: "image", path: shelf, width: 320, height: 200, origin: "drop" },
        { kind: "element", contextId: "ctx-pinned", role: "AXButton", label: "Gesture Like", bounds: { x: 1, y: 2, width: 3, height: 4 } },
      ],
    }));
    assert.equal(result.state, "completed", result.failureMessage);
    const log = lines.join("\n");
    for (const secret of ["zebra", "quokka", "marmot", "9917", "Ledger fixture", "Gesture Like", "harmless post", "Fixture feed", "8765",
      "shelf-t1", s.captures.dir, "Two posts"]) {
      assert(!log.includes(secret), `the log never carries ${JSON.stringify(secret)}`);
    }
    const line = (stage: string) => lines.find(entry => entry.includes(`stage=${stage} `)) ?? "";
    assert.match(line("invoke.context"), /scope=window source=user pull=allowed general=false followup=false window=true rules=[\d.]+ band=\w+ hint=0\.35 attachments=3 kinds=text\+image\+element images=1 chars=18/);
    assert.match(line("context.label"), /label=window followup=false rules=[\d.]+ hint=0\.35 override=true/);
    assert.match(line("invoke.page"), /ok=true staged=true chars=\d+ refs=\d+ truncated=false/);
    assert.match(line("agent.response"), /createdMs=\d+ firstDelta=text/);
    assert.match(line("invoke.route"), /scope=window/);
    assert.match(line("invoke.total"), /turns=1 scope=window source=user pulled=false included=true attachments=3/);
  } finally { await s.close(); }
});
