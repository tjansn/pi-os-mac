import { getSupportedThinkingLevels, type Api, type Model, type ModelThinkingLevel } from "@earendil-works/pi-ai";
import { modelKey, type CandidateInfo, type ModelTier, type Profile, type RoutingCatalog } from "./types.js";

/**
 * Latency/quality priors per model@level (routing.md §6.5) and generic family
 * estimates for everything else, so Auto works for any configured provider.
 *
 * Priors are Artificial Analysis public-API medians fetched 2026-10-02 (ttft s,
 * output tok/s, intelligence index), except on the ChatGPT/Codex backend, which
 * differs: there the priors are the medians measured on 2026-10-05 (r2/latency.md
 * §0, §3.3; new WebSocket per call, as pi-os runs): gpt-6-luna@off 1.70 s at
 * ≈ 60 tok/s, gpt-6-sol@off 5.05 s at 33–41, gpt-6.1-sol@low 2.55 s. Unmeasured
 * Codex models in a tier that holds a measured one carry the Luna-measured
 * backend penalty (+1.0 s, half the throughput) so a public-API median never
 * outranks a backend measurement. LatencyStats re-ranks with local measurements
 * (decide.ts expectedTtft: at once when far worse than the prior).
 *
 * Codex facts (pi-ai 1.0 openai-codex catalog, CRITIC.md C13/F13):
 * - gpt-6-luna / gpt-6-sol map `off` to "none". Measured, Sol@off is ~3× slower than
 *   Luna per turn and slower than the smarter gpt-6.1-sol@low (server-side queueing,
 *   0 reasoning tokens): the fast tier is gpt-6.1-sol@low, and gpt-6-sol@off is
 *   pin-only (a tier override may still choose it).
 * - gpt-6.1-sol / gpt-6-astra have NO `off`; `minimal` maps to "low" on every
 *   Codex model, so minimal is never a cheaper lane than low.
 * - gpt-5.3-codex-spark is text-only, Pro-only and reportedly retiring: never
 *   auto-selected (it can still be pinned through a tier override).
 */

type Prior = Omit<Profile, "source">;

const prior = (tier: ModelTier, provider: string, id: string, thinkingLevel: ModelThinkingLevel,
  ttftS: number, tps: number, ii: number, pinOnly = false): Prior =>
  ({ tier, provider, id, thinkingLevel, ttftS, tps, ii, ...(pinOnly ? { pinOnly } : {}) });

export const PRIOR_PROFILES: readonly Profile[] = [
  prior("quick", "anthropic", "claude-haiku-4-5", "off", 0.58, 95, 15),
  prior("quick", "openai-codex", "gpt-6-luna", "off", 1.7, 60, 18), // measured
  prior("quick", "openai", "gpt-6-luna", "off", 0.67, 130, 18),
  prior("quick", "openai-codex", "gpt-5.6-luna", "off", 1.8, 54, 16), // AA 0.78 s / 107 + backend penalty
  prior("quick", "openai", "gpt-5.6-luna", "off", 0.78, 107, 16),
  prior("fast", "anthropic", "claude-sonnet-5-5", "low", 1.31, 91, 36),
  prior("fast", "openai-codex", "gpt-6.1-sol", "low", 2.6, 57, 42), // measured
  prior("fast", "openai-codex", "gpt-6-sol", "off", 5.0, 40, 29, true), // measured; pin-only
  prior("fast", "openai", "gpt-6-sol", "off", 1.01, 79, 29),
  prior("fast", "openai-codex", "gpt-5.6-terra", "low", 2.8, 40, 27), // AA 1.77 s / 80 + backend penalty
  prior("standard", "anthropic", "claude-sonnet-5-5", "medium", 1.23, 99, 41),
  prior("standard", "openai-codex", "gpt-6.1-sol", "low", 2.6, 57, 42), // measured; the ladder skips the duplicate rung
  prior("standard", "openai", "gpt-6.1-sol", "low", 2.9, 57, 42),
  prior("deep", "openai-codex", "gpt-6.1-sol", "medium", 5.5, 54, 48),
  prior("deep", "openai", "gpt-6.1-sol", "medium", 5.5, 54, 48),
  prior("deep", "openai-codex", "gpt-6-astra", "medium", 6.07, 45, 50),
  prior("deep", "openai", "gpt-6-astra", "medium", 6.07, 45, 50),
  prior("deep", "anthropic", "claude-opus-5-5", "medium", 22.2, 72, 51),
  prior("max", "anthropic", "claude-opus-5-5", "high", 37.4, 74, 54),
  prior("max", "openai-codex", "gpt-6.1-sol", "high", 57.6, 58, 50),
  prior("max", "openai", "gpt-6.1-sol", "high", 57.6, 58, 50),
  prior("max", "openai-codex", "gpt-6-astra", "high", 58.4, 45, 51),
  prior("max", "openai", "gpt-6-astra", "high", 58.4, 45, 51),
].map(p => ({ ...p, source: "prior" as const }));

