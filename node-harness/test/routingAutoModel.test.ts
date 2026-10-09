import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import {
  createAssistantMessageEventStream, getSupportedThinkingLevels,
  type Api, type AssistantMessage, type Message, type Model, type ModelThinkingLevel, type ToolResultMessage, type UserMessage,
} from "@earendil-works/pi-ai";
import {
  createAgentSession, ModelRuntime, SessionManager, SettingsManager, VIRTUAL_MODEL_STATE_ENTRY,
  type ModelRoute, type ModelRouteRequest, type VirtualModelDefinition,
} from "@earendil-works/pi-coding-agent";
import { listAvailableModels } from "../src/agent/modelCatalog.js";
import { loadAgentResources } from "../src/agent/resources.js";
import {
  AUTO_MODEL_ID, AUTO_PROVIDER, biasForThinkingLevel, buildRouteInput, buildRoutingCatalog, createEscalateExtension, createEscalateTool, decide,
  DEFAULT_ROUTING_SETTINGS, ESCALATE_TOOL_NAME, isAutoSelection, LatencyStats, parseRouterState, registerAutoModel,
  targetKey, thinkingLevelForBias,
  type AutoModelRuntime, type AutoRouterState, type Profile, type RouteDecision, type RouteEvent, type RouteTarget,
} from "../src/agent/routing/index.js";

// ---------------------------------------------------------------------------
// Unit level: a fake runtime around the installed pi-ai catalogs (no network).

const catalogDir = mkdtempSync(join(tmpdir(), "pi-os-auto-catalog-"));
const builtins = await ModelRuntime.create({ authPath: join(catalogDir, "auth.json"), modelsPath: join(catalogDir, "missing.json"), modelsStorePath: join(catalogDir, "store.json") });
const CODEX = builtins.getModels("openai-codex");
const ANTHROPIC = builtins.getModels("anthropic");

class FakeRuntime implements AutoModelRuntime {
  definition?: VirtualModelDefinition;
  unregistered = false;
  constructor(readonly models: readonly Model<Api>[], readonly auth: Set<string>) {}
  registerVirtualModel(definition: VirtualModelDefinition) { this.definition = definition; }
  unregisterVirtualModel() { this.unregistered = true; }
  getPhysicalModel(provider: string, id: string) { return this.models.find(m => m.provider === provider && m.id === id); }
  hasConfiguredAuth(provider: string) { return this.auth.has(provider); }
  private available?: readonly Model<Api>[];
  getAvailableSnapshot() { return (this.available ??= this.models.filter(m => this.auth.has(m.provider))); }
}

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const user = (text: string, image = false): UserMessage => ({
  role: "user", timestamp: 0,
  content: image ? [{ type: "text", text }, { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }] : text,
});
const assistant = (model: Model<Api>, extra: Partial<AssistantMessage> = {}): AssistantMessage => ({
  role: "assistant", content: [{ type: "text", text: "ok" }], api: model.api, provider: model.provider, model: model.id,
  usage, stopReason: "stop", timestamp: 0, ...extra,
});
const toolResult = (id: string, toolName: string, isError = false): ToolResultMessage => ({
  role: "toolResult", toolCallId: id, toolName, content: [{ type: "text", text: isError ? "error" : "ok" }], isError, timestamp: 0,
});

