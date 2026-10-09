import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { supportDirectory } from "../platformPaths.js";

/**
 * Optional intent classifier configuration (`classifier.json` in the pi-os
 * support directory; GET/POST /settings/classifier). Default: off.
 *
 * - kind "laya": local CPU sidecar. python/modelDir come from the file (the
 *   Settings pickers), else PI_OS_LAYA_PYTHON / PI_OS_LAYA_MODEL_DIR, else a
 *   `laya/venv` + `laya/model` in the support directory (no personal paths in
 *   code). The sidecar script is never a setting: it is the copy shipped with
 *   pi-os (or PI_OS_LAYA_SCRIPT for development), so a settings write can never
 *   choose code to run; the interpreter must be named python/python3(.x).
 * - kind "pi": a pi catalog classifier (provider + model), e.g.
 *   cloudflare-workers-ai + typesafe/jev. Sends utterances to that provider.
 *
 * Paths live only in this file and the child's argv; they are never logged.
 */

export type ClassifierKind = "off" | "laya" | "pi";
export const CLASSIFIER_KINDS: readonly ClassifierKind[] = ["off", "laya", "pi"];

export interface ClassifierSettings {
  kind: ClassifierKind;
  /** Laya: absolute interpreter path of a venv with laya 0.3.5 + torch (CPU). */
  python?: string;
  /** Laya: absolute checkpoint directory (the multilingual checkpoint). */
  modelDir?: string;
  /** Laya: expected sha256 of model.safetensors, checked before loading. */
  sha256?: string;
  /** Laya: absolute path of a calibration JSON written by finetune/train.py. */
  calibration?: string;
  /** Laya: torch CPU threads, 1–16 (default 4). */
  threads?: number;
  /** pi: catalog provider id of a classifier model. */
  provider?: string;
  /** pi: catalog classifier model id. */
  model?: string;
  /** Opt-in local JSONL of labels, probabilities and latency (never text). Default false. */
  shadowLog?: boolean;
}

export const DEFAULT_CLASSIFIER_SETTINGS: Readonly<ClassifierSettings> = Object.freeze({ kind: "off", shadowLog: false });
export const DEFAULT_LAYA_THREADS = 4;

const MAX_FILE_BYTES = 16_384;
const MAX_PATH_CHARS = 1_024;
const PATH_KEYS = ["python", "modelDir", "calibration"] as const;
const NAME_KEYS = ["provider", "model"] as const;

export type ParsedClassifierSettings = { ok: true; settings: ClassifierSettings } | { ok: false; error: string };

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const CONTROL = /[\u0000-\u001f\u007f]/u;

/**
 * Strict validation for POST bodies and the stored file. Unknown keys are ignored; so is a
 * legacy `script` (older files and hosts that echo every stored field may still carry it).
 */
export function parseClassifierSettings(value: unknown): ParsedClassifierSettings {
  if (!isRecord(value)) return { ok: false, error: "classifier settings must be a JSON object" };
  if (!CLASSIFIER_KINDS.includes(value.kind as ClassifierKind)) {
    return { ok: false, error: `kind must be one of ${CLASSIFIER_KINDS.join(", ")}` };
  }
  const settings: ClassifierSettings = { kind: value.kind as ClassifierKind, shadowLog: false };
  for (const key of PATH_KEYS) {
    const path = value[key];
    if (path === undefined || path === null || path === "") continue;
    if (typeof path !== "string" || path.length > MAX_PATH_CHARS || CONTROL.test(path) || !isAbsolute(path)) {
      return { ok: false, error: `${key} must be an absolute path` };
    }
    settings[key] = path;
  }
  for (const key of NAME_KEYS) {
    const name = value[key];
    if (name === undefined || name === null || name === "") continue;
    if (typeof name !== "string" || name.length > 200 || CONTROL.test(name) || name.trim() !== name) {
      return { ok: false, error: `${key} must be a catalog id` };
    }
    settings[key] = name;
  }
  if (value.sha256 !== undefined && value.sha256 !== null && value.sha256 !== "") {
    if (typeof value.sha256 !== "string" || !/^[0-9a-f]{64}$/iu.test(value.sha256)) {
      return { ok: false, error: "sha256 must be 64 hex characters" };
    }
    settings.sha256 = value.sha256.toLowerCase();
  }
  if (value.threads !== undefined && value.threads !== null) {
    if (!Number.isInteger(value.threads) || (value.threads as number) < 1 || (value.threads as number) > 16) {
      return { ok: false, error: "threads must be an integer from 1 to 16" };
    }
    settings.threads = value.threads as number;
  }
  if (value.shadowLog !== undefined) {
    if (typeof value.shadowLog !== "boolean") return { ok: false, error: "shadowLog must be a boolean" };
    settings.shadowLog = value.shadowLog;
  }
  return { ok: true, settings };
}

export function defaultClassifierSettingsPath(env: NodeJS.ProcessEnv = process.env): string {
  return join(supportDirectory(env), "classifier.json");
}

export class ClassifierSettingsStore {
  private current: ClassifierSettings;

