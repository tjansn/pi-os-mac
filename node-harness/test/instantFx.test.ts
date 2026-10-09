import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import {
  EcbRateStore, ECB_DAILY_URL, fxFreshness, fxFreshnessLabel, fxNeedsRefresh, isTargetDay, parseEcbXml, type FxSnapshot,
} from "../src/instant/engines/fx.js";
import { assertOwnerOnly } from "./ownerOnly.js";

// Fixture XML only: every fetch is injected; the test guard rejects any real network call.

const fixtureXml = readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "instant-cases", "ecb-2026-10-02.xml"), "utf8");
const LAST_MODIFIED = "Fri, 02 Oct 2026 13:56:23 GMT";

function cacheFile(): string {
  return join(mkdtempSync(join(tmpdir(), "pi-os-fx-")), "cache", "fx-ecb.json");
}

interface Call { url: string; headers: Record<string, string> }

function fakeFetch(responses: (() => Response)[]): { fetch: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    fetch: (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(input), headers: { ...(init?.headers as Record<string, string>) } });
      const next = responses.shift();
      if (!next) throw new Error("unexpected fetch");
      return next();
    }) as typeof fetch,
  };
}

const ok = (xml = fixtureXml) => () => new Response(xml, { status: 200, headers: { "last-modified": LAST_MODIFIED, "content-type": "text/xml" } });
const notModified = () => new Response(null, { status: 304 });

function snapshot(asOf: string, fetchedAt = "2026-10-02T15:00:00.000Z"): FxSnapshot {
  return { source: "ecb-eurofxref-daily", base: "EUR", asOf, fetchedAt, rates: { EUR: 1, USD: 1.1225 } };
}

test("parseEcbXml reads the date and rates (EUR included) and rejects junk", () => {
  const parsed = parseEcbXml(fixtureXml);
  assert.deepEqual(parsed, { asOf: "2026-10-02", rates: { EUR: 1, USD: 1.1225, JPY: 176.99, GBP: 0.85033, CHF: 0.9279, ZAR: 18.7839 } });
  assert.equal(Object.keys(parsed!.rates).length, 6);
  assert.equal(parseEcbXml("<html>nope</html>"), null);
  assert.equal(parseEcbXml("<Cube time='2026-10-02'></Cube>"), null);
  assert.equal(parseEcbXml(`<Cube time='2026-10-02'><Cube currency='USD' rate='-1'/></Cube>`), null);
  assert.equal(parseEcbXml("x".repeat(300_000)), null);
});

test("first refresh: 200 → rates stored, cache file written atomically with owner-only mode, status-only log", async () => {
  const file = cacheFile();
  const lines: string[] = [];
  const { fetch, calls } = fakeFetch([ok()]);
  const store = new EcbRateStore({ file, fetch, now: () => new Date("2026-10-02T16:30:00Z"), log: (line) => lines.push(line) });
  assert.equal(await store.load(), null);
  assert.equal(store.freshness(), "missing");
  assert.equal(await store.refresh(), "updated");
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.url, ECB_DAILY_URL);
  assert.equal(calls[0]!.headers["if-modified-since"], undefined);
  const saved = JSON.parse(readFileSync(file, "utf8")) as FxSnapshot;
  assert.equal(saved.asOf, "2026-10-02");
  assert.equal(saved.lastModified, LAST_MODIFIED);
  assertOwnerOnly(file, 0o600);
  assertOwnerOnly(dirname(file), 0o700); // the store creates cache/ itself
  assert.deepEqual(lines, ["[instant] ecb fx refresh status=200 currencies=6"]);
  assert.equal(store.version, 1);
});

test("conditional GET: 304 keeps rates, updates fetchedAt and returns not_modified", async () => {
  const file = cacheFile();
  const first = new EcbRateStore({ file, fetch: fakeFetch([ok()]).fetch, now: () => new Date("2026-10-02T16:30:00Z"), log: () => {} });
  await first.refresh();
  const { fetch, calls } = fakeFetch([notModified]);
  const store = new EcbRateStore({ file, fetch, now: () => new Date("2026-10-02T23:00:00Z"), log: () => {} });
  const before = await store.load();
  assert.equal(await store.refresh(), "not_modified");
  assert.equal(calls[0]!.headers["if-modified-since"], LAST_MODIFIED);
  const after = store.snapshot()!;
  assert.deepEqual(after.rates, before!.rates);
  assert.equal(after.fetchedAt, "2026-10-02T23:00:00.000Z");
  assert.equal((JSON.parse(readFileSync(file, "utf8")) as FxSnapshot).fetchedAt, "2026-10-02T23:00:00.000Z");
});

