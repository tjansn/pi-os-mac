import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { continuedTargetLine } from "../src/agent/agentRunner.js";
import { isOneLineText, parseHostAction } from "../src/contracts/actions.js";
import { NO_CONTEXT_SCORER } from "../src/contracts/context.js";
import {
  FILL_IMPLICIT_KINDS, FILL_NEVER_KINDS, FILL_OPT_IN_KINDS, fillActConsistent, INSTANT_FIELD_KINDS, parseInstantRequest, parseVoiceMeta,
  type InstantAccept, type InstantFieldKind, type InstantRequest, type InstantResponse, type InstantTarget, type IntentClassifier, type VoiceHypothesis,
} from "../src/contracts/instant.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { DictionaryStore } from "../src/instant/dictionary.js";
import { createInstantDispatcher, type InstantDispatcherDeps } from "../src/instant/dispatcher.js";
import {
  continuityOf, explicitRemainder, fieldTier, fillBody, fillOfferBody, hasPiPrefix, hasTaskHead, isControlUtterance, isCorrectionLike, isDictation,
  isPageQuestion, pointsAtScreenDe, searchQuery, secretMissBody, secretTarget, shapeFillText, voiceDoubt, FILL_REPLACE_MS,
} from "../src/instant/fill.js";
import { bareSearchQuery } from "../src/instant/grammar/launch.js";
import { learnFromGesture, REPLAY_ACCEPTS, type LearnLane } from "../src/instant/learned.js";
import { InMemoryTakeMemo, takeRecordFor, type TakeRecord } from "../src/instant/takeMemo.js";
import { validateCard } from "../src/ui/validate.js";
import { HOST_ACTION_TYPES } from "../src/contracts/actions.js";
import { createEvalLane, fixtureApps } from "../scripts/voice-eval.mjs";
import { fauxAssistantMessage, type AssistantMessage } from "@earendil-works/pi-ai";
import type { ContextWire } from "../src/contracts/context.js";
import { agentHost, captureLogs, fakeHost, fauxRuntimes, seen, start, tempCaptures, type SeenRequest } from "./integrationFixtures.js";

/*
 * Continuity's Node lane (DESIGN5 §4.6, §5.3–§5.4, §5.10–§5.11 with Tom's binding answers of 2026-10-08): what a
 * final with `accept: "fill"` and a `target` decides — the escapes, explicit dictation, "nein, X" after a fill, the
 * search forms, commands first, page questions and pi tasks to pi, everything else into the focused field — plus
 * the text shaping, the take memo, learning, the server's defense in depth and the agent's one sentence. Synthetic
 * text on the 104-app fixture index; no host, no model, no logs with content.
 */

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = <T>(path: string): T => JSON.parse(readFileSync(join(fixtures, path), "utf8")) as T;
const ALL: InstantAccept[] = ["suggest", "check", "confirm", "fill"];
const TODAY: InstantAccept[] = ["suggest", "check", "confirm"];
const APPS = fixtureApps();

function make(overrides: Partial<InstantDispatcherDeps> = {}) {
  return createInstantDispatcher({
    apps: new AppIndexCache(async () => ({ version: "1", apps: APPS })), localZone: () => "Europe/Berlin", homeDir: "/Users/fixture", ...overrides,
  });
}

const P = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "parakeet-v3", role: "primary", confidence: 0.92, minConfidence: 0.6, ...extra });
const field = (kind: InstantFieldKind, extra: Partial<NonNullable<InstantTarget["field"]>> = {}): NonNullable<InstantTarget["field"]> =>
  ({ kind, ...(kind === "credential" ? {} : { empty: true }), ready: true, ...extra });
const target = (kind: InstantFieldKind | null, app: InstantTarget["app"] = "other", extra: Partial<InstantTarget> = {}): InstantTarget =>
  ({ app, ...(kind ? { field: field(kind) } : {}), ...extra });

/** A voice final (Parakeet primary) with a target; `accept` defaults to every kind. */
const voice = (text: string, tgt: InstantTarget | undefined, extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text, phase: "final", seq: 1, inputMode: "voice", locale: "de-DE", hypotheses: [P(text)], accept: ALL, ...(tgt ? { target: tgt } : {}), ...extra,
});
const typed = (text: string, tgt: InstantTarget | undefined, extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text, phase: "final", seq: 1, inputMode: "text", locale: "de-DE", accept: ALL, ...(tgt ? { target: tgt } : {}), ...extra,
});

type Act = Extract<InstantResponse, { decision: "act" }>;
const isFill = (response: InstantResponse): boolean => response.decision === "act" && response.intent === "fill";
const fillOf = (response: InstantResponse): { text: string; submit: boolean; confirm: boolean } => {
  assert.ok(isFill(response), JSON.stringify(response));
  const action = (response as Act).action as { type: "typeIntoPinned"; text: string; submit?: true };
  return { text: action.text, submit: action.submit === true, confirm: (response as Act).confirm };
};
const offers = (response: InstantResponse): boolean => response.decision === "fallthrough" && response.voice?.fill === "offer";
/** The response without timing (two dispatches of the same request are byte-identical apart from it). */
const stable = (response: InstantResponse): string => JSON.stringify({ ...response, elapsedMs: 0, seq: 0 });

// ---------------------------------------------------------------- fill.ts: closed lists and shaping

test("continuity is read only from a final that declares fill and carries a target; secrets are any credential or sensitive field", () => {
  assert.equal(continuityOf(voice("x", target("search"), { accept: TODAY })), null);
  assert.equal(continuityOf(voice("x", undefined)), null);
  assert.equal(continuityOf({ ...voice("x", target("search")), phase: "partial" }), null);
  assert.deepEqual(continuityOf(voice("x", target("search", "browser", { anchor: { takeId: "take-1" } }))),
    { app: "browser", field: { kind: "search", ready: true, ownFill: false }, anchorTakeId: "take-1" });
  assert.deepEqual(continuityOf(voice("x", { app: "browser" })), { app: "browser" });
  for (const kind of INSTANT_FIELD_KINDS) {
    assert.equal(secretTarget({ target: target(kind) }), kind === "credential" || kind === "sensitive", kind);
    assert.equal(fieldTier(kind), (FILL_IMPLICIT_KINDS as readonly string[]).includes(kind) ? "implicit"
      : (FILL_OPT_IN_KINDS as readonly string[]).includes(kind) ? "optIn" : (FILL_NEVER_KINDS as readonly string[]).includes(kind) ? "never" : "explicit", kind);
  }
  assert.equal(fieldTier("terminal"), "explicit");
  assert.equal(secretTarget({}), false);
});

