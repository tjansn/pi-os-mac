import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { request } from "node:http";
import { join } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { isHttpUrl } from "../src/contracts/actions.js";
import { parseInstant } from "../src/instant/grammar/index.js";
import { SITE_HOME, toWebUrl } from "../src/instant/grammar/launch.js";
import { parseTestSitesPort, TEST_SITE_HOME, TEST_SITES_ENV, testSiteHome, testSiteUrl } from "../src/instant/grammar/testSites.js";
import { normalize } from "../src/instant/normalize.js";
import {
  boundedDelay, MAX_DELAY_MS, PAGE_FIELDS, PAGES, parseEcho, SECURITY_HEADERS, startPageFixture, type PageFixture,
} from "../../host-macos/qa/continuity/page-fixture/server.mjs";

const continuity = join(import.meta.dirname, "..", "..", "host-macos", "qa", "continuity");
const pageFixture = join(continuity, "page-fixture");
const ON = { [TEST_SITES_ENV]: "47391" };
const REQUIRED = ["fixture search", "fixture page", "fixture login"];

// ---------------------------------------------------------------- the flag-only table

test("test sites: the table is empty unless the flag holds a valid port", () => {
  assert.equal(TEST_SITES_ENV, "PI_OS_TEST_SITES_PORT");
  assert.deepEqual({ ...testSiteHome({}) }, {});
  for (const value of ["", "0", "1", "80", "1023", "65536", "99999", "true", "yes", " 47391", "47391 ", "+47391", "047391",
    "4739.1", "1e4", "0x1000", "47391/search", "127.0.0.1:47391"]) {
    assert.equal(parseTestSitesPort(value), null, `port ${JSON.stringify(value)}`);
    assert.deepEqual({ ...testSiteHome({ [TEST_SITES_ENV]: value }) }, {}, `table for ${JSON.stringify(value)}`);
  }
  for (const [value, port] of [["1024", 1024], ["47391", 47391], ["65535", 65535]] as const) assert.equal(parseTestSitesPort(value), port);
  // Only this one flag counts; similar names do nothing.
  assert.deepEqual({ ...testSiteHome({ PI_OS_INSTALLED_TEST: "1", PI_OS_TEST_SITES: "47391", PI_OS_TEST_SITE_PORT: "47391" }) }, {});
});

test("test sites: this process reads the flag once; under npm test it is off", () => {
  assert.deepEqual({ ...TEST_SITE_HOME }, { ...testSiteHome(process.env) });
  assert.ok(Object.isFrozen(TEST_SITE_HOME));
  if (process.env[TEST_SITES_ENV] === undefined) {
    assert.equal(Object.keys(TEST_SITE_HOME).length, 0);
    for (const name of REQUIRED) assert.equal(testSiteUrl(name), undefined);
  }
});

test("test sites: with the flag, fixture names map to loopback page-fixture URLs only", () => {
  const table = testSiteHome(ON);
  assert.ok(Object.isFrozen(table));
  assert.equal(Object.getPrototypeOf(table), null);
  assert.equal(table["fixture search"], "http://127.0.0.1:47391/search");
  assert.equal(table["fixture page"], "http://127.0.0.1:47391/article");
  assert.equal(table["fixture login"], "http://127.0.0.1:47391/login");
  assert.equal(testSiteUrl("fixture suche", table), "http://127.0.0.1:47391/search");
  for (const [name, url] of Object.entries(table)) {
    assert.match(name, /^fixture [a-zäöüß ]+$/, name);
    assert.equal(name, name.trim().toLowerCase());
    assert.ok(isHttpUrl(url), url);
    const parsed = new URL(url);
    assert.equal(parsed.protocol, "http:");
    assert.equal(parsed.hostname, "127.0.0.1");
    assert.equal(parsed.port, "47391");
    assert.equal(parsed.search + parsed.hash + parsed.username + parsed.password, "");
    assert.ok(Object.hasOwn(PAGES, parsed.pathname), `${name} → ${parsed.pathname} is a page-fixture page`);
    assert.equal(Object.hasOwn(SITE_HOME, name), false, `${name} must not shadow a real site name`);
  }
  // Every page reachable by name except the iframe's inner document.
  const paths = new Set(Object.values(table).map((url) => new URL(url).pathname));
  assert.deepEqual([...Object.keys(PAGES)].filter((path) => !paths.has(path)), ["/frame"]);
  // Own properties only: no prototype names reach a URL.
  for (const name of ["constructor", "__proto__", "toString", "hasOwnProperty", "fixture", ""]) {
    assert.equal(table[name], undefined, name);
    assert.equal(testSiteUrl(name, table), undefined, name);
  }
});

