import type { CardElement, CardSpec } from "../contracts/cards.js";

/**
 * Deterministic plain-text / light-Markdown rendering of a card (DESIGN §3.2).
 *
 * This is what `responseText` carries: the Windows answer box shows it verbatim,
 * the macOS reader falls back to it, and Copy Answer copies it. One line per
 * paragraph (the macOS AnswerRenderer is line-based), blocks separated by a
 * blank line, no locale- or clock-dependent formatting. Suggestions are
 * omitted (they are buttons, not content); the Answer summary is used only
 * when no block produced text.
 */
export function cardToText(spec: CardSpec): string {
  const root = elementAt(spec, spec.root);
  if (!root) return "";
  const seen = new Set<string>([spec.root]);
  const blocks: { text: string; listItem: boolean }[] = [];
  for (const key of root.children ?? []) {
    const element = elementAt(spec, key);
    if (!element || seen.has(key)) continue;
    seen.add(key);
    const text = blockText(spec, element, seen);
    if (text) blocks.push({ text, listItem: element.type === "Item" });
  }
  if (!blocks.length) return str(root.props.summary).trim();
  // Consecutive top-level Items read as one list.
  return blocks.map((block, index) => (index === 0 ? "" : block.listItem && blocks[index - 1]!.listItem ? "\n" : "\n\n") + block.text).join("");
}

function elementAt(spec: CardSpec, key: string): CardElement | undefined {
  return Object.hasOwn(spec.elements, key) ? spec.elements[key] : undefined;
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/** Single-line text: paragraphs inside a value would otherwise split the layout. */
function line(value: unknown): string {
  return str(value).replace(/\s*[\r\n]+\s*/g, " ").trim();
}

function lines(...parts: string[]): string {
  return parts.filter(Boolean).join("\n");
}

const EQUALS_KINDS = new Set(["math", "conversion", "currency"]);
const STATUS_LABELS: Record<string, string> = { running: "Running", done: "Done", warning: "Warning", error: "Error" };

function blockText(spec: CardSpec, element: CardElement, seen: Set<string>): string {
  const props = element.props;
  switch (element.type) {
    case "Markdown":
      return str(props.source).trim();
    case "ResultCard": {
      const input = line(props.input);
      const value = line(props.value);
      const head = input ? `${input}${EQUALS_KINDS.has(str(props.kind)) ? " = " : ": "}${value}` : value;
      const freshness = typeof props.freshness === "object" && props.freshness !== null
        ? line((props.freshness as Record<string, unknown>).label) : "";
      return lines(head, line(props.detail), freshness);
    }
    case "KeyValue": {
      const items = Array.isArray(props.items) ? props.items as { key?: unknown; value?: unknown }[] : [];
      return lines(line(props.title), ...items.map(item => `- ${line(item.key)}: ${line(item.value)}`));
    }
    case "Table":
      return tableText(props);
    case "ItemList": {
      const items: string[] = [];
      for (const key of element.children ?? []) {
        const child = elementAt(spec, key);
        if (!child || child.type !== "Item" || seen.has(key)) continue;
        seen.add(key);
        items.push(itemText(child));
      }
      const total = typeof props.total === "number" && props.total > items.length ? ` (showing ${items.length} of ${props.total})` : "";
      const title = line(props.title);
      return lines(title || total ? `${title || "Results"}${total}` : "", ...items);
    }
    case "Item":
      return itemText(element);
    case "Notice":
      return line(props.text);
    case "Status": {
      const progress = typeof props.progress === "number" && props.state === "running" ? ` (${Math.round(props.progress * 100)}%)` : "";
      return `${STATUS_LABELS[str(props.state)] ?? "Status"}: ${line(props.text)}${progress}`;
    }
    default:
      // Answer (only valid as root), Suggestion (a button) and anything unknown.
      return "";
  }
}

function itemText(element: CardElement): string {
  const subtitle = line(element.props.subtitle);
  const detail = line(element.props.detail);
  return `- ${line(element.props.title)}${subtitle ? ` — ${subtitle}` : ""}${detail ? ` · ${detail}` : ""}`;
}

function cellText(value: unknown): string {
  const text = typeof value === "number" ? String(value) : line(value);
  return text.replace(/\|/g, "\\|");
}

function tableText(props: Record<string, unknown>): string {
  const columns = Array.isArray(props.columns) ? props.columns as { key?: unknown; label?: unknown; align?: unknown }[] : [];
  if (!columns.length) return "";
  const rows = Array.isArray(props.rows) ? props.rows as Record<string, unknown>[] : [];
  const rule = (align: unknown) => (align === "right" ? "---:" : align === "center" ? ":---:" : "---");
  return lines(
    line(props.title),
    `| ${columns.map(column => cellText(column.label)).join(" | ")} |`,
    `| ${columns.map(column => rule(column.align)).join(" | ")} |`,
    ...rows.map(row => `| ${columns.map(column => cellText(Object.hasOwn(row, str(column.key)) ? row[str(column.key)] : null)).join(" | ")} |`),
  );
}
