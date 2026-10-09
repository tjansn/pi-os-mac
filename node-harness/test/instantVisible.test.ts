import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { HOST_ACTION_TYPES } from "../src/contracts/actions.js";
import { bindingToHostAction, type CardSpec } from "../src/contracts/cards.js";
import { NO_DICTIONARY } from "../src/contracts/dictionary.js";
import type { InstantRequest, InstantResponse, VoiceHypothesis } from "../src/contracts/instant.js";
import type { AppRecord, FileCandidate, FileSearchRequest, VisibleItem, VisibleItemsResult } from "../src/contracts/launcher.js";
import type { HarnessConfig } from "../src/config.js";
import { HostClient, HostHttpError, LauncherRouteError } from "../src/hostClient.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { createInstantDispatcher, type InstantDispatcherDeps } from "../src/instant/dispatcher.js";
import { createLearnLane, learnFromGesture } from "../src/instant/learned.js";
import { DictionaryStore, nonCountingLookup } from "../src/instant/dictionary.js";
import { InMemoryTakeMemo, offeredBundleIds, takeDetailsOf, takeRecordFor } from "../src/instant/takeMemo.js";
import {
  matchKey, matchVisible, NO_VISIBLE, snapshotOf, VISIBLE, VisibleItemsCache, visibleFailureKind, visibleTarget, type VisibleItemsFetch,
} from "../src/instant/visible.js";
import { validateCard } from "../src/ui/validate.js";
import { captureLogs, fakeHost, start } from "./integrationFixtures.js";
import { fixtureApps, spokenTable } from "../scripts/voice-eval.mjs";

/*
 * Visible-first open resolution (design C; protocol.md "Visible items"): "öffne Radfotos" on the desktop opens
 * the desktop folder before any app, a folder next to an app of the same name is offered with it, a clear
 * sound-alike needs one Return, a missed final open form may offer Spotlight matches, and a host without
 * launcher.visibleItems (HTTP 404, not_found) keeps today's lane exactly. Synthetic names, fixture tokens and
 * paths under /Users/fixture only; no host process, no model, nothing logged.
 */

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = <T>(path: string): T => JSON.parse(readFileSync(join(fixtures, path), "utf8")) as T;
const DESKTOP = readJson<{ result: VisibleItemsResult }>("launcher/visible-items.response-desktop.json").result;
const FINDER_WINDOW = readJson<{ result: VisibleItemsResult }>("launcher/visible-items.response-finder-window.json").result;
const NONE = readJson<{ result: VisibleItemsResult }>("launcher/visible-items.response-none.json").result;
const RADFOTOS = "tok_7c1e0a9f3b2d";
const FOTOS = "tok_2b8d4f6a1c3e";
const ACCEPT: NonNullable<InstantRequest["accept"]> = ["suggest", "check", "confirm"];

const app = (bundleId: string, name: string, aliases: string[] = [], dir = "/Applications"): AppRecord => ({ bundleId, name, aliases, path: `${dir}/${name}.app`, running: false });
/** A German Mac: Photos answers to "Fotos" (CFBundleDisplayName), Notes to "Notizen". */
const APPS: AppRecord[] = [
  app("com.apple.Photos", "Photos", ["Fotos"], "/System/Applications"),
  app("com.apple.Notes", "Notes", ["Notizen"], "/System/Applications"),
  app("com.apple.finder", "Finder", [], "/System/Library/CoreServices"),
  app("com.spotify.client", "Spotify"),
  app("com.apple.Safari", "Safari"),
  app("com.figma.Desktop", "Figma"),
];

/** Visible items for the fixture desktop, a result built from `items`, or a fetch. */
function visibleCache(source: VisibleItemsResult | VisibleItemsFetch = DESKTOP, options: ConstructorParameters<typeof VisibleItemsCache>[1] = {}) {
  const calls: string[] = [];
  const fetch: VisibleItemsFetch = async (request, signal) => {
    calls.push(request.contextId);
    return typeof source === "function" ? source(request, signal) : structuredClone(source);
  };
  return Object.assign(new VisibleItemsCache(fetch, options), { calls });
}

function make(overrides: Partial<InstantDispatcherDeps> = {}) {
  return createInstantDispatcher({
    apps: new AppIndexCache(async () => ({ version: "1", apps: APPS })), localZone: () => "Europe/Berlin", homeDir: "/Users/fixture", ...overrides,
  });
}

const P = (text: string): VoiceHypothesis => ({ text, source: "parakeet-v3", role: "primary" });
const DE = (text: string, confidence = 0.7): VoiceHypothesis => ({ text, source: "apple-dt/de-DE", role: "peer", locale: "de-DE", confidence });
const EN = (text: string, confidence = 0.7): VoiceHypothesis => ({ text, source: "apple-dt/en-US", role: "peer", locale: "en-US", confidence });
const SEC = (text: string, source = "apple-dt/en-US"): VoiceHypothesis => ({ text, source, role: "secondary" });

const final = (hypotheses: VoiceHypothesis[], extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text: hypotheses[0]!.text, phase: "final", seq: 1, inputMode: "voice", hypotheses, accept: ACCEPT, contextId: "ctx-desk", ...extra,
});
const typed = (text: string, extra: Partial<InstantRequest> = {}): InstantRequest => ({ text, phase: "final", seq: 1, contextId: "ctx-desk", ...extra });

type Act = Extract<InstantResponse, { decision: "act" }>;
type List = Extract<InstantResponse, { decision: "list" }>;
const asAct = (response: InstantResponse): Act => {
  assert.equal(response.decision, "act", JSON.stringify(response));
  return response as Act;
};
const asList = (response: InstantResponse): List => {
  assert.equal(response.decision, "list", JSON.stringify(response));
  return response as List;
};
/** Rows of a card: title, subtitle and what the primary binding does (file token or app bundle id). */
const rows = (card: CardSpec) => Object.values(card.elements).flatMap((element) => {
  if (element.type !== "Item" || !element.on?.primary) return [];
  const action = bindingToHostAction(element.on.primary);
  const target = action?.type === "openFile" ? action.token : action?.type === "openApp" ? action.bundleId : action?.type;
  return [{ title: String(element.props.title), subtitle: String(element.props.subtitle ?? ""), target }];
});
/** The response without timing and the advisory scope. */
const wire = (response: InstantResponse) => {
  const copy: Record<string, unknown> = { ...response };
  delete copy.elapsedMs;
  delete copy.scope;
  return copy;
};
const validCard = (card: CardSpec | undefined): boolean => !!card && validateCard(card, { mode: "strict", allowedActions: HOST_ACTION_TYPES }).ok;
const opensItem = (response: InstantResponse, token = RADFOTOS): void => {
  const act = asAct(response);
  assert.equal(act.intent, "open_item");
  assert.deepEqual(act.action, { type: "openFile", token });
  assert.equal(act.confirm, false, "an exact visible item opens at once");
  assert.ok(validCard(act.card));
};

