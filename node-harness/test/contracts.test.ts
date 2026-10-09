import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { test } from "node:test";
import { HOST_ACTION_TYPES, parseHostAction } from "../src/contracts/actions.js";
import { bindingToHostAction, buildCard, type CardSpec, ui } from "../src/contracts/cards.js";
import { parseContext } from "../src/contracts/context.js";
import {
  accepts, appleDictationRecognizer, appleSpeechRecognizer, FILL_IMPLICIT_KINDS, FILL_NEVER_KINDS, FILL_OPT_IN_KINDS, fillActConsistent, fillSubmitAllowed,
  INSTANT_ACCEPTS, INSTANT_APP_CLASSES, INSTANT_FIELD_KINDS, INSTANT_LIMITS, isRecognizerId, parseInstantAccept, parseInstantRequest, parseInstantTarget,
  parseVoiceHypothesis, parseVoiceMeta, RECOGNIZERS, recognizerEngine, SUBMIT_AUTO_KINDS, SUBMIT_NEVER_KINDS, VOICE_FILLS, VOICE_VIAS, type InstantFieldKind,
  type InstantRequest, type InstantResponse,
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
  // typeIntoPinned `submit` (continuity fills): a literal true on one-line text; false and null read as absent.
  assert.deepEqual(parseHostAction({ type: "typeIntoPinned", text: "Albert Einstein", submit: true }), { type: "typeIntoPinned", text: "Albert Einstein", submit: true });
  for (const submit of [false, null, undefined]) {
    assert.deepEqual(parseHostAction({ type: "typeIntoPinned", text: "a\nb", submit }), { type: "typeIntoPinned", text: "a\nb" }, String(submit));
  }
  for (const text of ["a\nb", "a\rb", "a\tb", "a\u2028b", "a\u0085b"]) {
    assert.equal(parseHostAction({ type: "typeIntoPinned", text, submit: true }), null, JSON.stringify(text));
  }
  for (const submit of ["yes", 1, {}]) assert.equal(parseHostAction({ type: "typeIntoPinned", text: "x", submit }), null, JSON.stringify(submit));
  assert.deepEqual(parseHostAction({ type: "copyText", text: "x", submit: true }), { type: "copyText", text: "x" }, "copyText never submits");
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
    const response = readJson(file) as { decision: string; intent?: string; action?: unknown; card?: CardSpec; voice?: unknown };
    if (response.decision === "act") {
      const action = parseHostAction(response.action);
      assert.notEqual(action, null, file);
      assert.deepEqual(action, response.action, file);
      assert.ok(action && fillActConsistent(response.intent ?? "", action), `${file}: a fill types, and only a fill submits`);
    }
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
  assert.deepEqual(INSTANT_ACCEPTS, ["suggest", "check", "confirm", "fill"]);
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
  // The largest continuity target still fits next to them (the host never drops `target` to fit).
  const target = { app: "browser", anchor: { takeId: "a".repeat(128), settling: true }, field: { kind: "multiline", empty: false, ready: true, ownFill: true } };
  const withTarget = { ...body, target };
  assert.ok(parseInstantRequest(withTarget).ok);
  assert.ok(Buffer.byteLength(JSON.stringify(withTarget)) <= INSTANT_LIMITS.maxBodyBytes, String(Buffer.byteLength(JSON.stringify(withTarget))));
});

