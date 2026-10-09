import type { AssistantMessage, Model } from "@earendil-works/pi-ai";
import type { CreateAgentSessionOptions, InlineExtension, ToolDefinition, ToolLoadout } from "@earendil-works/pi-coding-agent";
import {
  createAgentSession,
  getAgentDir,
  ModelRuntime,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import type { HostClient, DesktopContextSnapshot, ScreenshotRef } from "../hostClient.js";
import { createComputerUseExtension } from "./computerUseExtension.js";
import { BrowserSession } from "../browser/session.js";
import { BROWSER_TOOLS } from "../browser/tools.js";
import { LiveAgentSession, type SessionObserver } from "./liveSession.js";
export { LiveAgentSession } from "./liveSession.js";
import { loadScreenshotImage } from "./screenshotImage.js";
import { createSessionSettings, loadAgentResources, registerResourceProviders } from "./resources.js";
import { effectiveResourceMode, TRUST_WARNING, type ResourceSelection } from "./resourceSettings.js";
import {
  CODEMODE_TOOL, CODEMODE_TOOL_NAMES, codemodeExtensionFactories, MODEL_ONLY_TOOLS, SCRIPT_CALLABLE_TOOLS,
} from "./codemodePolicy.js";
import {
  createLauncherToolsExtension, LAUNCHER_READ_TOOL_NAMES, OPEN_ITEM_TOOL,
  type FileRefLedger, type InstantToolEngines,
} from "./launcherTools.js";
import {
  AUTO_MODEL_ID, AUTO_PROVIDER, biasForThinkingLevel, buildRouteInput, buildRoutingCatalog, createEscalateExtension, decide,
  DEFAULT_ROUTING_SETTINGS, ESCALATE_TOOL_NAME, isAutoSelection, registerAutoModel, routeContextFromSnapshot, thinkingLevelForBias,
  type ClassifierHints, type LatencyStats, type LatencyView, type RouteDecision, type RouteInput, type RoutingCatalog, type RoutingSettings,
} from "./routing/index.js";
import { createShowResultExtension, SHOW_RESULT_TOOL } from "../ui/showResult.js";
import { FileLedger } from "../ui/ledger.js";
import { createInstantEngines, type InstantEngines } from "../instant/engines.js";
import type { CardSpec } from "../contracts/cards.js";
import { registerLayaProvider, type LayaPredictBackend } from "../classifier/provider.js";
export { createSessionSettings, loadAgentResources, PI_OS_SETTINGS_OVERRIDES } from "./resources.js";

/**
 * One in-memory session per pinned thread; sequential follow-ups retain history,
 * original model and resource scope. One-shot callers still dispose immediately.
 *
 * Session ids stay per thread (SessionManager.inMemory() mints one per session) rather
 * than stable per lane: pi's AgentSession.dispose() calls cleanupSessionResources(id),
 * which closes every cached Codex WebSocket of that id (openai-codex-responses.js
 * closeOpenAICodexWebSocketSessions), so a lane id shared by two threads would let one
 * reader's close cut the other's stream, and one-shot invocations dispose their session
 * anyway. The same id is also sent as session/affinity headers and prompt_cache_key to
 * Auto's other providers, whose server-side use of it cannot be verified offline.
 * Client-side, the cached-context delta only applies to a byte-identical prefix
 * (getCachedWebSocketInputDelta), so no conversation could have been merged; the cost of
 * not sharing is one WebSocket handshake per thread.
 */

/** Model + reasoning effort chosen in the settings page (modelSettings.ts). */
export interface ModelSelectionOption {
  provider: string;
  modelId: string;
  thinkingLevel: string;
}

/** How the request was entered (POST /invoke `input`); used for the spoken-input prompt note only. */
export interface InvokeInput {
  mode: "text" | "voice";
  confidence?: number;
  locale?: string;
  durationMs?: number;
  engine?: string;
}

/** Process-wide collaborators a session is built with (the server owns them). */
export interface AgentServices {
  /** Auto router knobs (RoutingSettingsStore.get). */
  routing?: () => RoutingSettings;
  /** Shared latency/health view for routing and failover penalties. */
  stats?: LatencyStats;
  /** Instant engines behind the agent's instant/launcher tools (default: engines without host routes). */
  engines?: InstantToolEngines;
  /** Optional local classifier backend, registered as the `laya` classifier provider. */
  laya?: () => LayaPredictBackend | undefined;
  /** Runtime factory (tests inject an in-process provider). One runtime per session: it holds Auto's decision slot. */
  modelRuntime?: () => Promise<ModelRuntime>;
  /** pi agent dir / cwd overrides (tests use a fixture agent dir). */
  agentDir?: string;
  cwd?: string;
}

export interface AgentRunOptions {
  hostClient: HostClient;
  contextId: string;
  prompt: string;
  snapshot: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null };
  capturesDir: string;
  log: (line: string) => void;
  /** Per-invocation host capabilities. Mac tools remain isolated even when input is enabled. */
  readOnly?: boolean;
  resourceSelection?: ResourceSelection;
  /** Stored settings selection; undefined/null/unresolvable means Auto (`pi-os/auto`). */
  modelSelection?: ModelSelectionOption | null;
  /** Host advertises launcher.searchFiles + launcher.listApps (macOS): find_files/list_apps/open_item. */
  launcher?: boolean;
  /** Abort signal; when fired the pi session is aborted and runAgent throws AbortError. */
  signal?: AbortSignal;
  /** Called on every agent tool execution start (for live invocation status). */
  onToolCall?: (toolName: string) => void;
  /** Live activity marker for the host pill: tool name while a tool runs,
   * "thinking" during reasoning, undefined when idle. */
  onActivity?: (activity: string | undefined) => void;
  /** Spoken/typed input metadata (POST /invoke `input`). */
  input?: InvokeInput;
  /** false: the router decided the request needs no screenshot; it is not attached (default true). */
  attachScreenshot?: boolean;
  services?: AgentServices;
}

