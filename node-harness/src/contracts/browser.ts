import { isCredentialLabel, isPageUrl } from "./attachments.js";

/**
 * Brave transport contracts (protocol.md "macOS private Brave adapter routes"): the snapshot's
 * `browser` hint and the private Accessibility routes `browser.page` (stage A: read the pinned tab
 * without a dialog or focus change) and `browser.axAct` (stage B: element-addressed AX actions while
 * Brave stays in the background). Swift mirror: `PiOSCore/BrowserContracts.swift` and `BrowserHint`
 * in `BrowserPolicy.swift`; wire fixtures: `shared/fixtures/browser-ax/*.json`.
 *
 * Refs (`e1`, `e2`, …) are opaque ids minted by the host per context from a monotonic counter: never
 * reused within a context, so a stale ref is unknown instead of pointing at another element. A new
 * `browser.page` read, an action and any navigation invalidate every earlier ref of that context
 * (an unknown ref is `browser_stale`). Node treats refs as opaque strings and never fabricates them.
 */

export const BROWSER_MODES = ["ax", "cdp", "extension"] as const;
/** `ax`: host Accessibility routes (default, no prompts). `cdp`: DevTools opt-in. `extension`: stage C. */
export type BrowserMode = (typeof BROWSER_MODES)[number];

/** Optional snapshot `browser` field (macOS). No endpoint or target capability is ever part of it. */
export interface BrowserHint {
  name: "Brave";
  mode: BrowserMode;
  pinned: boolean;
  /** `ax` only: the host accepts `browser.axAct` for this context (Settings "Act in Brave without bringing it to the front"). */
  background?: boolean;
}

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

export const BROWSER_PAGE_LIMITS = {
  /** Upper bound and default of `maxChars` (page text). */
  maxChars: 24_000,
  /** What Node stages into a window-scope first turn. */
  stagedChars: 12_000,
  /** Upper bound and default of `maxControls`: links + controls + fields (each carries a ref). */
  maxControls: 300,
  maxHeadings: 100,
  /** Title, heading, link, control and field labels (the host truncates longer ones). */
  maxLabelChars: 200,
  /** Non-credential field values. */
  maxValueChars: 1_000,
  /** `browser.axAct` setValue text (the shared input budget's per-action character cap). */
  maxSetValueChars: 20_000,
  maxVerificationChars: 500,
} as const;

export const BROWSER_REF_PATTERN = /^e[1-9][0-9]{0,6}$/;
export const BROWSER_CONTROL_ROLES = ["button", "checkbox", "radio", "switch", "tab", "menuitem", "select", "slider"] as const;
export type BrowserControlRole = (typeof BROWSER_CONTROL_ROLES)[number];
export const BROWSER_FIELD_ROLES = ["textbox", "searchbox", "textarea", "combobox"] as const;
export type BrowserFieldRole = (typeof BROWSER_FIELD_ROLES)[number];

/** POST /tools/browser.page `{arguments: BrowserPageRequest}`: read-only, no focus, no input budget. */
export interface BrowserPageRequest {
  contextId: string;
  /** 1..24,000; default 24,000. */
  maxChars?: number;
  /** 1..300; default 300. */
  maxControls?: number;
}

export interface BrowserHeading { label: string; level?: number }
export interface BrowserLink { label: string; ref: string }
export interface BrowserControl {
  label: string;
  role: BrowserControlRole;
  ref: string;
  pressed?: boolean;
  checked?: boolean;
  disabled?: boolean;
}
export interface BrowserField {
  label: string;
  role: BrowserFieldRole;
  ref: string;
  /** Secure text field or a clearly identified username/password field: never has a value. */
  secure: boolean;
  /** Current value of an ordinary field (≤ 1,000); never present when `secure`. */
  value?: string;
  disabled?: boolean;
}

/** `browser.page` result: an AX digest of the pinned window's selected tab. All of it is untrusted page content. */
export interface BrowserPageResult {
  title: string;
  /** http(s) only; omitted when the page URL is not an ordinary web URL. */
  url?: string;
  /** Visible page text (text markers), ≤ maxChars; credential field values are never included. */
  text: string;
  headings: BrowserHeading[];
  links: BrowserLink[];
  controls: BrowserControl[];
  fields: BrowserField[];
  /** True when text, headings or refs were cut at a cap. */
  truncated: boolean;
}

export const BROWSER_AX_ACTIONS = ["press", "setValue", "focus", "scrollIntoView"] as const;
export type BrowserAxAction = (typeof BROWSER_AX_ACTIONS)[number];

/**
 * POST /tools/browser.axAct `{arguments: BrowserAxActRequest}` (stage B). Host checks, in order: pin
 * verify (window, selected tab, URL); the ref is live and inside the pinned web area; role allow-list;
 * DeletionPolicy on the label; CredentialPolicy (`credential_input_blocked` unless the opt-in is on);
 * the shared input budget; uncertain-input poisoning. No focus change, Brave stays behind.
 */
