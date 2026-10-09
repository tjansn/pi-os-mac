import {
  isContextOverflow, type Api, type Message, type Model, type ToolResultMessage,
} from "@earendil-works/pi-ai";
import type { ModelRoute, ModelRouteReason, ModelRouteRequest, ModelRuntime } from "@earendil-works/pi-coding-agent";
import { decide, quickestTarget } from "./decide.js";
import { ESCALATE_TOOL_NAME } from "./escalate.js";
import { classifyUtterance, extractRequestText } from "./heuristics.js";
import { classifyProviderError, HEALTH_PENALTY_MS, type HealthReason } from "./latencyStats.js";
import { buildRoutingCatalog, isLocalModel } from "./profiles.js";
import { DEFAULT_ROUTING_SETTINGS } from "./settings.js";
import {
  isModelTier, sameTarget, targetKey, tierRank,
  type LatencyView, type ModelTier, type Profile, type RouteDecision, type RouteTarget, type RoutingBias,
  type RoutingCatalog, type RoutingSettings, type TierChoice,
} from "./types.js";

/**
 * `pi-os/auto`: a pi 1.0 virtual model (ModelRuntime.registerVirtualModel)
 * that picks the physical model + thinking level for every request.
 *
 * - `user`: consumes the decision server.ts computed BEFORE prompt() (decide()
 *   over heuristics, < 1 ms) from this registration's decision slot. Without
 *   one (steer/follow-up messages, a caller that skipped it) it runs the same
 *   pure heuristics over the request text. It never calls a classifier.
 * - `continuation`: sticky (keeps prompt caches/thinking signatures) unless
 *   an escalation trigger fires: a pi_os_escalate result, or on quick/fast ≥ 2
 *   tool errors or > 8 tool results in the turn. At most 2 escalations per turn.
 * - `retry`: rate limit/overload → same-tier sibling (other provider first),
 *   else the next rung; context overflow → a larger window; other errors →
 *   same model once, then a sibling.
 * - `direct` (compaction summaries): cheapest quick model with enough context.
 *
 * Auth guarantee: every target is re-checked with getPhysicalModel() and
 * hasConfiguredAuth() before it is returned (pi refuses others anyway), and
 * candidates come only from available (auth-checked) models.
 *
 * Decision slot: one registration per ModelRuntime, and agentRunner creates
 * one runtime per session, so the returned handle IS the session's slot.
 * Do not prompt two sessions concurrently through one runtime.
 */

export const AUTO_PROVIDER = "pi-os";
export const AUTO_MODEL_ID = "auto";
export const AUTO_MODEL_NAME = "Auto";
/** Virtual thinking levels = routing bias (speed / balanced / quality). */
export const AUTO_THINKING_LEVELS = ["low", "medium", "high"] as const;
export type AutoThinkingLevel = (typeof AUTO_THINKING_LEVELS)[number];

export const MAX_ESCALATIONS_PER_TURN = 2;
const ESCALATE_ON_ERRORS = 2;
const ESCALATE_AFTER_RESULTS = 8;
const DECISION_TTL_MS = 120_000;
const NO_MODEL = "no_authenticated_model: Auto found no usable model with credentials. Choose a model in pi-os Settings or sign in to a provider.";

export function biasForThinkingLevel(level: string | undefined): RoutingBias {
  if (level === "low" || level === "off" || level === "minimal") return "speed";
  if (level === "high" || level === "xhigh" || level === "max") return "quality";
  return "balanced";
}

export function thinkingLevelForBias(bias: RoutingBias): AutoThinkingLevel {
  return bias === "speed" ? "low" : bias === "quality" ? "high" : "medium";
}

/** Whether a stored model selection names the Auto virtual model. */
export function isAutoSelection(selection: { provider?: string; modelId?: string; id?: string } | null | undefined): boolean {
  return selection?.provider === AUTO_PROVIDER && (selection.modelId ?? selection.id) === AUTO_MODEL_ID;
}

export type AutoModelRuntime = Pick<ModelRuntime,
  "registerVirtualModel" | "unregisterVirtualModel" | "getPhysicalModel" | "hasConfiguredAuth" | "getAvailableSnapshot">;

