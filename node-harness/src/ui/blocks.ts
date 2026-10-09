import { StringEnum } from "@earendil-works/pi-ai";
import { Type, type Static, type TProperties } from "typebox";
import { isHttpUrl, MODEL_CARD_ACTION_TYPES, type HostAction } from "../contracts/actions.js";
import { bind, CARD_FORMAT, type CardElement, type CardSpec } from "../contracts/cards.js";
import { NOTICE_TONES, RESULT_KINDS, STATUS_STATES } from "./catalog.js";
import type { FileRef } from "./ledger.js";
import { validateCard, type CardIssue, type CardValidation } from "./validate.js";

/**
 * Model-facing "blocks" for the show_result tool, mapped onto pi-os-ui/1 cards
 * (jsonrender.md §11.3, adapted to DESIGN §3.2).
 *
 * The model never writes element keys, children, bindings, tokens or paths:
 * it lists flat blocks, and Node builds the tree, fills file rows from the
 * thread's ledger and binds every button. Limits live in the Zod catalog and
 * in descriptions rather than in JSON-schema keywords, because some providers
 * reject maxLength/maxItems/pattern; the validator reports violations back to
 * the model as a tool error instead.
 *
 * Each block is its own closed object keyed by `type` (a discriminated union, r2/DESIGN2 §5.6), so
 * a block carries only its own fields. The earlier single flat block made strict constrained
 * sampling emit every other type's 14 fields as nulls (about 70 output tokens per block, +1.3 s on
 * a one-line card). pi's strict converter does not take object unions, so with `strict: "prefer"`
 * the tool goes out without provider-side strict sampling: nothing is padded, pi checks the
 * arguments against this schema, and Node's validator stays the authority.
 */

export const SHOW_RESULT_BLOCK_TYPES = ["markdown", "result", "keyValue", "table", "files", "links", "status", "notice", "suggestions"] as const;
export type ShowResultBlockType = (typeof SHOW_RESULT_BLOCK_TYPES)[number];
export const SHOW_RESULT_MAX_BLOCKS = 12;
export const SHOW_RESULT_MAX_SUGGESTIONS = 4;
export const SHOW_RESULT_MAX_LINKS = 20;

const text = (description: string) => Type.String({ description });
const optionalText = (description: string) => Type.Optional(text(description));
const title = optionalText("Optional heading (≤200 chars).");
/** One block variant: its `type` (a one-value enum, not `const`, which some providers reject) plus only its own fields. */
const block = <T extends ShowResultBlockType, P extends TProperties>(type: T, description: string, properties: P) =>
  Type.Object({ type: StringEnum([type] as const), ...properties }, { additionalProperties: false, description });

export const showResultBlockSchema = Type.Union([
  block("markdown", "Prose that belongs on the card next to structured blocks.", { text: text("Inline-Markdown prose (≤4000 chars).") }),
  block("result", "A computed value.", {
    value: text("The value itself, e.g. \"51\" (≤200 chars)."),
    input: optionalText("What was computed, e.g. \"15% of 340\" (≤200 chars)."),
    detail: optionalText("One short supporting line (≤200 chars)."),
    kind: Type.Optional(StringEnum(RESULT_KINDS, { description: "Kind of value (default fact)." })),
  }),
  block("keyValue", "Labelled facts.", {
    items: Type.Array(Type.Object({ key: Type.String(), value: Type.String() }, { additionalProperties: false }),
      { description: "1–24 facts (key ≤200, value ≤500 chars)." }),
    title,
  }),
  block("table", "A small table.", {
    columns: Type.Array(Type.String(), { description: "1–6 column labels." }),
    rows: Type.Array(Type.Array(Type.String()), { description: "Up to 50 rows, one cell string (≤500 chars) per column." }),
    title,
  }),
  block("files", "Files found by pi-os file tools.", {
    refs: Type.Array(Type.String(), { description: "Refs exactly as returned by pi-os file tools (f1, f2, …), at most 50. Never paths." }),
    title,
  }),
  block("links", "Web links.", {
    links: Type.Array(Type.Object({ title: Type.String(), url: Type.String() }, { additionalProperties: false }),
      { description: "Up to 20 http(s) links taken from the conversation or tool results." }),
    title,
  }),
  block("status", "A status line.", {
    text: text("≤200 chars."),
    state: Type.Optional(StringEnum(STATUS_STATES, { description: "Default done." })),
  }),
  block("notice", "A short notice.", {
    text: text("≤500 chars."),
    tone: Type.Optional(StringEnum(NOTICE_TONES, { description: "Default info." })),
  }),
  block("suggestions", "Follow-up prompts the user can tap.", {
    prompts: Type.Array(Type.String(), { description: "Up to 4 short prompts (≤160 chars each)." }),
  }),
], { description: "One block; its type decides its fields." });

