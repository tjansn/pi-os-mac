import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { dirname, join } from "node:path";
import { FULL_INVOKE_TIMEOUT_MS, loadConfig, type HarnessConfig } from "./config.js";
import { HostClient, LauncherRouteError, type DesktopContextSnapshot, type ScreenshotRef, type ToolOutcome } from "./hostClient.js";
import { InvocationStore, TERMINAL_STATES, type InvocationRecord } from "./invocations.js";
// Types only: the agent stack itself is imported after listen() (importAgentModules).
import type {
  AgentRunOptions, AgentServices, BrowserPageProvider, InvokeInput, LiveAgentSession, SessionObserver, TurnPlan,
} from "./agent/agentRunner.js";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { RouteEvent } from "./agent/routing/autoModel.js";
import type { LatencyStats } from "./agent/routing/latencyStats.js";
import { AgentModelSettings, type ModelSelection } from "./agent/modelSettings.js";
import { AgentResourceSettings, TRUST_WARNING } from "./agent/resourceSettings.js";
import { classifyUtterance } from "./agent/routing/heuristics.js";
import { contextScope, rulesContextScorer, warmContextScope } from "./agent/routing/contextScope.js";
import { RoutingSettingsStore, validateRoutingPatch, validateTierOverrides } from "./agent/routing/settings.js";
import {
  createClassifier, type ClassifierFactoryDeps, type ManagedClassifier,
} from "./classifier/factory.js";
import { ClassifierSettingsStore, parseClassifierSettings, resolveLayaLaunch, type LayaLaunchReason } from "./classifier/settings.js";
import {
  AppIndexCache, createFendLoader, createInstantDispatcher, EcbRateStore, FileFrecencyStore, VisibleItemsCache,
  type FrecencyStore, type InstantDispatcher, type InstantDispatcherDeps,
} from "./instant/index.js";
import { DictionaryStore, nonCountingLookup } from "./instant/dictionary.js";
import { appRecords, applyEdit, createLearnLane, displayName, learnFromGesture, outcomeFields, type LearnLane } from "./instant/learned.js";
import { InMemoryTakeMemo, takeDetailsOf, takeRecordFor } from "./instant/takeMemo.js";
import { isCommonWord } from "./instant/lexicon.js";
import {
  accepts, FILL_NEVER_KINDS, fillActConsistent, fillSubmitAllowed, parseInstantRequest,
  type ClassifierHints, type InstantRequest, type InstantResponse, type IntentClassifier,
} from "./contracts/instant.js";
import { DICTIONARY_LIMITS, parseEditRequest, parseLearnRequest, parseRecognizerTermsMax } from "./contracts/dictionary.js";
import type { AppRecord } from "./contracts/launcher.js";
import { HOST_ACTION_TYPES } from "./contracts/actions.js";
import { attachmentStats, parseAttachments, summarizeAttachments, type Attachment, type AttachmentIssue } from "./contracts/attachments.js";
import { NO_CONTEXT_SCORER, parseContext, requestedContextRecord, SCOPE_THRESHOLDS, scopeBand, type ContextWire } from "./contracts/context.js";
import { parseWorkingDirectory, type BashGuard, type ResourceStatus } from "./contracts/piSession.js";
import type { CardSpec } from "./contracts/cards.js";
import { cardToText } from "./ui/text.js";
import { perfLog, Stopwatch, type PerfFields } from "./telemetry.js";
import { supportDirectory } from "./platformPaths.js";

/**
 * Node agent harness HTTP surface per shared/protocol/protocol.md:
 * - GET  /health
 * - POST /instant                   (deterministic instant lane; synchronous)
 * - /dictionary, /dictionary/{learn,edit,recognizer-terms} (personal dictionary; synchronous)
 * - POST /invocations/prepare       (202; pre-builds the agent session for a take)
 * - POST /invoke                    (202, async processing)
 * - GET  /invocations/{id}          (execution status; polling)
 * - GET  /invocations/{id}/events   (SSE: the record on every change)
 * - settings: /models, /settings/{model,resources,routing,classifier}
 *
 * Instant-first (DESIGN4 §7 item 5): the agent stack (pi-coding-agent, pi-ai, the model catalog and the
 * Auto router, ~380 ms of imports) is not imported before listen(). It loads by dynamic import() in the
 * warm-up that follows the first response (normally the host's /health probe), so /health, /instant and
 * /dictionary/* serve at once; every route that needs it awaits the same promise (starting it if the
 * warm-up has not), and an import that fails answers 503 `harness_unreachable`.
 *
 * Bound to loopback only. All non-health routes require X-Harness-Token.
 * Logs carry ids, kinds, counts, durations and model ids only: never prompts,
 * transcripts, typed text, file names, dictionary entries or classifier inputs.
 */

/** The agent stack's modules, imported together after listen() (tests wrap it to hold the import back). */
export async function importAgentModules() {
  const [runner, catalog, autoModel, latency, profiles, piAi, computerUse, showResult, axTransport] = await Promise.all([
    import("./agent/agentRunner.js"),
    import("./agent/modelCatalog.js"),
    import("./agent/routing/autoModel.js"),
    import("./agent/routing/latencyStats.js"),
    import("./agent/routing/profiles.js"),
    import("@earendil-works/pi-ai"),
    import("./agent/computerUseExtension.js"),
    import("./ui/showResult.js"),
    import("./browser/axTransport.js"),
  ]);
  return {
    runner, catalog, autoModel, latency, profiles, axTransport,
    getSupportedThinkingLevels: piAi.getSupportedThinkingLevels,
    USE_ACTIVE_WINDOW_TOOL: computerUse.USE_ACTIVE_WINDOW_TOOL,
    SHOW_RESULT_TOOL: showResult.SHOW_RESULT_TOOL,
  };
}
export type AgentModules = Awaited<ReturnType<typeof importAgentModules>>;

/** The loaded agent stack: its modules plus what is built from them once. */
interface AgentStack {
  modules: AgentModules;
  stats: LatencyStats;
  services: AgentServices;
}

/**
 * The instant dispatcher's dependencies, including what the voice pipeline reads: the personal dictionary
 * (DictionaryLookup, DESIGN4 §6.3) and the take memo ("No, I meant X").
 */
type LaneDeps = InstantDispatcherDeps;

class RequestError extends Error {
  constructor(readonly status: number, message: string, readonly code?: string) { super(message); }
}

/**
 * Browsers mark their requests (Origin, Sec-Fetch-Site); the native hosts (URLSession, .NET
 * HttpClient, Node fetch) send neither. Refusing them stops a web page from driving the
 * loopback harness by CSRF, also in insecure-dev mode where no token is required.
 */
function fromBrowser(request: IncomingMessage): boolean {
  const site = request.headers["sec-fetch-site"];
  return request.headers.origin !== undefined || (site !== undefined && site !== "none");
}

interface InvokeBody {
  invocationId?: unknown;
  contextId?: unknown;
  prompt?: unknown;
  invokedAt?: unknown;
  retainSession?: unknown;
  takeId?: unknown;
  input?: unknown;
  context?: unknown;
  attachments?: unknown;
  workingDirectory?: unknown;
}

export interface HarnessServerOptions {
  onInvocation?: (record: InvocationRecord) => Promise<void>;
  /** Fixture injection; production always creates the isolated SDK session. */
  createSession?: (options: AgentRunOptions) => Promise<LiveAgentSession>;
  modelSettings?: AgentModelSettings;
  resourceSettings?: AgentResourceSettings;
  modelRuntimeFactory?: (trustedResources: boolean) => Promise<ModelRuntime>;
  /** Deterministic expiry clock for fixture tests. */
  now?: () => number;
  /** Where routing stats, classifier settings, logs and the rate cache live (default: next to settings.json). */
  supportDir?: string;
  routingSettings?: RoutingSettingsStore;
  classifierSettings?: ClassifierSettingsStore;
  /** Classifier factory overrides (tests: the fake Laya engine). Nothing starts unless enabled. */
  classifierDeps?: ClassifierFactoryDeps;
  latencyStats?: LatencyStats;
  /** Instant engine overrides (tests: rate fetcher, clock, app index …). */
  instant?: Partial<InstantDispatcherDeps>;
  /** Agent session collaborators (tests: in-process provider runtime, fixture agent dir). */
  agentServices?: Partial<AgentServices>;
  /** SSE keep-alive comment interval (default 15 s) and coalescing window (default 33 ms). */
  sseKeepAliveMs?: number;
  sseCoalesceMs?: number;
  /** Prepared-session lifetime (default 30 s). */
  prepareTtlMs?: number;
  /**
   * Host platform for per-host defaults (default process.platform; tests inject it): Auto is the default
   * on macOS only, only a macOS host's tool catalog is negotiated, and agent sessions get it as theirs.
   */
  platform?: NodeJS.Platform;
  /** The personal dictionary (default `<support>/dictionary.json`, loaded at construction). */
  dictionary?: DictionaryStore;
  /** The take memo (default in memory: 20 takes, 2 minutes). */
  takeMemo?: InMemoryTakeMemo;
  /** App frecency (default `<support>/instant-usage.json`): ranks app matches and recognizer terms. */
  frecency?: FrecencyStore & { load?(): Promise<void> };
  /** Tests: replaces the agent stack import (e.g. to hold it back or fail it). */
  loadAgentModules?: () => Promise<AgentModules>;
}

/** Bookkeeping for one in-flight invocation (A.3: cancel + timeout). */
interface RunningInvocation {
  controller: AbortController;
  timedOut: boolean;
  timer?: NodeJS.Timeout;
  /** (Re)arms the wall-clock limit in ms, counted from the invocation's start; 0 disables it. */
  limit(ms: number): void;
}

/** Per-turn request metadata that is not part of the record. */
interface TurnMeta {
  takeId?: string;
  input?: InvokeInput;
  /** The host's context for this turn (parseContext). Absent: legacy on a first turn, the thread's scope on a follow-up. */
  context?: ContextWire;
  /** Context-shelf attachments, validated against the captures dir and the request's context. */
  attachments?: Attachment[];
  /** Assistant responses this turn (telemetry: model turns per invocation). */
  responses?: number;
  /** /invoke `workingDirectory` (first turns only; a thread keeps its folder). User content: never logged or recorded. */
  workingDirectory?: string;
}

/** A session pre-built at key-down for one take (POST /invocations/prepare). */
interface PreparedTake {
  takeId: string;
  contextId: string;
  controller: AbortController;
  timer: NodeJS.Timeout;
  session?: Promise<LiveAgentSession | undefined>;
  /** The app the take was pinned on (a general turn names it when the window is gone by submit). */
  app?: string;
  /** The prepare's `workingDirectory` (full pi sessions): part of what the session is built from. Never logged. */
  workingDirectory?: string;
}

interface ThreadEntry {
  live?: LiveAgentSession;
  expires: number;
  readOnly?: boolean;
  /** The app of the thread's pin (a general follow-up names it when the window is gone). */
  app?: string;
}
const MAX_THREADS = 20;
const THREAD_TTL_MS = 30 * 60_000;
const MAX_PREPARED = 3;
const MAX_INSTANT_KEYS = 64;
const MAX_TAKE_HINTS = 32;
const HINTS_TTL_MS = 60_000;
const MAX_INSTANT_BODY = 4_096;
const MAX_SETTINGS_BODY = 16_384;
/** recognizer-terms waits this long for the host's app index when none is cached yet (hosts ask at launch and on a new
 * revision, never on the hotkey path; right after launch the host's index can take ≈ 0.5–1 s). */
const TERMS_APPS_WAIT_MS = 1_500;
/** A learn (a user gesture is waiting) waits this long for the app index. */
const LEARN_APPS_WAIT_MS = 300;
/** A learn's lane resolve (corrected text) never takes longer than the instant budget. */
const LEARN_RESOLVE_MS = 250;
/** Warm-up starts after the first response (the host's readiness probe), or after this long without one. */
const WARM_UP_FALLBACK_MS = 1_000;
/** Longest prefix of a prompt the telemetry rules score reads. */
const MAX_SCORED_CHARS = 4_000;
/** A 400 lists at most this many attachment issues (paths and codes only). */
const MAX_ATTACHMENT_ISSUES = 32;
const ID = /^[\w-]{1,128}$/;
const LOCALE = /^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,3}$/;
const ENGINE = /^[\w.-]{1,64}$/;
const INPUT_TOOLS = ["window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll"];
const LAUNCHER_READ_ROUTES = ["launcher.searchFiles", "launcher.listApps"];

