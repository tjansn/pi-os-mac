import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { bindingToHostAction, type CardSpec } from "../src/contracts/cards.js";
import {
  foldPhrase, NO_DICTIONARY, type DictionaryEntryRef, type DictionaryLookup, type DictionaryMatch, type SafeTarget, type TakeMemoRecord,
} from "../src/contracts/dictionary.js";
import { parseVoiceMeta, type InstantRequest, type InstantResponse, type VoiceHypothesis } from "../src/contracts/instant.js";
import type { AppRecord } from "../src/contracts/launcher.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { DictionaryStore, nameCore, nonCountingLookup } from "../src/instant/dictionary.js";
import { createInstantDispatcher, type InstantDispatcherDeps } from "../src/instant/dispatcher.js";
import { InMemoryTakeMemo, offeredBundleIds, takeDetailsOf, takeRecordFor } from "../src/instant/takeMemo.js";
import { checkGate, correctionTarget, VOICE, voiceTake, wordsDisagree } from "../src/instant/voice.js";
import { validateCard } from "../src/ui/validate.js";
import { HOST_ACTION_TYPES } from "../src/contracts/actions.js";

/*
 * The voice decision pipeline (DESIGN4 §4.5, §5.3, §5.4, §6.3; N2) through the real dispatcher: hypotheses
 * arbitration (first tier, peer τ, agreement, the secondary consistency gate, bare secondaries), policy
 * first and last (refusals, deletion in a secondary, the host pick's compound/deixis), "Did you mean …?",
 * the voice URL guard, the check gate, "No, I meant X", the learned-rule order, noteUse, the take memo's
 * details, older hosts and contamination over the instant corpus's 665 negatives. Synthetic text only, on
 * the 104-app fixture index; no host, no model, no logs.
 */

// ---------------------------------------------------------------- the instant corpus tables (instantSpoken.test.ts)

const SPOKEN_TESTS = readFileSync(join(import.meta.dirname, "instantSpoken.test.ts"), "utf8");

/**
 * One top-level table of instantSpoken.test.ts (the seeded r3/mapping corpus and the fixture app index), read
 * from its source so both files replay the same data without importing a test file (which would run its tests).
 */
function table<T>(name: string): T {
  const start = SPOKEN_TESTS.search(new RegExp(`^const ${name}\\b`, "m"));
  assert.ok(start >= 0, `instantSpoken.test.ts declares ${name}`);
  let i = SPOKEN_TESTS.indexOf("= ", start) + 2;
  const from = i;
  let depth = 0;
  for (; i < SPOKEN_TESTS.length; i++) {
    const c = SPOKEN_TESTS[i]!;
    if (c === "\"" || c === "'" || c === "`") {
      for (i++; i < SPOKEN_TESTS.length && SPOKEN_TESTS[i] !== c; i++) if (SPOKEN_TESTS[i] === "\\") i++;
      continue;
    }
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (c === ";" && depth === 0) break;
  }
  return Function(`"use strict"; return (${SPOKEN_TESTS.slice(from, i)});`)() as T;
}

type AppRow = readonly [bundleId: string, name: string, dir: string, aliases?: readonly string[], running?: boolean];
const DIRS = table<Readonly<Record<string, string>>>("DIRS");
const APPS: AppRecord[] = table<readonly AppRow[]>("APP_ROWS").map(([bundleId, name, dir, aliases = [], running = false]) => ({
  bundleId, name, aliases: [...aliases], path: `${DIRS[dir]}/${name}.app`, running,
}));

interface Negative { text: string; lang: string; src: string; okApp?: string }

/** r3/mapping build_neg.py → the 665 negatives, exactly as instantSpoken.test.ts builds them. */
function negatives(): Negative[] {
  const items: Negative[] = [];
  const suffix = table<Readonly<Record<string, string>>>("NEG_SUFFIX_OK");
  const add = (text: string, lang: string, src: string, okApp?: string): void => {
    const ok = okApp ?? Object.entries(suffix).find(([k]) => text === k || text.endsWith(` ${k}.`))?.[1];
    items.push({ text, lang, src: `neg-${src}`, ...(ok ? { okApp: ok } : {}) });
  };
  const enNouns = table<readonly string[]>("NEG_EN_NOUNS");
  const enPicks = table<readonly (readonly number[])[]>("NEG_EN_PICKS");
  table<readonly string[]>("NEG_EN_VERBS").forEach((verb, v) => enPicks[v]!.forEach((i) => add(`${verb} ${enNouns[i]}.`, "en", "open-noun")));
  const deNouns = table<readonly string[]>("NEG_DE_NOUNS");
  const dePicks = table<readonly (readonly number[])[]>("NEG_DE_PICKS");
  table<readonly string[]>("NEG_DE_VERBS").forEach((verb, v) => dePicks[v]!.forEach((i) => {
    const noun = deNouns[i]!;
    add(verb === "Kannst du öffnen" ? `Kannst du ${noun} öffnen?` : verb === "Mach" ? `Mach ${noun} auf.` : `${verb} ${noun}.`, "de", "open-noun");
  }));
  const deStart = table<ReadonlySet<string>>("DE_QUESTION_START");
  for (const q of table<readonly string[]>("NEG_QUESTIONS")) add(q, /[äöüß]/.test(q) || deStart.has(q.split(" ")[0]!) ? "de" : "en", "question");
  const deWords = table<ReadonlySet<string>>("DE_WORDS");
  for (const w of table<readonly string[]>("NEG_WORDS")) add(w, deWords.has(w) ? "de" : "en", "word");
  for (const [text, app] of table<readonly (readonly [string, string])[]>("NEG_APP_NOUNS")) add(text, text.includes("Zeig") ? "de" : "en", "appnoun", app);
  return items;
}

// ---------------------------------------------------------------- fixtures

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = <T>(path: string): T => JSON.parse(readFileSync(join(fixtures, path), "utf8")) as T;
const ACCEPT: NonNullable<InstantRequest["accept"]> = ["suggest", "check", "confirm"];

const apps = () => new AppIndexCache(async () => ({ version: "1", apps: APPS }));
function make(overrides: Partial<InstantDispatcherDeps> = {}) {
  return createInstantDispatcher({ apps: apps(), localZone: () => "Europe/Berlin", homeDir: "/Users/fixture", ...overrides });
}

