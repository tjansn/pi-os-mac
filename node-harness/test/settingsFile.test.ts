import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { readJsonObjectFile, SettingsFile, writeJsonFileAtomic } from "../src/settingsFile.js";

function tempPath(name = "settings.json"): string {
  return join(mkdtempSync(join(tmpdir(), "pi-os-settings-file-")), name);
}

const quiet = () => {};

test("missing, empty, corrupt and non-object files read as empty with a status", () => {
  const path = tempPath();
  assert.deepEqual(readJsonObjectFile(path), { data: {}, status: "missing" });
  for (const content of ["", "{not json", "[1,2]", "42", "null"]) {
    writeFileSync(path, content);
    const result = readJsonObjectFile(path);
    assert.deepEqual(result.data, {}, content);
    assert.equal(result.status, "corrupt", content);
  }
  writeFileSync(path, JSON.stringify({ model: { provider: "p" } }));
  assert.deepEqual(readJsonObjectFile(path), { data: { model: { provider: "p" } }, status: "ok" });
});

test("update rewrites one key and preserves sibling and unknown keys exactly", () => {
  const path = tempPath();
  const original = { model: { provider: "openai-codex", modelId: "gpt-6-luna", thinkingLevel: "off" }, futureKey: { nested: [1, "two", null] }, flag: true };
  writeFileSync(path, JSON.stringify(original));
  const file = new SettingsFile(path, quiet);
  file.update("routing", { bias: "speed" });
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), { ...original, routing: { bias: "speed" } });
  file.update("routing", (current: unknown) => ({ ...(current as object), maxAutoTier: "standard" }));
  assert.deepEqual(file.get("routing"), { bias: "speed", maxAutoTier: "standard" });
  file.update("routing", undefined);
  assert.deepEqual(file.read(), original, "undefined removes only that key");
});

test("two stores sharing the file never clobber each other (read-modify-write against disk)", () => {
  const path = tempPath();
  const a = new SettingsFile(path, quiet), b = new SettingsFile(path, quiet);
  a.update("model", { provider: "x", modelId: "y", thinkingLevel: "low" });
  b.update("routing", { bias: "quality" });
  a.update("model", { provider: "x", modelId: "z", thinkingLevel: "low" });
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), {
    model: { provider: "x", modelId: "z", thinkingLevel: "low" }, routing: { bias: "quality" },
  });
});

test("atomic write leaves no temp file, creates the directory and uses owner-only permissions", () => {
  const dir = join(mkdtempSync(join(tmpdir(), "pi-os-settings-file-")), "nested", "pi-os");
  const path = join(dir, "settings.json");
  new SettingsFile(path, quiet).update("routing", { bias: "balanced" });
  assert.deepEqual(readdirSync(dir), ["settings.json"]);
  assert.match(readFileSync(path, "utf8"), /\n$/);
  if (process.platform !== "win32") {
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.equal(statSync(dir).mode & 0o777, 0o700);
  }
});

test("a corrupt file is kept as .corrupt before the first rewrite", () => {
  const path = tempPath();
  writeFileSync(path, "{\"model\": {\"provider\": \"hand-edited\"");
  const lines: string[] = [];
  new SettingsFile(path, line => lines.push(line)).update("routing", { bias: "speed" });
  assert.equal(readFileSync(`${path}.corrupt`, "utf8"), "{\"model\": {\"provider\": \"hand-edited\"");
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), { routing: { bias: "speed" } });
  assert.equal(lines.length, 1);
  assert.doesNotMatch(lines[0]!, /\//, "log names the file, not its directory");
});

test("a failed write throws and leaves the previous file (all keys) untouched", () => {
  const path = tempPath();
  const original = JSON.stringify({ model: { provider: "keep" }, other: 1 });
  writeFileSync(path, original);
  // Occupy the temp path with a directory so the temp file cannot be opened.
  mkdirSync(`${path}.${process.pid}.tmp`);
  assert.throws(() => new SettingsFile(path, quiet).update("routing", { bias: "speed" }));
  assert.equal(readFileSync(path, "utf8"), original);
});

test("an unreadable settings path is never replaced", () => {
  const path = tempPath();
  mkdirSync(path); // EISDIR on read: nothing to back up, so refuse instead of dropping it
  assert.equal(readJsonObjectFile(path).status, "corrupt");
  assert.throws(() => new SettingsFile(path, quiet).update("routing", {}), /settings_unreadable/);
  assert.ok(statSync(path).isDirectory());
});

test("writeJsonFileAtomic replaces content in place (rename over the old file)", () => {
  const path = tempPath("routing-stats.json");
  writeJsonFileAtomic(path, { version: 1, a: 1 });
  writeJsonFileAtomic(path, { version: 1, b: 2 });
  assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), { version: 1, b: 2 });
  assert.equal(existsSync(`${path}.${process.pid}.tmp`), false);
});
