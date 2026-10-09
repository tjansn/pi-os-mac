import { getSupportedThinkingLevels, type Model } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { loadAgentResources, registerResourceProviders } from "./resources.js";
import {
  AUTO_MODEL_ID, AUTO_MODEL_NAME, AUTO_PROVIDER, AUTO_THINKING_LEVELS, registerAutoModel, type AutoModelDeps,
} from "./routing/index.js";
import { registerLayaProvider, type LayaPredictBackend } from "../classifier/provider.js";

/**
 * The pi model catalog as seen by the host settings page.
 *
 * Each catalog request creates a fresh ModelRuntime. This reloads the user's
 * models.json and authentication changes without requiring a pi-os restart.
 * Invocation runs also create their own fresh runtime.
 *
 * Every catalog runtime registers the Auto virtual model `pi-os/auto`, so
 * GET /models lists it (first) and POST /settings/model accepts it unchanged.
 */

/** Wire shape for GET /models entries (protocol.md). */
export interface ModelSummary {
  provider: string;
  id: string;
  name: string;
  /** Whether the provider/model supports reasoning (thinking) at all. */
  reasoning: boolean;
  /** pi thinking levels this model accepts, ascending ("off" ... "max"). */
  thinkingLevels: string[];
}

/** GET /models entry for Auto; its levels are the routing bias (speed / balanced / quality). */
export const AUTO_MODEL_SUMMARY: Readonly<ModelSummary> = Object.freeze({
  provider: AUTO_PROVIDER, id: AUTO_MODEL_ID, name: AUTO_MODEL_NAME, reasoning: true, thinkingLevels: [...AUTO_THINKING_LEVELS],
});

export function getModelRuntime(): Promise<ModelRuntime> { return ModelRuntime.create(); }

export interface ModelCatalogOptions {
  /** Router hooks for the catalog's Auto registration (none needed for listing). */
  auto?: AutoModelDeps;
  /** Optional local classifier backend registered as the `laya` classifier provider. */
  laya?: LayaPredictBackend;
}

export async function createModelCatalogContext(trustedResources = false, options: ModelCatalogOptions = {}): Promise<{ runtime: ModelRuntime; dispose: () => void }> {
  const runtime = await getModelRuntime();
  const auto = registerAutoModel(runtime, options.auto);
  const unregisterLaya = options.laya ? registerLayaProvider(runtime, options.laya) : undefined;
  let disposeProviders = () => {};
  if (trustedResources) {
    const loader = await loadAgentResources([{ name: "pi-os-catalog", factory() {} }]);
    disposeProviders = await registerResourceProviders(loader, runtime);
  }
  return {
    runtime,
    dispose: () => {
      disposeProviders();
      unregisterLaya?.();
      auto.unregister();
    },
  };
}

const isAuto = (model: { provider: string; id: string }) => model.provider === AUTO_PROVIDER && model.id === AUTO_MODEL_ID;

/**
 * Models with configured authentication. Auto comes first whenever at least
 * one physical model is usable (it routes only to those); the rest is sorted
 * provider asc, then id — deterministic UI ordering. With no usable model the
 * list stays empty, so hosts keep their "configure authentication" hint.
 */
export async function listAvailableModels(runtime?: ModelRuntime): Promise<ModelSummary[]> {
  runtime ??= await getModelRuntime();
  return orderCatalog((await runtime.getAvailable()).map(summarizeModel));
}

export function orderCatalog(models: readonly ModelSummary[]): ModelSummary[] {
  const physical = models.filter(model => !isAuto(model))
    .sort((a, b) => a.provider.localeCompare(b.provider) || a.id.localeCompare(b.id));
  if (!physical.length) return [];
  const auto = models.find(isAuto) ?? { ...AUTO_MODEL_SUMMARY, thinkingLevels: [...AUTO_MODEL_SUMMARY.thinkingLevels] };
  return [auto, ...physical];
}

export function summarizeModel(model: Model<any>): ModelSummary {
  return {
    provider: model.provider,
    id: model.id,
    name: model.name,
    reasoning: Boolean(model.reasoning),
    thinkingLevels: [...getSupportedThinkingLevels(model)],
  };
}

export interface ResolvedSelection {
  model?: Model<any>;
  /** Set when the stored selection could not be resolved and pi will fall back. */
  fallbackReason?: string;
}

/**
 * Resolve a stored settings selection against a live runtime. Missing
 * catalogs or lost auth degrade to the session default instead of failing
 * the invocation (runAgent logs whatever happens).
 */
export function resolveModel(
  runtime: ModelRuntime,
  selection: { provider: string; modelId: string } | null | undefined,
): ResolvedSelection {
  if (!selection?.provider || !selection.modelId) {
    return {};
  }
  const model = runtime.getModel(selection.provider, selection.modelId);
  if (!model) {
    return {
      fallbackReason:
        `configured model ${selection.provider}/${selection.modelId} is not registered`,
    };
  }
  return { model };
}