const P = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "parakeet-v3", role: "primary", ...extra });
const EN = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "apple-dt/en-US", role: "peer", locale: "en-US", confidence: 0.7, ...extra });
const DE = (text: string, extra: Partial<VoiceHypothesis> = {}): VoiceHypothesis => ({ text, source: "apple-dt/de-DE", role: "peer", locale: "de-DE", confidence: 0.7, ...extra });
const SEC = (text: string, source = "apple-dt/en-US"): VoiceHypothesis => ({ text, source, role: "secondary" });

/** A voice final with hypotheses (the host's pick is the first one unless `text` says otherwise). */
const final = (hypotheses: VoiceHypothesis[], extra: Partial<InstantRequest> = {}): InstantRequest => ({
  text: hypotheses[0]!.text, phase: "final", seq: 1, inputMode: "voice", hypotheses, accept: ACCEPT, ...extra,
});

type Act = Extract<InstantResponse, { decision: "act" }>;
type List = Extract<InstantResponse, { decision: "list" }>;
const opens = (response: InstantResponse): string | undefined =>
  (response.decision === "act" && response.action.type === "openApp" ? response.action.bundleId : undefined);
const rows = (card: CardSpec): { title: string; bundleId: string }[] => Object.values(card.elements).flatMap((element) => {
  if (element.type !== "Item" || !element.on?.primary) return [];
  const action = bindingToHostAction(element.on.primary);
  return action?.type === "openApp" ? [{ title: String(element.props.title), bundleId: action.bundleId }] : [];
});
const asAct = (response: InstantResponse): Act => {
  assert.equal(response.decision, "act", JSON.stringify(response));
  return response as Act;
};
const asList = (response: InstantResponse): List => {
  assert.equal(response.decision, "list", JSON.stringify(response));
  return response as List;
};
/** The response without timing and advisory scope (goldens). */
const wire = (response: InstantResponse, drop: string[] = []) => {
  const copy: Record<string, unknown> = { ...response };
  for (const key of ["elapsedMs", "scope", ...drop]) delete copy[key];
  return copy;
};

/** A dictionary with fixed rules for the order tests, counting uses. */
function fakeDictionary(rules: {
  aliases?: Record<string, SafeTarget>; appNames?: Record<string, string>; fixes?: Record<string, string>; recognizer?: string;
} = {}): DictionaryLookup & { uses: string[]; calls: string[] } {
  const scope = rules.recognizer;
  const applies = (recognizer: string) => scope === undefined || scope === recognizer;
  const uses: string[] = [];
  const calls: string[] = [];
  return {
    uses, calls,
    revision: () => 1,
    settings: () => NO_DICTIONARY.settings(),
    alias: (phrase, recognizer) => {
      calls.push(`alias:${recognizer}`);
      const target = applies(recognizer) ? rules.aliases?.[foldPhrase(phrase)] : undefined;
      return target ? { ref: { list: "aliases", id: `a_${foldPhrase(phrase).replace(/ /g, "_")}` }, value: target } : null;
    },
    appName: (heard, recognizer) => {
      calls.push(`appName:${recognizer}`);
      const bundleId = applies(recognizer) ? rules.appNames?.[nameCore(heard)] : undefined;
      const display = APPS.find((app) => app.bundleId === bundleId)?.aliases[0] ?? APPS.find((app) => app.bundleId === bundleId)?.name ?? "";
      return bundleId ? { ref: { list: "appNames", id: `n_${nameCore(heard).replace(/ /g, "_")}` }, value: { bundleId, display } } : null;
    },
    fixes: (recognizer): DictionaryMatch<{ heard: string; intended: string }>[] => (applies(recognizer) ? Object.entries(rules.fixes ?? {}) : [])
      .sort(([a], [b]) => b.split(" ").length - a.split(" ").length)
      .map(([heard, intended]) => ({ ref: { list: "fixes", id: `f_${heard.replace(/ /g, "_")}` }, value: { heard, intended } })),
    noteUse: (ref: DictionaryEntryRef) => { uses.push(ref.id); },
  };
}

// ---------------------------------------------------------------- first tier

test("first tier: the primary acts on its own evidence; peers that agree act at once; a lone actionable peer rescues the take", async () => {
  const d = make();
  const primary = asAct(await d.dispatch(final([P("open page is")])));
  assert.deepEqual([primary.action, primary.confirm, primary.voice], [{ type: "openApp", bundleId: "com.apple.Pages" }, false, { heard: "page is", source: "parakeet-v3", via: "sound" }]);
  assert.equal(primary.title, "Open Pages", "the spoken label, not \"Pages Creator Studio\"");

  // Agreement: the low-confidence English peer agrees with the German one, so neither needs a Return.
  const agree = asAct(await d.dispatch(final([EN("Open Pages.", { confidence: 0.3 }), DE("Öffne Pages.", { confidence: 0.6 })])));
  assert.deepEqual([opens(agree), agree.confirm, agree.voice?.via, agree.voice?.source], ["com.apple.Pages", false, "exact", "apple-dt/en-US"]);

  // The English recognizer garbled German speech; the German peer heard it (via "peer").
  const rescued = asAct(await d.dispatch(final([EN("Of the bitter safari.", { confidence: 0.5 }), DE("Öffne bitte Safari.", { confidence: 0.7 })])));
  assert.deepEqual([opens(rescued), rescued.confirm, rescued.voice], ["com.apple.Safari", false, { heard: "safari", source: "apple-dt/de-DE", via: "peer" }]);

  // The shared request fixture (Phase A peers + an n-best secondary): the German peer acts at once.
  const fixture = readJson<InstantRequest>("instant/requests/final-peers.request.json");
  const peers = asAct(await d.dispatch(fixture));
  assert.deepEqual([opens(peers), peers.confirm, peers.voice?.source], ["com.apple.Pages", false, "apple-dt/de-DE"]);
});

