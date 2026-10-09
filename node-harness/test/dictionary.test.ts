import assert from "node:assert/strict";
import { chmodSync, copyFileSync, existsSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  DICTIONARY_LIMITS, parseDictionary, parseRecognizerTerms, type DictionaryDocument, type LearnedAlias,
} from "../src/contracts/dictionary.js";
import type { InstantRequest, InstantResponse } from "../src/contracts/instant.js";
import {
  contentWords, DictionaryStore, hasContentWord, nameCore, rankRecognizerTerms, utteranceCore,
} from "../src/instant/dictionary.js";
import { aliasGuardPasses, displayName } from "../src/instant/learned.js";
import { attachTakeDetails, InMemoryTakeMemo, offeredBundleIds, takeDetailsOf, takeRecordFor, type TakeRecord } from "../src/instant/takeMemo.js";

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = (path: string): any => JSON.parse(readFileSync(path, "utf8"));
const VALID = join(fixtures, "dictionary", "valid.json");
/** The fixtures' "now" (valid.json's entries are from 2026-10-01..07). */
const NOW = Date.parse("2026-10-07T12:00:00Z");

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), "pi-os-dictionary-"));
}

/** A store on a copy of `fixture` (or a fresh path), with a settable clock and captured log lines. */
function storeAt(fixture?: string | object, options: { now?: () => number; dir?: string } = {}) {
  const dir = options.dir ?? tempDir();
  const path = join(dir, "dictionary.json");
  if (typeof fixture === "string") copyFileSync(fixture, path);
  else if (fixture) writeFileSync(path, JSON.stringify(fixture));
  const lines: string[] = [];
  let now = NOW;
  const store = new DictionaryStore({ path, clock: options.now ?? (() => now), log: (line) => lines.push(line) });
  const report = store.load();
  return { store, report, path, dir, lines, advance: (ms: number) => { now += ms; } };
}

const onDisk = (path: string): DictionaryDocument => readJson(path);

test("store: a missing file is empty; the first write creates 0600 in a 0700 directory, atomically, at revision 1", () => {
  const root = tempDir();
  const dir = join(root, "support", "pi-os");
  const { store, report, path } = storeAt(undefined, { dir });
  assert.equal(report.status, "missing");
  assert.equal(store.revision(), 0);
  assert.equal(existsSync(path), false, "loading never creates the file");
  const outcome = store.bind({ list: "appNames", heard: "recast", bundleId: "com.raycast.macos", display: "Raycast" }, { recognizer: "parakeet-v3", source: "did-you-mean" });
  assert.ok(outcome.ok);
  assert.equal(outcome.revision, 1);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.equal(statSync(dir).mode & 0o777, 0o700);
  assert.deepEqual(readdirSync(dir), ["dictionary.json"], "no temp file is left behind");
  const written = onDisk(path);
  assert.equal(written.revision, 1);
  assert.deepEqual(parseDictionary(written), { ok: true, value: store.document(), issues: [] });
  // Every write bumps the revision on disk and in memory.
  store.updateSettings({ explainToAgent: false });
  assert.equal(onDisk(path).revision, 2);
  assert.equal(store.revision(), 2);
});

test("store: a loose support directory is tightened to 0700 on the first write", () => {
  const dir = tempDir();
  chmodSync(dir, 0o755);
  const { store } = storeAt(undefined, { dir });
  store.updateSettings({ learn: "ask" });
  assert.equal(statSync(dir).mode & 0o777, 0o700);
});

test("store: valid.json loads unchanged and the document is a deep copy", () => {
  const { store, report, lines } = storeAt(VALID);
  assert.equal(report.status, "ok");
  assert.deepEqual(report.issues, []);
  assert.deepEqual(store.document(), readJson(VALID));
  const copy = store.document();
  copy.aliases.length = 0;
  assert.equal(store.document().aliases.length, 5);
  // Content-free load line: counts and codes only.
  assert.deepEqual(lines, ["[dictionary] loaded status=ok entries=12 dropped=0 codes=none"]);
});

