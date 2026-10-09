import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { parseHostAction } from "../src/contracts/actions.js";
import { bindingToHostAction, type CardSpec } from "../src/contracts/cards.js";
import type { InstantResponse } from "../src/contracts/instant.js";
import type { AppRecord, FileCandidate, FileSearchRequest } from "../src/contracts/launcher.js";
import { AppIndexCache } from "../src/instant/apps.js";
import { createInstantDispatcher } from "../src/instant/dispatcher.js";
import { EcbRateStore } from "../src/instant/engines/fx.js";
import { parseInstant } from "../src/instant/grammar/index.js";
import { openStrength } from "../src/instant/grammar/launch.js";
import { normalize } from "../src/instant/normalize.js";

/*
 * Table-driven port of the research prototype's 82 fixtures (raycast §23.1,
 * verified 82/82 there), the extra raycast cases, and laya §12's 49 EN/DE
 * utterances. Everything runs through the real dispatcher with fend, a fixed
 * clock (2026-10-02 19:30 local), fixture apps, fixture ECB rates and a fake
 * host file search. v1 scope changes vs the prototype: appearance, lock
 * screen, power and clipboard intents are deferred, so they fall through.
 */

const NOW = new Date(2026, 9, 2, 19, 30);
const app = (bundleId: string, name: string, aliases: string[] = []): AppRecord =>
  ({ bundleId, name, aliases, path: `/Applications/${name}.app`, running: false });
const APPS: AppRecord[] = [
  app("com.figma.Desktop", "Figma"), app("com.spotify.client", "Spotify"), app("com.tinyspeck.slackmacgap", "Slack"),
  app("com.google.Chrome", "Google Chrome"), app("com.microsoft.VSCode", "Visual Studio Code", ["Code"]),
  app("com.apple.systempreferences", "System Settings"), app("com.apple.calculator", "Calculator"), app("com.brave.Browser", "Brave Browser"),
  app("com.apple.Terminal", "Terminal"), app("com.apple.dt.Xcode", "Xcode"),
];

const fileRequests: FileSearchRequest[] = [];
/** Fake host search: echoes one matching candidate per request (names from the first AND-group). */
async function searchFiles(request: FileSearchRequest): Promise<{ items: FileCandidate[]; truncated: boolean; elapsedMs: number }> {
  fileRequests.push(request);
  const name = `${request.nameGroups[0]!.join("-")}.pdf`;
  return {
    items: [{ token: "tok_fixture01", name, path: `/Users/fixture/Documents/${name}`, contentType: request.contentType ?? "com.adobe.pdf",
      createdMs: NOW.getTime() - 86_400_000, modifiedMs: NOW.getTime() - 86_400_000, isDirectory: false, isPackage: false }],
    truncated: false,
    elapsedMs: 1,
  };
}

const xml = readFileSync(join(import.meta.dirname, "..", "..", "shared", "fixtures", "instant-cases", "ecb-2026-10-02.xml"), "utf8");
const fx = new EcbRateStore({
  file: join(mkdtempSync(join(tmpdir(), "pi-os-instant-grammar-")), "fx.json"),
  fetch: (async () => new Response(xml, { status: 200 })) as typeof fetch,
  now: () => new Date("2026-10-02T18:00:00Z"),
  log: () => {},
});
const dispatcher = createInstantDispatcher({
  now: () => NOW,
  localZone: () => "Europe/Berlin",
  apps: new AppIndexCache(async () => ({ version: "fixture", apps: APPS })),
  searchFiles,
  fx,
  budgets: { defaultMs: 2_000, fileSearchMs: 2_000 },
});
const ctx = { now: NOW, locale: "en-US", webSearchTemplate: "https://duckduckgo.com/?q=%s" };

type Expect = {
  /** Partial match on the grammar output. */
  parsed?: Record<string, unknown> | null;
  /** Partial match on the InstantResponse (phase final). */
  response?: Record<string, unknown>;
  /** The card's copy binding text. */
  copy?: string;
};

function partialMatch(actual: unknown, expected: unknown, path: string): void {
  if (expected !== null && typeof expected === "object" && !Array.isArray(expected)) {
    assert.ok(actual !== null && typeof actual === "object", `${path}: expected object, got ${JSON.stringify(actual)}`);
    for (const [key, value] of Object.entries(expected)) partialMatch((actual as Record<string, unknown>)[key], value, `${path}.${key}`);
    return;
  }
  assert.deepEqual(actual, expected, path);
}

function copyText(card: CardSpec | undefined): string | undefined {
  for (const element of Object.values(card?.elements ?? {})) {
    const binding = element.on?.copy;
    if (binding) return String(binding.params.text);
  }
  return undefined;
}

function assertWellFormed(response: InstantResponse, input: string): void {
  if (response.decision === "act") assert.notEqual(parseHostAction(response.action), null, `${input}: action`);
  const card = "card" in response ? response.card : undefined;
  if (response.decision === "answer" || response.decision === "list" || response.decision === "refuse") assert.equal(card?.format, "pi-os-ui/1", input);
  for (const element of Object.values(card?.elements ?? {})) {
    for (const binding of Object.values(element.on ?? {})) assert.notEqual(bindingToHostAction(binding), null, `${input}: binding`);
  }
}

