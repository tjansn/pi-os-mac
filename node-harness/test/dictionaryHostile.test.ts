import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, readdirSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { test } from "node:test";
import { loadConfig } from "../src/config.js";
import {
  DICTIONARY_LISTS, parseEditRequest, type DictionaryEditRequest, type DictionaryLearnRequest, type DictionaryWriteResponse,
} from "../src/contracts/dictionary.js";
import type { AppRecord } from "../src/contracts/launcher.js";
import type { HostClient } from "../src/hostClient.js";
import { DictionaryStore, nonCountingLookup } from "../src/instant/dictionary.js";
import { AppIndexCache, createInstantDispatcher } from "../src/instant/index.js";
import { applyEdit, createLearnLane, learnFromGesture, type LearnLane } from "../src/instant/learned.js";
import { InMemoryTakeMemo, type TakeRecord } from "../src/instant/takeMemo.js";
import { HarnessServer } from "../src/server.js";
import { fakeHost } from "./integrationFixtures.js";

/**
 * DESIGN4 §6.8 as tests: a learned rule can never express or apply a deletion, a file/script URL or
 * anything beyond openApp / http(s) openURL / volume.*; policy runs first; shadowing an installed app asks;
 * the alias guard keeps bare verbs, politeness and numbers out; and no agent code can reach the dictionary.
 */

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const HOSTILE = join(fixtures, "dictionary", "hostile.json");
const NOW = Date.parse("2026-10-07T12:00:00Z");

const app = (bundleId: string, name: string, aliases: string[] = []): AppRecord => ({ bundleId, name, aliases, path: `/Applications/${name}.app`, running: false });
const APPS: AppRecord[] = [
  app("com.tinyspeck.slackmacgap", "Slack"), app("us.zoom.xos", "zoom.us", ["Zoom"]), app("com.apple.Pages", "Pages Creator Studio", ["Pages"]),
  app("com.apple.finder", "Finder"), app("com.apple.Keynote", "Keynote Creator Studio", ["Keynote"]), app("com.raycast.macos", "Raycast"),
  app("notion.id", "Notion"), app("com.apple.Notes", "Notes"), app("md.obsidian", "Obsidian"), app("com.apple.Siri", "Siri"),
  app("com.spotify.client", "Spotify"), app("com.apple.iCal", "Calendar"), app("com.apple.Music", "Music"),
];

/** File deletion, trash, uninstalling and shell deletion (EN/DE) that the grammar refuses today. */
const DELETIONS = [
  "empty the trash", "papierkorb leeren", "move pages to the trash", "rm -rf ~/Documents", "delete the zip files", "lösche alle Dateien",
  "uninstall slack", "slack deinstallieren", "trash report.pdf", "erase the disk", "wipe my hard drive", "delete Slack", "lösche Slack",
  "shred secrets.txt", "kannst du den papierkorb leeren", "in den papierkorb verschieben", "Zoom löschen",
];

function hostileStore(): DictionaryStore {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-hostile-"));
  copyFileSync(HOSTILE, join(dir, "dictionary.json"));
  const store = new DictionaryStore({ path: join(dir, "dictionary.json"), clock: () => NOW, log: () => {} });
  store.load();
  return store;
}

function emptyStore(): DictionaryStore {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-hostile-"));
  return new DictionaryStore({ path: join(dir, "dictionary.json"), clock: () => NOW, log: () => {} });
}

async function laneWith(apps: AppRecord[] = APPS, isCommonWord?: (word: string) => boolean): Promise<LearnLane> {
  const cache = new AppIndexCache(async () => ({ version: "1", apps }));
  await cache.refresh();
  const dispatcher = createInstantDispatcher({ apps: cache, scorer: () => null });
  return createLearnLane({ dispatcher, apps: () => apps, ...(isCommonWord ? { isCommonWord } : {}) });
}

/** A take as the voice pipeline would remember it (heard text, offered rows, acted target). */
function take(takeId: string, heard: string, extra: Partial<TakeRecord> = {}): TakeRecord {
  return {
    takeId, at: Date.now(), inputMode: "voice", hypotheses: [{ text: heard, source: "apple-dt/en-US", role: "peer" }], voiceHypotheses: true,
    decision: "list", recognizer: "apple-dt/en-US", offered: [], ...extra,
  };
}