test("store: corrupt, oversized and wrong-shape files start empty and are kept as .corrupt on the next write", () => {
  for (const [label, bytes] of [
    ["corrupt", "{ not json"],
    ["oversized", JSON.stringify({ version: 1, revision: 3, pad: "x".repeat(DICTIONARY_LIMITS.fileBytes) })],
    ["invalid", JSON.stringify({ version: 2, revision: 1 })],
  ] as const) {
    const dir = tempDir();
    const path = join(dir, "dictionary.json");
    writeFileSync(path, bytes);
    const store = new DictionaryStore({ path, clock: () => NOW, log: () => {} });
    assert.equal(store.load().status, label, label);
    assert.equal(store.revision(), 0, label);
    assert.ok(store.bind({ list: "fixes", heard: "clod", intended: "Claude" }, { recognizer: "any", source: "manual" }).ok, label);
    assert.equal(readFileSync(`${path}.corrupt`, "utf8"), bytes, `${label}: the unusable bytes are recoverable`);
    assert.equal(statSync(`${path}.corrupt`).mode & 0o777, 0o600);
    assert.equal(onDisk(path).fixes.length, 1, label);
  }
});

test("store: a file it cannot read is never replaced; changes stay in memory", (t) => {
  if (process.getuid?.() === 0) return t.skip("root reads everything");
  const dir = tempDir();
  const path = join(dir, "dictionary.json");
  writeFileSync(path, readFileSync(VALID));
  chmodSync(path, 0o000);
  try {
    const lines: string[] = [];
    const store = new DictionaryStore({ path, clock: () => NOW, log: (line) => lines.push(line) });
    assert.equal(store.load().status, "unreadable");
    const outcome = store.bind({ list: "fixes", heard: "clod", intended: "Claude" }, { recognizer: "any", source: "manual" });
    assert.ok(outcome.ok);
    assert.equal(store.document().fixes.length, 1);
    assert.ok(lines.some((line) => /not written/.test(line)));
    chmodSync(path, 0o600);
    assert.deepEqual(readJson(path), readJson(VALID), "the unreadable file is untouched");
  } finally {
    chmodSync(path, 0o600);
  }
});

test("store: load-time validation is learn-time validation (no content word → dropped; paths index the file)", () => {
  const entry = (id: string, phrase: string) => ({
    id, phrase, target: { kind: "openApp", bundleId: "com.apple.Music" }, recognizer: "any", source: "manual",
    count: 1, rejections: 0, uses: 0, createdAt: "2026-10-05T09:00:00Z",
  });
  const name = (id: string, heard: string) => ({
    id, heard, bundleId: "com.apple.iCal", display: "Calendar", recognizer: "apple-dt/de-DE", source: "did-you-mean",
    count: 1, rejections: 0, uses: 0, createdAt: "2026-10-05T09:00:00Z",
  });
  const { store, report } = storeAt({
    version: 1, revision: 4,
    aliases: [entry("a_trash", "empty the trash"), entry("a_open", "open"), entry("a_ok", "spiel musik"), entry("a_bitte", "bitte bitte")],
    appNames: [name("n_oben", "oben"), name("n_window", "the window"), name("n_cal", "kalender app")],
  });
  assert.equal(report.status, "ok");
  assert.deepEqual(report.issues, [
    { path: "appNames[0]", code: "invalid_phrase" },
    { path: "appNames[1]", code: "invalid_phrase" },
    { path: "aliases[0]", code: "refused_phrase" },
    { path: "aliases[1]", code: "invalid_phrase" },
    { path: "aliases[3]", code: "invalid_phrase" },
  ]);
  assert.deepEqual(store.document().aliases.map((alias) => alias.id), ["a_ok"]);
  assert.deepEqual(store.document().appNames.map((alias) => alias.id), ["n_cal"]);
});

