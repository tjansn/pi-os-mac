import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { contextScope } from "../src/agent/routing/contextScope.js";
import { bindingToHostAction, type CardSpec } from "../src/contracts/cards.js";
import { NO_CONTEXT_SCORER, type ContextScorer, type InstantScope } from "../src/contracts/context.js";
import type { ClassifierHints, InstantPhase, InstantRequest, InstantResponse, IntentClassifier } from "../src/contracts/instant.js";
import type { AppRecord, FileSearchResult } from "../src/contracts/launcher.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { createInstantDispatcher, type InstantDispatcherDeps } from "../src/instant/dispatcher.js";
import { createFendLoader } from "../src/instant/engines.js";
import { EcbRateStore, type FxSnapshot } from "../src/instant/engines/fx.js";

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = <T>(path: string): T => JSON.parse(readFileSync(join(fixtures, path), "utf8")) as T;
const NOW = new Date(2026, 9, 2, 19, 30);
const fend = createFendLoader();

const app = (bundleId: string, name: string): AppRecord => ({ bundleId, name, aliases: [], path: `/Applications/${name}.app`, running: false });
const APPS = [app("com.figma.Desktop", "Figma"), app("com.figma.FigJam", "FigJam"), app("com.spotify.client", "Spotify")];
const appsCache = () => new AppIndexCache(async () => ({ version: "1", apps: APPS }));
const searchResponse = readJson<{ result: FileSearchResult }>("launcher/search-files-response.json").result;

function make(overrides: Partial<InstantDispatcherDeps> = {}) {
  return createInstantDispatcher({
    fend,
    now: () => NOW,
    localZone: () => "Europe/Berlin",
    apps: appsCache(),
    searchFiles: async () => searchResponse,
    homeDir: "/Users/fixture",
    ...overrides,
  });
}

const request = (text: string, phase: InstantPhase = "final", extra: Partial<InstantRequest> = {}): InstantRequest => ({ text, phase, seq: 1, ...extra });
/** The response without its timing and its advisory scope (asserted on its own below). */
const withoutTiming = (response: InstantResponse): Omit<InstantResponse, "elapsedMs" | "scope"> => {
  const { elapsedMs, scope: _scope, ...rest } = response;
  assert.equal(typeof elapsedMs, "number");
  return rest;
};

function stubClassifier(result: ClassifierHints | null | "hang" | "throw") {
  const calls: string[] = [];
  const classifier: IntentClassifier = {
    name: "stub",
    classify: async (text) => {
      calls.push(text);
      if (result === "hang") return new Promise(() => {});
      if (result === "throw") throw new Error("boom");
      return result;
    },
  };
  return { classifier, calls };
}

test("golden: responses reproduce the shared instant fixtures", async () => {
  const dispatcher = make();
  const golden = async (file: string, req: InstantRequest) => {
    const expected = readJson<InstantResponse>(`instant/${file}`);
    const { elapsedMs: _ignored, ...rest } = expected;
    const response = await dispatcher.dispatch(req);
    assert.deepEqual(withoutTiming(response), rest, file);
    // The shared fixtures predate `scope`; the dispatcher adds the rules v2 score of the text.
    assert.deepEqual(response.scope, contextScope(req.text), file);
  };
  await golden("answer-calc.json", { text: "15% of 340", phase: "final", seq: 7 });
  await golden("act-web-search.json", { text: "search the web for best espresso grinder", phase: "final", seq: 9 });
  await golden("act-volume.json", { text: "set volume to 30%", phase: "final", seq: 2 });
  await golden("refuse-delete.json", { text: "empty the trash", phase: "final", seq: 5 });
  await golden("fallthrough-no-match.json", { text: "what's the capital of france", phase: "final", seq: 1 });

  // Currency golden: cached snapshot from 2026-10-01 viewed on Sunday 2026-10-04 (aging, no refresh due).
  const dir = mkdtempSync(join(tmpdir(), "pi-os-instant-fx-"));
  const snapshot: FxSnapshot = { source: "ecb-eurofxref-daily", base: "EUR", asOf: "2026-10-01", fetchedAt: "2026-10-04T11:00:00.000Z", rates: { EUR: 1, USD: 1.1637 } };
  writeFileSync(join(dir, "fx.json"), JSON.stringify(snapshot));
  const fx = new EcbRateStore({ file: join(dir, "fx.json"), now: () => new Date("2026-10-04T12:00:00Z"), fetch: (async () => { throw new Error("no fetch expected"); }) as typeof fetch });
  const currencyDispatcher = make({ fx });
  const expected = readJson<InstantResponse>("instant/answer-currency.json");
  const { elapsedMs: _e, ...rest } = expected;
  const currencyResponse = await currencyDispatcher.dispatch({ text: "100 usd in eur", phase: "final", seq: 3 });
  assert.deepEqual(withoutTiming(currencyResponse), rest);
  assert.deepEqual(currencyResponse.scope, contextScope("100 usd in eur"));
});

