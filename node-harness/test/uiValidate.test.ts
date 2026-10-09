import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { HOST_ACTION_TYPES, MODEL_CARD_ACTION_TYPES } from "../src/contracts/actions.js";
import { buildCard, CARD_COMPONENTS, CARD_EVENTS, type CardSpec, ui } from "../src/contracts/cards.js";
import { CARD_MAX_BYTES, CARD_MAX_ELEMENTS, cardCatalog } from "../src/ui/catalog.js";
import { validateCard, type CardIssueCode, type CardValidation } from "../src/ui/validate.js";

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = (path: string): any => JSON.parse(readFileSync(path, "utf8"));
const jsonFiles = (dir: string): string[] => readdirSync(join(fixtures, dir)).filter(f => f.endsWith(".json")).map(f => join(fixtures, dir, f));
const strict = (card: unknown, extra: object = {}) => validateCard(card, { mode: "strict", ...extra });
const lenient = (card: unknown, extra: object = {}) => validateCard(card, { mode: "lenient", ...extra });
const codes = (result: CardValidation): CardIssueCode[] => (result.ok ? result.dropped : result.issues).map(issue => issue.code);
const clone = <T>(value: T): T => structuredClone(value);
/** Root Answer with the given children (keys n1…), for compact structural cases. */
function card(elements: Record<string, unknown>, rootChildren = Object.keys(elements)): any {
  return { format: "pi-os-ui/1", root: "root", elements: { root: { type: "Answer", props: {}, children: rootChildren }, ...elements } };
}
const tokens = { hasToken: (token: string) => ["tok_3fa8c2d1e9b0", "tok_9be0a7c4d2f1", "tok_51d0e3b8a6c7"].includes(token) };

test("catalog: json-render core catalog mirrors the seeded component/event/action vocabulary", () => {
  assert.deepEqual(cardCatalog.componentNames, [...CARD_COMPONENTS]);
  assert.deepEqual(cardCatalog.actionNames, [...HOST_ACTION_TYPES]);
  for (const name of CARD_COMPONENTS) assert.deepEqual(cardCatalog.data.components[name]?.events, [...CARD_EVENTS[name]], name);
  assert(!cardCatalog.actionNames.some(name => /delete|trash|move|rename|write/i.test(name)));
});

test("catalog: prompt is the compact pi-os template, never json-render's sample-data defaults", () => {
  const prompt = cardCatalog.prompt();
  assert(prompt.length < 2_500, `prompt too long: ${prompt.length}`);
  for (const name of CARD_COMPONENTS) assert.match(prompt, new RegExp(`^- ${name} `, "m"));
  assert.match(prompt, /never invent/i);
  assert.doesNotMatch(prompt, /realistic|sample data|JSONL|SpecStream/i);
});

test("every shared valid card fixture passes strict validation unchanged (and json-render core agrees)", () => {
  const files = jsonFiles("cards");
  assert(files.length >= 6);
  for (const file of files) {
    const fixture = readJson(file);
    const result = strict(fixture);
    assert(result.ok, `${file}: ${JSON.stringify(!result.ok && result.issues)}`);
    assert.deepEqual(result.spec, fixture, file);
    assert.equal(cardCatalog.validate(fixture).success, true, file);
    // File cards also pass when the thread's ledger holds their host tokens.
    assert(strict(fixture, { ledger: tokens }).ok, file);
  }
});

test("every instant fixture card passes strict validation", () => {
  for (const file of jsonFiles("instant")) {
    const response = readJson(file);
    if (response.card) assert(strict(response.card).ok, file);
  }
});