async function learn(store: DictionaryStore, lane: LearnLane, record: TakeRecord, request: Omit<DictionaryLearnRequest, "takeId">): Promise<DictionaryWriteResponse> {
  const memo = new InMemoryTakeMemo();
  memo.remember(record);
  return learnFromGesture({ takeId: record.takeId, ...request }, { store, memo, lane });
}

const nothingStored = (store: DictionaryStore) => DICTIONARY_LISTS.every((list) => store.document()[list].length === 0);

test("hostile.json: the store drops exactly what learn would refuse, keeps the rest, and logs no content", () => {
  const body = JSON.parse(readFileSync(HOSTILE, "utf8"));
  const dir = mkdtempSync(join(tmpdir(), "pi-os-hostile-"));
  copyFileSync(HOSTILE, join(dir, "dictionary.json"));
  const lines: string[] = [];
  const store = new DictionaryStore({ path: join(dir, "dictionary.json"), clock: () => NOW, log: (line) => lines.push(line) });
  const report = store.load();
  assert.equal(report.status, "ok");
  assert.deepEqual(report.issues, body._expect);
  for (const list of DICTIONARY_LISTS) assert.deepEqual(store.document()[list].map((entry) => entry.id), body._kept[list], list);
  assert.equal(store.settings().learn, "picks", "an unknown learn mode falls back to the default");
  const logged = lines.join("\n");
  for (const value of ["trash", "Trash", "papierkorb", "passwd", "dummy", "gute nacht", "frag pi", "ganz laut"]) assert.ok(!logged.includes(value), `log echoes ${value}`);
});

test("hostile.json loaded: no lookup ever yields a deletion phrase or anything beyond openApp / http(s) openURL / volume", () => {
  const store = hostileStore();
  const raw = JSON.parse(readFileSync(HOSTILE, "utf8"));
  const recognizers = ["any", "parakeet-v3", "apple-dt/de-DE", "apple-dt/en-US"];
  for (const recognizer of recognizers) {
    for (const alias of raw.aliases) {
      const match = store.alias(alias.phrase, recognizer);
      if (!match) continue;
      assert.equal(match.ref.id, "a_ok_kept01", `${recognizer}: only the valid alias decides`);
      assert.ok(["openApp", "openURL", "system"].includes(match.value.kind));
    }
    for (const name of raw.appNames) {
      const match = store.appName(name.heard, recognizer);
      if (match) assert.equal(match.ref.id, "n_motion001");
    }
    for (const text of DELETIONS) {
      assert.equal(store.alias(text, recognizer), null, text);
      assert.equal(store.appName(text, recognizer), null, text);
    }
    for (const fix of store.fixes(recognizer)) assert.ok(!/trash|delete|lösch/i.test(`${fix.value.heard} ${fix.value.intended}`));
  }
});

test(`${DELETIONS.length} deletion and trash requests stay refused with the hostile dictionary loaded (voice and typed), and teach nothing`, async () => {
  const supportDir = mkdtempSync(join(tmpdir(), "pi-os-hostile-"));
  const dictionary = hostileStore();
  const before = dictionary.revision();
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "token", agentEnabled: false }, {
    hostClient: fakeHost({ apps: { version: "1", apps: APPS } }) as unknown as HostClient, supportDir, dictionary,
    onInvocation: async () => {}, loadAgentModules: () => new Promise(() => {}),
  });
  const base = `http://127.0.0.1:${await server.listen()}`;
  const headers = { "X-Harness-Token": "token", "Content-Type": "application/json" };
  const post = (path: string, body: unknown) => fetch(base + path, { method: "POST", headers, body: JSON.stringify(body) }).then(async (response) => ({ status: response.status, body: await response.json() as any }));
  try {
    let refusals = 0;
    for (const [index, text] of DELETIONS.entries()) {
      const voice = await post("/instant", {
        text, phase: "final", seq: 1, takeId: `del-${index}`, inputMode: "voice", accept: ["suggest", "check", "confirm"],
        hypotheses: [{ text, source: "parakeet-v3", role: "primary" }, { text: "open pages", source: "apple-dt/en-US", role: "secondary" }],
      });
      const typed = await post("/instant", { text, phase: "final", seq: 1, takeId: `typed-${index}` });
      // Phase A: only the other language's peer heard the deletion; the take is still refused (policy first).
      const peer = await post("/instant", {
        text: "open pages", phase: "final", seq: 1, takeId: `peer-${index}`, inputMode: "voice", accept: ["suggest", "check", "confirm"],
        hypotheses: [{ text: "open pages", source: "apple-dt/en-US", role: "peer", confidence: 0.9 }, { text, source: "apple-dt/de-DE", role: "peer", confidence: 0.2 }],
      });
      assert.equal(peer.body.decision, "refuse", `peer: ${text}`);
      assert.equal(voice.body.decision, "refuse", `voice: ${text}`);
      assert.equal(typed.body.decision, "refuse", `typed: ${text}`);
      refusals++;
      // A refused take offers nothing and acts on nothing: no gesture on it can teach a rule.
      for (const request of [{ kind: "pick", bundleId: "com.apple.finder" }, { kind: "confirm" }, { kind: "confirm", bundleId: "com.apple.Pages" }]) {
        const learned = await post("/dictionary/learn", { takeId: `del-${index}`, ...request });
        assert.equal(learned.status, 200);
        assert.equal(learned.body.status, "refused", `${text} ${request.kind}`);
      }
    }
    assert.equal(refusals, DELETIONS.length);
    assert.ok(refusals >= 15);
    assert.equal(dictionary.revision(), before, "nothing was written");
  } finally {
    await server.close();
  }
});