test("scope: every phase and decision carries the rules v2 score of the text", async () => {
  const dispatcher = make({ budgets: { typingFileQuietMs: 0 } });
  const cases: [string, InstantResponse["decision"][]][] = [
    ["15% of 340", ["answer"]], ["find invoice", ["list"]], ["open figma", ["list", "act"]], ["empty the trash", ["refuse"]],
    ["summarize this page", ["fallthrough"]], ["what's the capital of france", ["fallthrough"]], ["gib mir ein Rezept für Pfannkuchen", ["fallthrough"]],
  ];
  for (const [text, decisions] of cases) {
    for (const phase of ["typing", "partial", "final"] as const) {
      const response = await dispatcher.dispatch(request(text, phase));
      assert.ok(decisions.includes(response.decision), `${text} (${phase}) ${response.decision}`);
      assert.deepEqual(response.scope, contextScope(text), `${text} (${phase})`);
    }
  }
  assert.equal((await dispatcher.dispatch(request("summarize this page", "partial"))).scope?.window, 0.9);
  assert.equal((await dispatcher.dispatch(request("what's the capital of france", "typing"))).scope?.window, 0.1);
  // The kill switch turns off the instant lane, not the chip's suggestions.
  const off = await make({ enabled: () => false }).dispatch(request("summarize this page", "typing"));
  assert.deepEqual([off.decision === "fallthrough" && off.reason, off.scope], ["disabled", contextScope("summarize this page")]);
  // Timeouts and aborts still carry it: the score is computed before any engine work.
  const controller = new AbortController();
  const pending = make({ searchFiles: () => new Promise(() => {}) }).dispatch(request("find my resume"), controller.signal);
  controller.abort();
  const aborted = await pending;
  assert.deepEqual([aborted.decision === "fallthrough" && aborted.reason, aborted.scope], ["timeout", contextScope("find my resume")]);
});

test("scope: the injected scorer decides; off, failing or off-contract scorers leave the field out and change nothing else", async () => {
  const seen: string[] = [];
  const fixed: ContextScorer = (text) => { seen.push(text); return { window: 0.42, reasons: ["fixture-code"] }; };
  const custom = await make({ scorer: fixed }).dispatch(request("  Summarize THIS page  ", "typing"));
  assert.deepEqual(custom.scope, { window: 0.42, reasons: ["fixture-code"] });
  assert.deepEqual(seen, ["  Summarize THIS page  "], "the raw text, once per dispatch");
  await make({ scorer: fixed }).dispatch(request("x".repeat(600)));
  assert.equal(seen.at(-1)!.length, 600, "over-long text is still scored (it falls through to the agent)");

  const baseline = withoutTiming(await make().dispatch(request("what's the capital of france")));
  const broken: ContextScorer[] = [
    NO_CONTEXT_SCORER,
    () => { throw new Error("scorer"); },
    () => ({ window: 2, reasons: [] }),
    () => ({ window: 0.5, reasons: ["Not A Code"] }),
    () => ({ window: 0.5, reasons: Array.from({ length: 9 }, () => "x") }),
    () => "window" as unknown as InstantScope,
  ];
  for (const scorer of broken) {
    const response = await make({ scorer }).dispatch(request("what's the capital of france"));
    assert.ok(!("scope" in response), String(scorer));
    assert.deepEqual(withoutTiming(response), baseline);
  }
  // Unreadable requests carry no scope (there is no text to score).
  const dispatcher = make();
  for (const bad of [{ text: 42, phase: "final", seq: 1 }, null, { text: "", phase: "typing", seq: 2 }, { text: "   ", phase: "typing", seq: 3 }]) {
    assert.ok(!("scope" in await dispatcher.dispatch(bad as unknown as InstantRequest)), JSON.stringify(bad));
  }
  // A returned scope is a copy: a scorer mutating its own result later cannot change a sent response.
  const shared: InstantScope = { window: 0.3, reasons: ["pronoun"] };
  const copied = await make({ scorer: () => shared }).dispatch(request("make it shorter"));
  shared.reasons.push("ui-verb");
  assert.deepEqual(copied.scope, { window: 0.3, reasons: ["pronoun"] });
});