test("peer τ: a lone Phase A peer below 0.4 (or without a confidence) needs one Return; a primary never does", async () => {
  const d = make();
  const garbled = EN("Of the bitter safari.", { confidence: 0.6 });
  for (const confidence of [0.39, undefined]) {
    const low = asAct(await d.dispatch(final([garbled, DE("Öffne bitte Safari.", confidence === undefined ? { confidence: undefined } : { confidence })])));
    assert.deepEqual([opens(low), low.confirm, low.voice?.via], ["com.apple.Safari", true, "peer"], String(confidence));
  }
  assert.equal(VOICE.peerConfidence, 0.4);
  const at = asAct(await d.dispatch(final([garbled, DE("Öffne bitte Safari.", { confidence: 0.4 })])));
  assert.equal(at.confirm, false);
  // shared/fixtures/instant: requests/final-peers-confirm.request.json → act-confirm-peer.json, byte for byte.
  const confirmPeer = await d.dispatch(readJson<InstantRequest>("instant/requests/final-peers-confirm.request.json"));
  assert.deepEqual(wire(confirmPeer), wire(readJson<InstantResponse>("instant/act-confirm-peer.json")));
  // The host's own pick below τ: one Return as well.
  const sentLow = asAct(await d.dispatch(final([DE("Öffne bitte Safari.", { confidence: 0.2 }), garbled])));
  assert.equal(sentLow.confirm, true);
  // Without "confirm" Node never adds one: the host's pick acts as today; another peer is not acted on.
  const noConfirm = { accept: ["suggest", "check"] as InstantRequest["accept"] };
  assert.equal(asAct(await d.dispatch(final([DE("Öffne bitte Safari.", { confidence: 0.2 }), garbled], noConfirm))).confirm, false);
  assert.notEqual((await d.dispatch(final([garbled, DE("Öffne bitte Safari.", { confidence: 0.2 })], noConfirm))).decision, "act");
  // A primary engine acts on its evidence whatever its confidence.
  assert.equal(asAct(await d.dispatch(final([P("Open Safari.", { confidence: 0.1 })]))).confirm, false);
});

test("disagreement: peers that heard different apps get \"Did you mean …?\" with both; other disagreements hold the host's pick for one Return", async () => {
  const d = make();
  const apps = asList(await d.dispatch(final([EN("Open Notes.", { confidence: 0.6 }), DE("Öffne Notion.", { confidence: 0.5 })])));
  assert.deepEqual(rows(apps.card), [{ title: "Notes", bundleId: "com.apple.Notes" }, { title: "Notion", bundleId: "notion.id" }]);
  assert.deepEqual([apps.title, apps.voice], ["Did you mean…", { heard: "notes", source: "apple-dt/en-US", via: "peer", didYouMean: true }]);
  const mixed = asAct(await d.dispatch(final([EN("Open Notes.", { confidence: 0.6 }), DE("Lautstärke 50.", { confidence: 0.9 })])));
  assert.deepEqual([opens(mixed), mixed.confirm], ["com.apple.Notes", true]);
});

// ---------------------------------------------------------------- secondary tier

test("secondary gate: a literal app act consistent with the primary acts; an inconsistent one needs one Return; only after the first tier misses", async () => {
  const d = make();
  // "grave" is a common word, so the primary alone offers nothing; the n-best re-hears Brave (its top sound-alike).
  const consistent = asAct(await d.dispatch(final([P("open grave"), SEC("Open Brave.")])));
  assert.deepEqual([opens(consistent), consistent.confirm, consistent.voice], ["com.brave.Browser", false, { heard: "brave", source: "apple-dt/en-US", via: "secondary" }]);
  // The request fixture: Parakeet heard "open recast" (only a did-you-mean on its own); Apple's "Open Raycast." agrees.
  const raycast = asAct(await d.dispatch(readJson<InstantRequest>("instant/requests/final-hypotheses.request.json")));
  assert.deepEqual([opens(raycast), raycast.confirm, raycast.voice?.via], ["com.raycast.macos", false, "secondary"]);
  // n-best invents a different command: one Return.
  const invented = asAct(await d.dispatch(final([P("open august"), SEC("Open the podcast.")])));
  assert.deepEqual([opens(invented), invented.confirm, invented.voice?.via], ["com.apple.podcasts", true, "secondary"]);
  // A gated alternative offers closed targets only: never a display sleep.
  assert.notEqual((await d.dispatch(final([P("Oh, the spray off.", { minConfidence: 0.5 }), SEC("Turn off the display.")]))).decision, "act");
  assert.equal(asAct(await d.dispatch(final([P("Oh, the spray off.", { minConfidence: 0.5 }), SEC("Mute.")]))).confirm, true);
  // Not used when the first tier acted, and never without "confirm" unless consistent.
  assert.equal(opens(await d.dispatch(final([P("Open Safari."), SEC("Open Brave.")]))), "com.apple.Safari");
  assert.notEqual((await d.dispatch(final([P("open august"), SEC("Open the podcast.")], { accept: ["suggest", "check"] }))).decision, "act");
});

test("a bare name from a secondary is never immediate: one Return (the remaining wrong acts in design4 M3 were bare alternatives)", async () => {
  const d = make();
  const bare = asAct(await d.dispatch(final([P("Oh the spot of fight.", { minConfidence: 0.5 }), SEC("Spotify.")])));
  assert.deepEqual([opens(bare), bare.confirm, bare.voice?.via], ["com.spotify.client", true, "secondary"]);
  // The same bare name from the primary acts (an exact, non-dictionary name of ≥ 4 letters).
  assert.equal(asAct(await d.dispatch(final([P("Spotify.")]))).confirm, false);
  // A learned alias for a name said alone is still a bare name when a secondary says it.
  const store = new DictionaryStore({ persist: false });
  store.load();
  for (const phrase of ["spotify", "spotty fly"]) {
    assert.ok(store.bind({ list: "aliases", phrase, target: { kind: "openApp", bundleId: "com.spotify.client" } }, { recognizer: "apple-dt/en-US", source: "manual" }).ok, phrase);
  }
  const learned = make({ dictionary: nonCountingLookup(store) });
  for (const secondary of ["Spotify.", "Spotty fly."]) {
    const held = asAct(await learned.dispatch(final([P("Oh the spot of fight.", { minConfidence: 0.5 }), SEC(secondary)])));
    assert.deepEqual([opens(held), held.confirm, held.voice?.via], ["com.spotify.client", true, "secondary"], secondary);
  }
});

// ---------------------------------------------------------------- policy first and last

