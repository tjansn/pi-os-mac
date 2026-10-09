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
  return appRowsCard(summary, apps.map((app) => ({ app })));
}

/** One app row: the record plus the name to show ("Pages" for "Pages Creator Studio"; default the app's name). */
export interface AppRow { app: AppRecord; label?: string }

/**
 * App rows that open the app (primary binding). Spoken decisions title their rows with the matched label
 * (AppMatch.label, DESIGN4 §5.3): "Did you mean Pages?" shows a "Pages" row, not "Pages Creator Studio".
 */
export function appRowsCard(summary: string, rows: readonly AppRow[]): CardSpec {
  const items = rows.slice(0, MAX_LIST_ITEMS).map(({ app, label }) => ui.item({
    title: truncate(label?.trim() || app.name),
    subtitle: truncate(app.path, 1_024),
    icon: { kind: "app", bundleId: app.bundleId },
  }, { primary: { type: "openApp", bundleId: app.bundleId } }));
  return buildCard(ui.answer({ summary: truncate(summary) }, [ui.itemList({ title: "Applications" }, items)]));
}

/**
 * A file or folder an `open_item` decision offers: a visible item (desktop icon, target Finder window item)
 * or a found one. Display only: the row binds the host token, never the path.
 */
export interface ItemRow {
  token: string;
  name: string;
  /** Display name of the containing folder ("Desktop"); the subtitle reads "in Desktop". Never a full path. */
  folder: string;
  /** UTI for the icon ("public.folder"). */
  contentType?: string;
}

/** One row of an `open_item` card: a file or folder (ItemRow), or an app (AppRow). */
export type ChoiceRow = { item: ItemRow } | AppRow;

function itemRowNode(row: ItemRow): CardNode {
  return ui.item({
    title: truncate(row.name),
    subtitle: truncate(`in ${row.folder}`, 1_024),
    icon: { kind: "file", ...(row.contentType ? { uti: row.contentType } : {}) },
  }, {
    primary: { type: "openFile", token: row.token },
    secondary: { type: "revealFile", token: row.token },
    tertiary: { type: "copyPath", token: row.token },
  });
}

/**
 * `open_item` rows in the given order (visible rows first is the caller's rule), under one untitled list:
 * the did-you-mean / choice card ("Did you mean…" with a folder and an app). File rows open (primary),
 * reveal (secondary) and copy the path (tertiary) by token; app rows open the app, titled with the label.
 * Matches shared/fixtures/instant/list-did-you-mean-visible.json.
 */
export function choiceRowsCard(summary: string, rows: readonly ChoiceRow[]): CardSpec {
  const items = rows.slice(0, MAX_LIST_ITEMS).map((row) => "item" in row ? itemRowNode(row.item) : ui.item({
    title: truncate(row.label?.trim() || row.app.name),
    subtitle: truncate(row.app.path, 1_024),
    icon: { kind: "app", bundleId: row.app.bundleId },
  }, { primary: { type: "openApp", bundleId: row.app.bundleId } }));
  return buildCard(ui.answer({ summary: truncate(summary) }, [ui.itemList({}, items)]));
}

/** The reader's record of an `open_item` act ("Open Radfotos"): the one opened row. Matches shared/fixtures/instant/act-open-visible.json. */
export function openItemCard(title: string, row: ItemRow): CardSpec {
  return choiceRowsCard(title, [{ item: row }]);
}
