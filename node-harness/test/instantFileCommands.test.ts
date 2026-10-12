import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { HOST_ACTION_TYPES } from "../src/contracts/actions.js";
import { bindingToHostAction, type CardSpec } from "../src/contracts/cards.js";
import { NO_CONTEXT_SCORER } from "../src/contracts/context.js";
import { NO_DICTIONARY } from "../src/contracts/dictionary.js";
import type { InstantAccept, InstantRequest, InstantResponse, InstantTarget, VoiceHypothesis } from "../src/contracts/instant.js";
import type { AppRecord, VisibleItem, VisibleItemsResult } from "../src/contracts/launcher.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { fileOpActCard, fileOpRowsCard, noticeCard } from "../src/instant/cards.js";
import { createInstantDispatcher, type InstantDispatcherDeps } from "../src/instant/dispatcher.js";
import { DictionaryStore } from "../src/instant/dictionary.js";
import { FileOpStore, type LstatFn, type PathGuard } from "../src/instant/fileOps.js";
import { createLearnLane, learnFromGesture } from "../src/instant/learned.js";
import { InMemoryTakeMemo, takeRecordFor } from "../src/instant/takeMemo.js";
import { VisibleItemsCache } from "../src/instant/visible.js";
import { validateCard } from "../src/ui/validate.js";

/*
 * File commands in the instant lane (DESIGN6 with BUILD6): "lösche test" on what the take shows resolves against the
 * visible items and answers with an op staged in Node (`fileOp {opId}`), a list of such rows, an answer, or `quitApp` /
 * `closeFinderWindow`. Resolution 0/1/many/sound-alike, destinations, names, close, safety, voice gating, previews, the
 * fill lane, learning, and the golden rule: without the lane (no dependency, not active, no visible items, no context)
 * every decision is byte for byte today's. Fixture items under /Users/fixture only; the store's identity reads are
 * faked, so no file system is touched and nothing runs.
 */

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = <T>(path: string): T => JSON.parse(readFileSync(join(fixtures, path), "utf8")) as T;
const DESKTOP = readJson<{ result: VisibleItemsResult }>("launcher/visible-items.response-desktop.json").result;
const WITH_PATH = readJson<{ result: VisibleItemsResult }>("launcher/visible-items.with-path.json").result;
const FINDER_WINDOW = readJson<{ result: VisibleItemsResult }>("launcher/visible-items.response-finder-window.json").result;
const NONE = readJson<{ result: VisibleItemsResult }>("launcher/visible-items.response-none.json").result;
const ACCEPT: InstantAccept[] = ["suggest", "check", "confirm"];
const ALL: InstantAccept[] = ["suggest", "check", "confirm", "fill"];
const GUARD: PathGuard = { home: "/Users/fixture", temp: [] };

const app = (bundleId: string, name: string, aliases: string[] = [], dir = "/Applications"): AppRecord => ({ bundleId, name, aliases, path: `${dir}/${name}.app`, running: true });
const APPS: AppRecord[] = [
  app("com.apple.Photos", "Photos", ["Fotos"], "/System/Applications"),
  app("com.apple.Notes", "Notes", ["Notizen"], "/System/Applications"),
  app("com.apple.finder", "Finder", [], "/System/Library/CoreServices"),
  app("com.apple.Safari", "Safari"),
  app("com.spotify.client", "Spotify"),
  app("com.tinyspeck.slackmacgap", "Slack"),
];

const item = (token: string, name: string, path: string, extra: Partial<VisibleItem> = {}): VisibleItem => ({
  token, name, path, isDirectory: true, isPackage: false, contentType: "public.folder", source: "finderWindow", ...extra,
});
const windowOf = (path: string, items: VisibleItem[]): VisibleItemsResult => ({
  sources: [{ kind: "finderWindow", via: "ax", complete: true, path }], items, truncated: false, elapsedMs: 1,
});

/** The store's identity reads are faked: staging never touches a file. */
const fakeLstat: LstatFn = async () => ({ dev: 1n, ino: 2n, mtimeNs: 3n, isDirectory: () => true, isFile: () => false, isSymbolicLink: () => false });

interface Make {
  /** The lane's `active()` (default on). */
  active?: () => boolean;
  /** No fileCommands dependency at all (today's lane). */
  lane?: boolean;
  deps?: Partial<InstantDispatcherDeps>;
}

function make(visible: VisibleItemsResult | null, options: Make = {}) {
  let n = 0;
  const ops = new FileOpStore({ lstat: fakeLstat, mintId: () => `op_fixture_${String(++n).padStart(10, "0")}` });
  const cache = visible ? new VisibleItemsCache(async () => structuredClone(visible)) : undefined;
  let reads = 0;
  const dispatcher = createInstantDispatcher({
    apps: new AppIndexCache(async () => ({ version: "1", apps: APPS })), localZone: () => "Europe/Berlin", homeDir: "/Users/fixture",
    scorer: NO_CONTEXT_SCORER,
    ...(cache ? { visibleItems: cache } : {}),
    ...(options.lane === false ? {} : {
      fileCommands: {
        active: () => { reads++; return (options.active ?? (() => true))(); },
        store: ops, guard: GUARD,
        isDirectory: async (path: string) => path === "/Users/fixture/Projects",
      },
    }),
    ...options.deps,
  });
  /** Fills the visible-items cache (previews never wait for it). */
  const warm = async (contextId = "ctx-desk"): Promise<void> => { await cache?.get(contextId, new AbortController().signal); };
  return { dispatcher, ops, warm, reads: () => reads };
}

const P = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "parakeet-v3", role: "primary", confidence: 0.92, minConfidence: 0.6, ...extra });
const DE = (text: string, confidence = 0.8): VoiceHypothesis => ({ text, source: "apple-dt/de-DE", role: "peer", locale: "de-DE", confidence, minConfidence: 0.5 });
const EN = (text: string, confidence = 0.8): VoiceHypothesis => ({ text, source: "apple-dt/en-US", role: "peer", locale: "en-US", confidence, minConfidence: 0.5 });

const typed = (text: string, extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text, phase: "final", seq: 1, locale: "de-DE", contextId: "ctx-desk", takeId: "take-typed", ...extra,
});
const spoken = (hypotheses: VoiceHypothesis[], extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text: hypotheses[0]!.text, phase: "final", seq: 1, inputMode: "voice", hypotheses, accept: ACCEPT, locale: "de-DE", contextId: "ctx-desk",
  takeId: "take-voice", ...extra,
});

