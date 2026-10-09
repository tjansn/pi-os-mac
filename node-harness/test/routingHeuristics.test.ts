import assert from "node:assert/strict";
import { test } from "node:test";
import {
  BASE_TIERS, boundedUtterance, buildRouteInput, classificationFromHints, classifyUtterance, extractRequestText, intrinsicTier,
  routeContextFromSnapshot, screenEvidence, surfaceFromProcess, tierRank,
  type AgentIntent, type Classification, type ClassifierHints, type SurfaceClass,
} from "../src/agent/routing/index.js";
import type { DesktopContextSnapshot } from "../src/hostClient.js";

interface Row {
  text: string;
  intent: AgentIntent;
  surface?: SurfaceClass;
  cdp?: boolean;
  screen?: boolean;
  deep?: boolean;
  max?: boolean;
  fast?: boolean;
  correction?: boolean;
  complexity?: 0 | 1 | 2;
}

// Fixture utterances (EN + DE). No real user data.
const CORPUS: Row[] = [
  // calculate
  { text: "what's 18% of 240", intent: "calculate" },
  { text: "12 * 7 + 3", intent: "calculate" },
  { text: "100 km in miles", intent: "calculate" },
  { text: "convert 72 fahrenheit to celsius", intent: "calculate" },
  { text: "$20 in euro", intent: "calculate" },
  { text: "what is 15 times 17", intent: "calculate" },
  { text: "was sind 15 prozent von 80", intent: "calculate" },
  { text: "wie viel ist 3 hoch 4", intent: "calculate" },
  { text: "20 euro in dollar", intent: "calculate" },
  { text: "rechne 1200 geteilt durch 7", intent: "calculate" },
  // search_computer
  { text: "find my tax pdf from last year", intent: "search_computer" },
  { text: "where is the invoice from march", intent: "search_computer" },
  { text: "search for screenshots from yesterday", intent: "search_computer" },
  { text: "show me the presentation about q3", intent: "search_computer" },
  { text: "wo ist die rechnung von märz", intent: "search_computer" },
  { text: "finde meine bewerbungsunterlagen dateien", intent: "search_computer" },
  { text: "such die fotos vom urlaub", intent: "search_computer" },
  // open_launch
  { text: "open spotify", intent: "open_launch" },
  { text: "launch xcode", intent: "open_launch" },
  { text: "switch to slack", intent: "open_launch" },
  { text: "öffne safari", intent: "open_launch" },
  { text: "starte die musik app", intent: "open_launch" },
  // answer
  { text: "what's the capital of france", intent: "answer" },
  { text: "who wrote the magic mountain?", intent: "answer" },
  { text: "why is the sky blue", intent: "answer", complexity: 1 },
  { text: "how do vaccines work", intent: "answer", complexity: 1 },
  { text: "is it going to rain tomorrow in berlin?", intent: "answer" },
  { text: "what's the zip code of berlin mitte", intent: "answer" },
  { text: "wer hat die wm 2014 gewonnen", intent: "answer" },
  { text: "warum ist der himmel blau", intent: "answer", complexity: 1 },
  { text: "wie spät ist es in tokio?", intent: "answer" },
  { text: "erklär mir quantenverschränkung", intent: "answer", complexity: 1 },
  { text: "what is this error", intent: "answer", screen: true },
  { text: "was ist das hier", intent: "answer", screen: true },
  // write
  { text: "translate this to german", intent: "write", screen: true },
  { text: "rewrite the selected paragraph more formally", intent: "write", screen: true },
  { text: "summarize this article", intent: "write", screen: true },
  { text: "draft a reply to this email saying I'll be late this evening", intent: "write", screen: true },
  { text: "fix the grammar", intent: "write" },
  { text: "fasse diesen artikel zusammen", intent: "write", screen: true },
  { text: "übersetze das ins englische", intent: "write", screen: true },
  { text: "schreib eine kurze antwort an anna", intent: "write", fast: true },
  { text: "formuliere diesen absatz um", intent: "write", screen: true },
  // act_in_app
  { text: "click the blue submit button", intent: "act_in_app", screen: true },
  { text: "type hello world into the search field", intent: "act_in_app", screen: true },
  { text: "scroll down to the comments", intent: "act_in_app", screen: true },
  { text: "please press save", intent: "act_in_app", screen: true },
  { text: "like this post", intent: "act_in_app", screen: true },
  { text: "fill in the form with my work address", intent: "act_in_app", screen: true },
  { text: "klick auf den blauen button", intent: "act_in_app", screen: true },
  { text: "markiere die zweite zeile", intent: "act_in_app", screen: true },
  { text: "schließ das fenster", intent: "act_in_app", screen: true },
  { text: "bitte drück auf speichern", intent: "act_in_app", screen: true },
  { text: "change this to bold", intent: "act_in_app", screen: true },
  // browse_web
  { text: "book a table at the italian place for friday", intent: "browse_web", surface: "browser" },
  { text: "go to the pricing page", intent: "browse_web", surface: "browser" },
  { text: "click the login button", intent: "browse_web", surface: "browser", cdp: true },
  { text: "bestelle das zweite produkt", intent: "browse_web", surface: "browser" },
  { text: "geh auf die startseite", intent: "browse_web", surface: "browser" },
  // code
  { text: "write a python function that parses iso dates", intent: "code" },
  { text: "why does this regex not match", intent: "code", screen: true },
  { text: "fix the failing unit tests", intent: "code" },
  { text: "explain this stack trace", intent: "code", screen: true },
  { text: "refactor the login handler", intent: "code" },
  { text: "fix this", intent: "code", surface: "editor", screen: true },
  { text: "run the build", intent: "code", surface: "terminal" },
  { text: "schreib ein skript in python das dateien umbenennt", intent: "code" },
  { text: "warum kompiliert das nicht", intent: "code" },
  // explicit depth / speed
  { text: "think hard about how to restructure my week", intent: "answer", deep: true },
  { text: "take your time and plan my trip to japan", intent: "other", deep: true },
  { text: "deep dive into the pros and cons of heat pumps", intent: "other", deep: true },
  { text: "denk gründlich nach: wie sollte ich meine finanzen planen", intent: "answer", deep: true },
  { text: "bitte gründlich prüfen ob der vertrag fair ist", intent: "other", deep: true },
  { text: "ultrathink: prove that the square root of two is irrational", intent: "other", deep: true, max: true },
  { text: "maximum effort: design a backup strategy for my photos", intent: "other", deep: true, max: true },
  { text: "so gründlich wie möglich: vergleiche die beiden angebote", intent: "other", deep: true, max: true },
  { text: "quick: what time is it in tokyo", intent: "answer", fast: true },
  { text: "briefly, what is a heat pump", intent: "answer", fast: true },
  { text: "schnell: wie spät ist es in new york", intent: "answer", fast: true },
  { text: "kurz: was ist ein wärmepumpe", intent: "answer", fast: true },
  // corrections (follow-ups)
  { text: "no, that's wrong", intent: "other", correction: true },
  { text: "try again", intent: "other", correction: true },
  { text: "that didn't work", intent: "other", correction: true },
  { text: "nein, das stimmt nicht", intent: "other", correction: true },
  { text: "falsch, versuch es nochmal", intent: "other", correction: true },
  { text: "das funktioniert immer noch nicht", intent: "other", correction: true },
  // other / ambiguous
  { text: "hmm", intent: "other" },
  { text: "taylor swift new album", intent: "other" },
];