test("policy: a refusal in the first tier refuses; deletion vocabulary in any secondary turns the alternatives off", async () => {
  const d = make();
  const refused = await d.dispatch(final([EN("Open Pages.", { confidence: 0.9 }), DE("Lösche Pages.", { confidence: 0.4 })]));
  assert.equal(refused.decision, "refuse");
  assert.equal((await d.dispatch(final([P("Empty the trash.")]))).decision, "refuse");
  // The consistent "Open Brave." would act, but another alternative asks to delete: no alternative is used,
  // and none reaches the take memo's near miss.
  const off = await d.dispatch(final([P("open grave"), SEC("Open Brave."), SEC("Delete Brave.", "apple-dt/de-DE")]));
  assert.notEqual(off.decision, "act");
  assert.deepEqual(takeDetailsOf(off)?.nearMiss?.others ?? [], []);
  for (const deletion of ["Trash Brave.", "Brave in den Papierkorb.", "remove brave"]) {
    assert.notEqual((await d.dispatch(final([P("open grave"), SEC("Open Brave."), SEC(deletion)]))).decision, "act", deletion);
  }
  // A secondary that is itself a deletion request never refuses the take (it is gated) and never acts.
  assert.notEqual((await d.dispatch(final([P("open grave"), SEC("Delete Brave.")]))).decision, "refuse");
});

test("policy: the host's pick decides compound and deixis; another peer's deixis is a mishearing, its compound a veto", async () => {
  const d = make();
  const compound = await d.dispatch(final([EN("Open Safari and then open Pages", { confidence: 0.8 }), DE("Öffne Safari.", { confidence: 0.6 })]));
  assert.deepEqual([compound.decision, compound.decision === "fallthrough" && compound.reason], ["fallthrough", "compound"]);
  const deictic = await d.dispatch(final([EN("Open this page.", { confidence: 0.8 }), DE("Öffne Safari.", { confidence: 0.6 })]));
  assert.deepEqual([deictic.decision, deictic.decision === "fallthrough" && deictic.reason], ["fallthrough", "deictic"]);
  const misheard = asAct(await d.dispatch(final([DE("Öffne Safari.", { confidence: 0.8 }), EN("Open this cord.", { confidence: 0.4 })])));
  assert.deepEqual([opens(misheard), misheard.confirm], ["com.apple.Safari", false]);
  const veto = asAct(await d.dispatch(final([DE("Öffne Safari.", { confidence: 0.8 }), EN("Open Safari and then open Pages", { confidence: 0.4 })])));
  assert.equal(veto.confirm, true);
});

// ---------------------------------------------------------------- check gate

test("check gate: low_confidence + voice.check only for hosts that accept \"check\", on short misses with a doubt signal", async () => {
  const d = make();
  const garbled = (extra: Partial<InstantRequest> = {}) => d.dispatch(final([EN("Oh the kind order.", { minConfidence: 0.1 })], extra));
  const checked = await garbled();
  assert.deepEqual(wire(checked), { seq: 1, source: "grammar", decision: "fallthrough", reason: "low_confidence", voice: { source: "apple-dt/en-US", check: true } });
  // The shared fixture's shape exactly.
  const fixture = readJson<InstantResponse>("instant/fallthrough-low-confidence.json");
  assert.deepEqual(wire(await garbled({ seq: 5 })), wire(fixture));
  // Without "check" the agent gets it as today.
  for (const accept of [undefined, ["suggest", "confirm"]] as const) {
    const plain = await garbled(accept ? { accept: [...accept] } : { accept: undefined });
    assert.deepEqual([plain.decision, plain.decision === "fallthrough" && plain.reason], ["fallthrough", "no_match"], String(accept));
  }
  // Signals: the lowest word confidence, an utterance the router cannot place, first-tier disagreement.
  const sent = (text: string, extra: Partial<VoiceHypothesis> = {}) => EN(text, extra);
  assert.equal(checkGate({ accept: ACCEPT }, sent("Open the garage door", { minConfidence: 0.1 }), []), true);
  assert.equal(checkGate({ accept: ACCEPT }, sent("Open the garage door", { minConfidence: 0.5 }), []), false);
  assert.equal(checkGate({ accept: ACCEPT }, sent("Mhm kind order"), []), true, "intent other ≤ 0.3");
  assert.equal(checkGate({ accept: ACCEPT }, sent("Open the garage door", { minConfidence: 0.5, confidence: 0.45 }), [sent("Open the garage door"), DE("Oben Kalender.")]), true);
  // Disagreement alone is no doubt when the sent hypothesis was heard confidently (or its confidence is unknown):
  // the other language's peer garbles nearly every utterance.
  assert.equal(checkGate({ accept: ACCEPT }, sent("Open the garage door", { minConfidence: 0.5, confidence: 0.7 }), [sent("Open the garage door"), DE("Oben Kalender.")]), false);
  assert.equal(checkGate({ accept: ACCEPT }, sent("Open the garage door", { minConfidence: 0.5 }), [sent("Open the garage door"), DE("Oben Kalender.")]), false);
  assert.equal(checkGate({ accept: ACCEPT }, sent("Can you tell me how I export my slides as a PDF in Keynote", { minConfidence: 0.05 }), []), false, "> 8 words");
  assert.equal(checkGate({}, sent("Mhm kind order", { minConfidence: 0.05 }), []), false);
  assert.equal(wordsDisagree("Open Pages", "Öffne Pages"), false);
  assert.equal(wordsDisagree("Of the kind order", "Oben Kalender"), true);
  // Policy misses never show the check state: the agent gets deixis and compounds.
  const deictic = await d.dispatch(final([EN("Summarize this.", { minConfidence: 0.05 })]));
  assert.deepEqual([deictic.decision, deictic.decision === "fallthrough" && deictic.reason], ["fallthrough", "deictic"]);
});

// ---------------------------------------------------------------- did you mean (§5.3)

