import type { ContextScope } from "../../contracts/context.js";
import type { DesktopContextSnapshot, ScreenshotRef } from "../../hostClient.js";
import { classificationFromHints } from "./fusion.js";
import { classifyUtterance, surfaceFromProcess } from "./heuristics.js";
import type { ClassifierHints, ModelTier, RouteInput, SurfaceClass } from "./types.js";

/**
 * Glue for server.ts: pinned desktop context + utterance (+ optional advisory
 * hints) → RouteInput for decide(). Uses only the process name, the presence
 * of a screenshot, the browser mode and the host's context scope; never titles,
 * paths or element values.
 */

export interface RouteContext {
  surface: SurfaceClass;
  hasScreenshot: boolean;
  browserCdp: boolean;
  /** Host context scope (contracts/context.ts ContextWire.scope); absent = legacy request. */
  scope?: ContextScope;
}

/** System prompt + tool schemas + context summary, before the user's words and image. */
const BASE_PROMPT_TOKENS = 6_000;
const IMAGE_TOKENS = 1_500;

/** Route context of a pinned snapshot. A general scope has no screenshot to offer, whatever the snapshot holds. */
export function routeContextFromSnapshot(snapshot: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null }, scope?: ContextScope): RouteContext {
  const target = snapshot.targetWindow;
  return {
    surface: surfaceFromProcess(target?.processName, { finderDesktop: target?.surface === "finderDesktop" }),
    hasScreenshot: scope !== "general" && Boolean(snapshot.screenshot?.filePath),
    browserCdp: snapshot.browser?.mode === "cdp",
    ...(scope ? { scope } : {}),
  };
}

export interface BuildRouteInputOptions {
  followup?: boolean;
  lastTier?: ModelTier;
  /** Advisory classifier output; may only raise the tier / screenshot need. */
  hints?: ClassifierHints | null;
  selectionChars?: number;
  estimatedPromptTokens?: number;
  /** The agent pulled the window in (`use_active_window`, ContextRecord.pulled): a general thread routes as window. */
  pulled?: boolean;
  /** An image attachment rides along (context shelf): forces a vision-capable model. */
  hasImageAttachment?: boolean;
}

export function buildRouteInput(text: string, context: RouteContext, options: BuildRouteInputOptions = {}): RouteInput {
  const heuristic = classifyUtterance(text, { surface: context.surface, browserCdp: context.browserCdp });
  const scope: ContextScope | undefined = context.scope && options.pulled ? "window" : context.scope;
  const images = (context.hasScreenshot ? 1 : 0) + (options.hasImageAttachment ? 1 : 0);
  return {
    classification: classificationFromHints(heuristic, options.hints),
    followup: options.followup ?? false,
    surface: context.surface,
    hasScreenshot: context.hasScreenshot,
    selectionChars: Math.max(0, options.selectionChars ?? 0),
    browserCdp: context.browserCdp,
    estimatedPromptTokens: options.estimatedPromptTokens ?? BASE_PROMPT_TOKENS + Math.ceil(text.length / 4) + images * IMAGE_TOKENS,
    ...(options.lastTier ? { lastTier: options.lastTier } : {}),
    ...(scope ? { scope } : {}),
    ...(options.hasImageAttachment ? { hasImageAttachment: true } : {}),
  };
}
