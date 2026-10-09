import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateSync } from "node:zlib";
import { join, resolve } from "node:path";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream, Type, type AssistantMessage } from "@earendil-works/pi-ai";
import { createSessionSettings, loadAgentResources, registerResourceProviders } from "../src/agent/resources.js";

// pi >= 0.87 would shrink a 2600 px screenshot to 2000 px JPEG and add a coordinate hint.
// pi-os hosts own the coordinate space, so every pi-os session must pass images through.

function crc32(buf: Buffer) {
  let c = ~0;
  for (const b of buf) { c ^= b; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); }
  return ~c >>> 0;
}
function png(width: number, height: number): string {
  const chunk = (type: string, data: Buffer) => {
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const pixels = deflateSync(Buffer.alloc((width * 3 + 1) * height));
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header), chunk("IDAT", pixels), chunk("IEND", Buffer.alloc(0))]).toString("base64");
}
type Part = { type: string; text?: string; data?: string; mimeType?: string };
const describe = (image: Part) => {
  const bytes = Buffer.from(image.data ?? "", "base64");
  return bytes[0] === 0x89 ? `${image.mimeType} ${bytes.readUInt32BE(16)}x${bytes.readUInt32BE(20)}` : String(image.mimeType);
};
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const screenshot = png(2600, 1400);

async function run(settingsManager: SettingsManager) {
  const dir = resolve("test/fixtures/global-agent-dir");
  const loader = await loadAgentResources([{ name: "image-fixture", factory(pi) {
    pi.registerProvider("image-fixture", { api: "openai-completions", baseUrl: "https://never-called.invalid/v1", apiKey: "dummy-fixture-key",
      models: [{ id: "vision", name: "Vision", reasoning: false, input: ["text", "image"], contextWindow: 200_000, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
    pi.registerTool({ name: "fixture_capture", label: "Capture", description: "Fixture screenshot", parameters: Type.Object({}),
      async execute() {
        return { content: [{ type: "text", text: "capture" }, { type: "image", data: screenshot, mimeType: "image/png" }], details: {} };
      } });
  } }], process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing-models.json") });
  const cleanup = await registerResourceProviders(loader, runtime);
  const { session } = await createAgentSession({ modelRuntime: runtime, resourceLoader: loader, model: runtime.getModel("image-fixture", "vision"),
    tools: ["fixture_capture"], sessionManager: SessionManager.inMemory(), settingsManager });
  let turn = 0;
  session.agent.streamFunction = (model) => {
    const stream = createAssistantMessageEventStream();
    const toolTurn = turn++ === 0;
    const message: AssistantMessage = { role: "assistant", provider: model.provider, model: model.id, api: model.api, timestamp: Date.now(), usage,
      content: toolTurn ? [{ type: "toolCall", id: "call_1", name: "fixture_capture", arguments: {} }] : [{ type: "text", text: "done" }],
      stopReason: toolTurn ? "toolUse" : "stop" };
    stream.push({ type: "done", reason: toolTurn ? "toolUse" : "stop", message }); stream.end();
    return stream;
  };
  try {
    await session.prompt("look", { expandPromptTemplates: false, images: [{ type: "image", data: screenshot, mimeType: "image/png" }] });
    const parts = (role: string): Part[] => session.messages.flatMap(m => {
      const message = m as { role?: string; content?: unknown };
      return message.role === role && Array.isArray(message.content) ? message.content as Part[] : [];
    });
    const user = parts("user"), tool = parts("toolResult");
    return {
      userImages: user.filter(p => p.type === "image").map(describe),
      toolImages: tool.filter(p => p.type === "image").map(describe),
      hints: [...user, ...tool].filter(p => p.type === "text" && /\[Image: original/.test(p.text ?? "")).length,
      identical: [...user, ...tool].filter(p => p.type === "image").every(p => p.data === screenshot),
    };
  } finally { session.dispose(); cleanup(); }
}

test("pi-os session settings keep prompt and tool-result screenshots byte-for-byte in host coordinates", async () => {
  const settings = createSessionSettings(true, process.cwd(), resolve("test/fixtures/global-agent-dir"));
  assert.equal(settings.getImageAutoResize(), false);
  const result = await run(settings);
  assert.deepEqual(result, { userImages: ["image/png 2600x1400"], toolImages: ["image/png 2600x1400"], hints: 0, identical: true });
});

test("control: pi's default settings would resize the same screenshots (the override is load-bearing)", async () => {
  const result = await run(SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: false } }));
  assert.notDeepEqual(result.userImages, ["image/png 2600x1400"]);
  assert.notDeepEqual(result.toolImages, ["image/png 2600x1400"]);
  assert(result.hints >= 1, "pi appends a coordinate multiplier hint when it resizes");
  assert.equal(result.identical, false);
});

test("trusted (non-isolated) session settings also disable pi image resizing", () => {
  const settings = createSessionSettings(false, process.cwd(), resolve("test/fixtures/global-agent-dir"));
  assert.equal(settings.getImageAutoResize(), false);
  // Overrides are in-memory only and never shared between sessions.
  assert.equal(SettingsManager.inMemory().getImageAutoResize(), true);
});
