import assert from "node:assert/strict";
import { test } from "node:test";
import {
  addCalendar, daysBetween, easterSunday, localToday, monthRange, nextOccurrence, relativeRange, resolveHoliday, weekdayIn,
} from "../src/instant/engines/dates.js";
import { convertWallTime, resolvePlace, zoneDiff, zonedTime, zoneOffsetMinutes } from "../src/instant/engines/timezones.js";

const AT = new Date("2026-10-02T17:30:00Z");

test("resolvePlace: EN/DE aliases, IANA city names, modern names ICU does not list, never a guess", () => {
  assert.deepEqual(resolvePlace("tokio"), { place: "Tokio", zone: "Asia/Tokyo" });
  assert.deepEqual(resolvePlace("New York"), { place: "New York", zone: "America/New_York" });
  assert.deepEqual(resolvePlace("sf"), { place: "SF", zone: "America/Los_Angeles" });
  assert.equal(resolvePlace("münchen")?.zone, "Europe/Berlin");
  assert.equal(resolvePlace("kyiv")?.zone, "Europe/Kyiv");
  assert.equal(resolvePlace("kiev")?.zone, "Europe/Kiev");
  assert.equal(resolvePlace("kathmandu")?.zone, "Asia/Kathmandu");
  assert.equal(resolvePlace("kolkata")?.zone, "Asia/Kolkata");
  assert.equal(resolvePlace("Asia/Tokyo")?.zone, "Asia/Tokyo");
  assert.equal(resolvePlace("the uk")?.zone, "Europe/London");
  assert.equal(resolvePlace("narnia"), null);
  assert.equal(resolvePlace(""), null);
});

test("zonedTime: local display, 24 h time, offset label and day delta", () => {
  const tokyo = zonedTime("Asia/Tokyo", AT, "en-US", "Europe/Berlin");
  assert.equal(tokyo.time24, "02:30");
  assert.equal(tokyo.time, "2:30 AM");
  assert.equal(tokyo.offset, "GMT+9");
  assert.equal(tokyo.dayDelta, 1);
  assert.equal(tokyo.isoDate, "2026-10-03");
  assert.equal(zonedTime("Asia/Tokyo", AT, "de-DE", "Europe/Berlin").time, "02:30");
  const la = zonedTime("America/Los_Angeles", new Date("2026-10-03T05:00:00Z"), "en-US", "Europe/Berlin");
  assert.equal(la.dayDelta, -1);
  assert.equal(zonedTime("Asia/Kathmandu", AT, "en-US", "UTC").offset, "GMT+5:45");
  assert.equal(zoneDiff("Europe/Berlin", "Asia/Tokyo", AT), 7);
  assert.equal(zoneDiff("Europe/Berlin", "Asia/Kolkata", AT), 3.5);
  assert.equal(zoneOffsetMinutes("UTC", AT), 0);
});

test("convertWallTime: 5pm London → San Francisco, DST-correct on both sides", () => {
  const converted = convertWallTime(17, 0, "Europe/London", "America/Los_Angeles", AT);
  assert.equal(converted.time24, "09:00");
  assert.equal(converted.from.time24, "17:00");
  assert.equal(converted.dayDelta, 0);
  // 17:00 Berlin → Tokyo is the next morning.
  const tokyo = convertWallTime(17, 0, "Europe/Berlin", "Asia/Tokyo", AT);
  assert.equal(tokyo.time24, "00:00");
  assert.equal(tokyo.dayDelta, 1);
  // After the EU DST switch (Oct 25) Berlin is UTC+1 but the US is still on DST until Nov 1.
  const afterSwitch = convertWallTime(17, 0, "Europe/Berlin", "America/New_York", new Date("2026-10-27T12:00:00Z"));
  assert.equal(afterSwitch.time24, "12:00");
});

test("date math: holidays, explicit dates, rollover, DST-proof day counts (clock 2026-10-02)", () => {
  const today = localToday(new Date(2026, 9, 2, 19, 30));
  const until = (target: Parameters<typeof nextOccurrence>[0]) => daysBetween(today, nextOccurrence(target, today)!);
  assert.equal(until({ month: 0, day: 0, holiday: "christmas" }), 84);
  assert.equal(until({ month: 0, day: 0, holiday: "weihnachten" }), 84);
  assert.equal(until({ month: 3, day: 31 }), 180);
  assert.equal(until({ month: 10, day: 26 }), 24); // across the EU DST end on Oct 25
  assert.equal(until({ month: 10, day: 2 }), 0);
  assert.equal(until({ month: 10, day: 1 }), 364);
  assert.equal(until({ month: 0, day: 0, weekday: 5 }), 7); // Friday → next Friday
  assert.equal(until({ month: 0, day: 0, weekday: 1 }), 3);
  assert.equal(nextOccurrence({ month: 2, day: 30 }, today), null);
  assert.deepEqual(nextOccurrence({ month: 2, day: 29 }, today), { year: 2028, month: 2, day: 29 });
  assert.deepEqual(easterSunday(2027), { year: 2027, month: 3, day: 28 });
  assert.deepEqual(resolveHoliday("karfreitag", 2027), { year: 2027, month: 3, day: 26 });
  assert.deepEqual(resolveHoliday("pfingstmontag", 2027), { year: 2027, month: 5, day: 17 });
});

test("calendar offsets, 'monday in 3 weeks' and month/relative ranges", () => {
  const today = localToday(new Date(2026, 9, 2, 19, 30));
  assert.deepEqual(addCalendar(today, 3, "week"), { year: 2026, month: 10, day: 23 });
  assert.deepEqual(addCalendar(today, 10, "day"), { year: 2026, month: 10, day: 12 });
  assert.deepEqual(addCalendar({ year: 2026, month: 1, day: 31 }, 1, "month"), { year: 2026, month: 2, day: 28 });
  assert.deepEqual(addCalendar(today, 1, "year"), { year: 2027, month: 10, day: 2 });
  assert.deepEqual(weekdayIn(1, 3, today), { year: 2026, month: 10, day: 19 });
  assert.deepEqual(weekdayIn(5, 0, today), today);
  const march = monthRange(3, undefined, today);
  assert.equal(march.fromMs, new Date(2026, 2, 1).getTime());
  assert.equal(march.toMs, new Date(2026, 3, 1).getTime());
  assert.equal(monthRange(12, undefined, today).year, 2025); // "from December" in October = last December
  const yesterday = relativeRange("yesterday", today);
  assert.equal(yesterday.fromMs, new Date(2026, 9, 1).getTime());
  assert.equal(yesterday.toMs, new Date(2026, 9, 2).getTime());
  assert.equal(relativeRange("this week", today).fromMs, new Date(2026, 8, 28).getTime());
  assert.equal(relativeRange("last month", today).fromMs, new Date(2026, 8, 1).getTime());
});
