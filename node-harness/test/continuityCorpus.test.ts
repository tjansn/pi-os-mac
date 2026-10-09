import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { contextScope } from "../src/agent/routing/contextScope.js";
import { isOneLineText } from "../src/contracts/actions.js";
import {
  INSTANT_LIMITS, type InstantAccept, type InstantAppClass, type InstantFieldKind, type InstantRequest, type InstantResponse, type InstantTarget, type VoiceHypothesis,
} from "../src/contracts/instant.js";
import { explicitRemainder, hasPiPrefix, searchQuery, shapeFillText } from "../src/instant/fill.js";
import { parseInstant } from "../src/instant/grammar/index.js";
import { normalize } from "../src/instant/normalize.js";
import { mentionsDeletion } from "../src/instant/voice.js";
import { createEvalLane, groupTakes, loadCorpus, readBench, spokenTable, VOICE_FIXTURES } from "../scripts/voice-eval.mjs";

/*
 * The continuity corpus (DESIGN5 §11 WP2 with Tom's binding answers of 2026-10-08): synthetic EN/DE/mixed takes
 * with must-fill/must-not labels through the REAL dispatcher, for every field kind, plus the golden equivalence
 * over every instant corpus the repo has (the r3/mapping phrasings and negatives, the voice gold and the
 * context-scope sets): without `fill` (or without a `target`) nothing changes byte for byte, and with a focused
 * search field only today's misses may turn into a fill. Deletion, deictic and window-band takes are never typed.
 * Text fixtures only; no host, no model, no logs with content.
 */

interface Item { id: string; class: string; lang: "en" | "de" | "mix"; text: string; remainder?: string; query?: string }
const corpus = JSON.parse(readFileSync(join(import.meta.dirname, "fixtures", "continuity-corpus.json"), "utf8")) as {
  version: number; about: string; classes: Record<string, string>; items: Item[];
};
const MUST_FILL = new Set(["dictation", "explicit", "explicit-held", "search"]);
const ALL: InstantAccept[] = ["suggest", "check", "confirm", "fill"];
const TODAY: InstantAccept[] = ["suggest", "check", "confirm"];
const IMPLICIT = new Set<InstantFieldKind>(["search", "address", "text", "multiline"]);

const P = (text: string): VoiceHypothesis => ({ text, source: "parakeet-v3", role: "primary", confidence: 0.92, minConfidence: 0.6 });
const localeOf = (lang: string): string => (lang === "en" ? "en-US" : "de-DE");
/** One take's primary final (a new host: hypotheses + accept). */
const final = (text: string, lang: string, accept: InstantAccept[], target?: InstantTarget): InstantRequest => ({
  text, phase: "final", seq: 1, inputMode: "voice", locale: localeOf(lang), hypotheses: [P(text)], accept, ...(target ? { target } : {}),
});
const fieldOf = (kind: InstantFieldKind): NonNullable<InstantTarget["field"]> => ({ kind, ...(kind === "credential" ? {} : { empty: true }), ready: true });
const stable = (response: InstantResponse): string => JSON.stringify({ ...response, elapsedMs: 0, seq: 0 });
const isFill = (r: InstantResponse): boolean => r.decision === "act" && r.intent === "fill";
const isOffer = (r: InstantResponse): boolean => r.decision === "fallthrough" && r.voice?.fill === "offer";
const isWeb = (r: InstantResponse): boolean => r.decision === "act" && r.intent === "web";
/** A credential or sensitive field's answer to a non-command: a plain miss, no check card, no hints. */
const isSecretMiss = (r: InstantResponse): boolean => r.decision === "fallthrough" && r.reason === "no_match" && !r.voice?.check && !r.hints;
const fillText = (r: InstantResponse): { text: string; submit: boolean; confirm: boolean } | null =>
  r.decision === "act" && r.action.type === "typeIntoPinned" ? { text: r.action.text, submit: r.action.submit === true, confirm: r.confirm } : null;

/** Every field kind with the app class the host would report beside it, plus no field at all and a search field outside a browser. */
const COMBOS: readonly (readonly [InstantFieldKind | null, InstantAppClass])[] = [
  [null, "browser"], ["search", "browser"], ["address", "browser"], ["search", "other"], ["text", "other"], ["multiline", "other"],
  ["terminal", "terminal"], ["sensitive", "browser"], ["credential", "browser"], ["confirm", "browser"], ["rename", "finder"],
];