const item = (token: string, name: string, path: string, extra: Partial<VisibleItem> = {}): VisibleItem => ({
  token, name, path, isDirectory: true, isPackage: false, contentType: "public.folder", source: "desktop", ...extra,
});
const result = (items: VisibleItem[], sources: VisibleItemsResult["sources"] = [{ kind: "desktop", via: "ax", complete: true }]): VisibleItemsResult => ({
  sources, items, truncated: false, elapsedMs: 1,
});

// ---------------------------------------------------------------- matching keys and targets

test("matching keys: fold, no diacritics, ß → ss, no extension, no non-alphanumerics; folder/file nouns and places are not the name", () => {
  for (const name of ["Radfotos", "Rad Fotos", "Rad-Fotos", "rad_fotos", "RAD.FOTOS"]) assert.equal(matchKey(name), "radfotos", name);
  assert.equal(matchKey("Präsentation Straße"), "prasentationstrasse");
  const snap = snapshotOf(DESKTOP);
  assert.deepEqual(snap.entries.map((entry) => entry.key), ["radfotos", "fotos", "radtour2026", "prasentation", "notizen"]);
  assert.deepEqual(snap.entries.map((entry) => entry.parent), ["Desktop", "Desktop", "Desktop", "Desktop", "Desktop"]);
  assert.equal(snap.entries.find((entry) => entry.key === "prasentation")?.folder, false, "a package is a document");

  const cases: [string, string, string | undefined][] = [
    ["radfotos", "radfotos", undefined], ["rad fotos", "radfotos", undefined], ["rad-fotos", "radfotos", undefined],
    ["ordner radfotos", "radfotos", "folder"], ["radfotos folder", "radfotos", "folder"], ["the folder radfotos", "radfotos", "folder"],
    ["my radfotos folder", "radfotos", "folder"], ["den ordner namens radfotos", "radfotos", "folder"], ["datei notizen.txt", "notizen", "file"],
    ["radfotos on the desktop", "radfotos", undefined], ["radfotos auf dem schreibtisch", "radfotos", undefined], ["Radfotos’s", "radfotos", undefined],
  ];
  for (const [raw, key, kind] of cases) {
    const target = visibleTarget(raw);
    assert.equal(target?.key, key, raw);
    assert.equal(target?.kind, kind, raw);
  }
  assert.equal(visibleTarget("notizen.txt")?.fullKey, "notizentxt");
  // A name that starts with a dropped word still matches as said ("Mein Ordner", "My Photos").
  const named = snapshotOf(result([item("tok_nnnnnnnnnnnn", "Mein Ordner", "/Users/fixture/Desktop/Mein Ordner"), item("tok_oooooooooooo", "My Photos", "/Users/fixture/Desktop/My Photos")]));
  assert.deepEqual(matchVisible(named, visibleTarget("mein ordner")!).map((m) => [m.entry.item.token, m.exact]), [["tok_nnnnnnnnnnnn", true]]);
  assert.deepEqual(matchVisible(named, visibleTarget("my photos")!).map((m) => [m.entry.item.token, m.exact]), [["tok_oooooooooooo", true]]);
  assert.equal(visibleTarget("ordner")?.key, "ordner", "a noun alone is the name (a folder may be called that)");
  assert.equal(visibleTarget("   "), null);
  // "the Radfotos folder" matches folders only; "die Datei Notizen" documents only.
  const folderOnly = matchVisible(snap, visibleTarget("datei fotos")!);
  assert.deepEqual(folderOnly, []);
  assert.deepEqual(matchVisible(snap, visibleTarget("ordner fotos")!).map((m) => m.entry.item.token), [FOTOS]);
});

// ---------------------------------------------------------------- the desktop folder opens at once

test("Radfotos on the desktop opens at once: DT dual, split \"Rad Fotos\", Parakeet, typed, \"den Ordner\", verb-final, the folder noun, a bare name", async () => {
  const visible = visibleCache();
  const d = make({ visibleItems: visible });
  const takes: [string, InstantRequest][] = [
    ["DT dual (both German)", final([DE("Öffne Radfotos."), EN("Öffne Radfotos.", 0.3)])],
    ["DT dual (en-US hears English)", final([EN("Open Radfotos."), DE("Öffne Radfotos.")])],
    ["split", final([DE("Öffne Rad Fotos."), EN("Open rad photos.", 0.5)])],
    ["split, hyphen", final([DE("Öffne Rad-Fotos.")])],
    ["Parakeet + secondaries", final([P("Öffne Radfotos."), SEC("Öffne Rad Fotos.", "apple-dt/de-DE"), SEC("Open rat photos.")])],
    ["Parakeet alone", final([P("Öffne Rad Fotos.")])],
    ["den Ordner", final([DE("Öffne den Ordner Radfotos.")])],
    ["the folder", final([EN("Open the Radfotos folder.")])],
    ["verb-final", final([DE("Radfotos öffnen.")])],
    ["polite wrapper", final([DE("Kannst du bitte Radfotos öffnen?")])],
    ["weak verb, exact", final([DE("Zeig mir Radfotos.")])],
    ["bare name", final([DE("Radfotos.")])],
    ["older host (text only)", { text: "Öffne Radfotos.", phase: "final", seq: 1, inputMode: "voice", contextId: "ctx-desk" }],
    ["typed", typed("open radfotos")],
    ["typed German", typed("öffne den Ordner Radfotos")],
    ["typed hyphen", typed("Öffne Rad-Fotos")],
  ];
  for (const [label, request] of takes) {
    const response = await d.dispatch(request);
    assert.doesNotThrow(() => opensItem(response), label);
    const act = asAct(response);
    assert.equal(act.title, "Open Radfotos", label);
    assert.deepEqual(rows(act.card!), [{ title: "Radfotos", subtitle: "in Desktop", target: RADFOTOS }], label);
    if (request.inputMode === "voice") assert.equal(act.voice?.via, "visible", label);
    else assert.equal(act.voice, undefined, `${label}: typed decisions carry no voice meta`);
  }
  assert.deepEqual([...new Set(visible.calls)], ["ctx-desk"]);
  assert.equal(visible.calls.length, 1, "one host fetch per context while it is fresh");
});

test("shared fixtures: the open_item act and the folder/app did-you-mean reproduce byte for byte", async () => {
  const d = make({ visibleItems: visibleCache() });
  const act = readJson<InstantResponse>("instant/act-open-visible.json");
  assert.deepEqual(wire(await d.dispatch(final([DE("Öffne Radfotos.")], { seq: 5 }))), wire(act));
  const list = readJson<InstantResponse>("instant/list-did-you-mean-visible.json");
  assert.deepEqual(wire(await d.dispatch(final([DE("Öffne Fotos.")], { seq: 6 }))), wire(list));
  assert.ok(validCard((act as Act).card) && validCard((list as List).card));
});

// ---------------------------------------------------------------- collisions, several items, sound-alikes

