import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import { AgentResourceSettings } from "../src/agent/resourceSettings.js";
import { loadConfig } from "../src/config.js";
import { NO_CONTEXT_SCORER } from "../src/contracts/context.js";
import { NO_DICTIONARY, type DictionaryLookup } from "../src/contracts/dictionary.js";
import type { InstantAccept, InstantFieldKind, InstantRequest, InstantResponse, InstantTarget, VoiceHypothesis } from "../src/contracts/instant.js";
import type { HostClient } from "../src/hostClient.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { createInstantDispatcher, type InstantDispatcherDeps } from "../src/instant/dispatcher.js";
import { InMemoryTakeMemo, takeRecordFor } from "../src/instant/takeMemo.js";
import { HarnessServer } from "../src/server.js";
import { fixtureApps } from "../scripts/voice-eval.mjs";
import { fakeHost } from "./integrationFixtures.js";

/*
 * Full pi session (protocol.md "Full pi session (macOS)", Tom: "for destructive commands we have dcg running as a hook,
 * it should prompt its own approval dialogue when hit"): with `deletionToAgent` on, a deletion or trash request the
 * instant policy refuses goes to pi as a fallthrough `no_match` (pi runs it with bash under dcg) instead of an instant
 * refusal. Nothing else moves: it is never typed into a focused field, never learned, never an instant act, and a
 * dispatcher without the dependency (or with it false: isolated mode, Windows) answers byte for byte as before.
 * Synthetic text and the 104-app fixture index; no host, no model, no file is touched.
 */

const APPS = fixtureApps();
const ALL: InstantAccept[] = ["suggest", "check", "confirm", "fill"];
const TODAY: InstantAccept[] = ["suggest", "check", "confirm"];

/** The four requests of the task, and the shapes the policy refuses (trash, shell, uninstall, an installed app's name). */
const DELETIONS: readonly [text: string, locale: string][] = [
  ["Lösche den Ordner ~/pi-os-dcg-probe", "de-DE"], ["delete the folder ~/x", "en-US"], ["rm -r ~/x", "en-US"], ["move X to the trash", "en-US"],
  ["Move notes.txt to the trash.", "en-US"], ["Papierkorb leeren", "de-DE"], ["empty the trash", "en-US"], ["rm -rf ~/Downloads", "en-US"],
  ["delete the zip files", "en-US"], ["lösche alle Dateien", "de-DE"], ["i want to uninstall slack", "en-US"], ["Lösche Pages.", "de-DE"],
  ["delete Pages", "en-US"],
];
/** Everything else: answers, opens, text edits, how-tos and bare edits decide exactly as today in a full session. */
const OTHERS: readonly [text: string, locale: string][] = [
  ["open pages", "en-US"], ["15% of 340", "en-US"], ["open github.com", "en-US"], ["delete the last sentence", "en-US"], ["lösche den Termin", "de-DE"],
  ["how do I empty the trash", "en-US"], ["wie leere ich den Papierkorb", "de-DE"], ["delete it", "en-US"], ["Albert Einstein", "de-DE"],
  ["Öffne Notion.", "de-DE"], ["delete figma file comments", "en-US"],
];

let asked = 0;
function make(deletionToAgent: (() => boolean) | undefined, overrides: Partial<InstantDispatcherDeps> = {}) {
  return createInstantDispatcher({
    apps: new AppIndexCache(async () => ({ version: "1", apps: APPS })), localZone: () => "Europe/Berlin", homeDir: "/Users/fixture",
    scorer: NO_CONTEXT_SCORER, ...(deletionToAgent ? { deletionToAgent: () => { asked++; return deletionToAgent(); } } : {}), ...overrides,
  });
}

const P = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "parakeet-v3", role: "primary", confidence: 0.92, minConfidence: 0.6, ...extra });
const EN = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "apple-dt/en-US", role: "peer", locale: "en-US", confidence: 0.7, ...extra });
const DE = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "apple-dt/de-DE", role: "peer", locale: "de-DE", confidence: 0.7, ...extra });
const SEC = (text: string, source = "apple-dt/en-US"): VoiceHypothesis => ({ text, source, role: "secondary" });