test("lookups: exact on the folded phrase (wrapper particles folded), recognizer-scoped, active rules only, never fuzzy", () => {
  const { store } = storeAt(VALID);
  // Step 1: utterance aliases.
  assert.deepEqual(store.alias("Mach kein Note auf!", "apple-dt/de-DE"), { ref: { list: "aliases", id: "a_keynote01" }, value: { kind: "openApp", bundleId: "com.apple.Keynote" } });
  assert.equal(store.alias("mach kein note auf", "apple-dt/en-US"), null, "scoped to the recognizer that learned it");
  assert.equal(store.alias("mach kein note", "apple-dt/de-DE"), null, "no partial or fuzzy match");
  assert.equal(store.alias("mach keine note auf", "apple-dt/de-DE"), null);
  assert.deepEqual(store.alias("Ruhe, bitte!", "parakeet-v3")?.value, { kind: "system", op: "volume.mute", value: true }, "`any` applies to every recognizer");
  assert.deepEqual(store.alias("Ruhe", "any")?.ref, { list: "aliases", id: "a_ruhe00001" }, "the stored phrase's politeness folds too");
  assert.deepEqual(store.alias("okay, etwas leiser bitte", "any")?.value, { kind: "system", op: "volume.step", value: -0.1 });
  // Step 2: learned app names (the disabled older "recast" binding never decides).
  assert.deepEqual(store.appName("recast", "parakeet-v3"), { ref: { list: "appNames", id: "n_8f3a2c1d" }, value: { bundleId: "com.raycast.macos", display: "Raycast" } });
  assert.deepEqual(store.appName("Recast für mich", "parakeet-v3")?.value.bundleId, "com.raycast.macos");
  assert.equal(store.appName("recast", "apple-dt/en-US"), null);
  assert.equal(store.appName("recas", "parakeet-v3"), null);
  assert.equal(store.appName("nummer", "apple-dt/de-DE")?.value.bundleId, "com.apple.Numbers", "one rejection of a rule taught once keeps it active");
  // Step 4: fixes.
  assert.deepEqual(store.fixes("apple-dt/en-US").map((fix) => fix.value), [{ heard: "clod", intended: "Claude" }]);
  assert.deepEqual(store.fixes("parakeet-v3"), []);
  // An app the host index does not list never decides.
  store.setInstalledCheck((bundleId) => bundleId !== "com.raycast.macos");
  assert.equal(store.appName("recast", "parakeet-v3"), null);
  store.setInstalledCheck(() => undefined);
  assert.ok(store.appName("recast", "parakeet-v3"), "an unknown index never hides a rule");
});

test("lookups: the recognizer's own rule wins over `any`; fixes come longest heard phrase first", () => {
  const { store } = storeAt();
  const bind = (content: Parameters<DictionaryStore["bind"]>[0], recognizer: string) => assert.ok(store.bind(content, { recognizer, source: "manual" }).ok);
  bind({ list: "aliases", phrase: "spiel musik", target: { kind: "openApp", bundleId: "com.apple.Music" } }, "any");
  bind({ list: "aliases", phrase: "spiel musik", target: { kind: "openApp", bundleId: "com.spotify.client" } }, "parakeet-v3");
  assert.equal((store.alias("spiel musik", "parakeet-v3")?.value as { bundleId: string }).bundleId, "com.spotify.client");
  assert.equal((store.alias("spiel musik", "apple-dt/de-DE")?.value as { bundleId: string }).bundleId, "com.apple.Music");
  bind({ list: "fixes", heard: "clod", intended: "Claude" }, "any");
  bind({ list: "fixes", heard: "clod code", intended: "Claude Code" }, "any");
  bind({ list: "fixes", heard: "olama", intended: "Ollama" }, "parakeet-v3");
  assert.deepEqual(store.fixes("parakeet-v3").map((fix) => fix.value.heard), ["clod code", "olama", "clod"]);
  assert.deepEqual(store.fixes("apple-dt/en-US").map((fix) => fix.value.heard), ["clod code", "clod"]);
});

test("bind: re-teaching reinforces; a new binding for the same heard phrase replaces the old one (kept disabled for Undo)", () => {
  const { store, advance } = storeAt();
  const recast = { list: "appNames" as const, heard: "recast", bundleId: "com.raycast.macos", display: "Raycast" };
  const first = store.bind(recast, { recognizer: "parakeet-v3", source: "did-you-mean" });
  assert.ok(first.ok && first.ref && first.undoToken);
  advance(1_000);
  const again = store.bind(recast, { recognizer: "parakeet-v3", source: "confirm" });
  assert.ok(again.ok);
  assert.deepEqual(again.ref, first.ref);
  assert.equal(again.code, undefined);
  assert.equal(store.entry(first.ref)?.count, 2);
  assert.equal(store.entry(first.ref)?.source, "did-you-mean", "reinforcing keeps where the rule came from");
  const other = store.bind({ ...recast, bundleId: "com.example.Recast", display: "Recast" }, { recognizer: "parakeet-v3", source: "list-pick" });
  assert.ok(other.ok && other.ref && other.undoToken);
  assert.equal(other.code, "replaced");
  assert.ok(store.entry(first.ref)?.disabledAt, "the old binding is kept, disabled");
  assert.equal(store.appName("recast", "parakeet-v3")?.value.bundleId, "com.example.Recast");
  // Undo restores exactly the previous state: the old rule decides again, the new one is gone.
  const undone = store.undo(other.undoToken);
  assert.ok(undone.ok);
  assert.equal(undone.code, "undone");
  assert.equal(store.appName("recast", "parakeet-v3")?.value.bundleId, "com.raycast.macos");
  assert.equal(store.entry(other.ref), undefined);
  assert.deepEqual(store.undo(other.undoToken), { ok: false, revision: store.revision(), code: "undo_expired" }, "single use");
});

