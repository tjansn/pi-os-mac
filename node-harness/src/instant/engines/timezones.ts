/**
 * Time zones on built-in Intl only. ICU lists legacy canonical IDs
 * (Asia/Calcutta, Europe/Kiev, …) and leaves modern names out of
 * supportedValuesOf although DateTimeFormat accepts them, so modern names
 * are added explicitly. Unknown places return null: never guess a zone.
 */

export interface PlaceZone {
  /** As the user said it, title-cased ("Tokio", "New York"). */
  place: string;
  zone: string;
}

/** Curated EN/DE city, country and abbreviation aliases → IANA. */
const ALIASES: Readonly<Record<string, string>> = {
  tokyo: "Asia/Tokyo", tokio: "Asia/Tokyo", japan: "Asia/Tokyo", osaka: "Asia/Tokyo",
  sf: "America/Los_Angeles", "san francisco": "America/Los_Angeles", la: "America/Los_Angeles", "los angeles": "America/Los_Angeles",
  seattle: "America/Los_Angeles", "silicon valley": "America/Los_Angeles", california: "America/Los_Angeles", kalifornien: "America/Los_Angeles",
  "san jose": "America/Los_Angeles", portland: "America/Los_Angeles", "las vegas": "America/Los_Angeles", vancouver: "America/Vancouver",
  nyc: "America/New_York", "new york": "America/New_York", "new york city": "America/New_York", boston: "America/New_York",
  washington: "America/New_York", "washington dc": "America/New_York", miami: "America/New_York", atlanta: "America/New_York",
  philadelphia: "America/New_York", toronto: "America/Toronto", montreal: "America/Toronto",
  chicago: "America/Chicago", austin: "America/Chicago", dallas: "America/Chicago", houston: "America/Chicago",
  denver: "America/Denver", phoenix: "America/Phoenix", "mexico city": "America/Mexico_City", mexiko: "America/Mexico_City",
  "são paulo": "America/Sao_Paulo", "sao paulo": "America/Sao_Paulo", rio: "America/Sao_Paulo", "rio de janeiro": "America/Sao_Paulo",
  "buenos aires": "America/Argentina/Buenos_Aires", hawaii: "Pacific/Honolulu", honolulu: "Pacific/Honolulu", alaska: "America/Anchorage",
  london: "Europe/London", ldn: "Europe/London", uk: "Europe/London", england: "Europe/London", "great britain": "Europe/London",
  "united kingdom": "Europe/London", "großbritannien": "Europe/London", grossbritannien: "Europe/London", edinburgh: "Europe/London",
  manchester: "Europe/London", dublin: "Europe/Dublin", ireland: "Europe/Dublin", irland: "Europe/Dublin", lissabon: "Europe/Lisbon",
  lisbon: "Europe/Lisbon", portugal: "Europe/Lisbon",
  berlin: "Europe/Berlin", munich: "Europe/Berlin", "münchen": "Europe/Berlin", muenchen: "Europe/Berlin", hamburg: "Europe/Berlin",
  frankfurt: "Europe/Berlin", cologne: "Europe/Berlin", "köln": "Europe/Berlin", koeln: "Europe/Berlin", stuttgart: "Europe/Berlin",
  "düsseldorf": "Europe/Berlin", duesseldorf: "Europe/Berlin", dresden: "Europe/Berlin", leipzig: "Europe/Berlin", germany: "Europe/Berlin",
  deutschland: "Europe/Berlin", vienna: "Europe/Vienna", wien: "Europe/Vienna", austria: "Europe/Vienna", "österreich": "Europe/Vienna",
  zurich: "Europe/Zurich", "zürich": "Europe/Zurich", zuerich: "Europe/Zurich", geneva: "Europe/Zurich", genf: "Europe/Zurich",
  switzerland: "Europe/Zurich", schweiz: "Europe/Zurich", paris: "Europe/Paris", france: "Europe/Paris", frankreich: "Europe/Paris",
  madrid: "Europe/Madrid", barcelona: "Europe/Madrid", spain: "Europe/Madrid", spanien: "Europe/Madrid", rome: "Europe/Rome",
  rom: "Europe/Rome", milan: "Europe/Rome", mailand: "Europe/Rome", italy: "Europe/Rome", italien: "Europe/Rome",
  amsterdam: "Europe/Amsterdam", brussels: "Europe/Brussels", "brüssel": "Europe/Brussels", copenhagen: "Europe/Copenhagen",
  kopenhagen: "Europe/Copenhagen", stockholm: "Europe/Stockholm", oslo: "Europe/Oslo", helsinki: "Europe/Helsinki",
  warsaw: "Europe/Warsaw", warschau: "Europe/Warsaw", prague: "Europe/Prague", prag: "Europe/Prague", athens: "Europe/Athens",
  athen: "Europe/Athens", istanbul: "Europe/Istanbul", "türkei": "Europe/Istanbul", turkey: "Europe/Istanbul", moscow: "Europe/Moscow",
  moskau: "Europe/Moscow", kyiv: "Europe/Kyiv", kiew: "Europe/Kyiv",
  dubai: "Asia/Dubai", "abu dhabi": "Asia/Dubai", "tel aviv": "Asia/Jerusalem", israel: "Asia/Jerusalem", cairo: "Africa/Cairo",
  kairo: "Africa/Cairo", nairobi: "Africa/Nairobi", lagos: "Africa/Lagos", johannesburg: "Africa/Johannesburg", "cape town": "Africa/Johannesburg",
  kapstadt: "Africa/Johannesburg", delhi: "Asia/Kolkata", "new delhi": "Asia/Kolkata", "neu-delhi": "Asia/Kolkata", mumbai: "Asia/Kolkata",
  bombay: "Asia/Kolkata", bangalore: "Asia/Kolkata", bengaluru: "Asia/Kolkata", india: "Asia/Kolkata", indien: "Asia/Kolkata",
  kathmandu: "Asia/Kathmandu", nepal: "Asia/Kathmandu", bangkok: "Asia/Bangkok", hanoi: "Asia/Bangkok", "ho chi minh city": "Asia/Ho_Chi_Minh",
  saigon: "Asia/Ho_Chi_Minh", singapore: "Asia/Singapore", singapur: "Asia/Singapore", "kuala lumpur": "Asia/Kuala_Lumpur",
  jakarta: "Asia/Jakarta", manila: "Asia/Manila", "hong kong": "Asia/Hong_Kong", hongkong: "Asia/Hong_Kong", beijing: "Asia/Shanghai",
  peking: "Asia/Shanghai", shanghai: "Asia/Shanghai", shenzhen: "Asia/Shanghai", china: "Asia/Shanghai", taipei: "Asia/Taipei",
  seoul: "Asia/Seoul", korea: "Asia/Seoul", "south korea": "Asia/Seoul", "südkorea": "Asia/Seoul",
  sydney: "Australia/Sydney", melbourne: "Australia/Melbourne", brisbane: "Australia/Brisbane", perth: "Australia/Perth",
  auckland: "Pacific/Auckland", "new zealand": "Pacific/Auckland", neuseeland: "Pacific/Auckland",
  utc: "UTC", gmt: "UTC", zulu: "UTC", pst: "America/Los_Angeles", pdt: "America/Los_Angeles", pacific: "America/Los_Angeles",
  est: "America/New_York", edt: "America/New_York", eastern: "America/New_York", cst: "America/Chicago", cdt: "America/Chicago",
  mst: "America/Denver", mdt: "America/Denver", cet: "Europe/Berlin", cest: "Europe/Berlin", mez: "Europe/Berlin", mesz: "Europe/Berlin",
  bst: "Europe/London", jst: "Asia/Tokyo", aest: "Australia/Sydney",
};

