import { z } from "zod";
import { MODEL_CARD_ACTION_TYPES, parseHostAction, type HostAction, type HostActionType } from "../contracts/actions.js";
import { bind, CARD_EVENTS, CARD_FORMAT, type CardBinding, type CardComponent, type CardElement, type CardSpec } from "../contracts/cards.js";
import {
  CARD_ACTION_PARAMS, CARD_KEY_PATTERN, CARD_MAX_BYTES, CARD_MAX_ELEMENTS, CARD_PROPS, cardCatalog, isCardComponent, isCatalogAction,
} from "./catalog.js";
import type { FileTokenSource } from "./ledger.js";

/**
 * Card validation (DESIGN §3.2). Every card leaves Node through here.
 *
 * strict  — any problem rejects the card (model tool calls, fixtures, instant cards).
 * lenient — invalid elements, references and bindings are dropped instead
 *           (streaming partial cards); only an unusable root or format fails.
 *
 * json-render core's catalog.validate() checks structure and the component and
 * action enums, but not per-component props (F33) and nothing about the tree,
 * so this module re-checks every element itself and keeps core as a final gate.
 * Issue messages never echo card text; they name keys, fields and components.
 */

export type CardIssueCode =
  | "invalid_shape"
  | "invalid_format"
  | "unsupported_field"
  | "dynamic_expression"
  | "too_many_elements"
  | "too_large"
  | "invalid_key"
  | "missing_root"
  | "invalid_root"
  | "unknown_component"
  | "invalid_props"
  | "missing_child"
  | "cycle"
  | "shared_child"
  | "invalid_child"
  | "orphan"
  | "unknown_event"
  | "unknown_action"
  | "invalid_binding"
  | "action_not_allowed"
  | "unknown_file_token"
  /** Block mapping (blocks.ts): a files block named a ref the thread's ledger does not hold. */
  | "unknown_file_ref";

export interface CardIssue {
  code: CardIssueCode;
  /** Dotted location, e.g. "elements.n2.on.primary". */
  path: string;
  message: string;
}

export type CardValidationMode = "strict" | "lenient";

export interface ValidateCardOptions {
  mode: CardValidationMode;
  /** Actions bindings may use. Default: MODEL_CARD_ACTION_TYPES (no typeIntoPinned/system buttons). */
  allowedActions?: readonly HostActionType[];
  /** When given, every openFile/revealFile/copyPath token must be live in this thread's ledger. */
  ledger?: FileTokenSource;
}

export type CardValidation =
  /** `dropped` lists what lenient mode removed; always empty in strict mode. */
  | { ok: true; spec: CardSpec; dropped: CardIssue[] }
  | { ok: false; issues: CardIssue[] };

const SPEC_FIELDS = new Set(["format", "root", "elements"]);
const ELEMENT_FIELDS = new Set(["type", "props", "children", "on"]);
const DYNAMIC_FIELDS = new Set(["visible", "repeat", "watch", "state", "slots"]);
/** Events whose action is fixed by the component's meaning. */
const EVENT_ACTIONS: Readonly<Record<string, readonly HostActionType[]>> = { copy: ["copyText"], press: ["askAgent"] };
/** Containers and what they may hold; every other component is a leaf. Answer is only ever the root. */
const CHILD_RULES: Partial<Record<CardComponent, (child: CardComponent) => boolean>> = {
  Answer: child => child !== "Answer",
  ItemList: child => child === "Item",
};

function declaredFields(schema: unknown, found: Set<string>): Set<string> {
  if (Array.isArray(schema)) schema.forEach(item => declaredFields(item, found));
  else if (isRecord(schema)) {
    for (const [key, value] of Object.entries(schema)) {
      if (key === "properties" && isRecord(value)) Object.keys(value).forEach(name => found.add(name));
      declaredFields(value, found);
    }
  }
  return found;
}

/**
 * Object keys an issue path may name: the catalog's own field, element and
 * event names. Anything else (a table row key, an unknown prop) may be card
 * content and is shown as "…".
 */
const PATH_NAMES: ReadonlySet<string> = new Set([
  ...[...Object.values(CARD_PROPS), ...Object.values(CARD_ACTION_PARAMS)]
    .flatMap(schema => [...declaredFields(z.toJSONSchema(schema), new Set())]),
  ...ELEMENT_FIELDS, "action", "params", ...Object.values(CARD_EVENTS).flat(),
]);

