import type { HostAction } from "./actions.js";

/**
 * Host launcher routes (protocol.md "Launcher routes"). Same envelope as the
 * other host tools: request `{ arguments: … }`, response
 * `{ ok: true, result: … } | { ok: false, error: { code, message } }`.
 *
 *   POST /tools/launcher.searchFiles  (read)   FileSearchRequest -> FileSearchResult
 *   POST /tools/launcher.listApps     (read)   ListAppsRequest   -> AppIndexResult
 *   POST /tools/launcher.open         (effect) LauncherOpenRequest -> LauncherOpenResult
 *
 * File tokens are minted by the host per search (random, TTL 10 min). Node
 * never sends a path back for an effect; it sends the token.
 */

export const LAUNCHER_ROUTES = ["launcher.searchFiles", "launcher.listApps", "launcher.open"] as const;

export interface FileSearchRequest {
  contextId?: string;
  /** OR of AND-groups of name terms, e.g. [["invoice"], ["rechnung"]]; ≤ 6 terms total, ≤ 64 chars each. */
  nameGroups: string[][];
  /** UTI the results must conform to (kMDItemContentTypeTree), e.g. "com.adobe.pdf". */
  contentType?: string;
  /** Default ["home"]. */
  scopes?: ("home" | "applications" | "icloud")[];
  /** ≤ 200; default 100. */
  maxResults?: number;
}

export interface FileCandidate {
  token: string;
  name: string;
  /** Absolute path, for display and ranking only (never logged). */
  path: string;
  contentType?: string;
  createdMs?: number;
  modifiedMs?: number;
  lastUsedMs?: number;
  useCount?: number;
  isDirectory: boolean;
  isPackage: boolean;
}

export interface FileSearchResult {
  items: FileCandidate[];
  /** True when the host stopped at maxResults. */
  truncated: boolean;
  elapsedMs: number;
}

export interface ListAppsRequest {
  contextId?: string;
}

export interface AppRecord {
  bundleId: string;
  name: string;
  /** Localized/alternate names (CFBundleDisplayName, CFBundleName, file name). */
  aliases: string[];
  path: string;
  running: boolean;
}

export interface AppIndexResult {
  /** Changes whenever the index changes; Node caches by it. */
  version: string;
  apps: AppRecord[];
}

/** Agent-initiated effects are limited to these; the UI path calls LauncherService directly. */
export interface LauncherOpenRequest {
  contextId?: string;
  action: Extract<HostAction, { type: "openApp" | "openURL" | "openFile" | "revealFile" }>;
}

export interface LauncherOpenResult {
  /** User-visible status, e.g. "Opened Figma". */
  status: string;
  /** "revealFile" when an executable/script/installer was downgraded from openFile. */
  performed: "openApp" | "openURL" | "openFile" | "revealFile";
}