test("escapes: explicit dictation forms (EN/DE) and what is no dictation; the escape to pi; search forms", () => {
  for (const [said, remainder] of [
    ["Tippe Hallo Welt.", "Hallo Welt."], ["tipp Albert Einstein", "Albert Einstein"], ["Okay, tippe mal Liebe Grüße", "Liebe Grüße"],
    ["Type hello world", "hello world"], ["type in hello world", "hello world"], ["Dictate see you at five.", "see you at five."],
    ["Diktiere: Liebe Grüße, Anna", "Liebe Grüße, Anna"], ["Gib Albert Einstein ein.", "Albert Einstein"], ["Tippe: Das ist ein Test.", "Das ist ein Test."],
    ["Type open google", "open google"], ["Tippe nein", "nein"], ["Bitte tippe Hallo, bitte", "Hallo"], ["Tippe Bis morgen, danke.", "Bis morgen, danke."],
  ] as const) assert.equal(explicitRemainder(said), remainder, said);
  for (const said of [
    "type 2 diabetes symptoms", "type of cancer", "Tippe auf den Button", "tippe an", "tippe das", "type this", "Tippe das hier.",
    "type hello into the search box", "tippe Albert Einstein ins Suchfeld", "tippe hallo und drück Enter", "type hello and press enter",
    "typed", "Typ Albert", "write hello world", "Schreib Hallo", "gib mir ein Rezept", "tippe", "Gib die Nummer ein und drück Enter",
  ]) assert.equal(explicitRemainder(said), null, said);

  for (const said of ["Frag Pi, wie hoch ist der Eiffelturm?", "frag mal pi was das ist", "Ask pi what time it is", "Hey Pi, wie geht's?", "Pi, wer war Goethe?", "hey pie who wrote Hamlet"]) {
    assert.ok(hasPiPrefix(said), said);
  }
  for (const said of ["Pi mal zwei", "pie recipe", "Apple Pie", "frag Anna", "Albert Einstein", "pizza"]) assert.ok(!hasPiPrefix(said), said);

  for (const [said, query] of [
    ["Such nach Katzen.", "Katzen."], ["suche Rezept Lasagne", "Rezept Lasagne"], ["Such mal nach Hotels in Rom", "Hotels in Rom"], ["search for cats", "cats"],
    ["Search Albert Einstein", "Albert Einstein"], ["look for cheap flights, please", "cheap flights"], ["Okay, such nach Katzen bitte", "Katzen"],
  ] as const) assert.equal(searchQuery(said), query, said);
  for (const said of [
    "search the web for cats", "search online for cats", "search on youtube for cats", "search youtube for cats", "search google for cats",
    "search my files for invoices", "suche meine Rechnung", "such im Internet nach Katzen", "suche auf YouTube nach Katzen", "Suchmaschine", "searching",
    "search", "such nach",
  ]) assert.equal(searchQuery(said), null, said);
  assert.equal(bareSearchQuery("such nach Katzen"), "Katzen");
});

test("control words, corrections, page questions and pi tasks are never dictation; phrases and plain questions are", () => {
  for (const said of ["nein", "Nein.", "no", "ja", "okay", "Never mind.", "vergiss es", "Abbrechen", "rückgängig", "enter", "Los!", "senden", "danke", "Hmm.", "Äh", "Warte."]) {
    assert.ok(isControlUtterance(said), said);
    assert.ok(!isDictation(said), said);
  }
  for (const said of ["Nein, Marie Curie.", "no, Marie Curie", "No - I meant Notion", "nein ich meinte Notizen", "No, I meant the other one"]) assert.ok(isCorrectionLike(said), said);
  for (const said of ["No Country for Old Men", "Nein danke", "Nobody knows", "Neinhorn"]) assert.ok(!isCorrectionLike(said), said);
  for (const said of [
    "what is this page about", "Worum geht es auf dieser Seite?", "Was steht da?", "What does it say?", "summarize this page", "fasse die Seite zusammen",
    "worum geht's", "Lies mir das vor.", "Was bedeutet das?", "read it to me", "click the button", "make it bold",
  ]) assert.ok(isPageQuestion(said), said);
  for (const said of ["Albert Einstein", "Wie hoch ist der Eiffelturm?", "best pizza near me", "what's the capital of France"]) assert.ok(!isPageQuestion(said), said);
  // Review: German questions that point with "das"/"dem" are page questions like "is that true" / "should I buy this";
  // "das" as an article (German nouns are capitalized) is a plain question.
  for (const said of [
    "ist das wahr", "Ist das seriös?", "ist das ein Betrug", "sollte ich das kaufen", "kann ich dem trauen", "macht das Sinn", "Ergibt das überhaupt Sinn?",
    "gibt es das auch in blau", "Was ist daran falsch?", "Ist es wahr?", "Was ist das für ein Vogel?", "Wie funktioniert das?",
  ]) assert.ok(isPageQuestion(said) && pointsAtScreenDe(said) && !isDictation(said), said);
  for (const said of [
    "Wie groß ist das Universum?", "Was kostet das iPhone 16", "Wann beginnt das Oktoberfest?", "Wie wird das Wetter morgen", "Wo ist das nächste Krankenhaus?",
    "Was ist das beste Handy 2024", "Wie heißt das Lied", "gibt es Pizza in der Nähe", "Regnet es morgen?", "Ist das Wetter morgen gut?",
    "Das ist wahr", "Ich will das kaufen und mehr und noch mehr und so",
  ]) assert.ok(!pointsAtScreenDe(said), said);
  for (const said of ["Wie groß ist das Universum?", "Wann beginnt das Oktoberfest?", "Wie wird das Wetter morgen"]) assert.ok(isDictation(said), said);
  for (const said of [
    "Schreib eine Mail an Anna.", "Write an email to Tom", "Erstelle eine Präsentation", "remind me to call mom", "Erinnere mich morgen an den Zahnarzt",
    "Plan my trip to Rome", "Übersetze Guten Morgen ins Englische", "Explain quantum physics", "Erkläre mir Quantenphysik", "Neue Notiz Milch kaufen",
    "Tell me a joke", "Kannst du mir sagen, wie spät es ist?", "Can you help me with my taxes?", "Draft a reply to Anna", "Antworte Anna, dass ich komme",
    "fasse zusammen", "summarize", "Hilf mir bei der Steuer", "Vergleiche die Tarife", "Gib mir ein Rezept für Pfannkuchen", "Eine Mail an Anna schreiben",
    "Zeig mir die Fotos", "Such meine Rechnung", "Bitte übersetze das", "Let's plan the week", "Lass uns die Woche planen",
    "Quit Spotify", "Hide Pages", "Call Anna", "Get me App Store", "Mach Numbers open", "Spotify pause", "Nächster Song", "Beende Spotify",
    "Take a screenshot", "Lock the screen", "Restart the computer", "Shut down", "Log out", "Fahre den Mac herunter", "Sperre den Bildschirm",
  ]) assert.ok(hasTaskHead(said), said);
  for (const said of [
    "Albert Einstein", "Schreibtisch Ikea", "Erklärung Relativitätstheorie", "Vergleich Handytarife", "Erinnerungen an Paris", "Verfassung Deutschland",
    "Spiele für Kinder", "Wie kann ich eine Mail schreiben?", "New York Times", "Plan B", "Danke für die schnelle Antwort", "Thanks for the quick reply",
    "Call of Duty", "Hide and Seek", "Take On Me", "Running a bit late", "Lockscreen wallpaper",
    "Alarm für Cobra 11", "Musik von Queen", "Licht und Schatten", "Ton in Ton", "Wie kann ich mich abmelden?", "Refreshing drinks",
  ]) assert.ok(!hasTaskHead(said), said);
  for (const said of [
    "Albert Einstein", "Wie hoch ist der Eiffelturm?", "best pizza near me", "Danke für die schnelle Antwort!", "Thanks for the quick reply!",
    "Running a bit late, be there in ten minutes.", "Rechnung Telekom", "No Country for Old Men", "summary of the meeting",
  ]) assert.ok(isDictation(said), said);
  for (const said of ["Öffne Safari", "open the pod bay doors", "start a timer", "Click the blue button.", "Scroll down", "Send.", "Show me photos from last week"]) {
    assert.ok(!isDictation(said), said);
  }
});

