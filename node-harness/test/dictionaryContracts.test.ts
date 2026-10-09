import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { test } from "node:test";
import { parseHostAction } from "../src/contracts/actions.js";
import {
  CONTROL_WORDS, DEFAULT_DICTIONARY_SETTINGS, DELETION_WORDS, DICTIONARY_ISSUE_CODES, DICTIONARY_LIMITS, DICTIONARY_LISTS, DICTIONARY_ROUTES,
  DICTIONARY_WRITE_CODES, emptyDictionary, foldPhrase, isEntryActive, isFoldedPhrase, isRefusedPhrase, isTimestamp, NO_DICTIONARY,
  parseDictionary, parseEditRequest, parseLearnRequest, parseRecognizerTerms, parseRecognizerTermsMax, parseSafeTarget,
  parseWriteResponse, recognizerApplies, safeTargetToHostAction, TAKE_MEMO_LIMITS, type DictionaryDocument, type DictionaryIssue,
  type DictionaryLookup, type SafeTarget, type TakeMemo, type TakeMemoRecord,
} from "../src/contracts/dictionary.js";

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = (path: string): any => JSON.parse(readFileSync(path, "utf8"));
const jsonFiles = (dir: string): string[] => {
  const files = readdirSync(join(fixtures, dir)).filter((f) => f.endsWith(".json")).sort().map((f) => join(fixtures, dir, f));
  assert.ok(files.length > 0, dir);
  return files;
};
/** Classifies a dictionary fixture by its name; every fixture must have a parser. */
function parserFor(file: string): ((value: unknown) => { ok: boolean; error?: string; value?: unknown }) | "document" | "phrases" {
  const name = basename(file);
  if (name === "phrases.json") return "phrases";
  if (name === "valid.json" || name === "hostile.json" || name.startsWith("document-")) return "document";
  if (name.startsWith("terms-response")) return parseRecognizerTerms;
  if (name.includes("-response")) return parseWriteResponse;
  if (name.startsWith("learn-")) return parseLearnRequest;
  if (name.startsWith("edit-")) return parseEditRequest;
  throw new Error(`unclassified fixture ${name}`);
}
/** Values that appear in the fixtures; a parser error must never contain any of them. */
const ECHO = ["recast", "Raycast", "trash", "Trash", "dummy", "forget", "take 42", "Papierkorb", "lösch", "short", "always", "shortcuts", "import", "words", "üüü", "xxxxxxxx"];

test("dictionary valid.json parses to exactly its wire value, with no issues", () => {
  const body = readJson(join(fixtures, "dictionary", "valid.json"));
  const parsed = parseDictionary(body);
  assert.ok(parsed.ok);
  if (!parsed.ok) return;
  assert.deepEqual(parsed.issues, []);
  assert.deepEqual(parsed.value, body);
  // A disabled entry may share an active entry's heard phrase (kept for Undo), and is inactive.
  const recast = parsed.value.appNames.filter((entry) => entry.heard === "recast");
  assert.deepEqual(recast.map(isEntryActive), [true, false]);
});

test("dictionary hostile.json: load-time validation drops exactly the expected entries, content-free", () => {
  const body = readJson(join(fixtures, "dictionary", "hostile.json"));
  const parsed = parseDictionary(body);
  assert.ok(parsed.ok);
  if (!parsed.ok) return;
  assert.deepEqual(parsed.issues, body._expect as DictionaryIssue[]);
  for (const issue of parsed.issues) assert.ok((DICTIONARY_ISSUE_CODES as readonly string[]).includes(issue.code));
  for (const list of DICTIONARY_LISTS) assert.deepEqual(parsed.value[list].map((entry) => entry.id), body._kept[list], list);
  assert.deepEqual(parsed.value.settings, DEFAULT_DICTIONARY_SETTINGS);
  const issues = JSON.stringify(parsed.issues);
  for (const value of ECHO) assert.ok(!issues.includes(value), `issues echo ${value}`);
  // Nothing that survived can delete, reach the agent or open a file.
  for (const alias of parsed.value.aliases) {
    const action = parseHostAction(safeTargetToHostAction(alias.target));
    assert.ok(action && ["openApp", "openURL", "system"].includes(action.type));
  }
});

test("dictionary documents: a wrong overall shape fails as a whole, without echoing values", () => {
  for (const file of jsonFiles("dictionary/invalid").filter((f) => basename(f).startsWith("document-"))) {
    const parsed = parseDictionary(readJson(file));
    assert.equal(parsed.ok, false, file);
    if (!parsed.ok) assert.ok(!parsed.error.includes("42"), file);
  }
  assert.deepEqual(parseDictionary({ version: 1, revision: 0 }), { ok: true, value: emptyDictionary(), issues: [] });
  assert.deepEqual(parseDictionary({ version: 1, revision: 0, settings: null, terms: null }), { ok: true, value: emptyDictionary(), issues: [] });
});