test("every shared invalid card fixture fails with a meaningful issue", () => {
  const expected: Record<string, CardIssueCode> = {
    "bad-url-scheme.json": "invalid_binding",
    "delete-action.json": "unknown_action",
    "dollar-expression.json": "dynamic_expression",
    "missing-child.json": "missing_child",
    "unknown-component.json": "unknown_component",
    "wrong-format.json": "invalid_format",
  };
  const files = jsonFiles("cards/invalid");
  assert(files.length >= Object.keys(expected).length);
  for (const file of files) {
    const result = strict(readJson(file));
    assert(!result.ok, file);
    assert(result.issues.length > 0 && result.issues.every(issue => issue.message.length > 0 && issue.path !== undefined), file);
    const name = file.split("/").pop()!;
    if (expected[name]) assert(codes(result).includes(expected[name]), `${name}: ${JSON.stringify(result.issues)}`);
  }
});

test("per-element props are checked even though core's propsOf is lenient (F33)", () => {
  const bad = card({ n1: { type: "Markdown", props: { value: 5 } } });
  assert.equal(cardCatalog.validate(bad).success, true, "core alone accepts wrong props");
  assert.deepEqual(codes(strict(bad)), ["invalid_props"]);
  const cases: [string, unknown][] = [
    ["ResultCard", { kind: "weather", value: "51" }],
    ["ResultCard", { kind: "math", value: "" }],
    ["Markdown", { source: "x".repeat(4_001) }],
    ["Item", { title: "x", detail: "y".repeat(41) }],
    ["Item", { title: "x", icon: { kind: "folder" } }],
    ["Status", { state: "done", text: "ok", progress: 1.5 }],
    ["Suggestion", { prompt: "x".repeat(161) }],
    ["KeyValue", { items: [] }],
    ["Table", { columns: [], rows: [] }],
    ["Table", { columns: [{ key: "a", label: "A" }], rows: [{ b: "x" }] }],
    ["Table", { columns: [{ key: "a", label: "A" }, { key: "a", label: "B" }], rows: [] }],
    ["Table", { columns: [{ key: "a", label: "A" }], rows: [{ a: { nested: true } }] }],
    ["Table", { columns: [{ key: "__proto__", label: "P" }], rows: [] }],
    ["Notice", { tone: "info", text: "ok", extra: true }],
    ["ItemList", { total: -1 }],
  ];
  for (const [type, props] of cases) {
    const element = type === "Item" ? { n1: { type: "ItemList", props: {}, children: ["n2"] }, n2: { type, props } } : { n1: { type, props } };
    const result = strict(card(element, ["n1"]));
    assert(codes(result).includes("invalid_props"), `${type} ${JSON.stringify(props)}: ${JSON.stringify(result)}`);
  }
});

test("dynamic json-render features are rejected anywhere in the card", () => {
  const base = readJson(join(fixtures, "cards", "rich-answer.json"));
  const mutations: [string, (spec: any) => void][] = [
    ["visible", spec => { spec.elements.n1.visible = true; }],
    ["repeat", spec => { spec.elements.n1.repeat = { statePath: "/rows" }; }],
    ["watch", spec => { spec.elements.n1.watch = {}; }],
    ["slots", spec => { spec.elements.root.slots = { default: ["n1"] }; }],
    ["state", spec => { spec.state = { secret: 1 }; }],
    ["$cond in table cell", spec => { spec.elements.n3.props.rows[0].price = { $cond: true, $then: "a", $else: "b" }; }],
    ["$state in binding params", spec => { spec.elements.n6.on.primary.params = { url: { $state: "/u" } }; }],
    ["confirm on binding", spec => { spec.elements.n6.on.primary.confirm = { title: "Sure?", message: "?" }; }],
  ];
  for (const [label, mutate] of mutations) {
    const spec = clone(base);
    mutate(spec);
    const result = strict(spec);
    assert(!result.ok, label);
    assert(result.issues.some(issue => ["dynamic_expression", "invalid_binding", "invalid_props"].includes(issue.code)), `${label}: ${JSON.stringify(result.issues)}`);
  }
  assert.deepEqual(codes(strict((() => { const spec = clone(base); spec.state = {}; return spec; })())), ["dynamic_expression"]);
});

