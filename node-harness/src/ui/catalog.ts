import { defineCatalog, defineSchema, type PromptContext } from "@json-render/core";
import { z } from "zod";
import { HOST_ACTION_TYPES, SYSTEM_OPS, type HostActionType } from "../contracts/actions.js";
import { CARD_COMPONENTS, CARD_EVENTS, CARD_FORMAT, type CardComponent } from "../contracts/cards.js";

/**
 * The "pi-os-ui/1" result-card catalog (protocol.md "Result cards", DESIGN §3.2).
 *
 * json-render core is the single source of truth for the component vocabulary
 * and its Zod props; the native hosts only render validated, static specs.
 * Version 1 is deliberately static: no `$`-expressions, visible, repeat, watch
 * or state, and bindings are plain HostAction descriptors. There is no delete,
 * trash, move, rename or write action (AGENTS.md computer-use policy).
 *
 * Never ship json-render's default catalog.prompt(): it asks for "realistic
 * sample data", which would make the model invent files and numbers. The
 * schema's promptTemplate below replaces it with a compact, factual listing.
 */

export const CARD_MAX_ELEMENTS = 150;
/** Serialized UTF-8 JSON limit for one card. */
export const CARD_MAX_BYTES = 64 * 1024;
/** Element keys: short ASCII identifiers ("root", "n3", "b2-4"). */
export const CARD_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;

export const RESULT_KINDS = ["math", "conversion", "currency", "time", "date", "fact"] as const;
export const NOTICE_TONES = ["info", "warning", "error", "success"] as const;
export const STATUS_STATES = ["running", "done", "warning", "error"] as const;
export const ICON_KINDS = ["file", "app", "url"] as const;
export const COLUMN_ALIGNS = ["left", "right", "center"] as const;

const required = (max: number) => z.string().min(1).max(max);
const optional = (max: number) => z.string().max(max).optional();
const cell = z.union([z.string().max(500), z.number(), z.null()]);

const tableProps = z.strictObject({
  title: optional(200),
  columns: z.array(z.strictObject({
    // Zod skips "__proto__" record keys, so such a column's cells would silently vanish.
    key: z.string().regex(/^[A-Za-z0-9_-]{1,40}$/).refine(key => key !== "__proto__", "reserved column key"),
    label: z.string().max(200),
    align: z.enum(COLUMN_ALIGNS).optional(),
  })).min(1).max(6),
  rows: z.array(z.record(z.string(), cell)).max(50),
}).superRefine((table, ctx) => {
  const keys = new Set<string>();
  table.columns.forEach((column, index) => {
    if (keys.has(column.key)) ctx.addIssue({ code: "custom", path: ["columns", index, "key"], message: "duplicate column key" });
    keys.add(column.key);
  });
  table.rows.forEach((row, index) => {
    if (Object.keys(row).some(key => !keys.has(key))) {
      ctx.addIssue({ code: "custom", path: ["rows", index], message: "row has a cell for an undeclared column" });
    }
  });
});

/** Per-component props. json-render's propsOf() is lenient with more than one component (F33), so validate.ts applies these per element. */
export const CARD_PROPS = {
  Answer: z.strictObject({ summary: optional(200) }),
  Markdown: z.strictObject({ source: required(4_000) }),
  ResultCard: z.strictObject({
    kind: z.enum(RESULT_KINDS),
    input: optional(200),
    value: required(200),
    detail: optional(200),
    freshness: z.strictObject({ label: required(120), level: z.enum(["fresh", "aging", "stale", "missing"]) }).optional(),
  }),
  KeyValue: z.strictObject({
    title: optional(200),
    items: z.array(z.strictObject({ key: required(200), value: z.string().max(500) })).min(1).max(24),
  }),
  Table: tableProps,
  ItemList: z.strictObject({ title: optional(200), total: z.number().int().nonnegative().optional() }),
  Item: z.strictObject({
    title: required(200),
    subtitle: optional(1_024),
    icon: z.strictObject({ kind: z.enum(ICON_KINDS), uti: optional(255), bundleId: optional(255) }).optional(),
    detail: optional(40),
  }),
  Notice: z.strictObject({ tone: z.enum(NOTICE_TONES), text: required(500) }),
  Status: z.strictObject({ state: z.enum(STATUS_STATES), text: required(200), progress: z.number().min(0).max(1).nullable().optional() }),
  Suggestion: z.strictObject({ prompt: required(160) }),
} satisfies Record<CardComponent, z.ZodType>;