test("a deletion is never learned: picks, edits and 'No, I meant' with deletion words are refused; Settings refuses them too", async () => {
  const store = emptyStore();
  const lane = await laneWith();
  const refusedAs = async (record: TakeRecord, request: Omit<DictionaryLearnRequest, "takeId">, label: string) => {
    const result = await learn(store, lane, record, request);
    assert.equal(result.status, "refused", label);
    assert.equal(result.code, "refused_phrase", label);
  };
  await refusedAs(take("t1", "Papierkorb leeren", { offered: ["com.apple.finder"] }), { kind: "pick", bundleId: "com.apple.finder" }, "pick on a trash phrase");
  await refusedAs(take("t2", "open trash", { offered: ["com.apple.finder"] }), { kind: "pick", bundleId: "com.apple.finder" }, "pick: trash as a heard app name");
  await refusedAs(take("t3", "pages to the trash", { offered: ["com.apple.Pages"] }), { kind: "pick", bundleId: "com.apple.Pages" }, "pick: a hand-edit style phrase");
  await refusedAs(take("t4", "open pages", { decision: "fallthrough" }), { kind: "edit", correctedText: "move pages to the trash" }, "edit into a deletion");
  await refusedAs(take("t5", "open notes", { decision: "act", acted: { kind: "openApp", bundleId: "com.apple.Notes" } }), { kind: "no_i_meant", correctedText: "empty the trash" }, "no_i_meant a deletion");
  await refusedAs(take("t6", "open notes", { decision: "act", acted: { kind: "openApp", bundleId: "com.apple.Notes" } }), { kind: "no_i_meant", correctedText: "nein, ich meinte Papierkorb leeren" }, "nein, ich meinte …");
  await refusedAs(take("t7", "lösch das", { decision: "fallthrough" }), { kind: "edit", correctedText: "open pages" }, "edit from a deletion");
  // Settings: the strict parser refuses deletion vocabulary, and the edit engine re-checks with the grammar.
  for (const entry of [
    { list: "aliases", phrase: "Empty the trash", target: { kind: "openApp", bundleId: "com.apple.finder" } },
    { list: "terms", text: "Move to Trash" },
    { list: "fixes", heard: "pages", intended: "pages to the trash" },
    { list: "appNames", heard: "papierkorb", bundleId: "com.apple.finder", display: "Finder" },
  ]) {
    const parsed = parseEditRequest({ op: "upsert", entry });
    assert.equal(parsed.ok, false, JSON.stringify(entry));
    if (!parsed.ok) assert.match(parsed.error, /refused/);
  }
  for (const entry of [
    { list: "aliases", phrase: "pages to the trash", target: { kind: "openApp", bundleId: "com.apple.Pages" } },
    { list: "fixes", heard: "pages", intended: "delete everything" },
    { list: "appNames", heard: "trash", bundleId: "com.apple.finder", display: "Finder" },
    { list: "aliases", phrase: "open this", target: { kind: "openApp", bundleId: "com.apple.Pages" } },
  ] as const) {
    const result = applyEdit({ op: "upsert", entry } as DictionaryEditRequest, { store, lane });
    assert.equal(result.status, "refused", JSON.stringify(entry));
    assert.equal(result.code, "refused_phrase");
  }
  assert.ok(nothingStored(store));
  assert.equal(store.revision(), 0);
});

