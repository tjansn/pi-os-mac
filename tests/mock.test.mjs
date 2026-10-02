import { test } from "node:test";
import assert from "node:assert/strict";
import { examples, mockReply } from "../public/mock.js";
const run = (example, prompt, text = examples[example].text, turn = 1) =>
  mockReply({ example, prompt, text, turn });

for (const [id, example] of Object.entries(examples)) {
  for (const prompt of example.prompts)
    test(`${id}: ${prompt}`, () => {
      const a = run(id, prompt);
      assert.equal(a.kind, "answer");
      assert.deepEqual(a, run(id, prompt));
      assert.ok(a.blocks.length);
    });
}
test("summary extracts edited document, not canned original text", () => {
  assert.deepEqual(
    run(
      "notes",
      "Summarize this",
      "A new line.\r\nAnother line.\n\nThird.\nFourth.",
    ).blocks[1].items,
    ["A new line.", "Another line.", "Third."],
  );
});
test("shortening is disclosed and returns only the first three non-empty lines", () => {
  const a = run("mail", "make it shorter", "one\n\ntwo\nthree\nfour");
  assert.equal(a.patch, "one\ntwo\nthree");
  assert.match(a.blocks[0].text, /not an AI rewrite/);
});
test("checklist produces a text-only patch", () => {
  assert.equal(
    run("notes", "make a checklist", "Saturday\nCoffee\nWalk\nSunday\nMuseum")
      .patch,
    "☐ Coffee\n☐ Walk\n☐ Museum",
  );
});
test("empty documents return useful honest output without mutation", () => {
  assert.equal(run("notes", "shorten", "").patch, null);
  assert.match(run("notes", "summary", "").blocks[1].items[0], /empty/);
  assert.equal(run("notes", "checklist", "").patch, null);
});
test("arbitrary request is explicitly unsupported, including follow-ups", () => {
  const a = run("notes", "Who won the race in 2028?", "", 2);
  assert.equal(a.kind, "unsupported");
  assert.equal(a.patch, null);
  assert.match(a.title, /Still a scripted demo/);
});
for (const prompt of [
  "delete all files",
  "empty trash",
  "get my password",
  "rm -rf anything",
])
  test(`safe refusal: ${prompt}`, () => {
    assert.equal(run("notes", prompt).kind, "refusal");
    assert.equal(run("notes", prompt).patch, null);
  });
test("real account actions are not simulated as having occurred", () => {
  assert.match(
    run("mail", "send this email").blocks[0].text,
    /nothing is sent/,
  );
});
test("code and email templates disclose they are fixed examples", () => {
  assert.match(
    run("code", "add types", "arbitrary changed code").blocks[0].text,
    /fixed/,
  );
  assert.match(
    run("mail", "make it friendlier", "arbitrary changed mail").blocks[0].text,
    /fixed/,
  );
});
test("user markup remains plain text data", () => {
  const payload = '<img src=x onerror="alert(1)">';
  assert.equal(run("notes", "summary", payload).blocks[1].items[0], payload);
});