test("did-you-mean: the shared fixture, one-row and multi-row titles, spoken row labels, the heard subtitle, cards that validate strictly", async () => {
  const d = make();
  // shared/fixtures/instant/list-did-you-mean.json, byte for byte (minus timing and scope).
  const expected = readJson<InstantResponse>("instant/list-did-you-mean.json");
  const response = await d.dispatch(final([P("open recast")], { seq: 7 }));
  assert.deepEqual(wire(response), wire(expected));

  const one = asList(await d.dispatch(final([P("open paces")])));
  assert.deepEqual([one.intent, one.title, one.voice], ["open_app", "Did you mean Pages?", { heard: "paces", source: "parakeet-v3", via: "sound", didYouMean: true }]);
  assert.deepEqual(rows(one.card), [{ title: "Pages", bundleId: "com.apple.Pages" }], "the row label is the spoken name");
  const many = asList(await d.dispatch(final([P("open system")])));
  assert.deepEqual([many.title, rows(many.card).map((row) => row.title)], ["Did you mean…", ["System Settings", "System Information"]]);
  for (const list of [one, many, asList(await d.dispatch(final([EN("Open Notes.", { confidence: 0.6 }), DE("Öffne Notion.", { confidence: 0.5 })])))]) {
    const labels = rows(list.card).map((row) => row.title);
    assert.equal(list.title, labels.length === 1 ? `Did you mean ${labels[0]}?` : "Did you mean…");
    assert.ok(labels.length <= 3);
    assert.ok(parseVoiceMeta(list.voice)?.didYouMean);
    assert.ok(validateCard(list.card, { mode: "strict", allowedActions: HOST_ACTION_TYPES }).ok);
  }
  // Older hosts get the same list (did-you-mean is an ordinary list): no "suggest" needed.
  assert.equal((await d.dispatch({ text: "open recast", phase: "final", seq: 1, inputMode: "voice" })).decision, "list");
});

// ---------------------------------------------------------------- voice URL guard (§5.4)

test("voice URL guard: an unknown spoken domain needs one Return (hosts that accept confirm); known sites, typed text and older hosts act as today", async () => {
  const d = make();
  const unknown = asAct(await d.dispatch(final([P("open guests dot com")])));
  assert.deepEqual([unknown.action, unknown.confirm, unknown.voice], [{ type: "openURL", url: "https://guests.com" }, true, { heard: "guests.com", source: "parakeet-v3", via: "url" }]);
  assert.equal(asAct(await d.dispatch(final([P("open github dot com")]))).confirm, false);
  assert.equal(asAct(await d.dispatch(final([P("go to de dot wikipedia dot org")]))).confirm, false, "subdomains of known sites");
  assert.equal(asAct(await d.dispatch(final([P("open guests dot com")], { accept: ["suggest", "check"] }))).confirm, false);
  assert.equal(asAct(await d.dispatch({ text: "open guests dot com", phase: "final", seq: 1, inputMode: "voice" })).confirm, false);
  assert.equal(asAct(await d.dispatch({ text: "open guests.com", phase: "final", seq: 1, accept: ACCEPT })).confirm, false, "typed");
});

// ---------------------------------------------------------------- "No, I meant X"

test("No, I meant X: right after an act, X acts through the lane and names the corrected take; nothing is learned", async () => {
  const memo = new InMemoryTakeMemo();
  const dictionary = fakeDictionary();
  const d = make({ takeMemo: memo, dictionary });
  const acted = (takeId: string): TakeMemoRecord => ({
    takeId, at: Date.now(), inputMode: "voice", hypotheses: [P("open motion")], decision: "act", recognizer: "parakeet-v3",
    offered: ["com.apple.Music"], acted: { kind: "openApp", bundleId: "com.apple.Music" },
  });
  // Nothing acted yet: "No, I meant Notion" is an ordinary utterance.
  assert.equal(opens(await d.dispatch(final([P("No, I meant Notion.")], { takeId: "take-42" }))), undefined);
  memo.remember(acted("take-41"));
  // shared/fixtures/instant/act-no-i-meant.json (its act carries no card).
  const fixture = readJson<InstantResponse>("instant/act-no-i-meant.json");
  const response = await d.dispatch(readJson<InstantRequest>("instant/requests/final-no-i-meant.request.json"));
  assert.deepEqual(wire(response, ["card"]), wire(fixture));
  for (const [text, hypothesis] of [["nein, ich meinte Notion", DE], ["Nein, Notion.", DE], ["no I said notion", EN], ["Nö, eigentlich Notion", DE]] as const) {
    const corrected = asAct(await d.dispatch(final([hypothesis(text)], { takeId: "take-43" })));
    assert.deepEqual([opens(corrected), corrected.voice?.correctsTakeId], ["notion.id", "take-41"], text);
  }
  // Typed too.
  assert.equal(asAct(await d.dispatch({ text: "No, I meant Notion", phase: "final", seq: 3, takeId: "take-44" })).voice?.correctsTakeId, "take-41");
  // Policy holds for X; a bare "nein, X" that does not act is no correction; the take itself is never "corrected".
  assert.equal((await d.dispatch(final([P("No, I meant delete Pages.")], { takeId: "take-45" }))).decision, "refuse");
  assert.equal((await d.dispatch(final([DE("Nein, danke.")], { takeId: "take-46" }))).decision === "act", false);
  const self = await d.dispatch(final([P("No, I meant Notion.")], { takeId: "take-41" }));
  assert.ok(self.decision !== "act" && !(self.decision === "fallthrough" && self.voice?.correctsTakeId), "a take never corrects itself");
  // Policy first across the first tier: another peer's deletion refuses the take, correction or not.
  for (const peers of [[EN("No, I meant Notion.", { confidence: 0.8 }), DE("Lösche Notion.", { confidence: 0.6 })],
    [EN("No, I meant Notion.", { confidence: 0.8 }), DE("Leere den Papierkorb.", { confidence: 0.6 })],
    [DE("Nein, Notion.", { confidence: 0.8 }), EN("Delete Notion.", { confidence: 0.6 })]]) {
    assert.equal((await d.dispatch(final(peers, { takeId: "take-47" }))).decision, "refuse", peers.map((h) => h.text).join(" | "));
  }
  // A peer's correction never overrides the host's own actionable pick (arbitration decides) …
  for (const peer of ["Nein, ich meinte Notion.", "Nein, Notion."]) {
    const pick = asAct(await d.dispatch(final([EN("Open Pages.", { confidence: 0.8 }), DE(peer, { confidence: 0.5 })], { takeId: "take-48" })));
    assert.deepEqual([opens(pick), pick.voice?.correctsTakeId], ["com.apple.Pages", undefined], peer);
  }
  // … rescues a garbled pick, and below τ needs one Return like any lone peer act.
  const rescued = asAct(await d.dispatch(final([EN("Nine, ish mine to motion.", { confidence: 0.6 }), DE("Nein, ich meinte Notion.", { confidence: 0.7 })], { takeId: "take-49" })));
  assert.deepEqual([opens(rescued), rescued.confirm, rescued.voice?.correctsTakeId], ["notion.id", false, "take-41"]);
  const low = asAct(await d.dispatch(final([EN("Nine, ish mine to motion.", { confidence: 0.6 }), DE("Nein, ich meinte Notion.", { confidence: 0.2 })], { takeId: "take-50" })));
  assert.deepEqual([opens(low), low.confirm], ["notion.id", true]);
  // Only a closed target is named as a correction: a display sleep acts as it would anyway, but offers nothing to learn.
  const display = asAct(await d.dispatch(final([P("No, I meant turn off the display.")], { takeId: "take-51" })));
  assert.deepEqual([display.action.type, display.voice?.correctsTakeId], ["system", undefined]);
  assert.deepEqual(dictionary.uses, [], "no rule decided, nothing counted or learned");
  assert.deepEqual([correctionTarget("No, I meant Notion."), correctionTarget("nein, Notion"), correctionTarget("Notion"), correctionTarget("No.")],
    [{ target: "Notion", explicit: true }, { target: "Notion", explicit: false }, null, null]);
});

