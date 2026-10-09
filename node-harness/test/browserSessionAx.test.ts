import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import { createRequire } from "node:module";
import net from "node:net";
import { join, resolve } from "node:path";
import { test } from "node:test";
import tls from "node:tls";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type JsonObject } from "@earendil-works/pi-ai";
import {
  createLiveSession, planTurn, promptFirst, promptFollowup, sessionSetupKey, type AgentRunOptions, type BrowserPageProvider, type FollowupOptions,
} from "../src/agent/agentRunner.js";
import { USE_ACTIVE_WINDOW_TOOL } from "../src/agent/computerUseExtension.js";
import { PAGE_HEADING } from "../src/agent/desktopTools.js";
import { DEFAULT_ROUTING_SETTINGS } from "../src/agent/routing/index.js";
import { canReadPage, PAGE_SECTION_HEADING, readPage, type PageRead } from "../src/browser/axTransport.js";
import type { BrowserPageResult } from "../src/contracts/browser.js";
import type { ContextWire } from "../src/contracts/context.js";
import type { DesktopContextSnapshot, HostClient } from "../src/hostClient.js";
import { agentHost, agentRun, fauxRuntimes, seen, tempCaptures, type HostRoute, type SeenRequest } from "./integrationFixtures.js";

/**
 * Brave over Accessibility inside real agent sessions (r2/DESIGN3 D-T2, DESIGN2 §7 stages A/B):
 * createLiveSession builds an AxTransport for an `ax` hint, so browser_snapshot / browser_act exist
 * beside desktop_act (window scope, or after use_active_window in a general turn), the staged page's
 * refs are adopted so turn 1 acts without another read, background acting follows BrowserHint.background,
 * DevTools stays the explicit `cdp` opt-in, and no DevTools socket is ever opened in ax mode. Real pi 1.0
 * sessions on the in-process faux provider and a fake host serving shared/fixtures/browser-ax; no
 * network, no model, no real Brave.
 */

const FIXTURES = resolve("../shared/fixtures/browser-ax");
const load = (name: string): any => JSON.parse(readFileSync(join(FIXTURES, name), "utf8"));
const PAGE: BrowserPageResult = load("page-response.json").result;
const HINT = { background: load("hint-ax-background.json"), native: load("hint-ax-native.json"), cdp: load("hint-cdp.json") } as const;
const PRESSED = load("axact-response.json");
const BROWSER = ["browser_snapshot", "browser_act"];
const DESKTOP = ["desktop_get_context", "desktop_refresh_context", "desktop_capture_window", "desktop_act"];
const DEVTOOLS_ROUTES = ["browser.connection", "browser.validate", "browser.invalidate"];
const general = (): ContextWire => ({ scope: "general", pull: "allowed", source: "default" });
const windowScope = (): ContextWire => ({ scope: "window", pull: "allowed", source: "user" });

type Part = { type: string; text?: string };
const toolResult = (request: SeenRequest) => {
  const result = request.messages.findLast(message => message.role === "toolResult");
  const parts = (result?.content ?? []) as Part[];
  return { text: parts.filter(part => part.type === "text").map(part => part.text).join("\n"), isError: result?.isError === true };
};
const say = (text: string) => () => fauxAssistantMessage(text);
const call = (name: string, args: JsonObject = {}) => () => fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
const press = (ref: string) => call("browser_act", { action: "press", ref });

type ActReply = unknown | "throw";
interface ScenarioOptions {
  hint: unknown;
  context?: ContextWire;
  prompt?: string;
  readOnly?: boolean;
  page?: BrowserPageResult;
  /** Replies to browser.axAct, in order ("throw": the host connection fails mid-request). */
  acts?: ActReply[];
  /** Overrides the server-like page provider of the first turn. */
  browserPage?: BrowserPageProvider;
}

/**
 * A control-enabled macOS session pinned on Brave with the given hint. The host serves the AX
 * fixtures; the page provider mirrors the server's (one memoized readPage per request, the whole
 * read handed over, only for a readable ax pin).
 */
