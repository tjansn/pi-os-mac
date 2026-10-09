import { homedir } from "node:os";
import { rulesContextScorer, warmContextScope } from "../agent/routing/contextScope.js";
import type { HostAction } from "../contracts/actions.js";
import type { CardSpec } from "../contracts/cards.js";
import { parseInstantScope, type ContextScorer, type InstantScope } from "../contracts/context.js";
import type {
  ClassifierHints, FallthroughReason, InstantIntent, InstantPhase, InstantRequest, InstantResponse, IntentClassifier,
} from "../contracts/instant.js";
import type { PerfFields } from "../telemetry.js";
import { AppMatcher } from "./apps.js";
import { appListCard, fileListCard, linkCard, MAX_LIST_ITEMS, noticeCard, refuseCard, resultCard, type FileRow } from "./cards.js";
import {
  convertCurrencyWith, convertTimeWith, createFendLoader, createInstantEngines, evaluateDate, evaluateWith, searchFilesWith,
  timeAt, timeDiffWith, type InstantDeps, type InstantEngines,
} from "./engines.js";
import { localZone as systemZone } from "./engines/timezones.js";
import { copyNumber, displayLocale, formatNumber, localizeNumbers, truncate } from "./format.js";
import { DEFAULT_WEB_SEARCH, DELETION_REFUSAL_MESSAGE, parseInstant } from "./grammar/index.js";
import { normalize } from "./normalize.js";
import type { DateQuery, MatchContext, Parsed } from "./types.js";

/**
 * POST /instant core (DESIGN §3.3): normalize → anchored grammar → engine →
 * InstantResponse with a pi-os-ui/1 card. Node never performs effects; `act`
 * carries a HostAction descriptor and is produced only for phase "final".
 * Typing/partial phases get previews (answer/list). Budgets: 60 ms; 250 ms for
 * the first ECB download; file search 600 ms for typing/partial previews and
 * 1600 ms for a final (longer than the host's own 1.5 s Spotlight deadline, so a
 * final gets the host's answer or its search_timeout, never a Node timeout). A
 * typed file search waits for 150 ms of quiet first (each keystroke supersedes
 * the last), so only the settled query reaches the host's serial search queue.
 * Numbers are parsed and shown in the request's format locale and copied in the
 * same decimal convention. Never throws: every failure is a fallthrough. Logs
 * (perf) carry phase/decision/intent and timings only. Every response to a
 * readable request carries the advisory context `scope` of its text (rules v2,
 * microseconds, computed before any engine work): the host's context chip
 * listens to it while the user types or speaks.
 */

export interface InstantDispatcherDeps extends InstantDeps {
  /** Optional advisory classifier, consulted only on a grammar miss for partial/final, only for hints. */
  classifier?: IntentClassifier;
  /**
   * On-device scorer for `scope` on every response (default: rules v2, routing/contextScope.ts).
   * Synchronous and local: it sees typing and partials. NO_CONTEXT_SCORER leaves the field out.
   */
  scorer?: ContextScorer;
  /** Settings kill switch; false → fallthrough "disabled". */
  enabled?: () => boolean;
  /** Default web search template with %s (DuckDuckGo). */
  webSearchTemplate?: () => string;
  /** Monotonic clock for elapsedMs and budgets. */
  clock?: () => number;
  /** Home directory for "~/…" display paths. */
  homeDir?: string;
  budgets?: {
    defaultMs?: number;
    /** File search in phase "final" (default 1600 ms, above the host's 1.5 s FileSearch deadline). */
    fileSearchFinalMs?: number;
    /** File search previews in phases "typing" and "partial" (default 600 ms). */
    fileSearchPreviewMs?: number;
    /** @deprecated alias of fileSearchPreviewMs. */
    fileSearchMs?: number;
    /** Quiet period before a typed (phase "typing") file search reaches the host (default 150 ms). */
    typingFileQuietMs?: number;
    networkMs?: number;
    classifierMs?: number;
  };
  /** Per-dispatch timing hook, e.g. telemetry.perfLog. Never receives text. */
  perf?: (stage: string, ms: number, fields: PerfFields) => void;
  /**
   * When set, a phase "final" grammar miss answers its fallthrough immediately and classifies in
   * the background (same classifierMs deadline); a non-null result arrives here. The agent path
   * then never waits on the classifier (it fuses hints only if they already arrived).
   */
  onLateHints?: (request: InstantRequest, hints: ClassifierHints) => void;
}