type Act = Extract<InstantResponse, { decision: "act" }>;
type List = Extract<InstantResponse, { decision: "list" }>;
type Answer = Extract<InstantResponse, { decision: "answer" }>;
const asAct = (r: InstantResponse): Act => { assert.equal(r.decision, "act", JSON.stringify(r)); return r as Act; };
const asList = (r: InstantResponse): List => { assert.equal(r.decision, "list", JSON.stringify(r)); return r as List; };
const asAnswer = (r: InstantResponse): Answer => { assert.equal(r.decision, "answer", JSON.stringify(r)); return r as Answer; };
const stable = (r: InstantResponse): string => JSON.stringify({ ...r, elapsedMs: 0 });
const validCard = (card: CardSpec | undefined): boolean => !!card && validateCard(card, { mode: "strict", allowedActions: HOST_ACTION_TYPES }).ok;
/** Rows: title, subtitle and the staged op each binds. */
const rows = (card: CardSpec) => Object.values(card.elements).flatMap((element) => {
  if (element.type !== "Item") return [];
  const action = element.on?.primary ? bindingToHostAction(element.on.primary) : null;
  return [{ title: String(element.props.title), subtitle: String(element.props.subtitle ?? ""), opId: action?.type === "fileOp" ? action.opId : undefined }];
});
/** The argv of the op an act or row runs. */
const argvOf = (ops: FileOpStore, takeId: string) => ops.forTake(takeId).map((op) => op.plan.argv);

// ---------------------------------------------------------------- delete: 1 / many / sound-alike / none

test("delete a visible folder: an act at once (dcg's dialog is the confirmation); the op lives in Node, the wire carries only its id", async () => {
  const { dispatcher, ops } = make(DESKTOP);
  const act = asAct(await dispatcher.dispatch(typed("lösche Radfotos")));
  assert.deepEqual([act.intent, act.title, act.confirm], ["file_op", "Löschen: Radfotos", false]);
  assert.equal(act.action.type, "fileOp");
  assert.deepEqual(act.card, fileOpActCard("Löschen: Radfotos", { name: "Radfotos", subtitle: "in Desktop", contentType: "public.folder" }));
  assert.ok(validCard(act.card));
  assert.equal(act.voice, undefined, "typed: no voice meta");
  const [op] = ops.forTake("take-typed");
  assert.equal(act.action.type === "fileOp" && act.action.opId, op?.opId);
  assert.deepEqual(op?.plan.argv, ["/bin/rm", "-r", "--", "/Users/fixture/Desktop/Radfotos"]);
  assert.deepEqual([op?.plan.cwd, op?.contextId], ["/Users/fixture/Desktop", "ctx-desk"]);
  assert.ok(!JSON.stringify(act).includes("/Users/fixture"), "no path on the wire");
  // English words, English copy.
  const en = asAct(await dispatcher.dispatch(typed("delete Radfotos", { locale: "en-US", takeId: "take-en" })));
  assert.equal(en.title, "Delete Radfotos");

  // Spoken: the folder fixture exactly (apart from the minted id).
  const fixture = readJson<Act>("instant/act-file-op-delete-folder.json");
  const voice = asAct(await dispatcher.dispatch(spoken([DE("Lösche Radfotos.")])));
  assert.deepEqual([voice.intent, voice.title, voice.confirm, voice.card, voice.voice], [fixture.intent, fixture.title, fixture.confirm, fixture.card, fixture.voice]);
});

test("delete a visible file: one Return first (typed and voice hosts declare confirm); without confirm a one-row list whose row must be picked", async () => {
  const { dispatcher, ops } = make(DESKTOP);
  const fixture = readJson<Act>("instant/act-file-op-delete-file-confirm.json");
  const voice = asAct(await dispatcher.dispatch(spoken([P("Lösche Notizen.")])));
  assert.deepEqual([voice.intent, voice.title, voice.confirm, voice.card, voice.voice], [fixture.intent, fixture.title, fixture.confirm, fixture.card, fixture.voice]);
  assert.deepEqual(argvOf(ops, "take-voice"), [["/bin/rm", "--", "/Users/fixture/Desktop/Notizen.txt"]]);
  // Typed with confirm (the macOS host declares it on typed finals now).
  const typedConfirm = asAct(await dispatcher.dispatch(typed("lösche Notizen", { accept: ["confirm"], takeId: "take-c" })));
  assert.deepEqual([typedConfirm.title, typedConfirm.confirm], ["„Notizen.txt“ endgültig löschen?", true]);
  // A host without confirm: a one-row list, never an act.
  const list = asList(await dispatcher.dispatch(typed("lösche Notizen", { takeId: "take-l" })));
  assert.deepEqual([list.intent, list.title], ["file_op", "„Notizen.txt“ endgültig löschen?"]);
  const [row] = rows(list.card);
  assert.deepEqual([row?.title, row?.subtitle, row?.opId], ["Notizen.txt", "in Desktop", ops.forTake("take-l")[0]?.opId]);
  assert.ok(validCard(list.card));
  // A package (a directory on disk) is a folder for rm: dcg's dialog confirms it.
  const pkg = asAct(await dispatcher.dispatch(typed("lösche Präsentation", { takeId: "take-p" })));
  assert.equal(pkg.confirm, false);
  assert.deepEqual(argvOf(ops, "take-p"), [["/bin/rm", "-r", "--", "/Users/fixture/Desktop/Präsentation.key"]]);
});

test("several exact matches: \"which one?\" with one row per item (the which-list fixture); a said extension narrows to one", async () => {
  const { dispatcher, ops } = make(WITH_PATH);
  const fixture = readJson<List>("instant/list-file-op-which.json");
  const list = asList(await dispatcher.dispatch(spoken([DE("Lösche test.")])));
  const ids = ops.forTake("take-voice").map((op) => op.opId);
  assert.equal(ids.length, 2);
  assert.deepEqual([list.intent, list.title, list.voice], [fixture.intent, fixture.title, fixture.voice]);
  assert.deepEqual(list.card, fileOpRowsCard(fixture.title, [
    { opId: ids[0]!, name: "test", subtitle: "in Projekte", contentType: "public.folder" },
    { opId: ids[1]!, name: "test.txt", subtitle: "in Desktop", contentType: "public.plain-text" },
  ]));
  assert.deepEqual(argvOf(ops, "take-voice"), [
    ["/bin/rm", "-r", "--", "/Users/fixture/Documents/Projekte/test"], ["/bin/rm", "--", "/Users/fixture/Desktop/test.txt"],
  ]);
  const narrowed = asAct(await dispatcher.dispatch(typed("lösche test.txt", { accept: ["confirm"] })));
  assert.equal(narrowed.title, "„test.txt“ endgültig löschen?");
  // "den Ordner test": only folders.
  const folder = asAct(await dispatcher.dispatch(typed("lösche den Ordner test", { takeId: "take-f" })));
  assert.equal(folder.title, "Löschen: test");
  assert.deepEqual(argvOf(ops, "take-f"), [["/bin/rm", "-r", "--", "/Users/fixture/Documents/Projekte/test"]]);
});

test("no exact match: sound-alikes are a \"did you mean …?\" list — never an act, for every op that names an existing item", async () => {
  const { dispatcher } = make(DESKTOP);
  for (const request of [
    typed("lösche Radfotoss"), spoken([P("Lösche Radfotoss.")]), typed("verschiebe Radfotoss nach Dokumente"), typed("kopiere Radfotoss nach Dokumente"),
    typed("benenne Radfotoss in Radtour um"), typed("dupliziere Radfotoss"),
  ]) {
    const list = asList(await dispatcher.dispatch(request));
    assert.equal(list.intent, "file_op", request.text);
    assert.match(list.title, /^„Radfotoss“ nicht gefunden – meintest du …\?$/u, request.text);
    const listed = rows(list.card);
    assert.equal(listed[0]?.title, "Radfotos", request.text);
    assert.ok(listed.length <= 3 && listed.every((row) => row.opId), request.text);
    assert.equal(list.voice?.didYouMean, undefined, "a file list is never reported to /dictionary/learn");
  }
});

