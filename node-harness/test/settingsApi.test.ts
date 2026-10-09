import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { getSupportedThinkingLevels, type Model } from "@earendil-works/pi-ai";
import { HarnessServer } from "../src/server.js";
import { loadConfig } from "../src/config.js";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import { AgentResourceSettings } from "../src/agent/resourceSettings.js";
import type { HostClient } from "../src/hostClient.js";
import type { ClassifierFactoryDeps } from "../src/classifier/factory.js";

const fixtureModel: Model<"openai-completions"> = { id: "fixture-model", name: "Fixture model", provider: "fixture", api: "openai-completions",
  baseUrl: "https://never-called.invalid", reasoning: true, input: ["text", "image"],
  contextWindow: 8192, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const INPUT = ["window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll"];

async function settingsServer(options: {
  models?: Model<any>[]; allowInput?: () => boolean; platform?: NodeJS.Platform; classifierDeps?: ClassifierFactoryDeps;
} = {}) {
  const dir = await mkdtemp(join(tmpdir(), "pi-os-settings-api-"));
  const calls: boolean[] = [];
  const resources = new AgentResourceSettings(join(dir, "resources.json"));
  const models = new AgentModelSettings(join(dir, "settings.json"), () => {});
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: "test", readOnly: false, agentEnabled: false }, {
    modelSettings: models, resourceSettings: resources, platform: options.platform ?? "darwin",
    ...(options.classifierDeps ? { classifierDeps: options.classifierDeps } : {}),
    hostClient: { getToolNames: async () => (options.allowInput?.() ?? true) ? INPUT : [] } as unknown as HostClient,
    modelRuntimeFactory: async (trusted = false) => {
      calls.push(trusted);
      return { getAvailable: async () => options.models ?? [fixtureModel] } as unknown as ModelRuntime;
    },
  });
  const base = `http://127.0.0.1:${await server.listen()}`;
  const headers = { "X-Harness-Token": "test", "Content-Type": "application/json" };
  const post = (path: string, body: unknown) => fetch(base + path, { method: "POST", headers, body: JSON.stringify(body) });
  const get = async (path: string) => (await fetch(base + path, { headers })).json() as Promise<any>;
  return { dir, server, base, headers, post, get, calls, models, resources,
    async dispose() { await server.close(); await rm(dir, { recursive: true, force: true }); } };
}

test("model/resource Settings APIs round-trip against injected catalog with no provider networking", async () => {
  let allowInput = true;
  const f = await settingsServer({ allowInput: () => allowInput });
  const { base, headers, post, calls, models, resources, dir } = f;
  try {
    assert.equal((await fetch(base + "/settings/resources")).status, 401);
    const catalog = await f.get("/models");
    // Auto is offered first whenever a physical model is usable; it is the default with nothing stored.
    assert.deepEqual(catalog.models.map((m: any) => `${m.provider}/${m.id}`), ["pi-os/auto", "fixture/fixture-model"]);
    assert.deepEqual(catalog.models[0], { provider: "pi-os", id: "auto", name: "Auto", reasoning: true, thinkingLevels: ["low", "medium", "high"] });
    assert.deepEqual(catalog.current, { provider: "pi-os", modelId: "auto", thinkingLevel: "medium" });
    assert.equal(catalog.currentIsDefault, true);
    const selection = { provider: fixtureModel.provider, modelId: fixtureModel.id, thinkingLevel: getSupportedThinkingLevels(fixtureModel)[0] };
    assert.equal((await post("/settings/model", selection)).status, 200);
    assert.deepEqual(new AgentModelSettings(join(dir, "settings.json"), () => {}).get(), selection);
    assert.equal((await post("/settings/model", { ...selection, thinkingLevel: "not-supported" })).status, 400);
    assert.equal((await post("/settings/model", { ...selection, modelId: "not-authenticated" })).status, 400);
    assert.deepEqual(models.get(), selection);
    const stored = await f.get("/models");
    assert.deepEqual(stored.current, selection);
    assert.equal(stored.currentIsDefault, undefined);
    assert.equal((await post("/settings/resources", { mode: "trustedGlobal" })).status, 400);
    assert.equal(resources.get().mode, "isolated");
    assert.equal((await post("/settings/resources", { mode: "trustedGlobal", acknowledgeUnpinnedAccess: true })).status, 200);
    await fetch(base + "/models", { headers });
    assert.equal(calls.at(-1), true);
    allowInput = false;
    await fetch(base + "/models", { headers });
    assert.equal(calls.at(-1), false, "Revoked control must suppress trusted resource loading");
    assert.equal((await post("/settings/resources", { mode: "trustedGlobal", acknowledgeUnpinnedAccess: true })).status, 409);
    assert.equal((await post("/settings/resources", { mode: "isolated" })).status, 200);
    assert.equal(resources.get().mode, "isolated");
  } finally { await f.dispose(); }
});

