import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { parseHostAction } from "../contracts/actions.js";
import type { AppIndexResult, AppRecord } from "../contracts/launcher.js";
import { supportDirectory } from "../platformPaths.js";

/**
 * App matching over the host's app index (POST /tools/launcher.listApps).
 * Raycast-style: exact name/alias, prefix, whole word, initials ("vsc"),
 * word prefixes, then scattered-letter fuzzy; small boosts for frecency and
 * running apps. Built-in EN/DE aliases apply only to bundles the host lists.
 */

export type AppMatchReason = "exact" | "alias" | "prefix" | "word" | "initials" | "word-prefix" | "fuzzy";

export interface AppMatch {
  app: AppRecord;
  /** Match quality 0..1 before boosts. */
  score: number;
  /** Ranking score including frecency/running boosts. */
  rank: number;
  reason: AppMatchReason;
}

export interface FrecencyStore {
  /** 0..1 usage weight for a bundle id. */
  score(key: string, nowMs: number): number;
  record?(key: string, nowMs: number): void;
}

/** Spoken EN/DE names → bundle ids. */
export const BUILTIN_APP_ALIASES: Readonly<Record<string, readonly string[]>> = {
  "com.apple.calculator": ["rechner", "taschenrechner", "calculator", "calc"],
  "com.apple.systempreferences": ["systemeinstellungen", "systemeinstellung", "system settings", "system preferences", "systemeinstellungen app", "einstellungen", "settings", "preferences"],
  "com.apple.iCal": ["kalender", "calendar"],
  "com.apple.Notes": ["notizen", "notes"],
  "com.apple.reminders": ["erinnerungen", "reminders"],
  "com.apple.Photos": ["fotos", "photos"],
  "com.apple.Music": ["musik", "music", "apple music"],
  "com.apple.Maps": ["karten", "maps", "apple maps"],
  "com.apple.MobileSMS": ["nachrichten", "messages", "imessage"],
  "com.apple.AddressBook": ["kontakte", "contacts"],
  "com.apple.Preview": ["vorschau", "preview"],
  "com.apple.ActivityMonitor": ["aktivitätsanzeige", "activity monitor", "task manager"],
  "com.apple.finder": ["finder"],
  "com.apple.mail": ["mail", "apple mail", "e-mail", "email"],
  "com.apple.Safari": ["safari"],
  "com.apple.Terminal": ["terminal"],
  "com.apple.TextEdit": ["textedit", "text edit"],
  "com.apple.clock": ["uhr", "clock"],
  "com.apple.weather": ["wetter", "weather"],
  "com.apple.FaceTime": ["facetime"],
  "com.apple.AppStore": ["app store"],
  "com.apple.Home": ["home"],
  "com.apple.podcasts": ["podcasts"],
  "com.apple.dt.Xcode": ["xcode"],
  "com.apple.iWork.Pages": ["pages"],
  "com.apple.iWork.Numbers": ["numbers"],
  "com.apple.iWork.Keynote": ["keynote"],
  "com.google.Chrome": ["chrome", "google chrome"],
  "com.microsoft.VSCode": ["vs code", "vscode", "code", "visual studio code"],
  "com.brave.Browser": ["brave"],
  "org.mozilla.firefox": ["firefox"],
  "com.tinyspeck.slackmacgap": ["slack"],
  "com.spotify.client": ["spotify"],
  "com.figma.Desktop": ["figma"],
  "notion.id": ["notion"],
  "us.zoom.xos": ["zoom"],
  "com.microsoft.teams2": ["teams", "microsoft teams"],
  "com.microsoft.Word": ["word", "microsoft word"],
  "com.microsoft.Excel": ["excel", "microsoft excel"],
  "com.microsoft.Powerpoint": ["powerpoint", "microsoft powerpoint"],
  "com.microsoft.Outlook": ["outlook"],
  "net.whatsapp.WhatsApp": ["whatsapp"],
  "com.googlecode.iterm2": ["iterm", "iterm2"],
};

export const APP_ACT_SCORE = 0.85;
export const APP_ACT_MARGIN = 0.1;
const MIN_LIST_SCORE = 0.6;

export function foldName(text: string): string {
  return text.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ß/g, "ss").toLowerCase()
    .replace(/\.app$/, "").replace(/[^a-z0-9]+/g, " ").trim();
}

interface NameForm { text: string; words: string[]; initials: string; compact: string; alias: boolean }

interface Entry { app: AppRecord; forms: NameForm[] }