test("nothing there: an answer (the not-found fixture; voice shows what was heard) — unless that could be wrong, then today's", async () => {
  const { dispatcher, ops } = make(DESKTOP);
  const fixture = readJson<Answer>("instant/answer-file-op-not-found.json");
  const voice = asAnswer(await dispatcher.dispatch(spoken([P("Lösche tset.")])));
  assert.deepEqual([voice.intent, voice.title, voice.subtitle, voice.card], [fixture.intent, fixture.title, fixture.subtitle, fixture.card]);
  const typedAnswer = asAnswer(await dispatcher.dispatch(typed("lösche tset")));
  assert.deepEqual([typedAnswer.title, typedAnswer.subtitle], [fixture.title, undefined]);
  assert.equal(asAnswer(await dispatcher.dispatch(typed("delete tset", { locale: "en-US" }))).title, "There's nothing called “tset” on the Desktop.");
  assert.equal(ops.size, 0);

  // Today's handling: a class word ("Screenshots", "the zip files"), an installed app's name ("lösche Safari"), a phrase
  // ("Fotos in Rom"), a view that was incomplete (the Finder-window fixture), an app bundle.
  const today = make(DESKTOP, { lane: false });
  for (const [text, locale] of [["lösche Screenshots", "de-DE"], ["delete the zip files", "en-US"], ["lösche Safari", "de-DE"], ["lösche Fotos in Rom", "de-DE"]] as const) {
    assert.equal(stable(await dispatcher.dispatch(typed(text, { locale }))), stable(await today.dispatcher.dispatch(typed(text, { locale }))), text);
  }
  const incomplete = make(FINDER_WINDOW);
  const incompleteToday = make(FINDER_WINDOW, { lane: false });
  assert.equal(stable(await incomplete.dispatcher.dispatch(typed("lösche tset"))), stable(await incompleteToday.dispatcher.dispatch(typed("lösche tset"))));
  const apps = windowOf("/Applications", [item("tok_slackslack01", "Slack.app", "/Applications/Slack.app", { isPackage: true, contentType: "com.apple.application-bundle" })]);
  assert.equal(stable(await make(apps).dispatcher.dispatch(typed("lösche Slack"))), stable(await make(apps, { lane: false }).dispatcher.dispatch(typed("lösche Slack"))));
});

// ---------------------------------------------------------------- create, copy, duplicate, move, rename

test("create in the shown folder: mkdir / touch, never over an existing name; a valid single name; a Finder window without a path cannot say where", async () => {
  const { dispatcher, ops } = make(DESKTOP);
  const folder = asAct(await dispatcher.dispatch(typed("erstelle Ordner Projekte")));
  assert.deepEqual([folder.intent, folder.title, folder.confirm], ["file_op", "Ordner „Projekte“ erstellen", false]);
  assert.deepEqual(folder.card, fileOpActCard("Ordner „Projekte“ erstellen", { name: "Projekte", subtitle: "in Desktop", contentType: "public.folder" }));
  assert.deepEqual(argvOf(ops, "take-typed"), [["/bin/mkdir", "--", "/Users/fixture/Desktop/Projekte"]]);
  const file = asAct(await dispatcher.dispatch(typed("neue Datei notes.txt", { takeId: "take-file" })));
  assert.equal(file.title, "Datei „notes.txt“ erstellen");
  assert.deepEqual(argvOf(ops, "take-file"), [["/usr/bin/touch", "--", "/Users/fixture/Desktop/notes.txt"]]);
  assert.equal(asAct(await dispatcher.dispatch(typed("create folder Plans", { locale: "en-US" }))).title, "Create folder “Plans”");
  assert.equal(asAnswer(await dispatcher.dispatch(typed("erstelle Ordner Fotos"))).title, "„Fotos“ gibt es hier schon.");
  assert.equal(asAnswer(await dispatcher.dispatch(typed("erstelle Ordner a/b"))).title, "„a/b“ ist kein gültiger Name.");
  assert.equal(asAnswer(await make(FINDER_WINDOW).dispatcher.dispatch(typed("erstelle Ordner Neu"))).title, "Ich sehe nicht, welcher Ordner das ist.");
  const windowed = make(WITH_PATH);
  asAct(await windowed.dispatcher.dispatch(typed("erstelle Ordner Neu")));
  assert.deepEqual(argvOf(windowed.ops, "take-typed"), [["/bin/mkdir", "--", "/Users/fixture/Documents/Projekte/Neu"]]);
});

test("copy and move: standard folders, visible folders, existing paths and \"here\"; missing or unknown → \"where to?\" rows, never a guess", async () => {
  const { dispatcher, ops } = make(DESKTOP);
  const copy = asAct(await dispatcher.dispatch(typed("kopiere Radfotos nach Dokumente", { takeId: "t1" })));
  assert.deepEqual([copy.title, copy.confirm], ["„Radfotos“ nach Dokumente kopieren", false]);
  assert.deepEqual(argvOf(ops, "t1"), [["/bin/cp", "-R", "-n", "--", "/Users/fixture/Desktop/Radfotos", "/Users/fixture/Documents/Radfotos"]]);
  assert.equal(asAct(await dispatcher.dispatch(typed("copy Radfotos to Downloads", { locale: "en-US" }))).title, "Copy “Radfotos” to Downloads");
  const move = asAct(await dispatcher.dispatch(typed("verschiebe Radfotos nach Dokumente", { takeId: "t2" })));
  assert.equal(move.title, "„Radfotos“ nach Dokumente verschieben");
  assert.deepEqual(argvOf(ops, "t2"), [["/bin/mv", "-n", "--", "/Users/fixture/Desktop/Radfotos", "/Users/fixture/Documents/Radfotos"]]);
  // An existing ~/ path (the isDirectory seam) is a destination; one that is not a directory is unresolved.
  const path = asAct(await dispatcher.dispatch(typed("kopiere Radfotos nach ~/Projects", { takeId: "t3" })));
  assert.equal(path.title, "„Radfotos“ nach „Projects“ kopieren");
  assert.deepEqual(argvOf(ops, "t3"), [["/bin/cp", "-R", "-n", "--", "/Users/fixture/Desktop/Radfotos", "/Users/fixture/Projects/Radfotos"]]);
  for (const text of ["kopiere Radfotos", "kopiere Radfotos nach ~/Nope", "kopiere Radfotos nach Nirgendwo"]) {
    const where = asList(await dispatcher.dispatch(typed(text, { takeId: `w-${text.length}` })));
    assert.equal(where.title, "Wohin soll „Radfotos“ kopiert werden?", text);
    assert.deepEqual(rows(where.card).map((row) => [row.title, row.subtitle]), [
      ["Dokumente", "~/Documents"], ["Downloads", "~/Downloads"], ["Bilder", "~/Pictures"], ["Musik", "~/Music"], ["Filme", "~/Movies"], ["Benutzerordner", "~"],
    ], "the item's own folder is no destination");
    assert.equal(ops.forTake(`w-${text.length}`).length, 6, text);
  }
  assert.equal(asList(await dispatcher.dispatch(typed("verschiebe Radfotos"))).title, "Wohin soll „Radfotos“ verschoben werden?");
  // The item's own folder: a copy is a duplicate, a move answers; into itself is refused.
  assert.equal(asAct(await dispatcher.dispatch(typed("kopiere Radfotos nach Schreibtisch"))).title, "„Radfotos“ duplizieren");
  assert.equal(asAnswer(await dispatcher.dispatch(typed("verschiebe Radfotos auf den Schreibtisch"))).title, "„Radfotos“ liegt schon in Schreibtisch.");
  assert.equal(asAnswer(await dispatcher.dispatch(typed("verschiebe Radfotos nach Radfotos"))).title, "„Radfotos“ kann nicht in sich selbst verschoben werden.");
  // A visible folder as the destination.
  const windowed = make(WITH_PATH);
  const into = asAct(await windowed.dispatcher.dispatch(typed("kopiere test.txt in den Ordner Archiv")));
  assert.equal(into.title, "„test.txt“ nach „Archiv“ kopieren");
  assert.deepEqual(argvOf(windowed.ops, "take-typed"), [["/bin/cp", "-R", "-n", "--", "/Users/fixture/Desktop/test.txt", "/Users/fixture/Desktop/Archiv/test.txt"]]);
});