/** Strict validation of POST /invoke `input`; never echoes values. */
function parseInvokeInput(value: unknown): { ok: true; input?: InvokeInput } | { ok: false; error: string } {
  if (value === undefined || value === null) return { ok: true };
  if (typeof value !== "object" || Array.isArray(value)) return { ok: false, error: "input must be an object" };
  const v = value as Record<string, unknown>;
  if (v.mode !== "text" && v.mode !== "voice") return { ok: false, error: "input.mode must be text or voice" };
  const input: InvokeInput = { mode: v.mode };
  if (v.confidence !== undefined) {
    if (typeof v.confidence !== "number" || !Number.isFinite(v.confidence) || v.confidence < 0 || v.confidence > 1) return { ok: false, error: "input.confidence must be 0..1" };
    input.confidence = v.confidence;
  }
  if (v.locale !== undefined) {
    if (typeof v.locale !== "string" || !LOCALE.test(v.locale)) return { ok: false, error: "input.locale must be a BCP 47 tag" };
    input.locale = v.locale;
  }
  if (v.durationMs !== undefined) {
    if (typeof v.durationMs !== "number" || !Number.isFinite(v.durationMs) || v.durationMs < 0 || v.durationMs > 3_600_000) return { ok: false, error: "input.durationMs must be 0..3600000" };
    input.durationMs = v.durationMs;
  }
  if (v.engine !== undefined) {
    if (typeof v.engine !== "string" || !ENGINE.test(v.engine)) return { ok: false, error: "input.engine must be a short identifier" };
    input.engine = v.engine;
  }
  return { ok: true, input };
}

type TurnContextParse =
  | { ok: true; context?: ContextWire; attachments?: Attachment[] }
  | { ok: false; error: string; issues?: AttachmentIssue[] };

/**
 * Strict `context` and `attachments` of /invoke and /followup (protocol.md "Context scope",
 * "Attachments"): image attachments must be shelf PNGs directly inside the captures directory and an
 * actionable window must be the request's own context. Errors name fields and issue codes, never values.
 */
function parseTurnContext(body: { context?: unknown; attachments?: unknown }, capturesDir: string, contextId: string): TurnContextParse {
  const context = parseContext(body.context);
  if (!context.ok) return { ok: false, error: context.error };
  const attachments = parseAttachments(body.attachments, { capturesDir, contextId });
  if (!attachments.ok) return { ok: false, error: "attachments are invalid", issues: attachments.issues.slice(0, MAX_ATTACHMENT_ISSUES) };
  return {
    ok: true,
    ...(context.context ? { context: context.context } : {}),
    ...(attachments.attachments?.length ? { attachments: attachments.attachments } : {}),
  };
}

/** Content-free label of the attachment kinds, e.g. "text+image" (telemetry). */
function attachmentKinds(attachments: readonly Attachment[] | undefined): string {
  return [...new Set((attachments ?? []).map(attachment => attachment.kind))].join("+") || "none";
}

/** desktop.getContext codes that say the pinned window itself is gone (not a permission or host problem). */
const WINDOW_GONE: ReadonlySet<string> = new Set(["target_gone", "no_target"]);

/**
 * The pinned window is gone (or unreadable) but the turn is general: it continues with no window at
 * all, naming only the app the take or thread was pinned on (never its title, path or screenshot).
 */
function windowlessSnapshot(contextId: string, app: string | undefined): DesktopContextSnapshot & { screenshot: null } {
  return {
    id: contextId, capturedAt: new Date().toISOString(), cursor: { x: 0, y: 0 },
    foregroundWindow: null, windowUnderCursor: null,
    targetWindow: app ? { hwnd: "", processId: 0, processName: app, title: "", bounds: { x: 0, y: 0, width: 0, height: 0 } } : null,
    monitors: [], screenshot: null,
  };
}

/**
 * The host's apps as recognizer strings: the short spoken name first ("Pages" for "Pages Creator Studio"),
 * then the full name. The measured DictationTranscriber gain (asr.md §5) used names plus their aliases;
 * the full name alone would never bias toward what Tom says ("open Pages").
 */
function spokenAppNames(apps: readonly AppRecord[]): { name: string; bundleId: string }[] {
  return apps.flatMap((app) => {
    const short = displayName(app);
    return short === app.name.trim() ? [{ name: app.name, bundleId: app.bundleId }] : [{ name: short, bundleId: app.bundleId }, { name: app.name, bundleId: app.bundleId }];
  });
}

/** A promise that settles with `promise`, or with undefined once `ms` passed (never rejects). */
function within<T>(promise: Promise<T>, ms: number): Promise<T | undefined> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(undefined), ms);
    timer.unref?.();
    promise.then((value) => { clearTimeout(timer); resolve(value); }, () => { clearTimeout(timer); resolve(undefined); });
  });
}

export class HarnessServer {
  private readonly threads = new Map<string, ThreadEntry>();
  private stopping = false;
  readonly invocations = new InvocationStore();
  private readonly running = new Map<string, RunningInvocation>();
  private readonly turns = new Map<string, TurnMeta>();
  private readonly prepared = new Map<string, PreparedTake>();
  /** Takes an invocation already used: a prepare that arrives late must not build an orphan session. */
  private readonly usedTakes = new Set<string>();
  /** Latest /instant request per take: its seq, the in-flight dispatch, and the seq of the take's final (if any). */
  private readonly instantLatest = new Map<string, { seq: number; finalSeq?: number; controller?: AbortController }>();
  private readonly hints = new Map<string, { hints: ClassifierHints; at: number }>();
  private readonly server: Server;
  /** Settings-page model choice applied to every new invocation. */
  private readonly modelSettings: AgentModelSettings;
  private readonly resourceSettings: AgentResourceSettings;
  private readonly routing: RoutingSettingsStore;
  private statsDirty = false;
  private readonly classifierSettings: ClassifierSettingsStore;
  private classifier: ManagedClassifier;
  private classifierRuntime?: Promise<ModelRuntime>;
  private readonly instantDeps: LaneDeps;
  /** /instant: may consult the advisory classifier on a grammar miss (≤ 250 ms). */
  private readonly instant: InstantDispatcher;
  /** /invoke: same engines, never waits on a classifier (agent hot path). */
  private readonly instantDirect: InstantDispatcher;
  private readonly supportDir: string;
  /** The agent stack once imported (agentStack()); undefined until then. */
  private stack?: AgentStack;
  private agentLoad?: Promise<AgentStack>;
  private warmUpStarted = false;
  private warmUpTimer?: NodeJS.Timeout;
  /** The strict card catalog (zod), imported on first use or by the warm-up, never before listen. */
  private validatorLoad?: Promise<typeof import("./ui/validate.js")>;
  /** The personal dictionary (Node is its single writer) and the take memo the learn route validates against. */
  readonly dictionary: DictionaryStore;
  readonly takeMemo: InMemoryTakeMemo;
  private readonly frecency: FrecencyStore;
  private readonly frecencyReady: Promise<void>;
  /** The host's app index as last fetched (recognizer terms, learn display names, installed checks). */
  private appIndex?: { apps: AppRecord[]; bundles: ReadonlySet<string> };
  /** How learning sees the instant lane: the grammar plus a dispatcher without classifier or file search. */
  private readonly lane: LearnLane;

  constructor(
    private readonly config: HarnessConfig = loadConfig(),
    private readonly options: HarnessServerOptions & { hostClient?: HostClient } = {},
  ) {
    this.modelSettings = options.modelSettings ?? new AgentModelSettings();
    this.resourceSettings = options.resourceSettings ?? new AgentResourceSettings();
    this.options.hostClient ??= new HostClient(config);
    // Every pi-os store lives next to settings.json (the support dir), also when tests inject it.
    this.supportDir = options.supportDir ?? (options.modelSettings ? dirname(this.modelSettings.filePath) : supportDirectory());
    this.routing = options.routingSettings ?? new RoutingSettingsStore(this.modelSettings.filePath);
    this.classifierSettings = options.classifierSettings ?? new ClassifierSettingsStore(join(this.supportDir, "classifier.json"));
    this.classifier = this.buildClassifier();
    this.takeMemo = options.takeMemo ?? new InMemoryTakeMemo();
    this.dictionary = options.dictionary ?? new DictionaryStore({ path: join(this.supportDir, "dictionary.json") });
    if (!options.dictionary) this.dictionary.load();
    this.dictionary.setInstalledCheck((bundleId) => (this.appIndex ? this.appIndex.bundles.has(bundleId) : undefined));
    const frecency = options.frecency ?? new FileFrecencyStore(join(this.supportDir, "instant-usage.json"));
    this.frecency = frecency;
    this.frecencyReady = (frecency.load?.() ?? Promise.resolve()).catch(() => {});

    const host = () => this.options.hostClient;
    const deps: LaneDeps = {
      fend: createFendLoader(),
      fx: new EcbRateStore({ file: join(this.supportDir, "cache", "fx-ecb.json"), enabled: () => this.config.fxRatesEnabled !== false }),
      apps: new AppIndexCache(async (signal) => {
        const client = host();
        if (typeof client?.listApps !== "function") throw new Error("unavailable");
        const index = await client.listApps(signal);
        if (Array.isArray(index?.apps)) {
          const apps = appRecords(index.apps);
          this.appIndex = { apps, bundles: new Set(apps.map((app) => app.bundleId)) };
        }
        return index;
      }, { frecency }),
      searchFiles: (request, signal) => {
        const client = host();
        return typeof client?.searchFiles === "function" ? client.searchFiles(request, signal) : Promise.reject(new Error("unavailable"));
      },
      // The take's desktop icons / target Finder window (macOS hosts that serve launcher.visibleItems). A host
      // without the route (404, not_found) is remembered as unsupported: the lane then decides as before.
      visibleItems: new VisibleItemsCache((request, signal) => {
        const client = host();
        return typeof client?.visibleItems === "function" ? client.visibleItems(request, signal) : Promise.reject(new LauncherRouteError("unsupported"));
      }),
      perf: (stage, ms, fields) => perfLog(stage, ms, fields),
      enabled: () => this.config.instantEnabled !== false,
      ...(config.webSearchTemplate ? { webSearchTemplate: () => config.webSearchTemplate! } : {}),
      dictionary: this.dictionary,
      takeMemo: this.takeMemo,
      ...options.instant,
    };
    this.instantDeps = deps;
    // The managed classifier is replaced on settings changes; the dispatcher always asks the current one.
    const current = (): ManagedClassifier => this.classifier;
    const advisory: IntentClassifier = {
      name: "advisory",
      get local() { return current().local !== false; },
      classify: (text: string, signal: AbortSignal) => current().classify(text, signal),
    };
    // Finals never wait on the classifier: hints that arrive later are remembered for the take's /invoke.
    // The rules scorer is wrapped so its ~50 ms regex warm-up runs after listen (warmUp), not here.
    this.instant = createInstantDispatcher({
      scorer: (text) => rulesContextScorer(text),
      ...this.instantDeps, classifier: advisory,
      onLateHints: (request, hints) => { if (request.takeId) this.rememberHints(request.takeId, hints); },
    });
    // /invoke answers pure results only (answerInstantly): app and file decisions can never answer
    // there, so it never calls the launcher read routes (which the Windows host does not have).
    // It never reports a `scope` either: the host's chip already decided before /invoke.
    // Neither it nor learning's lane below is a take: they never see the take memo, and a learned rule
    // that decides for them is not a use (only the host's /instant finals count, DESIGN4 §6.1 `uses`).
    const uncounted = nonCountingLookup(this.dictionary);
    const { apps: _apps, searchFiles: _searchFiles, takeMemo: _memo, visibleItems: _visible, ...direct } = this.instantDeps;
    this.instantDirect = createInstantDispatcher({ ...direct, dictionary: uncounted, scorer: NO_CONTEXT_SCORER });
    // Learning resolves corrected text through the lane itself, but never asks a classifier (text could
    // leave the machine) or the host's file search, and never reports a scope. The regression check
    // replays journal takes through it with and without the candidate rule.
    const { searchFiles: _search, takeMemo: _takes, visibleItems: _shown, ...learnDeps } = this.instantDeps;
    this.lane = createLearnLane({
      dispatcher: createInstantDispatcher({ ...learnDeps, dictionary: uncounted, scorer: NO_CONTEXT_SCORER }),
      apps: () => this.appIndex?.apps,
      dictionary: uncounted,
      isCommonWord,
    });

    this.server = createServer({ maxHeaderSize: 8192, requestTimeout: 10_000, headersTimeout: 5000 }, (request, response) => {
      void this.handle(request, response);
    });
  }

