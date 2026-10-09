import assert from "node:assert/strict";
import { test } from "node:test";
import type { FileCandidate } from "../src/contracts/launcher.js";
import { buildFileSearchRequest } from "../src/instant/files/query.js";
import { isExcludedPath, nameScore, rankFiles } from "../src/instant/files/rank.js";

// Candidates as in the verified research prototype (scratchpad/bench/rank-proto.mjs); fixture paths only.
const NOW = Date.UTC(2026, 9, 2, 17, 30);
const d = (iso: string) => Date.parse(iso);
const H = "/Users/fixture";
let tokens = 0;
const file = (path: string, extra: Partial<FileCandidate> = {}): FileCandidate => ({
  token: `tok_${String(++tokens).padStart(8, "0")}`, path, name: path.split("/").pop()!, isDirectory: false, isPackage: false, ...extra,
});
const CANDIDATES: FileCandidate[] = [
  file(`${H}/Documents/Finance/Invoice-2026-03-Acme.pdf`, { modifiedMs: d("2026-03-14"), createdMs: d("2026-03-14"), contentType: "com.adobe.pdf" }),
  file(`${H}/Documents/Finance/Invoice-2026-09-Acme.pdf`, { modifiedMs: d("2026-09-14"), createdMs: d("2026-09-14"), contentType: "com.adobe.pdf" }),
  file(`${H}/Downloads/Rechnung_März_Telekom.pdf`, { modifiedMs: d("2026-03-20"), createdMs: d("2026-03-20"), contentType: "com.adobe.pdf" }),
  file(`${H}/dev/app/node_modules/invoice-lib/README.md`, { modifiedMs: d("2026-03-10") }),
  file(`${H}/dev/app/node_modules/invoice-lib/invoice.js`, { modifiedMs: d("2026-03-10") }),
  file(`${H}/.Trash/invoice-old.pdf`, { modifiedMs: d("2026-03-02"), contentType: "com.adobe.pdf" }),
  file(`${H}/Library/Caches/com.x/invoice.tmp`, { modifiedMs: d("2026-03-05") }),
  file(`${H}/Desktop/myinvoices2026.numbers`, { modifiedMs: d("2026-03-29"), lastUsedMs: d("2026-09-30"), useCount: 12 }),
];
const MARCH = { fromMs: Date.UTC(2026, 2, 1), toMs: Date.UTC(2026, 3, 1) };
const names = (files: { name: string }[]) => files.map((f) => f.name);

test("invoice + March: the March invoice first, bilingual synonym included, September filtered by date", () => {
  const ranked = rankFiles(CANDIDATES, { terms: ["invoice"], range: MARCH }, NOW);
  assert.equal(ranked.relaxed, false);
  assert.deepEqual(names(ranked.files), ["Invoice-2026-03-Acme.pdf", "Rechnung_März_Telekom.pdf", "myinvoices2026.numbers"]);
});

test("rechnung + March ranks the Telekom file first", () => {
  assert.equal(rankFiles(CANDIDATES, { terms: ["rechnung"], range: MARCH }, NOW).files[0]?.name, "Rechnung_März_Telekom.pdf");
});

test("node_modules, .Trash and ~/Library are never returned; hidden paths and bundle internals neither", () => {
  const all = names(rankFiles(CANDIDATES, { terms: ["invoice"] }, NOW).files);
  for (const excluded of ["invoice.js", "README.md", "invoice-old.pdf", "invoice.tmp"]) assert.ok(!all.includes(excluded), excluded);
  assert.equal(isExcludedPath(`${H}/.Trash/x.pdf`), true);
  assert.equal(isExcludedPath("/Volumes/USB/.Trashes/501/x.pdf"), true);
  assert.equal(isExcludedPath(`${H}/.config/invoice.txt`), true);
  assert.equal(isExcludedPath(`${H}/Applications/Foo.app/Contents/invoice.plist`), true);
  assert.equal(isExcludedPath(`${H}/Library/Mobile Documents/com~apple~CloudDocs/Invoice.pdf`), false);
  assert.equal(isExcludedPath(`${H}/Documents/Library/Invoice.pdf`), false);
});

