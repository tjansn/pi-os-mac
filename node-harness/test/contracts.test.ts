import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { HOST_ACTION_TYPES, parseHostAction } from "../src/contracts/actions.js";
import { bindingToHostAction, buildCard, type CardSpec, ui } from "../src/contracts/cards.js";
import {
  accepts, appleDictationRecognizer, appleSpeechRecognizer, INSTANT_ACCEPTS, INSTANT_LIMITS, isRecognizerId, parseInstantAccept,
  parseInstantRequest, parseVoiceHypothesis, parseVoiceMeta, RECOGNIZERS, recognizerEngine, VOICE_VIAS, type InstantRequest, type InstantResponse,
} from "../src/contracts/instant.js";
import {
  LAUNCHER_ROUTES, parseFileCandidate, parseVisibleItemsRequest, parseVisibleItemsResult, VISIBLE_ITEMS_LIMITS, VISIBLE_SOURCE_KINDS,
  VISIBLE_SOURCE_VIAS, type VisibleItem,
} from "../src/contracts/launcher.js";
import { choiceRowsCard, openItemCard } from "../src/instant/cards.js";
import { MAX_INSTANT_TEXT } from "../src/instant/dispatcher.js";
import { validateCard } from "../src/ui/validate.js";

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = (path: string): unknown => JSON.parse(readFileSync(path, "utf8"));
const jsonFiles = (dir: string): string[] => readdirSync(join(fixtures, dir)).filter((f) => f.endsWith(".json")).sort().map((f) => join(fixtures, dir, f));

test("host actions: closed vocabulary, http(s) only, host tokens only", () => {
  assert.deepEqual(parseHostAction({ type: "openURL", url: "https://example.com/a?b=1", extra: true }), { type: "openURL", url: "https://example.com/a?b=1" });
  assert.equal(parseHostAction({ type: "openURL", url: "file:///etc/passwd" }), null);
  assert.equal(parseHostAction({ type: "openURL", url: "javascript:alert(1)" }), null);
  // Values WHATWG would silently repair (and Swift's URL(string:) may reject) never bind.
  for (const url of ["https://example.com/a b", "https:\\example.com\\x", "https://example.com/\tx", "https://exa\u200bmple.com/", " https://example.com/"]) {
    assert.equal(parseHostAction({ type: "openURL", url }), null, JSON.stringify(url));
  }
  assert.equal(parseHostAction({ type: "deleteFile", token: "tok_12345678" }), null);
  assert.equal(parseHostAction({ type: "moveToTrash", token: "tok_12345678" }), null);
  assert.equal(parseHostAction({ type: "system", op: "power.restart" }), null);
  assert.equal(parseHostAction({ type: "openFile", token: "../../etc" }), null);
  assert.equal(parseHostAction({ type: "openApp", bundleId: "Figma" }), null);
  assert.deepEqual(parseHostAction({ type: "system", op: "volume.set", value: 0.3 }), { type: "system", op: "volume.set", value: 0.3 });
  assert.equal(parseHostAction({ type: "copyText", text: "x".repeat(4_001) }), null);
});

test("buildCard flattens deterministically and binds actions as json-render bindings", () => {
  const make = () => buildCard(ui.answer({ summary: "2 + 2 = 4" }, [ui.result({ kind: "math", value: "4" }, { type: "copyText", text: "4" })]));
  const a = make();
  assert.deepEqual(a, make());
  assert.equal(a.root, "root");
  assert.deepEqual(a.elements.root?.children, ["n1"]);
  assert.deepEqual(a.elements.n1?.on?.copy, { action: "copyText", params: { text: "4" } });
});