async function check(input: string, expect: Expect, locale?: string): Promise<InstantResponse> {
  if (expect.parsed !== undefined) {
    const parsed = parseInstant(normalize(input, locale), ctx);
    if (expect.parsed === null) assert.equal(parsed, null, input);
    else partialMatch(parsed, expect.parsed, input);
  }
  const response = await dispatcher.dispatch({ text: input, phase: "final", seq: 1, ...(locale ? { locale } : {}) });
  assertWellFormed(response, input);
  if (expect.response) partialMatch(response, expect.response, input);
  if (expect.copy !== undefined) assert.equal(copyText("card" in response ? response.card : undefined), expect.copy, `${input}: copy`);
  return response;
}

const calc = (copy: string): Expect => ({ parsed: { kind: "calc" }, response: { decision: "answer", intent: "calc" }, copy });
const unit = (expression: string, title?: string): Expect => ({ parsed: { kind: "unit", expression }, response: { decision: "answer", intent: "unit", ...(title ? { title } : {}) } });
const currency = (amount: number, from: string, to: string): Expect => ({ parsed: { kind: "currency", amount, from, to }, response: { decision: "answer", intent: "currency" } });
const base = (expression: string, title: string): Expect => ({ parsed: { kind: "base", expression }, response: { decision: "answer", intent: "base", title } });
const time = (zone: string): Expect => ({ parsed: { kind: "time", place: { zone } }, response: { decision: "answer", intent: "time" } });
const days = (n: number): Expect => ({ parsed: { kind: "date", query: { op: "days_until" } }, response: { decision: "answer", intent: "date", title: `${n} days` }, copy: String(n) });
const files = (query: Record<string, unknown>): Expect => ({ parsed: { kind: "file_search", query }, response: { decision: "list", intent: "file_search" } });
const openApp = (bundleId: string): Expect => ({ parsed: { kind: "open" }, response: { decision: "act", intent: "open_app", action: { type: "openApp", bundleId }, confirm: false } });
const openUrl = (url: string, intent = "url"): Expect => ({ response: { decision: "act", intent, action: { type: "openURL", url }, confirm: false } });
const system = (op: string, value?: number | boolean): Expect => ({ parsed: { kind: "system", op }, response: { decision: "act", intent: "system", action: { type: "system", op, ...(value !== undefined ? { value } : {}) } } });
const refuse: Expect = { parsed: { kind: "refuse" }, response: { decision: "refuse", code: "file_deletion_blocked" } };
const through = (reason: string): Expect => ({ response: { decision: "fallthrough", reason } });

const MARCH = { fromMs: new Date(2026, 2, 1).getTime(), toMs: new Date(2026, 3, 1).getTime() };
const YESTERDAY = { fromMs: new Date(2026, 9, 1).getTime(), toMs: new Date(2026, 9, 2).getTime() };

