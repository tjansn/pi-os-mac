import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test, type TestContext } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { loadConfig } from "../src/config.js";
import { parseRecognizerTerms, parseWriteResponse, type DictionaryDocument } from "../src/contracts/dictionary.js";
import type { AppRecord } from "../src/contracts/launcher.js";
import type { HostClient } from "../src/hostClient.js";
import { DictionaryStore } from "../src/instant/dictionary.js";
import { HarnessServer, importAgentModules, type AgentModules, type HarnessServerOptions } from "../src/server.js";
import { fakeHost } from "./integrationFixtures.js";

/**
 * POST /dictionary/learn, GET /dictionary, POST /dictionary/edit and GET /dictionary/recognizer-terms over
 * HTTP (DESIGN4 §6.2), the take memo /instant fills for them, strict /instant parsing (hypotheses, accept),
 * and the instant-first start: /health, /instant and /dictionary/* never wait for the agent stack.
 */

const TOKEN = "dictionary-token";
const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const VALID = join(fixtures, "dictionary", "valid.json");
const app = (bundleId: string, name: string, aliases: string[] = []): AppRecord => ({ bundleId, name, aliases, path: `/Applications/${name}.app`, running: false });
const APPS: AppRecord[] = [
  app("com.raycast.macos", "Raycast"), app("com.raycast.beta", "Raycast Beta"), app("com.apple.Keynote", "Keynote Creator Studio", ["Keynote"]),
  app("com.apple.Notes", "Notes"), app("notion.id", "Notion"), app("md.obsidian", "Obsidian"), app("com.example.opendesign", "Open Design"),
  app("com.mitchellh.ghostty", "Ghostty"), app("com.apple.Safari", "Safari"),
];
const ACCEPT = ["suggest", "check", "confirm"];

interface Harness {
  server: HarnessServer;
  supportDir: string;
  get(path: string, headers?: Record<string, string>): Promise<{ status: number; body: any }>;
  post(path: string, body: unknown, headers?: Record<string, string>): Promise<{ status: number; body: any }>;
  /** POST /dictionary/learn, checked against the wire contract. */
  learn(body: Record<string, unknown>): Promise<any>;
  edit(body: Record<string, unknown>): Promise<any>;
  dictionary(): Promise<DictionaryDocument>;
}

async function harness(t: TestContext, options: Partial<HarnessServerOptions> & { dictionaryFile?: string; hostClient?: HostClient } = {}): Promise<Harness> {
  const supportDir = mkdtempSync(join(tmpdir(), "pi-os-dict-routes-"));
  if (options.dictionaryFile) copyFileSync(options.dictionaryFile, join(supportDir, "dictionary.json"));
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: TOKEN, agentEnabled: false }, {
    hostClient: fakeHost({ apps: { version: "1", apps: APPS } }) as unknown as HostClient, supportDir, onInvocation: async () => {}, ...options,
  });
  const base = `http://127.0.0.1:${await server.listen()}`;
  t.after(() => server.close());
  const headers = { "X-Harness-Token": TOKEN, "Content-Type": "application/json" };
  const read = async (response: Response) => ({ status: response.status, body: await response.json().catch(() => null) as any });
  const get = (path: string, extra: Record<string, string> = {}) => fetch(base + path, { headers: { ...headers, ...extra } }).then(read);
  const post = (path: string, body: unknown, extra: Record<string, string> = {}) =>
    fetch(base + path, { method: "POST", headers: { ...headers, ...extra }, body: typeof body === "string" ? body : JSON.stringify(body) }).then(read);
  const write = async (path: string, body: Record<string, unknown>) => {
    const response = await post(path, body);
    assert.equal(response.status, 200, JSON.stringify(response.body));
    assert.ok(parseWriteResponse(response.body).ok, `wire shape: ${JSON.stringify(response.body)}`);
    return response.body;
  };
  return {
    server, supportDir, get, post,
    learn: (body) => write("/dictionary/learn", body),
    edit: (body) => write("/dictionary/edit", body),
    dictionary: async () => (await get("/dictionary")).body,
  };
}

const final = (takeId: string, text: string, extra: Record<string, unknown> = {}) => ({ text, phase: "final", seq: 1, takeId, ...extra });