test("GET /models on Windows: Auto is listed but opt-in; nothing stored reports pi's default (current null)", async () => {
  const f = await settingsServer({ platform: "win32" });
  try {
    const catalog = await f.get("/models");
    assert.deepEqual(catalog.models.map((m: any) => `${m.provider}/${m.id}`), ["pi-os/auto", "fixture/fixture-model"]);
    assert.equal(catalog.current, null);
    assert.equal(catalog.currentIsDefault, undefined);
    // Choosing Auto explicitly makes it the current selection there too.
    assert.equal((await f.post("/settings/model", { provider: "pi-os", modelId: "auto", thinkingLevel: "medium" })).status, 200);
    assert.deepEqual((await f.get("/models")).current, { provider: "pi-os", modelId: "auto", thinkingLevel: "medium" });
    // The routing bias only follows a stored Auto selection; with a manual model it never writes one.
    assert.equal((await f.post("/settings/model", { provider: "fixture", modelId: "fixture-model", thinkingLevel: "off" })).status, 200);
    assert.equal((await f.post("/settings/routing", { bias: "speed" })).status, 200);
    assert.deepEqual(f.models.get(), { provider: "fixture", modelId: "fixture-model", thinkingLevel: "off" });
  } finally { await f.dispose(); }
});

test("GET /models keeps the empty-catalog hint: no usable model means no Auto and no current", async () => {
  const f = await settingsServer({ models: [] });
  try {
    assert.deepEqual(await f.get("/models"), { models: [], current: null });
  } finally { await f.dispose(); }
});

test("Auto selection and routing settings stay in step and never clobber sibling keys in settings.json", async () => {
  const f = await settingsServer();
  const path = join(f.dir, "settings.json");
  try {
    // A key this build does not know (a newer host, a hand edit) must survive every write.
    await writeFile(path, JSON.stringify({ future: { keep: true } }));
    const fresh = new AgentModelSettings(path, () => {});
    assert.equal(fresh.get(), null);

    assert.deepEqual(await f.get("/settings/routing"), { bias: "balanced", maxAutoTier: "deep", allowLocalModels: false });
    // Auto is valid without a catalog lookup; its levels are the routing bias.
    assert.equal((await f.post("/settings/model", { provider: "pi-os", modelId: "auto", thinkingLevel: "xhigh" })).status, 400);
    assert.equal((await f.post("/settings/model", { provider: "pi-os", modelId: "auto", thinkingLevel: "low" })).status, 200);
    assert.equal((await f.get("/settings/routing")).bias, "speed");

    const routing = await f.post("/settings/routing", { bias: "quality", maxAutoTier: "standard", allowLocalModels: false });
    assert.equal(routing.status, 200);
    assert.deepEqual(await routing.json(), { bias: "quality", maxAutoTier: "standard", allowLocalModels: false });
    // The stored Auto selection follows the bias, so the next session runs at that level.
    assert.deepEqual(f.models.get(), { provider: "pi-os", modelId: "auto", thinkingLevel: "high" });

    const file = JSON.parse(await readFile(path, "utf8"));
    assert.deepEqual(file.future, { keep: true });
    assert.deepEqual(file.model, { provider: "pi-os", modelId: "auto", thinkingLevel: "high" });
    assert.deepEqual(file.routing, { bias: "quality", maxAutoTier: "standard", allowLocalModels: false });

    // Saving a model never erases the routing key (the old writer did).
    assert.equal((await f.post("/settings/model", { provider: "fixture", modelId: "fixture-model", thinkingLevel: "off" })).status, 200);
    const after = JSON.parse(await readFile(path, "utf8"));
    assert.deepEqual(after.routing, file.routing);
    assert.deepEqual(after.future, { keep: true });

    // Tier overrides are validated against the available catalog; unknown keys are rejected.
    assert.equal((await f.post("/settings/routing", { bias: "fast" })).status, 400);
    assert.equal((await f.post("/settings/routing", { unknown: 1 })).status, 400);
    const missing = await f.post("/settings/routing", { tierOverrides: { quick: { provider: "nope", id: "missing", thinkingLevel: "off" } } });
    assert.equal(missing.status, 400);
    assert.match(((await missing.json()) as any).error.message, /not available/);
    const pinned = await f.post("/settings/routing", { tierOverrides: { quick: { provider: "fixture", modelId: "fixture-model", thinkingLevel: "off" } } });
    assert.equal(pinned.status, 200);
    assert.deepEqual(((await pinned.json()) as any).tierOverrides, { quick: { provider: "fixture", id: "fixture-model", thinkingLevel: "off" } });
    assert.equal((await f.post("/settings/routing", { tierOverrides: null })).status, 200);
    assert.equal((await f.get("/settings/routing")).tierOverrides, undefined);
  } finally { await f.dispose(); }
});

