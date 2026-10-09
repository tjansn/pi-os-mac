import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { loadAgentResources, READ_ONLY_TOOLS, sessionExtensions, sessionToolAllowlist } from "../src/agent/agentRunner.js";
import { loadScreenshotImage } from "../src/agent/screenshotImage.js";
import { supportDirectory } from "../src/platformPaths.js";
import type { HostClient } from "../src/hostClient.js";

test("Darwin paths preserve Windows defaults and explicit overrides", () => {
  assert.equal(supportDirectory({}, "darwin", "/Users/test"), "/Users/test/Library/Application Support/pi-os");
  assert.equal(supportDirectory({ PI_OS_SUPPORT_DIR: "/custom" }, "darwin", "/Users/test"), "/custom");
  assert.equal(supportDirectory({ LOCALAPPDATA: "/local" }, "win32", "/home"), join("/local", "pi-os"));
});

test("read-only agent has exactly the pinned observation, instant/launcher-read, card and script tools; no global or planted project resources", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-os-isolation-"));
  const cwd = join(root, "agent-cwd");
  const agentDir = resolve("test/fixtures/global-agent-dir");
  await mkdir(join(cwd, ".pi/extensions"), { recursive: true });
  await writeFile(join(root, "AGENTS.md"), "THIS_PROJECT_CONTEXT_MUST_NOT_LOAD");
  await writeFile(join(cwd, ".pi/extensions/evil.ts"), "throw new Error('PROJECT_EXTENSION_EXECUTED')");
  await writeFile(join(cwd, ".pi/SYSTEM.md"), "THIS_SYSTEM_PROMPT_MUST_NOT_LOAD");
  try {
    const runtime = await ModelRuntime.create({ authPath: join(agentDir, "auth.json"), modelsPath: join(agentDir, "models.json") });
    for (const auto of [true, false]) {
      // The production extension set of a read-only Mac session whose host offers the launcher read routes.
      const { extensions } = sessionExtensions({ contextId: "ctx-pinned", hostClient: {} as HostClient, capturesDir: root, readOnly: true,
        platform: "darwin", launcher: true });
      const loader = await loadAgentResources(extensions, cwd, agentDir, true);
      assert.deepEqual(loader.getSkills().skills, []);
      assert.deepEqual(loader.getAgentsFiles().agentsFiles, []);
      assert.equal(loader.getExtensions().errors.length, 0);
      // computer use, launcher tools, show_result, pi_os_escalate, codemode policy, pi codemode.
      assert.equal(loader.getExtensions().extensions.length, 6);
      const { session } = await createAgentSession({
        cwd, agentDir, resourceLoader: loader, modelRuntime: runtime,
        tools: sessionToolAllowlist({ readOnly: true, auto }), sessionManager: SessionManager.inMemory(cwd),
        settingsManager: SettingsManager.create(cwd, agentDir, { projectTrusted: false }),
      });
      // Deliberate exact set (C1): observation + instant engines + launcher reads + cards + codemode (+ escalate on Auto).
      // No input, no open_item, no built-in coding tools.
      const expected = [...READ_ONLY_TOOLS, "instant_calc", "instant_convert_currency", "instant_time_in", "find_files", "list_apps",
        "show_result", "codemode", ...(auto ? ["pi_os_escalate"] : [])].sort();
      try {
        assert.deepEqual(session.agent.state.tools.map(t => t.name).sort(), expected);
        assert.deepEqual(session.getAllTools().map(t => t.name).sort(), expected);
        for (const forbidden of ["desktop_act", "open_item", "browser_act", "bash", "read", "edit", "write"]) {
          assert.ok(!session.getAllTools().some(t => t.name === forbidden), forbidden);
        }
        assert.doesNotMatch(session.agent.state.systemPrompt, /THIS_PROJECT_CONTEXT|THIS_SYSTEM_PROMPT/);
      } finally { session.dispose(); }
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("PNG containment resolves symlinks and accepts a trusted root alias", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-os-paths-"));
  const captures = join(root, "captures");
  await mkdir(captures);
  const png = await readFile(resolve("../shared/fixtures/captures/window.png"));
  await writeFile(join(captures, "shot.png"), png);
  await writeFile(join(root, "outside.png"), png);
  try {
    await symlink(captures, join(root, "alias"), "junction");
    const image = await loadScreenshotImage(join(captures, "shot.png"), join(root, "alias"));
    assert.equal(image.data, png.toString("base64"));
    // Directory symlink works on Windows without file-symlink privilege as well.
    await symlink(root, join(captures, "escape"), "junction");
    await assert.rejects(loadScreenshotImage(join(captures, "escape/outside.png"), captures), /outside/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