/** Drives route() like pi does: state is stored when a route returns one and fed back on the next request. */
class Driver {
  state: unknown;
  readonly events: RouteEvent[] = [];
  readonly lines: string[] = [];
  readonly runtime: FakeRuntime;
  readonly handle;
  readonly stats = new LatencyStats({ log: () => {} });
  constructor(models: readonly Model<Api>[], auth: string[], priors?: readonly Profile[]) {
    this.runtime = new FakeRuntime(models, new Set(auth));
    this.handle = registerAutoModel(this.runtime, {
      stats: this.stats, log: line => this.lines.push(line), onRoute: event => this.events.push(event), ...(priors ? { priors } : {}),
    });
  }
  route(reason: ModelRouteRequest["reason"], messages: Message[], extra: Partial<ModelRouteRequest> = {}): ModelRoute {
    const definition = this.runtime.definition!;
    const route = definition.route({
      model: { id: AUTO_MODEL_ID, provider: AUTO_PROVIDER } as Model<Api>, thinkingLevel: "medium", reason, messages,
      ...(reason === "direct" ? {} : { state: this.state }), ...extra,
    }) as ModelRoute;
    if (route.state !== undefined && reason !== "direct") this.state = route.state;
    return route;
  }
  get routerState(): AutoRouterState { return parseRouterState(this.state)!; }
}
const label = (route: ModelRoute) => `${route.model.provider}/${route.model.id}@${route.thinkingLevel}`;
const codexDecision = (text: string, extra: Partial<Parameters<typeof buildRouteInput>[2]> = {}, hasScreenshot = false): RouteDecision =>
  decide(buildRouteInput(text, { surface: "other", hasScreenshot, browserCdp: false }, extra), buildRoutingCatalog(CODEX), DEFAULT_ROUTING_SETTINGS);
const model = (provider: string, id: string) => [...CODEX, ...ANTHROPIC].find(m => m.provider === provider && m.id === id)!;

test("registers pi-os/auto with low/medium/high mapped to speed/balanced/quality", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  const definition = driver.runtime.definition!;
  assert.equal(definition.provider, "pi-os");
  assert.equal(definition.id, "auto");
  assert.deepEqual(definition.thinkingLevels, ["low", "medium", "high"]);
  assert.deepEqual(["low", "medium", "high"].map(biasForThinkingLevel), ["speed", "balanced", "quality"]);
  assert.deepEqual((["speed", "balanced", "quality"] as const).map(thinkingLevelForBias), ["low", "medium", "high"]);
  assert.equal(isAutoSelection({ provider: "pi-os", modelId: "auto" }), true);
  assert.equal(isAutoSelection({ provider: "openai-codex", modelId: "auto" }), false);
  driver.handle.unregister();
  assert.equal(driver.runtime.unregistered, true);
});

test("user: consumes the precomputed decision once; without one it falls back to pure heuristics", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  driver.handle.setDecision(codexDecision("write a python function that parses iso dates"));
  const first = driver.route("user", [user("## Request\nwrite a python function that parses iso dates")]);
  assert.equal(label(first), "openai-codex/gpt-6.1-sol@low");
  assert.equal(driver.events.at(-1)?.cause, "decision");
  assert.equal(driver.handle.lastTier(), "standard");
  // The slot is empty now: the next user turn (e.g. a steer message) classifies its own text.
  const second = driver.route("user", [user("x"), assistant(model("openai-codex", "gpt-6.1-sol")), user("## Request\nwhat's the capital of france")],
    { previous: { model: model("openai-codex", "gpt-6.1-sol"), thinkingLevel: "low" } });
  assert.equal(driver.events.at(-1)?.cause, "fallback");
  assert.equal(label(second), "openai-codex/gpt-6.1-sol@low", "follow-up never downgrades below the last tier");
});

test("user: an expired decision is ignored; the virtual level sets the fallback bias", () => {
  let now = 0;
  const runtime = new FakeRuntime(CODEX, new Set(["openai-codex"]));
  const handle = registerAutoModel(runtime, { now: () => now });
  handle.setDecision(codexDecision("denk gründlich nach"));
  now = 10 * 60_000;
  const route = runtime.definition!.route({ model: {} as Model<Api>, thinkingLevel: "low", reason: "user", messages: [user("click the submit button")] }) as ModelRoute;
  assert.equal(`${route.model.id}@${route.thinkingLevel}`, "gpt-6-luna@off", "speed bias: act_in_app stays quick");
});

test("auth: unauthenticated targets are skipped; nothing usable throws a clear error instead of a credential leak", () => {
  const driver = new Driver([...CODEX, ...ANTHROPIC], ["openai-codex"]);
  const anthropicOnly = decide(buildRouteInput("what's the capital of france", { surface: "other", hasScreenshot: false, browserCdp: false }),
    buildRoutingCatalog(ANTHROPIC), DEFAULT_ROUTING_SETTINGS);
  driver.handle.setDecision({ ...anthropicOnly, ladder: [...anthropicOnly.ladder, { provider: "openai-codex", id: "gpt-6-sol", thinkingLevel: "off", tier: "fast" }] });
  assert.equal(label(driver.route("user", [user("what's the capital of france")])), "openai-codex/gpt-6-sol@off");
  const nothing = new Driver(ANTHROPIC, []);
  nothing.handle.setDecision(anthropicOnly);
  assert.throws(() => nothing.route("user", [user("what's the capital of france")]), /^Error: no_authenticated_model/);
});

