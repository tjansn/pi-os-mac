import { homedir } from "node:os";
import { Type } from "typebox";
import { StringEnum, type JsonObject } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { HostClient } from "../hostClient.js";
import { AGENT_OPEN_ACTION_TYPES, parseHostAction, type HostAction } from "../contracts/actions.js";
import type { Freshness } from "../contracts/cards.js";
import type {
  AppIndexResult, AppRecord, FileCandidate, FileSearchRequest, FileSearchResult, LauncherOpenRequest, LauncherOpenResult,
} from "../contracts/launcher.js";

/**
 * Instant-engine and launcher tools for the agent (DESIGN B5). The engines and the file
 * ref ledger are injected (C1 wires src/instant and src/ui); host effects go through the
 * launcher routes, where the host applies the same LauncherPolicy as its own UI.
 *
 * Read tools are `direct` (model and codemode scripts) and declare `outputSchema`, so
 * scripts receive objects. `open_item` is the only effect: `model-only`, refused in
 * read-only invocations, and files open only by a ledger ref the model saw, never by a
 * path or token. Nothing here logs inputs, results or file names.
 */

export const INSTANT_CALC_TOOL = "instant_calc";
export const INSTANT_CURRENCY_TOOL = "instant_convert_currency";
export const INSTANT_TIME_TOOL = "instant_time_in";
export const FIND_FILES_TOOL = "find_files";
export const LIST_APPS_TOOL = "list_apps";
export const OPEN_ITEM_TOOL = "open_item";
/** Engine-only tools: need no host route (also usable where the host has no launcher routes). */
export const INSTANT_TOOL_NAMES = [INSTANT_CALC_TOOL, INSTANT_CURRENCY_TOOL, INSTANT_TIME_TOOL] as const;
/** Read-only tools: safe for the model and for codemode scripts. */
export const LAUNCHER_READ_TOOL_NAMES = [INSTANT_CALC_TOOL, INSTANT_CURRENCY_TOOL, INSTANT_TIME_TOOL, FIND_FILES_TOOL, LIST_APPS_TOOL] as const;
/** Every tool this extension registers (for the isolated tools allowlist). */
export const LAUNCHER_TOOL_NAMES = [...LAUNCHER_READ_TOOL_NAMES, OPEN_ITEM_TOOL] as const;

/** Exact calculator outcome; mirrors the instant engine's fend result. */
export type CalcOutcome = { ok: true; text: string; approximate?: boolean } | { ok: false; error: string };
/** ECB reference conversion (information only). */
export interface CurrencyOutcome { value: number; asOf: string; freshness: Freshness["level"] }
export interface TimeOutcome {
  place: string;
  /** IANA zone, e.g. "Asia/Tokyo". */
  zone: string;
  /** Local wall time, e.g. "03:15". */
  time: string;
  weekday: string;
  /** e.g. "UTC+09:00". */
  offset: string;
  dayDelta: -1 | 0 | 1;
}

/** The subset of the instant engine (B1) the agent tools need. Implementations bound their own
 * work (fend timeout, cached ECB rates) and should not throw for user input. */
export interface InstantToolEngines {
  calc(expression: string, signal?: AbortSignal): CalcOutcome | Promise<CalcOutcome>;
  /** null when there is no rate for the pair or rates were never downloaded. */
  convertCurrency(amount: number, from: string, to: string, signal?: AbortSignal): CurrencyOutcome | null | Promise<CurrencyOutcome | null>;
  /** null for an unknown place. */
  timeIn(place: string, signal?: AbortSignal): TimeOutcome | null | Promise<TimeOutcome | null>;
}

/** Thread-scoped file ref ledger (B2): model-visible refs ("f1") stand for host-minted tokens. */
export interface FileRefLedger {
  /** Remember one host search result and return its model-visible ref; undefined when the
   * ledger refuses the candidate (the item is then left out). */
  register(candidate: FileCandidate): string | undefined;
  /** The host token behind a ref this ledger issued, else undefined. */
  token(ref: string): string | undefined;
}

