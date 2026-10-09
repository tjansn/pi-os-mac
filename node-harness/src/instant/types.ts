import type { SystemOp } from "../contracts/actions.js";
import type { CalendarUnit, DateTarget, MsRange } from "./engines/dates.js";
import type { PlaceZone } from "./engines/timezones.js";

/** Inputs the pure grammar may consult (no I/O). */
export interface MatchContext {
  now: Date;
  /** BCP 47 display locale ("en-US", "de-DE"). */
  locale: string;
  /** Default web search URL with `%s` for the encoded query. */
  webSearchTemplate: string;
}

export type BaseName = "hex" | "binary" | "octal" | "decimal" | `base ${number}`;

export interface FileQuery {
  /** AND name terms, lowercase, stopwords removed. */
  terms: string[];
  /** Display form of the query ("invoice"). */
  label: string;
  /** UTI the results must conform to. */
  contentType?: string;
  range?: MsRange;
  /** "March 2026", "yesterday" … for subtitles. */
  rangeLabel?: string;
}

export type DateQuery =
  | { op: "days_until"; target: DateTarget; label: string }
  | { op: "offset"; amount: number; unit: CalendarUnit }
  | { op: "weekday_in"; weekday: number; weeks: number }
  | { op: "weekday_of"; target: DateTarget; label: string }
  | { op: "today" };

/** Grammar output: what the utterance asks for, before any engine runs. */
export type Parsed =
  | { kind: "refuse" }
  /** "delete Slack": refused when the bare object is exactly an installed app, else a plain miss. */
  | { kind: "delete_target"; target: string }
  | { kind: "fallthrough"; reason: "deictic" | "compound" | "unknown_place" }
  | { kind: "calc"; expression: string; display: string; units: boolean }
  | { kind: "unit"; expression: string; display: string }
  | { kind: "base"; expression: string; display: string; base: BaseName }
  | { kind: "currency"; amount: number; from: string; to: string }
  | { kind: "time"; place: PlaceZone }
  | { kind: "time_convert"; hour: number; minute: number; from: PlaceZone | null; to: PlaceZone }
  | { kind: "time_diff"; from: PlaceZone | null; to: PlaceZone }
  | { kind: "date"; query: DateQuery }
  | { kind: "file_search"; query: FileQuery }
  /** "open X": an app from the host index, else `siteUrl` when X names a well-known site. */
  | { kind: "open"; target: string; siteUrl?: string }
  | { kind: "url"; url: string; label: string }
  | { kind: "web"; url: string; query: string; engine: string }
  | { kind: "system"; op: SystemOp; value?: number | boolean; title: string };