// ---------------------------------------------------------------- learned rules: order, scope, policy, noteUse

test("learned order: exact alias → exact app name in an open form → grammar → fixes (only misses), scoped to the recognizer", async () => {
  const dictionary = fakeDictionary({
    recognizer: "parakeet-v3",
    aliases: { "mach kein note auf": { kind: "openApp", bundleId: "com.apple.Keynote" }, "open pages": { kind: "openApp", bundleId: "com.apple.Numbers" } },
    appNames: { recast: "com.raycast.macos", safari: "com.brave.Browser" },
    fixes: { clod: "Claude", "open safari": "open Notes" },
  });
  const d = make({ dictionary });
  // 1. An exact utterance alias wins over the grammar ("open pages" was taught to mean Numbers).
  const alias = asAct(await d.dispatch(final([P("Open Pages.")])));
  assert.deepEqual([opens(alias), alias.voice?.via, alias.voice?.learnedEntryId], ["com.apple.Numbers", "alias", "a_open_pages"]);
  assert.equal(opens(await d.dispatch(final([P("Mach kein Note auf.")]))), "com.apple.Keynote");
  // 2. An exact learned app name inside an open form wins over the spoken matcher (and an installed exact name).
  // shared/fixtures/instant/act-learned.json (its act carries no card; the entry id is the dictionary's).
  const name = asAct(await d.dispatch(final([P("open recast")], { seq: 3 })));
  const learnedFixture = readJson<Act>("instant/act-learned.json");
  assert.deepEqual(wire(name, ["card"]), wire({ ...learnedFixture, voice: { ...learnedFixture.voice, learnedEntryId: "n_recast" } }));
  assert.equal(opens(await d.dispatch(final([P("open safari")]))), "com.brave.Browser");
  // A name said alone is no open form: no learned app name.
  assert.notEqual(opens(await d.dispatch(final([P("Recast.")]))), "com.raycast.macos");
  // 4. Fixes turn a miss into a hit only ("open safari" acts before any fix could rewrite it).
  const fixed = asAct(await d.dispatch(final([P("Open clod.")])));
  assert.deepEqual([opens(fixed), fixed.voice?.via, fixed.voice?.learnedEntryId, fixed.voice?.heard], ["com.anthropic.claudefordesktop", "learned", "f_clod", "clod"]);
  // Scope: another recognizer, typed text and partials see none of these rules.
  assert.equal(opens(await d.dispatch(final([EN("open recast")]))), undefined);
  assert.equal(opens(await d.dispatch({ text: "open recast", phase: "final", seq: 1 })), undefined);
  assert.equal((await d.dispatch({ text: "open recast", phase: "partial", seq: 1, inputMode: "voice" })).decision === "act", false);
  assert.ok(dictionary.calls.includes("alias:any"), "typed finals look up `any` rules");
  // Typed text uses steps 1, 2 and 6 with `any` rules.
  const typed = make({ dictionary: fakeDictionary({ aliases: { "lauter bitte sehr": { kind: "system", op: "volume.step", value: 0.1 } }, appNames: { recast: "com.raycast.macos" } }) });
  const typedAlias = asAct(await typed.dispatch({ text: "lauter bitte sehr", phase: "final", seq: 1 }));
  assert.deepEqual([typedAlias.action, typedAlias.title, typedAlias.voice], [{ type: "system", op: "volume.step", value: 0.1 }, "Volume up", { via: "alias", learnedEntryId: "a_lauter_bitte_sehr" }]);
  assert.equal(opens(await typed.dispatch({ text: "open recast", phase: "final", seq: 1 })), "com.raycast.macos");
});

test("learned rules: policy first and last, closed targets, installed apps only, never merged into the fuzzy matcher", async () => {
  const hostile = fakeDictionary({
    aliases: {
      "delete pages": { kind: "openApp", bundleId: "com.apple.Pages" }, "summarize this": { kind: "openApp", bundleId: "com.apple.Notes" },
      "open my vault": { kind: "openApp", bundleId: "md.obsidian" },
      "show the files": { kind: "openURL", url: "file:///etc/passwd" } as unknown as SafeTarget,
      "dim it all now": { kind: "system", op: "display.sleep" } as unknown as SafeTarget,
    },
    appNames: { trash: "com.apple.finder", "pages and then": "com.apple.Pages" },
    fixes: { pages: "the trash", kino: "Keynote" },
  });
  const d = make({ dictionary: hostile });
  // Policy first: the words are refused, deictic or compound before any rule is looked up.
  assert.equal((await d.dispatch(final([P("Delete Pages.")]))).decision, "refuse");
  assert.equal((await d.dispatch(final([P("Summarize this.")]))).decision, "fallthrough");
  assert.equal((await d.dispatch(final([P("Open pages and then write a letter.")]))).decision, "fallthrough");
  // Closed targets and installed apps only (Obsidian is not in the fixture index).
  for (const text of ["Open my vault.", "Show the files.", "Dim it all now."]) assert.notEqual((await d.dispatch(final([P(text)]))).decision, "act", text);
  // Policy last: a fix whose rewrite is a deletion never acts ("open pages" acts on its own anyway).
  assert.equal(opens(await d.dispatch(final([P("Open pages.")]))), "com.apple.Pages");
  assert.notEqual((await d.dispatch(final([P("Move pages.")]))).decision, "refuse", "a rewrite never turns into a refusal of the take");
  assert.equal(opens(await d.dispatch(final([P("Open kino.")]))), "com.apple.Keynote", "a fix to an app name turns the miss into a hit");
  // Exact only: near forms of a learned name do not act through it.
  const store = new DictionaryStore({ persist: false });
  store.load();
  assert.ok(store.bind({ list: "appNames", heard: "calender", bundleId: "com.cron.electron", display: "Notion Calendar" }, { recognizer: "any", source: "manual" }).ok);
  const learned = make({ dictionary: nonCountingLookup(store) });
  assert.equal(opens(await learned.dispatch(final([P("Open calender.")]))), "com.cron.electron");
  assert.equal(opens(await learned.dispatch(final([P("Open calendar.")]))), "com.apple.iCal", "the real name still opens Calendar");
  assert.equal(opens(await learned.dispatch(final([P("Open calenders.")]))), "com.apple.iCal", "a variant of the learned name is not the learned name");
});

