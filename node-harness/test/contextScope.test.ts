import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import {
  MAX_SCOPE_REASONS, parseInstantScope, SCOPE_REASON_PATTERN, SCOPE_THRESHOLDS, scopeBand, type ContextScope,
} from "../src/contracts/context.js";
import { contextScope, followupScope, rulesContextScorer, warmContextScope } from "../src/agent/routing/index.js";
import { boundedUtterance, classifyUtterance, CONTENT_DEIXIS, SCREEN_DEIXIS, screenEvidence } from "../src/agent/routing/heuristics.js";

/*
 * Context scope rules v2 against the labeled sets of r2/classifier.md (single author, synthetic utterances,
 * no user data), copied to test/fixtures/context-scope/:
 *   dev.jsonl      = fixtures.jsonl (190, 10 follow-ups with `prev`): v2 was tuned on it.
 *   holdout1.jsonl = holdout.jsonl (74): contaminated for v2 (its v1 errors were read before v2 was written).
 *   holdout2.jsonl = holdout2.jsonl (82): BLIND, written after v2 was frozen (heuristic_v2.frozen.mjs sha256
 *                    bd5a43c8…). NEVER TUNE RULES ON IT: it is the gate, and its sha256 is pinned below.
 *   deixis.jsonl   = r2/context/deixis.json rows (60; text and label only).
 * Floors are the values measured for this port: identical to the frozen prototype on dev, holdout1 and holdout2;
 * the v2 additions fix two deixis items ("fix the bug", "stimmt das so").
 */

interface Item {
  id: string;
  text: string;
  gold: "window" | "general";
  cat?: string;
  prev?: string;
}

const dir = join(import.meta.dirname, "fixtures", "context-scope");
const raw = (name: string) => readFileSync(join(dir, name), "utf8");
const load = (name: string): Item[] => raw(name).trim().split("\n").map((line) => JSON.parse(line) as Item);
const HOLDOUT2_SHA256 = "3efda484deda2e35e551af6b9cd6d322073511af96c12ca565eaef1810e469fe";

const predict = (text: string): "window" | "general" => (contextScope(text).window >= SCOPE_THRESHOLDS.suggest ? "window" : "general");

function score(items: Item[]) {
  let correct = 0;
  let falseGeneral = 0;
  let falseWindow = 0;
  for (const item of items) {
    const pred = predict(item.text);
    if (pred === item.gold) correct++;
    else if (item.gold === "window") falseGeneral++;
    else falseWindow++;
  }
  return {
    n: items.length, correct, accuracy: correct / items.length, falseGeneral, falseWindow,
    windows: items.filter((item) => item.gold === "window").length,
  };
}

test("blind holdout2 (sha256-pinned, never tuned): accuracy ≥ 0.75 and false-general ≤ 13/42", () => {
  assert.equal(createHash("sha256").update(raw("holdout2.jsonl")).digest("hex"), HOLDOUT2_SHA256, "holdout2 must stay byte-identical");
  const h2 = score(load("holdout2.jsonl"));
  assert.deepEqual([h2.n, h2.windows], [82, 42]);
  assert.ok(h2.accuracy >= 0.75, `accuracy ${h2.accuracy.toFixed(3)}`);
  assert.ok(h2.falseGeneral <= 13, `false-general ${h2.falseGeneral}/42`);
  assert.ok(h2.falseWindow <= 7, `false-window ${h2.falseWindow}/40`);
});

test("dev, holdout1 and the deixis set stay at their measured floors", () => {
  const dev = score(load("dev.jsonl").filter((item) => item.cat !== "followup"));
  assert.equal(dev.n, 180);
  assert.ok(dev.correct >= 167, `dev ${dev.correct}/180 (fg ${dev.falseGeneral}, fw ${dev.falseWindow})`);
  const h1 = score(load("holdout1.jsonl"));
  assert.ok(h1.correct >= 73, `holdout1 ${h1.correct}/74`);
  const deixis = score(load("deixis.jsonl"));
  assert.equal(deixis.n, 60);
  assert.ok(deixis.accuracy >= 0.88, `deixis ${deixis.correct}/60`);
});