function form(text: string, alias: boolean): NameForm | null {
  const folded = foldName(text);
  if (!folded) return null;
  const words = folded.split(" ");
  return { text: folded, words, initials: words.map((w) => w[0]).join(""), compact: words.join(""), alias };
}

function isSubsequence(needle: string, haystack: string): boolean {
  let i = 0;
  for (const ch of haystack) if (ch === needle[i]) i++;
  return i === needle.length;
}

function containsWords(words: string[], query: string[]): boolean {
  for (let i = 0; i + query.length <= words.length; i++) {
    if (query.every((q, k) => words[i + k] === q)) return true;
  }
  return false;
}

function wordPrefixes(words: string[], query: string[]): boolean {
  let at = 0;
  for (const q of query) {
    while (at < words.length && !words[at]!.startsWith(q)) at++;
    if (at === words.length) return false;
    at++;
  }
  return true;
}

function scoreForm(query: string, queryWords: string[], f: NameForm): { score: number; reason: AppMatchReason } | null {
  if (f.text === query || f.compact === query.replace(/ /g, "")) return { score: 1, reason: f.alias ? "alias" : "exact" };
  if (query.length >= 2 && f.text.startsWith(query)) return { score: 0.8 + 0.1 * (query.length / f.text.length), reason: "prefix" };
  if (query.length >= 3 && containsWords(f.words, queryWords)) return { score: 0.88, reason: "word" };
  if (!query.includes(" ") && query.length >= 2 && f.words.length >= 2 && f.initials === query) return { score: 0.85, reason: "initials" };
  if (queryWords.length >= 2 && wordPrefixes(f.words, queryWords)) return { score: 0.8, reason: "word-prefix" };
  if (!query.includes(" ") && query.length >= 3 && query.length <= 16 && isSubsequence(query, f.compact)) {
    return { score: Math.min(0.75, 0.5 + 0.25 * (query.length / f.compact.length)), reason: "fuzzy" };
  }
  return null;
}

export class AppMatcher {
  private readonly entries: Entry[];

  constructor(apps: readonly AppRecord[], private readonly frecency?: FrecencyStore) {
    this.entries = apps.map((app) => {
      const names = [app.name, ...app.aliases, ...(BUILTIN_APP_ALIASES[app.bundleId] ?? []), app.path.split("/").pop() ?? ""];
      const forms: NameForm[] = [];
      const seen = new Set<string>();
      names.forEach((name, index) => {
        const f = form(name, index > 0);
        if (f && !seen.has(f.text)) {
          seen.add(f.text);
          forms.push(f);
        }
      });
      return { app, forms };
    });
  }

  get size(): number {
    return this.entries.length;
  }

  match(query: string, limit = 8, nowMs = Date.now()): AppMatch[] {
    const q = foldName(query);
    if (!q || q.length > 60) return [];
    const queryWords = q.split(" ");
    const out: AppMatch[] = [];
    for (const { app, forms } of this.entries) {
      let best: { score: number; reason: AppMatchReason } | null = null;
      for (const f of forms) {
        const scored = scoreForm(q, queryWords, f);
        if (scored && (!best || scored.score > best.score)) best = scored;
      }
      if (!best || best.score < MIN_LIST_SCORE) continue;
      const boost = Math.min(0.1, Math.max(0, this.frecency?.score(app.bundleId, nowMs) ?? 0) * 0.1) + (app.running ? 0.02 : 0);
      out.push({ app, score: best.score, rank: best.score + boost, reason: best.reason });
    }
    return out.sort((a, b) => b.rank - a.rank || a.app.name.length - b.app.name.length).slice(0, limit);
  }

  /** The single app to open without asking, or null (show a list instead). */
  static decisive(matches: readonly AppMatch[]): AppMatch | null {
    const [best, second] = matches;
    if (!best || best.score < APP_ACT_SCORE) return null;
    return !second || best.rank - second.rank >= APP_ACT_MARGIN ? best : null;
  }
}

/**
 * Caches the host app index. The host bumps `version` when apps change; the
 * matcher is rebuilt only then. Stale data is served immediately while a
 * background refresh runs, so app matching never waits on the host twice.
 */
export class AppIndexCache {
  private matcher: AppMatcher | null = null;
  private version: string | undefined;
  private fetchedAt = 0;
  private inflight: Promise<AppMatcher | null> | undefined;
  private readonly ttlMs: number;
  private readonly clock: () => number;
  private readonly frecency: FrecencyStore | undefined;