test("text shaping: one line, spoken punctuation, trailing period per field kind, case/umlauts/emoji kept, null when nothing is left", () => {
  const cases: readonly (readonly [string, InstantFieldKind, string | null])[] = [
    ["Albert Einstein.", "search", "Albert Einstein"], ["Albert Einstein.", "address", "Albert Einstein"], ["Albert Einstein.", "text", "Albert Einstein"],
    ["Albert Einstein.", "multiline", "Albert Einstein."], ["Sommer 2024.", "credential", "Sommer 2024"], ["4711.", "sensitive", "4711"],
    ["Ich komme. Bis gleich.", "text", "Ich komme. Bis gleich."], ["Wie hoch ist der Eiffelturm?", "search", "Wie hoch ist der Eiffelturm?"],
    ["U.S.A.", "search", "U.S.A."], ["Plan A.", "search", "Plan A."], ["Warte...", "search", "Warte..."],
    ["Hallo Komma wie geht's Fragezeichen", "multiline", "Hallo, wie geht's?"], ["hello comma how are you question mark", "multiline", "hello, how are you?"],
    ["Achtung Ausrufezeichen", "text", "Achtung!"], ["Liste Doppelpunkt Milch", "multiline", "Liste: Milch"], ["auf den Punkt gebracht", "multiline", "auf den Punkt gebracht"],
    ["Wir treffen uns Punkt", "multiline", "Wir treffen uns."], ["see you full stop", "multiline", "see you."], ["Komma", "multiline", "Komma"],
    ["a\nb\rc\td\u2028e\u0085f", "multiline", "a b c d e f"], ["  Grüße   aus  Köln  ", "multiline", "Grüße aus Köln"], ["Straße ÄÖÜ 🎉", "text", "Straße ÄÖÜ 🎉"],
    ["„Albert Einstein“", "search", "Albert Einstein"], ["\u200Bzero\u200B width\uFEFF", "text", "zero width"],
    ["...", "search", null], ["", "text", null], [" \n ", "multiline", null], ["x".repeat(501), "multiline", null],
  ];
  for (const [raw, kind, expected] of cases) {
    const shaped = shapeFillText(raw, kind);
    assert.equal(shaped, expected, `${JSON.stringify(raw)} → ${kind}`);
    if (shaped) assert.ok(isOneLineText(shaped), JSON.stringify(raw));
  }
});

test("fill bodies: typeIntoPinned one line, submit only in search boxes and the address bar, confirm, the replaced take, contract-consistent", () => {
  for (const kind of INSTANT_FIELD_KINDS) {
    const body = fillBody("Albert Einstein", kind, { submit: true, source: "parakeet-v3" });
    assert.equal(body.decision, "act");
    if (body.decision !== "act") continue;
    assert.equal(body.intent, "fill");
    assert.ok(fillActConsistent(body.intent, body.action), kind);
    assert.deepEqual(parseHostAction(body.action), body.action, kind);
    const submit = body.action.type === "typeIntoPinned" && body.action.submit === true;
    assert.equal(submit, kind === "search" || kind === "address", kind);
    assert.equal(body.title, submit ? "Search for Albert Einstein" : body.title, kind);
    if (!submit) assert.ok(!body.title.includes("Albert"), `${kind}: the title never carries the text`);
    assert.deepEqual(parseVoiceMeta(body.voice), { source: "parakeet-v3", via: "field" });
  }
  const held = fillBody("lösche den Absatz", "multiline", { confirm: true, replaces: "take-9" });
  assert.ok(held.decision === "act" && held.confirm && held.voice?.correctsTakeId === "take-9" && held.voice.source === undefined);
  assert.deepEqual(fillOfferBody("parakeet-v3"), { decision: "fallthrough", reason: "low_confidence", voice: { source: "parakeet-v3", check: true, fill: "offer" } });
  assert.deepEqual(secretMissBody(), { decision: "fallthrough", reason: "no_match" });
});

test("recognizer doubt: a low word confidence, or disagreeing first-tier readings at a low mean confidence; an unplaced utterance is no doubt", () => {
  assert.ok(voiceDoubt(P("Albert Einstein", { minConfidence: 0.1 }), []));
  assert.ok(!voiceDoubt(P("Albert Einstein"), []));
  const de = { text: "Albert Einstein", source: "apple-dt/de-DE", role: "peer" as const, confidence: 0.4 };
  const en = { text: "all bird Einstein lines", source: "apple-dt/en-US", role: "peer" as const, confidence: 0.4 };
  assert.ok(voiceDoubt(de, [de, en]));
  assert.ok(!voiceDoubt({ ...de, confidence: 0.8 }, [de, en]), "confident readings may disagree (Phase A peers garble each other)");
});

// ---------------------------------------------------------------- the dispatcher: golden fixtures and compatibility

test("shared fixtures: request-target-search answers act-fill-submit; the text and offer fixtures are what Node sends; old shapes are unchanged", async () => {
  const d = make({ scorer: NO_CONTEXT_SCORER });
  const golden = async (requestFile: string, responseFile: string, mutate: (request: InstantRequest) => InstantRequest = (r) => r) => {
    const parsed = parseInstantRequest(readJson(join("instant", "requests", requestFile)));
    assert.ok(parsed.ok, requestFile);
    if (!parsed.ok) return;
    const request = mutate(parsed.value);
    const expected = readJson<Record<string, unknown>>(join("instant", responseFile));
    const response = await d.dispatch({ ...request, seq: expected.seq as number });
    assert.deepEqual({ ...response, elapsedMs: 0 }, { ...expected, elapsedMs: 0 }, requestFile);
  };
  await golden("request-target-search.json", "act-fill-submit.json");
  // The same take into a text field, as act-fill.json shows it (Liebe Grüße into a text field).
  await golden("request-target-search.json", "act-fill.json", (r) => ({
    ...r, text: "Liebe Grüße", hypotheses: [{ ...r.hypotheses![0]!, text: "Liebe Grüße" }], target: { app: "other", field: { kind: "text", empty: true, ready: true } },
  }));
  await golden("request-target-search.json", "fallthrough-check-fill-offer.json", (r) => ({ ...r, hypotheses: [{ ...r.hypotheses![0]!, minConfidence: 0.1 }] }));

  // Without "fill" the target changes nothing; the typed own-fill request is a bar request (no implicit fill).
  for (const file of ["request-target-without-fill.json", "request-target-own-fill.json", "request-target-finder-rename.json"]) {
    const parsed = parseInstantRequest(readJson(join("instant", "requests", file)));
    assert.ok(parsed.ok, file);
    if (!parsed.ok) continue;
    const { target: _target, ...plain } = parsed.value;
    assert.equal(stable(await d.dispatch(parsed.value)), stable(await d.dispatch(plain)), file);
  }
  // The credential fixture is an explicit "tippe …" (the host reports the kind only with the Settings opt-in on).
  const credential = parseInstantRequest(readJson(join("instant", "requests", "request-target-credential.json")));
  assert.ok(credential.ok);
  if (credential.ok) assert.deepEqual(fillOf(await d.dispatch(credential.value)), { text: "fixture-user", submit: false, confirm: false });
  // "git status" with a terminal focused: the one-Return offer, never text on its own.
  const terminal = parseInstantRequest(readJson(join("instant", "requests", "request-target-terminal.json")));
  assert.ok(terminal.ok);
  if (terminal.ok) assert.ok(offers(await d.dispatch(terminal.value)));
  // A settling anchor with the field of the launching app itself: an ordinary fill, Return in the address bar.
  const settling = parseInstantRequest(readJson(join("instant", "requests", "request-target-address-settling.json")));
  assert.ok(settling.ok);
  if (settling.ok) assert.deepEqual(fillOf(await d.dispatch(settling.value)), { text: "Albert Einstein", submit: true, confirm: false });
});

