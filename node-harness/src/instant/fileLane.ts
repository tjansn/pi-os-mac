import { stat } from "node:fs/promises";
import { basename } from "node:path";
import type { HostAction } from "../contracts/actions.js";
import { isAbsoluteHostPath } from "../contracts/attachments.js";
import { accepts, type InstantRequest, type VoiceMeta } from "../contracts/instant.js";
import type { VisibleSourceKind } from "../contracts/launcher.js";
import { SPOKEN, type AppMatcher } from "./apps.js";
import { fileOpActCard, fileOpRowsCard, MAX_LIST_ITEMS, noticeCard, type FileOpRow } from "./cards.js";
import {
  childPath, copyPlan, createPlan, defaultPathGuard, deletePlan, movePlan, nameProblem, needsOwnConfirm, parentPath, planProblem, renamePlan,
  type FileOpPlan, type FileOpStore, type FileOpWords, type PathGuard,
} from "./fileOps.js";
import { truncate } from "./format.js";
import { phraseLike, type FileCommand, type FileCommandSplit } from "./grammar/fileCommands.js";
import { displayName as appDisplayName } from "./learned.js";
import type { InstantBody } from "./types.js";
import { voiceMeta } from "./voice.js";
import { matchKey, matchVisible, VISIBLE, visibleTarget, type VisibleEntry, type VisibleMatch, type VisibleSnapshot, type VisibleTarget } from "./visible.js";

/**
 * The file-command lane (DESIGN6 §1–§3 with BUILD6): a parsed file command (grammar/fileCommands.ts) resolved against the
 * take's visible items and turned into a decision with staged operations (fileOps.ts).
 *
 *   - Active only when the server says so (`FileCommandDeps.active`: a full pi session, dcg as the bash guard, a dcg that
 *     resolves) and the take shows the desktop or a Finder window (`sources`). Otherwise, and whenever a step below says
 *     "today's", the decision is null and the dispatcher goes on exactly as before.
 *   - Exact names only for every op that names an existing item: one exact match acts, several are a "which one?" list,
 *     none exact offers sound-alikes (≥ 0.66, ≤ 3, never an act), nothing is an answer — unless the name is a generic
 *     class word, reads like a phrase, or the visible items were incomplete (today's: never claim nothing is there).
 *   - Delete: a directory on disk acts at once (dcg's dialog confirms `rm -r`); a file or symlink needs one Return
 *     (`confirm: true`), or a one-row list for hosts without `confirm`.
 *   - Copy/move destinations: standard folders, "hier"/"here", a visible folder, an existing `~/…` or absolute directory;
 *     otherwise a "where to?" list of the standard folders. Never a guess.
 *   - Previews (typing, partial) show an act's plan as an answer and stage nothing; finals stage.
 *
 * Every row binds `fileOp {opId}` only. Nothing here logs; names and paths are user content.
 */

export interface FileCommandDeps {
  /**
   * A full pi session with dcg as the bash guard and a dcg that resolves (server.ts). Read only after a file command
   * parsed, once per decision; false or a throw: the lane is off.
   */
  active(): boolean;
  /** Where staged ops wait for POST /fileops/run. */
  store: FileOpStore;
  /** Safety rules (default: the dispatcher's home and the user's temp folder). */
  guard?: PathGuard;
  /** An existing directory (`~/…` and absolute destinations; default fs.stat). */
  isDirectory?: (path: string) => Promise<boolean>;
}

export interface FileLaneInput {
  command: FileCommand;
  request: InstantRequest;
  visible: VisibleSnapshot;
  german: boolean;
  home: string;
  /** Voice finals: the words as heard (an answer's subtitle) and the deciding recognizer (`voice.source`). */
  voice?: { text: string; source?: string };
  /** Every act needs one Return (a lone Phase A peer below the confidence threshold). */
  hold?: boolean;
  isWord: (word: string) => boolean;
  apps: () => Promise<AppMatcher | null>;
  nowMs: number;
  /** Safety rules (default: `home` and the user's temp folder). */
  guard?: PathGuard;
}

const LANE_SOURCES: ReadonlySet<VisibleSourceKind> = new Set(["desktop", "finderWindow"]);

/** The take shows the desktop or a Finder window (the lane's precondition besides `active`). */
export function laneVisible(visible: VisibleSnapshot): boolean {
  return visible.sources.some((source) => LANE_SOURCES.has(source.kind));
}