test("an exact app next to an exact visible item: \"Did you mean…\" with both, the item first; several exact items list, the Finder window first", async () => {
  const d = make({ visibleItems: visibleCache() });
  // The desktop's "Notizen.txt" is a file: Notes (German "Notizen") is said by its exact name and opens (integration rule).
  asAct(await d.dispatch(final([DE("Öffne Notizen.")])));
  for (const request of [final([DE("Öffne Fotos.")]), final([EN("Open Fotos."), DE("Öffne Fotos.")])]) {
    const list = asList(await d.dispatch(request));
    assert.equal(list.intent, "open_item");
    assert.equal(list.title, "Did you mean…");
    assert.equal(list.voice?.didYouMean, true);
    assert.equal(list.voice?.via, "visible");
    const [first, second] = rows(list.card);
    assert.equal(first?.subtitle, "in Desktop", "the visible row first");
    assert.ok(second?.target?.startsWith("com.apple."), "then the app");
    assert.ok(validCard(list.card));
  }
  // Typed: the same rows as a plain list (no voice meta).
  const typedList = asList(await d.dispatch(typed("open fotos")));
  assert.equal(typedList.intent, "open_item");
  assert.deepEqual(rows(typedList.card).map((row) => row.target), [FOTOS, "com.apple.Photos"]);
  assert.equal(typedList.voice, undefined);

  // Two "Radfotos" on the desktop (a folder and an archive): a list, never a guess.
  const twins = make({ visibleItems: visibleCache(result([
    item(RADFOTOS, "Radfotos", "/Users/fixture/Desktop/Radfotos"),
    item("tok_aaaaaaaaaaaa", "Radfotos.zip", "/Users/fixture/Desktop/Radfotos.zip", { isDirectory: false, contentType: "public.zip-archive" }),
  ])) });
  const both = asList(await twins.dispatch(final([DE("Öffne Radfotos.")])));
  assert.deepEqual(rows(both.card).map((row) => row.target), [RADFOTOS, "tok_aaaaaaaaaaaa"]);
  assert.equal(both.voice?.didYouMean, true);
  // "den Ordner Radfotos" names the folder: it opens.
  opensItem(await twins.dispatch(final([DE("Öffne den Ordner Radfotos.")])));

  // The target Finder window's item wins over a desktop icon of the same name.
  const mixed = make({ visibleItems: visibleCache(result([
    item(RADFOTOS, "Radfotos", "/Users/fixture/Desktop/Radfotos"),
    item("tok_bbbbbbbbbbbb", "Radfotos", "/Users/fixture/Pictures/Radfotos", { source: "finderWindow" }),
  ], [{ kind: "desktop", via: "ax", complete: true }, { kind: "finderWindow", via: "ax", complete: true }])) });
  opensItem(await mixed.dispatch(final([DE("Öffne Radfotos.")])), "tok_bbbbbbbbbbbb");
});

test("integration: an exact app beats a file of the same name (an installer on the desktop); a folder named like the app still asks", async () => {
  const d = make({ visibleItems: visibleCache(result([
    item("tok_cccccccccccc", "Spotify.dmg", "/Users/fixture/Desktop/Spotify.dmg", { isDirectory: false, contentType: "com.apple.disk-image-udif" }),
    item("tok_dddddddddddd", "Figma", "/Users/fixture/Desktop/Figma"),
  ])) });
  for (const request of [final([DE("Öffne Spotify.")]), typed("open spotify")]) {
    const act = asAct(await d.dispatch(request));
    assert.deepEqual([act.intent, act.action], ["open_app", { type: "openApp", bundleId: "com.spotify.client" }]);
  }
  const list = asList(await d.dispatch(final([DE("Öffne Figma.")])));
  assert.deepEqual(rows(list.card).map((row) => row.target), ["tok_dddddddddddd", "com.figma.Desktop"]);
});

test("integration: a host answer that is still reading (complete:false) is kept only briefly, so the final asks again", async () => {
  let now = 0;
  const reading = result([], [{ kind: "desktop", via: "ax", complete: false }]);
  let answer = reading;
  const cache = visibleCache(async () => structuredClone(answer), { clock: () => now });
  const signal = new AbortController().signal;
  assert.equal((await cache.get("ctx-desk", signal)).entries.length, 0);
  answer = DESKTOP;
  now = VISIBLE.failureTtlMs + 1;
  assert.ok((await cache.get("ctx-desk", signal)).entries.length > 0, "fetched again after the short ttl");
  assert.equal(cache.calls.length, 2);
  now += 1_000;
  await cache.get("ctx-desk", signal);
  assert.equal(cache.calls.length, 2, "a complete answer is kept for the full ttl");
});

test("a visible sound-alike: one Return for hosts that accept confirm, else a one-row did-you-mean; weak forms only offer; a bare name never sounds alike", async () => {
  const d = make({ visibleItems: visibleCache() });
  const held = asAct(await d.dispatch(final([EN("Open rad photos.")])));
  assert.equal(held.intent, "open_item");
  assert.deepEqual(held.action, { type: "openFile", token: RADFOTOS });
  assert.equal(held.confirm, true, "a sound-alike needs one Return");
  assert.equal(held.voice?.via, "visible");
  // Typed "open radfoto" (one letter short) is a sound-alike too.
  assert.equal(asList(await d.dispatch(typed("open radfoto"))).title, "Did you mean Radfotos?");

  // A host without "confirm": the same item as "Did you mean Radfotos?".
  const older = asList(await d.dispatch(final([EN("Open rad photos.")], { accept: ["suggest"] })));
  assert.equal(older.title, "Did you mean Radfotos?");
  assert.equal(older.voice?.didYouMean, true);
  assert.deepEqual(rows(older.card).map((row) => row.target), [RADFOTOS]);

  // Below the act threshold: offered ("radfoto", "rat photos").
  for (const text of ["Öffne Radfoto.", "Open rat photos."]) {
    const offered = asList(await d.dispatch(final([text.startsWith("Open") ? EN(text) : DE(text)])));
    assert.equal(offered.title, "Did you mean Radfotos?", text);
  }
  // Weak verbs: offered, never acted; a bare sound-alike is no visible match at all.
  // ("Show me rad photos" is a photo search, not an open form.)
  assert.equal(asList(await d.dispatch(final([EN("Focus rad photos.")]))).voice?.didYouMean, true);
  const bare = await d.dispatch(final([EN("Rad photos.")]));
  assert.notEqual(bare.decision, "act");
  assert.ok(!JSON.stringify(bare).includes(RADFOTOS), "a bare name matches visible items exactly or not at all");

  // Agreeing peers: the exact one acts at once even when the host picked the sound-alike.
  opensItem(await d.dispatch(final([EN("Open rad photos."), DE("Öffne Radfotos.")])));
});