test("noteUse: a rule that decided a final counts once; partials, non-deciding lookups and non-counting lookups never count", async () => {
  const dictionary = fakeDictionary({ appNames: { recast: "com.raycast.macos" }, fixes: { clod: "Claude" } });
  const d = make({ dictionary });
  await d.dispatch(final([P("open recast")]));
  await d.dispatch({ text: "open recast", phase: "partial", seq: 2, inputMode: "voice" });
  await d.dispatch(final([P("Open Safari.")]));
  await d.dispatch(final([P("Open clod.")]));
  assert.deepEqual(dictionary.uses, ["n_recast", "f_clod"]);
  // The learn lane and /invoke get a non-counting lookup (server.ts): the same decisions, no uses.
  const quiet = make({ dictionary: nonCountingLookup(dictionary) });
  assert.equal(opens(await quiet.dispatch(final([P("open recast")]))), "com.raycast.macos");
  assert.deepEqual(dictionary.uses, ["n_recast", "f_clod"]);
  // Peers that disagree get a did-you-mean list, which is no learned decision even when one peer's act was.
  const list = asList(await d.dispatch(final([EN("open recast", { confidence: 0.6 }), DE("Öffne Notion.", { confidence: 0.5 })])));
  assert.deepEqual([rows(list.card).map((row) => row.bundleId), list.voice?.learnedEntryId], [["com.raycast.macos", "notion.id"], undefined]);
  assert.deepEqual(dictionary.uses, ["n_recast", "f_clod"]);
  // A per-dispatch dictionary (the regression check) replaces the dispatcher's.
  assert.equal(opens(await make().dispatch(final([P("open recast")]), undefined, { dictionary })), "com.raycast.macos");
});

// ---------------------------------------------------------------- the take memo's details

test("take memo details: heard and recognizer of the sent hypothesis, a top-3 near miss with short labels, offered rows only, others without the sent text", async () => {
  const d = make();
  const request = final([EN("open notion calender", { confidence: 0.6 }), DE("Öffne Notion Kalender.", { confidence: 0.4 }), SEC("Open motion calendar.")], { takeId: "t0" });
  const response = await d.dispatch(request);
  const details = takeDetailsOf(response);
  assert.ok(details, "the dispatcher attaches the details");
  assert.equal(JSON.stringify(response).includes("nearMiss"), false, "never on the wire");
  assert.equal(details.recognizer, "apple-dt/en-US");
  const record = takeRecordFor(request, response, Date.now(), details)!;
  assert.equal(record.recognizer, "apple-dt/en-US");

  const miss = await d.dispatch(final([P("open frobnik"), SEC("open frob nick"), SEC("öffne Frobnik", "apple-dt/de-DE"), SEC("open frobnik")]));
  assert.deepEqual(takeDetailsOf(miss), {
    heard: "frobnik", recognizer: "parakeet-v3", offered: [],
    nearMiss: { heard: "frobnik", candidates: [], others: ["open frob nick", "öffne Frobnik"] },
  });
  const offer = await d.dispatch(final([P("open paces"), SEC("Open paces, please.")], { accept: ["suggest", "check"] }));
  const offerDetails = takeDetailsOf(offer)!;
  assert.deepEqual([offerDetails.heard, offerDetails.offered], ["paces", ["com.apple.Pages"]]);
  assert.deepEqual(offerDetails.nearMiss?.candidates[0], { bundleId: "com.apple.Pages", display: "Pages", score: offerDetails.nearMiss?.candidates[0]?.score });
  assert.ok((offerDetails.nearMiss?.candidates.length ?? 0) <= 3);
  for (const candidate of offerDetails.nearMiss?.candidates ?? []) assert.ok(candidate.score >= 0 && candidate.score <= 1 && Math.round(candidate.score * 100) === candidate.score * 100);
  // An app act's card lists the app, then its close alternatives: the host shows them after "Not this", so the
  // memo counts them as offered (pickable, learnable against this take) — the acted app first.
  const act = await d.dispatch(final([P("open page is")]));
  assert.deepEqual(takeDetailsOf(act)?.offered, []);
  const actRows = act.decision === "act" ? offeredBundleIds(act.card) : [];
  assert.equal(actRows[0], "com.apple.Pages");
  assert.deepEqual(takeRecordFor(final([P("open page is")], { takeId: "t1" }), act, Date.now(), takeDetailsOf(act))?.offered, actRows);
  // The sent hypothesis had no open form, another peer decided: the memo's heard name stays the sent one's (none).
  const rescued = await d.dispatch(final([EN("Of the bitter safari.", { confidence: 0.5 }), DE("Öffne bitte Safari.", { confidence: 0.7 })], { takeId: "t2" }));
  const rescuedRecord = takeRecordFor(final([EN("Of the bitter safari.")], { takeId: "t2" }), rescued, Date.now(), takeDetailsOf(rescued))!;
  assert.deepEqual([rescuedRecord.recognizer, rescuedRecord.heard], ["apple-dt/en-US", undefined]);
});

// ---------------------------------------------------------------- older hosts

