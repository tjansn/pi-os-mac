import { homedir } from "node:os";
import { join, posix } from "node:path";

/**
 * Keep Windows' existing layout; Finder-launched Mac apps use Application Support. The macOS
 * path is POSIX on every Node host (path.posix), so an injected "darwin" computes the same
 * directory wherever the tests run; the Windows path keeps the host's own join.
 */
export function supportDirectory(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
  home = homedir(),
): string {
  if (platform === "darwin") return env.PI_OS_SUPPORT_DIR ?? posix.join(home, "Library", "Application Support", "pi-os");
  return join(env.LOCALAPPDATA ?? join(home, "AppData", "Local"), "pi-os");
}