export interface BrowserAxActRequest {
  contextId: string;
  ref: string;
  action: BrowserAxAction;
  /** setValue only (required there, forbidden otherwise): 0..20,000 chars; "" clears the field. */
  value?: string;
}

/** `browser.axAct` result. The tool envelope's `ok` carries success; failures are `{ok:false, error:{code}}`. */
export interface BrowserAxActResult {
  performed: true;
  action: BrowserAxAction;
  /** Host-written, ≤ 500 chars, e.g. `Pressed button "Like"; the page changed.` Not proof of the effect. */
  verification: string;
  /** Fresh digest after a short settle; its refs are the only valid ones afterwards. */
  page?: BrowserPageResult;
  /** Error code when the post-action read failed (the action itself was performed). */
  pageError?: string;
}

/** Domain error codes of the two routes (open set; see protocol.md). */
export const BROWSER_AX_ERRORS = [
  "unknown_context",
  "accessibility_denied",
  "browser_disabled",
  "browser_tab_unknown",
  "browser_target_changed",
  "browser_page_unsupported",
  "browser_stale",
  "browser_background_disabled",
  "browser_unsupported_action",
  "credential_input_blocked",
  "file_deletion_blocked",
  "budget_exceeded",
  "policy_blocked",
  "input_failed",
] as const;

const CONTEXT_ID = /^[A-Za-z0-9_-]{1,128}$/;
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;
const ERROR_CODE = /^[a-z][a-z0-9_]{0,63}$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function oneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}
function isLabel(value: unknown): value is string {
  return typeof value === "string" && value.length <= BROWSER_PAGE_LIMITS.maxLabelChars && !CONTROL.test(value);
}
/** An optional member is present unless absent or JSON `null` (Swift `decodeIfPresent` semantics). */
function present(value: unknown): boolean {
  return value !== undefined && value !== null;
}
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
/** No lone surrogate: Swift's JSONDecoder refuses one, so the host would answer HTTP 400. */
function isWellFormedText(value: string): boolean {
  return !LONE_SURROGATE.test(value);
}
function optionalFlag(value: unknown): boolean {
  return !present(value) || typeof value === "boolean";
}
function intIn(value: unknown, min: number, max: number): value is number {
  return Number.isInteger(value) && (value as number) >= min && (value as number) <= max;
}

export function parseBrowserHint(value: unknown): Parsed<BrowserHint> {
  if (!isRecord(value) || value.name !== "Brave") return { ok: false, error: "browser.name must be Brave" };
  if (!oneOf(BROWSER_MODES, value.mode)) return { ok: false, error: "browser.mode must be ax, cdp or extension" };
  if (typeof value.pinned !== "boolean" || !optionalFlag(value.background)) return { ok: false, error: "browser flags must be booleans" };
  return { ok: true, value: { name: "Brave", mode: value.mode, pinned: value.pinned, ...(present(value.background) ? { background: value.background as boolean } : {}) } };
}

export function parseBrowserPageRequest(value: unknown): Parsed<BrowserPageRequest> {
  if (!isRecord(value) || typeof value.contextId !== "string" || !CONTEXT_ID.test(value.contextId)) return { ok: false, error: "contextId is required" };
  const request: BrowserPageRequest = { contextId: value.contextId };
  if (present(value.maxChars)) {
    if (!intIn(value.maxChars, 1, BROWSER_PAGE_LIMITS.maxChars)) return { ok: false, error: "maxChars must be 1..24000" };
    request.maxChars = value.maxChars;
  }
  if (present(value.maxControls)) {
    if (!intIn(value.maxControls, 1, BROWSER_PAGE_LIMITS.maxControls)) return { ok: false, error: "maxControls must be 1..300" };
    request.maxControls = value.maxControls;
  }
  return { ok: true, value: request };
}