export interface AgentRunResult {
  responseText: string;
  toolCalls: number;
}

/** Extract the visible text from one completed assistant message. */
export function assistantMessageText(message: AssistantMessage): string {
  return message.content
    .filter((part): part is { type: "text"; text: string } => part.type === "text")
    .map((part) => part.text)
    .join("\n");
}

/** Compact summary injected into the prompt; full detail stays on tools. */
export function summarizeSnapshot(snapshot: DesktopContextSnapshot): string {
  const pickWindow = (window: DesktopContextSnapshot["targetWindow"]) =>
    window && {
      process: `${window.processName} (${window.processId})`,
      title: window.title,
      className: window.className,
      surface: window.surface,
      shellFolderPath: window.shellFolderPath,
      documentPath: window.documentPath,
      hwnd: window.hwnd,
      bounds: window.bounds,
      monitorId: window.monitorId,
      dpi: window.dpi,
    };
  const pickElement = (element: DesktopContextSnapshot["focusedElement"]) =>
    element && {
      name: element.name,
      controlType: element.controlType,
      value: element.value,
      bounds: element.bounds,
    };
  const cursorMonitor = snapshot.monitors.find(({ bounds }) =>
    snapshot.cursor.x >= bounds.x && snapshot.cursor.x < bounds.x + bounds.width
    && snapshot.cursor.y >= bounds.y && snapshot.cursor.y < bounds.y + bounds.height);

  return JSON.stringify(
    {
      targetWindow: pickWindow(snapshot.targetWindow),
      browser: snapshot.browser,
      foregroundWindow: pickWindow(snapshot.foregroundWindow),
      windowUnderCursor: pickWindow(snapshot.windowUnderCursor),
      focusedElement: snapshot.focusedElement && {
        meaning: "keyboard focus only; does not imply selection",
        ...pickElement(snapshot.focusedElement),
      },
      elementUnderCursor: pickElement(snapshot.elementUnderCursor),
      selectedDesktopItems: snapshot.selectedDesktopItems?.map(pickElement),
      selectedDesktopItemCount: snapshot.selectedDesktopItemCount,
      selectedDesktopItemsTruncated: snapshot.selectedDesktopItemsTruncated,
      screenshot: snapshot.screenshot && {
        imageWidth: snapshot.screenshot.imageWidth, imageHeight: snapshot.screenshot.imageHeight,
        bounds: snapshot.screenshot.bounds,
      },
      cursor: { ...snapshot.cursor, monitorId: cursorMonitor?.id },
      monitors: snapshot.monitors.map(monitor => ({
        id: monitor.id,
        deviceName: monitor.deviceName,
        isPrimary: monitor.isPrimary,
        bounds: monitor.bounds,
        workArea: monitor.workArea,
        dpi: monitor.dpi,
      })),
    },
    null,
    1,
  );
}