test("every binding in the shared valid card fixtures is a valid host action", () => {
  for (const file of jsonFiles("cards")) {
    const card = readJson(file) as CardSpec;
    assert.equal(card.format, "pi-os-ui/1", file);
    for (const element of Object.values(card.elements)) {
      for (const binding of Object.values(element.on ?? {})) {
        assert.notEqual(bindingToHostAction(binding), null, `${file}: ${JSON.stringify(binding)}`);
      }
    }
  }
  const bad = readJson(join(fixtures, "cards", "invalid", "bad-url-scheme.json")) as CardSpec;
  assert.equal(bindingToHostAction(bad.elements.n1!.on!.primary!), null);
  const deletion = readJson(join(fixtures, "cards", "invalid", "delete-action.json")) as CardSpec;
  assert.equal(bindingToHostAction(deletion.elements.n1!.on!.primary!), null);
});

test("instant fixtures carry valid actions, cards and voice meta", () => {
  const responses = jsonFiles("instant");
  assert.ok(responses.length >= 15);
  for (const file of responses) {
    const response = readJson(file) as { decision: string; action?: unknown; card?: CardSpec; voice?: unknown };
    if (response.decision === "act") assert.notEqual(parseHostAction(response.action), null, file);
    if (["answer", "list", "refuse"].includes(response.decision)) assert.equal(response.card?.format, "pi-os-ui/1", file);
    if (response.voice !== undefined) {
      assert.ok(["act", "list", "fallthrough"].includes(response.decision), `${file}: voice only on act, list and fallthrough`);
      assert.deepEqual(parseVoiceMeta(response.voice), response.voice, file);
    }
  }
});

test("instant voice fixtures: did-you-mean is an ordinary list, check and confirm use today's fields", () => {
  const dym = readJson(join(fixtures, "instant", "list-did-you-mean.json")) as InstantResponse;
  assert.equal(dym.decision, "list");
  if (dym.decision === "list") {
    assert.equal(dym.intent, "open_app");
    assert.equal(dym.title, "Did you mean Raycast?");
    assert.deepEqual(dym.voice, { heard: "recast", source: "parakeet-v3", via: "sound", didYouMean: true });
    const rows = Object.values(dym.card.elements).filter((element) => element.type === "Item");
    assert.equal(rows.length, 1);
  }
  const two = readJson(join(fixtures, "instant", "list-did-you-mean-two.json")) as InstantResponse;
  assert.equal(two.decision === "list" && two.title, "Did you mean…");
  const check = readJson(join(fixtures, "instant", "fallthrough-low-confidence.json")) as InstantResponse;
  assert.ok(check.decision === "fallthrough" && check.reason === "low_confidence" && check.voice?.check === true);
  for (const name of ["act-confirm-secondary.json", "act-confirm-url.json"]) {
    const act = readJson(join(fixtures, "instant", name)) as InstantResponse;
    assert.ok(act.decision === "act" && act.confirm === true, name);
  }
  const learned = readJson(join(fixtures, "instant", "act-learned.json")) as InstantResponse;
  assert.ok(learned.decision === "act" && learned.voice?.via === "learned" && learned.voice.learnedEntryId === "n_8f3a2c1d");
  const meant = readJson(join(fixtures, "instant", "act-no-i-meant.json")) as InstantResponse;
  assert.ok(meant.decision === "act" && meant.voice?.correctsTakeId === "take-41");
});

test("instant request fixtures: valid bodies parse to exactly their wire value, invalid ones are rejected without echoing values", () => {
  // POST /instant bodies live in instant/requests so every listing of instant/ stays responses only.
  const valid = jsonFiles("instant/requests");
  assert.ok(valid.length >= 4);
  for (const file of valid) {
    const body = readJson(file);
    const parsed = parseInstantRequest(body);
    assert.ok(parsed.ok, `${file}: ${parsed.ok ? "" : parsed.error}`);
    if (parsed.ok) assert.deepEqual(parsed.value, body, file);
  }
  const legacy = parseInstantRequest(readJson(join(fixtures, "instant", "requests", "final-legacy.request.json")));
  assert.ok(legacy.ok && legacy.value.hypotheses === undefined && legacy.value.accept === undefined, "absent fields stay absent (today's behaviour)");
  const invalid = jsonFiles("instant/requests/invalid");
  assert.ok(invalid.length >= 15);
  for (const file of invalid) {
    const parsed = parseInstantRequest(readJson(file));
    assert.equal(parsed.ok, false, file);
    if (!parsed.ok) for (const value of ["recast", "Pages", "Apple DT", "tertiary", "english", "did-you-mean", "xxxxxxxx"]) assert.ok(!parsed.error.includes(value), `${file} echoes ${value}`);
  }
});

