import type { HostAction, HostActionType } from "./actions.js";
import { parseHostAction } from "./actions.js";

/**
 * Result cards ("pi-os-ui/1"): a json-render flat spec restricted to a closed,
 * static component catalog (protocol.md "Result cards"). The native host
 * renders it; Node validates it (src/ui) before it ever reaches a host.
 *
 * This module only holds the wire types and dependency-free builders so the
 * instant engine and tools can produce cards without importing the catalog.
 */

export const CARD_FORMAT = "pi-os-ui/1" as const;

export const CARD_COMPONENTS = [
  "Answer",
  "Markdown",
  "ResultCard",
  "KeyValue",
  "Table",
  "ItemList",
  "Item",
  "Notice",
  "Status",
  "Suggestion",
] as const;
export type CardComponent = (typeof CARD_COMPONENTS)[number];

/** json-render ActionBinding shape: the HostAction type plus its fields as params. */
export interface CardBinding {
  action: HostActionType;
  params: Record<string, unknown>;
}

export interface CardElement {
  type: CardComponent;
  props: Record<string, unknown>;
  children?: string[];
  on?: Record<string, CardBinding>;
}

export interface CardSpec {
  format: typeof CARD_FORMAT;
  root: string;
  elements: Record<string, CardElement>;
}

export type Freshness = { label: string; level: "fresh" | "aging" | "stale" | "missing" };

export interface AnswerProps { summary?: string }
export interface MarkdownProps { source: string }
export interface ResultCardProps {
  kind: "math" | "conversion" | "currency" | "time" | "date" | "fact";
  input?: string;
  value: string;
  detail?: string;
  freshness?: Freshness;
}
export interface KeyValueProps { title?: string; items: { key: string; value: string }[] }
export interface TableProps {
  title?: string;
  columns: { key: string; label: string; align?: "left" | "right" | "center" }[];
  rows: Record<string, string | number | null>[];
}
export interface ItemListProps { title?: string; total?: number }
export interface ItemProps {
  title: string;
  subtitle?: string;
  icon?: { kind: "file" | "app" | "url"; uti?: string; bundleId?: string };
  detail?: string;
}
export interface NoticeProps { tone: "info" | "warning" | "error" | "success"; text: string }
export interface StatusProps { state: "running" | "done" | "warning" | "error"; text: string; progress?: number | null }
export interface SuggestionProps { prompt: string }

/** Events each component may bind (anything else is rejected by validation). */
export const CARD_EVENTS: Readonly<Record<CardComponent, readonly string[]>> = {
  Answer: [],
  Markdown: [],
  ResultCard: ["copy"],
  KeyValue: [],
  Table: [],
  ItemList: [],
  Item: ["primary", "secondary", "tertiary"],
  Notice: [],
  Status: [],
  Suggestion: ["press"],
};

export function bind(action: HostAction): CardBinding {
  const { type, ...params } = action;
  return { action: type, params };
}

export function bindingToHostAction(binding: CardBinding): HostAction | null {
  return parseHostAction({ ...binding.params, type: binding.action });
}

/** Tree form used by builders; flattened by buildCard. */
export interface CardNode {
  type: CardComponent;
  props: Record<string, unknown>;
  on?: Record<string, CardBinding>;
  children?: CardNode[];
}

function stripUndefined<T extends object>(props: T): Record<string, unknown> {
  return Object.fromEntries(Object.entries(props).filter(([, value]) => value !== undefined));
}

function bindings(events: Record<string, HostAction | undefined> | undefined): Record<string, CardBinding> | undefined {
  if (!events) return undefined;
  const entries = Object.entries(events).filter((entry): entry is [string, HostAction] => entry[1] !== undefined);
  return entries.length ? Object.fromEntries(entries.map(([event, action]) => [event, bind(action)])) : undefined;
}

export const ui = {
  answer: (props: AnswerProps, children: CardNode[]): CardNode => ({ type: "Answer", props: stripUndefined(props), children }),
  markdown: (source: string): CardNode => ({ type: "Markdown", props: { source } }),
  result: (props: ResultCardProps, copy?: HostAction): CardNode => {
    const on = bindings({ copy });
    return { type: "ResultCard", props: stripUndefined(props), ...(on ? { on } : {}) };
  },
  keyValue: (props: KeyValueProps): CardNode => ({ type: "KeyValue", props: stripUndefined(props) }),
  table: (props: TableProps): CardNode => ({ type: "Table", props: stripUndefined(props) }),
  itemList: (props: ItemListProps, items: CardNode[]): CardNode => ({ type: "ItemList", props: stripUndefined(props), children: items }),
  item: (props: ItemProps, events?: { primary?: HostAction; secondary?: HostAction; tertiary?: HostAction }): CardNode => {
    const on = bindings(events);
    return { type: "Item", props: stripUndefined(props), ...(on ? { on } : {}) };
  },
  notice: (tone: NoticeProps["tone"], text: string): CardNode => ({ type: "Notice", props: { tone, text } }),
  status: (props: StatusProps): CardNode => ({ type: "Status", props: stripUndefined(props) }),
  suggestion: (prompt: string): CardNode => ({
    type: "Suggestion",
    props: { prompt },
    on: { press: bind({ type: "askAgent", prompt }) },
  }),
};

/**
 * Flattens a builder tree into the wire spec. Keys are deterministic
 * ("root", then "n1", "n2", … in pre-order) so fixtures and tests are stable.
 */
export function buildCard(root: CardNode): CardSpec {
  const elements: Record<string, CardElement> = {};
  let next = 1;
  const visit = (node: CardNode, key: string): void => {
    const childKeys = (node.children ?? []).map(() => `n${next++}`);
    elements[key] = {
      type: node.type,
      props: node.props,
      ...(childKeys.length ? { children: childKeys } : {}),
      ...(node.on ? { on: node.on } : {}),
    };
    (node.children ?? []).forEach((child, index) => visit(child, childKeys[index]!));
  };
  visit(root, "root");
  return { format: CARD_FORMAT, root: "root", elements };
}