/** Structural check of a `browser.page` result; Node never shows a digest that fails it to a model. */
export function parseBrowserPageResult(value: unknown): Parsed<BrowserPageResult> {
  if (!isRecord(value)) return { ok: false, error: "page must be an object" };
  const { title, url, text, headings, links, controls, fields, truncated } = value;
  if (!isLabel(title)) return { ok: false, error: "invalid title" };
  if (present(url) && !isPageUrl(url)) return { ok: false, error: "invalid url" };
  if (typeof text !== "string" || text.length > BROWSER_PAGE_LIMITS.maxChars) return { ok: false, error: "invalid text" };
  if (typeof truncated !== "boolean") return { ok: false, error: "truncated must be a boolean" };
  if (!Array.isArray(headings) || !Array.isArray(links) || !Array.isArray(controls) || !Array.isArray(fields)) return { ok: false, error: "lists are required" };
  if (headings.length > BROWSER_PAGE_LIMITS.maxHeadings) return { ok: false, error: "too many headings" };
  if (links.length + controls.length + fields.length > BROWSER_PAGE_LIMITS.maxControls) return { ok: false, error: "too many refs" };
  const refs = new Set<string>();
  const ref = (candidate: unknown): candidate is string => {
    if (typeof candidate !== "string" || !BROWSER_REF_PATTERN.test(candidate) || refs.has(candidate)) return false;
    refs.add(candidate);
    return true;
  };
  const page: BrowserPageResult = { title, text, headings: [], links: [], controls: [], fields: [], truncated, ...(present(url) ? { url: url as string } : {}) };
  for (const h of headings) {
    if (!isRecord(h) || !isLabel(h.label) || (present(h.level) && !intIn(h.level, 1, 6))) return { ok: false, error: "invalid heading" };
    page.headings.push({ label: h.label, ...(present(h.level) ? { level: h.level as number } : {}) });
  }
  for (const l of links) {
    if (!isRecord(l) || !isLabel(l.label) || !ref(l.ref)) return { ok: false, error: "invalid link" };
    page.links.push({ label: l.label, ref: l.ref });
  }
  for (const c of controls) {
    if (!isRecord(c) || !isLabel(c.label) || !oneOf(BROWSER_CONTROL_ROLES, c.role) || !ref(c.ref)
      || !optionalFlag(c.pressed) || !optionalFlag(c.checked) || !optionalFlag(c.disabled)) return { ok: false, error: "invalid control" };
    page.controls.push({
      label: c.label, role: c.role, ref: c.ref,
      ...(present(c.pressed) ? { pressed: c.pressed as boolean } : {}), ...(present(c.checked) ? { checked: c.checked as boolean } : {}),
      ...(present(c.disabled) ? { disabled: c.disabled as boolean } : {}),
    });
  }
  for (const f of fields) {
    if (!isRecord(f) || !isLabel(f.label) || !oneOf(BROWSER_FIELD_ROLES, f.role) || !ref(f.ref)
      || typeof f.secure !== "boolean" || !optionalFlag(f.disabled)) return { ok: false, error: "invalid field" };
    if (present(f.value)) {
      // Credential values never cross the boundary, whatever the input opt-in says.
      if (f.secure || isCredentialLabel(f.label)) return { ok: false, error: "credential field values are never sent" };
      if (typeof f.value !== "string" || f.value.length > BROWSER_PAGE_LIMITS.maxValueChars) return { ok: false, error: "invalid field value" };
    }
    page.fields.push({
      label: f.label, role: f.role, ref: f.ref, secure: f.secure,
      ...(present(f.value) ? { value: f.value as string } : {}), ...(present(f.disabled) ? { disabled: f.disabled as boolean } : {}),
    });
  }
  return { ok: true, value: page };
}

export function parseBrowserAxActRequest(value: unknown): Parsed<BrowserAxActRequest> {
  if (!isRecord(value) || typeof value.contextId !== "string" || !CONTEXT_ID.test(value.contextId)) return { ok: false, error: "contextId is required" };
  if (typeof value.ref !== "string" || !BROWSER_REF_PATTERN.test(value.ref)) return { ok: false, error: "ref must be a host ref" };
  if (!oneOf(BROWSER_AX_ACTIONS, value.action)) return { ok: false, error: "action must be press, setValue, focus or scrollIntoView" };
  const request: BrowserAxActRequest = { contextId: value.contextId, ref: value.ref, action: value.action };
  if (value.action === "setValue") {
    if (typeof value.value !== "string" || value.value.length > BROWSER_PAGE_LIMITS.maxSetValueChars) return { ok: false, error: "setValue needs value (at most 20000 characters)" };
    // A lone surrogate (half an emoji) is not text the host can decode: refuse it here, before anything is sent.
    if (!isWellFormedText(value.value)) return { ok: false, error: "value must be well-formed text" };
    request.value = value.value;
  } else if (present(value.value)) {
    return { ok: false, error: "value is only allowed with setValue" };
  }
  return { ok: true, value: request };
}

export function parseBrowserAxActResult(value: unknown): Parsed<BrowserAxActResult> {
  if (!isRecord(value) || value.performed !== true || !oneOf(BROWSER_AX_ACTIONS, value.action)) return { ok: false, error: "invalid act result" };
  if (typeof value.verification !== "string" || value.verification.length === 0 || value.verification.length > BROWSER_PAGE_LIMITS.maxVerificationChars) {
    return { ok: false, error: "invalid verification" };
  }
  const result: BrowserAxActResult = { performed: true, action: value.action, verification: value.verification };
  if (present(value.page)) {
    const page = parseBrowserPageResult(value.page);
    if (!page.ok) return page;
    result.page = page.value;
  }
  if (present(value.pageError)) {
    if (typeof value.pageError !== "string" || !ERROR_CODE.test(value.pageError)) return { ok: false, error: "invalid pageError" };
    result.pageError = value.pageError;
  }
  return { ok: true, value: result };
}
