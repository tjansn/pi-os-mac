import assert from "node:assert/strict";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { createAgentSession, ModelRuntime, SessionManager, type ExtensionAPI, type InlineExtension } from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream, Type, type AssistantMessage } from "@earendil-works/pi-ai";
import { READ_ONLY_TOOLS } from "../src/agent/agentRunner.js";
import {
  boundScriptOutput, clampScriptOptions, CODEMODE_TOOL_NAMES, codemodeExtensionFactories, createCodemodePolicyExtension,
  MODEL_ONLY_TOOLS, SCRIPT_CALLABLE_TOOLS,
} from "../src/agent/codemodePolicy.js";
import { createComputerUseExtension, USE_ACTIVE_WINDOW_TOOL, type ContextHooks } from "../src/agent/computerUseExtension.js";
import { createLauncherToolsExtension, LAUNCHER_TOOL_NAMES, type FileRefLedger } from "../src/agent/launcherTools.js";
import { createSessionSettings, loadAgentResources, registerResourceProviders } from "../src/agent/resources.js";
import type { FileCandidate } from "../src/contracts/launcher.js";
import type { HostClient } from "../src/hostClient.js";
import type { BrowserSession } from "../src/browser/session.js";
import { BROWSER_TOOLS } from "../src/browser/tools.js";

const png = await readFile(new URL("../../shared/fixtures/captures/window.png", import.meta.url));
const searchResponse = JSON.parse(await readFile(new URL("../../shared/fixtures/launcher/search-files-response.json", import.meta.url), "utf8"));
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

test("script options: a deadline is always set and capped; pi never gets a budget it would spill", () => {
  const plain = clampScriptOptions("return 1;")!;
  assert.equal(plain.code, '// @options: {"max_output_tokens":2147483648,"timeout_ms":15000}\nreturn 1;');
  assert.equal(plain.outputTokens, 10_000);
  const greedy = clampScriptOptions('// @options: {"timeout_ms": 600000, "max_output_tokens": 999999}\nreturn 2;')!;
  assert.equal(greedy.code, '// @options: {"max_output_tokens":2147483648,"timeout_ms":30000}\nreturn 2;');
  assert.equal(greedy.outputTokens, 10_000);
  const short = clampScriptOptions('  // @options: {"timeout_ms": 50, "max_output_tokens": 100}\r\nwhile (true) {}')!;
  assert.match(short.code, /"timeout_ms":50\}\nwhile \(true\) \{\}$/);
  assert.equal(short.outputTokens, 100);
  // Malformed options are left for pi to reject before anything runs.
  for (const bad of ['// @options: {"timeout_ms": ', "// @options: [1]", '// @options: {"timeout_ms": 5}']) assert.equal(clampScriptOptions(bad), undefined);
});

test("over-budget script output keeps head and tail in memory only", () => {
  const content = [{ type: "text" as const, text: "Script completed\nOutput:\n" }, { type: "text" as const, text: "x".repeat(500) + "END" }];
  assert.equal(boundScriptOutput(content, 1_000), undefined);
  const bounded = boundScriptOutput(content, 50)!;
  assert.equal(bounded.length, 1);
  const text = (bounded[0] as { text: string }).text;
  assert.ok(text.startsWith("Script completed\nOutput:\n"));
  assert.ok(text.endsWith("END"));
  assert.match(text, /characters of script output omitted/);
  assert.doesNotMatch(text, /Full output|pi-codemode-|tmp/);
});

test("policy: nested calls reach only read-only tools; options can never re-enable model-only tools", async () => {
  const handlers = new Map<string, (event: any) => any>();
  const fake = { on: (name: string, handler: any) => handlers.set(name, handler) } as unknown as ExtensionAPI;
  const policy = createCodemodePolicyExtension({ scriptCallable: [...SCRIPT_CALLABLE_TOOLS, "desktop_act", "fixture_reader"] }) as Exclude<InlineExtension, Function>;
  await policy.factory(fake);
  const call = handlers.get("tool_call")!;
  for (const name of [...MODEL_ONLY_TOOLS, "bash", "write", "fixture_writer"]) {
    const result = call({ type: "tool_call", toolName: name, toolCallId: "c/1", parentToolCallId: "c", input: {} });
    assert.equal(result?.block, true, name);
    assert.match(result.reason, /^policy_blocked: /);
  }
  assert.match(call({ toolName: "desktop_capture_window", toolCallId: "c/2", parentToolCallId: "c", input: {} }).reason, /Call it directly/);
  for (const name of [...SCRIPT_CALLABLE_TOOLS, "fixture_reader"]) {
    assert.equal(call({ toolName: name, toolCallId: "c/3", parentToolCallId: "c", input: {} }), undefined, name);
  }
  // Model-issued calls are untouched by the nested-call policy.
  assert.equal(call({ toolName: "desktop_act", toolCallId: "m1", input: { action: "focus" } }), undefined);
  assert.deepEqual([...SCRIPT_CALLABLE_TOOLS].filter(name => (MODEL_ONLY_TOOLS as readonly string[]).includes(name)), []);
});