test("\"Öffne Fotos\" with only a desktop folder \"Radfotos\" still opens Photos; app acts beat visible sound-alikes; partial names never act", async () => {
  const d = make({ visibleItems: visibleCache(result([item(RADFOTOS, "Radfotos", "/Users/fixture/Desktop/Radfotos")])) });
  for (const request of [final([DE("Öffne Fotos.")]), final([EN("Open Photos.")]), final([P("Öffne Fotos.")]), typed("öffne fotos"), typed("open photos")]) {
    const act = asAct(await d.dispatch(request));
    assert.deepEqual(act.action, { type: "openApp", bundleId: "com.apple.Photos" }, request.text);
    assert.equal(act.intent, "open_app");
    assert.ok(!JSON.stringify(act).includes(RADFOTOS), `${request.text}: no visible row`);
  }
  // A longer visible name is never the target of a prefix of it.
  for (const text of ["Öffne Rad.", "Öffne Rad Tour."]) {
    const response = await d.dispatch(final([DE(text)]));
    assert.notEqual(response.decision, "act", text);
  }
  // Spotify opens as today.
  assert.deepEqual(asAct(await d.dispatch(final([DE("Öffne Spotify.")]))).action, { type: "openApp", bundleId: "com.spotify.client" });
});

test("review: a bare common word or short name is offered, an Applications window's bundle is the app itself, possessives and \"auf dem Desktop\" match exactly", async () => {
  const d = make({ visibleItems: visibleCache(result([
    item("tok_rv0000000001", "Bilder", "/Users/fixture/Desktop/Bilder"),
    item("tok_rv0000000002", "Neu", "/Users/fixture/Desktop/Neu"),
    item("tok_rv0000000003", "Rechnung.pdf", "/Users/fixture/Desktop/Rechnung.pdf", { isDirectory: false, contentType: "com.adobe.pdf" }),
    item("tok_rv0000000004", "Tom's Fotos", "/Users/fixture/Desktop/Tom's Fotos"),
    item(RADFOTOS, "Radfotos", "/Users/fixture/Desktop/Radfotos"),
  ])) });
  // A name said alone opens only when it is unmistakably a name (the app rule): a dictionary word or < 4 letters is offered.
  for (const [text, token] of [["Bilder.", "tok_rv0000000001"], ["Neu.", "tok_rv0000000002"], ["Rechnung.", "tok_rv0000000003"]] as const) {
    const offered = asList(await d.dispatch(final([DE(text)])));
    assert.equal(offered.intent, "open_item", text);
    assert.equal(offered.voice?.didYouMean, true, text);
    assert.deepEqual(rows(offered.card).map((row) => row.target), [token], text);
  }
  opensItem(await d.dispatch(final([DE("Radfotos.")])), RADFOTOS);
  // With an open verb the same names open at once.
  opensItem(await d.dispatch(final([DE("Öffne Bilder.")])), "tok_rv0000000001");
  opensItem(await d.dispatch(final([DE("Öffne Neu.")])), "tok_rv0000000002");
  // A folder called "Tom's Fotos": the possessive is part of its name (as said, curly, without the apostrophe, typed).
  for (const request of [final([DE("Öffne Tom's Fotos.")]), final([EN("Open Tom’s Fotos.")]), final([DE("Öffne Toms Fotos.")]), typed("open tom's fotos")]) {
    opensItem(await d.dispatch(request), "tok_rv0000000004");
  }
  assert.equal(visibleTarget("radfotos’s")?.key, "radfotos");
  // "auf dem Desktop" is a place, "Radfotos-Ordner" a folder noun.
  for (const text of ["Öffne Radfotos auf dem Desktop.", "Öffne Radfotos vom Desktop.", "Öffne den Radfotos-Ordner.", "Radfotos-Ordner öffnen."]) {
    opensItem(await d.dispatch(final([DE(text)])), RADFOTOS);
  }
  assert.deepEqual([visibleTarget("radfotos-ordner")?.key, visibleTarget("radfotos-ordner")?.kind], ["radfotos", "folder"]);
  // Deletion of such a name stays refused.
  for (const request of [final([DE("Lösche Tom's Fotos.")]), final([DE("Lösche Radfotos auf dem Desktop.")]), typed("lösche den Radfotos-Ordner")]) {
    assert.equal((await d.dispatch(request)).decision, "refuse", request.text);
  }

  // The target is a Finder window of /Applications: "Safari.app" there is the indexed Safari, so the app opens as
  // today (no "Did you mean…" offering the same app twice); an unindexed bundle is still a visible item.
  const applications = make({ visibleItems: visibleCache(result([
    item("tok_rv0000000005", "Safari.app", "/Applications/Safari.app", { isPackage: true, contentType: "com.apple.application-bundle", source: "finderWindow" }),
    item("tok_rv0000000006", "Spotify.app", "/Applications/Spotify.app", { isPackage: true, contentType: "com.apple.application-bundle", source: "finderWindow" }),
    item("tok_rv0000000007", "Photos.app", "/System/Applications/Photos.app", { isPackage: true, contentType: "com.apple.application-bundle", source: "finderWindow" }),
    item("tok_rv0000000008", "Tool.app", "/Applications/Tool.app", { isPackage: true, contentType: "com.apple.application-bundle", source: "finderWindow" }),
  ], [{ kind: "finderWindow", via: "ax", complete: true }])) });
  for (const [request, bundleId] of [
    [final([EN("Open Safari.")]), "com.apple.Safari"], [final([DE("Öffne Spotify.")]), "com.spotify.client"], [final([DE("Öffne Fotos.")]), "com.apple.Photos"],
    [typed("open spotify"), "com.spotify.client"], [typed("open safari"), "com.apple.Safari"],
  ] as const) {
    const act = asAct(await applications.dispatch(request));
    assert.deepEqual(act.action, { type: "openApp", bundleId }, request.text);
    assert.ok(!JSON.stringify(act).includes("tok_rv"), `${request.text}: no file row for the app's own bundle`);
  }
  opensItem(await applications.dispatch(final([EN("Open Tool.")])), "tok_rv0000000008");
});

// ---------------------------------------------------------------- policy first

test("deletion stays refused and is never a visible act: \"lösche Radfotos\", trash phrases, compounds, deixis", async () => {
  const d = make({ visibleItems: visibleCache() });
  for (const request of [
    final([DE("Lösche Radfotos.")]), final([DE("Radfotos löschen.")]), final([EN("Delete Radfotos.")]), final([DE("Lösche den Ordner Radfotos.")]),
    final([EN("Move Radfotos to the trash.")]), final([DE("Öffne Radfotos."), EN("Delete Radfotos.")]),
    typed("lösche Radfotos"), typed("delete radfotos"),
    { ...typed("lösche Radfotos"), phase: "typing" }, { text: "Lösche Radfotos", phase: "partial", seq: 1, inputMode: "voice", contextId: "ctx-desk" },
  ] as InstantRequest[]) {
    const response = await d.dispatch(request);
    if (request.phase === "final") assert.equal(response.decision, "refuse", `${request.text}: ${JSON.stringify(wire(response))}`);
    assert.notEqual(response.decision, "act", request.text);
  }
  // Warm cache: previews refuse too.
  assert.equal((await d.dispatch({ ...typed("lösche Radfotos"), phase: "typing" })).decision, "refuse");
  // Without visible items "lösche Radfotos" is what it was: no refusal, no act (the agent decides).
  const before = await make().dispatch(final([DE("Lösche Radfotos.")]));
  assert.equal(before.decision, "fallthrough");
  // Compound and deixis go to the agent whole.
  for (const text of ["Öffne Radfotos und dann Safari.", "Öffne das hier."]) {
    const response = await d.dispatch(final([DE(text)]));
    assert.equal(response.decision, "fallthrough", text);
  }
});