test("dictionary caps: entries beyond a list's cap are dropped as over_limit; disabled duplicates do not count", () => {
  const alias = (i: number, extra: object = {}) => ({
    id: `a_${i}`, phrase: `alias number ${i}`, target: { kind: "openApp", bundleId: "com.apple.Music" }, recognizer: "any", source: "manual",
    count: 1, rejections: 0, uses: 0, createdAt: "2026-10-05T09:00:00Z", ...extra,
  });
  const many = Array.from({ length: DICTIONARY_LIMITS.aliases + 2 }, (_, i) => alias(i));
  const parsed = parseDictionary({ version: 1, revision: 1, aliases: many });
  assert.ok(parsed.ok);
  if (!parsed.ok) return;
  assert.equal(parsed.value.aliases.length, DICTIONARY_LIMITS.aliases);
  assert.deepEqual(parsed.issues, [{ path: "aliases[200]", code: "over_limit" }, { path: "aliases[201]", code: "over_limit" }]);
  // Same phrase and recognizer: a second active rule is a duplicate, a disabled or rejected-out one is not.
  const twice = parseDictionary({ version: 1, revision: 1, aliases: [
    alias(1, { phrase: "same" }), alias(2, { phrase: "same", disabledAt: "2026-10-06T09:00:00Z" }),
    alias(3, { phrase: "same", rejections: 2 }), alias(4, { phrase: "same", recognizer: "parakeet-v3" }), alias(5, { phrase: "same" }),
  ] });
  assert.ok(twice.ok);
  if (twice.ok) assert.deepEqual(twice.issues, [{ path: "aliases[4]", code: "duplicate_rule" }]);
});

test("dictionary phrases: folding and refused words agree with the shared cases", () => {
  const { fold, refused } = readJson(join(fixtures, "dictionary", "phrases.json"));
  for (const { input, folded } of fold) {
    assert.equal(foldPhrase(input), folded, JSON.stringify(input));
    if (folded) assert.equal(isFoldedPhrase(folded), true, folded);
  }
  for (const { input, refused: expected } of refused) assert.equal(isRefusedPhrase(input), expected, JSON.stringify(input));
  for (const word of [...DELETION_WORDS, ...CONTROL_WORDS]) assert.equal(foldPhrase(word), word, `${word} is stored folded`);
  assert.equal(isFoldedPhrase("Open Pages"), false);
  assert.equal(isFoldedPhrase("one two three four five six"), true);
  assert.equal(isFoldedPhrase("one two three four five six seven"), false);
  assert.equal(isFoldedPhrase("x".repeat(65)), false);
});

test("dictionary wire fixtures: valid messages parse to exactly their wire value; invalid ones are rejected without echoing values", () => {
  let checked = 0;
  for (const file of jsonFiles("dictionary")) {
    const parser = parserFor(file);
    if (typeof parser !== "function") continue;
    const body = readJson(file);
    const parsed = parser(body);
    assert.ok(parsed.ok, `${file}: ${parsed.error ?? ""}`);
    assert.deepEqual(parsed.value, body, file);
    checked++;
  }
  assert.ok(checked >= 25, String(checked));
  let rejected = 0;
  for (const file of jsonFiles("dictionary/invalid")) {
    const parser = parserFor(file);
    if (typeof parser !== "function") continue;
    const parsed = parser(readJson(file));
    assert.equal(parsed.ok, false, file);
    for (const value of ECHO) assert.ok(!(parsed.error ?? "").includes(value), `${file} echoes ${value}`);
    rejected++;
  }
  assert.ok(rejected >= 30, String(rejected));
});

test("dictionary edit input: phrases typed in Settings are folded, defaults are filled", () => {
  assert.deepEqual(parseEditRequest({ op: "upsert", entry: { list: "aliases", phrase: "Etwas  Leiser!", target: { kind: "system", op: "volume.mute" } } }),
    { ok: true, value: { op: "upsert", entry: { list: "aliases", phrase: "etwas leiser", target: { kind: "system", op: "volume.mute" } } } });
  assert.deepEqual(parseEditRequest({ op: "upsert", entry: { list: "terms", text: "Ghostty", soundsLike: ["Gousti"] } }),
    { ok: true, value: { op: "upsert", entry: { list: "terms", text: "Ghostty", soundsLike: ["gousti"], lang: "any", kind: "word" } } });
  assert.deepEqual(parseEditRequest({ op: "upsert", entry: { list: "appNames", heard: "Récast", bundleId: "com.raycast.macos", display: "Raycast" } }),
    { ok: true, value: { op: "upsert", entry: { list: "appNames", heard: "recast", bundleId: "com.raycast.macos", display: "Raycast" } } });
  // A heard name that is only cancel/confirm words could take over the bar's own answers.
  assert.equal(parseEditRequest({ op: "upsert", entry: { list: "appNames", heard: "Ja!", bundleId: "com.apple.Music", display: "Music" } }).ok, false);
  assert.equal(parseEditRequest({ op: "settings", settings: { applyToRecognizer: false, learn: null } }).ok, true);
});