const typed = (text: string, locale: string, extra: Partial<InstantRequest> = {}): InstantRequest => ({ text, phase: "final", seq: 1, locale, ...extra });
const spoken = (text: string, locale: string, extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text, phase: "final", seq: 1, locale, inputMode: "voice", hypotheses: [P(text)], accept: TODAY, ...extra,
});
const final = (hypotheses: VoiceHypothesis[], extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text: hypotheses[0]!.text, phase: "final", seq: 1, inputMode: "voice", hypotheses, accept: TODAY, ...extra,
});
const field = (kind: InstantFieldKind): NonNullable<InstantTarget["field"]> => ({ kind, ...(kind === "credential" ? {} : { empty: true }), ready: true });
const target = (kind: InstantFieldKind, app: InstantTarget["app"] = "other"): InstantTarget => ({ app, field: field(kind) });

/** The response without timing (two dispatches of the same request are byte-identical apart from it). */
const stable = (response: InstantResponse): string => JSON.stringify({ ...response, elapsedMs: 0 });
const isFill = (response: InstantResponse): boolean => response.decision === "act" && response.intent === "fill";
/** A plain hand-off to pi: no card, no hints, no check card, no fill offer, nothing to act on. */
function toPi(response: InstantResponse, label: string): void {
  assert.deepEqual({ ...response, elapsedMs: 0 }, { seq: response.seq, elapsedMs: 0, source: "grammar", decision: "fallthrough", reason: "no_match" }, label);
}
function refused(response: InstantResponse, label: string): void {
  assert.ok(response.decision === "refuse" && response.code === "file_deletion_blocked", `${label}: ${JSON.stringify(response)}`);
}

test("full pi session: deletion and trash finals go to pi (typed and spoken); without the dependency or with it false they are refused byte for byte", async () => {
  const today = make(undefined);
  const off = make(() => false);
  const full = make(() => true);
  for (const [text, locale] of DELETIONS) {
    for (const [mode, request] of [["typed", typed(text, locale)], ["voice", spoken(text, locale)]] as const) {
      const before = await today.dispatch(request);
      refused(before, `${mode} ${text}`);
      assert.equal(stable(await off.dispatch(request)), stable(before), `${mode} ${text}: false is today's lane`);
      toPi(await full.dispatch(request), `${mode} ${text}`);
    }
  }
  // A doubtful recognizer changes nothing: no "Did I hear that right?" card, the take goes to pi as it was said.
  toPi(await full.dispatch(spoken("Lösche den Ordner ~/pi-os-dcg-probe", "de-DE", { hypotheses: [P("Lösche den Ordner ~/pi-os-dcg-probe", { minConfidence: 0.1 })] })), "doubt");
});

test("full pi session: everything that is not a refused deletion decides exactly as today, and the mode is not even read", async () => {
  const today = make(undefined);
  const full = make(() => true);
  asked = 0;
  for (const [text, locale] of OTHERS) {
    for (const request of [typed(text, locale), spoken(text, locale), { ...typed(text, locale), phase: "typing" as const }, { ...spoken(text, locale), phase: "partial" as const }]) {
      assert.equal(stable(await full.dispatch(request)), stable(await today.dispatch(request)), `${request.inputMode ?? "text"} ${request.phase} ${text}`);
    }
  }
  assert.equal(asked, 0, "deletionToAgent is read only for a refused deletion");
});

test("full pi session: typing and partial previews of a deletion show nothing (no refusal warning, nothing actionable)", async () => {
  const today = make(undefined);
  const off = make(() => false);
  const full = make(() => true);
  for (const [text, locale] of DELETIONS) {
    for (const request of [{ ...typed(text, locale), phase: "typing" as const }, { text, phase: "partial" as const, seq: 2, locale, inputMode: "voice" as const }]) {
      const label = `${request.phase} ${text}`;
      const before = await today.dispatch(request);
      refused(before, label);
      assert.equal(stable(await off.dispatch(request)), stable(before), label);
      const preview = await full.dispatch(request);
      toPi(preview, label);
      assert.notEqual(preview.decision, "act", label);
    }
  }
});

