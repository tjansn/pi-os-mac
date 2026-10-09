import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { buildCard, type CardSpec, ui } from "../src/contracts/cards.js";
import { cardToText } from "../src/ui/text.js";

const fixture = (name: string): CardSpec => JSON.parse(readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "cards", name), "utf8"));

test("cardToText renders every shared card fixture deterministically", () => {
  const expected: Record<string, string> = {
    "calc-result.json": "15% of 340 = 51",
    "currency-result.json": "100 USD in EUR = 85.93 EUR\n1 USD = 0.8593 EUR\nECB reference rate 2026-10-01 · info only",
    "file-list.json": [
      "Files matching “invoice”",
      "- Invoice-2026-03.pdf — ~/Documents/Finance · Mar 14",
      "- invoice_march_acme.pdf — ~/Downloads · Mar 2",
      "- Invoices 2025.numbers — ~/Documents/Finance · Jan 8",
    ].join("\n"),
    "app-list.json": "Applications\n- Figma — /Applications/Figma.app\n- FigJam — /Applications/FigJam.app",
    "refuse-delete.json": "pi-os never deletes files, moves them to the Trash or empties the Trash.",
    "rich-answer.json": [
      "Here are the **two** cheapest options I found on the page.",
      "",
      "Best option\n- Airline: Lufthansa\n- Price: €214",
      "",
      "All options\n| Airline | Price | Stops |\n| --- | ---: | ---: |\n| Lufthansa | €214 | 0 |\n| Eurowings | €189 | 1 |",
      "",
      "Done: Compared 2 results",
      "",
      "- lufthansa.com — https://www.lufthansa.com/de/en/homepage",
    ].join("\n"),
  };
  for (const [name, text] of Object.entries(expected)) {
    assert.equal(cardToText(fixture(name)), text, name);
    assert.equal(cardToText(fixture(name)), cardToText(structuredClone(fixture(name))), name);
  }
});

test("cardToText: summary fallback, omitted suggestions, list grouping, totals and escaping", () => {
  assert.equal(cardToText(buildCard(ui.answer({ summary: "Nothing to show" }, [ui.suggestion("Try again")]))), "Nothing to show");
  assert.equal(cardToText(buildCard(ui.answer({}, []))), "");
  const items = buildCard(ui.answer({ summary: "ignored when blocks render" }, [
    ui.item({ title: "a", subtitle: "https://a.example" }),
    ui.item({ title: "b" }),
    ui.markdown("between"),
    ui.itemList({ total: 42 }, [ui.item({ title: "c", detail: "Mar 2" })]),
    ui.result({ kind: "time", input: "Time in Tokyo", value: "03:12" }),
    ui.result({ kind: "math", value: "4" }),
    ui.status({ state: "running", text: "Searching", progress: 0.42 }),
    ui.notice("warning", "Line one\nline two"),
  ]));
  assert.equal(cardToText(items), [
    "- a — https://a.example\n- b",
    "between",
    "Results (showing 1 of 42)\n- c · Mar 2",
    "Time in Tokyo: 03:12",
    "4",
    "Running: Searching (42%)",
    "Line one line two",
  ].join("\n\n"));
  const table = buildCard(ui.answer({}, [ui.table({
    columns: [{ key: "a", label: "A|B" }, { key: "n", label: "N", align: "center" }],
    rows: [{ a: "x|y\nz", n: 1.5 }, { a: null }],
  })]));
  assert.equal(cardToText(table), "| A\\|B | N |\n| --- | :---: |\n| x\\|y z | 1.5 |\n|  |  |");
});

test("cardToText tolerates unvalidated input (cycles, unknown types, missing root)", () => {
  const cyclic = {
    format: "pi-os-ui/1", root: "root",
    elements: {
      root: { type: "Answer", props: {}, children: ["l", "l", "x", "missing"] },
      l: { type: "ItemList", props: { title: "Loop" }, children: ["root", "i", "i"] },
      i: { type: "Item", props: { title: "once" } },
      x: { type: "WebView", props: { url: "https://example.com" } },
    },
  } as unknown as CardSpec;
  assert.equal(cardToText(cyclic), "Loop\n- once");
  assert.equal(cardToText({ ...cyclic, root: "nope" }), "");
  assert.equal(cardToText({ ...cyclic, root: "constructor" }), "");
});
