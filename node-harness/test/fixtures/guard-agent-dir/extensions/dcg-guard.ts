import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Test-only stand-in for a user's global dcg hook (`~/.pi/agent/extensions/dcg-guard.ts`): it sees every bash
 * call before it runs and fails closed. It never spawns dcg or any other process and shows no dialog. A command
 * containing the marker `fixture-destructive` (or a call without a command string) is blocked; everything else
 * runs, so tests exercise both outcomes with harmless commands only.
 */
export const FIXTURE_DESTRUCTIVE_MARKER = "fixture-destructive";

export default function fixtureDcgGuard(pi: ExtensionAPI): void {
  pi.on("tool_call", (event) => {
    if (event.toolName !== "bash") return undefined;
    const command = (event.input as { command?: unknown }).command;
    if (typeof command !== "string" || command.includes(FIXTURE_DESTRUCTIVE_MARKER)) {
      return { block: true, reason: "fixture dcg guard: denied" };
    }
    return undefined;
  });
}
