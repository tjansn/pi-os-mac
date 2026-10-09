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
 */

export { AppIndexCache, AppMatcher, BUILTIN_APP_ALIASES, FileFrecencyStore, type AppMatch, type FrecencyStore } from "./apps.js";
export { createInstantDispatcher, MAX_INSTANT_TEXT, type InstantDispatcher, type InstantDispatcherDeps } from "./dispatcher.js";
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
export { DEFAULT_WEB_SEARCH, DELETION_REFUSAL_MESSAGE, parseInstant } from "./grammar/index.js";
export { normalize, type Normalized } from "./normalize.js";
