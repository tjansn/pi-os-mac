import { copyFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { createFauxCore, getCurrentSystemPrompt, getCurrentTools, type FauxResponseStep } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { HarnessServer, type HarnessServerOptions } from "../src/server.js";
import { loadConfig, type HarnessConfig } from "../src/config.js";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import { AgentResourceSettings } from "../src/agent/resourceSettings.js";
import type { AgentRunOptions } from "../src/agent/agentRunner.js";
import { LatencyStats } from "../src/agent/routing/index.js";
import type { DesktopContextSnapshot, HostClient } from "../src/hostClient.js";
import type { AppIndexResult, FileSearchRequest, FileSearchResult } from "../src/contracts/launcher.js";

/**
 * Shared fixtures for the C1 integration tests: a fake native host and an in-process
 * provider (pi-ai's faux core behind a registered provider), so real pi sessions, the
 * Auto router and the HTTP surface run end to end with no network and no model.
 */

export const TOKEN = "integration-token";
export const CAPTURES = resolve("../shared/fixtures/captures");
export const AGENT_DIR = resolve("test/fixtures/global-agent-dir");
export const INPUT_TOOLS = ["window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll"];

/**
 * Skip reason for tests that load context-shelf images from disk. The shelf is macOS-only: an image
 * attachment's path is an absolute POSIX host path by contract (attachments.ts isAbsoluteHostPath,
 * protocol.md "Attachments"), and Windows hosts send no attachments, so a real file on a Windows runner
 * (D:\…) can never be a shelf image.
 */
export const SHELF_IMAGES_MACOS_ONLY = process.platform === "win32"
  && "context-shelf images are macOS-only: their paths are POSIX host paths and Windows hosts send no attachments";

export function snapshot(contextId = "ctx-pinned", withScreenshot = true): DesktopContextSnapshot {
  return {
    id: contextId, capturedAt: "2026-10-02T12:00:00Z", cursor: { x: 10, y: 10 },
    targetWindow: { hwnd: "w1", processId: 42, processName: "TextEdit", title: "Fixture", bounds: { x: 0, y: 0, width: 800, height: 600 } },
    foregroundWindow: null, windowUnderCursor: null,
    monitors: [{ id: "m1", isPrimary: true, bounds: { x: 0, y: 0, width: 1440, height: 900 }, workArea: { x: 0, y: 0, width: 1440, height: 875 } }],
    ...(withScreenshot ? { screenshot: { kind: "window", filePath: join(CAPTURES, "window.png"), imageId: "img-1", imageWidth: 800, imageHeight: 600 } } : {}),
  };
}

export interface FakeHostOptions {
  contexts?: Record<string, DesktopContextSnapshot>;
  tools?: string[];
  apps?: AppIndexResult;
  searchFiles?: (request: FileSearchRequest, signal?: AbortSignal) => Promise<FileSearchResult>;
}

export function fakeHost(options: FakeHostOptions = {}) {
  const calls: string[] = [];
  const contexts = options.contexts ?? { "ctx-pinned": snapshot(), "ctx-other": snapshot("ctx-other") };
  const host = {
    calls,
    async getSnapshot(contextId: string) {
      calls.push(`getContext:${contextId}`);
      const found = contexts[contextId];
      return found ? { ok: true, result: found } : { ok: false, error: { code: "unknown_context", message: "fixture" } };
    },
    async getToolNames() {
      calls.push("tools");
      return options.tools ?? [...INPUT_TOOLS, "launcher.searchFiles", "launcher.listApps", "launcher.open"];
    },
    async invokeTool(name: string) {
      calls.push(`tool:${name}`);
      return { ok: false, error: { code: "unsupported", message: "fixture" } };
    },
    async listApps() {
      calls.push("listApps");
      if (!options.apps) throw new Error("unavailable");
      return options.apps;
    },
    async searchFiles(request: FileSearchRequest, signal?: AbortSignal) {
      calls.push("searchFiles");
      if (!options.searchFiles) throw new Error("unavailable");
      return options.searchFiles(request, signal);
    },
  };
  return host;
}

const cost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

/** In-process provider `fx` with a fast and a strong model; responses are scripted per test. */
export function fauxRuntimes(tokensPerSecond = 2_000) {
  const core = createFauxCore({
    provider: "fx", api: "fx-faux", tokensPerSecond,
    models: [
      { id: "fast", reasoning: false, input: ["text", "image"], contextWindow: 100_000 },
      { id: "strong", reasoning: true, input: ["text", "image"], contextWindow: 200_000 },
    ],
  });
  let created = 0;
  const factory = async () => {
    created++;
    const dir = mkdtempSync(join(tmpdir(), "pi-os-int-runtime-"));
    const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "missing.json"), modelsStorePath: join(dir, "store.json") });
    runtime.registerProvider("fx", {
      api: "fx-faux", baseUrl: "https://never-called.invalid/v1", apiKey: "dummy-fixture-key",
      streamSimple: core.streamSimple as never,
      models: [
        { id: "fast", name: "Fixture fast", reasoning: false, input: ["text", "image"], contextWindow: 100_000, maxTokens: 1_024, cost },
        { id: "strong", name: "Fixture strong", reasoning: true, input: ["text", "image"], contextWindow: 200_000, maxTokens: 1_024, cost },
      ],
    });
    return runtime;
  };
  return {
    core, factory,
    get created() { return created; },
    respond(steps: FauxResponseStep[]) { core.setResponses(steps); },
  };
}

