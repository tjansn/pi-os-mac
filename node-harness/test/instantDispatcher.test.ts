import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { bindingToHostAction, type CardSpec } from "../src/contracts/cards.js";
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
const withoutTiming = (response: InstantResponse): Omit<InstantResponse, "elapsedMs"> => {
  const { elapsedMs, ...rest } = response;
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
    assert.deepEqual(withoutTiming(await dispatcher.dispatch(req)), rest, file);
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
  assert.deepEqual(withoutTiming(await currencyDispatcher.dispatch({ text: "100 usd in eur", phase: "final", seq: 3 })), rest);
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
  const hangingFiles = make({ searchFiles: () => new Promise(() => {}), budgets: { fileSearchMs: 80 } });
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
  const currency = await noDeps.dispatch(request("100 usd in eur"));
  assert.deepEqual(currency.decision === "answer" && currency.title, "Currency rates are not available.");
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
  const unknown = await dispatcher.dispatch(request("100 usd in inr"));
  assert.deepEqual(unknown.decision === "answer" && unknown.title, "No ECB reference rate for INR.");

  let offlineFetches = 0;
  const offline = make({ fx: new EcbRateStore({ file: join(mkdtempSync(join(tmpdir(), "pi-os-instant-fx-")), "fx.json"), fetch: (async () => { offlineFetches++; throw new Error("offline"); }) as typeof fetch, log: () => {} }) });
  for (const phase of ["typing", "typing", "partial", "final"] as const) {
    const failed = await offline.dispatch(request("100 usd in eur", phase));
    assert.deepEqual(failed.decision === "answer" && failed.title, "ECB reference rates could not be downloaded.", phase);
  }
  assert.equal(offlineFetches, 1, "previews while offline do not re-fetch per keystroke");

  const disabled = make({ fx: new EcbRateStore({ file: join(mkdtempSync(join(tmpdir(), "pi-os-instant-fx-")), "fx.json"), enabled: () => false }) });
  const off = await disabled.dispatch(request("100 usd in eur"));
  assert.deepEqual(off.decision === "answer" && off.title, "Currency rates are turned off in Settings.");
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