test("undo tokens expire after 10 minutes; reject disables a rule taught once after two rejections", () => {
  const { store, advance } = storeAt();
  const outcome = store.bind({ list: "aliases", phrase: "mach musik an", target: { kind: "openApp", bundleId: "com.apple.Music" } }, { recognizer: "any", source: "did-you-mean" });
  assert.ok(outcome.ok && outcome.ref && outcome.undoToken);
  advance(DICTIONARY_LIMITS.undoTtlMs + 1);
  assert.equal(store.undo(outcome.undoToken).ok, false);
  const ref = outcome.ref;
  const once = store.reject(ref);
  assert.ok(once.ok);
  assert.equal(once.code, "rejection_recorded");
  assert.ok(store.alias("mach musik an", "any"), "one rejection keeps it");
  const twice = store.reject(ref);
  assert.ok(twice.ok);
  assert.equal(twice.code, "rule_disabled");
  assert.ok(store.entry(ref)?.disabledAt);
  assert.equal(store.alias("mach musik an", "any"), null);
  // Enabling (Settings) clears the rejections so the rule decides again.
  const enabled = store.setState(ref, "enable");
  assert.ok(enabled.ok);
  assert.equal(store.entry(ref)?.rejections, 0);
  assert.ok(store.alias("mach musik an", "any"));
});

test("caps: a full list evicts its least recently used unpinned entry (disabled first); pinned entries survive; all pinned → limit_reached", () => {
  const alias = (index: number, extra: Partial<LearnedAlias> = {}): LearnedAlias => ({
    id: `a_${index}`, phrase: `alias number ${index}`, target: { kind: "openApp", bundleId: "com.apple.Music" }, recognizer: "any", source: "manual",
    count: 1, rejections: 0, uses: 0, createdAt: new Date(NOW - (1_000 - index) * 60_000).toISOString(), ...extra,
  });
  const full = Array.from({ length: DICTIONARY_LIMITS.aliases }, (_, index) => alias(index, index === 0 ? { pinned: true } : {}));
  // a_1 is the oldest unpinned; a_7 was used recently; a_9 is disabled.
  full[7] = alias(7, { lastUsedAt: new Date(NOW).toISOString() });
  full[9] = alias(9, { disabledAt: new Date(NOW - 60_000).toISOString() });
  const { store } = storeAt({ version: 1, revision: 1, aliases: full });
  const added = store.bind({ list: "aliases", phrase: "brand new alias", target: { kind: "openApp", bundleId: "com.apple.Notes" } }, { recognizer: "any", source: "manual" });
  assert.ok(added.ok);
  let ids = store.document().aliases.map((entry) => entry.id);
  assert.equal(ids.length, DICTIONARY_LIMITS.aliases);
  assert.ok(!ids.includes("a_9"), "a disabled entry goes first");
  const again = store.bind({ list: "aliases", phrase: "another new alias", target: { kind: "openApp", bundleId: "com.apple.Notes" } }, { recognizer: "any", source: "manual" });
  assert.ok(again.ok);
  ids = store.document().aliases.map((entry) => entry.id);
  assert.ok(ids.includes("a_0") && ids.includes("a_7") && !ids.includes("a_1"), "the LRU unpinned entry goes next; pinned and recently used stay");

  const pinned = Array.from({ length: DICTIONARY_LIMITS.aliases }, (_, index) => alias(index, { pinned: true }));
  const { store: full2 } = storeAt({ version: 1, revision: 1, aliases: pinned });
  const refused = full2.bind({ list: "aliases", phrase: "brand new alias", target: { kind: "openApp", bundleId: "com.apple.Notes" } }, { recognizer: "any", source: "manual" });
  assert.deepEqual(refused, { ok: false, revision: 1, code: "limit_reached" });
});