/**
 * A real pi 1.0 session: pi-os extensions, the codemode factories, an offline provider whose
 * stream is scripted (no network), and fake host routes.
 */
async function scriptedSession(root: string, turns: ((call: number) => AssistantMessage["content"])[], browser?: BrowserSession, hooks?: ContextHooks) {
  const dir = resolve("test/fixtures/global-agent-dir");
  const hostCalls: { name: string; args: any }[] = [];
  let shots = 1;
  const host = { invokeTool: async (name: string, args: any) => {
    hostCalls.push({ name, args });
    if (name === "desktop.captureWindow") {
      const imageId = `shot-${++shots}`, filePath = join(root, `${imageId}.png`);
      await writeFile(filePath, png);
      return { ok: true, result: { kind: "window", filePath, imageId, imageWidth: 640, imageHeight: 400 } };
    }
    if (name === "launcher.searchFiles") return searchResponse;
    if (name === "desktop.getContext") return { ok: true, result: { id: "ctx-fixed", targetWindow: { title: "Fixture" } } };
    return { ok: true, result: { posted: true } };
  } } as unknown as HostClient;
  const entries = new Map<string, FileCandidate>();
  const ledger: FileRefLedger = { register: (c) => { const ref = `f${entries.size + 1}`; entries.set(ref, c); return ref; }, token: (ref) => entries.get(ref)?.token };
  const engines = { calc: () => ({ ok: true as const, text: "4" }), convertCurrency: () => null, timeIn: () => null };
  const writes = { count: 0 }, seenCode: string[] = [];
  const fixture: InlineExtension = { name: "codemode-fixture", factory(pi) {
    pi.registerProvider("codemode-fixture", { api: "openai-completions", baseUrl: "https://never-called.invalid/v1", apiKey: "dummy-fixture-key",
      models: [{ id: "scripted", name: "Scripted", reasoning: false, input: ["text", "image"], contextWindow: 200_000, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
    // Callable from scripts by exposure, but not on pi-os's list: the policy must refuse it.
    pi.registerTool({ name: "fixture_writer", label: "Writer", description: "Fixture mutation", parameters: Type.Object({}), exposure: "codemode",
      async execute() { writes.count++; return { content: [{ type: "text", text: "wrote" }], details: {} }; } });
    // Any tool can run others through ctx.executeTool(), exactly like codemode does.
    pi.registerTool({ name: "fixture_probe", label: "Probe", description: "Fixture nested caller", parameters: Type.Object({}),
      async execute(_id, _params, _signal, _update, ctx) {
        const outcomes: Record<string, string> = {};
        for (const name of [...MODEL_ONLY_TOOLS, "fixture_writer", "instant_calc"]) {
          const outcome = await ctx.executeTool(name, name === "instant_calc" ? { expression: "2+2" } : { action: "click", x: 1, y: 2 });
          outcomes[name] = `${outcome.isError ? "error" : "ok"}: ${outcome.result.content.map(c => c.type === "text" ? c.text : "[image]").join(" ")}`;
        }
        return { content: [{ type: "text", text: JSON.stringify(outcomes) }], details: {} };
      } });
    // Registered after the policy, so it observes the clamped script source.
    pi.on("tool_call", (event) => { if (event.toolName === "codemode" && !event.parentToolCallId) seenCode.push(String(event.input.code)); return undefined; });
  } };
  const computer = createComputerUseExtension("ctx-fixed", host, root, false, "darwin", "shot-1", browser,
    { postActionCapture: true, settleMs: () => 0, ...(hooks ? { context: hooks } : {}) });
  const launcher = createLauncherToolsExtension({ engines, host, ledger, readOnly: false, homeDir: "/Users/fixture" });
  const loader = await loadAgentResources([computer, launcher, ...codemodeExtensionFactories(), fixture], process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing-models.json") });
  const cleanup = await registerResourceProviders(loader, runtime);
  const tools = [...READ_ONLY_TOOLS, ...(browser ? BROWSER_TOOLS : ["desktop_act"]), ...LAUNCHER_TOOL_NAMES, ...CODEMODE_TOOL_NAMES, "fixture_writer", "fixture_probe",
    ...(hooks ? [USE_ACTIVE_WINDOW_TOOL] : [])];
  const { session } = await createAgentSession({ modelRuntime: runtime, resourceLoader: loader, model: runtime.getModel("codemode-fixture", "scripted"),
    tools, sessionManager: SessionManager.inMemory(), settingsManager: createSessionSettings(true, process.cwd(), dir) });
  let call = 0;
  session.agent.streamFunction = (model) => {
    const stream = createAssistantMessageEventStream();
    const content = turns[Math.min(call, turns.length - 1)]!(call++);
    const toolUse = content.some(part => part.type === "toolCall");
    const message: AssistantMessage = { role: "assistant", provider: model.provider, model: model.id, api: model.api, timestamp: Date.now(), usage,
      content, stopReason: toolUse ? "toolUse" : "stop" };
    stream.push({ type: "done", reason: toolUse ? "toolUse" : "stop", message }); stream.end();
    return stream;
  };
  const results = () => session.messages.flatMap(m => {
    const message = m as { role?: string; toolName?: string; content?: { type: string; text?: string }[] };
    return message.role === "toolResult" ? [{ tool: message.toolName, text: (message.content ?? []).map(c => c.text ?? `[${c.type}]`).join("\n") }] : [];
  });
  return { session, hostCalls, writes, seenCode, results, dispose: () => { session.dispose(); cleanup(); } };
}

const SCRIPT = `
const out = {};
for (const name of ["desktop_act", "desktop_capture_window", "browser_act", "open_item", "codemode"]) {
  try { await tools[name]({ action: "click", x: 1, y: 2 }); out[name] = "CALLED"; }
  catch (error) { out[name] = "refused"; }
}
try { await tools.fixture_writer({}); out.fixture_writer = "CALLED"; } catch (error) { out.fixture_writer = String(error.message).slice(0, 80); }
out.calc = await tools.instant_calc({ expression: "2+2" });
out.files = await tools.find_files({ nameGroups: [["invoice"]] });
out.context = typeof (await tools.desktop_get_context({}));
return out;`;

test("a real codemode script cannot capture, act, open or call unlisted tools; read tools work and authority stays put", async () => {
  const root = join(process.cwd(), "test", ".tmp-codemode-session");
  await mkdir(root, { recursive: true });
  const run = await scriptedSession(root, [
    () => [{ type: "toolCall", id: "call_script", name: "codemode", arguments: { code: SCRIPT } }],
    () => [{ type: "toolCall", id: "call_click", name: "desktop_act", arguments: { action: "click", x: 5, y: 6 } }],
    () => [{ type: "text", text: "done" }],
  ]);
  try {
    // Declared descriptions: read tools advertise their script form, model-only tools do not.
    const declared = new Map(run.session.agent.state.tools.map(t => [t.name, t.description]));
    assert.match(declared.get("instant_calc")!, /Codemode: `tools\.instant_calc\(args\)` resolves to `\{ ok, value\?, approximate\?, error\? \}`/);
    for (const name of ["desktop_act", "desktop_capture_window", "open_item"]) assert.doesNotMatch(declared.get(name)!, /Codemode:/, name);

    await run.session.prompt("go", { expandPromptTemplates: false });
    const [script, click] = run.results();
    assert.equal(script!.tool, "codemode");
    assert.match(script!.text, /^Script completed/);
    const out = JSON.parse(script!.text.slice(script!.text.indexOf("{")));
    for (const name of ["desktop_act", "desktop_capture_window", "browser_act", "open_item", "codemode"]) assert.equal(out[name], "refused", name);
    assert.match(out.fixture_writer, /^policy_blocked: fixture_writer cannot be called from a script/);
    assert.equal(run.writes.count, 0);
    assert.deepEqual(out.calc, { ok: true, value: "4", approximate: false });
    assert.equal(out.files.items[0].ref, "f1");
    assert.equal(out.context, "string");
    for (const secret of ["tok_", "/Users/"]) assert(!script!.text.includes(secret), secret);
    assert.match(run.seenCode[0]!, /^\/\/ @options: \{"max_output_tokens":2147483648,"timeout_ms":15000\}\n/);

    // The script reached the host only through read routes: no input, no capture.
    const scriptCalls = run.hostCalls.slice(0, run.hostCalls.findIndex(c => c.name === "input.click"));
    assert.deepEqual(scriptCalls.map(c => c.name), ["launcher.searchFiles", "desktop.getContext"]);
    // The next direct click is still authorized by the request screenshot, then re-captured.
    const rest = run.hostCalls.slice(scriptCalls.length);
    assert.deepEqual(rest.map(c => c.name), ["input.click", "desktop.captureWindow"]);
    assert.equal(rest[0]!.args.screenshotId, "shot-1");
    assert.equal(click!.tool, "desktop_act");
    assert.match(click!.text, /after the action: 640×400 pixels[\s\S]*\[image\]/);
  } finally { run.dispose(); await rm(root, { recursive: true, force: true }); }
});

test("a runaway script stops at its clamped deadline without touching the host", async () => {
  const root = join(process.cwd(), "test", ".tmp-codemode-deadline");
  await mkdir(root, { recursive: true });
  const run = await scriptedSession(root, [
    () => [{ type: "toolCall", id: "call_loop", name: "codemode", arguments: { code: '// @options: {"timeout_ms": 200}\nwhile (true) {}' } }],
    () => [{ type: "text", text: "done" }],
  ]);
  try {
    const started = Date.now();
    await run.session.prompt("go", { expandPromptTemplates: false });
    assert.ok(Date.now() - started < 10_000);
    const [script] = run.results();
    assert.match(script!.text, /^Script failed[\s\S]*timed out/);
    assert.match(run.seenCode[0]!, /"timeout_ms":200\}\nwhile \(true\) \{\}$/);
    assert.deepEqual(run.hostCalls, []);
  } finally { run.dispose(); await rm(root, { recursive: true, force: true }); }
});

test("ctx.executeTool (the path every script call takes) refuses model-only and unlisted tools before any host call", async () => {
  const root = join(process.cwd(), "test", ".tmp-codemode-probe");
  await mkdir(root, { recursive: true });
  const run = await scriptedSession(root, [
    () => [{ type: "toolCall", id: "call_probe", name: "fixture_probe", arguments: {} }],
    () => [{ type: "text", text: "done" }],
  ]);
  try {
    await run.session.prompt("go", { expandPromptTemplates: false });
    const outcomes = JSON.parse(run.results()[0]!.text) as Record<string, string>;
    for (const name of MODEL_ONLY_TOOLS) assert.match(outcomes[name]!, new RegExp(`^error: Tool ${name} not found`), name);
    assert.match(outcomes.fixture_writer!, /^error: policy_blocked: fixture_writer cannot be called from a script/);
    assert.equal(outcomes.instant_calc, "ok: 2+2 = 4");
    assert.equal(run.writes.count, 0);
    assert.deepEqual(run.hostCalls, []);
  } finally { run.dispose(); await rm(root, { recursive: true, force: true }); }
});

test("large script output is bounded by the policy and never spilled to a temp file", async () => {
  const root = join(process.cwd(), "test", ".tmp-codemode-output");
  await mkdir(root, { recursive: true });
  const run = await scriptedSession(root, [
    () => [{ type: "toolCall", id: "call_big", name: "codemode", arguments: { code: '// @options: {"max_output_tokens": 100}\ntext("A".repeat(60000)); return "TAIL";' } }],
    () => [{ type: "text", text: "done" }],
  ]);
  try {
    await run.session.prompt("go", { expandPromptTemplates: false });
    const message = run.session.messages.find(m => (m as { role?: string }).role === "toolResult") as { content: { type: string; text?: string }[]; details?: Record<string, unknown> };
    const text = message.content.map(c => c.text ?? "").join("\n");
    assert.ok(text.length < 1_000, String(text.length));
    assert.match(text, /^Script completed[\s\S]*characters of script output omitted[\s\S]*TAIL$/);
    assert.doesNotMatch(text, /Full output|Could not save/);
    assert.equal(message.details?.fullOutputPath, undefined);
  } finally { run.dispose(); await rm(root, { recursive: true, force: true }); }
});

test("with a pinned Brave tab, scripts may read browser_snapshot but can never reach browser_act", async () => {
  const root = join(process.cwd(), "test", ".tmp-codemode-browser");
  await mkdir(root, { recursive: true });
  const browser = { acts: 0,
    exclusive: <T>(run: () => Promise<T>) => run(),
    snapshot: async () => ({ text: '[rfix-1-1] button "Like fixture"', truncated: false }),
    act: async () => { browser.acts++; return { performed: true as const, verification: "Action dispatched once." }; },
    dispose: async () => {} };
  const code = `const out = {};
try { await tools.browser_act({ action: "click", ref: "rfix-1-1" }); out.act = "CALLED"; } catch (error) { out.act = "refused"; }
out.snapshot = await tools.browser_snapshot({});
return out;`;
  const run = await scriptedSession(root, [
    () => [{ type: "toolCall", id: "call_script", name: "codemode", arguments: { code } }],
    () => [{ type: "toolCall", id: "call_probe", name: "fixture_probe", arguments: {} }],
    () => [{ type: "text", text: "done" }],
  ], browser as unknown as BrowserSession);
  try {
    assert.ok(run.session.agent.state.tools.some(t => t.name === "browser_act"));
    await run.session.prompt("go", { expandPromptTemplates: false });
    const [script, probe] = run.results();
    const out = JSON.parse(script!.text.slice(script!.text.indexOf("{")));
    assert.equal(out.act, "refused");
    assert.match(out.snapshot, /Untrusted page content[\s\S]*Like fixture/);
    assert.match(JSON.parse(probe!.text).browser_act, /^error: Tool browser_act not found/);
    assert.equal(browser.acts, 0);
  } finally { run.dispose(); await rm(root, { recursive: true, force: true }); }
});

test("coordinate authority follows images the model has seen: a click batched after another click keeps the old one", async () => {
  const root = join(process.cwd(), "test", ".tmp-codemode-batch");
  await mkdir(root, { recursive: true });
  const run = await scriptedSession(root, [
    // One model message, two clicks: both were planned from the request screenshot.
    () => [{ type: "toolCall", id: "call_a", name: "desktop_act", arguments: { action: "click", x: 1, y: 1 } },
      { type: "toolCall", id: "call_b", name: "desktop_act", arguments: { action: "click", x: 2, y: 2 } }],
    // Next turn: the model has now seen the captures both clicks returned.
    () => [{ type: "toolCall", id: "call_c", name: "desktop_act", arguments: { action: "click", x: 3, y: 3 } }],
    () => [{ type: "text", text: "done" }],
  ]);
  try {
    await run.session.prompt("go", { expandPromptTemplates: false });
    const clicks = run.hostCalls.filter(c => c.name === "input.click").map(c => c.args.screenshotId);
    // The second click must not inherit shot-2, which only reaches the model after the batch
    // (the host then refuses it as capture_stale); the next turn may use the latest capture.
    assert.deepEqual(clicks, ["shot-1", "shot-1", "shot-3"]);
  } finally { run.dispose(); await rm(root, { recursive: true, force: true }); }
});

test("use_active_window is model-only in a scope-aware session: a script can neither pull the window nor reach the host", async () => {
  const root = join(process.cwd(), "test", ".tmp-codemode-loader");
  await mkdir(root, { recursive: true });
  const asked: string[] = [];
  const hooks: ContextHooks = {
    pullState: () => { asked.push("pullState"); return "allowed"; }, pulled: () => { asked.push("pulled"); },
    browserPage: async () => undefined, takePromptContent: () => undefined,
  };
  const run = await scriptedSession(root, [
    () => [{ type: "toolCall", id: "call_probe", name: "fixture_probe", arguments: {} }],
    () => [{ type: "text", text: "done" }],
  ], undefined, hooks);
  try {
    assert((MODEL_ONLY_TOOLS as readonly string[]).includes(USE_ACTIVE_WINDOW_TOOL));
    assert(run.session.agent.state.tools.some(tool => tool.name === USE_ACTIVE_WINDOW_TOOL), "registered and declared to the model");
    await run.session.prompt("go", { expandPromptTemplates: false });
    const outcomes = JSON.parse(run.results()[0]!.text) as Record<string, string>;
    assert.match(outcomes[USE_ACTIVE_WINDOW_TOOL]!, /^error: /);
    assert.deepEqual(asked, [], "the loader never ran");
    assert.deepEqual(run.hostCalls, []);
  } finally { run.dispose(); await rm(root, { recursive: true, force: true }); }
});
