import { join } from "node:path";
import { supportDirectory } from "../platformPaths.js";
import { readJsonObjectFile, SettingsFile } from "../settingsFile.js";

/**
 * User-selected agent model + reasoning effort, chosen in the host settings
 * page and applied by every NEW invocation (sessions are per-invocation, so
 * an in-flight invocation keeps its own model).
 *
 * Persisted under the `model` key of %LOCALAPPDATA%\pi-os\settings.json
 * (macOS: ~/Library/Application Support/pi-os/settings.json) so the choice
 * survives restarts of the supervised harness child. The file is shared with
 * other key-scoped stores (`routing`), so writes are an atomic read-modify-write
 * of this key only (settingsFile.ts); sibling keys are never dropped.
 *
 * No stored selection means the Auto virtual model `pi-os/auto` (agentRunner).
 */

export interface ModelSelection {
  provider: string;
  modelId: string;
  /** pi ThinkingLevel name; the SDK clamps to model capabilities at use time. */
  thinkingLevel: string;
}

export const MODEL_SETTINGS_KEY = "model";

export class AgentModelSettings {
  private current: ModelSelection | null;
  private readonly file: SettingsFile;

  constructor(
    readonly filePath: string = defaultSettingsPath(),
    private readonly log: (line: string) => void = (line) => console.log(line),
  ) {
    this.file = new SettingsFile(filePath, log);
    this.current = readSelection(this.filePath, this.log);
    if (this.current) {
      const c = this.current;
      this.log(`[settings] loaded model preference ${c.provider}/${c.modelId} effort=${c.thinkingLevel}`);
    } else {
      this.log("[settings] no model preference; Auto (pi-os/auto) is the default");
    }
  }

  get(): ModelSelection | null {
    return this.current;
  }

  /**
   * Store and persist a validated selection. Returns the previous selection;
   * the caller logs the old -> new switch.
   */
  set(selection: ModelSelection): ModelSelection | null {
    const previous = this.current;
    this.current = {
      provider: selection.provider,
      modelId: selection.modelId,
      thinkingLevel: selection.thinkingLevel,
    };
    try {
      this.file.update(MODEL_SETTINGS_KEY, this.current);
    } catch (error) {
      // Memory-only fallback: the session still honors the choice until restart.
      this.log(`[settings] failed writing model preference: ${error instanceof Error ? error.message : String(error)}`);
    }
    return previous;
  }
}

export function defaultSettingsPath(supportDir: string = supportDirectory()): string {
  return join(supportDir, "settings.json");
}

/** Tolerant reader: any malformed/stale file degrades to "no preference". */
function readSelection(path: string, log: (line: string) => void): ModelSelection | null {
  const { data, status } = readJsonObjectFile(path);
  if (status === "corrupt") {
    log("[settings] ignoring unreadable settings.json");
    return null;
  }
  const m = data[MODEL_SETTINGS_KEY] as Partial<ModelSelection> | undefined;
  if (
    typeof m?.provider === "string" && m.provider &&
    typeof m?.modelId === "string" && m.modelId &&
    typeof m?.thinkingLevel === "string" && m.thinkingLevel
  ) {
    return { provider: m.provider, modelId: m.modelId, thinkingLevel: m.thinkingLevel };
  }
  if (m !== undefined) {
    log("[settings] ignoring incomplete model entry in settings.json");
  } // Else: valid file without a model entry -> Auto default.
  return null;
}