test("file cap: every write stays within 256 KB (LRU eviction across lists)", () => {
  const url = `https://example.com/${"p".repeat(480)}`;
  const at = (index: number) => new Date(NOW - (5_000 - index) * 60_000).toISOString();
  const aliases = Array.from({ length: 199 }, (_, index) => ({
    id: `a_${index}`, phrase: `long alias phrase number ${index}`, target: { kind: "openURL", url }, recognizer: "any", source: "manual",
    count: 1, rejections: 0, uses: 0, createdAt: at(index),
  }));
  const term = (index: number) => ({
    id: `t_${index}`, text: `Term ${index} ${"w".repeat(50)}`, soundsLike: ["a", "b", "c"].map((letter) => `${letter}${index} ${"s".repeat(56)}`),
    lang: "any", kind: "word", recognizer: "any", source: "manual", count: 1, rejections: 0, uses: 0, createdAt: at(1_000 + index),
  });
  // Terms up to just under the file cap (newer than every alias), well below the 500-term list cap.
  const terms: ReturnType<typeof term>[] = [];
  while (Buffer.byteLength(JSON.stringify({ version: 1, revision: 9, aliases, terms: [...terms, term(terms.length)] })) < DICTIONARY_LIMITS.fileBytes - 200) {
    terms.push(term(terms.length));
  }
  const document = { version: 1, revision: 9, aliases, terms };
  const size = Buffer.byteLength(JSON.stringify(document));
  assert.ok(size > DICTIONARY_LIMITS.fileBytes - 1_000 && size <= DICTIONARY_LIMITS.fileBytes && terms.length <= 400, `fixture ${size} bytes, ${terms.length} terms`);
  const { store, path } = storeAt(document);
  for (let index = 0; index < 40; index++) {
    const outcome = store.bind({ list: "terms", text: `Extra ${index} ${"x".repeat(50)}`, soundsLike: [], lang: "any", kind: "word" }, { recognizer: "any", source: "manual" });
    assert.ok(outcome.ok, `write ${index}`);
    assert.ok(statSync(path).size <= DICTIONARY_LIMITS.fileBytes, `write ${index} stays within the cap`);
  }
  const ids = store.document().aliases.map((entry) => entry.id);
  assert.ok(!ids.includes("a_0"), "the least recently used entries made room");
  assert.ok(store.document().terms.some((term) => term.text.startsWith("Extra 39")));
});

test("disabled entries are kept 30 days for Undo, then purged", () => {
  const fix = (id: string, days: number) => ({
    id, heard: `heard ${id.slice(2)}`, intended: "Claude", recognizer: "any", source: "manual", count: 1, rejections: 0, uses: 0,
    createdAt: "2026-08-01T00:00:00Z", disabledAt: new Date(NOW - days * 86_400_000).toISOString(),
  });
  const { store } = storeAt({ version: 1, revision: 1, fixes: [fix("f_old", 31), fix("f_new", 29)] });
  assert.deepEqual(store.document().fixes.map((entry) => entry.id), ["f_new"]);
});

test("noteUse counts uses and lastUsedAt, written lazily with a new revision; it never throws", () => {
  const { store, path } = storeAt(VALID);
  store.noteUse({ list: "appNames", id: "n_8f3a2c1d" });
  store.noteUse({ list: "appNames", id: "missing" });
  store.noteUse({ list: "nope" as never, id: "x" });
  assert.equal(store.revision(), 42, "nothing is written per use");
  store.flush();
  assert.equal(store.revision(), 43);
  const entry = onDisk(path).appNames.find((name) => name.id === "n_8f3a2c1d")!;
  assert.equal(entry.uses, 6);
  assert.equal(entry.lastUsedAt, new Date(NOW).toISOString());
  store.flush();
  assert.equal(store.revision(), 43, "nothing pending, nothing written");
});

test("reset forgets every list, the undo history and the backup; settings stay", () => {
  const dir = tempDir();
  const path = join(dir, "dictionary.json");
  writeFileSync(path, "{ corrupt");
  const store = new DictionaryStore({ path, clock: () => NOW, log: () => {} });
  store.load();
  const learned = store.bind({ list: "fixes", heard: "clod", intended: "Claude" }, { recognizer: "any", source: "manual" });
  assert.ok(learned.ok && learned.undoToken);
  assert.ok(existsSync(`${path}.corrupt`));
  store.updateSettings({ learn: "ask" });
  const reset = store.reset();
  assert.ok(reset.ok);
  assert.equal(reset.code, "reset");
  const document = onDisk(path);
  assert.deepEqual([document.terms, document.appNames, document.aliases, document.fixes], [[], [], [], []]);
  assert.equal(document.settings.learn, "ask");
  assert.equal(existsSync(`${path}.corrupt`), false);
  assert.equal(store.undo(learned.undoToken).ok, false, "nothing forgotten comes back");
});