test("compatibility: no target, a target without fill, or fill without a target decide byte-identically to today", async () => {
  const d = make();
  const texts = [
    "Albert Einstein", "Wie hoch ist der Eiffelturm?", "Öffne Safari", "Notizen", "tippe Hallo Welt", "such nach Katzen", "Nein, Marie Curie.", "Frag Pi, wer war Goethe?",
    "delete the last sentence", "what is this page about", "15% of 340", "google Albert Einstein", "Schreib eine Mail an Anna", "git status",
  ];
  for (const text of texts) {
    for (const make of [voice, typed]) {
      const base = make(text, undefined, { accept: TODAY });
      const today = stable(await d.dispatch(base));
      for (const kind of [...INSTANT_FIELD_KINDS, null]) {
        assert.equal(stable(await d.dispatch({ ...base, target: target(kind, "browser") })), today, `${text} with a ${kind} target but no fill`);
      }
      assert.equal(stable(await d.dispatch({ ...base, accept: ALL })), today, `${text} with fill but no target`);
    }
  }
});

// ---------------------------------------------------------------- implicit fills (voice)

test("voice: everything except commands goes into an implicit field; Return only in search boxes and the address bar", async () => {
  const d = make();
  for (const kind of FILL_IMPLICIT_KINDS) {
    const app = kind === "search" || kind === "address" ? "browser" : "other";
    for (const [text, typedText] of [
      ["Albert Einstein", "Albert Einstein"], ["Wie hoch ist der Eiffelturm?", "Wie hoch ist der Eiffelturm?"], ["best pizza near me", "best pizza near me"],
      ["Liebe Grüße", "Liebe Grüße"], ["No Country for Old Men", "No Country for Old Men"], ["Monitor", "Monitor"],
    ] as const) {
      const fill = fillOf(await d.dispatch(voice(text, target(kind, app))));
      assert.deepEqual(fill, { text: typedText, submit: kind === "search" || kind === "address", confirm: false }, `${text} → ${kind}`);
    }
    // Empty or not, with or without pi-os's own last fill in it.
    assert.ok(isFill(await d.dispatch(voice("Relativitätstheorie", { app, field: field(kind, { empty: false, ownFill: true }) }))), kind);
  }
  // A field that is not ready (a loading page, a nested frame) keeps today's decision.
  const notReady = voice("Albert Einstein", { app: "browser", field: field("search", { ready: false }) });
  assert.equal(stable(await d.dispatch(notReady)), stable(await d.dispatch({ ...notReady, accept: TODAY })));
});

test("voice: commands win, page questions and pi tasks stay with pi, deletion words and control words are never typed", async () => {
  const d = make();
  const tgt = target("search", "browser");
  const same = async (text: string) => {
    const request = voice(text, tgt);
    const response = await d.dispatch(request);
    assert.ok(!isFill(response) && !offers(response), `${text}: ${JSON.stringify(response)}`);
    assert.equal(stable(response), stable(await d.dispatch({ ...request, accept: TODAY })), `${text} decides as today`);
    return response;
  };
  const safari = await same("Öffne Safari.");
  assert.ok(safari.decision === "act" && safari.action.type === "openApp");
  for (const text of ["open Google", "what is 12 times 7", "Wie spät ist es in Tokio?", "github.com", "lauter", "google Albert Einstein", "öffne Foobarbaz", "100 Dollar in Euro"]) await same(text);
  for (const text of ["what is this page about", "Was steht da?", "Fasse die Seite zusammen.", "Erkläre mir das.", "translate this", "hier"]) await same(text);
  // Review: the German twins of "is that true" / "should I buy this" are page questions too: never typed, never submitted.
  const pointing = ["ist das wahr", "ist das seriös", "ist das ein Betrug", "sollte ich das kaufen", "kann ich dem trauen", "macht das Sinn", "gibt es das auch in blau"];
  for (const text of [...pointing, "is that true", "should I buy this", "is this legit"]) await same(text);
  for (const kind of ["multiline", "text", "address"] as const) {
    for (const text of pointing) {
      const response = await d.dispatch(voice(text, target(kind, "browser")));
      assert.ok(!isFill(response) && !offers(response), `${kind} ${text}: ${JSON.stringify(response)}`);
    }
  }
  assert.deepEqual(fillOf(await d.dispatch(voice("Wie groß ist das Universum?", tgt))), { text: "Wie groß ist das Universum?", submit: true, confirm: false },
    "das as an article: a plain question, typed");
  for (const text of ["Schreib eine Mail an Anna.", "Erstelle eine Präsentation.", "Remind me to call mom.", "Tell me a joke.", "Neue Notiz Milch kaufen.", "Make it bold.", "Tippe auf den Button."]) await same(text);
  // Device, page and browser commands without a task verb up front stay commands (pi), never text with a Return.
  for (const text of [
    "WLAN aus.", "Bluetooth an", "dark mode on", "Dunkelmodus an", "Nicht stören an", "do not disturb on", "Musik aus", "Bildschirm heller", "Mach WLAN aus",
    "Timer 5 Minuten", "Wecker auf 7 Uhr", "reload", "Seite neu laden", "nach unten scrollen", "drucken", "Print.", "fullscreen", "Vollbild",
    "new private window", "neues privates Fenster", "next field", "nächstes Feld", "zurück zur Startseite", "Formular absenden", "Cookies akzeptieren",
    "reject all", "Abmelden", "logout", "Escape", "Tab",
  ]) await same(text);
  for (const text of ["delete the last sentence", "Lösche den letzten Satz.", "remove the second paragraph", "how do I empty the trash", "throw it away"]) await same(text);
  for (const text of ["Nein.", "Never mind.", "Abbrechen.", "Enter.", "Los."]) await same(text);
  assert.equal((await same("rm -rf ~")).decision, "refuse");
  assert.equal((await same("empty the trash")).decision, "refuse");
  // A deletion word in another hypothesis vetoes the fill too.
  const veto = await d.dispatch({ ...voice("Albert Einstein", tgt), hypotheses: [P("Albert Einstein"), { text: "delete Albert Einstein", source: "apple-dt/en-US", role: "secondary" }] });
  assert.ok(!isFill(veto) && !offers(veto));
});

test("voice: doubt and terminals get the check card with the fill offer; without check the take keeps today's decision", async () => {
  const d = make();
  const low = (kind: InstantFieldKind, accept = ALL) => ({ ...voice("Albert Einstein", target(kind, "browser")), hypotheses: [P("Albert Einstein", { minConfidence: 0.1 })], accept });
  for (const kind of FILL_IMPLICIT_KINDS) assert.ok(offers(await d.dispatch(low(kind))), kind);
  for (const text of ["Albert Einstein", "git status", "Rechnung Telekom"]) {
    const response = await d.dispatch(voice(text, target("terminal", "terminal")));
    assert.deepEqual(response.decision === "fallthrough" && response.voice, { source: "parakeet-v3", check: true, fill: "offer" }, text);
  }
  const noCheck = low("search", ["suggest", "confirm", "fill"]);
  assert.equal(stable(await d.dispatch(noCheck)), stable(await d.dispatch({ ...noCheck, accept: ["suggest", "confirm"] })));
  // Commands and page questions never carry an offer, not even in a terminal.
  for (const text of ["Öffne Safari", "what is this page about", "delete the last sentence"]) assert.ok(!offers(await d.dispatch(voice(text, target("terminal", "terminal")))), text);
});

