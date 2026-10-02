import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
const root = resolve(import.meta.dirname, "../public");
const html = readFileSync(resolve(root, "index.html"), "utf8");
const code = ["demo.js", "mock.js"]
  .map((file) => readFileSync(resolve(root, file), "utf8"))
  .join("\n");

test("CSP prohibits network APIs, frames, workers and form navigation", () => {
  for (const directive of [
    "connect-src",
    "frame-src",
    "worker-src",
    "form-action",
    "object-src",
  ])
    assert.ok(html.includes(`${directive} 'none'`));
  assert.ok(html.includes("script-src 'self'"));
});
test("no inference, bridge, tracking, text persistence or code execution", () => {
  assert.doesNotMatch(
    code,
    /\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|eval|Function|localStorage|sessionStorage|indexedDB|sendBeacon)\s*[.(]/,
  );
  assert.doesNotMatch(code, /\.innerHTML\s*=|execCommand|clipboard\.read/);
});
test("all HTML IDs are unique, labels and fragment links resolve", () => {
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  assert.equal(ids.length, new Set(ids).size);
  for (const match of html.matchAll(
    /(?:for|aria-controls)="([^"]+)"|href="#([^"]+)"/g,
  ))
    assert.ok(ids.includes(match[1] ?? match[2]), `missing ${match[0]}`);
});
test("assets resolve from GitHub project subpath; no third-party assets", () => {
  for (const match of html.matchAll(/(?:src|href)="(\.\/[^"#]+)"/g))
    assert.ok(existsSync(resolve(root, match[1])), match[1]);
  assert.doesNotMatch(html, /(?:src|rel="stylesheet" href)="https?:/);
  for (const match of readFileSync(
    resolve(root, "styles.css"),
    "utf8",
  ).matchAll(/url\(['"]?(\.\/[^)'"\s]+)/g))
    assert.ok(existsSync(resolve(root, match[1])));
});
test("mock status, preview limits and privacy are visible", () => {
  for (const phrase of [
    "Interactive mock",
    "No LLM",
    "No model calls",
    "not your real app",
    "isn’t published yet",
    "acceptance are still pending",
  ])
    assert.ok(html.includes(phrase), phrase);
});
test("every required DOM control exists", () => {
  const controls = [...code.matchAll(/\$\((['"])([^'"]+)\1\)/g)];
  assert.ok(
    controls.length > 30,
    "DOM guard must inspect real controller references",
  );
  for (const match of controls)
    assert.ok(html.includes(`id="${match[2]}"`), match[2]);
});
test("the deployment uploads only public, not .git, tests or native app files", () => {
  const workflow = readFileSync(
    resolve(root, "../.github/workflows/pages.yml"),
    "utf8",
  );
  assert.match(workflow, /path: public/);
  assert.match(workflow, /branches: \[gh-pages\]/);
  assert.ok(!existsSync(resolve(root, ".git")));
  assert.ok(!existsSync(resolve(root, "node-harness")));
  const walk = (path) =>
    readdirSync(path, { withFileTypes: true }).flatMap((entry) =>
      entry.isDirectory()
        ? walk(resolve(path, entry.name))
        : [resolve(path, entry.name)],
    );
  for (const path of walk(root))
    assert.ok(
      /\.(?:html|css|js|svg|png|txt|xml)$|\.nojekyll$/.test(path),
      path,
    );
});