test("deletion phrasings no single word gives away ('throw … away', 'schmeiß … weg', 'in den Müll') are never saved, so they never open an app", async () => {
  const store = emptyStore();
  const lane = await laneWith();
  const phrases = ["throw pages away", "bin the pages app", "schmeiss pages weg", "pages in den mull", "discard pages", "verwirf pages",
    "wirf pages weg", "toss pages out", "put pages in the bin", "pages in die mulltonne"];
  for (const phrase of phrases) {
    const alias = applyEdit({ op: "upsert", entry: { list: "aliases", phrase, target: { kind: "openApp", bundleId: "com.apple.Pages" } } } as DictionaryEditRequest, { store, lane });
    assert.deepEqual([alias.status, alias.code], ["refused", "refused_phrase"], phrase);
    assert.equal(parseEditRequest({ op: "upsert", entry: { list: "aliases", phrase, target: { kind: "openApp", bundleId: "com.apple.Pages" } } }).ok, false, phrase);
    const fix = applyEdit({ op: "upsert", entry: { list: "fixes", heard: "paged", intended: phrase } } as DictionaryEditRequest, { store, lane });
    assert.equal(fix.status, "refused", `fix → ${phrase}`);
    // A confirm of a take that said it teaches nothing either.
    const confirm = await learn(store, lane, take(`t-${phrase.length}-${phrase.charCodeAt(0)}`, phrase, { decision: "act", acted: { kind: "openApp", bundleId: "com.apple.Pages" } }), { kind: "confirm" });
    assert.equal(confirm.status, "refused", `confirm: ${phrase}`);
  }
  assert.ok(nothingStored(store));
  // German "bin" is not the English verb: "Bin ich da" and "bin gleich zurück" stay ordinary words.
  assert.equal(applyEdit({ op: "upsert", entry: { list: "aliases", phrase: "bin gleich zuruck", target: { kind: "openApp", bundleId: "com.apple.Notes" } } } as DictionaryEditRequest, { store, lane }).status, "updated");
});

test("a learned fix never acts beyond the closed targets: a rewrite into a display sleep stays a miss (Settings, Import, Recent takes)", async () => {
  const store = emptyStore();
  const lane = await laneWith();
  for (const [heard, intended] of [["dim it", "screen off"], ["night night", "sleep the display"]]) {
    // A fix is plain words (no command verb, no deletion): every edit client accepts it.
    assert.equal(applyEdit({ op: "upsert", entry: { list: "fixes", heard, intended } } as DictionaryEditRequest, { store, lane }).status, "updated", heard);
  }
  const cache = new AppIndexCache(async () => ({ version: "1", apps: APPS }));
  await cache.refresh();
  const dispatcher = createInstantDispatcher({ apps: cache, scorer: () => null, dictionary: nonCountingLookup(store) });
  for (const text of ["dim it", "please dim it", "night night", "Dim it."]) {
    for (const hypotheses of [[{ text, source: "parakeet-v3", role: "primary" as const }], [{ text, source: "apple-dt/en-US", role: "peer" as const, confidence: 0.9 }]]) {
      const response = await dispatcher.dispatch({ text, phase: "final", seq: 1, inputMode: "voice", hypotheses, accept: ["suggest", "check", "confirm"] });
      assert.notEqual(response.decision, "act", `${text}: ${JSON.stringify(response)}`);
    }
    assert.notEqual((await dispatcher.dispatch({ text, phase: "final", seq: 1 })).decision, "act", `${text} (typed)`);
  }
  // The rewritten words said directly still do what they say: the grammar, not a learned rule.
  const direct = await dispatcher.dispatch({ text: "screen off", phase: "final", seq: 1, inputMode: "voice", hypotheses: [{ text: "screen off", source: "parakeet-v3", role: "primary" }] });
  assert.deepEqual(direct.decision === "act" ? [direct.action, direct.voice?.learnedEntryId] : direct.decision, [{ type: "system", op: "display.sleep" }, undefined]);
});