test("duplicate and rename: Finder's \"Kopie\" names, the new name as said, never onto an existing name", async () => {
  const { dispatcher, ops } = make(DESKTOP);
  const duplicate = asAct(await dispatcher.dispatch(typed("dupliziere Notizen", { takeId: "d1" })));
  assert.equal(duplicate.title, "„Notizen.txt“ duplizieren");
  assert.deepEqual(argvOf(ops, "d1"), [["/bin/cp", "-R", "-n", "--", "/Users/fixture/Desktop/Notizen.txt", "/Users/fixture/Desktop/Notizen Kopie.txt"]]);
  asAct(await dispatcher.dispatch(typed("duplicate Radfotos", { locale: "en-US", takeId: "d2" })));
  assert.deepEqual(argvOf(ops, "d2"), [["/bin/cp", "-R", "-n", "--", "/Users/fixture/Desktop/Radfotos", "/Users/fixture/Desktop/Radfotos copy"]]);
  const rename = asAct(await dispatcher.dispatch(typed("benenne Radfotos in Radtour um", { takeId: "r1" })));
  assert.equal(rename.title, "„Radfotos“ in „Radtour“ umbenennen");
  assert.deepEqual(argvOf(ops, "r1"), [["/bin/mv", "-n", "--", "/Users/fixture/Desktop/Radfotos", "/Users/fixture/Desktop/Radtour"]]);
  assert.equal(asAnswer(await dispatcher.dispatch(typed("benenne Radfotos in Fotos um"))).title, "„Fotos“ gibt es hier schon.");
  assert.equal(asAnswer(await dispatcher.dispatch(typed("rename Radfotos to Radfotos", { locale: "en-US" }))).title, "“Radfotos” already has that name.");
  assert.equal(asAnswer(await dispatcher.dispatch(typed("benenne Radfotos in .versteckt um"))).title, "„.versteckt“ ist kein gültiger Name.");
});

// ---------------------------------------------------------------- close

test("close: the take's Finder window by its folder name, else an app of exactly that name (graceful quit), else today's", async () => {
  const windowed = make(WITH_PATH);
  const window = asAct(await windowed.dispatcher.dispatch(typed("schließe Projekte")));
  assert.deepEqual([window.intent, window.title, window.action, window.confirm], ["close", "Fenster „Projekte“ schließen", { type: "closeFinderWindow", contextId: "ctx-desk" }, false]);
  const spokenWindow = asAct(await windowed.dispatcher.dispatch(spoken([DE("Schließe Projekte.")])));
  assert.deepEqual(spokenWindow.voice, { heard: "projekte", source: "apple-dt/de-DE", via: "file" });

  const { dispatcher } = make(DESKTOP);
  const quit = asAct(await dispatcher.dispatch(typed("beende Safari")));
  assert.deepEqual([quit.intent, quit.title, quit.action], ["close", "Safari beenden", { type: "quitApp", bundleId: "com.apple.Safari" }]);
  const fixture = readJson<Act>("instant/act-close-quit-app.json");
  const quitEn = asAct(await dispatcher.dispatch(typed("quit Safari", { locale: "en-US" })));
  assert.deepEqual([quitEn.intent, quitEn.title, quitEn.action, quitEn.confirm, quitEn.card], [fixture.intent, fixture.title, fixture.action, fixture.confirm, undefined]);
  assert.deepEqual(asAct(await dispatcher.dispatch(typed("schließe Notizen"))).action, { type: "quitApp", bundleId: "com.apple.Notes" }, "an app's alias");
  const today = make(DESKTOP, { lane: false });
  assert.equal(stable(await dispatcher.dispatch(typed("schließe Nirgendwo"))), stable(await today.dispatcher.dispatch(typed("schließe Nirgendwo"))));
  assert.equal(asAnswer(await make(FINDER_WINDOW).dispatcher.dispatch(typed("schließe Nirgendwo"))).title, "Ich sehe nicht, welcher Ordner das ist.");
});

// ---------------------------------------------------------------- safety

test("safety: the home folder's own folders, Library and app bundles are never targets; nothing is staged for them", async () => {
  const home = windowOf("/Users/fixture", [
    item("tok_documents001", "Documents", "/Users/fixture/Documents"), item("tok_library00001", "Library", "/Users/fixture/Library"),
    item("tok_desktop00001", "Desktop", "/Users/fixture/Desktop"), item("tok_projekte0001", "Projekte", "/Users/fixture/Projekte"),
  ]);
  const { dispatcher, ops } = make(home);
  for (const text of ["lösche Documents", "verschiebe Library nach Dokumente", "benenne Desktop in Schreibtisch2 um", "kopiere Documents nach Downloads"]) {
    const answer = asAnswer(await dispatcher.dispatch(typed(text)));
    assert.match(answer.title, /^pi-os rührt „(?:Documents|Library|Desktop)“ nicht an\.$/u, text);
    assert.ok(validCard(answer.card));
  }
  assert.equal(ops.size, 0);
  // An ordinary folder in the home window is fine.
  asAct(await dispatcher.dispatch(typed("lösche Projekte")));
  assert.deepEqual(argvOf(ops, "take-typed"), [["/bin/rm", "-r", "--", "/Users/fixture/Projekte"]]);
});

// ---------------------------------------------------------------- voice gating