test("classifier settings: off by default, strict validation, read-only status, separate classifier.json", async () => {
  const f = await settingsServer();
  try {
    const initial = await f.get("/settings/classifier");
    assert.equal(initial.kind, "off");
    assert.equal(initial.shadowLog, false);
    // Under the test guard (PI_OS_LAYA=0) Laya could never start, which layaLaunch says.
    assert.deepEqual(initial.status, { kind: "off", state: "off", shadowLog: false, layaLaunch: { ok: false, reason: "disabled_by_env" } });

    for (const body of [{}, { kind: "gpu" }, { kind: "laya", python: "relative/python" }, { kind: "pi", provider: " spaced" }]) {
      assert.equal((await f.post("/settings/classifier", body)).status, 400, JSON.stringify(body));
    }
    // A pi catalog classifier without a model is stored but reported unavailable; nothing starts.
    const saved = await f.post("/settings/classifier", { kind: "pi", provider: "cloudflare-workers-ai", status: { state: "ready" } });
    assert.equal(saved.status, 200);
    const body = await saved.json() as any;
    assert.equal(body.kind, "pi");
    assert.equal(body.status.state, "unavailable", "the echoed status is ignored; status is read-only");
    assert.equal(body.status.reason, "model_not_configured");

    // Laya under the test guard (PI_OS_LAYA=0) is inert: the real engine can never start.
    const laya = await f.post("/settings/classifier", { kind: "laya", python: "/usr/bin/python3", modelDir: "/models/laya", shadowLog: true });
    assert.equal(laya.status, 200);
    assert.deepEqual(((await laya.json()) as any).status, {
      kind: "laya", state: "unavailable", shadowLog: false, reason: "disabled_by_env", layaLaunch: { ok: false, reason: "disabled_by_env" },
    });
    const file = JSON.parse(await readFile(join(f.dir, "classifier.json"), "utf8"));
    assert.equal(file.kind, "laya");
    assert.equal(file.shadowLog, true);
    assert.equal(file.status, undefined);

    assert.equal((await f.post("/settings/classifier", { kind: "off" })).status, 200);
    assert.equal((await f.get("/settings/classifier")).status.state, "off");
  } finally { await f.dispose(); }
});

