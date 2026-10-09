import assert from "node:assert/strict";
import { test } from "node:test";
import { createInstantDispatcher } from "../src/instant/dispatcher.js";

/*
 * Latency targets (DESIGN §3.3, raycast §5.1): a cold first calc dispatch in a
 * fresh process (fend compile + instantiate + first evaluation) under 50 ms,
 * warm calc dispatches p50 under 5 ms. node:test runs each file in its own
 * process, so the first dispatch here really is cold. Measured on the dev
 * machine (M5 Max): cold ≈ 15–35 ms, warm p50 ≈ 0.05–0.2 ms. Set
 * PI_OS_PERF_SLACK (e.g. 3) on slower or loaded machines.
 */

const slack = Number(process.env.PI_OS_PERF_SLACK ?? "1") || 1;

test("cold first calc dispatch < 50 ms and warm calc dispatch p50 < 5 ms", async () => {
  const dispatcher = createInstantDispatcher({ budgets: { defaultMs: 1_000 } });
  const started = performance.now();
  const first = await dispatcher.dispatch({ text: "15% of 340", phase: "final", seq: 1 });
  const cold = performance.now() - started;
  assert.equal(first.decision, "answer");

  const texts = ["2+2", "15% of 340", "what's two to the power of thirty two", "80 + 15%", "5 miles in km", "zwei hoch sechzehn minus tausend"];
  for (let i = 0; i < 50; i++) await dispatcher.dispatch({ text: texts[i % texts.length]!, phase: "typing", seq: i });
  const samples: number[] = [];
  for (let i = 0; i < 300; i++) {
    const t = performance.now();
    const response = await dispatcher.dispatch({ text: texts[i % texts.length]!, phase: "typing", seq: i });
    samples.push(performance.now() - t);
    assert.equal(response.decision, "answer");
  }
  samples.sort((a, b) => a - b);
  const p50 = samples[Math.floor(samples.length / 2)]!;
  const p95 = samples[Math.floor(samples.length * 0.95)]!;
  console.log(`[perf-test] instant cold=${cold.toFixed(1)}ms warm p50=${p50.toFixed(3)}ms p95=${p95.toFixed(3)}ms`);
  assert.ok(cold < 50 * slack, `cold first call ${cold.toFixed(1)} ms`);
  assert.ok(p50 < 5 * slack, `warm p50 ${p50.toFixed(3)} ms`);
});

test("a voice final with 6 hypotheses (first tier, secondaries, learned rules) dispatches p95 < 5 ms", async () => {
  const { AppIndexCache } = await import("../src/instant/apps.js");
  const { DictionaryStore, nonCountingLookup } = await import("../src/instant/dictionary.js");
  const names = ["Pages Creator Studio", "Keynote Creator Studio", "Numbers Creator Studio", "Notion", "Notion Calendar", "Notion Mail", "Raycast", "Safari",
    "Brave Browser", "Spotify", "Ghostty", "Telegram", "Calendar", "Notes", "Music", "Photos", "Mail", "Messages", "Finder", "Terminal", "System Settings",
    "Activity Monitor", "Bluetooth File Exchange", "Claude", "ChatGPT", "Xcode", "Zed", "Orca", "Podcasts", "Weather", "Calculator", "TextEdit", "Preview"];
  const apps = names.map((name, i) => ({ bundleId: `com.example.app${i}`, name, aliases: name.endsWith(" Creator Studio") ? [name.split(" ")[0]!] : [], path: `/Applications/${name}.app`, running: false }));
  const dictionary = new DictionaryStore({ persist: false });
  dictionary.load();
  for (const [heard, i] of [["recast", 6], ["kein note", 1], ["page is", 0], ["clod", 23]] as const) {
    dictionary.bind({ list: "appNames", heard, bundleId: `com.example.app${i}`, display: names[i]! }, { recognizer: "any", source: "manual" });
    dictionary.bind({ list: "fixes", heard, intended: names[i]! }, { recognizer: "apple-dt/en-US", source: "manual" });
  }
  const dispatcher = createInstantDispatcher({ apps: new AppIndexCache(async () => ({ version: "1", apps })), dictionary: nonCountingLookup(dictionary) });
  await dispatcher.warm();
  const takes = [
    ["Of the bitter safari.", "Öffne bitte Safari.", "Of the bitter Sophie.", "Öffne bitte so fahre.", "Off the bitter safari", "Öffne Bitter Safari."],
    ["Oh, the kind order.", "Oh, die Kinder.", "Oh the kind of order.", "Oh die Kinder Ordner.", "Oh, then kinder.", "O die Kinder."],
    ["open grave", "Open Brave.", "Open grape.", "Open crave.", "Öffne Brave.", "Open brave browser."],
    ["Mark Mal pages off.", "Mach mal Pages auf.", "Mark mal pages of.", "Mach mal Pages an.", "Mark my pages off.", "Mach mal Paste auf."],
  ];
  const request = (texts: readonly string[], seq: number) => ({
    text: texts[0]!, phase: "final" as const, seq, inputMode: "voice" as const, accept: ["suggest", "check", "confirm"] as ("suggest" | "check" | "confirm")[],
    hypotheses: texts.map((text, i) => ({
      text, source: i % 2 ? "apple-dt/de-DE" : "apple-dt/en-US", role: i < 2 ? "peer" as const : "secondary" as const,
      ...(i < 2 ? { confidence: i ? 0.45 : 0.35, minConfidence: 0.3 } : {}),
    })),
  });
  for (let i = 0; i < 40; i++) await dispatcher.dispatch(request(takes[i % takes.length]!, i));
  const samples: number[] = [];
  for (let i = 0; i < 400; i++) {
    const t = performance.now();
    await dispatcher.dispatch(request(takes[i % takes.length]!, i));
    samples.push(performance.now() - t);
  }
  samples.sort((a, b) => a - b);
  const p50 = samples[Math.floor(samples.length / 2)]!;
  const p95 = samples[Math.floor(samples.length * 0.95)]!;
  console.log(`[perf-test] voice final, 6 hypotheses: p50=${p50.toFixed(3)}ms p95=${p95.toFixed(3)}ms`);
  assert.ok(p95 < 5 * slack, `p95 ${p95.toFixed(3)} ms`);
});