test("explicit null on the new optional members is absent (Swift decodeIfPresent parity)", () => {
  const n = readJson(join(fixtures, "null-optional-members.json")) as Record<string, { wire: unknown; normalized: unknown }>;
  assert.deepEqual(parseVoiceHypothesis(n.voiceHypothesis!.wire), { ok: true, value: n.voiceHypothesis!.normalized });
  assert.deepEqual(parseInstantRequest(n.instantRequest!.wire), { ok: true, value: n.instantRequest!.normalized });
  assert.deepEqual(parseVoiceMeta(n.voiceMeta!.wire), n.voiceMeta!.normalized);
  assert.deepEqual(parseVisibleItemsRequest(n.visibleItemsRequest!.wire), { ok: true, value: n.visibleItemsRequest!.normalized });
  assert.deepEqual(parseVisibleItemsResult(n.visibleItemsResult!.wire), { ok: true, value: n.visibleItemsResult!.normalized });
  // Continuity members.
  assert.deepEqual(parseInstantTarget(n.instantTarget!.wire), { ok: true, value: n.instantTarget!.normalized });
  assert.deepEqual(parseInstantRequest(n.instantRequestTarget!.wire), { ok: true, value: n.instantRequestTarget!.normalized });
  assert.deepEqual(parseVoiceMeta(n.voiceMetaFill!.wire), n.voiceMetaFill!.normalized);
  assert.deepEqual(parseHostAction(n.hostActionTypeIntoPinned!.wire), n.hostActionTypeIntoPinned!.normalized);
  assert.deepEqual(parseContext(n.contextTarget!.wire), { ok: true, context: n.contextTarget!.normalized });
  // Required members stay required: null never stands in for `app`, `kind` or `ready`.
  assert.equal(parseInstantTarget({ app: null }).ok, false);
  assert.equal(parseInstantTarget({ app: "browser", field: { kind: null, ready: true } }).ok, false);
  assert.equal(parseInstantTarget({ app: "browser", field: { kind: "search", ready: null } }).ok, false);
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
  // Older vias keep parsing exactly as before; "visible" and "field" are more open-set values.
  assert.deepEqual(VOICE_VIAS, ["exact", "alias", "learned", "sound", "peer", "secondary", "url", "visible", "field"]);
  assert.deepEqual(parseVoiceMeta({ via: "visible", heard: "radfotos" }), { heard: "radfotos", via: "visible" });
});

// ---------------------------------------------------------------- continuity (DESIGN5 §8, TOM-ANSWERS)

const TARGET_FIXTURE = /request-target-.*\.json$/;

test("continuity golden: request bodies without target or fill parse to exactly their bytes; target fixtures round-trip byte for byte", () => {
  const files = jsonFiles("instant/requests");
  const legacy = files.filter((file) => !TARGET_FIXTURE.test(file));
  const continuity = files.filter((file) => TARGET_FIXTURE.test(file));
  assert.ok(legacy.length >= 6 && continuity.length >= 7, `${legacy.length} + ${continuity.length}`);
  for (const file of files) {
    const raw = readFileSync(file, "utf8");
    const parsed = parseInstantRequest(JSON.parse(raw));
    assert.ok(parsed.ok, `${file}: ${parsed.ok ? "" : parsed.error}`);
    if (!parsed.ok) continue;
    assert.equal(`${JSON.stringify(parsed.value, null, 2)}\n`, raw, `${file}: byte-identical`);
    if (!TARGET_FIXTURE.test(file)) {
      assert.equal(parsed.value.target, undefined, file);
      assert.equal(parsed.value.accept?.includes("fill") ?? false, false, `${file}: today's bodies never declare fill`);
    }
  }
  // Every target fixture is content-free: closed words, take ids and booleans only.
  for (const file of continuity) {
    const parsed = parseInstantRequest(readJson(file));
    assert.ok(parsed.ok && parsed.value.target, file);
    if (!parsed.ok || !parsed.value.target) continue;
    const { app, anchor, field } = parsed.value.target;
    assert.ok((INSTANT_APP_CLASSES as readonly string[]).includes(app), file);
    assert.ok(anchor === undefined || Object.keys(anchor).every((key) => key === "takeId" || key === "settling"), file);
    assert.ok(field === undefined || Object.keys(field).every((key) => ["kind", "empty", "ready", "ownFill"].includes(key)), file);
    if (field?.kind === "credential") assert.equal("empty" in field, false, `${file}: no length facts for credential fields`);
  }
});

