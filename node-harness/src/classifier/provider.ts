import {
  type ClassifierAnswer,
  type ClassifierModel,
  type ClassifierResult,
  createProvider,
  type Provider,
} from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { type LayaAnswer, type LayaPredictRequest, type LayaPredictResult, LayaSidecarError } from "./laya.js";

/**
 * Laya as a native pi classifier provider: model `laya/multilingual`, so
 * `runtime.classify()` and codemode's `models.classify({ provider: "laya",
 * id: "multilingual" }, …)` reach the local sidecar like any catalog
 * classifier (codemode.md §7.6, routing.md §7.5). Registered with
 * `ModelRuntime.registerNativeProvider()` (pi 1.0) on each runtime that should
 * see it; keyless, and reported unconfigured once the sidecar has given up.
 *
 * The provider only answers questions. It never authorizes anything, and the
 * sidecar keeps every input out of logs.
 */

export const LAYA_PROVIDER_ID = "laya";
export const LAYA_MODEL_ID = "multilingual";
export const LAYA_CLASSIFIER_API = "laya-sidecar";

/** What the provider needs from the sidecar (LayaSidecar satisfies it). */
export interface LayaPredictBackend {
  predict(request: LayaPredictRequest, options?: { signal?: AbortSignal; timeoutMs?: number }): Promise<LayaPredictResult>;
  readonly available: boolean;
}

export function layaClassifierModel(): ClassifierModel<typeof LAYA_CLASSIFIER_API> {
  return {
    type: "classifier",
    id: LAYA_MODEL_ID,
    name: "Laya multilingual (local CPU, advisory)",
    api: LAYA_CLASSIFIER_API,
    provider: LAYA_PROVIDER_ID,
    baseUrl: "stdio://laya-sidecar",
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 1024,
  };
}

/** Softmax(log p / T): the same as dividing the logits by T (pi ClassifierOptions.temperature). */
function temper(probabilities: Record<string, number>, temperature: number): Record<string, number> {
  if (temperature === 1) return { ...probabilities };
  const logs = Object.entries(probabilities).map(([key, p]) => [key, Math.log(Math.max(p, 1e-6)) / temperature] as const);
  const max = Math.max(...logs.map(([, value]) => value));
  const weights = logs.map(([key, value]) => [key, Math.exp(value - max)] as const);
  const total = weights.reduce((sum, [, weight]) => sum + weight, 0);
  return Object.fromEntries(weights.map(([key, weight]) => [key, Math.round((weight / total) * 10_000) / 10_000]));
}

function toPiAnswer(answer: LayaAnswer, temperature: number): ClassifierAnswer {
  if (answer.type === "bool") {
    const tempered = temper({ true: answer.probability, false: 1 - answer.probability }, temperature);
    return { type: "bool", probability: tempered.true ?? answer.probability };
  }
  const probabilities = temper(answer.probabilities, temperature);
  const confidence = Math.max(0, ...Object.values(probabilities));
  if (answer.type === "choice") {
    const choice = temperature === 1
      ? answer.choice
      : Object.entries(probabilities).reduce((best, entry) => (entry[1] > best[1] ? entry : best))[0];
    return { type: "choice", choice, probabilities, confidence };
  }
  const score = temperature === 1
    ? answer.score
    : Object.entries(probabilities).reduce((sum, [level, p]) => sum + Number(level) * p, 0);
  return { type: "score", score: Math.round(score * 10_000) / 10_000, confidence };
}

export function createLayaProvider(backend: LayaPredictBackend): Provider {
  return createProvider({
    id: LAYA_PROVIDER_ID,
    name: "Laya (local)",
    auth: {
      apiKey: {
        name: "Laya sidecar (local, keyless)",
        resolve: async () => (backend.available ? { auth: {}, source: "pi-os Laya sidecar" } : undefined),
      },
    },
    models: [layaClassifierModel()],
    classifiers: {
      [LAYA_CLASSIFIER_API]: {
        async classify(model, context, options): Promise<ClassifierResult> {
          const output: ClassifierResult = {
            api: model.api, provider: model.provider, model: model.id, answers: {}, stopReason: "stop", timestamp: Date.now(),
          };
          try {
            const temperature = options?.temperature ?? 1;
            if (!(temperature > 0) || !Number.isFinite(temperature)) throw new LayaSidecarError("bad_temperature");
            const result = await backend.predict(
              { state: context.state, questions: context.questions },
              { ...(options?.signal ? { signal: options.signal } : {}), ...(options?.timeoutMs ? { timeoutMs: options.timeoutMs } : {}) },
            );
            output.answers = Object.fromEntries(Object.entries(result.answers).map(([id, answer]) => [id, toPiAnswer(answer, temperature)]));
            const input = result.usage.inputTokens;
            output.usage = {
              input, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: input,
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
            };
            return output;
          } catch (error) {
            output.answers = {};
            output.stopReason = options?.signal?.aborted ? "aborted" : "error";
            output.errorMessage = error instanceof LayaSidecarError ? error.message : "Laya sidecar: internal";
            return output;
          }
        },
      },
    },
  });
}

/** Register `laya/multilingual` on a runtime (catalog or per-invocation). Returns an unregister function. */
export function registerLayaProvider(
  runtime: Pick<ModelRuntime, "registerNativeProvider" | "unregisterProvider">,
  backend: LayaPredictBackend,
): () => void {
  runtime.registerNativeProvider(createLayaProvider(backend));
  return () => runtime.unregisterProvider(LAYA_PROVIDER_ID);
}