  constructor(
    private readonly listApps: (signal: AbortSignal) => Promise<AppIndexResult>,
    options: { ttlMs?: number; clock?: () => number; frecency?: FrecencyStore } = {},
  ) {
    this.ttlMs = options.ttlMs ?? 15_000;
    this.clock = options.clock ?? (() => Date.now());
    this.frecency = options.frecency;
  }

  peek(): AppMatcher | null {
    return this.matcher;
  }

  /** Current matcher; refreshes when stale (awaited only when nothing is cached yet). */
  get(signal: AbortSignal): Promise<AppMatcher | null> {
    const stale = this.clock() - this.fetchedAt >= this.ttlMs;
    if (this.matcher && !stale) return Promise.resolve(this.matcher);
    const refresh = this.refresh();
    return this.matcher ? Promise.resolve(this.matcher) : abortable(refresh, signal);
  }

  refresh(): Promise<AppMatcher | null> {
    if (this.inflight) return this.inflight;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5_000);
    timer.unref?.();
    const run = this.listApps(controller.signal)
      .then((index) => {
        this.fetchedAt = this.clock();
        if (!Array.isArray(index?.apps)) return this.matcher;
        if (index.version !== this.version || !this.matcher) {
          this.version = index.version;
          this.matcher = new AppMatcher(index.apps.filter(isAppRecord), this.frecency);
        }
        return this.matcher;
      })
      .catch(() => this.matcher)
      .finally(() => {
        clearTimeout(timer);
        if (this.inflight === run) this.inflight = undefined;
      });
    this.inflight = run;
    return run;
  }
}

/** Shape check plus a bundle id that openApp accepts (cards and acts must carry valid host actions). */
function isAppRecord(value: unknown): value is AppRecord {
  if (typeof value !== "object" || value === null) return false;
  const app = value as Partial<AppRecord>;
  return typeof app.bundleId === "string" && typeof app.name === "string" && typeof app.path === "string"
    && Array.isArray(app.aliases) && app.aliases.every((alias) => typeof alias === "string")
    && parseHostAction({ type: "openApp", bundleId: app.bundleId }) !== null;
}

function abortable<T>(promise: Promise<T>, signal: AbortSignal): Promise<T | null> {
  if (signal.aborted) return Promise.resolve(null);
  return new Promise((resolve) => {
    const onAbort = (): void => resolve(null);
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then((value) => {
      signal.removeEventListener("abort", onAbort);
      resolve(value);
    }, () => resolve(null));
  });
}

/**
 * Optional app frecency: `{bundleId: {count, lastMs}}` in
 * `<support dir>/instant-usage.json`, weight count × 0.5^(age / 14 d)
 * squashed to 0..1. Stores bundle ids only, never file paths or text.
 */
export class FileFrecencyStore implements FrecencyStore {
  private entries = new Map<string, { count: number; lastMs: number }>();
  private loaded = false;

  constructor(private readonly file: string = join(supportDirectory(), "instant-usage.json")) {}

  async load(): Promise<void> {
    if (this.loaded) return;
    this.loaded = true;
    try {
      const parsed: unknown = JSON.parse(await readFile(this.file, "utf8"));
      if (typeof parsed !== "object" || parsed === null) return;
      for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
        const v = value as { count?: unknown; lastMs?: unknown };
        if (typeof v?.count === "number" && typeof v.lastMs === "number" && /^[A-Za-z0-9.-]{1,255}$/.test(key)) {
          this.entries.set(key, { count: v.count, lastMs: v.lastMs });
        }
      }
    } catch {
      // Missing or corrupt: start empty.
    }
  }

  score(key: string, nowMs: number): number {
    const entry = this.entries.get(key);
    if (!entry) return 0;
    const weight = entry.count * 0.5 ** (Math.max(0, nowMs - entry.lastMs) / (14 * 86_400_000));
    return weight / (weight + 3);
  }

  record(key: string, nowMs: number): void {
    if (!/^[A-Za-z0-9.-]{1,255}$/.test(key)) return;
    const entry = this.entries.get(key);
    this.entries.set(key, { count: (entry?.count ?? 0) + 1, lastMs: nowMs });
    void this.save();
  }

  private async save(): Promise<void> {
    const temp = `${this.file}.${process.pid}.tmp`;
    try {
      await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
      await writeFile(temp, `${JSON.stringify(Object.fromEntries(this.entries))}\n`, { mode: 0o600 });
      await rename(temp, this.file);
    } catch {
      // Frecency is a convenience; losing a write is harmless.
    }
  }
}
