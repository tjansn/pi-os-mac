import { createAgentSession, DefaultResourceLoader, getAgentDir, hasTrustRequiringProjectResources, ProjectTrustStore, SessionManager,
  SettingsManager, type DefaultProjectTrust, type InlineExtension, type LoadExtensionsResult, type ModelRuntime, type ProjectTrustContext,
  type ProjectTrustEventResult } from "@earendil-works/pi-coding-agent";
import { stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { bashGuardOf, type BashGuard } from "../contracts/piSession.js";

/** pi >= 0.87 resizes prompt and tool-result images (2000 px / 4.5 MB, may re-encode to JPEG) and
 * appends a coordinate-multiplier hint. pi-os hosts own screenshot sizing and the click coordinate
 * space (protocol.md "Screenshot transfer"), so images must reach the provider unchanged. */
export const PI_OS_SETTINGS_OVERRIDES = { images: { autoResize: false } } as const;

/** Settings for every pi-os prompting session. Overrides live in memory only: they are never
 * written to the user's settings.json, and a settings reload/save inside pi would drop them, so
 * each session gets its own manager (never the resource loader's, which reload() resets). */
export function createSessionSettings(isolated: boolean, cwd = process.cwd(), agentDir = getAgentDir(),
  platform: NodeJS.Platform = process.platform, options: { projectTrusted?: boolean } = {}): SettingsManager {
  // A full pi session (macOS, trusted) passes the project trust pi's own resolution decided (projectTrustOf).
  const full = platform === "darwin" && !isolated && options.projectTrusted !== undefined;
  const settings = full ? SettingsManager.create(cwd, agentDir, { projectTrusted: options.projectTrusted })
    : platform === "darwin" || isolated
    ? SettingsManager.create(cwd, agentDir, { projectTrusted: false })
    // Windows trusted mode: identical to createAgentSession's own default manager.
    : SettingsManager.create(cwd, agentDir);
  // pi merges override objects by reference; never share the constant with a session.
  settings.applyOverrides(structuredClone(PI_OS_SETTINGS_OVERRIDES));
  return settings;
}

/**
 * Lean pi-os identity for isolated macOS sessions (DESIGN2 §5.7). It replaces pi's coding-agent
 * preamble, tool list, `<docs>` and `<cwd>`; the computer-use extension sends it, followed by the
 * scope-neutral pi-os rules, as the complete system prompt. It never names the active window or the
 * scope, so it is byte-identical for general and window turns (stable prompt-cache prefix); window and
 * Brave guidance travel with the window tools instead.
 */
export const PI_OS_SYSTEM_PROMPT = [
  "You are pi-os, a desktop assistant on the user's Mac. The user pressed the pi-os hotkey while working in another app and typed or spoke a request.",
  "- Most requests are questions, explanations, writing or quick lookups: answer them directly, concisely and in plain text. Use a tool only when the request needs one.",
  "- You see only what the request carries. A \"## Desktop context\" section (usually with a screenshot) means the user's active window is included; otherwise only the active app's name is known, so never claim to see its content. Material under \"Attached by the user\" is what the user explicitly added.",
  "- A tool's description carries its rules; follow them while the tool is available.",
].join("\n");

export interface AgentResourceOptions {
  /** Replaces pi's default base prompt (isolated macOS sessions pass PI_OS_SYSTEM_PROMPT). */
  systemPrompt?: string;
  /** The session's host platform (default process.platform; createLiveSession passes the session's). */
  platform?: NodeJS.Platform;
}

/** The project trust a full session's loader resolved (pi's own resolution); undefined for every other loader. */
const projectTrust = new WeakMap<DefaultResourceLoader, boolean>();
export function projectTrustOf(loader: DefaultResourceLoader): boolean | undefined {
  return projectTrust.get(loader);
}

/** What pi-os answers a global extension's project_trust handler: no UI, so a handler can only decide by itself. */
function headlessTrustContext(cwd: string): ProjectTrustContext {
  return {
    cwd, mode: "rpc", hasUI: false,
    ui: { select: async () => undefined, confirm: async () => false, input: async () => undefined, notify: () => {} },
  };
}

/**
 * pi's project trust resolution for a session without UI (pi's `resolveProjectTrusted` with `hasUI: false`, as
 * `pi -p` runs it): a folder without trust-requiring project resources (`.pi` settings, extensions, skills,
 * prompts …, `.agents/skills`) is trusted; otherwise the first global extension's `project_trust` decision
 * (remembered in `trust.json` when it says so), then `~/.pi/agent/trust.json`, then the `defaultProjectTrust`
 * setting, where "ask" means untrusted because nobody can be asked. A malformed trust store fails closed.
 */
export async function resolveProjectTrust(input: {
  cwd: string; agentDir: string; defaultProjectTrust?: DefaultProjectTrust; extensionsResult?: LoadExtensionsResult;
}): Promise<boolean> {
  if (!hasTrustRequiringProjectResources(input.cwd)) return true;
  const store = new ProjectTrustStore(input.agentDir);
  for (const extension of input.extensionsResult?.extensions ?? []) {
    for (const handler of extension.handlers.get("project_trust") ?? []) {
      let result: ProjectTrustEventResult | undefined;
      try { result = await handler({ type: "project_trust", cwd: input.cwd }, headlessTrustContext(input.cwd)) as ProjectTrustEventResult | undefined; }
      catch { continue; /* pi reports the error and asks the next handler */ }
      if (!result || result.trusted === "undecided") continue;
      const trusted = result.trusted === "yes";
      if (result.remember === true) {
        try { store.set(input.cwd, trusted); } catch { /* the decision still holds for this session */ }
      }
      return trusted;
    }
  }
  let decision: boolean | null;
  try { decision = store.get(input.cwd); } catch { return false; }
  if (decision !== null) return decision;
  return input.defaultProjectTrust === "always";
}

export async function loadAgentResources(
  extensions: readonly InlineExtension[],
  cwd = process.cwd(),
  agentDir = getAgentDir(),
  isolated = false,
  options: AgentResourceOptions = {},
): Promise<DefaultResourceLoader> {
  const mac = (options.platform ?? process.platform) === "darwin";
  // macOS with trusted globals is a full pi session: project resources follow pi's own trust resolution
  // (resolveProjectTrust), and the folder's context files load like in terminal pi.
  const full = mac && !isolated;
  const settingsManager = SettingsManager.create(cwd, agentDir, { projectTrusted: mac ? false : !isolated });
  const loader = new DefaultResourceLoader({
    cwd, agentDir, extensionFactories: [...extensions],
    // pi 1.0: a custom base prompt replaces the preamble, tool list, rules and docs sections
    // (buildSystemPromptSections); a SYSTEM.md is then never discovered.
    ...(options.systemPrompt !== undefined ? { systemPrompt: options.systemPrompt } : {}),
    settingsManager,
    ...(isolated ? { noExtensions: true, noSkills: true, noPromptTemplates: true, noContextFiles: true } : {}),
  });
  // pi's pre-trust pass loads the global (and pi-os inline) extensions once, asks them and the trust store, then
  // loads the project's resources only when the folder is trusted.
  await loader.reload(full ? {
    resolveProjectTrust: async ({ extensionsResult }) => {
      const trusted = await resolveProjectTrust({ cwd, agentDir, defaultProjectTrust: settingsManager.getDefaultProjectTrust(), extensionsResult });
      projectTrust.set(loader, trusted);
      return trusted;
    },
  } : undefined);
  if (loader.getExtensions().errors.length) throw new Error("resource_load_failed: A configured pi extension could not load; check your extension configuration");
  return loader;
}

/**
 * The global (`~/.pi/agent`) extensions alone, for the content-free bash guard status: no project resources,
 * skills, prompts, themes or context files, no pi-os extensions, no session. Runs the extensions' factory code
 * (callers do this only while full sessions are on). Load errors are left out, not thrown.
 */
export async function loadGlobalExtensions(agentDir = getAgentDir()): Promise<LoadExtensionsResult> {
  const loader = new DefaultResourceLoader({
    cwd: agentDir, agentDir, settingsManager: SettingsManager.create(agentDir, agentDir, { projectTrusted: false }),
    noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  });
  await loader.reload();
  return loader.getExtensions();
}

/** bashGuardOf over the global extensions (protocol.md resource status `guard`): `dcg`, `other` or `none`. */
export async function globalBashGuard(agentDir = getAgentDir()): Promise<BashGuard> {
  const { extensions } = await loadGlobalExtensions(agentDir);
  return bashGuardOf(extensions.map(extension => ({ path: extension.path, scope: extension.sourceInfo.scope, events: extension.handlers.keys() })));
}

/**
 * GET /settings/resources' guard status, per agent dir for this process. Loading the global extensions runs their
 * factories (one may fetch a local model list), so they load again only when the agent dir's `extensions` folder
 * (an extension added, removed or renamed) or its `settings.json` (extension packages and paths) changed its mtime,
 * or after forgetGlobalBashGuards (the resource mode changed). A failed load is not remembered.
 */
const bashGuards = new Map<string, { stamp: string; guard: Promise<BashGuard> }>();

export async function cachedGlobalBashGuard(agentDir = getAgentDir(), load: (agentDir: string) => Promise<BashGuard> = globalBashGuard): Promise<BashGuard> {
  const key = resolve(agentDir);
  const mtime = (path: string) => stat(path).then(info => String(info.mtimeMs), () => "-");
  const stamp = (await Promise.all([mtime(join(key, "extensions")), mtime(join(key, "settings.json"))])).join(":");
  const cached = bashGuards.get(key);
  if (cached?.stamp === stamp) return cached.guard;
  const guard = load(key);
  bashGuards.set(key, { stamp, guard });
  guard.catch(() => { if (bashGuards.get(key)?.guard === guard) bashGuards.delete(key); });
  return guard;
}

/** The resource mode changed: the next full-mode status loads the global extensions again. */
export function forgetGlobalBashGuards(): void {
  bashGuards.clear();
}

/** Public SDK bootstrap flushes factory-registered providers before model selection.
 * No prompt, inference, session_start hook or settings write. Factory code itself is
 * trusted executable code, which is why this path is explicit opt-in on Mac. */
export async function registerResourceProviders(loader: DefaultResourceLoader, runtime: ModelRuntime): Promise<() => void> {
  const { session } = await createAgentSession({
    modelRuntime: runtime, resourceLoader: loader, tools: [],
    sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(PI_OS_SETTINGS_OVERRIDES),
  });
  // Keep the bootstrap alive while its loader/runtime is reused. Disposing here would
  // permanently invalidate the ExtensionAPI captured by every loaded extension.
  return () => session.dispose();
}
