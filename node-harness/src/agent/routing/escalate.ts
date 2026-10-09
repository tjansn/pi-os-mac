import { Type } from "typebox";
import { defineTool, type InlineExtension } from "@earendil-works/pi-coding-agent";

/**
 * `pi_os_escalate`: the model's explicit "hand off to a stronger model" signal
 * (routing.md §6.6). The tool itself does nothing but acknowledge; the Auto
 * router sees its successful tool result on the next `continuation` request
 * and moves one rung up the escalation ladder (at most twice per user turn).
 *
 * Harmless by construction (no side effects, no host calls), so it is allowed
 * in isolated and read-only sessions. Activate it only for sessions running on
 * the `pi-os/auto` virtual model; on a manually chosen model it would be a no-op.
 */

export const ESCALATE_TOOL_NAME = "pi_os_escalate";

export function createEscalateTool() {
  return defineTool({
    name: ESCALATE_TOOL_NAME,
    label: "Hand off to a stronger model",
    description: "Call this when the task turned out harder than expected, you are unsure how to proceed, or two attempts failed. "
      + "The next step continues with a stronger model and the full history. Never call it for simple tasks.",
    parameters: Type.Object({
      reason: Type.String({ maxLength: 200, description: "Short reason, e.g. 'two clicks missed the target'" }),
    }, { additionalProperties: false }),
    // The router only sees a top-level tool result, so a codemode script calling it would be told
    // "handing off" while nothing happens: declared to the model, never callable from scripts.
    exposure: "model-only",
    executionMode: "sequential",
    async execute() {
      // The reason stays in the transcript only; it is never logged or persisted elsewhere.
      return {
        content: [{ type: "text" as const, text: "Handing off to a stronger model. Continue the task from where you are." }],
        details: {},
      };
    },
  });
}

/** Inline extension registering the tool (loadAgentResources accepts several extensions). */
export function createEscalateExtension(): InlineExtension {
  return { name: "pi-os-escalate", factory(pi) { pi.registerTool(createEscalateTool()); } };
}
