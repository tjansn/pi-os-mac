import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { test } from "node:test";
import {
  createAssistantMessageEventStream, getCurrentSystemPrompt, getCurrentTools, parseStreamingJson, type AssistantMessage, type JsonObject, type ToolCall,
} from "@earendil-works/pi-ai";
import { makeStrictJsonSchema } from "@earendil-works/pi-ai/api/constrained-sampling";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager, type ExtensionAPI, type InlineExtension, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { CardSpec } from "../src/contracts/cards.js";
import { loadAgentResources, registerResourceProviders } from "../src/agent/resources.js";
import { blocksToCard } from "../src/ui/blocks.js";
import { FileLedger } from "../src/ui/ledger.js";
import { createShowResultExtension, SHOW_RESULT_TOOL } from "../src/ui/showResult.js";
import { validateCard } from "../src/ui/validate.js";

const searchResult = JSON.parse(readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "launcher", "search-files-response.json"), "utf8"));
const fixtureLedger = () => { const ledger = new FileLedger({ homeDir: "/Users/fixture" }); ledger.register(searchResult.result.items); return ledger; };
const formatDate = (ms: number) => new Date(ms).toISOString().slice(5, 10);
const args = {
  summary: "2 invoices found",
  blocks: [
    { type: "markdown", text: "These are the **March** invoices I found in your documents and downloads." },
    { type: "files", title: "Invoices", refs: ["f1", "f2"] },
    { type: "suggestions", prompts: ["Open the newest one", "Find April invoices"] },
  ],
};
const zeroUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

/** Captures what a factory registers, for checking the tool definition itself. */
function registered(extension: InlineExtension): ToolDefinition {
  let tool: ToolDefinition | undefined;
  const api = { on() { return () => {}; }, registerTool(definition: ToolDefinition) { tool = definition; } } as unknown as ExtensionAPI;
  void (typeof extension === "function" ? extension(api) : extension.factory(api));
  assert(tool);
  return tool;
}

function schemaKeywords(schema: unknown, found = new Set<string>()): Set<string> {
  if (Array.isArray(schema)) schema.forEach(item => schemaKeywords(item, found));
  else if (typeof schema === "object" && schema !== null) {
    for (const [key, value] of Object.entries(schema)) {
      if (key !== "properties") found.add(key);
      if (key === "properties") Object.values(value as object).forEach(item => schemaKeywords(item, found));
      else schemaKeywords(value, found);
    }
  }
  return found;
}

test("show_result tool definition: closed TypeBox schema, prefer-strict sampling, model-only, factual guidance", () => {
  const tool = registered(createShowResultExtension({ ledger: fixtureLedger(), onCard() {} }));
  assert.equal(tool.name, SHOW_RESULT_TOOL);
  assert.deepEqual(tool.constrainedSampling, { type: "json_schema", strict: "prefer" });
  assert.equal(tool.exposure, "model-only");
  assert.match(tool.promptGuidelines!.join("\n"), /Never invent values, sample rows, file names, paths, links or metadata/);
  assert.match(tool.promptGuidelines!.join("\n"), /never write paths or tokens/);
  const schema = JSON.parse(JSON.stringify(tool.parameters));
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.blocks.items.additionalProperties, false);
  // Keywords some providers reject under strict sampling stay out of the model-facing schema (the catalog enforces limits).
  const keywords = schemaKeywords(schema);
  for (const banned of ["maxLength", "minLength", "pattern", "maxItems", "minimum", "maximum", "uniqueItems", "anyOf", "oneOf", "const", "$ref"]) {
    assert(!keywords.has(banned), `schema uses ${banned}`);
  }
  // pi-ai converts it to the provider strict subset without falling back.
  const strict = makeStrictJsonSchema(schema) as { required: string[]; properties: Record<string, unknown> };
  assert.deepEqual(strict.required.sort(), ["blocks", "summary"]);
});

test("show_result execute: valid card → onCard(complete) + terminate; invalid → tool error, no card", async () => {
  const cards: [CardSpec, boolean][] = [];
  const ledger = fixtureLedger();
  const tool = registered(createShowResultExtension({ ledger, formatDate, onCard: (spec, complete) => { cards.push([spec, complete]); } }));
  const run = (params: unknown) => tool.execute("call_1", params as never, undefined, undefined, {} as never);
  const done = await run(args);
  assert.deepEqual(done, { content: [{ type: "text", text: "Displayed to the user." }], details: {}, terminate: true });
  assert.equal(cards.length, 1);
  const expected = blocksToCard(args, ledger, { formatDate });
  assert(expected.ok);
  assert.deepEqual(cards[0], [expected.spec, true]);

  const invented = await run({ blocks: [{ type: "files", refs: ["f1", "f9"] }, { type: "result", input: "2+2" }] });
  assert.equal(invented.isError, true);
  assert.equal(invented.terminate, undefined);
  const message = (invented.content[0] as { text: string }).text;
  assert.match(message, /^invalid_card: blocks\[0\]\.refs\[1\]: unknown or expired file ref.*; blocks\[1\]\.value: result blocks need value/);
  assert.equal(cards.length, 1, "no card for an invalid call");

  const failing = registered(createShowResultExtension({ ledger, onCard() { throw new Error("host gone"); } }));
  const failed = await failing.execute("call_2", args as never, undefined, undefined, {} as never);
  assert.equal(failed.isError, true);
  assert.match((failed.content[0] as { text: string }).text, /^display_failed/);
});

