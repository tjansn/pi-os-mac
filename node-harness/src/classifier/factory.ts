import { join } from "node:path";
import { type IntentClassifier, NO_CLASSIFIER } from "../contracts/instant.js";
import { supportDirectory } from "../platformPaths.js";
import { LayaClassifier, LayaSidecar, type LayaSidecarOptions, type LayaSidecarState, type LayaSidecarStatus } from "./laya.js";
import { type ClassifierRuntime, PiCatalogClassifier } from "./piClassifier.js";
import { type ClassifierKind, type ClassifierSettings, defaultSidecarScript, resolveLayaLaunch } from "./settings.js";
import { ShadowLogWriter, withShadowLog } from "./shadowLog.js";

/**
 * Builds the configured advisory classifier. Nothing is spawned here: the Laya
 * sidecar starts lazily on first use (or warm()), and only for kind "laya".
 * Unusable configurations degrade to "no hints" with a status reason; the
 * router always has its heuristics.
 */

export interface ClassifierStatus {
  kind: ClassifierKind;
  /** "configured": kind "pi" is set up (auth is only known per call). */
  state: "off" | "unavailable" | "configured" | LayaSidecarState;
  reason?: string;
  name?: string;
  shadowLog: boolean;
  laya?: LayaSidecarStatus;
}

export interface ManagedClassifier extends IntentClassifier {
  readonly kind: ClassifierKind;
  /** Present for kind "laya"; pass it to registerLayaProvider() on a ModelRuntime. */
  readonly sidecar?: LayaSidecar;
  /**
   * Present when shadowLog is on. classify() already records every call; use it to add
   * the rule-derived decision for comparison: shadow.record({ ..., reference: { intent, tier } }).
   */
  readonly shadow?: ShadowLogWriter;
  status(): ClassifierStatus;
  /** Start the Laya sidecar in the background (~18 s CPU load); no-op otherwise. */
  warm(): void;
  /** Stop the sidecar (stdin EOF, then its own PID) and flush the shadow log. */
  dispose(): Promise<void>;
}

export interface ClassifierFactoryDeps {
  env?: NodeJS.ProcessEnv;
  log?: (line: string) => void;
  supportDir?: string;
  /** Kind "pi": lazily created runtime, e.g. `() => ModelRuntime.create()`. */
  modelRuntime?: () => Promise<ClassifierRuntime>;
  /** Sidecar timing overrides (tests, tuning). */
  sidecar?: Pick<LayaSidecarOptions,
    "deadlineMs" | "readyTimeoutMs" | "idleShutdownMs" | "maxRestarts" | "restartBackoffMs" | "stopGraceMs" | "predictTimeoutMs">;
  piDeadlineMs?: number;
  shadowLogPath?: string;
  /** TEST ONLY: run the sidecar's deterministic fake engine (no torch, no model, no venv). */
  fakeEngine?: { python: string; script?: string; args?: readonly string[] };
  exists?: (path: string) => boolean;
}

export function createClassifier(settings: ClassifierSettings, deps: ClassifierFactoryDeps = {}): ManagedClassifier {
  const env = deps.env ?? process.env;
  const log = deps.log ?? ((line: string) => console.log(line));
  const supportDir = deps.supportDir ?? supportDirectory(env);
  const shadow = settings.shadowLog === true && settings.kind !== "off"
    ? new ShadowLogWriter(deps.shadowLogPath ?? join(supportDir, "logs", "classifier-shadow.jsonl"), { log })
    : undefined;

  if (settings.kind === "laya") {
    let options: LayaSidecarOptions;
    if (deps.fakeEngine) {
      options = {
        python: deps.fakeEngine.python,
        script: deps.fakeEngine.script ?? defaultSidecarScript(),
        args: ["--fake", ...(deps.fakeEngine.args ?? [])],
      };
    } else {
      // Explicit kill switch (e.g. test environments): the real engine never starts.
      if (env.PI_OS_LAYA === "0") return inert("laya", "unavailable", "disabled_by_env");
      const resolved = resolveLayaLaunch(settings, env, deps.exists);
      if (!resolved.ok) {
        log(`[classifier] laya unavailable: ${resolved.reason}`);
        return inert("laya", "unavailable", resolved.reason);
      }
      const { launch } = resolved;
      const threads = String(launch.threads);
      options = {
        python: launch.python,
        script: launch.script,
        args: [
          "--model-dir", launch.modelDir,
          "--stage-dir", join(supportDir, "laya", "stage"),
          "--threads", threads,
          ...(launch.sha256 ? ["--sha256", launch.sha256] : []),
          ...(launch.calibration ? ["--calibration", launch.calibration] : []),
        ],
        env: {
          HF_HOME: join(supportDir, "laya", "hf-home"),
          OMP_NUM_THREADS: threads, MKL_NUM_THREADS: threads, VECLIB_MAXIMUM_THREADS: threads,
        },
      };
    }
    const sidecar = new LayaSidecar({ ...options, ...deps.sidecar, log });
    const base = new LayaClassifier(sidecar, deps.sidecar?.deadlineMs !== undefined ? { deadlineMs: deps.sidecar.deadlineMs } : {});
    const classifier = shadow ? withShadowLog(base, shadow) : base;
    return {
      kind: "laya",
      name: base.name,
      sidecar,
      ...(shadow ? { shadow } : {}),
      classify: (text, signal) => classifier.classify(text, signal),
      status: () => {
        const laya = sidecar.status();
        return {
          kind: "laya", state: laya.state, name: base.name, shadowLog: shadow !== undefined, laya,
          ...(laya.lastError ? { reason: laya.lastError } : {}),
        };
      },
      warm: () => { void sidecar.warm(); },
      dispose: async () => {
        await sidecar.stop();
        await shadow?.flush();
      },
    };
  }

  if (settings.kind === "pi") {
    if (!settings.provider || !settings.model) return inert("pi", "unavailable", "model_not_configured");
    if (!deps.modelRuntime) return inert("pi", "unavailable", "runtime_unavailable");
    const base = new PiCatalogClassifier({
      provider: settings.provider, model: settings.model, runtime: deps.modelRuntime, log,
      ...(deps.piDeadlineMs !== undefined ? { deadlineMs: deps.piDeadlineMs } : {}),
    });
    const classifier = shadow ? withShadowLog(base, shadow) : base;
    return {
      kind: "pi",
      name: base.name,
      ...(shadow ? { shadow } : {}),
      classify: (text, signal) => classifier.classify(text, signal),
      status: () => ({ kind: "pi", state: "configured", name: base.name, shadowLog: shadow !== undefined }),
      warm: () => {},
      dispose: async () => { await shadow?.flush(); },
    };
  }

  return inert("off", "off");
}

function inert(kind: ClassifierKind, state: "off" | "unavailable", reason?: string): ManagedClassifier {
  return {
    kind,
    name: NO_CLASSIFIER.name,
    classify: NO_CLASSIFIER.classify,
    status: () => ({ kind, state, shadowLog: false, ...(reason ? { reason } : {}) }),
    warm: () => {},
    dispose: async () => {},
  };
}
