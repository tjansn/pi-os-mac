import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { test } from "node:test";
import type { ClassifierContext, ClassifierModel, ClassifierResult, ModelsClassifierOptions } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { LayaSidecar, LayaSidecarError, type LayaPredictRequest, type LayaPredictResult } from "../src/classifier/laya.js";
import { type ClassifierRuntime, PiCatalogClassifier } from "../src/classifier/piClassifier.js";
import { LAYA_CLASSIFIER_API, LAYA_MODEL_ID, LAYA_PROVIDER_ID, type LayaPredictBackend, registerLayaProvider } from "../src/classifier/provider.js";
import { PI_OS_INTENT_QUESTIONS } from "../src/classifier/questions.js";

// No network, no GPU: pi's runtime with temp auth/models files, Laya behind a fake backend
// (or the sidecar's fake engine when python3 is available).

const QUESTIONS: ClassifierContext["questions"] = {
  kind: { type: "choice", instructions: "Which kind?", criteria: { bug: "a defect", question: "a question" } },
  urgency: { type: "score", instructions: "How urgent?", criteria: ["later", "soon", "now"] },
  visible: { type: "bool", instructions: "On screen?", criteria: { true: "refers to the screen", false: "self-contained" } },
};

class FakeBackend implements LayaPredictBackend {
  available = true;
  calls: LayaPredictRequest[] = [];
  next: LayaPredictResult | Error = {
    answers: {
      kind: { type: "choice", choice: "bug", probabilities: { bug: 0.8, question: 0.2 }, confidence: 0.8 },
      urgency: { type: "score", score: 0.6, probabilities: { 0: 0.6, 1: 0.2, 2: 0.2 }, confidence: 0.6 },
      visible: { type: "bool", probability: 0.9 },
    },
    usage: { inputTokens: 12, stateTokens: 4 },
  };

  async predict(request: LayaPredictRequest, options?: { signal?: AbortSignal }): Promise<LayaPredictResult> {
    this.calls.push(request);
    if (options?.signal?.aborted) throw new LayaSidecarError("aborted");
    if (this.next instanceof Error) throw this.next;
    return this.next;
  }
}

async function piRuntime(): Promise<ModelRuntime> {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-classifier-runtime-"));
  return ModelRuntime.create({
    authPath: join(dir, "auth.json"), modelsPath: join(dir, "models.json"), modelsStorePath: join(dir, "models-store.json"),
    refreshOnCreate: false, allowModelNetwork: false,
  });
}

function layaModel(runtime: ModelRuntime): ClassifierModel<string> {
  const model = runtime.getModelOfType("classifier", LAYA_PROVIDER_ID, LAYA_MODEL_ID);
  assert.ok(model, "laya/multilingual is registered");
  return model;
}

test("Laya registers as the native pi classifier laya/multilingual and answers runtime.classify", async () => {
  const runtime = await piRuntime();
  const backend = new FakeBackend();
  const unregister = registerLayaProvider(runtime, backend);
  const model = layaModel(runtime);
  assert.deepEqual([model.api, model.type, model.contextWindow, model.input], [LAYA_CLASSIFIER_API, "classifier", 1024, ["text"]]);
  assert.equal(runtime.getModel(LAYA_PROVIDER_ID, LAYA_MODEL_ID), undefined); // never a chat model

  const state = { utterance: "is this a bug" };
  const result = await runtime.classify(model, { state, questions: QUESTIONS });
  assert.equal(result.stopReason, "stop", result.errorMessage);
  assert.deepEqual(result.answers, {
    kind: { type: "choice", choice: "bug", probabilities: { bug: 0.8, question: 0.2 }, confidence: 0.8 },
    urgency: { type: "score", score: 0.6, confidence: 0.6 },
    visible: { type: "bool", probability: 0.9 },
  });
  assert.deepEqual([result.provider, result.model, result.usage?.input, result.usage?.cost.total], ["laya", "multilingual", 12, 0]);
  assert.deepEqual(backend.calls, [{ state, questions: QUESTIONS }]);

  // Discoverable the way codemode's models.getAvailableOfType() looks it up (keyless, local).
  await runtime.refresh({ allowNetwork: false, providers: [LAYA_PROVIDER_ID] });
  const available = await runtime.getAvailableOfType("classifier", LAYA_PROVIDER_ID);
  assert.deepEqual(available.map((m) => `${m.provider}/${m.id}`), ["laya/multilingual"]);

  unregister();
  assert.equal(runtime.getModelOfType("classifier", LAYA_PROVIDER_ID, LAYA_MODEL_ID), undefined);
});