export interface StartOptions extends HarnessServerOptions {
  host?: ReturnType<typeof fakeHost>;
  config?: Partial<HarnessConfig>;
  runtimes?: ReturnType<typeof fauxRuntimes>;
}

export async function start(options: StartOptions = {}) {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-int-"));
  const host = options.host ?? fakeHost();
  const stats = options.latencyStats ?? new LatencyStats({ log: () => {} });
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: TOKEN, agentEnabled: true, invokeTimeoutMs: 20_000,
    capturesDir: CAPTURES, ...options.config }, {
    // Auto-default behaviour is per host; the shared suite pins macOS so it runs alike on every CI OS
    // (Windows defaults are covered by tests that inject "win32").
    platform: "darwin",
    ...options,
    hostClient: host as unknown as HostClient,
    modelSettings: options.modelSettings ?? new AgentModelSettings(join(dir, "settings.json"), () => {}),
    resourceSettings: options.resourceSettings ?? new AgentResourceSettings(join(dir, "resources.json")),
    supportDir: dir,
    latencyStats: stats,
    agentServices: {
      agentDir: AGENT_DIR,
      ...(options.runtimes ? { modelRuntime: options.runtimes.factory } : {}),
      ...options.agentServices,
    },
  });
  const base = `http://127.0.0.1:${await server.listen()}`;
  const headers = { "X-Harness-Token": TOKEN, "Content-Type": "application/json" };
  const post = (path: string, body: unknown, token = TOKEN) =>
    fetch(base + path, { method: "POST", headers: { ...headers, "X-Harness-Token": token }, body: typeof body === "string" ? body : JSON.stringify(body) });
  const get = (path: string) => fetch(base + path, { headers });
  async function terminal(id: string) {
    for (let i = 0; i < 1_000; i++) {
      const status = await (await get(`/invocations/${id}`)).json() as any;
      if (!["queued", "running"].includes(status.state)) return status;
      await delay(5);
    }
    throw new Error("Invocation did not settle");
  }
  return {
    server, host, stats, dir, base, headers, post, get, terminal,
    async close() { await server.close(); await rm(dir, { recursive: true, force: true }); },
  };
}

/** Collects console lines while `run` executes (privacy checks on logs). */
export async function captureLogs<T>(run: () => Promise<T>): Promise<{ result: T; lines: string[] }> {
  const lines: string[] = [];
  const original = { log: console.log, warn: console.warn, error: console.error };
  const sink = (...args: unknown[]) => { lines.push(args.map(String).join(" ")); };
  console.log = sink; console.warn = sink; console.error = sink;
  try {
    return { result: await run(), lines };
  } finally {
    Object.assign(console, original);
  }
}

/** Reads an SSE response into parsed frames until the server closes it. */
export async function readEvents(response: Response): Promise<{ records: any[]; comments: number; raw: string }> {
  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  let raw = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    raw += decoder.decode(value, { stream: true });
  }
  const frames = raw.split("\n\n").filter(Boolean);
  const records = frames.filter(frame => frame.startsWith("event: record\n"))
    .map(frame => JSON.parse(frame.slice(frame.indexOf("data: ") + 6)));
  return { records, comments: frames.filter(frame => frame.startsWith(": ping")).length, raw };
}

// ---------------------------------------------------------------------------------------------
// Direct agent sessions (createLiveSession → planTurn → promptFirst/promptFollowup) on the faux
// provider: context scopes, use_active_window and attachments, with no HTTP server in between.

/** A captures directory of its own (window.png copied in) and snapshots whose screenshot lives there. */
export function tempCaptures() {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-captures-"));
  copyFileSync(join(CAPTURES, "window.png"), join(dir, "window.png"));
  const at = (contextId = "ctx-pinned", withScreenshot = true): DesktopContextSnapshot => {
    const base = snapshot(contextId, false);
    return { ...base, ...(withScreenshot ? { screenshot: { kind: "window", filePath: join(dir, "window.png"), imageId: "img-1", imageWidth: 800, imageHeight: 600 } } : {}) };
  };
  return { dir, snapshot: at, close: () => rm(dir, { recursive: true, force: true }) };
}