export interface LauncherToolDeps {
  engines: InstantToolEngines;
  /**
   * Host tool transport (HostClient works as is); used for the launcher routes only. Without
   * host AND ledger (a host with no launcher routes, e.g. Windows) only INSTANT_TOOL_NAMES register.
   */
  host?: Pick<HostClient, "invokeTool">;
  ledger?: FileRefLedger;
  /** No effects in this invocation (computer control off): open_item refuses. */
  readOnly: boolean;
  /** Optional for launcher routes; sent when present so the host can scope tokens. */
  contextId?: string;
  /** Only used to name a coarse location (Downloads, Documents, …) instead of a path. */
  homeDir?: string;
  now?: () => number;
  /** Optional ranking (e.g. the instant engine's); default: most recently used/modified first. */
  rankFiles?: (items: FileCandidate[]) => FileCandidate[];
}

const FILE_KINDS = {
  any: undefined, pdf: "com.adobe.pdf", image: "public.image", text: "public.text", spreadsheet: "public.spreadsheet",
  presentation: "public.presentation", audio: "public.audio", video: "public.movie", archive: "public.archive",
  folder: "public.folder", app: "com.apple.application-bundle",
} as const;
type FileKind = keyof typeof FILE_KINDS;
const MAX_NAME_TERMS = 6;
const DAY_MS = 86_400_000;

const ok = Type.Boolean({ description: "false when the request could not be answered; see error" });
const error = Type.Optional(Type.String());
const calcOutput = Type.Object({ ok, value: Type.Optional(Type.String()), approximate: Type.Optional(Type.Boolean()), error });
const currencyOutput = Type.Object({
  ok, amount: Type.Number(), from: Type.String(), to: Type.String(), value: Type.Optional(Type.Number()),
  asOf: Type.Optional(Type.String()), freshness: Type.Optional(StringEnum(["fresh", "aging", "stale", "missing"] as const)), error,
});
const timeOutput = Type.Object({
  ok, place: Type.String(), timeZone: Type.Optional(Type.String()), time: Type.Optional(Type.String()), weekday: Type.Optional(Type.String()),
  utcOffset: Type.Optional(Type.String()), dayDelta: Type.Optional(Type.Integer({ minimum: -1, maximum: 1 })), error,
});
const fileItem = Type.Object({
  ref: Type.String({ description: "Pass to open_item; valid for this task only" }), name: Type.String(), kind: Type.String(),
  location: Type.String({ description: "Coarse location such as Downloads or Documents; never a path" }), modified: Type.Optional(Type.String()),
});
const filesOutput = Type.Object({ ok, items: Type.Array(fileItem), total: Type.Integer(), truncated: Type.Boolean(), error });
const appsOutput = Type.Object({
  ok, apps: Type.Array(Type.Object({ name: Type.String(), bundleId: Type.String(), running: Type.Boolean() })), total: Type.Integer(), error,
});

type Result = { content: { type: "text"; text: string }[]; details: Record<string, never>; structuredContent: JsonObject; isError?: boolean };
function reply(text: string, structured: JsonObject, isError = false): Result {
  return { content: [{ type: "text", text }], details: {}, structuredContent: structured, ...(isError ? { isError: true } : {}) };
}

/** Engine failures become an error result; aborts stay aborts. No engine message is echoed. */
async function guarded<T>(signal: AbortSignal | undefined, run: () => T | Promise<T>): Promise<T | undefined> {
  try { return await run(); } catch { signal?.throwIfAborted(); return undefined; }
}

function locationOf(path: string, home: string): string {
  const inside = (dir: string) => path === dir || path.startsWith(`${dir}/`);
  if (inside("/Applications") || inside(`${home}/Applications`) || inside("/System/Applications")) return "Applications";
  if (inside(`${home}/Library/Mobile Documents/com~apple~CloudDocs`)) return "iCloud Drive";
  for (const name of ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]) if (inside(`${home}/${name}`)) return name;
  return inside(home) ? "Home" : "Other";
}

function kindOf(candidate: FileCandidate): string {
  if (candidate.isPackage && /\.app$/i.test(candidate.name)) return "app";
  if (candidate.isDirectory && !candidate.isPackage) return "folder";
  return /\.([A-Za-z0-9]{1,8})$/.exec(candidate.name)?.[1]?.toLowerCase() ?? "file";
}

const ms = (value: unknown) => typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= 8.64e15 ? value : undefined;
const recency = (c: FileCandidate) => Math.max(ms(c.lastUsedMs) ?? 0, ms(c.modifiedMs) ?? 0);
const defaultRank = (items: FileCandidate[]) => [...items].sort((a, b) => recency(b) - recency(a));
const fold = (value: string) => value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