test("follow-ups inherit the thread's scope instead of being classified on their own words", () => {
  const followups = load("dev.jsonl").filter((item) => item.cat === "followup");
  assert.equal(followups.length, 10);
  // The label policy gives a follow-up its thread's label; the thread's scope was the first turn's (the host's chip).
  const classified = followups.filter((item) => predict(item.text) === item.gold).length;
  assert.ok(classified < followups.length, "classified alone, follow-ups are a coin flip (r2/classifier.md §2.2)");
  for (const item of followups) {
    const thread: ContextScope = item.gold;
    assert.equal(followupScope(thread, contextScope(item.text)), item.gold, `${item.id}: ${item.text} after ${item.prev}`);
  }
  // Never downgraded; upgraded only by a strong reference to the screen itself.
  assert.equal(followupScope("window", contextScope("what's the capital of france")), "window");
  assert.equal(followupScope("general", contextScope("what does the error on this page say")), "window");
  assert.equal(followupScope("general", contextScope("click the blue submit button")), "window");
  assert.equal(followupScope("general", contextScope("make it shorter")), "general", "'it' is the previous answer");
  assert.equal(followupScope("general", contextScope("stimmt das so?")), "general");
  assert.equal(followupScope("general", contextScope("mach das kürzer")), "general", "'das' is the previous answer");
  assert.equal(followupScope("general", null), "general");
  assert.equal(followupScope("general", { window: 0.9, reasons: [] }), "general", "no screen-anchored reason");
});

test("pronoun and implicit references, bare transforms and the 'gib … ein' false positive", () => {
  const windowBand = ["make it shorter", "fix the bug", "tl;dr", "stimmt das so", "passt das so?", "is what I typed correct",
    "check what I wrote", "what's the price of the second one", "does that look right?", "make the first line bold",
    "format the table", "gib deine Adresse ein", "fass zusammen", "summarize", "mach das kürzer", "mach's bitte etwas kürzer",
    "kannst du es freundlicher formulieren", "gib hallo ein und drück enter"];
  for (const text of windowBand) assert.equal(scopeBand(contextScope(text).window), "window", text);
  for (const text of ["gib mir ein Rezept für Pfannkuchen", "explain the difference between TCP and UDP", "what is the capital of Australia",
    "write a haiku about autumn", "fix this sentence: their going to the park tomorrow", "was ist die Hauptstadt von Frankreich",
    "gib mir ein, zwei Tipps", "wie kann ich mir das Leben einfacher machen", "make a bigger plan for my week"]) {
    assert.equal(scopeBand(contextScope(text).window), "general", text);
  }
  assert.equal(scopeBand(contextScope("what's the deal").window), "uncertain", "short, no noun: neither");
});

test("reason codes explain the score: base evidence, then what lowered or raised it", () => {
  assert.deepEqual(contextScope("summarize this page"), { window: 0.9, reasons: ["deixis-strong"] });
  assert.deepEqual(contextScope("fix this sentence: their going to the park tomorrow"), { window: 0.1, reasons: ["deixis-strong", "deixis-content", "inline-content"] });
  assert.deepEqual(contextScope("play some jazz"), { window: 0.15, reasons: ["act-in-app", "act-not-ui"] });
  assert.deepEqual(contextScope("scroll down"), { window: 0.8, reasons: ["act-in-app"] });
  assert.deepEqual(contextScope("make it shorter"), { window: 0.75, reasons: ["pronoun"] });
  assert.deepEqual(contextScope("summarize the page"), { window: 0.7, reasons: ["definite-noun"] });
  assert.deepEqual(contextScope("tl;dr"), { window: 0.75, reasons: ["bare-transform"] });
  assert.deepEqual(contextScope("what's the deal"), { window: 0.5, reasons: ["short-unclear"] });
  assert.deepEqual(contextScope("what is the capital of australia"), { window: 0.1, reasons: [] });
  // The routing context changes the intent, not the scope of a UI verb.
  assert.equal(contextScope("click the login button", { surface: "browser", browserCdp: true }).window, 0.85);
  assert.deepEqual(rulesContextScorer("summarize this page"), contextScope("summarize this page"));
});