test("loopback models are never reached through fallbacks unless allowLocalModels", () => {
  const splash = { ...luna(), provider: "splash", id: "qwen-local", baseUrl: "http://127.0.0.1:8002/v1", api: "openai-completions" } as Model<Api>;
  const runtime = new FakeRuntime([splash], new Set(["splash"]));
  let allowLocalModels = false;
  registerAutoModel(runtime, { settings: () => ({ ...DEFAULT_ROUTING_SETTINGS, allowLocalModels }) });
  const request = { model: {} as Model<Api>, thinkingLevel: "medium" as const, reason: "user" as const,
    messages: [user("hi"), assistant(splash), user("what's the capital of france")], previous: { model: splash, thinkingLevel: "off" as const } };
  assert.throws(() => runtime.definition!.route(request), /no_authenticated_model/);
  allowLocalModels = true;
  assert.equal((runtime.definition!.route(request) as ModelRoute).model.provider, "splash");
});

test("user: an attached image skips text-only targets in the pool", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  const decision = codexDecision("what's the capital of france");
  driver.handle.setDecision({ ...decision, model: { provider: "openai-codex", id: "gpt-5.3-codex-spark", thinkingLevel: "off", tier: "quick" },
    alternates: [decision.model!, ...decision.alternates] });
  assert.equal(label(driver.route("user", [user("what is this", true)])), "openai-codex/gpt-6-luna@off");
  driver.handle.setDecision({ ...decision, model: { provider: "openai-codex", id: "gpt-5.3-codex-spark", thinkingLevel: "off", tier: "quick" } });
  assert.equal(label(driver.route("user", [user("plain text")])), "openai-codex/gpt-5.3-codex-spark@off", "text-only is fine without an image");
});

test("fallback: an image in the user message (screenshot or attachment) needs a vision model even without a decision", () => {
  const runtime = new FakeRuntime(CODEX, new Set(["openai-codex"]));
  const spark = { provider: "openai-codex", id: "gpt-5.3-codex-spark", thinkingLevel: "off" as const };
  const events: RouteEvent[] = [];
  registerAutoModel(runtime, { settings: () => ({ ...DEFAULT_ROUTING_SETTINGS, tierOverrides: { quick: spark } }), onRoute: event => events.push(event) });
  const route = (message: UserMessage) => runtime.definition!.route({ model: {} as Model<Api>, thinkingLevel: "medium", reason: "user", messages: [message] }) as ModelRoute;
  assert.equal(label(route(user("what's the capital of france", true))), "openai-codex/gpt-6-luna@off");
  assert.equal(events.at(-1)?.cause, "fallback");
  assert.ok(events.at(-1)?.reasons.includes("image-attachment"), "decided for vision, not only filtered in the pool");
  assert.ok(!events.at(-1)?.reasons.includes("no-vision-model"));
  assert.equal(label(route(user("what's the capital of france"))), "openai-codex/gpt-5.3-codex-spark@off");
});

function startQuick(driver: Driver) {
  driver.handle.setDecision(codexDecision("what's the capital of france"));
  driver.route("user", [user("what's the capital of france")]);
}
const luna = () => model("openai-codex", "gpt-6-luna");