async function scenario(options: ScenarioOptions) {
  const captures = tempCaptures();
  const base = captures.snapshot();
  const pinned: DesktopContextSnapshot = {
    ...base, browser: options.hint as DesktopContextSnapshot["browser"],
    targetWindow: { ...base.targetWindow!, processName: "Brave Browser", title: "Fixture feed – pi-os QA" },
  };
  const acts = [...(options.acts ?? [])];
  const routes: Record<string, HostRoute> = {
    "browser.page": () => structuredClone({ ok: true, result: options.page ?? PAGE }),
    "browser.axAct": () => {
      const reply = acts.shift();
      if (reply === "throw") throw new Error("socket hang up");
      if (reply === undefined) throw new Error("no browser.axAct reply queued");
      return structuredClone(reply);
    },
  };
  const host = agentHost(captures.dir, pinned, routes);
  const pageProvider = (): BrowserPageProvider | undefined => {
    if (!canReadPage(pinned.browser)) return undefined;
    let pending: Promise<PageRead | null> | undefined;
    return () => pending ??= readPage(host as unknown as HostClient, "ctx-pinned", { timeoutMs: 1_500 }).then(read => read.ok ? read : null);
  };
  const runtimes = fauxRuntimes();
  const provider = options.browserPage ?? pageProvider();
  const run: AgentRunOptions = agentRun(host, runtimes, captures.dir, pinned, {
    prompt: options.prompt ?? "like the first post", readOnly: options.readOnly ?? false,
    ...(options.context ? { context: options.context } : {}), ...(provider ? { browserPage: provider } : {}),
  });
  const live = await createLiveSession(run);
  const requests: SeenRequest[] = [];
  const reply = (answer: (request: SeenRequest) => AssistantMessage) =>
    (context: unknown, _options: unknown, _state: unknown, model: { provider: string; id: string }) => {
      const request = seen(context, model);
      requests.push(request);
      return answer(request);
    };
  const first = async () => {
    const plan = planTurn(live, { text: run.prompt, snapshot: run.snapshot, followup: false, settings: DEFAULT_ROUTING_SETTINGS,
      ...(run.context ? { context: run.context } : {}) });
    return promptFirst(live, { ...run, attachScreenshot: plan.attachScreenshot });
  };
  const followup = async (text: string, extra: FollowupOptions = {}) => {
    planTurn(live, { text, snapshot: pinned, followup: true, settings: DEFAULT_ROUTING_SETTINGS, ...(extra.context ? { context: extra.context } : {}) });
    return promptFollowup(live, text, undefined, undefined, extra);
  };
  return {
    host, runtimes, run, live, requests, reply, first, followup, pinned, pageProvider,
    acted: () => host.calls.filter(c => c.name === "browser.axAct").map(c => c.args),
    reads: () => host.calls.filter(c => c.name === "browser.page").length,
    devtools: () => host.names().filter(name => DEVTOOLS_ROUTES.includes(name)),
    async close() { await live.close(); await captures.close(); },
  };
}

/**
 * Counts and refuses every socket a DevTools connection needs: the `ws` client goes through
 * http.request (then net/tls.connect); a global WebSocket is refused too. Restored by `restore`.
 */
function trapSockets() {
  const opened: string[] = [];
  const saved = {
    httpRequest: http.request, httpsRequest: https.request, netConnect: net.connect, netCreate: net.createConnection,
    tlsConnect: tls.connect, WebSocket: globalThis.WebSocket,
  };
  const refuse = (kind: string) => () => { opened.push(kind); throw new Error(`a socket was opened in an Accessibility test (${kind})`); };
  http.request = refuse("http.request") as never;
  https.request = refuse("https.request") as never;
  net.connect = refuse("net.connect") as never;
  net.createConnection = refuse("net.createConnection") as never;
  tls.connect = refuse("tls.connect") as never;
  globalThis.WebSocket = class { constructor() { opened.push("WebSocket"); throw new Error("a WebSocket was opened in an Accessibility test"); } } as never;
  return {
    opened,
    restore() {
      Object.assign(http, { request: saved.httpRequest });
      Object.assign(https, { request: saved.httpsRequest });
      Object.assign(net, { connect: saved.netConnect, createConnection: saved.netCreate });
      Object.assign(tls, { connect: saved.tlsConnect });
      globalThis.WebSocket = saved.WebSocket;
    },
  };
}