/** Real pi 1.0 AgentSession against an in-process provider fixture (no network; stream function replaced). */
async function sessionWith(extension: InlineExtension) {
  const dir = resolve("test/fixtures/global-agent-dir");
  const loader = await loadAgentResources([extension, { name: "cards-provider-fixture", factory(pi) {
    pi.registerProvider("cards-fixture", { api: "openai-completions", baseUrl: "https://never-called.invalid/v1", apiKey: "dummy-fixture-key",
      models: [{ id: "dummy", name: "Dummy", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  } }], process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing-models.json") });
  const cleanup = await registerResourceProviders(loader, runtime);
  const { session } = await createAgentSession({ modelRuntime: runtime, resourceLoader: loader, model: runtime.getModel("cards-fixture", "dummy"),
    tools: [SHOW_RESULT_TOOL], sessionManager: SessionManager.inMemory(),
    settingsManager: SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: false } }) });
  return { session, dispose: () => { session.dispose(); cleanup(); } };
}

/** Streams one tool call the way pi-ai providers do: live partial block, arguments re-parsed per delta. */
function streamToolCall(model: { provider: string; id: string; api: string }, toolArgs: JsonObject, chunk = 9) {
  const stream = createAssistantMessageEventStream();
  const call: ToolCall = { type: "toolCall", id: "call_show", name: SHOW_RESULT_TOOL, arguments: {} };
  const partial: AssistantMessage = { role: "assistant", content: [call], provider: model.provider, model: model.id, api: model.api,
    stopReason: "pending", timestamp: Date.now(), usage: zeroUsage };
  void (async () => {
    stream.push({ type: "start", partial });
    stream.push({ type: "toolcall_start", contentIndex: 0, partial });
    const json = JSON.stringify(toolArgs);
    for (let at = 0; at < json.length; at += chunk) {
      call.arguments = parseStreamingJson(json.slice(0, at + chunk)) as JsonObject;
      stream.push({ type: "toolcall_delta", contentIndex: 0, delta: json.slice(at, at + chunk), partial });
      await new Promise(resolve => setImmediate(resolve));
    }
    call.arguments = toolArgs;
    stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: call, partial });
    stream.push({ type: "done", reason: "toolUse", message: { ...partial, content: [{ ...call }], stopReason: "toolUse" } });
    stream.end();
  })();
  return stream;
}

function textAnswer(model: { provider: string; id: string; api: string }, text: string) {
  const stream = createAssistantMessageEventStream();
  const message: AssistantMessage = { role: "assistant", content: [{ type: "text", text }], provider: model.provider, model: model.id, api: model.api,
    stopReason: "stop", timestamp: Date.now(), usage: zeroUsage };
  stream.push({ type: "done", reason: "stop", message });
  stream.end();
  return stream;
}

test("real SDK: a streamed show_result call yields partial cards, one complete card, and ends the turn", async () => {
  const cards: [CardSpec, boolean][] = [];
  const ledger = fixtureLedger();
  let clock = 0;
  const { session, dispose } = await sessionWith(createShowResultExtension({
    ledger, formatDate, now: () => (clock += 60), onCard: (spec, complete) => { cards.push([structuredClone(spec), complete]); },
  }));
  const contexts: { systemPrompt: string; tools: { name: string; constrainedSampling?: unknown }[] }[] = [];
  session.agent.streamFunction = (model, context) => {
    contexts.push({ systemPrompt: getCurrentSystemPrompt(context.messages), tools: getCurrentTools(context.messages) });
    return streamToolCall(model, args as unknown as JsonObject);
  };
  try {
    await session.prompt("Show me my March invoices", { expandPromptTemplates: false });
    assert.equal(contexts.length, 1, "terminate: true ends the loop without a second model call");
    const tool = contexts[0]!.tools.find(entry => entry.name === SHOW_RESULT_TOOL);
    assert.deepEqual(tool?.constrainedSampling, { type: "json_schema", strict: "prefer" });
    assert.match(contexts[0]!.systemPrompt, /Never invent values/);

    const partials = cards.filter(([, complete]) => !complete);
    const finals = cards.filter(([, complete]) => complete);
    assert(partials.length >= 3, `partial cards streamed (${partials.length})`);
    assert.equal(finals.length, 1);
    assert.equal(cards.at(-1)![1], true, "the complete card comes last");
    const expected = blocksToCard(args, ledger, { formatDate });
    assert(expected.ok);
    assert.deepEqual(finals[0]![0], expected.spec);
    for (const [spec] of partials) {
      assert(validateCard(spec, { mode: "strict", ledger }).ok);
      assert(Object.keys(spec.elements).every(key => key in expected.spec.elements), "partial keys are final keys");
    }
    assert(partials.some(([spec]) => spec.elements.b0?.props.source !== args.blocks[0]!.text), "prose streamed before it was complete");

    const result = session.messages.find(message => message.role === "toolResult");
    assert.deepEqual((result as { content: unknown }).content, [{ type: "text", text: "Displayed to the user." }]);
  } finally { dispose(); }
});