test("continuity corpus: classes, ids, languages and texts are well-formed (no user content)", () => {
  assert.equal(corpus.version, 1);
  const count = (cls: string) => corpus.items.filter((item) => item.class === cls).length;
  assert.deepEqual(Object.keys(corpus.classes).sort(), [...new Set(corpus.items.map((item) => item.class))].sort());
  assert.deepEqual(
    ["dictation", "command", "page", "task", "deletion", "control", "correction", "pi", "explicit", "explicit-held", "explicit-refused", "search"].map(count),
    [41, 22, 25, 41, 13, 18, 3, 5, 10, 2, 2, 6],
  );
  assert.equal(new Set(corpus.items.map((item) => item.id)).size, corpus.items.length);
  for (const item of corpus.items) {
    assert.ok(["en", "de", "mix"].includes(item.lang), item.id);
    assert.ok(item.text.length > 0 && item.text.length <= INSTANT_LIMITS.maxHypothesisChars && isOneLineText(item.text), item.id);
    assert.equal(item.remainder !== undefined, item.class === "explicit" || item.class === "explicit-held", item.id);
    assert.equal(item.query !== undefined, item.class === "search", item.id);
  }
  for (const lang of ["en", "de"]) assert.ok(corpus.items.filter((item) => item.lang === lang && MUST_FILL.has(item.class)).length >= 15, lang);
});

test("continuity corpus × every field kind: must-fill takes are typed where the kind allows it, must-not takes never are", async (t) => {
  const { dispatcher } = createEvalLane();
  let fills = 0, offers = 0, secrets = 0, unchanged = 0, webs = 0, refusals = 0;
  for (const item of corpus.items) {
    const today = await dispatcher.dispatch(final(item.text, item.lang, TODAY));
    for (const [kind, app] of COMBOS) {
      const tgt: InstantTarget = { app, ...(kind ? { field: fieldOf(kind) } : {}) };
      const response = await dispatcher.dispatch(final(item.text, item.lang, ALL, tgt));
      const where = `${item.id} ${JSON.stringify(item.text)} → ${kind ?? "no field"} in ${app}: ${JSON.stringify(response)}`;
      const same = stable(response) === stable(today);
      const typed = fillText(response);
      switch (item.class) {
        case "dictation":
          if (kind && IMPLICIT.has(kind)) {
            assert.deepEqual(typed, { text: shapeFillText(item.text, kind), submit: kind === "search" || kind === "address", confirm: false }, where);
            fills++;
          } else if (kind === "terminal") {
            assert.ok(isOffer(response), where);
            offers++;
          } else if (kind === "credential" || kind === "sensitive") {
            assert.ok(isSecretMiss(response) && !isFill(response), where);
            secrets++;
          } else {
            assert.ok(same, where);
            unchanged++;
          }
          break;
        case "explicit":
        case "explicit-held": {
          const held = item.class === "explicit-held";
          if (kind === "confirm") {
            assert.equal(response.decision, "refuse", where);
            refusals++;
          } else if (kind === null || kind === "rename") {
            assert.ok(same, where);
            unchanged++;
          } else {
            assert.deepEqual(typed, {
              text: shapeFillText(item.remainder!, kind), submit: !held && (kind === "search" || kind === "address"), confirm: held || kind === "sensitive",
            }, where);
            fills++;
          }
          break;
        }
        case "explicit-refused":
          if (kind === null || kind === "rename") assert.ok(same, where);
          else assert.equal(response.decision, "refuse", where);
          break;
        case "search":
          if (kind === "search" || (kind === "address" && app === "browser")) {
            assert.deepEqual(typed, { text: shapeFillText(item.query!, kind), submit: true, confirm: false }, where);
            fills++;
          } else if (app === "browser") {
            assert.ok(isWeb(response), where);
            webs++;
          } else {
            assert.ok(!isFill(response) && !isOffer(response) && (same || isSecretMiss(response)), where);
          }
          break;
        default:
          // command, page, task, deletion, control, correction, pi: never typed, never offered.
          assert.ok(!isFill(response) && !isOffer(response), where);
          if (item.class === "pi") assert.ok(response.decision === "fallthrough" && !response.voice?.check, where);
          else if (kind === "credential" || kind === "sensitive") assert.ok(same || isSecretMiss(response), where);
          else {
            assert.ok(same, where);
            unchanged++;
          }
      }
    }
  }
  t.diagnostic(`${corpus.items.length} takes × ${COMBOS.length} targets: ${fills} fills, ${offers} offers, ${secrets} secret misses, ${webs} web searches, ${refusals} refusals, ${unchanged} decided as today`);
});