const PROTOTYPE_82: [string, Expect][] = [
  // calculator EN
  ["2^32", { ...calc("4294967296"), response: { title: "4,294,967,296", subtitle: "2^32" } }],
  ["what's two to the power of thirty two", calc("4294967296")],
  ["15% of 340", calc("51")],
  ["what is fifteen percent of three hundred and forty", calc("51")],
  ["square root of 625", calc("25")],
  ["20% off 80", calc("64")],
  ["15% tip on 42", calc("6.3")],
  ["80 + 15%", calc("92")],
  ["(3 + 4) * 12 / 2", calc("42")],
  ["one point five times four", calc("6")],
  ["5 factorial", calc("120")],
  ["a million divided by 8", calc("125000")],
  ["12 x 12", calc("144")],
  ["1,000 * 3", calc("3000")],
  // calculator DE
  ["wie viel sind 15 prozent von 340", calc("51")],
  ["wie viel sind fünfzehn prozent von dreihundertvierzig", calc("51")],
  ["was ist zwei hoch zweiunddreißig", calc("4294967296")],
  ["rechne 7 mal 6", calc("42")],
  ["wurzel aus 144", calc("12")],
  ["zweihundertfünfzig geteilt durch fünf", calc("50")],
  // conversions
  ["5 miles in km", unit("5 miles to km", "8.04672 km")],
  ["five miles to kilometers", unit("5 miles to km", "8.04672 km")],
  ["5 meilen in km", unit("5 miles to km")],
  ["72 fahrenheit in celsius", unit("72 °F to °C", "≈ 22.2222 °C")],
  ["100 usd in eur", { ...currency(100, "USD", "EUR"), response: { title: "89.09 EUR" } }],
  ["$100 to euro", currency(100, "USD", "EUR")],
  ["hundert dollar in euro", currency(100, "USD", "EUR")],
  ["50 franken in euro", currency(50, "CHF", "EUR")],
  ["10k usd in gbp", currency(10_000, "USD", "GBP")],
  ["5 pounds in kg", unit("5 lb to kg", "2.26796185 kg")],
  ["255 in hex", base("255 to hex", "0xff")],
  ["0xff in decimal", base("0xff to decimal", "255")],
  ["255 to binary", base("255 to binary", "0b11111111")],
  // time zones and dates
  ["time in tokyo", time("Asia/Tokyo")],
  ["what time is it in new york", time("America/New_York")],
  ["wie spät ist es in tokio", time("Asia/Tokyo")],
  ["time in kathmandu", time("Asia/Kathmandu")],
  ["days until christmas", days(84)],
  ["how many days until 31 mar", days(180)],
  ["wie viele tage bis weihnachten", days(84)],
  // files
  ["search my computer for the invoice from March", files({ terms: ["invoice"], range: MARCH })],
  ["find my resume", files({ terms: ["resume"] })],
  ["find pdfs about taxes", files({ terms: ["taxes"], contentType: "com.adobe.pdf" })],
  ["where is the screenshot from yesterday", files({ contentType: "public.image", range: YESTERDAY })],
  ["suche auf meinem computer nach der rechnung vom märz", files({ terms: ["rechnung"], range: MARCH })],
  ["finde den vertrag", files({ terms: ["vertrag"] })],
  // apps and URLs
  ["open figma", openApp("com.figma.Desktop")],
  ["launch spotify", openApp("com.spotify.client")],
  ["switch to slack", openApp("com.tinyspeck.slackmacgap")],
  ["öffne figma", openApp("com.figma.Desktop")],
  ["starte den rechner", openApp("com.apple.calculator")],
  ["open vs code", openApp("com.microsoft.VSCode")],
  ["open vsc", openApp("com.microsoft.VSCode")],
  ["go to example dot com", openUrl("https://example.com")],
  // system (v1: volume + display sleep only)
  ["turn on dark mode", { parsed: null, ...through("no_match") }],
  ["dunkelmodus aus", { parsed: null, ...through("no_match") }],
  ["set volume to thirty percent", system("volume.set", 0.3)],
  ["lautstärke auf 30 prozent", system("volume.set", 0.3)],
  ["mute", system("volume.mute", true)],
  ["lock screen", { parsed: null, ...through("no_match") }],
  ["bildschirm sperren", { parsed: null, ...through("no_match") }],
  ["sleep display", system("display.sleep")],
  ["restart my mac", { parsed: null, ...through("no_match") }],
  // prohibited
  ["empty trash", refuse],
  ["papierkorb leeren", refuse],
  ["delete the invoice from march", refuse],
  ["move old screenshots to the trash", refuse],
  ["lösche die datei", refuse],
  // web (clipboard is deferred)
  ["google best pizza in berlin", openUrl("https://www.google.com/search?q=best+pizza+in+berlin", "web")],
  ["search youtube for lofi beats", openUrl("https://www.youtube.com/results?search_query=lofi+beats", "web")],
  ["such im internet nach wetter münchen", openUrl("https://duckduckgo.com/?q=wetter+m%C3%BCnchen", "web")],
  ["what's in my clipboard", through("no_match")],
  // must fall through to the agent
  ["summarize this page", through("deictic")],
  ["what is 15% of the total in this spreadsheet", through("deictic")],
  ["reply to this email and say thanks", through("deictic")],
  ["open figma and create a new file", through("compound")],
  ["open the settings in this app", through("deictic")],
  ["search this page for pricing", through("deictic")],
  ["what's the capital of france", through("no_match")],
  ["2024", through("no_match")],
  ["open the pod bay doors", through("no_match")],
  ["fasse diese seite zusammen", through("deictic")],
];

test("prototype fixtures: all 82 cases (v1 scope)", async () => {
  assert.equal(PROTOTYPE_82.length, 82);
  for (const [input, expect] of PROTOTYPE_82) await check(input, expect);
});

