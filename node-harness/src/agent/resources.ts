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
export function createSessionSettings(isolated: boolean, cwd = process.cwd(), agentDir = getAgentDir()): SettingsManager {
  const settings = process.platform === "darwin" || isolated
    ? SettingsManager.create(cwd, agentDir, { projectTrusted: false })
    // Windows trusted mode: identical to createAgentSession's own default manager.
    : SettingsManager.create(cwd, agentDir);
  // pi merges override objects by reference; never share the constant with a session.
  settings.applyOverrides(structuredClone(PI_OS_SETTINGS_OVERRIDES));
  return settings;
}

export async function loadAgentResources(
  extensions: readonly InlineExtension[],
  cwd = process.cwd(),
  agentDir = getAgentDir(),
  isolated = false,
): Promise<DefaultResourceLoader> {
  const loader = new DefaultResourceLoader({
    cwd, agentDir, extensionFactories: [...extensions],
    // Project resources are never trusted on Mac, even with explicit GLOBAL compatibility.
    settingsManager: SettingsManager.create(cwd, agentDir, { projectTrusted: process.platform === "darwin" ? false : !isolated }),
    ...(isolated ? { noExtensions: true, noSkills: true, noPromptTemplates: true, noContextFiles: true } : {}),
    ...(process.platform === "darwin" && !isolated ? {
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