test("GET /dictionary is the document; recognizer-terms ranks it with the host's apps; ?max is validated without echoing it", async (t) => {
  const h = await harness(t, { dictionaryFile: VALID });
  assert.deepEqual((await h.get("/dictionary")).body, JSON.parse(readFileSync(VALID, "utf8")));
  const terms = await h.get("/dictionary/recognizer-terms");
  assert.equal(terms.status, 200);
  const parsed = parseRecognizerTerms(terms.body);
  assert.ok(parsed.ok);
  if (!parsed.ok) return;
  assert.equal(parsed.value.revision, 42);
  const texts = parsed.value.terms.map((term) => term.text);
  assert.equal(texts[0], "Ghostty", "the pinned term first");
  assert.ok(texts.includes("Safari") && texts.includes("Notion"), "installed apps follow");
  assert.ok(texts.includes("Keynote") && texts.indexOf("Keynote") < texts.indexOf("Keynote Creator Studio"), "an app's spoken short name, then its full name");
  assert.ok(!texts.includes("Open Design"), "never a verb-initial name");
  assert.equal(texts.filter((text) => text === "Raycast").length, 1, "duplicates fold");
  assert.equal((await h.get("/dictionary/recognizer-terms?max=2")).body.terms.length, 2);
  for (const max of ["0", "101", "abc", "1.5", "-1"]) {
    const bad = await h.get(`/dictionary/recognizer-terms?max=${max}`);
    assert.equal(bad.status, 400, max);
    assert.deepEqual(bad.body.error, { code: "invalid_arguments", message: "max must be 1..100" });
  }
  assert.equal((await h.get("/dictionary/nope")).status, 404);
  assert.equal((await h.post("/dictionary", {})).status, 404);
});

test("recognizer-terms without the host's app index answers no terms, so the host asks again instead of keeping a list without app names", async (t) => {
  const h = await harness(t, { dictionaryFile: VALID, hostClient: fakeHost({}) as unknown as HostClient });
  const terms = await h.get("/dictionary/recognizer-terms");
  assert.equal(terms.status, 200);
  assert.deepEqual(terms.body, { revision: 42, terms: [] });
  assert.ok(parseRecognizerTerms(terms.body).ok);
});

test("learn over HTTP: an /instant list is remembered; a pick learns at once with Undo; Undo restores; the pick counts as app usage", async (t) => {
  const h = await harness(t);
  const list = await h.post("/instant", final("take-1", "open rayc"));
  assert.equal(list.body.decision, "list");
  assert.deepEqual(h.server.takeMemo.get("take-1")?.offered, ["com.raycast.macos", "com.raycast.beta"]);
  const learned = await h.learn({ takeId: "take-1", kind: "pick", bundleId: "com.raycast.macos" });
  assert.equal(learned.status, "learned");
  assert.equal(learned.line, "Learned: “rayc” → Raycast");
  assert.equal(learned.entry.list, "appNames");
  assert.equal(learned.revision, 1);
  const document = await h.dictionary();
  assert.deepEqual(document.appNames.map((entry) => [entry.heard, entry.bundleId, entry.display, entry.recognizer, entry.source]),
    [["rayc", "com.raycast.macos", "Raycast", "any", "list-pick"]]);
  assert.equal(h.server.dictionary.appName("rayc", "any")?.value.bundleId, "com.raycast.macos", "the next take's lookup sees it at once");
  const undone = await h.edit({ op: "undo", undoToken: learned.undoToken });
  assert.deepEqual([undone.status, undone.code, undone.revision], ["updated", "undone", 2]);
  assert.deepEqual((await h.dictionary()).appNames, []);
  const again = await h.edit({ op: "undo", undoToken: learned.undoToken });
  assert.deepEqual([again.status, again.code], ["refused", "undo_expired"]);
  // The pick is app usage (frecency), recorded next to the dictionary.
  const usage = join(h.supportDir, "instant-usage.json");
  for (let i = 0; i < 50 && !existsSync(usage); i++) await delay(10);
  assert.ok(JSON.parse(readFileSync(usage, "utf8"))["com.raycast.macos"]?.count >= 1);
});