test("raycast §23.1 additions and spoken-URL / unit edge cases", async () => {
  await check("1,5 mal 2", calc("3"), "de-DE");
  await check("1.000 * 3", calc("3000"), "de-DE");
  await check("zwei hoch sechzehn minus tausend", calc("64536"));
  await check("5pm london in sf", { parsed: { kind: "time_convert", hour: 17, minute: 0, from: { zone: "Europe/London" }, to: { zone: "America/Los_Angeles" } }, response: { decision: "answer", intent: "time_convert", title: "9:00 AM" } });
  await check("17 uhr berlin in tokio", { parsed: { kind: "time_convert", hour: 17, to: { zone: "Asia/Tokyo" } }, response: { intent: "time_convert", title: "00:00" } });
  await check("monday in 3 weeks", { parsed: { kind: "date", query: { op: "weekday_in", weekday: 1, weeks: 3 } }, response: { intent: "date", title: "Mon, Oct 19, 2026" } });
  await check("in 3 weeks", { response: { intent: "date", title: "Fri, Oct 23, 2026" } });
  await check("time in narnia", through("unknown_place"));
  await check("2.50 usd in eur", currency(2.5, "USD", "EUR"));
  await check("open github dot com", openUrl("https://github.com"));
  await check("github.com", openUrl("https://github.com"));
  await check("open youtube", openUrl("https://www.youtube.com/"));
  await check("search the web for best espresso grinder", { response: { decision: "act", intent: "web", title: "Search the web for “best espresso grinder”", action: { url: "https://duckduckgo.com/?q=best+espresso+grinder" } } });
  await check("5 km + 300 m", { response: { decision: "answer", intent: "unit", title: "5.3 km" } });
  await check("340 * 15%", calc("51"));
  await check("+49 176 1234", through("no_match"));
  await check("2026-10-02", through("no_match"));
  await check("delete the last sentence", through("no_match"));
  await check("remove the bold formatting", through("no_match"));
  await check("how do i delete a file in python", through("no_match"));
  await check("die alten downloads löschen", refuse);
  await check("rm -rf ~/Downloads", refuse);
  await check("in den papierkorb verschieben", refuse);
  await check("delete this file", refuse);
  // An edit-object word describing files is still file deletion; uninstalling and emptying folders too.
  await check("delete duplicate files in my downloads folder", refuse);
  await check("remove duplicate photos", refuse);
  await check("doppelte fotos löschen", refuse);
  await check("delete empty folders", refuse);
  await check("uninstall slack", refuse);
  await check("slack deinstallieren", refuse);
  await check("empty my downloads folder", refuse);
  await check("leere den download-ordner", refuse);
  await check("den downloads-ordner leeren", refuse);
  await check("delete duplicate rows", through("no_match"));
  await check("remove blank lines", through("no_match"));
  await check("remove the background from the photo", through("no_match"));
  await check("how do i uninstall slack", through("no_match"));
  await check("empty folders in downloads", { parsed: null });
  await check("leere ordner finden", { parsed: null });
  await check("zwölfhundert minus einhundertzwölf", calc("1088"));
  await check("open readme.md", through("no_match"));
  await check("find a restaurant nearby", through("no_match"));
  await check("days until friday", { response: { intent: "date", title: "7 days" } });
  await check("what day is christmas", { response: { intent: "date", title: "Friday" } });
  await check("turn it up", system("volume.step", 0.1));
  await check("leiser", system("volume.step", -0.1));
  await check("unmute", system("volume.mute", false));
  await check("bildschirm aus", system("display.sleep"));
  await check("set volume to 150", through("no_match"));
  // Weak file verbs need evidence (kind, scope, date, document noun); the echo host would otherwise list a file.
  await check("where is my order", through("no_match"));
  await check("where is the nearest pharmacy", through("no_match"));
  await check("find out who won the game", through("no_match"));
  await check("show me the weather", through("no_match"));
  await check("where is the contract from march", files({ terms: ["contract"], range: MARCH }));
  await check("where is budget.xlsx", files({ terms: ["budget.xlsx"] }));
});

/** Ordinary text editing and in-app edits: never a file-deletion refusal (AGENTS.md: preserve ordinary text editing). */
const TEXT_EDITS = [
  "delete it", "delete this", "delete that", "please delete that", "erase the last sentence", "delete the comma", "remove the semicolon",
  "remove the quotes", "delete the period at the end", "delete everything I typed", "delete what I just typed",
  "delete everything after the comma", "delete the title", "delete the heading", "delete the signature", "delete the greeting",
  "delete the intro", "remove the exclamation mark", "delete the rest", "delete all of it", "delete the image from the document",
  "lösch das", "lösche es", "lösche alles", "lösche alles was ich getippt habe", "entferne die Fettformatierung",
  "entferne den Fettdruck", "entferne das Komma", "lösche die Überschrift", "lösche den Titel", "lösche die Anrede",
  "lösch den Punkt am Ende", "entferne die Anführungszeichen",
  // in-app content, not files
  "delete the draft", "delete my last message", "delete the note", "lösche den Termin", "lösche die Nachricht", "lösche die Folie",
];

/** File deletion, trash, uninstalling and shell deletion commands stay refused. */
const FILE_DELETIONS = [
  "erase report.pdf", "rm report.pdf", "trash report.pdf", "delete ~/Downloads/report.pdf", "delete the zip files", "delete my documents",
  "lösche alle Dateien", "lösche das Programm", "remove Zoom from my mac", "erase the disk", "wipe my hard drive",
  "empty the trash", "can you empty the trash", "could you empty the trash", "kannst du den papierkorb leeren", "please empty the trash",
  "how about you empty the trash", "find old screenshots and move them to the trash", "trash the old pdfs", "trash it", "del report.pdf",
  "shred secrets.txt", "rm -rf ~/Downloads", "rm -rf ~", "find old screenshots and delete them", "i want to uninstall slack",
  // a bare object that is exactly an installed app: uninstalling moves it to the Trash
  "delete Slack", "lösche Slack", "slack löschen",
];