test("voice: the host's pick decides; doubt, a first-tier reading against it or a different command leave the take to today's lane; a lone low peer needs one Return", async () => {
  const lane = make(DESKTOP);
  const today = make(DESKTOP, { lane: false });
  const same = async (request: InstantRequest, label: string): Promise<void> => {
    assert.equal(stable(await lane.dispatcher.dispatch(request)), stable(await today.dispatcher.dispatch(request)), label);
  };
  await same(spoken([P("Lösche Radfotos.", { minConfidence: 0.1 })]), "low word confidence");
  await same(spoken([DE("Lösche Radfotos.", 0.3), EN("Open Spotify now please.", 0.3)]), "disagreeing readings at a low mean");
  await same(spoken([DE("Lösche Radfotos."), EN("Delete this.")]), "a deictic peer");
  await same(spoken([DE("Lösche Radfotos."), EN("Delete Fotos.")]), "a different file command");
  await same(spoken([DE("Lösche Radfotos."), EN("Lösche den Ordner und dann Safari.")]), "a compound peer");
  // Agreeing readings act at once.
  const agreed = asAct(await lane.dispatcher.dispatch(spoken([DE("Lösche Radfotos.", 0.3), EN("Delete Radfotos.", 0.3)])));
  assert.equal(agreed.confirm, false);
  // A lone peer below 0.4: one Return; a host without confirm: today's.
  const held = asAct(await lane.dispatcher.dispatch(spoken([DE("Lösche Radfotos.", 0.3)], { takeId: "take-held" })));
  assert.equal(held.confirm, true);
  await same(spoken([DE("Lösche Radfotos.", 0.3)], { accept: ["suggest", "check"] }), "a held act without confirm");
  // "frag pi …" is for pi.
  await same(spoken([P("Frag pi lösche Radfotos.")]), "frag pi");
  await same(typed("frag pi lösche Radfotos"), "frag pi typed");
});

test("previews show an act's plan and stage nothing; finals stage; a preview without a sure plan is today's", async () => {
  const lane = make(DESKTOP);
  const today = make(DESKTOP, { lane: false });
  await lane.warm();
  await today.warm();
  for (const request of [
    typed("lösche Radfotos", { phase: "typing" }), { text: "Lösche Radfotos", phase: "partial", seq: 1, inputMode: "voice", locale: "de-DE", contextId: "ctx-desk" } as InstantRequest,
  ]) {
    const preview = asAnswer(await lane.dispatcher.dispatch(request));
    assert.deepEqual([preview.intent, preview.title, preview.card], ["file_op", "Löschen: Radfotos", noticeCard("info", "Löschen: Radfotos", "Löschen: Radfotos")]);
  }
  const closing = asAnswer(await lane.dispatcher.dispatch(typed("beende Safari", { phase: "typing" })));
  assert.deepEqual([closing.intent, closing.title], ["close", "Safari beenden"]);
  assert.equal(lane.ops.size, 0, "previews never stage");
  for (const text of ["lösche tset", "lösche t", "kopiere Radfotos", "lösche Radfotoss"]) {
    const request = typed(text, { phase: "typing" });
    assert.equal(stable(await lane.dispatcher.dispatch(request)), stable(await today.dispatcher.dispatch(request)), text);
  }
  assert.equal(lane.ops.size, 0);
});

// ---------------------------------------------------------------- the fill lane, the confirm gate, learning

test("fill: a file command where the lane applies is never typed into a focused field; elsewhere the same words are today's", async () => {
  const lane = make(DESKTOP);
  const finderSearch: InstantTarget = { app: "finder", field: { kind: "search", empty: true, ready: true } };
  const act = asAct(await lane.dispatcher.dispatch(spoken([P("Kopiere Radfotos nach Dokumente.")], { accept: ALL, target: finderSearch })));
  assert.equal(act.intent, "file_op");
  // The lane leaves a doubtful take to today's lane: still a command, never typed or offered for typing.
  const doubtful = await lane.dispatcher.dispatch(spoken([P("Kopiere Radfotos nach Dokumente.", { minConfidence: 0.1 })], { accept: ALL, target: finderSearch }));
  assert.ok(!(doubtful.decision === "act" && doubtful.intent === "fill"), JSON.stringify(doubtful));
  assert.ok(!(doubtful.decision === "fallthrough" && doubtful.voice?.fill), JSON.stringify(doubtful));
  // No desktop or Finder window (a chat): "Close enough." decides exactly as without the lane.
  const chat: InstantTarget = { app: "other", field: { kind: "multiline", empty: false, ready: true } };
  const none = make(NONE);
  const noneToday = make(NONE, { lane: false });
  for (const text of ["Close enough.", "Move on.", "Kopiere den Link nach oben."]) {
    const request = spoken([P(text)], { accept: ALL, target: chat, locale: "en-US" });
    assert.equal(stable(await none.dispatcher.dispatch(request)), stable(await noneToday.dispatcher.dispatch(request)), text);
  }
});

test("typed finals that declare confirm (the macOS host now does) keep today's open and fill decisions; only the file delete uses it", async () => {
  const lane = make(DESKTOP);
  // A typed visible sound-alike stays the one-row did-you-mean.
  const open = asList(await lane.dispatcher.dispatch(typed("open radfoto", { accept: ["confirm"], locale: "en-US" })));
  assert.equal(open.title, "Did you mean Radfotos?");
  const withoutConfirm = asList(await lane.dispatcher.dispatch(typed("open radfoto", { locale: "en-US" })));
  assert.equal(stable(open), stable(withoutConfirm));
  // A typed "tippe …" with deletion words is dropped, not held for one Return.
  const target: InstantTarget = { app: "other", field: { kind: "multiline", empty: true, ready: true } };
  for (const accept of [["fill"], ["fill", "confirm"], ALL] as InstantAccept[][]) {
    const response = await lane.dispatcher.dispatch(typed("tippe lösche den Absatz", { accept, target, inputMode: "text" }));
    assert.ok(!(response.decision === "act" && response.intent === "fill"), `${accept.join(",")}: ${JSON.stringify(response)}`);
  }
  // A spoken one is still held (voice keeps the one-Return fill).
  const spokenHeld = asAct(await lane.dispatcher.dispatch(spoken([P("Tippe lösche den Absatz.")], { accept: ALL, target })));
  assert.deepEqual([spokenHeld.intent, spokenHeld.confirm], ["fill", true]);
});