function classify(row: Row): Classification {
  return classifyUtterance(row.text, { surface: row.surface ?? "other", browserCdp: row.cdp ?? false });
}

test("EN/DE corpus: intent accuracy >= 0.9 overall and per-row flags are exact", () => {
  assert.ok(CORPUS.length >= 60, "corpus has at least 60 rows");
  const misses: string[] = [];
  for (const row of CORPUS) {
    const c = classify(row);
    if (c.intent !== row.intent) misses.push(`${row.text} -> ${c.intent} (expected ${row.intent})`);
    assert.equal(c.explicitDeep, row.deep ?? false, `explicitDeep: ${row.text}`);
    assert.equal(c.explicitMax, row.max ?? false, `explicitMax: ${row.text}`);
    assert.equal(c.explicitFast, row.fast ?? false, `explicitFast: ${row.text}`);
    assert.equal(c.correction >= 0.6, row.correction ?? false, `correction: ${row.text}`);
    if (row.screen !== undefined) assert.equal(c.needsScreen >= 0.5, row.screen, `needsScreen: ${row.text}`);
    if (row.complexity !== undefined) assert.equal(c.complexity, row.complexity, `complexity: ${row.text}`);
  }
  const accuracy = 1 - misses.length / CORPUS.length;
  assert.ok(accuracy >= 0.9, `accuracy ${accuracy.toFixed(3)}; misses:\n${misses.join("\n")}`);
});