test("golden shapes: app act and file list match the fixture structure", async () => {
  const dispatcher = make();
  const act = await dispatcher.dispatch(request("open figma"));
  const fixture = readJson<InstantResponse & { decision: "act" }>("instant/act-open-app.json");
  assert.equal(act.decision, "act");
  if (act.decision !== "act") return;
  assert.deepEqual({ intent: act.intent, title: act.title, action: act.action, confirm: act.confirm }, { intent: fixture.intent, title: fixture.title, action: fixture.action, confirm: fixture.confirm });
  assert.deepEqual(act.card?.elements.root, fixture.card!.elements.root);
  assert.deepEqual(act.card?.elements.n2, fixture.card!.elements.n2);

  const list = await dispatcher.dispatch(request("find invoice"));
  assert.equal(list.decision, "list");
  if (list.decision !== "list") return;
  assert.equal(list.title, "3 files match “invoice”");
  const root = list.card.elements.root!;
  assert.equal(root.props.summary, "3 files match “invoice”");
  const itemList = list.card.elements[root.children![0]!]!;
  assert.deepEqual(itemList.props, { title: "Files matching “invoice”", total: 3 });
  const first = list.card.elements[itemList.children![0]!]!;
  assert.equal(first.type, "Item");
  assert.equal(first.props.subtitle, "~/Documents/Finance");
  assert.deepEqual(first.props.icon, { kind: "file", uti: "com.adobe.pdf" });
  assert.deepEqual(Object.keys(first.on ?? {}).sort(), ["primary", "secondary", "tertiary"]);
  const token = (first.on!.primary!.params.token as string);
  assert.deepEqual(first.on, {
    primary: { action: "openFile", params: { token } },
    secondary: { action: "revealFile", params: { token } },
    tertiary: { action: "copyPath", params: { token } },
  });
  assert.ok(searchResponse.items.some((item) => item.token === token), "only host-minted tokens");
});

test("act only on final: typing/partial get previews and never side effects", async () => {
  const dispatcher = make();
  const commands = ["open figma", "set volume to 30%", "mute", "sleep display", "github dot com", "google best pizza", "search the web for ramen"];
  for (const text of commands) {
    for (const phase of ["typing", "partial"] as const) {
      const response = await dispatcher.dispatch(request(text, phase));
      assert.notEqual(response.decision, "act", `${text} (${phase})`);
      assert.ok(response.decision === "answer" || response.decision === "list", `${text} (${phase}) previews`);
      assert.ok(!("action" in response), `${text} (${phase}) carries no action`);
    }
    assert.equal((await dispatcher.dispatch(request(text, "final"))).decision, "act", `${text} final`);
  }
  const preview = await dispatcher.dispatch(request("open figma", "typing"));
  assert.equal(preview.decision, "list");
  const url = await dispatcher.dispatch(request("github.com", "partial"));
  assert.deepEqual(url.decision === "answer" && { intent: url.intent, title: url.title }, { intent: "url", title: "Open github.com" });
  // Ambiguous apps list even on final.
  const ambiguous = await dispatcher.dispatch(request("open fig"));
  assert.equal(ambiguous.decision, "list");
});

test("deletion phrases are refused in every phase and never reach the classifier", async () => {
  const { classifier, calls } = stubClassifier({ source: "laya", latencyMs: 1, intent: "act_in_app", intentP: 0.99 });
  const dispatcher = make({ classifier });
  for (const phase of ["typing", "partial", "final"] as const) {
    for (const text of ["empty trash", "Papierkorb leeren", "delete this file", "lösche alle Downloads"]) {
      const response = await dispatcher.dispatch(request(text, phase));
      assert.equal(response.decision, "refuse", `${text} (${phase})`);
      if (response.decision === "refuse") assert.equal(response.card.elements.n1?.props.tone, "error");
    }
  }
  assert.deepEqual(calls, []);
});

test("trash questions and web searches are never refused, in any phase", async () => {
  const dispatcher = make();
  for (const phase of ["typing", "partial", "final"] as const) {
    for (const text of ["how do I empty the trash", "google how to empty the trash", "delete the comma", "lösch das"]) {
      const response = await dispatcher.dispatch(request(text, phase));
      assert.notEqual(response.decision, "refuse", `${text} (${phase})`);
    }
  }
});