test("continuation: sticky without rewriting state; pi_os_escalate moves one rung, at most twice per turn", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  startQuick(driver);
  const history: Message[] = [user("what's the capital of france"), assistant(luna()), toolResult("t1", "desktop_get_context")];
  const sticky = driver.route("continuation", history);
  assert.equal(label(sticky), "openai-codex/gpt-6-luna@off");
  assert.equal(sticky.state, undefined, "unchanged state is not re-appended to the session");

  // Fast and standard share gpt-6.1-sol@low (one rung); gpt-6-sol@off is no longer on the ladder.
  history.push(assistant(luna()), toolResult("e1", ESCALATE_TOOL_NAME));
  assert.equal(label(driver.route("continuation", history)), "openai-codex/gpt-6.1-sol@low");
  assert.equal(driver.events.at(-1)?.cause, "escalate:tool");
  assert.deepEqual(driver.routerState.consumed, ["e1"]);
  // The same tool result is not acted on again.
  assert.equal(label(driver.route("continuation", history)), "openai-codex/gpt-6.1-sol@low");

  history.push(assistant(model("openai-codex", "gpt-6.1-sol")), toolResult("e2", ESCALATE_TOOL_NAME));
  assert.equal(label(driver.route("continuation", history)), "openai-codex/gpt-6.1-sol@medium");
  history.push(assistant(model("openai-codex", "gpt-6.1-sol")), toolResult("e3", ESCALATE_TOOL_NAME));
  assert.equal(label(driver.route("continuation", history)), "openai-codex/gpt-6.1-sol@medium", "cap: 2 escalations per user turn");
  assert.equal(driver.routerState.escalations, 2);

  // A new user turn resets the budget.
  driver.handle.setDecision(codexDecision("what's the capital of spain", { followup: true, lastTier: driver.handle.lastTier() }));
  driver.route("user", [...history, assistant(model("openai-codex", "gpt-6.1-sol")), user("and spain?")]);
  assert.equal(driver.routerState.escalations, 0);
  assert.equal(driver.routerState.tier, "deep", "follow-up keeps the escalated tier");
});

test("continuation: repeated tool errors or a long turn escalate quick/fast tiers only, once per fresh evidence", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  startQuick(driver);
  const history: Message[] = [user("q"), assistant(luna()), toolResult("a", "desktop_act", true), assistant(luna()), toolResult("b", "desktop_act", true)];
  assert.equal(label(driver.route("continuation", history)), "openai-codex/gpt-6.1-sol@low");
  assert.equal(driver.events.at(-1)?.cause, "escalate:errors");
  assert.equal(label(driver.route("continuation", history)), "openai-codex/gpt-6.1-sol@low", "same errors do not escalate twice");

  const long = new Driver(CODEX, ["openai-codex"]);
  startQuick(long);
  const many: Message[] = [user("q")];
  for (let i = 0; i < 9; i++) many.push(assistant(luna()), toolResult(`r${i}`, "desktop_get_context"));
  assert.equal(label(long.route("continuation", many)), "openai-codex/gpt-6.1-sol@low");
  assert.equal(long.events.at(-1)?.cause, "escalate:long-turn");

  const standard = new Driver(CODEX, ["openai-codex"]);
  standard.handle.setDecision(codexDecision("write a python function"));
  standard.route("user", [user("write a python function")]);
  const sol = model("openai-codex", "gpt-6.1-sol");
  assert.equal(label(standard.route("continuation", [user("x"), assistant(sol), toolResult("a", "t", true), assistant(sol), toolResult("b", "t", true)])),
    "openai-codex/gpt-6.1-sol@low", "standard and above stay put on tool errors");
});

test("retry: rate limits fail over to another provider first, penalize the failed model, then same-provider siblings", () => {
  const driver = new Driver([...CODEX, ...ANTHROPIC], ["openai-codex", "anthropic"]);
  const decision = codexDecision("what's the capital of france");
  const haiku: RouteTarget = { provider: "anthropic", id: "claude-haiku-4-5", thinkingLevel: "off", tier: "quick" };
  driver.handle.setDecision({ ...decision, alternates: [...decision.alternates, haiku] });
  driver.route("user", [user("q")]);
  const failed = { model: luna(), thinkingLevel: "off" as ModelThinkingLevel, message: assistant(luna(), { stopReason: "error", errorMessage: "429 Too Many Requests", content: [] }) };
  assert.equal(label(driver.route("retry", [user("q")], { failed })), "anthropic/claude-haiku-4-5@off");
  assert.equal(driver.events.at(-1)?.cause, "failover:rate");
  assert.equal(driver.stats.blocked("openai-codex", "gpt-6-luna"), true);

  const codexOnly = new Driver(CODEX, ["openai-codex"]);
  startQuick(codexOnly);
  assert.equal(label(codexOnly.route("retry", [user("q")], { failed: { ...failed, message: { ...failed.message, errorMessage: "529 overloaded" } } })),
    "openai-codex/gpt-5.6-luna@off");
});

