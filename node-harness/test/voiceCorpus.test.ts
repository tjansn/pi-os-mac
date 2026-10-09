import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { INSTANT_LIMITS, type InstantAccept, type InstantRequest, type VoiceHypothesis } from "../src/contracts/instant.js";
import { DictionaryStore } from "../src/instant/dictionary.js";
import {
  appRows, buildAttempt, createEvalLane, crossTakeLearning, fixtureApps, groupTakes, isInstantItem, labelGold, loadCorpus, main,
  parseBenchLine, readBench, scoreStack, signatureOf, spokenTable, TOM_MIX, VOICE_FIXTURES, wholeTakeAlternatives,
  type BenchLine, type CorpusItem, type LearningScore, type StackScore, type Take,
} from "../scripts/voice-eval.mjs";

/*
 * Voice corpus replay (DESIGN4 §9.1; H1): recognizer outputs of 288 synthetic `say` utterances (r3/asr: Apple
 * SpeechTranscriber, Apple DictationTranscriber en-US + de-DE, Parakeet TDT v3, Whisper turbo; clean, tail, room
 * and ptt2 audio) replayed through the REAL instant dispatcher with the 104-app fixture index, plus the r3/mapping
 * phrasing corpus (3,380 + 665 negatives). The gates sit a little below the measured values so regressions fail
 * (the design targets are in the table of DESIGN4 §9.1). Text fixtures only (transcripts of synthetic TTS, no user
 * content); no host, no model, no network, nothing logged. Provenance: test/fixtures/voice/README.md.
 */

/**
 * The decision kinds these replays declare: an explicit list, never `INSTANT_ACCEPTS` as a whole, so a kind added to
 * the contract (continuity's `fill`) never changes what the corpus measures. The replays carry no `target` either.
 */
const ACCEPT: InstantAccept[] = ["suggest", "check", "confirm"];
const corpus = loadCorpus();
const bench = (...names: string[]): Take[] => {
  const run = readBench(names.map((name) => join(VOICE_FIXTURES, "bench", name)));
  assert.deepEqual([run.rejected, run.duplicates], [{}, 0], names.join(" + "));
  return groupTakes(run.lines);
};
const fmt = (value: number): string => value.toFixed(1);
const summary = (s: StackScore): string => `${s.stack} ${s.variant}: Tom-mix at once ${fmt(s.tomMixAtOnce)} %, with one Return ${fmt(s.tomMixWithReturn)} %, `
  + `A at once ${fmt(100 * (s.categories.A?.atOnce ?? 0) / (s.categories.A?.instant || 1))} %, wrong at once ${s.wrongAtOnce}, wrong behind a Return ${s.wrongBehindConfirm}, `
  + `agent items acted ${s.hijacked} / held ${s.nagged} of ${s.agentItems}`;
/** Ids and categories of an outcome class (content-free failure detail). */
const ids = (s: StackScore, pick: (o: StackScore["outcomes"][number]) => boolean): string =>
  s.outcomes.filter(pick).map((o) => `${o.id}[${o.cat}]`).join(" ") || "none";

// ---------------------------------------------------------------- fixtures

