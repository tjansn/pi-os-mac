import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { AppIndexResult, AppRecord } from "../src/contracts/launcher.js";
import { AppIndexCache, AppMatcher, FileFrecencyStore } from "../src/instant/apps.js";
import { assertOwnerOnly } from "./ownerOnly.js";

const app = (bundleId: string, name: string, aliases: string[] = [], running = false): AppRecord =>
  ({ bundleId, name, aliases, path: `/Applications/${name}.app`, running });

const APPS: AppRecord[] = [
  app("com.figma.Desktop", "Figma"),
  app("com.figma.FigJam", "FigJam"),
  app("com.spotify.client", "Spotify"),
  app("com.tinyspeck.slackmacgap", "Slack"),
  app("com.google.Chrome", "Google Chrome"),
  app("com.microsoft.VSCode", "Visual Studio Code", ["Code"], true),
  app("com.apple.systempreferences", "System Settings"),
  app("com.apple.calculator", "Calculator"),
  app("com.apple.iCal", "Calendar"),
  app("com.brave.Browser", "Brave Browser"),
  app("com.apple.Terminal", "Terminal"),
  app("com.apple.FaceTime", "FaceTime"),
  app("com.apple.dt.Xcode", "Xcode"),
];
const matcher = new AppMatcher(APPS);
const top = (query: string) => matcher.match(query)[0];
const decisive = (query: string) => AppMatcher.decisive(matcher.match(query))?.app.bundleId ?? null;

test("exact names and EN/DE aliases (Rechner, Systemeinstellungen, Kalender) resolve decisively", () => {
  assert.equal(decisive("figma"), "com.figma.Desktop");
  assert.equal(decisive("Spotify"), "com.spotify.client");
  assert.equal(decisive("rechner"), "com.apple.calculator");
  assert.equal(decisive("Taschenrechner"), "com.apple.calculator");
  assert.equal(decisive("systemeinstellungen"), "com.apple.systempreferences");
  assert.equal(decisive("settings"), "com.apple.systempreferences");
  assert.equal(decisive("kalender"), "com.apple.iCal");
  assert.equal(decisive("chrome"), "com.google.Chrome");
  assert.equal(decisive("vs code"), "com.microsoft.VSCode");
  assert.equal(decisive("code"), "com.microsoft.VSCode");
  assert.equal(top("figma")?.reason, "exact");
  assert.equal(top("rechner")?.reason, "alias");
});

test("initials, prefixes, whole words and fuzzy letters rank like Raycast", () => {
  assert.equal(decisive("vsc"), "com.microsoft.VSCode");
  assert.equal(top("gc")?.app.name, "Google Chrome");
  assert.equal(top("gc")?.reason, "initials");
  assert.equal(top("spot")?.app.name, "Spotify");
  assert.equal(top("spot")?.reason, "prefix");
  assert.equal(top("brave")?.app.name, "Brave Browser");
  assert.equal(top("ftime")?.app.name, "FaceTime");
  assert.equal(top("ftime")?.reason, "fuzzy");
  assert.equal(decisive("ftime"), null, "fuzzy matches list, never act");
  // "fig" is ambiguous between Figma and FigJam: list, don't act.
  assert.deepEqual(matcher.match("fig").map((m) => m.app.name).sort(), ["FigJam", "Figma"]);
  assert.equal(decisive("fig"), null);
});

test("non-app phrases do not match anything", () => {
  for (const query of ["pod bay doors", "last email from lisa", "a timer for 5 minutes", "the tests"]) {
    assert.deepEqual(matcher.match(query), [], query);
  }
});

test("frecency and running boosts break ties without overriding clearly better names", () => {
  const frecency = { score: (key: string) => (key === "com.figma.FigJam" ? 1 : 0) };
  const boosted = new AppMatcher(APPS, frecency);
  assert.equal(boosted.match("fig")[0]?.app.name, "FigJam");
  assert.equal(boosted.match("figma")[0]?.app.name, "Figma");
});

test("AppIndexCache: fetches once per TTL, rebuilds only when the version changes, serves stale data while refreshing", async () => {
  let now = 0;
  let calls = 0;
  let version = "apps-1";
  const index = (): AppIndexResult => ({ version, apps: version === "apps-1" ? APPS : [...APPS, app("com.apple.Notes", "Notes")] });
  const cache = new AppIndexCache(async () => { calls++; return index(); }, { ttlMs: 1_000, clock: () => now });
  const signal = new AbortController().signal;
  const [a, b] = await Promise.all([cache.get(signal), cache.get(signal)]);
  assert.equal(calls, 1);
  assert.equal(a, b);
  now = 500;
  assert.equal(await cache.get(signal), a);
  assert.equal(calls, 1);
  now = 1_500;
  assert.equal(await cache.get(signal), a, "stale matcher is served immediately");
  await cache.refresh();
  assert.equal(calls, 2);
  assert.equal(cache.peek(), a, "same version keeps the matcher");
  version = "apps-2";
  now = 3_000;
  await cache.get(signal);
  await cache.refresh();
  assert.notEqual(cache.peek(), a);
  assert.equal(cache.peek()?.size, APPS.length + 1);
});

test("AppIndexCache survives host errors and malformed records", async () => {
  const failing = new AppIndexCache(async () => { throw new Error("host down"); });
  assert.equal(await failing.get(new AbortController().signal), null);
  const malformed = new AppIndexCache(async () => ({ version: "1", apps: [{ bundleId: 3 }, app("com.figma.Desktop", "Figma")] as unknown as AppRecord[] }));
  assert.equal((await malformed.get(new AbortController().signal))?.size, 1);
  // A bundle id openApp would reject never becomes an act or a card row.
  const badId = new AppIndexCache(async () => ({ version: "1", apps: [app("not a bundle id", "Figma Beta"), app("com.figma.Desktop", "Figma")] }));
  assert.deepEqual((await badId.get(new AbortController().signal))?.match("figma").map((m) => m.app.bundleId), ["com.figma.Desktop"]);
  const aborted = new AbortController();
  aborted.abort();
  const slow = new AppIndexCache(() => new Promise(() => {}));
  assert.equal(await slow.get(aborted.signal), null);
});

test("FileFrecencyStore keeps bundle ids only, decays with age and persists owner-only", async () => {
  const file = join(mkdtempSync(join(tmpdir(), "pi-os-frecency-")), "instant-usage.json");
  const store = new FileFrecencyStore(file);
  await store.load();
  const day = 86_400_000;
  store.record("com.figma.Desktop", 0);
  store.record("com.figma.Desktop", 0);
  store.record("/Users/fixture/secret.pdf", 0);
  assert.ok(store.score("com.figma.Desktop", 0) > store.score("com.figma.Desktop", 30 * day));
  assert.equal(store.score("com.spotify.client", 0), 0);
  await new Promise((resolve) => setTimeout(resolve, 50));
  const saved = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
  assert.deepEqual(Object.keys(saved), ["com.figma.Desktop"]);
  assertOwnerOnly(file, 0o600);
  const reloaded = new FileFrecencyStore(file);
  await reloaded.load();
  assert.ok(reloaded.score("com.figma.Desktop", 0) > 0);
});