test("instant invalid response fixtures: a malformed voice meta is dropped, never the response", () => {
  const files = jsonFiles("instant/invalid");
  assert.ok(files.length >= 5);
  for (const file of files) {
    const response = readJson(file) as { decision: string; action: unknown; voice: unknown };
    assert.equal(response.decision, "act", file);
    assert.notEqual(parseHostAction(response.action), null, file);
    assert.equal(parseVoiceMeta(response.voice), null, file);
  }
  // An unknown `via` is an open-set value: dropped on its own, the rest is kept.
  assert.deepEqual(parseVoiceMeta({ heard: "recast", via: "telepathy", didYouMean: true }), { heard: "recast", didYouMean: true });
  assert.deepEqual(parseVoiceMeta({ heard: null, check: null }), {});
  for (const via of VOICE_VIAS) assert.deepEqual(parseVoiceMeta({ via }), { via });
});

test("instant request: accept vocabulary, hypotheses and limits", () => {
  assert.deepEqual(INSTANT_ACCEPTS, ["suggest", "check", "confirm"]);
  // Unknown words are ignored (newer hosts may declare more); duplicates collapse into canonical order.
  assert.deepEqual(parseInstantAccept(["confirm", "futureKind", "suggest", "confirm"]), { ok: true, value: ["suggest", "confirm"] });
  assert.deepEqual(parseInstantAccept([]), { ok: true, value: [] });
  assert.deepEqual(parseInstantAccept(null), { ok: true, value: undefined });
  const request: InstantRequest = { text: "x", phase: "final", seq: 1, accept: ["check"] };
  assert.equal(accepts(request, "check"), true);
  assert.equal(accepts(request, "confirm"), false);
  assert.equal(accepts({}, "suggest"), false, "no accept: today's vocabulary");
  // null on optional members is absent; unknown keys are dropped.
  assert.deepEqual(parseVoiceHypothesis({ text: "open Pages", source: "apple-dt/en-US", role: "peer", confidence: null, minConfidence: null, locale: null, extra: 1 }),
    { ok: true, value: { text: "open Pages", source: "apple-dt/en-US", role: "peer" } });
  assert.equal(parseVoiceHypothesis({ text: "x".repeat(200), source: "parakeet-v3", role: "primary" }).ok, true);
  assert.equal(parseVoiceHypothesis({ text: "open \uD83D", source: "parakeet-v3", role: "primary" }).ok, false, "lone surrogate");
  assert.equal(MAX_INSTANT_TEXT, INSTANT_LIMITS.maxText);
  // Recognizer ids.
  assert.equal(appleDictationRecognizer("de-DE"), "apple-dt/de-DE");
  assert.equal(appleSpeechRecognizer("en-US"), "apple-st/en-US");
  for (const id of [RECOGNIZERS.any, RECOGNIZERS.parakeetV3, RECOGNIZERS.whisperTurbo, "apple-dt/en-US", "apple-st/de-DE", "whisper-626mb", "x"]) {
    assert.equal(isRecognizerId(id), true, id);
  }
  for (const id of ["", "Apple-dt/en-US", "apple dt", "a/b/c", "apple-dt/", "1abc", "apple-dt/en_US", "x".repeat(33), "apple-dt/en-US\n"]) {
    assert.equal(isRecognizerId(id), false, JSON.stringify(id));
  }
  // POST /invoke `input.engine` (server.ts ENGINE) admits no "/": hosts send the engine part, the language goes in `locale`.
  assert.equal(recognizerEngine("apple-dt/de-DE"), "apple-dt");
  assert.equal(recognizerEngine(RECOGNIZERS.parakeetV3), "parakeet-v3");
  for (const id of [RECOGNIZERS.any, RECOGNIZERS.parakeetV3, RECOGNIZERS.whisperTurbo, appleDictationRecognizer("en-US"), appleSpeechRecognizer("zh-Hant-TW"), "x".repeat(32)]) {
    assert.match(recognizerEngine(id), /^[\w.-]{1,64}$/, id);
  }
  // Six maximal ASCII hypotheses plus a maximal text still fit the 4 KB body; multi-byte text is the host's to trim.
  const hypotheses = Array.from({ length: INSTANT_LIMITS.maxHypotheses }, (_, i) => ({
    text: "x".repeat(INSTANT_LIMITS.maxHypothesisChars), source: i % 2 ? "apple-dt/de-DE" : "apple-dt/en-US", role: "secondary" as const,
    confidence: 0.123456789, minConfidence: 0.123456789, locale: "de-DE",
  }));
  const body = { text: "x".repeat(INSTANT_LIMITS.maxText), phase: "final", seq: 9_007_199_254_740_991, takeId: "t".repeat(128), contextId: "c".repeat(128),
    locale: "en-US", inputMode: "voice", silenceMs: 1234, hypotheses, accept: [...INSTANT_ACCEPTS] };
  assert.ok(parseInstantRequest(body).ok);
  assert.ok(Buffer.byteLength(JSON.stringify(body)) <= INSTANT_LIMITS.maxBodyBytes, String(Buffer.byteLength(JSON.stringify(body))));
});