function segment(part: PropertyKey): string {
  return typeof part === "number" ? String(part) : typeof part === "string" && PATH_NAMES.has(part) ? part : "…";
}

interface Checked { element: CardElement; children: string[] }

interface Context {
  strict: boolean;
  allowed: ReadonlySet<HostActionType>;
  ledger?: FileTokenSource;
  report(code: CardIssueCode, path: string, message: string): void;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Names from the input appear in messages only when they look like identifiers. */
function label(value: unknown): string {
  return typeof value === "string" && /^[A-Za-z][A-Za-z0-9_.-]{0,39}$/.test(value) ? `"${value}"` : "(invalid name)";
}

function pathKey(key: string): string {
  return CARD_KEY_PATTERN.test(key) ? key : "(invalid key)";
}

function zodSummary(error: z.ZodError): string {
  return error.issues.slice(0, 3).map((issue) => {
    // Zod quotes unrecognized keys verbatim; every other default message names only types, limits and allowed values.
    const message = issue.code === "unrecognized_keys" ? "unknown fields are not allowed" : issue.message;
    return `${issue.path.length ? issue.path.map(segment).join(".") : "value"}: ${message}`;
  }).join("; ");
}

/** First `$`-prefixed key anywhere below `value` (iterative: inputs may be deeply nested). */
function findDollarKey(value: unknown): string | undefined {
  const stack: { value: unknown; path: string }[] = [{ value, path: "" }];
  const seen = new WeakSet<object>();
  while (stack.length) {
    const next = stack.pop()!;
    if (typeof next.value === "object" && next.value !== null) {
      if (seen.has(next.value)) continue;
      seen.add(next.value);
    }
    if (Array.isArray(next.value)) {
      next.value.forEach((item, index) => stack.push({ value: item, path: `${next.path}.${index}` }));
    } else if (isRecord(next.value)) {
      for (const [key, item] of Object.entries(next.value)) {
        if (key.startsWith("$")) return `${next.path}.${/^\$[A-Za-z]{1,24}$/.test(key) ? key : "$…"}`;
        stack.push({ value: item, path: `${next.path}.${segment(key)}` });
      }
    }
  }
  return undefined;
}

function jsonBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value), "utf8");
}