const DESCRIPTIONS: Record<CardComponent, string> = {
  Answer: "Root vertical stack; its children are the answer blocks. summary: one short sentence.",
  Markdown: "Prose in the host's inline Markdown subset.",
  ResultCard: "One computed value (calculator style); copy copies the value.",
  KeyValue: "Labelled facts.",
  Table: "Small table (1–6 columns, at most 50 rows).",
  ItemList: "Container of Item children.",
  Item: "One file, app or link row with up to three actions.",
  Notice: "Short info/warning/error/success message.",
  Status: "Step or progress line.",
  Suggestion: "Follow-up chip; pressing it sends exactly the visible prompt to the agent.",
};

/** Binding params per HostAction type. Field shapes only; parseHostAction stays the semantic authority. */
export const CARD_ACTION_PARAMS = {
  copyText: z.strictObject({ text: z.string() }),
  typeIntoPinned: z.strictObject({ text: z.string() }),
  openURL: z.strictObject({ url: z.string() }),
  openApp: z.strictObject({ bundleId: z.string() }),
  openFile: z.strictObject({ token: z.string() }),
  revealFile: z.strictObject({ token: z.string() }),
  copyPath: z.strictObject({ token: z.string() }),
  system: z.strictObject({ op: z.enum(SYSTEM_OPS), value: z.union([z.number(), z.boolean(), z.enum(["dark", "light"])]).optional() }),
  askAgent: z.strictObject({ prompt: z.string() }),
} satisfies Record<HostActionType, z.ZodType>;

const ACTION_DESCRIPTIONS: Record<HostActionType, string> = {
  copyText: "Copy text to the clipboard.",
  typeIntoPinned: "Type text into the pinned app (instant lane only).",
  openURL: "Open an http(s) URL in the default browser.",
  openApp: "Open an app from the host's app index.",
  openFile: "Open a file found by a host search (host token; executables are only revealed).",
  revealFile: "Reveal a file found by a host search in Finder.",
  copyPath: "Copy the path of a file found by a host search.",
  system: "Volume / display system operation (instant lane only).",
  askAgent: "Send a follow-up prompt to the agent.",
};

/** Compact catalog listing (one line per component). Replaces json-render's ~18 K-char default prompt. */
function compactPrompt(context: PromptContext): string {
  const { components } = context.catalog as { components: Record<string, { props: z.ZodType; events?: string[]; description?: string }> };
  const lines = Object.entries(components).map(([name, def]) => {
    const events = def.events?.length ? ` events: ${def.events.join(", ")}.` : "";
    return `- ${name} ${context.formatZodType(def.props)}: ${def.description ?? ""}${events}`;
  });
  return [
    `pi-os result cards (${CARD_FORMAT}). Static flat spec {format, root, elements}; root is an Answer.`,
    "Show only data you actually have; never invent values, rows, files, paths or links.",
    ...lines,
  ].join("\n");
}

const cardSchema = defineSchema((s) => ({
  spec: s.object({
    format: s.string(),
    root: s.string(),
    elements: s.record(s.object({
      type: s.ref("catalog.components"),
      props: s.propsOf("catalog.components"),
      children: { ...s.array(s.string()), ...s.optional() },
      // Declared so core's validate() neither rejects nor strips bindings.
      on: { ...s.record(s.object({ action: s.ref("catalog.actions"), params: s.record(s.any()) })), ...s.optional() },
    })),
  }),
  catalog: s.object({
    components: s.map({ props: s.zod(), events: s.array(s.string()), description: s.string() }),
    actions: s.map({ params: s.zod(), description: s.string() }),
  }),
}), { promptTemplate: compactPrompt });

function recordOf<K extends string, V>(keys: readonly K[], make: (key: K) => V): Record<K, V> {
  return Object.fromEntries(keys.map(key => [key, make(key)])) as Record<K, V>;
}

export const cardCatalog = defineCatalog(cardSchema, {
  components: recordOf(CARD_COMPONENTS, (name): { props: z.ZodType; events: string[]; description: string } => ({
    props: CARD_PROPS[name],
    events: [...CARD_EVENTS[name]],
    description: DESCRIPTIONS[name],
  })),
  actions: recordOf(HOST_ACTION_TYPES, (type): { params: z.ZodType; description: string } => ({
    params: CARD_ACTION_PARAMS[type],
    description: ACTION_DESCRIPTIONS[type],
  })),
});

export function isCardComponent(value: unknown): value is CardComponent {
  return typeof value === "string" && Object.hasOwn(CARD_PROPS, value);
}

export function isCatalogAction(value: unknown): value is HostActionType {
  return typeof value === "string" && Object.hasOwn(CARD_ACTION_PARAMS, value);
}
