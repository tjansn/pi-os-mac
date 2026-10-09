import type { ClassifierAnswer, ClassifierContext } from "@earendil-works/pi-ai";
import type { AgentIntent, ClassifierHints, Tier } from "../contracts/instant.js";

/**
 * The pi-os-intent-v1 question set and its mapping onto the advisory
 * ClassifierHints vocabulary (DESIGN.md §3.4). Shared by the Laya sidecar
 * client and by pi catalog classifiers (Jev today, Clef once pi ships it).
 *
 * Laya's zero-shot answers are 45–55% accurate on pi-os commands (laya.md §7),
 * so every hint is advisory: the router may use it to raise a tier or ask for
 * a screenshot, never to authorize or trigger an action.
 */

export const PI_OS_INTENT_QUESTION_SET = "pi-os-intent-v1";
/** Utterances above this are refused, never truncated (sidecar enforces the same cap). */
export const MAX_CLASSIFIER_TEXT_CHARS = 500;

/** Stable intent ids; the sidecar maps Laya's short labels onto these. */
export const LAYA_INTENT_LABELS = [
  "calculate", "convert", "time_date", "file_search", "app_launch",
  "web_search", "open_url", "system_toggle", "dictation", "agent_task",
] as const;
export type LayaIntentLabel = (typeof LAYA_INTENT_LABELS)[number];

/** Levels of the "how much AI reasoning" score question, lowest first. */
export const LAYA_TIER_LEVELS = ["none", "little", "moderate", "heavy"] as const;
export type LayaTierLevel = (typeof LAYA_TIER_LEVELS)[number];

export const LAYA_SURFACES = ["browser", "native_app", "none"] as const;
export type LayaSurface = (typeof LAYA_SURFACES)[number];

/**
 * Laya intent -> router intent. Lossy on purpose: fast-path labels only say
 * which kind of work the agent faces; deterministic grammars stay the only
 * source of executable slots. A system setting falling through to the agent
 * is "other" (not act_in_app) so it does not request a screenshot.
 */
export const LAYA_INTENT_TO_AGENT_INTENT: Readonly<Record<LayaIntentLabel, AgentIntent>> = {
  calculate: "calculate",
  convert: "calculate",
  time_date: "answer",
  file_search: "search_computer",
  app_launch: "open_launch",
  web_search: "browse_web",
  open_url: "open_launch",
  system_toggle: "other",
  dictation: "write",
  agent_task: "other",
};

/** Score level -> router tier (routing.md §6.5: answer/write → quick, multi-step → standard, research/code → deep). */
export const LAYA_TIER_TO_TIER: Readonly<Record<LayaTierLevel, Tier>> = {
  none: "instant",
  little: "quick",
  moderate: "standard",
  heavy: "deep",
};

const TIER_CRITERIA = [
  "none: a direct command or lookup a simple program does instantly",
  "little: one short answer, explanation, translation or summary",
  "moderate: several steps or actions in apps or on websites",
  "heavy: coding, research, deep analysis or long planning",
];

/**
 * pi-os-intent-v1 in pi's ClassifierContext form for catalog classifiers
 * (TypeSafe Jev, Workers AI). Keys are the stable ids so answers map without
 * a lookup table; descriptions help the larger cloud models. The Laya sidecar
 * keeps its own short-label variant (measured best zero-shot).
 */
export const PI_OS_INTENT_QUESTIONS: ClassifierContext["questions"] = {
  intent: {
    type: "choice",
    instructions: "What does the user want done with `utterance`?",
    criteria: {
      calculate: "do arithmetic or percentages",
      convert: "convert units or currency",
      time_date: "tell the time or a date, or do date math",
      file_search: "find a file or folder on this computer",
      app_launch: "open or switch to an app",
      web_search: "search the web",
      open_url: "open a website",
      system_toggle: "change a system setting such as volume, Wi-Fi or dark mode",
      dictation: "type out dictated text",
      agent_task: "any other question or task for the AI assistant",
    },
  },
  tier: { type: "score", instructions: "How much AI reasoning does `utterance` need?", criteria: TIER_CRITERIA },
  screen: {
    type: "bool",
    instructions: "Does `utterance` refer to something currently shown on screen?",
    criteria: {
      true: "refers to visible content such as this page, this email, selected text or a visible error",
      false: "self-contained; nothing on screen is needed",
    },
  },
  surface: {
    type: "choice",
    instructions: "Which user interface must the assistant read or operate for `utterance`?",
    criteria: {
      browser: "a web page or website in a browser",
      native_app: "a desktop application window",
      none: "no interface: answer, compute or change a setting directly",
    },
  },
};

/** Sidecar `classify` result (laya.md §8.5, with stable labels). */
export interface LayaIntentResult {
  advisory: true;
  questions: string;
  intent: { label: LayaIntentLabel; p: number; probs: Partial<Record<LayaIntentLabel, number>> };
  tier: { label: LayaTierLevel; p: number; expected: number; probs: Partial<Record<LayaTierLevel, number>> };
  screen: { p: number };
  surface: { label: LayaSurface; p: number; probs: Partial<Record<LayaSurface, number>> };
  usage: { input_tokens: number; state_tokens: number };
}

