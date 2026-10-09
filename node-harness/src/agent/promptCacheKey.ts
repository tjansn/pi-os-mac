import { createHash } from "node:crypto";
import type { InlineExtension } from "@earendil-works/pi-coding-agent";

/**
 * Stable prompt-cache keys for Responses-shaped provider bodies (openai-codex-responses,
 * openai-responses, azure-openai-responses).
 *
 * pi sends the session id as `prompt_cache_key`, and pi-os mints one session (and id) per
 * thread, so a random key per invocation spreads requests that share the same ~4K-token
 * static prefix (instructions + tool schemas) across cache machines. This hook replaces only
 * the body's key with a hash of that prefix per prompt variant. Everything that identifies the
 * thread stays per thread: options.sessionId, the session-id / x-client-request-id headers,
 * the WebSocket cache and SSE-fallback state, and dispose cleanup.
 *
 * The hash never includes `input` (user text, images, history), and instructions (which may
 * contain AGENTS.md content in trusted mode) are never sent in clear.
 */

const MAX_KEY_LENGTH = 64;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const proto = Object.getPrototypeOf(value) as unknown;
  return proto === Object.prototype || proto === null;
}

/** The body with a stable `prompt_cache_key`, or undefined (leave the payload unchanged). */
export function stabilizePromptCacheKey(payload: unknown): unknown {
  if (!isPlainObject(payload) || typeof payload.prompt_cache_key !== "string") return undefined;
  // Responses-shaped bodies only; cacheRetention "none" (no key) and other APIs stay untouched.
  if (typeof payload.instructions !== "string" && !Array.isArray(payload.input)) return undefined;
  const prefix = JSON.stringify([payload.model ?? null, payload.instructions ?? "", payload.tools ?? [], payload.tool_choice ?? null]);
  const key = `pi-os-${createHash("sha256").update(prefix).digest("hex").slice(0, 32)}`.slice(0, MAX_KEY_LENGTH);
  return { ...payload, prompt_cache_key: key };
}

/** First-party extension (isolated and trusted sessions alike) registering the payload hook. */
export function createPromptCacheExtension(): InlineExtension {
  return {
    name: "pi-os-prompt-cache",
    factory(pi) {
      pi.on("before_provider_request", (event) => stabilizePromptCacheKey(event.payload));
    },
  };
}