test("voice: a credential or sensitive field never gets implicit text; the take ends without a check card, hints or memo words", async () => {
  let classified = 0;
  const classifier: IntentClassifier = { name: "spy", local: false, classify: async () => { classified++; return { source: "pi-classifier", latencyMs: 1, intent: "answer", intentP: 0.9 }; } };
  const memo = new InMemoryTakeMemo();
  const d = make({ classifier, takeMemo: memo });
  for (const kind of ["credential", "sensitive"] as const) {
    for (const text of ["Sommer2024", "Albert Einstein", "vier sieben eins eins", "Nein, Marie Curie.", "delete the last sentence"]) {
      const request = { ...voice(text, target(kind, "browser")), takeId: `take-${kind}-${text.length}` };
      const response = await d.dispatch(request);
      assert.deepEqual({ decision: response.decision, reason: response.decision === "fallthrough" ? response.reason : "", voice: response.decision === "fallthrough" ? response.voice : null },
        { decision: "fallthrough", reason: "no_match", voice: { source: "parakeet-v3" } }, `${kind} ${text}`);
      assert.equal(response.decision === "fallthrough" ? response.hints : undefined, undefined);
      const record = takeRecordFor(request, response, Date.now());
      assert.deepEqual([record?.hypotheses, record?.heard, record?.nearMiss], [[], undefined, undefined], "the memo keeps no words");
    }
    // Commands and named page questions keep their way; the classifier still never sees the words.
    assert.equal((await d.dispatch(voice("Öffne Safari", target(kind, "browser")))).decision, "act");
    const page = await d.dispatch(voice("What does it say?", target(kind, "browser")));
    assert.ok(page.decision === "fallthrough" && page.reason === "no_match" && !page.hints);
  }
  // Without "fill" a secret field still keeps the words from the classifier (the decision itself is today's).
  const plain = await d.dispatch({ ...voice("Albert Einstein", target("credential", "browser")), accept: TODAY });
  assert.ok(plain.decision === "fallthrough" && !plain.hints);
  assert.equal(classified, 0, "no classifier saw a word spoken into a secret field");
  const open = await d.dispatch({ ...voice("Albert Einstein", undefined), accept: TODAY });
  assert.ok(open.decision === "fallthrough");
  assert.equal(classified, 1, "the same take without a secret target is classified as today");
});

test("voice: a secret field's take that typed nothing still gets no check card (nein, X after a fill there; a form the field cannot take)", async () => {
  let now = 2_000_000;
  const memo = new InMemoryTakeMemo({ clock: () => now });
  const d = make({ takeMemo: memo });
  const secretMiss = (response: InstantResponse, where: string) =>
    assert.deepEqual([response.decision, response.decision === "fallthrough" ? response.reason : "", response.decision === "fallthrough" ? response.voice : null],
      ["fallthrough", "no_match", { source: "parakeet-v3" }], `${where}: ${JSON.stringify(response)}`);
  // An explicit fill into the password field (the host's opt-in), then "nein, X" while it still holds that fill.
  const owned = { app: "browser" as const, field: field("credential", { ownFill: true }) };
  const first = { ...voice("Tippe fixture-pass-1", owned), takeId: "take-secret-fill" };
  const filled = await d.dispatch(first);
  assert.deepEqual(fillOf(filled), { text: "fixture-pass-1", submit: false, confirm: false });
  memo.remember(takeRecordFor(first, filled, now)!);
  now += 2_000;
  for (const hypothesis of [P("Nein, fixture-pass-2."), P("Nein, fixture-pass-2.", { minConfidence: 0.1 })]) {
    secretMiss(await d.dispatch({ ...voice(hypothesis.text, owned), hypotheses: [hypothesis], takeId: "take-secret-2" }), "nein, X after a secret fill");
  }
  // An explicit form a secret field cannot take now (not ready; a code field without the one-Return confirm).
  for (const kind of ["credential", "sensitive"] as const) {
    secretMiss(await d.dispatch(voice("Tippe fixture-pass-1", { app: "browser", field: field(kind, { ready: false }) })), `${kind} not ready`);
  }
  secretMiss(await d.dispatch({ ...voice("Tippe 4711", target("sensitive", "browser")), accept: ["check", "fill"] }), "sensitive without confirm");
  // "frag pi …" still asks pi (the user said so).
  const toPi = await d.dispatch({ ...voice("Frag Pi, was ist das für ein Feld?", owned), takeId: "take-secret-3" });
  assert.ok(toPi.decision === "fallthrough" && !toPi.voice?.check && !isFill(toPi), JSON.stringify(toPi));
});

test("voice: a cold app index never holds a fill decision past the budget", async () => {
  const stalled = createInstantDispatcher({
    apps: new AppIndexCache(() => new Promise(() => {})), localZone: () => "Europe/Berlin", homeDir: "/Users/fixture",
  });
  for (const text of ["Wie hoch ist der Eiffelturm?", "best pizza near me"]) {
    const started = performance.now();
    const response = await stalled.dispatch(voice(text, target("search", "browser")));
    const elapsed = performance.now() - started;
    assert.ok(elapsed < 1_000, `${text}: ${elapsed.toFixed(0)} ms`);
    assert.deepEqual(fillOf(response), { text, submit: true, confirm: false });
  }
});

test("voice: a confirm or rename field never gets text; a resembling name's did-you-mean becomes a fill, an exact app name stays a command", async () => {
  const d = make();
  for (const kind of FILL_NEVER_KINDS) {
    const request = voice("Albert Einstein", target(kind, kind === "rename" ? "finder" : "browser"));
    const response = await d.dispatch(request);
    assert.ok(!isFill(response) && !offers(response), kind);
    assert.equal(stable(response), stable(await d.dispatch({ ...request, accept: TODAY })), kind);
  }
  const resembling = await d.dispatch({ ...voice("Monitor", undefined), accept: TODAY });
  assert.ok(resembling.decision === "list" && resembling.voice?.didYouMean, "today: Did you mean Activity Monitor?");
  assert.deepEqual(fillOf(await d.dispatch(voice("Monitor", target("search", "browser")))), { text: "Monitor", submit: true, confirm: false });
  // An installed app's exact name said alone is a command (DESIGN5 A4): "Did you mean Notes?", the check card for "1Password".
  for (const text of ["Notizen", "Wetter", "Pages, please.", "1Password"]) {
    const request = voice(text, target("search", "browser"));
    const response = await d.dispatch(request);
    assert.ok(!isFill(response) && !offers(response), text);
    assert.equal(stable(response), stable(await d.dispatch({ ...request, accept: TODAY })), text);
  }
  const strong = await d.dispatch(voice("Öffne Notizen", target("search", "browser")));
  assert.ok(strong.decision === "act" && strong.action.type === "openApp");
});

test("frag pi / ask pi: never typed, and no \"Did I hear that right?\" unless the recognizers doubt the words", async () => {
  const d = make();
  for (const text of ["Frag Pi, wer war Goethe?", "Ask pi who wrote Hamlet", "Hey Pi, wie geht's?", "Pi, was ist die Hauptstadt von Australien?"]) {
    const response = await d.dispatch(voice(text, target("search", "browser")));
    assert.ok(response.decision === "fallthrough" && response.reason === "no_match" && !response.voice?.check && !response.voice?.fill, text);
  }
  const doubted = await d.dispatch({ ...voice("Frag Pi, wer war Goethe?", target("search", "browser")), hypotheses: [P("Frag Pi, wer war Goethe?", { minConfidence: 0.1 })] });
  assert.ok(doubted.decision === "fallthrough" && doubted.voice?.check === true && !doubted.voice.fill);
});

// ---------------------------------------------------------------- explicit dictation (voice and typed)