test("voice fixtures: 288 gold items, 210 instant-able, every bench file complete and schema-valid, ≤ 6 MB", () => {
  assert.equal(corpus.length, 288);
  const count = (pick: (item: CorpusItem) => boolean) => Object.fromEntries(["A", "B", "C", "D", "E", "F", "G", "H", "I"].map((cat) => [cat, corpus.filter((item) => item.cat === cat && pick(item)).length]));
  assert.deepEqual(count(() => true), { A: 44, B: 32, C: 32, D: 28, E: 30, F: 32, G: 30, H: 32, I: 28 });
  // r3/design4 stack.md: instant-able items 210/288 (A 32, F 23, G 21, H 23, I 22).
  assert.equal(corpus.filter(isInstantItem).length, 210);
  assert.deepEqual(TOM_MIX.map((cat) => count(isInstantItem)[cat]), [23, 21, 23, 22]);
  assert.equal(count(isInstantItem).A, 32);

  const dir = join(VOICE_FIXTURES, "bench");
  const files = readdirSync(dir).filter((name) => name.endsWith(".jsonl")).sort();
  assert.equal(files.length, 18);
  const sources = new Set<string>();
  for (const name of files) {
    const run = readBench([join(dir, name)]);
    assert.deepEqual([run.rejected, run.duplicates], [{}, 0], name);
    const variant = name.split(".").at(-2)!;
    for (const line of run.lines) {
      sources.add(line.source);
      assert.equal(line.variant, variant, name);
      assert.ok(line.text.length <= INSTANT_LIMITS.maxText && !/[\n\r]/.test(line.text), name);
    }
    // Every corpus id, once per recognizer in the file.
    const perSource = new Map<string, Set<string>>();
    for (const line of run.lines) (perSource.get(line.source) ?? perSource.set(line.source, new Set()).get(line.source)!).add(line.id);
    for (const [source, seen] of perSource) assert.equal(seen.size, 288, `${name} ${source}`);
  }
  assert.deepEqual([...sources].sort(), ["apple-dt/de-DE", "apple-dt/en-US", "apple-st/en-US", "parakeet-v3", "whisper-turbo"]);

  let bytes = 0;
  const walk = (path: string): void => {
    for (const entry of readdirSync(path)) {
      const full = join(path, entry);
      const stat = statSync(full);
      if (stat.isDirectory()) walk(full);
      else bytes += stat.size;
    }
  };
  walk(VOICE_FIXTURES);
  assert.ok(bytes <= 6 * 1024 * 1024, `${bytes} bytes`);
  const readme = readFileSync(join(VOICE_FIXTURES, "README.md"), "utf8");
  for (const needle of ["r3/asr", "say", "Provenance", "import-r3", "relabel", "No user content"]) assert.ok(readme.includes(needle), needle);
  // The 104-app index is instantSpoken.test.ts's (no personal app names, nothing under a home directory).
  const apps = fixtureApps();
  assert.equal(apps.length, 104);
  assert.ok(apps.every((app) => !app.path.startsWith("/Users/")));
});

test("gold labels: the real lane still decides every gold text as labeled (else relabel deliberately)", async () => {
  const relabeled = await labelGold(corpus);
  const changed = relabeled.filter((item, index) => item.expect !== corpus[index]!.expect).map((item) => item.id);
  assert.deepEqual(changed, [], "a mapping change moved these gold labels; if intended, run `npx tsx scripts/voice-eval.mts relabel`");
});

// ---------------------------------------------------------------- the r3/mapping phrasing corpus through the real dispatcher

type Expect =
  | { kind: "open_app"; bundleId: string }
  | { kind: "url"; host: string }
  | { kind: "web" | "file_search" | "calc" | "refuse" }
  | { kind: "system"; op: string }
  | { kind: "agent"; okApp?: string };
interface Item { text: string; lang: string; src: string; expect: Expect }

/** r3/mapping build.py → corpus.json (3,380), from instantSpoken.test.ts's seeded tables (same order and counts). */
function mappingCorpus(): Item[] {
  const t = <T>(name: string) => spokenTable<T>(name);
  const items: Item[] = [];
  const add = (text: string, lang: string, src: string, expect: Expect): void => void items.push({ text, lang, src, expect });
  const enT = t<readonly string[]>("EN_T");
  const deT = t<readonly string[]>("DE_T");
  const mixT = t<readonly string[]>("MIX_T");
  for (const [name, bundleId, deNames, dePicks, namePicks, mixPicks] of t<readonly (readonly [string, string, readonly string[], readonly number[], readonly (readonly number[])[], readonly number[]])[]>("CORPUS_APPS")) {
    const open: Expect = { kind: "open_app", bundleId };
    for (const template of enT) add(template.replaceAll("{a}", name), "en", "wrapper-en", open);
    for (const i of dePicks) add(deT[i]!.replaceAll("{a}", name), "de", "wrapper-de", open);
    deNames.forEach((deName, k) => {
      for (const i of namePicks[k]!) add(deT[i]!.replaceAll("{a}", deName), "de", "wrapper-de-name", open);
    });
    for (const i of mixPicks) add(mixT[i]!.replaceAll("{a}", name), "mix", "wrapper-mix", open);
  }
  const frames = t<readonly string[]>("FRAMES");
  for (const [bundleId, [near, far]] of Object.entries(t<Readonly<Record<string, readonly [readonly string[], readonly string[]]>>>("ASR"))) {
    const frame = (i: number, x: string): [string, string] => [frames[i % frames.length]!.replace("{x}", x), frames[i % frames.length]!.startsWith("Öffne") ? "de" : "en"];
    near.forEach((x, i) => add(...frame(i, x), "asr-near", { kind: "open_app", bundleId }));
    far.forEach((x, i) => add(...frame(i + 2, x), "asr-far", { kind: "open_app", bundleId }));
  }
  for (const [text, lang, expect] of t<readonly (readonly [string, string, Expect])[]>("OTHER")) add(text, lang, "other", expect);
  const okApps = t<Readonly<Record<string, string>>>("NEG_OK_APPS");
  for (const [text, lang] of t<readonly (readonly [string, string])[]>("NEG")) add(text, lang, "negative", okApps[text] ? { kind: "agent", okApp: okApps[text] } : { kind: "agent" });
  for (const [text, lang] of t<readonly (readonly [string, string])[]>("REFUSE")) add(text, lang, "refuse", { kind: "refuse" });
  return items;
}