// ---------------------------------------------------------------- golden equivalence over the repo's instant corpora

/** r3/mapping phrasings (3,380) and negatives (665), exactly as voiceCorpus.test.ts builds them (texts and languages only). */
function mappingTexts(): { text: string; lang: string; src: string }[] {
  const t = <T>(name: string) => spokenTable<T>(name);
  const items: { text: string; lang: string; src: string }[] = [];
  const add = (text: string, lang: string, src: string): void => void items.push({ text, lang, src });
  const enT = t<readonly string[]>("EN_T");
  const deT = t<readonly string[]>("DE_T");
  const mixT = t<readonly string[]>("MIX_T");
  for (const [name, , deNames, dePicks, namePicks, mixPicks] of t<readonly (readonly [string, string, readonly string[], readonly number[], readonly (readonly number[])[], readonly number[]])[]>("CORPUS_APPS")) {
    for (const template of enT) add(template.replaceAll("{a}", name), "en", "wrapper-en");
    for (const i of dePicks) add(deT[i]!.replaceAll("{a}", name), "de", "wrapper-de");
    deNames.forEach((deName, k) => { for (const i of namePicks[k]!) add(deT[i]!.replaceAll("{a}", deName), "de", "wrapper-de-name"); });
    for (const i of mixPicks) add(mixT[i]!.replaceAll("{a}", name), "mix", "wrapper-mix");
  }
  const frames = t<readonly string[]>("FRAMES");
  for (const [near, far] of Object.values(t<Readonly<Record<string, readonly [readonly string[], readonly string[]]>>>("ASR"))) {
    const frame = (i: number, x: string): [string, string] => [frames[i % frames.length]!.replace("{x}", x), frames[i % frames.length]!.startsWith("Öffne") ? "de" : "en"];
    near.forEach((x, i) => add(...frame(i, x), "asr-near"));
    far.forEach((x, i) => add(...frame(i + 2, x), "asr-far"));
  }
  for (const [text, lang] of t<readonly (readonly [string, string, unknown])[]>("OTHER")) add(text, lang, "other");
  for (const [text, lang] of t<readonly (readonly [string, string])[]>("NEG")) add(text, lang, "negative");
  for (const [text, lang] of t<readonly (readonly [string, string])[]>("REFUSE")) add(text, lang, "refuse");
  const enNouns = t<readonly string[]>("NEG_EN_NOUNS");
  const enPicks = t<readonly (readonly number[])[]>("NEG_EN_PICKS");
  t<readonly string[]>("NEG_EN_VERBS").forEach((verb, v) => enPicks[v]!.forEach((i) => add(`${verb} ${enNouns[i]}.`, "en", "neg-open-noun")));
  const deNouns = t<readonly string[]>("NEG_DE_NOUNS");
  const dePicks = t<readonly (readonly number[])[]>("NEG_DE_PICKS");
  t<readonly string[]>("NEG_DE_VERBS").forEach((verb, v) => dePicks[v]!.forEach((i) => {
    const noun = deNouns[i]!;
    add(verb === "Kannst du öffnen" ? `Kannst du ${noun} öffnen?` : verb === "Mach" ? `Mach ${noun} auf.` : `${verb} ${noun}.`, "de", "neg-open-noun");
  }));
  const deStart = t<ReadonlySet<string>>("DE_QUESTION_START");
  for (const q of t<readonly string[]>("NEG_QUESTIONS")) add(q, /[äöüß]/.test(q) || deStart.has(q.split(" ")[0]!) ? "de" : "en", "neg-question");
  const deWords = t<ReadonlySet<string>>("DE_WORDS");
  for (const w of t<readonly string[]>("NEG_WORDS")) add(w, deWords.has(w) ? "de" : "en", "neg-word");
  for (const [text] of t<readonly (readonly [string, string])[]>("NEG_APP_NOUNS")) add(text, text.includes("Zeig") ? "de" : "en", "neg-appnoun");
  return items;
}

interface ScopeItem { text: string; lang?: string; gold?: string; cat?: string }
function scopeTexts(): ScopeItem[] {
  return ["deixis", "dev", "holdout1", "holdout2"].flatMap((name) => readFileSync(join(import.meta.dirname, "fixtures", "context-scope", `${name}.jsonl`), "utf8")
    .split("\n").filter((line) => line.trim()).map((line) => JSON.parse(line) as ScopeItem));
}