test("learn validation: unknown take, an app the take never offered, learning off and ask mode", async (t) => {
  const h = await harness(t);
  const unknown = await h.learn({ takeId: "never-seen", kind: "pick", bundleId: "com.raycast.macos" });
  assert.deepEqual([unknown.status, unknown.code, unknown.line], ["refused", "unknown_take", "That take is too old to learn from."]);
  await h.post("/instant", final("take-2", "open rayc"));
  const unoffered = await h.learn({ takeId: "take-2", kind: "pick", bundleId: "notion.id" });
  assert.deepEqual([unoffered.status, unoffered.code], ["refused", "not_offered"]);
  await h.edit({ op: "settings", settings: { learn: "off" } });
  const off = await h.learn({ takeId: "take-2", kind: "pick", bundleId: "com.raycast.macos" });
  assert.deepEqual([off.status, off.code], ["refused", "learning_off"]);
  await h.edit({ op: "settings", settings: { learn: "ask" } });
  const ask = await h.learn({ takeId: "take-2", kind: "pick", bundleId: "com.raycast.macos" });
  assert.deepEqual([ask.status, ask.code, ask.line], ["needs_confirmation", "ask_mode", "Remember “rayc” → Raycast?"]);
  assert.equal((await h.dictionary()).appNames.length, 0);
  const remembered = await h.learn({ takeId: "take-2", kind: "pick", bundleId: "com.raycast.macos", confirmed: true });
  assert.equal(remembered.status, "learned");
  // A malformed body is a 400 that names the field, never the value.
  const bad = await h.post("/dictionary/learn", { takeId: "take-2", kind: "pick", bundleId: "not a bundle id" });
  assert.equal(bad.status, 400);
  assert.ok(!JSON.stringify(bad.body).includes("not a bundle id"));
});

test("No, I meant: a target the lane resolves, asked once, then learned for the recognizer that misheard", async (t) => {
  const h = await harness(t);
  const heard = await h.post("/instant", final("take-3", "open the frobnicator", {
    inputMode: "voice", accept: ACCEPT, hypotheses: [{ text: "open the frobnicator", source: "parakeet-v3", role: "primary", confidence: 0.6 }],
  }));
  assert.deepEqual([heard.body.decision, heard.body.reason, heard.body.voice], ["fallthrough", "no_match", { heard: "frobnicator", source: "parakeet-v3" }]);
  const asked = await h.learn({ takeId: "take-3", kind: "no_i_meant", correctedText: "No, I meant Notion" });
  assert.deepEqual([asked.status, asked.code, asked.line], ["needs_confirmation", "inferred", "Remember “frobnicator” → Notion?"]);
  assert.equal((await h.dictionary()).revision, 0);
  const learned = await h.learn({ takeId: "take-3", kind: "no_i_meant", correctedText: "No, I meant Notion", confirmed: true });
  assert.equal(learned.status, "learned");
  const entry = (await h.dictionary()).appNames[0]!;
  assert.deepEqual([entry.heard, entry.bundleId, entry.recognizer, entry.source], ["frobnicator", "notion.id", "parakeet-v3", "no-i-meant"]);
  const unresolved = await h.learn({ takeId: "take-3", kind: "no_i_meant", correctedText: "the frobnicator thing" });
  assert.deepEqual([unresolved.status, unresolved.code], ["refused", "unresolved"]);
});

test("check-state edit: the edited resend keeps the voice hypotheses, and the edit teaches the heard name after Remember", async (t) => {
  const h = await harness(t);
  const voice = await h.post("/instant", final("take-4", "open the key thing", {
    inputMode: "voice", locale: "de-DE", accept: ACCEPT, hypotheses: [{ text: "open the key thing", source: "apple-dt/de-DE", role: "peer", confidence: 0.5 }],
  }));
  assert.equal(voice.body.decision, "fallthrough");
  const resend = await h.post("/instant", { ...final("take-4", "open Keynote", { inputMode: "text", accept: ACCEPT }), seq: 2 });
  assert.equal(resend.body.decision, "act");
  const memo = h.server.takeMemo.get("take-4")!;
  assert.deepEqual(memo.hypotheses.map((hypothesis) => hypothesis.text), ["open the key thing"], "the first voice final's hypotheses stay");
  assert.deepEqual([memo.inputMode, memo.decision, memo.offered], ["text", "act", ["com.apple.Keynote"]]);
  const asked = await h.learn({ takeId: "take-4", kind: "edit", correctedText: "open Keynote" });
  assert.deepEqual([asked.status, asked.code, asked.line], ["needs_confirmation", "inferred", "Remember “key thing” → Keynote?"]);
  const learned = await h.learn({ takeId: "take-4", kind: "edit", correctedText: "open Keynote", confirmed: true });
  assert.equal(learned.line, "Learned: “key thing” → Keynote");
  const entry = (await h.dictionary()).appNames[0]!;
  assert.deepEqual([entry.heard, entry.bundleId, entry.display, entry.recognizer, entry.source], ["key thing", "com.apple.Keynote", "Keynote", "apple-dt/de-DE", "transcript-edit"]);
  assert.equal(h.server.dictionary.appName("key thing", "apple-dt/en-US"), null, "scoped to the recognizer that misheard");
});