// ---------------------------------------------------------------- previews

test("partials and typing only preview a visible item; a cold cache never makes a preview wait, it warms the next one", async () => {
  let release: (() => void) | undefined;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const visible = visibleCache(async () => { await gate; return structuredClone(DESKTOP); });
  const d = make({ visibleItems: visible });
  const partial = (text: string): InstantRequest => ({ text, phase: "partial", seq: 1, inputMode: "voice", contextId: "ctx-desk" });
  const started = performance.now();
  const cold = await d.dispatch(partial("Öffne Radfotos"));
  assert.ok(performance.now() - started < 100, "a preview never waits for the host");
  assert.notEqual(cold.decision, "act");
  assert.deepEqual(visible.calls, ["ctx-desk"], "the preview started the fetch");
  release!();
  await new Promise((resolve) => setTimeout(resolve, 5));
  for (const request of [partial("Öffne Radfotos"), partial("Radfotos öffnen"), { ...typed("open radfotos"), phase: "typing" } as InstantRequest]) {
    const preview = asList(await d.dispatch(request));
    assert.equal(preview.intent, "open_item");
    assert.equal(preview.title, "Open Radfotos");
    assert.deepEqual(rows(preview.card).map((row) => row.target), [RADFOTOS]);
  }
  assert.equal(visible.calls.length, 1);
  // A partial never acts on a sound-alike either.
  assert.notEqual((await d.dispatch(partial("Open rad photos"))).decision, "act");
});

// ---------------------------------------------------------------- the Spotlight did-you-mean (step 4)

function spotlight(items: FileCandidate[]) {
  const requests: FileSearchRequest[] = [];
  const searchFiles = async (request: FileSearchRequest) => {
    requests.push(structuredClone(request));
    return { items: structuredClone(items), truncated: false, elapsedMs: 3 };
  };
  return { requests, searchFiles };
}
const found = (token: string, name: string, path: string, extra: Partial<FileCandidate> = {}): FileCandidate => ({
  token, name, path, isDirectory: true, isPackage: false, contentType: "public.folder", ...extra,
});
const HOME_HITS: FileCandidate[] = [
  found("tok_cccccccccccc", "Radfotos 2025", "/Users/fixture/Pictures/Radfotos 2025", { lastUsedMs: 2 }),
  found("tok_dddddddddddd", "Radfotos", "/Users/fixture/Desktop/Radfotos"),
  found("tok_eeeeeeeeeeee", "Radfotos", "/Users/fixture/Library/Caches/Radfotos"),
  found("tok_ffffffffffff", "Radfotos", "/Users/fixture/.Trash/Radfotos"),
  found("tok_gggggggggggg", "Rad.pdf", "/Users/fixture/Documents/Rad.pdf", { isDirectory: false, contentType: "com.adobe.pdf" }),
  found("tok_hhhhhhhhhhhh", "Meine Radfotos", "/Users/fixture/Documents/Meine Radfotos"),
];

test("an open-form miss on a final: Spotlight did-you-mean (≤ 3, never an act, \"in Desktop\"), only for hosts that serve visible items", async () => {
  const search = spotlight(HOME_HITS);
  // The take's target is not the desktop (no sources): nothing visible, so step 4 runs on the final.
  const d = make({ visibleItems: visibleCache(NONE), searchFiles: search.searchFiles });
  const list = asList(await d.dispatch(final([DE("Öffne Radfotos.")])));
  assert.equal(list.intent, "open_item");
  assert.equal(list.title, "Did you mean…");
  assert.deepEqual(rows(list.card), [
    { title: "Radfotos", subtitle: "in Desktop", target: "tok_dddddddddddd" },
    { title: "Radfotos 2025", subtitle: "in Pictures", target: "tok_cccccccccccc" },
  ], "exact first; hidden, Library and non-prefix names are left out");
  assert.deepEqual(list.voice, { heard: "radfotos", source: "apple-dt/de-DE", didYouMean: true });
  assert.ok(validCard(list.card));
  assert.ok(!JSON.stringify(list).includes("/Users/fixture"), "rows carry tokens and folder names, never paths");
  assert.deepEqual(search.requests.at(-1), { contextId: "ctx-desk", nameGroups: [["radfotos"]], scopes: ["home"], maxResults: 50 });

  // The split name searches the joined word and both words; typed finals list without voice meta.
  await d.dispatch(final([DE("Öffne Rad Fotos.")]));
  assert.deepEqual(search.requests.at(-1)?.nameGroups, [["radfotos"], ["rad", "fotos"]]);
  const typedList = asList(await d.dispatch(typed("open radfotos")));
  assert.equal(typedList.voice, undefined);
  assert.equal(rows(typedList.card)[0]?.target, "tok_dddddddddddd");

  // One exact hit: "Did you mean Radfotos?".
  const one = make({ visibleItems: visibleCache(NONE), searchFiles: spotlight([HOME_HITS[1]!]).searchFiles });
  assert.equal(asList(await one.dispatch(final([DE("Öffne Radfotos.")]))).title, "Did you mean Radfotos?");

  // Never on previews, weak or bare forms, an app or visible match, or a policy miss.
  const before = search.requests.length;
  for (const request of [
    { text: "Öffne Radfotos", phase: "partial", seq: 1, inputMode: "voice", contextId: "ctx-desk" }, { ...typed("open radfotos"), phase: "typing" },
    final([DE("Zeig mir Radfotos.")]), final([DE("Radfotos.")]), final([DE("Öffne Radfotos und dann Safari.")]),
  ] as InstantRequest[]) {
    const response = await d.dispatch(request);
    assert.notEqual(response.decision, "act", request.text);
  }
  assert.deepEqual(asAct(await d.dispatch(final([DE("Öffne Spotify.")]))).action, { type: "openApp", bundleId: "com.spotify.client" });
  assert.equal(search.requests.length, before, "no Spotlight call outside a final strong open-form miss");
});

test("nothing found, or a host without visible items: today's fallthrough exactly (check gate and agent alike)", async () => {
  const empty = spotlight([found("tok_iiiiiiiiiiii", "Urlaub", "/Users/fixture/Pictures/Urlaub")]);
  const today = make({ searchFiles: empty.searchFiles });
  const withVisible = make({ visibleItems: visibleCache(NONE), searchFiles: empty.searchFiles });
  const takes: InstantRequest[] = [
    final([DE("Öffne Radfotos.")]),
    final([DE("Öffne Radfotos.", 0.3), EN("Open rad photos.", 0.3)]),
    final([DE("Öffne Radfotos.", 0.3)], { hypotheses: [{ ...DE("Öffne Radfotos.", 0.3), minConfidence: 0.1 }] }),
    final([DE("Öffne Radfotos.")], { accept: [] }),
    typed("open radfotos"),
  ];
  for (const request of takes) {
    const expected = await today.dispatch(request);
    assert.equal(expected.decision, "fallthrough");
    assert.deepEqual(wire(await withVisible.dispatch(request)), wire(expected), request.text);
  }
  assert.ok(empty.requests.length > 0, "the search ran and found nothing usable");
});