test("classifier: only on grammar miss, only partial/final, only hints, never an action", async () => {
  const hints: ClassifierHints = { source: "laya", latencyMs: 12, intent: "open_launch", intentP: 0.95, complete: 0.97 };
  const { classifier, calls } = stubClassifier(hints);
  const dispatcher = make({ classifier });
  const miss = await dispatcher.dispatch(request("could you bring figma up", "final"));
  assert.deepEqual(withoutTiming(miss), { seq: 1, source: "grammar", decision: "fallthrough", reason: "no_match", hints });
  assert.equal((await dispatcher.dispatch(request("could you bring figma up", "partial"))).decision, "fallthrough");
  assert.equal(calls.length, 2);
  await dispatcher.dispatch(request("could you bring figma up", "typing"));
  await dispatcher.dispatch(request("2+2", "final"));
  await dispatcher.dispatch(request("open figma", "final"));
  assert.equal(calls.length, 2, "not on typing, not on grammar hits");
  const deictic = await dispatcher.dispatch(request("summarize this page", "final"));
  assert.deepEqual(deictic.decision === "fallthrough" && deictic.hints, hints);
});

test("a remote classifier (local: false) sees finals only: partials never leave the machine", async () => {
  const hints: ClassifierHints = { source: "pi-classifier", latencyMs: 300, intent: "open_launch", intentP: 0.9 };
  const { classifier, calls } = stubClassifier(hints);
  const dispatcher = make({ classifier: { ...classifier, local: false } });
  for (const phase of ["typing", "partial"] as const) {
    const response = await dispatcher.dispatch(request("could you bring figma up", phase));
    assert.deepEqual(response.decision === "fallthrough" && response.hints, undefined, phase);
  }
  // Deixis keeps its local heuristic hint without asking the remote classifier.
  const deictic = await dispatcher.dispatch(request("summarize this page", "partial"));
  assert.deepEqual(deictic.decision === "fallthrough" && deictic.hints, { source: "heuristic", latencyMs: 0, needsScreen: 0.9 });
  assert.deepEqual(calls, []);
  const final = await dispatcher.dispatch(request("could you bring figma up", "final"));
  assert.deepEqual(final.decision === "fallthrough" && final.hints, hints);
  assert.equal(calls.length, 1);
});

test("with onLateHints a final never waits on the classifier; late hints arrive via the callback", async () => {
  const hints: ClassifierHints = { source: "laya", latencyMs: 120, needsScreen: 0.8 };
  const slow: IntentClassifier = { name: "slow", classify: () => new Promise((resolve) => setTimeout(() => resolve(hints), 120)) };
  const late: { request: InstantRequest; hints: ClassifierHints }[] = [];
  const dispatcher = make({ classifier: slow, budgets: { classifierMs: 250 }, onLateHints: (request, value) => late.push({ request, hints: value }) });
  const started = performance.now();
  const final = await dispatcher.dispatch(request("could you bring figma up", "final", { takeId: "take-1" }));
  assert.ok(performance.now() - started < 60, "the final answered without waiting");
  assert.deepEqual(withoutTiming(final), { seq: 1, source: "grammar", decision: "fallthrough", reason: "no_match" });
  // Deixis still carries its immediate heuristic hint.
  const deictic = await dispatcher.dispatch(request("summarize this page", "final", { takeId: "take-2" }));
  assert.deepEqual(deictic.decision === "fallthrough" && deictic.hints, { source: "heuristic", latencyMs: 0, needsScreen: 0.9 });
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.deepEqual(late.map((entry) => [entry.request.takeId, entry.hints]), [["take-1", hints], ["take-2", hints]]);
  // Partials still wait (they run during speech, off the critical path) and never use the callback.
  const partial = await dispatcher.dispatch(request("could you bring figma up", "partial", { takeId: "take-3" }));
  assert.deepEqual(partial.decision === "fallthrough" && partial.hints, hints);
  assert.equal(late.length, 2);
  // A hanging classifier never calls back and leaves nothing pending past its deadline.
  const hang = stubClassifier("hang");
  const quiet: unknown[] = [];
  const hanging = make({ classifier: hang.classifier, budgets: { classifierMs: 30 }, onLateHints: (...args) => quiet.push(args) });
  await hanging.dispatch(request("could you bring figma up", "final", { takeId: "take-4" }));
  await new Promise((resolve) => setTimeout(resolve, 80));
  assert.deepEqual(quiet, []);
});