/** Never auto-selected (tier overrides may still pin them). */
const EXCLUDED_MODELS = new Set(["openai-codex/gpt-5.3-codex-spark", "openai/gpt-5.3-codex-spark"]);
/** Not general chat agents: realtime/audio/image/search/computer-use/deep-research variants, moving aliases. */
const SPECIALIZED = /realtime|audio|tts|transcribe|whisper|embed|moderation|image|search-preview|computer-use|deep-research|-live|chat-latest|customtools|guard/i;

/** pi's virtual-model API id (virtual-models.js VIRTUAL_MODEL_API; not exported from the package index). */
const VIRTUAL_API = "pi-virtual";

const LOOPBACK_HOST = /^(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[?::1\]?|[^.]+\.local)$/i;
const LOCAL_PROVIDER = /^(?:ollama|lm-?studio|llama[-.]?cpp|llamacpp|mlx(?:-.*)?|local(?:-.*)?)$/i;

/** Loopback inference servers share the local GPU (AGENTS.md DRACO lock): opt-in only. */
export function isLocalModel(model: Pick<Model<Api>, "provider" | "baseUrl">): boolean {
  if (LOCAL_PROVIDER.test(model.provider)) return true;
  try {
    return LOOPBACK_HOST.test(new URL(model.baseUrl).hostname);
  } catch {
    return false;
  }
}

/**
 * Supported levels with duplicates collapsed: when `minimal` maps to the same
 * provider effort as `low` (every Codex model), only `low` remains.
 */
export function distinctThinkingLevels(model: Model<Api>): ModelThinkingLevel[] {
  const levels = getSupportedThinkingLevels(model);
  const mapped = (level: ModelThinkingLevel) => model.thinkingLevelMap?.[level] ?? level;
  return levels.filter(level => !(level === "minimal" && levels.includes("low") && mapped("minimal") === mapped("low")));
}

type SizeClass = "small" | "medium" | "large";

// Name tokens, bounded by separators ("gemini" must not read as "mini").
const SMALL_NAME = /(?:^|[-_ ./:])(?:nano|mini|lite|flash-lite|haiku|luna|small|tiny|instant|spark|e[24]b|[a-z]?[1-9]b)(?=$|[-_ ./:])/i;
const LARGE_NAME = /(?:^|[-_ ./:])(?:opus|astra|fable|ultra|large|pro|max|405b|671b|235b|thinking|o1|o3)(?=$|[-_ ./:])/i;

/** Rough size class from the name, then the output price. */
export function sizeClass(model: Model<Api>): SizeClass {
  const name = `${model.id} ${model.name}`;
  if (SMALL_NAME.test(name)) return "small";
  if (LARGE_NAME.test(name)) return "large";
  const out = model.cost?.output ?? 0;
  if (out > 0 && out <= 2) return "small";
  if (out >= 25) return "large";
  return "medium";
}

interface Template {
  tier: ModelTier;
  /** First supported level wins. */
  levels: readonly ModelThinkingLevel[];
}

