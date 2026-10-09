import { mkdtempSync } from "node:fs";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { createFauxCore, type FauxResponseStep } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { HarnessServer, type HarnessServerOptions } from "../src/server.js";
import { loadConfig, type HarnessConfig } from "../src/config.js";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import { AgentResourceSettings } from "../src/agent/resourceSettings.js";
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