export const showResultParamsSchema = Type.Object({
  summary: optionalText("One short sentence summarizing the answer (≤200 chars)."),
  blocks: Type.Array(showResultBlockSchema, { minItems: 1, description: "1–12 blocks, shown top to bottom." }),
}, { additionalProperties: false });

/**
 * Before pi checks the arguments: a `null` member is an absent one (models trained on strict
 * sampling still pad optional fields with nulls; the union schema would refuse them). Everything else
 * is passed through unchanged for the schema and the validator to judge.
 */
export function withoutNullMembers(args: unknown): ShowResultParams {
  if (!isRecord(args)) return args as ShowResultParams;
  const strip = (value: Record<string, unknown>) => Object.fromEntries(Object.entries(value).filter(([, member]) => member !== null));
  const params = strip(args);
  if (Array.isArray(params.blocks)) params.blocks = params.blocks.map(entry => (isRecord(entry) ? strip(entry) : entry));
  return params as ShowResultParams;
}

export type ShowResultBlock = Static<typeof showResultBlockSchema>;
export type ShowResultParams = Static<typeof showResultParamsSchema>;

/** What block mapping needs from the thread's FileLedger. */
export interface FileRefSource {
  resolve(ref: string): FileRef | undefined;
  hasToken(token: string): boolean;
}

export interface BlocksOptions {
  /** Item detail for file rows (clipped to 40 chars). Default: "Mar 14" / "Mar 14, 2025" (en-US, local time). */
  formatDate?: (ms: number) => string;
}

export function defaultFormatDate(ms: number, now = Date.now()): string {
  const date = new Date(ms);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) }).format(date);
}

/**
 * Complete tool arguments → validated card. Strict: unknown or expired file
 * refs, missing fields and every catalog violation are returned as issues
 * (addressed as blocks[i] so the model can correct its call).
 */
export function blocksToCard(params: unknown, ledger: FileRefSource, options: BlocksOptions = {}): CardValidation {
  const built = buildCard(params, ledger, false, options);
  const checked = validateCard(built.spec, { mode: "strict", allowedActions: MODEL_CARD_ACTION_TYPES, ledger });
  const issues = [...built.issues, ...(checked.ok ? [] : checked.issues.map(toBlockIssue))];
  return issues.length || !checked.ok ? { ok: false, issues } : checked;
}

/**
 * Streaming tool arguments (pi-ai's parseStreamingJson output, possibly cut
 * mid-string) → a renderable partial card, or null when nothing is ready.
 * The block still being written only shows what cannot change any more:
 * markdown prose as it streams, and every list entry except the last.
 * Unknown refs and invalid parts are dropped. Element keys are stable across
 * revisions ("b{i}", "b{i}-{j}"); a table's numeric right-alignment may
 * settle once rows arrive. The summary is left to the final card.
 */
export function partialBlocksToCard(partialArgs: unknown, ledger: FileRefSource, options: BlocksOptions = {}): CardSpec | null {
  const built = buildCard(partialArgs, ledger, true, options);
  const checked = validateCard(built.spec, { mode: "lenient", allowedActions: MODEL_CARD_ACTION_TYPES, ledger });
  if (!checked.ok || !checked.spec.elements[checked.spec.root]?.children?.length) return null;
  return checked.spec;
}