/** Every instant corpus text in the repo: the mapping corpus and negatives, the voice gold (said and gold), the context-scope sets, this corpus. */
function everyText(): { text: string; lang: string; src: string }[] {
  const out = mappingTexts();
  for (const item of loadCorpus()) {
    out.push({ text: item.say, lang: item.lang, src: `voice-${item.cat}` });
    if (item.gold !== item.say) out.push({ text: item.gold, lang: item.lang, src: `voice-${item.cat}` });
  }
  for (const item of scopeTexts()) out.push({ text: item.text, lang: item.lang ?? "en", src: "scope" });
  for (const item of corpus.items) out.push({ text: item.text, lang: item.lang, src: `continuity-${item.class}` });
  return out.filter((item) => item.text.trim() && item.text.length <= INSTANT_LIMITS.maxHypothesisChars);
}

test("golden equivalence: without fill, or without a target, every corpus take decides byte-identically; with a search field only misses change", async (t) => {
  const { dispatcher } = createEvalLane();
  const texts = everyText();
  assert.ok(texts.length >= 4_400, `${texts.length} texts`);
  const search: InstantTarget = { app: "browser", field: fieldOf("search") };
  let changed = 0, filled = 0, offered = 0, web = 0;
  const changes: Record<string, number> = {};
  for (const { text, lang, src } of texts) {
    const today = await dispatcher.dispatch(final(text, lang, TODAY));
    const before = stable(today);
    assert.equal(stable(await dispatcher.dispatch(final(text, lang, TODAY, search))), before, `${src}: a target without fill changed ${JSON.stringify(text)}`);
    assert.equal(stable(await dispatcher.dispatch(final(text, lang, ALL))), before, `${src}: fill without a target changed ${JSON.stringify(text)}`);
    const response = await dispatcher.dispatch(final(text, lang, ALL, search));
    if (stable(response) === before) continue;
    changed++;
    changes[src.replace(/-\w+$/, "")] = (changes[src.replace(/-\w+$/, "")] ?? 0) + 1;
    // Only today's misses (a fallthrough no_match / check card, or a name said alone's "Did you mean …?") may change,
    // and only into a fill or the check card's fill offer; the explicit and search forms are deliberate changes, and
    // "frag pi …" skips "Did I hear that right?" (it goes to pi).
    const miss = (today.decision === "fallthrough" && (today.reason === "no_match" || today.reason === "low_confidence"))
      || (today.decision === "list" && today.voice?.didYouMean === true);
    const form = explicitRemainder(text) !== null || searchQuery(text) !== null;
    assert.ok(miss || form, `${src}: a command changed: ${JSON.stringify(text)} ${before} → ${stable(response)}`);
    const toPi = hasPiPrefix(text) && response.decision === "fallthrough" && response.reason === "no_match" && !response.voice?.check;
    assert.ok(isFill(response) || isOffer(response) || toPi || (form && (isWeb(response) || response.decision === "refuse")),
      `${src}: ${JSON.stringify(text)} changed into ${stable(response)}`);
    if (isFill(response)) filled++;
    if (isOffer(response)) offered++;
    if (isWeb(response)) web++;
  }
  t.diagnostic(`${texts.length} corpus texts: ${changed} changed with a search field (${filled} fills, ${offered} offers, ${web} web searches) by source ${JSON.stringify(changes)}`);
});