test("nothing is learned from a file command, and \"No, I meant X\" never aims at it or past it", async () => {
  const takeMemo = new InMemoryTakeMemo();
  const { dispatcher } = make(DESKTOP, { deps: { takeMemo } });
  // An older act the memo knows.
  const opening = spoken([P("Öffne Spotify.")], { takeId: "take-open" });
  takeMemo.remember(takeRecordFor(opening, await dispatcher.dispatch(opening), Date.now())!);
  const request = spoken([P("Lösche Radfotos.")], { takeId: "take-file" });
  const act = asAct(await dispatcher.dispatch(request));
  const record = takeRecordFor(request, act, Date.now())!;
  assert.deepEqual([record.fileOp, record.offered, record.acted], [true, [], undefined]);
  takeMemo.remember(record);
  assert.equal(takeMemo.latestActed(), undefined, "a correction never aims past the file command at the older open");
  // Every gesture against the take is refused.
  const store = new DictionaryStore({ persist: false });
  const lane = createLearnLane({ dispatcher: createInstantDispatcher({ scorer: NO_CONTEXT_SCORER, dictionary: NO_DICTIONARY }), apps: () => APPS });
  for (const gesture of [{ kind: "pick", bundleId: "com.spotify.client" }, { kind: "confirm" }, { kind: "edit", correctedText: "öffne Radfotos" },
    { kind: "no_i_meant", correctedText: "Spotify" }, { kind: "reject" }] as const) {
    const learned = await learnFromGesture({ takeId: "take-file", ...gesture } as Parameters<typeof learnFromGesture>[0], { store, memo: takeMemo, lane });
    assert.deepEqual([learned.status, learned.code], ["refused", "nothing_to_learn"], gesture.kind);
  }
  // "nein, ich meinte Fotos" right after: no correction (no correctsTakeId), no act on Fotos.
  const after = await dispatcher.dispatch(spoken([P("Nein, ich meinte Fotos.")], { takeId: "take-after" }));
  assert.ok(!(after.decision === "act"), JSON.stringify(after));
  assert.ok(!("voice" in after && after.voice?.correctsTakeId), JSON.stringify(after));
  // Lists and answers are file-command takes too.
  const list = await dispatcher.dispatch(spoken([P("Lösche Radfotoss.")], { takeId: "take-list" }));
  assert.equal(takeRecordFor(spoken([P("Lösche Radfotoss.")], { takeId: "take-list" }), list, Date.now())?.fileOp, true);
});

// ---------------------------------------------------------------- exact names, packages, protected roots, incomplete views

test("a said extension must be the item's: \"Bericht.pdf\" never deletes the folder \"Bericht\", \"Entwurf 2.1\" never \"Entwurf 2\", \"notes.txt\" never \"notes.md\" — offered, never acted on", async () => {
  const shown = windowOf("/Users/fixture/Projekte", [
    item("tok_bericht00001", "Bericht", "/Users/fixture/Projekte/Bericht"),
    item("tok_entwurf20001", "Entwurf 2", "/Users/fixture/Projekte/Entwurf 2"),
    item("tok_notesmd00001", "notes.md", "/Users/fixture/Projekte/notes.md", { isDirectory: false, contentType: "net.daringfireball.markdown" }),
  ]);
  const { dispatcher } = make(shown);
  for (const [text, offered] of [
    ["lösche Bericht.pdf", "Bericht"], ["lösche Entwurf 2.1", "Entwurf 2"], ["lösche notes.txt", "notes.md"],
    ["verschiebe Bericht.pdf nach Dokumente", "Bericht"], ["benenne notes.txt in alt.txt um", "notes.md"], ["kopiere Entwurf 2.1 nach Dokumente", "Entwurf 2"],
    ["dupliziere notes.txt", "notes.md"],
  ] as const) {
    const list = asList(await dispatcher.dispatch(typed(text, { accept: ["confirm"], takeId: `x-${text}` })));
    assert.match(list.title, /nicht gefunden – meintest du …\?$/u, text);
    assert.deepEqual(rows(list.card).map((row) => row.title), [offered], text);
  }
  const spokenList = asList(await dispatcher.dispatch(spoken([P("Lösche Bericht.pdf.")])));
  assert.deepEqual(rows(spokenList.card).map((row) => row.title), ["Bericht"]);

  // The item that has the said extension or version acts; the name without one still finds every item of that name.
  const versions = windowOf("/Users/fixture/Projekte", [
    item("tok_entwurf20001", "Entwurf 2", "/Users/fixture/Projekte/Entwurf 2"),
    item("tok_entwurf21001", "Entwurf 2.1", "/Users/fixture/Projekte/Entwurf 2.1"),
    item("tok_berichtpdf01", "Bericht.pdf", "/Users/fixture/Projekte/Bericht.pdf", { isDirectory: false, contentType: "com.adobe.pdf" }),
    item("tok_bericht00001", "Bericht", "/Users/fixture/Projekte/Bericht"),
  ]);
  const exact = make(versions);
  asAct(await exact.dispatcher.dispatch(typed("lösche Entwurf 2.1", { takeId: "v1" })));
  assert.deepEqual(argvOf(exact.ops, "v1"), [["/bin/rm", "-r", "--", "/Users/fixture/Projekte/Entwurf 2.1"]]);
  asAct(await exact.dispatcher.dispatch(typed("lösche Entwurf 2", { takeId: "v2" })));
  assert.deepEqual(argvOf(exact.ops, "v2"), [["/bin/rm", "-r", "--", "/Users/fixture/Projekte/Entwurf 2"]]);
  const pdf = asAct(await exact.dispatcher.dispatch(typed("lösche Bericht.pdf", { accept: ["confirm"], takeId: "v3" })));
  assert.equal(pdf.title, "„Bericht.pdf“ endgültig löschen?");
  assert.deepEqual(argvOf(exact.ops, "v3"), [["/bin/rm", "--", "/Users/fixture/Projekte/Bericht.pdf"]]);
  const which = asList(await exact.dispatcher.dispatch(typed("lösche Bericht", { takeId: "v4" })));
  assert.equal(which.title, "Welches „Bericht“ meinst du?");
  assert.deepEqual(rows(which.card).map((row) => row.title).sort(), ["Bericht", "Bericht.pdf"]);
  // A file whose name ends in a version ("Entwurf 2.1", no extension) is that whole name, never "Entwurf 2".
  const file = make(windowOf("/Users/fixture/Projekte", [
    item("tok_entwurffile1", "Entwurf 2.1", "/Users/fixture/Projekte/Entwurf 2.1", { isDirectory: false, contentType: "public.data" }),
  ]));
  assert.equal(asList(await file.dispatcher.dispatch(typed("lösche Entwurf 2", { accept: ["confirm"] }))).decision, "list");
  assert.equal(asAct(await file.dispatcher.dispatch(typed("lösche Entwurf 2.1", { accept: ["confirm"], takeId: "f1" }))).title, "„Entwurf 2.1“ endgültig löschen?");
  // A visible folder as a destination is matched the same way.
  const dest = make(windowOf("/Users/fixture/Projekte", [
    item("tok_archiv000001", "Archiv", "/Users/fixture/Projekte/Archiv"),
    item("tok_testtxt00001", "test.txt", "/Users/fixture/Projekte/test.txt", { isDirectory: false, contentType: "public.plain-text" }),
  ]));
  assert.equal(asList(await dest.dispatcher.dispatch(typed("kopiere test.txt nach Archiv.zip"))).title, "Wohin soll „test.txt“ kopiert werden?");
});