test("explicit null on the new optional members is absent (Swift decodeIfPresent parity)", () => {
  const n = readJson(join(fixtures, "null-optional-members.json")) as Record<string, { wire: unknown; normalized: unknown }>;
  assert.deepEqual(parseVoiceHypothesis(n.voiceHypothesis!.wire), { ok: true, value: n.voiceHypothesis!.normalized });
  assert.deepEqual(parseInstantRequest(n.instantRequest!.wire), { ok: true, value: n.instantRequest!.normalized });
  assert.deepEqual(parseVoiceMeta(n.voiceMeta!.wire), n.voiceMeta!.normalized);
  assert.deepEqual(parseVisibleItemsRequest(n.visibleItemsRequest!.wire), { ok: true, value: n.visibleItemsRequest!.normalized });
  assert.deepEqual(parseVisibleItemsResult(n.visibleItemsResult!.wire), { ok: true, value: n.visibleItemsResult!.normalized });
});

// ---------------------------------------------------------------- visible items (launcher.visibleItems, open_item)

test("visible-items fixtures: valid bodies parse to exactly their wire value, invalid ones are rejected without echoing values", () => {
  const files = jsonFiles("launcher").filter((file) => file.includes("visible-items."));
  assert.ok(files.length >= 6);
  let results = 0;
  for (const file of files) {
    const body = readJson(file) as { arguments?: unknown; ok?: boolean; result?: unknown; error?: { code: string } };
    if (file.endsWith("visible-items.request.json")) {
      assert.deepEqual(parseVisibleItemsRequest(body.arguments), { ok: true, value: body.arguments }, file);
    } else if (body.ok === true) {
      assert.deepEqual(parseVisibleItemsResult(body.result), { ok: true, value: body.result }, file);
      results += 1;
    } else {
      // An older or Windows host: Node treats not_found (and HTTP 404, unsupported) as "no visible items".
      assert.equal(body.error?.code, "not_found", file);
    }
  }
  assert.equal(results, 4);
  const invalid = jsonFiles("launcher/invalid").filter((file) => file.includes("visible-items."));
  assert.ok(invalid.length >= 20);
  for (const file of invalid) {
    const body = readJson(file) as { arguments?: unknown; result?: unknown };
    const parsed = file.includes("visible-items.request-") ? parseVisibleItemsRequest(body.arguments) : parseVisibleItemsResult(body.result);
    assert.equal(parsed.ok, false, file);
    if (!parsed.ok) for (const value of ["Radfotos", "fixture", "tok_", "ctx", "dock", "filemanager"]) assert.ok(!parsed.error.includes(value), `${file} echoes ${value}`);
  }
});