test("retry: context overflow moves to a larger window; transient errors retry the same model once, then a sibling", () => {
  const small = { ...luna(), id: "luna-small", contextWindow: 32_000 } as Model<Api>;
  const models = [...CODEX, small];
  const driver = new Driver(models, ["openai-codex"]);
  const decision = codexDecision("what's the capital of france");
  driver.handle.setDecision({ ...decision, model: { provider: "openai-codex", id: "luna-small", thinkingLevel: "off", tier: "quick" },
    alternates: [decision.model!, ...decision.alternates] });
  driver.route("user", [user("q")]);
  const overflow = { model: small, thinkingLevel: "off" as ModelThinkingLevel,
    message: assistant(small, { stopReason: "error", errorMessage: "prompt is too long: 40000 tokens > 32000 maximum", content: [] }) };
  assert.equal(label(driver.route("retry", [user("q")], { failed: overflow })), "openai-codex/gpt-6-luna@off");
  assert.equal(driver.events.at(-1)?.cause, "failover:context");

  const transient = new Driver(CODEX, ["openai-codex"]);
  startQuick(transient);
  const failed = { model: luna(), thinkingLevel: "off" as ModelThinkingLevel, message: assistant(luna(), { stopReason: "error", errorMessage: "fetch failed", content: [] }) };
  assert.equal(label(transient.route("retry", [user("q")], { failed })), "openai-codex/gpt-6-luna@off");
  assert.equal(transient.events.at(-1)?.cause, "retry-same");
  assert.equal(label(transient.route("retry", [user("q")], { failed })), "openai-codex/gpt-5.6-luna@off");
  assert.equal(transient.events.at(-1)?.cause, "failover:retry");
});

test("health blocks demote: with every model blocked, user and direct requests still route (never a false no-credentials error)", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  driver.stats.block("openai-codex", 30 * 60_000, "quota");
  const decision = decide(buildRouteInput("what's the capital of france", { surface: "other", hasScreenshot: false, browserCdp: false }),
    buildRoutingCatalog(CODEX), DEFAULT_ROUTING_SETTINGS, { stats: driver.stats });
  driver.handle.setDecision(decision);
  assert.equal(label(driver.route("user", [user("what's the capital of france")])), "openai-codex/gpt-6-luna@off");
  assert.equal(label(driver.route("user", [user("x"), assistant(luna()), user("and of spain?")])), "openai-codex/gpt-6-luna@off", "fallback path too");
  const fresh = new Driver(CODEX, ["openai-codex"]);
  fresh.stats.block("openai-codex", 30 * 60_000, "quota");
  assert.equal(label(fresh.route("direct", [user("summarize the conversation")])), "openai-codex/gpt-6-luna@off");
});

test("retry: a successful continuation ends the retry episode, so the next failure retries the same model first", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  startQuick(driver);
  const failed = { model: luna(), thinkingLevel: "off" as ModelThinkingLevel, message: assistant(luna(), { stopReason: "error", errorMessage: "fetch failed", content: [] }) };
  driver.route("retry", [user("q")], { failed });
  assert.equal(driver.routerState.retries, 1);
  const recovered = driver.route("continuation", [user("q"), assistant(luna()), toolResult("t1", "desktop_get_context")]);
  assert.equal(label(recovered), "openai-codex/gpt-6-luna@off");
  assert.equal(driver.routerState.retries, 0);
  assert.equal(label(driver.route("retry", [user("q"), assistant(luna()), toolResult("t1", "desktop_get_context")], { failed })), "openai-codex/gpt-6-luna@off");
  assert.equal(driver.events.at(-1)?.cause, "retry-same");
});

test("direct: compaction summaries go to the cheapest quick model and store no state", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  startQuick(driver);
  const route = driver.route("direct", [user("summarize the conversation")]);
  assert.equal(label(route), "openai-codex/gpt-6-luna@off");
  assert.equal(route.state, undefined);
});

