import type { Models } from "@earendil-works/pi-ai";
import type { ClassifierHints, IntentClassifier } from "../contracts/instant.js";
import { normalizeUtterance, PI_OS_INTENT_QUESTIONS, piAnswersToHints } from "./questions.js";

/**
 * IntentClassifier over any pi catalog classifier model through
 * `ModelRuntime.classify()`, e.g. `cloudflare-workers-ai` / `typesafe/jev`
 * (Workers AI credentials) or `typesafe` / `jev-latest` (TYPESAFE_API_KEY).
 * Cloudflare Clef will plug in the same way once pi's catalog ships it.
 *
 * This sends the utterance to that provider, so it runs only when the user
 * picked classifier kind "pi" in Settings. Advisory like Laya; never throws.
 * Provider error messages are not logged (they may echo request content).
 */

/** The part of pi's ModelRuntime this needs (ModelRuntime satisfies it). */
export type ClassifierRuntime = Pick<Models, "getModelOfType" | "classify">;

/** Workers AI Jev measured ~524 ms median (codemode.md §5); TypeSafe ~300 ms p50. */
export const DEFAULT_PI_CLASSIFIER_DEADLINE_MS = 1_000;

export interface PiCatalogClassifierOptions {
  provider: string;
  model: string;
  /** A runtime, or a lazy factory (created once, retried after a failure). */
  runtime: ClassifierRuntime | (() => Promise<ClassifierRuntime>);
  deadlineMs?: number;
  log?: (line: string) => void;
  clock?: () => number;
}

export class PiCatalogClassifier implements IntentClassifier {
  readonly name: string;
  private runtime: Promise<ClassifierRuntime> | undefined;
  private reportedMissing = false;
  private readonly log: (line: string) => void;

  constructor(private readonly options: PiCatalogClassifierOptions) {
    this.name = `pi:${options.provider}/${options.model}`;
    this.log = options.log ?? ((line) => console.log(line));
  }

  async classify(text: string, signal: AbortSignal): Promise<ClassifierHints | null> {
    const utterance = normalizeUtterance(text);
    if (!utterance || signal.aborted) return null;
    const clock = this.options.clock ?? (() => performance.now());
    const started = clock();
    const deadlineMs = this.options.deadlineMs ?? DEFAULT_PI_CLASSIFIER_DEADLINE_MS;
    const combined = AbortSignal.any([signal, AbortSignal.timeout(deadlineMs)]);
    try {
      const runtime = await raceAbort(this.resolveRuntime(), combined);
      if (!runtime) return null;
      const model = runtime.getModelOfType("classifier", this.options.provider, this.options.model);
      if (!model) {
        if (!this.reportedMissing) this.log(`[classifier] ${this.name} is not in the pi catalog; no hints`);
        this.reportedMissing = true;
        return null;
      }
      const result = await raceAbort(runtime.classify(model, {
        state: { utterance },
        questions: PI_OS_INTENT_QUESTIONS,
      }, { signal: combined, maxRetries: 0, timeoutMs: deadlineMs }), combined);
      if (!result || result.stopReason !== "stop" || signal.aborted) return null;
      return piAnswersToHints(result.answers, clock() - started);
    } catch {
      return null;
    }
  }

  private resolveRuntime(): Promise<ClassifierRuntime> {
    const source = this.options.runtime;
    if (typeof source !== "function") return Promise.resolve(source);
    this.runtime ??= source().catch((error: unknown) => {
      this.runtime = undefined; // retry on the next call
      throw error;
    });
    return this.runtime;
  }
}

/** Resolves undefined as soon as the signal aborts, even if the promise ignores it. */
function raceAbort<T>(promise: Promise<T>, signal: AbortSignal): Promise<T | undefined> {
  if (signal.aborted) return Promise.resolve(undefined);
  return new Promise((resolve, reject) => {
    const onAbort = () => resolve(undefined);
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => { signal.removeEventListener("abort", onAbort); resolve(value); },
      (error: unknown) => { signal.removeEventListener("abort", onAbort); reject(error); },
    );
  });
}