test("safe targets: closed vocabulary with LauncherPolicy's ranges; every target is a valid host action", () => {
  const valid: SafeTarget[] = [
    { kind: "openApp", bundleId: "com.apple.Pages" },
    { kind: "openURL", url: "https://news.example.com/a?b=1" },
    { kind: "system", op: "volume.set", value: 0 },
    { kind: "system", op: "volume.set", value: 1 },
    { kind: "system", op: "volume.step", value: -1 },
    { kind: "system", op: "volume.mute" },
    { kind: "system", op: "volume.mute", value: false },
  ];
  for (const target of valid) {
    assert.deepEqual(parseSafeTarget(target), target);
    assert.deepEqual(parseHostAction(safeTargetToHostAction(target)), safeTargetToHostAction(target));
  }
  for (const bad of [
    { kind: "openApp", bundleId: "Pages" }, { kind: "openURL", url: "http://user:pw@example.com" }, { kind: "openURL", url: "ftp://example.com" },
    { kind: "openURL", url: `https://example.com/${"a".repeat(DICTIONARY_LIMITS.urlChars)}` }, { kind: "system", op: "volume.set", value: 1.01 },
    { kind: "system", op: "volume.step", value: 0 }, { kind: "system", op: "volume.step" }, { kind: "system", op: "volume.mute", value: "on" },
    { kind: "system", op: "display.sleep" }, { kind: "system", op: "appearance.toggle" }, { kind: "openFile", token: "tok_12345678" },
    { kind: "revealFile", token: "tok_12345678" }, { kind: "askAgent", prompt: "x" }, { kind: "copyText", text: "x" }, { type: "openApp", bundleId: "com.apple.Pages" },
  ]) {
    assert.equal(parseSafeTarget(bad), null, JSON.stringify(bad));
  }
});

test("dictionary lifecycle, scope, timestamps, routes and limits", () => {
  const entry = { count: 1, rejections: 0, disabledAt: undefined };
  assert.equal(isEntryActive(entry), true);
  assert.equal(isEntryActive({ ...entry, rejections: 2 }), false, "two rejections disable a rule taught once");
  assert.equal(isEntryActive({ count: 3, rejections: 2 }), true, "a rule taught three times survives two rejections");
  assert.equal(isEntryActive({ ...entry, disabledAt: "2026-10-06T09:00:00Z" }), false);
  assert.equal(recognizerApplies("any", "parakeet-v3"), true);
  assert.equal(recognizerApplies("parakeet-v3", "parakeet-v3"), true);
  assert.equal(recognizerApplies("parakeet-v3", "apple-dt/en-US"), false);
  assert.equal(recognizerApplies("parakeet-v3", "any"), false, "typed input sees only `any` entries");
  for (const value of ["2026-10-07T09:00:00Z", "2026-10-07T09:00:00.123456789+02:00", "2026-12-31T23:59:59-11:30"]) assert.equal(isTimestamp(value), true, value);
  for (const value of ["2026-13-07T09:00:00Z", "2026-10-07 09:00:00Z", "2026-10-07T24:00:00Z", "2026-10-07T09:00:00", "2026-10-07T09:00:00.Z",
    "2026-10-07T09:00:00.1234567890Z", "2026-10-07T09:00:00+2:00", "yesterday", "2026-10-07T09:00:00Z\n"]) {
    assert.equal(isTimestamp(value), false, value);
  }
  assert.deepEqual(parseRecognizerTermsMax(undefined), { ok: true, value: 100 });
  assert.deepEqual(parseRecognizerTermsMax("48"), { ok: true, value: 48 });
  for (const raw of ["0", "101", "-1", "1e2", "48.0", " 48", ""]) assert.equal(parseRecognizerTermsMax(raw).ok, false, raw);
  assert.deepEqual(DICTIONARY_ROUTES, {
    learn: "POST /dictionary/learn", get: "GET /dictionary", edit: "POST /dictionary/edit", recognizerTerms: "GET /dictionary/recognizer-terms",
  });
  assert.deepEqual([DICTIONARY_LIMITS.terms, DICTIONARY_LIMITS.appNames, DICTIONARY_LIMITS.aliases, DICTIONARY_LIMITS.fixes], [500, 300, 200, 300]);
  assert.deepEqual([DICTIONARY_LIMITS.fileBytes, DICTIONARY_LIMITS.learnBodyBytes, DICTIONARY_LIMITS.bodyBytes], [262_144, 16_384, 4_096]);
  assert.deepEqual([DICTIONARY_LIMITS.phraseWords, DICTIONARY_LIMITS.phraseChars, DICTIONARY_LIMITS.recognizerTerms], [6, 64, 100]);
  assert.deepEqual(TAKE_MEMO_LIMITS, { maxTakes: 20, ttlMs: 120_000 });
  assert.deepEqual(DEFAULT_DICTIONARY_SETTINGS, { learn: "picks", applyToRecognizer: true, explainToAgent: true });
  for (const code of DICTIONARY_WRITE_CODES) assert.match(code, /^[a-z][a-z0-9_]{0,63}$/);
});

