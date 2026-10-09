import { isHttpUrl } from "../../contracts/actions.js";
import { normalizeSpokenUrl, spokenCore, type Normalized } from "../normalize.js";
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
const LOUDER = /^(?:volume up|louder|make it louder|turn up the (?:volume|sound|music)|(?:a bit |a little )?louder|turn (?:it|the volume|the sound|the music) up|increase (?:the )?volume|raise (?:the )?volume|lauter|(?:etwas |ein bisschen )?lauter|mach lauter|mach (?:es |das )?lauter|lautstärke (?:hoch|erhöhen|rauf))$/;
const QUIETER = /^(?:volume down|quieter|softer|make it quieter|make it softer|turn down the (?:volume|sound|music)|(?:a bit |a little )?quieter|turn (?:it|the volume|the sound|the music) down|decrease (?:the )?volume|lower (?:the )?volume|leiser|(?:etwas |ein bisschen )?leiser|mach leiser|mach (?:es |das )?leiser|lautstärke (?:runter|verringern|senken))$/;
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

/**
 * Domains a spoken URL may open without asking (DESIGN4 §5.4): the site tables plus common sites. A voice
 * final that names any other domain ("Open guests.com" for "open github dot com") gets a one-Return
 * confirm instead, because recognizers turn spoken domains into real but wrong ones.
 */
export const KNOWN_SPOKEN_DOMAINS: ReadonlySet<string> = new Set([
  "google.com", "google.de", "youtube.com", "github.com", "wikipedia.org", "amazon.com", "amazon.de", "reddit.com", "x.com",
  "twitter.com", "linkedin.com", "facebook.com", "instagram.com", "netflix.com", "apple.com", "icloud.com", "chatgpt.com",
  "openai.com", "claude.ai", "anthropic.com", "notion.so", "figma.com", "duckduckgo.com", "spiegel.de", "zeit.de", "heise.de",
  "tagesschau.de", "faz.net", "sueddeutsche.de", "bild.de", "web.de", "gmx.net", "gmx.de", "ebay.de", "ebay.com", "paypal.com",
  "dhl.de", "deutschebahn.com", "bahn.de", "news.ycombinator.com", "stackoverflow.com", "medium.com", "twitch.tv", "spotify.com",
  "maps.google.com", "mail.google.com", "drive.google.com", "docs.google.com", "calendar.google.com", "wetter.com", "dict.cc", "leo.org",
]);

/**
 * True when a spoken URL's host is a known site (`KNOWN_SPOKEN_DOMAINS`, `www.` ignored) or a subdomain of
 * one ("de.wikipedia.org"). Case-insensitive; a trailing dot is ignored.
 */
export function isKnownSpokenHost(host: string): boolean {
  const bare = host.toLowerCase().replace(/\.$/, "").replace(/^www\./, "");
  if (KNOWN_SPOKEN_DOMAINS.has(bare)) return true;
  const parts = bare.split(".");
  return parts.length > 2 && KNOWN_SPOKEN_DOMAINS.has(parts.slice(-2).join("."));
}

/**
 * Hosts a spoken site name stands for ("youtube" → www.youtube.com), from the home and search
 * tables. The agent's open_item opens a URL without a click only for sites the user named.
 */
export const SITE_NAME_HOSTS: Readonly<Record<string, readonly string[]>> = (() => {
  const out: Record<string, Set<string>> = {};
  const add = (name: string, url: string): void => {
    (out[name] ??= new Set()).add(new URL(url.replace("%s", "q")).hostname);
  };
  for (const [name, url] of Object.entries(SITE_HOME)) add(name, url);
  for (const [alias, key] of Object.entries(SITE_ALIASES)) {
    for (const variant of [key, `${key}-de`]) {
      const site = SITE_SEARCH[variant];
      if (site) add(alias, site.template);
    }
  }
  return Object.fromEntries(Object.entries(out).map(([name, hosts]) => [name, [...hosts]]));
})();

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

/** True when the utterance starts like a web search ("google …", "search the web for …"); read-only by definition. */
export function isWebSearchPhrase(lower: string): boolean {
  return WEB_RULES.some(([pattern]) => pattern.test(lower));
}

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