test("deletion grammar: text editing and in-app edits are never refused; bare pronouns go to the agent as deictic", async () => {
  for (const input of TEXT_EDITS) {
    const response = await check(input, {});
    assert.equal(response.decision, "fallthrough", input);
    const typing = await dispatcher.dispatch({ text: input, phase: "typing", seq: 1 });
    assert.notEqual(typing.decision, "refuse", `${input} (typing)`);
  }
  for (const input of ["delete it", "please delete that", "delete everything I typed", "delete all of it", "lösch das", "lösche alles was ich getippt habe"]) {
    await check(input, { parsed: { kind: "fallthrough", reason: "deictic" }, response: { decision: "fallthrough", reason: "deictic" } });
  }
  // A deictic file object is still a deletion: the deletion rule runs before the bare-edit route.
  await check("delete this file", refuse);
  // Unknown in-app objects are not apps: no refusal.
  await check("delete figma file comments", through("no_match"));
});

test("deletion grammar: files, trash, uninstalling and shell commands stay refused", async () => {
  for (const input of FILE_DELETIONS) await check(input, { response: { decision: "refuse", code: "file_deletion_blocked" } });
});

test("deletion grammar: questions, how-tos, searches and unrelated words are answered, not refused", async () => {
  for (const input of [
    "how do I empty the trash", "wie leere ich den Papierkorb", "what happens when I empty the trash", "why can't I empty the trash",
    "how to empty trash on mac", "del taco opening hours", "del mar weather", "trash talk examples", "trash day", "trash can sizes",
    "remind me to empty the bin", "rm williams boots", "erase una vez", "shred guitar lessons", "del toro movies",
  ]) await check(input, through("no_match"));
  await check("google how to empty the trash", openUrl("https://www.google.com/search?q=how+to+empty+the+trash", "web"));
  await check("search the web for how to empty the trash", openUrl("https://duckduckgo.com/?q=how+to+empty+the+trash", "web"));
  for (const input of ["find files to delete", "show me large files I could delete", "search for empty trash shortcut"]) {
    const response = await check(input, {});
    assert.ok(response.decision === "list" || response.decision === "fallthrough", `${input}: ${response.decision}`);
  }
});

/** laya §12 (49 EN/DE utterances). Agent tasks (g*) and the c5 word problem must fall through. */
const LAYA_49: [string, string, Expect][] = [
  ["c1", "what's 15 percent of 240", calc("36")],
  ["c2", "square root of 1764 divided by 6", calc("7")],
  ["c3", "wie viel ist 17 mal 23", calc("391")],
  ["c4", "was ergibt zwei hoch sechzehn minus tausend", calc("64536")],
  ["c5", "rechne aus, wie viel ich im Monat sparen muss, um in drei Jahren 20.000 Euro zu haben", through("no_match")],
  ["v1", "convert 72 fahrenheit to celsius", unit("72 °F to °C")],
  ["v2", "how many euros is 250 dollars", currency(250, "USD", "EUR")],
  ["v3", "wie viel sind 3 Kilo in Pfund", unit("3 kg to lb")],
  ["v4", "rechne 5 Meilen in Kilometer um", unit("5 miles to km")],
  ["t1", "what time is it in Tokyo right now", time("Asia/Tokyo")],
  ["t2", "how many days until Christmas", days(84)],
  ["t3", "welcher Wochentag ist der 3. Oktober", { parsed: { kind: "date", query: { op: "weekday_of" } }, response: { intent: "date", title: "Samstag" } }],
  ["t4", "wie spät ist es gerade in New York", time("America/New_York")],
  ["f1", "find the PDF about my apartment lease I downloaded last week", files({ terms: ["apartment", "lease"], contentType: "com.adobe.pdf" })],
  ["f2", "where is the keynote for the Q3 board meeting", files({ terms: ["q3", "board", "meeting"], contentType: "public.presentation" })],
  // laya labels f3 file_search (ambiguous with mail search); a document noun + date make it a file query, and no hits fall through.
  ["f3", "such die Rechnung von der Telekom aus dem August", files({ terms: ["rechnung", "telekom"], range: { fromMs: new Date(2026, 7, 1).getTime(), toMs: new Date(2026, 8, 1).getTime() } })],
  ["f4", "finde meine Präsentation über Projekt Phoenix", files({ terms: ["projekt", "phoenix"], contentType: "public.presentation" })],
  ["a1", "open Spotify", openApp("com.spotify.client")],
  ["a2", "switch to the terminal", openApp("com.apple.Terminal")],
  ["a3", "öffne die Systemeinstellungen", openApp("com.apple.systempreferences")],
  ["a4", "wechsle zu Xcode", openApp("com.apple.dt.Xcode")],
  ["w1", "search the web for the best ramen in Berlin", openUrl("https://duckduckgo.com/?q=best+ramen+in+Berlin", "web")],
  ["w2", "google how to reset AirPods", openUrl("https://www.google.com/search?q=how+to+reset+AirPods", "web")],
  ["w3", "such im Internet nach den Öffnungszeiten vom Bürgeramt", openUrl("https://duckduckgo.com/?q=%C3%96ffnungszeiten+vom+B%C3%BCrgeramt", "web")],
  ["w4", "google mal das Wetter am Wochenende in Hamburg", openUrl("https://www.google.com/search?q=Wetter+am+Wochenende+in+Hamburg", "web")],
  ["u1", "open github.com", openUrl("https://github.com")],
  ["u2", "go to youtube.com", openUrl("https://youtube.com")],
  ["u3", "öffne spiegel.de", openUrl("https://spiegel.de")],
  ["u4", "ruf heise.de auf", openUrl("https://heise.de")],
  ["s1", "turn on do not disturb", through("no_match")], // not a v1 system op
  ["s2", "set the volume to 20 percent", system("volume.set", 0.2)],
  ["s3", "schalte Bluetooth aus", through("no_match")],
  ["s4", "mach den Dunkelmodus an", through("no_match")],
  ["d1", "type: see you tomorrow at nine, thanks!", through("no_match")],
  ["d2", "dictate: the quarterly numbers look good, let's ship it", through("no_match")],
  ["d3", "schreib: Ich komme heute etwas später, sorry", through("no_match")],
  ["d4", "tippe ein: Vielen Dank für die schnelle Antwort", through("no_match")],
  ["g1", "summarize this article in three bullet points", through("deictic")],
  ["g2", "reply to this email and tell him Tuesday afternoon works for me", through("deictic")],
  ["g3", "refactor this function to use async await and add unit tests", through("deictic")],
  ["g4", "book a table for two at an Italian restaurant nearby for Friday at 8pm", through("no_match")],
  ["g5", "what's the capital of Australia", through("no_match")],
  ["g6", "open the last email from Lisa", through("no_match")],
  ["g7", "schreib eine kurze Mail an Anna, dass ich heute später komme", through("no_match")],
  ["g8", "was bedeutet diese Fehlermeldung", through("deictic")],
  ["g9", "vergleiche die drei Angebote in diesem Ordner und erstelle eine Tabelle mit den Preisen", through("deictic")],
  ["g10", "übersetze den markierten Text ins Englische", through("deictic")],
  ["g11", "recherchiere die besten Laptops unter 1500 Euro und vergleiche Akkulaufzeit, Gewicht und Preis", through("no_match")],
  ["g12", "trag den Termin aus dieser Mail in meinen Kalender ein", through("deictic")],
];

