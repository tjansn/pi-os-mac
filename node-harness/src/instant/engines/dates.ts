/**
 * Calendar math on whole days (no Temporal in Node 24). Day numbers come from
 * Date.UTC, so DST transitions never change a day count; "today" is the
 * user's local calendar day of the injected clock.
 */

export interface YMD { year: number; month: number; day: number }

const DAY_MS = 86_400_000;

export function dayNumber(year: number, month: number, day: number): number {
  return Date.UTC(year, month - 1, day) / DAY_MS;
}

export function fromDayNumber(n: number): YMD {
  const d = new Date(n * DAY_MS);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

export function localToday(now: Date): YMD {
  return { year: now.getFullYear(), month: now.getMonth() + 1, day: now.getDate() };
}

export function ymdNumber(date: YMD): number {
  return dayNumber(date.year, date.month, date.day);
}

/** 0 = Sunday … 6 = Saturday. */
export function weekday(date: YMD): number {
  return new Date(ymdNumber(date) * DAY_MS).getUTCDay();
}

export function isValidDate(year: number, month: number, day: number): boolean {
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day) || month < 1 || month > 12 || day < 1) return false;
  const back = fromDayNumber(dayNumber(year, month, day));
  return back.month === month && back.day === day;
}

/** Gregorian Easter Sunday (anonymous computus). */
export function easterSunday(year: number): YMD {
  const a = year % 19;
  const b = Math.floor(year / 100);
  const c = year % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31);
  const day = ((h + l - 7 * m + 114) % 31) + 1;
  return { year, month, day };
}

type HolidayRule = readonly [number, number] | { easterOffset: number };

const HOLIDAYS: Readonly<Record<string, { rule: HolidayRule; en: string; de: string }>> = (() => {
  const table: Record<string, { rule: HolidayRule; en: string; de: string }> = {};
  const add = (names: string[], rule: HolidayRule, en: string, de: string): void => {
    for (const name of names) table[name] = { rule, en, de };
  };
  add(["christmas", "xmas", "christmas day", "weihnachten", "erster weihnachtstag", "1. weihnachtstag"], [12, 25], "Christmas", "Weihnachten");
  add(["christmas eve", "heiligabend", "heiliger abend", "heilig abend"], [12, 24], "Christmas Eve", "Heiligabend");
  add(["boxing day", "zweiter weihnachtstag", "2. weihnachtstag"], [12, 26], "Boxing Day", "2. Weihnachtstag");
  add(["new year", "new year's", "new years", "new year's day", "new years day", "neujahr"], [1, 1], "New Year's Day", "Neujahr");
  add(["new year's eve", "new years eve", "silvester"], [12, 31], "New Year's Eve", "Silvester");
  add(["halloween"], [10, 31], "Halloween", "Halloween");
  add(["valentine's day", "valentines day", "valentine's", "valentinstag"], [2, 14], "Valentine's Day", "Valentinstag");
  add(["st patrick's day", "st. patrick's day", "saint patrick's day"], [3, 17], "St Patrick's Day", "St. Patrick's Day");
  add(["independence day", "4th of july", "fourth of july"], [7, 4], "Independence Day", "Independence Day");
  add(["tag der deutschen einheit", "german unity day"], [10, 3], "German Unity Day", "Tag der Deutschen Einheit");
  add(["nikolaus", "nikolaustag", "st nicholas day", "st. nicholas day"], [12, 6], "St Nicholas Day", "Nikolaus");
  add(["tag der arbeit", "erster mai", "1. mai", "may day", "labour day", "labor day"], [5, 1], "May Day", "Tag der Arbeit");
  add(["allerheiligen", "all saints' day", "all saints day"], [11, 1], "All Saints' Day", "Allerheiligen");
  add(["easter", "easter sunday", "ostern", "ostersonntag"], { easterOffset: 0 }, "Easter", "Ostern");
  add(["good friday", "karfreitag"], { easterOffset: -2 }, "Good Friday", "Karfreitag");
  add(["easter monday", "ostermontag"], { easterOffset: 1 }, "Easter Monday", "Ostermontag");
  add(["ascension day", "ascension", "christi himmelfahrt", "himmelfahrt"], { easterOffset: 39 }, "Ascension Day", "Christi Himmelfahrt");
  add(["pentecost", "whitsun", "pfingsten", "pfingstsonntag"], { easterOffset: 49 }, "Pentecost", "Pfingsten");
  add(["whit monday", "pfingstmontag"], { easterOffset: 50 }, "Whit Monday", "Pfingstmontag");
  return table;
})();

export function holidayName(name: string, lang: "en" | "de"): string | null {
  const entry = HOLIDAYS[name.toLowerCase().trim()];
  return entry ? entry[lang] : null;
}

/** Month/day of a named holiday in `year`, or null. */
export function resolveHoliday(name: string, year: number): YMD | null {
  const entry = HOLIDAYS[name.toLowerCase().trim()];
  if (!entry) return null;
  if ("easterOffset" in entry.rule) return fromDayNumber(ymdNumber(easterSunday(year)) + entry.rule.easterOffset);
  return { year, month: entry.rule[0], day: entry.rule[1] };
}