test("reject: only the rule that decided the take; two rejections disable a rule taught once", async (t) => {
  const h = await harness(t);
  await h.post("/instant", final("take-5", "open rayc"));
  const learned = await h.learn({ takeId: "take-5", kind: "pick", bundleId: "com.raycast.macos" });
  const id = learned.entry.id as string;
  // The voice pipeline (N2) remembers the rule that decided a later take.
  for (const takeId of ["take-6", "take-7"]) {
    h.server.takeMemo.remember({
      takeId, at: Date.now(), inputMode: "voice", hypotheses: [{ text: "open rayc", source: "any", role: "primary" }], decision: "act",
      recognizer: "any", offered: ["com.raycast.macos"], acted: { kind: "openApp", bundleId: "com.raycast.macos" }, learnedEntryId: id, via: "learned",
    });
  }
  const forged = await h.learn({ takeId: "take-6", kind: "reject", entryId: "n_someoneelse" });
  assert.deepEqual([forged.status, forged.code], ["refused", "unknown_entry"]);
  const once = await h.learn({ takeId: "take-6", kind: "reject" });
  assert.deepEqual([once.status, once.code, once.entry], ["learned", "rejection_recorded", { list: "appNames", id }]);
  const twice = await h.learn({ takeId: "take-7", kind: "reject", entryId: id });
  assert.deepEqual([twice.status, twice.code], ["learned", "rule_disabled"]);
  assert.equal(h.server.dictionary.appName("rayc", "any"), null);
  const plain = await h.learn({ takeId: "take-5", kind: "reject" });
  assert.deepEqual([plain.status, plain.code], ["refused", "nothing_to_learn"], "a take no rule decided has nothing to reject");
  // Learning off never stops a rejection (it only ever disables rules).
  await h.edit({ op: "settings", settings: { learn: "off" } });
  assert.equal((await h.learn({ takeId: "take-6", kind: "reject" })).status, "learned");
});

test("regression check: a rule that would change accepted journal takes asks first, with their indices", async (t) => {
  const h = await harness(t);
  await h.post("/instant", final("take-8", "open rayc"));
  const regression = [
    { text: "open rayc", source: "apple-dt/en-US", target: { kind: "openApp", bundleId: "com.raycast.beta" } },
    { text: "wie spät ist es in Tokio", source: "apple-dt/de-DE" },
    { text: "Open rayc, please.", source: "parakeet-v3", target: { kind: "openApp", bundleId: "com.raycast.beta" } },
    { text: "open rayc", source: "parakeet-v3", target: { kind: "openApp", bundleId: "com.raycast.macos" } },
    { text: "open rayc", source: "parakeet-v3" },
  ];
  const asked = await h.learn({ takeId: "take-8", kind: "pick", bundleId: "com.raycast.macos", regression });
  assert.deepEqual([asked.status, asked.code, asked.conflicts, asked.line], ["needs_confirmation", "regression", [0, 2], "This would change 2 earlier takes. Remember anyway?"]);
  const learned = await h.learn({ takeId: "take-8", kind: "pick", bundleId: "com.raycast.macos", regression, confirmed: true });
  assert.equal(learned.status, "learned");
});