/** r3/mapping build_neg.py → negatives.json (665). */
function mappingNegatives(): Item[] {
  const t = <T>(name: string) => spokenTable<T>(name);
  const items: Item[] = [];
  const suffix = t<Readonly<Record<string, string>>>("NEG_SUFFIX_OK");
  const add = (text: string, lang: string, src: string, okApp?: string): void => {
    const ok = okApp ?? Object.entries(suffix).find(([k]) => text === k || text.endsWith(` ${k}.`))?.[1];
    items.push({ text, lang, src: `neg-${src}`, expect: ok ? { kind: "agent", okApp: ok } : { kind: "agent" } });
  };
  const enNouns = t<readonly string[]>("NEG_EN_NOUNS");
  const enPicks = t<readonly (readonly number[])[]>("NEG_EN_PICKS");
  t<readonly string[]>("NEG_EN_VERBS").forEach((verb, v) => enPicks[v]!.forEach((i) => add(`${verb} ${enNouns[i]}.`, "en", "open-noun")));
  const deNouns = t<readonly string[]>("NEG_DE_NOUNS");
  const dePicks = t<readonly (readonly number[])[]>("NEG_DE_PICKS");
  t<readonly string[]>("NEG_DE_VERBS").forEach((verb, v) => dePicks[v]!.forEach((i) => {
    const noun = deNouns[i]!;
    add(verb === "Kannst du öffnen" ? `Kannst du ${noun} öffnen?` : verb === "Mach" ? `Mach ${noun} auf.` : `${verb} ${noun}.`, "de", "open-noun");
  }));
  const deStart = t<ReadonlySet<string>>("DE_QUESTION_START");
  for (const q of t<readonly string[]>("NEG_QUESTIONS")) add(q, /[äöüß]/.test(q) || deStart.has(q.split(" ")[0]!) ? "de" : "en", "question");
  const deWords = t<ReadonlySet<string>>("DE_WORDS");
  for (const w of t<readonly string[]>("NEG_WORDS")) add(w, deWords.has(w) ? "de" : "en", "word");
  for (const [text, app] of t<readonly (readonly [string, string])[]>("NEG_APP_NOUNS")) add(text, text.includes("Zeig") ? "de" : "en", "appnoun", app);
  return items;
}