function validCandidate(value: unknown): value is FileCandidate {
  const c = value as Partial<FileCandidate> | null;
  return !!c && typeof c.token === "string" && typeof c.name === "string" && c.name.length > 0 && c.name.length <= 1024
    && typeof c.path === "string" && typeof c.isDirectory === "boolean" && typeof c.isPackage === "boolean";
}

function validApp(value: unknown): value is AppRecord {
  const a = value as Partial<AppRecord> | null;
  return !!a && typeof a.bundleId === "string" && typeof a.name === "string" && Array.isArray(a.aliases);
}

export function createLauncherToolsExtension(deps: LauncherToolDeps) {
  const home = deps.homeDir ?? homedir();
  const now = deps.now ?? Date.now;
  const rank = deps.rankFiles ?? defaultRank;
  const scoped = (args: Record<string, unknown>) => (deps.contextId ? { ...args, contextId: deps.contextId } : args);
  const host = async <T>(route: "launcher.searchFiles" | "launcher.listApps" | "launcher.open", args: Record<string, unknown>, signal?: AbortSignal): Promise<T> => {
    const outcome = await deps.host!.invokeTool<T>(route, scoped(args), signal);
    if (!outcome.ok) throw new Error(`${outcome.error.code}: ${outcome.error.message}`);
    return outcome.result;
  };

  return {
    name: "pi-os-launcher-tools",
    factory(pi: ExtensionAPI) {
      pi.registerTool({
        name: INSTANT_CALC_TOOL, label: "Calculate",
        description: "Exact calculator: arithmetic, percentages, units and number bases (e.g. \"18% of 2340\", \"5 ft to cm\", \"0xff to decimal\"). Use it instead of mental math.",
        parameters: Type.Object({ expression: Type.String({ minLength: 1, maxLength: 500 }) }, { additionalProperties: false }),
        outputSchema: calcOutput,
        annotations: { readOnlyHint: true },
        async execute(_id, params, signal) {
          const outcome = await guarded(signal, () => deps.engines.calc(params.expression, signal));
          if (!outcome?.ok) {
            const reason = outcome ? outcome.error : "calculator_unavailable";
            return reply(`calc_failed: ${reason}`, { ok: false, error: reason }, true);
          }
          const value = `${outcome.approximate ? "≈ " : ""}${outcome.text}`;
          return reply(`${params.expression} = ${value}`, { ok: true, value: outcome.text, approximate: outcome.approximate === true });
        },
      });

      pi.registerTool({
        name: INSTANT_CURRENCY_TOOL, label: "Convert Currency",
        description: "Convert an amount between currencies (ISO codes such as USD, EUR, CHF) at the cached ECB reference rate. Information only; report the rate date and freshness.",
        parameters: Type.Object({
          amount: Type.Number({ minimum: 0, maximum: 1e15 }),
          from: Type.String({ pattern: "^[A-Za-z]{3}$" }), to: Type.String({ pattern: "^[A-Za-z]{3}$" }),
        }, { additionalProperties: false }),
        outputSchema: currencyOutput,
        annotations: { readOnlyHint: true },
        async execute(_id, params, signal) {
          const from = params.from.toUpperCase(), to = params.to.toUpperCase(), amount = params.amount;
          if (!Number.isFinite(amount) || !/^[A-Z]{3}$/.test(from) || !/^[A-Z]{3}$/.test(to)) {
            return reply("invalid_arguments: amount must be finite and currencies 3-letter ISO codes", { ok: false, amount: 0, from, to, error: "invalid_arguments" }, true);
          }
          const outcome = await guarded(signal, () => deps.engines.convertCurrency(amount, from, to, signal));
          if (!outcome || !Number.isFinite(outcome.value)) {
            return reply(`no_rate: No ECB reference rate is available for ${from} → ${to}.`, { ok: false, amount, from, to, error: "no_rate" }, true);
          }
          const shown = outcome.value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
          return reply(
            `${amount} ${from} = ${shown} ${to} (ECB reference rate ${outcome.asOf}, ${outcome.freshness}; information only)`,
            { ok: true, amount, from, to, value: outcome.value, asOf: outcome.asOf, freshness: outcome.freshness },
          );
        },
      });

      pi.registerTool({
        name: INSTANT_TIME_TOOL, label: "Time In",
        description: "Current local time, weekday and UTC offset in a city, country or time zone (e.g. \"Tokyo\", \"New York\", \"Europe/Berlin\").",
        parameters: Type.Object({ place: Type.String({ minLength: 1, maxLength: 100 }) }, { additionalProperties: false }),
        outputSchema: timeOutput,
        annotations: { readOnlyHint: true },
        async execute(_id, params, signal) {
          const outcome = await guarded(signal, () => deps.engines.timeIn(params.place, signal));
          if (!outcome) return reply(`unknown_place: No time zone is known for "${params.place}".`, { ok: false, place: params.place, error: "unknown_place" }, true);
          const day = outcome.dayDelta === 1 ? ", tomorrow" : outcome.dayDelta === -1 ? ", yesterday" : "";
          return reply(`${outcome.place} (${outcome.zone}): ${outcome.time}, ${outcome.weekday}${day}, ${outcome.offset}`, {
            ok: true, place: outcome.place, timeZone: outcome.zone, time: outcome.time, weekday: outcome.weekday,
            utcOffset: outcome.offset, dayDelta: outcome.dayDelta,
          });
        },
      });

      const ledger = deps.ledger;
      if (!deps.host || !ledger) return;

      pi.registerTool({
        name: FIND_FILES_TOOL, label: "Find Files",
        description: "Search the user's files by name (Spotlight). nameGroups is an OR of AND-groups of name words, e.g. [[\"invoice\",\"march\"],[\"rechnung\",\"märz\"]]; at most 6 words in total. Returns names with refs (never paths); pass a ref to open_item.",
        parameters: Type.Object({
          nameGroups: Type.Array(Type.Array(Type.String({ minLength: 1, maxLength: 64 }), { minItems: 1, maxItems: MAX_NAME_TERMS }), { minItems: 1, maxItems: MAX_NAME_TERMS }),
          kind: Type.Optional(StringEnum(Object.keys(FILE_KINDS) as FileKind[])),
          modifiedWithinDays: Type.Optional(Type.Integer({ minimum: 1, maximum: 3650 })),
          limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50 })),
        }, { additionalProperties: false }),
        outputSchema: filesOutput,
        annotations: { readOnlyHint: true },
        async execute(_id, params, signal) {
          const nameGroups = params.nameGroups.map(group => group.map(term => term.trim()).filter(Boolean)).filter(group => group.length > 0);
          const terms = nameGroups.reduce((total, group) => total + group.length, 0);
          if (terms === 0 || terms > MAX_NAME_TERMS) {
            return reply(`invalid_arguments: use 1–${MAX_NAME_TERMS} name words in total`, { ok: false, items: [], total: 0, truncated: false, error: "invalid_arguments" }, true);
          }
          const kind: FileKind = params.kind ?? "any";
          const limit = params.limit ?? 20;
          const request: FileSearchRequest = {
            nameGroups,
            ...(FILE_KINDS[kind] ? { contentType: FILE_KINDS[kind] } : {}),
            ...(kind === "app" ? { scopes: ["applications", "home"] } : {}),
            // Over-fetch when dates are filtered here (the host route has no date range).
            maxResults: params.modifiedWithinDays ? 200 : Math.min(200, limit * 2),
          };
          const result = await host<FileSearchResult>("launcher.searchFiles", { ...request }, signal);
          const since = params.modifiedWithinDays ? now() - params.modifiedWithinDays * DAY_MS : undefined;
          const matches = (Array.isArray(result?.items) ? result.items : []).filter(validCandidate)
            .filter(item => since === undefined || (ms(item.modifiedMs) ?? 0) >= since);
          const kept = rank(matches).slice(0, limit);
          // Tokens and paths stay in Node: the model and scripts only ever see refs.
          const items = kept.flatMap(candidate => {
            const ref = ledger.register(candidate);
            if (!ref) return [];
            const modified = ms(candidate.modifiedMs);
            return [{
              ref, name: candidate.name, kind: kindOf(candidate), location: locationOf(candidate.path, home),
              ...(modified ? { modified: new Date(modified).toISOString().slice(0, 10) } : {}),
            }];
          });
          const truncated = result?.truncated === true || matches.length > kept.length;
          const lines = items.map(item => `${item.ref}  ${item.name} — ${item.kind}, ${item.location}${item.modified ? `, modified ${item.modified}` : ""}`);
          const text = items.length
            ? `${items.length} of ${matches.length}${result?.truncated ? "+" : ""} matching item(s):\n${lines.join("\n")}\nOpen or reveal one with open_item and its ref.`
            : "No matching files.";
          return reply(text, { ok: true, items, total: matches.length, truncated });
        },
      });

      pi.registerTool({
        name: LIST_APPS_TOOL, label: "List Apps",
        description: "List installed applications, optionally filtered by name (matches localized names and aliases). Returns names and bundle ids for open_item.",
        parameters: Type.Object({
          query: Type.Optional(Type.String({ maxLength: 100 })),
          limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50 })),
        }, { additionalProperties: false }),
        outputSchema: appsOutput,
        annotations: { readOnlyHint: true },
        async execute(_id, params, signal) {
          const index = await host<AppIndexResult>("launcher.listApps", {}, signal);
          const query = fold(params.query?.trim() ?? "");
          const apps = (Array.isArray(index?.apps) ? index.apps : []).filter(validApp)
            .filter(app => !query || [app.name, ...app.aliases].some(name => typeof name === "string" && fold(name).includes(query)));
          const kept = apps.slice(0, params.limit ?? 20).map(app => ({ name: app.name, bundleId: app.bundleId, running: app.running === true }));
          const text = kept.length
            ? `${kept.length} of ${apps.length} app(s):\n${kept.map(app => `${app.name} (${app.bundleId})${app.running ? " — running" : ""}`).join("\n")}`
            : "No matching apps.";
          return reply(text, { ok: true, apps: kept, total: apps.length });
        },
      });

      pi.registerTool({
        name: OPEN_ITEM_TOOL, label: "Open Item",
        description: "Open an app (bundleId from list_apps), an http(s) URL, or a file found by find_files (ref), or reveal that file in Finder. Executables, scripts and installers are only revealed. Nothing is ever deleted, moved or renamed.",
        parameters: Type.Object({
          action: StringEnum(AGENT_OPEN_ACTION_TYPES as readonly ("openApp" | "openURL" | "openFile" | "revealFile")[]),
          bundleId: Type.Optional(Type.String({ maxLength: 255 })),
          url: Type.Optional(Type.String({ maxLength: 2048 })),
          ref: Type.Optional(Type.String({ maxLength: 64 })),
        }, { additionalProperties: false }),
        annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
        // An effect: the model decides it directly; scripts can never open anything.
        exposure: "model-only",
        executionMode: "sequential",
        async execute(_id, params, signal) {
          if (deps.readOnly) {
            throw new Error("control_disabled: Opening apps, links and files is not available in this invocation. Tell the user what to open instead.");
          }
          let candidate: Partial<HostAction> & { type: string };
          if (params.action === "openApp") candidate = { type: "openApp", bundleId: params.bundleId ?? "" };
          else if (params.action === "openURL") candidate = { type: "openURL", url: params.url ?? "" };
          else {
            // Only refs this thread's ledger issued resolve; a token or path from the model never does.
            const token = params.ref ? ledger.token(params.ref) : undefined;
            if (!token) throw new Error("unknown_ref: Use a ref returned by find_files in this task.");
            candidate = { type: params.action, token };
          }
          const action = parseHostAction(candidate);
          if (!action || !AGENT_OPEN_ACTION_TYPES.includes(action.type)) {
            throw new Error(`invalid_arguments: ${params.action} needs ${params.action === "openApp" ? "a bundleId" : params.action === "openURL" ? "an http(s) url" : "a ref"}`);
          }
          const request: LauncherOpenRequest = { action: action as LauncherOpenRequest["action"] };
          const result = await host<LauncherOpenResult>("launcher.open", { ...request }, signal);
          const downgraded = result?.performed === "revealFile" && action.type === "openFile";
          return {
            content: [{ type: "text", text: `${typeof result?.status === "string" ? result.status : `Done (${action.type})`}${downgraded ? " (revealed in Finder instead of opened: executables, scripts and installers are never opened)" : ""}` }],
            details: {},
          };
        },
      });
    },
  };
}
