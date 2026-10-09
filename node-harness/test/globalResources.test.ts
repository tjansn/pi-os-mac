import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync } from "node:fs";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { createComputerUseExtension } from "../src/agent/computerUseExtension.js";
import { createLiveSession, loadAgentResources, sessionExtensions } from "../src/agent/agentRunner.js";
import { codemodeExtensionFactories } from "../src/agent/codemodePolicy.js";
import type { HostClient } from "../src/hostClient.js";
import { CAPTURES, fauxRuntimes, snapshot } from "./integrationFixtures.js";

const fixtureAgentDir = join(process.cwd(), "test", "fixtures", "global-agent-dir");

test("global skill and extension tool are visible beside Computer Use", async () => {
  const extension = createComputerUseExtension(
    "ctx-test",
    { invokeTool: async () => ({ ok: true, result: {} }) } as unknown as HostClient,
    join(process.cwd(), "test", "captures"),
  );
  const loader = await loadAgentResources([extension], process.cwd(), fixtureAgentDir);

  assert.ok(loader.getSkills().skills.some((skill) => skill.name === "fixture-global-skill"));

  const modelRuntime = await ModelRuntime.create({
    authPath: join(fixtureAgentDir, "auth.json"),
    modelsPath: join(fixtureAgentDir, "models.json"),
  });
  const { session } = await createAgentSession({
    agentDir: fixtureAgentDir,
    modelRuntime,
    resourceLoader: loader,
    sessionManager: SessionManager.inMemory(),
    settingsManager: SettingsManager.inMemory(),
  });

  try {
    const activeTools = session.agent.state.tools.map((tool) => tool.name);
    assert.ok(activeTools.includes("fixture_global_tool"));
    assert.ok(activeTools.includes("desktop_act"));
  } finally {
    session.dispose();
  }
});

test("trusted (Windows-style) sessions activate cards, instant tools and codemode without an allowlist; pi_os_escalate only on Auto", async () => {
  const runtimes = fauxRuntimes();
  // A macOS session with trusted globals is a full pi session: a copy of the fixture agent dir (its session bucket)
  // and a temporary home folder (its working directory), never the repository or the user's own.
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-os-global-")));
  const agentDir = join(root, "agent");
  cpSync(fixtureAgentDir, agentDir, { recursive: true });
  const home = join(root, "home");
  mkdirSync(home);
  try {
    for (const selection of [null, { provider: "fx", modelId: "fast", thinkingLevel: "off" }]) {
      // Nothing stored means Auto on macOS only (a Windows host keeps pi's own default model, so there is no
      // Auto to hand off to; integrationAgent pins that path).
      const live = await createLiveSession({
        hostClient: { invokeTool: async () => ({ ok: true, result: {} }) } as unknown as HostClient,
        contextId: "ctx-test", prompt: "", snapshot: snapshot("ctx-test"), capturesDir: CAPTURES, log: () => {},
        readOnly: false, resourceSelection: { mode: "trustedGlobal" }, modelSelection: selection,
        services: { agentDir, home, modelRuntime: runtimes.factory, platform: "darwin" },
      });
      try {
        const tools = live.controls.toolNames!;
        for (const name of ["fixture_global_tool", "desktop_act", "instant_calc", "instant_convert_currency", "instant_time_in", "show_result", "codemode",
          "read", "bash", "edit", "write"]) {
          assert.ok(tools.includes(name), `${name} is active on the trusted path`);
        }
        // No host launcher routes were negotiated: the host-backed tools do not register.
        assert.ok(!tools.includes("find_files") && !tools.includes("open_item"));
        assert.equal(tools.includes("pi_os_escalate"), selection === null, "the hand-off tool exists only where Auto acts on it");
        assert.equal(Boolean(live.controls.auto), selection === null);
      } finally { await live.close(); }
    }
    // A session that never prompted leaves no pi session file behind.
    const sessions = join(agentDir, "sessions");
    const files = existsSync(sessions) ? readdirSync(sessions, { recursive: true }).map(String).filter(name => name.endsWith(".jsonl")) : [];
    assert.deepEqual(files, []);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("codemode advertises exactly the script-callable tools: trusted built-ins and global tools are never offered to scripts", async () => {
  const declared = async (wrap: boolean) => {
    const { extensions } = sessionExtensions({ contextId: "ctx-test", hostClient: {} as HostClient, capturesDir: CAPTURES, readOnly: false });
    const list = wrap ? extensions : extensions.map(extension =>
      typeof extension !== "function" && extension.name === "pi-os-codemode" ? codemodeExtensionFactories()[1]! : extension);
    const loader = await loadAgentResources(list, process.cwd(), fixtureAgentDir, false);
    const modelRuntime = await ModelRuntime.create({ authPath: join(fixtureAgentDir, "auth.json"), modelsPath: join(fixtureAgentDir, "missing-models.json") });
    const { session } = await createAgentSession({ agentDir: fixtureAgentDir, modelRuntime, resourceLoader: loader,
      sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory() });
    try {
      session.setActiveToolsByName([...session.getActiveToolNames(), "codemode"]);
      return new Map(session.agent.state.tools.map(tool => [tool.name, tool.description]));
    } finally { session.dispose(); }
  };
  const wrapped = await declared(true);
  assert.match(wrapped.get("instant_calc")!, /Codemode: `tools\.instant_calc\(args\)`/);
  assert.match(wrapped.get("desktop_get_context")!, /Codemode:/);
  for (const blocked of ["bash", "read", "edit", "write", "fixture_global_tool"]) {
    if (wrapped.has(blocked)) assert.doesNotMatch(wrapped.get(blocked)!, /Codemode:/, `${blocked} is not advertised to scripts`);
  }
  for (const modelOnly of ["desktop_act", "show_result", "pi_os_escalate"]) {
    if (wrapped.has(modelOnly)) assert.doesNotMatch(wrapped.get(modelOnly)!, /Codemode:/, modelOnly);
  }
  // Without the pi-os narrowing, pi itself would tell the model that scripts may call bash.
  const raw = await declared(false);
  assert.match(raw.get("bash")!, /Codemode:/);
});