const TEMPLATES: Record<SizeClass, readonly Template[]> = {
  small: [
    { tier: "quick", levels: ["off", "minimal", "low"] },
    { tier: "fast", levels: ["low", "medium"] },
  ],
  medium: [
    { tier: "fast", levels: ["off", "minimal", "low"] },
    { tier: "standard", levels: ["low", "medium", "off"] },
    { tier: "deep", levels: ["medium", "high"] },
  ],
  large: [
    { tier: "standard", levels: ["off", "minimal", "low"] },
    { tier: "deep", levels: ["medium", "high", "off"] },
    { tier: "max", levels: ["high", "medium"] },
  ],
};

const LEVEL_TTFT: Partial<Record<ModelThinkingLevel, number>> = { off: 1, minimal: 1.8, low: 2.8, medium: 6, high: 30 };
const CLASS_FACTOR: Record<SizeClass, { ttft: number; tps: number; ii: number }> = {
  small: { ttft: 0.9, tps: 110, ii: 14 },
  medium: { ttft: 1.3, tps: 70, ii: 26 },
  large: { ttft: 1.8, tps: 45, ii: 34 },
};
const LEVEL_II: Partial<Record<ModelThinkingLevel, number>> = { off: 0, minimal: 3, low: 6, medium: 10, high: 12 };

/** Conservative generic estimates; curated priors win within a tier (decide.ts). */
export function genericProfiles(model: Model<Api>): Profile[] {
  const size = sizeClass(model);
  const levels = distinctThinkingLevels(model);
  const profiles: Profile[] = [];
  for (const template of TEMPLATES[size]) {
    const level = template.levels.find(l => levels.includes(l));
    if (!level) continue;
    const factor = CLASS_FACTOR[size];
    profiles.push({
      tier: template.tier, provider: model.provider, id: model.id, thinkingLevel: level, source: "generic",
      ttftS: (LEVEL_TTFT[level] ?? 30) * factor.ttft, tps: factor.tps, ii: factor.ii + (LEVEL_II[level] ?? 12),
    });
  }
  return profiles;
}

export function candidateInfo(model: Model<Api>): CandidateInfo {
  return {
    provider: model.provider,
    id: model.id,
    vision: model.input.includes("image"),
    contextWindow: model.contextWindow,
    local: isLocalModel(model),
    reasoning: Boolean(model.reasoning),
    levels: getSupportedThinkingLevels(model),
  };
}

/**
 * Router catalog from AVAILABLE (auth-checked) models: `runtime.getAvailable()`
 * or `getAvailableSnapshot()`. Virtual models (pi-os/auto itself) are dropped.
 * Known models get the curated priors (only at levels the model supports);
 * unknown general chat models get generic family estimates. A pin-only prior
 * stays in the catalog (latency estimates for overrides) and also keeps generic
 * estimates from re-adding its model.
 */
export function buildRoutingCatalog(models: readonly Model<Api>[], priors: readonly Profile[] = PRIOR_PROFILES): RoutingCatalog {
  const candidates = new Map<string, CandidateInfo>();
  const physical: Model<Api>[] = [];
  for (const model of models) {
    if (model.api === VIRTUAL_API || (model.type !== undefined && model.type !== "chat")) continue;
    const key = modelKey(model.provider, model.id);
    if (candidates.has(key)) continue;
    candidates.set(key, candidateInfo(model));
    physical.push(model);
  }
  const profiles: Profile[] = [];
  const curated = new Set<string>();
  for (const p of priors) {
    const info = candidates.get(modelKey(p.provider, p.id));
    if (!info || !info.levels.includes(p.thinkingLevel)) continue;
    profiles.push(p);
    curated.add(modelKey(p.provider, p.id));
  }
  for (const model of physical) {
    const key = modelKey(model.provider, model.id);
    if (curated.has(key) || EXCLUDED_MODELS.has(key) || SPECIALIZED.test(model.id)) continue;
    profiles.push(...genericProfiles(model));
  }
  return { candidates, profiles };
}