export interface DateTarget {
  month: number;
  day: number;
  year?: number;
  holiday?: string;
  /** 0 = Sunday … 6 = Saturday; the next such day strictly after today. */
  weekday?: number;
}

/** The next occurrence on or after today (or the explicit year). Null for impossible dates. */
export function nextOccurrence(target: DateTarget, today: YMD): YMD | null {
  if (target.weekday !== undefined) {
    const ahead = ((target.weekday - weekday(today) + 7) % 7) || 7;
    return fromDayNumber(ymdNumber(today) + ahead);
  }
  const resolve = (year: number): YMD | null => {
    if (target.holiday) return resolveHoliday(target.holiday, year);
    return isValidDate(year, target.month, target.day) ? { year, month: target.month, day: target.day } : null;
  };
  if (target.year !== undefined) return resolve(target.year);
  const todayN = ymdNumber(today);
  for (let year = today.year; year <= today.year + 8; year++) {
    const date = resolve(year);
    if (date && ymdNumber(date) >= todayN) return date;
  }
  return null;
}

export function daysBetween(from: YMD, to: YMD): number {
  return ymdNumber(to) - ymdNumber(from);
}

export type CalendarUnit = "day" | "week" | "month" | "year";

/** today + n units; month/year arithmetic clamps to the month's last day (Jan 31 + 1 month → Feb 28/29). */
export function addCalendar(today: YMD, amount: number, unit: CalendarUnit): YMD {
  if (unit === "day" || unit === "week") return fromDayNumber(ymdNumber(today) + amount * (unit === "week" ? 7 : 1));
  const months = unit === "year" ? amount * 12 : amount;
  const index = today.year * 12 + (today.month - 1) + months;
  const year = Math.floor(index / 12);
  const month = (index % 12) + 1;
  const last = fromDayNumber(dayNumber(year, month + 1, 1) - 1).day;
  return { year, month, day: Math.min(today.day, last) };
}

/**
 * "monday in 3 weeks": the given weekday (0 = Sunday) in the ISO week
 * (Monday-based) that lies `weeks` weeks after the current one.
 */
export function weekdayIn(targetWeekday: number, weeks: number, today: YMD): YMD {
  const todayN = ymdNumber(today);
  const mondayOffset = (weekday(today) + 6) % 7;
  const monday = todayN - mondayOffset + weeks * 7;
  return fromDayNumber(monday + ((targetWeekday + 6) % 7));
}

export interface MsRange { fromMs: number; toMs: number }

function localMidnight(date: YMD): number {
  return new Date(date.year, date.month - 1, date.day).getTime();
}

/** Local-time range of a calendar month. Without a year, the most recent such month (this month counts). */
export function monthRange(month: number, year: number | undefined, today: YMD): MsRange & { year: number } {
  const y = year ?? (month > today.month ? today.year - 1 : today.year);
  return { year: y, fromMs: new Date(y, month - 1, 1).getTime(), toMs: new Date(y, month, 1).getTime() };
}

export function yearRange(year: number): MsRange {
  return { fromMs: new Date(year, 0, 1).getTime(), toMs: new Date(year + 1, 0, 1).getTime() };
}

export type RelativeRangeKey = "today" | "yesterday" | "this week" | "last week" | "this month" | "last month" | "this year" | "last year";

export function relativeRange(key: RelativeRangeKey, today: YMD): MsRange {
  const todayN = ymdNumber(today);
  const at = (n: number): number => localMidnight(fromDayNumber(n));
  const monday = todayN - ((weekday(today) + 6) % 7);
  switch (key) {
    case "today": return { fromMs: at(todayN), toMs: at(todayN + 1) };
    case "yesterday": return { fromMs: at(todayN - 1), toMs: at(todayN) };
    case "this week": return { fromMs: at(monday), toMs: at(monday + 7) };
    case "last week": return { fromMs: at(monday - 7), toMs: at(monday) };
    case "this month": return { fromMs: new Date(today.year, today.month - 1, 1).getTime(), toMs: new Date(today.year, today.month, 1).getTime() };
    case "last month": return { fromMs: new Date(today.year, today.month - 2, 1).getTime(), toMs: new Date(today.year, today.month - 1, 1).getTime() };
    case "this year": return yearRange(today.year);
    case "last year": return yearRange(today.year - 1);
  }
}

const dateFormatters = new Map<string, Intl.DateTimeFormat>();

/** "Fri, Dec 25, 2026" / "Fr., 25. Dez. 2026". */
export function formatDate(date: YMD, locale: string, withYear = true): string {
  const key = `${locale}|${withYear}`;
  let formatter = dateFormatters.get(key);
  if (!formatter) {
    const options: Intl.DateTimeFormatOptions = { weekday: "short", month: "short", day: "numeric", timeZone: "UTC", ...(withYear ? { year: "numeric" } : {}) };
    try {
      formatter = new Intl.DateTimeFormat(locale, options);
    } catch {
      formatter = new Intl.DateTimeFormat("en-US", options);
    }
    if (dateFormatters.size >= 128) dateFormatters.clear();
    dateFormatters.set(key, formatter);
  }
  return formatter.format(new Date(ymdNumber(date) * DAY_MS));
}

export function isoDate(date: YMD): string {
  return `${date.year}-${String(date.month).padStart(2, "0")}-${String(date.day).padStart(2, "0")}`;
}
