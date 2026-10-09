import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { parseStreamingJson } from "@earendil-works/pi-ai";
import type { CardElement, CardSpec } from "../src/contracts/cards.js";
import type { FileCandidate } from "../src/contracts/launcher.js";
import { blocksToCard, defaultFormatDate, fileItemElement, partialBlocksToCard } from "../src/ui/blocks.js";
import { FileLedger } from "../src/ui/ledger.js";
import { cardToText } from "../src/ui/text.js";
import { validateCard, type CardValidation } from "../src/ui/validate.js";

const searchResult = JSON.parse(readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "launcher", "search-files-response.json"), "utf8"));
const extra = (i: number): FileCandidate => ({ token: `tok_extra_${String(i).padStart(4, "0")}`, name: `notes-${i}.md`, path: `/Users/fixture/Notes/notes-${i}.md`, isDirectory: false, isPackage: false });
/** Fixture ledger: f1–f3 from the shared search fixture, f4–f12 extra notes. */
function fixtureLedger(options: ConstructorParameters<typeof FileLedger>[0] = {}): FileLedger {
  const ledger = new FileLedger({ homeDir: "/Users/fixture", ...options });
  ledger.register(searchResult.result.items);
  ledger.register(Array.from({ length: 9 }, (_, i) => extra(i + 4)));
  return ledger;
}
const formatDate = (ms: number) => new Date(ms).toISOString().slice(5, 10);
const ok = (result: CardValidation): CardSpec => {
  assert(result.ok, JSON.stringify(!result.ok && result.issues));
  return result.spec;
};
const issuePaths = (result: CardValidation) => (result.ok ? [] : result.issues.map(issue => issue.path));

const everyBlock = {
  summary: "Invoices and totals",
  blocks: [
    { type: "markdown", text: "Found **3** invoices in your documents." },
    { type: "result", kind: "currency", input: "Sum", value: "€214.00", detail: "3 invoices" },
    { type: "keyValue", title: "Latest", items: [{ key: "Vendor", value: "Telekom" }, { key: "Due", value: "Apr 1" }] },
    { type: "table", title: "Totals", columns: ["Vendor", "Amount"], rows: [["Telekom", "€89.90"], ["ACME", "€124.10"]] },
    { type: "files", title: "Invoices", refs: ["f1", "f12"] },
    { type: "links", links: [{ title: "Telekom billing", url: "https://www.telekom.de/rechnung" }, { title: "", url: "https://acme.example/invoices" }] },
    { type: "status", state: "done", text: "Checked 3 files" },
    { type: "notice", tone: "warning", text: "One invoice is a scan" },
    { type: "suggestions", prompts: ["Open the newest invoice", "Sum by vendor"] },
  ],
};