test("explicit: tippe/type/diktiere/gib … ein types the remainder into every kind but confirm (refused) and rename; typed finals too", async () => {
  const d = make();
  for (const ask of [voice, typed]) {
    for (const kind of INSTANT_FIELD_KINDS) {
      const response = await d.dispatch(ask("Tippe Hallo Welt.", target(kind, kind === "search" || kind === "address" ? "browser" : "other")));
      if (kind === "confirm") {
        assert.ok(response.decision === "refuse" && response.code === "file_deletion_blocked" && /confirms a deletion/.test(response.message), kind);
        assert.ok(validateCard(response.card, { mode: "strict", allowedActions: HOST_ACTION_TYPES }).ok);
        continue;
      }
      if (kind === "rename") {
        assert.ok(!isFill(response), "a Finder rename editor never takes text");
        continue;
      }
      const expected = shapeFillText("Hallo Welt.", kind)!;
      // A code field waits for one Return after a spoken take; the composer's Return already confirmed a typed one.
      assert.deepEqual(fillOf(response), { text: expected, submit: kind === "search" || kind === "address", confirm: ask === voice && kind === "sensitive" },
        `${ask === voice ? "voice" : "typed"} ${kind}`);
    }
  }
  // "type open google" types the words (dictation before the grammar), "tippe nein" types the word.
  assert.equal(fillOf(await d.dispatch(voice("Type open google", target("multiline")))).text, "open google");
  assert.equal(fillOf(await d.dispatch(voice("Tippe nein", target("multiline")))).text, "nein");
  assert.equal(fillOf(await d.dispatch(voice("Gib Albert Einstein ein.", target("search", "browser")))).text, "Albert Einstein");
  // No field, a field that is not ready, a described remainder: today's decision.
  for (const request of [voice("Tippe Hallo Welt", target(null, "browser")), voice("Tippe Hallo Welt", { app: "other", field: field("text", { ready: false }) }),
    voice("Tippe auf den Button", target("text")), voice("Type hello into the search box", target("text"))]) {
    assert.equal(stable(await d.dispatch(request)), stable(await d.dispatch({ ...request, accept: TODAY })));
  }
});

test("explicit: deletion words wait for one Return and never submit; a deletion request is refused; without confirm nothing is typed", async () => {
  const d = make();
  for (const [text, typedText] of [["Tippe lösche den Absatz.", "lösche den Absatz"], ["Type remove the comma", "remove the comma"]] as const) {
    assert.deepEqual(fillOf(await d.dispatch(voice(text, target("search", "browser")))), { text: typedText, submit: false, confirm: true }, text);
  }
  for (const text of ["type rm -rf ~", "Tippe Papierkorb leeren", "tippe empty the trash"]) {
    const response = await d.dispatch(voice(text, target("multiline")));
    assert.equal(response.decision, "refuse", text);
  }
  const noConfirm = { ...voice("Tippe lösche den Absatz", target("multiline")), accept: ["check", "fill"] as InstantAccept[] };
  assert.ok(!isFill(await d.dispatch(noConfirm)));
  const sensitive = { ...voice("Tippe 4711", target("sensitive")), accept: ["check", "fill"] as InstantAccept[] };
  assert.ok(!isFill(await d.dispatch(sensitive)), "a sensitive fill needs the one-Return confirm");
  // Review: a typed final declares only `fill` (the host's typed and check-resend finals): its Return was the explicit
  // confirmation, so the code is typed instead of falling through to pi with the code in it.
  for (const kind of ["sensitive", "credential"] as const) {
    const typedCode = { ...typed("tippe 123456", target(kind, "browser")), accept: ["fill"] as InstantAccept[] };
    assert.deepEqual(fillOf(await d.dispatch(typedCode)), { text: "123456", submit: false, confirm: false }, kind);
  }
  // Deletion words still wait for one Return, which a typed final cannot give: nothing is typed.
  assert.ok(!isFill(await d.dispatch({ ...typed("tippe lösche den Absatz", target("multiline")), accept: ["fill"] as InstantAccept[] })));
});

test("typed bar input never fills implicitly: typing in the bar addresses pi", async () => {
  const d = make();
  for (const text of ["Albert Einstein", "Wie hoch ist der Eiffelturm?", "Liebe Grüße"]) {
    const request = typed(text, target("search", "browser"));
    assert.equal(stable(await d.dispatch(request)), stable(await d.dispatch({ ...request, accept: TODAY })), text);
  }
});

// ---------------------------------------------------------------- search forms (DESIGN5 §4.6)

test("such nach X / search for X: into a search box or the address bar with one Return; a browser without one searches the web", async () => {
  const d = make();
  for (const ask of [voice, typed]) {
    for (const kind of ["search", "address"] as const) {
      assert.deepEqual(fillOf(await d.dispatch(ask("Such nach Katzen.", target(kind, "browser")))), { text: "Katzen", submit: true, confirm: false }, kind);
    }
    for (const kind of ["text", "multiline", null] as const) {
      const response = await d.dispatch(ask("Search for cats.", target(kind, "browser")));
      assert.ok(response.decision === "act" && response.intent === "web", `${kind}: ${JSON.stringify(response)}`);
      if (response.decision === "act") assert.deepEqual(response.action, { type: "openURL", url: "https://duckduckgo.com/?q=cats" });
    }
    // Outside a browser the commands decide first (DESIGN5 §4.6): a file search stays one, even with a search field focused;
    // another field outside a browser keeps today's decision.
    for (const request of [ask("Suche Rechnung Telekom", target("search", "other")), ask("Such nach Katzen", target("multiline", "other"))]) {
      assert.equal(stable(await d.dispatch(request)), stable(await d.dispatch({ ...request, accept: TODAY })), request.text);
    }
  }
  // A spoken search that no command took goes into a search field in any app (Mail, Finder) with one Return; typed, it is the bar's.
  assert.deepEqual(fillOf(await d.dispatch(voice("Such nach Katzen.", target("search", "other")))), { text: "Katzen", submit: true, confirm: false });
  const typedSearch = typed("Such nach Katzen", target("search", "other"));
  assert.equal(stable(await d.dispatch(typedSearch)), stable(await d.dispatch({ ...typedSearch, accept: TODAY })));
  // With the host's file search (the eval lane), that take is today's file list, never a fill.
  const { dispatcher: withFiles } = createEvalLane();
  const fileSearch = await withFiles.dispatch(voice("Suche Rechnung Telekom", target("search", "other")));
  assert.ok(fileSearch.decision === "list" && fileSearch.intent === "file_search", JSON.stringify(fileSearch));
  // Deixis and compounds stay the agent's; deletion words search the web instead of typing.
  const deictic = await d.dispatch(voice("search for this", target("search", "browser")));
  assert.ok(deictic.decision === "fallthrough" && deictic.reason === "deictic");
  const words = await d.dispatch(voice("search for how to delete files", target("search", "browser")));
  assert.ok(words.decision === "act" && words.intent === "web");
  const custom = make({ webSearchTemplate: () => "https://search.example/?q=%s" });
  const response = await custom.dispatch(voice("such nach Katzen", target(null, "browser")));
  assert.ok(response.decision === "act" && response.action.type === "openURL" && response.action.url === "https://search.example/?q=Katzen");
});