test("real SDK: an invalid show_result call is a tool error the model can recover from, with no complete card", async () => {
  const cards: [CardSpec, boolean][] = [];
  const { session, dispose } = await sessionWith(createShowResultExtension({
    ledger: fixtureLedger(), now: (() => { let clock = 0; return () => (clock += 60); })(), onCard: (spec, complete) => { cards.push([spec, complete]); },
  }));
  const seen: string[] = [];
  session.agent.streamFunction = (model, context) => {
    seen.push(JSON.stringify(context.messages));
    return seen.length === 1
      ? streamToolCall(model, { blocks: [{ type: "markdown", text: "Here is the file you asked for, opened from the list below." }, { type: "files", refs: ["f42"] }] })
      : textAnswer(model, "I could not find that file.");
  };
  try {
    await session.prompt("Open the report", { expandPromptTemplates: false });
    assert.equal(seen.length, 2, "the loop continues after a tool error");
    assert.match(seen[1]!, /invalid_card: blocks\[1\]\.refs\[0\]: unknown or expired file ref/);
    assert(cards.length > 0 && cards.every(([, complete]) => !complete), "only discardable partial cards");
    const last = session.messages.at(-1) as AssistantMessage;
    assert.deepEqual(last.content, [{ type: "text", text: "I could not find that file." }]);
  } finally { dispose(); }
});

test("partial cards can be disabled", async () => {
  const cards: boolean[] = [];
  const { session, dispose } = await sessionWith(createShowResultExtension({ ledger: fixtureLedger(), partialIntervalMs: 0, onCard: (_spec, complete) => { cards.push(complete); } }));
  session.agent.streamFunction = (model) => streamToolCall(model, args as unknown as JsonObject);
  try {
    await session.prompt("Show me my March invoices", { expandPromptTemplates: false });
    assert.deepEqual(cards, [true]);
  } finally { dispose(); }
});

test("partial cards follow only show_result calls, by content index", () => {
  const handlers = new Map<string, (event: unknown) => void>();
  const api = { on(name: string, handler: (event: unknown) => void) { handlers.set(name, handler); return () => {}; }, registerTool() {} } as unknown as ExtensionAPI;
  const cards: CardSpec[] = [];
  let clock = 0;
  const extension = createShowResultExtension({ ledger: fixtureLedger(), now: () => (clock += 60), onCard: (spec) => { cards.push(spec); } });
  void (typeof extension === "function" ? extension(api) : extension.factory(api));
  const update = handlers.get("message_update")!;
  const json = JSON.stringify(args);
  const stream = (name: string, contentIndex: number) => {
    const call = { type: "toolCall", id: `call_${name}`, name, arguments: {} as unknown };
    const partial = { content: [...Array.from({ length: contentIndex }, () => ({ type: "text", text: "" })), call] };
    update({ assistantMessageEvent: { type: "toolcall_start", contentIndex, partial } });
    for (let at = 0; at < json.length; at += 16) {
      call.arguments = parseStreamingJson(json.slice(0, at + 16));
      update({ assistantMessageEvent: { type: "toolcall_delta", contentIndex, delta: json.slice(at, at + 16), partial } });
    }
    update({ assistantMessageEvent: { type: "toolcall_end", contentIndex, partial } });
  };
  stream("find_files", 0);
  assert.equal(cards.length, 0, "another tool's arguments never become a card");
  stream(SHOW_RESULT_TOOL, 1);
  assert(cards.length >= 3);
  const seen = cards.length;
  // Deltas for a different content block (e.g. a parallel call) are ignored after show_result ends.
  update({ assistantMessageEvent: { type: "toolcall_delta", contentIndex: 1, delta: "{}", partial: { content: [] } } });
  assert.equal(cards.length, seen);
});