test("recognizer terms: pinned terms, then learned entries by uses, then frecent and installed apps; never verb-initial names or soundsLike forms", () => {
  const document = readJson(VALID) as DictionaryDocument;
  const apps = [
    { name: "Safari", bundleId: "com.apple.Safari" }, { name: "Open Design", bundleId: "com.example.opendesign" },
    { name: "Ghostty", bundleId: "com.mitchellh.ghostty" }, { name: "Find My", bundleId: "com.apple.findmy" },
    { name: "Calculator", bundleId: "com.apple.calculator" }, { name: "Raycast", bundleId: "com.raycast.macos" },
  ];
  const frecency = (bundleId: string) => (bundleId === "com.apple.calculator" ? 0.6 : bundleId === "com.apple.Safari" ? 0.2 : 0);
  const terms = rankRecognizerTerms(document, 100, { apps, frecency });
  assert.deepEqual(terms.map((term) => term.text), [
    "Ghostty", // pinned term
    "Raycast", "Claude", "Numbers", "Spotify", "DRACO", // learned app names, fix targets and terms by uses (the disabled "Recast" never)
    "Calculator", "Safari", // frecent apps
  ]);
  assert.deepEqual(terms.find((term) => term.text === "DRACO"), { text: "DRACO", lang: "en" });
  assert.ok(!terms.some((term) => /gousti|open design|find my/i.test(term.text)));
  assert.ok(parseRecognizerTerms({ revision: document.revision, terms }).ok);
  assert.deepEqual(rankRecognizerTerms(document, 3, { apps, frecency }).map((term) => term.text), ["Ghostty", "Raycast", "Claude"]);
  // With biasing off the dictionary's own entries stay out (apps still rank).
  const off = { ...document, settings: { ...document.settings, applyToRecognizer: false } };
  assert.deepEqual(rankRecognizerTerms(off, 100, { apps, frecency }).map((term) => term.text), ["Calculator", "Safari", "Ghostty", "Raycast"]);
  const { store } = storeAt(VALID);
  assert.equal(store.recognizerTerms(2).revision, 42);
});

test("explain: entries whose heard phrase occurs in the utterance, ≤ max, off with explainToAgent", () => {
  const { store } = storeAt(VALID);
  assert.deepEqual(store.explain("Open recast and ask clod", "parakeet-v3"), [{ heard: "recast", meaning: "the Raycast app (com.raycast.macos)" }]);
  assert.deepEqual(store.explain("ask clod about gousti", "apple-dt/en-US"), [{ heard: "clod", meaning: "Claude" }, { heard: "gousti", meaning: "Ghostty" }]);
  assert.deepEqual(store.explain("ask clod about gousti", "apple-dt/en-US", 1).length, 1);
  store.updateSettings({ explainToAgent: false });
  assert.deepEqual(store.explain("open recast", "parakeet-v3"), []);
});

test("phrase canonicalization and the alias guard (§6.5): 'Oben', 'Open', 'Bitte', 'Drei', 'Please' never count", () => {
  assert.equal(nameCore("Öffne mir bitte Pages für mich"), "offne mir bitte pages");
  assert.equal(nameCore("up the recast app"), "recast");
  assert.equal(utteranceCore("Okay, can you open recast please"), "open recast");
  assert.equal(utteranceCore("ich möchte bitte etwas leiser"), "etwas leiser");
  for (const word of ["Oben", "Open", "Bitte", "Drei", "Please", "ok", "ja", "the", "xy", "42"]) {
    assert.deepEqual(contentWords(utteranceCore(word)), [], word);
    assert.equal(aliasGuardPasses(word), false, word);
    assert.equal(hasContentWord(word.toLowerCase()), false, word);
  }
  assert.equal(aliasGuardPasses("Open Oben bitte"), false);
  assert.equal(aliasGuardPasses("Notion"), true, "one content word of ≥ 5 letters");
  assert.equal(aliasGuardPasses("Notion", (word) => word === "notion"), false, "…unless it is a common word");
  assert.equal(aliasGuardPasses("Zed"), false, "one short content word is not enough");
  assert.equal(aliasGuardPasses("mach musik an"), true, "two content words");
  assert.equal(aliasGuardPasses("oh then kind order"), true);
  assert.equal(displayName({ name: "Pages Creator Studio", aliases: ["Pages", "Pages Creator Studio"] }), "Pages");
  assert.equal(displayName({ name: "Raycast", aliases: ["Raycast Beta"] }), "Raycast");
});

// ---------------------------------------------------------------------------------------------
// Take memo

