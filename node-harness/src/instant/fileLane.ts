import { readdir, realpath, stat } from "node:fs/promises";
import { basename } from "node:path";
import type { HostAction } from "../contracts/actions.js";
import { isAbsoluteHostPath } from "../contracts/attachments.js";
import { accepts, type InstantRequest, type VoiceMeta } from "../contracts/instant.js";
import type { FileCandidate, VisibleSource, VisibleSourceKind } from "../contracts/launcher.js";
import { SPOKEN, type AppMatcher } from "./apps.js";
import { fileOpActCard, fileOpRowsCard, MAX_LIST_ITEMS, noticeCard, type FileOpRow } from "./cards.js";
import {
  childPath, copyPlan, createPlan, defaultPathGuard, deleteAllPlan, deletePlan, movePlan, nameProblem, needsOwnConfirm, parentPath, planProblem,
  renamePlan, transferAllPlan, undoPlanOf, type FileOpPlan, type FileOpStore, type FileOpWords, type PathGuard, type PlanItem,
} from "./fileOps.js";
import { truncate } from "./format.js";
import { phraseLike, type FileCommand, type FileCommandPlace, type FileCommandSplit } from "./grammar/fileCommands.js";
import { displayName as appDisplayName } from "./learned.js";
import type { InstantBody } from "./types.js";
import { voiceMeta } from "./voice.js";
import {
  matchKey, matchVisible, VISIBLE, visibleEntry, visibleTarget, type VisibleEntry, type VisibleMatch, type VisibleSnapshot, type VisibleTarget,
} from "./visible.js";

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
 *     A said extension must be the item's ("Bericht.pdf" is never the folder "Bericht"; "Entwurf 2.1" has none); an
 *     item that differs only there is offered, never acted on. With an incomplete view a delete, move or rename of the
 *     one match is a one-row list (another item of that name may not have been read).
 *   - Delete: a directory on disk — a folder or a package — acts at once (dcg's dialog confirms `rm -r`); a file or
 *     symlink needs one Return (`confirm: true`), or a one-row list for hosts without `confirm`.
 *   - Copy/move destinations: standard folders, "hier"/"here", a visible folder, an existing `~/…` or absolute directory,
 *     each by its real path; otherwise a "where to?" list of the standard folders. Never a guess.
 *   - Close: a window noun ("das Safari-Fenster") only ever closes the take's Finder window, never quits an app.
 *   - Voice: delete, move and rename take the words as said when only they name an item ("delete Backup Now"), the
 *     spoken core otherwise; two readings that name different items act on neither (today's).
 *   - Finals decide on the shown folders as they are on disk (DESIGN7 §2): items the host did not list or no longer are
 *     there count as they are now, and a folder read whole is a complete view. A said standard folder ("lösche test in
 *     Downloads") is read the same way and decided on alone; the whole object is tried first on what the take shows.
 *     Spoken punctuation names an item too ("notes punkt txt"). Previews keep the host's capture.
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
  /** A destination folder's real path, or null when it cannot be resolved (then it is taken as named; default fs.realpath). */
  realPath?: (path: string) => Promise<string | null>;
  /** A folder's direct children as they are on disk, or null when unreadable (default listFolderOnDisk). Finals only. */
  listFolder?: (path: string) => Promise<FolderListing | null>;
}

/** A folder's children as read from disk; `complete` false when the read stopped at its cap. */
export interface FolderListing {
  items: FileCandidate[];
  complete: boolean;
}

export interface FileLaneInput {
  command: FileCommand;
  /**
   * Voice: the words as said (not the spoken core) when they read as the same op on other names ("delete Backup Now"
   * vs. the core's "delete Backup"). Delete, move and rename prefer it when it names an item.
   */
  said?: FileCommand;
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

/**
 * The destinations a said one names: none (unresolved: the lane asks "where to?"), one, or several folders of that name
 * near home (DESIGN8 A3: the lane lists them). Never a guess. Each path is the folder's real path (a symlinked
 * "~/Link" to /Applications is /Applications), so the safety rules see where the op would go.
 */
async function destinations(said: string, input: FileLaneInput, deps: FileCommandDeps): Promise<Destination[]> {
  const named = await namedDestinations(said, input, deps);
  const resolve = deps.realPath ?? ((path: string) => realpath(path).catch(() => null));
  const out: Destination[] = [];
  for (const destination of named) {
    let real: string | null;
    try {
      real = await resolve(destination.path);
    } catch {
      real = null;
    }
    const path = real ? folderPath(real) : undefined;
    out.push(path && path !== destination.path ? { ...destination, path } : destination);
  }
  return out;
}

async function namedDestinations(said: string, input: FileLaneInput, deps: FileCommandDeps): Promise<Destination[]> {
  const one = await namedDestination(said, input, deps);
  if (one) return [one];
  // A folder by name near home (finals: read from disk), "Archiv" in ~/Documents: one is it, several are listed.
  const target = visibleTarget(said.trim());
  if (!target || said.trim().startsWith("~") || said.trim().startsWith("/")) return [];
  const folders = await foldersNearHome(said.trim(), input, deps);
  return folders.map((path) => ({ path, label: quote(input.german, basename(path)) }));
}

async function namedDestination(said: string, input: FileLaneInput, deps: FileCommandDeps): Promise<Destination | null> {
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
    const folders = matchVisible(visible, { ...target, kind: "folder" }).filter((match) => match.exact && match.entry.folder && laneExact(target, match.entry));
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

/** The item as the plans see it: a package (`.rtfd`, `.key`) is a directory on disk, so `rm -r` like a folder. */
function planItem(entry: VisibleEntry): PlanItem {
  return { path: entry.item.path, isDirectory: entry.item.isDirectory || entry.item.isPackage };
}

/** A name's keys as the file lane compares them, and whether they say a file extension. */
interface NameKeys { key: string; fullKey: string; extension: boolean }

/** A numeric-only "extension" is part of the name ("Entwurf 2.1" is not "Entwurf 2" plus ".1"); any other one is said. */
function nameKeys(key: string, fullKey: string): NameKeys {
  if (fullKey === key) return { key, fullKey, extension: false };
  const suffix = fullKey.startsWith(key) ? fullKey.slice(key.length) : "";
  return /^\p{N}+$/u.test(suffix) ? { key: fullKey, fullKey, extension: false } : { key, fullKey, extension: true };
}

/**
 * The item is the one named, exactly. A said extension must be the item's ("Bericht.pdf" is never the folder
 * "Bericht", "notes.txt" never "notes.md"); without one the name matches with or without the item's extension, or as
 * said with its articles and nouns. Stricter than the open lane's exact key (visible.ts), which stays as it is.
 */
function laneExact(target: VisibleTarget, entry: VisibleEntry): boolean {
  const said = nameKeys(target.key, target.fullKey);
  if (said.extension) return entry.fullKey === said.fullKey;
  const name = nameKeys(entry.key, entry.fullKey);
  return name.key === said.key || entry.fullKey === said.key
    || (target.rawKey !== undefined && (name.key === target.rawKey || entry.fullKey === target.rawKey))
    || (target.possessiveKey !== undefined && name.key === target.possessiveKey);
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
  const exact = usable.filter((match) => match.exact && laneExact(target, match.entry));
  if (exact.length === 1) return { kind: "one", matches: exact, target };
  if (exact.length > 1) return { kind: "several", matches: exact.slice(0, MAX_LIST_ITEMS), target };
  // The same name with another extension or version ("notes.md" for "notes.txt") is offered first, never acted on.
  const near = usable.filter((match) => match.exact);
  const best = usable.find((match) => !match.exact);
  const sound = best
    ? usable.filter((match) => !match.exact && match.score >= SPOKEN.offerScore && match.score >= best.score - SPOKEN.offerWindow)
    : [];
  const offers = [...near, ...sound].slice(0, VISIBLE.maxRows);
  return offers.length ? { kind: "sound", matches: offers, target } : { kind: "none", matches: [], target };
}

function incomplete(visible: VisibleSnapshot): boolean {
  return visible.truncated === true || visible.sources.some((source) => LANE_SOURCES.has(source.kind) && !source.complete);
}

// ---------------------------------------------------------------------------------------------
// The current view (DESIGN7 §2): the shown folders and a said place as they are on disk, read on finals only

const MAX_LISTED = 2_000;
/** Directory extensions macOS shows as one file (a package: `rm -r` like a folder, never browsed as one). */
const PACKAGE_EXTENSIONS: ReadonlySet<string> = new Set([
  "app", "bundle", "framework", "plugin", "kext", "rtfd", "key", "pages", "numbers", "photoslibrary", "xcodeproj", "xcworkspace",
  "playground", "logicx", "band", "fcpbundle", "imovielibrary", "musiclibrary", "aplibrary", "scptd", "workflow",
]);

/**
 * A folder's direct children: no dot names and no Finder "Icon\r", a symlink is no directory, at most 2,000 (then
 * `complete` is false). Null when the folder cannot be read. Names and paths stay as stored: they are what the ops get.
 */
export async function listFolderOnDisk(path: string): Promise<FolderListing | null> {
  let dirents;
  try {
    dirents = await readdir(path, { withFileTypes: true });
  } catch {
    return null;
  }
  const items: FileCandidate[] = [];
  for (const dirent of dirents) {
    const name = dirent.name;
    if (!name || name.startsWith(".") || name === "Icon\r") continue;
    if (items.length >= MAX_LISTED) return { items, complete: false };
    const directory = dirent.isDirectory();
    const extension = /\.([^.]+)$/u.exec(name)?.[1]?.toLowerCase();
    const isPackage = directory && extension !== undefined && PACKAGE_EXTENSIONS.has(extension);
    items.push({ token: "", name, path: childPath(path, name), isDirectory: directory, isPackage, ...(directory && !isPackage ? { contentType: "public.folder" } : {}) });
  }
  return { items, complete: true };
}

const foldName = (text: string): string => text.normalize("NFC").toLowerCase();

/**
 * `visible` with `folder`'s items as they are on disk: items the host did not list are added; listed items gone from
 * disk are dropped (only after a complete read); a complete read makes that source complete.
 */
function mergeListing(visible: VisibleSnapshot, folder: string, kind: VisibleSourceKind, listing: FolderListing): VisibleSnapshot {
  const folderKey = foldName(folder);
  const onDisk = new Map(listing.items.map((item) => [foldName(item.name), item]));
  const entries: VisibleEntry[] = [];
  const seen = new Set<string>();
  for (const entry of visible.entries) {
    if (foldName(parentPath(entry.item.path)) !== folderKey) {
      entries.push(entry);
      continue;
    }
    const key = foldName(entry.item.name);
    if (onDisk.has(key)) {
      seen.add(key);
      entries.push(entry);
    } else if (!listing.complete) {
      entries.push(entry);
    }
  }
  for (const [key, item] of onDisk) {
    if (seen.has(key)) continue;
    const entry = visibleEntry({ ...item, source: kind });
    if (entry.key) entries.push(entry);
  }
  const sources = visible.sources.map((source) => (source.kind === kind && listing.complete ? { ...source, complete: true } : source));
  return { ...visible, sources, entries };
}

/** The folder a lane source shows (the desktop's is `~/Desktop` without a path); never `/`. */
function laneFolder(source: VisibleSource, home: string): string | undefined {
  const path = source.kind === "desktop" ? folderPath(source.path) ?? childPath(home, "Desktop") : folderPath(source.path);
  return path && path !== "/" ? path : undefined;
}

/**
 * The take's view with its shown folders read from disk (a final's): a stale capture (an op or pi just changed the
 * folder, a thread's older take) or a view the host could not read whole is current and complete again. Previews keep
 * the host's view: the host never enumerates these folders itself (macOS's folder-privacy prompt), and a final file
 * command needs the same access for its op anyway.
 */
async function currentView(input: FileLaneInput, deps: FileCommandDeps): Promise<VisibleSnapshot> {
  if (input.request.phase !== "final") return input.visible;
  const list = deps.listFolder ?? listFolderOnDisk;
  let visible = input.visible;
  let lanes = 0, read = 0;
  for (const source of input.visible.sources) {
    if (!LANE_SOURCES.has(source.kind)) continue;
    lanes++;
    const folder = laneFolder(source, input.home);
    if (!folder) continue;
    const listing = await list(folder).catch(() => null);
    if (!listing) continue;
    visible = mergeListing(visible, folder, source.kind, listing);
    if (listing.complete) read++;
  }
  // Every shown folder read whole: the host's result cap no longer hides anything the lane compares.
  if (lanes > 0 && read === lanes && visible.truncated) {
    const { truncated: _truncated, ...complete } = visible;
    return complete;
  }
  return visible;
}

/** At most this many folders a name may stand for (DESIGN8 A2); more is today's. */
const MAX_PLACES = 4;
/** Where a folder named by name is looked for after the current view (direct children only). */
const NAMED_FOLDER_ROOTS = ["Desktop", "Documents", "Downloads", ""] as const;

/** Folder paths named exactly `name` among `entries` (folders only, lane-exact), in order, without repeats. */
function foldersNamed(name: string, entries: readonly VisibleEntry[]): string[] {
  const target = visibleTarget(name);
  if (!target) return [];
  return [...new Set(entries.filter((entry) => entry.folder && laneExact(target, entry)).map((entry) => entry.item.path))];
}

/**
 * Folders directly inside ~/Desktop, ~/Documents, ~/Downloads and ~ named exactly `name` (DESIGN8 A2 tier 3, A3), read
 * from disk; finals only. More than MAX_PLACES: none.
 */
async function foldersNearHome(name: string, input: FileLaneInput, deps: FileCommandDeps): Promise<string[]> {
  if (input.request.phase !== "final") return [];
  const list = deps.listFolder ?? listFolderOnDisk;
  const found: string[] = [];
  for (const dir of NAMED_FOLDER_ROOTS) {
    const listing = await list(dir ? childPath(input.home, dir) : input.home).catch(() => null);
    if (listing) found.push(...foldersNamed(name, listing.items.map((item) => visibleEntry(item))));
  }
  const unique = [...new Set(found)];
  return unique.length <= MAX_PLACES ? unique : [];
}

/**
 * The folders a said place names (DESIGN8 A2), finals only: a standard folder; else folders of that name in the
 * take's current view; else directly inside Desktop, Documents, Downloads or home. Never more than MAX_PLACES.
 */
async function placeFolders(place: string, input: FileLaneInput, deps: FileCommandDeps): Promise<string[]> {
  if (input.request.phase !== "final") return [];
  const standard = STANDARD_FOLDERS.find((folder) => folder.keys.includes(matchKey(place)));
  if (standard) return [standardDestination(standard, input.home, input.german).path];
  const shown = foldersNamed(place, input.visible.entries);
  if (shown.length) return shown.length <= MAX_PLACES ? shown : [];
  return foldersNearHome(place, input, deps);
}

/** One folder as a view of its own, read from disk; null when unreadable. */
async function folderView(folder: string, input: FileLaneInput, deps: FileCommandDeps): Promise<VisibleSnapshot | null> {
  const listing = await (deps.listFolder ?? listFolderOnDisk)(folder).catch(() => null);
  if (!listing) return null;
  const kind: VisibleSourceKind = folder === childPath(input.home, "Desktop") ? "desktop" : "finderWindow";
  const entries = listing.items.map((item) => visibleEntry({ ...item, source: kind })).filter((entry) => entry.key);
  return { supported: true, sources: [{ kind, via: "ax", complete: listing.complete, path: folder }], entries };
}

/**
 * A said place ("lösche test in Downloads", "… in Projekte") as one view of every folder it names, read from disk on
 * finals: the object resolves in all of them at once (rows say which). Null when it names none or one is unreadable.
 */
async function placeView(place: string, input: FileLaneInput, deps: FileCommandDeps): Promise<VisibleSnapshot | null> {
  const folders = await placeFolders(place, input, deps);
  if (!folders.length) return null;
  const sources: VisibleSource[] = [];
  const entries: VisibleEntry[] = [];
  for (const folder of folders) {
    const view = await folderView(folder, input, deps);
    if (!view) return null;
    sources.push(...view.sources);
    entries.push(...view.entries);
  }
  return { supported: true, sources, entries };
}

/** Spoken punctuation between name parts ("notes punkt txt" → "notes.txt", "rad unterstrich tour" → "rad_tour"). */
const SPOKEN_MARKS: readonly (readonly [RegExp, string])[] = [
  [/\s+(?:punkt|dot)\s+/giu, "."], [/\s+(?:unterstrich|underscore)\s+/giu, "_"], [/\s+(?:bindestrich|dash|hyphen)\s+/giu, "-"],
];

function spokenMarks(name: string): string {
  return SPOKEN_MARKS.reduce((text, [pattern, mark]) => text.replace(pattern, mark), name);
}

/** resolveItem, then the name with its spoken punctuation when only that names an item. */
function resolveName(name: string, input: FileLaneInput): Resolution | null {
  const first = resolveItem(name, input);
  if (first && (first.kind === "one" || first.kind === "several")) return first;
  const spelled = spokenMarks(name);
  if (spelled === name) return first;
  const second = resolveItem(spelled, input);
  return second && (second.kind === "one" || second.kind === "several") ? second : first;
}

/** An object as the grammar parsed it: its name and, when said, its standard folder. */
interface ItemRef extends FileCommandPlace {
  name: string;
}

/** A resolved object: the resolution, the view it was found in (a said place's own) and the name as compared. */
interface Resolved {
  resolution: Resolution;
  input: FileLaneInput;
  name: string;
}

/** Several named items (DESIGN8 B2), each exactly one, in the view they were found in; or the answer why not. */
type Several = { entries: VisibleEntry[]; input: FileLaneInput } | { outcome: Outcome };

/**
 * Every one of several names (in the said place, if any) as exactly one item — two names for one item count once.
 * Any name that names nothing, or more than one item, is an answer and nothing is staged (never a partial op); a view
 * that may miss items, an app's name or an unresolvable place is today's (null). `done`: the op's participle.
 */
async function resolveAll(ref: ItemRef, shown: FileLaneInput, deps: FileCommandDeps, done: { de: string; en: string }): Promise<Several | null> {
  let input = shown;
  if (ref.place) {
    const view = await placeView(ref.place, shown, deps);
    if (!view) return null;
    input = { ...shown, visible: view };
  }
  const entries: VisibleEntry[] = [];
  const absent: string[] = [];
  const twice: string[] = [];
  for (const name of ref.names ?? []) {
    const resolution = resolveName(name, input);
    if (!resolution) return null;
    if (resolution.kind === "one") {
      const entry = resolution.matches[0]!.entry;
      if (!entries.some((other) => other.item.path === entry.item.path)) entries.push(entry);
    } else if (resolution.kind === "several") {
      twice.push(name);
    } else {
      absent.push(name);
    }
  }
  const de = input.german;
  if (absent.length) {
    if (incomplete(input.visible)) return null;
    return { outcome: answer(de ? `${joinQuoted(absent, true)} gibt es hier nicht – nichts ${done.de}.`
      : `${joinQuoted(absent, false)} ${absent.length > 1 ? "aren't" : "isn't"} here — nothing was ${done.en}.`) };
  }
  if (twice.length) {
    return { outcome: answer(de ? `${joinQuoted(twice, true)} gibt es mehrmals – bitte einzeln sagen.`
      : `There's more than one ${joinQuoted(twice, false)} — please say them one at a time.`) };
  }
  return entries.length ? { entries, input } : null;
}

/**
 * Where an object resolves: with a place, the whole object on what the take shows first (an item may be called "Fotos in
 * Downloads"), then the name in that folder; without one, on what the take shows. Null: today's.
 */
async function resolveRef(ref: ItemRef, input: FileLaneInput, deps: FileCommandDeps): Promise<Resolved | null> {
  if (!ref.place) {
    const resolution = resolveName(ref.name, input);
    return resolution ? { resolution, input, name: ref.name } : null;
  }
  if (ref.whole) {
    const whole = resolveName(ref.whole, input);
    if (whole && (whole.kind === "one" || whole.kind === "several")) return { resolution: whole, input, name: ref.whole };
  }
  const view = await placeView(ref.place, input, deps);
  if (!view) return null;
  const placed = { ...input, visible: view };
  const resolution = resolveName(ref.name, placed);
  return resolution ? { resolution, input: placed, name: ref.name } : null;
}

// ---------------------------------------------------------------------------------------------
// Outcomes (decideFileCommand renders them into a body)

interface Option { plan: FileOpPlan; row: FileOpRow }

type Outcome =
  /** `confirm`: one Return first even where the op would not need it (an undo: DESIGN8 C4). */
  | { kind: "act"; option: Option; title: string; heard: string; confirm?: true }
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

/** "a, b und c" (≤ 3 names), else "a, b und 2 weitere" (DESIGN8 B4). */
function joinNames(names: readonly string[], german: boolean): string {
  const and = german ? "und" : "and";
  if (names.length <= 1) return names[0] ?? "";
  if (names.length <= 3) return `${names.slice(0, -1).join(", ")} ${and} ${names.at(-1)}`;
  return `${names.slice(0, 2).join(", ")} ${and} ${names.length - 2} ${german ? "weitere" : "more"}`;
}

/** Each name quoted, then joined ("„a“ und „b“"). */
function joinQuoted(names: readonly string[], german: boolean): string {
  return joinNames(names.map((name) => quote(german, name)), german);
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

/**
 * A delete, move or rename of the one match in an incomplete view (another item of that name may not have been read):
 * a one-row "which one?" list whose row must be picked, never an act.
 */
function oneRowList(input: FileLaneInput, resolution: Resolution, name: string, entry: VisibleEntry, plan: FileOpPlan): Outcome {
  if (planProblem(plan, guardOf(input))) return protectedAnswer(input, entry.item.name);
  return { kind: "list", options: [{ plan, row: itemRow(entry) }], title: whichTitle(input, resolution, name), heard: resolution.target.heard };
}

/** "lösche test": the item's folder is where the take shows it (or the said standard folder: "lösche test in Downloads"). */
async function deleteOutcome(shown: FileLaneInput, ref: ItemRef, deps: FileCommandDeps): Promise<Outcome | null> {
  const resolved = await resolveRef(ref, shown, deps);
  // "lösche a und b": the whole object first ("Fotos und Videos" may be one folder), then every name.
  if (ref.names && !(resolved && (resolved.resolution.kind === "one" || resolved.resolution.kind === "several"))) return deleteAll(shown, ref, deps);
  if (!resolved) return null;
  const { resolution, input, name } = resolved;
  const plan = (entry: VisibleEntry): FileOpPlan => deletePlan(planItem(entry), parentPath(entry.item.path), words(input, entry.item.name));
  if (resolution.kind === "none") return missing(input, resolution, name);
  if (resolution.kind !== "one" || incomplete(input.visible)) return listOf(input, resolution, name, plan);
  const entry = resolution.matches[0]!.entry;
  const planned = plan(entry);
  return actOf(input, entry, planned, deleteTitle(shown, planned, entry.item.name, [entry.item.path]), resolution.target.heard);
}

/** The folder items are in when that is not one the take shows (a said place): the confirm says where. */
function elsewhere(shown: FileLaneInput, paths: readonly string[]): string | undefined {
  const folders = [...new Set(paths.map((path) => parentPath(path)))];
  const seen = new Set(takeFolders(shown).map(foldName));
  if (folders.length !== 1 || seen.has(foldName(folders[0]!))) return undefined;
  return basename(folders[0]!) || folders[0]!;
}

/** "„x“ endgültig löschen?" (pi-os's Return) or "Löschen: x" (dcg's dialog), with the folder when it is not in view. */
function deleteTitle(shown: FileLaneInput, plan: FileOpPlan, label: string, paths: readonly string[]): string {
  const de = shown.german;
  const where = elsewhere(shown, paths);
  if (needsOwnConfirm(plan)) {
    const at = where ? (de ? ` in ${quote(true, where)}` : ` in ${quote(false, where)}`) : "";
    return de ? `${quote(true, label)}${at} endgültig löschen?` : `Delete ${quote(false, label)}${at} permanently?`;
  }
  const at = where ? (de ? ` (in ${quote(true, where)})` : ` (in ${quote(false, where)})`) : "";
  return de ? `Löschen: ${label}${at}` : `Delete ${label}${at}`;
}

/**
 * "lösche a und b" (DESIGN8 B2/B3): every name exactly one item, then one `rm` for all of them — pi-os's one Return for
 * files only, dcg's dialog (the whole command) when any is a directory on disk. A view that may miss items: a one-row list.
 */
async function deleteAll(shown: FileLaneInput, ref: ItemRef, deps: FileCommandDeps): Promise<Outcome | null> {
  const all = await resolveAll(ref, shown, deps, { de: "gelöscht", en: "deleted" });
  if (!all || "outcome" in all) return all?.outcome ?? null;
  const { entries, input } = all;
  const de = input.german;
  const names = entries.map((entry) => entry.item.name);
  const label = joinNames(names, de);
  const first = entries[0]!;
  const plan = entries.length === 1
    ? deletePlan(planItem(first), parentPath(first.item.path), words(input, first.item.name))
    : deleteAllPlan(entries.map(planItem), parentPath(first.item.path), words(input, label));
  if (planProblem(plan, guardOf(input))) return protectedAnswer(input, label);
  const title = deleteTitle(shown, plan, label, entries.map((entry) => entry.item.path));
  const option = { plan, row: entries.length === 1 ? itemRow(first) : { name: label, subtitle: `in ${first.parent}` } };
  const heard = ref.name.toLowerCase();
  if (incomplete(input.visible)) return { kind: "list", options: [option], title, heard };
  return { kind: "act", option, title, heard };
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

/**
 * "erstelle Ordner test": in the folder the take shows, or in the said one ("… in Dokumente", "… in Projekte"); a name
 * that stands for several folders is a list with one row per folder (DESIGN8 A4).
 */
async function createOutcome(take: FileLaneInput, name: string, kind: "folder" | "file", place: string | undefined,
  deps: FileCommandDeps): Promise<Outcome | null> {
  if (place === undefined) return createIn(take, name, kind);
  const folders = await placeFolders(place, take, deps);
  if (!folders.length) return null;
  const options: Option[] = [];
  for (const folder of folders) {
    const view = await folderView(folder, take, deps);
    if (!view) return null;
    const outcome = createIn({ ...take, visible: view }, name, kind);
    if (folders.length === 1) return outcome;
    if (outcome.kind === "act") options.push({ ...outcome.option, row: { ...outcome.option.row, subtitle: tildePath(folder, take.home) } });
  }
  if (!options.length) return null;
  const de = take.german;
  return { kind: "list", options, title: de ? `In welchem Ordner ${quote(true, place)}?` : `In which ${quote(false, place)} folder?`, heard: name.toLowerCase() };
}

/** Create `name` in the folder `input` shows (its first lane source). */
function createIn(input: FileLaneInput, name: string, kind: "folder" | "file"): Outcome {
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

async function duplicateOutcome(shown: FileLaneInput, ref: ItemRef, deps: FileCommandDeps): Promise<Outcome | null> {
  const resolved = await resolveRef(ref, shown, deps);
  if (!resolved) return null;
  const { resolution, input, name } = resolved;
  if (resolution.kind === "none") return missing(input, resolution, name);
  const plan = (entry: VisibleEntry): FileOpPlan | null => {
    const copy = copyName(entry, input.visible, input.german);
    const folder = parentPath(entry.item.path);
    return copy ? copyPlan(planItem(entry), folder, copy, folder, words(input, entry.item.name, { newName: copy, duplicate: true })) : null;
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
  const item = planItem(entry);
  const same =(a: string, b: string): boolean => a.normalize("NFC").toLowerCase() === b.normalize("NFC").toLowerCase();
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

/**
 * Several items into one folder by one op (DESIGN8 B3); one item: transferPlan. Never into one of them, and never into
 * their own folder (a move there changes nothing, a copy there is a duplicate of each: one at a time).
 */
function transferOf(input: FileLaneInput, op: "copy" | "move", entries: readonly VisibleEntry[], dest: Destination): FileOpPlan | Outcome {
  if (entries.length === 1) return transferPlan(input, op, entries[0]!, dest);
  const de = input.german;
  const label = joinNames(entries.map((entry) => entry.item.name), de);
  const destKey = foldName(dest.path);
  const verb = op === "copy" ? (de ? "kopiert" : "copied") : (de ? "verschoben" : "moved");
  for (const entry of entries) {
    const path = foldName(entry.item.path);
    if (destKey === path || destKey.startsWith(`${path}/`)) {
      return answer(de ? `${quote(true, entry.item.name)} kann nicht in sich selbst ${verb} werden.` : `${quote(false, entry.item.name)} can't be ${verb} into itself.`);
    }
    if (destKey === foldName(parentPath(entry.item.path))) {
      return answer(de ? `${quote(true, entry.item.name)} liegt schon in ${dest.label}.` : `${quote(false, entry.item.name)} is already in ${dest.label}.`);
    }
  }
  return transferAllPlan(op, entries.map(planItem), dest.path, parentPath(entries[0]!.item.path), words(input, label, { dest: dest.label }));
}

/**
 * Copy or move resolved items to what was said: one destination acts (a view that may miss items makes a move a one-row
 * list); none is a "where to?" list of the standard folders (not the items' own); several folders of the said name are
 * a list of those (DESIGN8 A3). `which`: the single item's resolution, for today's titles.
 */
async function transferEntries(input: FileLaneInput, shown: FileLaneInput, op: "copy" | "move", entries: readonly VisibleEntry[], said: string,
  heard: string, deps: FileCommandDeps, which?: { resolution: Resolution; name: string }): Promise<Outcome | null> {
  const de = input.german;
  const guard = guardOf(input);
  const label = joinNames(entries.map((entry) => entry.item.name), de);
  const dests = await destinations(said, shown, deps);
  if (dests.length !== 1) {
    const standard = dests.length === 0;
    const own = new Set(entries.map((entry) => foldName(parentPath(entry.item.path))));
    const candidates = standard ? STANDARD_FOLDERS.map((folder) => standardDestination(folder, input.home, de)) : dests;
    const options: Option[] = [];
    for (const candidate of candidates) {
      if (standard && own.has(foldName(candidate.path))) continue;
      const planned = transferOf(input, op, entries, candidate);
      if (!isPlan(planned) || planProblem(planned, guard)) continue;
      const name = standard ? candidate.label : basename(candidate.path);
      options.push({ plan: planned, row: { name, subtitle: tildePath(candidate.path, input.home), contentType: "public.folder" } });
    }
    if (!options.length) return protectedAnswer(input, label);
    const verb = op === "copy" ? (de ? "kopiert" : "copied") : (de ? "verschoben" : "moved");
    const title = de ? `Wohin soll ${quote(true, label)} ${verb} werden?` : `Where should ${quote(false, label)} be ${verb}?`;
    return { kind: "list", options, title, heard };
  }
  const planned = transferOf(input, op, entries, dests[0]!);
  if (!isPlan(planned)) return planned;
  if (planProblem(planned, guard)) return protectedAnswer(input, label);
  const first = entries[0]!;
  const row = entries.length === 1 ? itemRow(first) : { name: label, subtitle: `in ${first.parent}` };
  if (op === "move" && incomplete(input.visible)) {
    const title = which ? whichTitle(input, which.resolution, which.name) : transferTitle(input, op, planned);
    return { kind: "list", options: [{ plan: planned, row }], title, heard };
  }
  return { kind: "act", option: { plan: planned, row }, title: transferTitle(input, op, planned), heard };
}

async function transferOutcome(shown: FileLaneInput, op: "copy" | "move", splits: readonly FileCommandSplit[], deps: FileCommandDeps): Promise<Outcome | null> {
  // "kopiere a und b nach Dokumente" (DESIGN8 B): the whole object first, then every name, in the last preposition's reading.
  const first = splits[0];
  if (first?.names) {
    const whole = await resolveRef(first, shown, deps);
    if (!whole || (whole.resolution.kind !== "one" && whole.resolution.kind !== "several")) {
      const done = op === "copy" ? { de: "kopiert", en: "copied" } : { de: "verschoben", en: "moved" };
      const all = await resolveAll(first, shown, deps, done);
      if (!all || "outcome" in all) return all?.outcome ?? null;
      return transferEntries(all.input, shown, op, all.entries, first.dest, first.name.toLowerCase(), deps);
    }
  }
  // The reading whose object resolves best ("kopiere Fotos in Rom nach Archiv": the last preposition first).
  const RANK = { one: 0, several: 1, sound: 2, none: 3 } as const;
  let chosen: { split: FileCommandSplit; resolved: Resolved } | undefined;
  for (const split of splits) {
    const resolved = await resolveRef(split, shown, deps);
    if (resolved && (!chosen || RANK[resolved.resolution.kind] < RANK[chosen.resolved.resolution.kind])) chosen = { split, resolved };
  }
  if (!chosen) return null;
  const { split } = chosen;
  // The object's view (a said place's own); the destination is named from what the take shows ("hierher", a visible folder).
  const { resolution, input, name } = chosen.resolved;
  if (resolution.kind === "none") return missing(input, resolution, name);
  if (resolution.kind !== "one") {
    // "Which one?" needs one destination; asking two questions at once is pi's job.
    const dests = await destinations(split.dest, shown, deps);
    if (dests.length !== 1) return null;
    return listOf(input, resolution, name, (entry) => {
      const planned = transferPlan(input, op, entry, dests[0]!);
      return isPlan(planned) ? planned : null;
    });
  }
  return transferEntries(input, shown, op, [resolution.matches[0]!.entry], split.dest, resolution.target.heard, deps, { resolution, name });
}

async function renameOutcome(input: FileLaneInput, name: string, newName: string): Promise<Outcome | null> {
  const de = input.german;
  const resolution = resolveName(name, input);
  if (!resolution) return null;
  if (resolution.kind === "none") return missing(input, resolution, name);
  if (nameProblem(newName)) return answer(de ? `${quote(true, newName)} ist kein gültiger Name.` : `${quote(false, newName)} isn't a valid name.`, "warning");
  const plan = (entry: VisibleEntry): FileOpPlan | null => {
    if (entry.item.name.normalize("NFC").toLowerCase() === newName.normalize("NFC").toLowerCase()) return null;
    if (taken(input.visible, parentPath(entry.item.path), newName, entry.item.path)) return null;
    return renamePlan(planItem(entry), newName, parentPath(entry.item.path), words(input, entry.item.name, { newName }));
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
  if (incomplete(input.visible)) return oneRowList(input, resolution, name, entry, planned);
  const title = de ? `${quote(true, entry.item.name)} in ${quote(true, newName)} umbenennen` : `Rename ${quote(false, entry.item.name)} to ${quote(false, newName)}`;
  return actOf(input, entry, planned, title, resolution.target.heard);
}

/**
 * "schließe Downloads": the take's Finder window when it shows that folder, else an app of exactly that name, else
 * today's. A window noun ("das Safari-Fenster", "the Safari window") names a window: it never quits an app.
 */
async function closeOutcome(input: FileLaneInput, command: Extract<FileCommand, { op: "close" }>): Promise<Outcome | null> {
  const de = input.german;
  const { name } = command;
  const target = visibleTarget(name);
  if (!target) return null;
  const window = input.visible.sources.find((source) => source.kind === "finderWindow");
  const folder = folderPath(window?.path);
  const contextId = input.request.contextId;
  if (window && folder && folder !== "/" && contextId) {
    const shown = basename(folder);
    const key = matchKey(shown);
    const said = nameKeys(target.key, target.fullKey);
    if (key && (said.extension ? key === said.fullKey : key === said.key || key === said.fullKey)) {
      return {
        kind: "close", action: { type: "closeFinderWindow", contextId }, heard: target.heard,
        title: de ? `Fenster ${quote(true, shown)} schließen` : `Close the ${quote(false, shown)} window`,
      };
    }
  }
  if (command.window) return window && !folder ? answer(de ? "Ich sehe nicht, welcher Ordner das ist." : "I can't tell which folder that is.") : null;
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

/** The items a reading names exactly (every reading of a move counts, each in its said place), by path. */
async function namedItems(input: FileLaneInput, command: FileCommand, deps: FileCommandDeps): Promise<Set<string>> {
  if (command.op === "undo") return new Set();
  const refs: readonly ItemRef[] = "splits" in command ? command.splits : [command.op === "delete" ? command : { name: command.name }];
  const out = new Set<string>();
  for (const ref of refs) {
    const resolution = (await resolveRef(ref, input, deps))?.resolution;
    if (resolution?.kind === "one" || resolution?.kind === "several") for (const match of resolution.matches) out.add(match.entry.item.path);
  }
  return out;
}

const SAID_FIRST: ReadonlySet<FileCommand["op"]> = new Set(["delete", "move", "rename"]);

/**
 * The reading to decide. Voice parses the spoken core ("äh, test löschen" → "test"); for a delete, move or rename the
 * words as said win when only they name an item ("delete Backup Now" with a "Backup Now" there), and when both readings
 * name items and those differ neither is acted on (null: today's handling). Both naming the same items: the core
 * ("rename Backup to Archive now" is "Archive").
 */
async function readingOf(input: FileLaneInput, deps: FileCommandDeps): Promise<FileCommand | null> {
  const { command, said } = input;
  if (!said || said.op !== command.op || !SAID_FIRST.has(command.op)) return command;
  const asSaid = await namedItems(input, said, deps);
  if (!asSaid.size) return command;
  const asCore = await namedItems(input, command, deps);
  if (!asCore.size) return said;
  return asCore.size === asSaid.size && [...asCore].every((path) => asSaid.has(path)) ? command : null;
}

async function outcomeOf(input: FileLaneInput, deps: FileCommandDeps): Promise<Outcome | null> {
  const command = await readingOf(input, deps);
  if (!command) return null;
  switch (command.op) {
    case "delete": return deleteOutcome(input, command, deps);
    case "create": return createOutcome(input, command.name, command.kind, command.place, deps);
    case "duplicate": return duplicateOutcome(input, command, deps);
    case "copy":
    case "move": return transferOutcome(input, command.op, command.splits, deps);
    case "rename": return renameOutcome(input, command.name, command.newName);
    case "close": return closeOutcome(input, command);
    case "undo": return undoOutcome(input, deps);
  }
}

/**
 * "rückgängig" (DESIGN8 C): the last op pi-os ran to done (≤ 3 minutes), undone behind one Return — always, whatever the
 * undo itself is. Nothing to undo: today's (the word stays the app's). A delete: an answer (there is no trash). Finals
 * only: the journal's items are read for their identity.
 */
async function undoOutcome(input: FileLaneInput, deps: FileCommandDeps): Promise<Outcome | null> {
  if (input.request.phase !== "final") return null;
  const done = deps.store.lastDone();
  if (!done) return null;
  const de = input.german;
  const undo = await undoPlanOf(done, de, deps.store.lstat);
  if ("why" in undo) {
    if (undo.why === "delete") return answer(de ? "Löschen kann pi-os nicht rückgängig machen." : "pi-os can't undo a delete.");
    if (undo.why === "changed") return answer(de ? "Das hat sich inzwischen geändert – nichts rückgängig gemacht." : "That changed in the meantime — nothing was undone.");
    return null;
  }
  const { plan } = undo;
  if (planProblem(plan, guardOf(input))) return protectedAnswer(input, plan.words.name);
  const name = quote(de, plan.words.name);
  const title = (() => {
    switch (done.plan.kind) {
      case "rename": return de ? `${name} wieder in ${quote(true, plan.words.newName ?? "")} umbenennen?` : `Rename ${name} back to ${quote(false, plan.words.newName ?? "")}?`;
      case "move": return de ? `${name} zurück nach ${plan.words.dest ?? ""} verschieben?` : `Move ${name} back to ${plan.words.dest ?? ""}?`;
      case "copy": return de ? `Kopie ${name} wieder löschen?` : `Delete the copy ${name} again?`;
      default: return de ? `${done.plan.targetDir ? "Neuen Ordner" : "Neue Datei"} ${name} wieder entfernen?` : `Remove the new ${done.plan.targetDir ? "folder" : "file"} ${name} again?`;
    }
  })();
  const where = plan.source ?? plan.entries?.[0]?.source ?? "";
  return {
    kind: "act", title, heard: de ? "rückgängig" : "undo", confirm: true,
    option: { plan, row: { name: plan.words.name, subtitle: `in ${basename(parentPath(where)) || "/"}` } },
  };
}

// ---------------------------------------------------------------------------------------------
// Rendering

/** The folders the take shows (its desktop and Finder window), as paths. */
function takeFolders(input: FileLaneInput): string[] {
  return [...new Set(input.visible.sources.flatMap((source) => {
    if (!LANE_SOURCES.has(source.kind)) return [];
    const folder = laneFolder(source, input.home);
    return folder ? [folder] : [];
  }))];
}

/**
 * Every op carries the folders the take shows, so the safety rules keep them (and their ancestors) out of reach even
 * when the op runs in a said place ("lösche Projekte in Dokumente" while the window shows Dokumente/Projekte/2026):
 * a refused act is the protected answer, refused rows are dropped.
 */
function withShownFolders(outcome: Outcome, input: FileLaneInput): Outcome | null {
  const shown = takeFolders(input);
  if (!shown.length || (outcome.kind !== "act" && outcome.kind !== "list")) return outcome;
  const guard = guardOf(input);
  const protect = (option: Option): Option | null => {
    // An undo keeps the folders its op protected, too.
    const plan = { ...option.plan, shown: [...new Set([...(option.plan.shown ?? []), ...shown])] };
    return planProblem(plan, guard) ? null : { ...option, plan };
  };
  if (outcome.kind === "act") {
    const option = protect(outcome.option);
    return option ? { ...outcome, option } : protectedAnswer(input, outcome.option.plan.words.name);
  }
  const options = outcome.options.map(protect).filter((option): option is Option => option !== null);
  return options.length ? { ...outcome, options } : protectedAnswer(input, outcome.options[0]?.plan.words.name ?? "");
}

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
  // Every file command, undo included, needs the desktop or a Finder window in front (an "undo" typed in an app is the
  // app's).
  if (!laneVisible(input.visible)) return null;
  const guarded = deps.guard && !input.guard ? { ...input, guard: deps.guard } : input;
  // A final decides on the shown folders as they are now (DESIGN7 §2a); previews on the host's capture. A close or an
  // undo reads no folder.
  const op = input.command.op;
  const visible = op === "close" || op === "undo" ? guarded.visible : await currentView(guarded, deps);
  const decided = await outcomeOf(visible === guarded.visible ? guarded : { ...guarded, visible }, deps);
  if (!decided) return null;
  const outcome = withShownFolders(decided, input);
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
      // pi-os's own Return: a delete of files only, and every undo (DESIGN8 C4).
      const own = needsOwnConfirm(outcome.option.plan) || outcome.confirm === true;
      const confirm = own || input.hold === true;
      if (confirm && !accepts(request, "confirm")) {
        // A held act without "confirm" is today's; a file delete or an undo becomes a one-row list whose row must be picked.
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