// Typed open forms (today's grammar). No "page "/"app " target prefix: it ate names ("open App Store" →
// "store", "open page is" → "is"); a leading "app" word is the app matcher's job (AppMatcher.match).
const OPEN_EN = /^(?:open|launch|start|run|switch to|go to|goto|bring up|pull up|fire up|activate|visit|navigate to|browse to|take me to)(?: the)? (?:application |website |site )?(.+?)(?: app| application| website| site)?$/;
const OPEN_DE = /^(?:öffne|oeffne|öffnen|starte|start|wechsle (?:zu|zur|zum|in|auf)|wechsel (?:zu|zur|zum)|geh(?:e)? (?:zu|zur|zum|auf)|zeig(?:e)? mir|besuche|navigiere zu)(?: die| das| den| der| dem)? (?:programm |webseite |seite )?(.+?)(?: app)?$/;
const OPEN_DE_SPLIT = /^(?:ruf(?:e)?|mach(?:e)?|hol(?:e)?) (?:die |das |den )?(?:webseite |seite )?(.+?) (?:auf|nach vorne|in den vordergrund)$/;

// Spoken open forms (voice only, DESIGN4 §5.1), tried on the spoken core first, then on the raw text.
const SPOKEN_OPEN_EN = /^(?:open up|open|launch|start up|start|run|switch over to|switch back to|switch to|go back to|go to|goto|bring up|pull up|fire up|boot up|load up|activate|jump into|jump to|flip to|change to|visit|navigate to|browse to|take me to)(?: the)? (?:application |website |site )?(.+?)(?: app| application| website| site| window)?$/;
const SPOKEN_OPEN_DE = /^(?:öffne|oeffne|öffnen|starte|start|wechsle (?:zu|zur|zum|in|auf)|wechsel (?:zu|zur|zum|in|auf)|geh(?:e)? (?:zu|zur|zum|auf|in)|besuche|navigiere zu)(?: die| das| den| der| dem)? (?:programm |anwendung |webseite |seite )?(.+?)(?: app)?$/;
const SPOKEN_OPEN_DE_SPLIT = /^(?:ruf(?:e)?|mach(?:e)?|hol(?:e)?) (?:mir )?(?:die |das |den )?(?:programm |webseite |seite )?(.+?) (?:auf|nach vorne|in den vordergrund|her)$/;
/** German verb-final ("Pages öffnen", "kannst du (mir bitte) Pages aufmachen" once the wrapper is gone). */
const SPOKEN_OPEN_DE_FINAL = /^(?:(?:mir|uns) )?(?:(?:bitte|mal|doch|jetzt|schnell|kurz|gleich|eben|einfach) )*(?:die |das |den |der |dem )?(?:app |programm )?(.+?)(?: (?:bitte|mal|doch|jetzt|schnell|kurz|gleich))* (?:öffnen|oeffnen|starten|aufmachen|aufrufen|hochfahren|anmachen)$/;
/** "Bring Pages to the front", "pull Pages up", "get Pages up". */
const SPOKEN_OPEN_EN_SPLIT = /^(?:bring|pull|get|put) (?:the )?(.+?) (?:to the front|up|forward|to front)$/;
/** Weak verbs: they open only an exact name ("show me Pages", "zeig mir Pages", "focus Ghostty"). */
const SPOKEN_OPEN_WEAK = /^(?:show me|show|get me|get|focus|focus on|zeig(?:e)? mir|zeig(?:e)?|hol(?:e)? mir)(?: the| die| das| den)? (?:app |programm )?(.+?)(?: app)?$/;
/** Bare utterances that are answers, verbs or noise, never an app name. */
const BARE_NOT_NAMES = /^(?:yes|yeah|yep|no|nope|ok|okay|thanks|thank you|danke|ja|nein|nö|hm+|um+|uh+|äh+|open|launch|start|run|öffne|öffnen|starte|starten|go|stop|cancel|help|hilfe|hello|hallo|hi|hey|test|testing)$/;
/** An indefinite noun phrase is a thing to create, not an app name ("open a new window", "starte einen Timer"). */
const INDEFINITE = /^(?:a|an|ein|eine|einen|einem|some|another|new|neue[nsm]?)\s/;
/** A bare name is at most this many words ("Notion Calendar", "QuickTime Player"). */
const BARE_MAX_WORDS = 3;

/**
 * How firmly an open form asks to open: "strong" open/launch/switch verbs, "weak" show/get/focus verbs and
 * indefinite objects, "bare" a name said alone (voice only). Typed open forms are always strong.
 */
