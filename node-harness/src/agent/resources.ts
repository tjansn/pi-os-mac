import { join, resolve } from "node:path";
import { createAgentSession, DefaultResourceLoader, getAgentDir, SessionManager, SettingsManager,
  type InlineExtension, type ModelRuntime } from "@earendil-works/pi-coding-agent";

/** pi >= 0.87 resizes prompt and tool-result images (2000 px / 4.5 MB, may re-encode to JPEG) and
 * appends a coordinate-multiplier hint. pi-os hosts own screenshot sizing and the click coordinate
 * space (protocol.md "Screenshot transfer"), so images must reach the provider unchanged. */
export const PI_OS_SETTINGS_OVERRIDES = { images: { autoResize: false } } as const;

/** Settings for every pi-os prompting session. Overrides live in memory only: they are never
 * written to the user's settings.json, and a settings reload/save inside pi would drop them, so
 * each session gets its own manager (never the resource loader's, which reload() resets). */
export function createSessionSettings(isolated: boolean, cwd = process.cwd(), agentDir = getAgentDir(),
  platform: NodeJS.Platform = process.platform): SettingsManager {
  const settings = platform === "darwin" || isolated
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

export async function loadAgentResources(
  extensions: readonly InlineExtension[],
  cwd = process.cwd(),
  agentDir = getAgentDir(),
  isolated = false,
  options: AgentResourceOptions = {},
): Promise<DefaultResourceLoader> {
  const mac = (options.platform ?? process.platform) === "darwin";
  const loader = new DefaultResourceLoader({
    cwd, agentDir, extensionFactories: [...extensions],
    // pi 1.0: a custom base prompt replaces the preamble, tool list, rules and docs sections
    // (buildSystemPromptSections); a SYSTEM.md is then never discovered.
    ...(options.systemPrompt !== undefined ? { systemPrompt: options.systemPrompt } : {}),
    // Project resources are never trusted on Mac, even with explicit GLOBAL compatibility.
    settingsManager: SettingsManager.create(cwd, agentDir, { projectTrusted: mac ? false : !isolated }),
    ...(isolated ? { noExtensions: true, noSkills: true, noPromptTemplates: true, noContextFiles: true } : {}),
    ...(mac && !isolated ? {
      agentsFilesOverride: (base: { agentsFiles: { path: string; content: string }[] }) => ({
        agentsFiles: base.agentsFiles.filter(file => ["AGENTS.md", "CLAUDE.md"].some(name => resolve(file.path) === resolve(join(agentDir, name)))),
      }),
    } : {}),
  });
  await loader.reload();
  if (loader.getExtensions().errors.length) throw new Error("resource_load_failed: A configured pi extension could not load; check your extension configuration");
  return loader;
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