// ---------------------------------------------------------------------------------------------
// Copy (titles and answers; the take's language)

function quote(german: boolean, text: string): string {
  const shown = truncate(text, 80);
  return german ? `„${shown}“` : `“${shown}”`;
}

const NOUN_WORDS = "folder|ordner|directory|verzeichnis|file|datei|document|dokument";
const DISPLAY_LEAD = new RegExp(`^(?:(?:the|my|den|die|das|der|dem|mein|meine|meinen|meinem)\\s+)?(?:(?:${NOUN_WORDS})(?:\\s+(?:called|named|namens|mit dem namen))?\\s+)?`, "iu");
const DISPLAY_TAIL = new RegExp(`(?:[\\s-]+(?:${NOUN_WORDS}))?(?:\\s+(?:on|from|in) (?:the|my) desktop|\\s+(?:auf dem|auf meinem|vom|im) (?:schreibtisch|desktop))?$`, "iu");

/** The name as said without articles, folder/file nouns and a desktop place ("den Ordner Radfotos" → "Radfotos"). */
export function saidName(name: string): string {
  const lead = DISPLAY_LEAD.exec(name)?.[0].length ?? 0;
  const rest = name.slice(lead).replace(DISPLAY_TAIL, "").trim();
  return rest || name;
}

interface Place { de: string; en: string }

/** Where the take looks, for "nothing called …": the desktop, a Finder window's folder, or "here". */
function placeOf(visible: VisibleSnapshot): Place {
  const window = visible.sources.find((source) => source.kind === "finderWindow");
  const desktop = visible.sources.find((source) => source.kind === "desktop");
  if (window && !desktop && window.path && window.path !== "/") {
    const folder = basename(window.path);
    return { de: `In ${quote(true, folder)}`, en: `in ${quote(false, folder)}` };
  }
  if (desktop && !window) return { de: "Auf dem Schreibtisch", en: "on the Desktop" };
  return { de: "Hier", en: "here" };
}

// ---------------------------------------------------------------------------------------------
// Shown folders and destinations

/** A source path as Node uses it: absolute and normalized (a trailing "/" off), else unknown. */
function folderPath(path: string | undefined): string | undefined {
  if (path === undefined) return undefined;
  if (path === "/") return "/";
  const trimmed = path.replace(/\/+$/u, "");
  return isAbsoluteHostPath(trimmed) ? trimmed : undefined;
}

/** The folder the take shows: the Finder window's (known only with `path`), else the desktop's (`~/Desktop` without one). */
function shownFolder(visible: VisibleSnapshot, home: string): { path?: string; window: boolean } {
  const window = visible.sources.find((source) => source.kind === "finderWindow");
  if (window) {
    const path = folderPath(window.path);
    return path ? { path, window: true } : { window: true };
  }
  const desktop = visible.sources.find((source) => source.kind === "desktop");
  const path = folderPath(desktop?.path) ?? childPath(home, "Desktop");
  return { path, window: false };
}

/** "~/Documents" for a path in the home folder (display only). */
function tildePath(path: string, home: string): string {
  if (path === home) return "~";
  return path.startsWith(`${home}/`) ? `~${path.slice(home.length)}` : path;
}

interface StandardFolder { dir: string; de: string; en: string; keys: readonly string[] }

/** Standard destinations by EN/DE name (DESIGN6 §3); `dir` "" is the home folder itself. */
const STANDARD_FOLDERS: readonly StandardFolder[] = [
  { dir: "Desktop", de: "Schreibtisch", en: "Desktop", keys: ["schreibtisch", "desktop"] },
  { dir: "Documents", de: "Dokumente", en: "Documents", keys: ["dokumente", "documents", "dokumenten"] },
  { dir: "Downloads", de: "Downloads", en: "Downloads", keys: ["downloads", "download"] },
  { dir: "Pictures", de: "Bilder", en: "Pictures", keys: ["bilder", "pictures"] },
  { dir: "Music", de: "Musik", en: "Music", keys: ["musik", "music"] },
  { dir: "Movies", de: "Filme", en: "Movies", keys: ["filme", "movies"] },
  { dir: "", de: "Benutzerordner", en: "Home", keys: ["benutzerordner", "home", "homeordner", "privatordner"] },
];

interface Destination {
  path: string;
  /** As titles and lines show it: a standard folder's name bare, any other folder quoted. */
  label: string;
}