test("noteUse: only the host's /instant finals count a learned rule — never partials, /invoke's instant answers or the learn lane's resolves", async (t) => {
  const h = await harness(t);
  await h.post("/instant", final("take-u1", "open rayc"));
  assert.equal((await h.learn({ takeId: "take-u1", kind: "pick", bundleId: "com.raycast.macos" })).status, "learned");
  const uses = async () => (await h.dictionary()).appNames[0]!.uses;
  assert.equal(await uses(), 0);
  // A typed final decided by the learned name: one use, and the rule is named on the response.
  const acted = await h.post("/instant", final("take-u2", "open rayc"));
  assert.deepEqual([acted.body.decision, acted.body.action, acted.body.voice?.via], ["act", { type: "openApp", bundleId: "com.raycast.macos" }, "learned"]);
  assert.equal(h.server.takeMemo.get("take-u2")?.learnedEntryId, acted.body.voice?.learnedEntryId);
  assert.equal(await uses(), 1);
  // Partials and typing previews never apply learned rules.
  for (const phase of ["typing", "partial"]) {
    const preview = await h.post("/instant", { text: "open rayc", phase, seq: 1, takeId: `take-u3-${phase}`, inputMode: "voice" });
    assert.notEqual(preview.body.decision, "act");
  }
  // /invoke without a takeId runs the instant lane for pure answers (Windows-shaped): no use.
  assert.equal((await h.post("/invoke", { invocationId: "inv-u", contextId: "ctx-pinned", prompt: "open rayc" })).status, 202);
  for (let i = 0; i < 100 && !["completed", "failed"].includes((await h.get("/invocations/inv-u")).body?.state); i++) await delay(10);
  // The learn lane resolves "open rayc" through the same rule: no use either.
  await h.post("/instant", final("take-u4", "open the frobnicator"));
  assert.equal((await h.learn({ takeId: "take-u4", kind: "no_i_meant", correctedText: "No, I meant rayc" })).status, "needs_confirmation");
  assert.equal(await uses(), 1);
});

test("Settings edits: upsert, pin, disable, enable, delete, reset (which also forgets the takes) and settings", async (t) => {
  const h = await harness(t);
  const added = await h.edit({ op: "upsert", entry: { list: "terms", text: "DRACO", soundsLike: ["Draco"], lang: "en" } });
  assert.equal(added.status, "updated");
  const id = added.entry.id as string;
  assert.deepEqual((await h.dictionary()).terms.map((term) => [term.text, term.soundsLike, term.source]), [["DRACO", ["draco"], "manual"]]);
  assert.equal((await h.edit({ op: "pin", list: "terms", id })).status, "updated");
  assert.equal((await h.dictionary()).terms[0]!.pinned, true);
  assert.equal((await h.edit({ op: "disable", list: "terms", id })).status, "updated");
  assert.ok((await h.dictionary()).terms[0]!.disabledAt);
  assert.equal((await h.edit({ op: "enable", list: "terms", id })).status, "updated");
  const journal = await h.edit({ op: "upsert", source: "journal-fix", entry: { list: "fixes", heard: "Clod", intended: "Claude", recognizer: "apple-dt/en-US" } });
  assert.equal(journal.status, "updated");
  assert.equal((await h.dictionary()).fixes[0]!.source, "journal-fix");
  const missing = await h.edit({ op: "delete", list: "fixes", id: "f_missing" });
  assert.deepEqual([missing.status, missing.code], ["refused", "unknown_entry"]);
  await h.post("/instant", final("take-9", "open rayc"));
  assert.ok(h.server.takeMemo.get("take-9"));
  const reset = await h.edit({ op: "reset", confirmed: true });
  assert.deepEqual([reset.status, reset.code], ["updated", "reset"]);
  const document = await h.dictionary();
  assert.deepEqual([document.terms, document.fixes], [[], []]);
  assert.equal(h.server.takeMemo.get("take-9"), undefined, "Forget everything forgets the takes too");
  assert.equal((await h.post("/dictionary/edit", { op: "reset" })).status, 400, "reset needs confirmed: true");
});

