import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Test-only global extension that subscribes to `tool_call` but is not dcg: GET /settings/resources reports
 * `guard: "other"` for it. It allows every call and keeps nothing (no file, process or log).
 */
export default function fixtureCommandAudit(pi: ExtensionAPI): void {
  pi.on("tool_call", () => undefined);
}