test("closed targets: file:, javascript:, data:, userinfo URLs, display sleep and file/agent kinds are never learned or applied", async () => {
  for (const target of [
    { kind: "openURL", url: "javascript:alert(1)" }, { kind: "openURL", url: "file:///etc/passwd" }, { kind: "openURL", url: "data:text/html,hi" },
    { kind: "openURL", url: "https://dummy:dummy@example.com/" }, { kind: "openURL", url: `https://example.com/${"x".repeat(600)}` },
    { kind: "system", op: "display.sleep" }, { kind: "system", op: "volume.set", value: 1.5 }, { kind: "deleteFile", token: "tok_12345678" },
    { kind: "askAgent", prompt: "empty the trash" }, { kind: "openFile", token: "tok_12345678" }, { kind: "openApp", bundleId: "../../bin/sh" },
  ]) {
    const parsed = parseEditRequest({ op: "upsert", entry: { list: "aliases", phrase: "meine seite", target } });
    assert.equal(parsed.ok, false, JSON.stringify(target));
  }
  const store = emptyStore();
  const lane = await laneWith();
  assert.equal(await lane.resolve("open file:///etc/passwd", { inputMode: "voice" }), null);
  assert.equal(await lane.resolve("javascript:alert(1)", { inputMode: "text" }), null);
  const unresolved = await learn(store, lane, take("u1", "open my page", { decision: "act", acted: { kind: "openApp", bundleId: "com.apple.Notes" } }),
    { kind: "no_i_meant", correctedText: "file:///etc/passwd" });
  assert.equal(unresolved.status, "refused");
  assert.equal(unresolved.code, "unresolved");
  // An http(s) target learned from a confirm stays exactly that URL.
  const url = await learn(store, lane, take("u2", "open guests dot com", { decision: "act", acted: { kind: "openURL", url: "https://guests.com/" } }), { kind: "confirm" });
  assert.equal(url.status, "learned");
  assert.deepEqual(store.alias("open guests dot com", "apple-dt/en-US")?.value, { kind: "openURL", url: "https://guests.com/" });
});

test("shadowing an installed app's exact name asks first and stays scoped to the recognizer that misheard", async () => {
  const store = emptyStore();
  const lane = await laneWith();
  const siri = take("s1", "open siri", { offered: ["com.spotify.client"], didYouMean: true });
  const asked = await learn(store, lane, siri, { kind: "pick", bundleId: "com.spotify.client" });
  assert.equal(asked.status, "needs_confirmation");
  assert.equal(asked.code, "shadows_app");
  assert.equal(asked.line, "“siri” will open Spotify instead of Siri. Remember?");
  assert.ok(nothingStored(store));
  const learned = await learn(store, lane, siri, { kind: "pick", bundleId: "com.spotify.client", confirmed: true });
  assert.equal(learned.status, "learned");
  const entry = store.document().appNames[0]!;
  assert.deepEqual([entry.heard, entry.bundleId, entry.shadows, entry.recognizer, entry.source], ["siri", "com.spotify.client", "com.apple.Siri", "apple-dt/en-US", "did-you-mean"]);
  assert.equal(store.appName("siri", "apple-dt/en-US")?.value.bundleId, "com.spotify.client");
  assert.equal(store.appName("siri", "parakeet-v3"), null, "other recognizers still open Siri");
  assert.equal(store.appName("siri", "any"), null, "typed input still opens Siri");
  // Settings asks the same way.
  const settings = emptyStore();
  const upsert = { op: "upsert", entry: { list: "appNames", heard: "siri", bundleId: "com.spotify.client", display: "Spotify", recognizer: "apple-dt/en-US" } } as const;
  const ask = applyEdit(upsert, { store: settings, lane });
  assert.equal(ask.status, "needs_confirmation");
  assert.equal(ask.code, "shadows_app");
  const saved = applyEdit({ ...upsert, confirmed: true }, { store: settings, lane });
  assert.equal(saved.status, "updated");
  assert.equal(settings.document().appNames[0]?.shadows, "com.apple.Siri");
});

