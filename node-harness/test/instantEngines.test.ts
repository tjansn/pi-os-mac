import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { FileCandidate, FileSearchRequest } from "../src/contracts/launcher.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { createFendLoader, createInstantEngines } from "../src/instant/engines.js";
import { EcbRateStore } from "../src/instant/engines/fx.js";

// The structured engine API that B5's pi tools (instant_calc, instant_convert_currency,
// instant_time_in, find_files, list_apps) call. Fixtures only.

const xml = readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "instant-cases", "ecb-2026-10-02.xml"), "utf8");
const requests: FileSearchRequest[] = [];
const candidates: FileCandidate[] = [
  { token: "tok_aaaaaaaa", name: "Invoice-2026-03.pdf", path: "/Users/fixture/Documents/Invoice-2026-03.pdf", contentType: "com.adobe.pdf", modifiedMs: Date.UTC(2026, 2, 14), createdMs: Date.UTC(2026, 2, 14), isDirectory: false, isPackage: false },
  { token: "tok_bbbbbbbb", name: "invoice.pdf", path: "/Users/fixture/.Trash/invoice.pdf", isDirectory: false, isPackage: false },
];
const engines = createInstantEngines({
  fend: createFendLoader(),
  fx: new EcbRateStore({
    file: join(mkdtempSync(join(tmpdir(), "pi-os-engines-")), "fx.json"),
    fetch: (async () => new Response(xml, { status: 200 })) as typeof fetch,
    now: () => new Date("2026-10-02T18:00:00Z"),
    log: () => {},
  }),
  apps: new AppIndexCache(async () => ({ version: "1", apps: [{ bundleId: "com.figma.Desktop", name: "Figma", aliases: [], path: "/Applications/Figma.app", running: false }] })),
  searchFiles: async (request) => { requests.push(request); return { items: candidates, truncated: false, elapsedMs: 1 }; },
  now: () => new Date(2026, 9, 2, 19, 30),
  localZone: () => "Europe/Berlin",
});

test("calc: exact fend results with Raycast percent semantics; errors are values", async () => {
  assert.deepEqual(await engines.calc("2^64"), { ok: true, expression: "2^64", text: "18446744073709551616", approximate: false, display: "18,446,744,073,709,551,616", copy: "18446744073709551616" });
  assert.equal((await engines.calc("80 + 15%")).ok && (await engines.calc("80 + 15%") as { text: string }).text, "92");
  assert.equal((await engines.calc("340 × 15%") as { text: string }).text, "51");
  assert.equal((await engines.calc("10 GB to MB") as { text: string }).text, "10000 MB");
  assert.deepEqual(await engines.calc("1/0"), { ok: false, error: "division by zero" });
  assert.deepEqual(await engines.calc(""), { ok: false, error: "empty" });
  assert.deepEqual(await engines.calc("9".repeat(600)), { ok: false, error: "too_long" });
  assert.deepEqual(await engines.calc(42 as unknown as string), { ok: false, error: "empty" });
});

test("convertCurrency: ISO codes or names, ECB label and freshness, explicit errors", async () => {
  const result = await engines.convertCurrency(100, "dollars", "eur");
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.equal(result.from, "USD");
  assert.equal(result.display, "89.09 EUR");
  assert.equal(result.copy, "89.09");
  assert.equal(result.rateDisplay, "1 USD = 0.8909 EUR");
  assert.equal(result.label, "ECB reference rate 2026-10-02 · info only");
  assert.equal(result.freshness, "fresh");
  assert.equal((await engines.convertCurrency(1000, "EUR", "JPY")).ok && (await engines.convertCurrency(1000, "EUR", "JPY") as { display: string }).display, "176,990 JPY");
  assert.deepEqual(await engines.convertCurrency(1, "XYZ", "EUR"), { ok: false, error: "unknown_currency", message: "No ECB reference rate for XYZ." });
  assert.deepEqual(await engines.convertCurrency(1, "dogecoin", "EUR"), { ok: false, error: "unknown_currency", message: "Unknown currency." });
  assert.equal((await engines.convertCurrency(Number.NaN, "USD", "EUR")).ok, false);
});

test("timeIn / convertTime / timeDifference / dateMath", async () => {
  const tokyo = await engines.timeIn("tokio");
  assert.ok(tokyo.ok);
  if (tokyo.ok) assert.equal(tokyo.zone, "Asia/Tokyo");
  assert.deepEqual(await engines.timeIn("narnia"), { ok: false, error: "unknown_place" });
  const converted = await engines.convertTime("5pm", "london", "san francisco");
  assert.ok(converted.ok && converted.time24 === "09:00");
  assert.deepEqual(await engines.convertTime("25:00", null, "tokyo"), { ok: false, error: "invalid_time" });
  assert.deepEqual(await engines.timeDifference("berlin", "tokyo"), { ok: true, fromPlace: "Berlin", toPlace: "Tokyo", hours: 7 });
  const christmas = await engines.dateMath("days until christmas");
  assert.ok(christmas.ok && christmas.days === 84 && christmas.date === "2026-12-25");
  assert.deepEqual((await engines.dateMath("in 3 weeks")).ok && (await engines.dateMath("in 3 weeks") as { date: string }).date, "2026-10-23");
  assert.deepEqual(await engines.dateMath("what's the capital of france"), { ok: false, error: "unparsed" });
});

test("findFiles: grammar-aware query, host request, Node ranking, trash excluded", async () => {
  const result = await engines.findFiles("invoice from march");
  assert.ok(result.ok);
  if (!result.ok) return;
  assert.deepEqual(result.files.map((file) => file.token), ["tok_aaaaaaaa"]);
  assert.deepEqual(requests.at(-1)?.nameGroups, [["invoice"], ["rechnung"]]);
  await engines.findFiles("budget", { contentType: "public.spreadsheet", maxResults: 10 });
  assert.equal(requests.at(-1)?.contentType, "public.spreadsheet");
  assert.equal(requests.at(-1)?.maxResults, 10);
  assert.deepEqual(await engines.findFiles(""), { ok: false, error: "invalid_query" });
  const noHost = createInstantEngines({ fend: createFendLoader() });
  assert.deepEqual(await noHost.findFiles("invoice"), { ok: false, error: "unavailable" });
  // Rows without a well-formed host token are dropped (their open/reveal/copy bindings would be invalid).
  const badToken = createInstantEngines({
    searchFiles: async () => [{ ...candidates[0]!, token: "../../etc" }, { ...candidates[0]!, token: "tok_cccccccc" }],
    now: () => new Date(2026, 9, 2, 19, 30),
  });
  const filtered = await badToken.findFiles("invoice");
  assert.deepEqual(filtered.ok && filtered.files.map((file) => file.token), ["tok_cccccccc"]);
});

test("matchApps uses the host index cache", async () => {
  const apps = await engines.matchApps("figma");
  assert.ok(apps.ok && apps.matches[0]?.app.bundleId === "com.figma.Desktop");
  assert.deepEqual(await createInstantEngines({}).matchApps("figma"), { ok: false, error: "unavailable" });
});
