import { homedir } from "node:os";
import { rulesContextScorer, warmContextScope } from "../agent/routing/contextScope.js";
import type { HostAction } from "../contracts/actions.js";
import { parseInstantScope, type ContextScorer, type InstantScope } from "../contracts/context.js";
import {
  foldPhrase, isRefusedPhrase, NO_DICTIONARY, parseSafeTarget, safeTargetToHostAction,
  type DictionaryEntryRef, type DictionaryLookup, type SafeTarget, type TakeMemo,
} from "../contracts/dictionary.js";
import {
  accepts, RECOGNIZERS,
  type ClassifierHints, type FallthroughReason, type InstantIntent, type InstantPhase, type InstantRequest, type InstantResponse,
  type IntentClassifier, type VoiceHypothesis, type VoiceMeta, type VoiceVia,
} from "../contracts/instant.js";
import { parseFileCandidate, type FileCandidate, type FileSearchResult } from "../contracts/launcher.js";
import type { PerfFields } from "../telemetry.js";
import { AppMatcher, SPOKEN, spokenHead, type AppMatch } from "./apps.js";
import {
  appListCard, appRowsCard, choiceRowsCard, fileListCard, linkCard, MAX_LIST_ITEMS, noticeCard, openItemCard, refuseCard, resultCard,
  type ChoiceRow, type FileRow,
} from "./cards.js";
import {
  convertCurrencyWith, convertTimeWith, createFendLoader, createInstantEngines, evaluateDate, evaluateWith, searchFilesWith,
  timeAt, timeDiffWith, type InstantDeps, type InstantEngines,
} from "./engines.js";
import { localZone as systemZone } from "./engines/timezones.js";
import { copyNumber, displayLocale, formatNumber, localizeNumbers, truncate } from "./format.js";
import { DEFAULT_WEB_SEARCH, DELETION_REFUSAL_MESSAGE, isKnownSpokenHost, openStrength, parseInstant, type OpenStrength } from "./grammar/index.js";
import { displayName } from "./learned.js";
import { isCommonWord as lexiconWord, warmLexicon } from "./lexicon.js";
import { normalize, spokenCore, type Normalized } from "./normalize.js";
import { attachTakeDetails, safeTargetOf, type TakeDetails, type TakeRecord } from "./takeMemo.js";
import type { DateQuery, InstantBody, MatchContext, Parsed } from "./types.js";
import {
  checkGate, consistentAlternative, correctionTarget, decisionSignature, didYouMeanTitle, isActionable, mentionsDeletion,
  mergeOffers, nearMissOf, spokenLabel, VOICE, voiceMeta, voiceTake, type FirstTierView, type LaneOutcome, type VoiceTake,
} from "./voice.js";
import {
  choiceRows, decideVisible, foundMatches, itemRow, matchVisible, mergeVisibleOffers, NO_VISIBLE, userVisible, visibleEntry, visibleTarget, withoutApps,
  type VisibleDecision, type VisibleItemsCache, type VisibleMatch, type VisibleSnapshot, type VisibleTarget,
} from "./visible.js";

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
 *
 * Voice (DESIGN4 §4.5, §5, §6.3; voice.ts): partials and finals use the spoken grammar (`parseInstant` with
 * `voice`) and the spoken app matcher; a voice final runs every hypothesis through the lane (policy →
 * learned alias → learned app name → grammar + spoken matcher → learned fixes) and arbitrates them, with
 * "Did you mean …?" lists, one-Return confirms and the check gate only for hosts that accept them. Typed
 * finals add the exact learned alias and app name (recognizer `any`) to today's grammar. Learned rules act
 * on finals only, and `noteUse` counts a rule that decided a final (give dispatchers that are not the
 * host's /instant a non-counting lookup). Every voice decision carries a `voice` meta; the take memo's
 * details (heard target, recognizer of the sent hypothesis, near miss) ride on the response object
 * (`attachTakeDetails`) and never reach JSON.
 *
 * Visible items (design C; visible.ts): with `visibleItems`, an open form (voice or typed) first tries what
 * the take's context shows — the desktop icons or the target Finder window, from the host once per context
 * and cached ≤ 3 s — after policy and the learned steps, before the apps: an exact name opens at once
 * (`open_item`, `openFile` by token, `voice.via` "visible"), an exact app of the same name makes it a
 * did-you-mean with both (the item first), a clear sound-alike needs one Return. A final strong open form
 * that misses everything may offer Spotlight matches (≤ 3, never an act) before the check gate or the
 * agent. "lösche <visible name>" is refused. A host without the route keeps today's lane exactly.
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
    /**
     * How long a final open form waits for a context's visible items that are not cached yet (default 150 ms,
     * before the decision's own budget starts). Previews never wait: they use the cache and start a fetch.
     */
    visibleMs?: number;
  };
  /** Per-dispatch timing hook, e.g. telemetry.perfLog. Never receives text. */
  perf?: (stage: string, ms: number, fields: PerfFields) => void;
  /**
   * When set, a phase "final" grammar miss answers its fallthrough immediately and classifies in
   * the background (same classifierMs deadline); a non-null result arrives here. The agent path
   * then never waits on the classifier (it fuses hints only if they already arrived).
   */
  onLateHints?: (request: InstantRequest, hints: ClassifierHints) => void;
  /**
   * The personal dictionary (DESIGN4 §6.3): exact learned utterance aliases, app names and fixes, looked
   * up per hypothesis recognizer (`any` for typed text). Default: none.
   */
  dictionary?: DictionaryLookup;
  /** The take memo: "No, I meant X" finds the act it corrects. Only the host's /instant dispatcher has one. */
  takeMemo?: Pick<TakeMemo, "latestActed">;
  /** Common-word check of the spoken matcher's dictionary-word guard (default: lexicon.ts). */
  isCommonWord?: (word: string) => boolean;
  /**
   * The host's visible items per context (POST /tools/launcher.visibleItems, cached ≤ 3 s; design C): open
   * forms try the take's desktop icons / target Finder window before the apps, and a final open-form miss
   * may offer Spotlight matches. Absent, or a host without the route (404, not_found): today's lane exactly.
   */
  visibleItems?: VisibleItemsCache;
}

export interface DispatchOptions {
  /** This dispatch's dictionary instead of `deps.dictionary` (the learn route's regression check). */
  dictionary?: DictionaryLookup;
}

export interface InstantDispatcher {
  dispatch(request: InstantRequest, signal?: AbortSignal, options?: DispatchOptions): Promise<InstantResponse>;
  /** Preloads fend, the rate cache and the common-word lexicon so the first keystroke or take is warm. */
  warm(): Promise<void>;
  /** The same engines, for pi tools. */
  readonly engines: InstantEngines;
}

export const MAX_INSTANT_TEXT = 500;
/** Longest text a scorer sees (over-long requests still fall through to the agent, which the chip serves). */
const MAX_SCORED_TEXT = 4_000;
const PHASES: readonly InstantPhase[] = ["typing", "partial", "final"];
/** The visible-items route's contextId rule (protocol.md). */
const CONTEXT_ID = /^[A-Za-z0-9_-]{1,128}$/;
const TIMEOUT = Symbol("timeout");
const FAILED = Symbol("failed");