test("one-word guard: 'Oben', 'Open', 'Bitte', 'Drei', 'Please', 'Okay' never become aliases or app names", async () => {
  const store = emptyStore();
  const lane = await laneWith(APPS, (word) => ["music", "notes", "pages"].includes(word));
  for (const heard of ["Oben", "Open", "Bitte", "Drei.", "Please", "Okay", "Open Oben", "Öffne bitte", "Open the", "xy"]) {
    const result = await learn(store, lane, take(`g-${heard}`, heard, { offered: ["com.apple.iCal"] }), { kind: "pick", bundleId: "com.apple.iCal" });
    assert.equal(result.status, "refused", heard);
    assert.ok(result.code === "alias_guard" || result.code === "refused_phrase", `${heard}: ${result.code}`);
    const confirm = await learn(store, lane, take(`c-${heard}`, heard, { decision: "act", acted: { kind: "openApp", bundleId: "com.apple.iCal" } }), { kind: "confirm" });
    assert.equal(confirm.status, "refused", `${heard} (confirm)`);
  }
  for (const phrase of ["Bitte", "Open", "Drei", "Oben bitte"]) {
    const result = applyEdit({ op: "upsert", entry: { list: "aliases", phrase: phrase.toLowerCase(), target: { kind: "openApp", bundleId: "com.apple.iCal" } } }, { store, lane });
    assert.equal(result.code, "alias_guard", phrase);
  }
  assert.ok(nothingStored(store));
  // A single common word as an app name asks first; two content words learn at once.
  const name = await learn(store, lane, take("m1", "open spotti bitte", { offered: ["com.spotify.client"] }), { kind: "pick", bundleId: "com.spotify.client" });
  assert.equal(name.status, "learned", "a heard name that is neither common nor another app's learns at once");
  assert.equal(store.appName("spotti", "apple-dt/en-US")?.value.bundleId, "com.spotify.client");
  const german = await learn(store, lane, take("m4", "open musik bitte", { offered: ["com.spotify.client"] }), { kind: "pick", bundleId: "com.spotify.client" });
  assert.equal(german.code, "shadows_app", "“musik” is Music's built-in German name");
  const asks = await learn(store, lane, take("m2", "open pages", { offered: ["md.obsidian"] }), { kind: "pick", bundleId: "md.obsidian" });
  assert.equal(asks.status, "needs_confirmation");
  assert.ok(asks.code === "shadows_app" || asks.code === "common_word");
  const sentence = await learn(store, lane, take("m3", "mach musik an", { offered: ["com.apple.Music"] }), { kind: "pick", bundleId: "com.apple.Music" });
  assert.equal(sentence.status, "learned");
  assert.deepEqual(store.alias("Mach Musik an!", "apple-dt/en-US")?.value, { kind: "openApp", bundleId: "com.apple.Music" });
});

test("no generalized verb rewrites: a fix that touches an open or search verb is refused from any edit client (§6.8 #6)", async () => {
  const store = emptyStore();
  const lane = await laneWith();
  for (const [heard, intended] of [
    ["search pages", "open pages"], ["close", "open"], ["suchen", "öffnen"], ["beende safari", "öffne safari"], ["zeig mir", "finde"], ["kalender", "starte kalender"],
  ] as const) {
    const result = applyEdit({ op: "upsert", entry: { list: "fixes", heard, intended } }, { store, lane });
    assert.deepEqual([result.status, result.code], ["refused", "refused_phrase"], `${heard} → ${intended}`);
  }
  assert.ok(nothingStored(store));
  // Word fixes without a command verb still save.
  const fix = applyEdit({ op: "upsert", entry: { list: "fixes", heard: "clod", intended: "Claude" } }, { store, lane });
  assert.ok(fix.status === "learned" || fix.status === "updated", fix.status);
  assert.deepEqual(store.fixes("any").map((match) => match.value.intended), ["Claude"]);
});

test("policy first: words the grammar marks deictic or compound never become a rule, in either direction", async () => {
  const store = emptyStore();
  const lane = await laneWith();
  for (const [heard, request] of [
    ["open this", { kind: "pick", bundleId: "com.apple.Pages" }],
    ["open pages and then delete it", { kind: "pick", bundleId: "com.apple.Pages" }],
    ["open recast", { kind: "edit", correctedText: "open pages and then delete it" }],
    ["open this", { kind: "edit", correctedText: "open Raycast" }],
  ] as const) {
    const result = await learn(store, lane, take(`p-${heard}-${request.kind}`, heard, { offered: ["com.apple.Pages"] }), request);
    assert.equal(result.status, "refused", `${heard} ${request.kind}`);
    assert.equal(result.code, "refused_phrase", `${heard} ${request.kind}`);
  }
  assert.ok(nothingStored(store));
});

test("no agent route: nothing an agent tool runs can reach the dictionary or its routes", () => {
  const src = join(import.meta.dirname, "..", "src");
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (name.endsWith(".ts")) files.push(path);
    }
  };
  for (const dir of ["agent", "browser", "classifier", "ui"]) walk(join(src, dir));
  assert.ok(files.length > 20);
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    // Agent code may use the pure contracts (types, folding, refusal words) but never the store, its
    // write paths or the /dictionary routes.
    assert.ok(!/["'`]\/dictionary|instant\/dictionary|instant\/learned|DictionaryStore|learnFromGesture|applyEdit/.test(text), relative(src, file));
  }
});