export const READ_ONLY_TOOLS = ["desktop_get_context", "desktop_refresh_context", "desktop_capture_window"];

/**
 * The isolated tools allowlist (CRITIC F24: the allowlist filters every registered tool and
 * naming one activates it). Read-only sessions get observation, instant/launcher reads, cards
 * and codemode; control adds native input (or the Brave tools) and open_item. pi_os_escalate
 * only exists for sessions on Auto, where the router acts on it.
 */
export function sessionToolAllowlist(options: { readOnly: boolean; browser?: boolean; auto?: boolean }): string[] {
  return [
    ...READ_ONLY_TOOLS,
    ...(options.readOnly ? [] : options.browser ? BROWSER_TOOLS : ["desktop_act"]),
    ...LAUNCHER_READ_TOOL_NAMES,
    ...(options.readOnly ? [] : [OPEN_ITEM_TOOL]),
    SHOW_RESULT_TOOL,
    ...CODEMODE_TOOL_NAMES,
    ...(options.auto ? [ESCALATE_TOOL_NAME] : []),
  ];
}

/** Tools a light lane (quick/fast tier) leaves inactive unless the router hints them; an escalation restores them. */
export const LIGHT_LANE_OMITTED_TOOLS: readonly string[] = [CODEMODE_TOOL];

/** The active tool set for one routed turn: everything the session may use, minus heavy tools on light lanes. */
export function activeToolsFor(all: readonly string[], decision: Pick<RouteDecision, "tier" | "toolsAdd">): string[] {
  const light = decision.tier === "quick" || decision.tier === "fast";
  const hinted = new Set(decision.toolsAdd);
  return all.filter(name => !light || !LIGHT_LANE_OMITTED_TOOLS.includes(name) || hinted.has(name));
}

/** B1 instant engines → the shapes B5's agent tools take. Engines bound their own work and never throw. */
export function toolEnginesFrom(engines: InstantEngines): InstantToolEngines {
  return {
    async calc(expression) {
      const result = await engines.calc(expression);
      return result.ok ? { ok: true, text: result.text, approximate: result.approximate } : { ok: false, error: result.error };
    },
    async convertCurrency(amount, from, to, signal) {
      const result = await engines.convertCurrency(amount, from, to, signal ? { signal } : {});
      return result.ok ? { value: result.value, asOf: result.asOf, freshness: result.freshness } : null;
    },
    async timeIn(place) {
      const result = await engines.timeIn(place);
      if (!result.ok) return null;
      const dayDelta = result.dayDelta > 0 ? 1 : result.dayDelta < 0 ? -1 : 0;
      return { place: result.place, zone: result.zone, time: result.time24, weekday: result.weekday, offset: result.offset, dayDelta };
    },
  };
}

/** B2 FileLedger → B5's single-candidate ledger interface (one ledger per thread, shared with show_result). */
export function ledgerAdapter(ledger: FileLedger): FileRefLedger {
  return {
    register: candidate => ledger.register([candidate])[0]?.ref,
    token: ref => ledger.resolve(ref)?.token,
  };
}

/**
 * pi's codemode tool advertises every active `direct` tool as script-callable and appends
 * "Codemode: tools.x(args) resolves to …" to its description. The pi-os policy refuses
 * nested calls to anything outside SCRIPT_CALLABLE_TOOLS (in trusted mode: read, bash, edit,
 * write and global extension tools), so advertise exactly the callable set; scripts are then
 * never told they may call a tool the policy blocks.
 */
