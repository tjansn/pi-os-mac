#!/usr/bin/env node
/**
 * Continuity page fixture (DESIGN5 §12, WP6): harmless loopback pages for the coordinated live QA in ../README.md.
 *
 * - Binds 127.0.0.1 only and answers only Host 127.0.0.1:<port> or localhost:<port> (no DNS rebinding).
 * - No cookies, no storage, no external requests (CSP `default-src 'none'`, `form-action 'none'`), no request logs.
 * - Pages report counts and booleans (lengths, Return keys, submits, focus) to POST /echo; GET /state returns the latest
 *   ones. Field values, labels and URLs never reach this server; /echo rejects anything outside its closed schema.
 *
 * CLI: `node server.mjs [--port 47391]` (`--port 0` picks a free port). Prints one line, `… ready port=<n>`, and
 * nothing per request. Ctrl-C stops it.
 */
import { readFileSync, realpathSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

export const DEFAULT_PORT = 47391;
export const LOOPBACK = "127.0.0.1";
/** Upper bound for every `ms` query parameter (delayed focus, slow load, moving focus). */
export const MAX_DELAY_MS = 10_000;
const MAX_ECHO_BYTES = 4096;
const MAX_COUNT = 1_000_000;

/** Path → page file in ./pages. node-harness/src/instant/grammar/testSites.ts points its names at these paths. */
export const PAGES = Object.freeze({
  "/": "index",
  "/search": "search",
  "/combobox": "combobox",
  "/delayed": "delayed",
  "/loading": "loading",
  "/consent": "consent",
  "/iframe": "iframe",
  "/frame": "frame",
  "/login": "login",
  "/article": "article",
  "/moving": "moving",
  "/editor": "editor",
});

/** The closed echo schema: page → field → "text" (lengths) or "credential" (booleans only, never a length). */
export const PAGE_FIELDS = Object.freeze({
  index: Object.freeze({}),
  search: Object.freeze({ search: "text" }),
  combobox: Object.freeze({ q: "text" }),
  delayed: Object.freeze({ search: "text" }),
  loading: Object.freeze({ search: "text" }),
  consent: Object.freeze({ search: "text" }),
  iframe: Object.freeze({ top: "text" }),
  frame: Object.freeze({ embedded: "text" }),
  login: Object.freeze({ username: "credential", password: "credential" }),
  article: Object.freeze({ search: "text" }),
  moving: Object.freeze({ first: "text", second: "text" }),
  editor: Object.freeze({ notes: "text" }),
});

const ASSETS = Object.freeze({
  "/fixture.js": ["fixture.js", "text/javascript; charset=utf-8"],
  "/fixture.css": ["fixture.css", "text/css; charset=utf-8"],
});

export const SECURITY_HEADERS = Object.freeze({
  "content-security-policy":
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-src 'self'; " +
    "frame-ancestors 'self'; form-action 'none'; base-uri 'none'",
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
  "cross-origin-resource-policy": "same-origin",
});

const TEXT_KEYS = ["focused", "inputs", "length", "lineBreaks", "replacements", "returnKeys", "scalars"];
const CREDENTIAL_KEYS = ["dummyMatches", "filled", "focused", "returnKeys"];
const BOOLEAN_KEYS = new Set(["focused", "dummyMatches", "filled", "open"]);
const CONSENT_KEYS = ["accepted", "open", "rejected"];

/** A decimal `ms` value bounded to [0, MAX_DELAY_MS]; anything else is `fallback`. */
export function boundedDelay(raw, fallback) {
  if (typeof raw !== "string" || !/^\d{1,6}$/.test(raw)) return fallback;
  return Math.min(Number(raw), MAX_DELAY_MS);
}

const isRecord = (value) => typeof value === "object" && value !== null && !Array.isArray(value);
const own = (record, key) => Object.prototype.hasOwnProperty.call(record, key);

function exactCounts(value, keys) {
  if (!isRecord(value)) return null;
  const present = Object.keys(value).sort();
  if (present.length !== keys.length || present.some((key, i) => key !== keys[i])) return null;
  const out = {};
  for (const key of keys) {
    const item = value[key];
    if (BOOLEAN_KEYS.has(key)) {
      if (typeof item !== "boolean") return null;
    } else if (!Number.isSafeInteger(item) || item < 0 || item > MAX_COUNT) {
      return null;
    }
    out[key] = item;
  }
  return out;
}

/** A page's count snapshot, rebuilt from the closed schema; null for anything else (strings, unknown keys or names). */
export function parseEcho(value) {
  if (!isRecord(value)) return null;
  const allowed = ["fields", "page", "submits", ...(value.page === "consent" ? ["consent"] : [])].sort();
  const keys = Object.keys(value).sort();
  if (keys.length !== allowed.length || keys.some((key, i) => key !== allowed[i])) return null;
  if (typeof value.page !== "string" || !own(PAGE_FIELDS, value.page)) return null;
  if (!Number.isSafeInteger(value.submits) || value.submits < 0 || value.submits > MAX_COUNT) return null;
  const schema = PAGE_FIELDS[value.page];
  if (!isRecord(value.fields)) return null;
  const names = Object.keys(value.fields).sort();
  const expected = Object.keys(schema).sort();
  if (names.length !== expected.length || names.some((name, i) => name !== expected[i])) return null;
  const fields = {};
  for (const name of expected) {
    const entry = exactCounts(value.fields[name], schema[name] === "credential" ? CREDENTIAL_KEYS : TEXT_KEYS);
    if (!entry) return null;
    fields[name] = entry;
  }
  const out = { page: value.page, submits: value.submits, fields };
  if (value.page === "consent") {
    const consent = exactCounts(value.consent, CONSENT_KEYS);
    if (!consent) return null;
    out.consent = consent;
  }
  return out;
}

function loadFiles() {
  const pages = new Map();
  for (const [path, name] of Object.entries(PAGES)) pages.set(path, readFileSync(join(HERE, "pages", `${name}.html`)));
  const assets = new Map();
  for (const [path, [file, type]] of Object.entries(ASSETS)) assets.set(path, { body: readFileSync(join(HERE, "assets", file)), type });
  return { pages, assets };
}

/**
 * Starts the fixture on 127.0.0.1 (`port` 0 = a free port). Resolves once listening. `state()` returns the latest
 * page snapshots and how often each page was served; `close()` stops it and any pending slow responses.
 */
export async function startPageFixture({ port = DEFAULT_PORT, host = LOOPBACK } = {}) {
  if (host !== LOOPBACK) throw new Error("The continuity page fixture binds 127.0.0.1 only");
  if (!Number.isInteger(port) || port < 0 || port > 65_535) throw new Error("Invalid port");
  const { pages, assets } = loadFiles();
  let echoes = Object.create(null);
  let served = Object.create(null);
  const timers = new Set();
  let actual = port;

  const send = (req, res, status, body = "", type = "text/plain; charset=utf-8", extra = {}) => {
    const bytes = typeof body === "string" ? Buffer.from(body) : body;
    res.writeHead(status, { ...SECURITY_HEADERS, "content-type": type, "content-length": bytes.length, ...extra });
    res.end(req.method === "HEAD" ? undefined : bytes);
  };
  const sameOrigin = (req) => {
    const origin = req.headers.origin;
    const site = req.headers["sec-fetch-site"];
    const origins = [`http://127.0.0.1:${actual}`, `http://localhost:${actual}`];
    return (origin === undefined || origins.includes(origin)) && (site === undefined || site === "same-origin" || site === "none");
  };

  const server = createServer((req, res) => {
    const hostHeader = req.headers.host ?? "";
    if (hostHeader !== `127.0.0.1:${actual}` && hostHeader !== `localhost:${actual}`) return send(req, res, 421, "Misdirected request\n");
    let url;
    try {
      url = new URL(req.url ?? "/", `http://127.0.0.1:${actual}`);
    } catch {
      return send(req, res, 400, "Bad request\n");
    }
    const path = url.pathname, query = url.searchParams;

    if (path === "/echo" || path === "/reset") {
      if (req.method !== "POST") return send(req, res, 405, "Method not allowed\n", undefined, { allow: "POST" });
      if (!sameOrigin(req)) return send(req, res, 403, "Forbidden\n");
      if (path === "/reset") {
        req.resume();
        echoes = Object.create(null);
        served = Object.create(null);
        return send(req, res, 204);
      }
      if (!(req.headers["content-type"] ?? "").toLowerCase().startsWith("application/json")) return send(req, res, 415, "JSON only\n");
      const chunks = [];
      let size = 0, tooLarge = false;
      req.on("data", (chunk) => {
        size += chunk.length;
        if (size > MAX_ECHO_BYTES) tooLarge = true;
        else chunks.push(chunk);
      });
      req.on("end", () => {
        if (tooLarge) return send(req, res, 413, "Too large\n");
        let parsed = null;
        try {
          parsed = parseEcho(JSON.parse(Buffer.concat(chunks).toString("utf8")));
        } catch {
          parsed = null;
        }
        if (!parsed) return send(req, res, 400, "Counts only\n");
        echoes[parsed.page] = parsed;
        return send(req, res, 204);
      });
      return undefined;
    }
    if (req.method !== "GET" && req.method !== "HEAD") return send(req, res, 405, "Method not allowed\n", undefined, { allow: "GET, HEAD" });
    if (path === "/state") return send(req, res, 200, JSON.stringify({ pages: echoes, served }), "application/json; charset=utf-8");
    if (path === "/slow.js") {
      const timer = setTimeout(() => {
        timers.delete(timer);
        send(req, res, 200, "/* slow fixture resource */\n", "text/javascript; charset=utf-8");
      }, boundedDelay(query.get("ms"), 1500));
      timers.add(timer);
      return undefined;
    }
    const page = pages.get(path);
    if (page) {
      served[path] = (served[path] ?? 0) + 1;
      return send(req, res, 200, page, "text/html; charset=utf-8");
    }
    const asset = assets.get(path);
    if (asset) return send(req, res, 200, asset.body, asset.type);
    return send(req, res, 404, "Not found\n");
  });

  await new Promise((accept, reject) => {
    server.once("error", reject);
    server.listen(port, LOOPBACK, () => {
      server.off("error", reject);
      accept();
    });
  });
  actual = server.address().port;
  return {
    port: actual,
    url: `http://127.0.0.1:${actual}/`,
    state: () => JSON.parse(JSON.stringify({ pages: echoes, served })),
    close: () =>
      new Promise((accept) => {
        for (const timer of timers) clearTimeout(timer);
        timers.clear();
        server.close(() => accept());
        server.closeAllConnections();
      }),
  };
}

function isMain() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  const flag = process.argv.indexOf("--port");
  const raw = flag > 0 ? process.argv[flag + 1] : String(DEFAULT_PORT);
  const port = raw !== undefined && /^\d{1,5}$/.test(raw) ? Number(raw) : Number.NaN;
  if (!Number.isInteger(port) || port > 65_535) {
    process.stderr.write("usage: node server.mjs [--port <0-65535>]\n");
    process.exit(64);
  }
  startPageFixture({ port }).then(
    (fixture) => {
      process.stdout.write(`continuity page fixture ready port=${fixture.port}\n`);
      const stop = () => fixture.close().then(() => process.exit(0));
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
    },
    (error) => {
      process.stderr.write(`continuity page fixture failed: ${error?.code ?? "error"}\n`);
      process.exit(1);
    },
  );
}