test("never typed: deletion, deictic and window-band takes get no fill and no offer in any field kind", async (t) => {
  const { dispatcher } = createEvalLane();
  const sets: Record<string, { text: string; lang: string }[]> = { deletion: [], deictic: [], window: [] };
  const seen = new Set<string>();
  for (const item of everyText()) {
    if (seen.has(item.text)) continue;
    seen.add(item.text);
    const n = normalize(item.text, localeOf(item.lang));
    const parsed = parseInstant(n, { now: new Date(2026, 9, 8), locale: localeOf(item.lang), webSearchTemplate: "https://duckduckgo.com/?q=%s" }, { voice: true });
    if (mentionsDeletion(n) || parsed?.kind === "refuse" || parsed?.kind === "delete_target") sets.deletion!.push(item);
    if (parsed?.kind === "fallthrough" && parsed.reason === "deictic") sets.deictic!.push(item);
    if (contextScope(item.text).window >= 0.7) sets.window!.push(item);
  }
  for (const item of scopeTexts()) if (item.cat === "deixis") sets.deictic!.push({ text: item.text, lang: item.lang ?? "en" });
  assert.ok(sets.deletion!.length >= 30 && sets.deictic!.length >= 60 && sets.window!.length >= 150, JSON.stringify(Object.fromEntries(Object.entries(sets).map(([k, v]) => [k, v.length]))));
  let checked = 0;
  for (const [name, items] of Object.entries(sets)) {
    for (const item of items) {
      // An explicit "tippe …" is the user's own words (held for one Return when they hold deletion words): not part of these sets.
      if (explicitRemainder(item.text) !== null) continue;
      for (const kind of ["search", "address", "text", "multiline", "terminal"] as const) {
        const response = await dispatcher.dispatch(final(item.text, item.lang, ALL, { app: kind === "terminal" ? "terminal" : "browser", field: fieldOf(kind) }));
        assert.ok(!isFill(response) && !isOffer(response), `${name}: ${JSON.stringify(item.text)} → ${kind}: ${stable(response)}`);
        checked++;
      }
    }
  }
  t.diagnostic(`deletion ${sets.deletion!.length}, deictic ${sets.deictic!.length}, window band ${sets.window!.length} takes: ${checked} dispatches, 0 fills, 0 offers`);
});

// As voiceCorpus.test.ts: PI_OS_PERF_SLACK (e.g. 3) widens the latency bound on slower or loaded machines.
const slack = Number(process.env.PI_OS_PERF_SLACK ?? "1") || 1;

test("a voice final with 6 hypotheses and a focused field dispatches in p95 < 5 ms", async (t) => {
  const takes = groupTakes(readBench(["parakeet-v3.clean.jsonl", "apple-dt-dual.clean.jsonl", "whisper-turbo-prompt.clean.jsonl", "apple-st-en.clean.jsonl"]
    .map((name) => join(VOICE_FIXTURES, "bench", name))).lines);
  const requests: InstantRequest[] = [];
  const kinds: readonly InstantFieldKind[] = ["search", "address", "text", "multiline", "terminal", "credential"];
  for (const take of takes) {
    const texts: { text: string; source: string }[] = [];
    for (const source of ["parakeet-v3", "apple-dt/en-US", "apple-dt/de-DE", "whisper-turbo", "apple-st/en-US"]) {
      const line = take.lines.find((candidate) => candidate.source === source);
      if (line?.text.trim()) texts.push({ text: line.text, source: line.source });
      for (const alternative of line?.nbest ?? []) texts.push({ text: alternative, source: line!.source });
    }
    if (texts.length < 6) continue;
    const hypotheses: VoiceHypothesis[] = texts.slice(0, 6).map((h, i) => ({ text: h.text.slice(0, INSTANT_LIMITS.maxHypothesisChars), source: h.source, role: i === 0 ? "primary" : "secondary" }));
    const kind = kinds[requests.length % kinds.length]!;
    requests.push({
      text: hypotheses[0]!.text, phase: "final", seq: requests.length + 1, locale: "en-US", inputMode: "voice", hypotheses, accept: ALL,
      target: { app: kind === "terminal" ? "terminal" : "browser", field: fieldOf(kind) },
    });
  }
  assert.ok(requests.length >= 150, `${requests.length} six-hypothesis takes`);
  const { dispatcher } = createEvalLane();
  await dispatcher.warm();
  for (const request of requests.slice(0, 40)) await dispatcher.dispatch(request);
  const times: number[] = [];
  let fills = 0;
  for (const request of requests) {
    const started = performance.now();
    const response = await dispatcher.dispatch({ ...request, seq: request.seq + 1_000 });
    times.push(performance.now() - started);
    if (isFill(response)) fills++;
  }
  times.sort((a, b) => a - b);
  const p50 = times[Math.floor(times.length * 0.5)]!;
  const p95 = times[Math.floor(times.length * 0.95)]!;
  t.diagnostic(`${times.length} takes with 6 hypotheses and a focused field (${fills} fills): p50 ${p50.toFixed(2)} ms, p95 ${p95.toFixed(2)} ms, max ${times.at(-1)!.toFixed(2)} ms`);
  assert.ok(p95 < 5 * slack, `p95 ${p95.toFixed(2)} ms`);
});