test("older hosts (no hypotheses, no accept): today's vocabulary — no confirm for voice doubt, no check state; typed finals unchanged", async () => {
  const d = make();
  const legacy = (text: string, locale = "en-US") => d.dispatch({ text, phase: "final", seq: 1, inputMode: "voice", locale });
  assert.deepEqual([opens(await legacy("open Pages")), asAct(await legacy("open Pages")).confirm], ["com.apple.Pages", false]);
  assert.equal(opens(await legacy("Mach mal Pages auf.", "de-DE")), "com.apple.Pages", "better mapping");
  const garbled = await legacy("Oh the kind order.");
  assert.deepEqual([garbled.decision, garbled.decision === "fallthrough" && garbled.reason], ["fallthrough", "no_match"]);
  assert.equal(asAct(await legacy("open guests dot com")).confirm, false);
  // The legacy shape of a voice final: no source (the recognizer is unknown).
  assert.deepEqual(asAct(await legacy("open Pages")).voice, { heard: "pages", via: "exact" });
  // The shared legacy request fixture parses and acts.
  assert.equal(opens(await d.dispatch(readJson<InstantRequest>("instant/requests/final-legacy.request.json"))), "com.apple.Pages");
  // Typed finals: the same decisions with and without the voice pipeline's dictionary and memo (nothing learned).
  const typed = make({ dictionary: fakeDictionary(), takeMemo: new InMemoryTakeMemo() });
  const plain = make();
  for (const text of ["open figma", "open pages", "open safari", "15% of 340", "open github.com", "no I meant notion", "empty the trash", "find invoice"]) {
    const a = await typed.dispatch({ text, phase: "final", seq: 1 });
    const b = await plain.dispatch({ text, phase: "final", seq: 1 });
    assert.deepEqual(wire(a), wire(b), text);
  }
  // Without accept, every negative's voice final stays in today's vocabulary.
  for (const item of negatives().slice(0, 120)) {
    const response = await legacy(item.text, item.lang === "de" ? "de-DE" : "en-US");
    assert.ok(!(response.decision === "act" && response.confirm) && !(response.decision === "fallthrough" && response.reason === "low_confidence"), item.text);
  }
});

test("voiceTake: the first tier is every primary and peer; a host pick among the secondaries only stands in when no first tier was sent", () => {
  assert.deepEqual(voiceTake({ text: "a" }).firstTier, [0]);
  assert.equal(voiceTake({ text: "a" }).legacy, true);
  const take = voiceTake({ text: "Öffne Pages.", hypotheses: [EN("Open pages."), DE("Öffne Pages."), SEC("Öffne Paste.")] });
  assert.deepEqual([take.sent, take.firstTier, take.secondary, take.legacy], [1, [0, 1], [2], false]);
  const unknownText = voiceTake({ text: "something else", hypotheses: [P("open pages"), SEC("open paste")] });
  assert.equal(unknownText.sent, 0);
  const secondariesOnly = voiceTake({ text: "open paste", hypotheses: [SEC("open pages"), SEC("open paste")] });
  assert.deepEqual([secondariesOnly.firstTier, secondariesOnly.hypotheses[1]?.role], [[1], "primary"]);
});

// ---------------------------------------------------------------- contamination (665 negatives)

test("contamination: 0 false acts on the 665 negatives — without and with a dictionary learned from the ASR corpus, with and without hypotheses", async (t) => {
  const items = negatives();
  assert.equal(items.length, 665);
  assert.deepEqual(["neg-open-noun", "neg-question", "neg-word", "neg-appnoun"].map((src) => items.filter((item) => item.src === src).length), [536, 68, 48, 13]);
  // A dense dictionary: every near and far ASR form of the corpus as an app name, a fix and an alias — except
  // forms whose words a negative says (a rule for exactly those words acting is the rule, not contamination).
  const said = items.map((item) => ` ${foldPhrase(item.text)} `);
  const store = new DictionaryStore({ persist: false });
  store.load();
  let rules = 0;
  for (const [bundleId, [near, far]] of Object.entries(table<Record<string, readonly [readonly string[], readonly string[]]>>("ASR"))) {
    const app = APPS.find((record) => record.bundleId === bundleId);
    if (!app) continue;
    for (const form of [...near, ...far]) {
      const heard = nameCore(form);
      if (!heard || said.some((words) => words.includes(` ${heard} `))) continue;
      const scope = { recognizer: "any", source: "manual" as const };
      rules += Number(store.bind({ list: "appNames", heard, bundleId, display: app.name }, scope).ok);
      rules += Number(store.bind({ list: "fixes", heard, intended: app.name }, scope).ok);
      rules += Number(store.bind({ list: "aliases", phrase: `mach ${heard} auf`, target: { kind: "openApp", bundleId } }, scope).ok);
    }
  }
  assert.ok(rules > 500, `rules ${rules}`);
  const cache = apps();
  const runs = { plain: make({ apps: cache }), learned: make({ apps: cache, dictionary: nonCountingLookup(store) }) };
  const summary: string[] = [];
  for (const [name, dispatcher] of Object.entries(runs)) {
    for (const mode of ["legacy", "hypotheses"] as const) {
      let falseActs = 0;
      let confirms = 0;
      let offers = 0;
      for (const item of items) {
        const locale = item.lang === "de" ? "de-DE" : "en-US";
        const request: InstantRequest = mode === "legacy"
          ? { text: item.text, phase: "final", seq: 1, inputMode: "voice", locale }
          : final([{ text: item.text, source: `apple-dt/${locale}`, role: "peer", confidence: 0.7, locale }], { locale });
        const response = await dispatcher.dispatch(request);
        if (response.decision === "act" && !(item.okApp && opens(response) === item.okApp)) {
          if (response.confirm) confirms++;
          else falseActs++;
        }
        if (response.decision === "list" && response.voice?.didYouMean) offers++;
      }
      summary.push(`${name}/${mode}: false acts ${falseActs}, behind a Return ${confirms}, offers ${offers}`);
      assert.equal(falseActs, 0, `${name}/${mode}`);
      assert.equal(confirms, 0, `${name}/${mode}`);
      assert.ok(offers <= 0.07 * items.length, `${name}/${mode} offers ${offers}`);
    }
  }
  t.diagnostic(`${rules} learned rules; ${summary.join("; ")}`);
});