test("foreign or corrupt router state is ignored, not trusted", () => {
  assert.equal(parseRouterState({ v: 2 }), undefined);
  assert.equal(parseRouterState({ v: 1, tier: "quick", choice: { provider: "x" } }), undefined);
  const driver = new Driver(CODEX, ["openai-codex"]);
  driver.state = { v: 1, tier: "max", choice: { provider: "evil", id: "x", thinkingLevel: "max", tier: "max" }, ladder: "nope" };
  assert.equal(label(driver.route("continuation", [user("hi")], { previous: { model: luna(), thinkingLevel: "off" } })), "openai-codex/gpt-6-luna@off");
});

test("route logs and events carry labels and model ids only, never the request text", () => {
  const driver = new Driver(CODEX, ["openai-codex"]);
  driver.route("user", [user("## Request\nplease rewrite the secret fixture phrase copper robin")]);
  const failed = { model: luna(), thinkingLevel: "off" as ModelThinkingLevel, message: assistant(luna(), { stopReason: "error", errorMessage: "503 overloaded copper", content: [] }) };
  driver.route("retry", [user("copper robin")], { failed });
  const everything = JSON.stringify([driver.lines, driver.events, driver.state]);
  assert.doesNotMatch(everything, /copper|robin|secret|rewrite the/);
  assert.match(driver.lines[0]!, /^\[route\] reason=user cause=fallback tier=\w+ model=openai-codex\/[\w.-]+@\w+ reasons=intent=write,/);
});

test("pi_os_escalate is a side-effect-free acknowledgement that never echoes the model's reason", async () => {
  const tool = createEscalateTool();
  assert.equal(tool.name, ESCALATE_TOOL_NAME);
  assert.equal(tool.exposure, "model-only", "declared to the model, never callable from codemode scripts");
  const result = await tool.execute("call_1", { reason: "secret fixture reason" }, undefined, undefined, {} as never);
  assert.doesNotMatch(JSON.stringify(result), /secret fixture reason/);
  assert.deepEqual(result.details, {});
});

// ---------------------------------------------------------------------------
// Integration: real pi 1.0 ModelRuntime + AgentSession, in-process fixture provider (never contacted).

const FX_PRIORS: Profile[] = [
  { tier: "quick", provider: "fx", id: "fast", thinkingLevel: "off", ttftS: 0.5, tps: 100, ii: 10, source: "prior" },
  { tier: "standard", provider: "fx", id: "strong", thinkingLevel: "medium", ttftS: 2, tps: 60, ii: 40, source: "prior" },
];

async function fixtureRuntime() {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-auto-runtime-"));
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing-models.json"), modelsStorePath: join(dir, "models-store.json") });
  const cost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  runtime.registerProvider("fx", {
    api: "openai-completions", baseUrl: "https://never-called.invalid/v1", apiKey: "dummy-fixture-key",
    models: [
      { id: "fast", name: "Fixture fast", reasoning: false, input: ["text", "image"], contextWindow: 100_000, maxTokens: 1_024, cost },
      { id: "strong", name: "Fixture strong", reasoning: true, input: ["text", "image"], contextWindow: 200_000, maxTokens: 1_024, cost },
    ],
  });
  return runtime;
}

test("integration: getAvailable() lists pi-os/auto and the GET /models summary offers low/medium/high", async () => {
  const runtime = await fixtureRuntime();
  registerAutoModel(runtime, { priors: FX_PRIORS });
  const available = await runtime.getAvailable();
  assert.ok(available.some(m => m.provider === "pi-os" && m.id === "auto"));
  assert.equal(runtime.hasConfiguredAuth("openai-codex"), false, "fixture has no real credentials");
  const auto = runtime.getModel("pi-os", "auto")!;
  assert.deepEqual(getSupportedThinkingLevels(auto), ["low", "medium", "high"]);
  const summary = (await listAvailableModels(runtime)).find(m => m.provider === "pi-os");
  assert.deepEqual(summary, { provider: "pi-os", id: "auto", name: "Auto", reasoning: true, thinkingLevels: ["low", "medium", "high"] });
  assert.equal(runtime.getPhysicalModel("pi-os", "auto"), undefined, "virtual, never a provider model");
});