test("an older host (HTTP 404) or the Windows host (not_found): remembered as unsupported, and every decision is today's", async () => {
  for (const failure of [new HostHttpError(404, "launcher.visibleItems"), new LauncherRouteError("unsupported"), new LauncherRouteError("not_found")]) {
    const visible = visibleCache(async () => { throw failure; });
    const search = spotlight(HOME_HITS);
    const older = make({ visibleItems: visible, searchFiles: search.searchFiles });
    const today = make({ searchFiles: search.searchFiles });
    const takes: InstantRequest[] = [
      final([DE("Öffne Radfotos.")]), final([DE("Öffne Fotos.")]), final([EN("Open rad photos.")]), final([DE("Radfotos.")]), final([DE("Lösche Radfotos.")]),
      typed("open radfotos"), typed("open fotos"), { ...typed("open radfotos"), phase: "typing" }, final([DE("Öffne Spotify.")], { contextId: "ctx-other" }),
    ];
    for (const request of takes) assert.deepEqual(wire(await older.dispatch(request)), wire(await today.dispatch(request)), `${failure.message}: ${request.text}`);
    assert.equal(visible.calls.length, 1, "asked once, then remembered for the host");
    assert.equal(visible.unsupported, true);
    assert.equal(search.requests.length, 0, "no Spotlight did-you-mean for a host that cannot show file rows");
  }
});

// ---------------------------------------------------------------- the cache and the host client

test("VisibleItemsCache: one fetch per context within 3 s, shared in flight, failures are \"no visible items\", 404 remembered per host", async () => {
  let now = 1_000;
  const clock = () => now;
  const ok = visibleCache(DESKTOP, { clock });
  const never = new AbortController().signal;
  const [a, b] = await Promise.all([ok.get("ctx-1", never), ok.get("ctx-1", never)]);
  assert.equal(a, b);
  assert.equal(a.entries.length, 5);
  assert.equal(ok.calls.length, 1, "in-flight fetch shared");
  now += VISIBLE.ttlMs - 1;
  assert.ok(ok.peek("ctx-1"));
  now += 1;
  assert.equal(ok.peek("ctx-1"), undefined, "≤ 3 s");
  await ok.get("ctx-1", never);
  await ok.get("ctx-2", never);
  assert.deepEqual(ok.calls, ["ctx-1", "ctx-1", "ctx-2"]);

  // A waiting caller gives up on its own signal; the fetch still fills the cache.
  let release: (() => void) | undefined;
  const slow = visibleCache(async () => { await new Promise<void>((resolve) => { release = resolve; }); return structuredClone(DESKTOP); }, { clock });
  const controller = new AbortController();
  const waiting = slow.get("ctx-slow", controller.signal);
  controller.abort();
  assert.equal(await waiting, NO_VISIBLE);
  release!();
  await new Promise((resolve) => setTimeout(resolve, 1));
  assert.equal(slow.peek("ctx-slow")?.entries.length, 5);

  // Transient failures (busy, unknown_context, transport): nothing visible for this context for 0.5 s, then asked again.
  const flaky = visibleCache(async () => { throw new LauncherRouteError("unknown_context"); }, { clock });
  assert.equal(await flaky.get("ctx-1", never), NO_VISIBLE);
  assert.equal(await flaky.get("ctx-1", never), NO_VISIBLE);
  assert.equal(flaky.calls.length, 1);
  now += VISIBLE.failureTtlMs;
  await flaky.get("ctx-1", never);
  assert.equal(flaky.calls.length, 2);
  assert.equal(flaky.unsupported, false);
  // A malformed result is discarded whole (the route exists, so the Spotlight step stays possible).
  const bad = visibleCache({ ...DESKTOP, items: [{ ...DESKTOP.items[0]!, path: "relative/path" }] } as VisibleItemsResult, { clock });
  const discarded = await bad.get("ctx-1", never);
  assert.deepEqual([discarded.supported, discarded.entries.length], [true, 0]);

  // Unsupported: remembered for the host (every context), then asked again after the memo expires.
  const gone = visibleCache(async () => { throw new HostHttpError(404, "launcher.visibleItems"); }, { clock });
  await gone.get("ctx-1", never);
  await gone.get("ctx-2", never);
  gone.prefetch("ctx-3");
  assert.equal(gone.calls.length, 1);
  now += VISIBLE.unsupportedTtlMs;
  await gone.get("ctx-4", never);
  assert.equal(gone.calls.length, 2);
  assert.deepEqual(["unsupported", "unsupported", "unsupported", "invalid", "transient"],
    [{ status: 404 }, { code: "not_found" }, { code: "unsupported" }, { code: "invalid_result" }, new Error("x")].map(visibleFailureKind));

  // Bounded: at most VISIBLE.maxContexts contexts are kept.
  const many = visibleCache(DESKTOP, { clock });
  for (let i = 0; i < VISIBLE.maxContexts + 5; i++) await many.get(`ctx-${i}`, never);
  assert.equal(many.peek("ctx-0"), undefined);
  assert.ok(many.peek(`ctx-${VISIBLE.maxContexts + 4}`));
});

