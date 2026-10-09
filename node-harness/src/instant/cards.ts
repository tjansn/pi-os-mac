import { MAX_ACTION_TEXT, type HostAction } from "../contracts/actions.js";
import { buildCard, ui, type CardNode, type CardSpec, type Freshness, type ResultCardProps } from "../contracts/cards.js";
import type { AppRecord } from "../contracts/launcher.js";
import { truncate } from "./format.js";

/**
 * pi-os-ui/1 cards for instant responses, built only from the dependency-free
 * builders in src/contracts/cards.ts. Every action is a host descriptor the
 * user triggers explicitly; file actions carry host-minted tokens only.
 */

export const MAX_LIST_ITEMS = 8;

export interface ResultCardInput {
  kind: ResultCardProps["kind"];
  value: string;
  input?: string;
  detail?: string;
  freshness?: Freshness;
  /** Plain value for the copy action; omitted → no copy binding. */
  copyText?: string;
  /** Defaults to "<input> = <value>" (or the value). */
  summary?: string;
}

/** Never copies a silently shortened value: above the action limit there is no copy binding. */
function copyAction(text: string | undefined): HostAction | undefined {
  return text && text.length <= MAX_ACTION_TEXT ? { type: "copyText", text } : undefined;
}

export function resultCard(r: ResultCardInput): CardSpec {
  const summary = r.summary ?? (r.input ? `${r.input}${r.value.startsWith("≈") ? " " : " = "}${r.value}` : r.value);
  return buildCard(ui.answer({ summary: truncate(summary) }, [
    ui.result({
      kind: r.kind,
      ...(r.input !== undefined ? { input: truncate(r.input) } : {}),
      value: truncate(r.value),
      ...(r.detail !== undefined ? { detail: truncate(r.detail) } : {}),
      ...(r.freshness ? { freshness: { label: truncate(r.freshness.label, 120), level: r.freshness.level } } : {}),
    }, copyAction(r.copyText)),
  ]));
}

export function noticeCard(tone: "info" | "warning" | "error" | "success", text: string, summary?: string): CardSpec {
  return buildCard(ui.answer(summary ? { summary: truncate(summary) } : {}, [ui.notice(tone, truncate(text, 500))]));
}

export function refuseCard(message: string): CardSpec {
  return noticeCard("error", message);
}

/** One link row: previews and the reader's record of an opened URL / web search. */
export function linkCard(title: string, url: string): CardSpec {
  return buildCard(ui.answer({ summary: truncate(title) }, [
    ui.itemList({}, [ui.item({ title: truncate(title), subtitle: truncate(url, 1_024), icon: { kind: "url" } }, { primary: { type: "openURL", url } })]),
  ]));
}

export interface FileRow {
  token: string;
  name: string;
  /** "~/Documents/Finance" */
  folder: string;
  contentType?: string;
  /** "Mar 14" */
  detail?: string;
}

export function fileListCard(summary: string, listTitle: string, rows: readonly FileRow[], total: number, notice?: string): CardSpec {
  const items: CardNode[] = rows.slice(0, MAX_LIST_ITEMS).map((row) => ui.item({
    title: truncate(row.name),
    subtitle: truncate(row.folder, 1_024),
    icon: { kind: "file", ...(row.contentType ? { uti: row.contentType } : {}) },
    ...(row.detail ? { detail: truncate(row.detail, 40) } : {}),
  }, {
    primary: { type: "openFile", token: row.token },
    secondary: { type: "revealFile", token: row.token },
    tertiary: { type: "copyPath", token: row.token },
  }));
  const children: CardNode[] = [];
  if (notice) children.push(ui.notice("info", truncate(notice, 500)));
  children.push(ui.itemList({ title: truncate(listTitle), total }, items));
  return buildCard(ui.answer({ summary: truncate(summary) }, children));
}

export function appListCard(summary: string, apps: readonly AppRecord[]): CardSpec {
  const items = apps.slice(0, MAX_LIST_ITEMS).map((app) => ui.item({
    title: truncate(app.name),
    subtitle: truncate(app.path, 1_024),
    icon: { kind: "app", bundleId: app.bundleId },
  }, { primary: { type: "openApp", bundleId: app.bundleId } }));
  return buildCard(ui.answer({ summary: truncate(summary) }, [ui.itemList({ title: "Applications" }, items)]));
}