test("google X goes into the anchored Google page's search box; elsewhere it opens the search URL as today", async () => {
  const memo = new InMemoryTakeMemo();
  const d = make({ takeMemo: memo });
  const opened = (takeId: string, url: string) => memo.remember({
    takeId, at: Date.now(), inputMode: "voice", hypotheses: [P("open it")], decision: "act", recognizer: "parakeet-v3", offered: [], acted: { kind: "openURL", url },
  });
  opened("take-google", "https://www.google.com/");
  opened("take-wiki", "https://www.wikipedia.org/");
  const anchored = (takeId: string, kind: InstantFieldKind = "search") => voice("google Albert Einstein", { app: "browser", anchor: { takeId }, field: field(kind) });
  assert.deepEqual(fillOf(await d.dispatch(anchored("take-google"))), { text: "Albert Einstein", submit: true, confirm: false });
  for (const request of [anchored("take-wiki"), anchored("take-unknown"), anchored("take-google", "address"), voice("google Albert Einstein", target("search", "browser"))]) {
    const response = await d.dispatch(request);
    assert.ok(response.decision === "act" && response.intent === "web", JSON.stringify(request.target));
  }
  // Wikipedia's language editions are the same site as its portal.
  assert.deepEqual(fillOf(await d.dispatch(voice("search wikipedia for Albert Einstein", { app: "browser", anchor: { takeId: "take-wiki" }, field: field("search") }))),
    { text: "Albert Einstein", submit: true, confirm: false });
  // With no search box focused, a bare search on an anchored search site uses that site's search (DESIGN5 §4.6 step 2).
  const site = async (text: string, takeId: string, locale: string) => {
    const response = await d.dispatch({ ...voice(text, { app: "browser", anchor: { takeId } }), locale, hypotheses: [P(text, { locale })] });
    assert.ok(response.decision === "act" && response.action.type === "openURL", JSON.stringify(response));
    return response.decision === "act" ? { title: response.title, url: response.action.type === "openURL" ? response.action.url : "" } : null;
  };
  assert.deepEqual(await site("Such nach Albert Einstein", "take-wiki", "de-DE"),
    { title: "Search Wikipedia for “Albert Einstein”", url: "https://de.wikipedia.org/w/index.php?search=Albert+Einstein" });
  assert.deepEqual(await site("search for Albert Einstein", "take-wiki", "en-US"),
    { title: "Search Wikipedia for “Albert Einstein”", url: "https://en.wikipedia.org/w/index.php?search=Albert+Einstein" });
  assert.deepEqual(await site("search for cats", "take-google", "en-US"), { title: "Search Google for “cats”", url: "https://www.google.com/search?q=cats" });
  assert.deepEqual(await site("search for cats", "take-unknown", "en-US"), { title: "Search the web for “cats”", url: "https://duckduckgo.com/?q=cats" });
});

// ---------------------------------------------------------------- "nein, X" after a fill, the memo, learning

test("nein, X right after pi-os's own fill replaces it (the host undoes, then types X); otherwise it is neither typed nor a correction", async () => {
  let now = 1_000_000;
  const memo = new InMemoryTakeMemo({ clock: () => now });
  const d = make({ takeMemo: memo });
  const remember = (request: InstantRequest, response: InstantResponse) => memo.remember(takeRecordFor(request, response, now)!);
  // An open, then a fill.
  const open = { ...voice("Öffne Google", target(null, "browser")), takeId: "take-open" };
  remember(open, await d.dispatch(open));
  const first = { ...voice("Albert Einstein", target("search", "browser")), takeId: "take-fill" };
  const filled = await d.dispatch(first);
  assert.ok(isFill(filled));
  remember(first, filled);
  assert.equal(memo.latestActed()?.takeId, "take-open", "a fill acted on nothing a correction could name");
  assert.equal(memo.get("take-fill")?.fill, true);

  now += 3_000;
  const owned = { app: "browser" as const, field: field("search", { empty: false, ownFill: true }) };
  const replace = await d.dispatch({ ...voice("Nein, Marie Curie.", owned), takeId: "take-3" });
  assert.deepEqual(fillOf(replace), { text: "Marie Curie", submit: true, confirm: false });
  assert.equal(replace.decision === "act" ? replace.voice?.correctsTakeId : undefined, "take-fill");
  assert.equal(stable(await d.dispatch({ ...voice("No, I meant Marie Curie", owned), takeId: "take-3" })).includes("\"correctsTakeId\":\"take-fill\""), true);

  // The user edited the field (no ownFill): nothing typed, and "Öffne Google" is not corrected either.
  const edited = await d.dispatch({ ...voice("Nein, Notizen.", target("search", "browser")), takeId: "take-4" });
  assert.ok(!isFill(edited) && !(edited.decision === "act" && edited.voice?.correctsTakeId), JSON.stringify(edited));
  // X itself a command, a deletion or a task: not typed.
  for (const text of ["Nein, öffne Safari.", "Nein, lösche das.", "Nein, schreib eine Mail."]) {
    const response = await d.dispatch({ ...voice(text, owned), takeId: "take-5" });
    assert.ok(!isFill(response), text);
  }
  // A take in between, or more than 30 s: "nein, X" is about that one (no replace).
  now += FILL_REPLACE_MS;
  assert.ok(!isFill(await d.dispatch({ ...voice("Nein, Marie Curie.", owned), takeId: "take-6" })));
  now -= FILL_REPLACE_MS;
  const answer = { ...voice("Wie spät ist es in Tokio?", target(null, "browser")), takeId: "take-time" };
  remember(answer, await d.dispatch(answer));
  assert.ok(!isFill(await d.dispatch({ ...voice("Nein, Marie Curie.", owned), takeId: "take-7" })));
  // A plain phrase after a fill is a new fill (appended at the caret); "No Country for Old Men" without a recent fill too.
  assert.ok(isFill(await d.dispatch({ ...voice("Relativitätstheorie", owned), takeId: "take-8" })));
});

test("take memo: fill takes are marked and stay marked, latestFill sees only the newest other take within its window", () => {
  let now = 5_000_000;
  const memo = new InMemoryTakeMemo({ clock: () => now });
  const record = (takeId: string, extra: Partial<TakeRecord> = {}): TakeRecord =>
    ({ takeId, at: now, inputMode: "voice", hypotheses: [P("x")], decision: "act", recognizer: "parakeet-v3", offered: [], ...extra });
  memo.remember(record("a", { acted: { kind: "openApp", bundleId: "com.apple.Safari" } }));
  memo.remember(record("b", { fill: true }));
  assert.equal(memo.latestFill(FILL_REPLACE_MS)?.takeId, "b");
  assert.equal(memo.latestFill(FILL_REPLACE_MS, "b"), undefined, "the newest other take is the open");
  assert.equal(memo.latestActed()?.takeId, "a");
  // A later final of the fill take that falls through keeps the mark (it never teaches).
  memo.remember(record("b", { decision: "fallthrough", reason: "no_match" }));
  assert.equal(memo.get("b")?.fill, true);
  now += FILL_REPLACE_MS + 1;
  assert.equal(memo.latestFill(FILL_REPLACE_MS), undefined);
  // takeRecordFor marks a fill act; a fill offer is no fill.
  const request = { ...voice("Albert Einstein", target("search", "browser")), takeId: "take-x" };
  assert.equal(takeRecordFor(request, { seq: 1, elapsedMs: 0, source: "grammar", ...fillBody("Albert Einstein", "search", { submit: true }) } as InstantResponse, now)?.fill, true);
  assert.equal(takeRecordFor(request, { seq: 1, elapsedMs: 0, source: "grammar", ...fillOfferBody() } as InstantResponse, now)?.fill, undefined);
});

test("learning: a fill take teaches nothing, whatever the gesture; learned replays never declare fill", async () => {
  assert.ok(!REPLAY_ACCEPTS.includes("fill"));
  const store = new DictionaryStore({ log: () => {} });
  const memo = new InMemoryTakeMemo();
  memo.remember({ takeId: "take-fill", at: Date.now(), inputMode: "voice", hypotheses: [P("Albert Einstein")], decision: "act", recognizer: "parakeet-v3", offered: [], via: "field", fill: true } as TakeRecord);
  const lane = { openTarget: () => null, blocked: () => false, resolve: async () => ({ kind: "openApp", bundleId: "com.apple.Safari" }), appDisplay: () => "Safari", exactApp: () => undefined, outcome: async () => ({ kind: "none" }) } as unknown as LearnLane;
  for (const request of [
    { takeId: "take-fill", kind: "pick", bundleId: "com.apple.Safari" }, { takeId: "take-fill", kind: "confirm" }, { takeId: "take-fill", kind: "reject" },
    { takeId: "take-fill", kind: "no_i_meant", correctedText: "Safari" }, { takeId: "take-fill", kind: "edit", correctedText: "open Safari" },
  ] as const) {
    const result = await learnFromGesture(request, { store, memo, lane });
    assert.deepEqual([result.status, result.status === "refused" ? result.code : ""], ["refused", "nothing_to_learn"], request.kind);
  }
});