/** Trim and collapse whitespace; null when empty or over the cap (refuse, never truncate). */
export function normalizeUtterance(text: string): string | null {
  if (typeof text !== "string") return null;
  const normalized = text.split(/\s+/u).filter(Boolean).join(" ");
  return normalized && normalized.length <= MAX_CLASSIFIER_TEXT_CHARS ? normalized : null;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const isProbability = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;

function probabilities<T extends string>(value: unknown, labels: readonly T[]): Partial<Record<T, number>> | null {
  if (!isRecord(value)) return null;
  const out: Partial<Record<T, number>> = {};
  for (const [key, p] of Object.entries(value)) {
    if (!(labels as readonly string[]).includes(key) || !isProbability(p)) return null;
    out[key as T] = p;
  }
  return out;
}

function labeled<T extends string>(value: unknown, labels: readonly T[]): { label: T; p: number; probs: Partial<Record<T, number>> } | null {
  if (!isRecord(value) || !(labels as readonly unknown[]).includes(value.label) || !isProbability(value.p)) return null;
  const probs = probabilities(value.probs, labels);
  return probs ? { label: value.label as T, p: value.p, probs } : null;
}

/** Strict decoder for the sidecar's classify result; anything unexpected is dropped (null). */
export function parseLayaIntentResult(value: unknown): LayaIntentResult | null {
  if (!isRecord(value) || value.advisory !== true) return null;
  const intent = labeled(value.intent, LAYA_INTENT_LABELS);
  const tier = labeled(value.tier, LAYA_TIER_LEVELS);
  const surface = labeled(value.surface, LAYA_SURFACES);
  const screen = isRecord(value.screen) && isProbability(value.screen.p) ? { p: value.screen.p } : null;
  const expected = isRecord(value.tier) ? value.tier.expected : undefined;
  if (!intent || !tier || !surface || !screen || typeof expected !== "number" || !Number.isFinite(expected)) return null;
  const usage = isRecord(value.usage) ? value.usage : {};
  return {
    advisory: true,
    questions: typeof value.questions === "string" ? value.questions : PI_OS_INTENT_QUESTION_SET,
    intent,
    tier: { ...tier, expected },
    screen,
    surface,
    usage: {
      input_tokens: typeof usage.input_tokens === "number" ? usage.input_tokens : 0,
      state_tokens: typeof usage.state_tokens === "number" ? usage.state_tokens : 0,
    },
  };
}

const roundP = (p: number): number => Math.round(p * 10_000) / 10_000;
const roundMs = (ms: number): number => Math.max(0, Math.round(ms * 10) / 10);

/** Sidecar result -> advisory hints. Probabilities are uncalibrated until a fine-tune passes laya.md §10. */
export function layaResultToHints(result: LayaIntentResult, latencyMs: number): ClassifierHints {
  return {
    source: "laya",
    latencyMs: roundMs(latencyMs),
    intent: LAYA_INTENT_TO_AGENT_INTENT[result.intent.label],
    intentP: roundP(result.intent.p),
    tier: LAYA_TIER_TO_TIER[result.tier.label],
    tierP: roundP(result.tier.p),
    needsScreen: roundP(result.screen.p),
  };
}

/**
 * pi ClassifierResult answers for PI_OS_INTENT_QUESTIONS -> advisory hints.
 * Score answers carry no per-level probabilities in pi's contract, so tierP
 * stays unset (consumers then treat the tier as low-confidence). Null when no
 * question produced a usable answer.
 */
export function piAnswersToHints(answers: Record<string, ClassifierAnswer>, latencyMs: number): ClassifierHints | null {
  const hints: ClassifierHints = { source: "pi-classifier", latencyMs: roundMs(latencyMs) };
  let useful = false;
  const intent = answers.intent;
  if (intent?.type === "choice" && (LAYA_INTENT_LABELS as readonly string[]).includes(intent.choice)) {
    hints.intent = LAYA_INTENT_TO_AGENT_INTENT[intent.choice as LayaIntentLabel];
    const p = intent.probabilities[intent.choice];
    if (isProbability(p)) hints.intentP = roundP(p);
    useful = true;
  }
  const tier = answers.tier;
  if (tier?.type === "score" && Number.isFinite(tier.score)) {
    const level = Math.min(LAYA_TIER_LEVELS.length - 1, Math.max(0, Math.round(tier.score)));
    hints.tier = LAYA_TIER_TO_TIER[LAYA_TIER_LEVELS[level]!];
    useful = true;
  }
  const screen = answers.screen;
  if (screen?.type === "bool" && isProbability(screen.probability)) {
    hints.needsScreen = roundP(screen.probability);
    useful = true;
  }
  return useful ? hints : null;
}
