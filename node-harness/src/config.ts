import { join } from "node:path";
import { supportDirectory } from "./platformPaths.js";

/**
 * Environment-driven configuration for the node harness.
 * Defaults match shared/protocol/protocol.md.
 */
export interface HarnessConfig {
  port: number;
  hostBaseUrl: string;
  hostToken: string | undefined;
  /** Routes invocations through a real pi agent session.
   *  Default ON since 2026-08-24 (product decision): slice mode only helps
   *  headless smoke tests. Opt out with PI_OS_AGENT=0 or =false. */
  agentEnabled: boolean;
  /** Max wall-clock time per invocation in ms (PI_OS_INVOKE_TIMEOUT_MS). 0 disables. Default: 5 min. */
  invokeTimeoutMs: number;
  /**
   * The same limit for a full pi session's turn (macOS `trustedGlobal`, protocol.md "Full pi session (macOS)";
   * PI_OS_FULL_INVOKE_TIMEOUT_MS): coding work and the user's command guard's approval dialog count against it.
   * 0 disables. Default (also when absent): FULL_INVOKE_TIMEOUT_MS. Isolated sessions and Windows keep invokeTimeoutMs.
   */
  fullInvokeTimeoutMs?: number;
  /** Trusted directory where the C# host writes screenshots. */
  capturesDir: string;
  /** Explicit read-only mode; Mac additionally negotiates native input availability per invocation. */
  readOnly?: boolean;
  /** Explicit opt-out for isolated split development only. */
  insecureDev?: boolean;
  /** Instant lane (POST /instant and instant answers in /invoke). PI_OS_INSTANT=0 turns it off. Default on. */
  instantEnabled?: boolean;
  /** On-demand ECB reference-rate download for currency answers (PI_OS_FX_RATES=0 disables). Default on. */
  fxRatesEnabled?: boolean;
  /** Default web search URL with `%s` (PI_OS_WEB_SEARCH, http/https only). Default DuckDuckGo. */
  webSearchTemplate?: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): HarnessConfig {
  const webSearchTemplate = parseSearchTemplate(env.PI_OS_WEB_SEARCH);
  return {
    port: Number.parseInt(env.PI_OS_NODE_PORT ?? "17832", 10),
    hostBaseUrl: env.PI_OS_HOST_URL ?? "http://127.0.0.1:17831",
    hostToken: env.PI_OS_TOKEN,
    agentEnabled: parseAgentEnabled(env.PI_OS_AGENT),
    invokeTimeoutMs: parseTimeoutMs(env.PI_OS_INVOKE_TIMEOUT_MS),
    fullInvokeTimeoutMs: parseTimeoutMs(env.PI_OS_FULL_INVOKE_TIMEOUT_MS, FULL_INVOKE_TIMEOUT_MS),
    capturesDir: env.PI_OS_CAPTURES_DIR ?? join(supportDirectory(env), "captures"),
    readOnly: env.PI_OS_READ_ONLY === "1",
    insecureDev: env.PI_OS_INSECURE_DEV === "1" && env.PI_OS_SUPERVISED !== "1",
    instantEnabled: parseFlag(env.PI_OS_INSTANT, true),
    fxRatesEnabled: parseFlag(env.PI_OS_FX_RATES, true),
    ...(webSearchTemplate ? { webSearchTemplate } : {}),
  };
}

/** Unset/blank -> fallback; explicit 0/false/off -> false; anything else -> true. */
function parseFlag(raw: string | undefined, fallback: boolean): boolean {
  if (raw === undefined || raw.trim() === "") return fallback;
  return !["0", "false", "off"].includes(raw.trim().toLowerCase());
}

/** Only an http(s) template containing exactly one %s is accepted; anything else keeps the default. */
function parseSearchTemplate(raw: string | undefined): string | undefined {
  const value = raw?.trim();
  if (!value || value.length > 512 || value.split("%s").length !== 2) return undefined;
  try {
    const url = new URL(value.replace("%s", "q"));
    return url.protocol === "https:" || url.protocol === "http:" ? value : undefined;
  } catch {
    return undefined;
  }
}

/** A full pi session's default invocation limit: 60 minutes. */
export const FULL_INVOKE_TIMEOUT_MS = 60 * 60_000;

function parseTimeoutMs(raw: string | undefined, fallback = 300_000): number {
  const value = Number.parseInt(raw ?? String(fallback), 10);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

/** Unset -> true (agent mode is the product); explicit 0/false -> slice mode. */
function parseAgentEnabled(raw: string | undefined): boolean {
  if (raw === undefined || raw.trim() === "") {
    return true;
  }
  return !["0", "false"].includes(raw.trim().toLowerCase());
}