test("/instant parses strictly: request fixtures pass, a bad hypothesis or accept is a 400 that never echoes it; hypotheses count on voice finals only", async (t) => {
  const h = await harness(t);
  const requests = join(fixtures, "instant", "requests");
  for (const name of readdirSync(requests).filter((file) => file.endsWith(".json"))) {
    const response = await h.post("/instant", JSON.parse(readFileSync(join(requests, name), "utf8")));
    assert.equal(response.status, 200, name);
  }
  const invalid = join(requests, "invalid");
  for (const name of readdirSync(invalid).filter((file) => file.endsWith(".json"))) {
    const body = readFileSync(join(invalid, name), "utf8");
    const response = await h.post("/instant", body);
    assert.equal(response.status, 400, name);
    const parsed = JSON.parse(body);
    for (const hypothesis of Array.isArray(parsed.hypotheses) ? parsed.hypotheses : []) {
      if (typeof hypothesis?.text === "string" && hypothesis.text.length > 3) assert.ok(!JSON.stringify(response.body).includes(hypothesis.text), name);
    }
  }
  const secret = "my secret transcript";
  const bad = await h.post("/instant", final("take-10", secret, { inputMode: "voice", hypotheses: [{ text: secret, source: "Bad Source!", role: "primary" }] }));
  assert.equal(bad.status, 400);
  assert.ok(!JSON.stringify(bad.body).includes(secret));
  assert.equal((await h.post("/instant", final("take-10", "open rayc", { accept: "check" }))).status, 400);
  // Hypotheses on a typed final are validated, then ignored: the memo keeps the typed text.
  const typed = await h.post("/instant", final("take-11", "open rayc", { inputMode: "text", hypotheses: [{ text: "open kein note", source: "apple-dt/de-DE", role: "peer" }] }));
  assert.equal(typed.status, 200);
  assert.deepEqual(h.server.takeMemo.get("take-11")?.hypotheses, [{ text: "open rayc", source: "any", role: "primary" }]);
  // Previews are never remembered; finals are.
  await h.post("/instant", { text: "open rayc", phase: "typing", seq: 1, takeId: "take-12" });
  assert.equal(h.server.takeMemo.get("take-12"), undefined);
});

test("body limits: learn ≤ 16 KB, edit ≤ 4 KB (413 above), JSON only (415)", async (t) => {
  const h = await harness(t);
  const pad = (bytes: number) => ({ takeId: "take-13", kind: "pick", bundleId: "com.raycast.macos", note: "x".repeat(bytes) });
  assert.equal((await h.post("/dictionary/learn", pad(12_000))).status, 200, "unknown members are ignored below the limit");
  assert.equal((await h.post("/dictionary/learn", pad(17_000))).status, 413);
  assert.equal((await h.post("/dictionary/edit", { op: "settings", settings: { learn: "ask" }, note: "x".repeat(5_000) })).status, 413);
  assert.equal((await h.post("/dictionary/edit", "op=reset", { "Content-Type": "text/plain" })).status, 415);
});

test("dictionary log lines carry kinds, statuses and codes only — never heard text, targets or tokens", async (t) => {
  const lines: string[] = [];
  const log = t.mock.method(console, "log", (...args: unknown[]) => { lines.push(args.map(String).join(" ")); });
  const warn = t.mock.method(console, "warn", (...args: unknown[]) => { lines.push(args.map(String).join(" ")); });
  const h = await harness(t);
  await h.post("/instant", final("take-14", "open kein note", { inputMode: "voice", hypotheses: [{ text: "open kein note", source: "apple-dt/de-DE", role: "peer" }] }));
  await h.post("/instant", { ...final("take-14", "open Keynote"), seq: 2 });
  const learned = await h.learn({ takeId: "take-14", kind: "edit", correctedText: "open Keynote", confirmed: true });
  await h.edit({ op: "undo", undoToken: learned.undoToken });
  await h.get("/dictionary/recognizer-terms?max=5");
  log.mock.restore();
  warn.mock.restore();
  const output = lines.join("\n");
  assert.match(output, /\[perf\] stage=dictionary\.learn ms=[\d.]+ kind=edit status=learned list=appNames/);
  assert.match(output, /\[perf\] stage=dictionary\.edit ms=[\d.]+ op=undo status=updated code=undone/);
  for (const content of ["kein", "Keynote", "com.apple.Keynote", learned.undoToken as string, learned.entry.id as string]) {
    assert.ok(!output.includes(content), `log line echoes ${content}`);
  }
});

// ---------------------------------------------------------------------------------------------
// Instant-first start (DESIGN4 §7 item 5)

function gate<T>() {
  let open!: (value: T) => void;
  const promise = new Promise<T>((resolve) => { open = resolve; });
  return { promise, open };
}