test("test sites: names parse as plain open targets (typed, voice, EN and DE) and loopback is no web URL", () => {
  const ctx = { now: new Date(2026, 9, 8, 12, 0), locale: "en-US", webSearchTemplate: "https://duckduckgo.com/?q=%s" };
  for (const name of Object.keys(testSiteHome(ON))) {
    for (const [text, voice] of [[`open ${name}`, false], [`open ${name}`, true], [`öffne ${name}`, true], [`${name} öffnen`, true]] as const) {
      const parsed = parseInstant(normalize(text, /ö/.test(text) ? "de-DE" : "en-US"), ctx, voice ? { voice: true } : {});
      assert.ok(parsed?.kind === "open", `${text} (${voice ? "voice" : "typed"}) → ${JSON.stringify(parsed)}`);
      assert.equal(parsed.target, name, text);
      // The grammar looks the name up in this process's table (empty under npm test, so no site and today's app lookup).
      assert.equal(parsed.siteUrl, testSiteUrl(name), text);
    }
  }
  // Why the table exists: the spoken-URL grammar needs a TLD and never yields a loopback URL.
  for (const spoken of ["127.0.0.1:47391/search", "http://127.0.0.1:47391/search", "localhost:47391"]) assert.equal(toWebUrl(spoken), null, spoken);
});