test("temperature, sidecar errors, aborts and a failed sidecar become pi results (never rejections)", async () => {
  const runtime = await piRuntime();
  const backend = new FakeBackend();
  registerLayaProvider(runtime, backend);
  const model = layaModel(runtime);
  const context = { state: { utterance: "x" }, questions: QUESTIONS };

  const softened = await runtime.classify(model, context, { temperature: 2 });
  assert.equal(softened.stopReason, "stop");
  const kind = softened.answers.kind;
  assert.ok(kind?.type === "choice");
  assert.deepEqual(kind.probabilities, { bug: 0.6667, question: 0.3333 });
  assert.equal(softened.answers.visible?.type === "bool" ? softened.answers.visible.probability : 0, 0.75);
  const urgency = softened.answers.urgency;
  assert.ok(urgency?.type === "score" && urgency.score > 0.6);

  assert.match((await runtime.classify(model, context, { temperature: 0 })).errorMessage ?? "", /bad_temperature/u);

  backend.next = new LayaSidecarError("timeout");
  const timedOut = await runtime.classify(model, context);
  assert.deepEqual([timedOut.stopReason, timedOut.errorMessage, timedOut.answers], ["error", "Laya sidecar: timeout", {}]);

  backend.next = new Error("raw failure mentioning SENTINEL4711");
  const internal = await runtime.classify(model, context);
  assert.equal(internal.errorMessage, "Laya sidecar: internal"); // no raw messages pass through

  const controller = new AbortController();
  controller.abort();
  assert.equal((await runtime.classify(model, context, { signal: controller.signal })).stopReason, "aborted");

  backend.available = false; // the sidecar gave up: the provider reports itself unconfigured
  const calls = backend.calls.length;
  const unavailable = await runtime.classify(model, context);
  assert.equal(unavailable.stopReason, "error");
  assert.equal(backend.calls.length, calls);
});

function catalogModel(provider: string, id: string): ClassifierModel<string> {
  return {
    type: "classifier", id, name: id, api: "typesafe-system-one", provider, baseUrl: "https://api.invalid/v1/",
    input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 64_000,
  };
}

function fakeCatalog(respond: (context: ClassifierContext, options?: ModelsClassifierOptions) => Promise<ClassifierResult>) {
  const calls: Array<{ context: ClassifierContext; options?: ModelsClassifierOptions }> = [];
  const runtime: ClassifierRuntime = {
    getModelOfType: ((type: string, provider: string, id: string) =>
      type === "classifier" && provider === "typesafe" && id === "jev-latest" ? catalogModel(provider, id) : undefined) as ClassifierRuntime["getModelOfType"],
    classify: async (_model, context, options) => {
      calls.push({ context, ...(options ? { options } : {}) });
      return respond(context, options);
    },
  };
  return { runtime, calls };
}

const jevAnswer = (stopReason: ClassifierResult["stopReason"] = "stop"): ClassifierResult => ({
  api: "typesafe-system-one", provider: "typesafe", model: "jev-latest", stopReason, timestamp: 0,
  answers: stopReason === "stop" ? {
    intent: { type: "choice", choice: "file_search", probabilities: { file_search: 0.93, agent_task: 0.07 }, confidence: 0.9 },
    tier: { type: "score", score: 0.2, confidence: 0.8 },
    screen: { type: "bool", probability: 0.04 },
  } : {},
});

test("PiCatalogClassifier sends pi-os-intent-v1 to a catalog classifier and maps the answers", async () => {
  const logs: string[] = [];
  const { runtime, calls } = fakeCatalog(async () => jevAnswer());
  const classifier = new PiCatalogClassifier({ provider: "typesafe", model: "jev-latest", runtime, log: (line) => logs.push(line) });
  assert.equal(classifier.name, "pi:typesafe/jev-latest");
  const hints = await classifier.classify("  find the PDF about my lease ", new AbortController().signal);
  assert.deepEqual({ ...hints, latencyMs: 0 }, {
    source: "pi-classifier", latencyMs: 0, intent: "search_computer", intentP: 0.93, tier: "instant", needsScreen: 0.04,
  });
  assert.deepEqual(calls[0]?.context, { state: { utterance: "find the PDF about my lease" }, questions: PI_OS_INTENT_QUESTIONS });
  assert.equal(calls[0]?.options?.maxRetries, 0);
  assert.ok(calls[0]?.options?.signal instanceof AbortSignal);

  assert.equal(await classifier.classify("x".repeat(501), new AbortController().signal), null);
  const aborted = new AbortController();
  aborted.abort();
  assert.equal(await classifier.classify("open Spotify", aborted.signal), null);
  assert.equal(calls.length, 1);
  assert.equal(logs.length, 0);

  const missing = new PiCatalogClassifier({ provider: "cloudflare-workers-ai", model: "@cf/cloudflare/clef-flash", runtime, log: (line) => logs.push(line) });
  assert.equal(await missing.classify("open Spotify", new AbortController().signal), null);
  assert.equal(await missing.classify("open Spotify", new AbortController().signal), null);
  assert.deepEqual(logs, ["[classifier] pi:cloudflare-workers-ai/@cf/cloudflare/clef-flash is not in the pi catalog; no hints"]);
});