test("mapping corpus through the real dispatcher: ≥ 93 % open-app acts, 0 false acts on the 665 negatives", async (t) => {
  const items = mappingCorpus();
  const negatives = mappingNegatives();
  const count = (list: Item[], src: string) => list.filter((item) => item.src === src).length;
  assert.deepEqual(
    ["wrapper-en", "wrapper-de", "wrapper-de-name", "wrapper-mix", "asr-near", "asr-far", "other", "negative", "refuse"].map((src) => count(items, src)),
    [2240, 560, 84, 80, 126, 126, 47, 109, 8],
  );
  assert.deepEqual(["neg-open-noun", "neg-question", "neg-word", "neg-appnoun"].map((src) => count(negatives, src)), [536, 68, 48, 13]);

  // Each phrasing is one take's primary final (a new host: hypotheses + accept), on the 104-app index.
  const { dispatcher } = createEvalLane();
  let seq = 0;
  const decide = (item: Item) => {
    const locale = item.lang === "de" ? "de-DE" : "en-US";
    const hypothesis: VoiceHypothesis = { text: item.text, source: "parakeet-v3", role: "primary" };
    const request: InstantRequest = { text: item.text, phase: "final", seq: ++seq, locale, inputMode: "voice", hypotheses: [hypothesis], accept: ACCEPT };
    return dispatcher.dispatch(request);
  };
  let positives = 0, acts = 0, offered = 0, wrongApps = 0, other = 0, otherOk = 0, refusals = 0, refused = 0;
  const misses: string[] = [];
  for (const item of items) {
    const response = await decide(item);
    const sig = signatureOf(response);
    const atOnce = response.decision === "act" && !response.confirm;
    const e = item.expect;
    if (e.kind === "open_app") {
      positives++;
      if (atOnce && sig === `app:${e.bundleId}`) acts++;
      else if (atOnce && sig.startsWith("app:")) wrongApps++;
      else misses.push(item.src);
      if ((atOnce && sig === `app:${e.bundleId}`) || appRows(response).slice(0, 3).includes(e.bundleId)) offered++;
    } else if (e.kind === "refuse") {
      refusals++;
      if (response.decision === "refuse") refused++;
    } else if (e.kind !== "agent") {
      other++;
      const ok = e.kind === "url" ? sig === `url:${e.host}`
        : e.kind === "system" ? sig === `sys:${e.op}`
        : e.kind === "web" ? response.decision === "act" && response.intent === "web"
        : e.kind === "file_search" ? sig === "files"
        : response.decision === "answer" && ["calc", "unit"].includes(response.intent);
      if (ok) otherOk++;
    }
  }
  let falseActs = 0, heldActs = 0, offersOnNegatives = 0;
  const falseSrc: string[] = [];
  for (const item of [...items.filter((i) => i.expect.kind === "agent"), ...negatives]) {
    const response = await decide(item);
    const okApp = item.expect.kind === "agent" ? item.expect.okApp : undefined;
    const sig = signatureOf(response);
    const acted = response.decision === "act" && !(okApp && sig === `app:${okApp}`);
    if (acted && !response.confirm) {
      falseActs++;
      falseSrc.push(item.src);
    }
    if (acted && response.confirm) heldActs++;
    if (appRows(response).length) offersOnNegatives++;
  }
  const missBySrc = Object.entries(misses.reduce<Record<string, number>>((acc, src) => ({ ...acc, [src]: (acc[src] ?? 0) + 1 }), {}));
  t.diagnostic(`open-app acts ${acts}/${positives} (${fmt((100 * acts) / positives)} %), act or offered ${fmt((100 * offered) / positives)} %, wrong apps ${wrongApps}, `
    + `false acts ${falseActs} (held for a Return ${heldActs}, offers ${offersOnNegatives}) on ${109 + negatives.length} agent-bound phrasings, other intents ${otherOk}/${other}, refused ${refused}/${refusals}; misses by source ${JSON.stringify(missBySrc)}`);
  // DESIGN4 §9.1: mapping corpus act ≥ 93 %, negatives false acts = 0.
  assert.ok(acts / positives >= 0.93, `open-app acts ${fmt((100 * acts) / positives)} %`);
  assert.ok(offered / positives >= 0.98, `act or offered ${fmt((100 * offered) / positives)} %`);
  assert.equal(wrongApps, 0);
  assert.equal(falseActs, 0, `false acts by source: ${falseSrc.join(", ")}`);
  assert.equal(otherOk, other);
  assert.equal(refused, refusals);
});

// ---------------------------------------------------------------- recognizer stacks (r3/design4 stack.mts, stack2.mts)

test("Phase A (Apple DictationTranscriber en-US + de-DE peers + n-best): Tom-mix ≥ 64 % at once, ≤ 2 wrong at once", async (t) => {
  const takes = bench("apple-dt-dual.clean.jsonl", "apple-st-en.clean.jsonl");
  const today = await scoreStack(corpus, takes, "legacy:apple-st/en-US", "clean");
  const phaseA = await scoreStack(corpus, takes, "phaseA", "clean");
  t.diagnostic(`today (SpeechTranscriber en-US, text only): ${summary(today)}`);
  t.diagnostic(`Phase A: ${summary(phaseA)}; wrong at once: ${ids(phaseA, (o) => o.wrongAtOnce)}`);
  // DESIGN4 §9.1 (M3: 67 % at once, 2 wrong at once with τ = 0.4).
  assert.ok(phaseA.tomMixAtOnce >= 64, `Phase A Tom-mix at once ${fmt(phaseA.tomMixAtOnce)} %`);
  assert.ok(phaseA.wrongAtOnce <= 2, `Phase A wrong at once ${phaseA.wrongAtOnce}: ${ids(phaseA, (o) => o.wrongAtOnce)}`);
  assert.ok(phaseA.tomMixAtOnce > today.tomMixAtOnce + 30, "Phase A is far ahead of today's single-locale SpeechTranscriber");
  assert.equal(phaseA.empty, 0);
});

