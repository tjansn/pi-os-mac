import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { AppIndexResult, AppRecord } from "../src/contracts/launcher.js";
import { AppIndexCache, AppMatcher, FileFrecencyStore, spokenHead, spokenVariants, spokenVia } from "../src/instant/apps.js";
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

// ---------------------------------------------------------------- spoken matching (DESIGN4 §5.2)

const SPOKEN_APPS: AppRecord[] = [
  app("com.apple.Pages", "Pages Creator Studio", ["Pages"]), app("com.apple.Keynote", "Keynote Creator Studio", ["Keynote"]),
  app("com.apple.Numbers", "Numbers Creator Studio"), app("notion.id", "Notion"), app("com.cron.electron", "Notion Calendar"),
  app("com.brave.Browser", "Brave Browser", ["Brave"]), app("com.apple.iCal", "Calendar"), app("com.apple.finder", "Finder"),
  app("com.apple.BluetoothFileExchange", "Bluetooth File Exchange"), app("com.1password.1password", "1Password"), app("com.apple.dt.Xcode", "Xcode"),
  app("com.cmuxterm.app", "cmux"), app("com.spotify.client", "Spotify"), app("com.mitchellh.ghostty", "Ghostty"), app("com.apple.AppStore", "App Store"),
];
const spoken = new AppMatcher(SPOKEN_APPS);

test("iWork Creator Studio bundle ids answer to Pages, Keynote and Numbers (classic ids keep their aliases)", () => {
  assert.equal(AppMatcher.decisive(spoken.match("pages"))?.app.bundleId, "com.apple.Pages");
  assert.equal(AppMatcher.decisive(spoken.match("numbers"))?.app.bundleId, "com.apple.Numbers");
  assert.equal(AppMatcher.decisive(spoken.match("keynote"))?.app.bundleId, "com.apple.Keynote");
  const classic = new AppMatcher([app("com.apple.iWork.Pages", "Pages Classic")]);
  assert.equal(AppMatcher.decisive(classic.match("pages"))?.app.bundleId, "com.apple.iWork.Pages");
  assert.equal(spoken.app("com.apple.Pages")?.name, "Pages Creator Studio");
  assert.equal(spoken.app("com.example.missing"), undefined);
});

test("typed matching: a leading 'app' word is stripped unless it is part of the name; spoken-only forms stay out", () => {
  assert.equal(AppMatcher.decisive(matcher.match("app figma"))?.app.bundleId, "com.figma.Desktop");
  assert.equal(spoken.match("app store")[0]?.reason, "exact");
  assert.equal(AppMatcher.decisive(spoken.match("app store"))?.app.bundleId, "com.apple.AppStore");
  // "one password" is a spoken form of 1Password; typing "one" does not list it.
  assert.deepEqual(spoken.match("one").map((m) => m.app.bundleId), []);
  assert.equal(spoken.matchSpoken("one password")[0]?.app.bundleId, "com.1password.1password");
});

test("spoken variants: possessives, plurals, wrappers, spelled letters and number words", () => {
  const texts = (raw: string) => spokenVariants(raw).map((v) => v.text);
  assert.ok(texts("Notion's").includes("notion"));
  assert.ok(texts("notions").includes("notion"));
  assert.ok(texts("the Brave browser").includes("brave"));
  assert.ok(texts("ex code").includes("x code"));
  assert.ok(texts("see mux").includes("c mux"));
  assert.ok(texts("one password").includes("1 password"));
  assert.ok(texts("number").includes("numbers"));
  assert.equal(spokenVariants("Pages")[0]?.penalty, 0, "the heard form first, unpenalized");
  assert.equal(spokenHead("the Brave browser"), "brave");
  assert.equal(spokenHead("Notion's"), "notion");
  assert.equal(spokenHead("page is"), "page is");
});

test("spoken literal tiers: exact names and aliases, whole words; a single word of a longer name is capped", () => {
  const top = (query: string) => spoken.matchSpoken(query)[0];
  assert.equal(top("key note")?.app.bundleId, "com.apple.Keynote");
  assert.equal(top("the Brave browser")?.app.bundleId, "com.brave.Browser");
  assert.equal(top("Pages")?.label, "Pages", "the shorter proper alias is the label");
  assert.equal(top("Notion Calendar")?.reason, "exact");
  // A single word of a two-word name is offered at most (0.8); one word of a three-word name is not even a candidate.
  const activity = new AppMatcher([app("com.apple.ActivityMonitor", "Activity Monitor")]).matchSpoken("activity")[0];
  assert.deepEqual([activity?.reason, activity?.score], ["prefix", 0.8]);
  assert.equal(spoken.matchSpoken("file").some((m) => m.app.bundleId === "com.apple.BluetoothFileExchange"), false);
  assert.equal(AppMatcher.decisive(spoken.match("file"))?.app.bundleId, "com.apple.BluetoothFileExchange", "typing keeps its tiers");
  // Typing aids are gone for speech: no partial-word prefix ("note" → Notion?) and no subsequence fuzzy.
  assert.equal(spoken.matchSpoken("cal").some((m) => m.reason === "prefix" || m.reason === "fuzzy"), false);
});

test("spoken sound tier: edit + Double Metaphone, Kölner Phonetik only for German", () => {
  const sound = (query: string, german = false) => spoken.matchSpoken(query, { german })[0];
  assert.deepEqual([sound("page is")?.app.bundleId, sound("page is")?.reason], ["com.apple.Pages", "sound"]);
  assert.equal(sound("calender")?.app.bundleId, "com.apple.iCal");
  assert.equal(sound("ghost T")?.app.bundleId, "com.mitchellh.ghostty");
  assert.equal(sound("spotifei")?.app.bundleId, "com.spotify.client");
  assert.equal(spokenVia(sound("page is")!), "sound");
  assert.equal(spokenVia(spoken.matchSpoken("Keynote")[0]!), "alias");
  assert.equal(spokenVia(spoken.matchSpoken("Ghostty")[0]!), "exact");
  // Kölner Phonetik models German spelling: "Brejf" is Brave, "Nambers" is Numbers — for German speech only.
  for (const [heard, bundleId] of [["Brejf", "com.brave.Browser"], ["Nambers", "com.apple.Numbers"]] as const) {
    const score = (german: boolean) => spoken.matchSpoken(heard, { german }).find((m) => m.app.bundleId === bundleId)?.score ?? 0;
    assert.ok(score(true) > score(false) + 0.05, `${heard}: ${score(true)} vs ${score(false)}`);
  }
  // Numbers belong to the request: "page 2" never sounds like an app.
  assert.equal(spoken.matchSpoken("page 2").some((m) => m.reason === "sound"), false);
  // A dictionary word only reaches sound-alikes with its own first sound: "lotion" ≠ Notion, "nation" ~ Notion.
  assert.equal(spoken.matchSpoken("lotion", { heardIsWord: true }).some((m) => m.app.bundleId === "notion.id"), false);
  assert.equal(spoken.matchSpoken("nation", { heardIsWord: true })[0]?.app.bundleId, "notion.id");
});