/** One file row (also usable by tools that list ledger files directly). */
export function fileItemElement(file: FileRef, options: BlocksOptions = {}): CardElement {
  const format = options.formatDate ?? ((ms: number) => defaultFormatDate(ms));
  const uti = file.contentType ?? (file.isDirectory ? "public.folder" : undefined);
  const detail = file.modifiedMs !== undefined ? clipEnd(format(file.modifiedMs), 40) : "";
  return {
    type: "Item",
    props: {
      title: clipMiddle(file.name, 200),
      ...(file.displayDir ? { subtitle: clipStart(file.displayDir, 1_024) } : {}),
      icon: { kind: "file", ...(uti ? { uti: clipEnd(uti, 255) } : {}) },
      ...(detail ? { detail } : {}),
    },
    on: {
      primary: bind({ type: "openFile", token: file.token }),
      secondary: bind({ type: "revealFile", token: file.token }),
      tertiary: bind({ type: "copyPath", token: file.token }),
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Strict constrained sampling sends null for absent optional fields. */
function field<T>(block: Record<string, unknown>, name: string, guard: (value: unknown) => value is T): T | undefined {
  const value = block[name];
  return value !== null && value !== undefined && guard(value) ? value : undefined;
}

const isString = (value: unknown): value is string => typeof value === "string";
const isArray = (value: unknown): value is unknown[] => Array.isArray(value);
const oneOf = <T extends string>(values: readonly T[]) => (value: unknown): value is T => typeof value === "string" && (values as readonly string[]).includes(value);

function clipEnd(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

function clipStart(value: string, max: number): string {
  return value.length <= max ? value : `…${value.slice(value.length - max + 1)}`;
}

/** Keeps a file name's extension visible. */
function clipMiddle(value: string, max: number): string {
  if (value.length <= max) return value;
  const tail = Math.min(40, Math.floor(max / 3));
  return `${value.slice(0, max - tail - 1)}…${value.slice(value.length - tail)}`;
}

const NUMERIC = /^[-+−]?[$€£¥]?\s?\d[\d.,'\s]*\s?(%|[$€£¥]|[A-Z]{3})?$/u;

interface Built { spec: CardSpec; issues: CardIssue[] }

function buildCard(raw: unknown, ledger: FileRefSource, partial: boolean, options: BlocksOptions): Built {
  const issues: CardIssue[] = [];
  const problem = (path: string, message: string, code: CardIssue["code"] = "invalid_shape") => {
    if (!partial) issues.push({ code, path, message });
  };
  const elements: Record<string, CardElement> = {};
  const rootChildren: string[] = [];
  const add = (key: string, element: CardElement, top = true) => {
    elements[key] = element;
    if (top) rootChildren.push(key);
  };
  const params = isRecord(raw) ? raw : {};
  const summary = partial ? undefined : field(params, "summary", isString);
  const blocks = field(params, "blocks", isArray) ?? [];
  if (!partial && blocks.length === 0) problem("blocks", "show_result needs at least one block");
  if (!partial && blocks.length > SHOW_RESULT_MAX_BLOCKS) problem("blocks", `show_result takes at most ${SHOW_RESULT_MAX_BLOCKS} blocks`);

  blocks.slice(0, SHOW_RESULT_MAX_BLOCKS).forEach((value, index) => {
    const path = `blocks[${index}]`;
    const key = `b${index}`;
    // While streaming, the last block may still be cut off mid-value.
    const open = partial && index === blocks.length - 1;
    const settled = <T>(list: T[]): T[] => (open ? list.slice(0, -1) : list);
    if (!isRecord(value)) { problem(path, "a block must be an object"); return; }
    const type = field(value, "type", oneOf(SHOW_RESULT_BLOCK_TYPES));
    if (!type) { problem(`${path}.type`, "unknown block type"); return; }
    const need = <T>(name: string, found: T | undefined): found is T => {
      if (found === undefined) problem(`${path}.${name}`, `${type} blocks need ${name}`);
      return found !== undefined;
    };
    const title = field(value, "title", isString);
    switch (type) {
      case "markdown": {
        const source = field(value, "text", isString);
        if (need("text", source) && (!partial || source.trim())) add(key, { type: "Markdown", props: { source } });
        return;
      }
      case "result": {
        if (open) return;
        const result = field(value, "value", isString);
        if (!need("value", result)) return;
        const input = field(value, "input", isString);
        const detail = field(value, "detail", isString);
        add(key, {
          type: "ResultCard",
          props: { kind: field(value, "kind", oneOf(RESULT_KINDS)) ?? "fact", ...(input ? { input } : {}), value: result, ...(detail ? { detail } : {}) },
          on: { copy: bind({ type: "copyText", text: result }) },
        });
        return;
      }
      case "status":
      case "notice": {
        if (open) return;
        const line = field(value, "text", isString);
        if (!need("text", line)) return;
        add(key, type === "status"
          ? { type: "Status", props: { state: field(value, "state", oneOf(STATUS_STATES)) ?? "done", text: line } }
          : { type: "Notice", props: { tone: field(value, "tone", oneOf(NOTICE_TONES)) ?? "info", text: line } });
        return;
      }
      case "keyValue": {
        const listed = settled(field(value, "items", isArray) ?? []);
        const items = listed
          .filter((item): item is { key: string; value: string } => isRecord(item) && isString(item.key) && isString(item.value))
          .map(item => ({ key: item.key, value: item.value }));
        if (items.length !== listed.length) problem(`${path}.items`, "every item needs a string key and value");
        if (!items.length) { problem(`${path}.items`, "keyValue blocks need at least one item"); return; }
        add(key, { type: "KeyValue", props: { ...(title ? { title } : {}), items } });
        return;
      }
      case "table": {
        const rows = field(value, "rows", isArray);
        const listed = field(value, "columns", isArray) ?? [];
        const columns = listed.filter(isString);
        if (open && rows === undefined) return; // Columns may still be streaming.
        if (columns.length !== listed.length) problem(`${path}.columns`, "column labels must be strings");
        if (!columns.length) { problem(`${path}.columns`, "table blocks need 1–6 columns"); return; }
        if (columns.length > 6) problem(`${path}.columns`, "tables take at most 6 columns");
        const shown = columns.slice(0, 6);
        const cells = settled(rows ?? []).filter(isArray).map((row, rowIndex) => {
          if (row.length > shown.length) problem(`${path}.rows[${rowIndex}]`, "a row has more cells than there are columns");
          return Object.fromEntries(shown.map((_, column) => [`c${column}`, isString(row[column]) ? row[column] : null])) as Record<string, string | null>;
        });
        const numeric = shown.map((_, column) => {
          const values = cells.map(row => row[`c${column}`]).filter((cell): cell is string => typeof cell === "string" && cell.trim() !== "");
          return values.length > 0 && values.every(cell => NUMERIC.test(cell.trim()));
        });
        add(key, {
          type: "Table",
          props: {
            ...(title ? { title } : {}),
            columns: shown.map((label, column) => ({ key: `c${column}`, label, ...(numeric[column] ? { align: "right" } : {}) })),
            rows: partial ? cells.slice(0, 50) : cells,
          },
        });
        return;
      }
      case "files": {
        const refs = settled(field(value, "refs", isArray) ?? []);
        if (!partial && !refs.length) { problem(`${path}.refs`, "files blocks need at least one ref"); return; }
        const children: string[] = [];
        refs.forEach((ref, item) => {
          const file = isString(ref) ? ledger.resolve(ref.trim()) : undefined;
          if (!file) {
            problem(`${path}.refs[${item}]`, "unknown or expired file ref; use refs returned by a pi-os file tool in this conversation", "unknown_file_ref");
            return;
          }
          children.push(`${key}-${item}`);
          add(`${key}-${item}`, fileItemElement(file, options), false);
        });
        if (children.length) add(key, { type: "ItemList", props: title ? { title } : {}, children });
        return;
      }
      case "links": {
        const links = settled(field(value, "links", isArray) ?? []);
        if (!partial && !links.length) { problem(`${path}.links`, "links blocks need at least one link"); return; }
        if (links.length > SHOW_RESULT_MAX_LINKS) problem(`${path}.links`, `links blocks take at most ${SHOW_RESULT_MAX_LINKS} links`);
        const children: string[] = [];
        links.slice(0, SHOW_RESULT_MAX_LINKS).forEach((link, item) => {
          const url = isRecord(link) && isString(link.url) ? link.url.trim() : undefined;
          const name = isRecord(link) && isString(link.title) ? link.title.trim() : "";
          if (!url || !isHttpUrl(url)) { problem(`${path}.links[${item}].url`, "links must be http(s) URLs"); return; }
          const visit: HostAction = { type: "openURL", url };
          children.push(`${key}-${item}`);
          add(`${key}-${item}`, {
            type: "Item",
            props: { title: clipEnd(name || new URL(url).hostname, 200), subtitle: clipEnd(url, 1_024), icon: { kind: "url" } },
            on: { primary: bind(visit), secondary: bind({ type: "copyText", text: url }) },
          }, false);
        });
        if (children.length) add(key, { type: "ItemList", props: title ? { title } : {}, children });
        return;
      }
      case "suggestions": {
        const prompts = settled(field(value, "prompts", isArray) ?? []).filter(isString).map(prompt => prompt.trim()).filter(Boolean);
        if (!partial && !prompts.length) { problem(`${path}.prompts`, "suggestions blocks need at least one prompt"); return; }
        if (prompts.length > SHOW_RESULT_MAX_SUGGESTIONS) problem(`${path}.prompts`, `at most ${SHOW_RESULT_MAX_SUGGESTIONS} suggestions`);
        prompts.slice(0, SHOW_RESULT_MAX_SUGGESTIONS).forEach((prompt, item) => {
          add(`${key}-${item}`, { type: "Suggestion", props: { prompt }, on: { press: bind({ type: "askAgent", prompt }) } });
        });
        return;
      }
    }
  });

  elements.root = { type: "Answer", props: summary ? { summary } : {}, ...(rootChildren.length ? { children: rootChildren } : {}) };
  return { spec: { format: CARD_FORMAT, root: "root", elements }, issues };
}

/** Validation paths name generated keys; translate them back to the model's blocks. */
function toBlockIssue(issue: CardIssue): CardIssue {
  const path = issue.path
    .replace(/^elements\.root\.props(?:\.summary)?/, "summary")
    .replace(/^elements\.b(\d+)-(\d+)/, "blocks[$1] entry $2")
    .replace(/^elements\.b(\d+)/, "blocks[$1]");
  return { ...issue, path };
}