test("contract: every score is a valid InstantScope with content-free reasons; deterministic and fast", () => {
  const texts = ["dev.jsonl", "holdout1.jsonl", "holdout2.jsonl", "deixis.jsonl"].flatMap((name) => load(name).map((item) => item.text));
  texts.push("", "   ", "x".repeat(10_000), "\u0000￿", "Bitte, bitte: 'zitiert'");
  for (const text of texts) {
    const scope = contextScope(text);
    assert.deepEqual(parseInstantScope(scope), scope, text.slice(0, 60));
    assert.ok(scope.window >= 0 && scope.window <= 1);
    assert.ok(scope.reasons.length <= MAX_SCOPE_REASONS);
    assert.ok(scope.reasons.every((reason) => SCOPE_REASON_PATTERN.test(reason)));
    assert.deepEqual(contextScope(text), scope);
  }
  const secret = contextScope("summarize the secret fixture phrase copper robin");
  assert.doesNotMatch(JSON.stringify(secret), /copper|robin|secret/);

  const slack = Number(process.env.PI_OS_PERF_SLACK ?? "1") || 1;
  warmContextScope();
  const again = performance.now();
  warmContextScope();
  assert.ok(performance.now() - again < 1, "the warm-up runs once per process");
  for (let i = 0; i < 2_000; i++) contextScope(texts[i % texts.length]!);
  const samples: number[] = [];
  for (let i = 0; i < 3_000; i++) {
    const started = performance.now();
    contextScope(texts[i % texts.length]!);
    samples.push(performance.now() - started);
  }
  samples.sort((a, b) => a - b);
  const p99 = samples[Math.floor(samples.length * 0.99)]!;
  assert.ok(p99 < 0.5 * slack, `p99 ${p99.toFixed(4)} ms`);
});

test("a general thread is not widened by a definite noun alone (the agent's own output), only by strong screen anchors", () => {
  for (const text of ["make the email more formal", "fix the bug", "translate the text into German"]) {
    assert.equal(followupScope("general", contextScope(text)), "general", text);
  }
  assert.equal(followupScope("general", contextScope("what does this button do on my screen")), "window");
  assert.equal(followupScope("window", contextScope("make the email more formal")), "window", "window threads never narrow");
});

test("deixis-content: strong deixis that only names user content says so; the score and every other reason stay", () => {
  const content = { window: 0.9, reasons: ["deixis-strong", "deixis-content"] };
  for (const text of ["summarize the selection", "what is this image", "explain this code", "fasse die Auswahl zusammen", "what is this?",
    "summarize this text", "describe this picture", "übersetze diesen Text", "was ist das?", "the highlighted part"]) {
    assert.deepEqual(contextScope(text), content, text);
  }
  // Anything that names the screen itself, or operates the window, stays a plain screen anchor.
  for (const text of ["summarize this page", "what's on my screen", "compare the selection with this page", "look at this",
    "click this button", "select this text", "was steht auf dem bildschirm"]) {
    assert(!contextScope(text).reasons.includes("deixis-content"), text);
    assert(contextScope(text).reasons.includes("deixis-strong"), text);
  }
  // The shared /instant fixture is exactly what the rules return for such a request.
  const fixture = JSON.parse(readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "context", "instant-content-deixis.json"), "utf8"));
  assert.deepEqual(fixture.scope, contextScope("summarize the selection"));
  // A follow-up still widens a general thread on it (deixis-strong is unchanged), as before.
  assert.equal(followupScope("general", contextScope("what is this image")), "window");
});

test("strong deixis is exactly screen deixis or content deixis (the split changes no score)", () => {
  const texts = ["dev.jsonl", "holdout1.jsonl", "holdout2.jsonl", "deixis.jsonl"].flatMap((name) => load(name).map((item) => item.text));
  let strong = 0;
  for (const text of texts) {
    const normalized = boundedUtterance(text);
    const either = SCREEN_DEIXIS.test(normalized) || CONTENT_DEIXIS.test(normalized);
    assert.equal(screenEvidence(normalized, classifyUtterance(text).intent).reason === "deixis-strong", either, text);
    if (either) strong++;
  }
  assert(strong > 20, `the corpus exercises strong deixis (${strong})`);
});