test("blocksToCard maps every block type onto a strictly valid card with Node-made bindings", () => {
  const ledger = fixtureLedger();
  const spec = ok(blocksToCard(everyBlock, ledger, { formatDate }));
  assert.deepEqual(spec.elements.root, {
    type: "Answer", props: { summary: "Invoices and totals" },
    children: ["b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8-0", "b8-1"],
  });
  assert.deepEqual(spec.elements.b1, {
    type: "ResultCard", props: { kind: "currency", input: "Sum", value: "€214.00", detail: "3 invoices" },
    on: { copy: { action: "copyText", params: { text: "€214.00" } } },
  });
  assert.deepEqual(spec.elements.b3!.props.columns, [{ key: "c0", label: "Vendor" }, { key: "c1", label: "Amount", align: "right" }]);
  assert.deepEqual(spec.elements.b3!.props.rows, [{ c0: "Telekom", c1: "€89.90" }, { c0: "ACME", c1: "€124.10" }]);
  assert.deepEqual(spec.elements.b4, { type: "ItemList", props: { title: "Invoices" }, children: ["b4-0", "b4-1"] });
  assert.deepEqual(spec.elements["b4-0"], {
    type: "Item",
    props: { title: "Invoice-2026-03.pdf", subtitle: "~/Documents/Finance", icon: { kind: "file", uti: "com.adobe.pdf" }, detail: "03-14" },
    on: {
      primary: { action: "openFile", params: { token: "tok_3fa8c2d1e9b0" } },
      secondary: { action: "revealFile", params: { token: "tok_3fa8c2d1e9b0" } },
      tertiary: { action: "copyPath", params: { token: "tok_3fa8c2d1e9b0" } },
    },
  });
  assert.equal(spec.elements["b4-1"]!.props.title, "notes-12.md");
  assert.deepEqual(spec.elements["b5-1"], {
    type: "Item", props: { title: "acme.example", subtitle: "https://acme.example/invoices", icon: { kind: "url" } },
    on: { primary: { action: "openURL", params: { url: "https://acme.example/invoices" } }, secondary: { action: "copyText", params: { text: "https://acme.example/invoices" } } },
  });
  assert.deepEqual(spec.elements["b8-1"], { type: "Suggestion", props: { prompt: "Sum by vendor" }, on: { press: { action: "askAgent", params: { prompt: "Sum by vendor" } } } });
  assert.deepEqual(spec.elements.b7, { type: "Notice", props: { tone: "warning", text: "One invoice is a scan" } });
  assert(!JSON.stringify(spec).includes("/Users/fixture"), "cards carry ~-folders, never absolute paths");
  assert(validateCard(spec, { mode: "strict", ledger }).ok);
  assert.equal(cardToText(spec).split("\n\n")[0], "Found **3** invoices in your documents.");
  assert.match(cardToText(spec), /^Invoices\n- Invoice-2026-03\.pdf — ~\/Documents\/Finance · 03-14\n- notes-12\.md — ~\/Notes$/m);
});

test("blocksToCard treats strict-sampling nulls as absent and applies defaults", () => {
  const nulls = { text: null, title: null, kind: null, input: null, value: null, detail: null, items: null, columns: null, rows: null, refs: null, links: null, state: null, tone: null, prompts: null };
  const spec = ok(blocksToCard({ summary: null, blocks: [
    { ...nulls, type: "result", value: "42" },
    { ...nulls, type: "status", text: "Working" },
    { ...nulls, type: "notice", text: "Heads up" },
    { ...nulls, type: "markdown", text: "plain" },
  ] }, fixtureLedger()));
  assert.deepEqual(spec.elements.root!.props, {});
  assert.deepEqual(spec.elements.b0!.props, { kind: "fact", value: "42" });
  assert.deepEqual(spec.elements.b1!.props, { state: "done", text: "Working" });
  assert.deepEqual(spec.elements.b2!.props, { tone: "info", text: "Heads up" });
});