test("window turn: the staged page's refs act through browser.axAct in turn 1, without a second read; a new turn never inherits them", async () => {
  for (const context of [windowScope(), undefined]) {
    const label = context ? "window" : "legacy";
    const s = await scenario({ hint: HINT.background, ...(context ? { context } : {}), acts: [PRESSED] });
    try {
      s.runtimes.respond([s.reply(press("e3")), s.reply(say("Liked the first post."))]);
      const result = await s.first();
      assert.equal(result.responseText, "Liked the first post.");
      const [turn1, turn2] = s.requests;
      assert.equal(s.requests.length, 2, `${label}: act, then answer`);
      assert(turn1!.request.includes(PAGE_SECTION_HEADING), `${label}: the AX digest is staged`);
      assert.match(turn1!.request, /\n\[e3\] button "Like" \(#1 of 2\) pressed=false\n/);
      for (const tool of [...BROWSER, "desktop_act"]) assert(turn1!.tools.includes(tool), `${label}: ${tool} is active in turn 1`);
      assert(!turn1!.tools.includes(USE_ACTIVE_WINDOW_TOOL));
      // The model sees which refs it may use and that page content is data.
      assert.match(turn1!.descriptions.browser_act!, /background/);
      assert.match(turn1!.descriptions.browser_act!, /Guidelines:[\s\S]*Never retry after input_failed/);
      assert.deepEqual(s.acted(), [{ contextId: "ctx-pinned", ref: "e3", action: "press" }], `${label}: exactly one background press`);
      assert.equal(s.reads(), 1, `${label}: the staged read only; no browser_snapshot before acting`);
      const acted = toolResult(turn2!);
      assert.equal(acted.isError, false, acted.text);
      assert.match(acted.text, /^Performed once: press on e3\. Earlier refs are consumed\. Readback \(matched by label and position\): button "Like" \(#1 of 2\) \[e14\] now pressed=true \(was false\)\./);
      assert.deepEqual(s.devtools(), []);
      assert(!s.host.names().some(name => name.startsWith("input.") || name === "window.focus"), `${label}: Brave stays in the background`);

      // A follow-up never inherits refs: the post-action ref from turn 1 is stale and reaches no host.
      s.runtimes.respond([s.reply(press("e15")), s.reply(say("I need to read the page again first."))]);
      await s.followup("and the second one");
      const stale = toolResult(s.requests[3]!);
      assert.equal(stale.isError, true);
      assert.match(stale.text, /^browser_stale: /);
      assert.equal(s.acted().length, 1, `${label}: no second axAct`);
    } finally { await s.close(); }
  }
});

test("general turn: no browser tools until use_active_window; its page's refs then act in the background without another read", async () => {
  const s = await scenario({ hint: HINT.background, context: general(), acts: [PRESSED] });
  try {
    s.runtimes.respond([s.reply(call(USE_ACTIVE_WINDOW_TOOL)), s.reply(press("e3")), s.reply(say("Liked."))]);
    await s.first();
    const [looking, acting, answering] = s.requests;
    assert(!looking!.tools.some(tool => BROWSER.includes(tool) || DESKTOP.includes(tool)), "general: no browser or desktop tools");
    assert(looking!.tools.includes(USE_ACTIVE_WINDOW_TOOL));
    assert(!looking!.request.includes(PAGE_SECTION_HEADING) && !looking!.request.includes(PAGE_HEADING), "general: no page staged");
    assert.equal(s.reads(), 1, "the pull read the page once");
    for (const tool of [...BROWSER, "desktop_act"]) assert(acting!.tools.includes(tool), `${tool} is active after the pull`);
    const pulled = toolResult(acting!).text;
    assert(pulled.includes(PAGE_HEADING), "the extension's fence and untrusted note");
    // The AX transport's own digest is the body: exactly the adopted refs, numbered like browser_act's results.
    assert.match(pulled, /\n\[e3\] button "Like" \(#1 of 2\) pressed=false\n/);
    assert.match(pulled, /\n\| A harmless post used by pi-os QA\.\n/);
    assert.doesNotMatch(pulled, /\nelements:\n/, "no second element list with other refs");
    assert.deepEqual(s.acted(), [{ contextId: "ctx-pinned", ref: "e3", action: "press" }]);
    assert.equal(s.reads(), 1, "no browser_snapshot between the pull and the press");
    assert.equal(toolResult(answering!).isError, false);
    assert.deepEqual(s.devtools(), []);
  } finally { await s.close(); }

  // Without a pull the browser tools never appear in a general turn, and nothing is read.
  const quiet = await scenario({ hint: HINT.background, context: general(), prompt: "what is the capital of France" });
  try {
    quiet.runtimes.respond([quiet.reply(say("Paris."))]);
    await quiet.first();
    assert(!quiet.requests[0]!.tools.some(tool => BROWSER.includes(tool)));
    assert.deepEqual(quiet.host.names(), []);
  } finally { await quiet.close(); }
});

test("a follow-up that brings the window into a general thread stages the page and can act at once", async () => {
  const s = await scenario({ hint: HINT.background, context: general(), prompt: "what is the capital of France", acts: [PRESSED] });
  try {
    s.runtimes.respond([s.reply(say("Paris."))]);
    await s.first();
    assert.equal(s.reads(), 0);
    s.runtimes.respond([s.reply(press("e3")), s.reply(say("Liked."))]);
    await s.followup("like the first post on this page", { context: windowScope(), snapshot: s.pinned, browserPage: s.pageProvider()! });
    const upgrade = s.requests[1]!;
    assert.match(upgrade.request, /^## Follow-up: the user included the active window/);
    assert(upgrade.request.includes(PAGE_SECTION_HEADING));
    assert(upgrade.tools.includes("browser_act"));
    assert.deepEqual(s.acted(), [{ contextId: "ctx-pinned", ref: "e3", action: "press" }]);
    assert.equal(s.reads(), 1);
    assert.equal(toolResult(s.requests[2]!).isError, false);
  } finally { await s.close(); }
});

test("background acting off (or read-only): no browser_act; browser_snapshot re-reads and points to desktop_act", async () => {
  const native = await scenario({ hint: HINT.native, context: windowScope() });
  try {
    native.runtimes.respond([native.reply(say("Use the Like button."))]);
    await native.first();
    const request = native.requests[0]!;
    assert(request.tools.includes("browser_snapshot") && request.tools.includes("desktop_act"));
    assert(!request.tools.includes("browser_act"), "nothing that could act in the background");
    assert.match(request.descriptions.browser_snapshot!, /To act on the Brave page, use desktop_act on the pinned window/);
    assert(request.request.includes(PAGE_SECTION_HEADING), "the page is still staged for reading");
    assert.deepEqual(native.acted(), []);
  } finally { await native.close(); }

  const readOnly = await scenario({ hint: HINT.background, context: windowScope(), readOnly: true });
  try {
    readOnly.runtimes.respond([readOnly.reply(say("Here is the page."))]);
    await readOnly.first();
    const request = readOnly.requests[0]!;
    assert(request.tools.includes("browser_snapshot"));
    assert(!request.tools.includes("browser_act") && !request.tools.includes("desktop_act"), "read-only: observation only");
    assert.doesNotMatch(request.descriptions.browser_snapshot!, /use desktop_act/);
  } finally { await readOnly.close(); }
});

test("DevTools mode is unchanged: its tools replace desktop_act, no AX route is used, general turns hide them", async () => {
  for (const context of [windowScope(), general()]) {
    const s = await scenario({ hint: HINT.cdp, context });
    try {
      s.runtimes.respond([s.reply(say("ok"))]);
      await s.first();
      const request = s.requests[0]!;
      if (context.scope === "window") {
        assert(BROWSER.every(tool => request.tools.includes(tool)) && !request.tools.includes("desktop_act"));
        assert.match(request.descriptions.browser_act!, /In Brave DevTools mode browser_act replaces native input/);
      } else {
        assert(!request.tools.some(tool => BROWSER.includes(tool) || DESKTOP.includes(tool)));
      }
      assert(!request.request.includes(PAGE_SECTION_HEADING) && !request.request.includes(PAGE_HEADING), "no AX page for a DevTools pin");
      // No tool ran, so nothing connected: the CDP connection still starts only on first use.
      assert.deepEqual(s.host.names(), []);
    } finally { await s.close(); }
  }
});

test("no DevTools code path in ax mode: no WebSocket or other socket, no DevTools host route", async () => {
  const trap = trapSockets();
  try {
    // Positive control: the trap catches the `ws` client a DevTools connection would use.
    const Socket = createRequire(import.meta.url)("ws") as new (url: string) => unknown;
    assert.throws(() => new Socket("ws://127.0.0.1:9/devtools/page/fixture"));
    assert.deepEqual(trap.opened, ["http.request"]);
    trap.opened.length = 0;

    const window = await scenario({ hint: HINT.background, context: windowScope(), acts: [PRESSED] });
    try {
      window.runtimes.respond([window.reply(press("e3")), window.reply(call("browser_snapshot")), window.reply(say("Liked."))]);
      await window.first();
      assert.deepEqual(window.host.names().filter(name => name.startsWith("browser.")), ["browser.page", "browser.axAct", "browser.page"]);
      assert.deepEqual(window.devtools(), []);
    } finally { await window.close(); }

    const pulled = await scenario({ hint: HINT.background, context: general(), acts: [PRESSED] });
    try {
      pulled.runtimes.respond([pulled.reply(call(USE_ACTIVE_WINDOW_TOOL)), pulled.reply(press("e3")), pulled.reply(say("Liked."))]);
      await pulled.first();
      assert.deepEqual(pulled.devtools(), []);
      assert.equal(pulled.acted().length, 1);
    } finally { await pulled.close(); }
    assert.deepEqual(trap.opened, [], "no socket of any kind");
  } finally { trap.restore(); }
});

test("prepared sessions are keyed by the hint's mode, pinned tab and background acting", () => {
  const captures = tempCaptures();
  try {
    const keys = [HINT.background, HINT.native, HINT.cdp, { ...HINT.background, pinned: false }, undefined].map(hint => {
      const pinned = { ...captures.snapshot(), ...(hint ? { browser: hint } : {}) } as DesktopContextSnapshot;
      return sessionSetupKey({ ...agentRun(agentHost(captures.dir, pinned), fauxRuntimes(), captures.dir, pinned), readOnly: false });
    });
    assert.equal(new Set(keys).size, keys.length, "each variant builds its own session");
    // Background acting is decided at build time: a session with browser_act is never reused when it is off.
    assert.notEqual(keys[0], keys[1]);
  } finally { void captures.close(); }
});

test("safety checks stay in force: deletion labels, uncertain outcomes, credential refusals; unshown, natively consumed, expired and foreign refs", async () => {
  // A recognized file-deletion control is refused before the host, and acting stops for the task.
  const trash = await scenario({ hint: HINT.background, context: windowScope(),
    page: { ...PAGE, controls: [...PAGE.controls, { label: "Move to Trash", role: "button", ref: "e30" }] } });
  try {
    trash.runtimes.respond([trash.reply(press("e30")), trash.reply(press("e3")), trash.reply(say("I can't do that."))]);
    await trash.first();
    assert.match(toolResult(trash.requests[1]!).text, /^file_deletion_blocked: /);
    assert.match(toolResult(trash.requests[2]!).text, /^input_failed: A prior browser action/);
    assert.deepEqual(trash.acted(), [], "nothing reached the host");
  } finally { await trash.close(); }

  // An uncertain outcome is never retried, and later actions are refused locally.
  const uncertain = await scenario({ hint: HINT.background, context: windowScope(), acts: ["throw"] });
  try {
    uncertain.runtimes.respond([uncertain.reply(press("e3")), uncertain.reply(press("e4")), uncertain.reply(say("Stopped."))]);
    await uncertain.first();
    assert.match(toolResult(uncertain.requests[1]!).text, /^input_failed: The outcome is uncertain/);
    assert.match(toolResult(uncertain.requests[2]!).text, /^input_failed: A prior browser action/);
    assert.equal(uncertain.acted().length, 1);
  } finally { await uncertain.close(); }

  // A clearly identified credential field: the host's refusal reaches the model with the Settings hint (dummy value only).
  const credential = await scenario({ hint: HINT.background, context: windowScope(), acts: [load("axact-response-credential.json")] });
  try {
    credential.runtimes.respond([credential.reply(call("browser_act", { action: "setValue", ref: "e10", value: "dummy-fixture-value" })),
      credential.reply(say("That field is blocked."))]);
    await credential.first();
    const refused = toolResult(credential.requests[1]!);
    assert.match(refused.text, /^credential_input_blocked: [\s\S]*pi-os Settings/);
    assert.doesNotMatch(refused.text, /dummy-fixture-value/);
    assert.deepEqual(credential.acted(), [{ contextId: "ctx-pinned", ref: "e10", action: "setValue", value: "dummy-fixture-value" }]);
  } finally { await credential.close(); }

  // Only refs printed in the staged digest are actionable: one cut at the budget is stale and never sent.
  const many = Array.from({ length: 250 }, (_, i) => ({ label: `Item ${i + 1} ${"x".repeat(100)}`, role: "button" as const, ref: `e${i + 1}` }));
  const long = await scenario({ hint: HINT.background, context: windowScope(), page: { ...PAGE, controls: many, fields: [], links: [] } });
  try {
    long.runtimes.respond([long.reply(press("e250")), long.reply(say("I need to read more of the page."))]);
    await long.first();
    assert(!long.requests[0]!.request.includes("[e250]"), "the fixture's last element is past the staged budget");
    assert.match(long.requests[0]!.request, /\n\[e1\] button "Item 1 x+"\n/);
    assert.match(toolResult(long.requests[1]!).text, /^browser_stale: /);
    assert.deepEqual(long.acted(), []);
  } finally { await long.close(); }

  // Native input may change the page in place (a relabelled toggle keeps its element): desktop_act consumes the refs.
  const native = await scenario({ hint: HINT.background, context: windowScope(), acts: [PRESSED] });
  try {
    native.runtimes.respond([native.reply(call("desktop_act", { action: "click", x: 5, y: 5 })), native.reply(press("e3")),
      native.reply(say("I need to read the page again."))]);
    await native.first();
    assert.equal(toolResult(native.requests[1]!).isError, false, "the native click went through");
    assert(native.host.names().includes("input.click"));
    assert.match(toolResult(native.requests[2]!).text, /^browser_stale: /);
    assert.deepEqual(native.acted(), []);
  } finally { await native.close(); }

  // Refs age from the host's read (the server hands over the whole read): past the 60 s lifetime they are stale.
  const old = await scenario({ hint: HINT.background, context: windowScope(), browserPage: async () => {
    const read = await readPage({ invokeTool: async () => ({ ok: true, result: PAGE }) } as unknown as HostClient, "ctx-pinned");
    return read.ok ? { ...read, readAt: read.readAt - 61_000 } : null;
  } });
  try {
    old.runtimes.respond([old.reply(press("e3")), old.reply(say("I need to read the page again."))]);
    await old.first();
    assert(old.requests[0]!.request.includes(PAGE_SECTION_HEADING));
    assert.match(toolResult(old.requests[1]!).text, /^browser_stale: /);
    assert.deepEqual(old.acted(), []);
  } finally { await old.close(); }

  // A read of another context is neither shown nor adopted.
  const other = await scenario({ hint: HINT.background, context: windowScope(),
    browserPage: () => readPage({ invokeTool: async () => ({ ok: true, result: PAGE }) } as unknown as HostClient, "ctx-other") });
  try {
    other.runtimes.respond([other.reply(press("e3")), other.reply(say("I need to read the page."))]);
    await other.first();
    assert(!other.requests[0]!.request.includes(PAGE_SECTION_HEADING));
    assert.match(toolResult(other.requests[1]!).text, /^browser_stale: /);
    assert.deepEqual(other.acted(), []);
  } finally { await other.close(); }
});