export function advertiseScriptCallableOnly(factories: InlineExtension[], callable: Iterable<string> = SCRIPT_CALLABLE_TOOLS): InlineExtension[] {
  const never = new Set<string>(MODEL_ONLY_TOOLS);
  const allowed = new Set([...callable].filter(name => !never.has(name)));
  const narrow = (loadout: ToolLoadout): ToolLoadout => ({ ...loadout, callable: loadout.callable.filter(tool => allowed.has(tool.name)) });
  return factories.map(extension => typeof extension === "function" || extension.name !== "pi-os-codemode" ? extension : {
    name: extension.name,
    factory(pi) {
      const api = Object.create(pi) as typeof pi;
      api.registerTool = ((tool: ToolDefinition) => {
        const prepare = tool.name === CODEMODE_TOOL ? tool.prepareLoadout : undefined;
        pi.registerTool(prepare ? { ...tool, prepareLoadout: loadout => prepare(narrow(loadout)) } : tool);
      }) as typeof pi.registerTool;
      return extension.factory(api);
    },
  });
}

/** Engine stand-ins when the caller wires none (only reachable outside the harness server). */
let defaultEngines: InstantToolEngines | undefined;

export interface SessionExtensionOptions {
  contextId: string;
  hostClient: HostClient;
  capturesDir: string;
  readOnly: boolean;
  platform?: NodeJS.Platform;
  /** Only when that image is attached to the first prompt (or revoked before it, see promptFirst). */
  initialScreenshotId?: string;
  browser?: BrowserSession;
  /** Host launcher read routes exist (macOS): find_files, list_apps, open_item. */
  launcher?: boolean;
  engines?: InstantToolEngines;
  /** The thread's ledger, shared by find_files and show_result. */
  ledger?: FileLedger;
  onCard?: (spec: CardSpec, complete: boolean) => void;
}

/**
 * Every pi-os extension of a session, in load order: computer use, instant/launcher tools,
 * show_result, pi_os_escalate (only allowed/active on Auto), then the codemode policy before
 * pi's codemode. The isolated allowlist (sessionToolAllowlist) decides what is exposed.
 */
export function sessionExtensions(options: SessionExtensionOptions) {
  const platform = options.platform ?? process.platform;
  const ledger = options.ledger ?? new FileLedger();
  // macOS: desktop_act returns the post-action capture (one model turn fewer; ignored elsewhere).
  const computerUse = createComputerUseExtension(options.contextId, options.hostClient, options.capturesDir, options.readOnly, platform,
    options.initialScreenshotId, options.browser, { postActionCapture: platform === "darwin" });
  const engines = options.engines ?? (defaultEngines ??= toolEnginesFrom(createInstantEngines()));
  const extensions: InlineExtension[] = [
    computerUse,
    // Without host launcher routes (Windows) only the engine-only instant tools register.
    createLauncherToolsExtension({
      engines, readOnly: options.readOnly, contextId: options.contextId,
      ...(options.launcher ? { host: options.hostClient, ledger: ledgerAdapter(ledger) } : {}),
    }),
    createShowResultExtension({ ledger, onCard: (spec, complete) => options.onCard?.(spec, complete) }),
    createEscalateExtension(),
    ...advertiseScriptCallableOnly(codemodeExtensionFactories()),
  ];
  return { extensions, computerUse, ledger };
}

/** Selection a session starts with: a resolvable manual model, otherwise Auto at the routing bias. */
export function resolveSessionModel(
  runtime: Pick<ModelRuntime, "getModel">,
  stored: ModelSelectionOption | null | undefined,
  bias: RoutingSettings["bias"],
): { auto: boolean; model?: Model<any>; thinkingLevel?: string; fallbackReason?: string } {
  if (stored && !isAutoSelection(stored) && stored.provider && stored.modelId) {
    const model = runtime.getModel(stored.provider, stored.modelId);
    if (model) return { auto: false, model, ...(stored.thinkingLevel ? { thinkingLevel: stored.thinkingLevel } : {}) };
    const auto = runtime.getModel(AUTO_PROVIDER, AUTO_MODEL_ID);
    return { auto: Boolean(auto), ...(auto ? { model: auto, thinkingLevel: thinkingLevelForBias(bias) } : {}),
      fallbackReason: `configured model ${stored.provider}/${stored.modelId} is not registered` };
  }
  const auto = runtime.getModel(AUTO_PROVIDER, AUTO_MODEL_ID);
  // Explicit level: pi's global default (xhigh) would clamp to "high" and silently mean quality bias.
  const level = isAutoSelection(stored) && stored?.thinkingLevel ? stored.thinkingLevel : thinkingLevelForBias(bias);
  return auto ? { auto: true, model: auto, thinkingLevel: level } : { auto: false };
}