test("200 with a new reference date is an update; concurrent refreshes share one request", async () => {
  const next = fixtureXml.replace("2026-10-02", "2026-10-05").replace("1.1225", "1.1300");
  const file = cacheFile();
  const { fetch, calls } = fakeFetch([ok(), ok(next)]);
  const store = new EcbRateStore({ file, fetch, now: () => new Date("2026-10-05T16:30:00Z"), log: () => {} });
  const [a, b] = await Promise.all([store.refresh(), store.refresh()]);
  assert.deepEqual([a, b], ["updated", "updated"]);
  assert.equal(calls.length, 1);
  assert.equal(await store.refresh(), "updated");
  assert.equal(store.snapshot()!.asOf, "2026-10-05");
  assert.equal(store.snapshot()!.rates.USD, 1.13);
  assert.equal(store.version, 2);
});

test("refresh never throws: network errors, HTTP errors, bad XML and the disabled setting", async () => {
  const lines: string[] = [];
  const failing = new EcbRateStore({ file: cacheFile(), fetch: (async () => { throw new Error("offline"); }) as typeof fetch, log: (line) => lines.push(line) });
  assert.equal(await failing.refresh(), "failed");
  const http = new EcbRateStore({ file: cacheFile(), fetch: fakeFetch([() => new Response("", { status: 503 })]).fetch, log: (line) => lines.push(line) });
  assert.equal(await http.refresh(), "failed");
  const junk = new EcbRateStore({ file: cacheFile(), fetch: fakeFetch([ok("<html/>")]).fetch, log: (line) => lines.push(line) });
  assert.equal(await junk.refresh(), "failed");
  const { fetch, calls } = fakeFetch([ok()]);
  const disabled = new EcbRateStore({ file: cacheFile(), fetch, enabled: () => false });
  assert.equal(await disabled.refresh(), "disabled");
  assert.equal(calls.length, 0);
  assert.deepEqual(lines, ["[instant] ecb fx refresh status=error", "[instant] ecb fx refresh status=503", "[instant] ecb fx refresh status=200 parse=failed"]);
  // The default fetch is the guarded global one: it fails closed here instead of reaching the network.
  const unguarded = new EcbRateStore({ file: cacheFile(), log: () => {} });
  assert.equal(await unguarded.refresh(), "failed");
});

test("after a failed download the store backs off instead of re-fetching on every query", async () => {
  let clock = Date.parse("2026-10-02T16:30:00Z");
  const { fetch, calls } = fakeFetch([() => new Response("", { status: 503 }), ok()]);
  const store = new EcbRateStore({ file: cacheFile(), fetch, now: () => new Date(clock), log: () => {}, retryAfterFailureMs: 60_000 });
  await store.load();
  assert.equal(store.needsRefresh(), true);
  assert.equal(await store.refresh(), "failed");
  assert.equal(store.recentlyFailed(), true);
  assert.equal(store.needsRefresh(), false, "no retry inside the backoff window");
  clock += 59_000;
  assert.equal(store.needsRefresh(), false);
  clock += 2_000;
  assert.equal(store.recentlyFailed(), false);
  assert.equal(store.needsRefresh(), true);
  assert.equal(await store.refresh(), "updated");
  assert.equal(store.recentlyFailed(), false, "a success clears the backoff");
  assert.equal(calls.length, 2);
});

test("a waiting caller can give up without cancelling the shared fetch", async () => {
  let release: (() => void) | undefined;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const store = new EcbRateStore({
    file: cacheFile(),
    fetch: (async () => { await gate; return ok()(); }) as typeof fetch,
    log: () => {},
  });
  const controller = new AbortController();
  const waiting = store.refresh(controller.signal);
  controller.abort();
  assert.equal(await waiting, "failed");
  release?.();
  assert.equal(await store.refresh(), "updated");
});

test("corrupt cache files are ignored", async () => {
  const file = join(mkdtempSync(join(tmpdir(), "pi-os-fx-")), "fx-ecb.json");
  writeFileSync(file, "{not json");
  assert.equal(await new EcbRateStore({ file }).load(), null);
  writeFileSync(file, JSON.stringify({ ...snapshot("2026-10-02"), rates: { USD: "1.1" } }));
  assert.equal(await new EcbRateStore({ file }).load(), null);
});