function record(takeId: string, at: number, extra: Partial<TakeRecord> = {}): TakeRecord {
  return { takeId, at, inputMode: "voice", hypotheses: [], decision: "fallthrough", recognizer: "any", offered: [], ...extra };
}

test("take memo: the last 20 takes for 2 minutes; latestActed finds the newest act; forget and clear", () => {
  let now = NOW;
  const memo = new InMemoryTakeMemo({ clock: () => now });
  for (let index = 0; index < 25; index++) memo.remember(record(`take-${index}`, now, index % 5 === 0 ? { decision: "act" } : {}));
  assert.equal(memo.size, 20);
  assert.equal(memo.get("take-4"), undefined, "the oldest takes were evicted");
  assert.ok(memo.get("take-5"));
  assert.equal(memo.latestActed()?.takeId, "take-20");
  memo.forget("take-20");
  assert.equal(memo.latestActed()?.takeId, "take-15");
  now += 120_001;
  assert.equal(memo.get("take-24"), undefined, "older than 2 minutes");
  assert.equal(memo.latestActed(), undefined);
  memo.remember(record("fresh", now));
  memo.clear();
  assert.equal(memo.size, 0);
});

test("take memo: a later final merges — the first voice hypotheses and the earliest time stay, offered accumulates, the rest is the latest's", () => {
  const memo = new InMemoryTakeMemo({ clock: () => NOW });
  const heard = [{ text: "open kein note", source: "apple-dt/de-DE", role: "peer" as const }];
  memo.remember(record("take-44", NOW, { hypotheses: heard, voiceHypotheses: true, decision: "list", offered: ["com.apple.Keynote", "com.apple.Notes"], heard: "kein note", recognizer: "apple-dt/de-DE" }));
  memo.remember(record("take-44", NOW + 900, {
    inputMode: "text", hypotheses: [{ text: "open Keynote", source: "any", role: "primary" }], decision: "act",
    offered: ["com.apple.Keynote", "com.apple.Pages"], acted: { kind: "openApp", bundleId: "com.apple.Keynote" },
  }));
  const merged = memo.get("take-44")!;
  assert.deepEqual(merged.hypotheses, heard);
  assert.equal(merged.at, NOW);
  assert.deepEqual(merged.offered, ["com.apple.Keynote", "com.apple.Notes", "com.apple.Pages"]);
  assert.equal(merged.decision, "act");
  assert.equal(merged.inputMode, "text");
  assert.equal(merged.heard, undefined, "the latest final's fields replace the earlier ones");
  assert.deepEqual(merged.acted, { kind: "openApp", bundleId: "com.apple.Keynote" });
});

test("takeRecordFor: list rows, act targets, voice meta and the typed text; only finals with a take id", () => {
  const request = readJson(join(fixtures, "instant", "requests", "final-hypotheses.request.json")) as InstantRequest;
  const list = readJson(join(fixtures, "instant", "list-did-you-mean.json")) as Extract<InstantResponse, { decision: "list" }>;
  const listRecord = takeRecordFor(request, list, NOW)!;
  assert.equal(listRecord.takeId, "take-42");
  assert.equal(listRecord.decision, "list");
  assert.equal(listRecord.didYouMean, true);
  assert.deepEqual(listRecord.offered, offeredBundleIds(list.card));
  assert.ok(listRecord.offered.length >= 1);
  assert.equal(listRecord.hypotheses.length, request.hypotheses!.length);
  assert.equal(listRecord.recognizer, "parakeet-v3", "voice.source decided");
  assert.equal(listRecord.heard, "recast", "voice.heard, folded");
  const act = readJson(join(fixtures, "instant", "act-learned.json")) as Extract<InstantResponse, { decision: "act" }>;
  const actRecord = takeRecordFor(request, act, NOW)!;
  assert.equal(actRecord.decision, "act");
  assert.ok(actRecord.acted);
  assert.equal(actRecord.learnedEntryId, act.voice?.learnedEntryId);
  const typed = takeRecordFor({ text: "open ray", phase: "final", seq: 1, takeId: "typed-1" }, act, NOW)!;
  assert.deepEqual(typed.hypotheses, [{ text: "open ray", source: "any", role: "primary" }]);
  assert.equal(typed.inputMode, "text");
  assert.equal(takeRecordFor({ ...request, phase: "partial" }, act, NOW), undefined);
  assert.equal(takeRecordFor({ text: "x", phase: "final", seq: 1 }, act, NOW), undefined);
  // An act a learned rule could never express (copy, files, display sleep) has no acted target.
  const sleep = { ...act, action: { type: "system", op: "display.sleep" } } as InstantResponse;
  assert.equal(takeRecordFor(request, sleep, NOW)!.acted, undefined);
});