test("calculate rows are 100% correct and confident (instant-lane eligible)", () => {
  for (const row of CORPUS.filter(r => r.intent === "calculate")) {
    const c = classify(row);
    assert.equal(c.intent, "calculate", row.text);
    assert.ok(c.intentConfidence >= 0.9, row.text);
  }
});

test("time expressions and 'here is' are not screen deixis; strong screen words are", () => {
  for (const text of ["what should I cook this evening", "remind me this weekend", "here is my plan for today", "was mache ich diese woche"]) {
    assert.ok(classifyUtterance(text).needsScreen < 0.5, text);
  }
  for (const text of ["what's on my screen", "read the highlighted text", "was steht auf dem bildschirm", "erklär mir diese tabelle"]) {
    assert.ok(classifyUtterance(text).needsScreen >= 0.9, text);
  }
});

test("a definite on-screen noun ('the page', 'die Mail') asks for the screenshot; general questions do not", () => {
  for (const text of ["summarize the page", "reply to the email", "what does the error say", "explain the chart", "read the article to me",
    "fasse die seite zusammen", "antworte auf die mail", "was sagt die fehlermeldung", "erklär mir die tabelle"]) {
    assert.ok(classifyUtterance(text).needsScreen >= 0.5, text);
  }
  for (const text of ["what's the capital of france", "what's the weather tomorrow", "write an email to my boss", "who won the game last night",
    "how do I make pasta", "wie wird das wetter morgen", "schreib eine mail an meinen chef"]) {
    assert.ok(classifyUtterance(text).needsScreen < 0.5, text);
  }
});

test("German object pronoun 'das' is deixis like English 'this'; the article 'das' is not", () => {
  for (const text of ["fass das zusammen", "übersetz das ins Englische", "kannst du das mal kurz übersetzen", "was bedeutet das?", "erklär mir das bitte", "summarize this"]) {
    assert.ok(classifyUtterance(text).needsScreen >= 0.5, text);
  }
  for (const text of ["wie wird das wetter morgen", "mach das licht aus", "was ist das beste restaurant in berlin", "steht das in der zeitung von heute"]) {
    assert.ok(classifyUtterance(text).needsScreen < 0.5, text);
  }
  assert.equal(classifyUtterance("ändere das").intent, "act_in_app", "like 'change this'");
});

test("'gib … ein' is typing into a field only when 'ein' closes the clause ('gib mir ein Rezept' is a request)", () => {
  for (const text of ["gib mir ein Rezept für Pfannkuchen", "gib mir ein paar ideen für das wochenende", "gib mir einen tipp", "gib mir ein, zwei tipps"]) {
    const c = classifyUtterance(text);
    assert.notEqual(c.intent, "act_in_app", text);
    assert.ok(c.needsScreen < 0.5, text);
  }
  for (const text of ["gib deine adresse ein", "gib hallo welt ein.", "gib das datum ein und drück enter", "bitte gib die nummer 1234 ein"]) {
    assert.equal(classifyUtterance(text).intent, "act_in_app", text);
  }
});

test("edits of what is shown are UI actions ('make the first line bold', 'format …', 'rename …', 'set/change … to')", () => {
  for (const text of ["make the first line bold", "make the heading bigger", "format the table", "rename this file to notes",
    "set my status to away", "change the title to hello", "mach den text fett", "formatiere die tabelle", "benenne die datei in notizen um"]) {
    assert.equal(classifyUtterance(text).intent, "act_in_app", text);
  }
  assert.equal(classifyUtterance("make it shorter").intent, "write", "rewrites stay write");
  assert.equal(classifyUtterance("make a bigger plan for my week").intent, "other", "no determiner, nothing shown is edited");
  assert.equal(classifyUtterance("rename the login handler", { surface: "editor" }).intent, "code", "an editor rename is a refactoring");
  assert.equal(classifyUtterance("set an alarm for 7").intent, "other");
});