test("visible-items contract: route name, vocabularies, limits, unknown keys, sources and tokens", () => {
  assert.deepEqual(LAUNCHER_ROUTES, ["launcher.searchFiles", "launcher.listApps", "launcher.open", "launcher.visibleItems"]);
  assert.deepEqual(VISIBLE_SOURCE_KINDS, ["desktop", "finderWindow"]);
  assert.deepEqual(VISIBLE_SOURCE_VIAS, ["ax", "spotlight"]);
  assert.deepEqual([VISIBLE_ITEMS_LIMITS.maxResults, VISIBLE_ITEMS_LIMITS.defaultMaxResults], [200, 100]);
  assert.deepEqual(parseVisibleItemsRequest({ contextId: "ctx-1", maxResults: 200, extra: true }), { ok: true, value: { contextId: "ctx-1", maxResults: 200 } });
  assert.deepEqual(parseVisibleItemsRequest({ contextId: "c".repeat(128) }), { ok: true, value: { contextId: "c".repeat(128) } });
  assert.equal(parseVisibleItemsRequest({ contextId: "c".repeat(129) }).ok, false);
  assert.equal(parseVisibleItemsRequest(null).ok, false);

  const item = (i: number, extra: Partial<VisibleItem> = {}): VisibleItem => ({
    token: `tok_${String(i).padStart(12, "0")}`, name: `Item ${i}`, path: `/Users/fixture/Desktop/Item ${i}`, isDirectory: false, isPackage: false, source: "desktop", ...extra,
  });
  const result = (items: VisibleItem[], extra: Record<string, unknown> = {}) => ({ sources: [{ kind: "desktop", via: "ax", complete: true }], items, truncated: false, elapsedMs: 1, ...extra });
  const full = Array.from({ length: VISIBLE_ITEMS_LIMITS.maxResults }, (_, i) => item(i));
  assert.equal(parseVisibleItemsResult(result(full, { truncated: true })).ok, true, "200 items");
  assert.equal(parseVisibleItemsResult(result([...full, item(200)])).ok, false, "201 items");
  // Unknown keys are dropped at every level; null optional members are absent.
  assert.deepEqual(parseVisibleItemsResult({ ...result([{ ...item(1), extra: 1 } as VisibleItem]), more: 2, sources: [{ kind: "desktop", via: "ax", complete: true, x: 1 }] }),
    { ok: true, value: result([item(1)]) });
  // Both kinds together (a Finder window showing the desktop folder next to the desktop surface) is a valid shape.
  const both = { sources: [{ kind: "finderWindow", via: "spotlight", complete: false }, { kind: "desktop", via: "ax", complete: true }],
    items: [item(1, { source: "finderWindow" }), item(2)], truncated: false, elapsedMs: 0 };
  assert.deepEqual(parseVisibleItemsResult(both), { ok: true, value: both });
  // A name is what the file system shows: umlauts and ß are fine, 255 UTF-16 units at most.
  assert.equal(parseVisibleItemsResult(result([item(1, { name: "Präsentation Straße.key", isPackage: true })])).ok, true);
  assert.equal(parseVisibleItemsResult(result([item(1, { name: "x".repeat(255) })])).ok, true);
  assert.equal(parseVisibleItemsResult(result([item(1, { name: "Rad\uD83Dfotos" })])).ok, false, "lone surrogate");
  assert.equal(parseVisibleItemsResult(result([item(1, { path: "/Users/fixture/Desktop/Radfotos/" })])).ok, false, "trailing slash");
  assert.equal(parseVisibleItemsResult(result([item(1, { modifiedMs: Number.NaN })])).ok, false);
  assert.equal(parseVisibleItemsResult(result([item(1, { useCount: 1.5 })])).ok, false);
  assert.equal(parseVisibleItemsResult(result([], { elapsedMs: "1" })).ok, false);
  assert.equal(parseVisibleItemsResult(result([], { sources: [{ kind: "desktop", via: "ax", complete: true }, { kind: "finderWindow", via: "ax", complete: true }, { kind: "desktop", via: "spotlight", complete: true }] })).ok, false, "3 sources");
  // The shared candidate check accepts every search fixture item too (one rule for both read routes).
  const search = readJson(join(fixtures, "launcher", "search-files-response.json")) as { result: { items: unknown[] } };
  for (const candidate of search.result.items) assert.deepEqual(parseFileCandidate(candidate), { ok: true, value: candidate });
});