test("laya §12: 49 EN/DE utterances; every agent task falls through", async () => {
  assert.equal(LAYA_49.length, 49);
  for (const [id, input, expect] of LAYA_49) {
    const response = await check(input, expect);
    if (id.startsWith("g") || id === "c5") assert.equal(response.decision, "fallthrough", `${id} must reach the agent`);
  }
});

test("file-search phrasing produces the host request (synonyms widen the name groups)", async () => {
  fileRequests.length = 0;
  await dispatcher.dispatch({ text: "search my computer for the invoice from March", phase: "final", seq: 1, contextId: "ctx-3f2a" });
  assert.deepEqual(fileRequests.at(-1), { contextId: "ctx-3f2a", nameGroups: [["invoice"], ["rechnung"]], scopes: ["home"], maxResults: 100 });
});

test("grammar parse is microseconds per utterance", () => {
  const inputs = [...PROTOTYPE_82.map(([input]) => input), ...LAYA_49.map(([, input]) => input)];
  for (const input of inputs) parseInstant(normalize(input), ctx);
  const started = performance.now();
  for (let round = 0; round < 20; round++) for (const input of inputs) parseInstant(normalize(input), ctx);
  const perUtterance = ((performance.now() - started) * 1_000) / (20 * inputs.length);
  // As instantPerf.test.ts: PI_OS_PERF_SLACK (e.g. 3) widens the latency bound on slower or loaded machines.
  const slack = Number(process.env.PI_OS_PERF_SLACK ?? "1") || 1;
  assert.ok(perUtterance < 500 * slack, `${perUtterance.toFixed(1)} µs per utterance`);
});

// ---------------------------------------------------------------- voice grammar (DESIGN4 §5.1)

const voiceParse = (input: string, locale?: string) => parseInstant(normalize(input, locale), ctx, { voice: true });
const typedParse = (input: string, locale?: string) => parseInstant(normalize(input, locale), ctx);
/** "target" or "target/weak" or "target/bare"; anything else as its kind. */
function voiceOpen(input: string, locale?: string): string {
  const parsed = voiceParse(input, locale);
  if (parsed?.kind !== "open") return parsed?.kind ?? "null";
  const strength = openStrength(parsed);
  return strength === "strong" ? parsed.target : `${parsed.target}/${strength}`;
}