test("classifier failures and hangs degrade to heuristic hints within the deadline", async () => {
  const hang = stubClassifier("hang");
  const dispatcher = make({ classifier: hang.classifier, budgets: { classifierMs: 40 } });
  const started = performance.now();
  const response = await dispatcher.dispatch(request("summarize this page", "final"));
  assert.ok(performance.now() - started < 400);
  assert.deepEqual(response.decision === "fallthrough" && response.hints, { source: "heuristic", latencyMs: 0, needsScreen: 0.9 });
  const thrower = make({ classifier: stubClassifier("throw").classifier });
  const plain = await thrower.dispatch(request("what's the meaning of life", "final"));
  assert.deepEqual(withoutTiming(plain), { seq: 1, source: "grammar", decision: "fallthrough", reason: "no_match" });
});

test("budgets: a hanging host or engine falls through with timeout", async () => {
  const hangingFiles = make({ searchFiles: () => new Promise(() => {}), budgets: { fileSearchFinalMs: 80 } });
  let started = performance.now();
  const files = await hangingFiles.dispatch(request("find my resume"));
  assert.deepEqual(files.decision === "fallthrough" && files.reason, "timeout");
  assert.ok(performance.now() - started < 400);

  const hangingApps = make({ apps: new AppIndexCache(() => new Promise(() => {})), budgets: { defaultMs: 30 } });
  assert.equal((await hangingApps.dispatch(request("open figma"))).decision, "fallthrough");

  const hangingFend = make({ fend: { get: () => new Promise(() => {}), peek: () => null }, budgets: { defaultMs: 30 } });
  started = performance.now();
  const calc = await hangingFend.dispatch(request("2+2"));
  assert.deepEqual(calc.decision === "fallthrough" && calc.reason, "timeout");
  assert.ok(performance.now() - started < 300);

  const controller = new AbortController();
  const pending = make({ searchFiles: () => new Promise(() => {}) }).dispatch(request("find my resume"), controller.signal);
  controller.abort();
  assert.deepEqual(await pending.then((r) => r.decision === "fallthrough" && r.reason), "timeout");

  // An engine failure is a miss, not a timeout.
  const brokenFend = make({ fend: { get: () => Promise.reject(new Error("no wasm")), peek: () => null } });
  assert.deepEqual(await brokenFend.dispatch(request("2+2")).then((r) => r.decision === "fallthrough" && r.reason), "no_match");
});

test("file-search budgets depend on the phase: a final waits past the host's own 1.5 s deadline, previews stay short", async () => {
  const slow = (ms: number) => async () => { await new Promise((resolve) => setTimeout(resolve, ms)); return searchResponse; };
  // Defaults: 400 ms (a few-hit search with the host's substring fallback) still lists on a final.
  const final = await make({ searchFiles: slow(400) }).dispatch(request("find invoice pdfs"));
  assert.equal(final.decision, "list");
  // Previews keep a short budget; the stale preview is superseded anyway.
  const preview = make({ searchFiles: slow(400), budgets: { fileSearchPreviewMs: 250, typingFileQuietMs: 0 } });
  for (const phase of ["typing", "partial"] as const) {
    const response = await preview.dispatch(request("find invoice pdfs", phase));
    assert.deepEqual(response.decision === "fallthrough" && response.reason, "timeout", phase);
  }
  // The deprecated fileSearchMs alias still sets the preview budget only.
  const alias = make({ searchFiles: slow(150), budgets: { fileSearchMs: 50, typingFileQuietMs: 0 } });
  assert.deepEqual(await alias.dispatch(request("find invoice pdfs", "partial")).then((r) => r.decision === "fallthrough" && r.reason), "timeout");
  assert.equal((await alias.dispatch(request("find invoice pdfs"))).decision, "list");
});