test("PiCatalogClassifier returns null on provider errors, deadlines and runtime failures", async () => {
  const failing = new PiCatalogClassifier({ provider: "typesafe", model: "jev-latest", runtime: fakeCatalog(async () => jevAnswer("error")).runtime });
  assert.equal(await failing.classify("open Spotify", new AbortController().signal), null);
  const throwing = new PiCatalogClassifier({
    provider: "typesafe", model: "jev-latest", runtime: fakeCatalog(async () => { throw new Error("boom"); }).runtime,
  });
  assert.equal(await throwing.classify("open Spotify", new AbortController().signal), null);

  const hanging = new PiCatalogClassifier({
    provider: "typesafe", model: "jev-latest", deadlineMs: 50, runtime: fakeCatalog(() => new Promise<ClassifierResult>(() => {})).runtime,
  });
  const started = performance.now();
  assert.equal(await hanging.classify("open Spotify", new AbortController().signal), null);
  assert.ok(performance.now() - started < 1_000);

  let attempts = 0;
  const flaky = new PiCatalogClassifier({
    provider: "typesafe", model: "jev-latest",
    runtime: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("auth file unreadable");
      return fakeCatalog(async () => jevAnswer()).runtime;
    },
  });
  assert.equal(await flaky.classify("open Spotify", new AbortController().signal), null);
  assert.equal((await flaky.classify("open Spotify", new AbortController().signal))?.intent, "search_computer");
  assert.equal(attempts, 2);
});

test("kind pi can point at laya/multilingual: catalog classifier -> runtime.classify -> Laya provider", async () => {
  const runtime = await piRuntime();
  const backend = new FakeBackend();
  backend.next = {
    answers: {
      intent: { type: "choice", choice: "app_launch", probabilities: { app_launch: 0.7, agent_task: 0.3 }, confidence: 0.7 },
      tier: { type: "score", score: 0.1, probabilities: { 0: 0.9, 1: 0.1, 2: 0, 3: 0 }, confidence: 0.9 },
      screen: { type: "bool", probability: 0.02 },
      surface: { type: "choice", choice: "native_app", probabilities: { browser: 0, native_app: 1, none: 0 }, confidence: 1 },
    },
    usage: { inputTokens: 30, stateTokens: 5 },
  };
  registerLayaProvider(runtime, backend);
  const classifier = new PiCatalogClassifier({ provider: LAYA_PROVIDER_ID, model: LAYA_MODEL_ID, runtime });
  const hints = await classifier.classify("open Spotify", new AbortController().signal);
  assert.deepEqual([hints?.source, hints?.intent, hints?.intentP, hints?.tier, hints?.needsScreen], ["pi-classifier", "open_launch", 0.7, "instant", 0.02]);
  assert.deepEqual(backend.calls[0]?.questions, PI_OS_INTENT_QUESTIONS);
});

function findPython(): string | undefined {
  for (const candidate of [process.env.PI_OS_TEST_PYTHON, "python3", "python"]) {
    if (!candidate) continue;
    const probe = spawnSync(candidate, ["-I", "-B", "-c", "import sys; assert sys.version_info >= (3, 8); print(sys.executable)"], {
      encoding: "utf8", timeout: 10_000,
    });
    const path = probe.stdout?.trim();
    if (probe.status === 0 && path && isAbsolute(path)) return path;
  }
  return undefined;
}
const PYTHON = findPython();

test("runtime.classify reaches the real sidecar process (fake engine), waiting for its start", { skip: PYTHON ? false : "python3 >= 3.8 is not available" }, async (t) => {
  const sidecar = new LayaSidecar({
    python: PYTHON!, script: join(import.meta.dirname, "..", "..", "sidecars", "laya", "laya_intent_sidecar.py"),
    args: ["--fake"], log: () => {}, predictTimeoutMs: 10_000,
  });
  t.after(() => sidecar.stop());
  const runtime = await piRuntime();
  registerLayaProvider(runtime, sidecar);
  assert.equal(sidecar.state, "stopped");
  const result = await runtime.classify(layaModel(runtime), { state: { utterance: "is this a bug" }, questions: QUESTIONS });
  assert.equal(result.stopReason, "stop", result.errorMessage);
  assert.deepEqual([result.answers.kind?.type, result.answers.urgency?.type, result.answers.visible?.type], ["choice", "score", "bool"]);
  assert.equal(result.answers.kind?.type === "choice" ? result.answers.kind.choice : "", "bug");
  assert.equal(sidecar.state, "ready");

  const tooBig = await runtime.classify(layaModel(runtime), { state: { text: "y".repeat(5_000) }, questions: QUESTIONS });
  assert.deepEqual([tooBig.stopReason, tooBig.errorMessage], ["error", "Laya sidecar: state_too_long"]);
});
