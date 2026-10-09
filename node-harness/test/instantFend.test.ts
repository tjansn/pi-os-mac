import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { createFendLoader } from "../src/instant/engines.js";
import { FendEngine, fendImportObject } from "../src/instant/engines/fend.js";

// Runs fend locally from node_modules: CPU-only, offline, no eval.

const warnings: string[] = [];
process.on("warning", (warning) => warnings.push(`${warning.name}: ${warning.message}`));
const engine = FendEngine.load();

test("manual wasm load emits no experimental warning and never imports the wasm ESM entry", async () => {
  await engine;
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(warnings.filter((w) => /wasm|webassembly|experimental/i.test(w)), []);
});

test("the glue's Function-constructor import is replaced by a throwing stub", () => {
  const dir = dirname(createRequire(import.meta.url).resolve("fend-wasm/package.json"));
  const glueSource = readFileSync(join(dir, "fend_wasm_bg.js"), "utf8");
  const names = [...glueSource.matchAll(/export function (__wbg_new_no_args_\w+)/g)].map((m) => m[1]!);
  assert.equal(names.length, 1, "fend 1.5.8 glue exposes exactly one Function-constructor import");
  let constructed = false;
  const fake: Record<string, unknown> = { [names[0]!]: () => { constructed = true; }, __wbg_other: () => 1 };
  const imports = fendImportObject(fake)["./fend_wasm_bg.js"]!;
  assert.throws(() => (imports[names[0]!] as () => unknown)(), /disabled/);
  assert.equal(constructed, false);
  assert.equal(imports.__wbg_other, fake.__wbg_other);
});

test("fend results are pinned for the calculator fixtures (raycast §23.3)", async () => {
  const fend = await engine;
  const ok = (expression: string, text: string, approximate = false) =>
    assert.deepEqual(fend.evaluate(expression), { ok: true, text, approximate }, expression);
  ok("2^32", "4294967296");
  ok("15% of 340", "51");
  ok("sqrt(625)", "25");
  ok("5 miles to km", "8.04672 km");
  ok("0xff to decimal", "255");
  ok("255 to hex", "ff");
  ok("255 to binary", "11111111");
  ok("72 °F to °C", "22.2222222222 °C", true);
  ok("5 lb to kg", "2.26796185 kg");
  ok("(80)*(1+15/100)", "92");
  ok("80*(1-20/100)", "64");
  ok("2^16 - 1000", "64536");
  ok("1/3", "0.3333333333", true);
  ok("2^100", "1267650600228229401496703205376");
  const big = fend.evaluate("100!");
  assert.ok(big.ok && big.text.length === 158 && big.text.startsWith("93326215443944"), "arbitrary precision");
});

test("errors come back as results, not exceptions; hard timeout interrupts runaway input", async () => {
  const fend = await engine;
  assert.deepEqual(fend.evaluate("1/0"), { ok: false, error: "division by zero" });
  assert.equal(fend.evaluate("hello world").ok, false);
  assert.deepEqual(fend.evaluate(""), { ok: false, error: "empty" });
  assert.deepEqual(fend.evaluate("1+".repeat(300)), { ok: false, error: "too_long" });
  assert.deepEqual(fend.evaluate("100 USD to EUR"), { ok: false, error: "exchange rates are not available" });
  const started = performance.now();
  const runaway = fend.evaluate("10^10^10", 30);
  const elapsed = performance.now() - started;
  assert.deepEqual(runaway, { ok: false, error: "interrupted" });
  assert.ok(elapsed < 250, `timeout honoured (${elapsed.toFixed(1)} ms)`);
  // The engine stays usable afterwards.
  assert.deepEqual(fend.evaluate("2+2"), { ok: true, text: "4", approximate: false });
});

test("a wasm trap (runaway recursion) drops the instance; the loader waits for the rebuild", async () => {
  const loader = createFendLoader();
  const fend = await loader.get();
  // Self-application recurses until the wasm stack overflows (well inside the 1 s cap), which traps.
  assert.deepEqual(fend.evaluate("(\\x.x x) (\\x.x x)", 1_000), { ok: false, error: "engine_error" });
  assert.equal(fend.ready, false);
  const rebuilt = await loader.get();
  assert.equal(rebuilt, fend);
  assert.equal(rebuilt.ready, true);
  assert.deepEqual(rebuilt.evaluate("2+2"), { ok: true, text: "4", approximate: false });
});

test("currency rates are injected per instance; reload swaps the write-once table", async () => {
  const fend = await FendEngine.load({ rates: new Map([["EUR", 1], ["USD", 1.1225]]) });
  assert.equal(fend.hasRates, true);
  assert.deepEqual(fend.evaluate("100 USD to EUR"), { ok: true, text: "89.0868596882 EUR", approximate: true });
  await fend.reload(new Map([["EUR", 1], ["USD", 2]]));
  assert.deepEqual(fend.evaluate("100 USD to EUR"), { ok: true, text: "50 EUR", approximate: false });
  // Other engines are separate instances with their own glue state.
  assert.deepEqual((await engine).evaluate("100 USD to EUR"), { ok: false, error: "exchange rates are not available" });
});
