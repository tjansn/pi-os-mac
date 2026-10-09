import { holidayName, type CalendarUnit, type DateTarget } from "../engines/dates.js";
import { resolvePlace, type PlaceZone } from "../engines/timezones.js";
import type { Normalized } from "../normalize.js";
import type { Parsed } from "../types.js";

/**
 * Time zone, time conversion and date-math phrasing (EN + DE). Places
 * resolve through the curated alias table + IANA names; an explicit time
 * question about an unknown place falls through as "unknown_place" rather
 * than guessing.
 */

export const MONTHS: Readonly<Record<string, number>> = {
  jan: 1, january: 1, januar: 1, "jänner": 1, feb: 2, february: 2, februar: 2, mar: 3, march: 3, "märz": 3, maerz: 3, marz: 3, "mär": 3,
  apr: 4, april: 4, may: 5, mai: 5, jun: 6, june: 6, juni: 6, jul: 7, july: 7, juli: 7, aug: 8, august: 8, sep: 9, sept: 9,
  september: 9, oct: 10, october: 10, okt: 10, oktober: 10, nov: 11, november: 11, dec: 12, december: 12, dez: 12, dezember: 12,
};

export const WEEKDAYS: Readonly<Record<string, number>> = {
  sunday: 0, sonntag: 0, monday: 1, montag: 1, tuesday: 2, dienstag: 2, wednesday: 3, mittwoch: 3, thursday: 4, donnerstag: 4,
  friday: 5, freitag: 5, saturday: 6, samstag: 6, sonnabend: 6,
};

const UNITS: Readonly<Record<string, CalendarUnit>> = {
  day: "day", days: "day", tag: "day", tage: "day", tagen: "day", week: "week", weeks: "week", woche: "week", wochen: "week",
  month: "month", months: "month", monat: "month", monate: "month", monaten: "month", year: "year", years: "year", jahr: "year",
  jahre: "year", jahren: "year",
};

const NOW_WORDS = String.raw`(?: right now| now| currently| at the moment| gerade| jetzt| grad| aktuell| im moment)?`;
const TIME_IN: readonly RegExp[] = [
  new RegExp(String.raw`^(?:what(?:'s| is) the |the |current |what's the current |what is the current )?(?:local |current )?time(?: is it)?${NOW_WORDS} (?:in|at) (.+?)${NOW_WORDS}$`),
  new RegExp(String.raw`^what time is it${NOW_WORDS} in (.+?)${NOW_WORDS}$`),
  new RegExp(String.raw`^(?:wie spät ist es|wie spaet ist es|wie viel uhr ist es|wieviel uhr ist es|wie spät|uhrzeit|die uhrzeit|zeit|aktuelle uhrzeit|wie spät ist's)${NOW_WORDS} in (.+?)${NOW_WORDS}$`),
  /^time (.+)$/,
];
const TIME_SUFFIX = /^(.+?) (?:time|uhrzeit)(?: now)?$/;

// h, separator, mm, marker. "2.50 usd in eur" is money, so "." only reads as a clock with am/pm/uhr.
const CLOCK = String.raw`(\d{1,2})(?:([:.])(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|uhr)?`;
const TIME_CONVERT = new RegExp(String.raw`^(?:what(?:'s| is) |convert |wie spät ist es |wieviel uhr ist |was ist )?${CLOCK}\s+(?:(?:in|at|um) )?(.+?)(?: time| zeit)?\s+(?:in|to|into|nach|zu|für|in der zeitzone) (.+?)(?: time| zeit)?$`);
const TIME_CONVERT_LOCAL = new RegExp(String.raw`^(?:what(?:'s| is) |convert |was ist )?${CLOCK}\s+(?:in|to|nach|für) (.+?)(?: time| zeit)?$`);

