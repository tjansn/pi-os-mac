import { isHttpUrl } from "../../contracts/actions.js";
import { normalizeSpokenUrl, type Normalized } from "../normalize.js";
import type { MatchContext, Parsed } from "../types.js";

/**
 * System toggles, web search, quicklinks, URLs and "open X" (EN + DE).
 * Node only describes effects; the host validates and performs them.
 * System ops in v1: volume set/step/mute and display sleep. Appearance,
 * lock screen and power are deliberately not matched (they fall through).
 */

export const DEFAULT_WEB_SEARCH = "https://duckduckgo.com/?q=%s";
/** Signed fraction of full scale for "louder"/"leiser". */
export const VOLUME_STEP = 0.1;

const VOLUME_SET = [
  /^(?:set |change |put |turn )?(?:the |my )?(?:volume|sound|audio)(?: level)? (?:to |at |on )?(\d{1,3})(?: ?%| percent)?$/,
  /^(?:stelle |stell |setze |setz |mach |mache )?(?:die )?(?:lautstärke|lautstaerke)(?: auf)? (\d{1,3})(?: ?%| prozent)?(?: (?:stellen|setzen|einstellen))?$/,
];
const VOLUME_MAX = /^(?:set |turn )?(?:the )?volume (?:to )?(?:max|maximum|full)$|^(?:lautstärke|lautstaerke) (?:auf )?(?:maximum|max|voll)$/;
const MUTE = /^(?:mute|mute (?:the |my )?(?:sound|audio|volume|mac|computer|speakers?)|silence|stumm|stumm schalten|stummschalten|ton aus|sound aus|(?:schalte|mach|mache) (?:den )?ton aus)$/;
const UNMUTE = /^(?:unmute|unmute (?:the |my )?(?:sound|audio|volume|mac|computer|speakers?)|sound on|ton an|ton wieder an|sound an|stummschaltung aufheben|(?:schalte|mach|mache) (?:den )?ton (?:wieder )?an)$/;
const LOUDER = /^(?:volume up|louder|(?:a bit |a little )?louder|turn (?:it|the volume|the sound|the music) up|increase (?:the )?volume|raise (?:the )?volume|lauter|(?:etwas |ein bisschen )?lauter|mach lauter|mach (?:es |das )?lauter|lautstärke (?:hoch|erhöhen|rauf))$/;
const QUIETER = /^(?:volume down|quieter|softer|(?:a bit |a little )?quieter|turn (?:it|the volume|the sound|the music) down|decrease (?:the )?volume|lower (?:the )?volume|leiser|(?:etwas |ein bisschen )?leiser|mach leiser|mach (?:es |das )?leiser|lautstärke (?:runter|verringern|senken))$/;
const DISPLAY_SLEEP = /^(?:(?:sleep|turn off|switch off|put)(?: the| my)? (?:display|displays|screen|screens|monitor|monitors)(?: to sleep| off)?|(?:display|displays|screen) (?:sleep|off)|(?:bildschirm|display|monitor|bildschirme) (?:aus|ausschalten|schlafen legen|in den ruhezustand)|(?:schalte|mach|mache) (?:den |die )?(?:bildschirm|monitor|display|bildschirme) aus)$/;

export function matchSystem(n: Normalized): Parsed | null {
  const s = n.numeric;
  for (const pattern of VOLUME_SET) {
    const m = pattern.exec(s);
    if (!m) continue;
    const percent = Number(m[1]);
    if (percent > 100) return null;
    return { kind: "system", op: "volume.set", value: percent / 100, title: `Set volume to ${percent}%` };
  }
  if (VOLUME_MAX.test(s)) return { kind: "system", op: "volume.set", value: 1, title: "Set volume to 100%" };
  if (MUTE.test(s)) return { kind: "system", op: "volume.mute", value: true, title: "Mute" };
  if (UNMUTE.test(s)) return { kind: "system", op: "volume.mute", value: false, title: "Unmute" };
  if (LOUDER.test(s)) return { kind: "system", op: "volume.step", value: VOLUME_STEP, title: "Volume up" };
  if (QUIETER.test(s)) return { kind: "system", op: "volume.step", value: -VOLUME_STEP, title: "Volume down" };
  if (DISPLAY_SLEEP.test(s)) return { kind: "system", op: "display.sleep", title: "Sleep display" };
  return null;
}

// ---------------------------------------------------------------- web search and sites

interface SearchSite { engine: string; template: string }