// ---------------------------------------------------------------- server: /instant, defense in depth, /dictionary/learn, /invoke

test("server: /instant fills over HTTP, remembers the fill take, refuses to learn from it, and drops a fill the request did not allow", async () => {
  const host = fakeHost({ apps: { version: "1", apps: APPS } });
  const f = await start({ host });
  try {
    const post = async (body: Record<string, unknown>) => {
      const response = await f.post("/instant", body);
      assert.equal(response.status, 200);
      return response.json() as Promise<InstantResponse>;
    };
    const { result: filled, lines } = await captureLogs(() => post({ ...voice("Albert Einstein", target("search", "browser")), takeId: "take-http" }));
    assert.deepEqual(fillOf(filled), { text: "Albert Einstein", submit: true, confirm: false });
    assert.ok(lines.some((line) => /stage=instant\.dispatch .*kind=fill .*fill=implicit field=search/.test(line)), lines.join("\n"));
    assert.ok(!lines.some((line) => line.includes("Albert") || line.includes("Einstein")), "no text in the logs");
    const learn = await f.post("/dictionary/learn", { takeId: "take-http", kind: "confirm" });
    assert.deepEqual(((await learn.json()) as { status: string; code: string }).code, "nothing_to_learn");

    const check = (f.server as unknown as { checkInstantFill(request: InstantRequest, response: InstantResponse): InstantResponse }).checkInstantFill.bind(f.server);
    const wrap = (body: object): InstantResponse => ({ seq: 1, elapsedMs: 0, source: "grammar", ...body } as InstantResponse);
    const fill = (text: string, submit = false) => wrap({ decision: "act", intent: "fill", title: "Type", action: { type: "typeIntoPinned", text, ...(submit ? { submit: true } : {}) }, confirm: false });
    const ok = voice("x", target("search", "browser"));
    const { result: dropped, lines: warned } = await captureLogs(async () => [
      check({ ...ok, accept: TODAY }, fill("Albert")), check(voice("x", target(null, "browser")), fill("Albert")), check(ok, fill("a\nb")),
      check(voice("x", target("multiline")), fill("Albert", true)), check(voice("x", target("terminal")), fill("Albert", true)),
      check(voice("x", target("confirm")), fill("Albert")), check(voice("x", target("rename")), fill("Albert")),
      check(ok, wrap({ decision: "act", intent: "url", title: "Open", action: { type: "typeIntoPinned", text: "x", submit: true }, confirm: false })),
      check(voice("x", { app: "browser", field: field("search", { ready: false }) }), fill("Albert")), check({ ...ok, phase: "partial" }, fill("Albert")),
    ]);
    for (const response of dropped) assert.deepEqual([response.decision, response.decision === "fallthrough" ? response.reason : ""], ["fallthrough", "no_match"]);
    assert.ok(warned.every((line) => !line.includes("Albert")) && warned.length === dropped.length);
    assert.deepEqual(check(ok, fill("Albert", true)), fill("Albert", true));
    assert.deepEqual(check(voice("x", target("credential")), fill("Albert")), fill("Albert"));
    const offer = wrap(fillOfferBody("parakeet-v3"));
    assert.deepEqual(check(ok, offer), offer);
    assert.deepEqual((check({ ...ok, accept: TODAY }, offer) as Extract<InstantResponse, { decision: "fallthrough" }>).voice, { source: "parakeet-v3", check: true });
  } finally {
    await f.close();
  }
});

test("the agent's continued-target sentence: provenance and an ordinary field kind only, never a secret field", () => {
  assert.equal(continuedTargetLine(undefined), undefined);
  assert.equal(continuedTargetLine({}), undefined);
  assert.equal(continuedTargetLine({ anchored: true }), "pi-os opened this app with the user's previous command.");
  assert.equal(continuedTargetLine({ field: "search", anchored: true }),
    "pi-os opened this app with the user's previous command, and a search field has the keyboard focus there; this request was not typed into it.");
  assert.equal(continuedTargetLine({ field: "address" }), "The browser's address bar has the keyboard focus there; this request was not typed into it.");
  assert.equal(continuedTargetLine({ field: "multiline", anchored: false }), "A text area has the keyboard focus there; this request was not typed into it.");
  for (const kind of ["terminal", "sensitive", "credential", "confirm", "rename"] as const) {
    assert.equal(continuedTargetLine({ field: kind }), undefined, kind);
    assert.equal(continuedTargetLine({ field: kind, anchored: true }), "pi-os opened this app with the user's previous command.", kind);
  }
});

test("server: /invoke hands context.target to the agent as one sentence in a general turn; logs carry the kind only", async () => {
  const captures = tempCaptures();
  const host = agentHost(captures.dir, captures.snapshot());
  const runtimes = fauxRuntimes();
  const f = await start({ runtimes, host: host as unknown as ReturnType<typeof fakeHost>, config: { capturesDir: captures.dir } });
  const requests: SeenRequest[] = [];
  const reply = (context: unknown, _options: unknown, _state: unknown, model: { provider: string; id: string }): AssistantMessage => {
    requests.push(seen(context, model));
    return fauxAssistantMessage("TCP retransmits; UDP does not.");
  };
  const turn = async (id: string, context: ContextWire) => {
    runtimes.respond([reply]);
    const accepted = await f.post("/invoke", { invocationId: id, contextId: "ctx-pinned", prompt: "explain the difference between TCP and UDP", context });
    assert.equal(accepted.status, 202, await accepted.clone().text());
    const done = await f.terminal(id);
    assert.equal(done.state, "completed", done.failureMessage);
    return requests.at(-1)!.request;
  };
  try {
    const general = { scope: "general", pull: "allowed", source: "default" } as const;
    const { result: anchored, lines } = await captureLogs(() => turn("target-general", { ...general, target: { field: "search", anchored: true } }));
    assert.match(anchored, /^Active app: "TextEdit" \(its window is not included\)\. Call use_active_window only if the request refers to something shown there\.\npi-os opened this app with the user's previous command, and a search field has the keyboard focus there; this request was not typed into it\.\n\n## Request\nexplain the difference between TCP and UDP$/);
    const logged = lines.find((line) => line.includes("stage=invoke.context"));
    assert.ok(logged && / field=search /.test(logged) && / anchored=true /.test(`${logged} `), logged);
    assert.ok(!lines.some((line) => line.includes("TCP and UDP")), "no prompt text in the logs");
    // A secret field is never named; without a target the prompt is today's.
    const secret = await turn("target-secret", { ...general, target: { field: "credential" } });
    assert.match(secret, /^Active app: "TextEdit" \(its window is not included\)\. Call use_active_window only if the request refers to something shown there\.\n\n## Request\n/);
    const plain = await turn("target-none", general);
    assert.equal(plain, secret);
    // A window turn shows the window itself: no extra sentence.
    const window = await turn("target-window", { scope: "window", pull: "allowed", source: "user", target: { field: "search", anchored: true } });
    assert.doesNotMatch(window, /pi-os opened this app|keyboard focus/);
  } finally {
    await f.close();
    await captures.close();
  }
});
