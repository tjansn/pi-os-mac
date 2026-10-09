import assert from "node:assert/strict";
import { test } from "node:test";
import { formatPerfLine, perfLog, Stopwatch } from "../src/telemetry.js";
import { outcomeFields } from "../src/instant/learned.js";

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

test("dictionary perf fields are the outcome's status, code, list and conflict count — never its line, entry id or undo token", () => {
  const learned = outcomeFields({
    status: "learned", code: "replaced", entry: { list: "appNames", id: "n_8f3a2c1d" }, line: "Learned: “recast” → Raycast",
    undoToken: "u_4c1f9e2a7b3d5e6f", revision: 43,
  });
  assert.deepEqual(learned, { status: "learned", code: "replaced", list: "appNames" });
  assert.equal(formatPerfLine("dictionary.learn", 0.42, { kind: "pick", ...learned }), "[perf] stage=dictionary.learn ms=0.4 kind=pick status=learned code=replaced list=appNames");
  const asked = outcomeFields({ status: "needs_confirmation", code: "regression", conflicts: [0, 3], line: "This would change 2 earlier takes. Remember anyway?", revision: 42 });
  assert.deepEqual(asked, { status: "needs_confirmation", code: "regression", conflicts: 2 });
  const line = formatPerfLine("dictionary.learn", 1, { kind: "edit", ...asked });
  for (const content of ["recast", "Raycast", "n_8f3a2c1d", "u_4c1f", "earlier takes"]) assert.ok(!line.includes(content));
});

test("harness readiness lines are content-free: listen and agent-stack timings only", (t) => {
  const log = t.mock.method(console, "log", () => {});
  perfLog("harness.listen", 87.25, {});
  perfLog("harness.agent", 312.4, { ok: true });
  assert.deepEqual(log.mock.calls.map((call) => call.arguments[0]), [
    "[perf] stage=harness.listen ms=87.3",
    "[perf] stage=harness.agent ms=312.4 ok=true",
  ]);
});