  constructor(
    readonly filePath: string = defaultClassifierSettingsPath(),
    private readonly log: (line: string) => void = (line) => console.log(line),
  ) {
    this.current = readSettings(filePath, log);
    this.log(`[classifier] settings kind=${this.current.kind} shadowLog=${this.current.shadowLog === true}`);
  }

  get(): ClassifierSettings {
    return { ...this.current };
  }

  /** Validate, persist atomically (temp file + rename), and return the stored copy. Throws on invalid input. */
  set(settings: ClassifierSettings): ClassifierSettings {
    const parsed = parseClassifierSettings(settings);
    if (!parsed.ok) throw new Error(parsed.error);
    this.current = parsed.settings;
    try {
      mkdirSync(dirname(this.filePath), { recursive: true, mode: 0o700 });
      const temporary = `${this.filePath}.tmp`;
      writeFileSync(temporary, `${JSON.stringify(this.current, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
      renameSync(temporary, this.filePath);
    } catch (error) {
      // Memory-only fallback: the choice holds until restart.
      this.log(`[classifier] failed writing classifier settings: ${error instanceof Error ? error.name : "error"}`);
    }
    this.log(`[classifier] settings kind=${this.current.kind} shadowLog=${this.current.shadowLog === true}`);
    return this.get();
  }
}

/** Tolerant reader: a missing, oversized or malformed file means "off". */
function readSettings(path: string, log: (line: string) => void): ClassifierSettings {
  try {
    if (statSync(path).size > MAX_FILE_BYTES) {
      log("[classifier] ignoring oversized classifier settings");
      return { ...DEFAULT_CLASSIFIER_SETTINGS };
    }
    const parsed = parseClassifierSettings(JSON.parse(readFileSync(path, "utf8")));
    if (parsed.ok) return parsed.settings;
    log("[classifier] ignoring invalid classifier settings");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") log("[classifier] ignoring unreadable classifier settings");
  }
  return { ...DEFAULT_CLASSIFIER_SETTINGS };
}

/** The sidecar shipped with pi-os: <root>/sidecars/laya/ next to node-harness (src or dist). */
export function defaultSidecarScript(): string {
  return fileURLToPath(new URL("../../../sidecars/laya/laya_intent_sidecar.py", import.meta.url));
}

export interface LayaLaunch {
  python: string;
  script: string;
  modelDir: string;
  threads: number;
  sha256?: string;
  calibration?: string;
}

export type LayaLaunchReason =
  | "python_not_configured" | "python_not_found"
  | "model_dir_not_configured" | "model_dir_not_found"
  | "script_not_found" | "calibration_not_found";

/** A Python interpreter by name (venvs ship python, python3 and python3.x). */
const PYTHON_NAME = /^python(?:3(?:\.\d{1,2})?)?$/u;

export type LayaLaunchResolution = { ok: true; launch: LayaLaunch } | { ok: false; reason: LayaLaunchReason };

const absolute = (value: string | undefined): string | undefined =>
  value && isAbsolute(value) && !CONTROL.test(value) ? value : undefined;

/**
 * Settings first, then PI_OS_LAYA_PYTHON / PI_OS_LAYA_MODEL_DIR, then `<supportDir>/laya/venv/bin/python`
 * and `<supportDir>/laya/model` when those exist. The script is PI_OS_LAYA_SCRIPT or the shipped copy,
 * never a setting. Absolute paths only; only existsSync-style checks, nothing is spawned.
 */
export function resolveLayaLaunch(
  settings: ClassifierSettings,
  env: NodeJS.ProcessEnv = process.env,
  exists: (path: string) => boolean = existsSync,
  supportDir?: string,
): LayaLaunchResolution {
  const local = (path: string, marker = path): string | undefined =>
    (supportDir && exists(join(supportDir, marker)) ? join(supportDir, path) : undefined);
  const python = absolute(settings.python ?? env.PI_OS_LAYA_PYTHON) ?? local(join("laya", "venv", "bin", "python"));
  if (!python) return { ok: false, reason: "python_not_configured" };
  if (!PYTHON_NAME.test(basename(python)) || !exists(python)) return { ok: false, reason: "python_not_found" };
  const modelDir = absolute(settings.modelDir ?? env.PI_OS_LAYA_MODEL_DIR) ?? local(join("laya", "model"), join("laya", "model", "rl_agent_config.json"));
  if (!modelDir) return { ok: false, reason: "model_dir_not_configured" };
  if (!exists(join(modelDir, "rl_agent_config.json"))) return { ok: false, reason: "model_dir_not_found" };
  const script = absolute(env.PI_OS_LAYA_SCRIPT) ?? defaultSidecarScript();
  if (!exists(script)) return { ok: false, reason: "script_not_found" };
  if (settings.calibration && !exists(settings.calibration)) return { ok: false, reason: "calibration_not_found" };
  return {
    ok: true,
    launch: {
      python, script, modelDir,
      threads: settings.threads ?? DEFAULT_LAYA_THREADS,
      ...(settings.sha256 ? { sha256: settings.sha256 } : {}),
      ...(settings.calibration ? { calibration: settings.calibration } : {}),
    },
  };
}