test("voice: EN wrapper families reduce to the open target", () => {
  for (const input of [
    "open Pages", "Okay, open Pages.", "Um, open Pages.", "Hey, open Pages.", "So open Pages.", "Hey pi, open Pages.", "Open, Pages.",
    "Open Pages for me.", "Can you open Pages for me?", "Could you open Pages please?", "Would you mind opening Pages?",
    "Go ahead and open Pages.", "I want to open Pages.", "I'd like to open Pages.", "Let's open Pages.", "Just open Pages.",
    "Open open Pages.", "Open up Pages.", "Start up Pages.", "Switch over to Pages.", "Switch back to Pages.", "Jump to Pages.",
    "Bring Pages to the front.", "Pull Pages up.", "Get Pages up.", "Switch to the Pages window.", "Open the Pages app.",
    "Okay so open Pages please.", "Open Pages now.", "Can you launch Pages?",
  ]) assert.equal(voiceOpen(input), "pages", input);
});

test("voice: German verb-first, particles, verb-final and split forms", () => {
  for (const input of [
    "Öffne Pages.", "Öffne bitte Pages.", "Öffne mir bitte Pages.", "Öffne mal Pages.", "Öffne Pages bitte.", "Öffne Pages für mich.",
    "Pages öffnen.", "Pages bitte öffnen.", "Bitte Pages öffnen.", "Kannst du Pages öffnen?", "Kannst du mal Pages aufmachen?",
    "Könntest du bitte Pages starten?", "Ich will Pages öffnen.", "Ich möchte Pages öffnen.", "Pages starten.", "Pages aufrufen.",
    "Mach Pages auf.", "Mach mal Pages auf.", "Mach bitte Pages auf.", "Mach mir mal Pages auf.", "Hol Pages nach vorne.",
    "Hol mir Pages her.", "Ruf Pages auf.", "Starte mal Pages.", "Starte bitte Pages.", "Wechsel zu Pages.", "Wechsle in Pages.",
    "Geh mal zu Pages.", "Okay, öffne Pages.", "Äh, öffne Pages.", "Also öffne Pages.", "Hey pi, öffne Pages.",
    "Öffne das Programm Pages.",
  ]) assert.equal(voiceOpen(input, "de-DE"), "pages", input);
  // Particles never end up in the target.
  assert.equal(voiceOpen("Öffne mir bitte mal die Systemeinstellungen.", "de-DE"), "systemeinstellungen");
  assert.equal(voiceOpen("Kannst du mir bitte Notion Calendar öffnen?", "de-DE"), "notion calendar");
  assert.equal(voiceOpen("Kannst du mir mal Pages aufmachen?", "de-DE"), "pages");
  assert.equal(voiceOpen("Könntest du uns bitte die Systemeinstellungen öffnen?", "de-DE"), "systemeinstellungen");
});

test("voice: weak verbs, indefinite objects and bare names are marked; noise words are not names", () => {
  assert.equal(voiceOpen("Show me Pages."), "pages/weak");
  assert.equal(voiceOpen("Zeig mir Pages.", "de-DE"), "pages/weak");
  assert.equal(voiceOpen("Focus Ghostty."), "ghostty/weak");
  assert.equal(voiceOpen("Open a new tab."), "a new tab/weak");
  assert.equal(voiceOpen("Starte einen Timer.", "de-DE"), "einen timer/weak");
  assert.equal(voiceOpen("Spotify."), "spotify/bare");
  assert.equal(voiceOpen("Notion Calendar, please."), "notion calendar/bare");
  for (const input of ["Yes.", "No.", "Okay.", "Thanks.", "Danke.", "Hmm.", "Open.", "Launch.", "Hallo.", "Page 2.", "Tell me a joke about cats."]) {
    assert.notEqual(voiceParse(input)?.kind, "open", input);
  }
  // Known site names keep their fallback URL; a bare site name does not open it.
  assert.deepEqual(voiceParse("Okay, open YouTube."), { kind: "open", target: "youtube", siteUrl: "https://www.youtube.com/" });
  assert.equal(voiceOpen("YouTube."), "youtube/bare");
  assert.equal(voiceParse("YouTube.")?.kind === "open" && "siteUrl" in voiceParse("YouTube.")!, false);
});

test("voice: the target keeps App Store and page names (no 'app '/'page ' prefix eats them)", () => {
  assert.equal(voiceOpen("Open App Store."), "app store");
  assert.equal(voiceOpen("Open page is."), "page is");
  assert.equal(voiceOpen("Open the App Store app."), "app store");
  assert.equal(typedParse("open app store")?.kind === "open" && typedParse("open app store")!.kind, "open");
  assert.deepEqual(typedParse("open app store"), { kind: "open", target: "app store" });
  assert.deepEqual(typedParse("open page is"), { kind: "open", target: "page is" });
  // …but a URL after "page"/"app" still opens, and typed known-site names keep today's fallback.
  for (const parse of [typedParse, voiceParse]) {
    assert.deepEqual(parse("open the page github.com"), { kind: "url", url: "https://github.com", label: "github.com" });
  }
  assert.deepEqual(typedParse("open the app youtube"), { kind: "open", target: "app youtube", siteUrl: "https://www.youtube.com/" });
  assert.deepEqual(typedParse("öffne die app youtube", "de-DE"), { kind: "open", target: "app youtube", siteUrl: "https://www.youtube.com/" });
  assert.deepEqual(typedParse("open page x"), { kind: "open", target: "page x", siteUrl: "https://x.com/" });
});