test("freshness tiers follow TARGET days (weekends and holidays keep the last rate fresh)", () => {
  const at = (iso: string) => new Date(iso);
  assert.equal(fxFreshness(null, at("2026-10-02T12:00:00Z")), "missing");
  assert.equal(fxFreshness(snapshot("2026-10-02"), at("2026-10-02T18:00:00Z")), "fresh"); // same day
  assert.equal(fxFreshness(snapshot("2026-10-02"), at("2026-10-05T10:00:00Z")), "fresh"); // Monday vs Friday
  assert.equal(fxFreshness(snapshot("2026-10-01"), at("2026-10-02T10:00:00Z")), "fresh"); // previous TARGET day
  assert.equal(fxFreshness(snapshot("2026-09-30"), at("2026-10-03T10:00:00Z")), "aging"); // +3 d
  assert.equal(fxFreshness(snapshot("2026-10-01"), at("2026-10-04T10:00:00Z")), "aging");
  assert.equal(fxFreshness(snapshot("2026-09-25"), at("2026-10-01T10:00:00Z")), "stale"); // +6 d
  // Easter 2027: Good Friday (Mar 26) and Easter Monday (Mar 29) are TARGET holidays.
  assert.equal(isTargetDay({ year: 2027, month: 3, day: 26 }), false);
  assert.equal(isTargetDay({ year: 2027, month: 3, day: 29 }), false);
  assert.equal(isTargetDay({ year: 2026, month: 12, day: 25 }), false);
  assert.equal(isTargetDay({ year: 2026, month: 10, day: 2 }), true);
  assert.equal(fxFreshness(snapshot("2027-03-25"), at("2027-03-30T10:00:00Z")), "fresh");
  assert.equal(fxFreshnessLabel(snapshot("2026-10-02")), "ECB reference rate 2026-10-02 · info only");
  assert.equal(fxFreshnessLabel(null), "ECB reference rates not downloaded yet");
});

test("refresh schedule: on demand when missing, after 6 h, or after the 16:00 CET publication", () => {
  assert.equal(fxNeedsRefresh(null, new Date("2026-10-02T10:00:00Z")), true);
  assert.equal(fxNeedsRefresh(snapshot("2026-10-02", "2026-10-02T15:00:00Z"), new Date("2026-10-02T16:00:00Z")), false);
  assert.equal(fxNeedsRefresh(snapshot("2026-10-02", "2026-10-02T09:00:00Z"), new Date("2026-10-02T16:00:00Z")), true);
  // 16:20 Berlin (14:20Z) on a TARGET day with yesterday's rate, last fetch 90 min ago.
  assert.equal(fxNeedsRefresh(snapshot("2026-10-01", "2026-10-02T12:50:00Z"), new Date("2026-10-02T14:20:00Z")), true);
  assert.equal(fxNeedsRefresh(snapshot("2026-10-01", "2026-10-02T14:00:00Z"), new Date("2026-10-02T14:20:00Z")), false);
});

test("convert uses EUR-based cross rates and carries freshness and the ECB label", async () => {
  const store = new EcbRateStore({ file: cacheFile(), fetch: fakeFetch([ok()]).fetch, now: () => new Date("2026-10-02T18:00:00Z"), log: () => {} });
  assert.equal(store.convert(100, "USD", "EUR"), null);
  await store.refresh();
  const usd = store.convert(100, "usd", "EUR")!;
  assert.ok(Math.abs(usd.value - 89.0868596882) < 1e-9);
  assert.equal(usd.freshness, "fresh");
  assert.equal(usd.label, "ECB reference rate 2026-10-02 · info only");
  const cross = store.convert(10_000, "USD", "GBP")!;
  assert.ok(Math.abs(cross.value - 10_000 / 1.1225 * 0.85033) < 1e-6);
  assert.equal(store.convert(1, "BTC", "EUR"), null);
});

test("an oversized ECB body is rejected without buffering it whole (streamed byte cap and Content-Length)", async () => {
  let pulled = 0;
  const huge = () => new ReadableStream<Uint8Array>({
    pull(controller) {
      pulled++;
      if (pulled > 1_000) { controller.close(); return; }
      controller.enqueue(new Uint8Array(64 * 1024).fill(0x20));
    },
  });
  const streamed = new EcbRateStore({ file: cacheFile(), fetch: (async () => new Response(huge(), { status: 200 })) as typeof fetch, log: () => {} });
  assert.equal(await streamed.refresh(), "failed");
  assert.ok(pulled < 10, `stopped reading after ${pulled} chunks`);
  const declared = new EcbRateStore({
    file: cacheFile(), log: () => {},
    fetch: (async () => new Response(fixtureXml, { status: 200, headers: { "content-length": String(10 * 1024 * 1024) } })) as typeof fetch,
  });
  assert.equal(await declared.refresh(), "failed");
  // The real fixture still parses through the capped reader.
  const normal = new EcbRateStore({ file: cacheFile(), fetch: (async () => new Response(fixtureXml, { status: 200 })) as typeof fetch, log: () => {} });
  assert.equal(await normal.refresh(), "updated");
});