test("a package (the host sends isDirectory false, isPackage true) is a folder for every plan: rm -r with dcg's dialog only, and the run's kind check agrees", async () => {
  const { dispatcher, ops } = make(DESKTOP);
  const del = asAct(await dispatcher.dispatch(typed("lösche Präsentation.key", { accept: ["confirm"], takeId: "p1" })));
  assert.deepEqual([del.title, del.confirm], ["Löschen: Präsentation.key", false]);
  const [op] = ops.forTake("p1");
  assert.deepEqual([op?.plan.argv, op?.plan.sourceDir], [["/bin/rm", "-r", "--", "/Users/fixture/Desktop/Präsentation.key"], true]);
  asAct(await dispatcher.dispatch(typed("verschiebe Präsentation nach Dokumente", { takeId: "p2" })));
  assert.deepEqual(ops.forTake("p2").map((staged) => [staged.plan.argv, staged.plan.sourceDir]),
    [[["/bin/mv", "-n", "--", "/Users/fixture/Desktop/Präsentation.key", "/Users/fixture/Documents/Präsentation.key"], true]]);
  asAct(await dispatcher.dispatch(typed("dupliziere Präsentation", { takeId: "p3" })));
  assert.deepEqual(argvOf(ops, "p3"), [["/bin/cp", "-R", "-n", "--", "/Users/fixture/Desktop/Präsentation.key", "/Users/fixture/Desktop/Präsentation Kopie.key"]]);
});

test("the startup disk's top level, /Applications, /opt and other users' folders are never targets: \"pi-os won't touch\"", async () => {
  const root = windowOf("/", [
    item("tok_appsfolder01", "Applications", "/Applications"), item("tok_usersfolder1", "Users", "/Users"), item("tok_optfolder0001", "opt", "/opt"),
    item("tok_library00002", "Library", "/Library"),
  ]);
  const { dispatcher, ops } = make(root);
  for (const [text, name] of [["lösche Applications", "Applications"], ["lösche Users", "Users"], ["lösche opt", "opt"], ["benenne Library in Bib um", "Library"],
    ["verschiebe Applications nach Dokumente", "Applications"]] as const) {
    assert.equal(asAnswer(await dispatcher.dispatch(typed(text))).title, `pi-os rührt „${name}“ nicht an.`, text);
  }
  const users = make(windowOf("/Users", [item("tok_shared000001", "Shared", "/Users/Shared"), item("tok_otheruser001", "anna", "/Users/anna")]));
  for (const text of ["lösche Shared", "lösche anna"]) assert.match(asAnswer(await users.dispatcher.dispatch(typed(text))).title, /^pi-os rührt „/u, text);
  const apps = make(windowOf("/Applications", [item("tok_utilities001", "Utilities", "/Applications/Utilities")]));
  assert.equal(asAnswer(await apps.dispatcher.dispatch(typed("lösche Utilities"))).title, "pi-os rührt „Utilities“ nicht an.");
  assert.equal(ops.size + users.ops.size + apps.ops.size, 0);
});

test("an incomplete view: a delete, move or rename of the one match is a one-row list (another item of that name may be unread); a copy still acts", async () => {
  const { dispatcher, ops } = make(FINDER_WINDOW);
  for (const [index, text] of ["lösche Alpen", "verschiebe Alpen nach Dokumente", "benenne Alpen in Berge um"].entries()) {
    const list = asList(await dispatcher.dispatch(typed(text, { accept: ["confirm"], takeId: `i${index}` })));
    assert.equal(list.title, "Welches „Alpen“ meinst du?", text);
    assert.deepEqual(rows(list.card).map((row) => [row.title, row.subtitle, row.opId]), [["Alpen.jpg", "in Touren", ops.forTake(`i${index}`)[0]?.opId]], text);
  }
  asAct(await dispatcher.dispatch(typed("kopiere Alpen nach Dokumente", { takeId: "i-copy" })));
  // A complete view acts on its one match as before.
  const complete = make({ ...FINDER_WINDOW, sources: [{ kind: "finderWindow", via: "ax", complete: true }] });
  asAct(await complete.dispatcher.dispatch(typed("verschiebe Alpen nach Dokumente")));
});

// ---------------------------------------------------------------- close with a window noun; voice readings

test("close with a window noun never quits an app: \"close the Safari window\" is today's unless it names the take's Finder window", async () => {
  const lane = make(DESKTOP);
  const today = make(DESKTOP, { lane: false });
  for (const [text, locale] of [["close the Safari window", "en-US"], ["schließe das Safari-Fenster", "de-DE"], ["schließe das Fenster Safari", "de-DE"]] as const) {
    const request = typed(text, { locale });
    const response = await lane.dispatcher.dispatch(request);
    assert.ok(!(response.decision === "act" && response.action.type === "quitApp"), `${text}: ${JSON.stringify(response)}`);
    assert.equal(stable(response), stable(await today.dispatcher.dispatch(request)), text);
  }
  const voice = await lane.dispatcher.dispatch(spoken([DE("Schließe das Safari-Fenster.")]));
  assert.ok(!(voice.decision === "act" && voice.action.type === "quitApp"), JSON.stringify(voice));
  // Without the noun it is the app; with it, the take's Finder window by its folder name.
  assert.deepEqual(asAct(await lane.dispatcher.dispatch(typed("schließe Safari"))).action, { type: "quitApp", bundleId: "com.apple.Safari" });
  assert.deepEqual(asAct(await make(WITH_PATH).dispatcher.dispatch(typed("schließe das Projekte-Fenster"))).action, { type: "closeFinderWindow", contextId: "ctx-desk" });
  assert.equal(asAnswer(await make(FINDER_WINDOW).dispatcher.dispatch(typed("schließe das Safari-Fenster"))).title, "Ich sehe nicht, welcher Ordner das ist.");
});

test("voice: delete, move and rename take the words as said when they name an item (\"Delete Backup Now\"); two readings naming different items act on neither", async () => {
  const backup = item("tok_backup000001", "Backup", "/Users/fixture/Projekte/Backup");
  const backupNow = item("tok_backupnow001", "Backup Now", "/Users/fixture/Projekte/Backup Now");
  const said = (text: string, takeId = "take-voice") => spoken([P(text)], { locale: "en-US", takeId });
  // Both there: the spoken core ("now" is a softener) names "Backup", the words as said "Backup Now" — neither acts.
  const both = make(windowOf("/Users/fixture/Projekte", [backup, backupNow]));
  const today = make(windowOf("/Users/fixture/Projekte", [backup, backupNow]), { lane: false });
  assert.equal(stable(await both.dispatcher.dispatch(said("Delete Backup Now."))), stable(await today.dispatcher.dispatch(said("Delete Backup Now."))));
  assert.equal(both.ops.size, 0);
  // Only "Backup Now": the words as said.
  const only = make(windowOf("/Users/fixture/Projekte", [backupNow]));
  asAct(await only.dispatcher.dispatch(said("Delete Backup Now.")));
  assert.deepEqual(argvOf(only.ops, "take-voice"), [["/bin/rm", "-r", "--", "/Users/fixture/Projekte/Backup Now"]]);
  // Only "Backup": the spoken core, as for fillers ("äh, …") and softeners.
  const core = make(windowOf("/Users/fixture/Projekte", [backup]));
  asAct(await core.dispatcher.dispatch(said("Delete Backup Now.")));
  assert.deepEqual(argvOf(core.ops, "take-voice"), [["/bin/rm", "-r", "--", "/Users/fixture/Projekte/Backup"]]);
  asAct(await core.dispatcher.dispatch(spoken([P("Äh, kannst du Backup löschen?")], { takeId: "take-filler" })));
  // Both readings name the same item: the core decides ("now" is no part of the new name).
  asAct(await core.dispatcher.dispatch(said("Rename Backup to Archive now.", "take-rename")));
  assert.deepEqual(argvOf(core.ops, "take-rename"), [["/bin/mv", "-n", "--", "/Users/fixture/Projekte/Backup", "/Users/fixture/Projekte/Archive"]]);
  // Typed words are the words as said.
  asAct(await both.dispatcher.dispatch(typed("delete Backup Now", { locale: "en-US", takeId: "typed-now" })));
  assert.deepEqual(argvOf(both.ops, "typed-now"), [["/bin/rm", "-r", "--", "/Users/fixture/Projekte/Backup Now"]]);
});