test("blocksToCard rejects invented files, bad fields and oversize cards with block-level paths", () => {
  let now = 0;
  const ledger = fixtureLedger({ now: () => now });
  const cases: [string, unknown, string][] = [
    ["unknown ref", { blocks: [{ type: "files", refs: ["f1", "f99"] }] }, "blocks[0].refs[1]"],
    ["token instead of ref", { blocks: [{ type: "files", refs: ["tok_3fa8c2d1e9b0"] }] }, "blocks[0].refs[0]"],
    ["path instead of ref", { blocks: [{ type: "files", refs: ["/Users/fixture/Documents/Finance/Invoice-2026-03.pdf"] }] }, "blocks[0].refs[0]"],
    ["result without value", { blocks: [{ type: "result", input: "2+2" }] }, "blocks[0].value"],
    ["empty markdown", { blocks: [{ type: "markdown", text: "" }] }, "blocks[0].props"],
    ["status text too long", { blocks: [{ type: "markdown", text: "ok" }, { type: "status", text: "x".repeat(201) }] }, "blocks[1].props"],
    ["summary too long", { summary: "x".repeat(201), blocks: [{ type: "markdown", text: "ok" }] }, "summary"],
    ["too many blocks", { blocks: Array.from({ length: 13 }, () => ({ type: "markdown", text: "ok" })) }, "blocks"],
    ["no blocks", { blocks: [] }, "blocks"],
    ["unknown block type", { blocks: [{ type: "html", text: "<b>x</b>" }] }, "blocks[0].type"],
    ["javascript link", { blocks: [{ type: "links", links: [{ title: "x", url: "javascript:alert(1)" }] }] }, "blocks[0].links[0].url"],
    ["file link", { blocks: [{ type: "links", links: [{ title: "x", url: "file:///etc/passwd" }] }] }, "blocks[0].links[0].url"],
    ["row longer than columns", { blocks: [{ type: "table", columns: ["a"], rows: [["1", "2"]] }] }, "blocks[0].rows[0]"],
    ["seven columns", { blocks: [{ type: "table", columns: ["1", "2", "3", "4", "5", "6", "7"], rows: [] }] }, "blocks[0].columns"],
    ["five suggestions", { blocks: [{ type: "suggestions", prompts: ["a", "b", "c", "d", "e"] }] }, "blocks[0].prompts"],
    ["suggestion too long", { blocks: [{ type: "suggestions", prompts: ["x".repeat(161)] }] }, "blocks[0] entry 0.props"],
    ["keyValue without items", { blocks: [{ type: "keyValue", items: [] }] }, "blocks[0].items"],
    ["not an object", "blocks", "blocks"],
  ];
  for (const [label, params, path] of cases) {
    const result = blocksToCard(params, ledger);
    assert(!result.ok, label);
    assert(issuePaths(result).includes(path), `${label}: ${JSON.stringify(result.issues)}`);
  }
  const unknown = blocksToCard({ blocks: [{ type: "files", refs: ["f7"] }] }, ledger);
  now += 10 * 60_000;
  const expired = blocksToCard({ blocks: [{ type: "files", refs: ["f7"] }] }, ledger);
  assert(unknown.ok && !expired.ok && expired.issues[0]!.code === "unknown_file_ref");

  const many = new FileLedger({ homeDir: "/Users/fixture" });
  many.register(Array.from({ length: 200 }, (_, i) => extra(i)));
  const refs = (from: number) => Array.from({ length: 50 }, (_, i) => `f${from + i}`);
  const crowded = blocksToCard({ blocks: [1, 51, 101, 151].map(from => ({ type: "files", refs: refs(from) })) }, many);
  assert(!crowded.ok && crowded.issues.some(issue => issue.code === "too_many_elements"));
});

