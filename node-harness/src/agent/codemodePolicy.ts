import { createCodemodeExtension, type ExtensionAPI, type InlineExtension } from "@earendil-works/pi-coding-agent";
import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import { LAUNCHER_READ_TOOL_NAMES, OPEN_ITEM_TOOL } from "./launcherTools.js";

/**
 * pi 1.0 codemode for pi-os, safe subset (DESIGN B5, CRITIC C6/C7/S8).
 *
 * Scripts run in pi's QuickJS sandbox and reach tools only through ctx.executeTool(), which
 * already excludes `model-only` tools (desktop_act, desktop_capture_window, use_active_window,
 * browser_act, open_item, codemode itself). This policy is the second, independent layer:
 *  - a nested call is allowed only for an explicit list of read-only tools, so a tool that
 *    later becomes callable by accident (exposure change, trusted-mode extension, bash) is
 *    still refused, and scripts can never capture (coordinate authority) or mutate;
 *  - every script gets a deadline (pi's built-in has none);
 *  - script output is bounded here instead of by pi, which would spill the full output
 *    (window/page text) to a temp file.
 */

export const CODEMODE_TOOL = "codemode";
/** Name(s) to add to the isolated tools allowlist; naming it activates pi's inactive tool. */
export const CODEMODE_TOOL_NAMES = [CODEMODE_TOOL] as const;
/** Read-only tools scripts may call. None posts input, opens anything or yields an image. */
export const SCRIPT_CALLABLE_TOOLS = [
  "desktop_get_context", "desktop_refresh_context", "browser_snapshot", ...LAUNCHER_READ_TOOL_NAMES,
] as const;
/**
 * Never callable from a script, whatever exposure or options say. use_active_window captures (coordinate
 * authority follows images the model received) and switches the session's tools, like a direct call only.
 */
export const MODEL_ONLY_TOOLS = ["desktop_act", "desktop_capture_window", "use_active_window", "browser_act", OPEN_ITEM_TOOL, CODEMODE_TOOL] as const;

export const CODEMODE_DEFAULT_TIMEOUT_MS = 15_000;
export const CODEMODE_MAX_TIMEOUT_MS = 30_000;
/** Same default budget as pi (estimated tokens, 4 chars each), but never spilled to disk. */
export const CODEMODE_MAX_OUTPUT_TOKENS = 10_000;
const CHARS_PER_TOKEN = 4;
const OPTIONS_PREFIX = "// @options:";
/** Handed to pi so it never truncates (and therefore never writes a spill file). */
const PI_OUTPUT_TOKENS = 2 ** 31;

export interface CodemodePolicyOptions {
  /** Tools a script may call. Default SCRIPT_CALLABLE_TOOLS; MODEL_ONLY_TOOLS are always removed. */
  scriptCallable?: Iterable<string>;
}

/**
 * Clamp a codemode source's first-line options in place: timeout_ms defaults to 15 s and is
 * capped at 30 s; the requested max_output_tokens (≤ 10,000) is returned for this policy to
 * apply, and pi gets an effectively unlimited budget so it never spills. Malformed options are
 * left untouched: pi rejects them before any script runs.
 */
export function clampScriptOptions(code: string): { code: string; outputTokens: number } | undefined {
  const newline = code.indexOf("\n");
  const first = (newline === -1 ? code : code.slice(0, newline)).replace(/\r$/, "").trimStart();
  let requested: Record<string, unknown> = {};
  let body = code;
  if (first.startsWith(OPTIONS_PREFIX)) {
    try {
      const parsed: unknown = JSON.parse(first.slice(OPTIONS_PREFIX.length).trim());
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
      requested = parsed as Record<string, unknown>;
    } catch { return undefined; }
    if (newline === -1) return undefined;
    body = code.slice(newline + 1);
  }
  const positive = (value: unknown) => typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : undefined;
  const timeout = Math.min(positive(requested.timeout_ms) ?? CODEMODE_DEFAULT_TIMEOUT_MS, CODEMODE_MAX_TIMEOUT_MS);
  const outputTokens = Math.min(positive(requested.max_output_tokens) ?? CODEMODE_MAX_OUTPUT_TOKENS, CODEMODE_MAX_OUTPUT_TOKENS);
  const options = JSON.stringify({ max_output_tokens: PI_OUTPUT_TOKENS, timeout_ms: timeout });
  return { code: `${OPTIONS_PREFIX} ${options}\n${body}`, outputTokens };
}

/** Keep the start and end of over-budget script text in memory only (no spill file). */
export function boundScriptOutput(content: (TextContent | ImageContent)[], outputTokens: number): (TextContent | ImageContent)[] | undefined {
  const text = content.filter((item): item is TextContent => item.type === "text").map(item => item.text).join("\n");
  const budget = outputTokens * CHARS_PER_TOKEN;
  if (text.length <= budget) return undefined;
  const head = Math.floor(budget / 2), tail = budget - head;
  return [
    { type: "text", text: `${text.slice(0, head)}\n…[${text.length - budget} characters of script output omitted; print less or filter inside the script]…\n${tail > 0 ? text.slice(-tail) : ""}` },
    ...content.filter(item => item.type === "image"),
  ];
}

export function createCodemodePolicyExtension(options: CodemodePolicyOptions = {}): InlineExtension {
  const never = new Set<string>(MODEL_ONLY_TOOLS);
  const callable = new Set([...(options.scriptCallable ?? SCRIPT_CALLABLE_TOOLS)].filter(name => !never.has(name)));
  const budgets = new Map<string, number>();
  return {
    name: "pi-os-codemode-policy",
    factory(pi: ExtensionAPI) {
      pi.on("tool_call", (event) => {
        if (event.parentToolCallId) {
          if (callable.has(event.toolName)) return undefined;
          const direct = never.has(event.toolName) ? " Call it directly (not from a script) so you see its result." : "";
          return { block: true, reason: `policy_blocked: ${event.toolName} cannot be called from a script; scripts may only read.${direct}` };
        }
        if (event.toolName !== CODEMODE_TOOL || typeof event.input.code !== "string") return undefined;
        const clamped = clampScriptOptions(event.input.code);
        if (!clamped) return undefined;
        event.input.code = clamped.code;
        if (budgets.size >= 64) budgets.clear();
        budgets.set(event.toolCallId, clamped.outputTokens);
        return undefined;
      });
      pi.on("tool_result", (event) => {
        if (event.parentToolCallId || event.toolName !== CODEMODE_TOOL) return undefined;
        const outputTokens = budgets.get(event.toolCallId) ?? CODEMODE_MAX_OUTPUT_TOKENS;
        budgets.delete(event.toolCallId);
        const content = boundScriptOutput(event.content, outputTokens);
        return content ? { content } : undefined;
      });
    },
  };
}

/**
 * Inline extension factories for codemode: the policy first, then pi's codemode tool in "on"
 * mode (declared tools stay declared; screenshots reach the model only through direct calls),
 * a small inline catalog, and no `models` global (no classifier or image-model calls from
 * scripts). Add them to loadAgentResources and name CODEMODE_TOOL_NAMES in the allowlist.
 */
export function codemodeExtensionFactories(options: CodemodePolicyOptions = {}): InlineExtension[] {
  return [
    createCodemodePolicyExtension(options),
    { name: "pi-os-codemode", factory: createCodemodeExtension({ mode: "on", inlineBudget: 1500, models: false }) },
  ];
}