test("voice: a delete, move or rename needs every first-tier reading to say it — another command or words that parse as nothing keep today's handling", async () => {
  const lane = make(DESKTOP);
  const today = make(DESKTOP, { lane: false });
  for (const [label, request] of [
    ["an open peer", spoken([DE("Lösche Radfotos."), EN("Öffne Radfotos.")])],
    ["an unparsed peer", spoken([DE("Lösche Radfotos."), EN("Lush rat photos.")])],
    ["a move with an open peer", spoken([DE("Verschiebe Radfotos nach Dokumente."), EN("Open Radfotos.")])],
    ["a rename with an open peer", spoken([DE("Benenne Radfotos in Radtour um."), EN("Open Radfotos.")])],
  ] as const) {
    assert.equal(stable(await lane.dispatcher.dispatch(request)), stable(await today.dispatcher.dispatch(request)), label);
  }
  assert.equal(lane.ops.size, 0);
  // Other ops keep the agreement rule they had: another command as a peer does not stop a duplicate.
  asAct(await lane.dispatcher.dispatch(spoken([DE("Dupliziere Radfotos."), EN("Open Radfotos.")], { takeId: "take-dup" })));
});

// ---------------------------------------------------------------- golden: without the lane, today's decisions byte for byte

const GOLDEN_TEXTS: readonly [string, string][] = [
  // File commands of every op.
  ["lösche Radfotos", "de-DE"], ["Lösche Notizen.", "de-DE"], ["delete Radfotos", "en-US"], ["lösche tset", "de-DE"], ["kopiere Radfotos nach Dokumente", "de-DE"],
  ["verschiebe Radfotos nach Downloads", "de-DE"], ["erstelle Ordner Projekte", "de-DE"], ["neue Datei notes.txt", "de-DE"], ["benenne Radfotos in Radtour um", "de-DE"],
  ["dupliziere Notizen", "de-DE"], ["beende Safari", "de-DE"], ["schließe Downloads", "de-DE"], ["quit Safari", "en-US"], ["Lösche den Ordner Radfotos.", "de-DE"],
  // The deletion policy's shapes and everything else.
  ["Lösche den Ordner ~/pi-os-dcg-probe", "de-DE"], ["rm -r ~/x", "en-US"], ["move X to the trash", "en-US"], ["Papierkorb leeren", "de-DE"],
  ["delete the zip files", "en-US"], ["lösche alle Dateien", "de-DE"], ["i want to uninstall slack", "en-US"], ["Lösche Pages.", "de-DE"], ["open pages", "en-US"],
  ["15% of 340", "en-US"], ["delete the last sentence", "en-US"], ["lösche den Termin", "de-DE"], ["how do I empty the trash", "en-US"], ["delete it", "en-US"],
  ["Albert Einstein", "de-DE"], ["Öffne Radfotos.", "de-DE"], ["open radfoto", "en-US"], ["close enough", "en-US"], ["copy that", "en-US"],
];

function forms(text: string, locale: string, contextId: string | undefined): InstantRequest[] {
  const context = contextId ? { contextId } : {};
  const base = { text, seq: 1, locale, ...context };
  return [
    { ...base, phase: "final" }, { ...base, phase: "final", accept: ["confirm"] }, { ...base, phase: "typing" },
    { ...base, phase: "final", inputMode: "voice", hypotheses: [P(text)], accept: ACCEPT, takeId: "golden" },
    { ...base, phase: "partial", inputMode: "voice" },
  ];
}

test("golden: lane off, no visible items from the desktop or a Finder window, or no context → every decision exactly as without the lane", async () => {
  const today = make(DESKTOP, { lane: false });
  const off = make(DESKTOP, { active: () => false });
  const noneToday = make(NONE, { lane: false });
  const none = make(NONE);
  const on = make(DESKTOP);
  for (const [text, locale] of GOLDEN_TEXTS) {
    for (const [index, request] of forms(text, locale, "ctx-desk").entries()) {
      const label = `${index} ${text}`;
      const expected = stable(await today.dispatcher.dispatch(request));
      assert.equal(stable(await off.dispatcher.dispatch(request)), expected, `lane off: ${label}`);
      assert.equal(stable(await none.dispatcher.dispatch(request)), stable(await noneToday.dispatcher.dispatch(request)), `no visible items: ${label}`);
    }
    for (const request of forms(text, locale, undefined)) {
      assert.equal(stable(await on.dispatcher.dispatch(request)), stable(await today.dispatcher.dispatch(request)), `no context: ${text}`);
    }
  }
  assert.equal(off.ops.size + none.ops.size + on.ops.size, 0, "nothing staged without the lane");
  // The lane's switch is read only for words that are a file command.
  const counted = make(DESKTOP);
  for (const text of ["open pages", "15% of 340", "how do I empty the trash", "Albert Einstein", "Öffne Notion.", "delete the last sentence", "wie spät ist es in Tokio"]) {
    for (const request of forms(text, "de-DE", "ctx-desk")) await counted.dispatcher.dispatch(request);
  }
  assert.equal(counted.reads(), 0);
});

test("logs: the dispatcher's perf fields name the op kind and decision only, never a name or path", async () => {
  const lines: Record<string, unknown>[] = [];
  const { dispatcher } = make(DESKTOP, { deps: { perf: (_stage, _ms, fields) => { lines.push(fields); } } });
  await dispatcher.dispatch(typed("lösche Radfotos"));
  await dispatcher.dispatch(spoken([P("Kopiere Radfotos nach Dokumente.")]));
  await dispatcher.dispatch(typed("lösche tset"));
  assert.deepEqual(lines.map((fields) => [fields.decision, fields.kind, fields.parsed]), [
    ["act", "file_op", "file_delete"], ["act", "file_op", "file_copy"], ["answer", "file_op", "file_delete"],
  ]);
  assert.equal(lines[1]?.via, "file");
  const logged = JSON.stringify(lines);
  for (const content of ["Radfotos", "Dokumente", "tset", "/Users", "fixture"]) assert.ok(!logged.includes(content), content);
});
