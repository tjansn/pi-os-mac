/**
 * Instant lane (DESIGN §3.3): deterministic EN/DE commands answered or
 * described in milliseconds without a model. Wiring (C1):
 *
 *   const fend = createFendLoader();
 *   const fx = new EcbRateStore();                              // cache in the support dir
 *   const apps = new AppIndexCache((signal) => listApps(signal));  // host launcher.listApps
 *   const deps = { fend, fx, apps, searchFiles };                // host launcher.searchFiles
 *   const dispatcher = createInstantDispatcher({ ...deps, classifier, perf: perfLog });
 *   const engines = dispatcher.engines;                         // or createInstantEngines(deps) for pi tools
 *
 * Every response carries the advisory context `scope` of its text from `deps.scorer` (default: the
 * routing rules v2, rulesContextScorer; NO_CONTEXT_SCORER from contracts/context.ts turns it off).
 *
 * Visible items (design C): add `visibleItems: new VisibleItemsCache((request, signal) => host.visibleItems(request,
 * signal))`; open forms then try the take's desktop icons / target Finder window before the apps, and a missed
 * final open form may offer Spotlight matches ("Did you mean Radfotos?"). Hosts without the route: today's lane.
 *
 * Voice (DESIGN4): add `dictionary` (DictionaryStore, or nonCountingLookup(store) for dispatchers that are
 * not the host's /instant) and `takeMemo` (InMemoryTakeMemo) to the deps; voice finals with `hypotheses`
 * are arbitrated (voice.ts), and `takeDetailsOf(response)` gives the take memo's details.
 */

export {
  AppIndexCache, AppMatcher, BUILTIN_APP_ALIASES, FileFrecencyStore, SPOKEN, spokenHead, spokenVariants,
  type AppMatch, type FrecencyStore, type SpokenDecision, type SpokenOpenResult,
} from "./apps.js";
export { rulesContextScorer } from "../agent/routing/contextScope.js";
export { createInstantDispatcher, MAX_INSTANT_TEXT, type DispatchOptions, type InstantDispatcher, type InstantDispatcherDeps } from "./dispatcher.js";
export { DictionaryStore, nonCountingLookup } from "./dictionary.js";
export { InMemoryTakeMemo, takeDetailsOf, takeRecordFor, type TakeDetails, type TakeRecord } from "./takeMemo.js";
export { isCommonWord, warmLexicon } from "./lexicon.js";
export {
  checkGate, consistentAlternative, correctionTarget, didYouMeanTitle, VOICE, voiceTake,
  type Correction, type LaneOutcome, type VoiceTake,
} from "./voice.js";
export {
  createFendLoader, createInstantEngines,
  type AppsResult, type CalcResult, type CurrencyResult, type DateResult, type FendLoader, type FilesResult, type InstantDeps,
  type InstantEngines, type SearchFiles, type TimeConvertResult, type TimeDiffResult, type TimeInResult,
} from "./engines.js";
export { FendEngine, type FendResult } from "./engines/fend.js";
export {
  defaultFxCacheFile, EcbRateStore, ECB_DAILY_URL, fxFreshness, fxFreshnessLabel, parseEcbXml,
  type EcbRateStoreOptions, type FxFreshness, type FxSnapshot,
} from "./engines/fx.js";
export { buildFileSearchRequest } from "./files/query.js";
export { rankFiles, type RankedFile } from "./files/rank.js";
export {
  DEFAULT_WEB_SEARCH, DELETION_REFUSAL_MESSAGE, isKnownSpokenHost, KNOWN_SPOKEN_DOMAINS, openStrength, parseInstant,
  type OpenStrength, type ParseOptions,
} from "./grammar/index.js";
export { normalize, spokenCore, type Normalized } from "./normalize.js";
export {
  decideVisible, matchKey, matchVisible, NO_VISIBLE, VISIBLE, VisibleItemsCache, visibleTarget,
  type VisibleDecision, type VisibleItemsFetch, type VisibleMatch, type VisibleSnapshot, type VisibleTarget,
} from "./visible.js";