/** JSON router state pi stores on the session branch (`pi.virtual-model-state`). */
export interface AutoRouterState {
  v: 1;
  tier: ModelTier;
  choice: RouteTarget;
  ladder: RouteTarget[];
  alternates: RouteTarget[];
  /** Per user turn. */
  escalations: number;
  /** pi_os_escalate toolCallIds already acted on in this turn. */
  consumed: string[];
  /** Consecutive failed attempts (reset by the next successful response). */
  retries: number;
  /** Tool error/result counts at the last escalation (each trigger needs fresh evidence). */
  errBase: number;
  resBase: number;
}

export type RouteCause =
  | "decision" | "fallback" | "previous" | "sticky" | "sticky-failover"
  | "escalate:tool" | "escalate:errors" | "escalate:long-turn"
  | "failover:rate" | "failover:context" | "failover:retry" | "retry-same" | "direct";

/** One routing step (ids and labels only; safe to log and to put on the invocation record). */
export interface RouteEvent {
  reason: ModelRouteReason;
  cause: RouteCause;
  tier: ModelTier;
  target: RouteTarget;
  reasons: readonly string[];
}

export interface AutoModelDeps {
  /** Routing knobs for fallback decisions (bias comes from the virtual thinking level). */
  settings?: () => RoutingSettings;
  /** Health/latency view; `block` receives retry penalties. */
  stats?: LatencyView & { block?(provider: string, durationMs: number, reason: HealthReason, model?: string): void };
  priors?: readonly Profile[];
  log?: (line: string) => void;
  /** Called for every routed request (e.g. to update the invocation record's `route`). */
  onRoute?: (event: RouteEvent) => void;
  now?: () => number;
  decisionTtlMs?: number;
  /** Limits shown before the first response (pi then uses the routed model's). */
  contextWindow?: number;
  maxTokens?: number;
}

export interface AutoModelHandle {
  /** Decision for the NEXT user request of this session (consumed once; expires after 2 min). */
  setDecision(decision: RouteDecision): void;
  clearDecision(): void;
  /** Most recent routing step, for logs and the HUD. */
  lastRoute(): RouteEvent | undefined;
  /** Tier the session ran on last (pass as RouteInput.lastTier for follow-ups). */
  lastTier(): ModelTier | undefined;
  unregister(): void;
}

function isTarget(value: unknown): value is RouteTarget {
  const t = value as RouteTarget | null;
  return typeof t === "object" && t !== null && typeof t.provider === "string" && typeof t.id === "string"
    && typeof t.thinkingLevel === "string" && isModelTier(t.tier);
}

/** Validate persisted state (older/foreign shapes are ignored, not trusted). */
export function parseRouterState(value: unknown): AutoRouterState | undefined {
  const s = value as Partial<AutoRouterState> | null;
  if (typeof s !== "object" || s === null || s.v !== 1 || !isModelTier(s.tier) || !isTarget(s.choice)) return undefined;
  if (!Array.isArray(s.ladder) || !s.ladder.every(isTarget) || !Array.isArray(s.alternates) || !s.alternates.every(isTarget)) return undefined;
  if (!Array.isArray(s.consumed) || !s.consumed.every(id => typeof id === "string")) return undefined;
  const count = (n: unknown) => (typeof n === "number" && Number.isFinite(n) && n >= 0 ? n : 0);
  return {
    v: 1, tier: s.tier, choice: s.choice, ladder: s.ladder, alternates: s.alternates, consumed: s.consumed,
    escalations: count(s.escalations), retries: count(s.retries), errBase: count(s.errBase), resBase: count(s.resBase),
  };
}

function sinceLastUser(messages: readonly Message[]): readonly Message[] {
  return messages.slice(messages.findLastIndex(m => m.role === "user") + 1);
}

function lastUserMessage(messages: readonly Message[]) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message?.role === "user") return message;
  }
  return undefined;
}

function lastUserText(messages: readonly Message[]): string {
  const content = lastUserMessage(messages)?.content ?? "";
  return typeof content === "string" ? content : content.flatMap(part => (part.type === "text" ? [part.text] : [])).join("\n");
}

function lastUserHasImage(messages: readonly Message[]): boolean {
  const content = lastUserMessage(messages)?.content;
  return Array.isArray(content) && content.some(part => part.type === "image");
}

