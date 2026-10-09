import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { parseHostAction } from "../src/contracts/actions.js";
import { bindingToHostAction, buildCard, type CardSpec, ui } from "../src/contracts/cards.js";

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures");
const readJson = (path: string): unknown => JSON.parse(readFileSync(path, "utf8"));
const jsonFiles = (dir: string): string[] => readdirSync(join(fixtures, dir)).filter((f) => f.endsWith(".json")).map((f) => join(fixtures, dir, f));

test("host actions: closed vocabulary, http(s) only, host tokens only", () => {
  assert.deepEqual(parseHostAction({ type: "openURL", url: "https://example.com/a?b=1", extra: true }), { type: "openURL", url: "https://example.com/a?b=1" });
  assert.equal(parseHostAction({ type: "openURL", url: "file:///etc/passwd" }), null);
  assert.equal(parseHostAction({ type: "openURL", url: "javascript:alert(1)" }), null);
  // Values WHATWG would silently repair (and Swift's URL(string:) may reject) never bind.
  for (const url of ["https://example.com/a b", "https:\\example.com\\x", "https://example.com/\tx", "https://exa\u200bmple.com/", " https://example.com/"]) {
    assert.equal(parseHostAction({ type: "openURL", url }), null, JSON.stringify(url));
  }
  assert.equal(parseHostAction({ type: "deleteFile", token: "tok_12345678" }), null);
  assert.equal(parseHostAction({ type: "moveToTrash", token: "tok_12345678" }), null);
  assert.equal(parseHostAction({ type: "system", op: "power.restart" }), null);
  assert.equal(parseHostAction({ type: "openFile", token: "../../etc" }), null);
  assert.equal(parseHostAction({ type: "openApp", bundleId: "Figma" }), null);
  assert.deepEqual(parseHostAction({ type: "system", op: "volume.set", value: 0.3 }), { type: "system", op: "volume.set", value: 0.3 });
  assert.equal(parseHostAction({ type: "copyText", text: "x".repeat(4_001) }), null);
});

test("buildCard flattens deterministically and binds actions as json-render bindings", () => {
  const make = () => buildCard(ui.answer({ summary: "2 + 2 = 4" }, [ui.result({ kind: "math", value: "4" }, { type: "copyText", text: "4" })]));
  const a = make();
  assert.deepEqual(a, make());
  assert.equal(a.root, "root");
  assert.deepEqual(a.elements.root?.children, ["n1"]);
  assert.deepEqual(a.elements.n1?.on?.copy, { action: "copyText", params: { text: "4" } });
});

test("every binding in the shared valid card fixtures is a valid host action", () => {
  for (const file of jsonFiles("cards")) {
    const card = readJson(file) as CardSpec;
    assert.equal(card.format, "pi-os-ui/1", file);
    for (const element of Object.values(card.elements)) {
      for (const binding of Object.values(element.on ?? {})) {
        assert.notEqual(bindingToHostAction(binding), null, `${file}: ${JSON.stringify(binding)}`);
      }
    }
  }
  const bad = readJson(join(fixtures, "cards", "invalid", "bad-url-scheme.json")) as CardSpec;
  assert.equal(bindingToHostAction(bad.elements.n1!.on!.primary!), null);
  const deletion = readJson(join(fixtures, "cards", "invalid", "delete-action.json")) as CardSpec;
  assert.equal(bindingToHostAction(deletion.elements.n1!.on!.primary!), null);
});

test("instant fixtures carry valid actions and cards", () => {
  for (const file of jsonFiles("instant")) {
    const response = readJson(file) as { decision: string; action?: unknown; card?: CardSpec };
    if (response.decision === "act") assert.notEqual(parseHostAction(response.action), null, file);
    if (["answer", "list", "refuse"].includes(response.decision)) assert.equal(response.card?.format, "pi-os-ui/1", file);
  }
});
