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