export interface InstantDispatcher {
  dispatch(request: InstantRequest, signal?: AbortSignal): Promise<InstantResponse>;
  /** Preloads fend and the rate cache so the first keystroke is warm. */
  warm(): Promise<void>;
  /** The same engines, for pi tools. */
  readonly engines: InstantEngines;
}

export const MAX_INSTANT_TEXT = 500;
/** Longest text a scorer sees (over-long requests still fall through to the agent, which the chip serves). */
const MAX_SCORED_TEXT = 4_000;
const PHASES: readonly InstantPhase[] = ["typing", "partial", "final"];
const TIMEOUT = Symbol("timeout");
const FAILED = Symbol("failed");

type Body =
  | { decision: "answer"; intent: InstantIntent; title: string; subtitle?: string; card: CardSpec }
  | { decision: "list"; intent: "file_search" | "open_app"; title: string; card: CardSpec; relaxed?: boolean }
  | { decision: "act"; intent: InstantIntent; title: string; action: HostAction; confirm: boolean; card?: CardSpec }
  | { decision: "refuse"; code: "file_deletion_blocked"; message: string; card: CardSpec }
  | { decision: "fallthrough"; reason: FallthroughReason; hints?: ClassifierHints };

function fallthrough(reason: FallthroughReason): Body {
  return { decision: "fallthrough", reason };
}

/** Settles with the work's value, TIMEOUT when `signal` aborts first, or FAILED when the work rejects. */
function race<T>(work: Promise<T>, signal: AbortSignal): Promise<T | typeof TIMEOUT | typeof FAILED> {
  if (signal.aborted) return Promise.resolve(TIMEOUT);
  return new Promise((resolve) => {
    const onAbort = (): void => resolve(TIMEOUT);
    signal.addEventListener("abort", onAbort, { once: true });
    work.then((value) => {
      signal.removeEventListener("abort", onAbort);
      resolve(value);
    }, () => {
      signal.removeEventListener("abort", onAbort);
      resolve(signal.aborted ? TIMEOUT : FAILED);
    });
  });
}

/**
 * `parent` plus a budget. The timer is ref'd on purpose: AbortSignal.timeout's
 * unref'd timer never fires when nothing else holds the event loop (Node 22
 * then drops the pending dispatch). Always dispose() once the race settles.
 */
function deadline(parent: AbortSignal, ms: number): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const abort = (): void => controller.abort();
  const timer = setTimeout(abort, ms);
  if (parent.aborted) abort();
  else parent.addEventListener("abort", abort, { once: true });
  return {
    signal: controller.signal,
    dispose: () => {
      clearTimeout(timer);
      parent.removeEventListener("abort", abort);
    },
  };
}

