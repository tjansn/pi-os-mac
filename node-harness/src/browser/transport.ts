import type { HostClient } from "../hostClient.js";
import { parseBrowserHint } from "../contracts/browser.js";
import { AxTransport } from "./axTransport.js";
import { BrowserSession } from "./session.js";

/**
 * Transport for the pinned Brave tab, chosen by the host's snapshot hint (DESIGN2 §7):
 * - `ax` (default): host Accessibility routes, no DevTools socket, no dialog. Reads always; acts in
 *   the background only when the hint says `background: true` (Settings "Act in Brave without
 *   bringing it to the front"). desktop_act stays available, Brave is a native target.
 * - `cdp`: the explicit DevTools opt-in; browser_act replaces desktop_act as before.
 * - `extension` (stage C) is not implemented: no transport, and never a DevTools fallback.
 * Common members: `mode`, `replacesDesktopAct`, `canAct`, `exclusive`, `snapshot`,
 * `invalidateReferences`, `dispose`; `act` differs per mode (see registerBrowserTools).
 */
export type BrowserTransport = AxTransport | BrowserSession;

export interface BrowserTransportOptions {
  readOnly: boolean;
  /** Invocation lifetime; aborting ends the transport (and closes a CDP socket). */
  signal?: AbortSignal;
  platform?: NodeJS.Platform;
}

/**
 * The transport for this context, or undefined (not macOS, no or invalid hint, unknown mode, an ax
 * tab the host could not pin, or a read-only DevTools session: CDP is never opened just to read).
 */
export function createBrowserTransport(hint: unknown, host: HostClient, contextId: string, options: BrowserTransportOptions): BrowserTransport | undefined {
  if ((options.platform ?? process.platform) !== "darwin" || hint === undefined || hint === null) return undefined;
  const parsed = parseBrowserHint(hint);
  if (!parsed.ok) return undefined;
  const { mode, pinned, background } = parsed.value;
  if (mode === "ax") {
    return pinned ? new AxTransport(host, contextId, { background: background === true && !options.readOnly, ...(options.signal ? { signal: options.signal } : {}) }) : undefined;
  }
  if (mode === "cdp") return options.readOnly ? undefined : new BrowserSession(host, contextId, options.signal);
  return undefined;
}