const HERE = /^(?:hier|hierher|hierhin|here|over here)$/iu;

function standardDestination(folder: StandardFolder, home: string, german: boolean): Destination {
  return { path: folder.dir ? childPath(home, folder.dir) : home, label: german ? folder.de : folder.en };
}

/** The destination as said, or null (unresolved: the lane asks "where to?"). Never a guess. */
async function destination(said: string, input: FileLaneInput, deps: FileCommandDeps): Promise<Destination | null> {
  const text = said.trim();
  if (!text) return null;
  const { german, home, visible } = input;
  if (HERE.test(text)) {
    const shown = shownFolder(visible, home).path;
    if (!shown) return null;
    const standard = STANDARD_FOLDERS.find((folder) => standardDestination(folder, home, german).path === shown);
    return { path: shown, label: standard ? (german ? standard.de : standard.en) : quote(german, basename(shown) || shown) };
  }
  if (text.startsWith("~/") || text.startsWith("/")) {
    const path = folderPath(text.startsWith("~/") ? childPath(home, text.slice(2)) : text);
    const isDirectory = deps.isDirectory ?? ((candidate: string) => stat(candidate).then((info) => info.isDirectory(), () => false));
    if (path && path !== "/" && await isDirectory(path)) return { path, label: quote(german, basename(path)) };
    return null;
  }
  const target = visibleTarget(text);
  const key = target?.key ?? matchKey(text);
  const standard = STANDARD_FOLDERS.find((folder) => folder.keys.includes(key));
  if (standard) return standardDestination(standard, home, german);
  if (target) {
    const folders = matchVisible(visible, { ...target, kind: "folder" }).filter((match) => match.exact && match.entry.folder);
    const folder = folders[0];
    if (folder) return { path: folder.entry.item.path, label: quote(german, folder.entry.item.name) };
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Resolving the named item

type Resolution =
  | { kind: "one" | "several" | "sound"; matches: VisibleMatch[]; target: VisibleTarget }
  | { kind: "none"; matches: []; target: VisibleTarget };

/** An app's own bundle: never a file-command target (deleting an app is uninstalling: today's handling). */
function isAppBundle(entry: VisibleEntry): boolean {
  return entry.item.isPackage && /\.app$/iu.test(entry.item.path);
}

/**
 * Generic class words ("Fotos", "PDFs", "Downloads", "the zip files"): without an exact item the name means a set of
 * files (today's), never "nothing called …".
 */
const GENERIC_KEYS: ReadonlySet<string> = new Set([
  "file", "files", "datei", "dateien", "folder", "folders", "ordner", "verzeichnis", "verzeichnisse", "document", "documents", "dokument",
  "dokumente", "foto", "fotos", "photo", "photos", "bild", "bilder", "picture", "pictures", "image", "images", "screenshot", "screenshots",
  "bildschirmfoto", "bildschirmfotos", "video", "videos", "film", "filme", "movie", "movies", "download", "downloads", "pdf", "pdfs", "zip",
  "zips", "musik", "music", "song", "songs", "app", "apps", "programm", "programme", "sachen", "stuff", "zeug",
]);

function resolveItem(name: string, input: FileLaneInput): Resolution | null {
  const target = visibleTarget(name);
  if (!target) return null;
  const heardIsWord = target.words.length === 1 && input.isWord(target.words[0]!);
  const all = matchVisible(input.visible, target, { german: input.german, heardIsWord, sound: true });
  const usable = all.filter((match) => !isAppBundle(match.entry));
  // An app's exact name: deleting, moving or renaming it is today's (uninstall) handling.
  if (all.some((match) => match.exact) && !usable.some((match) => match.exact)) return null;
  let exact = usable.filter((match) => match.exact);
  // A said extension narrows ("test.txt" is not the folder "test").
  if (target.fullKey !== target.key) {
    const said = exact.filter((match) => match.entry.fullKey === target.fullKey);
    if (said.length) exact = said;
  }
  if (exact.length === 1) return { kind: "one", matches: exact, target };
  if (exact.length > 1) return { kind: "several", matches: exact.slice(0, MAX_LIST_ITEMS), target };
  const best = usable.find((match) => !match.exact);
  const sound = best
    ? usable.filter((match) => !match.exact && match.score >= SPOKEN.offerScore && match.score >= best.score - SPOKEN.offerWindow).slice(0, VISIBLE.maxRows)
    : [];
  return sound.length ? { kind: "sound", matches: sound, target } : { kind: "none", matches: [], target };
}

function incomplete(visible: VisibleSnapshot): boolean {
  return visible.truncated === true || visible.sources.some((source) => LANE_SOURCES.has(source.kind) && !source.complete);
}

// ---------------------------------------------------------------------------------------------
// Outcomes (decideFileCommand renders them into a body)

interface Option { plan: FileOpPlan; row: FileOpRow }

type Outcome =
  | { kind: "act"; option: Option; title: string; heard: string }
  | { kind: "list"; options: Option[]; title: string; heard: string }
  | { kind: "answer"; title: string; tone: "info" | "warning" }
  | { kind: "close"; action: HostAction; title: string; heard: string };

function itemRow(entry: VisibleEntry): FileOpRow {
  return { name: entry.item.name, subtitle: `in ${entry.parent}`, ...(entry.item.contentType ? { contentType: entry.item.contentType } : {}) };
}

function words(input: FileLaneInput, name: string, extra: Partial<FileOpWords> = {}): FileOpWords {
  return { german: input.german, name, ...extra };
}

function answer(title: string, tone: "info" | "warning" = "info"): Outcome {
  return { kind: "answer", title, tone };
}

function notFound(input: FileLaneInput, name: string): Outcome {
  const place = placeOf(input.visible);
  const said = saidName(name);
  return answer(input.german ? `${place.de} gibt es nichts namens ${quote(true, said)}.` : `There's nothing called ${quote(false, said)} ${place.en}.`);
}

function protectedAnswer(input: FileLaneInput, name: string): Outcome {
  return answer(input.german ? `pi-os rührt ${quote(true, name)} nicht an.` : `pi-os won't touch ${quote(false, name)}.`, "warning");
}

function whichTitle(input: FileLaneInput, resolution: Resolution, name: string): string {
  const said = saidName(name);
  return resolution.kind === "sound"
    ? (input.german ? `${quote(true, said)} nicht gefunden – meintest du …?` : `Couldn't find ${quote(false, said)} — did you mean…?`)
    : (input.german ? `Welches ${quote(true, said)} meinst du?` : `Which ${quote(false, said)} do you mean?`);
}

/**
 * The items' options for a "which one?" / "did you mean …?" list. Nothing left to offer: a protected answer when a
 * safety rule refused them, else null (today's).
 */
function listOf(input: FileLaneInput, resolution: Resolution, name: string, plan: (entry: VisibleEntry) => FileOpPlan | null): Outcome | null {
  const guard = guardOf(input);
  const options: Option[] = [];
  let refused: string | undefined;
  for (const match of resolution.matches) {
    const planned = plan(match.entry);
    if (!planned) continue;
    if (planProblem(planned, guard)) refused ??= match.entry.item.name;
    else options.push({ plan: planned, row: itemRow(match.entry) });
  }
  if (!options.length) return refused !== undefined ? protectedAnswer(input, refused) : null;
  return { kind: "list", options, title: whichTitle(input, resolution, name), heard: resolution.target.heard };
}

let laneGuard: { home: string; guard: PathGuard } | undefined;

function guardOf(input: FileLaneInput): PathGuard {
  if (input.guard) return input.guard;
  if (laneGuard?.home !== input.home) laneGuard = { home: input.home, guard: defaultPathGuard(input.home) };
  return laneGuard.guard;
}

/** The single-item act, or a protected answer when a safety rule refuses its paths. */
function actOf(input: FileLaneInput, entry: VisibleEntry, plan: FileOpPlan, title: string, heard: string): Outcome {
  if (planProblem(plan, guardOf(input))) return protectedAnswer(input, entry.item.name);
  return { kind: "act", option: { plan, row: itemRow(entry) }, title, heard };
}

/** "lösche test": the item's folder is where the take shows it. */
async function deleteOutcome(input: FileLaneInput, name: string): Promise<Outcome | null> {
  const resolution = resolveItem(name, input);
  if (!resolution) return null;
  const plan = (entry: VisibleEntry): FileOpPlan => deletePlan({ path: entry.item.path, isDirectory: entry.item.isDirectory }, parentPath(entry.item.path),
    words(input, entry.item.name));
  if (resolution.kind === "none") return missing(input, resolution, name);
  if (resolution.kind !== "one") return listOf(input, resolution, name, plan);
  const entry = resolution.matches[0]!.entry;
  const planned = plan(entry);
  const title = needsOwnConfirm(planned)
    ? (input.german ? `${quote(true, entry.item.name)} endgültig löschen?` : `Delete ${quote(false, entry.item.name)} permanently?`)
    : (input.german ? `Löschen: ${entry.item.name}` : `Delete ${entry.item.name}`);
  return actOf(input, entry, planned, title, resolution.target.heard);
}

/**
 * Nothing matched: "nothing called …", unless that could be wrong — a class word, a phrase, an incomplete view, or an
 * installed app's exact name ("lösche Slack" is uninstalling: today's handling).
 */
async function missing(input: FileLaneInput, resolution: Resolution, name: string): Promise<Outcome | null> {
  const target = resolution.target;
  if (GENERIC_KEYS.has(target.key) || target.words.some((word) => GENERIC_KEYS.has(word))) return null;
  if (phraseLike(saidName(name)) || incomplete(input.visible)) return null;
  const matcher = await input.apps();
  if ((matcher?.match(saidName(name), 8, input.nowMs) ?? []).some((match) => match.score >= 1)) return null;
  return notFound(input, name);
}

function createOutcome(input: FileLaneInput, name: string, kind: "folder" | "file"): Outcome {
  const de = input.german;
  const shown = shownFolder(input.visible, input.home);
  if (!shown.path) return answer(de ? "Ich sehe nicht, welcher Ordner das ist." : "I can't tell which folder that is.");
  if (nameProblem(name)) return answer(de ? `${quote(true, name)} ist kein gültiger Name.` : `${quote(false, name)} isn't a valid name.`, "warning");
  if (taken(input.visible, shown.path, name)) return answer(de ? `${quote(true, name)} gibt es hier schon.` : `${quote(false, name)} already exists here.`);
  const folder = kind === "folder";
  const plan = createPlan(shown.path, name, folder, words(input, name));
  if (planProblem(plan, guardOf(input))) return protectedAnswer(input, name);
  const title = de ? `${folder ? "Ordner" : "Datei"} ${quote(true, name)} erstellen` : `Create ${folder ? "folder" : "file"} ${quote(false, name)}`;
  const where = shown.path === input.home ? "~" : basename(shown.path) || shown.path;
  return {
    kind: "act", title, heard: name.toLowerCase(),
    option: { plan, row: { name, subtitle: `in ${where}`, ...(folder ? { contentType: "public.folder" } : {}) } },
  };
}

/** A visible item in `folder` already has `name` (case-insensitive, as APFS compares). */
function taken(visible: VisibleSnapshot, folder: string, name: string, except?: string): boolean {
  const key = name.normalize("NFC").toLowerCase();
  const folderKey = folder.normalize("NFC").toLowerCase();
  return visible.entries.some((entry) => entry.item.path !== except && parentPath(entry.item.path).normalize("NFC").toLowerCase() === folderKey
    && entry.item.name.normalize("NFC").toLowerCase() === key);
}

const EXTENSION = /\.[\p{L}\p{N}]{1,8}$/u;

/** "test Kopie", "notes Kopie.txt", then "… Kopie 2" (Finder's naming), free among the folder's visible names. */
function copyName(entry: VisibleEntry, visible: VisibleSnapshot, german: boolean): string | null {
  const name = entry.item.name;
  const extension = entry.folder ? undefined : EXTENSION.exec(name);
  const ext = extension && extension.index > 0 ? extension[0] : "";
  const base = ext ? name.slice(0, -ext.length) : name;
  const word = german ? "Kopie" : "copy";
  const folder = parentPath(entry.item.path);
  for (let i = 1; i < 100; i++) {
    const candidate = `${base} ${word}${i > 1 ? ` ${i}` : ""}${ext}`;
    if (!taken(visible, folder, candidate) && !nameProblem(candidate)) return candidate;
  }
  return null;
}

async function duplicateOutcome(input: FileLaneInput, name: string): Promise<Outcome | null> {
  const resolution = resolveItem(name, input);
  if (!resolution) return null;
  if (resolution.kind === "none") return missing(input, resolution, name);
  const plan = (entry: VisibleEntry): FileOpPlan | null => {
    const copy = copyName(entry, input.visible, input.german);
    const folder = parentPath(entry.item.path);
    return copy ? copyPlan({ path: entry.item.path, isDirectory: entry.item.isDirectory }, folder, copy, folder,
      words(input, entry.item.name, { newName: copy, duplicate: true })) : null;
  };
  if (resolution.kind !== "one") return listOf(input, resolution, name, plan);
  const entry = resolution.matches[0]!.entry;
  const planned = plan(entry);
  if (!planned) return null;
  const title = input.german ? `${quote(true, entry.item.name)} duplizieren` : `Duplicate ${quote(false, entry.item.name)}`;
  return actOf(input, entry, planned, title, resolution.target.heard);
}

/** Copy or move one item to a destination; a copy into its own folder is a duplicate. */
function transferPlan(input: FileLaneInput, op: "copy" | "move", entry: VisibleEntry, dest: Destination): FileOpPlan | Outcome {
  const de = input.german;
  const folder = parentPath(entry.item.path);
  const item = { path: entry.item.path, isDirectory: entry.item.isDirectory };
  const same = (a: string, b: string): boolean => a.normalize("NFC").toLowerCase() === b.normalize("NFC").toLowerCase();
  if (same(dest.path, entry.item.path) || dest.path.normalize("NFC").toLowerCase().startsWith(`${entry.item.path.normalize("NFC").toLowerCase()}/`)) {
    const verb = op === "copy" ? (de ? "kopiert" : "copied") : (de ? "verschoben" : "moved");
    return answer(de ? `${quote(true, entry.item.name)} kann nicht in sich selbst ${verb} werden.` : `${quote(false, entry.item.name)} can't be ${verb} into itself.`);
  }
  if (same(dest.path, folder)) {
    if (op === "move") return answer(de ? `${quote(true, entry.item.name)} liegt schon in ${dest.label}.` : `${quote(false, entry.item.name)} is already in ${dest.label}.`);
    const copy = copyName(entry, input.visible, de);
    if (!copy) return answer(de ? `Für ${quote(true, entry.item.name)} finde ich keinen freien Namen.` : `There's no free name for a copy of ${quote(false, entry.item.name)}.`);
    return copyPlan(item, folder, copy, folder, words(input, entry.item.name, { newName: copy, duplicate: true }));
  }
  if (op === "move") return movePlan(item, dest.path, folder, words(input, entry.item.name, { dest: dest.label }));
  return copyPlan(item, dest.path, basename(entry.item.path), folder, words(input, entry.item.name, { dest: dest.label }));
}

function isPlan(value: FileOpPlan | Outcome): value is FileOpPlan {
  return "argv" in value;
}

function transferTitle(input: FileLaneInput, op: "copy" | "move", plan: FileOpPlan): string {
  const de = input.german;
  const name = plan.words.name;
  if (plan.words.duplicate) return de ? `${quote(true, name)} duplizieren` : `Duplicate ${quote(false, name)}`;
  const dest = plan.words.dest ?? "";
  if (op === "copy") return de ? `${quote(true, name)} nach ${dest} kopieren` : `Copy ${quote(false, name)} to ${dest}`;
  return de ? `${quote(true, name)} nach ${dest} verschieben` : `Move ${quote(false, name)} to ${dest}`;
}

async function transferOutcome(input: FileLaneInput, op: "copy" | "move", splits: readonly FileCommandSplit[], deps: FileCommandDeps): Promise<Outcome | null> {
  // The reading whose object resolves best ("kopiere Fotos in Rom nach Archiv": the last preposition first).
  const RANK = { one: 0, several: 1, sound: 2, none: 3 } as const;
  let chosen: { split: FileCommandSplit; resolution: Resolution } | undefined;
  for (const split of splits) {
    const resolution = resolveItem(split.name, input);
    if (resolution && (!chosen || RANK[resolution.kind] < RANK[chosen.resolution.kind])) chosen = { split, resolution };
  }
  if (!chosen) return null;
  const { split, resolution } = chosen;
  if (resolution.kind === "none") return missing(input, resolution, split.name);
  const dest = await destination(split.dest, input, deps);
  const guard = guardOf(input);
  if (resolution.kind !== "one") {
    // "Which one?" needs a destination; asking two questions at once is pi's job.
    if (!dest) return null;
    return listOf(input, resolution, split.name, (entry) => {
      const planned = transferPlan(input, op, entry, dest);
      return isPlan(planned) ? planned : null;
    });
  }
  const entry = resolution.matches[0]!.entry;
  if (!dest) {
    // "Wohin soll „test“ kopiert werden?": the standard folders (not the item's own folder) as rows.
    const folder = parentPath(entry.item.path).normalize("NFC").toLowerCase();
    const options: Option[] = [];
    for (const standard of STANDARD_FOLDERS) {
      const candidate = standardDestination(standard, input.home, input.german);
      if (candidate.path.normalize("NFC").toLowerCase() === folder) continue;
      const planned = transferPlan(input, op, entry, candidate);
      if (!isPlan(planned) || planProblem(planned, guard)) continue;
      options.push({ plan: planned, row: { name: candidate.label, subtitle: tildePath(candidate.path, input.home), contentType: "public.folder" } });
    }
    if (!options.length) return protectedAnswer(input, entry.item.name);
    const de = input.german;
    const verb = op === "copy" ? (de ? "kopiert" : "copied") : (de ? "verschoben" : "moved");
    const title = de ? `Wohin soll ${quote(true, entry.item.name)} ${verb} werden?` : `Where should ${quote(false, entry.item.name)} be ${verb}?`;
    return { kind: "list", options, title, heard: resolution.target.heard };
  }
  const planned = transferPlan(input, op, entry, dest);
  if (!isPlan(planned)) return planned;
  return actOf(input, entry, planned, transferTitle(input, op, planned), resolution.target.heard);
}

async function renameOutcome(input: FileLaneInput, name: string, newName: string): Promise<Outcome | null> {
  const de = input.german;
  const resolution = resolveItem(name, input);
  if (!resolution) return null;
  if (resolution.kind === "none") return missing(input, resolution, name);
  if (nameProblem(newName)) return answer(de ? `${quote(true, newName)} ist kein gültiger Name.` : `${quote(false, newName)} isn't a valid name.`, "warning");
  const plan = (entry: VisibleEntry): FileOpPlan | null => {
    if (entry.item.name.normalize("NFC").toLowerCase() === newName.normalize("NFC").toLowerCase()) return null;
    if (taken(input.visible, parentPath(entry.item.path), newName, entry.item.path)) return null;
    return renamePlan({ path: entry.item.path, isDirectory: entry.item.isDirectory }, newName, parentPath(entry.item.path),
      words(input, entry.item.name, { newName }));
  };
  if (resolution.kind !== "one") return listOf(input, resolution, name, plan);
  const entry = resolution.matches[0]!.entry;
  if (entry.item.name.normalize("NFC").toLowerCase() === newName.normalize("NFC").toLowerCase()) {
    return answer(de ? `${quote(true, entry.item.name)} heißt schon so.` : `${quote(false, entry.item.name)} already has that name.`);
  }
  if (taken(input.visible, parentPath(entry.item.path), newName, entry.item.path)) {
    return answer(de ? `${quote(true, newName)} gibt es hier schon.` : `${quote(false, newName)} already exists here.`);
  }
  const planned = plan(entry)!;
  const title = de ? `${quote(true, entry.item.name)} in ${quote(true, newName)} umbenennen` : `Rename ${quote(false, entry.item.name)} to ${quote(false, newName)}`;
  return actOf(input, entry, planned, title, resolution.target.heard);
}

/** "schließe Downloads": the take's Finder window when it shows that folder, else an app of exactly that name, else today's. */
async function closeOutcome(input: FileLaneInput, name: string): Promise<Outcome | null> {
  const de = input.german;
  const target = visibleTarget(name);
  if (!target) return null;
  const window = input.visible.sources.find((source) => source.kind === "finderWindow");
  const folder = folderPath(window?.path);
  const contextId = input.request.contextId;
  if (window && folder && folder !== "/" && contextId) {
    const shown = basename(folder);
    const key = matchKey(shown);
    if (key && (key === target.key || key === target.fullKey)) {
      return {
        kind: "close", action: { type: "closeFinderWindow", contextId }, heard: target.heard,
        title: de ? `Fenster ${quote(true, shown)} schließen` : `Close the ${quote(false, shown)} window`,
      };
    }
  }
  const matcher = await input.apps();
  const exact = (matcher?.match(saidName(name), 8, input.nowMs) ?? []).filter((match) => match.score >= 1);
  const apps = [...new Map(exact.map((match) => [match.app.bundleId, match.app])).values()];
  if (apps.length === 1) {
    const app = apps[0]!;
    const label = appDisplayName(app);
    return { kind: "close", action: { type: "quitApp", bundleId: app.bundleId }, heard: target.heard, title: de ? `${label} beenden` : `Quit ${label}` };
  }
  if (window && !folder && !apps.length) return answer(de ? "Ich sehe nicht, welcher Ordner das ist." : "I can't tell which folder that is.");
  return null;
}

async function outcomeOf(input: FileLaneInput, deps: FileCommandDeps): Promise<Outcome | null> {
  const command = input.command;
  switch (command.op) {
    case "delete": return deleteOutcome(input, command.name);
    case "create": return createOutcome(input, command.name, command.kind);
    case "duplicate": return duplicateOutcome(input, command.name);
    case "copy":
    case "move": return transferOutcome(input, command.op, command.splits, deps);
    case "rename": return renameOutcome(input, command.name, command.newName);
    case "close": return closeOutcome(input, command.name);
  }
}

// ---------------------------------------------------------------------------------------------
// Rendering

function metaOf(input: FileLaneInput, heard: string): { voice?: VoiceMeta } {
  if (!input.voice) return {};
  const meta = voiceMeta({ heard, ...(input.voice.source ? { source: input.voice.source } : {}), via: "file" });
  return meta ? { voice: meta } : {};
}

/**
 * The decision for a parsed file command on what the take shows, or null for today's handling. Finals stage their ops
 * in `deps.store` (bound to the request's takeId and contextId); typing and partial previews only show an act's plan.
 */
export async function decideFileCommand(input: FileLaneInput, deps: FileCommandDeps): Promise<InstantBody | null> {
  if (!laneVisible(input.visible)) return null;
  const outcome = await outcomeOf(deps.guard && !input.guard ? { ...input, guard: deps.guard } : input, deps);
  if (!outcome) return null;
  const request = input.request;
  const final = request.phase === "final";
  if (!final) {
    // Previews show the plan of an act only, and never stage anything.
    if (outcome.kind !== "act" && outcome.kind !== "close") return null;
    return { decision: "answer", intent: outcome.kind === "act" ? "file_op" : "close", title: outcome.title, card: noticeCard("info", outcome.title, outcome.title) };
  }
  const binding = { ...(request.takeId ? { takeId: request.takeId } : {}), ...(request.contextId ? { contextId: request.contextId } : {}) };
  switch (outcome.kind) {
    case "answer": {
      const heard = input.voice ? truncate(input.voice.text, 120) : undefined;
      const subtitle = heard ? (input.german ? `Gehört: ${quote(true, heard)}` : `Heard ${quote(false, heard)}`) : undefined;
      return { decision: "answer", intent: "file_op", title: outcome.title, ...(subtitle ? { subtitle } : {}), card: noticeCard(outcome.tone, outcome.title, outcome.title) };
    }
    case "close": {
      if (input.hold && !accepts(request, "confirm")) return null;
      return { decision: "act", intent: "close", title: outcome.title, action: outcome.action, confirm: input.hold === true, ...metaOf(input, outcome.heard) };
    }
    case "list": {
      const ids = deps.store.stage(outcome.options.map((option) => option.plan), binding);
      const rows = outcome.options.map((option, index) => ({ ...option.row, opId: ids[index]! }));
      return { decision: "list", intent: "file_op", title: outcome.title, card: fileOpRowsCard(outcome.title, rows), ...metaOf(input, outcome.heard) };
    }
    case "act": {
      const own = needsOwnConfirm(outcome.option.plan);
      const confirm = own || input.hold === true;
      if (confirm && !accepts(request, "confirm")) {
        // A held act without "confirm" is today's; a file delete becomes a one-row list whose row must be picked.
        if (!own) return null;
        const [opId] = deps.store.stage([outcome.option.plan], binding);
        return {
          decision: "list", intent: "file_op", title: outcome.title, card: fileOpRowsCard(outcome.title, [{ ...outcome.option.row, opId: opId! }]),
          ...metaOf(input, outcome.heard),
        };
      }
      const [opId] = deps.store.stage([outcome.option.plan], binding);
      return {
        decision: "act", intent: "file_op", title: outcome.title, action: { type: "fileOp", opId: opId! }, confirm,
        card: fileOpActCard(outcome.title, outcome.option.row), ...metaOf(input, outcome.heard),
      };
    }
  }
}