/** Resolves true after `ms`, or false as soon as `signal` aborts. */
function quiet(ms: number, signal: AbortSignal): Promise<boolean> {
  if (signal.aborted) return Promise.resolve(false);
  return new Promise((resolve) => {
    const onAbort = (): void => {
      clearTimeout(timer);
      resolve(false);
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve(true);
    }, ms);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function quoted(text: string): string {
  return `“${truncate(text, 120)}”`;
}

export function displayFolder(path: string, home: string): string {
  const folder = path.slice(0, Math.max(1, path.lastIndexOf("/")));
  if (home && (folder === home || folder.startsWith(`${home}/`))) return `~${folder.slice(home.length)}`;
  return folder.replace(/^\/Users\/[^/]+(?=\/|$)/, "~");
}

const shortDate = new Map<string, Intl.DateTimeFormat>();

function fileDateLabel(ms: number | undefined, now: Date, locale: string): string | undefined {
  if (!ms || !Number.isFinite(ms)) return undefined;
  const sameYear = new Date(ms).getFullYear() === now.getFullYear();
  const key = `${locale}|${sameYear}`;
  let formatter = shortDate.get(key);
  if (!formatter) {
    const options: Intl.DateTimeFormatOptions = sameYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" };
    try {
      formatter = new Intl.DateTimeFormat(locale, options);
    } catch {
      formatter = new Intl.DateTimeFormat("en-US", options);
    }
    if (shortDate.size >= 128) shortDate.clear();
    shortDate.set(key, formatter);
  }
  return formatter.format(new Date(ms));
}

function dayDeltaLabel(delta: number): string {
  if (delta === 0) return "";
  if (delta === 1) return " (+1 day)";
  if (delta === -1) return " (−1 day)";
  return ` (${delta > 0 ? "+" : "−"}${Math.abs(delta)} days)`;
}

function hoursLabel(hours: number): string {
  if (hours === 0) return "same time";
  const abs = Math.abs(hours);
  const text = Number.isInteger(abs) ? String(abs) : abs.toFixed(2).replace(/0$/, "");
  return `${text} ${abs === 1 ? "hour" : "hours"} ${hours > 0 ? "ahead" : "behind"}`;
}

export function createInstantDispatcher(deps: InstantDispatcherDeps = {}): InstantDispatcher {
  const fend = deps.fend ?? createFendLoader();
  const shared: InstantDeps = { ...deps, fend };
  const engines = createInstantEngines(shared);
  const now = deps.now ?? (() => new Date());
  const clock = deps.clock ?? (() => performance.now());
  const homeZone = deps.localZone ?? systemZone;
  const enabled = deps.enabled ?? (() => true);
  const webSearchTemplate = deps.webSearchTemplate ?? (() => DEFAULT_WEB_SEARCH);
  const home = deps.homeDir ?? homedir();
  const budgets = {
    defaultMs: deps.budgets?.defaultMs ?? 60,
    fileSearchFinalMs: deps.budgets?.fileSearchFinalMs ?? 1_600,
    fileSearchPreviewMs: deps.budgets?.fileSearchPreviewMs ?? deps.budgets?.fileSearchMs ?? 600,
    typingFileQuietMs: deps.budgets?.typingFileQuietMs ?? 150,
    networkMs: deps.budgets?.networkMs ?? 250,
    classifierMs: deps.budgets?.classifierMs ?? 250,
  };
  const timeoutMs = deps.calcTimeoutMs ?? 30;
  const scorer = deps.scorer ?? rulesContextScorer;
  // The default rules compile their regexes now (once per process), not on the first keystroke.
  if (scorer === rulesContextScorer) warmContextScope();

  /** The text's scope, or undefined (unreadable request, no scorer, a scorer that failed or answered off-contract). */
  function scopeOf(text: unknown): InstantScope | undefined {
    if (typeof text !== "string" || !text.trim()) return undefined;
    try {
      return parseInstantScope(scorer(text.slice(0, MAX_SCORED_TEXT))) ?? undefined;
    } catch {
      return undefined;
    }
  }

  async function math(parsed: Extract<Parsed, { kind: "calc" | "unit" | "base" }>, locale: string): Promise<Body | null> {
    const engine = await fend.get();
    const unit = parsed.kind === "unit" || (parsed.kind === "calc" && parsed.units);
    const result = evaluateWith(engine, parsed.expression, locale, timeoutMs, unit);
    if (!result.ok) return null;
    let value = result.display;
    let copy = result.copy;
    if (parsed.kind === "base" && /^[0-9a-z]+$/i.test(result.text)) {
      const prefix = parsed.base === "hex" ? "0x" : parsed.base === "binary" ? "0b" : parsed.base === "octal" ? "0o" : "";
      value = copy = prefix && !result.text.startsWith(prefix) ? `${prefix}${result.text}` : result.text;
    }
    const intent: InstantIntent = parsed.kind === "base" ? "base" : unit ? "unit" : "calc";
    // One decimal convention per card: the input and the copied value follow the display locale.
    const input = parsed.kind === "base" ? parsed.display : localizeNumbers(parsed.display, locale);
    if (parsed.kind !== "base") copy = copyNumber(copy, locale);
    return {
      decision: "answer",
      intent,
      title: value,
      subtitle: input,
      card: resultCard({ kind: intent === "calc" ? "math" : "conversion", input, value, copyText: copy }),
    };
  }

  async function currency(parsed: Extract<Parsed, { kind: "currency" }>, locale: string, phase: InstantPhase, signal: AbortSignal): Promise<Body> {
    const result = await convertCurrencyWith(deps.fx, parsed.amount, parsed.from, parsed.to, locale, { signal, waitMs: budgets.networkMs - 10 });
    if (!result.ok) {
      // A notice ("Downloading ECB reference rates…", an unknown currency) is a preview hint, never
      // the final answer to the request: the agent gets the final instead.
      if (phase === "final") return fallthrough("no_match");
      const asked = `${formatNumber(parsed.amount, locale, 2)} ${parsed.from} in ${parsed.to}`;
      return { decision: "answer", intent: "currency", title: result.message, subtitle: asked, card: noticeCard(result.error === "unknown_currency" ? "warning" : "info", result.message, asked) };
    }
    const input = `${result.amountDisplay} in ${result.to}`;
    return {
      decision: "answer",
      intent: "currency",
      title: result.display,
      subtitle: `${input} · ECB ${result.asOf}`,
      card: resultCard({
        kind: "currency",
        input,
        value: result.display,
        detail: result.rateDisplay,
        freshness: { label: result.label, level: result.freshness },
        copyText: copyNumber(result.copy, locale),
        summary: `${result.amountDisplay} = ${result.display}`,
      }),
    };
  }

  function time(parsed: Extract<Parsed, { kind: "time" | "time_convert" | "time_diff" }>, locale: string): Body {
    const at = now();
    const zone = homeZone();
    if (parsed.kind === "time") {
      const t = timeAt(parsed.place, at, locale, zone);
      if (!t.ok) return fallthrough("unknown_place");
      const detail = `${t.weekday}, ${t.date} · ${t.offset}${dayDeltaLabel(t.dayDelta)}`;
      return {
        decision: "answer", intent: "time", title: t.time, subtitle: `${t.place} · ${detail}`,
        card: resultCard({ kind: "time", input: `Time in ${t.place}`, value: t.time, detail, copyText: t.time }),
      };
    }
    if (parsed.kind === "time_convert") {
      const t = convertTimeWith(parsed.hour, parsed.minute, parsed.from, parsed.to, at, locale, zone);
      if (!t.ok) return fallthrough("unknown_place");
      const input = `${t.from.time} ${t.fromPlace} in ${t.toPlace}`;
      const detail = `${t.weekday}, ${t.date} · ${t.offset}${dayDeltaLabel(t.dayDelta)}`;
      return {
        decision: "answer", intent: "time_convert", title: t.time, subtitle: input,
        card: resultCard({ kind: "time", input, value: t.time, detail, copyText: t.time }),
      };
    }
    const d = timeDiffWith(parsed.from, parsed.to, at, zone);
    if (!d.ok) return fallthrough("unknown_place");
    const value = hoursLabel(d.hours);
    const input = `${d.toPlace} vs ${d.fromPlace}`;
    return {
      decision: "answer", intent: "time", title: value, subtitle: input,
      card: resultCard({ kind: "time", input, value, copyText: String(d.hours), summary: `${d.toPlace} is ${value === "same time" ? "on the same time as" : value + " of"} ${d.fromPlace}` }),
    };
  }

  function date(query: DateQuery, locale: string): Body | null {
    const result = evaluateDate(query, now(), locale);
    if (!result.ok) return null;
    let title = result.display;
    let input: string;
    switch (query.op) {
      case "days_until":
        title = result.days === 0 ? "Today" : `${formatNumber(result.days ?? 0, locale, 0)} ${result.days === 1 ? "day" : "days"}`;
        input = query.label ? `Until ${query.label} · ${result.display}` : `Until ${result.display}`;
        break;
      case "offset":
        input = `In ${query.amount} ${query.unit}${query.amount === 1 ? "" : "s"}`;
        break;
      case "weekday_in":
        input = `${result.weekday} in ${query.weeks} week${query.weeks === 1 ? "" : "s"}`;
        break;
      case "weekday_of":
        title = result.weekday;
        input = query.label ? `${query.label} · ${result.display}` : result.display;
        break;
      case "today":
        input = "Today";
        break;
    }
    return {
      decision: "answer", intent: "date", title, subtitle: input,
      card: resultCard({ kind: "date", input, value: title, ...(title !== result.display ? { detail: result.display } : {}), copyText: query.op === "days_until" ? String(result.days ?? 0) : result.date }),
    };
  }

  async function files(parsed: Extract<Parsed, { kind: "file_search" }>, request: InstantRequest, locale: string, signal: AbortSignal): Promise<Body> {
    const at = now();
    const result = await searchFilesWith(deps.searchFiles, parsed.query, at, signal, request.contextId ? { contextId: request.contextId } : {});
    if (!result.ok) return fallthrough(result.error === "timeout" ? "timeout" : "no_match");
    if (!result.files.length) return fallthrough("no_match");
    const label = parsed.query.label;
    const count = result.files.length;
    const rows: FileRow[] = result.files.slice(0, MAX_LIST_ITEMS).map((file) => {
      const detail = fileDateLabel(Math.max(file.lastUsedMs ?? 0, file.modifiedMs ?? 0), at, locale);
      return {
        token: file.token,
        name: file.name,
        folder: displayFolder(file.path, home),
        ...(file.contentType ? { contentType: file.contentType } : {}),
        ...(detail ? { detail } : {}),
      };
    });
    const title = `${count}${result.truncated ? "+" : ""} ${count === 1 ? "file matches" : "files match"} ${quoted(label)}`;
    const notice = result.relaxed && parsed.query.rangeLabel ? `Nothing from ${parsed.query.rangeLabel} — showing all matches.` : undefined;
    return {
      decision: "list",
      intent: "file_search",
      title,
      card: fileListCard(title, `Files matching ${quoted(label)}`, rows, count, notice),
      ...(result.relaxed ? { relaxed: true } : {}),
    };
  }

  function openUrl(url: string, label: string, intent: "url" | "web", title: string, phase: InstantPhase): Body {
    if (phase === "final") return { decision: "act", intent, title, action: { type: "openURL", url }, confirm: false };
    return { decision: "answer", intent, title, subtitle: label, card: linkCard(title, url) };
  }

  async function open(parsed: Extract<Parsed, { kind: "open" }>, phase: InstantPhase, signal: AbortSignal): Promise<Body> {
    const matcher = deps.apps ? await deps.apps.get(signal) : null;
    const matches = matcher ? matcher.match(parsed.target, 8, now().getTime()) : [];
    const exact = matches[0] && matches[0].score >= 1 ? matches[0] : undefined;
    if (parsed.siteUrl && !exact) {
      const label = parsed.siteUrl.replace(/^https?:\/\//, "").replace(/\/$/, "");
      return openUrl(parsed.siteUrl, label, "url", `Open ${label}`, phase);
    }
    if (!matches.length) return fallthrough("no_match");
    const decisive = AppMatcher.decisive(matches);
    const apps = matches.map((match) => match.app);
    if (decisive && phase === "final") {
      const title = `Open ${decisive.app.name}`;
      return { decision: "act", intent: "open_app", title, action: { type: "openApp", bundleId: decisive.app.bundleId }, confirm: false, card: appListCard(title, apps) };
    }
    const title = decisive ? `Open ${decisive.app.name}` : `${apps.length} ${apps.length === 1 ? "app matches" : "apps match"} ${quoted(parsed.target)}`;
    return { decision: "list", intent: "open_app", title, card: appListCard(title, apps) };
  }

  function refusal(): Body {
    return { decision: "refuse", code: "file_deletion_blocked", message: DELETION_REFUSAL_MESSAGE, card: refuseCard(DELETION_REFUSAL_MESSAGE) };
  }

  /** "delete Slack" / "Zoom löschen": uninstalling moves the app to the Trash. Other objects are in-app edits. */
  async function deleteTarget(target: string, signal: AbortSignal): Promise<Body> {
    const matcher = deps.apps ? await deps.apps.get(signal) : null;
    const exact = matcher?.match(target, 8, now().getTime()).some((match) => match.score >= 1);
    return exact ? refusal() : fallthrough("no_match");
  }

  function system(parsed: Extract<Parsed, { kind: "system" }>, phase: InstantPhase): Body {
    const action: HostAction = parsed.value === undefined ? { type: "system", op: parsed.op } : { type: "system", op: parsed.op, value: parsed.value };
    if (phase === "final") return { decision: "act", intent: "system", title: parsed.title, action, confirm: false };
    return { decision: "answer", intent: "system", title: parsed.title, card: noticeCard("info", parsed.title, parsed.title) };
  }

  async function resolve(parsed: Parsed, request: InstantRequest, ctx: MatchContext, signal: AbortSignal): Promise<Body | null> {
    switch (parsed.kind) {
      case "refuse":
        return refusal();
      case "delete_target":
        return deleteTarget(parsed.target, signal);
      case "fallthrough":
        return fallthrough(parsed.reason);
      case "calc":
      case "unit":
      case "base":
        return math(parsed, ctx.locale);
      case "currency":
        return currency(parsed, ctx.locale, request.phase, signal);
      case "time":
      case "time_convert":
      case "time_diff":
        return time(parsed, ctx.locale);
      case "date":
        return date(parsed.query, ctx.locale);
      case "file_search":
        return files(parsed, request, ctx.locale, signal);
      case "open":
        return open(parsed, request.phase, signal);
      case "url":
        return openUrl(parsed.url, parsed.label, "url", `Open ${parsed.label}`, request.phase);
      case "web":
        return openUrl(parsed.url, parsed.query, "web", `Search ${parsed.engine} for ${quoted(parsed.query)}`, request.phase);
      case "system":
        return system(parsed, request.phase);
    }
  }

  function budgetFor(parsed: Parsed, phase: InstantPhase): number {
    if (parsed.kind === "file_search") return phase === "final" ? budgets.fileSearchFinalMs : budgets.fileSearchPreviewMs;
    if (parsed.kind === "currency" && !deps.fx?.snapshot()) return budgets.networkMs + 20;
    return budgets.defaultMs;
  }

  async function hintsFor(reason: FallthroughReason, text: string, request: InstantRequest, phase: InstantPhase, signal: AbortSignal): Promise<ClassifierHints | undefined> {
    const heuristic: ClassifierHints | undefined = reason === "deictic" ? { source: "heuristic", latencyMs: 0, needsScreen: 0.9 } : undefined;
    const classifier = deps.classifier;
    if (!classifier || !text || phase === "typing" || reason === "timeout" || reason === "disabled") return heuristic;
    // Partials (and takes the user then cancels) never leave the machine: remote classifiers see finals only.
    if (phase !== "final" && classifier.local === false) return heuristic;
    const late = deps.onLateHints;
    if (phase === "final" && late) {
      // The final is on the critical path to the agent: answer now, deliver hints if they come.
      const background = deadline(signal, budgets.classifierMs);
      void race(classifier.classify(text, background.signal).catch(() => null), background.signal)
        .then((result) => { if (result && result !== TIMEOUT && result !== FAILED) late(request, result); })
        .catch(() => undefined)
        .finally(() => background.dispose());
      return heuristic;
    }
    const budget = deadline(signal, budgets.classifierMs);
    try {
      const result = await race(classifier.classify(text, budget.signal).catch(() => null), budget.signal);
      return result === TIMEOUT || result === FAILED || !result ? heuristic : result;
    } finally {
      budget.dispose();
    }
  }

  async function dispatch(request: InstantRequest, callerSignal?: AbortSignal): Promise<InstantResponse> {
    const started = clock();
    const seq = typeof request?.seq === "number" && Number.isFinite(request.seq) ? request.seq : 0;
    const phase: InstantPhase = PHASES.includes(request?.phase) ? request.phase : "final";
    const signal = callerSignal ?? new AbortController().signal;
    let intentLabel = "none";
    // Every phase and decision: the chip needs it on typing previews and on instant answers alike.
    const scope = scopeOf(request?.text);
    const finish = (body: Body): InstantResponse => {
      const elapsedMs = Math.round((clock() - started) * 10) / 10;
      const label = body.decision === "fallthrough" ? body.reason : body.decision === "refuse" ? "refuse" : body.intent;
      deps.perf?.("instant.dispatch", elapsedMs, { phase, decision: body.decision, kind: label, parsed: intentLabel });
      return { seq, elapsedMs, source: "grammar", ...body, ...(scope ? { scope } : {}) } as InstantResponse;
    };
    try {
      if (typeof request?.text !== "string" || !PHASES.includes(request.phase) || request.text.length > MAX_INSTANT_TEXT) return finish(fallthrough("no_match"));
      if (!enabled()) return finish(fallthrough("disabled"));
      const n = normalize(request.text, request.locale);
      const ctx: MatchContext = { now: now(), locale: displayLocale(request.locale, n.lang), webSearchTemplate: webSearchTemplate() };
      const parsed = parseInstant(n, ctx);
      intentLabel = parsed?.kind ?? "none";
      if (!parsed || parsed.kind === "fallthrough") {
        const reason: FallthroughReason = parsed?.reason ?? "no_match";
        const hints = await hintsFor(reason, n.text, request, phase, signal);
        return finish(hints ? { decision: "fallthrough", reason, hints } : fallthrough(reason));
      }
      // Typing: only the query that survives a quiet period reaches the host's serial search queue;
      // the next keystroke's request aborts this one (server latest-wins), which answers "timeout".
      if (phase === "typing" && parsed.kind === "file_search" && budgets.typingFileQuietMs > 0) {
        if (!(await quiet(budgets.typingFileQuietMs, signal))) return finish(fallthrough("timeout"));
      }
      const budget = deadline(signal, budgetFor(parsed, phase));
      let body: Body | null | typeof TIMEOUT | typeof FAILED;
      try {
        body = await race(resolve(parsed, request, ctx, budget.signal), budget.signal);
      } finally {
        budget.dispose();
      }
      if (body === TIMEOUT) return finish(fallthrough("timeout"));
      if (body === FAILED || !body) {
        const hints = await hintsFor("no_match", n.text, request, phase, signal);
        return finish(hints ? { decision: "fallthrough", reason: "no_match", hints } : fallthrough("no_match"));
      }
      if (body.decision === "fallthrough" && body.reason !== "timeout" && !body.hints) {
        const hints = await hintsFor(body.reason, n.text, request, phase, signal);
        if (hints) return finish({ ...body, hints });
      }
      return finish(body);
    } catch {
      return finish(fallthrough("no_match"));
    }
  }

  return {
    dispatch,
    warm: () => engines.warm(),
    engines,
  };
}