test("DictionaryLookup and TakeMemo: the no-op lookup learns nothing; the memo interface is implementable", () => {
  const lookup: DictionaryLookup = NO_DICTIONARY;
  assert.equal(lookup.alias("mach kein note auf", "apple-dt/de-DE"), null);
  assert.equal(lookup.appName("recast", "parakeet-v3"), null);
  assert.deepEqual(lookup.fixes("apple-dt/en-US"), []);
  assert.equal(lookup.settings().learn, "off");
  assert.doesNotThrow(() => lookup.noteUse({ list: "aliases", id: "a_1" }));
  // A minimal reference memo pins the documented merge rule for takeId reuse.
  const records = new Map<string, TakeMemoRecord>();
  const memo: TakeMemo = {
    remember(record) {
      const old = records.get(record.takeId);
      records.delete(record.takeId);
      records.set(record.takeId, old ? {
        ...record, at: old.at, hypotheses: old.hypotheses.length ? old.hypotheses : record.hypotheses,
        offered: [...new Set([...old.offered, ...record.offered])],
      } : record);
      while (records.size > TAKE_MEMO_LIMITS.maxTakes) records.delete(records.keys().next().value!);
    },
    get(takeId, now = Date.now()) {
      const record = records.get(takeId);
      return record && now - record.at <= TAKE_MEMO_LIMITS.ttlMs ? record : undefined;
    },
    latestActed(now = Date.now()) {
      return [...records.values()].reverse().find((record) => record.acted && now - record.at <= TAKE_MEMO_LIMITS.ttlMs);
    },
    forget(takeId) { records.delete(takeId); },
  };
  const hypotheses = [{ text: "open recast", source: "parakeet-v3", role: "primary" as const }];
  memo.remember({ takeId: "take-42", at: 1_000, inputMode: "voice", hypotheses, decision: "list", recognizer: "parakeet-v3", heard: "recast", offered: ["com.raycast.macos"] });
  memo.remember({ takeId: "take-42", at: 5_000, inputMode: "text", hypotheses: [], decision: "act", recognizer: "any", offered: ["com.apple.Keynote"],
    acted: { kind: "openApp", bundleId: "com.apple.Keynote" } });
  const merged = memo.get("take-42", 6_000);
  assert.deepEqual(merged?.hypotheses, hypotheses);
  assert.deepEqual(merged?.offered, ["com.raycast.macos", "com.apple.Keynote"]);
  assert.equal(merged?.at, 1_000);
  assert.equal(memo.latestActed(6_000)?.takeId, "take-42");
  assert.equal(memo.get("take-42", 1_000 + TAKE_MEMO_LIMITS.ttlMs + 1), undefined);
});

test("explicit null on optional learn members is absent (Swift decodeIfPresent parity)", () => {
  const n = readJson(join(fixtures, "null-optional-members.json"));
  assert.deepEqual(parseLearnRequest(n.learnRequest.wire), { ok: true, value: n.learnRequest.normalized });
  const document: DictionaryDocument = emptyDictionary();
  assert.deepEqual(parseDictionary({ ...document, terms: [{
    id: "t_1", text: "DRACO", soundsLike: null, lang: "en", kind: "word", bundleId: null, recognizer: "any", source: "manual", count: 1,
    rejections: 0, uses: 0, createdAt: "2026-10-05T09:00:00Z", lastUsedAt: null, disabledAt: null, pinned: null,
  }] }), { ok: true, issues: [], value: { ...document, terms: [{
    id: "t_1", text: "DRACO", soundsLike: [], lang: "en", kind: "word", recognizer: "any", source: "manual", count: 1, rejections: 0, uses: 0,
    createdAt: "2026-10-05T09:00:00Z",
  }] } });
});