test("an empty date range relaxes to all name hits", () => {
  const ranked = rankFiles(CANDIDATES, { terms: ["invoice"], range: { fromMs: Date.UTC(2025, 0, 1), toMs: Date.UTC(2025, 1, 1) } }, NOW);
  assert.equal(ranked.relaxed, true);
  assert.ok(ranked.files.length >= 3);
});

test("kind matches boost, recency breaks ties, any missing term drops the file", () => {
  assert.equal(nameScore(["invoice"], "Invoice.pdf"), 1);
  assert.equal(nameScore(["invoice"], "Invoice-2026.pdf"), 0.9);
  assert.equal(nameScore(["acme", "invoice"], "Invoice-2026-03-Acme.pdf"), 0.8);
  assert.ok(Math.abs(nameScore(["invoice"], "Rechnung_März.pdf") - 0.6) < 1e-9);
  assert.ok(Math.abs(nameScore(["präsentation"], "Presentation Q3.key") - 0.6) < 1e-9);
  assert.equal(nameScore(["invoice", "telekom"], "Invoice-Acme.pdf"), 0);
  const folder = file(`${H}/Documents/Invoices`, { isDirectory: true, modifiedMs: d("2026-01-01") });
  const pdf = file(`${H}/Documents/Invoices.pdf`, { contentType: "com.adobe.pdf", modifiedMs: d("2026-01-01") });
  assert.equal(rankFiles([pdf, folder], { terms: ["invoices"], contentType: "public.folder" }, NOW).files[0]?.name, "Invoices");
  const old = file(`${H}/Documents/report.pdf`, { modifiedMs: d("2025-01-01") });
  const fresh = file(`${H}/Documents/report.pdf`, { modifiedMs: d("2026-09-30") });
  assert.equal(rankFiles([old, fresh], { terms: ["report"] }, NOW).files[0]?.token, fresh.token);
});

test("500 candidates rank in well under 5 ms", () => {
  const big = Array.from({ length: 500 }, (_, i) => ({ ...CANDIDATES[i % CANDIDATES.length]!, path: `${CANDIDATES[i % CANDIDATES.length]!.path}${i}` }));
  for (let i = 0; i < 20; i++) rankFiles(big, { terms: ["invoice"], range: MARCH }, NOW);
  const started = performance.now();
  for (let i = 0; i < 50; i++) rankFiles(big, { terms: ["invoice"], range: MARCH }, NOW);
  const perRun = (performance.now() - started) / 50;
  assert.ok(perRun < 5, `${perRun.toFixed(3)} ms per ranking`);
});

test("FileSearchRequest: OR of AND-groups widened with synonyms, ≤ 6 terms, home scope", () => {
  assert.deepEqual(buildFileSearchRequest({ terms: ["invoice"], label: "invoice", contentType: "com.adobe.pdf" }, { contextId: "ctx-3f2a" }), {
    contextId: "ctx-3f2a", nameGroups: [["invoice"], ["rechnung"]], contentType: "com.adobe.pdf", scopes: ["home"], maxResults: 100,
  });
  assert.deepEqual(buildFileSearchRequest({ terms: ["resume"], label: "resume" }).nameGroups, [["resume"], ["cv"], ["lebenslauf"]]);
  const wide = buildFileSearchRequest({ terms: ["invoice", "receipt", "acme"], label: "" });
  assert.ok(wide.nameGroups.flat().length <= 6);
  assert.deepEqual(wide.nameGroups[0], ["invoice", "receipt", "acme"]);
  assert.equal(buildFileSearchRequest({ terms: ["x"], label: "x" }, { maxResults: 5_000 }).maxResults, 200);
});