test("continuity target: strict parse, unknown keys dropped, credential never has empty, invalid takeId refused, no value echoed", () => {
  assert.deepEqual(INSTANT_APP_CLASSES, ["browser", "finder", "terminal", "other"]);
  assert.deepEqual(INSTANT_FIELD_KINDS, ["search", "address", "text", "multiline", "terminal", "sensitive", "credential", "confirm", "rename"]);
  // Unknown keys are dropped at every level; false on a literal-true flag is absent.
  assert.deepEqual(parseInstantTarget({ app: "browser", bundleId: "com.apple.Safari", anchor: { takeId: "take-50", settling: false, url: "https://x.example/" },
    field: { kind: "search", empty: true, ready: true, ownFill: false, label: "Search", value: "secret" } }),
  { ok: true, value: { app: "browser", anchor: { takeId: "take-50" }, field: { kind: "search", empty: true, ready: true } } });
  assert.deepEqual(parseInstantTarget({ app: "finder", anchor: {} }), { ok: true, value: { app: "finder", anchor: {} } });
  assert.deepEqual(parseInstantTarget(undefined), { ok: true, value: undefined });
  // A credential field carries no length fact at all, not even `empty: false`.
  for (const empty of [true, false]) assert.equal(parseInstantTarget({ app: "browser", field: { kind: "credential", empty, ready: true } }).ok, false);
  assert.deepEqual(parseInstantTarget({ app: "browser", field: { kind: "credential", empty: null, ready: true } }),
    { ok: true, value: { app: "browser", field: { kind: "credential", ready: true } } });
  for (const kind of INSTANT_FIELD_KINDS) assert.equal(parseInstantTarget({ app: "other", field: { kind, ready: false } }).ok, true, kind);
  for (const takeId of ["", "take 50", "take/50", "t".repeat(129), 50]) {
    assert.equal(parseInstantTarget({ app: "browser", anchor: { takeId } }).ok, false, JSON.stringify(takeId));
  }
  // Invalid request fixtures: rejected with an error that names the member and never the value.
  // By file name: the joined path uses the host's separator (`\` on Windows).
  const invalid = jsonFiles("instant/requests/invalid").filter((file) => basename(file).startsWith("target-"));
  assert.ok(invalid.length >= 12, String(invalid.length));
  for (const file of invalid) {
    const parsed = parseInstantRequest(readJson(file));
    assert.equal(parsed.ok, false, file);
    if (!parsed.ok) {
      assert.match(parsed.error, /target/, file);
      for (const value of ["mail", "password", "take 50", "xxxxxxxx", "yes", "Albert"]) assert.ok(!parsed.error.includes(value), `${file} echoes ${value}`);
    }
  }
  // `target` on a typing preview parses too (Node uses it on finals only).
  assert.equal(parseInstantRequest({ text: "Alb", phase: "typing", seq: 1, target: { app: "browser" } }).ok, true);
});

test("continuity responses: act fill types (submit only into a fill), via field, and the check card's fill offer", () => {
  const fill = readJson(join(fixtures, "instant", "act-fill.json")) as InstantResponse;
  assert.ok(fill.decision === "act" && fill.intent === "fill" && fill.confirm === false);
  if (fill.decision !== "act") return;
  assert.deepEqual(fill.action, { type: "typeIntoPinned", text: "Liebe Grüße" });
  assert.deepEqual(fill.voice, { source: "parakeet-v3", via: "field" });
  const submit = readJson(join(fixtures, "instant", "act-fill-submit.json")) as InstantResponse;
  assert.ok(submit.decision === "act" && submit.intent === "fill");
  if (submit.decision !== "act") return;
  assert.deepEqual(submit.action, { type: "typeIntoPinned", text: "Albert Einstein", submit: true });
  const offer = readJson(join(fixtures, "instant", "fallthrough-check-fill-offer.json")) as InstantResponse;
  assert.ok(offer.decision === "fallthrough" && offer.reason === "low_confidence");
  if (offer.decision !== "fallthrough") return;
  assert.deepEqual(offer.voice, { source: "parakeet-v3", check: true, fill: "offer" });
  assert.deepEqual(VOICE_FILLS, ["offer"]);
  // An unknown fill word is dropped on its own; a non-string spoils the meta (the response survives).
  assert.deepEqual(parseVoiceMeta({ check: true, fill: "auto" }), { check: true });
  assert.equal(parseVoiceMeta({ check: true, fill: true }), null);
  // Pairing rule (Swift's decoder enforces the same).
  assert.equal(fillActConsistent("fill", { type: "typeIntoPinned", text: "x" }), true);
  assert.equal(fillActConsistent("fill", { type: "openURL", url: "https://example.com/" }), false);
  assert.equal(fillActConsistent("web", { type: "typeIntoPinned", text: "x", submit: true }), false);
  assert.equal(fillActConsistent("open_app", { type: "typeIntoPinned", text: "x" }), true, "today's shapes stay valid");
  // A fill types one line whether or not it submits: a CR/LF would be a Return of its own, a Tab moves focus.
  for (const text of ["a\nb", "a\rb", "a\tb", "a\u2028b", "a\u0085b"]) {
    assert.equal(fillActConsistent("fill", { type: "typeIntoPinned", text }), false, JSON.stringify(text));
  }
  assert.equal(fillActConsistent("open_app", { type: "typeIntoPinned", text: "a\nb" }), true, "today's typing acts keep their text");
  // invalid-action fixtures: a bad action or pairing rejects the whole response.
  const invalid = jsonFiles("instant/invalid-action");
  assert.ok(invalid.length >= 6);
  for (const file of invalid) {
    const response = readJson(file) as { decision: string; intent: string; action: unknown };
    assert.equal(response.decision, "act", file);
    const action = parseHostAction(response.action);
    assert.ok(action === null || !fillActConsistent(response.intent, action), file);
  }
});

