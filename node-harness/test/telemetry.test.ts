import assert from "node:assert/strict";
import { test } from "node:test";
import { formatPerfLine, perfLog, Stopwatch } from "../src/telemetry.js";

test("Stopwatch reports elapsed time and consecutive laps from a monotonic clock", () => {
  let now = 100;
  const watch = new Stopwatch(() => now);
  now = 112.5; assert.equal(watch.lap(), 12.5);
  now = 130; assert.equal(watch.lap(), 17.5);
  assert.equal(watch.elapsed(), 30);
  const real = new Stopwatch();
  assert(real.elapsed() >= 0 && real.lap() >= 0);
});

test("perfLog writes exactly one [perf] line with rounded ms and typed fields", (t) => {
  const log = t.mock.method(console, "log", () => {});
  perfLog("instant.dispatch", 3.14159, { intent: "calc", count: 2, cached: true, model: "openai/gpt-x@high" });
  assert.equal(log.mock.callCount(), 1);
  assert.deepEqual(log.mock.calls[0]!.arguments,
    ["[perf] stage=instant.dispatch ms=3.1 intent=calc count=2 cached=true model=openai/gpt-x@high"]);
  assert.equal(formatPerfLine("session.create", 12), "[perf] stage=session.create ms=12");
});

test("perf lines stay single-token per field, bounded, and cannot spoof stage/ms", () => {
  const line = formatPerfLine("bad stage\nname", Number.NaN, {
    "key with space": "two words\nnext=line", stage: "spoof", ms: 1, long: "x".repeat(500),
  });
  assert.doesNotMatch(line, /\n/);
  assert.match(line, /^\[perf\] stage=bad_stage_name ms=NaN key_with_space=two_words_next_line long=x{80}$/);
  assert.equal(line.match(/ stage=/g)?.length, 1);
  assert.equal(line.match(/ ms=/g)?.length, 1);
});