test("test sites: with the flag set, the open grammar opens fixture names on loopback after the real sites", { timeout: 30_000 }, async () => {
  // The table is read once per process, so the flag-on grammar runs in a child under the same no-live-models guard.
  const script = `
    const { parseInstant } = await import("./src/instant/grammar/index.js");
    const { normalize } = await import("./src/instant/normalize.js");
    const ctx = { now: new Date(2026, 9, 8, 12, 0), locale: "en-US", webSearchTemplate: "https://duckduckgo.com/?q=%s" };
    const out = {};
    for (const [text, voice] of ${JSON.stringify([
      ["open fixture search", false], ["open fixture search", true], ["öffne fixture suche", true], ["fixture login öffnen", true],
      ["open fixture page", true], ["open google", true], ["fixture search", true],
    ])}) {
      const parsed = parseInstant(normalize(text, /ö/.test(text) ? "de-DE" : "en-US"), ctx, voice ? { voice: true, bare: true } : {});
      out[(voice ? "voice " : "typed ") + text] = parsed?.kind === "open" ? parsed.siteUrl ?? null : "not open";
    }
    process.stdout.write(JSON.stringify(out));`;
  const child = spawn(process.execPath, ["--import", "./test/no-live-models.mjs", "--import", "tsx", "--input-type=module", "-e", script], {
    cwd: join(import.meta.dirname, ".."), env: { ...process.env, [TEST_SITES_ENV]: "47391" }, stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "", stderr = "";
  child.stdout.on("data", (data: Buffer) => { stdout += data; });
  child.stderr.on("data", (data: Buffer) => { stderr += data; });
  const timer = setTimeout(() => child.kill("SIGTERM"), 25_000); // Only this exact child.
  const [code] = await once(child, "exit");
  clearTimeout(timer);
  assert.equal(code, 0, stderr);
  assert.deepEqual(JSON.parse(stdout), {
    "typed open fixture search": "http://127.0.0.1:47391/search",
    "voice open fixture search": "http://127.0.0.1:47391/search",
    "voice öffne fixture suche": "http://127.0.0.1:47391/search",
    "voice fixture login öffnen": "http://127.0.0.1:47391/login",
    "voice open fixture page": "http://127.0.0.1:47391/article",
    // Real sites keep their home page, and a name said alone never opens a site.
    "voice open google": SITE_HOME.google,
    "voice fixture search": null,
  });
});

// ---------------------------------------------------------------- the page fixture (loopback server)

interface Reply { status: number; headers: Record<string, string | string[] | undefined>; body: string }

/** Raw loopback HTTP to the fixture this test started (fetch is limited to harness routes by the test guard). */
function call(port: number, path: string, options: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<Reply> {
  return new Promise((accept, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: options.method ?? "GET", headers: options.headers ?? {} }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (chunk: Buffer) => chunks.push(chunk));
      res.on("end", () => accept({ status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
      res.on("error", reject);
    });
    req.setTimeout(5000, () => req.destroy(new Error("timeout")));
    req.on("error", reject);
    req.end(options.body);
  });
}

async function withFixture(run: (fixture: PageFixture) => Promise<void>): Promise<void> {
  const fixture = await startPageFixture({ port: 0 });
  try {
    await run(fixture);
  } finally {
    await fixture.close();
  }
}

const echoFor = (page: string, override: Record<string, unknown> = {}): Record<string, unknown> => {
  const fields: Record<string, unknown> = {};
  for (const [name, kind] of Object.entries(PAGE_FIELDS[page] ?? {})) {
    fields[name] = kind === "credential"
      ? { filled: false, dummyMatches: false, focused: false, returnKeys: 0 }
      : { length: 0, scalars: 0, lineBreaks: 0, replacements: 0, inputs: 0, returnKeys: 0, focused: false };
  }
  return { page, submits: 0, fields, ...(page === "consent" ? { consent: { accepted: 0, rejected: 0, open: true } } : {}), ...override };
};

test("page fixture: binds 127.0.0.1 only and serves every page with the locked-down headers", async () => {
  await assert.rejects(startPageFixture({ port: 0, host: "0.0.0.0" }), /127\.0\.0\.1 only/);
  await assert.rejects(startPageFixture({ port: 0, host: "localhost" }), /127\.0\.0\.1 only/);
  await withFixture(async (fixture) => {
    assert.match(fixture.url, /^http:\/\/127\.0\.0\.1:\d+\/$/);
    for (const path of Object.keys(PAGES)) {
      const reply = await call(fixture.port, path);
      assert.equal(reply.status, 200, path);
      assert.equal(reply.headers["content-type"], "text/html; charset=utf-8", path);
      for (const [name, value] of Object.entries(SECURITY_HEADERS)) assert.equal(reply.headers[name], value, `${path} ${name}`);
      assert.equal(reply.headers["set-cookie"], undefined, path);
      assert.match(reply.body, /^<!doctype html>/, path);
      assert.match(reply.body, /<script src="\/fixture\.js" defer><\/script>/, path);
      assert.match(reply.body, new RegExp(`<body data-page="${PAGES[path]}"`), path);
    }
    const csp = SECURITY_HEADERS["content-security-policy"] ?? "";
    for (const directive of ["default-src 'none'", "form-action 'none'", "script-src 'self'", "connect-src 'self'", "frame-ancestors 'self'"]) {
      assert.ok(csp.includes(directive), directive);
    }
    assert.equal((await call(fixture.port, "/fixture.js")).headers["content-type"], "text/javascript; charset=utf-8");
    assert.equal((await call(fixture.port, "/fixture.css")).headers["content-type"], "text/css; charset=utf-8");
    assert.equal((await call(fixture.port, "/nope")).status, 404);
    assert.equal((await call(fixture.port, "/search", { method: "POST" })).status, 405);
    assert.equal((await call(fixture.port, "/state", { method: "DELETE" })).status, 405);
    // DNS-rebinding guard: only the loopback names of this port.
    assert.equal((await call(fixture.port, "/search", { headers: { host: "fixture.example" } })).status, 421);
    assert.equal((await call(fixture.port, "/search", { headers: { host: `127.0.0.1:${fixture.port + 1}` } })).status, 421);
    assert.equal((await call(fixture.port, "/search", { headers: { host: `localhost:${fixture.port}` } })).status, 200);
  });
});

test("page fixture: each page carries the surface its QA step needs", () => {
  const page = (name: string) => readFileSync(join(pageFixture, "pages", `${name}.html`), "utf8");
  const tag = (html: string, field: string) => html.match(new RegExp(`<[a-z]+ [^>]*data-field="${field}"[^>]*>`))?.[0] ?? "";
  const search = tag(page("search"), "search");
  assert.match(search, /^<input /); assert.match(search, /type="search"/); assert.match(search, / autofocus/);
  const combobox = tag(page("combobox"), "q");
  assert.match(combobox, /^<textarea /); assert.match(combobox, /role="combobox"/); assert.match(combobox, /aria-label="Search"/);
  assert.match(combobox, / autofocus/); assert.match(combobox, /data-enter-submits="true"/);
  assert.doesNotMatch(tag(page("delayed"), "search"), /autofocus/);
  assert.match(page("delayed"), /<body data-page="delayed" data-delayed-focus>/);
  assert.match(tag(page("loading"), "search"), / autofocus/);
  assert.match(page("loading"), /data-slow-load/);
  assert.match(page("consent"), /<dialog data-consent/);
  assert.match(page("consent"), /<button type="button" data-choice="accept" autofocus>/);
  assert.match(page("iframe"), /<iframe src="\/frame" title="Embedded search"><\/iframe>/);
  assert.doesNotMatch(tag(page("iframe"), "top"), /autofocus/);
  assert.match(tag(page("frame"), "embedded"), / autofocus/);
  const login = page("login");
  assert.match(tag(login, "username"), /autocomplete="username"/); assert.match(tag(login, "username"), /data-kind="credential"/);
  assert.match(tag(login, "password"), /type="password"/); assert.match(tag(login, "password"), /autocomplete="current-password"/);
  assert.match(tag(login, "password"), /data-kind="credential"/);
  assert.doesNotMatch(login, /\saction=|\svalue=|\smethod=/, "no prefilled values and nowhere to submit");
  assert.match(page("article"), /<article>[\s\S]*<h1>[^<]+<\/h1>[\s\S]*<p lang="de">/);
  assert.match(tag(page("article"), "search"), / autofocus/);
  assert.match(page("moving"), /data-moving-focus/);
  assert.match(tag(page("editor"), "notes"), /contenteditable="true"/); assert.match(tag(page("editor"), "notes"), /aria-multiline="true"/);
  // Every page's fields are exactly its echo schema.
  for (const [path, name] of Object.entries(PAGES)) {
    const html = page(name);
    const fields = [...html.matchAll(/data-field="([^"]+)"/g)].map((m) => m[1]).sort();
    assert.deepEqual(fields, Object.keys(PAGE_FIELDS[name] ?? {}).sort(), path);
    for (const field of fields) {
      const credential = PAGE_FIELDS[name]?.[field!] === "credential";
      assert.equal(/data-kind="credential"/.test(tag(html, field!)), credential, `${path} ${field}`);
    }
  }
});

test("page fixture: pages and assets stay self-contained and content-free", () => {
  const files = [
    ...readdirSync(join(pageFixture, "pages")).map((file) => join(pageFixture, "pages", file)),
    ...readdirSync(join(pageFixture, "assets")).map((file) => join(pageFixture, "assets", file)),
  ];
  assert.equal(files.length, Object.keys(PAGES).length + 2);
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    assert.doesNotMatch(text, /https?:\/\//, `${file}: no external reference`);
    for (const m of text.matchAll(/\s(?:src|href)="([^"]*)"/g)) assert.match(m[1]!, /^\/[a-z.]*$/, `${file}: ${m[1]}`);
    assert.doesNotMatch(text, /<script>|\son[a-z]+=/i, `${file}: no inline script (CSP)`);
  }
  const script = readFileSync(join(pageFixture, "assets", "fixture.js"), "utf8");
  assert.doesNotMatch(script, /console\.|document\.cookie|localStorage|sessionStorage|indexedDB|XMLHttpRequest|sendBeacon|eval\(|new Function/);
  assert.deepEqual([...script.matchAll(/fetch\("([^"]+)"/g)].map((m) => m[1]), ["/echo"], "the only request is the count echo");
  assert.doesNotMatch(script, /\.value\s*=(?!=)/, "the page never writes a field value");
  const server = readFileSync(join(pageFixture, "server.mjs"), "utf8");
  assert.doesNotMatch(server, /console\./, "the server logs nothing per request");
});

test("page fixture: /echo keeps closed-schema counts only and /state reports them", async () => {
  await withFixture(async (fixture) => {
    const json = (body: unknown, headers: Record<string, string> = {}) =>
      call(fixture.port, "/echo", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
    const search = echoFor("search", {
      submits: 1,
      fields: { search: { length: 15, scalars: 15, lineBreaks: 0, replacements: 0, inputs: 15, returnKeys: 1, focused: true } },
    });
    assert.equal((await json(search)).status, 204);
    assert.equal((await json(echoFor("login", { fields: {
      username: { filled: true, dummyMatches: true, focused: false, returnKeys: 0 },
      password: { filled: true, dummyMatches: true, focused: true, returnKeys: 0 },
    } }))).status, 204);
    assert.equal((await json(echoFor("consent"))).status, 204);
    assert.equal((await json(echoFor("index"))).status, 204);
    assert.equal((await call(fixture.port, "/search")).status, 200);
    assert.equal((await call(fixture.port, "/search")).status, 200);
    const state = JSON.parse((await call(fixture.port, "/state")).body) as ReturnType<PageFixture["state"]>;
    assert.deepEqual(state.pages.search, search);
    assert.deepEqual(state.pages.login?.fields.password, { filled: true, dummyMatches: true, focused: true, returnKeys: 0 });
    assert.deepEqual(state.served, { "/search": 2 });
    assert.deepEqual(fixture.state(), state);

    // Anything outside the schema is refused: strings (a value or label), unknown pages, fields or keys, lengths on
    // credential fields, negative or fractional counts.
    const refused = [
      echoFor("search", { fields: { search: { length: "Albert Einstein", scalars: 0, lineBreaks: 0, replacements: 0, inputs: 0, returnKeys: 0, focused: false } } }),
      echoFor("search", { text: "Albert Einstein" }),
      echoFor("search", { fields: { search: { length: 1, scalars: 1, lineBreaks: 0, replacements: 0, inputs: 0, returnKeys: 0, focused: false, value: "x" } } }),
      echoFor("search", { fields: { other: { length: 1, scalars: 1, lineBreaks: 0, replacements: 0, inputs: 0, returnKeys: 0, focused: false } } }),
      echoFor("login", { fields: { username: { filled: true, dummyMatches: false, focused: true, returnKeys: 0, length: 8 },
        password: { filled: false, dummyMatches: false, focused: false, returnKeys: 0 } } }),
      echoFor("search", { submits: -1 }),
      echoFor("search", { submits: 1.5 }),
      echoFor("search", { page: "https://example.com/" }),
      echoFor("consent", { consent: { accepted: 0, rejected: 0, open: "yes" } }),
      echoFor("search", { consent: { accepted: 0, rejected: 0, open: true } }),
      [], "counts", null,
    ];
    for (const body of refused) {
      assert.equal(parseEcho(body), null, JSON.stringify(body));
      assert.equal((await json(body)).status, 400, JSON.stringify(body));
    }
    assert.equal((await call(fixture.port, "/echo", { method: "POST", headers: { "content-type": "text/plain" }, body: JSON.stringify(search) })).status, 415);
    assert.equal((await call(fixture.port, "/echo", { method: "POST", headers: { "content-type": "application/json" }, body: "{" })).status, 400);
    assert.equal((await call(fixture.port, "/echo", { method: "POST", headers: { "content-type": "application/json" }, body: " ".repeat(5000) })).status, 413);
    assert.equal((await call(fixture.port, "/echo")).status, 405);
    // Cross-site posts are refused (the pages post same-origin).
    assert.equal((await json(search, { origin: "https://example.com" })).status, 403);
    assert.equal((await json(search, { "sec-fetch-site": "cross-site" })).status, 403);
    assert.equal((await json(search, { origin: `http://127.0.0.1:${fixture.port}`, "sec-fetch-site": "same-origin" })).status, 204);
    const after = JSON.stringify(fixture.state());
    assert.doesNotMatch(after, /Albert|Einstein|example\.com|"value"|"text"/);

    assert.equal((await call(fixture.port, "/reset", { method: "POST", headers: { origin: "https://example.com" } })).status, 403);
    assert.equal((await call(fixture.port, "/reset", { method: "POST" })).status, 204);
    assert.deepEqual(fixture.state(), { pages: {}, served: {} });
  });
});

// ---------------------------------------------------------------- the page script, run on a fake DOM per real page

interface FakeEvent { type: string; key?: string; isTrusted: boolean; isComposing?: boolean; shiftKey?: boolean; defaultPrevented: boolean; preventDefault(): void }
type Listener = (event: FakeEvent) => void;

class FakeNode {
  readonly listeners = new Map<string, Listener[]>();
  addEventListener(type: string, listener: Listener): void { this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]); }
  dispatch(type: string, init: Partial<FakeEvent> = {}): FakeEvent {
    const event: FakeEvent = { type, isTrusted: true, defaultPrevented: false, preventDefault() { event.defaultPrevented = true; }, ...init };
    for (const listener of this.listeners.get(type) ?? []) listener(event);
    return event;
  }
}

/** Just enough DOM for fixture.js, built from a real page's markup (fields, forms, outputs, consent dialog). */
function fakePage(name: string, search = "") {
  const html = readFileSync(join(pageFixture, "pages", `${name}.html`), "utf8");
  const attributes = (tag: string) => new Map([...tag.matchAll(/\s([a-z-]+)(?:="([^"]*)")?/g)].map((m) => [m[1]!, m[2] ?? ""]));
  const dataset = (attrs: Map<string, string>) => Object.fromEntries([...attrs].filter(([key]) => key.startsWith("data-"))
    .map(([key, value]) => [key.slice(5).replace(/-([a-z])/g, (_m, c: string) => c.toUpperCase()), value]));
  const timers: { ms: number; run: () => void }[] = [];
  const posts: string[] = [];
  const doc = new (class extends FakeNode {
    activeElement: unknown = null;
    head = { append: (node: { src?: string }) => { scripts.push(node.src ?? ""); } };
  })();
  const scripts: string[] = [];
  class FakeElement extends FakeNode {
    value = ""; innerText = ""; textContent = ""; open = false;
    form: FakeForm | null = null;
    constructor(readonly attrs: Map<string, string>) { super(); }
    get dataset() { return dataset(this.attrs); }
    get isContentEditable() { return this.attrs.get("contenteditable") === "true"; }
    hasAttribute(key: string) { return this.attrs.has(key); }
    focus() { doc.activeElement = this; }
  }
  class FakeForm extends FakeNode { requestSubmit() { this.dispatch("submit"); } }
  const body = new FakeElement(attributes(/<body[^>]*>/.exec(html)![0]));
  doc.activeElement = body;
  const forms = [...html.matchAll(/<form[\s\S]*?<\/form>/g)].map((m) => ({ form: new FakeForm(), start: m.index, end: m.index + m[0].length }));
  const fields = [...html.matchAll(/<[a-z]+ [^>]*data-field="[^"]*"[^>]*>/g)].map((m) => {
    const element = new FakeElement(attributes(m[0]));
    element.form = forms.find((f) => m.index > f.start && m.index < f.end)?.form ?? null;
    if (element.hasAttribute("autofocus") && doc.activeElement === body) doc.activeElement = element;
    return element;
  });
  const outputs = new Map([...html.matchAll(/<output (data-echo(?:-page|="[^"]*"))/g)].map((m) => [m[1]!, new FakeElement(new Map())]));
  const dialogTag = /<dialog data-consent[\s\S]*?<\/dialog>/.exec(html)?.[0];
  const dialog = dialogTag ? new (class extends FakeElement {
    buttons = [...(dialogTag ?? "").matchAll(/<button [^>]*>/g)].map((m) => new FakeElement(attributes(m[0])));
    querySelectorAll() { return this.buttons; }
    showModal() { this.open = true; doc.activeElement = this.buttons.find((b) => b.hasAttribute("autofocus")); }
    close() { this.open = false; }
  })(new Map()) : null;
  Object.assign(doc, {
    body, forms: forms.map((f) => f.form),
    querySelectorAll: (selector: string) => selector === "[data-field]" ? fields : [],
    querySelector: (selector: string) => selector === "dialog[data-consent]" ? dialog : outputs.get(selector.replace(/^\[|\]$/g, "")) ?? null,
    createElement: () => ({ src: "", async: false }),
  });
  const context = {
    document: doc, location: { search }, URLSearchParams,
    setTimeout: (run: () => void, ms: number) => { timers.push({ ms, run }); return timers.length; },
    fetch: (path: string, init: { body: string }) => { assert.equal(path, "/echo"); posts.push(init.body); return Promise.resolve(); },
  };
  runInNewContext(readFileSync(join(pageFixture, "assets", "fixture.js"), "utf8"), context);
  const flush = () => { while (timers.length) timers.shift()!.run(); };
  const last = () => { flush(); return parseEcho(JSON.parse(posts.at(-1) ?? "null")); };
  return { fields, forms: forms.map((f) => f.form), dialog, doc, timers, posts, scripts, outputs, flush, last };
}

test("page script: every page's echo matches the server's closed schema and carries no value", () => {
  for (const name of Object.values(PAGES)) {
    const page = fakePage(name);
    const snapshot = page.last();
    assert.ok(snapshot, `${name}: the first echo parses`);
    assert.equal(snapshot.page, name);
    for (const field of page.fields) {
      field.value = "Albert Einstein ☕";
      field.innerText = "Albert Einstein ☕";
      field.dispatch("input");
    }
    const after = page.last();
    assert.ok(after, `${name}: the echo after typing parses`);
    for (const body of page.posts) assert.doesNotMatch(body, /Albert|Einstein|☕|dummy-credential/, name);
    for (const output of page.outputs.values()) assert.doesNotMatch(output.textContent, /Albert|Einstein|☕/, name);
  }
});

test("page script: counts lengths, Return keys, submits and focus without navigating", () => {
  const search = fakePage("search");
  const field = search.fields[0]!;
  assert.equal(search.doc.activeElement, field, "autofocus");
  field.value = "Grüße ☕ 👩‍💻";
  field.dispatch("input");
  const enter = field.dispatch("keydown", { key: "Enter" });
  field.dispatch("keydown", { key: "Enter", isTrusted: false });
  field.dispatch("keydown", { key: "Enter", isComposing: true });
  field.dispatch("keydown", { key: "a" });
  const submit = search.forms[0]!.dispatch("submit");
  assert.equal(enter.defaultPrevented, false, "a search input's Return is the browser's own implicit submit");
  assert.equal(submit.defaultPrevented, true, "the form never navigates");
  const counts = search.last()!.fields.search;
  assert.deepEqual(counts, { length: "Grüße ☕ 👩‍💻".length, scalars: [..."Grüße ☕ 👩‍💻"].length, lineBreaks: 0, replacements: 0, inputs: 1, returnKeys: 1, focused: true });
  assert.equal(search.last()!.submits, 1);
  assert.equal(search.outputs.get('data-echo="search"')!.textContent, `${"Grüße ☕ 👩‍💻".length} received · Return 1 · focused`);

  const combobox = fakePage("combobox");
  const box = combobox.fields[0]!;
  const comboEnter = box.dispatch("keydown", { key: "Enter" });
  assert.equal(comboEnter.defaultPrevented, true, "Return submits instead of adding a line");
  assert.equal(combobox.last()!.submits, 1);
  assert.equal(box.dispatch("keydown", { key: "Enter", shiftKey: true }).defaultPrevented, false);

  const login = fakePage("login");
  const [username, password] = login.fields;
  assert.equal(login.doc.activeElement, username);
  password!.value = "dummy-credential-QA-only";
  password!.dispatch("input");
  username!.value = "someone";
  username!.dispatch("input");
  const credentials = login.last()!.fields;
  assert.deepEqual(credentials.password, { filled: true, dummyMatches: true, focused: false, returnKeys: 0 });
  assert.deepEqual(credentials.username, { filled: true, dummyMatches: false, focused: true, returnKeys: 0 });
  assert.ok(login.posts.every((body) => !/someone|dummy-credential|length/.test(body)), "credential echoes carry no value and no length");

  const editor = fakePage("editor");
  editor.fields[0]!.innerText = "eins\nzwei\n";
  editor.fields[0]!.dispatch("input");
  assert.equal((editor.last()!.fields.notes as unknown as Record<string, number>).lineBreaks, 1, "the trailing contenteditable newline is ignored");
});

test("page script: consent holds focus, delayed and moving focus follow ?ms=, loading inserts the slow resource", () => {
  const consent = fakePage("consent");
  assert.equal(consent.dialog?.open, true);
  assert.notEqual(consent.doc.activeElement, consent.fields[0], "the dialog holds focus");
  const escape = consent.dialog!.dispatch("cancel");
  assert.equal(escape.defaultPrevented, true, "Escape does not dismiss it");
  consent.dialog!.buttons.find((b) => b.dataset.choice === "accept")!.dispatch("click");
  assert.equal(consent.dialog!.open, false);
  assert.equal(consent.doc.activeElement, consent.fields[0], "focus moves to the search box");
  assert.deepEqual(consent.last()!.consent, { accepted: 1, rejected: 0, open: false });

  const delayed = fakePage("delayed", "?ms=1200");
  assert.notEqual(delayed.doc.activeElement, delayed.fields[0]);
  assert.ok(delayed.timers.some((timer) => timer.ms === 1200));
  delayed.flush();
  assert.equal(delayed.doc.activeElement, delayed.fields[0]);
  assert.ok(fakePage("delayed", "?ms=99999999").timers.some((timer) => timer.ms === 800), "an out-of-range ms falls back");
  assert.ok(fakePage("delayed", "?ms=999999").timers.some((timer) => timer.ms === 10_000), "ms is capped");

  const moving = fakePage("moving");
  assert.equal(moving.doc.activeElement, moving.fields[0]);
  assert.ok(moving.timers.some((timer) => timer.ms === 1500));
  moving.flush();
  assert.equal(moving.doc.activeElement, moving.fields[1]);

  assert.deepEqual(fakePage("loading", "?ms=3000").scripts, ["/slow.js?ms=3000"]);
  assert.deepEqual(fakePage("loading").scripts, ["/slow.js?ms=1500"]);
  assert.deepEqual(fakePage("search").scripts, []);
  const frame = fakePage("frame");
  assert.equal(frame.doc.activeElement, frame.fields[0]);
});

test("page fixture: delays are bounded and the slow resource holds the load", async () => {
  assert.equal(MAX_DELAY_MS, 10_000);
  assert.equal(boundedDelay("250", 800), 250);
  assert.equal(boundedDelay("0", 800), 0);
  assert.equal(boundedDelay("999999", 800), MAX_DELAY_MS);
  for (const raw of [null, undefined, "", "-5", "1e3", "12ms", "0x10", "1234567"]) assert.equal(boundedDelay(raw, 800), 800, String(raw));
  await withFixture(async (fixture) => {
    const started = performance.now();
    const reply = await call(fixture.port, "/slow.js?ms=120");
    assert.equal(reply.status, 200);
    assert.equal(reply.headers["content-type"], "text/javascript; charset=utf-8");
    assert.ok(performance.now() - started >= 100, "the slow resource waits");
    // A pending slow response does not keep close() waiting.
    const pending = call(fixture.port, "/slow.js?ms=8000").catch(() => null);
    await new Promise((resolve) => setTimeout(resolve, 30));
    const closing = performance.now();
    await fixture.close();
    assert.ok(performance.now() - closing < 2000);
    await pending;
  });
});

test("page fixture: the CLI prints one content-free ready line and nothing per request", { timeout: 20_000 }, async () => {
  const child = spawn(process.execPath, [join(pageFixture, "server.mjs"), "--port", "0"], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", (data: Buffer) => { stdout += data; });
  child.stderr.on("data", (data: Buffer) => { stderr += data; });
  try {
    const port = await new Promise<number>((accept, reject) => {
      const timer = setTimeout(() => reject(new Error(`no ready line: ${stderr}`)), 10_000);
      child.once("exit", (code) => { clearTimeout(timer); reject(new Error(`exited ${code}: ${stderr}`)); });
      child.stdout.on("data", () => {
        const m = /^continuity page fixture ready port=(\d+)\n/.exec(stdout);
        if (m) { clearTimeout(timer); accept(Number(m[1])); }
      });
    });
    for (const path of ["/search", "/login", "/article", "/nope"]) await call(port, path);
    await call(port, "/echo", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(echoFor("search")) });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(stdout, `continuity page fixture ready port=${port}\n`);
    assert.equal(stderr, "");
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const exit = once(child, "exit");
      child.kill("SIGTERM"); // Only the exact child this test started.
      await exit;
    }
  }
  const bad = spawn(process.execPath, [join(pageFixture, "server.mjs"), "--port", "http"], { stdio: ["ignore", "pipe", "pipe"] });
  const [code] = await once(bad, "exit");
  assert.equal(code, 64);
});

// ---------------------------------------------------------------- the native fixture's offscreen self-test

const fixtureBinary = join(import.meta.dirname, "..", "..", "host-macos", ".build", "debug", "pi-os-input-fixture");
const SELF_TEST_MARKER = "pi-os-continuity-self-test-v1";

/**
 * Runs `pi-os-input-fixture --self-test` (no window is ever shown; activation policy `.prohibited`) when a build that
 * contains the self-test exists. An older binary would read `--self-test` as a state path and open its A/B windows, so
 * it is only started when the marker is present in it.
 */
test("native fixture: the continuity self-test passes without showing a window", { timeout: 30_000 }, async (t) => {
  if (process.platform !== "darwin") return t.skip("macOS only");
  if (!existsSync(fixtureBinary)) return t.skip("pi-os-input-fixture is not built (swift build --package-path host-macos)");
  if (!readFileSync(fixtureBinary).includes(Buffer.from(SELF_TEST_MARKER))) return t.skip("the built fixture predates the self-test; rebuild it");
  const child = spawn(fixtureBinary, ["--self-test"], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", (data: Buffer) => { stdout += data; });
  child.stderr.on("data", (data: Buffer) => { stderr += data; });
  const timer = setTimeout(() => child.kill("SIGTERM"), 20_000); // Only this exact child.
  const [code] = await once(child, "exit");
  clearTimeout(timer);
  assert.equal(code, 0, stdout + stderr);
  assert.match(stdout, new RegExp(`^PASS ${SELF_TEST_MARKER}: \\d+ checks, 5 surfaces, 7 fields, no window shown\\n$`));
  assert.doesNotMatch(stdout + stderr, /Albert|Einstein|Grüße|☕/);
});

test("continuity QA README covers Q1–Q11 with stop conditions", () => {
  const readme = readFileSync(join(continuity, "README.md"), "utf8");
  for (let q = 1; q <= 11; q += 1) assert.match(readme, new RegExp(`^\\| Q${q} \\|`, "m"), `Q${q}`);
  assert.match(readme, /## Stop conditions/);
  assert.match(readme, new RegExp(TEST_SITES_ENV));
  for (const name of REQUIRED) assert.ok(readme.includes(name), name);
});

test("continuity QA README keeps the live plan harmless and complete", () => {
  const readme = readFileSync(join(continuity, "README.md"), "utf8");
  const row = (q: number) => readme.match(new RegExp(`^\\| Q${q} \\|.*$`, "m"))?.[0] ?? "";
  // pi-os is launched through Launch Services with its own permission identity, never as a shell child.
  assert.match(readme, new RegExp(`open --env ${TEST_SITES_ENV}=\\d+ `));
  assert.match(readme, /quits the\s+running pi-os first/);
  assert.doesNotMatch(readme, /Contents\/MacOS\/pi-os/);
  // A deletion-vocabulary probe only ever names a path that cannot exist, in case it reaches a real shell.
  const rm = [...readme.matchAll(/\brm\s+-\S+\s+(\S+?)["`]/g)].map((m) => m[1]);
  assert.ok(rm.length > 0, "Q8 still probes the rm refusal");
  assert.deepEqual([...new Set(rm)], ["pi-os-qa-nonexistent"]);
  // The launch race cold-launches an app that opens no document (nothing to discard, so no Delete button at teardown).
  assert.doesNotMatch(row(2), /TextEdit|Notes|Pages|Word/);
  // Q4 covers DESIGN5 §12's whole fill chain: search form, Undo, replace and the bare ask-pi after a fill.
  for (const step of ["such nach Katzen", "\"nein\" within 5 s", "\"nein, Marie Curie\"", "bare \"frag pi\"", "tippe http://127.0.0.1:"]) {
    assert.ok(row(4).includes(step), step);
  }
  // The terminal offer card needs a dictation-like phrase; a command would reach the agent instead.
  assert.doesNotMatch(row(8), /voice "list files"/);
  assert.doesNotMatch(readme, /Delete the temporary/);
});