test("continuity eligibility: fill tiers and Return rules partition the field kinds (TOM-ANSWERS 1, 2, D6)", () => {
  const kinds = new Set<string>(INSTANT_FIELD_KINDS);
  const tiers = [FILL_IMPLICIT_KINDS, FILL_OPT_IN_KINDS, FILL_NEVER_KINDS].flat() as string[];
  assert.equal(new Set(tiers).size, tiers.length, "disjoint");
  assert.deepEqual([...kinds].filter((kind) => !tiers.includes(kind)), ["terminal"], "terminal is the explicit-only kind");
  assert.deepEqual(FILL_IMPLICIT_KINDS, ["search", "address", "text", "multiline"]);
  assert.deepEqual([...FILL_OPT_IN_KINDS], ["sensitive", "credential"]);
  assert.deepEqual([...FILL_NEVER_KINDS], ["confirm", "rename"]);
  assert.deepEqual([...SUBMIT_AUTO_KINDS], ["search", "address"]);
  const expected: Record<InstantFieldKind, [auto: boolean, explicit: boolean]> = {
    // TOM-ANSWERS 1: documents and chats (multiline) never get a Return, not even an explicit one.
    search: [true, true], address: [true, true], text: [false, true], multiline: [false, false],
    terminal: [false, false], sensitive: [false, false], credential: [false, false], confirm: [false, false], rename: [false, false],
  };
  for (const kind of INSTANT_FIELD_KINDS) {
    assert.deepEqual([fillSubmitAllowed(kind, false), fillSubmitAllowed(kind, true)], expected[kind], kind);
    assert.equal((SUBMIT_NEVER_KINDS as readonly string[]).includes(kind), !expected[kind][1], kind);
  }
});

test("context.target: content-free, strict, optional; requests without it stay exactly as before", () => {
  const base = { scope: "general", pull: "allowed", source: "default" };
  assert.deepEqual(parseContext(base), { ok: true, context: base });
  assert.deepEqual(parseContext({ ...base, target: { field: "search", anchored: true, app: "Safari", title: "x" } }),
    { ok: true, context: { ...base, target: { field: "search", anchored: true } } });
  assert.deepEqual(parseContext({ ...base, target: {} }), { ok: true, context: { ...base, target: {} } });
  assert.deepEqual(parseContext({ ...base, target: null }), { ok: true, context: base });
  for (const field of INSTANT_FIELD_KINDS) assert.equal(parseContext({ ...base, target: { field } }).ok, true, field);
  for (const target of ["search", [], { field: "password" }, { field: 1 }, { anchored: "yes" }]) {
    const parsed = parseContext({ ...base, target });
    assert.equal(parsed.ok, false, JSON.stringify(target));
    if (!parsed.ok) for (const value of ["password", "yes"]) assert.ok(!parsed.error.includes(value), parsed.error);
  }
});