test("instant-first: /health, /instant, /dictionary, prepare and status answer while the agent stack loads; /invoke waits for it", async (t) => {
  const held = gate<void>();
  let loads = 0;
  const h = await harness(t, { loadAgentModules: async () => { loads++; await held.promise; return importAgentModules(); } });
  assert.equal((await h.get("/health")).status, 200);
  assert.equal((await h.post("/instant", final("take-15", "2+2"))).body.decision, "answer");
  assert.equal((await h.get("/dictionary")).status, 200);
  assert.equal((await h.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-15" })).status, 202);
  assert.equal((await h.get("/invocations/missing")).status, 404);
  let invoked: { status: number } | undefined;
  const invoke = h.post("/invoke", { contextId: "ctx-pinned", prompt: "what is on my screen", takeId: "take-15" }).then((response) => { invoked = response; return response; });
  await delay(150);
  assert.equal(invoked, undefined, "/invoke waits for the agent stack");
  assert.equal(loads, 1, "one import, shared by the warm-up and the route");
  held.open();
  assert.equal((await invoke).status, 202);
});

test("a failed agent import answers 503 harness_unreachable on agent routes (instant routes unaffected) and is retried", async (t) => {
  let fail = true;
  const h = await harness(t, {
    loadAgentModules: async (): Promise<AgentModules> => {
      if (fail) throw new Error("Cannot find module '/secret/path/agentRunner.js'");
      return importAgentModules();
    },
  });
  const errors = t.mock.method(console, "error", () => {});
  const failed = await h.post("/invoke", { contextId: "ctx-pinned", prompt: "hello" });
  assert.equal(failed.status, 503);
  assert.deepEqual(failed.body.error, { code: "harness_unreachable", message: "The agent could not be loaded" });
  assert.ok(errors.mock.calls.every((call) => !String(call.arguments[0]).includes("/secret/path")), "the log carries the error class only");
  assert.equal((await h.post("/instant", final("take-16", "2+2"))).status, 200);
  fail = false;
  assert.equal((await h.post("/invoke", { contextId: "ctx-pinned", prompt: "hello" })).status, 202);
});

test("server.ts imports neither pi-coding-agent nor pi-ai; /health answers first and the agent stack loads after it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-lazy-"));
  const script = join(dir, "probe.mjs");
  const root = resolve(import.meta.dirname, "..");
  // ESM specifiers (`import()`, `--import`) must be file: URLs; a Windows path such as D:\… would parse as scheme "d:".
  const moduleUrl = (...parts: string[]) => pathToFileURL(join(root, ...parts)).href;
  writeFileSync(script, `
import { registerHooks } from "node:module";
const seen = new Set();
registerHooks({ resolve(specifier, context, next) {
  const result = next(specifier, context);
  const match = /@earendil-works\\/(pi-coding-agent|pi-ai)\\//.exec(result.url);
  if (match) seen.add(match[1]);
  return result;
} });
const { HarnessServer } = await import(${JSON.stringify(moduleUrl("src", "server.ts"))});
const { loadConfig } = await import(${JSON.stringify(moduleUrl("src", "config.ts"))});
const afterImport = [...seen];
const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "t", agentEnabled: false });
const port = await server.listen();
const health = (await fetch("http://127.0.0.1:" + port + "/health")).status;
const atHealth = [...seen];
for (let i = 0; i < 400 && seen.size < 2; i++) await new Promise((resolve) => setTimeout(resolve, 25));
await server.close();
console.log(JSON.stringify({ afterImport, health, atHealth, later: [...seen].sort() }));
`);
  const child = spawn(process.execPath, ["--import", moduleUrl("test", "no-live-models.mjs"), "--import", "tsx", script], {
    cwd: root, env: { ...process.env, PI_OS_SUPPORT_DIR: dir }, stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  let err = "";
  child.stdout.on("data", (chunk) => { out += chunk; });
  child.stderr.on("data", (chunk) => { err += chunk; });
  const code = await new Promise<number | null>((resolve) => child.once("exit", resolve));
  assert.equal(code, 0, `${out}${err}`);
  const result = JSON.parse(out.trim().split("\n").filter((line) => line.startsWith("{")).at(-1)!);
  assert.deepEqual(result, { afterImport: [], health: 200, atHealth: [], later: ["pi-ai", "pi-coding-agent"] });
});
