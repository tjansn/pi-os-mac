import assert from "node:assert/strict";
import { realpathSync } from "node:fs";
import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { Type } from "typebox";
import { createAgentSession, ModelRuntime, ProjectTrustStore, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { AgentResourceSettings, effectiveResourceMode } from "../src/agent/resourceSettings.js";
import { loadAgentResources, projectTrustOf, registerResourceProviders, resolveProjectTrust } from "../src/agent/resources.js";

test("resource compatibility is explicit, persisted, and always suppressed by read-only mode", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pi-os-resources-"));
  const path = join(dir, "resources.json");
  const settings = new AgentResourceSettings(path);
  try {
    assert.deepEqual(settings.get(), { mode: "isolated" });
    assert.throws(() => settings.set("trustedGlobal", false), /acknowledgement/);
    settings.set("trustedGlobal", true);
    assert.deepEqual(new AgentResourceSettings(path).get(), { mode: "trustedGlobal" });
    assert.equal(effectiveResourceMode("darwin", true, settings.get()), "isolated");
    assert.equal(effectiveResourceMode("darwin", false, settings.get()), "trustedGlobal");
    assert.equal(effectiveResourceMode("darwin", false), "isolated");
    assert.equal(effectiveResourceMode("win32", false), "trustedGlobal");
    await writeFile(path, '{"mode":"trustedGlobal"}');
    assert.equal(settings.get().mode, "isolated");
    await writeFile(path, "broken");
    assert.equal(settings.get().mode, "isolated");
    settings.set("isolated", false);
    assert.equal(JSON.parse(await readFile(path, "utf8")).trustAcknowledgement, 0);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("full pi sessions (trusted Mac globals) follow pi's project trust: context files load, project extensions only in a trusted folder", { skip: process.platform !== "darwin" }, async () => {
  const root = realpathSync(await mkdtemp(join(tmpdir(), "pi-os-global-compat-")));
  // A copy of the fixture agent dir: trust decisions are written to its trust.json, never the user's.
  const dir = join(root, "agent");
  await cp(resolve("test/fixtures/global-agent-dir"), dir, { recursive: true });
  const cwd = join(root, "project");
  await mkdir(join(cwd, ".pi/extensions"), { recursive: true });
  await writeFile(join(cwd, ".pi/extensions/project.ts"), [
    'import { Type } from "typebox";',
    "export default function projectFixture(pi: any): void {",
    '  pi.registerTool({ name: "fixture_project_tool", label: "Project", description: "Project fixture tool.", parameters: Type.Object({}),',
    '    async execute() { return { content: [{ type: "text", text: "project" }], details: {} }; } });',
    "}",
  ].join("\n"));
  await writeFile(join(cwd, "AGENTS.md"), "PROJECT_CONTEXT_LOADS_LIKE_PI");
  const load = (isolated = false) => loadAgentResources([{ name: "fixture", factory() {} }], cwd, dir, isolated, { platform: "darwin" });
  const hasProjectTool = (loader: Awaited<ReturnType<typeof load>>) => loader.getExtensions().extensions.some(extension => extension.tools.has("fixture_project_tool"));
  const hasContext = (loader: Awaited<ReturnType<typeof load>>) => loader.getAgentsFiles().agentsFiles.some(file => file.content.includes("PROJECT_CONTEXT_LOADS_LIKE_PI"));
  try {
    // A folder with project resources and no decision: pi's default "ask" with nobody to ask means untrusted.
    const untrusted = await load();
    assert.equal(projectTrustOf(untrusted), false);
    assert.equal(untrusted.getExtensions().errors.length, 0);
    assert.ok(untrusted.getSkills().skills.some(skill => skill.name === "fixture-global-skill"));
    assert.ok(hasContext(untrusted), "the folder's AGENTS.md loads like in terminal pi");
    assert.ok(!hasProjectTool(untrusted), "an untrusted project's extension never runs");
    const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "models.json") });
    const { session } = await createAgentSession({ cwd, agentDir: dir, modelRuntime: runtime, resourceLoader: untrusted,
      sessionManager: SessionManager.inMemory(cwd), settingsManager: SettingsManager.inMemory() });
    try {
      const tools = session.getAllTools().map(tool => tool.name);
      assert.ok(tools.includes("fixture_global_tool"));
      assert.ok(tools.includes("bash"));
      assert.ok(!tools.includes("fixture_project_tool"));
    } finally { session.dispose(); }

    // pi's trust store decides, as `pi` in that folder would.
    new ProjectTrustStore(dir).set(cwd, true);
    const trusted = await load();
    assert.equal(projectTrustOf(trusted), true);
    assert.ok(hasProjectTool(trusted) && hasContext(trusted));
    new ProjectTrustStore(dir).set(cwd, false);
    assert.equal(projectTrustOf(await load()), false);
    // Without a decision, pi's defaultProjectTrust setting applies.
    new ProjectTrustStore(dir).set(cwd, null);
    await writeFile(join(dir, "settings.json"), JSON.stringify({ defaultProjectTrust: "always" }));
    assert.equal(projectTrustOf(await load()), true);
    // A folder without project resources is trusted; isolated sessions never load project resources or decide trust.
    assert.equal(await resolveProjectTrust({ cwd: join(root, "agent", "extensions"), agentDir: dir }), true);
    const isolated = await load(true);
    assert.equal(projectTrustOf(isolated), undefined);
    assert.ok(!hasProjectTool(isolated) && !hasContext(isolated));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("trusted extension providers are registered before model selection without startup hooks or inference", async () => {
  const dir = resolve("test/fixtures/global-agent-dir");
  let started = 0;
  let activeTools: (() => string[]) | undefined;
  const loader = await loadAgentResources([{ name: "fixture-provider", factory(pi) {
    pi.on("session_start", async () => { started += 1; });
    activeTools = () => pi.getActiveTools();
    pi.registerTool({ name: "fixture_probe", label: "Probe", description: "Fixture", parameters: Type.Object({}),
      async execute() { return { content: [{ type: "text", text: "fixture" }], details: {} }; } });
    pi.registerProvider("fixture-custom", { baseUrl: "https://never-called.invalid/v1", apiKey: "fixture-key", api: "openai-completions",
      models: [{ id: "fixture-model", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  } }], process.cwd(), dir, true);
  const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "models.json") });
  assert.equal(runtime.getModel("fixture-custom", "fixture-model"), undefined);
  const disposeBootstrap = await registerResourceProviders(loader, runtime);
  try {
    assert.equal(runtime.getModel("fixture-custom", "fixture-model")?.id, "fixture-model");
    const { session } = await createAgentSession({ modelRuntime: runtime, resourceLoader: loader,
      model: runtime.getModel("fixture-custom", "fixture-model"), tools: ["fixture_probe"],
      settingsManager: SettingsManager.inMemory(), sessionManager: SessionManager.inMemory() });
    try { assert.deepEqual(activeTools!(), ["fixture_probe"]); }
    finally { session.dispose(); }
    assert.equal(started, 0);
  } finally { disposeBootstrap(); }
});