test("full pi session: arbitration keeps its caution — a peer's deletion never lets the take act, the take goes to pi; a secondary's deletion changes nothing", async () => {
  const today = make(undefined);
  const full = make(() => true);
  for (const hypotheses of [
    [EN("Open Pages.", { confidence: 0.9 }), DE("Lösche Pages.", { confidence: 0.4 })],
    [DE("Lösche den Ordner ~/pi-os-dcg-probe", { confidence: 0.6 }), EN("Open Notion.", { confidence: 0.9 })],
    [EN("Open Notion.", { confidence: 0.9 }), DE("Leere den Papierkorb.", { confidence: 0.5 })],
  ]) {
    const label = hypotheses.map((h) => h.text).join(" | ");
    refused(await today.dispatch(final(hypotheses)), label);
    toPi(await full.dispatch(final(hypotheses)), label);
  }
  // Secondaries never refuse a take: their deletion turns the alternatives off in both modes alike.
  asked = 0;
  for (const hypotheses of [[P("open grave"), SEC("Open Brave."), SEC("Delete Brave.", "apple-dt/de-DE")], [P("open grave"), SEC("Delete Brave.")]]) {
    const response = await full.dispatch(final(hypotheses));
    assert.equal(stable(response), stable(await today.dispatch(final(hypotheses))));
    assert.notEqual(response.decision, "act");
  }
  assert.equal(asked, 0);
  // "No, I meant delete Pages" right after an act: no correction, no act; the take goes to pi (typed and spoken).
  const takeMemo = new InMemoryTakeMemo();
  const opening = final([P("Open Notion.")], { takeId: "take-41" });
  const opened = await make(undefined, { takeMemo }).dispatch(opening);
  assert.equal(opened.decision, "act");
  takeMemo.remember(takeRecordFor(opening, opened, Date.now())!);
  const before = make(undefined, { takeMemo });
  const after = make(() => true, { takeMemo });
  for (const request of [final([P("No, I meant delete Pages.")], { takeId: "take-42" }), typed("No, I meant delete Pages", "en-US", { takeId: "take-43" })]) {
    refused(await before.dispatch(request), request.text);
    toPi(await after.dispatch(request), request.text);
  }
});

test("full pi session: a focused field never receives a deletion (voice and typed); dictating one or a confirm field stays refused", async () => {
  const full = make(() => true);
  const today = make(undefined);
  const fields: InstantTarget[] = [
    target("multiline"), target("text"), target("search", "browser"), target("address", "browser"), target("terminal", "terminal"),
    target("credential", "browser"), target("sensitive", "browser"),
  ];
  for (const [text, locale] of DELETIONS.slice(0, 4)) {
    for (const tgt of fields) {
      for (const [mode, request] of [
        ["voice", spoken(text, locale, { accept: ALL, target: tgt })], ["typed", typed(text, locale, { accept: ["fill"], target: tgt })],
      ] as const) {
        const label = `${mode} ${tgt.field!.kind} ${text}`;
        const response = await full.dispatch(request);
        assert.ok(!isFill(response), label);
        assert.ok(!(response.decision === "fallthrough" && response.voice?.fill), `${label}: no fill offer`);
        toPi(response, label);
      }
    }
  }
  // "type rm -r ~/x": continuity's own refusal (a dictated deletion is never typed), in both modes alike.
  for (const request of [spoken("type rm -r ~/x", "en-US", { accept: ALL, target: target("terminal", "terminal") }),
    typed("type rm -r ~/x", "en-US", { accept: ["fill"], target: target("multiline") })]) {
    const response = await full.dispatch(request);
    refused(response, request.text);
    assert.equal(stable(response), stable(await today.dispatch(request)));
  }
  const confirm = await full.dispatch(spoken("Tippe Hallo Welt.", "de-DE", { accept: ALL, target: target("confirm") }));
  assert.ok(confirm.decision === "refuse" && /confirms a deletion/.test(confirm.message));
});