test("typing: a file search waits for quiet (each keystroke supersedes it); other intents answer at once; partial/final never wait", async () => {
  const calls: string[] = [];
  const dispatcher = make({
    searchFiles: async (req) => { calls.push(req.nameGroups.flat().join(" ")); return searchResponse; },
    budgets: { typingFileQuietMs: 150 },
  });
  // Three keystrokes 20 ms apart: the caller (server latest-wins) aborts the previous request each time.
  const results: Promise<InstantResponse>[] = [];
  let controller: AbortController | undefined;
  for (const text of ["find invoice", "find invoice pd", "find invoice pdfs"]) {
    controller?.abort();
    controller = new AbortController();
    results.push(dispatcher.dispatch(request(text, "typing"), controller.signal));
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const lastSent = performance.now() - 20;
  const settled = await Promise.all(results);
  assert.deepEqual(settled.slice(0, 2).map((r) => r.decision === "fallthrough" && r.reason), ["timeout", "timeout"]);
  assert.equal(settled[2]!.decision, "list");
  assert.ok(performance.now() - lastSent >= 140, "the surviving request waited for quiet");
  assert.equal(calls.length, 1, "only the settled query reaches the host");
  assert.match(calls[0]!, /invoice/);

  let started = performance.now();
  const calc = await dispatcher.dispatch(request("15% of 340", "typing"));
  assert.equal(calc.decision, "answer");
  assert.ok(performance.now() - started < 100, "calculations preview on every keystroke");
  for (const phase of ["partial", "final"] as const) {
    started = performance.now();
    await dispatcher.dispatch(request("find invoice pdfs", phase));
    assert.ok(performance.now() - started < 120, `${phase} is not delayed`);
  }
});

test("one decimal convention per card: input, value and copy follow the format locale", async () => {
  const dispatcher = make();
  const copyOf = (response: InstantResponse): unknown => (response.decision === "answer" ? response.card.elements.n1?.on?.copy?.params.text : undefined);
  const inputOf = (response: InstantResponse): unknown => (response.decision === "answer" ? response.card.elements.n1?.props.input : undefined);
  for (const [text, locale] of [["15% von 1234,5", "de-DE"], ["15% of 1234,5", "en-DE"]] as const) {
    const response = await dispatcher.dispatch(request(text, "final", { locale }));
    assert.equal(response.decision, "answer", `${text} ${locale}`);
    assert.equal(inputOf(response), "15% of 1234,5", locale);
    assert.equal(response.decision === "answer" && response.title, "185,175", locale);
    assert.equal(copyOf(response), "185,175", locale);
  }
  const us = await dispatcher.dispatch(request("15% of 1234.5", "final", { locale: "en-US" }));
  assert.deepEqual([inputOf(us), us.decision === "answer" && us.title, copyOf(us)], ["15% of 1234.5", "185.175", "185.175"]);
  // en-DE (an en-US Mac with region Germany) parses German separators.
  assert.equal(copyOf(await dispatcher.dispatch(request("2,5 * 4", "final", { locale: "en-DE" }))), "10");
  assert.equal(copyOf(await dispatcher.dispatch(request("1.000 + 1", "final", { locale: "en-DE" }))), "1001");
  assert.equal(copyOf(await dispatcher.dispatch(request("1,250 * 4", "final", { locale: "en-US" }))), "5000");
  assert.equal((await dispatcher.dispatch(request("2,5 * 4", "final", { locale: "en-US" }))).decision, "fallthrough");
  // Units: the copied number uses the display convention too.
  const km = await dispatcher.dispatch(request("2,5 km in miles", "final", { locale: "de-DE" }));
  assert.equal(inputOf(km), "2,5 km in miles");
  assert.match(String(copyOf(km)), /^1,55/);
  // Base conversions keep programmer literals.
  const hex = await dispatcher.dispatch(request("0xff in decimal", "final", { locale: "de-DE" }));
  assert.deepEqual([hex.decision === "answer" && hex.title, copyOf(hex)], ["255", "255"]);
});

test("budget timers are cleared once a dispatch settles", async () => {
  const timeouts = (): number => process.getActiveResourcesInfo().filter((kind) => kind === "Timeout").length;
  const { classifier } = stubClassifier(null);
  const dispatcher = make({ classifier, budgets: { defaultMs: 60_000, fileSearchMs: 60_000, classifierMs: 60_000 } });
  await dispatcher.warm();
  const before = timeouts();
  for (const text of ["2+2", "find invoice", "open figma", "what's the meaning of life"]) await dispatcher.dispatch(request(text));
  assert.equal(timeouts(), before, "no 60 s budget timer outlives its dispatch");
});

test("never throws: invalid requests, disabled lane and throwing dependencies", async () => {
  const dispatcher = make({ searchFiles: async () => { throw new Error("host"); }, apps: new AppIndexCache(async () => { throw new Error("host"); }) });
  const bad = [
    { text: 42, phase: "final", seq: 3 },
    { text: "2+2", phase: "later", seq: 4 },
    { text: "x".repeat(501), phase: "final", seq: 5 },
    null,
  ] as unknown as InstantRequest[];
  for (const req of bad) {
    const response = await dispatcher.dispatch(req);
    assert.equal(response.decision, "fallthrough");
  }
  assert.equal((await dispatcher.dispatch({ text: "2+2", phase: "later", seq: 4 } as unknown as InstantRequest)).seq, 4);
  assert.deepEqual((await dispatcher.dispatch(request("find my resume"))).decision, "fallthrough");
  assert.deepEqual((await dispatcher.dispatch(request("open figma"))).decision, "fallthrough");
  const off = make({ enabled: () => false });
  assert.deepEqual(withoutTiming(await off.dispatch(request("2+2"))), { seq: 1, source: "grammar", decision: "fallthrough", reason: "disabled" });
  const noDeps = createInstantDispatcher({ fend, now: () => NOW });
  assert.equal((await noDeps.dispatch(request("find my resume"))).decision, "fallthrough");
  assert.equal((await noDeps.dispatch(request("open figma"))).decision, "fallthrough");
  const currency = await noDeps.dispatch(request("100 usd in eur", "typing"));
  assert.deepEqual(currency.decision === "answer" && currency.title, "Currency rates are not available.");
  // A notice is a preview only: the final goes to the agent.
  assert.deepEqual(withoutTiming(await noDeps.dispatch(request("100 usd in eur"))), { seq: 1, source: "grammar", decision: "fallthrough", reason: "no_match" });
});

test("privacy: perf hook and logs never carry the utterance", async () => {
  const fields: unknown[] = [];
  const logged: unknown[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => { logged.push(args); };
  try {
    const dispatcher = make({ perf: (stage, ms, f) => fields.push({ stage, ms, ...f }) });
    const secrets = ["what is 15% of my salary 98765", "find my passport scan", "open secret-project", "google my medical symptoms"];
    for (const text of secrets) await dispatcher.dispatch(request(text, "final"));
    const blob = JSON.stringify(fields);
    for (const text of secrets) for (const word of text.split(" ").filter((w) => w.length > 4)) assert.ok(!blob.includes(word), word);
    assert.equal(fields.length, secrets.length);
    assert.deepEqual(Object.keys(fields[0] as object).sort(), ["decision", "kind", "ms", "parsed", "phase", "stage"]);
  } finally {
    console.log = original;
  }
  assert.deepEqual(logged, []);
});

test("privacy: voice finals report counts and content-free labels only (hypothesis count, via), never heard text or sources", async () => {
  const fields: Record<string, unknown>[] = [];
  const logged: unknown[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => { logged.push(args); };
  try {
    const dispatcher = make({ perf: (stage, ms, f) => fields.push({ stage, ms, ...f }) });
    const hypotheses = [
      { text: "open spotifei secretword", source: "parakeet-v3", role: "primary" as const },
      { text: "Open Spotify.", source: "apple-dt/en-US", role: "secondary" as const },
      { text: "Öffne Spotifei privat.", source: "apple-dt/de-DE", role: "secondary" as const },
    ];
    await dispatcher.dispatch({ ...request("open spotifei secretword", "final"), inputMode: "voice", hypotheses, accept: ["suggest", "check", "confirm"] });
    await dispatcher.dispatch({ ...request("Spotify", "final"), inputMode: "voice" });
    const blob = JSON.stringify(fields);
    for (const word of ["spotifei", "secretword", "privat", "parakeet", "apple-dt"]) assert.ok(!blob.toLowerCase().includes(word), word);
    assert.deepEqual(fields.map((f) => [f.hyps, f.via]), [[3, "secondary"], [0, "exact"]]);
  } finally {
    console.log = original;
  }
  assert.deepEqual(logged, []);
});

test("currency rates download on the first currency query only, then come from the cache", async () => {
  const xml = readFileSync(join(fixtures, "instant-cases", "ecb-2026-10-02.xml"), "utf8");
  let fetches = 0;
  const fx = new EcbRateStore({
    file: join(mkdtempSync(join(tmpdir(), "pi-os-instant-fx-")), "fx.json"),
    fetch: (async () => { fetches++; return new Response(xml, { status: 200 }); }) as typeof fetch,
    now: () => new Date("2026-10-02T18:00:00Z"),
    log: () => {},
  });
  const dispatcher = make({ fx });
  await dispatcher.dispatch(request("2+2"));
  await dispatcher.dispatch(request("time in tokyo"));
  assert.equal(fetches, 0, "no egress for non-currency queries");
  const first = await dispatcher.dispatch(request("100 usd in eur", "typing"));
  assert.equal(fetches, 1);
  assert.deepEqual(first.decision === "answer" && { intent: first.intent, title: first.title }, { intent: "currency", title: "89.09 EUR" });
  await dispatcher.dispatch(request("50 chf in usd"));
  assert.equal(fetches, 1);
  // The copied amount uses the card's decimal convention (de: "89,09"), never grouping.
  const german = await dispatcher.dispatch(request("100 usd in eur", "final", { locale: "de-DE" }));
  const germanCopy = german.decision === "answer" ? german.card.elements.n1?.on?.copy?.params.text : undefined;
  assert.deepEqual([german.decision === "answer" && german.title, germanCopy], ["89,09 EUR", "89,09"]);
  const unknown = await dispatcher.dispatch(request("100 usd in inr", "partial"));
  assert.deepEqual(unknown.decision === "answer" && unknown.title, "No ECB reference rate for INR.");
  assert.equal((await dispatcher.dispatch(request("100 usd in inr"))).decision, "fallthrough", "a notice never ends a final");

  let offlineFetches = 0;
  const offline = make({ fx: new EcbRateStore({ file: join(mkdtempSync(join(tmpdir(), "pi-os-instant-fx-")), "fx.json"), fetch: (async () => { offlineFetches++; throw new Error("offline"); }) as typeof fetch, log: () => {} }) });
  for (const phase of ["typing", "typing", "partial"] as const) {
    const failed = await offline.dispatch(request("100 usd in eur", phase));
    assert.deepEqual(failed.decision === "answer" && failed.title, "ECB reference rates could not be downloaded.", phase);
  }
  assert.equal((await offline.dispatch(request("100 usd in eur", "final"))).decision, "fallthrough", "the final goes to the agent");
  assert.equal(offlineFetches, 1, "previews while offline do not re-fetch per keystroke");

  const disabled = make({ fx: new EcbRateStore({ file: join(mkdtempSync(join(tmpdir(), "pi-os-instant-fx-")), "fx.json"), enabled: () => false }) });
  const off = await disabled.dispatch(request("100 usd in eur", "typing"));
  assert.deepEqual(off.decision === "answer" && off.title, "Currency rate downloads are turned off (PI_OS_FX_RATES=0).");
});

test("every card binding is a valid host action and file actions only carry host tokens", async () => {
  const dispatcher = make();
  const texts = ["15% of 340", "5 miles in km", "time in tokyo", "days until christmas", "open fig", "find invoice", "github.com", "empty trash"];
  for (const phase of ["typing", "final"] as const) {
    for (const text of texts) {
      const response = await dispatcher.dispatch(request(text, phase));
      const card = ("card" in response ? response.card : undefined) as CardSpec | undefined;
      if (!card) continue;
      assert.equal(card.format, "pi-os-ui/1");
      assert.ok(Object.keys(card.elements).length <= 150);
      assert.ok(JSON.stringify(card).length <= 64 * 1024);
      for (const element of Object.values(card.elements)) {
        for (const binding of Object.values(element.on ?? {})) {
          const action = bindingToHostAction(binding);
          assert.notEqual(action, null, `${text}: ${JSON.stringify(binding)}`);
          if (action && "token" in action) assert.ok(searchResponse.items.some((item) => item.token === action.token));
        }
      }
    }
  }
});

test("huge results show scientific notation and never copy a shortened number", async () => {
  const dispatcher = make();
  const medium = await dispatcher.dispatch(request("2^1000"));
  assert.deepEqual(medium.decision === "answer" && medium.title, "1.0715086071 × 10^301");
  const mediumCopy = medium.decision === "answer" ? medium.card.elements.n1?.on?.copy?.params.text : undefined;
  assert.equal(String(mediumCopy).length, 302, "exact digits are copied");
  const huge = await dispatcher.dispatch(request("2^20000"));
  assert.equal(huge.decision, "answer");
  if (huge.decision === "answer") {
    assert.match(huge.title, /× 10\^6020$/);
    assert.equal(huge.card.elements.n1?.on, undefined, "no copy binding above the 4000-char action limit");
  }
});

test("warm() preloads the calculator; engines are exposed for pi tools", async () => {
  const dispatcher = make();
  await dispatcher.warm();
  const result = await dispatcher.engines.calc("80 + 15%");
  assert.deepEqual(result.ok && result.text, "92");
});