export type OpenStrength = "strong" | "weak" | "bare";

/** The open parse with its strength; `strength` is present only when it is not "strong". */
export type OpenParse = Extract<Parsed, { kind: "open" }> & { strength?: OpenStrength };

/** The strength of an open parse (`parseInstant` with `voice` marks weak and bare forms). */
export function openStrength(parsed: Extract<Parsed, { kind: "open" }>): OpenStrength {
  return (parsed as OpenParse).strength ?? "strong";
}

export interface OpenMatchOptions {
  /** Voice transcript: spoken core, spoken verb families, verb-final German, weak verbs. */
  voice?: boolean;
  /** Voice only: also accept a name said alone (the grammar's last resort). */
  bare?: boolean;
}

/** `strength` undefined: a typed form (today's shape, no strength). */
function openResult(rawTarget: string, strength?: OpenStrength): Parsed | null {
  const target = rawTarget.trim().replace(/\.app$/, "");
  if (!target || target.length > 80) return null;
  const effective: OpenStrength = strength === undefined ? "strong" : strength === "strong" && INDEFINITE.test(target) ? "weak" : strength;
  // The "page"/"app" word stays in the target ("page is", "app store"), but a URL after it still opens
  // ("open page github.com"), and typed "open the app YouTube" keeps today's known-site fallback.
  const named = /^(?:app|page) \S/.test(target) ? target.slice(target.indexOf(" ") + 1) : undefined;
  const url = toWebUrl(target) ?? (named ? toWebUrl(named) : null);
  if (url) return effective === "bare" ? null : { kind: "url", url, label: urlLabel(url) };
  const site = effective === "bare" ? undefined : SITE_HOME[target] ?? (named && strength === undefined ? SITE_HOME[named] : undefined);
  const parsed: OpenParse = site ? { kind: "open", target, siteUrl: site } : { kind: "open", target };
  if (effective !== "strong") parsed.strength = effective;
  return parsed;
}

function matchSpokenOpen(n: Normalized, bare: boolean): Parsed | null {
  const core = spokenCore(n.lower);
  // The core first: on the raw text a wrapper would end up in the target ("öffne mir bitte Pages").
  for (const text of core === n.lower ? [n.lower] : [core, n.lower]) {
    const m = SPOKEN_OPEN_EN.exec(text) ?? SPOKEN_OPEN_DE.exec(text) ?? SPOKEN_OPEN_DE_SPLIT.exec(text)
      ?? SPOKEN_OPEN_EN_SPLIT.exec(text) ?? SPOKEN_OPEN_DE_FINAL.exec(text);
    if (m) return openResult(m[1]!, "strong");
  }
  const weak = SPOKEN_OPEN_WEAK.exec(core);
  if (weak) return openResult(weak[1]!, "weak");
  // A name said alone: the dispatcher accepts it only for an exact, unmistakable installed name.
  if (bare && core && core.split(" ").length <= BARE_MAX_WORDS && !/\d/.test(core) && !BARE_NOT_NAMES.test(core)) return openResult(core, "bare");
  return null;
}

/**
 * "open github dot com" → url; "open figma" / "öffne die Systemeinstellungen" → open (resolved against
 * the host app index by the dispatcher; known site names carry a fallback URL). With `voice`, spoken
 * wrappers ("okay, can you open Pages for me", "öffne mir bitte mal Pages", "Pages öffnen", "mach mal
 * Pages auf", "bring Pages to the front") are reduced to their command core first, weak verbs and
 * indefinite objects are marked "weak", and `bare` accepts a name said alone.
 */
export function matchOpen(n: Normalized, options: OpenMatchOptions = {}): Parsed | null {
  if (options.voice) return matchSpokenOpen(n, options.bare === true);
  const m = OPEN_EN.exec(n.lower) ?? OPEN_DE.exec(n.lower) ?? OPEN_DE_SPLIT.exec(n.lower);
  return m ? openResult(m[1]!) : null;
}

/** A bare typed or spoken URL ("github.com", "example dot com slash docs"). */
export function matchBareUrl(n: Normalized): Parsed | null {
  if (n.lower.split(" ").length > 6) return null;
  const url = toWebUrl(n.lower);
  return url ? { kind: "url", url, label: urlLabel(url) } : null;
}
