import type { DesktopContextSnapshot, ScreenshotRef } from "../../hostClient.js";
import { classificationFromHints } from "./fusion.js";
import { classifyUtterance, surfaceFromProcess } from "./heuristics.js";
import type { ClassifierHints, ModelTier, RouteInput, SurfaceClass } from "./types.js";

/**
 * Glue for server.ts: pinned desktop context + utterance (+ optional advisory
 * hints) → RouteInput for decide(). Uses only the process name, the presence
 * of a screenshot and the browser mode; never titles, paths or element values.
 */

export interface RouteContext {
  surface: SurfaceClass;
  hasScreenshot: boolean;
  browserCdp: boolean;
}

/** System prompt + tool schemas + context summary, before the user's words and image. */
const BASE_PROMPT_TOKENS = 6_000;
const IMAGE_TOKENS = 1_500;

export function routeContextFromSnapshot(snapshot: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null }): RouteContext {
  const target = snapshot.targetWindow;
  return {
    surface: surfaceFromProcess(target?.processName, { finderDesktop: target?.surface === "finderDesktop" }),
    hasScreenshot: Boolean(snapshot.screenshot?.filePath),
    browserCdp: snapshot.browser?.mode === "cdp",
  };
}

export interface BuildRouteInputOptions {
  followup?: boolean;
  lastTier?: ModelTier;
  /** Advisory classifier output; may only raise the tier / screenshot need. */
  hints?: ClassifierHints | null;
  selectionChars?: number;
  estimatedPromptTokens?: number;
}

export function buildRouteInput(text: string, context: RouteContext, options: BuildRouteInputOptions = {}): RouteInput {
  const heuristic = classifyUtterance(text, { surface: context.surface, browserCdp: context.browserCdp });
  return {
    classification: classificationFromHints(heuristic, options.hints),
    followup: options.followup ?? false,
    surface: context.surface,
    hasScreenshot: context.hasScreenshot,
    selectionChars: Math.max(0, options.selectionChars ?? 0),
    browserCdp: context.browserCdp,
    estimatedPromptTokens: options.estimatedPromptTokens
      ?? BASE_PROMPT_TOKENS + Math.ceil(text.length / 4) + (context.hasScreenshot ? IMAGE_TOKENS : 0),
    ...(options.lastTier ? { lastTier: options.lastTier } : {}),
  };
}
