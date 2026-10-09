/**
 * QA-only site names for the continuity page fixture (host-macos/qa/continuity, DESIGN5 §12 / WP6).
 *
 * `toWebUrl` needs a TLD and so never yields a loopback URL ("127.0.0.1:47391/search" is not a URL to it), which is
 * right for real speech. For the coordinated live QA, `PI_OS_TEST_SITES_PORT=<port>` in the harness environment turns
 * these spoken names ("open fixture search", "öffne fixture suche") into `http://127.0.0.1:<port>/…`. With the
 * flag unset or invalid (anything but a decimal port in 1024–65535) the table is empty, so production speech never
 * reaches a fixture name. Every name starts with "fixture "; no real site, app or user word is shadowed.
 *
 * The instant grammar looks a target up here after SITE_HOME, as a known-site home page (an exact installed app name
 * still wins). Lookups are own-property only: the table has no prototype.
 */

/** Harness environment flag: the page fixture's loopback port. Unset → no test sites. */
export const TEST_SITES_ENV = "PI_OS_TEST_SITES_PORT";

const LOOPBACK = "127.0.0.1";

/** Spoken name (lowercase, as the open grammar's target) → page fixture path (`PAGES` in page-fixture/server.mjs). */
const TEST_SITE_PATHS: Readonly<Record<string, string>> = {
  "fixture home": "/",
  "fixture search": "/search",
  "fixture suche": "/search",
  "fixture combobox": "/combobox",
  "fixture combo box": "/combobox",
  "fixture delayed": "/delayed",
  "fixture loading": "/loading",
  "fixture consent": "/consent",
  "fixture frame": "/iframe",
  "fixture iframe": "/iframe",
  "fixture login": "/login",
  "fixture anmeldung": "/login",
  "fixture page": "/article",
  "fixture seite": "/article",
  "fixture article": "/article",
  "fixture artikel": "/article",
  "fixture moving": "/moving",
  "fixture editor": "/editor",
};

/** The port from the flag's value: a plain decimal 1024–65535 (no sign, spaces or leading zero), else null. */
export function parseTestSitesPort(value: string | undefined): number | null {
  if (value === undefined || !/^[1-9]\d{3,4}$/.test(value)) return null;
  const port = Number(value);
  return port >= 1024 && port <= 65_535 ? port : null;
}

/** The test-site table for an environment: empty unless `PI_OS_TEST_SITES_PORT` holds a valid port. Frozen, no prototype. */
export function testSiteHome(env: Readonly<Record<string, string | undefined>>): Readonly<Record<string, string>> {
  const table: Record<string, string> = Object.create(null) as Record<string, string>;
  const port = parseTestSitesPort(env[TEST_SITES_ENV]);
  if (port !== null) {
    for (const [name, path] of Object.entries(TEST_SITE_PATHS)) table[name] = `http://${LOOPBACK}:${port}${path}`;
  }
  return Object.freeze(table);
}

/** The table for this process, read once at startup (the harness is restarted to change it). */
export const TEST_SITE_HOME: Readonly<Record<string, string>> = testSiteHome(process.env);

/** The fixture URL for an open target ("fixture search"), or undefined (always, when the flag is off). */
export function testSiteUrl(target: string, table: Readonly<Record<string, string>> = TEST_SITE_HOME): string | undefined {
  return Object.prototype.hasOwnProperty.call(table, target) ? table[target] : undefined;
}