export function validateCard(input: unknown, options: ValidateCardOptions): CardValidation {
  const issues: CardIssue[] = [];
  const context: Context = {
    strict: options.mode === "strict",
    allowed: new Set(options.allowedActions ?? MODEL_CARD_ACTION_TYPES),
    ...(options.ledger ? { ledger: options.ledger } : {}),
    report: (code, path, message) => { issues.push({ code, path, message }); },
  };
  const fail = (code: CardIssueCode, path: string, message: string): CardValidation => {
    issues.push({ code, path, message });
    return { ok: false, issues };
  };

  if (!isRecord(input)) return fail("invalid_shape", "", "a card must be a JSON object");
  if (input.format !== CARD_FORMAT) return fail("invalid_format", "format", `format must be "${CARD_FORMAT}"`);
  let bytes: number;
  try { bytes = jsonBytes(input); } catch { return fail("invalid_shape", "", "a card must be serializable JSON"); }
  // Lenient mode trims the rebuilt spec instead (below).
  if (context.strict && bytes > CARD_MAX_BYTES) context.report("too_large", "", `card JSON exceeds ${CARD_MAX_BYTES} bytes`);
  for (const field of Object.keys(input)) {
    if (SPEC_FIELDS.has(field)) continue;
    if (DYNAMIC_FIELDS.has(field) || field.startsWith("$")) context.report("dynamic_expression", label(field), "state and dynamic expressions are not supported");
    else context.report("unsupported_field", label(field), "unsupported top-level field");
  }
  const root = input.root;
  if (typeof root !== "string" || !CARD_KEY_PATTERN.test(root)) return fail("missing_root", "root", "root must name an element");
  const raw = input.elements;
  if (!isRecord(raw)) return fail("invalid_shape", "elements", "elements must be an object keyed by element key");
  const keys = Object.keys(raw);
  if (context.strict && keys.length > CARD_MAX_ELEMENTS) {
    context.report("too_many_elements", "elements", `a card holds at most ${CARD_MAX_ELEMENTS} elements`);
  }

  const valid = new Map<string, Checked>();
  for (const key of keys) {
    const checked = checkElement(key, raw[key], context);
    if (checked) valid.set(key, checked);
  }

  if (!Object.hasOwn(raw, root)) return fail("missing_root", "root", "the root element does not exist");
  const rootElement = valid.get(root);
  if (!rootElement) return fail("invalid_root", `elements.${root}`, "the root element is invalid");
  if (rootElement.element.type !== "Answer") return fail("invalid_root", `elements.${root}.type`, "the root element must be an Answer");

  // Pre-order walk from the root: every reference must exist, appear once, and fit its container.
  const order: string[] = [];
  const kept = new Map<string, string[]>();
  const rejected = new Set<string>();
  const visited = new Set<string>();
  const visit = (key: string, ancestors: ReadonlySet<string>): void => {
    visited.add(key);
    order.push(key);
    const node = valid.get(key)!;
    const rule = CHILD_RULES[node.element.type];
    const lineage = new Set(ancestors).add(key);
    const children: string[] = [];
    kept.set(key, children);
    for (const child of node.children) {
      const at = `elements.${key}.children`;
      if (!Object.hasOwn(raw, child)) { context.report("missing_child", at, `child ${label(child)} does not exist`); continue; }
      if (lineage.has(child)) { rejected.add(child); context.report("cycle", at, `child ${label(child)} is an ancestor`); continue; }
      if (visited.has(child)) { rejected.add(child); context.report("shared_child", at, `child ${label(child)} is referenced more than once`); continue; }
      const target = valid.get(child);
      if (!target) continue; // Already reported (strict) or dropped (lenient) on its own.
      if (!rule?.(target.element.type)) {
        rejected.add(child);
        context.report("invalid_child", at, `${node.element.type} cannot contain ${target.element.type}`);
        continue;
      }
      children.push(child);
      visit(child, lineage);
    }
  };
  visit(root, new Set());
  for (const key of valid.keys()) {
    if (!visited.has(key) && !rejected.has(key)) context.report("orphan", `elements.${pathKey(key)}`, "element is not reachable from the root");
  }

  if (context.strict) {
    if (!issues.length) {
      // Defense in depth: json-render core must agree with the per-element checks.
      const core = cardCatalog.validate(input);
      if (!core.success) for (const issue of core.error?.issues ?? []) context.report("invalid_shape", issue.path.map(String).join("."), issue.message);
    }
    return issues.length ? { ok: false, issues } : { ok: true, spec: buildSpec(root, order, valid, kept), dropped: [] };
  }

  let keep = order;
  if (keep.length > CARD_MAX_ELEMENTS) {
    context.report("too_many_elements", "elements", `trimmed to ${CARD_MAX_ELEMENTS} elements`);
    keep = keep.slice(0, CARD_MAX_ELEMENTS);
  }
  let spec = buildSpec(root, keep, valid, kept);
  let size = jsonBytes(spec);
  if (size > CARD_MAX_BYTES) {
    // Dropping from the end of the pre-order never orphans anything still kept.
    context.report("too_large", "", `trimmed to ${CARD_MAX_BYTES} bytes`);
    while (size > CARD_MAX_BYTES && keep.length > 1) {
      const last = keep[keep.length - 1]!;
      // Estimate (entry plus its child reference), then measure exactly once under budget.
      size -= jsonBytes({ [last]: spec.elements[last] }) + jsonBytes(last);
      keep = keep.slice(0, -1);
      if (size <= CARD_MAX_BYTES) {
        spec = buildSpec(root, keep, valid, kept);
        size = jsonBytes(spec);
      }
    }
  }
  return { ok: true, spec, dropped: issues };
}

function buildSpec(root: string, order: readonly string[], valid: ReadonlyMap<string, Checked>, kept: ReadonlyMap<string, string[]>): CardSpec {
  const keep = new Set(order);
  // Object.fromEntries defines own properties, so odd keys cannot touch prototypes.
  const elements = Object.fromEntries(order.map((key) => {
    const { element } = valid.get(key)!;
    const children = (kept.get(key) ?? []).filter(child => keep.has(child));
    return [key, { type: element.type, props: element.props, ...(children.length ? { children } : {}), ...(element.on ? { on: element.on } : {}) }];
  }));
  return { format: CARD_FORMAT, root, elements };
}