test("Phase B (Parakeet primary + Apple secondaries, two-step final): Tom-mix ≥ 80 % at once, ≥ 86 % with one Return, ≤ 2 wrong at once", async (t) => {
  const takes = bench("parakeet-v3.clean.jsonl", "apple-dt-dual.clean.jsonl");
  const phaseB = await scoreStack(corpus, takes, "phaseB", "clean");
  const parakeet = await scoreStack(corpus, takes, "single:parakeet-v3", "clean");
  t.diagnostic(`Parakeet alone: ${summary(parakeet)}`);
  t.diagnostic(`Phase B: ${summary(phaseB)}; wrong at once: ${ids(phaseB, (o) => o.wrongAtOnce)}; wrong behind a Return: ${ids(phaseB, (o) => o.wrongBehindConfirm)}`);
  // DESIGN4 §9.1 (M3: 83 % at once, 89 % with one Return, 2 wrong at once).
  assert.ok(phaseB.tomMixAtOnce >= 80, `Phase B Tom-mix at once ${fmt(phaseB.tomMixAtOnce)} %`);
  assert.ok(phaseB.tomMixWithReturn >= 86, `Phase B Tom-mix with one Return ${fmt(phaseB.tomMixWithReturn)} %`);
  assert.ok(phaseB.wrongAtOnce <= 2, `Phase B wrong at once ${phaseB.wrongAtOnce}: ${ids(phaseB, (o) => o.wrongAtOnce)}`);
  // The secondaries never make Parakeet worse.
  assert.ok(phaseB.tomMixAtOnce >= parakeet.tomMixAtOnce);
});

// ---------------------------------------------------------------- learning (r3/design4 repeat.mts, with the real store and learn lane)

test("cross-take learning clean → ptt2: one correction never causes a wrong act and gains ≥ 5 points per new-stack engine", async (t) => {
  const takes = bench(
    "parakeet-v3.clean.jsonl", "parakeet-v3.ptt2.jsonl", "apple-dt.clean.jsonl", "apple-dt.ptt2.jsonl",
    "apple-st-en.clean.jsonl", "apple-st-en.ptt2.jsonl", "whisper-turbo.clean.jsonl", "whisper-turbo.ptt2.jsonl",
  );
  const rows: LearningScore[] = [];
  for (const source of ["parakeet-v3", "apple-dt/en-US", "apple-dt/de-DE", "apple-st/en-US", "whisper-turbo"]) {
    const row = await crossTakeLearning(corpus, takes, source, "clean", "ptt2");
    rows.push(row);
    t.diagnostic(`${source}: ${row.takes} open-app takes, ${row.corrections} corrections → ${row.rules} rules ${JSON.stringify(row.learnOutcomes)}; `
      + `at once ${row.before} → ${row.after} (${row.gainPoints >= 0 ? "+" : ""}${fmt(row.gainPoints)} points); over all ${row.checked} ptt2 items: `
      + `learning-caused wrong acts ${row.learningCausedWrong}, wrong ${row.wrongBefore} → ${row.wrongAfter}`);
  }
  // DESIGN4 §9.1: learning-caused wrong acts = 0 (every engine, the alias guard of §6.5), counted over every ptt2
  // item, so a learned rule that hijacks an agent-bound request or another instant item fails too …
  for (const row of rows) {
    assert.equal(row.checked, 288, row.source);
    assert.equal(row.learningCausedWrong, 0, `${row.source}: ${row.causedIds.join(" ")}`);
  }
  // … and a gain of ≥ +5 points on the engines of the new stack (Phase A peers, the Phase B primary). Today's
  // SpeechTranscriber (+3.8 measured; +5 in M4 on r3's prototype) and Whisper (not adopted, D-T3) are reported only.
  for (const row of rows.filter((r) => ["parakeet-v3", "apple-dt/en-US", "apple-dt/de-DE"].includes(r.source))) {
    assert.ok(row.gainPoints >= 5, `${row.source}: +${fmt(row.gainPoints)} points`);
    assert.ok(row.rules > 0 && row.after > row.before, row.source);
  }
});