test("screen evidence names why needsScreen is set (content-free reason codes)", () => {
  const evidence = (text: string) => {
    const normalized = boundedUtterance(text);
    return screenEvidence(normalized, classifyUtterance(text).intent);
  };
  assert.deepEqual(evidence("what's on my screen"), { p: 0.9, reason: "deixis-strong" });
  assert.deepEqual(evidence("click the blue submit button"), { p: 0.8, reason: "act-in-app" });
  assert.deepEqual(evidence("translate this to german"), { p: 0.6, reason: "deixis-weak" });
  assert.deepEqual(evidence("summarize the page"), { p: 0.6, reason: "definite-noun" });
  assert.deepEqual(evidence("what's the capital of france"), { p: 0.1 });
  for (const text of ["what's on my screen", "summarize the page", "hmm"]) assert.equal(evidence(text).p, classifyUtterance(text).needsScreen);
  assert.equal(boundedUtterance(`  Hello’s   ${"x".repeat(5_000)}`).length, 1_000);
});

test("ordinary words are not code: language names and 'code' only in a code context", () => {
  assert.equal(classifyUtterance("taylor swift new album").intent, "other");
  assert.equal(classifyUtterance("how do I remove rust from a bike chain").intent, "answer");
  assert.equal(classifyUtterance("what's the area code of munich").intent, "answer");
  assert.equal(classifyUtterance("write it in swift").intent, "code");
});

test("long multi-step or analytical requests are complex; short ones are not", () => {
  assert.equal(classifyUtterance("what's the capital of france").complexity, 0);
  assert.equal(classifyUtterance("open the report and then summarize it and then email it to anna").complexity, 2);
  assert.equal(classifyUtterance("compare these two offers").complexity, 2);
  assert.equal(classifyUtterance(`${"word ".repeat(45)}`).complexity, 2);
});

test("classification is fast (p99 < 1 ms) and deterministic", () => {
  const samples: number[] = [];
  for (let i = 0; i < 2_000; i++) {
    const row = CORPUS[i % CORPUS.length]!;
    const start = performance.now();
    classify(row);
    samples.push(performance.now() - start);
  }
  samples.sort((a, b) => a - b);
  const p99 = samples[Math.floor(samples.length * 0.99)]!;
  assert.ok(p99 < 1, `p99 ${p99.toFixed(3)} ms`);
  assert.deepEqual(classify(CORPUS[0]!), classify(CORPUS[0]!));
});

test("surface classes come from process names only", () => {
  assert.equal(surfaceFromProcess("Safari"), "browser");
  assert.equal(surfaceFromProcess("Brave Browser"), "browser");
  assert.equal(surfaceFromProcess("msedge.exe"), "browser");
  assert.equal(surfaceFromProcess("Code"), "editor");
  assert.equal(surfaceFromProcess("iTerm2"), "terminal");
  assert.equal(surfaceFromProcess("Finder"), "finder");
  assert.equal(surfaceFromProcess("Slack"), "mail_chat");
  assert.equal(surfaceFromProcess("Microsoft Word"), "office");
  assert.equal(surfaceFromProcess("1Password"), "other");
  assert.equal(surfaceFromProcess("Archive Utility"), "other");
  assert.equal(surfaceFromProcess(undefined), "other");
  assert.equal(surfaceFromProcess("Finder", { finderDesktop: true }), "finder");
});

test("the request is extracted from agentRunner's prompt wrapper before classification", () => {
  const wrapped = "## Desktop context (target identity pinned before the prompt appeared)\n{\"targetWindow\":{\"title\":\"click here\"}}\n\n## Request\nwhat's 2+2";
  assert.equal(extractRequestText(wrapped), "what's 2+2");
  assert.equal(extractRequestText("plain"), "plain");
  // A "## Request" line inside the user's own words is part of the request, not the wrapper's marker.
  assert.equal(extractRequestText(`${wrapped}\n## Request\nand more`), "what's 2+2\n## Request\nand more");
});

