import { join } from "node:path";
import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import { supportDirectory } from "../../platformPaths.js";
import { SettingsFile } from "../../settingsFile.js";
import {
  isModelTier, MODEL_TIERS, modelKey, ROUTING_BIASES,
  type CandidateInfo, type ModelTier, type RoutingBias, type RoutingSettings, type TierChoice,
} from "./types.js";

/**
 * Auto-router knobs under the `routing` key of <supportDir>/settings.json
 * (GET/POST /settings/routing). Shares the file with the model selection
 * (`model` key) through key-scoped atomic read-modify-write.
 *
 * Wire/file shape: { bias, maxAutoTier, tierOverrides?, allowLocalModels }
 * with tierOverrides = { [tier]: { provider, id, thinkingLevel } }.
 */

export const ROUTING_SETTINGS_KEY = "routing";

export const DEFAULT_ROUTING_SETTINGS: Readonly<RoutingSettings> = Object.freeze({
  bias: "balanced",
  maxAutoTier: "deep",
  allowLocalModels: false,
});

const THINKING_LEVELS: readonly ModelThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isBias(value: unknown): value is RoutingBias {
  return typeof value === "string" && (ROUTING_BIASES as readonly string[]).includes(value);
}

function parseChoice(value: unknown): TierChoice | undefined {
  if (!isRecord(value)) return undefined;
  const provider = value.provider;
  const id = value.id ?? value.modelId; // accept the /settings/model spelling too
  const level = value.thinkingLevel;
  if (typeof provider !== "string" || !IDENTIFIER.test(provider)) return undefined;
  if (typeof id !== "string" || !IDENTIFIER.test(id)) return undefined;
  if (typeof level !== "string" || !(THINKING_LEVELS as readonly string[]).includes(level)) return undefined;
  return { provider, id, thinkingLevel: level as ModelThinkingLevel };
}

/** Tolerant parse of a stored value: every field falls back to its default on its own. */
export function parseRoutingSettings(value: unknown): RoutingSettings {
  const stored = isRecord(value) ? value : {};
  const settings: RoutingSettings = {
    bias: isBias(stored.bias) ? stored.bias : DEFAULT_ROUTING_SETTINGS.bias,
    maxAutoTier: isModelTier(stored.maxAutoTier) ? stored.maxAutoTier : DEFAULT_ROUTING_SETTINGS.maxAutoTier,
    allowLocalModels: typeof stored.allowLocalModels === "boolean" ? stored.allowLocalModels : DEFAULT_ROUTING_SETTINGS.allowLocalModels,
  };
  if (isRecord(stored.tierOverrides)) {
    const overrides: Partial<Record<ModelTier, TierChoice>> = {};
    for (const tier of MODEL_TIERS) {
      const choice = parseChoice(stored.tierOverrides[tier]);
      if (choice) overrides[tier] = choice;
    }
    if (Object.keys(overrides).length) settings.tierOverrides = overrides;
  }
  return settings;
}

export type RoutingSettingsPatch = Partial<Omit<RoutingSettings, "tierOverrides">> & {
  /** null clears all overrides; a tier mapped to null clears that tier. */
  tierOverrides?: Partial<Record<ModelTier, TierChoice | null>> | null;
};

export type PatchResult = { ok: true; patch: RoutingSettingsPatch } | { ok: false; error: string };

/**
 * Strict validation of a POST /settings/routing body. Unknown keys and bad
 * values are rejected (the caller answers 400 with `error`). Availability of
 * override models is checked separately (validateTierOverrides) because it
 * needs a runtime.
 */