test("tree integrity: root, missing/shared/cyclic children, container rules, orphans, keys", () => {
  const md = (source = "ok") => ({ type: "Markdown", props: { source } });
  const cases: [string, any, CardIssueCode][] = [
    ["missing root", { ...card({ n1: md() }), root: "nope" }, "missing_root"],
    ["root not Answer", { format: "pi-os-ui/1", root: "n1", elements: { n1: md() } }, "invalid_root"],
    ["shared child", card({ n1: md() }, ["n1", "n1"]), "shared_child"],
    ["cycle", card({ n1: { type: "ItemList", props: {}, children: ["root"] } }, ["n1"]), "cycle"],
    ["ItemList holds only Items", card({ n1: { type: "ItemList", props: {}, children: ["n2"] }, n2: md() }, ["n1"]), "invalid_child"],
    ["leaf with children", card({ n1: { ...md(), children: ["n2"] }, n2: md() }, ["n1"]), "invalid_child"],
    ["nested Answer", card({ n1: { type: "Answer", props: {} } }), "invalid_child"],
    ["orphan", card({ n1: md(), n2: md() }, ["n1"]), "orphan"],
    ["prototype key is not an element", card({ n1: md() }, ["n1", "constructor"]), "missing_child"],
    ["bad element key", card({ "__proto__x": md() }, []), "invalid_key"],
    ["children not strings", card({ n1: { ...md(), children: [1] } }, ["n1"]), "invalid_shape"],
    ["unknown element field", card({ n1: { ...md(), style: "red" } }), "unsupported_field"],
  ];
  for (const [label, spec, code] of cases) {
    const result = strict(spec);
    assert(!result.ok, label);
    assert(codes(result).includes(code), `${label}: ${JSON.stringify(result.issues)}`);
  }
  for (const bad of [null, [], "card", { format: "pi-os-ui/1", root: "root", elements: [] }]) assert(!strict(bad).ok);
});

test("limits: at most 150 elements and 64 KB per card", () => {
  const many = Object.fromEntries(Array.from({ length: CARD_MAX_ELEMENTS }, (_, i) => [`n${i}`, { type: "Markdown", props: { source: "x" } }]));
  assert(codes(strict(card(many))).includes("too_many_elements"));
  assert(strict(card(Object.fromEntries(Object.entries(many).slice(0, CARD_MAX_ELEMENTS - 1)))).ok);
  const big = Object.fromEntries(Array.from({ length: 20 }, (_, i) => [`n${i}`, { type: "Markdown", props: { source: "y".repeat(4_000) } }]));
  assert(Buffer.byteLength(JSON.stringify(card(big))) > CARD_MAX_BYTES);
  assert.deepEqual(codes(strict(card(big))), ["too_large"]);
});