// ---------------------------------------------------------------- latency

// As instantPerf.test.ts: PI_OS_PERF_SLACK (e.g. 3) widens the latency bound on slower or loaded machines.
const slack = Number(process.env.PI_OS_PERF_SLACK ?? "1") || 1;

test("a voice final with 6 hypotheses dispatches in p95 < 5 ms", async (t) => {
  const takes = bench("parakeet-v3.clean.jsonl", "apple-dt-dual.clean.jsonl", "whisper-turbo-prompt.clean.jsonl", "apple-st-en.clean.jsonl");
  const requests: InstantRequest[] = [];
  for (const take of takes) {
    const by = (source: string) => take.lines.find((line) => line.source === source);
    const texts: { text: string; source: string }[] = [];
    for (const line of [by("parakeet-v3"), by("apple-dt/en-US"), by("apple-dt/de-DE"), by("whisper-turbo"), by("apple-st/en-US")]) {
      if (line?.text.trim()) texts.push({ text: line.text, source: line.source });
      for (const alternative of line?.nbest ?? []) texts.push({ text: alternative, source: line!.source });
    }
    if (texts.length < 6) continue;
    const hypotheses: VoiceHypothesis[] = texts.slice(0, 6).map((h, i) => ({ text: h.text.slice(0, INSTANT_LIMITS.maxHypothesisChars), source: h.source, role: i === 0 ? "primary" : "secondary" }));
    requests.push({ text: hypotheses[0]!.text, phase: "final", seq: requests.length + 1, locale: "en-US", inputMode: "voice", hypotheses, accept: ACCEPT });
  }
  assert.ok(requests.length >= 150, `${requests.length} six-hypothesis takes`);
  const { dispatcher } = createEvalLane();
  await dispatcher.warm();
  for (const request of requests.slice(0, 40)) await dispatcher.dispatch(request);
  const times: number[] = [];
  for (const request of requests) {
    const started = performance.now();
    await dispatcher.dispatch({ ...request, seq: request.seq + 1_000 });
    times.push(performance.now() - started);
  }
  times.sort((a, b) => a - b);
  const p50 = times[Math.floor(times.length * 0.5)]!;
  const p95 = times[Math.floor(times.length * 0.95)]!;
  t.diagnostic(`${times.length} takes with 6 hypotheses: p50 ${p50.toFixed(2)} ms, p95 ${p95.toFixed(2)} ms, max ${times.at(-1)!.toFixed(2)} ms`);
  assert.ok(p95 < 5 * slack, `p95 ${p95.toFixed(2)} ms`);
});

// ---------------------------------------------------------------- voice-eval.mts itself