export function validateRoutingPatch(body: unknown): PatchResult {
  if (!isRecord(body)) return { ok: false, error: "Expected a JSON object" };
  const allowed = new Set(["bias", "maxAutoTier", "tierOverrides", "allowLocalModels"]);
  const unknown = Object.keys(body).filter(key => !allowed.has(key));
  if (unknown.length) return { ok: false, error: `Unknown routing setting: ${unknown[0]}` };
  const patch: RoutingSettingsPatch = {};
  if (body.bias !== undefined) {
    if (!isBias(body.bias)) return { ok: false, error: "bias must be speed, balanced or quality" };
    patch.bias = body.bias;
  }
  if (body.maxAutoTier !== undefined) {
    if (!isModelTier(body.maxAutoTier)) return { ok: false, error: `maxAutoTier must be one of ${MODEL_TIERS.join(", ")}` };
    patch.maxAutoTier = body.maxAutoTier;
  }
  if (body.allowLocalModels !== undefined) {
    if (typeof body.allowLocalModels !== "boolean") return { ok: false, error: "allowLocalModels must be a boolean" };
    patch.allowLocalModels = body.allowLocalModels;
  }
  if (body.tierOverrides !== undefined) {
    if (body.tierOverrides === null) {
      patch.tierOverrides = null;
    } else if (!isRecord(body.tierOverrides)) {
      return { ok: false, error: "tierOverrides must be an object or null" };
    } else {
      const overrides: Partial<Record<ModelTier, TierChoice | null>> = {};
      for (const [tier, value] of Object.entries(body.tierOverrides)) {
        if (!isModelTier(tier)) return { ok: false, error: `Unknown tier in tierOverrides: ${tier}` };
        if (value === null) { overrides[tier] = null; continue; }
        const choice = parseChoice(value);
        if (!choice) return { ok: false, error: `tierOverrides.${tier} needs provider, id and thinkingLevel` };
        overrides[tier] = choice;
      }
      patch.tierOverrides = overrides;
    }
  }
  return { ok: true, patch };
}

/**
 * Save-time check of overrides against the AVAILABLE catalog (buildRoutingCatalog
 * over runtime.getAvailable()): the model must be authenticated and support the
 * level. Returns the first problem, or undefined. Local models are allowed here;
 * allowLocalModels still gates them at route time.
 */
export function validateTierOverrides(
  overrides: Partial<Record<ModelTier, TierChoice | null>> | null | undefined,
  candidates: ReadonlyMap<string, CandidateInfo>,
): string | undefined {
  for (const [tier, choice] of Object.entries(overrides ?? {})) {
    if (!choice) continue;
    const info = candidates.get(modelKey(choice.provider, choice.id));
    if (!info) return `tierOverrides.${tier}: ${choice.provider}/${choice.id} is not available (no credentials or unknown model)`;
    if (!info.levels.includes(choice.thinkingLevel)) {
      return `tierOverrides.${tier}: ${choice.provider}/${choice.id} does not support thinking level ${choice.thinkingLevel}`;
    }
  }
  return undefined;
}

export function applyRoutingPatch(current: RoutingSettings, patch: RoutingSettingsPatch): RoutingSettings {
  const next: RoutingSettings = {
    bias: patch.bias ?? current.bias,
    maxAutoTier: patch.maxAutoTier ?? current.maxAutoTier,
    allowLocalModels: patch.allowLocalModels ?? current.allowLocalModels,
  };
  const overrides: Partial<Record<ModelTier, TierChoice>> = patch.tierOverrides === null ? {} : { ...current.tierOverrides };
  for (const [tier, choice] of Object.entries(patch.tierOverrides ?? {}) as [ModelTier, TierChoice | null][]) {
    if (choice) overrides[tier] = choice;
    else delete overrides[tier];
  }
  if (Object.keys(overrides).length) next.tierOverrides = overrides;
  return next;
}

export class RoutingSettingsStore {
  private readonly file: SettingsFile;
  private memory?: RoutingSettings;

  constructor(
    file: SettingsFile | string = join(supportDirectory(), "settings.json"),
    private readonly log: (line: string) => void = (line) => console.log(line),
  ) {
    this.file = typeof file === "string" ? new SettingsFile(file, log) : file;
  }

  /** Current settings (re-read each call so other writers' changes apply to the next task). */
  get(): RoutingSettings {
    return this.memory ?? parseRoutingSettings(this.file.get(ROUTING_SETTINGS_KEY));
  }

  /**
   * Merge a validated patch and persist it under `routing`, preserving every
   * other key. On a write failure the value is kept in memory for this process
   * (and logged), matching the model settings' fallback.
   */
  set(patch: RoutingSettingsPatch): RoutingSettings {
    const next = applyRoutingPatch(this.get(), patch);
    try {
      this.file.update(ROUTING_SETTINGS_KEY, next);
      this.memory = undefined;
    } catch (error) {
      this.memory = next;
      this.log(`[settings] failed saving routing settings: ${error instanceof Error ? error.message : String(error)}`);
    }
    this.log(`[settings] routing bias=${next.bias} maxAutoTier=${next.maxAutoTier} local=${next.allowLocalModels}` +
      ` overrides=${Object.keys(next.tierOverrides ?? {}).join("+") || "none"}`);
    return next;
  }
}
