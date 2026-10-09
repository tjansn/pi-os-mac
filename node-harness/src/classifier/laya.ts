import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { ClassifierContext } from "@earendil-works/pi-ai";
import type { ClassifierHints, IntentClassifier } from "../contracts/instant.js";
import { layaResultToHints, type LayaIntentResult, normalizeUtterance, parseLayaIntentResult } from "./questions.js";

/**
 * Supervisor for the Laya intent sidecar (sidecars/laya/laya_intent_sidecar.py):
 * one CPU-only Python child speaking stdio JSON-lines (laya.md §8.2–8.3).
 *
 * - Lazy: nothing is spawned until the first classify()/predict()/warm(), and
 *   only the factory creates a supervisor when the user enabled kind "laya".
 * - classify() never waits for the ~18 s model load: it returns null (the
 *   router proceeds on heuristics) and starts the child in the background.
 * - Each classify has a deadline (default 250 ms); a newer classify supersedes
 *   older in-flight ones (latest wins) and the sidecar drops cancelled work.
 * - Idle shutdown after 10 minutes; unexpected exits restart lazily with
 *   exponential backoff, at most 3 times per configuration, then stay failed.
 * - Shutdown closes stdin (the sidecar exits on EOF) and only then kills
 *   exactly the child's own PID. Never by image name (AGENTS.md).
 * - Privacy: inputs never reach logs; log lines carry states, codes, PIDs and
 *   durations. Sidecar stderr (library warnings) is forwarded capped and with
 *   absolute paths redacted; the sidecar itself never echoes input.
 */

export const LAYA_PROTOCOL_VERSION = 1;
export const DEFAULT_LAYA_DEADLINE_MS = 250;
export const DEFAULT_LAYA_IDLE_SHUTDOWN_MS = 10 * 60_000;
/** CPU load measured at 18.4 s (laya.md §6.1); allow for sha256, staging and a busy machine. */
export const DEFAULT_LAYA_READY_TIMEOUT_MS = 120_000;
export const DEFAULT_LAYA_MAX_RESTARTS = 3;
export const DEFAULT_LAYA_RESTART_BACKOFF_MS = 2_000;
export const DEFAULT_LAYA_PREDICT_TIMEOUT_MS = 30_000;
export const LAYA_MAX_STATE_CHARS = 4_000;
/**
 * The sidecar drops longer request lines with an id-less error, so the caller
 * would only learn at its timeout; refuse them here instead (MAX_LINE_BYTES).
 */
export const LAYA_MAX_LINE_BYTES = 64 * 1024;
/** Sidecar exit code when its socket kill-switch fired. */
export const LAYA_EXIT_NETWORK = 97;