  listen(): Promise<number> {
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      // Loopback only; never bind 0.0.0.0 (protocol.md).
      this.server.listen(this.config.port, "127.0.0.1", () => {
        resolve((this.server.address() as { port: number }).port);
        // Instant-first: the port answers now; warm-up starts after the first response (see warmUp).
        this.warmUpTimer = setTimeout(() => this.warmUp(), WARM_UP_FALLBACK_MS);
        this.warmUpTimer.unref();
      });
    });
  }

  /**
   * Instant-first warm-up (DESIGN4 §7 item 5), once, after the first response was written (normally the
   * host's /health probe) or WARM_UP_FALLBACK_MS after listen. Each step holds the event loop (module
   * loading is synchronous), so the steps yield between each other: the context-scope regexes and the
   * calculator (no network) for the first keystroke, the router heuristics for the first prompt, then the
   * agent stack. A route that needs the agent earlier starts its import at once (agentStack()).
   */
  private warmUp(): void {
    if (this.warmUpStarted || this.stopping) return;
    this.warmUpStarted = true;
    if (this.warmUpTimer) clearTimeout(this.warmUpTimer);
    const yieldToRequests = () => new Promise<void>((resolve) => setImmediate(resolve));
    void (async () => {
      await yieldToRequests();
      await this.cardValidator().catch(() => {});
      await yieldToRequests();
      if (this.config.instantEnabled !== false) {
        warmContextScope();
        await yieldToRequests();
        await this.instant.warm().catch(() => {});
        await yieldToRequests();
      }
      classifyUtterance("warm");
      await yieldToRequests();
      if (!this.stopping) await this.agentStack().catch(() => {});
    })();
  }

  /**
   * The agent stack, imported once (DESIGN4 §7 item 5). Routes that need it await this; a failed import
   * rejects with 503 `harness_unreachable` and is retried by the next request that needs it.
   */
  private agentStack(): Promise<AgentStack> {
    if (!this.agentLoad) {
      const watch = new Stopwatch();
      const load = this.options.loadAgentModules ?? importAgentModules;
      this.agentLoad = load().then((modules) => {
        const stats = this.options.latencyStats ?? new modules.latency.LatencyStats({ path: join(this.supportDir, modules.latency.DEFAULT_STATS_FILE) });
        const services: AgentServices = {
          platform: this.options.platform ?? process.platform,
          routing: () => this.routing.get(),
          stats,
          engines: modules.runner.toolEnginesFrom(this.instant.engines),
          laya: () => this.classifier.sidecar,
          ...this.options.agentServices,
        };
        this.stack = { modules, stats, services };
        perfLog("harness.agent", watch.elapsed(), { ok: true });
        return this.stack;
      }, (error: unknown) => {
        this.agentLoad = undefined;
        // The error class only: module errors can quote paths.
        console.error(`[harness] agent stack failed to load kind=${error instanceof Error ? error.name : "unknown"}`);
        perfLog("harness.agent", watch.elapsed(), { ok: false });
        throw new RequestError(503, "The agent could not be loaded", "harness_unreachable");
      });
    }
    return this.agentLoad;
  }

  private cardValidator(): Promise<typeof import("./ui/validate.js")> {
    return this.validatorLoad ??= import("./ui/validate.js");
  }

  /** The loaded stack, for code that runs after a route awaited agentStack(). */
  private get agent(): AgentStack {
    if (!this.stack) throw new RequestError(503, "The agent is still loading", "harness_unreachable");
    return this.stack;
  }

  close(): Promise<void> {
    this.stopping = true;
    if (this.warmUpTimer) clearTimeout(this.warmUpTimer);
    for (const id of this.threads.keys()) void this.closeThread(id);
    for (const takeId of [...this.prepared.keys()]) this.discardPrepared(takeId, "shutdown");
    for (const entry of this.running.values()) {
      entry.controller.abort();
      if (entry.timer) clearTimeout(entry.timer);
    }
    for (const latest of this.instantLatest.values()) latest.controller?.abort();
    if (this.statsDirty) this.stack?.stats.flush();
    this.dictionary.flush();
    // stdin EOF for a Laya sidecar before the process exits (its exit hook is only the fallback).
    const classifier = this.classifier.dispose().catch(() => {});
    const server = new Promise<void>((resolve, reject) => {
      this.server.close((error) => (error ? reject(error) : resolve()));
      this.server.closeAllConnections();
    });
    return Promise.all([server, classifier]).then(() => {});
  }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    if (!this.warmUpStarted) response.once("finish", () => this.warmUp());
    try {
      const url = new URL(request.url ?? "/", "http://localhost");
      const route = `${request.method} ${url.pathname}`;

      if (route === "GET /health") {
        return this.json(response, 200, {
          service: "node-harness",
          version: "0.1.0",
          uptimeSeconds: Math.round(process.uptime()),
          // Non-secret spawn identity prevents readiness attaching to a different listener.
          sessionId: process.env.PI_OS_SESSION_ID,
        });
      }

      if (fromBrowser(request)) {
        return this.json(response, 403, { error: { code: "forbidden_origin", message: "Browser requests are not accepted" } });
      }

      if (!this.authorized(request)) {
        return this.json(response, 401, {
          error: { code: "unauthorized", message: "Missing or wrong X-Harness-Token" },
        });
      }

      if (route === "POST /instant") {
        await this.handleInstant(request, response);
        return;
      }

      if (url.pathname === "/dictionary" || url.pathname.startsWith("/dictionary/")) {
        await this.handleDictionary(route, url, request, response);
        return;
      }

      if (route === "POST /invocations/prepare") {
        await this.handlePrepare(request, response);
        return;
      }

      // Status reads, the event stream and cancel never need the agent stack.
      const eventsMatch = /^\/invocations\/([\w-]+)\/events$/.exec(url.pathname);
      if (request.method === "GET" && eventsMatch) {
        return this.streamEvents(eventsMatch[1]!, response);
      }

      const invocationMatch = /^\/invocations\/([\w-]+)$/.exec(url.pathname);
      if (request.method === "GET" && invocationMatch) {
        const record = this.invocations.get(invocationMatch[1] as string);
        if (!record) {
          return this.json(response, 404, {
            error: { code: "not_found", message: `Unknown invocation '${invocationMatch[1]}'` },
          });
        }
        return this.json(response, 200, record);
      }

      const cancelMatch = /^\/invocations\/([\w-]+)\/cancel$/.exec(url.pathname);
      if (request.method === "POST" && cancelMatch) {
        return this.handleCancel(cancelMatch[1] as string, response);
      }

      // Everything else runs on the agent stack (imported in the warm-up; at most its import time on a cold start).
      await this.agentStack();

      if (route === "POST /invoke") {
        await this.handleInvoke(request, response);
        return;
      }

      if (route === "GET /models") {
        // Catalog for the host settings page; 500s flow through handle().
        const { catalog, autoModel } = this.agent.modules;
        const models = await this.withModelRuntime(runtime => catalog.listAvailableModels(runtime));
        const stored = this.modelSettings.get();
        // macOS: no stored choice means Auto; report it as the effective selection while Auto is offered.
        // Elsewhere (Windows) Auto is opt-in: nothing stored is pi's own default, reported as null.
        const autoByDefault = (this.options.platform ?? process.platform) === "darwin";
        const current = stored ?? (models.length && autoByDefault
          ? { provider: autoModel.AUTO_PROVIDER, modelId: autoModel.AUTO_MODEL_ID, thinkingLevel: autoModel.thinkingLevelForBias(this.routing.get().bias) }
          : null);
        return this.json(response, 200, { models, current, ...(!stored && current ? { currentIsDefault: true } : {}) });
      }

      if (route === "GET /settings/resources") {
        return this.json(response, 200, { current: this.resourceSettings.get(), warning: TRUST_WARNING, status: await this.resourceStatus() });
      }
      if (route === "POST /settings/resources") {
        const body = await this.readJson(request) as { mode?: unknown; acknowledgeUnpinnedAccess?: unknown } | null;
        if (!body || !["isolated", "trustedGlobal"].includes(body.mode as string)
          || (body.mode === "trustedGlobal" && body.acknowledgeUnpinnedAccess !== true)) {
          return this.json(response, 400, { error: { code: "invalid_arguments", message: "mode and explicit trust acknowledgement are required" } });
        }
        if (body.mode === "trustedGlobal" && (this.config.readOnly || !(await this.hostAllowsInput()))) {
          return this.json(response, 409, { error: { code: "control_disabled", message: "Trusted compatibility requires the signed native host's computer-control permissions first" } });
        }
        const previous = this.resourceSettings.get().mode;
        const current = this.resourceSettings.set(body.mode as "isolated" | "trustedGlobal", body.acknowledgeUnpinnedAccess === true);
        // A mode change reloads the guard status (the extensions may have changed while it was off).
        if (current.mode !== previous) this.stack?.modules.runner.forgetGlobalBashGuards();
        return this.json(response, 200, { current });
      }

      if (route === "POST /settings/model") {
        await this.handleSetModel(request, response);
        return;
      }

      if (route === "GET /settings/routing") {
        return this.json(response, 200, this.routing.get());
      }
      if (route === "POST /settings/routing") {
        await this.handleSetRouting(request, response);
        return;
      }

      if (route === "GET /settings/classifier") {
        return this.json(response, 200, { ...this.classifierSettings.get(), status: this.classifierStatus() });
      }
      if (route === "POST /settings/classifier") {
        await this.handleSetClassifier(request, response);
        return;
      }

      const followupMatch = /^\/invocations\/([\w-]+)\/followup$/.exec(url.pathname);
      if (request.method === "POST" && followupMatch) {
        return await this.handleFollowup(followupMatch[1]!, request, response);
      }
      const closeMatch = /^\/invocations\/([\w-]+)\/close$/.exec(url.pathname);
      if (request.method === "POST" && closeMatch) {
        const id = closeMatch[1]!;
        this.running.get(id)?.controller.abort();
        await this.closeThread(id);
        return this.json(response, 200, { closed: true, invocationId: id });
      }
      this.json(response, 404, { error: { code: "not_found", message: `No route: ${route}` } });
    } catch (error) {
      if (response.headersSent) { response.end(); return; }
      const status = error instanceof RequestError ? error.status : error instanceof SyntaxError ? 400 : 500;
      this.json(response, status, {
        error: {
          code: error instanceof RequestError && error.code ? error.code : status < 500 ? "invalid_arguments" : "internal_error",
          message: error instanceof Error ? error.message : String(error),
        },
      });
    }
  }

  // ------------------------------------------------------------------ instant lane

  /**
   * POST /instant: synchronous, latest-wins per take (or context). A newer seq aborts the
   * older dispatch (it answers fallthrough "timeout"); a request older than the newest seen
   * answers that immediately. The final wins: once a take's final arrived, a late typing/partial
   * request for it (debounce timer, reordered connection) is stale and never aborts it.
   * Requests with neither takeId nor contextId are independent. Node never performs effects:
   * `act` carries a HostAction.
   *
   * Bodies are parsed strictly (contracts `parseInstantRequest`): `hypotheses` reach the lane on a voice
   * final only, `accept` always. Every take's final is remembered in the take memo (what was heard, offered
   * and acted on) for POST /dictionary/learn, and an app the host opens without asking counts as usage.
   */
  private async handleInstant(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const parsed = parseInstantRequest(await this.readJson(request, MAX_INSTANT_BODY));
    if (!parsed.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: parsed.error } });
    const body = parsed.value;
    // Hypotheses belong to a voice final (protocol.md); anywhere else they are validated and ignored.
    if (body.hypotheses && !(body.phase === "final" && body.inputMode === "voice")) delete body.hypotheses;
    const key = body.takeId ?? body.contextId;
    const latest = key === undefined ? undefined : this.instantLatest.get(key);
    const final = body.phase === "final";
    const stale = latest && (final
      ? latest.finalSeq !== undefined && body.seq < latest.finalSeq
      : latest.finalSeq !== undefined || body.seq < latest.seq);
    if (stale) {
      return this.json(response, 200, { seq: body.seq, elapsedMs: 0, source: "grammar", decision: "fallthrough", reason: "timeout" });
    }
    latest?.controller?.abort();
    const controller = new AbortController();
    if (key !== undefined) {
      this.instantLatest.delete(key);
      this.instantLatest.set(key, {
        seq: Math.max(body.seq, latest?.seq ?? 0), controller,
        ...(final ? { finalSeq: body.seq } : latest?.finalSeq !== undefined ? { finalSeq: latest.finalSeq } : {}),
      });
      if (this.instantLatest.size > MAX_INSTANT_KEYS) {
        const oldest = this.instantLatest.keys().next().value;
        if (oldest !== undefined) this.instantLatest.delete(oldest);
      }
    }
    response.once("close", () => { if (!response.writableFinished) controller.abort(); });
    const raw = await this.instant.dispatch(body, controller.signal);
    const result = this.checkInstantFill(body, await this.checkInstantCard(raw));
    const entry = key === undefined ? undefined : this.instantLatest.get(key);
    if (entry?.controller === controller) delete entry.controller;
    // Advisory hints that arrived for this take; /invoke may fuse them (never waits for them).
    if (result.decision === "fallthrough" && result.hints && body.takeId) this.rememberHints(body.takeId, result.hints);
    // A superseded dispatch answered "timeout": the newer final is the one to remember.
    if (final && !controller.signal.aborted) this.rememberTake(body, result, takeDetailsOf(raw));
    this.json(response, 200, result);
  }

  /** The take memo entry for a final, and app usage for an app the host opens without asking. */
  private rememberTake(body: Parameters<InstantDispatcher["dispatch"]>[0], result: InstantResponse, details: ReturnType<typeof takeDetailsOf>): void {
    try {
      const record = takeRecordFor(body, result, Date.now(), details);
      if (record) this.takeMemo.remember(record);
      if (result.decision === "act" && !result.confirm && result.action.type === "openApp") this.recordAppUse(result.action.bundleId);
    } catch {
      // The memo and frecency are conveniences; the decision is already made.
    }
  }

  private recordAppUse(bundleId: string): void {
    void this.frecencyReady.then(() => this.frecency.record?.(bundleId, Date.now()));
  }

  // ------------------------------------------------------------------ personal dictionary

  /**
   * /dictionary/* (protocol.md "Personal dictionary"): token-authed like /instant, synchronous, never on
   * the agent stack, and no agent tool reaches them. Log lines carry the kind, status and code only.
   */
  private async handleDictionary(route: string, url: URL, request: IncomingMessage, response: ServerResponse): Promise<void> {
    const watch = new Stopwatch();
    switch (route) {
      case "GET /dictionary":
        return this.json(response, 200, this.dictionary.document());
      case "GET /dictionary/recognizer-terms": {
        const max = parseRecognizerTermsMax(url.searchParams.get("max"));
        if (!max.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: max.error } });
        // The host fetches terms rarely (revision changes, launch): wait briefly for the app index once.
        if (!this.appIndex && this.instantDeps.apps) await within(this.instantDeps.apps.refresh(), TERMS_APPS_WAIT_MS);
        const terms = this.dictionary.recognizerTerms(max.value, {
          ...(this.appIndex ? { apps: spokenAppNames(this.appIndex.apps) } : {}),
          frecency: (bundleId) => this.frecency.score(bundleId, Date.now()),
        });
        // Without the host's app index the list would hold a few learned words and no app names, and a host keeps a
        // non-empty list for the whole session: answer none, which hosts read as "not ready" and ask again shortly.
        if (!this.appIndex && this.instantDeps.apps) {
          perfLog("dictionary.terms", watch.elapsed(), { count: 0, max: max.value, apps: false });
          return this.json(response, 200, { revision: terms.revision, terms: [] });
        }
        perfLog("dictionary.terms", watch.elapsed(), { count: terms.terms.length, max: max.value });
        return this.json(response, 200, terms);
      }
      case "POST /dictionary/learn": {
        const parsed = parseLearnRequest(await this.readJson(request, DICTIONARY_LIMITS.learnBodyBytes));
        if (!parsed.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: parsed.error } });
        // The lane may need the app index to name or check the app (it is usually cached by the take's /instant).
        if (!this.appIndex && this.instantDeps.apps) await within(this.instantDeps.apps.refresh(), LEARN_APPS_WAIT_MS);
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), LEARN_RESOLVE_MS);
        timer.unref?.();
        try {
          const result = await learnFromGesture(parsed.value, {
            store: this.dictionary, memo: this.takeMemo, lane: this.lane, recordUse: (bundleId) => this.recordAppUse(bundleId),
          }, controller.signal);
          perfLog("dictionary.learn", watch.elapsed(), { kind: parsed.value.kind, ...outcomeFields(result) });
          return this.json(response, 200, result);
        } finally {
          clearTimeout(timer);
        }
      }
      case "POST /dictionary/edit": {
        const parsed = parseEditRequest(await this.readJson(request, DICTIONARY_LIMITS.bodyBytes));
        if (!parsed.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: parsed.error } });
        const result = applyEdit(parsed.value, { store: this.dictionary, lane: this.lane, onReset: () => this.takeMemo.clear() });
        perfLog("dictionary.edit", watch.elapsed(), { op: parsed.value.op, ...outcomeFields(result) });
        return this.json(response, 200, result);
      }
      default:
        return this.json(response, 404, { error: { code: "not_found", message: `No route: ${route}` } });
    }
  }

  /**
   * Defense in depth for continuity (protocol.md "Continuity"; the dispatcher already decides this way): a fill goes
   * only to a final that declared `fill` and sent a ready `target.field` it may type into, as one line
   * (`fillActConsistent`), with `submit` only where the contract allows Return; no other act carries `submit`; a
   * check card's fill offer only to such a request. A fill that fails becomes a plain miss, an offer that fails is
   * dropped from the card. The warning names the field kind only.
   */
  private checkInstantFill(request: InstantRequest, response: InstantResponse): InstantResponse {
    const field = request.target?.field;
    const kind = field?.kind;
    const fillable = request.phase === "final" && accepts(request, "fill") && kind !== undefined && field?.ready === true
      && !(FILL_NEVER_KINDS as readonly string[]).includes(kind);
    if (response.decision === "act") {
      const fill = response.intent === "fill";
      const submit = response.action.type === "typeIntoPinned" && response.action.submit === true;
      if (fillActConsistent(response.intent, response.action) && (!fill || (fillable && (!submit || fillSubmitAllowed(kind!, false))))) return response;
      console.warn(`[instant] dropped an inconsistent fill act field=${kind ?? "none"}`);
      return {
        seq: response.seq, elapsedMs: response.elapsedMs, source: response.source,
        ...(response.scope ? { scope: response.scope } : {}), decision: "fallthrough", reason: "no_match",
      };
    }
    if (response.decision === "fallthrough" && response.voice?.fill !== undefined && !(fillable && response.voice.check === true)) {
      const { fill: _offer, ...voice } = response.voice;
      console.warn(`[instant] dropped a fill offer field=${kind ?? "none"}`);
      return { ...response, voice };
    }
    return response;
  }

  /** Defense in depth: every instant card must pass the strict catalog check before a host sees it. */
  private async checkInstantCard(response: InstantResponse): Promise<InstantResponse> {
    const card = "card" in response ? response.card : undefined;
    if (!card) return response;
    const { validateCard } = await this.cardValidator();
    const checked = validateCard(card, { mode: "strict", allowedActions: HOST_ACTION_TYPES });
    if (checked.ok) return response;
    console.warn(`[instant] dropped an invalid card issues=${checked.issues.length} first=${checked.issues[0]?.code ?? "?"}`);
    if (response.decision === "act") {
      const { card: _dropped, ...rest } = response;
      return rest;
    }
    return {
      seq: response.seq, elapsedMs: response.elapsedMs, source: response.source,
      ...(response.scope ? { scope: response.scope } : {}), decision: "fallthrough", reason: "no_match",
    };
  }

  private rememberHints(takeId: string, hints: ClassifierHints): void {
    this.hints.delete(takeId);
    this.hints.set(takeId, { hints, at: this.now() });
    if (this.hints.size > MAX_TAKE_HINTS) {
      const oldest = this.hints.keys().next().value;
      if (oldest !== undefined) this.hints.delete(oldest);
    }
  }

  private takeHints(takeId: string | undefined): ClassifierHints | undefined {
    if (!takeId) return undefined;
    const entry = this.hints.get(takeId);
    this.hints.delete(takeId);
    if (!entry || this.now() - entry.at > HINTS_TTL_MS) return undefined;
    // Zero-shot Laya is uncalibrated (≈ 50 % intent accuracy): until a fine-tune passes the
    // promotion gates it may only ask for the screenshot, never raise the tier by label.
    if (entry.hints.source === "laya" && this.classifier.status().laya?.model?.calibrated !== true) {
      const { intent: _intent, intentP: _intentP, tier: _tier, tierP: _tierP, ...screenOnly } = entry.hints;
      return screenOnly;
    }
    return entry.hints;
  }

  // ------------------------------------------------------------------ prepared sessions

  /**
   * POST /invocations/prepare {contextId, takeId[, cancel]}: warm the instant engines and,
   * in agent mode, pre-build the take's session (runtime, resources, Auto). Best effort:
   * always 202; /invoke with the same takeId + contextId adopts it if nothing changed.
   */
  private async handlePrepare(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = await this.readJson(request, MAX_INSTANT_BODY) as { contextId?: unknown; takeId?: unknown; cancel?: unknown; workingDirectory?: unknown } | null;
    if (typeof body?.takeId !== "string" || !ID.test(body.takeId)) {
      return this.json(response, 400, { error: { code: "invalid_arguments", message: "takeId is required" } });
    }
    if (body.cancel === true) {
      this.discardPrepared(body.takeId, "cancel");
      return this.json(response, 200, { cancelled: true, takeId: body.takeId });
    }
    if (typeof body.contextId !== "string" || !ID.test(body.contextId)) {
      return this.json(response, 400, { error: { code: "invalid_arguments", message: "contextId and takeId are required" } });
    }
    // The issue code only, never the value (a cancel above ignores the key).
    const workingDirectory = parseWorkingDirectory(body.workingDirectory);
    if (!workingDirectory.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: workingDirectory.error } });
    this.json(response, 202, { accepted: true, takeId: body.takeId });
    this.prepareTake(body.contextId, body.takeId, workingDirectory.workingDirectory);
  }

  private prepareTake(contextId: string, takeId: string, workingDirectory?: string): void {
    const existing = this.prepared.get(takeId);
    if ((existing?.contextId === contextId && existing.workingDirectory === workingDirectory) || this.stopping || this.usedTakes.has(takeId)) return;
    if (existing) this.discardPrepared(takeId, "replaced");
    // No network: fend compile + rate cache; the host app index makes the first "open X" warm.
    if (this.config.instantEnabled !== false) {
      void this.instant.warm();
      void this.instantDeps.apps?.refresh();
    }
    if (this.classifier.kind === "laya") this.classifier.warm();
    while (this.prepared.size >= MAX_PREPARED) {
      const oldest = this.prepared.keys().next().value;
      if (oldest === undefined) break;
      this.discardPrepared(oldest, "evicted");
    }
    const take: PreparedTake = {
      takeId, contextId, controller: new AbortController(),
      timer: setTimeout(() => this.discardPrepared(takeId, "expired"), this.options.prepareTtlMs ?? 30_000),
      ...(workingDirectory !== undefined ? { workingDirectory } : {}),
    };
    take.timer.unref();
    this.prepared.set(takeId, take);
    if (this.config.agentEnabled && !this.options.onInvocation) take.session = this.buildPrepared(take).catch(() => undefined);
  }

  private async buildPrepared(take: PreparedTake): Promise<LiveAgentSession | undefined> {
    const watch = new Stopwatch();
    const signal = take.controller.signal;
    const host = this.options.hostClient!;
    // Prepare answers 202 at once; the session waits for the agent stack (instant-first start).
    const { runner } = (await this.agentStack()).modules;
    if (signal.aborted || this.stopping) return undefined;
    const outcome = await host.getSnapshot(take.contextId, signal);
    if (!outcome.ok) {
      console.log(`[prepare] no session: context ${outcome.error.code}`);
      return undefined;
    }
    if (outcome.result.targetWindow?.processName) take.app = outcome.result.targetWindow.processName;
    const { readOnly, launcher } = await this.negotiate(signal);
    const options: AgentRunOptions = {
      ...this.runOptions({ contextId: take.contextId, prompt: "" }, outcome.result, readOnly, launcher, signal, undefined, {}),
      ...(take.workingDirectory !== undefined ? { workingDirectory: take.workingDirectory } : {}),
    };
    // A full pi session in (or through a link into) a privacy-protected folder is built at /invoke: reading its
    // project context now could show a privacy prompt at key-down.
    if (await runner.defersPreparation(options)) {
      console.log("[prepare] no session: deferred to invoke");
      return undefined;
    }
    const live = await (this.options.createSession ?? runner.createLiveSession)(options);
    // Discarded (expiry, cancel, replacement, shutdown) while building. Adoption does not abort.
    if (signal.aborted || this.stopping) {
      await live.close();
      return undefined;
    }
    perfLog("prepare.session", watch.elapsed(), {});
    return live;
  }

  private discardPrepared(takeId: string, reason: string): void {
    const take = this.prepared.get(takeId);
    if (!take) return;
    this.prepared.delete(takeId);
    clearTimeout(take.timer);
    take.controller.abort();
    void take.session?.then(live => live?.close());
    console.log(`[prepare] discarded reason=${reason}`);
  }

  /** The take's prepared session when it was built for exactly this context and setup; otherwise none. */
  private async adoptPrepared(takeId: string | undefined, options: AgentRunOptions): Promise<LiveAgentSession | undefined> {
    if (!takeId) return undefined;
    this.usedTakes.add(takeId);
    if (this.usedTakes.size > MAX_INSTANT_KEYS) {
      const oldest = this.usedTakes.values().next().value;
      if (oldest !== undefined) this.usedTakes.delete(oldest);
    }
    const take = this.prepared.get(takeId);
    if (!take) return undefined;
    this.prepared.delete(take.takeId);
    clearTimeout(take.timer);
    const live = take.contextId === options.contextId ? await take.session : undefined;
    if (live && !live.isClosed && live.controls.setupKey === this.agent.modules.runner.sessionSetupKey(options)) return live;
    take.controller.abort();
    void take.session?.then(stale => stale?.close());
    console.log(`[prepare] discarded reason=${live ? "mismatch" : "unavailable"}`);
    return undefined;
  }

  // ------------------------------------------------------------------ invocations

  private async handleInvoke(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = (await this.readJson(request)) as InvokeBody | null;
    if (!body || typeof body !== "object") {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "Body must be a JSON object" },
      });
    }

    const { contextId, prompt } = body;
    if (typeof contextId !== "string" || typeof prompt !== "string" || !prompt.trim() || prompt.length > 20_000
      || (body.retainSession !== undefined && typeof body.retainSession !== "boolean")) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "contextId (string) and prompt (non-empty string) are required" },
      });
    }

    if (body.invocationId !== undefined && (typeof body.invocationId !== "string"
      || !/^[\w-]{1,128}$/.test(body.invocationId))) {
      return this.json(response, 400, { error: { code: "invalid_arguments", message: "Invalid invocationId" } });
    }
    if (body.takeId !== undefined && (typeof body.takeId !== "string" || !ID.test(body.takeId))) {
      return this.json(response, 400, { error: { code: "invalid_arguments", message: "Invalid takeId" } });
    }
    const input = parseInvokeInput(body.input);
    if (!input.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: input.error } });
    const scoped = parseTurnContext(body, this.config.capturesDir, contextId);
    if (!scoped.ok) return this.invalidTurnContext(response, scoped);
    // Full pi sessions only (the macOS host sends it while full mode is on); the issue code only, never the value.
    const workingDirectory = parseWorkingDirectory(body.workingDirectory);
    if (!workingDirectory.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: workingDirectory.error } });
    if (typeof body.invocationId === "string" && this.invocations.get(body.invocationId)) {
      return this.json(response, 409, { error: { code: "duplicate_invocation", message: "Invocation already exists; it was not re-executed" } });
    }

    this.expireThreads();
    if (body.retainSession === true && this.threads.size >= MAX_THREADS) {
      return this.json(response, 409, { error: { code: "thread_limit", message: "Close an existing reader before starting another thread" } });
    }
    const record = this.invocations.create(
      contextId,
      prompt,
      typeof body.invokedAt === "string" ? body.invokedAt : new Date().toISOString(),
      typeof body.invocationId === "string" ? body.invocationId : undefined,
    );
    if (input.input) this.invocations.setInput(record.invocationId, { mode: input.input.mode });
    // Content-free from the start: the host's scope (pulled until the agent looks) and attachment summaries.
    if (scoped.context) this.invocations.setContext(record.invocationId, requestedContextRecord(scoped.context));
    if (scoped.attachments) this.invocations.setAttachments(record.invocationId, summarizeAttachments(scoped.attachments));
    this.turns.set(record.invocationId, {
      ...(typeof body.takeId === "string" ? { takeId: body.takeId } : {}),
      ...(input.input ? { input: input.input } : {}),
      ...(scoped.context ? { context: scoped.context } : {}),
      ...(scoped.attachments ? { attachments: scoped.attachments } : {}),
      ...(workingDirectory.workingDirectory !== undefined ? { workingDirectory: workingDirectory.workingDirectory } : {}),
    });

    if (body.retainSession === true) this.threads.set(record.invocationId, { expires: this.now() + THREAD_TTL_MS });
    console.log(`[invoke] id=${record.invocationId}`);
    console.log(`[invoke] invokedAt=${record.invokedAt}`);

    this.json(response, 202, { accepted: true, invocationId: record.invocationId });

    // Async processing after the 202 is out.
    void this.processInvocation(record);
  }

  /** POST /settings/model — validate + store the settings-page model choice.
   *  Validation uses the live pi catalog so unauthenticated/unknown models are
   *  rejected here instead of failing an invocation later. Auto is always valid. */
  private async handleSetModel(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = (await this.readJson(request)) as Partial<ModelSelection> | null;
    const { provider, modelId, thinkingLevel } = body ?? {};
    if (typeof provider !== "string" || typeof modelId !== "string"
      || typeof thinkingLevel !== "string" || !provider || !modelId || !thinkingLevel) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: "provider, modelId and thinkingLevel (non-empty strings) are required" },
      });
    }

    const { autoModel, getSupportedThinkingLevels } = this.agent.modules;
    const selection = { provider, modelId, thinkingLevel };
    const auto = autoModel.isAutoSelection(selection);
    const supported = auto
      ? [...autoModel.AUTO_THINKING_LEVELS] as string[]
      : await (async () => {
        const available = await this.withModelRuntime(runtime => runtime.getAvailable());
        const model = available.find(model => model.provider === provider && model.id === modelId);
        return model ? getSupportedThinkingLevels(model) as string[] : undefined;
      })();
    if (!supported) {
      return void this.json(response, 400, {
        error: { code: "invalid_arguments", message: `model ${provider}/${modelId} is not available in the pi catalog` },
      });
    }
    if (!supported.includes(thinkingLevel)) {
      return void this.json(response, 400, {
        error: {
          code: "invalid_arguments",
          message: `model ${provider}/${modelId} supports effort levels [${supported.join(", ")}], got '${thinkingLevel}'`,
        },
      });
    }

    const previous = this.modelSettings.set(selection);
    // Auto's level IS the routing bias; keep GET /settings/routing in step with the picker.
    if (auto) this.routing.set({ bias: autoModel.biasForThinkingLevel(thinkingLevel) });
    const describe = (s: ModelSelection | null) =>
      s ? `${s.provider}/${s.modelId} effort=${s.thinkingLevel}` : "Auto (default)";
    console.log(`[settings] model switched: ${describe(previous)} -> ${describe(selection)}`);

    return this.json(response, 200, { current: selection });
  }

  /** POST /settings/routing — strict patch; tier overrides must name available models. */
  private async handleSetRouting(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const checked = validateRoutingPatch(await this.readJson(request, MAX_SETTINGS_BODY));
    if (!checked.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: checked.error } });
    const { autoModel, profiles } = this.agent.modules;
    const overrides = checked.patch.tierOverrides;
    if (overrides && Object.values(overrides).some(Boolean)) {
      const available = await this.withModelRuntime(runtime => runtime.getAvailable());
      const problem = validateTierOverrides(overrides, profiles.buildRoutingCatalog(available).candidates);
      if (problem) return this.json(response, 400, { error: { code: "invalid_arguments", message: problem } });
    }
    const next = this.routing.set(checked.patch);
    const stored = this.modelSettings.get();
    if (checked.patch.bias && stored && autoModel.isAutoSelection(stored)) {
      this.modelSettings.set({ ...stored, thinkingLevel: autoModel.thinkingLevelForBias(checked.patch.bias) });
    }
    return this.json(response, 200, next);
  }

  /** POST /settings/classifier — strict body; the classifier is rebuilt (nothing starts until used). */
  private async handleSetClassifier(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const parsed = parseClassifierSettings(await this.readJson(request, MAX_SETTINGS_BODY));
    if (!parsed.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: parsed.error } });
    const saved = this.classifierSettings.set(parsed.settings);
    const previous = this.classifier;
    this.classifier = this.buildClassifier();
    await previous.dispose().catch(() => {});
    return this.json(response, 200, { ...saved, status: this.classifierStatus() });
  }

  /**
   * The classifier status plus `layaLaunch`: whether Laya could start with the stored paths
   * (for every kind, so Settings can say what is missing before the switch is turned on).
   * Only existence checks; nothing is spawned and no path is reported.
   */
  private classifierStatus(): ReturnType<ManagedClassifier["status"]> & { layaLaunch: { ok: boolean; reason?: LayaLaunchReason | "disabled_by_env" } } {
    const deps = this.options.classifierDeps ?? {};
    const env = deps.env ?? process.env;
    let layaLaunch: { ok: boolean; reason?: LayaLaunchReason | "disabled_by_env" };
    if (env.PI_OS_LAYA === "0" && !deps.fakeEngine) layaLaunch = { ok: false, reason: "disabled_by_env" };
    else {
      const resolved = resolveLayaLaunch(this.classifierSettings.get(), env, deps.exists, deps.supportDir ?? this.supportDir);
      layaLaunch = resolved.ok ? { ok: true } : { ok: false, reason: resolved.reason };
    }
    return { ...this.classifier.status(), layaLaunch };
  }

  private buildClassifier(): ManagedClassifier {
    return createClassifier(this.classifierSettings.get(), {
      supportDir: this.supportDir,
      // Kind "pi" only: one lazily created runtime per process (on the agent stack, imported after listen).
      modelRuntime: () => (this.classifierRuntime ??= this.agentStack().then(stack => stack.modules.catalog.createModelCatalogContext(false)).then(context => context.runtime)),
      ...this.options.classifierDeps,
    });
  }

  /**
   * GET /settings/resources `status` (protocol.md "Full pi session (macOS)"), content-free. Full sessions are on for a
   * macOS host with `trustedGlobal` stored, no read-only launch and the native input routes. Only then are the global
   * extensions loaded and classified (globalBashGuard), once per process until the resource mode or the agent dir's
   * extensions change (cachedGlobalBashGuard); isolated mode never runs their code for this.
   */
  private async resourceStatus(): Promise<ResourceStatus> {
    const off: ResourceStatus = { fullSession: false, guard: "none" };
    const mode = this.resourceSettings.get().mode;
    // Off: the next full-mode status loads the global extensions again (they may change meanwhile).
    if (mode !== "trustedGlobal") this.stack?.modules.runner.forgetGlobalBashGuards();
    if ((this.options.platform ?? process.platform) !== "darwin" || this.config.readOnly || mode !== "trustedGlobal") return off;
    if (!(await this.hostAllowsInput().catch(() => false))) return off;
    let guard: BashGuard = "none";
    try { guard = await this.agent.modules.runner.cachedGlobalBashGuard(this.agent.services.agentDir); }
    catch { /* Extensions that cannot load guard nothing; Settings then warns. */ }
    return { fullSession: true, guard };
  }

  private async hostAllowsInput(signal?: AbortSignal): Promise<boolean> {
    const tools = await this.options.hostClient!.getToolNames(signal);
    return INPUT_TOOLS.every(name => tools.includes(name));
  }

  /**
   * A warm Mac child may outlive permission/settings changes, so each session negotiates the
   * host's actual catalog: native input (else read-only) and the launcher read routes. Windows
   * keeps its fixed contract (no discovery, no launcher routes).
   */
  private async negotiate(signal?: AbortSignal): Promise<{ readOnly: boolean; launcher: boolean }> {
    let readOnly = this.config.readOnly ?? false;
    if ((this.options.platform ?? process.platform) !== "darwin") return { readOnly, launcher: false };
    let names: string[] = [];
    try {
      names = await this.options.hostClient!.getToolNames(signal);
    } catch (error) {
      if (!readOnly) throw error;
    }
    if (!readOnly) readOnly = !INPUT_TOOLS.every(name => names.includes(name));
    return { readOnly, launcher: LAUNCHER_READ_ROUTES.every(name => names.includes(name)) };
  }

  private async withModelRuntime<T>(use: (runtime: ModelRuntime) => Promise<T>): Promise<T> {
    const trusted = this.resourceSettings.get().mode === "trustedGlobal" && !this.config.readOnly && await this.hostAllowsInput();
    if (this.options.modelRuntimeFactory) return use(await this.options.modelRuntimeFactory(trusted));
    const sidecar = this.classifier.sidecar;
    const context = await this.agent.modules.catalog.createModelCatalogContext(trusted, sidecar ? { laya: sidecar } : {});
    try { return await use(context.runtime); } finally { context.dispose(); }
  }

  /** 400 for a bad `context` or `attachments`: the field, or `details.issues` ({path, code}), never a value. */
  private invalidTurnContext(response: ServerResponse, parsed: Extract<TurnContextParse, { ok: false }>): void {
    this.json(response, 400, { error: { code: "invalid_arguments", message: parsed.error, ...(parsed.issues ? { details: { issues: parsed.issues } } : {}) } });
  }

  /** POST /invocations/{id}/cancel — request cancellation of a running invocation. */
  private handleCancel(id: string, response: ServerResponse): void {
    if (!this.invocations.get(id)) {
      return this.json(response, 404, {
        error: { code: "not_found", message: `Unknown invocation '${id}'` },
      });
    }

    const entry = this.running.get(id);
    if (!entry || entry.controller.signal.aborted) {
      return this.json(response, 409, {
        error: { code: "not_running", message: `Invocation '${id}' is not running` },
      });
    }

    console.log(`[invoke] cancel requested id=${id}`);
    entry.controller.abort();
    this.json(response, 202, { accepted: true, invocationId: id });
  }

  private async closeThread(id: string): Promise<void> {
    const thread = this.threads.get(id);
    this.threads.delete(id); // Revoke before awaiting cleanup; startup cannot resurrect it.
    this.invocations.setFollowupAvailable(id, false);
    await thread?.live?.close();
  }
  private expireThreads(): void {
    for (const [id, thread] of this.threads) {
      if (thread.expires <= this.now() && !this.running.has(id)) void this.closeThread(id);
    }
  }
  private async handleFollowup(id: string, request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = await this.readJson(request) as { prompt?: unknown; input?: unknown; context?: unknown; attachments?: unknown } | null;
    if (typeof body?.prompt !== "string" || !body.prompt.trim() || body.prompt.length > 20_000) {
      return this.json(response, 400, { error: { code: "invalid_arguments", message: "A nonempty prompt of at most 20,000 characters is required" } });
    }
    const input = parseInvokeInput(body.input);
    if (!input.ok) return this.json(response, 400, { error: { code: "invalid_arguments", message: input.error } });
    this.expireThreads();
    const record = this.invocations.get(id);
    if (!record) return this.json(response, 404, { error: { code: "not_found", message: "Unknown invocation" } });
    // The thread keeps its pin: an actionable window attachment must name the thread's own context.
    const scoped = parseTurnContext(body ?? {}, this.config.capturesDir, record.contextId);
    if (!scoped.ok) return this.invalidTurnContext(response, scoped);
    if (this.running.has(id) || record.state === "queued" || record.state === "running") {
      return this.json(response, 409, { error: { code: "not_idle", message: "The previous prompt is still running; follow-ups are sequential" } });
    }
    if (!this.threads.has(id)) return this.json(response, 404, { error: { code: "session_closed", message: "The thread ended or expired. Start a new task" } });
    if (!this.invocations.requeueForFollowup(id, body.prompt.trim())) return;
    if (input.input) this.invocations.setInput(id, { mode: input.input.mode });
    if (scoped.attachments) this.invocations.setAttachments(id, summarizeAttachments(scoped.attachments));
    this.turns.set(id, {
      ...(input.input ? { input: input.input } : {}),
      ...(scoped.context ? { context: scoped.context } : {}),
      ...(scoped.attachments ? { attachments: scoped.attachments } : {}),
    });
    this.invocations.setFollowupAvailable(id, false);
    this.json(response, 202, { accepted: true, invocationId: id });
    void this.processInvocation(record, true);
  }

  private async processInvocation(record: InvocationRecord, followup = false): Promise<void> {
    // A.3: one AbortController per invocation; timeout fires it when configured. A full pi session's turn gets its
    // own limit once its session is known (defaultProcessor).
    const watch = new Stopwatch();
    const entry: RunningInvocation = {
      controller: new AbortController(), timedOut: false,
      limit: (ms) => {
        if (entry.timer) clearTimeout(entry.timer);
        entry.timer = undefined;
        if (ms <= 0 || entry.controller.signal.aborted) return;
        entry.timer = setTimeout(() => {
          entry.timedOut = true;
          entry.controller.abort();
          console.warn(`[invoke] timeout (${ms}ms) id=${record.invocationId}`);
        }, Math.max(0, ms - watch.elapsed()));
        entry.timer.unref();
      },
    };
    entry.limit(this.config.invokeTimeoutMs);
    this.running.set(record.invocationId, entry);
    const signal = entry.controller.signal;
    const id = record.invocationId;

    try {
      this.invocations.start(id);
      if (this.options.onInvocation) {
        await this.options.onInvocation(record);
      }
      else {
        await this.defaultProcessor(record, signal, followup);
      }
      if (signal.aborted) {
        throw this.agent.modules.runner.abortError(signal);
      }
      this.invocations.setFollowupAvailable(id, this.threads.has(id));
      this.invocations.setTimings(id, { totalMs: watch.elapsed() });
      this.invocations.finish(id, "completed");
    } catch (error) {
      const aborted = signal.aborted;
      const message = error instanceof Error ? error.message : String(error);
      if (aborted || !followup) await this.closeThread(id);
      this.invocations.setFollowupAvailable(id, this.threads.has(id));
      // A partial card from an interrupted show_result must never outlive the turn.
      if (!record.cardComplete) this.invocations.clearCard(id);
      this.invocations.setTimings(id, { totalMs: watch.elapsed() });
      // Logs carry the error class only; provider and host messages can quote the request or
      // name files, so the full message stays on the record (failureMessage), never on disk.
      const kind = /^([a-z][a-z0-9_]{1,40}):/.exec(message)?.[1] ?? this.stack?.modules.latency.classifyProviderError(message) ?? "other";
      if (aborted) {
        console.warn(`[invoke] ${entry.timedOut ? "timed out" : "aborted"} kind=${kind}`);
        this.invocations.addStep(id,
          entry.timedOut ? "timeout" : "cancel", false, message);
        this.invocations.finish(id, entry.timedOut ? "timed_out" : "aborted", message);
      } else {
        console.error(`[invoke] failed kind=${kind}`);
        this.invocations.addStep(id, "process", false, message);
        this.invocations.finish(id, "failed", message);
      }
    } finally {
      if (entry.timer) {
        clearTimeout(entry.timer);
      }
      this.running.delete(id);
      const turn = this.turns.get(id);
      this.turns.delete(id);
      // Content-free: model turns, the scope that ran (legacy when the request had none) and the attachment count.
      perfLog("invoke.total", watch.elapsed(), {
        state: record.state, followup, tools: record.steps.length, turns: turn?.responses ?? 0,
        scope: record.context?.scope ?? "legacy",
        ...(record.context ? { source: record.context.source, pulled: record.context.pulled, included: record.context.included } : {}),
        attachments: turn?.attachments?.length ?? 0,
      });
    }
  }

  /**
   * Instant lane (hosts without their own /instant use, e.g. Windows), pinned context,
   * then the agent: prepared or fresh session, Auto routing before the prompt, streaming
   * observers, and the final answer (lead text + card text).
   */
  private async defaultProcessor(record: InvocationRecord, signal: AbortSignal, followup = false): Promise<void> {
    const hostClient = this.options.hostClient;
    if (!hostClient) {
      throw new Error("No host client configured");
    }
    const id = record.invocationId;
    const turn = this.turns.get(id) ?? {};
    const watch = new Stopwatch();
    const { runner } = this.agent.modules;

    // A host that sends a takeId ran POST /instant itself (or bypassed it on purpose, ⌥↵). Attachments
    // are for the agent: a request that carries some never ends on an instant answer.
    if (!followup && !turn.takeId && !turn.attachments?.length && this.config.instantEnabled !== false
      && await this.answerInstantly(record, turn, signal)) {
      return;
    }
    if (!followup && !turn.takeId) this.invocations.setTimings(id, { instantMs: watch.lap() });

    let general = this.generalTurn(record, turn, followup);
    const pinned = await this.pinnedSnapshot(record, turn, general, followup, signal);
    const unavailable = pinned.unavailable;
    let snapshot = pinned.snapshot;
    if (pinned.released) {
      // The window the agent pulled in is gone: this follow-up runs general, without the loader (it cannot bring it back).
      general = true;
      turn.context = { scope: "general", pull: "denied", source: turn.context?.source ?? "followup" };
    }
    const contextMs = watch.lap();
    this.invocations.setTimings(id, { contextMs });
    this.logContext(record, turn, followup, general, unavailable, contextMs);

    if (!this.config.agentEnabled) {
      if (unavailable) {
        this.invocations.setResponse(id, "[slice] general turn without the window (PI_OS_AGENT=0)");
        return;
      }
      // Deterministic slice mode (default): prove the round trip without an LLM.
      await this.roundTripCapture(record, record.contextId, signal);
      this.invocations.setResponse(id,
        "[slice] round-trip capture ok (PI_OS_AGENT=0)");
      return;
    }

    // The Brave page digest: staged into a window (or legacy) first turn, read in parallel with the
    // session; otherwise read only if the turn needs it (use_active_window, a follow-up that includes the window).
    const staged = this.stagesPage(record, turn, followup, general);
    const browserPage = unavailable ? undefined : this.pageProvider(record, snapshot, signal, staged);
    // The harness is the only party that captures for a follow-up (the host never does before POST
    // /followup). A window follow-up gets a fresh capture of the pin when the thread has none to show:
    // it brings the window into a general thread (DESIGN2 §5.2: the thread has no image, or only the
    // take's key-down one), or the pinned snapshot has no screenshot (the window thread's first capture
    // failed). Taken while the session is negotiated, next to the page read; viewing only (a follow-up
    // image never authorizes clicks).
    const freshCapture = followup && turn.context?.scope === "window" && !unavailable && (staged || !snapshot.screenshot);
    const upgradeShot = freshCapture ? this.upgradeCapture(record, signal) : undefined;

    const { readOnly, launcher } = await this.negotiate(signal);
    const thread = this.threads.get(id);
    if (followup && thread?.readOnly === false && readOnly) {
      await this.closeThread(id);
      throw new Error("control_disabled: Permissions changed. Start a new task");
    }
    if (thread && !unavailable && snapshot.targetWindow?.processName) thread.app = snapshot.targetWindow.processName;
    const shot = await upgradeShot;
    // Only the fresh capture is shown: when it failed, an older image (a key-down capture) is not passed off as current.
    if (freshCapture) snapshot = { ...snapshot, screenshot: shot ?? null };
    // Original model/resources/tool scope remain fixed for the entire thread.
    const runOptions: AgentRunOptions = {
      ...this.runOptions(record, snapshot, readOnly, launcher, signal, turn.input, {
        onToolCall: (toolName) => this.invocations.addStep(id, `agent.${toolName}`, true),
        onActivity: (activity) => this.invocations.setActivity(id, activity),
      }),
      ...(turn.context ? { context: turn.context } : {}),
      ...(turn.attachments ? { attachments: turn.attachments } : {}),
      ...(browserPage ? { browserPage } : {}),
      // A thread keeps its first turn's folder: a follow-up never carries one.
      ...(!followup && turn.workingDirectory !== undefined ? { workingDirectory: turn.workingDirectory } : {}),
    };
    if (!followup) {
      // What the instant lane knew about this voice take (near miss, matching dictionary entries) for the
      // first prompt only; never logged, never part of the session setup key.
      const voice = runner.voiceTakeContext({
        ...(turn.takeId ? { takeId: turn.takeId } : {}), text: record.prompt, ...(turn.input ? { input: turn.input } : {}),
        memo: this.takeMemo, dictionary: this.dictionary,
      });
      if (voice) runOptions.voice = voice;
    }
    // Auto: heuristics (+ advisory hints that already arrived) → decide() → decision slot,
    // active tools and screenshot gating. Never waits on a classifier. The turn's scope is applied
    // first (planTurn), so a prepared session serves either scope.
    const hints = this.takeHints(turn.takeId);
    const plan = (session: LiveAgentSession) => runner.planTurn(session, {
      text: record.prompt, snapshot, followup, hints, settings: this.routing.get(), stats: this.agent.stats,
      ...(turn.context ? { context: turn.context } : {}), ...(turn.attachments ? { attachments: turn.attachments } : {}),
      ...(shot ? { freshScreenshot: true } : {}),
      // A short spoken request no rule places routes to the quick lane with the option tools (DESIGN4 §5.5).
      ...(turn.input ? { input: turn.input } : {}),
    });
    let live = thread?.live;
    let prepared = false;
    let turnPlan: TurnPlan | undefined;
    if (!live) {
      if (followup) throw new Error("session_closed: Start a new task");
      live = await this.adoptPrepared(turn.takeId, runOptions);
      if (live) {
        // A take is usually prepared before the host's capture lands, so its session holds no screenshot
        // seed: it adopts the attached image's authority (seedScreenshot) instead of being rebuilt. Only a
        // session seeded with a different image is replaced: the attached image must carry authority.
        turnPlan = plan(live);
        const imageId = snapshot.screenshot?.imageId;
        if (runner.attachesScreenshot(snapshot, turnPlan) && live.controls.initialScreenshotId !== imageId
          && !(imageId && runner.seedScreenshot(live, imageId))) {
          // Off the critical path: the replacement session is built while this one disposes.
          void live.close().catch(() => {});
          console.log("[prepare] discarded reason=screenshot");
          live = turnPlan = undefined;
        }
      }
      prepared = live !== undefined;
      live ??= await (this.options.createSession ?? runner.createLiveSession)(runOptions);
      if (signal?.aborted || this.stopping || (thread && this.threads.get(id) !== thread)) {
        await live.close();
        throw signal?.aborted ? runner.abortError(signal) : new Error("session_closed: Reader closed during startup");
      }
      if (thread) { thread.live = live; thread.readOnly = readOnly; }
    } else if (turn.takeId) {
      this.discardPrepared(turn.takeId, "unused");
    }
    const sessionMs = watch.lap();
    this.invocations.setTimings(id, { sessionMs });
    perfLog("invoke.session", sessionMs, { prepared, followup });
    // A full pi session's turn (coding work, the user's command guard's approval dialog) runs under its own limit,
    // counted from the invocation's start; isolated and Windows sessions keep invokeTimeoutMs.
    if (runner.isFullThread(live)) this.running.get(id)?.limit(this.config.fullInvokeTimeoutMs ?? FULL_INVOKE_TIMEOUT_MS);

    turnPlan ??= plan(live);
    this.recordPlan(record, live, turnPlan);
    this.recordContext(id, live, turn, followup);
    this.invocations.setTimings(id, { routeMs: watch.lap() });

    live.observe(this.observerFor(record, runOptions, watch, live));
    let result;
    try {
      result = followup
        ? await runner.promptFollowup(live, record.prompt, signal, turn.input, {
          ...(turn.context ? { context: turn.context } : {}),
          ...(turn.attachments ? { attachments: turn.attachments } : {}),
          snapshot,
          ...(browserPage ? { browserPage } : {}),
          ...(shot ? { freshScreenshot: true } : {}),
        })
        : await runner.promptFirst(live, { ...runOptions, attachScreenshot: turnPlan.attachScreenshot });
    } finally {
      this.recordContext(id, live, turn, followup);
      if (!thread) await live.close();
    }
    console.log(`[agent] finished (${result.toolCalls} tool calls)`);
    // show_result: the card is the answer; responseText = lead sentence + its text form.
    const current = this.invocations.get(id);
    const card = current?.cardComplete ? current.card : undefined;
    if (!card) this.invocations.clearCard(id);
    this.invocations.setResponse(id, [result.responseText, card ? cardToText(card) : ""].filter(Boolean).join("\n\n"));
    this.invocations.addStep(id, "agent.run", true,
      `${result.toolCalls} tool calls; ${result.responseText.length} chars${card ? "; card" : ""}`);
  }

  /**
   * Whether this turn leaves the window out (DESIGN2 §4.2): a general first turn; a follow-up in a
   * general thread the agent never pulled the window into (or one the user narrows to general). Window
   * and legacy turns need the pinned window and keep today's strictness.
   */
  private generalTurn(record: InvocationRecord, turn: TurnMeta, followup: boolean): boolean {
    if (!followup) return turn.context?.scope === "general";
    const generalThread = this.threadGeneral(record);
    if (!turn.context) return generalThread;
    if (turn.context.scope === "window") return false;
    // Only an explicit choice narrows a window (or legacy) thread, as agentRunner's ThreadContext.apply does.
    return generalThread || turn.context.source === "user" || turn.context.source === "setting";
  }

  /**
   * The thread leaves the window out before this follow-up is planned: the live thread's own view
   * (threadIsGeneral); the record's `included` only for sessions without a thread view.
   */
  private threadGeneral(record: InvocationRecord): boolean {
    const live = this.threads.get(record.invocationId)?.live;
    return (live ? this.agent.modules.runner.threadIsGeneral(live) : undefined) ?? record.context?.included === false;
  }

  /**
   * The pinned snapshot. Window and legacy turns fail when the host cannot provide it (target_gone,
   * expired, …) exactly as before. A general turn does not need the window: it continues without it,
   * naming only the app the take or thread was pinned on (`unavailable` carries the host's code).
   * One exception keeps a conversation alive: a follow-up in a thread that has the window only because
   * the agent pulled it in (an error dialog the user has since closed) is `released` when the window
   * is gone (`target_gone`, `no_target`) and goes on general (releasePulledWindow).
   */
  private async pinnedSnapshot(record: InvocationRecord, turn: TurnMeta, general: boolean, followup: boolean, signal: AbortSignal):
    Promise<{ snapshot: DesktopContextSnapshot & { screenshot?: ScreenshotRef | null }; unavailable?: string; released?: boolean }> {
    const id = record.invocationId;
    console.log("[context] fetching pinned context from host");
    let outcome: ToolOutcome<DesktopContextSnapshot>;
    try {
      outcome = await this.options.hostClient!.getSnapshot(record.contextId, signal);
    } catch (error) {
      if (!general || signal.aborted) throw error;
      outcome = { ok: false, error: { code: "host_unavailable", message: "The host did not answer" } };
    }

    if (!outcome.ok) {
      // Domain outcome as data (protocol.md): e.g. target_gone / expired. Host messages can name
      // windows or files, so the log carries the code only; the record step keeps the message.
      console.warn(`[context] unavailable: ${outcome.error.code}`);
      this.invocations.addStep(id, "desktop.getContext", false,
        `${outcome.error.code}: ${outcome.error.message}`);
      const live = followup ? this.threads.get(id)?.live : undefined;
      const released = !general && live !== undefined && WINDOW_GONE.has(outcome.error.code) && this.agent.modules.runner.releasePulledWindow(live);
      if (!general && !released) {
        await this.closeThread(id);
        throw new Error(`Pinned context unavailable (${outcome.error.code})`);
      }
      const app = this.threads.get(id)?.app ?? (turn.takeId ? this.prepared.get(turn.takeId)?.app : undefined);
      console.log(released ? "[context] pulled window gone; the thread continues general" : "[context] general turn continues without the window");
      return { snapshot: windowlessSnapshot(record.contextId, app), unavailable: outcome.error.code, ...(released ? { released } : {}) };
    }

    const snapshot = outcome.result;
    // Do not persist window contents, context capabilities, or the user's prompt in logs.
    const target = snapshot.targetWindow ?? snapshot.foregroundWindow;
    console.log(`[context] target=${target?.processName ?? "?"}`);
    this.invocations.addStep(id, "desktop.getContext", true,
      `target=${target?.processName ?? "?"}`);
    return { snapshot };
  }

  /** A window (or legacy) first turn, or a follow-up that brings the window into a general thread, shows the page at once. */
  private stagesPage(record: InvocationRecord, turn: TurnMeta, followup: boolean, general: boolean): boolean {
    if (general) return false;
    if (!followup) return true;
    return turn.context?.scope === "window" && this.threadGeneral(record);
  }

  /**
   * A fresh capture of the thread's pin for a follow-up that brings the window in, or undefined when
   * the host cannot take one (the follow-up then says no screenshot is attached). Never rejects; the
   * record step and telemetry carry the image id or the host's code only.
   */
  private async upgradeCapture(record: InvocationRecord, signal: AbortSignal): Promise<ScreenshotRef | undefined> {
    const watch = new Stopwatch();
    let shot: ScreenshotRef | undefined;
    let code = "capture_failed";
    try {
      const capture = await this.options.hostClient!.invokeTool<ScreenshotRef>("desktop.captureWindow", { contextId: record.contextId }, signal);
      if (capture.ok && capture.result?.filePath) shot = capture.result;
      else if (!capture.ok) code = capture.error.code;
    } catch {
      code = signal.aborted ? "cancelled" : "host_unavailable";
    }
    const current = this.invocations.get(record.invocationId);
    if (current && !TERMINAL_STATES.has(current.state)) {
      this.invocations.addStep(record.invocationId, "desktop.captureWindow", Boolean(shot), shot ? `imageId=${shot.imageId ?? "?"}` : code);
    }
    perfLog("invoke.capture", watch.elapsed(), shot ? { ok: true, upgrade: true } : { ok: false, upgrade: true, code });
    return shot;
  }

  /**
   * The pinned Brave tab's AX page read for this request only (N2: a provider never outlives its
   * request), or undefined when the snapshot has no readable ax pin. `eager` starts the host read now,
   * in parallel with session adoption; otherwise it starts on first use. The read is bounded by the
   * prompt's own wait (PAGE_DIGEST_TIMEOUT_MS) and never opens DevTools; a digest that fails the
   * contract is never shown. The whole read is handed over (not only the page) so the session's AX
   * transport adopts its refs with the prompt that shows it and the model can act without another
   * read. Telemetry: timings and counts only, never page content.
   */
  private pageProvider(record: InvocationRecord, snapshot: DesktopContextSnapshot, signal: AbortSignal, eager: boolean):
    BrowserPageProvider | undefined {
    const { canReadPage, readPage } = this.agent.modules.axTransport;
    if (!canReadPage(snapshot.browser)) return undefined;
    const id = record.invocationId;
    let pending: ReturnType<BrowserPageProvider> | undefined;
    const timeoutMs = this.agent.modules.runner.PAGE_DIGEST_TIMEOUT_MS;
    const read = () => pending ??= readPage(this.options.hostClient!, record.contextId, { signal, timeoutMs }).then(page => {
      const current = this.invocations.get(id);
      if (current && !TERMINAL_STATES.has(current.state)) this.invocations.setTimings(id, { pageMs: page.elapsedMs });
      perfLog("invoke.page", page.elapsedMs, page.ok
        ? { ok: true, staged: eager, chars: page.digest.length, refs: page.refs.length, truncated: page.truncated }
        : { ok: false, staged: eager, code: page.code });
      return page.ok ? page : null;
    });
    if (eager) void read();
    return read;
  }

  /**
   * The record's `context` from the live thread (`pulled` once use_active_window ran); fixture
   * sessions without a thread view keep what the request said.
   */
  private recordContext(id: string, live: LiveAgentSession, turn: TurnMeta, followup: boolean): void {
    const current = this.agent.modules.runner.contextRecord(live);
    if (current) this.invocations.setContext(id, current);
    else if (!followup && turn.context) this.invocations.setContext(id, requestedContextRecord(turn.context));
  }

  /**
   * One content-free line per turn about its context (DESIGN2 §5.9): the host's scope, source and pull,
   * its advisory score (`hint`, the fused number the chip used) beside Node's rules score for the same
   * words, whether the pinned window was available, and the attachments' count, kinds and sizes. A user
   * choice also writes `context.label` (label + scores only) for retraining; the text never appears.
   * Node never acts on either score: the host's choice is what runs.
   */
  private logContext(record: InvocationRecord, turn: TurnMeta, followup: boolean, general: boolean, unavailable: string | undefined, ms: number): void {
    const context = turn.context;
    // Scores as fixed two-decimal strings: perf numbers round to 0.1, labels need the pre-registered thresholds.
    // Bounded like the /instant scorer's input (MAX_SCORED_TEXT): the rules are linear but prompts reach 20,000 characters.
    const rulesScore = contextScope(record.prompt.slice(0, MAX_SCORED_CHARS)).window;
    const rules = rulesScore.toFixed(2);
    const hint: PerfFields = context?.scopeHint !== undefined ? { hint: context.scopeHint.toFixed(2) } : {};
    const stats = turn.attachments?.length ? attachmentStats(turn.attachments) : { images: 0, textChars: 0 };
    perfLog("invoke.context", ms, {
      scope: context?.scope ?? (followup ? record.context?.scope ?? "legacy" : "legacy"),
      ...(context ? { source: context.source, pull: context.pull } : {}),
      general, followup, window: unavailable === undefined, ...(unavailable ? { code: unavailable } : {}),
      rules, band: scopeBand(rulesScore), ...hint,
      // Continuity (closed vocabulary): the focused field's kind and whether pi-os's own open put the app in front.
      ...(context?.target?.field ? { field: context.target.field } : {}), ...(context?.target?.anchored ? { anchored: true } : {}),
      attachments: turn.attachments?.length ?? 0, kinds: attachmentKinds(turn.attachments), images: stats.images, chars: stats.textChars,
    });
    if (context?.source === "user") {
      const score = context.scopeHint ?? rulesScore;
      perfLog("context.label", 0, {
        label: context.scope, followup, rules, ...hint,
        override: (score >= SCOPE_THRESHOLDS.suggest) !== (context.scope === "window"),
      });
    }
  }

  /**
   * Windows-compatible instant answers: a pure `answer` (calc, units, currency, time, dates) completes
   * the invocation; everything else goes to the agent. `act`/`list` need host effects. `refuse` is not
   * short-circuited either: the agent is bound by the same file-deletion prohibition (with the host's
   * native checks), so hosts without /instant keep their previous behaviour for every request the
   * (now narrow) deletion grammar refuses, and DESIGN §1.5 allows only pure answers here.
   */
  private async answerInstantly(record: InvocationRecord, turn: TurnMeta, signal: AbortSignal): Promise<boolean> {
    const watch = new Stopwatch();
    const quick = await this.checkInstantCard(await this.instantDirect.dispatch({
      text: record.prompt, phase: "final", seq: 0, contextId: record.contextId,
      ...(turn.input?.locale ? { locale: turn.input.locale } : {}), ...(turn.input ? { inputMode: turn.input.mode } : {}),
    }, signal));
    if (quick.decision !== "answer") return false;
    // Only a real result replaces the agent: a Notice-only answer ("Downloading ECB reference rates.
    // Try again in a moment.", an unknown currency) is a preview hint, not an answer to this request.
    if (!Object.values(quick.card.elements).some(element => element.type === "ResultCard")) return false;
    const id = record.invocationId;
    this.invocations.setCard(id, quick.card, true);
    this.invocations.setResponse(id, cardToText(quick.card) || quick.title);
    this.invocations.addStep(id, "instant", true, `answer intent=${quick.intent}`);
    this.invocations.setTimings(id, { instantMs: watch.elapsed() });
    perfLog("invoke.instant", watch.elapsed(), { decision: quick.decision, kind: quick.intent });
    // No agent session exists; a follow-up starts a fresh /invoke ("Earlier quick answer: Q → A").
    await this.closeThread(id);
    return true;
  }

  private runOptions(
    record: Pick<InvocationRecord, "contextId" | "prompt">, snapshot: DesktopContextSnapshot, readOnly: boolean, launcher: boolean,
    signal: AbortSignal, input: InvokeInput | undefined, callbacks: Pick<AgentRunOptions, "onToolCall" | "onActivity">,
  ): AgentRunOptions {
    return {
      hostClient: this.options.hostClient!,
      contextId: record.contextId,
      prompt: record.prompt,
      snapshot: snapshot as DesktopContextSnapshot & { screenshot?: ScreenshotRef | null },
      capturesDir: this.config.capturesDir,
      readOnly,
      launcher,
      resourceSelection: this.resourceSettings.get(),
      log: (line) => console.log(line),
      modelSelection: this.modelSettings.get(),
      signal,
      services: this.agent.services,
      ...(input ? { input } : {}),
      ...callbacks,
    };
  }

  /** Route preview on the record (updated by onRoute), plus the optional label-only shadow log. */
  private recordPlan(record: InvocationRecord, live: LiveAgentSession, plan: TurnPlan): void {
    const id = record.invocationId;
    const decision = plan.decision;
    if (decision?.model) {
      this.invocations.setRoute(id, {
        tier: decision.tier, provider: decision.model.provider, model: decision.model.id,
        thinkingLevel: decision.model.thinkingLevel, reasons: decision.reasons, auto: true,
      });
      perfLog("invoke.route", 0, { tier: decision.tier, model: `${decision.model.provider}/${decision.model.id}@${decision.model.thinkingLevel}`,
        scope: decision.scope ?? "legacy", screenshot: plan.attachScreenshot, vision: decision.vision, tools: plan.activeTools?.length ?? 0 });
    } else if (!decision && live.controls.manual) {
      const manual = live.controls.manual;
      this.invocations.setRoute(id, { provider: manual.provider, model: manual.model, thinkingLevel: live.controls.thinkingLevel?.() ?? manual.thinkingLevel, reasons: ["manual"], auto: false });
    }
    if (decision && plan.routeInput) {
      this.classifier.shadow?.record({
        classifier: "heuristic", latencyMs: 0, hints: null,
        reference: { intent: plan.routeInput.classification.intent, tier: decision.tier },
      });
    }
  }

  /** Per-invocation stream sink: steps, activity, partial text, cards, route, context, latency stats. */
  private observerFor(record: InvocationRecord, options: AgentRunOptions, watch: Stopwatch, live: LiveAgentSession): SessionObserver {
    const id = record.invocationId;
    const { modules, stats } = this.agent;
    let lastComplete: CardSpec | undefined;
    let firstResponse = true;
    return {
      log: options.log,
      ...(options.onToolCall ? { onToolCall: options.onToolCall } : {}),
      ...(options.onActivity ? { onActivity: options.onActivity } : {}),
      onPartialText: (text) => this.invocations.setPartialText(id, text),
      onCard: (spec, complete) => {
        if (complete) lastComplete = spec;
        this.invocations.setCard(id, spec, complete);
      },
      onToolEnd: (name, isError) => {
        // The host shows "Looked at <app>" as soon as the agent pulled the window in.
        if (name === modules.USE_ACTIVE_WINDOW_TOOL) {
          const context = modules.runner.contextRecord(live);
          if (context) this.invocations.setContext(id, context);
          return;
        }
        // A rejected show_result attempt must not leave its partial card on screen.
        if (name !== modules.SHOW_RESULT_TOOL || !isError) return;
        if (lastComplete) this.invocations.setCard(id, lastComplete, true);
        else this.invocations.clearCard(id);
      },
      onRoute: (event: RouteEvent) => {
        if (event.cause === "sticky") return;
        this.invocations.setRoute(id, {
          tier: event.tier, provider: event.target.provider, model: event.target.id, thinkingLevel: event.target.thinkingLevel,
          reasons: [...(event.reasons.length ? event.reasons : this.invocations.get(id)?.route?.reasons ?? []), `cause=${event.cause}`], auto: true,
        });
      },
      onResponse: (sample) => {
        const level = sample.thinkingLevel ?? "off";
        const model = `${sample.provider}/${sample.model}@${level}`;
        this.statsDirty = true;
        const turn = this.turns.get(id);
        if (turn) turn.responses = (turn.responses ?? 0) + 1;
        if (!sample.ok) {
          stats.recordError({ provider: sample.provider, model: sample.model, thinkingLevel: level });
          // Quota errors are not retried by pi, so route() never sees them: keep Auto off that provider.
          if (sample.errorKind === "quota") stats.block(sample.provider, modules.latency.HEALTH_PENALTY_MS.quota, "quota");
          perfLog("agent.error", 0, { model, kind: sample.errorKind ?? "other" });
          return;
        }
        stats.record({
          provider: sample.provider, model: sample.model, thinkingLevel: level,
          ...(sample.ttftMs !== undefined ? { ttftMs: sample.ttftMs } : {}),
          ...(sample.outputTokens !== undefined ? { outputTokens: sample.outputTokens } : {}),
          ...(sample.streamMs !== undefined ? { streamMs: sample.streamMs } : {}),
        });
        if (firstResponse && sample.ttftMs !== undefined) {
          firstResponse = false;
          this.invocations.setTimings(id, { ttftMs: sample.ttftMs, firstTokenMs: watch.elapsed() - (sample.streamMs ?? 0) });
        }
        perfLog("agent.response", sample.ttftMs ?? 0, {
          model, outTokens: sample.outputTokens ?? 0, streamMs: Math.round(sample.streamMs ?? 0),
          ...(sample.createdMs !== undefined ? { createdMs: Math.round(sample.createdMs) } : {}),
          ...(sample.firstDelta ? { firstDelta: sample.firstDelta } : {}),
          ...(sample.cacheReadTokens !== undefined ? { cacheRead: sample.cacheReadTokens } : {}),
        });
      },
    };
  }

  // ------------------------------------------------------------------ SSE

  /**
   * GET /invocations/{id}/events: `event: record` with the full record on every change,
   * coalesced to one write per window; the terminal record ends the stream. Comment pings
   * keep idle proxies and clients alive. Polling GET /invocations/{id} is unchanged.
   */
  private streamEvents(id: string, response: ServerResponse): void {
    if (!this.invocations.get(id)) {
      return this.json(response, 404, { error: { code: "not_found", message: `Unknown invocation '${id}'` } });
    }
    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });
    const coalesceMs = this.options.sseCoalesceMs ?? 33;
    // Milestones skip the coalescing window: the first token, a card (or its completion), the
    // answer and the terminal state reach the reader at once; only text growth is coalesced.
    const milestoneOf = (record: InvocationRecord): string =>
      `${record.state}|${record.partialText ? 1 : 0}|${record.card ? (record.cardComplete ? 2 : 1) : 0}|${record.responseText !== undefined ? 1 : 0}`;
    let milestone = "";
    let sent = -1;
    let lastWrite = Number.NEGATIVE_INFINITY;
    let timer: NodeJS.Timeout | undefined;
    let closed = false;
    let draining = false;
    const finish = () => {
      if (closed) return;
      closed = true;
      unsubscribe();
      clearInterval(ping);
      if (timer) clearTimeout(timer);
      response.end();
    };
    const flush = () => {
      timer = undefined;
      if (closed) return;
      const record = this.invocations.get(id);
      if (!record) return finish(); // Evicted.
      // A reader that stopped reading gets the latest record once it drains, not a growing backlog.
      if (response.writableNeedDrain) {
        if (!draining) {
          draining = true;
          response.once("drain", () => { draining = false; schedule(); });
        }
        return;
      }
      if (record.revision !== sent) {
        response.write(`event: record\ndata: ${JSON.stringify(record)}\n\n`);
        sent = record.revision;
        milestone = milestoneOf(record);
        lastWrite = performance.now();
      }
      if (TERMINAL_STATES.has(record.state)) finish();
    };
    const schedule = () => {
      if (closed || draining) return;
      const record = this.invocations.get(id);
      if (record && milestoneOf(record) !== milestone) {
        if (timer) clearTimeout(timer);
        flush();
        return;
      }
      if (timer) return;
      const wait = lastWrite + coalesceMs - performance.now();
      if (wait <= 0) flush();
      else timer = setTimeout(flush, wait);
    };
    const unsubscribe = this.invocations.subscribe(id, schedule);
    const ping = setInterval(() => { if (!closed && !response.writableNeedDrain) response.write(": ping\n\n"); }, this.options.sseKeepAliveMs ?? 15_000);
    ping.unref();
    // Client went away (or the server is closing): drop the subscription and timers.
    response.once("close", () => {
      closed = true;
      unsubscribe();
      clearInterval(ping);
      if (timer) clearTimeout(timer);
    });
    flush();
  }

  /** Round-trip test (handoff section 23, item 9): call back into the C#
   * host for a fresh screenshot of the pinned target window. */
  private async roundTripCapture(
    record: InvocationRecord,
    contextId: string,
    signal?: AbortSignal,
  ): Promise<void> {
    const hostClient = this.options.hostClient;
    if (!hostClient) {
      throw new Error("No host client configured");
    }

    const capture = await hostClient.invokeTool<ScreenshotRef>(
      "desktop.captureWindow",
      { contextId },
      signal,
    );

    if (!capture.ok) {
      console.warn(`[roundtrip] capture failed: ${capture.error.code}`);
      this.invocations.addStep(record.invocationId, "desktop.captureWindow", false,
        `${capture.error.code}: ${capture.error.message}`);
      throw new Error(`Round-trip capture failed (${capture.error.code})`);
    }

    console.log(`[roundtrip] fresh screenshot: imageId=${capture.result.imageId} file=${capture.result.filePath}`);
    this.invocations.addStep(record.invocationId, "desktop.captureWindow", true,
      `imageId=${capture.result.imageId}`);
  }

  private now(): number {
    return this.options.now?.() ?? Date.now();
  }

  private authorized(request: IncomingMessage): boolean {
    const expected = this.config.hostToken;
    if (!expected) return this.config.insecureDev === true;
    const supplied = request.headers["x-harness-token"];
    if (typeof supplied !== "string") return false;
    const a = Buffer.from(supplied), b = Buffer.from(expected);
    return a.length === b.length && timingSafeEqual(a, b);
  }

  private async readJson(request: IncomingMessage, maxBytes = 1_000_000): Promise<unknown> {
    // JSON only: a text/plain "simple request" (no CORS preflight) never reaches a handler.
    const type = (request.headers["content-type"] ?? "").split(";")[0]!.trim().toLowerCase();
    if (type !== "application/json") throw new RequestError(415, "Content-Type must be application/json", "unsupported_media_type");
    const chunks: Buffer[] = [];
    let total = 0;
    for await (const chunk of request) {
      total += (chunk as Buffer).length;
      if (total > maxBytes) {
        throw new RequestError(413, "Request body too large");
      }
      chunks.push(chunk as Buffer);
    }
    const raw = Buffer.concat(chunks).toString("utf8");
    return raw.length > 0 ? JSON.parse(raw) : null;
  }

  private json(response: ServerResponse, status: number, payload: unknown): void {
    const body = JSON.stringify(payload);
    response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
    response.end(body);
  }
}