test("classifier settings: status.layaLaunch says what Laya still needs (existence checks only, nothing spawns)", async () => {
  const support = await mkdtemp(join(tmpdir(), "pi-os-laya-launch-"));
  const python = join(support, "venv", "bin", "python3");
  const modelDir = join(support, "model");
  const present = new Set([python, join(modelDir, "rl_agent_config.json")]);
  const f = await settingsServer({ classifierDeps: { env: {}, exists: (path) => present.has(path) || path.endsWith("laya_intent_sidecar.py"), supportDir: support } });
  try {
    const initial = await f.get("/settings/classifier");
    assert.deepEqual(initial.status.layaLaunch, { ok: false, reason: "python_not_configured" }, "reported while kind is off too");
    const withPython = await (await f.post("/settings/classifier", { kind: "off", python })).json() as any;
    assert.deepEqual(withPython.status.layaLaunch, { ok: false, reason: "model_dir_not_configured" });
    // An echoed status (and its layaLaunch) in the body is ignored; the server recomputes it.
    const ready = await (await f.post("/settings/classifier", { kind: "off", python, modelDir, status: { layaLaunch: { ok: false } } })).json() as any;
    assert.deepEqual(ready.status.layaLaunch, { ok: true });
    assert.equal(ready.kind, "off");
    // A legacy or echoed `script` is accepted and dropped: the shipped sidecar is the only script.
    const echoed = await f.post("/settings/classifier", { kind: "off", python, modelDir, script: "/tmp/payload.py" });
    assert.equal(echoed.status, 200);
    assert.equal(((await echoed.json()) as any).script, undefined);
    assert.equal((await f.get("/settings/classifier")).script, undefined);
    assert.equal(JSON.parse(await readFile(join(f.dir, "classifier.json"), "utf8")).script, undefined);
    assert.deepEqual((await f.get("/settings/classifier")).status.layaLaunch, { ok: true });
    // Turning Laya on with picked paths configures it (lazily: nothing starts until first use).
    const on = await (await f.post("/settings/classifier", { kind: "laya", python, modelDir })).json() as any;
    assert.equal(on.kind, "laya");
    assert.notEqual(on.status.reason, "python_not_configured");
    assert.notEqual(on.status.state, "unavailable");
    assert.deepEqual(on.status.layaLaunch, { ok: true });
  } finally {
    await f.dispose();
    await rm(support, { recursive: true, force: true });
  }
});

test("browser-originated requests are refused (403 forbidden_origin) and bodies must be JSON, in token and insecure-dev modes", async () => {
  for (const insecureDev of [false, true]) {
    const dir = await mkdtemp(join(tmpdir(), "pi-os-origin-"));
    const server = new HarnessServer({
      ...loadConfig({}), port: 0, agentEnabled: false, ...(insecureDev ? { hostToken: undefined, insecureDev: true } : { hostToken: "test" }),
    }, {
      modelSettings: new AgentModelSettings(join(dir, "settings.json"), () => {}),
      resourceSettings: new AgentResourceSettings(join(dir, "resources.json")),
      hostClient: { getToolNames: async () => [] } as unknown as HostClient,
      supportDir: dir,
    });
    const base = `http://127.0.0.1:${await server.listen()}`;
    const token = insecureDev ? {} : { "X-Harness-Token": "test" };
    const body = JSON.stringify({ kind: "laya", python: "/usr/bin/python3", modelDir: "/tmp" });
    try {
      for (const browser of [{ Origin: "https://evil.example" }, { "Sec-Fetch-Site": "cross-site" }, { Origin: "null" }]) {
        const response = await fetch(`${base}/settings/classifier`, { method: "POST", headers: { ...token, ...browser, "Content-Type": "application/json" }, body });
        assert.equal(response.status, 403, `${insecureDev} ${JSON.stringify(browser)}`);
        assert.equal(((await response.json()) as any).error.code, "forbidden_origin");
      }
      // A CORS "simple request" (text/plain, no preflight) never reaches a handler either.
      const plain = await fetch(`${base}/settings/classifier`, { method: "POST", headers: { ...token, "Content-Type": "text/plain" }, body });
      assert.equal(plain.status, 415);
      assert.equal(((await plain.json()) as any).error.code, "unsupported_media_type");
      // Nothing was stored.
      assert.equal(existsSync(join(dir, "classifier.json")), false);
      assert.equal((await fetch(`${base}/settings/classifier`, { headers: token })).status, 200, "native clients (no Origin) still work");
      assert.equal((await fetch(`${base}/health`, { headers: { Origin: "https://evil.example" } })).status, 200, "health stays open");
    } finally {
      await server.close();
      await rm(dir, { recursive: true, force: true });
    }
  }
});