function checkElement(key: string, raw: unknown, context: Context): Checked | null {
  const path = `elements.${pathKey(key)}`;
  if (!CARD_KEY_PATTERN.test(key)) {
    context.report("invalid_key", path, "element keys must be 1–64 ASCII letters, digits, '.', '_' or '-'");
    return null;
  }
  if (!isRecord(raw)) { context.report("invalid_shape", path, "an element must be an object"); return null; }
  let usable = true;
  for (const field of Object.keys(raw)) {
    if (ELEMENT_FIELDS.has(field)) continue;
    usable = false;
    if (DYNAMIC_FIELDS.has(field) || field.startsWith("$")) context.report("dynamic_expression", `${path}.${label(field)}`, "visible/repeat/watch/state/slots are not supported");
    else context.report("unsupported_field", `${path}.${label(field)}`, "unsupported element field");
  }
  const dollar = findDollarKey(raw);
  if (dollar !== undefined) { usable = false; context.report("dynamic_expression", `${path}${dollar}`, "$-expressions are not supported"); }
  if (!isCardComponent(raw.type)) {
    context.report("unknown_component", `${path}.type`, `unknown component ${label(raw.type)}`);
    return null;
  }
  const type = raw.type;
  const props = CARD_PROPS[type].safeParse(raw.props);
  if (!props.success) { usable = false; context.report("invalid_props", `${path}.props`, `${type}: ${zodSummary(props.error)}`); }
  let children: string[] = [];
  if (raw.children !== undefined) {
    if (Array.isArray(raw.children) && raw.children.every(child => typeof child === "string")) children = raw.children as string[];
    else { usable = false; context.report("invalid_shape", `${path}.children`, "children must be an array of element keys"); }
  }
  if (!usable || !props.success) return null;
  const on = checkBindings(type, raw, path, context);
  return { element: { type, props: props.data as Record<string, unknown>, ...(on ? { on } : {}) }, children };
}

function checkBindings(type: CardComponent, raw: Record<string, unknown>, path: string, context: Context): Record<string, CardBinding> | undefined {
  if (raw.on === undefined) return undefined;
  if (!isRecord(raw.on)) { context.report("invalid_binding", `${path}.on`, "on must map event names to bindings"); return undefined; }
  const out: Record<string, CardBinding> = {};
  for (const [event, binding] of Object.entries(raw.on)) {
    const at = `${path}.on.${label(event) === "(invalid name)" ? "…" : event}`;
    if (!CARD_EVENTS[type].includes(event)) { context.report("unknown_event", at, `${type} has no ${label(event)} event`); continue; }
    const action = checkBinding(type, event, binding, raw.props, at, context);
    if (action) out[event] = bind(action);
  }
  return Object.keys(out).length ? out : undefined;
}

function checkBinding(type: CardComponent, event: string, binding: unknown, props: unknown, at: string, context: Context): HostAction | null {
  if (!isRecord(binding) || !isRecord(binding.params) || Object.keys(binding).some(key => key !== "action" && key !== "params")) {
    context.report("invalid_binding", at, "a binding must be exactly {action, params}");
    return null;
  }
  if (!isCatalogAction(binding.action)) { context.report("unknown_action", at, `unknown action ${label(binding.action)}`); return null; }
  const action = binding.action;
  const params = CARD_ACTION_PARAMS[action].safeParse(binding.params);
  if (!params.success) { context.report("invalid_binding", at, `${action} params: ${zodSummary(params.error)}`); return null; }
  const parsed = parseHostAction({ ...binding.params, type: action });
  if (!parsed) { context.report("invalid_binding", at, `${action} params are not a valid host action (scheme, token, bundle id or length)`); return null; }
  if (!context.allowed.has(action)) { context.report("action_not_allowed", at, `${action} is not allowed on this card`); return null; }
  const only = EVENT_ACTIONS[event];
  if (only && !only.includes(action)) { context.report("invalid_binding", at, `${event} must bind ${only.join(" or ")}`); return null; }
  if (type === "Suggestion" && (parsed.type !== "askAgent" || !isRecord(props) || parsed.prompt !== props.prompt)) {
    context.report("invalid_binding", at, "a Suggestion must ask exactly its visible prompt");
    return null;
  }
  if ((parsed.type === "openFile" || parsed.type === "revealFile" || parsed.type === "copyPath")
      && context.ledger && !context.ledger.hasToken(parsed.token)) {
    context.report("unknown_file_token", at, "file actions may only use tokens from a host search in this thread");
    return null;
  }
  return parsed;
}