const MAX_STDERR_LINES = 200;
const MAX_LOG_CHARS = 300;
/** POSIX (/a/b) and Windows (C:\\a\\b) absolute paths inside library warnings. */
const ABSOLUTE_PATH = /(?:[A-Za-z]:\\|\/)[^\s'"`,;:()<>]*(?:[\\/][^\s'"`,;:()<>]*)+/gu;

export type LayaSidecarState = "stopped" | "starting" | "ready" | "stopping" | "backoff" | "failed";

export interface LayaSidecarOptions {
  /** Absolute path of the interpreter (a venv with laya 0.3.5 + torch for the real engine). */
  python: string;
  script: string;
  /** Arguments after the script: --model-dir/--stage-dir/--threads/... or --fake. */
  args: readonly string[];
  /** Extra environment for the child, merged over sidecarEnvironment(). */
  env?: Record<string, string>;
  log?: (line: string) => void;
  deadlineMs?: number;
  readyTimeoutMs?: number;
  idleShutdownMs?: number;
  maxRestarts?: number;
  restartBackoffMs?: number;
  stopGraceMs?: number;
  predictTimeoutMs?: number;
  clock?: () => number;
}

export interface LayaModelInfo {
  name: string;
  questions: string;
  device: string;
  threads: number;
  fake: boolean;
  calibrated: boolean;
  stateTokenRoom: number;
  laya: string | null;
  torch: string | null;
  loadMs: number;
}

export interface LayaSidecarStatus {
  state: LayaSidecarState;
  pid?: number;
  failures: number;
  maxRestarts: number;
  lastError?: string;
  nextStartInMs?: number;
  model?: LayaModelInfo;
  /** Per-code counts of classify/predict requests that produced no answer. */
  requestErrors: Record<string, number>;
}

export interface LayaHealth {
  pid: number;
  queue: number;
  peakRssBytes: number | null;
}

export interface LayaClassifyOptions {
  signal?: AbortSignal;
  deadlineMs?: number;
  /** Default true: supersede (and cancel) every older in-flight classify. */
  latestWins?: boolean;
}

/** pi classifier context forwarded to the sidecar's generic `predict` op. */
export interface LayaPredictRequest {
  state: ClassifierContext["state"];
  questions: ClassifierContext["questions"];
}

export type LayaAnswer =
  | { type: "choice"; choice: string; probabilities: Record<string, number>; confidence: number }
  | { type: "score"; score: number; probabilities: Record<string, number>; confidence: number }
  | { type: "bool"; probability: number };

export interface LayaPredictResult {
  answers: Record<string, LayaAnswer>;
  usage: { inputTokens: number; stateTokens: number };
}

export class LayaSidecarError extends Error {
  constructor(readonly code: string) {
    super(`Laya sidecar: ${code}`);
    this.name = "LayaSidecarError";
  }
}

type Outcome = { ok: true; message: Record<string, unknown> } | { ok: false; code: string };
type RequestKind = "classify" | "predict" | "health";
interface PendingRequest { kind: RequestKind; finish(outcome: Outcome, cancel: boolean): void }

/** Minimal child environment: offline HF/transformers flags, no proxies, tokens or user PYTHON* vars. */
export function sidecarEnvironment(
  extra: Record<string, string> = {},
  base: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
): Record<string, string> {
  const env: Record<string, string> = {
    PATH: platform === "win32" ? (base.PATH ?? base.Path ?? "") : "/usr/bin:/bin",
    HF_HUB_OFFLINE: "1",
    TRANSFORMERS_OFFLINE: "1",
    HF_DATASETS_OFFLINE: "1",
    HF_HUB_DISABLE_TELEMETRY: "1",
    DO_NOT_TRACK: "1",
    TOKENIZERS_PARALLELISM: "false",
    PYTHONDONTWRITEBYTECODE: "1",
    PYTHONUNBUFFERED: "1",
  };
  // Windows Python needs SystemRoot/TEMP to start; Unix keeps HOME/TMPDIR/locale only.
  const keep = platform === "win32" ? ["SystemRoot", "SYSTEMROOT", "windir", "TEMP", "TMP", "PATHEXT"] : ["HOME", "TMPDIR", "LANG"];
  for (const name of keep) {
    const value = base[name];
    if (value) env[name] = value;
  }
  return { ...env, ...extra };
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const finite = (value: unknown, fallback = 0): number =>
  typeof value === "number" && Number.isFinite(value) ? value : fallback;
/** Log-safe single token (codes, kinds): never free text. */
const token = (value: unknown, fallback: string): string =>
  typeof value === "string" && /^[A-Za-z0-9_.:-]{1,40}$/u.test(value) ? value : fallback;
const clampMs = (value: number, min: number, max: number): number =>
  Number.isFinite(value) ? Math.min(max, Math.max(min, Math.round(value))) : min;

function parseReady(message: Record<string, unknown>): LayaModelInfo | null {
  const model = message.model;
  if (message.proto !== LAYA_PROTOCOL_VERSION || !isRecord(model) || typeof model.questions !== "string") return null;
  return {
    name: token(model.name, "laya"),
    questions: token(model.questions, "unknown"),
    device: token(model.device, "unknown"),
    threads: finite(model.threads),
    fake: model.fake === true,
    calibrated: model.calibrated === true,
    stateTokenRoom: finite(model.state_token_room),
    laya: typeof model.laya === "string" ? token(model.laya, "unknown") : null,
    torch: typeof model.torch === "string" ? token(model.torch, "unknown") : null,
    loadMs: finite(message.load_ms),
  };
}

function errorCode(message: Record<string, unknown>): string {
  return token(isRecord(message.error) ? message.error.code : undefined, "internal");
}

const isProbability = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;

function probabilityMap(value: unknown, allowed: readonly string[]): Record<string, number> | null {
  if (!isRecord(value)) return null;
  const out: Record<string, number> = {};
  for (const [key, p] of Object.entries(value)) {
    if (!allowed.includes(key) || !isProbability(p)) return null;
    out[key] = p;
  }
  return out;
}

/** Strict decoder: every question needs an answer of its own type over its own options. */
export function parseLayaPredictResult(value: unknown, questions: LayaPredictRequest["questions"]): LayaPredictResult | null {
  if (!isRecord(value) || value.advisory !== true || !isRecord(value.answers)) return null;
  const answers: Record<string, LayaAnswer> = {};
  for (const [id, question] of Object.entries(questions)) {
    const answer = value.answers[id];
    if (!isRecord(answer) || answer.type !== question.type) return null;
    if (question.type === "bool") {
      if (!isProbability(answer.probability)) return null;
      answers[id] = { type: "bool", probability: answer.probability };
      continue;
    }
    const keys = question.type === "choice" ? Object.keys(question.criteria) : question.criteria.map((_, i) => String(i));
    const probabilities = probabilityMap(answer.probabilities, keys);
    if (!probabilities || !isProbability(answer.confidence)) return null;
    if (question.type === "choice") {
      if (typeof answer.choice !== "string" || !keys.includes(answer.choice)) return null;
      answers[id] = { type: "choice", choice: answer.choice, probabilities, confidence: answer.confidence };
    } else {
      if (typeof answer.score !== "number" || !Number.isFinite(answer.score)) return null;
      answers[id] = { type: "score", score: answer.score, probabilities, confidence: answer.confidence };
    }
  }
  const usage = isRecord(value.usage) ? value.usage : {};
  return { answers, usage: { inputTokens: finite(usage.input_tokens), stateTokens: finite(usage.state_tokens) } };
}

/** Resolves false when the promise does not resolve true within `ms` or the signal aborts. */
function readyWithin(ready: Promise<boolean>, ms: number, signal?: AbortSignal): Promise<boolean> {
  if (signal?.aborted) return Promise.resolve(false);
  return new Promise((resolve) => {
    const done = (value: boolean) => { clearTimeout(timer); signal?.removeEventListener("abort", onAbort); resolve(value); };
    const timer = setTimeout(() => done(false), ms);
    const onAbort = () => done(false);
    signal?.addEventListener("abort", onAbort, { once: true });
    ready.then(done, () => done(false));
  });
}

export class LayaSidecar {
  private child: ChildProcessWithoutNullStreams | undefined;
  private current: LayaSidecarState = "stopped";
  private starting: Promise<boolean> | undefined;
  private readonly pending = new Map<string, PendingRequest>();
  private readonly exited = new WeakSet<ChildProcessWithoutNullStreams>();
  private readonly stopping = new WeakSet<ChildProcessWithoutNullStreams>();
  private readonly exitHooks = new Map<ChildProcessWithoutNullStreams, () => void>();
  private readonly stderrLines = new WeakMap<ChildProcessWithoutNullStreams, number>();
  private readonly requestErrors: Record<string, number> = {};
  private idleTimer: NodeJS.Timeout | undefined;
  private sequence = 0;
  private failures = 0;
  private permanent = false;
  private lastError: string | undefined;
  private nextStartAt = 0;
  private info: LayaModelInfo | undefined;
  private readonly log: (line: string) => void;
  private readonly now: () => number;
  private readonly env: Record<string, string>;

  constructor(private readonly options: LayaSidecarOptions) {
    this.log = options.log ?? ((line) => console.log(line));
    this.now = options.clock ?? (() => Date.now());
    this.env = sidecarEnvironment(options.env);
  }

  get state(): LayaSidecarState { return this.current; }
  get pid(): number | undefined { return this.child?.pid; }
  get model(): LayaModelInfo | undefined { return this.info; }
  /** False once the sidecar gave up; the pi provider then reports itself unconfigured. */
  get available(): boolean { return this.current !== "failed"; }

  status(): LayaSidecarStatus {
    return {
      state: this.current,
      ...(this.child?.pid !== undefined ? { pid: this.child.pid } : {}),
      failures: this.failures,
      maxRestarts: this.maxRestarts,
      ...(this.lastError ? { lastError: this.lastError } : {}),
      ...(this.current === "backoff" ? { nextStartInMs: Math.max(0, this.nextStartAt - this.now()) } : {}),
      ...(this.info ? { model: { ...this.info } } : {}),
      requestErrors: { ...this.requestErrors },
    };
  }

  /** Start (or join the start of) the child. Resolves true once ready; false when it cannot start now. */
  warm(): Promise<boolean> {
    if (this.current === "ready") return Promise.resolve(true);
    if (this.starting) return this.starting;
    if (this.current === "failed" || this.current === "stopping") return Promise.resolve(false);
    if (this.current === "backoff" && this.now() < this.nextStartAt) return Promise.resolve(false);
    const starting = this.launch().finally(() => { if (this.starting === starting) this.starting = undefined; });
    this.starting = starting;
    return starting;
  }

  /**
   * Advisory intent classification of one utterance. Never throws. Null when
   * the sidecar is not ready yet (a start is kicked off), the text is empty or
   * over 500 chars, the deadline passes, the call is aborted or superseded.
   */
  async classify(text: string, options: LayaClassifyOptions = {}): Promise<LayaIntentResult | null> {
    const utterance = normalizeUtterance(text);
    if (!utterance || options.signal?.aborted) return null;
    if (this.current !== "ready") {
      void this.warm();
      return null;
    }
    if (options.latestWins !== false) this.supersede("classify");
    const deadlineMs = clampMs(options.deadlineMs ?? this.options.deadlineMs ?? DEFAULT_LAYA_DEADLINE_MS, 10, 10_000);
    const outcome = await this.request("classify", { op: "classify", text: utterance, deadline_ms: deadlineMs }, deadlineMs, options.signal);
    if (!outcome.ok) {
      this.countError(outcome.code);
      return null;
    }
    const result = parseLayaIntentResult(outcome.message.result);
    if (!result) this.countError("invalid_response");
    return result;
  }

  /**
   * Generic typed questions (the pi classifier provider / codemode path). Waits
   * for the model load within the timeout; rejects with LayaSidecarError.
   */
  async predict(request: LayaPredictRequest, options: { signal?: AbortSignal; timeoutMs?: number } = {}): Promise<LayaPredictResult> {
    if (JSON.stringify(request.state ?? null).length > LAYA_MAX_STATE_CHARS) throw new LayaSidecarError("state_too_long");
    const timeoutMs = clampMs(options.timeoutMs ?? this.options.predictTimeoutMs ?? DEFAULT_LAYA_PREDICT_TIMEOUT_MS, 10, 300_000);
    const started = this.now();
    if (this.current !== "ready" && !(await readyWithin(this.warm(), timeoutMs, options.signal))) {
      throw new LayaSidecarError(options.signal?.aborted ? "aborted" : this.current === "failed" ? "unavailable" : "not_ready");
    }
    const remaining = clampMs(timeoutMs - (this.now() - started), 10, timeoutMs);
    const outcome = await this.request("predict", {
      op: "predict", state: request.state, questions: request.questions, deadline_ms: remaining,
    }, remaining, options.signal);
    if (!outcome.ok) {
      this.countError(outcome.code);
      throw new LayaSidecarError(outcome.code);
    }
    const parsed = parseLayaPredictResult(outcome.message.result, request.questions);
    if (!parsed) {
      this.countError("invalid_response");
      throw new LayaSidecarError("invalid_response");
    }
    return parsed;
  }

  async health(timeoutMs = 1_000): Promise<LayaHealth | null> {
    const outcome = await this.request("health", { op: "health" }, timeoutMs);
    if (!outcome.ok || !isRecord(outcome.message.health)) return null;
    const health = outcome.message.health;
    return {
      pid: finite(health.pid),
      queue: finite(health.queue),
      peakRssBytes: typeof health.peak_rss_bytes === "number" ? health.peak_rss_bytes : null,
    };
  }

  /** Graceful stop: close stdin (the sidecar exits on EOF), then kill exactly this child's PID after a grace period. */
  async stop(): Promise<void> {
    clearTimeout(this.idleTimer);
    const child = this.child;
    if (!child || this.exited.has(child)) {
      if (this.current !== "failed") this.current = "stopped";
      return;
    }
    this.stopping.add(child);
    if (this.current !== "failed") this.current = "stopping";
    await this.terminate(child);
  }

  /** Forget failures (e.g. after the user changed the configuration). */
  reset(): void {
    this.failures = 0;
    this.permanent = false;
    this.lastError = undefined;
    if (this.current === "failed" || this.current === "backoff") this.current = "stopped";
  }

  private get maxRestarts(): number { return this.options.maxRestarts ?? DEFAULT_LAYA_MAX_RESTARTS; }

  private launch(): Promise<boolean> {
    this.current = "starting";
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawn(this.options.python, ["-I", "-B", this.options.script, ...this.options.args], {
        env: this.env, shell: false, windowsHide: true,
      });
    } catch {
      this.lastError = "spawn_failed";
      this.permanent = true;
      this.recordFailure(undefined, null, null);
      return Promise.resolve(false);
    }
    this.child = child;
    this.installExitHook(child);
    this.log(`[laya] starting sidecar pid=${child.pid ?? "?"}`);
    return new Promise<boolean>((resolve) => {
      let settled = false;
      const settle = (ready: boolean) => {
        if (settled) return;
        settled = true;
        clearTimeout(readyTimer);
        resolve(ready);
      };
      const readyTimeoutMs = this.options.readyTimeoutMs ?? DEFAULT_LAYA_READY_TIMEOUT_MS;
      const readyTimer = setTimeout(() => {
        if (this.child !== child || this.current !== "starting") return;
        this.lastError = "ready_timeout";
        this.log(`[laya] no ready line within ${readyTimeoutMs} ms; terminating pid=${child.pid}`);
        void this.terminate(child);
        settle(false);
      }, readyTimeoutMs);
      child.stdin.on("error", () => { /* EPIPE once the child is gone; the exit handler reports */ });
      child.stderr.setEncoding("utf8");
      createInterface({ input: child.stderr }).on("line", (line) => this.forwardStderr(child, line));
      createInterface({ input: child.stdout }).on("line", (line) => this.onLine(child, line, settle));
      child.once("error", (error: Error) => {
        // ENOENT/EACCES: 'exit' may never follow, so finish the bookkeeping here.
        this.lastError ??= "spawn_failed";
        if (child.pid === undefined) this.permanent = true;
        this.log(`[laya] spawn error ${token((error as NodeJS.ErrnoException).code, error.name)}`);
        settle(false);
        if (child.pid === undefined) this.onExit(child, null, null);
      });
      child.once("exit", (code, signal) => {
        settle(false);
        this.onExit(child, code, signal);
      });
    });
  }

  private onLine(child: ChildProcessWithoutNullStreams, line: string, settle: (ready: boolean) => void): void {
    if (child !== this.child) return;
    let message: unknown;
    try { message = JSON.parse(line); } catch {
      this.log("[laya] dropped a non-JSON stdout line");
      return;
    }
    if (!isRecord(message)) return;
    if (message.type === "ready") {
      // stop() won the race against the load: the child is already on its way out.
      if (this.stopping.has(child)) {
        settle(false);
        return;
      }
      const info = parseReady(message);
      if (!info) {
        this.lastError = "protocol_mismatch";
        this.permanent = true;
        this.log(`[laya] unsupported ready line; terminating pid=${child.pid}`);
        void this.terminate(child);
        settle(false);
        return;
      }
      this.info = info;
      this.current = "ready";
      this.lastError = undefined;
      this.log(`[laya] ready pid=${child.pid} load_ms=${Math.round(info.loadMs)} questions=${info.questions} device=${info.device} calibrated=${info.calibrated} fake=${info.fake}`);
      this.touch();
      settle(true);
      return;
    }
    if (message.type === "fatal") {
      const error = isRecord(message.error) ? message.error : {};
      this.lastError = token(error.code, "load_failed");
      this.permanent = true;
      this.log(`[laya] load failed code=${this.lastError} kind=${token(error.kind, "unknown")}`);
      settle(false);
      return; // the sidecar exits by itself
    }
    if (typeof message.id !== "string") return;
    this.pending.get(message.id)?.finish(message.ok === true ? { ok: true, message } : { ok: false, code: errorCode(message) }, false);
  }

  private onExit(child: ChildProcessWithoutNullStreams, code: number | null, signal: NodeJS.Signals | null): void {
    if (this.exited.has(child)) return;
    this.exited.add(child);
    this.removeExitHook(child);
    if (this.child === child) this.child = undefined;
    clearTimeout(this.idleTimer);
    for (const pending of [...this.pending.values()]) pending.finish({ ok: false, code: "exited" }, false);
    if (this.stopping.has(child)) {
      if (this.current !== "failed") this.current = "stopped";
      this.log(`[laya] stopped pid=${child.pid} code=${code} signal=${signal}`);
      return;
    }
    this.recordFailure(child.pid, code, signal);
  }

  private recordFailure(pid: number | undefined, code: number | null, signal: NodeJS.Signals | null): void {
    if (code === LAYA_EXIT_NETWORK) {
      this.lastError = "network_blocked";
      this.permanent = true;
    }
    this.lastError ??= "crashed";
    this.failures += 1;
    if (this.permanent || this.failures > this.maxRestarts) {
      this.current = "failed";
      this.log(`[laya] exited pid=${pid ?? "?"} code=${code} signal=${signal}; disabled (${this.lastError}, failures=${this.failures})`);
      return;
    }
    const delay = (this.options.restartBackoffMs ?? DEFAULT_LAYA_RESTART_BACKOFF_MS) * 2 ** (this.failures - 1);
    this.nextStartAt = this.now() + delay;
    this.current = "backoff";
    this.log(`[laya] exited pid=${pid ?? "?"} code=${code} signal=${signal} (${this.lastError}); restart ${this.failures}/${this.maxRestarts} allowed in ${delay} ms`);
  }

  private request(kind: RequestKind, payload: Record<string, unknown>, timeoutMs: number, signal?: AbortSignal): Promise<Outcome> {
    const child = this.child;
    if (!child || this.current !== "ready") return Promise.resolve({ ok: false, code: "not_ready" });
    if (signal?.aborted) return Promise.resolve({ ok: false, code: "aborted" });
    const id = `${kind.charAt(0)}${++this.sequence}`;
    const line = JSON.stringify({ id, ...payload });
    if (Buffer.byteLength(line) > LAYA_MAX_LINE_BYTES) return Promise.resolve({ ok: false, code: "bad_request" });
    this.touch();
    return new Promise<Outcome>((resolve) => {
      let done = false;
      const finish = (outcome: Outcome, cancel: boolean) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
        this.pending.delete(id);
        if (cancel) this.write(child, JSON.stringify({ id: `x${++this.sequence}`, op: "cancel", target: id }));
        resolve(outcome);
      };
      const timer = setTimeout(() => finish({ ok: false, code: "timeout" }, true), timeoutMs);
      const onAbort = () => finish({ ok: false, code: "aborted" }, true);
      signal?.addEventListener("abort", onAbort, { once: true });
      this.pending.set(id, { kind, finish });
      if (!this.write(child, line)) finish({ ok: false, code: "write_failed" }, false);
    });
  }

  /** Latest wins: older classifications resolve null and the sidecar skips them if still queued. */
  private supersede(kind: RequestKind): void {
    for (const pending of [...this.pending.values()]) {
      if (pending.kind === kind) pending.finish({ ok: false, code: "superseded" }, true);
    }
  }

  private write(child: ChildProcessWithoutNullStreams, line: string): boolean {
    if (child !== this.child || this.exited.has(child) || !child.stdin.writable) return false;
    try {
      child.stdin.write(`${line}\n`);
      return true;
    } catch {
      return false;
    }
  }

  private terminate(child: ChildProcessWithoutNullStreams): Promise<void> {
    const exited = this.exited.has(child) ? Promise.resolve() : new Promise<void>((resolve) => {
      child.once("exit", () => resolve());
      child.once("error", () => resolve());
    });
    try { child.stdin.end(); } catch { /* already closed */ }
    const killTimer = setTimeout(() => this.killPid(child), this.options.stopGraceMs ?? 2_000);
    return exited.finally(() => clearTimeout(killTimer));
  }

  /** Kill exactly this child's PID, and only while it is still running. */
  private killPid(child: ChildProcessWithoutNullStreams): void {
    const pid = child.pid;
    if (pid === undefined || this.exited.has(child) || child.exitCode !== null || child.signalCode !== null) return;
    try {
      process.kill(pid, "SIGKILL");
      this.log(`[laya] killed pid=${pid}`);
    } catch { /* already gone */ }
  }

  /** The child dies with the harness: stdin EOF covers normal exits, this covers a hung child. */
  private installExitHook(child: ChildProcessWithoutNullStreams): void {
    const hook = () => this.killPid(child);
    this.exitHooks.set(child, hook);
    process.once("exit", hook);
  }

  private removeExitHook(child: ChildProcessWithoutNullStreams): void {
    const hook = this.exitHooks.get(child);
    if (!hook) return;
    process.removeListener("exit", hook);
    this.exitHooks.delete(child);
  }

  private touch(): void {
    const idleMs = this.options.idleShutdownMs ?? DEFAULT_LAYA_IDLE_SHUTDOWN_MS;
    if (idleMs <= 0) return;
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => {
      if (this.pending.size > 0) {
        this.touch();
        return;
      }
      this.log(`[laya] idle for ${Math.round(idleMs / 1000)} s; stopping pid=${this.child?.pid ?? "?"}`);
      void this.stop();
    }, idleMs);
    this.idleTimer.unref();
  }

  private forwardStderr(child: ChildProcessWithoutNullStreams, line: string): void {
    const count = (this.stderrLines.get(child) ?? 0) + 1;
    this.stderrLines.set(child, count);
    if (count > MAX_STDERR_LINES) return;
    const redacted = line.replace(ABSOLUTE_PATH, "<path>");
    const text = redacted.length > MAX_LOG_CHARS ? `${redacted.slice(0, MAX_LOG_CHARS)}…` : redacted;
    this.log(count === MAX_STDERR_LINES ? "[laya:stderr] (further stderr suppressed)" : `[laya:stderr] ${text}`);
  }

  private countError(code: string): void {
    this.requestErrors[code] = (this.requestErrors[code] ?? 0) + 1;
  }
}

/** IntentClassifier over the sidecar. Never throws; null = no advisory hint this time. */
export class LayaClassifier implements IntentClassifier {
  readonly name = "laya";

  constructor(
    private readonly sidecar: Pick<LayaSidecar, "classify">,
    private readonly options: { deadlineMs?: number; clock?: () => number } = {},
  ) {}

  async classify(text: string, signal: AbortSignal): Promise<ClassifierHints | null> {
    const clock = this.options.clock ?? (() => performance.now());
    const started = clock();
    try {
      const result = await this.sidecar.classify(text, {
        signal, ...(this.options.deadlineMs !== undefined ? { deadlineMs: this.options.deadlineMs } : {}),
      });
      if (!result || signal.aborted) return null;
      return layaResultToHints(result, clock() - started);
    } catch {
      return null;
    }
  }
}