test("bindings: declared events only, fixed actions per event, allowed actions, ledger tokens", () => {
  const result = (on: unknown, element = "ResultCard") => card({
    n1: element === "ResultCard" ? { type: "ResultCard", props: { kind: "math", value: "4" }, on }
      : element === "Suggestion" ? { type: "Suggestion", props: { prompt: "Convert to USD" }, on }
        : { type: "ItemList", props: {}, children: ["n2"] },
    ...(element === "Item" ? { n2: { type: "Item", props: { title: "x" }, on } } : {}),
  }, ["n1"]);
  const cases: [string, any, CardIssueCode][] = [
    ["undeclared event", result({ primary: { action: "copyText", params: { text: "4" } } }), "unknown_event"],
    ["copy must copy", result({ copy: { action: "openURL", params: { url: "https://example.com" } } }), "invalid_binding"],
    ["extra binding key", result({ copy: { action: "copyText", params: { text: "4" }, onSuccess: { set: {} } } }), "invalid_binding"],
    ["extra params key", result({ copy: { action: "copyText", params: { text: "4", token: "tok_3fa8c2d1e9b0" } } }), "invalid_binding"],
    ["missing params", result({ copy: { action: "copyText" } }), "invalid_binding"],
    ["oversized copy text", result({ copy: { action: "copyText", params: { text: "x".repeat(4_001) } } }), "invalid_binding"],
    ["suggestion asks something else", result({ press: { action: "askAgent", params: { prompt: "Delete my files" } } }, "Suggestion"), "invalid_binding"],
    ["typeIntoPinned is instant-only", result({ primary: { action: "typeIntoPinned", params: { text: "hi" } } }, "Item"), "action_not_allowed"],
    ["system is instant-only", result({ primary: { action: "system", params: { op: "volume.mute" } } }, "Item"), "action_not_allowed"],
    ["bad bundle id", result({ primary: { action: "openApp", params: { bundleId: "Figma" } } }, "Item"), "invalid_binding"],
    ["path-like token", result({ primary: { action: "openFile", params: { token: "../../etc/passwd" } } }, "Item"), "invalid_binding"],
    ["trash action", result({ primary: { action: "moveToTrash", params: { token: "tok_3fa8c2d1e9b0" } } }, "Item"), "unknown_action"],
  ];
  for (const [label, spec, code] of cases) {
    const checked = strict(spec);
    assert(!checked.ok, label);
    assert(codes(checked).includes(code), `${label}: ${JSON.stringify(checked.issues)}`);
  }
  const system = result({ primary: { action: "system", params: { op: "volume.set", value: 0.3 } } }, "Item");
  assert(strict(system, { allowedActions: HOST_ACTION_TYPES }).ok, "callers may widen the allowed set (instant cards)");
  assert(!strict(result({ copy: { action: "copyText", params: { text: "4" } } }), { allowedActions: ["openURL"] }).ok);

  const files = readJson(join(fixtures, "cards", "file-list.json"));
  assert.deepEqual([...new Set(codes(strict(files, { ledger: { hasToken: () => false } })))], ["unknown_file_token"]);
  assert(strict(files, { allowedActions: MODEL_CARD_ACTION_TYPES, ledger: tokens }).ok);
});

test("issue messages name locations, never card content", () => {
  const secret = "SECRET-TRANSCRIPT-4711";
  const spec = card({
    n1: { type: "Markdown", props: { source: `${secret} `.repeat(400) } },
    n2: { type: "ResultCard", props: { kind: "math", value: "1" }, on: { copy: { action: "openURL", params: { url: `javascript:${secret}` } } } },
    n3: { type: "Item", props: { title: secret, detail: secret.repeat(3) } },
    n4: { type: "Table", props: { columns: [{ key: "a", label: secret }], rows: [{ a: secret, [secret]: 1 }] } },
    n5: { type: "Suggestion", props: { prompt: "ok" }, on: { press: { action: "askAgent", params: { prompt: secret } } } },
    n6: { type: "Markdown", props: { source: { [`$${secret}`]: 1 } } },
    // Content in object keys: unknown props, row keys, binding params, nested expressions.
    n7: { type: "Notice", props: { tone: "info", text: "ok", [secret]: 1, freshness: 2 } },
    n8: { type: "Table", props: { columns: [{ key: "a", label: "A" }], rows: [{ [secret]: { nested: true } }] } },
    n9: { type: "ResultCard", props: { kind: "math", value: "1" }, on: { copy: { action: "copyText", params: { text: "1", [secret]: 1 } } } },
    n10: { type: "Table", props: { columns: [{ key: "a", label: "A" }], rows: [{ [secret]: { $state: "/x" } }] } },
  });
  const checked = strict(spec);
  assert(!checked.ok);
  assert.equal(new Set(checked.issues.map(issue => issue.path.split(".")[1])).size, 10, JSON.stringify(checked.issues));
  assert(!JSON.stringify(checked.issues).includes(secret), JSON.stringify(checked.issues));
  // Declared field names stay visible so the author can still fix the card.
  assert(checked.issues.some(issue => issue.message.includes("Table: rows.0.…")), JSON.stringify(checked.issues));
  assert(checked.issues.some(issue => issue.path === "elements.n10.props.rows.0.….$state"), JSON.stringify(checked.issues));
});

