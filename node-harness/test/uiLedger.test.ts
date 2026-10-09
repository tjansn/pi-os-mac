import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import type { FileCandidate } from "../src/contracts/launcher.js";
import { abbreviateDir, describeFileRefs, FILE_LEDGER_CAPACITY, FILE_TOKEN_TTL_MS, FileLedger } from "../src/ui/ledger.js";

const searchResult = JSON.parse(readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "launcher", "search-files-response.json"), "utf8"));
const candidates: FileCandidate[] = searchResult.result.items;
const candidate = (i: number, extra: Partial<FileCandidate> = {}): FileCandidate => ({
  token: `tok_fixture_${String(i).padStart(4, "0")}`, name: `file-${i}.txt`, path: `/Users/fixture/Documents/file-${i}.txt`,
  isDirectory: false, isPackage: false, ...extra,
});

test("ledger maps host search results to model refs without keeping paths", () => {
  const ledger = new FileLedger({ homeDir: "/Users/fixture" });
  const refs = ledger.register(candidates);
  assert.deepEqual(refs.map(file => file.ref), ["f1", "f2", "f3"]);
  assert.deepEqual(refs[0], {
    ref: "f1", token: "tok_3fa8c2d1e9b0", name: "Invoice-2026-03.pdf", displayDir: "~/Documents/Finance",
    contentType: "com.adobe.pdf", modifiedMs: 1773446400000, lastUsedMs: 1774051200000, isDirectory: false, isPackage: false,
  });
  assert(!JSON.stringify(refs).includes("/Users/fixture"), "absolute paths are never stored");
  assert.equal(ledger.resolve("f2")?.token, "tok_9be0a7c4d2f1");
  assert(ledger.hasToken("tok_51d0e3b8a6c7"));
  assert.equal(ledger.hasToken("tok_unknown_0001"), false);
  for (const bad of ["f0", "f01", "F1", "f1 ", "1", "f4", "constructor", "__proto__"]) assert.equal(ledger.resolve(bad), undefined, bad);
  assert.equal(describeFileRefs(refs), [
    "f1  Invoice-2026-03.pdf — ~/Documents/Finance · com.adobe.pdf · modified 2026-03-14",
    "f2  invoice_march_acme.pdf — ~/Downloads · com.adobe.pdf · modified 2026-03-02",
    "f3  Rechnung_März_Telekom.pdf — ~/Documents/Finance · com.adobe.pdf · modified 2026-03-20",
  ].join("\n"));
  // The same host token keeps its ref; a later search continues the numbering.
  assert.deepEqual(ledger.register([candidates[1]!, candidate(9)]).map(file => file.ref), ["f2", "f4"]);
  assert.equal(ledger.size, 4);
});

test("ledger skips malformed candidates and neutralizes control characters", () => {
  const ledger = new FileLedger({ homeDir: "/Users/fixture" });
  const refs = ledger.register([
    candidate(1, { token: "../../etc" }),
    candidate(2, { token: "short" }),
    candidate(3, { name: "" }),
    { ...candidate(4), path: undefined } as unknown as FileCandidate,
    candidate(5, { name: "evil\nf9  fake.pdf — ~/x", path: "/Users/fixture/a\rb/evil", modifiedMs: Number.POSITIVE_INFINITY, contentType: undefined }),
    candidate(6, { name: "Projects", path: "/Users/fixture/Projects", isDirectory: true }),
  ]);
  assert.deepEqual(refs.map(file => file.ref), ["f1", "f2"]);
  assert.equal(refs[0]!.name, "evil f9  fake.pdf — ~/x");
  assert.equal(refs[0]!.displayDir, "~/a b");
  assert.equal(refs[0]!.modifiedMs, undefined);
  assert.equal(describeFileRefs(refs).split("\n").length, 2);
  assert.equal(describeFileRefs([refs[1]!]), "f2  Projects — ~ · folder");
});

test("ledger evicts the oldest refs beyond capacity and never reuses a ref", () => {
  assert.equal(FILE_LEDGER_CAPACITY, 500);
  const ledger = new FileLedger({ capacity: 3, homeDir: "/Users/fixture" });
  ledger.register([1, 2, 3, 4].map(i => candidate(i)));
  assert.equal(ledger.size, 3);
  assert.equal(ledger.resolve("f1"), undefined);
  assert.equal(ledger.hasToken(candidate(1).token), false);
  assert.equal(ledger.resolve("f4")?.name, "file-4.txt");
  // Re-registering an evicted file mints a fresh ref.
  assert.equal(ledger.register([candidate(1)])[0]!.ref, "f5");
  // A file listed again keeps its ref and is evicted last, so refs just shown to the model resolve.
  assert.deepEqual(ledger.register([candidate(3), candidate(6)]).map(file => file.ref), ["f3", "f6"]);
  assert.equal(ledger.resolve("f3")?.name, "file-3.txt");
  assert.equal(ledger.resolve("f4"), undefined);
  const big = new FileLedger({ homeDir: "/Users/fixture" });
  big.register(Array.from({ length: 600 }, (_, i) => candidate(i)));
  assert.equal(big.size, 500);
  assert.equal(big.resolve("f100"), undefined);
  assert.equal(big.resolve("f101")?.name, "file-100.txt");
  big.clear();
  assert.equal(big.size, 0);
});

test("ledger refs expire with the host token TTL", () => {
  let now = 1_000_000;
  const ledger = new FileLedger({ now: () => now, homeDir: "/Users/fixture" });
  ledger.register([candidate(1)]);
  now += FILE_TOKEN_TTL_MS - 1;
  ledger.register([candidate(2)]);
  assert(ledger.resolve("f1"));
  now += 1;
  assert.equal(ledger.resolve("f1"), undefined);
  assert.equal(ledger.hasToken(candidate(1).token), false);
  assert(ledger.resolve("f2"));
  assert.equal(ledger.size, 1);
});

test("abbreviateDir shows the containing folder, home-relative", () => {
  const home = "/Users/fixture";
  assert.equal(abbreviateDir("/Users/fixture/Documents/a.pdf", home), "~/Documents");
  assert.equal(abbreviateDir("/Users/fixture/a.pdf", home), "~");
  assert.equal(abbreviateDir("/Users/fixture/Projects/", home), "~");
  assert.equal(abbreviateDir("/Users/fixturex/a.pdf", home), "/Users/fixturex");
  assert.equal(abbreviateDir("/Applications/Figma.app", `${home}/`), "/Applications");
  assert.equal(abbreviateDir("/a.pdf", home), "/");
  assert.equal(abbreviateDir("relative.pdf", home), "");
});