test("open_item fixtures: an act on a visible folder and a did-you-mean with a folder and an app, built by the shared card builders", () => {
  const act = readJson(join(fixtures, "instant", "act-open-visible.json")) as InstantResponse;
  assert.ok(act.decision === "act");
  if (act.decision !== "act") return;
  assert.deepEqual([act.intent, act.title, act.action, act.confirm], ["open_item", "Open Radfotos", { type: "openFile", token: "tok_7c1e0a9f3b2d" }, false]);
  assert.deepEqual(act.voice, { heard: "radfotos", source: "apple-dt/de-DE", via: "visible" });
  assert.deepEqual(act.card, openItemCard("Open Radfotos", { token: "tok_7c1e0a9f3b2d", name: "Radfotos", folder: "Desktop", contentType: "public.folder" }));

  const list = readJson(join(fixtures, "instant", "list-did-you-mean-visible.json")) as InstantResponse;
  assert.ok(list.decision === "list");
  if (list.decision !== "list") return;
  assert.deepEqual([list.intent, list.title, list.voice], ["open_item", "Did you mean…", { heard: "fotos", source: "apple-dt/de-DE", via: "visible", didYouMean: true }]);
  const photos = { bundleId: "com.apple.Photos", name: "Photos", aliases: ["Fotos", "Photos"], path: "/System/Applications/Photos.app", running: false };
  assert.deepEqual(list.card, choiceRowsCard("Did you mean…", [
    { item: { token: "tok_2b8d4f6a1c3e", name: "Fotos", folder: "Desktop", contentType: "public.folder" } }, { app: photos, label: "Fotos" },
  ]));
  // Visible row first: the folder opens by token, the app by bundle id; both cards pass the strict catalog check.
  const primaries = Object.values(list.card.elements).filter((element) => element.type === "Item").map((element) => element.on?.primary?.action);
  assert.deepEqual(primaries, ["openFile", "openApp"]);
  for (const card of [act.card!, list.card]) assert.ok(validateCard(card, { mode: "strict", allowedActions: HOST_ACTION_TYPES }).ok);
  // The visible tokens are the desktop fixture's: Node never invents one.
  const desktop = readJson(join(fixtures, "launcher", "visible-items.response-desktop.json")) as { result: { items: VisibleItem[] } };
  const tokens = new Set(desktop.result.items.map((entry) => entry.token));
  assert.ok(tokens.has("tok_7c1e0a9f3b2d") && tokens.has("tok_2b8d4f6a1c3e"));
  // Older vias keep parsing exactly as before; "visible" is one more open-set value.
  assert.deepEqual(VOICE_VIAS, ["exact", "alias", "learned", "sound", "peer", "secondary", "url", "visible"]);
  assert.deepEqual(parseVoiceMeta({ via: "visible", heard: "radfotos" }), { heard: "radfotos", via: "visible" });
});