/**
 * Everything a prepared session was built from; it is reused only when an invocation matches exactly.
 * The screenshot is not part of it: a take is usually prepared before the host's capture finishes,
 * so the server compares the seeded screenshot (`controls.initialScreenshotId`) only when the
 * routed turn will attach an image (without one, promptFirst revokes the seed anyway).
 */
export function sessionSetupKey(options: AgentRunOptions): string {
  const routing = options.services?.routing?.() ?? DEFAULT_ROUTING_SETTINGS;
  return JSON.stringify([
    process.platform, options.contextId, options.readOnly ?? null, options.launcher === true,
    options.resourceSelection?.mode ?? "isolated", options.modelSelection ?? null, routing.bias,
    options.snapshot.browser?.mode ?? null,
  ]);
}

/** Whether promptFirst will attach the pinned screenshot for this plan. */
export function attachesScreenshot(snapshot: AgentRunOptions["snapshot"], plan: Pick<TurnPlan, "attachScreenshot">): boolean {
  return Boolean(snapshot.screenshot?.filePath) && plan.attachScreenshot;
}

export async function runAgent(options: AgentRunOptions): Promise<AgentRunResult> {
  const live = await createLiveSession(options);
  try { return await promptFirst(live, options); }
  finally { await live.close(); }
}