test("voice: URLs keep their punctuation through the spoken core", () => {
  for (const [input, url] of [
    ["Open https://github.com.", "https://github.com"], ["Okay, open https://github.com.", "https://github.com"],
    ["Go to example.com/search?q=pizza", "https://example.com/search?q=pizza"], ["Open example.com:8080.", "https://example.com:8080"],
  ] as const) {
    const parsed = voiceParse(input);
    assert.equal(parsed?.kind === "url" ? parsed.url : null, url, input);
    assert.deepEqual(parsed, typedParse(input.replace(/^okay, /i, "")), input);
  }
});

test("voice: policy runs on the raw text and again on the core; wrappers never hide deletion or deixis", () => {
  for (const input of ["Okay, empty the trash.", "Kannst du bitte den Papierkorb leeren?", "Um, delete this file.", "Go ahead and delete my downloads."]) {
    assert.equal(voiceParse(input, /[äöü]|kannst/i.test(input) ? "de-DE" : undefined)?.kind, "refuse", input);
  }
  // "delete <app>" is refused by the dispatcher when the object is an installed app: the core names it cleanly.
  assert.deepEqual(voiceParse("Can you delete Pages for me?"), { kind: "delete_target", target: "pages" });
  assert.deepEqual(voiceParse("Okay, delete Spotify please."), { kind: "delete_target", target: "spotify" });
  assert.deepEqual(typedParse("Can you delete Pages for me?"), { kind: "delete_target", target: "pages for me" });
  // Spoken text editing is never refused, wrapped or not (AGENTS.md: preserve ordinary text editing).
  for (const edit of TEXT_EDITS) {
    for (const input of [edit, `okay, ${edit}`, `um, ${edit} please`, `can you ${edit} for me`, `kannst du mal ${edit}`]) {
      assert.notEqual(voiceParse(input)?.kind, "refuse", input);
    }
  }
  for (const input of FILE_DELETIONS) assert.ok(["refuse", "delete_target"].includes(voiceParse(`okay, ${input} please`)?.kind ?? ""), input);
  assert.deepEqual(voiceParse("Okay, summarize this page."), { kind: "fallthrough", reason: "deictic" });
  // A wrapped bare edit stays deictic (the agent gets the screen); it is never guessed as a name said alone.
  for (const input of ["Okay, delete it.", "Um, delete it please.", "Okay, lösche alles."]) {
    assert.deepEqual(voiceParse(input, /lösche/.test(input) ? "de-DE" : undefined), { kind: "fallthrough", reason: "deictic" }, input);
  }
  // "Go ahead and open X" is one request; "open X and write Y" stays a compound.
  assert.equal(voiceOpen("Go ahead and open Pages."), "pages");
  assert.deepEqual(voiceParse("Open Pages and write a letter."), { kind: "fallthrough", reason: "compound" });
  assert.deepEqual(voiceParse("Öffne Pages und schreib einen Brief.", "de-DE"), { kind: "fallthrough", reason: "compound" });
});

test("voice: the core parse also reaches the other instant intents", () => {
  assert.deepEqual(voiceParse("Okay, what's 17 times 23?"), { kind: "calc", expression: "17 * 23", display: "17 × 23", units: false });
  assert.equal(voiceParse("Mach mal lauter.", "de-DE")?.kind, "system");
  assert.deepEqual(voiceParse("Turn the volume down a bit."), { kind: "system", op: "volume.step", value: -0.1, title: "Volume down" });
  assert.deepEqual(voiceParse("Could you mute the sound please?"), { kind: "system", op: "volume.mute", value: true, title: "Mute" });
  assert.deepEqual(voiceParse("Make it louder."), { kind: "system", op: "volume.step", value: 0.1, title: "Volume up" });
  assert.equal(voiceParse("Um, open github dot com.")?.kind, "url");
});

test("typed text keeps today's grammar (spoken forms are voice-only)", async () => {
  for (const input of [
    "could you bring figma up", "pages öffnen", "mach mal figma auf", "show me figma", "figma", "switch over to figma", "bring figma to the front",
    "okay open figma", "open figma for me",
  ]) {
    const typed = typedParse(input);
    assert.ok(typed === null || typed.kind !== "open" || typed.target !== "figma", `${input}: ${JSON.stringify(typed)}`);
  }
  // Typed open parses never carry a strength.
  assert.deepEqual(typedParse("open a new window"), { kind: "open", target: "a new window" });
  // "zeig mir" stays a typed open form; a leading "app" word still finds the app.
  await check("zeig mir figma", openApp("com.figma.Desktop"));
  await check("open the app figma", openApp("com.figma.Desktop"));
  await check("öffne die app spotify", openApp("com.spotify.client"));
  await check("mach die app slack auf", openApp("com.tinyspeck.slackmacgap"));
  // Unambiguous volume phrasings are a strict improvement for typing too.
  await check("make it louder", system("volume.step", 0.1));
  await check("turn down the volume", system("volume.step", -0.1));
});