type Body = InstantBody;
/** A target for the Spotlight did-you-mean and the recognizer of the hypothesis it came from (`voice.source`). */
interface SpotlightTarget { target: VisibleTarget; source: string }
/** Learned fixes tried per hypothesis (longest heard phrase first). */
const MAX_FIX_TRIES = 4;

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
    visibleMs: deps.budgets?.visibleMs ?? 150,
  };
  const isWord = deps.isCommonWord ?? lexiconWord;
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

  /**
   * A typed open target: visible items first (design C, with the same steps as speech), then today's
   * Raycast-style app matching. A visible sound-alike that cannot act joins a non-decisive app list.
   */
  async function open(parsed: Extract<Parsed, { kind: "open" }>, request: InstantRequest, ctx: MatchContext, signal: AbortSignal, visible: VisibleSnapshot): Promise<Body> {
    const phase = request.phase;
    const matcher = deps.apps ? await deps.apps.get(signal) : null;
    const matches = matcher ? matcher.match(parsed.target, 8, now().getTime()) : [];
    const exact = matches[0] && matches[0].score >= 1 ? matches[0] : undefined;
    const seen = visibleStep(parsed.target, "strong", visible, { exact: exact !== undefined, top: matches[0]?.score ?? 0, paths: matches.map((match) => match.app.path) },
      isGerman(ctx.locale));
    const vd = seen?.decision ?? null;
    if (vd?.kind === "act") return visibleAct(vd, request, false);
    if (vd?.kind === "offer" && vd.decides) return choiceList(vd.matches, matches.filter((match) => match.score >= 1), false);
    const visibleOffers = vd?.kind === "offer" ? vd.matches : [];
    if (parsed.siteUrl && !exact) {
      const label = parsed.siteUrl.replace(/^https?:\/\//, "").replace(/\/$/, "");
      return openUrl(parsed.siteUrl, label, "url", `Open ${label}`, phase);
    }
    if (!matches.length) return visibleOffers.length ? choiceList(visibleOffers, [], false) : fallthrough("no_match");
    const decisive = AppMatcher.decisive(matches);
    const apps = matches.map((match) => match.app);
    if (decisive && phase === "final") {
      const title = `Open ${decisive.app.name}`;
      return { decision: "act", intent: "open_app", title, action: { type: "openApp", bundleId: decisive.app.bundleId }, confirm: false, card: appListCard(title, apps) };
    }
    if (!decisive && visibleOffers.length) return choiceList(visibleOffers, matches, false);
    const title = decisive ? `Open ${decisive.app.name}` : `${apps.length} ${apps.length === 1 ? "app matches" : "apps match"} ${quoted(parsed.target)}`;
    return { decision: "list", intent: "open_app", title, card: appListCard(title, apps) };
  }

  function refusal(): Body {
    return { decision: "refuse", code: "file_deletion_blocked", message: DELETION_REFUSAL_MESSAGE, card: refuseCard(DELETION_REFUSAL_MESSAGE) };
  }

  /**
   * "delete Slack" / "Zoom löschen": uninstalling moves the app to the Trash. "lösche Radfotos" with a visible
   * Radfotos (exact key) is file deletion. Other objects are in-app edits.
   */
  async function deleteTarget(target: string, signal: AbortSignal, visible: VisibleSnapshot = NO_VISIBLE): Promise<Body> {
    const matcher = deps.apps ? await deps.apps.get(signal) : null;
    const exact = matcher?.match(target, 8, now().getTime()).some((match) => match.score >= 1);
    if (exact) return refusal();
    const item = visible.entries.length ? visibleTarget(target) : null;
    return item && matchVisible(visible, { ...item, kind: undefined }).some((match) => match.exact) ? refusal() : fallthrough("no_match");
  }

  // ------------------------------------------------------------------ visible items (design C; visible.ts)

  function isGerman(locale: string): boolean {
    return locale.toLowerCase().startsWith("de");
  }

  /**
   * Steps 1 and 2 for one open target (after policy and the learned steps, before the apps): the visible
   * items' decision, or null when the context shows none. `apps`: an exact app (≥ 0.995), the best app score and
   * the candidates' bundle paths (an item that is one of those bundles is that app, not a visible candidate).
   */
  function visibleStep(rawTarget: string, strength: OpenStrength, visible: VisibleSnapshot, apps: { exact: boolean; top: number; paths: readonly string[] },
    german: boolean): { target: VisibleTarget; decision: VisibleDecision } | null {
    if (!visible.entries.length) return null;
    const target = visibleTarget(rawTarget);
    if (!target) return null;
    const heardIsWord = target.words.length === 1 && isWord(target.words[0]!);
    const matches = withoutApps(matchVisible(visible, target, { german, heardIsWord, sound: strength !== "bare" }), apps.paths);
    return { target, decision: matches.length ? decideVisible(matches, target, { strength, appExact: apps.exact, appTop: apps.top, heardIsWord }) : null };
  }

  /** An open_item act: at once (exact), behind one Return (a sound-alike, hosts that accept confirm), else a one-row did-you-mean. Previews list it. */
  function visibleAct(decision: Extract<VisibleDecision, { kind: "act" }>, request: InstantRequest, voice: boolean): Body {
    const row = itemRow(decision.match.entry);
    const title = `Open ${row.name}`;
    const card = openItemCard(title, row);
    if (request.phase !== "final") return { decision: "list", intent: "open_item", title, card };
    if (decision.confirm && !accepts(request, "confirm")) return choiceList([decision.match], [], voice);
    return { decision: "act", intent: "open_item", title, action: { type: "openFile", token: row.token }, confirm: decision.confirm, card };
  }

  /** "Did you mean Radfotos?" / "Did you mean…": visible (or found) rows first, then app rows, ≤ 3. */
  function choiceList(items: readonly VisibleMatch[], apps: readonly AppMatch[], voice: boolean): Body {
    const rows = choiceRows(items, apps);
    const title = didYouMeanTitle([...rows.items.map((match) => match.entry.item.name), ...rows.apps.map(spokenLabel)]);
    const card = choiceRowsCard(title, [
      ...rows.items.map((match): ChoiceRow => ({ item: itemRow(match.entry) })),
      ...rows.apps.map((match): ChoiceRow => ({ app: match.app, label: spokenLabel(match) })),
    ]);
    return { decision: "list", intent: "open_item", title, card, ...(voice ? { voice: { didYouMean: true } } : {}) };
  }

  /** The words of a Spotlight did-you-mean (design C step 4): each target's words and its joined word, ≤ 6 terms. */
  function spotlightGroups(targets: readonly VisibleTarget[]): string[][] {
    const groups: string[][] = [];
    let total = 0;
    const add = (group: string[]): void => {
      const terms = group.filter((term) => term.length > 0 && term.length <= 64);
      if (!terms.length || total + terms.length > 6 || groups.some((g) => g.join(" ") === terms.join(" "))) return;
      groups.push(terms);
      total += terms.length;
    };
    for (const target of targets) {
      const words = target.heard.split(" ").filter(Boolean);
      add([words.join("")]);
      if (words.length > 1) add(words);
    }
    return groups;
  }

  /**
   * Step 4, finals only: Spotlight (`searchFiles`, home) for the open-form targets; names whose key equals or
   * starts with a target's key become a did-you-mean list (≤ 3, never an act). Null when nothing is found
   * in the file-search final budget.
   */
  async function spotlightOffer(targets: readonly SpotlightTarget[], request: InstantRequest, voice: boolean, signal: AbortSignal): Promise<{ body: Body; target: SpotlightTarget } | null> {
    const search = deps.searchFiles;
    const nameGroups = spotlightGroups(targets.map((t) => t.target));
    if (!search || !nameGroups.length) return null;
    const budget = deadline(signal, budgets.fileSearchFinalMs);
    try {
      const work = Promise.resolve().then(() => search({ ...(request.contextId ? { contextId: request.contextId } : {}), nameGroups, scopes: ["home"], maxResults: 50 }, budget.signal));
      const raw = await race(work, budget.signal);
      if (raw === TIMEOUT || raw === FAILED) return null;
      const items = Array.isArray(raw) ? raw as readonly FileCandidate[] : (raw as FileSearchResult | null)?.items;
      if (!Array.isArray(items)) return null;
      const entries = items.flatMap((item) => {
        const parsed = parseFileCandidate(item);
        return parsed.ok && userVisible(parsed.value.path) ? [visibleEntry(parsed.value)] : [];
      });
      for (const t of targets) {
        const found = foundMatches(entries, t.target);
        if (found.length) return { body: choiceList(found, [], voice), target: t };
      }
      return null;
    } finally {
      budget.dispose();
    }
  }

  function system(parsed: Extract<Parsed, { kind: "system" }>, phase: InstantPhase): Body {
    const action: HostAction = parsed.value === undefined ? { type: "system", op: parsed.op } : { type: "system", op: parsed.op, value: parsed.value };
    if (phase === "final") return { decision: "act", intent: "system", title: parsed.title, action, confirm: false };
    return { decision: "answer", intent: "system", title: parsed.title, card: noticeCard("info", parsed.title, parsed.title) };
  }

  // ------------------------------------------------------------------ voice: the spoken open path and the URL guard

  /**
   * A spoken open target (DESIGN4 §5.2): AppMatcher.resolveSpoken decides act / offer / nothing. A final acts
   * (its card lists the near alternatives); a partial previews one row; an offer is a "Did you mean …?"
   * list. `info` collects what arbitration and the take memo need (heard, candidates, evidence).
   */
  async function spokenOpen(parsed: Extract<Parsed, { kind: "open" }>, request: InstantRequest, signal: AbortSignal, info: LaneOutcome,
    visible: VisibleSnapshot): Promise<Body> {
    const phase = request.phase;
    const matcher = deps.apps ? await deps.apps.get(signal) : null;
    const strength = openStrength(parsed);
    const resolved = matcher?.resolveSpoken(parsed.target, strength, {
      ...(info.german ? { german: true } : {}), ...(deps.isCommonWord ? { isCommonWord: deps.isCommonWord } : {}), nowMs: now().getTime(),
    });
    if (resolved?.heard) info.heard = resolved.heard;
    info.matches = resolved?.matches ?? [];
    // Visible items first (design C steps 1–2): an exact desktop or Finder-window item opens at once unless an
    // app has exactly that name too (then both are offered, the item first); a clear sound-alike needs one Return.
    const seen = visibleStep(parsed.target, strength, visible, {
      exact: resolved?.exact !== undefined, top: resolved?.matches[0]?.score ?? 0, paths: (resolved?.matches ?? []).map((match) => match.app.path),
    }, info.german);
    const vd = seen?.decision ?? null;
    if (seen && vd && (vd.kind === "act" || vd.decides)) {
      info.heard = seen.target.heard;
      info.via = "visible";
      if (vd.kind === "act") {
        info.literal = vd.match.exact;
        info.bare = strength === "bare";
        const body = visibleAct(vd, request, true);
        if (body.decision === "list" && body.voice?.didYouMean) info.visibleOffers = [vd.match];
        return body;
      }
      const apps = (resolved?.matches ?? []).filter((match) => match.score >= SPOKEN.exactScore && (match.reason === "exact" || match.reason === "alias"));
      info.visibleOffers = vd.matches;
      info.offers = apps;
      return choiceList(vd.matches, apps, true);
    }
    const visibleOffers = vd?.kind === "offer" ? vd.matches : [];
    // A known site name ("open youtube") opens its home page unless an installed app has exactly that name.
    if (parsed.siteUrl && !resolved?.exact) {
      const label = parsed.siteUrl.replace(/^https?:\/\//, "").replace(/\/$/, "");
      info.via = "exact";
      info.literal = true;
      return openUrl(parsed.siteUrl, label, "url", `Open ${label}`, phase);
    }
    const decision = resolved?.decision;
    // Visible sound-alikes join the apps' "Did you mean …?" rows (visible first); an app act wins.
    if (seen && visibleOffers.length && decision?.kind !== "act") {
      info.heard = seen.target.heard;
      info.via = "visible";
      info.visibleOffers = visibleOffers;
      info.offers = decision?.matches ?? [];
      return choiceList(visibleOffers, info.offers, true);
    }
    if (!decision) return fallthrough("no_match");
    if (decision.kind === "offer") {
      info.offers = decision.matches;
      info.via = decision.matches[0]?.reason === "sound" ? "sound" : "exact";
      return didYouMean(decision.matches);
    }
    const match = decision.match;
    const title = `Open ${spokenLabel(match)}`;
    info.via = match.reason === "sound" ? "sound" : "exact";
    info.literal = match.reason !== "sound";
    info.bare = strength === "bare";
    info.acted = match;
    if (phase !== "final") return { decision: "list", intent: "open_app", title, card: appRowsCard(title, [{ app: match.app, label: spokenLabel(match) }]) };
    // The reader's record: the app, then the close alternatives "Not this" offers (the take memo counts them as offered).
    const near = resolved.matches.filter((other) => other !== match && other.score >= SPOKEN.offerScore && other.score >= match.score - SPOKEN.offerWindow);
    const rows = [match, ...near].slice(0, VOICE.maxDidYouMean).map((row) => ({ app: row.app, label: spokenLabel(row) }));
    return { decision: "act", intent: "open_app", title, action: { type: "openApp", bundleId: match.app.bundleId }, confirm: false, card: appRowsCard(title, rows) };
  }

  /** "Did you mean Pages?" / "Did you mean…" (DESIGN4 §5.3): ≤ 3 rows titled with the spoken labels. */
  function didYouMean(matches: readonly AppMatch[]): Body {
    const rows = matches.slice(0, VOICE.maxDidYouMean);
    const title = didYouMeanTitle(rows.map(spokenLabel));
    return {
      decision: "list", intent: "open_app", title,
      card: appRowsCard(title, rows.map((row) => ({ app: row.app, label: spokenLabel(row) }))),
      voice: { didYouMean: true },
    };
  }

  /**
   * Voice URL guard (DESIGN4 §5.4): a spoken domain opens at once only when it is a known site; any other
   * domain gets one Return (`confirm: true`) — for hosts that accept "confirm"; others keep today's act.
   */
  function spokenUrl(parsed: Extract<Parsed, { kind: "url" }>, request: InstantRequest, info: LaneOutcome): Body {
    info.heard = parsed.label;
    info.via = "url";
    info.literal = true;
    if (request.phase === "final" && accepts(request, "confirm") && !isKnownSpokenHost(hostOf(parsed.url))) {
      return { decision: "act", intent: "url", title: `Open ${parsed.label}`, action: { type: "openURL", url: parsed.url }, confirm: true };
    }
    return openUrl(parsed.url, parsed.label, "url", `Open ${parsed.label}`, request.phase);
  }

  // ------------------------------------------------------------------ learned rules (DESIGN4 §6.3 steps 1, 2, 4)

  /**
   * The act a learned alias performs, or null. Policy last: the target must still be a closed SafeTarget,
   * and an app must be in the host's index (an unknown index never acts on a learned app).
   */
  function learnedAct(target: SafeTarget, matcher: AppMatcher | null, display?: string): { body: Body; app?: AppMatch } | null {
    const checked = parseSafeTarget(target);
    if (!checked) return null;
    const action = safeTargetToHostAction(checked);
    switch (checked.kind) {
      case "openApp": {
        const app = matcher?.app(checked.bundleId);
        if (!app) return null;
        const label = display?.trim() || displayName(app);
        const title = `Open ${label}`;
        return {
          body: { decision: "act", intent: "open_app", title, action, confirm: false, card: appRowsCard(title, [{ app, label }]) },
          app: { app, score: 1, rank: 1, reason: "exact", label },
        };
      }
      case "openURL": {
        const label = checked.url.replace(/^https?:\/\//, "").replace(/\/$/, "");
        return { body: { decision: "act", intent: "url", title: `Open ${label}`, action, confirm: false } };
      }
      case "system":
        return { body: { decision: "act", intent: "system", title: systemTitle(checked), action, confirm: false } };
    }
  }

  /**
   * Steps 1 and 2 for one text: an exact utterance alias, else an exact learned app name inside an open
   * form (never a name said alone). The caller ran the policy on the words first.
   */
  async function learnedRule(text: string, n: Normalized, parsed: Parsed | null, recognizer: string, dictionary: DictionaryLookup,
    matcher: () => Promise<AppMatcher | null>, info: LaneOutcome): Promise<Body | null> {
    const core = spokenCore(n.lower);
    const alias = dictionary.alias(text, recognizer) ?? (core && core !== n.lower ? dictionary.alias(core, recognizer) : null);
    if (alias) {
      const acted = learnedAct(alias.value, await matcher());
      if (acted) {
        info.via = "alias";
        info.learned = alias.ref;
        info.literal = true;
        // An alias for a name said alone ("Spotify.") is still a bare name: never immediate from a secondary.
        info.bare = parsed?.kind === "open" && openStrength(parsed) === "bare";
        if (acted.app) info.acted = acted.app;
        return acted.body;
      }
    }
    if (parsed?.kind !== "open" || openStrength(parsed) === "bare") return null;
    const heard = foldPhrase(spokenHead(parsed.target));
    const name = heard ? dictionary.appName(heard, recognizer) : null;
    if (!name) return null;
    const acted = learnedAct({ kind: "openApp", bundleId: name.value.bundleId }, await matcher(), name.value.display);
    if (!acted) return null;
    info.via = "learned";
    info.learned = name.ref;
    info.literal = true;
    info.heard = heard;
    if (acted.app) info.acted = acted.app;
    return acted.body;
  }

  // ------------------------------------------------------------------ the lane for one hypothesis

  interface LaneOptions {
    sent: boolean;
    firstTier: boolean;
    /** Learned rules (finals only). */
    learned: boolean;
    /** May reach the host's file search (the sent hypothesis only: alternatives never cost a host call). */
    host: boolean;
    dictionary: DictionaryLookup;
    matcher: () => Promise<AppMatcher | null>;
    /** The take's visible items (fetched once per context before the lane runs; NO_VISIBLE when none). */
    visible: VisibleSnapshot;
  }

  /**
   * One hypothesis through the lane (DESIGN4 §6.3): policy on the original words, then (finals) the exact
   * learned alias and app name, the grammar with the spoken matcher, and the learned fixes, which may only
   * turn a miss into a hit and go through the policy and the grammar again.
   */
  async function lane(hypothesis: VoiceHypothesis, request: InstantRequest, options: LaneOptions, signal: AbortSignal): Promise<LaneOutcome> {
    const locale = hypothesis.locale ?? request.locale;
    const n = normalize(hypothesis.text, locale);
    const ctx: MatchContext = { now: now(), locale: displayLocale(locale, n.lang), webSearchTemplate: webSearchTemplate() };
    const german = ctx.locale.toLowerCase().startsWith("de") || n.lang === "de";
    const parsed = parseInstant(n, ctx, { voice: true });
    const out: LaneOutcome = {
      hypothesis, sent: options.sent, firstTier: options.firstTier, n, parsed, german, deletion: mentionsDeletion(n), body: null, offers: [], matches: [],
    };
    // Policy on the original words, before anything learned can apply.
    if (parsed?.kind === "refuse") {
      out.policy = "refuse";
      out.deletion = true;
      out.body = refusal();
      return out;
    }
    if (parsed?.kind === "delete_target") {
      out.deletion = true;
      out.body = await deleteTarget(parsed.target, signal, options.visible);
      out.policy = out.body.decision === "refuse" ? "refuse" : "delete_target";
      return out;
    }
    if (parsed?.kind === "fallthrough" && parsed.reason !== "unknown_place") {
      out.policy = parsed.reason;
      out.body = fallthrough(parsed.reason);
      return out;
    }
    const learned = options.learned && request.phase === "final" && !out.deletion;
    if (learned) {
      const rule = await learnedRule(hypothesis.text, n, parsed, hypothesis.source, options.dictionary, options.matcher, out);
      if (rule) {
        out.body = rule;
        return out;
      }
    }
    if (parsed?.kind === "fallthrough") out.body = fallthrough(parsed.reason);
    else if (parsed && !(parsed.kind === "file_search" && !options.host)) out.body = await resolve(parsed, request, ctx, signal, out, options.visible);
    if (learned && !isActionable(out.body)) await applyFixes(out, request, options, signal);
    return out;
  }

  /** Step 4: learned fixes, longest heard phrase first; the first rewrite that turns this miss into a hit wins. */
  async function applyFixes(out: LaneOutcome, request: InstantRequest, options: LaneOptions, signal: AbortSignal): Promise<void> {
    const fixes = options.dictionary.fixes(out.hypothesis.source);
    if (!fixes.length) return;
    const folded = ` ${foldPhrase(out.hypothesis.text)} `;
    let tries = 0;
    for (const fix of fixes) {
      const heard = foldPhrase(fix.value.heard);
      if (!heard || !folded.includes(` ${heard} `) || isRefusedPhrase(fix.value.intended)) continue;
      if (++tries > MAX_FIX_TRIES) return;
      const text = folded.replace(` ${heard} `, ` ${fix.value.intended} `).trim();
      // Policy again: the rewritten words go through the whole lane without learned rules.
      const again = await lane({ ...out.hypothesis, text }, request, { ...options, learned: false, host: false }, signal);
      if (again.policy || again.deletion || !isActionable(again.body)) continue;
      // A learned rule never acts beyond the closed targets (openApp, http(s) openURL, volume.*): a fix that rewrites
      // the words into a display sleep (or anything else) is no hit.
      if (again.body!.decision === "act" && !safeTargetOf(again.body!.action)) continue;
      out.body = again.body;
      out.via = "learned";
      out.learned = fix.ref;
      out.literal = again.literal ?? true;
      out.bare = again.bare;
      out.heard ??= again.heard;
      if (again.acted) out.acted = again.acted;
      out.offers = [];
      return;
    }
  }

  async function resolve(parsed: Parsed, request: InstantRequest, ctx: MatchContext, signal: AbortSignal, voice?: LaneOutcome,
    visible: VisibleSnapshot = NO_VISIBLE): Promise<Body | null> {
    switch (parsed.kind) {
      case "refuse":
        return refusal();
      case "delete_target":
        return deleteTarget(parsed.target, signal, visible);
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
        return voice ? spokenOpen(parsed, request, signal, voice, visible) : open(parsed, request, ctx, signal, visible);
      case "url":
        return voice ? spokenUrl(parsed, request, voice) : openUrl(parsed.url, parsed.label, "url", `Open ${parsed.label}`, request.phase);
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

  // ------------------------------------------------------------------ voice finals: arbitration (DESIGN4 §4.5)

  /** What a voice final decided, before the dispatcher adds timing and scope. */
  interface Settled {
    body: Body;
    details: TakeDetails;
    /** The learned rule that decided (noteUse). */
    learned?: DictionaryEntryRef;
    via?: VoiceVia;
    /**
     * The take ended in a fallthrough after an open-form miss (no app act or offer, no visible match, no
     * policy): the targets a Spotlight did-you-mean may try first (design C step 4; voiceFinal runs it).
     */
    spotlight?: SpotlightTarget[];
  }

  /** The decision with its `voice` meta (act, list and fallthrough carry one; answers and refusals cannot). */
  function withVoice(body: Body, meta: VoiceMeta | undefined): Body {
    if (body.decision !== "act" && body.decision !== "list" && body.decision !== "fallthrough") return body;
    const { voice: _previous, ...rest } = body;
    return (meta ? { ...rest, voice: meta } : rest) as Body;
  }

  function listRows(body: Body): string[] {
    // App rows only: a file row (open_item) is never offered for learning.
    if (body.decision !== "list" || (body.intent !== "open_app" && body.intent !== "open_item")) return [];
    const rows: string[] = [];
    for (const element of Object.values(body.card.elements)) {
      const primary = element.type === "Item" ? element.on?.primary : undefined;
      if (primary?.action === "openApp" && typeof primary.params?.bundleId === "string") rows.push(primary.params.bundleId);
    }
    return rows;
  }

  /**
   * The settled decision for outcome `o`: its `voice` meta (heard, deciding recognizer, via, learned rule)
   * and the take memo's details — the heard target and recognizer of the hypothesis the host sent as text,
   * the near miss, and only the bundle ids the card shows as rows.
   */
  function settle(take: VoiceTake, sent: LaneOutcome, o: LaneOutcome, body: Body, via: VoiceVia | undefined,
    extra: Pick<VoiceMeta, "check" | "correctsTakeId"> = {}, nearMiss?: TakeDetails["nearMiss"]): Settled {
    const meta = voiceMeta({
      ...(o.heard ? { heard: o.heard } : {}),
      ...(take.legacy ? {} : { source: o.hypothesis.source }),
      ...(via ? { via } : {}),
      ...(o.learned ? { learnedEntryId: o.learned.id } : {}),
      ...(body.decision === "list" && body.voice?.didYouMean ? { didYouMean: true } : {}),
      ...extra,
    });
    const details: TakeDetails = {
      heard: sent.heard ?? "",
      recognizer: take.hypotheses[take.sent]!.source,
      offered: listRows(body),
      ...(nearMiss ? { nearMiss } : {}),
    };
    return { body: withVoice(body, meta), details, ...(o.learned ? { learned: o.learned } : {}), ...(via ? { via } : {}) };
  }

  /** The highest-confidence outcome (absent confidence counts lowest), earliest first on ties. */
  function mostConfident(outcomes: readonly LaneOutcome[]): LaneOutcome {
    return outcomes.reduce((best, o) => ((o.hypothesis.confidence ?? -1) > (best.hypothesis.confidence ?? -1) ? o : best));
  }

  /** How a first-tier decision reads: its own evidence, or "peer" when the other language rescued the take. */
  function firstTierVia(o: LaneOutcome, agree: boolean): VoiceVia | undefined {
    if (o.via === "alias" || o.via === "learned" || o.via === "sound" || o.via === "url" || o.via === "visible") return o.via;
    return !o.sent && !agree && o.hypothesis.role === "peer" ? "peer" : o.via;
  }

  /**
   * An act that needs one Return: `confirm: true` for hosts that accept it; otherwise only the host's own
   * pick acts (today's behaviour), and anything else is not acted on (null: continue with the next step).
   */
  function hold(request: InstantRequest, take: VoiceTake, sent: LaneOutcome, o: LaneOutcome, via: VoiceVia | undefined, needsReturn: boolean): Settled | null {
    const body = o.body!;
    if (!needsReturn || body.decision !== "act") return settle(take, sent, o, body, via);
    if (accepts(request, "confirm")) return settle(take, sent, o, { ...body, confirm: true }, via);
    return o.sent ? settle(take, sent, o, body, via) : null;
  }

  /**
   * "No, I meant X" / "nein, ich meinte X" / "nein, X" right after an act (the memo's latest act, ≤ 2 min):
   * X goes through the lane — as said, else as an open form ("No, I meant Notion" → "open Notion") — and the
   * decision names the corrected take (`voice.correctsTakeId`). Nothing is learned here: the host asks and
   * calls POST /dictionary/learn. A bare "nein, X" counts only when X acts; "I meant X" may also offer.
   * Arbitration still governs the take: another first-tier hypothesis's deletion or refusal, or a host pick
   * that decides on its own, leaves it to arbitrate(); a lone peer below τ needs one Return; and only a
   * closed target is named as a correction (anything else would offer a rule learning cannot store).
   */
  async function correct(request: InstantRequest, take: VoiceTake, signal: AbortSignal, dictionary: DictionaryLookup,
    matcher: () => Promise<AppMatcher | null>, visible: VisibleSnapshot): Promise<Settled | null> {
    const memo = deps.takeMemo;
    if (!memo || request.phase !== "final") return null;
    for (const index of [take.sent, ...take.firstTier.filter((i) => i !== take.sent)]) {
      const hypothesis = take.hypotheses[index]!;
      const correction = correctionTarget(hypothesis.text);
      if (!correction) continue;
      let latest: ReturnType<typeof memo.latestActed>;
      try {
        latest = memo.latestActed();
      } catch {
        latest = undefined;
      }
      if (!latest || latest.takeId === request.takeId) return null;
      const options: LaneOptions = { sent: true, firstTier: true, learned: true, host: false, dictionary, matcher, visible };
      // Policy first: when another first-tier hypothesis is refused or names a deletion, arbitration decides
      // the take (it refuses it, or holds it), never the correction.
      if (take.firstTier.some((i) => i !== index && namesDeletion(take.hypotheses[i]!, request))) return null;
      // A peer's correction never overrides the host's pick when that decides on its own: arbitration does.
      if (index !== take.sent) {
        const own = await lane(take.hypotheses[take.sent]!, request, options, signal);
        if (own.policy || isActionable(own.body)) return null;
      }
      let o = await lane({ ...hypothesis, text: correction.target }, request, options, signal);
      const name = !o.policy && !isActionable(o.body) && (o.parsed === null || (o.parsed.kind === "open" && openStrength(o.parsed) === "bare"));
      if (name && correction.target.split(/\s+/).length <= 3) {
        const opened = await lane({ ...hypothesis, text: `open ${correction.target}` }, request, options, signal);
        if (opened.policy === "refuse" || isActionable(opened.body) || opened.offers.length) o = opened;
      }
      const sent: LaneOutcome = { ...o, sent: true };
      if (o.policy === "refuse") return settle(take, sent, o, o.body!, undefined);
      if (!o.body || o.policy || !(isActionable(o.body) || (correction.explicit && o.offers.length))) return null;
      let body = o.body;
      // A lone Phase A peer below τ needs one Return, as in arbitration (a host without "confirm": no correction).
      if (index !== take.sent && body.decision === "act" && hypothesis.role === "peer" && !((hypothesis.confidence ?? -1) >= VOICE.peerConfidence)) {
        if (!accepts(request, "confirm")) return null;
        body = { ...body, confirm: true };
      }
      // Only a closed target can be learned: an act beyond them (a display sleep, a visible item) is not offered as
      // a correction, and neither is a take that opened a file or folder (nothing is learned from visible items).
      const learnable = (body.decision !== "act" || safeTargetOf(body.action) !== undefined) && !(latest as TakeRecord).item;
      return settle(take, sent, o, body, o.via, learnable ? { correctsTakeId: latest.takeId } : {});
    }
    return null;
  }

  /**
   * A voice final (DESIGN4 §4.5, §6.3): the first tier through the lane, policy first, agreement, the
   * secondary tier, "Did you mean …?", the check gate, else a fallthrough with the near miss.
   */
  async function arbitrate(request: InstantRequest, take: VoiceTake, signal: AbortSignal, dictionary: DictionaryLookup,
    matcher: () => Promise<AppMatcher | null>, visible: VisibleSnapshot): Promise<Settled> {
    const hypotheses = take.hypotheses;
    const sentHypothesis = hypotheses[take.sent]!;
    const options = (index: number, firstTier: boolean): LaneOptions => ({
      sent: index === take.sent, firstTier, learned: true, host: index === take.sent, dictionary, matcher, visible,
    });

    const correction = await correct(request, take, signal, dictionary, matcher, visible);
    if (correction) return correction;

    const first: LaneOutcome[] = [];
    for (const index of take.firstTier) first.push(await lane(hypotheses[index]!, request, options(index, true), signal));
    const sent = first.find((o) => o.sent) ?? first[0]!;
    // Policy first: a refusal of the primary or any peer refuses the take.
    const refused = first.find((o) => o.policy === "refuse");
    if (refused) return settle(take, sent, refused, refused.body!, undefined);

    const secondaryDeletion = take.secondary.some((index) => mentionsDeletion(normalize(hypotheses[index]!.text, hypotheses[index]!.locale ?? request.locale)));
    // Deletion vocabulary in any hypothesis turns the alternatives off (and keeps them out of the near miss).
    const deletion = secondaryDeletion || first.some((o) => o.deletion);
    const blocked = (o: LaneOutcome): boolean => o.policy !== undefined;
    const others = deletion ? [] : hypotheses.filter((_, index) => index !== take.sent).map((hypothesis) => hypothesis.text);
    // The heard name and its candidates come from one hypothesis: the sent one, else the first with candidates.
    const missFrom = sent.matches.length || sent.heard ? sent : first.find((o) => o.matches.length) ?? sent;
    const nearMiss = () => nearMissOf(missFrom.heard, missFrom.matches, others, sentHypothesis.text);
    // The host's pick decides the policy of its take: a compound, deictic or deletion-object request goes to
    // the agent whole, never as a part another recognizer heard ("Open Safari" of "Open Safari and then …").
    if (sent.policy) {
      return settle(take, sent, sent, fallthrough(sent.policy === "deictic" || sent.policy === "compound" ? sent.policy : "no_match"), undefined, {}, nearMiss());
    }
    // Another first-tier hypothesis that is a compound or names a deletion (an object, or words it cannot act
    // on) argues against acting at once; a deictic word in the other language is usually a mishearing.
    const veto = first.some((o) => o.policy === "compound" || o.policy === "delete_target" || (o.deletion && !isActionable(o.body)));
    const alternativesOff = take.legacy || deletion || first.some(blocked);

    // First tier: one actionable result, or several that agree, decides.
    const acts = first.filter((o) => !blocked(o) && isActionable(o.body));
    if (acts.length) {
      const signatures = new Set(acts.map((o) => decisionSignature(o.body!)));
      if (signatures.size === 1) {
        const agree = acts.length >= 2;
        // Agreeing hypotheses act at once when one of them needs no Return ("Radfotos" exact next to "rad photos").
        const settled = (o: LaneOutcome): boolean => !(o.body?.decision === "act" && o.body.confirm);
        const pool = agree && acts.some(settled) ? acts.filter(settled) : acts;
        const chosen = pool.find((o) => o.sent) ?? mostConfident(pool);
        const lowPeer = !agree && chosen.hypothesis.role === "peer" && !((chosen.hypothesis.confidence ?? -1) >= VOICE.peerConfidence);
        const done = hold(request, take, sent, chosen, firstTierVia(chosen, agree), veto || lowPeer);
        if (done) return done;
      } else if (acts.every((o) => o.acted && o.body?.decision === "act" && o.body.action.type === "openApp")) {
        // Peers that heard different apps: "Did you mean …?" with both, sent first.
        const ordered = [sent, ...acts.filter((o) => o !== sent).sort((a, b) => (b.hypothesis.confidence ?? -1) - (a.hypothesis.confidence ?? -1))]
          .filter((o) => acts.includes(o));
        const rows: AppMatch[] = [];
        for (const match of [...ordered.map((o) => o.acted!), ...mergeOffers(first.map((o) => o.offers))]) {
          if (rows.length < VOICE.maxDidYouMean && !rows.some((row) => row.app.bundleId === match.app.bundleId)) rows.push(match);
        }
        // The list is no learned decision, even when one peer's act came from a rule.
        const { learned: _rule, ...asked } = sent;
        return settle(take, sent, { ...asked, heard: sent.heard ?? ordered[0]?.heard }, didYouMean(rows), "peer", {}, nearMiss());
      } else {
        const lead = acts.find((o) => o.sent) ?? mostConfident(acts);
        const done = hold(request, take, sent, lead, firstTierVia(lead, false), true);
        if (done) return done;
      }
    } else if (!alternativesOff) {
      // Secondary tier: a consistent literal app act acts; a bare name or anything else needs one Return. A
      // gated alternative only ever offers a closed target (an app, an http(s) page, the volume).
      const views: FirstTierView[] = first.map((o) => ({ parsed: o.parsed, n: o.n, german: o.german }));
      let held: LaneOutcome | undefined;
      for (const index of take.secondary) {
        const o = await lane(hypotheses[index]!, request, options(index, false), signal);
        const body = o.body;
        if (o.policy || o.deletion || body?.decision !== "act" || !safeTargetOf(body.action)) continue;
        if (body.action.type === "openApp" && o.literal && !o.bare && o.parsed?.kind === "open"
          && consistentAlternative(await matcher(), views, body.action.bundleId, o.parsed.target, o.german)) {
          return settle(take, sent, o, body, "secondary");
        }
        held ??= o;
      }
      if (held?.body?.decision === "act" && accepts(request, "confirm")) return settle(take, sent, held, { ...held.body, confirm: true }, "secondary");
    }

    // Open-form miss → "Did you mean …?" (≤ 3), never for a compound or a deletion. Visible items first.
    if (!first.some((o) => o.policy === "compound" || o.policy === "delete_target" || o.deletion)) {
      const offering = first.filter((o) => !blocked(o) && (o.offers.length || o.visibleOffers?.length));
      if (offering.length) {
        const rows = mergeOffers(offering.map((o) => o.offers));
        const items = mergeVisibleOffers(offering.map((o) => o.visibleOffers ?? []));
        if (items.length) {
          const lead = items[0]!.entry.item.token;
          const from = offering.find((o) => o.sent && o.visibleOffers?.length) ?? offering.find((o) => o.visibleOffers?.some((m) => m.entry.item.token === lead)) ?? offering[0]!;
          return settle(take, sent, from, choiceList(items, rows, true), "visible", {}, nearMiss());
        }
        const from = offering.find((o) => o.sent) ?? offering.find((o) => o.offers.some((m) => m.app.bundleId === rows[0]?.app.bundleId)) ?? offering[0]!;
        return settle(take, sent, from, didYouMean(rows), from.sent ? from.via : "peer", {}, nearMiss());
      }
    }

    // Check gate, else the agent with the near miss (a Spotlight did-you-mean may come first: voiceFinal).
    const reason: FallthroughReason = sent.body?.decision === "fallthrough" ? sent.body.reason : "no_match";
    const policyMiss = first.some((o) => o.policy === "deictic" || o.policy === "compound" || o.policy === "delete_target");
    const searchable = reason === "no_match" && !policyMiss && !deletion ? spotlightTargets(first) : [];
    const spotlight = searchable.length ? { spotlight: searchable } : {};
    if (reason === "no_match" && !policyMiss && checkGate(request, sentHypothesis, first.map((o) => o.hypothesis))) {
      return { ...settle(take, sent, sent, fallthrough("low_confidence"), undefined, { check: true }, nearMiss()), ...spotlight };
    }
    return { ...settle(take, sent, sent, fallthrough(reason), undefined, {}, nearMiss()), ...spotlight };
  }

  /**
   * The open-form targets of a missed take for the Spotlight did-you-mean: strong open forms only (an explicit
   * open verb; weak verbs and names said alone go to the agent as today), the host's pick first, ≤ 3 keys.
   */
  function spotlightTargets(first: readonly LaneOutcome[]): SpotlightTarget[] {
    const out: SpotlightTarget[] = [];
    for (const o of [...first.filter((x) => x.sent), ...first.filter((x) => !x.sent)]) {
      if (o.policy || o.deletion || o.parsed?.kind !== "open" || o.parsed.siteUrl || openStrength(o.parsed) !== "strong") continue;
      const target = visibleTarget(o.parsed.target);
      if (target && target.key.length >= 3 && !out.some((t) => t.target.key === target.key)) out.push({ target, source: o.hypothesis.source });
    }
    return out.slice(0, 3);
  }

  interface VoiceDecision extends Settled {
    /** Content-free grammar label of the sent hypothesis (perf). */
    parsed: string;
    /** The sent hypothesis's cleaned text (classifier hints only; never logged). */
    text: string;
  }

  /**
   * A voice final under one budget (60 ms, or the sent hypothesis's own: file search, first rate download).
   * The take's visible items are fetched before it (≤ visibleMs when not cached); a Spotlight did-you-mean
   * after a missed open form runs after it, in the file-search final budget, only for hosts that serve them.
   */
  async function voiceFinal(request: InstantRequest, signal: AbortSignal, dictionary: DictionaryLookup): Promise<VoiceDecision> {
    const take = voiceTake(request);
    const sentHypothesis = take.hypotheses[take.sent]!;
    const locale = sentHypothesis.locale ?? request.locale;
    const n = normalize(sentHypothesis.text, locale);
    const parsed = parseInstant(n, { now: now(), locale: displayLocale(locale, n.lang), webSearchTemplate: webSearchTemplate() }, { voice: true });
    const visible = await visibleFor(request, () => needsVisible(parsed) || take.firstTier.some((index) => {
      const hypothesis = take.hypotheses[index]!;
      if (index !== take.sent && needsVisible(parseVoice(hypothesis, request))) return true;
      return deps.takeMemo !== undefined && correctionTarget(hypothesis.text) !== null;
    }), signal);
    const budget = deadline(signal, parsed && parsed.kind !== "fallthrough" ? budgetFor(parsed, "final") : budgets.defaultMs);
    let apps: Promise<AppMatcher | null> | undefined;
    const matcher = () => (apps ??= deps.apps ? deps.apps.get(budget.signal) : Promise.resolve(null));
    const label = { parsed: parsed?.kind ?? "none", text: n.text };
    let result: Settled | typeof TIMEOUT | typeof FAILED;
    try {
      result = await race(arbitrate(request, take, budget.signal, dictionary, matcher, visible), budget.signal);
    } finally {
      budget.dispose();
    }
    if (result !== TIMEOUT && result !== FAILED) {
      const { spotlight, ...settled } = result;
      if (spotlight?.length && visible.supported) {
        const found = await spotlightOffer(spotlight, request, true, signal);
        if (found) {
          const meta = voiceMeta({ heard: found.target.target.heard, ...(take.legacy ? {} : { source: found.target.source }), didYouMean: true });
          return { body: withVoice(found.body, meta), details: { ...settled.details, offered: [] }, ...label };
        }
      }
      return { ...settled, ...label };
    }
    const meta = voiceMeta(take.legacy ? {} : { source: sentHypothesis.source });
    return { body: withVoice(fallthrough(result === TIMEOUT ? "timeout" : "no_match"), meta), details: { recognizer: sentHypothesis.source }, ...label };
  }

  /** Open forms and deletion objects consult the visible items (open and refuse); nothing else waits for them. */
  function needsVisible(parsed: Parsed | null): boolean {
    return parsed?.kind === "open" || parsed?.kind === "delete_target";
  }

  function parseVoice(hypothesis: VoiceHypothesis, request: InstantRequest): Parsed | null {
    const locale = hypothesis.locale ?? request.locale;
    const n = normalize(hypothesis.text, locale);
    return parseInstant(n, { now: now(), locale: displayLocale(locale, n.lang), webSearchTemplate: webSearchTemplate() }, { voice: true });
  }

  /**
   * The request context's visible items when `needed()`: the cache at once; a final waits ≤ visibleMs for a
   * fetch (then goes on without, the fetch still fills the cache); typing and partials never wait, they start
   * the fetch for the next keystroke or partial. NO_VISIBLE without the dep, a context or a need.
   */
  async function visibleFor(request: InstantRequest, needed: () => boolean, signal: AbortSignal): Promise<VisibleSnapshot> {
    const cache = deps.visibleItems;
    const contextId = request.contextId;
    if (!cache || typeof contextId !== "string" || !CONTEXT_ID.test(contextId) || !needed()) return NO_VISIBLE;
    const fresh = cache.peek(contextId);
    if (fresh) return fresh;
    if (request.phase !== "final") {
      cache.prefetch(contextId);
      return NO_VISIBLE;
    }
    const wait = deadline(signal, budgets.visibleMs);
    try {
      return await cache.get(contextId, wait.signal);
    } finally {
      wait.dispose();
    }
  }

  /** Counts a learned rule that decided a final. Never fails the decision. */
  function noteUse(dictionary: DictionaryLookup, ref: DictionaryEntryRef | undefined): void {
    if (!ref) return;
    try {
      dictionary.noteUse(ref);
    } catch {
      // Usage is a ranking hint.
    }
  }

  function blankOutcome(hypothesis: VoiceHypothesis, n: Normalized, parsed: Parsed | null, german: boolean): LaneOutcome {
    return { hypothesis, sent: true, firstTier: true, n, parsed, german, deletion: mentionsDeletion(n), body: null, offers: [], matches: [] };
  }

  /** The hypothesis's words hold deletion vocabulary, or the spoken grammar refuses them or names a deletion object. */
  function namesDeletion(hypothesis: VoiceHypothesis, request: InstantRequest): boolean {
    const locale = hypothesis.locale ?? request.locale;
    const n = normalize(hypothesis.text, locale);
    if (mentionsDeletion(n)) return true;
    const parsed = parseInstant(n, { now: now(), locale: displayLocale(locale, n.lang), webSearchTemplate: webSearchTemplate() }, { voice: true });
    return parsed?.kind === "refuse" || parsed?.kind === "delete_target";
  }

  /** Policy on the words lets learned rules apply (no refusal, deletion object, deixis or compound). */
  function learnable(parsed: Parsed | null, n: Normalized): boolean {
    if (parsed?.kind === "refuse" || parsed?.kind === "delete_target") return false;
    if (parsed?.kind === "fallthrough" && parsed.reason !== "unknown_place") return false;
    return !mentionsDeletion(n);
  }

  async function dispatch(request: InstantRequest, callerSignal?: AbortSignal, options: DispatchOptions = {}): Promise<InstantResponse> {
    const started = clock();
    const seq = typeof request?.seq === "number" && Number.isFinite(request.seq) ? request.seq : 0;
    const phase: InstantPhase = PHASES.includes(request?.phase) ? request.phase : "final";
    const signal = callerSignal ?? new AbortController().signal;
    let intentLabel = "none";
    let voiceFields: PerfFields = {};
    let details: TakeDetails | undefined;
    // Every phase and decision: the chip needs it on typing previews and on instant answers alike.
    const scope = scopeOf(request?.text);
    const finish = (body: Body): InstantResponse => {
      const elapsedMs = Math.round((clock() - started) * 10) / 10;
      const label = body.decision === "fallthrough" ? body.reason : body.decision === "refuse" ? "refuse" : body.intent;
      deps.perf?.("instant.dispatch", elapsedMs, { phase, decision: body.decision, kind: label, parsed: intentLabel, ...voiceFields });
      const response = { seq, elapsedMs, source: "grammar", ...body, ...(scope ? { scope } : {}) } as InstantResponse;
      return details ? attachTakeDetails(response, details) : response;
    };
    try {
      if (typeof request?.text !== "string" || !PHASES.includes(request.phase) || request.text.length > MAX_INSTANT_TEXT) return finish(fallthrough("no_match"));
      if (!enabled()) return finish(fallthrough("disabled"));
      const dictionary = options.dictionary ?? deps.dictionary ?? NO_DICTIONARY;
      const voice = request.inputMode === "voice" && phase !== "typing";
      if (voice && phase === "final") {
        const decided = await voiceFinal(request, signal, dictionary);
        intentLabel = decided.parsed;
        voiceFields = { hyps: request.hypotheses?.length ?? 0, ...(decided.via ? { via: decided.via } : {}) };
        details = decided.details;
        noteUse(dictionary, decided.learned);
        const body = decided.body;
        if (body.decision === "fallthrough" && body.reason !== "timeout" && !body.hints) {
          const hints = await hintsFor(body.reason, decided.text, request, phase, signal);
          if (hints) return finish({ ...body, hints });
        }
        return finish(body);
      }
      const n = normalize(request.text, request.locale);
      const ctx: MatchContext = { now: now(), locale: displayLocale(request.locale, n.lang), webSearchTemplate: webSearchTemplate() };
      const parsed = parseInstant(n, ctx, voice ? { voice: true } : {});
      intentLabel = parsed?.kind ?? "none";
      const visible = await visibleFor(request, () => needsVisible(parsed)
        || (phase === "final" && deps.takeMemo !== undefined && correctionTarget(request.text) !== null), signal);
      if (phase === "final") {
        // Typed finals (steps 1, 2 and 6 of DESIGN4 §6.3 with recognizer `any`), after "No, I meant X".
        const typed = await typedFinal(request, n, parsed, signal, dictionary, visible);
        if (typed) {
          details = typed.details;
          voiceFields = typed.via ? { via: typed.via } : {};
          noteUse(dictionary, typed.learned);
          return finish(typed.body);
        }
      }
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
      // Voice partials preview through the spoken matcher (never act; hypotheses belong to finals).
      const info = voice ? blankOutcome({ text: request.text, source: RECOGNIZERS.any, role: "primary" }, n, parsed, ctx.locale.toLowerCase().startsWith("de") || n.lang === "de") : undefined;
      const budget = deadline(signal, budgetFor(parsed, phase));
      let body: Body | null | typeof TIMEOUT | typeof FAILED;
      try {
        body = await race(resolve(parsed, request, ctx, budget.signal, info, visible), budget.signal);
      } finally {
        budget.dispose();
      }
      if (body === TIMEOUT) return finish(fallthrough("timeout"));
      if (body === FAILED || !body) {
        const hints = await hintsFor("no_match", n.text, request, phase, signal);
        return finish(hints ? { decision: "fallthrough", reason: "no_match", hints } : fallthrough("no_match"));
      }
      if (info) body = withVoice(body, voiceMeta({ ...(info.heard ? { heard: info.heard } : {}), ...(info.via ? { via: info.via } : {}), ...(body.decision === "list" && body.voice?.didYouMean ? { didYouMean: true } : {}) }));
      // A typed open-form miss (design C step 4): a Spotlight did-you-mean before the agent, for hosts that serve visible items.
      if (phase === "final" && !voice && parsed.kind === "open" && !parsed.siteUrl && visible.supported
        && body.decision === "fallthrough" && body.reason === "no_match") {
        const target = visibleTarget(parsed.target);
        const found = target && target.key.length >= 3 ? await spotlightOffer([{ target, source: RECOGNIZERS.any }], request, false, signal) : null;
        if (found) return finish(found.body);
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

  /**
   * A typed final's learned steps: "No, I meant X" right after an act, then the exact learned alias and app
   * name scoped to `any` (DESIGN4 §6.3: typed input uses steps 1–3 and 6). Null: today's grammar decides.
   */
  async function typedFinal(request: InstantRequest, n: Normalized, parsed: Parsed | null, signal: AbortSignal, dictionary: DictionaryLookup,
    visible: VisibleSnapshot): Promise<Settled | null> {
    const budget = deadline(signal, budgets.defaultMs);
    let apps: Promise<AppMatcher | null> | undefined;
    const matcher = () => (apps ??= deps.apps ? deps.apps.get(budget.signal) : Promise.resolve(null));
    const work = async (): Promise<Settled | null> => {
      const take = voiceTake({ text: request.text });
      if (deps.takeMemo && correctionTarget(request.text)) {
        const corrected = await correct(request, take, budget.signal, dictionary, matcher, visible);
        if (corrected) return corrected;
      }
      if (!learnable(parsed, n)) return null;
      const hypothesis = take.hypotheses[0]!;
      const info = blankOutcome(hypothesis, n, parsed, n.lang === "de");
      const rule = await learnedRule(request.text, n, parsed, RECOGNIZERS.any, dictionary, matcher, info);
      return rule ? settle(take, info, info, rule, info.via) : null;
    };
    try {
      const result = await race(work(), budget.signal);
      return result === TIMEOUT || result === FAILED ? null : result;
    } finally {
      budget.dispose();
    }
  }

  return {
    dispatch,
    warm: async () => {
      // The 48.8k-word common-word set, off the first spoken final (a few ms, a few MB).
      warmLexicon();
      await engines.warm();
    },
    engines,
  };
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}

function systemTitle(target: Extract<SafeTarget, { kind: "system" }>): string {
  if (target.op === "volume.mute") return target.value === false ? "Unmute" : "Mute";
  if (target.op === "volume.set") return `Set volume to ${Math.round(Number(target.value) * 100)}%`;
  return Number(target.value) > 0 ? "Volume up" : "Volume down";
}