/** Modern IANA names that ICU accepts but does not list (Node 24 / ICU 78). */
const MODERN_ZONES = ["Asia/Kolkata", "Asia/Kathmandu", "Asia/Ho_Chi_Minh", "Asia/Yangon", "Europe/Kyiv",
  "America/Argentina/Buenos_Aires", "America/Nuuk", "Atlantic/Faroe"];

let cityIndex: Map<string, string> | undefined;

/** Last IANA segment ("new york", "kiev", "kolkata") → zone, built once. */
function ianaCities(): Map<string, string> {
  if (cityIndex) return cityIndex;
  const zones = [...Intl.supportedValuesOf("timeZone"), ...MODERN_ZONES];
  cityIndex = new Map();
  for (const zone of zones) {
    const city = zone.split("/").pop()?.replace(/_/g, " ").toLowerCase();
    if (city && !cityIndex.has(city)) cityIndex.set(city, zone);
    cityIndex.set(zone.toLowerCase(), zone);
  }
  for (const zone of MODERN_ZONES) cityIndex.set(zone.split("/").pop()!.replace(/_/g, " ").toLowerCase(), zone);
  return cityIndex;
}

const ABBREVIATIONS = new Set(["sf", "la", "nyc", "ldn", "uk", "utc", "gmt", "pst", "pdt", "est", "edt", "cst", "cdt", "mst", "mdt",
  "cet", "cest", "mez", "mesz", "bst", "jst", "aest"]);