test("voice-eval: bench schema, S1's whole-take n-best, Phase B two-step finals, content-free output", async () => {
  // Schema: content-free rejection reasons; roles, ranges, n-best ≤ 2.
  const ok = { id: "A001", variant: "clean", source: "parakeet-v3", role: "primary", text: "Open Pages." };
  assert.deepEqual(parseBenchLine(ok), ok);
  assert.deepEqual(parseBenchLine({ ...ok, text: "", confidence: 0.5, finalMs: 35.5, locale: "de-DE", nbest: ["a", " "] }), { ...ok, text: "", confidence: 0.5, finalMs: 35.5, locale: "de-DE", nbest: ["a"] });
  for (const [bad, reason] of [
    [{ ...ok, id: "../x" }, "id"], [{ ...ok, source: "Parakeet V3" }, "source"], [{ ...ok, role: "first" }, "role"], [{ ...ok, confidence: 1.5 }, "confidence"],
    [{ ...ok, nbest: ["a", "b", "c"] }, "nbest"], [{ ...ok, finalMs: -1 }, "finalMs"], [{ ...ok, locale: "german" }, "locale"], [{ ...ok, text: 3 }, "text"],
  ] as const) assert.equal(parseBenchLine(bad), reason);

  // DictationTranscriber re-finalizes ranges: the take's segments are the suffix that spells the transcript;
  // one segment swaps to its alternatives (own text and case variants excluded), ≤ 2.
  assert.deepEqual(wholeTakeAlternatives("Open Numbers", [["Open "], ["Numbers", "numbers"], [" Open "], ["Numbers", "numbers"]]), []);
  assert.deepEqual(wholeTakeAlternatives("Open Notion", [["Open Notion"], [" Open Notion", " Open Motion", " Open Nation", " Opened Notion"]]), ["Open Motion", "Open Nation"]);
  assert.deepEqual(wholeTakeAlternatives("Call mommy daughter until Christmas", [["Call "], ["mommy daughter", "mom daughter"], [" Call "], ["mommy daughter until ", "mommy until "], ["Christmas"]]), ["Call mommy until Christmas"]);
  assert.deepEqual(wholeTakeAlternatives("unrelated", [["Open "]]), []);

  // Phase B: Parakeet alone first, then every hypothesis; Phase A: Apple peers, then their n-best.
  const take: Take = { id: "X1", variant: "clean", lines: [
    { id: "X1", variant: "clean", source: "apple-dt/de-DE", role: "peer", text: "Öffne Pages.", confidence: 0.8, locale: "de-DE" },
    { id: "X1", variant: "clean", source: "apple-dt/en-US", role: "peer", text: "Of the pages.", confidence: 0.4, locale: "en-US", nbest: ["Open pages."] },
    { id: "X1", variant: "clean", source: "parakeet-v3", role: "primary", text: "Öffne Pages.", locale: "de-DE" },
  ] satisfies BenchLine[] };
  const b = buildAttempt(take, "phaseB")!;
  assert.deepEqual(b.finals.map((f) => f.hypotheses!.map((h) => `${h.role}:${h.source}`)), [
    ["primary:parakeet-v3"],
    ["primary:parakeet-v3", "secondary:apple-dt/de-DE", "secondary:apple-dt/en-US", "secondary:apple-dt/en-US"],
  ]);
  assert.equal(b.locale, "de-DE");
  const a = buildAttempt(take, "phaseA")!;
  assert.deepEqual(a.finals.map((f) => [f.text, f.hypotheses!.map((h) => `${h.role}:${h.source}`)]), [
    ["Öffne Pages.", ["peer:apple-dt/de-DE", "peer:apple-dt/en-US", "secondary:apple-dt/en-US"]],
  ]);
  assert.equal(buildAttempt({ ...take, lines: take.lines.map((line) => ({ ...line, text: " " })) }, "phaseA"), null);
  assert.deepEqual(buildAttempt(take, "legacy:apple-dt/en-US"), { locale: "en-US", finals: [{ text: "Of the pages." }] });

  // The CLI prints counts and percentages only: no transcript, gold text or app choice without --show-content.
  const out: string[] = [];
  const files = ["parakeet-v3.clean.jsonl", "apple-dt-dual.clean.jsonl"].map((name) => join(VOICE_FIXTURES, "bench", name));
  assert.equal(await main(["--stack", "phaseA,phaseB", "--details", ...files], (line) => out.push(line)), 0);
  const printed = out.join("\n");
  assert.match(printed, /\| phaseB \| clean \|/);
  const texts = new Set<string>();
  for (const item of corpus) for (const text of [item.gold, item.say]) if (text.length >= 8) texts.add(text);
  for (const line of readBench(files).lines) if (line.text.trim().length >= 8) texts.add(line.text.trim());
  for (const text of texts) assert.ok(!printed.includes(text), "a transcript reached the output");
  assert.ok(!/com\.|bundle|app:/.test(printed), "an app choice reached the output");

  // The learning safety count sees agent-bound items too: a rule that hijacks "Schreib eine Mail an Thomas"
  // (agent-bound C028/H028; Parakeet hears "Schreibt eine Mail an Thomas." on ptt2) is learning-caused.
  const dir = mkdtempSync(join(tmpdir(), "pi-os-voice-corpus-"));
  try {
    const store = new DictionaryStore({ path: join(dir, "dictionary.json"), log: () => {} });
    store.load();
    assert.ok(store.bind({ list: "aliases", phrase: "schreibt eine mail an thomas", target: { kind: "openApp", bundleId: "com.apple.mail" } }, { recognizer: "parakeet-v3", source: "manual" }).ok);
    store.flush();
    const row = await crossTakeLearning(corpus, bench("parakeet-v3.clean.jsonl", "parakeet-v3.ptt2.jsonl"), "parakeet-v3", "clean", "ptt2", { dir });
    assert.deepEqual([row.checked, row.causedIds], [288, ["C028", "H028"]]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