export type HostRoute = (args: Record<string, unknown>) => unknown;

/**
 * Fake macOS host for agent tools: `desktop.getContext` returns the pinned snapshot, every
 * `desktop.captureWindow` writes a numbered PNG (shot-2, shot-3, …) into the captures dir, input
 * posts succeed; `routes` overrides any route. Every call is recorded with its arguments.
 */
export function agentHost(capturesDir: string, pinned: DesktopContextSnapshot, routes: Record<string, HostRoute> = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  let shots = 1;
  const host = {
    calls,
    names: () => calls.map(call => call.name),
    async invokeTool(name: string, args: Record<string, unknown> = {}) {
      calls.push({ name, args });
      const route = routes[name];
      if (route) return route(args);
      if (name === "desktop.getContext") return { ok: true, result: pinned };
      if (name === "desktop.captureWindow") {
        const imageId = `shot-${++shots}`, filePath = join(capturesDir, `${imageId}.png`);
        copyFileSync(join(CAPTURES, "window.png"), filePath);
        return { ok: true, result: { kind: "window", filePath, imageId, imageWidth: 800, imageHeight: 600 } };
      }
      if (name.startsWith("input.") || name === "window.focus") return { ok: true, result: { posted: true } };
      return { ok: false, error: { code: "unsupported", message: "fixture" } };
    },
    async getSnapshot() { return { ok: true, result: pinned }; },
    async getToolNames() { return [...INPUT_TOOLS, "launcher.searchFiles", "launcher.listApps", "launcher.open"]; },
  };
  return host;
}

/** Run options for a control-enabled macOS session on the manual `fx/fast` model (override anything). */
export function agentRun(host: ReturnType<typeof agentHost>, runtimes: ReturnType<typeof fauxRuntimes>, capturesDir: string,
  pinned: DesktopContextSnapshot, overrides: Partial<AgentRunOptions> = {}): AgentRunOptions {
  return {
    hostClient: host as unknown as HostClient, contextId: "ctx-pinned", prompt: "", snapshot: pinned, capturesDir, log: () => {},
    readOnly: false, launcher: true, modelSelection: { provider: "fx", modelId: "fast", thinkingLevel: "off" },
    ...overrides,
    services: { agentDir: AGENT_DIR, modelRuntime: runtimes.factory, platform: "darwin", ...overrides.services },
  };
}

type SeenPart = { type: string; text?: string; data?: string };
type SeenMessage = { role: string; content: unknown; customType?: string; toolName?: string; isError?: boolean };

/** What one provider request carried: system prompt, declared tools, the request message and what followed it. */
export interface SeenRequest {
  model: string;
  system: string;
  tools: string[];
  descriptions: Record<string, string>;
  /** Text of the latest user message that holds "## Request". */
  request: string;
  /** Images in that message. */
  requestImages: number;
  /** User-role content after it (attachment images and their labels). */
  extras: SeenPart[];
  messages: SeenMessage[];
}

export function seen(context: unknown, model: { provider: string; id: string }): SeenRequest {
  const messages = (context as { messages: SeenMessage[] }).messages;
  const parts = (message: SeenMessage | undefined): SeenPart[] => !message ? []
    : typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content as SeenPart[];
  const text = (message: SeenMessage | undefined) => parts(message).filter(part => part.type === "text").map(part => part.text).join("\n");
  const index = messages.findLastIndex(message => message.role === "user" && text(message).includes("## Request"));
  const tools = getCurrentTools(messages as never);
  return {
    model: `${model.provider}/${model.id}`,
    system: getCurrentSystemPrompt(messages as never),
    tools: tools.map(tool => tool.name),
    descriptions: Object.fromEntries(tools.map(tool => [tool.name, tool.description])),
    request: text(messages[index]),
    requestImages: parts(messages[index]).filter(part => part.type === "image").length,
    extras: messages.slice(index + 1).filter(message => message.role === "user").flatMap(parts),
    messages,
  };
}

/** A tiny RGB PNG of exactly width × height (attachment images with a known header). */
export function pngFile(path: string, width: number, height: number): void {
  const crc32 = (buf: Buffer) => {
    let c = ~0;
    for (const b of buf) { c ^= b; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); }
    return ~c >>> 0;
  };
  const chunk = (type: string, data: Buffer) => {
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  // Empty IDAT: the header is what pi-os checks; no decoder runs in these tests.
  writeFileSync(path, Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header), chunk("IDAT", Buffer.alloc(0)), chunk("IEND", Buffer.alloc(0))]));
}