async function hostServer(handler: (body: any) => { status: number; body: unknown }) {
  const seen: any[] = [];
  const server: Server = createServer((request, response) => {
    let raw = "";
    request.on("data", (chunk) => { raw += chunk; });
    request.on("end", () => {
      const body = JSON.parse(raw || "{}");
      seen.push({ url: request.url, token: request.headers["x-harness-token"], body });
      const answer = handler(body);
      response.writeHead(answer.status, { "Content-Type": "application/json" });
      response.end(JSON.stringify(answer.body));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  const client = new HostClient({ hostBaseUrl: `http://127.0.0.1:${port}`, hostToken: "fixture-token" } as HarnessConfig);
  return { client, seen, close: () => new Promise<void>((resolve) => server.close(() => resolve())) };
}

test("HostClient.visibleItems: token-authed POST, strict parse, 404 and not_found → unsupported, a bad item → invalid_result", async () => {
  const cases: [string, { status: number; body: unknown }, string | undefined][] = [
    ["ok", { status: 200, body: { ok: true, result: DESKTOP } }, undefined],
    ["older Mac host", { status: 404, body: { ok: false, error: { code: "not_found", message: "Unknown launcher route" } } }, "unsupported"],
    ["Windows host", { status: 200, body: readJson("launcher/visible-items.response-not-found.json") }, "unsupported"],
    ["refusal", { status: 200, body: { ok: false, error: { code: "busy", message: "x" } } }, "busy"],
    ["malformed", { status: 200, body: { ok: true, result: { ...DESKTOP, items: [{ ...DESKTOP.items[0], token: "x" }] } } }, "invalid_result"],
    ["server error", { status: 500, body: {} }, "host_unavailable"],
  ];
  for (const [label, answer, code] of cases) {
    const host = await hostServer(() => answer);
    try {
      const outcome = await host.client.visibleItems({ contextId: "ctx-3f2a", maxResults: 100 }).then((value) => value, (error: unknown) => error);
      if (code) {
        assert.ok(outcome instanceof LauncherRouteError, label);
        assert.equal(outcome.code, code, label);
      } else {
        assert.deepEqual(outcome, DESKTOP, label);
      }
      assert.deepEqual(host.seen[0], { url: "/tools/launcher.visibleItems", token: "fixture-token", body: readJson("launcher/visible-items.request.json") }, label);
    } finally {
      await host.close();
    }
  }
});

// ---------------------------------------------------------------- learning, logs and the server

test("learning: file rows are never offered, a visible act teaches nothing, \"No, I meant X\" after it acts without naming it", async () => {
  const memo = new InMemoryTakeMemo();
  const d = make({ visibleItems: visibleCache(), takeMemo: memo, dictionary: NO_DICTIONARY });
  const request = final([DE("Öffne Radfotos.")], { takeId: "take-vis" });
  const response = await d.dispatch(request);
  opensItem(response);
  const record = takeRecordFor(request, response, Date.now(), takeDetailsOf(response))!;
  assert.deepEqual([record.offered, record.acted, record.item, record.via], [[], undefined, true, "visible"]);
  memo.remember(record);

  // The collision list offers only its app row.
  const list = asList(await d.dispatch(final([DE("Öffne Fotos.")])));
  assert.deepEqual(offeredBundleIds(list.card), ["com.apple.Photos"]);
  assert.deepEqual(takeDetailsOf(list)?.offered, ["com.apple.Photos"]);

  // "Nein, ich meinte Fotos" right after: Photos opens, but no take is named for learning.
  const corrected = asAct(await d.dispatch(final([DE("Nein, ich meinte Spotify.")], { takeId: "take-fix" })));
  assert.deepEqual(corrected.action, { type: "openApp", bundleId: "com.spotify.client" });
  assert.equal(corrected.voice?.correctsTakeId, undefined);

  // And the learn route refuses a no_i_meant against the item take.
  const store = new DictionaryStore({ path: join(mkdtempSync(join(tmpdir(), "pi-os-visible-")), "dictionary.json") });
  const lane = createLearnLane({ dispatcher: make({ dictionary: nonCountingLookup(store) }), apps: () => APPS, dictionary: nonCountingLookup(store) });
  const learned = await learnFromGesture({ takeId: "take-vis", kind: "no_i_meant", correctedText: "Spotify" }, { store, memo, lane });
  assert.equal(learned.status, "refused");
  assert.equal((learned as { code?: string }).code, "nothing_to_learn");
});

test("logs and perf fields carry kinds and timings only: never a visible name, a token or a path", async () => {
  const perf: unknown[] = [];
  const d = make({ visibleItems: visibleCache(), searchFiles: spotlight(HOME_HITS).searchFiles, perf: (stage, ms, fields) => perf.push({ stage, ms, fields }) });
  const nothing = make({ visibleItems: visibleCache(NONE), searchFiles: spotlight(HOME_HITS).searchFiles, perf: (stage, ms, fields) => perf.push({ stage, ms, fields }) });
  const { lines } = await captureLogs(async () => {
    await d.dispatch(final([DE("Öffne Radfotos.")]));
    await d.dispatch(final([DE("Öffne Fotos.")]));
    await d.dispatch(typed("open radfotos"));
    await d.dispatch(final([DE("Lösche Radfotos.")]));
    await nothing.dispatch(final([DE("Öffne Radfotos.")]));
  });
  assert.deepEqual(lines, []);
  const text = JSON.stringify(perf).toLowerCase();
  for (const secret of ["radfotos", "fotos\"", "tok_", "/users/", "desktop"]) assert.ok(!text.includes(secret), secret);
  assert.ok(perf.length >= 5);
});

test("POST /instant over HTTP: the host's visible items open the desktop folder; the card passes the strict check; the memo marks the take", async () => {
  const visibleCalls: unknown[] = [];
  const host = Object.assign(fakeHost({ apps: { version: "1", apps: APPS } }), {
    async visibleItems(request: unknown) {
      visibleCalls.push(request);
      return structuredClone(DESKTOP);
    },
  });
  const takeMemo = new InMemoryTakeMemo();
  const f = await start({ host, takeMemo });
  try {
    const response = await f.post("/instant", { text: "Öffne Radfotos.", phase: "final", seq: 3, takeId: "take-http", contextId: "ctx-http", inputMode: "voice",
      locale: "de-DE", hypotheses: [DE("Öffne Radfotos.")], accept: ACCEPT });
    assert.equal(response.status, 200);
    const body = await response.json() as InstantResponse;
    opensItem(body);
    assert.deepEqual(visibleCalls, [{ contextId: "ctx-http", maxResults: VISIBLE.maxResults }]);
    const record = takeMemo.get("take-http");
    assert.deepEqual([record?.item, record?.offered, record?.via], [true, [], "visible"]);
  } finally {
    await f.close();
  }
  // A host without the method (an older client) keeps today's answer.
  const plain = await start({ host: fakeHost({ apps: { version: "1", apps: APPS } }) });
  try {
    const response = await plain.post("/instant", { text: "Öffne Radfotos.", phase: "final", seq: 1, contextId: "ctx-http", inputMode: "voice", hypotheses: [DE("Öffne Radfotos.")], accept: ACCEPT });
    assert.equal(((await response.json()) as InstantResponse).decision, "fallthrough");
  } finally {
    await plain.close();
  }
});

// ---------------------------------------------------------------- contamination (H1 negatives with a full desktop)

/** r3/mapping build_neg.py → the 665 negatives plus the corpus's 109 agent-bound phrasings (voiceCorpus.test.ts). */
function agentBound(): { text: string; lang: string; okApp?: string }[] {
  const t = <T>(name: string) => spokenTable<T>(name);
  const items: { text: string; lang: string; okApp?: string }[] = [];
  const suffix = t<Readonly<Record<string, string>>>("NEG_SUFFIX_OK");
  const add = (text: string, lang: string, okApp?: string): void => {
    const ok = okApp ?? Object.entries(suffix).find(([k]) => text === k || text.endsWith(` ${k}.`))?.[1];
    items.push({ text, lang, ...(ok ? { okApp: ok } : {}) });
  };
  const enNouns = t<readonly string[]>("NEG_EN_NOUNS");
  const enPicks = t<readonly (readonly number[])[]>("NEG_EN_PICKS");
  t<readonly string[]>("NEG_EN_VERBS").forEach((verb, v) => enPicks[v]!.forEach((i) => add(`${verb} ${enNouns[i]}.`, "en")));
  const deNouns = t<readonly string[]>("NEG_DE_NOUNS");
  const dePicks = t<readonly (readonly number[])[]>("NEG_DE_PICKS");
  t<readonly string[]>("NEG_DE_VERBS").forEach((verb, v) => dePicks[v]!.forEach((i) => {
    const noun = deNouns[i]!;
    add(verb === "Kannst du öffnen" ? `Kannst du ${noun} öffnen?` : verb === "Mach" ? `Mach ${noun} auf.` : `${verb} ${noun}.`, "de");
  }));
  const deStart = t<ReadonlySet<string>>("DE_QUESTION_START");
  for (const q of t<readonly string[]>("NEG_QUESTIONS")) add(q, /[äöüß]/.test(q) || deStart.has(q.split(" ")[0]!) ? "de" : "en");
  const deWords = t<ReadonlySet<string>>("DE_WORDS");
  for (const w of t<readonly string[]>("NEG_WORDS")) add(w, deWords.has(w) ? "de" : "en");
  for (const [text, okApp] of t<readonly (readonly [string, string])[]>("NEG_APP_NOUNS")) add(text, text.includes("Zeig") ? "de" : "en", okApp);
  const okApps = t<Readonly<Record<string, string>>>("NEG_OK_APPS");
  for (const [text, lang] of t<readonly (readonly [string, string])[]>("NEG")) add(text, lang, okApps[text]);
  return items;
}

test("contamination: the 665 negatives and 109 agent-bound phrasings never open a visible item they do not name exactly (104-app index)", async (t) => {
  const items = agentBound();
  assert.equal(items.length, 665 + 109);
  const run = async (desktop: VisibleItemsResult) => {
    const d = createInstantDispatcher({
      apps: new AppIndexCache(async () => ({ version: "fixture", apps: fixtureApps() })), localZone: () => "Europe/Berlin", homeDir: "/Users/fixture",
      visibleItems: visibleCache(desktop), searchFiles: spotlight([]).searchFiles,
    });
    const acts: { text: string; name: string }[] = [];
    let held = 0, lists = 0;
    for (const [index, entry] of items.entries()) {
      const hypothesis: VoiceHypothesis = { text: entry.text, source: "parakeet-v3", role: "primary" };
      const response = await d.dispatch({ text: entry.text, phase: "final", seq: index, locale: entry.lang === "de" ? "de-DE" : "en-US", inputMode: "voice",
        hypotheses: [hypothesis], accept: ACCEPT, contextId: "ctx-desk" });
      if (response.decision === "act" && response.intent === "open_item") {
        if (response.confirm) held++;
        else acts.push({ text: entry.text, name: response.title.replace(/^Open /, "") });
      }
      if (response.decision === "list" && response.intent === "open_item") lists++;
    }
    return { acts, held, lists };
  };
  // A desktop whose names are not the phrasings' nouns: nothing visible ever acts or is held.
  const typical = await run(result([
    item(RADFOTOS, "Radfotos", "/Users/fixture/Desktop/Radfotos"),
    item("tok_5e0c9a7b3d1f", "Rad-Tour 2026.pdf", "/Users/fixture/Desktop/Rad-Tour 2026.pdf", { isDirectory: false, contentType: "com.adobe.pdf" }),
    item("tok_jjjjjjjjjjjj", "Screenshot 2026-10-01 um 10.00.00.png", "/Users/fixture/Desktop/Screenshot 2026-10-01 um 10.00.00.png", { isDirectory: false, contentType: "public.png" }),
    item("tok_kkkkkkkkkkkk", "Rechnung März.pdf", "/Users/fixture/Desktop/Rechnung März.pdf", { isDirectory: false, contentType: "com.adobe.pdf" }),
    item("tok_llllllllllll", "Urlaub 2025", "/Users/fixture/Desktop/Urlaub 2025"),
    item("tok_mmmmmmmmmmmm", "Unbenannt.txt", "/Users/fixture/Desktop/Unbenannt.txt", { isDirectory: false, contentType: "public.plain-text" }),
  ]));
  t.diagnostic(`typical desktop: visible acts ${typical.acts.length}, held ${typical.held}, did-you-mean lists ${typical.lists} on ${items.length}`);
  assert.deepEqual([typical.acts.length, typical.held, typical.lists], [0, 0, 0]);
  // The fixture desktop holds generic names ("Präsentation.key", "Notizen.txt", "Fotos"): "Öffne die Präsentation" then
  // opens that file, as designed (an exact visible name). Every immediate act names its item exactly; none is held.
  const generic = await run(DESKTOP);
  t.diagnostic(`fixture desktop: visible acts ${generic.acts.length} (exact names), held ${generic.held}, did-you-mean lists ${generic.lists}`);
  for (const act of generic.acts) assert.ok(matchKey(act.text).includes(matchKey(act.name.replace(/\.[a-z]+$/i, ""))), act.name);
  assert.equal(generic.held, 0);
});

// ---------------------------------------------------------------- perf

test("perf: with a warm cache of 200 visible items the visible step adds < 2 ms to a 6-hypothesis voice final", async (t) => {
  const names = ["Projekt", "Rechnung", "Urlaub", "Bilder", "Notizen", "Steuer", "Vertrag", "Entwurf", "Skizzen", "Musik"];
  const items: VisibleItem[] = [...DESKTOP.items];
  for (let i = 0; items.length < 200; i++) {
    items.push(item(`tok_${String(i).padStart(12, "0")}`, `${names[i % names.length]} ${2000 + i}`, `/Users/fixture/Desktop/${names[i % names.length]} ${2000 + i}`));
  }
  const visible = visibleCache(result(items));
  await visible.get("ctx-desk", new AbortController().signal);
  const withVisible = make({ visibleItems: visible });
  const without = make();
  const take = (text: string) => final([P(`Öffne ${text}.`), DE(`Öffne ${text}.`), EN(`Open ${text}.`), SEC(`Öffne ${text}`, "apple-dt/de-DE"), SEC(`Open ${text}`), SEC(`Open the ${text}`)]);
  const time = async (d: ReturnType<typeof make>, request: InstantRequest, runs: number) => {
    for (let i = 0; i < 20; i++) await d.dispatch(request);
    const samples: number[] = [];
    for (let i = 0; i < runs; i++) {
      const t0 = performance.now();
      await d.dispatch({ ...request, seq: i });
      samples.push(performance.now() - t0);
    }
    samples.sort((a, b) => a - b);
    return { p50: samples[Math.floor(runs * 0.5)]!, p95: samples[Math.floor(runs * 0.95)]! };
  };
  const spotify = take("Spotify");
  const a = await time(without, spotify, 200);
  const b = await time(withVisible, spotify, 200);
  const radfotos = await time(withVisible, take("Radfotos"), 200);
  t.diagnostic(`visible step: app take p50 ${a.p50.toFixed(2)} → ${b.p50.toFixed(2)} ms, p95 ${a.p95.toFixed(2)} → ${b.p95.toFixed(2)} ms; visible act p50 ${radfotos.p50.toFixed(2)} ms, p95 ${radfotos.p95.toFixed(2)} ms`);
  assert.ok(b.p50 - a.p50 < 2, `p50 +${(b.p50 - a.p50).toFixed(2)} ms`);
  assert.ok(b.p95 - a.p95 < 2, `p95 +${(b.p95 - a.p95).toFixed(2)} ms`);
  assert.ok(radfotos.p95 < 5, `visible act p95 ${radfotos.p95.toFixed(2)} ms`);
});