/** ~4 chars per token; images ~1.5k tokens. Only sizes, never content, leave this function. */
function estimateTokens(messages: readonly Message[]): number {
  let chars = 0;
  let images = 0;
  for (const message of messages) {
    const content = (message as { content?: unknown }).content;
    if (typeof content === "string") { chars += content.length; continue; }
    if (!Array.isArray(content)) continue;
    for (const part of content as { type?: string; text?: string; thinking?: string; arguments?: unknown }[]) {
      if (part.type === "image") images++;
      else chars += (part.text ?? part.thinking ?? "").length + (part.type === "toolCall" ? 200 : 0);
    }
  }
  return Math.ceil(chars / 4) + images * 1_500;
}

export function registerAutoModel(runtime: AutoModelRuntime, deps: AutoModelDeps = {}): AutoModelHandle {
  const now = deps.now ?? Date.now;
  const log = deps.log ?? (() => {});
  const ttl = deps.decisionTtlMs ?? DECISION_TTL_MS;
  let pending: { decision: RouteDecision; at: number } | undefined;
  let last: RouteEvent | undefined;
  let lastState: AutoRouterState | undefined;
  let memo: { source: readonly Model<Api>[]; catalog: RoutingCatalog } | undefined;

  const catalog = (): RoutingCatalog => {
    const models = runtime.getAvailableSnapshot();
    if (memo?.source !== models) memo = { source: models, catalog: buildRoutingCatalog(models, deps.priors) };
    return memo.catalog;
  };
  /** Settings snapshot for the request being routed (read once per route() call). */
  let settings: RoutingSettings = DEFAULT_ROUTING_SETTINGS;
  const physical = (t: TierChoice) => runtime.getPhysicalModel(t.provider, t.id);
  /** Physical, authenticated, not loopback unless opted in (GPU coordination), and healthy unless allowBlocked. */
  const usable = (t: TierChoice | undefined, allowBlocked = false): t is RouteTarget => {
    const model = t && physical(t);
    return !!t && !!model && runtime.hasConfiguredAuth(t.provider)
      && (settings.allowLocalModels || !isLocalModel(model))
      && (allowBlocked || !deps.stats?.blocked(t.provider, t.id));
  };
  const vision = (t: TierChoice) => physical(t)?.input.includes("image") ?? false;

  const take = (): RouteDecision | undefined => {
    const slot = pending;
    pending = undefined;
    if (!slot || now() - slot.at > ttl || slot.decision.lane !== "agent") return undefined;
    return slot.decision;
  };

  /**
   * Build the route. `persist: false` returns no state, which keeps the stored
   * one: pi appends a session entry for every returned state object.
   */
  const to = (request: ModelRouteRequest, target: RouteTarget, cause: RouteCause, state: AutoRouterState | undefined,
    reasons: readonly string[] = [], persist = true): ModelRoute => {
    const event: RouteEvent = { reason: request.reason, cause, tier: target.tier, target, reasons };
    last = event;
    if (state && request.reason !== "direct") lastState = state;
    if (cause !== "sticky") {
      log(`[route] reason=${request.reason} cause=${cause} tier=${target.tier} model=${targetKey(target)}${reasons.length ? ` reasons=${reasons.join(",")}` : ""}`);
    }
    try { deps.onRoute?.(event); } catch { /* observers never break routing */ }
    const route: ModelRoute = { model: physical(target)!, thinkingLevel: target.thinkingLevel };
    if (state && persist && request.reason !== "direct") route.state = state;
    return route;
  };

  const fresh = (choice: RouteTarget, decision?: RouteDecision): AutoRouterState => ({
    v: 1, tier: choice.tier, choice,
    ladder: (decision?.ladder ?? []).filter(r => tierRank(r.tier) > tierRank(choice.tier) && !sameTarget(r, choice)),
    alternates: (decision?.alternates ?? []).filter(a => !sameTarget(a, choice)),
    escalations: 0, consumed: [], retries: 0, errBase: 0, resBase: 0,
  });

  const previousTarget = (request: ModelRouteRequest, state?: AutoRouterState): RouteTarget | undefined => {
    const previous = request.previous;
    if (!previous) return undefined;
    return {
      provider: previous.model.provider, id: previous.model.id,
      thinkingLevel: previous.thinkingLevel ?? state?.choice.thinkingLevel ?? "off",
      tier: state?.tier ?? "standard",
    };
  };

  const fallbackDecision = (request: ModelRouteRequest, state?: AutoRouterState): RouteDecision => decide({
    classification: classifyUtterance(extractRequestText(lastUserText(request.messages))),
    followup: state !== undefined || request.previous !== undefined,
    surface: "other",
    hasScreenshot: lastUserHasImage(request.messages),
    // Whatever the image is (screenshot or attachment), the model must be able to see it.
    hasImageAttachment: lastUserHasImage(request.messages),
    selectionChars: 0,
    browserCdp: false,
    estimatedPromptTokens: estimateTokens(request.messages),
    lastTier: state?.tier,
  }, catalog(), settings, { stats: deps.stats });

  const routeUser = (request: ModelRouteRequest, state?: AutoRouterState, consumeDecision = true): ModelRoute => {
    const decided = consumeDecision ? take() : undefined;
    const decision = decided ?? fallbackDecision(request, state);
    const pool = [decision.model, ...decision.alternates, ...decision.ladder].filter((t): t is RouteTarget => !!t);
    const image = lastUserHasImage(request.messages);
    // Healthy first; a health block only demotes (decide() does the same when everything is blocked).
    const choice = pool.find(t => usable(t) && (!image || vision(t))) ?? pool.find(t => usable(t))
      ?? pool.find(t => usable(t, true) && (!image || vision(t))) ?? pool.find(t => usable(t, true));
    if (choice) return to(request, choice, decided ? "decision" : "fallback", fresh(choice, decision), decision.reasons);
    const previous = previousTarget(request, state);
    if (usable(previous, true)) return to(request, previous, "previous", fresh(previous), decision.reasons);
    throw new Error(NO_MODEL);
  };

  const routeContinuation = (request: ModelRouteRequest, state?: AutoRouterState): ModelRoute => {
    if (!state) {
      const previous = previousTarget(request);
      return usable(previous, true) ? to(request, previous, "previous", fresh(previous)) : routeUser(request, undefined, false);
    }
    const results = sinceLastUser(request.messages).filter((m): m is ToolResultMessage => m.role === "toolResult");
    const escalate = results.find(m => m.toolName === ESCALATE_TOOL_NAME && !m.isError && !state.consumed.includes(m.toolCallId));
    const errors = results.filter(m => m.isError).length;
    const low = tierRank(state.tier) <= tierRank("fast");
    const trigger = escalate ? "tool"
      : low && errors - state.errBase >= ESCALATE_ON_ERRORS ? "errors"
        : low && results.length - state.resBase > ESCALATE_AFTER_RESULTS ? "long-turn" : undefined;
    const consumed = escalate ? [...state.consumed, escalate.toolCallId] : state.consumed;
    if (trigger && state.escalations < MAX_ESCALATIONS_PER_TURN) {
      const index = state.ladder.findIndex(r => usable(r));
      const next = state.ladder[index];
      if (next) {
        return to(request, next, `escalate:${trigger}`, {
          ...state, tier: next.tier, choice: next, ladder: state.ladder.slice(index + 1), alternates: [],
          escalations: state.escalations + 1, consumed, retries: 0, errBase: errors, resBase: results.length,
        });
      }
    }
    // A continuation follows a successful response, so any retry episode is over (the next failure
    // retries the same model first again). An escalate call that found no rung is remembered so it
    // is not re-evaluated.
    const kept = escalate || state.retries > 0 ? { ...state, consumed, retries: 0 } : state;
    if (usable(state.choice)) return to(request, state.choice, "sticky", kept, [], kept !== state);
    const alternative = [...state.alternates, ...state.ladder].find(t => usable(t));
    if (alternative) return to(request, alternative, "sticky-failover", { ...kept, tier: alternative.tier, choice: alternative });
    if (usable(state.choice, true)) return to(request, state.choice, "sticky", kept, [], kept !== state);
    const previous = previousTarget(request, state);
    if (usable(previous, true)) return to(request, previous, "previous", { ...kept, choice: previous });
    throw new Error(NO_MODEL);
  };

  const routeRetry = (request: ModelRouteRequest, state?: AutoRouterState): ModelRoute => {
    const failed = request.failed;
    if (!failed) return routeContinuation(request, state); // the router itself failed: nothing to fail over from
    const failedTarget: RouteTarget = {
      provider: failed.model.provider, id: failed.model.id,
      thinkingLevel: failed.thinkingLevel ?? state?.choice.thinkingLevel ?? "off", tier: state?.tier ?? "standard",
    };
    const base = state ?? fresh(failedTarget);
    const retries = base.retries + 1;
    const kind = isContextOverflow(failed.message, failed.model.contextWindow) ? "context" : classifyProviderError(failed.message.errorMessage);
    const others = (list: RouteTarget[]) => list.filter(t => !sameTarget(t, failedTarget) && usable(t));
    let next: RouteTarget | undefined;
    let cause: RouteCause = "failover:retry";
    if (kind === "rate_limit" || kind === "overloaded") {
      deps.stats?.block?.(failed.model.provider, HEALTH_PENALTY_MS[kind], kind, failed.model.id);
      const siblings = others(base.alternates);
      next = siblings.find(t => t.provider !== failed.model.provider) ?? siblings[0] ?? others(base.ladder)[0];
      cause = "failover:rate";
    } else if (kind === "context") {
      next = others([...base.alternates, ...base.ladder]).find(t => (physical(t)?.contextWindow ?? 0) > failed.model.contextWindow);
      cause = "failover:context";
    } else if (retries >= 2) {
      next = others([...base.alternates, ...base.ladder])[0];
    }
    if (next) {
      const ladderIndex = base.ladder.findIndex(r => sameTarget(r, next));
      return to(request, next, cause, {
        ...base, tier: next.tier, choice: next, retries,
        alternates: base.alternates.filter(a => !sameTarget(a, next)),
        ladder: ladderIndex >= 0 ? base.ladder.slice(ladderIndex + 1) : base.ladder,
      }, [`error=${kind}`]);
    }
    // Same model keeps the prompt cache; pi backs off between attempts.
    if (usable(failedTarget, true)) return to(request, failedTarget, "retry-same", { ...base, retries }, [`error=${kind}`]);
    const any = [...base.alternates, ...base.ladder].find(t => usable(t, true));
    if (any) return to(request, any, "failover:retry", { ...base, tier: any.tier, choice: any, retries }, [`error=${kind}`]);
    throw new Error(NO_MODEL);
  };

  const routeDirect = (request: ModelRouteRequest): ModelRoute => {
    // Compaction summaries read the whole conversation: require room for it.
    const needed = Math.ceil(estimateTokens(request.messages) * 1.1);
    const quick = quickestTarget(catalog(), settings, needed, deps.stats);
    if (usable(quick)) return to(request, quick, "direct", undefined);
    const previous = previousTarget(request, lastState);
    if (usable(previous, true)) return to(request, previous, "direct", undefined);
    // Everything that fits is health-blocked: a block demotes, it does not refuse.
    const blocked = quickestTarget(catalog(), settings, needed);
    if (usable(blocked, true)) return to(request, blocked, "direct", undefined);
    throw new Error(NO_MODEL);
  };

  runtime.registerVirtualModel({
    provider: AUTO_PROVIDER,
    id: AUTO_MODEL_ID,
    name: AUTO_MODEL_NAME,
    thinkingLevels: AUTO_THINKING_LEVELS,
    contextWindow: deps.contextWindow ?? 272_000,
    maxTokens: deps.maxTokens ?? 128_000,
    input: ["text", "image"],
    route(request) {
      settings = { ...(deps.settings?.() ?? DEFAULT_ROUTING_SETTINGS), bias: biasForThinkingLevel(request.thinkingLevel) };
      const state = parseRouterState(request.state);
      switch (request.reason) {
        case "direct": return routeDirect(request);
        case "user": return routeUser(request, state);
        case "retry": return routeRetry(request, state);
        default: return routeContinuation(request, state);
      }
    },
  });

  return {
    setDecision(decision) { pending = { decision, at: now() }; },
    clearDecision() { pending = undefined; },
    lastRoute: () => last,
    lastTier: () => lastState?.tier,
    unregister() { runtime.unregisterVirtualModel(AUTO_PROVIDER, AUTO_MODEL_ID); },
  };
}