test("partialBlocksToCard streams settled content only, with stable keys", () => {
  const ledger = fixtureLedger();
  const json = JSON.stringify(everyBlock);
  const final = ok(blocksToCard(everyBlock, ledger, { formatDate }));
  let previous = 0;
  let sawPartialProse = false;
  let renders = 0;
  for (let end = 0; end <= json.length; end++) {
    const partial = partialBlocksToCard(parseStreamingJson(json.slice(0, end)), ledger, { formatDate });
    if (!partial) { assert.equal(previous, 0, `a card vanished at ${end}`); continue; }
    renders++;
    assert(validateCard(partial, { mode: "strict", ledger }).ok, `partial at ${end} is strictly valid`);
    assert.deepEqual(partial.elements.root!.props, {}, "summary waits for the final card");
    const keys = Object.keys(partial.elements);
    assert(keys.length >= previous, `elements never disappear (at ${end})`);
    previous = keys.length;
    for (const key of keys) {
      const shown: CardElement = partial.elements[key]!;
      const done: CardElement | undefined = final.elements[key];
      assert(done, `key ${key} at ${end} exists in the final card`);
      assert.equal(shown.type, done.type);
      if (key === "root") {
        assert.deepEqual((done.children ?? []).slice(0, shown.children?.length ?? 0), shown.children ?? [], `root children at ${end}`);
      } else if (shown.type === "Markdown") {
        assert(String(done.props.source).startsWith(String(shown.props.source)));
        if (shown.props.source !== done.props.source) sawPartialProse = true;
      } else if (shown.type === "KeyValue" || shown.type === "Table") {
        // Lists grow entry by entry; every entry shown is already final.
        const list = shown.type === "KeyValue" ? "items" : "rows";
        const entries = shown.props[list] as unknown[];
        // Numeric right-alignment may settle once rows arrive; keys and labels never change.
        const shape = (props: Record<string, unknown>) => ({ ...props, [list]: [],
          ...(props.columns ? { columns: (props.columns as { key: string; label: string }[]).map(({ key, label }) => ({ key, label })) } : {}) });
        assert.deepEqual(shape(shown.props), shape(done.props), `${key} at ${end}`);
        assert.deepEqual((done.props[list] as unknown[]).slice(0, entries.length), entries, `${key} at ${end}`);
      } else {
        // Values, file rows, links and buttons are never shown half-written.
        assert.deepEqual(shown.props, done.props, `${key} at ${end}`);
        assert.deepEqual(shown.on, done.on, `${key} at ${end}`);
        assert.deepEqual((done.children ?? []).slice(0, shown.children?.length ?? 0), shown.children ?? [], `${key} children at ${end}`);
      }
    }
  }
  assert(sawPartialProse, "markdown prose renders while it streams");
  assert(renders > 100);
  // The open last block holds back its final entry until the call completes.
  const full = partialBlocksToCard(parseStreamingJson(json), ledger, { formatDate })!;
  assert.deepEqual(full.elements.root!.children, ["b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8-0"]);
});

test("partialBlocksToCard returns null until something is renderable and drops unknown refs", () => {
  const ledger = fixtureLedger();
  for (const empty of [undefined, null, "x", {}, { blocks: [] }, { blocks: [{ type: "result", value: "5" }] }, { blocks: [{ type: "files", refs: ["f1"] }] }, { blocks: [{ type: "mark" }] }]) {
    assert.equal(partialBlocksToCard(empty, ledger), null, JSON.stringify(empty));
  }
  const partial = partialBlocksToCard({ blocks: [{ type: "files", refs: ["f99", "f2", "f3"] }, { type: "markdown", text: "x" }] }, ledger);
  assert.deepEqual(partial?.elements.b0?.children, ["b0-1", "b0-2"]);
  const tooLong = partialBlocksToCard({ blocks: [{ type: "status", text: "x".repeat(300) }, { type: "markdown", text: "still here" }] }, ledger);
  assert.deepEqual(tooLong?.elements.root?.children, ["b1"]);
});

test("file rows: default date format, folder icons and clipping", () => {
  const march = Date.UTC(2026, 2, 14, 12);
  assert.equal(defaultFormatDate(march, Date.UTC(2026, 9, 2)), "Mar 14");
  assert.equal(defaultFormatDate(march, Date.UTC(2027, 0, 5)), "Mar 14, 2026");
  const ledger = new FileLedger({ homeDir: "/Users/fixture" });
  const [long, folder] = ledger.register([
    { token: "tok_long_00001", name: `${"a".repeat(250)}.pdf`, path: `/Users/fixture/${"d".repeat(1_100)}/x.pdf`, isDirectory: false, isPackage: false },
    { token: "tok_folder_0001", name: "Projects", path: "/Users/fixture/Projects", isDirectory: true, isPackage: false },
  ]);
  const item = fileItemElement(long!);
  assert.equal(String(item.props.title).length, 200);
  assert.match(String(item.props.title), /…a+\.pdf$/);
  assert.equal(String(item.props.subtitle).length, 1_024);
  assert.equal(item.props.detail, undefined);
  assert.deepEqual(fileItemElement(folder!).props.icon, { kind: "file", uti: "public.folder" });
  assert.equal(fileItemElement({ ...folder!, modifiedMs: march }, { formatDate: () => "x".repeat(60) }).props.detail, `${"x".repeat(39)}…`);
});