export async function createLiveSession(options: AgentRunOptions): Promise<LiveAgentSession> {
  const { hostClient, contextId, snapshot, capturesDir, log, signal, onToolCall, onActivity } = options;
  const services = options.services ?? {};
  const cwd = services.cwd ?? process.cwd();
  const agentDir = services.agentDir ?? getAgentDir();
  const routing = services.routing ?? (() => DEFAULT_ROUTING_SETTINGS);
  const lifetime = new AbortController();
  const mac = process.platform === "darwin";
  const readOnly = options.readOnly ?? mac;
  const browser = mac && !readOnly && snapshot.browser?.mode === "cdp"
    ? new BrowserSession(hostClient, contextId, lifetime.signal) : undefined;

  if (signal?.aborted) throw abortError(signal);
  const isolated = effectiveResourceMode(process.platform, readOnly, options.resourceSelection) === "isolated";
  // Hooks created here outlive a prepared session's build: they reach the CURRENT observer through `live`.
  let live: LiveAgentSession | undefined;
  const { extensions, computerUse: extension, ledger } = sessionExtensions({
    contextId, hostClient, capturesDir, readOnly, launcher: options.launcher === true,
    ...(snapshot.screenshot?.imageId ? { initialScreenshotId: snapshot.screenshot.imageId } : {}),
    ...(browser ? { browser } : {}),
    ...(services.engines ? { engines: services.engines } : {}),
    onCard: (spec, complete) => live?.emitCard(spec, complete),
  });
  const loader = await loadAgentResources(extensions, cwd, agentDir, isolated);

  const modelRuntime = await (services.modelRuntime ?? (() => ModelRuntime.create()))();
  // Every invocation runtime knows Auto; the handle is this session's decision slot.
  const auto = registerAutoModel(modelRuntime, {
    settings: routing, log, onRoute: event => live?.emitRoute(event), ...(services.stats ? { stats: services.stats } : {}),
  });
  const laya = services.laya?.();
  const unregisterLaya = laya ? registerLayaProvider(modelRuntime, laya) : undefined;
  let disposeProviderBootstrap: (() => void) | undefined;
  const release = () => { disposeProviderBootstrap?.(); unregisterLaya?.(); auto.unregister(); };
  try {
    disposeProviderBootstrap = !isolated ? await registerResourceProviders(loader, modelRuntime) : undefined;
  } catch (error) { release(); throw error; }
  if (signal?.aborted) { release(); throw abortError(signal); }

  // Settings-page selection (if any) -> concrete model for THIS invocation; none (or a lost one) -> Auto.
  const resolved = resolveSessionModel(modelRuntime, options.modelSelection, routing().bias);
  if (resolved.fallbackReason) log(`[agent] ${resolved.fallbackReason}; using Auto`);

  const sessionOptions: CreateAgentSessionOptions = {
    cwd,
    agentDir,
    modelRuntime,
    resourceLoader: loader,
    sessionManager: SessionManager.inMemory(),
    ...(isolated ? { tools: sessionToolAllowlist({ readOnly, browser: Boolean(browser), auto: resolved.auto }) } : {}),
    // Always explicit (also Windows trusted mode) so the image override applies to every session.
    settingsManager: createSessionSettings(isolated, cwd, agentDir),
  };
  if (resolved.model) {
    sessionOptions.model = resolved.model;
    // The SDK clamps unsupported levels to model capabilities.
    if (resolved.thinkingLevel) sessionOptions.thinkingLevel = resolved.thinkingLevel as CreateAgentSessionOptions["thinkingLevel"];
  }

  let created: Awaited<ReturnType<typeof createAgentSession>>;
  try { created = await createAgentSession(sessionOptions); }
  catch (error) { release(); throw error; }
  const { session } = created;

  // Trusted sessions have no allowlist: extension tools are active by default, pi's codemode is
  // registered inactive and is activated here; pi_os_escalate does nothing off Auto.
  const registered = new Set(session.getAllTools().map(tool => tool.name));
  const initial = session.getActiveToolNames();
  const toolNames = [...new Set([...initial, ...(!isolated && registered.has(CODEMODE_TOOL) ? [CODEMODE_TOOL] : [])])]
    .filter(name => resolved.auto || name !== ESCALATE_TOOL_NAME);
  const setActiveTools = (names: string[]) => {
    const current = session.getActiveToolNames();
    if (current.length !== names.length || names.some(name => !current.includes(name))) session.setActiveToolsByName(names);
  };
  setActiveTools(toolNames);
  log(
    `[agent] model=${session.model ? `${session.model.provider}/${session.model.id}` : "default"}` +
    ` effort=${session.thinkingLevel} tools=${toolNames.length}`,
  );

  let memo: { source: readonly Model<any>[]; catalog: RoutingCatalog } | undefined;
  const catalog = (): RoutingCatalog => {
    const models = modelRuntime.getAvailableSnapshot();
    if (memo?.source !== models) memo = { source: models, catalog: buildRoutingCatalog(models) };
    return memo.catalog;
  };

  let first = true;
  live = new LiveAgentSession(session, lifetime, { log, onToolCall, onActivity }, async () => {
    try { await browser?.dispose(); } finally { release(); }
  }, () => {
    if (!first) { extension.invalidateScreenshot(); browser?.invalidateReferences(); }
    first = false;
  }, {
    ...(resolved.auto ? { auto } : {}),
    catalog,
    thinkingLevel: () => session.thinkingLevel,
    ...(!resolved.auto && session.model ? { manual: { provider: session.model.provider, model: session.model.id, thinkingLevel: session.thinkingLevel } } : {}),
    toolNames,
    setActiveTools,
    revokeInitialScreenshot: () => extension.invalidateScreenshot(),
    ...(snapshot.screenshot?.imageId ? { initialScreenshotId: snapshot.screenshot.imageId } : {}),
    ledger,
    setupKey: sessionSetupKey(options),
  });
  return live;
}

export interface TurnInput {
  /** The user's own words (never the desktop-context wrapper). */
  text: string;
  snapshot?: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null };
  followup: boolean;
  /** Advisory classifier hints that ALREADY arrived (never awaited here). */
  hints?: ClassifierHints | null;
  settings: RoutingSettings;
  stats?: LatencyView;
}

export interface TurnPlan {
  decision?: RouteDecision;
  routeInput?: RouteInput;
  /** Attach the pinned screenshot to the first prompt. */
  attachScreenshot: boolean;
  activeTools?: string[];
}

/**
 * Auto: route the next prompt BEFORE it is sent. Heuristics (+ already-available advisory
 * hints) → decide() (< 1 ms, no I/O) → the session's decision slot, the turn's active tools
 * and screenshot gating. Sessions on a manually chosen model keep today's behaviour.
 */