test("take details ride beside the response and never reach the wire", () => {
  const response = { seq: 1, elapsedMs: 0, source: "grammar", decision: "fallthrough", reason: "no_match" } as InstantResponse;
  const wire = JSON.stringify(response);
  const nearMiss = { heard: "recast", candidates: [{ bundleId: "com.raycast.macos", display: "Raycast", score: 0.8 }], others: ["open we cast"] };
  attachTakeDetails(response, { heard: "recast", nearMiss });
  assert.equal(JSON.stringify(response), wire);
  assert.deepEqual(takeDetailsOf(response)?.nearMiss, nearMiss);
  const recordWithDetails = takeRecordFor({ text: "open recast", phase: "final", seq: 1, takeId: "t1", inputMode: "voice" }, response, NOW, takeDetailsOf(response));
  assert.equal(recordWithDetails?.heard, "recast");
  assert.deepEqual(recordWithDetails?.nearMiss, nearMiss);
  assert.equal(takeDetailsOf({}), undefined);
});

// ---------------------------------------------------------------------------------------------
// The regression check replays journal takes through the lane (N2)

test("regression check: each take is replayed as one hypothesis from its recognizer, with and without the rule; a missing target is not \"did not act\"", async () => {
  const { AppIndexCache } = await import("../src/instant/apps.js");
  const { createInstantDispatcher } = await import("../src/instant/dispatcher.js");
  const { createLearnLane, regressionConflicts } = await import("../src/instant/learned.js");
  const apps = [
    { bundleId: "com.apple.Safari", name: "Safari", aliases: [], path: "/Applications/Safari.app", running: false },
    { bundleId: "notion.id", name: "Notion", aliases: [], path: "/Applications/Notion.app", running: false },
  ];
  const store = new DictionaryStore({ persist: false });
  store.load();
  const lane = createLearnLane({
    dispatcher: createInstantDispatcher({ apps: new AppIndexCache(async () => ({ version: "1", apps })) }), apps: () => apps, dictionary: store,
  });
  const youtube = { list: "appNames" as const, heard: "youtube", bundleId: "com.apple.Safari", display: "Safari", recognizer: "any" };
  const takes = [
    // Acted on youtube.com (a known site name) without a recorded target: the rule would change it.
    { text: "open youtube", source: "parakeet-v3" },
    // The user kept what the rule now opens: no conflict.
    { text: "Open YouTube, please.", source: "apple-dt/en-US", target: { kind: "openApp" as const, bundleId: "com.apple.Safari" } },
    // The user kept the site: conflict.
    { text: "open youtube", source: "apple-dt/de-DE", target: { kind: "openURL" as const, url: "https://www.youtube.com/" } },
    // Untouched by the rule.
    { text: "what is 2 plus 2", source: "parakeet-v3" },
  ];
  assert.deepEqual(await regressionConflicts(youtube, takes, lane), [0, 2]);
  // A take that went to the agent and now acts is what a rule is for.
  const frobnik = { list: "appNames" as const, heard: "frobnik", bundleId: "notion.id", display: "Notion", recognizer: "any" };
  assert.deepEqual(await regressionConflicts(frobnik, [{ text: "open frobnik", source: "parakeet-v3" }], lane), []);
  // Recognizer scope: a rule for one recognizer never changes another's takes.
  assert.deepEqual(await regressionConflicts({ ...youtube, recognizer: "apple-dt/en-US" }, takes, lane), []);
  // Aliases and fixes are replayed the same way.
  const alias = { list: "aliases" as const, phrase: "mach mal youtube auf", target: { kind: "openApp" as const, bundleId: "notion.id" }, recognizer: "any" };
  assert.deepEqual(await regressionConflicts(alias, [{ text: "Mach mal YouTube auf.", source: "apple-dt/de-DE" }], lane), [0]);
  const fix = { list: "fixes" as const, heard: "you tube", intended: "Notion", recognizer: "any" };
  assert.deepEqual(await regressionConflicts(fix, [{ text: "open you tube", source: "parakeet-v3" }, { text: "open you tube", source: "parakeet-v3", target: { kind: "openApp" as const, bundleId: "notion.id" } }], lane), []);
  // The candidate rule never reaches the stored dictionary.
  assert.equal(store.revision(), 0);
});