test("route input from a pinned snapshot uses the process name, screenshot presence and browser mode only", () => {
  const snapshot = {
    id: "ctx", capturedAt: "2026-10-02T00:00:00Z", cursor: { x: 0, y: 0 }, monitors: [],
    foregroundWindow: null, windowUnderCursor: null,
    targetWindow: { hwnd: "1", processId: 1, processName: "Brave Browser", title: "Fixture", bounds: { x: 0, y: 0, width: 1, height: 1 } },
    browser: { name: "Brave", mode: "cdp", pinned: true },
    screenshot: { kind: "file", filePath: "/tmp/fixture.png" },
  } satisfies DesktopContextSnapshot;
  const context = routeContextFromSnapshot(snapshot);
  assert.deepEqual(context, { surface: "browser", hasScreenshot: true, browserCdp: true });
  const input = buildRouteInput("click the login button", context, { followup: true, lastTier: "fast" });
  assert.equal(input.classification.intent, "browse_web");
  assert.equal(input.followup, true);
  assert.equal(input.lastTier, "fast");
  assert.ok(input.estimatedPromptTokens > 6_000);
});

// --- advisory fusion ---------------------------------------------------------

const HINTS: ClassifierHints[] = [];
for (const intent of Object.keys(BASE_TIERS) as AgentIntent[]) {
  for (const p of [0.2, 0.75, 0.99]) {
    HINTS.push({ source: "laya", latencyMs: 40, intent, intentP: p });
  }
}
for (const tier of ["instant", "quick", "fast", "standard", "deep", "max"] as const) {
  for (const p of [0.3, 0.9]) HINTS.push({ source: "pi-classifier", latencyMs: 200, tier, tierP: p, needsScreen: p });
}
HINTS.push({ source: "laya", latencyMs: Number.NaN, intent: "toString" as AgentIntent, intentP: 1, needsScreen: Number.POSITIVE_INFINITY });

test("advisory hints never lower the tier or the screenshot need and never clear explicit words", () => {
  for (const row of CORPUS) {
    const heuristic = classify(row);
    for (const hints of HINTS) {
      const fused = classificationFromHints(heuristic, hints);
      assert.ok(tierRank(intrinsicTier(fused)) >= tierRank(intrinsicTier(heuristic)), `${row.text} ${JSON.stringify(hints)}`);
      assert.ok(fused.needsScreen >= heuristic.needsScreen);
      assert.equal(fused.explicitDeep, heuristic.explicitDeep);
      assert.equal(fused.explicitMax, heuristic.explicitMax);
      assert.equal(fused.explicitFast, heuristic.explicitFast);
      assert.equal(fused.complexity, heuristic.complexity);
      if (heuristic.intent !== "other") assert.equal(fused.intent, heuristic.intent, "rule-derived labels are kept");
      assert.ok(!["calculate", "open_launch", "search_computer"].includes(fused.intent) || fused.intent === heuristic.intent,
        "a hint never adopts an instant-lane intent");
    }
  }
});

test("confident hints raise: unknown utterance adopts a label, a higher hinted tier becomes a floor", () => {
  const other = classifyUtterance("hmm the thing");
  const adopted = classificationFromHints(other, { source: "laya", latencyMs: 30, intent: "act_in_app", intentP: 0.9 });
  assert.equal(adopted.intent, "act_in_app");
  assert.ok(adopted.needsScreen >= 0.6);
  assert.deepEqual(adopted.advisory, { source: "laya", latencyMs: 30, raised: ["intent", "screen"] });

  const answer = classifyUtterance("what's the capital of france");
  assert.equal(intrinsicTier(answer), "quick");
  const raised = classificationFromHints(answer, { source: "pi-classifier", latencyMs: 180, tier: "standard", tierP: 0.8 });
  assert.equal(raised.tierFloor, "standard");
  assert.equal(intrinsicTier(raised), "standard");
  const ignored = classificationFromHints(answer, { source: "pi-classifier", latencyMs: 180, tier: "deep", tierP: 0.4 });
  assert.equal(intrinsicTier(ignored), "quick", "low-probability hints are ignored");
  assert.equal(classificationFromHints(answer, null), answer);
});