const TIME_DIFF_PAIR = /^(?:what(?:'s| is) the )?(?:time difference|time diff|time zone difference|zeitunterschied|zeitverschiebung|diff)(?: between| zwischen)? (.+?) (?:and|und|to|zu|nach|vs|versus) (.+)$/;
const TIME_DIFF_ONE = /^(?:what(?:'s| is) the )?(?:time difference|time diff|time zone difference|zeitunterschied|zeitverschiebung|diff)(?: to| with| from| zu| nach| mit)? (.+)$/;

function hourOf(h: number, minute: number, marker: string | undefined): { hour: number; minute: number } | null {
  if (minute > 59) return null;
  let hour = h;
  if (marker === "pm" || marker === "p.m.") {
    if (hour < 1 || hour > 12) return null;
    if (hour < 12) hour += 12;
  } else if (marker === "am" || marker === "a.m.") {
    if (hour < 1 || hour > 12) return null;
    if (hour === 12) hour = 0;
  }
  return hour <= 23 ? { hour, minute } : null;
}

function place(text: string): PlaceZone | null {
  return resolvePlace(text.replace(/^(?:in|the|der|die|das) /, ""));
}

function clockOf(m: RegExpExecArray): { hour: number; minute: number } | null {
  const marker = m[4];
  if (!marker && m[2] !== ":") return null;
  return hourOf(Number(m[1]), Number(m[3] ?? 0), marker);
}

export function matchTime(n: Normalized): Parsed | null {
  const s = n.numeric;
  const convert = TIME_CONVERT.exec(s);
  const convertClock = convert ? clockOf(convert) : null;
  if (convert && convertClock) {
    const from = place(convert[5]!);
    const to = place(convert[6]!);
    if (from && to) return { kind: "time_convert", ...convertClock, from, to };
  }
  const local = TIME_CONVERT_LOCAL.exec(s);
  const localClock = local ? clockOf(local) : null;
  if (local && localClock) {
    const to = place(local[5]!);
    if (to) return { kind: "time_convert", ...localClock, from: null, to };
  }
  if (convertClock || localClock) return { kind: "fallthrough", reason: "unknown_place" };

  const pair = TIME_DIFF_PAIR.exec(n.lower);
  if (pair) {
    const from = place(pair[1]!);
    const to = place(pair[2]!);
    if (from && to) return { kind: "time_diff", from, to };
  }
  const one = TIME_DIFF_ONE.exec(n.lower);
  if (one) {
    const to = place(one[1]!);
    if (to) return { kind: "time_diff", from: null, to };
    // A bare "diff …" is not necessarily about time zones.
    if (!n.lower.startsWith("diff ")) return { kind: "fallthrough", reason: "unknown_place" };
  }

  for (const pattern of TIME_IN) {
    const m = pattern.exec(n.lower);
    if (!m) continue;
    const zone = place(m[1]!);
    if (zone) return { kind: "time", place: zone };
    // "time management tips" is not a time-zone question; only the explicit "time in X" forms claim the utterance.
    return pattern === TIME_IN[3] ? null : { kind: "fallthrough", reason: "unknown_place" };
  }
  const suffix = TIME_SUFFIX.exec(n.lower);
  if (suffix) {
    const zone = place(suffix[1]!);
    if (zone) return { kind: "time", place: zone };
  }
  return null;
}

// ---------------------------------------------------------------- dates

/** "christmas", "31 mar", "march 31st", "31. märz 2027", "24.12.", "2026-12-24", "friday". */
export function parseDateTarget(text: string, lang: "en" | "de"): { target: DateTarget; label: string } | null {
  const t = text.trim().replace(/^(?:the|der|den|dem|zum|zur|am|on|next|nächsten|nächster|naechsten|kommenden)\s+/, "").replace(/[?.!]+$/, "").trim();
  const holiday = holidayName(t, lang);
  if (holiday) return { target: { month: 0, day: 0, holiday: t }, label: holiday };
  const weekdayValue = WEEKDAYS[t];
  if (weekdayValue !== undefined) return { target: { month: 0, day: 0, weekday: weekdayValue }, label: t.charAt(0).toUpperCase() + t.slice(1) };
  let m = /^(\d{1,2})(?:st|nd|rd|th)?\.?(?: of)? ([a-zäöü]+)\.?,?(?: (\d{4}))?$/.exec(t);
  if (m && MONTHS[m[2]!]) return dated(MONTHS[m[2]!]!, Number(m[1]), m[3]);
  m = /^([a-zäöü]+)\.? (\d{1,2})(?:st|nd|rd|th)?,?(?: (\d{4}))?$/.exec(t);
  if (m && MONTHS[m[1]!]) return dated(MONTHS[m[1]!]!, Number(m[2]), m[3]);
  m = /^(\d{1,2})\.(\d{1,2})\.?(\d{4}|\d{2})?$/.exec(t);
  if (m) return dated(Number(m[2]), Number(m[1]), m[3] && m[3].length === 2 ? `20${m[3]}` : m[3]);
  m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(t);
  if (m) return dated(Number(m[2]), Number(m[3]), m[1]);
  return null;
}

/** Explicit dates carry no label; callers show the formatted date instead. */
function dated(month: number, day: number, year: string | undefined): { target: DateTarget; label: string } | null {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return { target: { month, day, ...(year ? { year: Number(year) } : {}) }, label: "" };
}

const DAYS_UNTIL: readonly RegExp[] = [
  /^(?:how many )?days (?:are there |are left |left |remaining )?(?:until|till|til|to|before) (.+)$/,
  /^(?:how long|how much time)(?: is it| is left)? (?:until|till|til|to) (.+)$/,
  /^(?:wie ?viele )?tage (?:sind es |sind's )?(?:noch )?bis (?:zum |zur |zu )?(.+)$/,
  /^wie lange (?:ist es |dauert es )?(?:noch )?bis (?:zum |zur |zu )?(.+)$/,
];
const OFFSET: readonly RegExp[] = [
  /^(?:what(?:'s| is) the date |what date is it |what day is it |what day will it be |which day is it )?in (\d{1,4}) (days?|weeks?|months?|years?)$/,
  /^(\d{1,4}) (days?|weeks?|months?|years?) from (?:now|today)$/,
  /^(?:today|heute) (?:in|plus|\+) (\d{1,4}) (days?|weeks?|months?|years?|tagen?|wochen?|monaten?|jahren?)$/,
  /^(?:welches datum ist |welcher tag ist |was ist |das datum )?(?:heute )?in (\d{1,4}) (tagen|wochen|monaten|jahren|tag|woche|monat|jahr)$/,
];
const WEEKDAY_IN = /^(?:next )?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sonntag|montag|dienstag|mittwoch|donnerstag|freitag|samstag) in (\d{1,3}) (weeks?|wochen?)$/;
const WEEKDAY_OF = [
  /^(?:what day(?: of the week)? is|which day(?: of the week)? is|what weekday is|what day does) (.+?)(?: fall on| land on)?$/,
  /^(?:welcher (?:wochen)?tag ist|was für ein (?:wochen)?tag ist|auf welchen (?:wochen)?tag fällt) (.+)$/,
];
const TODAY = /^(?:what(?:'s| is) (?:the date|today's date|the date today|today)|what day is (?:it|today)(?: today)?|what's the day today|welcher tag ist heute|welches datum (?:ist|haben wir) heute|der wievielte ist heute|was ist heute für ein tag|welchen tag haben wir(?: heute)?)$/;

export function matchDate(n: Normalized): Parsed | null {
  const s = n.numeric;
  if (TODAY.test(n.lower)) return { kind: "date", query: { op: "today" } };
  for (const pattern of DAYS_UNTIL) {
    const m = pattern.exec(s);
    if (!m) continue;
    const parsed = parseDateTarget(m[1]!, n.lang);
    return parsed ? { kind: "date", query: { op: "days_until", target: parsed.target, label: parsed.label } } : null;
  }
  const weekdayIn = WEEKDAY_IN.exec(s);
  if (weekdayIn) {
    return { kind: "date", query: { op: "weekday_in", weekday: WEEKDAYS[weekdayIn[1]!] ?? 1, weeks: Number(weekdayIn[2]) } };
  }
  for (const pattern of OFFSET) {
    const m = pattern.exec(s);
    const unit = m ? UNITS[m[2]!] : undefined;
    if (m && unit) return { kind: "date", query: { op: "offset", amount: Number(m[1]), unit } };
  }
  for (const pattern of WEEKDAY_OF) {
    const m = pattern.exec(s);
    if (!m) continue;
    const parsed = parseDateTarget(m[1]!, n.lang);
    if (parsed && parsed.target.weekday === undefined) return { kind: "date", query: { op: "weekday_of", target: parsed.target, label: parsed.label } };
  }
  return null;
}