export function planTurn(live: LiveAgentSession, turn: TurnInput): TurnPlan {
  const { auto, catalog } = live.controls;
  if (!auto || !catalog) return { attachScreenshot: true };
  const context = turn.snapshot && !turn.followup
    ? routeContextFromSnapshot(turn.snapshot)
    // Follow-ups never carry an image; route them like a text request on the same surface.
    : { ...(turn.snapshot ? routeContextFromSnapshot(turn.snapshot) : { surface: "other" as const, browserCdp: false }), hasScreenshot: false };
  const lastTier = auto.lastTier();
  const routeInput = buildRouteInput(turn.text, context, {
    followup: turn.followup, ...(lastTier ? { lastTier } : {}), ...(turn.hints ? { hints: turn.hints } : {}),
  });
  const settings: RoutingSettings = { ...turn.settings, bias: biasForThinkingLevel(live.controls.thinkingLevel?.()) };
  const decision = decide(routeInput, catalog(), settings, turn.stats ? { stats: turn.stats } : {});
  auto.setDecision(decision);
  let activeTools: string[] | undefined;
  if (live.controls.toolNames && live.controls.setActiveTools) {
    activeTools = activeToolsFor(live.controls.toolNames, decision);
    live.controls.setActiveTools(activeTools);
  }
  return { decision, routeInput, attachScreenshot: decision.attachScreenshot, ...(activeTools ? { activeTools } : {}) };
}

/** Prompt note for push-to-talk input; carries no transcript metadata beyond the language. */
export function spokenInputNote(input: InvokeInput | undefined): string[] {
  if (input?.mode !== "voice") return [];
  return [
    "## Input",
    `The request was spoken and transcribed by speech recognition${input.locale ? ` (${input.locale})` : ""}. Words may be misheard,`
      + " especially names, numbers and homophones: act on the most plausible desktop intent, and ask only when the action or target stays unclear.",
    "",
  ];
}

export async function promptFirst(live: LiveAgentSession, options: AgentRunOptions): Promise<AgentRunResult> {
  const { snapshot, prompt, capturesDir, signal } = options;
  const isolated = effectiveResourceMode(process.platform, options.readOnly ?? process.platform === "darwin", options.resourceSelection) === "isolated";
  const available = Boolean(snapshot.screenshot?.filePath);
  const attach = attachesScreenshot(snapshot, { attachScreenshot: options.attachScreenshot !== false });
  // Coordinate authority follows delivered images only (computerUseExtension): no image, no authority,
  // and a seed for any other image (a session prepared before this capture) never authorizes either.
  if (!attach || live.controls.initialScreenshotId !== snapshot.screenshot?.imageId) live.controls.revokeInitialScreenshot?.();
  const userMessage = [
    "## Desktop context (target identity pinned before the prompt appeared)",
    summarizeSnapshot(attach ? snapshot : { ...snapshot, screenshot: null }),
    ...(available && !attach ? ["No screenshot is attached to this request; call desktop_capture_window when you need to see the window."] : []),
    "",
    ...(!isolated && process.platform === "darwin" ? ["## Trusted pi compatibility", TRUST_WARNING,
      "Desktop tool refusals must not be bypassed through another input path.", ""] : []),
    ...spokenInputNote(options.input),
    "## Request",
    prompt,
  ].join("\n");

  if (signal?.aborted) throw abortError(signal);
  const image = attach && snapshot.screenshot?.filePath
    ? await loadScreenshotImage(snapshot.screenshot.filePath, capturesDir) : undefined;
  return live.prompt(userMessage, signal, image);
}

export function promptFollowup(live: LiveAgentSession, prompt: string, signal?: AbortSignal, input?: InvokeInput): Promise<AgentRunResult> {
  return live.prompt([
    "## Follow-up on the same pinned target",
    "Keep the thread's original target; never retarget. Earlier screenshots and browser references are historical.",
    "Take a fresh desktop_capture_window or browser_snapshot before acting. All safety and cumulative input budgets still apply.",
    ...spokenInputNote(input),
    "## Request", prompt,
  ].join("\n"), signal);
}

/** Normalize an aborted signal into a classifiable error. */
export function abortError(signal: AbortSignal): Error {
  const reason = signal.reason instanceof Error ? signal.reason : undefined;
  const error = new Error(reason?.message ?? "Invocation aborted");
  error.name = "AbortError";
  return error;
}

export type { SessionObserver };
