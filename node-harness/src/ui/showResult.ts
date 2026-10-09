import { parseStreamingJson } from "@earendil-works/pi-ai";
import type { ExtensionAPI, InlineExtension } from "@earendil-works/pi-coding-agent";
import type { CardSpec } from "../contracts/cards.js";
import { blocksToCard, partialBlocksToCard, showResultParamsSchema, withoutNullMembers, type BlocksOptions, type FileRefSource } from "./blocks.js";
import type { CardIssue } from "./validate.js";

/**
 * pi tool `show_result`: the agent's way to answer with a native card.
 *
 * The model sends flat blocks; Node builds and strictly validates the card
 * (file rows only from this thread's ledger), hands it to `onCard`, and ends
 * the agent loop (`terminate: true`) so no second model round-trip is spent
 * restating it. While the call streams, partial cards are built leniently
 * from the provider's partially parsed arguments. Invalid calls come back to
 * the model as tool errors so it can fix them. Nothing here logs content.
 *
 * Cards are for structured results only (r2/DESIGN2 §5.6): prose and one-line
 * answers stream as text from the first token, while a card shows nothing
 * readable until its call is generated (a one-sentence card cost 93–95 output
 * tokens against 11 as text).
 */

export const SHOW_RESULT_TOOL = "show_result";

export const SHOW_RESULT_GUIDELINES = [
  "Use show_result only for structured results: computed values, files found by pi-os file tools, tables, key facts, links or follow-up suggestions. Answer explanations, prose and one-line answers in plain text, which the user sees as it streams.",
  "Put only data you actually have from the conversation, the screen or tool results into show_result. Never invent values, sample rows, file names, paths, links or metadata.",
  "For files pass only refs (f1, f2, …) returned by a pi-os file tool in this conversation; never write paths or tokens.",
  "show_result ends your turn and its card is the answer: write at most one short sentence before it and nothing after it. If it returns invalid_card, fix the named blocks and call it again, or answer in text.",
];

export interface ShowResultExtensionOptions extends BlocksOptions {
  /** The thread's FileLedger (shared with the file-search tools). */
  ledger: FileRefSource;
  /**
   * Receives each displayable card: partial ones while the call streams
   * (complete=false, possibly several), then the validated final card
   * (complete=true) right before the tool ends the turn. If no complete card
   * follows (invalid call, abort), partial cards must be discarded.
   */
  onCard(spec: CardSpec, complete: boolean): void;
  /** Minimum gap between partial cards; 0 disables partial cards. Default 50 ms. */
  partialIntervalMs?: number;
  now?: () => number;
}

function formatIssues(issues: readonly CardIssue[]): string {
  const shown = issues.slice(0, 8).map(issue => `${issue.path || "card"}: ${issue.message}`);
  return `${shown.join("; ")}${issues.length > shown.length ? ` (+${issues.length - shown.length} more)` : ""}`;
}

function hasKeys(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && Object.keys(value).length > 0;
}

export function createShowResultExtension(options: ShowResultExtensionOptions): InlineExtension {
  const interval = options.partialIntervalMs ?? 50;
  const now = options.now ?? Date.now;
  return {
    name: "pi-os-show-result",
    factory(pi: ExtensionAPI) {
      // The show_result call currently streaming (one per assistant message at a time).
      let streaming: { contentIndex: number; json: string; lastAt: number; last: string } | undefined;

      if (interval > 0) {
        pi.on("message_update", (event) => {
          const update = event.assistantMessageEvent;
          if (update.type === "toolcall_start") {
            const block = update.partial.content[update.contentIndex];
            streaming = block?.type === "toolCall" && block.name === SHOW_RESULT_TOOL
              ? { contentIndex: update.contentIndex, json: "", lastAt: Number.NEGATIVE_INFINITY, last: "" } : undefined;
          } else if (update.type === "toolcall_delta" && streaming?.contentIndex === update.contentIndex) {
            streaming.json += update.delta;
            if (now() - streaming.lastAt < interval) return;
            // Providers keep partially parsed arguments on the live block; fall back to the raw deltas.
            const block = update.partial.content[update.contentIndex];
            const args = block?.type === "toolCall" && hasKeys(block.arguments) ? block.arguments : parseStreamingJson(streaming.json);
            const spec = partialBlocksToCard(args, options.ledger, options);
            if (!spec) return;
            const serialized = JSON.stringify(spec);
            if (serialized === streaming.last) return;
            streaming.lastAt = now();
            streaming.last = serialized;
            try { options.onCard(spec, false); } catch { /* A display hiccup must never break the stream. */ }
          } else if (update.type === "toolcall_end" && streaming?.contentIndex === update.contentIndex) {
            streaming = undefined;
          }
        });
        pi.on("message_end", () => { streaming = undefined; });
      }

      pi.registerTool({
        name: SHOW_RESULT_TOOL,
        label: "Show Result",
        description: "Display a structured final answer as a native pi-os card built from blocks: a computed result, key/value facts, "
          + "a small table, files (ledger refs from pi-os file tools), links, a status line, a notice, follow-up suggestions, or markdown "
          + "prose next to them. Each block has only the fields of its type. Ends the turn. Plain answers go in text, not here.",
        promptSnippet: "Display a structured answer as a native card (values, tables, files, links, suggestions)",
        promptGuidelines: SHOW_RESULT_GUIDELINES,
        parameters: showResultParamsSchema,
        // The block union is outside pi's strict subset, so "prefer" sends it without provider-side strict
        // sampling (no null padding); pi checks the schema and blocksToCard stays the authority.
        constrainedSampling: { type: "json_schema", strict: "prefer" },
        prepareArguments: withoutNullMembers,
        // The card is the turn's final answer: codemode scripts cannot call it mid-run.
        exposure: "model-only",
        async execute(_toolCallId, params) {
          streaming = undefined;
          const card = blocksToCard(params, options.ledger, options);
          if (!card.ok) {
            return { content: [{ type: "text", text: `invalid_card: ${formatIssues(card.issues)}` }], details: {}, isError: true };
          }
          try {
            options.onCard(card.spec, true);
          } catch {
            return { content: [{ type: "text", text: "display_failed: The card could not be shown; answer in text instead." }], details: {}, isError: true };
          }
          return { content: [{ type: "text", text: "Displayed to the user." }], details: {}, terminate: true };
        },
      });
    },
  };
}