function titleCase(text: string): string {
  return text.replace(/(^|[\s-])(\p{L})/gu, (_m, sep: string, ch: string) => sep + ch.toUpperCase());
}

export function resolvePlace(text: string): PlaceZone | null {
  const key = text.toLowerCase().replace(/\s+/g, " ").replace(/^(?:the|der|die|das) /, "").trim();
  if (!key || key.length > 40) return null;
  const zone = ALIASES[key] ?? ianaCities().get(key);
  if (!zone) return null;
  const place = ABBREVIATIONS.has(key) ? key.toUpperCase() : titleCase(key);
  return { place, zone };
}

export function isValidZone(zone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
    return true;
  } catch {
    return false;
  }
}

export function localZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

const partsFormatters = new Map<string, Intl.DateTimeFormat>();

function partsFormatter(zone: string): Intl.DateTimeFormat {
  let formatter = partsFormatters.get(zone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat("en-US", {
      timeZone: zone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    partsFormatters.set(zone, formatter);
  }
  return formatter;
}

export interface WallTime { year: number; month: number; day: number; hour: number; minute: number; second: number }

export function wallTime(zone: string, at: Date): WallTime {
  const parts: Record<string, number> = {};
  for (const part of partsFormatter(zone).formatToParts(at)) {
    if (part.type !== "literal") parts[part.type] = Number(part.value);
  }
  return {
    year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1,
    hour: (parts.hour ?? 0) % 24, minute: parts.minute ?? 0, second: parts.second ?? 0,
  };
}

/** Offset of `zone` from UTC at `at`, in minutes. */
export function zoneOffsetMinutes(zone: string, at: Date): number {
  const w = wallTime(zone, at);
  const asUtc = Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute, w.second);
  return Math.round((asUtc - Math.floor(at.getTime() / 1000) * 1000) / 60_000);
}

function dayIndex(w: Pick<WallTime, "year" | "month" | "day">): number {
  return Date.UTC(w.year, w.month - 1, w.day) / 86_400_000;
}

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

function offsetLabel(minutes: number): string {
  if (minutes === 0) return "GMT";
  const sign = minutes < 0 ? "-" : "+";
  const abs = Math.abs(minutes);
  return `GMT${sign}${Math.floor(abs / 60)}${abs % 60 ? `:${pad(abs % 60)}` : ""}`;
}

const displayFormatters = new Map<string, Intl.DateTimeFormat>();

function displayFormatter(locale: string, zone: string, options: Intl.DateTimeFormatOptions, key: string): Intl.DateTimeFormat {
  const cacheKey = `${locale}|${zone}|${key}`;
  let formatter = displayFormatters.get(cacheKey);
  if (!formatter) {
    try {
      formatter = new Intl.DateTimeFormat(locale, { ...options, timeZone: zone });
    } catch {
      formatter = new Intl.DateTimeFormat("en-US", { ...options, timeZone: zone });
    }
    if (displayFormatters.size >= 256) displayFormatters.clear();
    displayFormatters.set(cacheKey, formatter);
  }
  return formatter;
}

const hourCycles = new Map<string, boolean>();

/** 24-hour locales show "02:30", 12-hour ones "2:30 AM". */
function uses24h(locale: string): boolean {
  let h24 = hourCycles.get(locale);
  if (h24 === undefined) {
    try {
      const cycle = new Intl.DateTimeFormat(locale, { hour: "numeric" }).resolvedOptions().hourCycle;
      h24 = cycle === "h23" || cycle === "h24";
    } catch {
      h24 = false;
    }
    if (hourCycles.size >= 128) hourCycles.clear();
    hourCycles.set(locale, h24);
  }
  return h24;
}

export interface ZonedTime {
  zone: string;
  /** "02:30" (24 h). */
  time24: string;
  /** Locale display ("2:30 AM" / "02:30"). */
  time: string;
  /** Locale short weekday ("Sat"). */
  weekday: string;
  /** Locale short date ("Oct 3"). */
  date: string;
  /** ISO calendar date in that zone. */
  isoDate: string;
  /** "GMT+9", "GMT-7", "GMT+5:45". */
  offset: string;
  /** Calendar days relative to `relativeTo` (the user's zone). */
  dayDelta: number;
}

export function zonedTime(zone: string, at: Date, locale = "en-US", relativeTo: string = localZone()): ZonedTime {
  const w = wallTime(zone, at);
  const home = wallTime(relativeTo, at);
  return {
    zone,
    time24: `${pad(w.hour)}:${pad(w.minute)}`,
    time: displayFormatter(locale, zone, { hour: uses24h(locale) ? "2-digit" : "numeric", minute: "2-digit" }, "time").format(at),
    weekday: displayFormatter(locale, zone, { weekday: "short" }, "weekday").format(at),
    date: displayFormatter(locale, zone, { month: "short", day: "numeric" }, "date").format(at),
    isoDate: `${w.year}-${pad(w.month)}-${pad(w.day)}`,
    offset: offsetLabel(zoneOffsetMinutes(zone, at)),
    dayDelta: dayIndex(w) - dayIndex(home),
  };
}

/** The instant at which `zone` shows h:m on the calendar day `ref` has in that zone (DST-safe). */
export function instantForWallTime(hour: number, minute: number, zone: string, ref: Date): Date {
  const day = wallTime(zone, ref);
  const target = Date.UTC(day.year, day.month - 1, day.day, hour, minute);
  let guess = target - zoneOffsetMinutes(zone, new Date(target)) * 60_000;
  // Second pass corrects guesses that straddle a DST transition.
  guess = target - zoneOffsetMinutes(zone, new Date(guess)) * 60_000;
  return new Date(guess);
}

/** "5pm london in sf": wall time in `fromZone` (today there) → wall time in `toZone`. */
export function convertWallTime(hour: number, minute: number, fromZone: string, toZone: string, ref: Date, locale = "en-US"): ZonedTime & { from: ZonedTime } {
  const at = instantForWallTime(hour, minute, fromZone, ref);
  const from = zonedTime(fromZone, at, locale, fromZone);
  return { ...zonedTime(toZone, at, locale, fromZone), from };
}

/** Hours `b` is ahead of `a` at `at` (fractional for :30/:45 zones). */
export function zoneDiff(a: string, b: string, at: Date): number {
  return (zoneOffsetMinutes(b, at) - zoneOffsetMinutes(a, at)) / 60;
}
