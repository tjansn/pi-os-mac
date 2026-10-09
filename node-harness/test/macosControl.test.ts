import assert from "node:assert/strict";
import { test } from "node:test";
import { resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createComputerUseExtension, createDesktopActSchema, validateDesktopAction } from "../src/agent/computerUseExtension.js";
import { loadAgentResources, READ_ONLY_TOOLS, sessionExtensions, sessionToolAllowlist } from "../src/agent/agentRunner.js";
import type { HostClient } from "../src/hostClient.js";

test("Mac supports Command/Space without expanding the Windows key contract", () => {
  assert.doesNotThrow(() => validateDesktopAction({ action: "key_chord", key: "space", modifiers: ["cmd"] }, "darwin"));
  assert.throws(() => validateDesktopAction({ action: "key_chord", key: "space", modifiers: ["cmd"] }, "win32"));
  assert.throws(() => validateDesktopAction({ action: "key_chord", key: "a", modifiers: ["cmd"] }, "win32"));
  assert.ok(JSON.stringify(createDesktopActSchema("darwin")).includes('"cmd"'));
  assert.ok(!JSON.stringify(createDesktopActSchema("win32")).includes('"cmd"'));
});

test("Mac actions bind context and the last viewed image, not model-supplied identities", async () => {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const tools = new Map<string, any>();
  const extension = createComputerUseExtension("ctx-fixed", { invokeTool: async (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args });
    return { ok: true, result: {} };
  } } as unknown as HostClient, "/captures", false, "darwin", "viewed-image");
  extension.factory({ on() {}, registerTool(tool: any) { tools.set(tool.name, tool); } } as unknown as ExtensionAPI);
  await tools.get("desktop_act").execute("1", { action: "key_chord", key: "s", modifiers: ["cmd"], contextId: "wrong", screenshotId: "unseen" });
  assert.deepEqual(calls, [{ name: "input.keyChord", args: { key: "s", modifiers: ["cmd"], contextId: "ctx-fixed", screenshotId: "viewed-image" } }]);
  extension.invalidateScreenshot();
  await tools.get("desktop_act").execute("2", { action: "click", x: 1, y: 2, screenshotId: "old-model-image" });
  assert.equal(calls[1]!.args.screenshotId, undefined, "New turns cannot reuse prior screenshot authority");
});

test("failed image ingestion cannot advance coordinate authority; mutations are never retried", async () => {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const tools = new Map<string, any>();
  const extension = createComputerUseExtension("ctx-fixed", { invokeTool: async (name: string, args: Record<string, unknown>) => {
    calls.push({ name, args });
    if (name === "desktop.captureWindow") return { ok: true, result: { imageId: "unseen-image", filePath: "/not-a-png" } };
    return { ok: false, error: { code: "capture_stale", message: "No input posted" } };
  } } as unknown as HostClient, "/captures", false, "darwin", "viewed-image");
  extension.factory({ on() {}, registerTool(tool: any) { tools.set(tool.name, tool); } } as unknown as ExtensionAPI);
  await assert.rejects(tools.get("desktop_capture_window").execute("1", {}));
  await assert.rejects(tools.get("desktop_act").execute("2", { action: "click", x: 4, y: 8 }), /capture_stale/);
  assert.equal(calls.length, 2);
  assert.equal(calls[1]!.args.screenshotId, "viewed-image");
});

test("full Mac desktop control still excludes built-ins and global extension bypasses", async () => {
  const dir = resolve("test/fixtures/global-agent-dir");
  for (const launcher of [true, false]) {
    const { extensions } = sessionExtensions({ contextId: "ctx-fixed", hostClient: {} as HostClient, capturesDir: "/captures",
      readOnly: false, platform: "darwin", launcher });
    const loader = await loadAgentResources(extensions, process.cwd(), dir, true);
    const runtime = await ModelRuntime.create({ authPath: resolve(dir, "auth.json"), modelsPath: resolve(dir, "models.json") });
    const { session } = await createAgentSession({ resourceLoader: loader, modelRuntime: runtime, agentDir: dir,
      sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(), tools: sessionToolAllowlist({ readOnly: false, auto: true }) });
    // Deliberate exact set (C1): native input plus instant/launcher tools, cards, codemode and Auto's escalation.
    // Without the host launcher routes, only the engine-only instant tools register.
    const names = [...READ_ONLY_TOOLS, "desktop_act", "instant_calc", "instant_convert_currency", "instant_time_in",
      ...(launcher ? ["find_files", "list_apps", "open_item"] : []), "show_result", "codemode", "pi_os_escalate"];
    try {
      assert.deepEqual(session.getAllTools().map(t => t.name).sort(), [...names].sort());
      assert.deepEqual(session.agent.state.tools.map(t => t.name).sort(), [...names].sort());
      assert.ok(!session.getAllTools().some(t => ["bash", "read", "edit", "write", "fixture_global_tool"].includes(t.name)));
      // computer use, launcher/instant, show_result, escalate, prompt-cache key, codemode policy + codemode.
      assert.equal(loader.getExtensions().extensions.length, 7);
    } finally { session.dispose(); }
  }
});