test("integration: a prompt routes to the decided physical model, escalates via pi_os_escalate, fails over on retry", async () => {
  const runtime = await fixtureRuntime();
  const stats = new LatencyStats({ log: () => {} });
  const events: RouteEvent[] = [];
  const handle = registerAutoModel(runtime, { priors: FX_PRIORS, stats, onRoute: event => events.push(event) });
  const catalog = buildRoutingCatalog(await runtime.getAvailable(), FX_PRIORS);
  const decision = decide(buildRouteInput("what's the capital of france", { surface: "other", hasScreenshot: false, browserCdp: false }), catalog, DEFAULT_ROUTING_SETTINGS);
  assert.equal(decision.model && targetKey(decision.model), "fx/fast@off");
  // An unauthenticated physical rung (built-in Codex without credentials) must be skipped, never routed to.
  const unauthenticated: RouteTarget = { provider: "openai-codex", id: "gpt-6-sol", thinkingLevel: "off", tier: "fast" };
  handle.setDecision({ ...decision, ladder: [unauthenticated, ...decision.ladder] });

  const loader = await loadAgentResources([createEscalateExtension()], process.cwd(), resolve("test/fixtures/global-agent-dir"), true);
  const { session } = await createAgentSession({
    modelRuntime: runtime, resourceLoader: loader, model: runtime.getModel(AUTO_PROVIDER, AUTO_MODEL_ID), thinkingLevel: "medium",
    tools: [ESCALATE_TOOL_NAME], sessionManager: SessionManager.inMemory(),
    settingsManager: SettingsManager.inMemory({ retry: { enabled: true, maxRetries: 2, baseDelayMs: 1 }, compaction: { enabled: false } }),
  });
  const seen: string[] = [];
  let turn = 0;
  session.agent.streamFunction = (routed, _context, options) => {
    seen.push(`${routed.provider}/${routed.id}@${(options as { reasoning?: string } | undefined)?.reasoning ?? "off"}`);
    const stream = createAssistantMessageEventStream();
    const step = turn++;
    const base = { role: "assistant" as const, api: routed.api, provider: routed.provider, model: routed.id, usage, timestamp: Date.now() };
    if (step === 0) {
      const message: AssistantMessage = { ...base, stopReason: "toolUse", content: [{ type: "toolCall", id: "call_esc", name: ESCALATE_TOOL_NAME, arguments: { reason: "fixture" } }] };
      stream.push({ type: "done", reason: "toolUse", message });
    } else if (step === 1) {
      const message: AssistantMessage = { ...base, stopReason: "error", errorMessage: "503 overloaded", content: [] };
      stream.push({ type: "error", reason: "error", error: message });
    } else {
      const message: AssistantMessage = { ...base, stopReason: "stop", content: [{ type: "text", text: "Paris" }] };
      stream.push({ type: "done", reason: "stop", message });
    }
    stream.end();
    return stream;
  };
  try {
    await session.prompt("## Request\nwhat's the capital of france", { expandPromptTemplates: false });
    assert.deepEqual(seen, ["fx/fast@off", "fx/strong@medium", "fx/strong@medium"]);
    assert.deepEqual(events.map(e => `${e.reason}:${e.cause}`), ["user:decision", "continuation:escalate:tool", "retry:retry-same"]);
    assert.equal(session.routedModel?.model.id, "strong");
    assert.equal(stats.blocked("fx", "strong"), true, "overload penalized the failed model");
    const last = session.messages.at(-1) as AssistantMessage;
    assert.equal(last.provider, "fx");
    assert.deepEqual(last.content, [{ type: "text", text: "Paris" }]);
    const stateEntries = session.sessionManager.getBranch().filter(e => e.type === "custom" && e.customType === VIRTUAL_MODEL_STATE_ENTRY);
    assert.ok(stateEntries.length >= 2, "router state is persisted on the session branch");
    assert.equal(handle.lastTier(), "standard");
  } finally {
    session.dispose();
  }
});