test("lenient mode drops what is invalid, keeps the rest, and still refuses unusable cards", () => {
  const spec = card({
    n1: { type: "Markdown", props: { source: "kept" } },
    n2: { type: "WebView", props: {} },
    n3: { type: "ResultCard", props: { kind: "math", value: "4" }, on: { copy: { action: "copyText", params: { text: "4" } }, primary: { action: "copyText", params: { text: "4" } } } },
    n4: { type: "ItemList", props: {}, children: ["n5", "n6", "ghost"] },
    n5: { type: "Item", props: { title: "file" }, on: { primary: { action: "openFile", params: { token: "tok_3fa8c2d1e9b0" } }, secondary: { action: "openURL", params: { url: "file:///etc" } } } },
    n6: { type: "Markdown", props: { source: "not an item" } },
    n7: { type: "Markdown", props: { source: "orphan" } },
  }, ["n1", "n2", "n3", "n4", "n1"]);
  const result = lenient(spec, { ledger: tokens });
  assert(result.ok);
  assert.deepEqual(Object.keys(result.spec.elements), ["root", "n1", "n3", "n4", "n5"]);
  assert.deepEqual(result.spec.elements.root!.children, ["n1", "n3", "n4"]);
  assert.deepEqual(Object.keys(result.spec.elements.n3!.on!), ["copy"]);
  assert.deepEqual(Object.keys(result.spec.elements.n5!.on!), ["primary"]);
  assert.deepEqual(result.spec.elements.n4!.children, ["n5"]);
  assert.deepEqual(new Set(codes(result)), new Set(["unknown_component", "unknown_event", "invalid_binding", "invalid_child", "missing_child", "shared_child", "orphan"]));
  assert(strict(result.spec, { ledger: tokens }).ok, "lenient output is itself strictly valid");

  const many = Object.fromEntries(Array.from({ length: 200 }, (_, i) => [`n${i}`, { type: "Markdown", props: { source: `m${i}` } }]));
  const trimmed = lenient(card(many));
  assert(trimmed.ok);
  assert.equal(Object.keys(trimmed.spec.elements).length, CARD_MAX_ELEMENTS);
  assert.equal(trimmed.spec.elements.root!.children!.at(-1), `n${CARD_MAX_ELEMENTS - 2}`);
  const big = Object.fromEntries(Array.from({ length: 20 }, (_, i) => [`n${i}`, { type: "Markdown", props: { source: "y".repeat(4_000) } }]));
  const shrunk = lenient(card(big));
  assert(shrunk.ok && codes(shrunk).includes("too_large"));
  assert(Buffer.byteLength(JSON.stringify(shrunk.spec)) <= CARD_MAX_BYTES);
  assert(strict(shrunk.spec).ok);

  for (const bad of [{ ...spec, format: "pi-os-ui/2" }, { ...spec, root: "missing" }, { format: "pi-os-ui/1", root: "n1", elements: { n1: { type: "Markdown", props: { source: "x" } } } }]) {
    assert(!lenient(bad).ok);
  }
});

test("builder cards from contracts/cards.ts validate strictly", () => {
  const spec: CardSpec = buildCard(ui.answer({ summary: "Done" }, [
    ui.markdown("Hello **there**"),
    ui.result({ kind: "conversion", input: "5 km in mi", value: "3.11 mi" }, { type: "copyText", text: "3.11" }),
    ui.keyValue({ items: [{ key: "a", value: "b" }] }),
    ui.itemList({ title: "Apps" }, [ui.item({ title: "Figma", icon: { kind: "app", bundleId: "com.figma.Desktop" } }, { primary: { type: "openApp", bundleId: "com.figma.Desktop" } })]),
    ui.notice("warning", "Rates are a day old"),
    ui.status({ state: "running", text: "Searching", progress: 0.5 }),
    ui.suggestion("Convert to USD"),
  ]));
  const result = strict(spec);
  assert(result.ok, JSON.stringify(!result.ok && result.issues));
});