test("full pi session: a learned rule never carries a deletion — the words go to pi, no rule decides and none is counted", async () => {
  const uses: string[] = [];
  const hostile: DictionaryLookup = {
    ...NO_DICTIONARY,
    alias: () => ({ ref: { list: "aliases", id: "a_hostile" }, value: { kind: "openApp", bundleId: "com.apple.Pages" } }),
    appName: () => ({ ref: { list: "appNames", id: "n_hostile" }, value: { bundleId: "com.apple.Pages", display: "Pages" } }),
    fixes: () => [{ ref: { list: "fixes", id: "f_hostile" }, value: { heard: "x", intended: "pages" } }],
    noteUse: (ref) => { uses.push(ref.id); },
  };
  const full = make(() => true, { dictionary: hostile });
  for (const [text, locale] of DELETIONS) {
    toPi(await full.dispatch(spoken(text, locale)), `voice ${text}`);
    toPi(await full.dispatch(typed(text, locale)), `typed ${text}`);
  }
  assert.deepEqual(uses, []);
});

test("server: /instant follows the stored resource mode — macOS trustedGlobal hands deletions to pi; isolated, read-only and Windows refuse; nothing is learned", async () => {
  const text = "Lösche den Ordner ~/pi-os-dcg-probe";
  const scenario = async (platform: NodeJS.Platform, readOnly: boolean, check: (ask: (body: Record<string, unknown>) => Promise<any>,
    settings: AgentResourceSettings, learn: (body: Record<string, unknown>) => Promise<any>) => Promise<void>) => {
    const supportDir = mkdtempSync(join(tmpdir(), "pi-os-deletion-agent-"));
    const settings = new AgentResourceSettings(join(supportDir, "resources.json"));
    const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "token", agentEnabled: false, readOnly }, {
      hostClient: fakeHost({ apps: { version: "1", apps: APPS } }) as unknown as HostClient, supportDir, platform, resourceSettings: settings,
      modelSettings: new AgentModelSettings(join(supportDir, "settings.json"), () => {}), onInvocation: async () => {}, loadAgentModules: () => new Promise(() => {}),
    });
    const base = `http://127.0.0.1:${await server.listen()}`;
    const post = (path: string, body: unknown) => fetch(base + path, { method: "POST", headers: { "X-Harness-Token": "token", "Content-Type": "application/json" }, body: JSON.stringify(body) })
      .then(async (response) => { assert.equal(response.status, 200, path); return response.json() as Promise<any>; });
    try {
      await check((body) => post("/instant", { text, phase: "final", seq: 1, locale: "de-DE", ...body }), settings, (body) => post("/dictionary/learn", body));
    } finally {
      await server.close();
      rmSync(supportDir, { recursive: true, force: true });
    }
  };
  const voice = { inputMode: "voice", accept: TODAY, hypotheses: [{ text, source: "parakeet-v3", role: "primary" }] };

  await scenario("darwin", false, async (ask, settings, learn) => {
    assert.equal((await ask({})).decision, "refuse", "fresh installs are isolated");
    settings.set("trustedGlobal", true);
    for (const [index, body] of [{}, voice, { phase: "typing" }].entries()) {
      const response = await ask({ ...body, takeId: `full-${index}` });
      assert.deepEqual([response.decision, response.reason], ["fallthrough", "no_match"], JSON.stringify(body));
    }
    // The take went to pi, and nothing about it can be learned (policy on the words, not on the decision).
    for (const gesture of [{ kind: "edit", correctedText: "open pages" }, { kind: "pick", bundleId: "com.apple.Pages" }, { kind: "confirm", bundleId: "com.apple.Pages" }]) {
      for (const takeId of ["full-0", "full-1"]) {
        const learned = await learn({ takeId, ...gesture });
        assert.equal(learned.status, "refused", `${takeId} ${gesture.kind}`);
        if (gesture.kind === "edit") assert.equal(learned.code, "refused_phrase");
      }
    }
    // The mode is read per decision: back to isolated, back to the refusal.
    settings.set("isolated", false);
    assert.equal((await ask({ ...voice, takeId: "isolated" })).decision, "refuse");
  });
  await scenario("darwin", true, async (ask, settings) => {
    settings.set("trustedGlobal", true);
    assert.equal((await ask(voice)).decision, "refuse", "a read-only launch is never a full session");
  });
  await scenario("win32", false, async (ask, settings) => {
    settings.set("trustedGlobal", true);
    assert.equal((await ask({})).decision, "refuse", "Windows keeps today's lane");
  });
});