const SITE_SEARCH: Readonly<Record<string, SearchSite>> = {
  google: { engine: "Google", template: "https://www.google.com/search?q=%s" },
  youtube: { engine: "YouTube", template: "https://www.youtube.com/results?search_query=%s" },
  wikipedia: { engine: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search=%s" },
  "wikipedia-de": { engine: "Wikipedia", template: "https://de.wikipedia.org/w/index.php?search=%s" },
  github: { engine: "GitHub", template: "https://github.com/search?q=%s&type=repositories" },
  amazon: { engine: "Amazon", template: "https://www.amazon.com/s?k=%s" },
  "amazon-de": { engine: "Amazon", template: "https://www.amazon.de/s?k=%s" },
  reddit: { engine: "Reddit", template: "https://www.reddit.com/search/?q=%s" },
  x: { engine: "X", template: "https://x.com/search?q=%s" },
  maps: { engine: "Maps", template: "https://maps.apple.com/?q=%s" },
  duckduckgo: { engine: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s" },
};

/** Spoken site names → home pages ("open youtube"). An installed app with the exact name wins. */
export const SITE_HOME: Readonly<Record<string, string>> = {
  google: "https://www.google.com/", youtube: "https://www.youtube.com/", github: "https://github.com/",
  wikipedia: "https://www.wikipedia.org/", amazon: "https://www.amazon.com/", reddit: "https://www.reddit.com/",
  x: "https://x.com/", twitter: "https://x.com/", "hacker news": "https://news.ycombinator.com/", gmail: "https://mail.google.com/",
  "google maps": "https://www.google.com/maps", "google drive": "https://drive.google.com/", "google calendar": "https://calendar.google.com/",
  "google docs": "https://docs.google.com/", linkedin: "https://www.linkedin.com/", duckduckgo: "https://duckduckgo.com/",
  netflix: "https://www.netflix.com/", instagram: "https://www.instagram.com/", facebook: "https://www.facebook.com/",
  chatgpt: "https://chatgpt.com/", claude: "https://claude.ai/",
};

const SITE_ALIASES: Readonly<Record<string, string>> = {
  google: "google", youtube: "youtube", wikipedia: "wikipedia", github: "github", amazon: "amazon", reddit: "reddit",
  twitter: "x", x: "x", "apple maps": "maps", maps: "maps", karten: "maps", duckduckgo: "duckduckgo",
};

const WEB_RULES: readonly (readonly [RegExp, string | null])[] = [
  // [pattern whose LAST group is the query (and optional site group "site"), fixed site or null = default engine]
  [/^(?:search (?:the )?(?:web|internet|net|online) for|search online for|web search(?: for)?|look up online|look online for|such(?:e)? (?:mal )?im (?:internet|web|netz) nach|im (?:internet|web|netz) nach|websuche(?: nach)?|internetsuche(?: nach)?) (.+)$/d, null],
  // Longer alternatives first: "google mal X" must not search for "mal X".
  [/^(?:google for|google nach|google mal|search google for|such(?:e)? (?:mal )?(?:bei|mit|auf|in) google nach|look up on google|google) (.+)$/d, "google"],
  [/^(?:search youtube for|search on youtube for|search youtube|youtube nach|such(?:e)? (?:mal )?(?:auf|bei|in) youtube nach|youtube) (.+)$/d, "youtube"],
  [/^(?:search wikipedia for|look up on wikipedia|such(?:e)? (?:mal )?(?:auf|bei|in) wikipedia nach|wikipedia) (.+)$/d, "wikipedia"],
  [/^(?:search (?<site>github|amazon|reddit|twitter|x|apple maps|maps) for|such(?:e)? (?:mal )?(?:auf|bei|in) (?<siteDe>github|amazon|reddit|twitter|x|karten) nach) (.+)$/d, ""],
  [/^look up (.+) on wikipedia$/d, "wikipedia"],
  [/^look up (.+) online$/d, null],
];

/** Encodes like a form field (spaces as "+"), the way search engines expect. */
export function expandTemplate(template: string, query: string): string {
  return template.replace("%s", encodeURIComponent(query).replace(/%20/g, "+"));
}

/** Original-case text of the match's last group (`n.lower` and `n.text` align when lengths match). */
function lastGroupText(n: Normalized, m: RegExpExecArray): string {
  const raw = m[m.length - 1] ?? "";
  const span = m.indices?.[m.length - 1];
  return span && n.text.length === n.lower.length ? n.text.slice(span[0], span[1]) : raw;
}

function stripArticle(query: string): string {
  return query.replace(/^(?:the|a|an|der|die|das|den|dem|ein|eine|einen|nach)\s+/i, "").trim();
}

export function matchWeb(n: Normalized, ctx: MatchContext): Parsed | null {
  for (const [pattern, fixed] of WEB_RULES) {
    const m = pattern.exec(n.lower);
    if (!m) continue;
    const query = stripArticle(lastGroupText(n, m));
    if (!query || query.length > 400) return null;
    let siteKey = fixed === "" ? SITE_ALIASES[m.groups?.site ?? m.groups?.siteDe ?? ""] : fixed;
    if (siteKey === "wikipedia" && n.lang === "de") siteKey = "wikipedia-de";
    if (siteKey === "amazon" && n.lang === "de") siteKey = "amazon-de";
    const site = siteKey ? SITE_SEARCH[siteKey] : undefined;
    const template = site?.template ?? ctx.webSearchTemplate;
    const url = expandTemplate(template, query);
    if (!isHttpUrl(url)) return null;
    return { kind: "web", url, query, engine: site?.engine ?? "the web" };
  }
  return null;
}

// ---------------------------------------------------------------- URLs and "open X"

const TLDS = "com|org|net|io|ai|dev|co|edu|gov|de|uk|us|xyz|info|me|tv|ch|at|fr|nl|es|it|eu|be|se|no|dk|fi|pl|cz|jp|cn|ca|au|nz|in|br|mx|gg|fm|ly|so|tech|blog|news|shop|online|site|cloud|page|wiki|design|studio|ie|pt|gr|kr|sg|hk|tw|il|za|ru|ua|tr";
const DOMAIN = new RegExp(String.raw`^(?:https?:\/\/)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:${TLDS})(?::\d{2,5})?(?:\/[^\s]*)?$`);

/** A spoken or typed domain/URL → validated https URL, else null. */
export function toWebUrl(target: string): string | null {
  const spoken = normalizeSpokenUrl(target);
  if (/\s/.test(spoken) || !DOMAIN.test(spoken)) return null;
  const url = /^https?:\/\//.test(spoken) ? spoken : `https://${spoken}`;
  return isHttpUrl(url) ? url : null;
}

function urlLabel(url: string): string {
  return url.replace(/^https?:\/\//, "").replace(/\/$/, "");
}

const OPEN_EN = /^(?:open|launch|start|run|switch to|go to|goto|bring up|pull up|fire up|activate|visit|navigate to|browse to|take me to)(?: the)? (?:app |application |website |site |page )?(.+?)(?: app| application| website| site)?$/;
const OPEN_DE = /^(?:öffne|oeffne|öffnen|starte|start|wechsle (?:zu|zur|zum|in|auf)|wechsel (?:zu|zur|zum)|geh(?:e)? (?:zu|zur|zum|auf)|zeig(?:e)? mir|besuche|navigiere zu)(?: die| das| den| der| dem)? (?:app |programm |webseite |seite )?(.+?)(?: app)?$/;
const OPEN_DE_SPLIT = /^(?:ruf(?:e)?|mach(?:e)?|hol(?:e)?) (?:die |das |den )?(?:app |webseite |seite )?(.+?) (?:auf|nach vorne|in den vordergrund)$/;

/**
 * "open github dot com" → url; "open figma" / "öffne die Systemeinstellungen"
 * → open (resolved against the host app index by the dispatcher; known site
 * names carry a fallback URL).
 */
export function matchOpen(n: Normalized): Parsed | null {
  const m = OPEN_EN.exec(n.lower) ?? OPEN_DE.exec(n.lower) ?? OPEN_DE_SPLIT.exec(n.lower);
  if (!m) return null;
  const target = m[1]!.trim().replace(/\.app$/, "");
  if (!target || target.length > 80) return null;
  const url = toWebUrl(target);
  if (url) return { kind: "url", url, label: urlLabel(url) };
  const site = SITE_HOME[target];
  return site ? { kind: "open", target, siteUrl: site } : { kind: "open", target };
}

/** A bare typed or spoken URL ("github.com", "example dot com slash docs"). */
export function matchBareUrl(n: Normalized): Parsed | null {
  if (n.lower.split(" ").length > 6) return null;
  const url = toWebUrl(n.lower);
  return url ? { kind: "url", url, label: urlLabel(url) } : null;
}
