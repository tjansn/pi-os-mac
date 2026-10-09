import assert from "node:assert/strict";
import { test } from "node:test";
import type { AppRecord } from "../src/contracts/launcher.js";
import { AppMatcher, SPOKEN, type AppMatch, type AppMatchReason } from "../src/instant/apps.js";
import { parseInstant } from "../src/instant/grammar/index.js";
import { isKnownSpokenHost, KNOWN_SPOKEN_DOMAINS, openStrength, SITE_HOME } from "../src/instant/grammar/launch.js";
import { isCommonWord, warmLexicon } from "../src/instant/lexicon.js";
import { LEXICON_WORD_COUNT } from "../src/instant/lexiconData.js";
import { normalize } from "../src/instant/normalize.js";
import { colognePhonetic, damerau, doubleMetaphone, editSimilarity, firstSound, phoneticKeys, phoneticSimilarity } from "../src/instant/phonetic.js";
import type { MatchContext } from "../src/instant/types.js";

/*
 * Spoken command core + sound-alike app matcher (DESIGN4 §5.1/§5.2; N1). The voice decision below is what
 * the instant dispatcher does with these APIs for an open form: parseInstant(…, {voice}) → resolveSpoken →
 * act / did-you-mean offers / nothing. The corpus replay regenerates the r3/mapping corpus exactly (3,380
 * phrasings incl. simulated ASR errors, plus 665 negatives; seeded samples kept as index tables) and gates
 * the measured results: open-app acts 46.9 % today → 93.9 %, 0 false actions (today 20 on the negatives).
 * Synthetic text only (TTS-style phrasings and app names from a fixture index); no host, no model, no logs.
 */

// ---------------------------------------------------------------- fixture app index (104 apps)

const DIRS: Readonly<Record<string, string>> = {
  A: "/Applications", S: "/System/Applications", U: "/System/Applications/Utilities", C: "/System/Library/CoreServices", P: "/Applications/Python 3.13",
};
type AppRow = readonly [bundleId: string, name: string, dir: string, aliases?: readonly string[], running?: boolean];
const APP_ROWS: readonly AppRow[] = [
  ["com.1password.1password", "1Password", "A"], ["com.apple.ActivityMonitor", "Activity Monitor", "U"],
  ["com.apple.airport.airportutility", "AirPort Utility", "U"], ["com.if.Amphetamine", "Amphetamine", "A"],
  ["com.apple.AppStore", "App Store", "S"], ["com.apple.apps.launcher", "Apps", "S"],
  ["com.apple.audio.AudioMIDISetup", "Audio MIDI Setup", "U"], ["com.apple.Automator", "Automator", "S"],
  ["com.apple.BluetoothFileExchange", "Bluetooth File Exchange", "U"], ["com.apple.iBooksX", "Books", "S"],
  ["com.brave.Browser", "Brave Browser", "A", ["Brave"], true], ["xyz.block.buzz.app", "Buzz", "A"],
  ["com.apple.calculator", "Calculator", "S"], ["com.apple.iCal", "Calendar", "S"], ["com.openai.codex", "ChatGPT", "A"],
  ["com.apple.Chess", "Chess", "S"], ["com.anthropic.claudefordesktop", "Claude", "A", [], true],
  ["com.anthropic.claude-code-url-handler", "Claude Code URL Handler", "A"], ["com.sabotage.clearly", "Clearly", "A"],
  ["com.apple.clock", "Clock", "S"], ["com.cmuxterm.app", "cmux", "A", [], true], ["com.steipete.codexbar", "CodexBar", "A"],
  ["com.apple.ColorSyncUtility", "ColorSync Utility", "U"], ["com.apple.Console", "Console", "U"], ["com.apple.AddressBook", "Contacts", "S"],
  ["ch.sudo.cyberduck", "Cyberduck", "A"], ["com.apple.Dictionary", "Dictionary", "S"],
  ["com.apple.DigitalColorMeter", "Digital Color Meter", "U"], ["com.apple.DiskUtility", "Disk Utility", "U"],
  ["com.displaylink.DisplayLinkUserAgent", "DisplayLink Manager", "A", ["DisplayLinkUserAgent"]], ["com.apple.FaceTime", "FaceTime", "S"],
  ["com.apple.finder", "Finder", "C", [], true], ["com.apple.findmy", "FindMy", "S"], ["com.apple.FontBook", "Font Book", "S"],
  ["com.apple.freeform", "Freeform", "S"], ["com.apple.games", "Games", "S"], ["com.apple.garageband10", "GarageBand", "A"],
  ["com.mitchellh.ghostty", "Ghostty", "A", [], true], ["com.yourcompany.GoldenCheetah", "GoldenCheetah", "A"],
  ["com.apple.grapher", "Grapher", "U"], ["com.apple.Home", "Home", "S"], ["com.xs-labs.Hot", "Hot", "A"], ["org.python.IDLE", "IDLE", "P"],
  ["com.apple.Image_Capture", "Image Capture", "S"], ["com.apple.GenerativePlaygroundApp", "Image Playground", "S"],
  ["com.apple.iMovieApp", "iMovie", "A"], ["com.apple.ScreenContinuity", "iPhone Mirroring", "S"], ["com.apple.journal", "Journal", "S"],
  ["com.apple.Keynote", "Keynote Creator Studio", "A", ["Keynote"]], ["at.obdev.littlesnitch", "Little Snitch", "A"],
  ["com.apple.Magnifier", "Magnifier", "U"], ["com.apple.mail", "Mail", "S", [], true], ["com.apple.Maps", "Maps", "S"],
  ["com.apple.MobileSMS", "Messages", "S"], ["com.apple.MigrateAssistant", "Migration Assistant", "U"],
  ["com.apple.exposelauncher", "Mission Control", "S"], ["com.apple.Music", "Music", "S"], ["com.apple.news", "News", "S"],
  ["com.apple.Notes", "Notes", "S"], ["notion.id", "Notion", "A", [], true], ["com.cron.electron", "Notion Calendar", "A"],
  ["notion.mail.id", "Notion Mail", "A"], ["com.apple.Numbers", "Numbers Creator Studio", "A", ["Numbers"]],
  ["com.electron.ollama", "Ollama", "A"], ["io.open-design.desktop", "Open Design", "A"], ["com.stablyai.orca", "Orca", "A", [], true],
  ["com.apple.Pages", "Pages Creator Studio", "A", ["Pages"]], ["com.apple.Passwords", "Passwords", "S"],
  ["com.apple.mobilephone", "Phone", "S"], ["com.apple.PhotoBooth", "Photo Booth", "S"], ["com.apple.Photos", "Photos", "S"],
  ["com.apple.podcasts", "Podcasts", "S"], ["com.apple.Preview", "Preview", "S"], ["com.apple.printcenter", "Print Center", "U"],
  ["org.python.PythonLauncher", "Python Launcher", "P"], ["com.apple.QuickTimePlayerX", "QuickTime Player", "S"],
  ["com.raycast.macos", "Raycast", "A"], ["com.apple.reminders", "Reminders", "S"], ["com.apple.Safari", "Safari", "A"],
  ["com.apple.ScreenSharing", "Screen Sharing", "U"], ["com.apple.screenshot.launcher", "Screenshot", "U"],
  ["com.apple.ScriptEditor2", "Script Editor", "U"], ["com.apple.shortcuts", "Shortcuts", "S"], ["com.apple.siri.launcher", "Siri", "S"],
  ["com.apple.campo", "Siri AI", "S"], ["com.spotify.client", "Spotify", "A", [], true], ["com.apple.Stickies", "Stickies", "S"],
  ["com.apple.stocks", "Stocks", "S"], ["com.apple.SystemProfiler", "System Information", "U"],
  ["com.apple.systempreferences", "System Settings", "S"], ["io.tailscale.ipn.macsys", "Tailscale", "A"],
  ["ru.keepcoder.Telegram", "Telegram", "A", [], true], ["com.apple.Terminal", "Terminal", "U"], ["com.apple.TextEdit", "TextEdit", "S"],
  ["com.macpaw.site.theunarchiver", "The Unarchiver", "A"], ["com.apple.backup.launcher", "Time Machine", "S"],
  ["com.apple.helpviewer", "Tips", "S"], ["net.tunnelblick.tunnelblick", "Tunnelblick", "A"], ["com.apple.TV", "TV", "S"],
  ["com.apple.VoiceMemos", "VoiceMemos", "S"], ["com.apple.VoiceOverUtility", "VoiceOver Utility", "U"],
  ["com.apple.weather", "Weather", "S"], ["com.apple.dt.Xcode", "Xcode", "A"], ["dev.zed.Zed", "Zed", "A"],
];
const FIXTURE_APPS: AppRecord[] = APP_ROWS.map(([bundleId, name, dir, aliases = [], running = false]) => ({
  bundleId, name, aliases: [...aliases], path: `${DIRS[dir]}/${name}.app`, running,
}));

// ---------------------------------------------------------------- voice decision (what the dispatcher does)

type Outcome =
  | { kind: "act"; app?: string; url?: string; intent: string; op?: string }
  | { kind: "offer"; apps: string[] }
  | { kind: "answer" | "list"; intent: string }
  | { kind: "refuse" }
  | { kind: "none" };

const NOW = new Date(2026, 9, 2, 19, 30);
const localeOf = (lang: string): string => (lang === "de" ? "de-DE" : "en-US");

/** One utterance → outcome. `voice` false is today's path: typed grammar and literal tiers (AppMatcher.match + decisive). */
function decide(matcher: AppMatcher, text: string, lang: string, voice = true): Outcome {
  const locale = localeOf(lang);
  const n = normalize(text, locale);
  const ctx: MatchContext = { now: NOW, locale, webSearchTemplate: "https://duckduckgo.com/?q=%s" };
  const parsed = parseInstant(n, ctx, { voice });
  if (!parsed) return { kind: "none" };
  switch (parsed.kind) {
    case "fallthrough":
      return { kind: "none" };
    case "refuse":
      return { kind: "refuse" };
    case "delete_target":
      return matcher.match(parsed.target).some((m) => m.score >= 1) ? { kind: "refuse" } : { kind: "none" };
    case "url":
      return { kind: "act", intent: "url", url: new URL(parsed.url).hostname };
    case "web":
      return { kind: "act", intent: "web" };
    case "system":
      return { kind: "act", intent: "system", op: parsed.op };
    case "file_search":
      return { kind: "list", intent: "file_search" };
    case "open": {
      if (!voice) {
        const matches = matcher.match(parsed.target);
        if (parsed.siteUrl && !(matches[0] && matches[0].score >= 1)) return { kind: "act", intent: "url", url: new URL(parsed.siteUrl).hostname };
        const decisive = AppMatcher.decisive(matches);
        if (decisive) return { kind: "act", intent: "open_app", app: decisive.app.bundleId };
        return matches.length ? { kind: "offer", apps: matches.map((m) => m.app.bundleId) } : { kind: "none" };
      }
      const resolved = matcher.resolveSpoken(parsed.target, openStrength(parsed), { german: locale.startsWith("de") || n.lang === "de" });
      if (parsed.siteUrl && !resolved.exact) return { kind: "act", intent: "url", url: new URL(parsed.siteUrl).hostname };
      if (!resolved.decision) return { kind: "none" };
      if (resolved.decision.kind === "act") return { kind: "act", intent: "open_app", app: resolved.decision.match.app.bundleId };
      return { kind: "offer", apps: resolved.decision.matches.map((m) => m.app.bundleId) };
    }
    default:
      return { kind: "answer", intent: parsed.kind };
  }
}

const opened = (outcome: Outcome): string | undefined => (outcome.kind === "act" ? outcome.app : undefined);
const offered = (outcome: Outcome): string[] => (outcome.kind === "offer" ? outcome.apps : []);

// ---------------------------------------------------------------- behaviour

const small = new AppMatcher([
  ["com.apple.Pages", "Pages Creator Studio", ["Pages"]], ["com.apple.Keynote", "Keynote Creator Studio", ["Keynote"]], ["notion.id", "Notion"],
  ["com.cron.electron", "Notion Calendar"], ["com.brave.Browser", "Brave Browser", ["Brave"]], ["com.apple.iCal", "Calendar"],
  ["com.apple.weather", "Weather"], ["com.apple.finder", "Finder"], ["com.apple.BluetoothFileExchange", "Bluetooth File Exchange"],
  ["com.apple.news", "News"], ["com.spotify.client", "Spotify"], ["dev.zed.Zed", "Zed"], ["com.mitchellh.ghostty", "Ghostty"],
  ["ru.keepcoder.Telegram", "Telegram"], ["com.raycast.macos", "Raycast"],
].map(([bundleId, name, aliases]) => ({ bundleId: bundleId as string, name: name as string, aliases: [...(aliases ?? [])] as string[], path: `/Applications/${name}.app`, running: false })));
const voiceSmall = (text: string, lang = /[öäü]|^(?:mach|kannst|ich|starte|hol|ruf|wechsel|geh)\b/i.test(text) ? "de" : "en") => decide(small, text, lang);

test("voice finals open the app for the natural EN/DE phrasings that used to fall through", () => {
  for (const text of [
    "Okay, open Pages.", "Open Pages for me.", "Open up Pages.", "Hey, open Pages.", "Go ahead and open Pages.", "Open, Pages.", "Open open Pages.",
    "Can you open Pages for me?", "Would you mind opening Pages?", "Switch over to Pages.", "Bring Pages to the front.", "Pages öffnen.",
    "Öffne bitte Pages.", "Öffne mir bitte mal Pages.", "Mach mal Pages auf.", "Kannst du Pages öffnen?", "Ich möchte Pages öffnen.",
    "Hol mir Pages her.", "Starte mal Pages.",
  ]) assert.equal(opened(voiceSmall(text)), "com.apple.Pages", text);
  // Tom's "open pages" (and typed text keeps working the way it did).
  assert.equal(opened(voiceSmall("open pages")), "com.apple.Pages");
  assert.equal(opened(decide(small, "open pages", "en", false)), "com.apple.Pages");
});

test("sound-alike names act when clearly ahead and not dictionary words; otherwise they are offered", () => {
  for (const [text, bundleId] of [
    ["Open page is.", "com.apple.Pages"], ["Open ghost T.", "com.mitchellh.ghostty"], ["Launch Spotifei.", "com.spotify.client"],
    ["Open Notion calender.", "com.cron.electron"], ["Open notions.", "notion.id"], ["Open key note.", "com.apple.Keynote"], ["Öffne Keynotes.", "com.apple.Keynote"],
  ] as const) assert.equal(opened(voiceSmall(text)), bundleId, text);
  // Far sound-alikes are offered, not opened: "Kienout" sounds like Keynote but is spelled far from it.
  assert.deepEqual(offered(voiceSmall("Öffne Kienout.")).slice(0, 1), ["com.apple.Keynote"]);
  // Common EN/DE words never act on sound alone: "nation" and German "Telegramm" are offered ("Did you mean …?").
  assert.deepEqual(offered(voiceSmall("Open nation.")).slice(0, 1), ["notion.id"]);
  assert.deepEqual(offered(voiceSmall("Open Telegramm.")).slice(0, 1), ["ru.keepcoder.Telegram"]);
  assert.deepEqual(offered(voiceSmall("Open recast.")).slice(0, 1), ["com.raycast.macos"]);
  // A word that starts with another sound is not even offered.
  assert.deepEqual(voiceSmall("Open lotion."), { kind: "none" });
});

test("false-action guards: generic nouns, partial names, short words, bare dictionary names", () => {
  for (const text of [
    "Open a new window.", "Open the door.", "Bring up file.", "Open the feather.", "Open up the mall.", "Open said.", "Start over.", "Run the tests.",
    "Switch to chat.", "Open the garage.", "Launch cyber.", "Öffne die Tür.", "Starte einen Timer.", "Show me the door.", "Get coffee.",
  ]) assert.notEqual(voiceSmall(text).kind, "act", text);
  // A name said alone opens only when it is unmistakably a name.
  assert.equal(opened(voiceSmall("Spotify.")), "com.spotify.client");
  assert.equal(opened(voiceSmall("Notion Calendar, please.")), "com.cron.electron");
  assert.deepEqual(offered(voiceSmall("Calendar.")), ["com.apple.iCal"]);
  assert.deepEqual(offered(voiceSmall("News.")), ["com.apple.news"], "generic app names are offered");
  assert.deepEqual(offered(voiceSmall("Zed.")), ["dev.zed.Zed"], "short names are offered");
  assert.deepEqual(voiceSmall("Weiter."), { kind: "none" }, "bare names are never matched by sound (Weiter ≠ Wetter)");
  for (const text of ["No.", "Yes.", "Thanks.", "Hmm.", "Open."]) assert.deepEqual(voiceSmall(text), { kind: "none" }, text);
  // Weak verbs open exact names only.
  assert.equal(opened(voiceSmall("Show me Spotify.")), "com.spotify.client");
  assert.notEqual(voiceSmall("Show me Spotifei.").kind, "act");
  // Typed bare names are not commands.
  assert.deepEqual(decide(small, "spotify", "en", false), { kind: "none" });
});

/** A synthetic ranked candidate list for decideSpoken. */
function candidates(...rows: [string, number, AppMatchReason, number?][]): AppMatch[] {
  return rows.map(([name, score, reason, rank]) => ({
    app: { bundleId: `com.example.${name.toLowerCase().replace(/\W/g, "")}`, name, aliases: [], path: `/Applications/${name}.app`, running: false },
    score, rank: rank ?? score, reason,
  }));
}
const kind = (decision: ReturnType<typeof AppMatcher.decideSpoken>): string => (decision ? `${decision.kind}${decision.kind === "offer" ? decision.matches.length : ""}` : "none");

test("voice acceptance thresholds (calibrated): act ≥ 0.82 with a 0.08 lead and ≥ 4 letters; offer ≤ 3 at ≥ 0.66", () => {
  assert.deepEqual({ ...SPOKEN }, {
    actScore: 0.82, actMargin: 0.08, minActLength: 4, offerScore: 0.66, offerWindow: 0.15, maxOffers: 3, weakOfferScore: 0.8,
    partialWordCap: 0.8, exactScore: 0.995, soundFloor: 0.6, soundWeight: 0.95, minLengthRatio: 0.5,
  });
  const d = AppMatcher.decideSpoken;
  // Sound tier.
  assert.equal(kind(d(candidates(["Pages", 0.82, "sound"], ["Pastes", 0.73, "sound"]), "strong", 6)), "act");
  assert.equal(kind(d(candidates(["Pages", 0.819, "sound"]), "strong", 6)), "offer1");
  assert.equal(kind(d(candidates(["Pages", 0.9, "sound"], ["Pastes", 0.821, "sound"]), "strong", 6)), "offer2", "lead < 0.08");
  assert.equal(kind(d(candidates(["Zed", 0.9, "sound"]), "strong", 3)), "offer1", "fewer than 4 letters");
  assert.equal(kind(d(candidates(["Notion", 0.9, "sound"]), "strong", 6, true)), "offer1", "a dictionary word");
  assert.equal(kind(d(candidates(["Pages", 0.9, "sound"]), "weak", 6)), "offer1");
  assert.equal(kind(d(candidates(["Pages", 0.79, "sound"]), "weak", 6)), "none", "weak verbs offer ≥ 0.80 only");
  assert.equal(kind(d(candidates(["Pages", 0.9, "sound"]), "bare", 6)), "none", "bare names never by sound");
  assert.equal(kind(d(candidates(["Pages", 0.659, "sound"]), "strong", 6)), "none");
  // Offers: at most three, within 0.15 of the best.
  assert.equal(kind(d(candidates(["A", 0.8, "sound"], ["B", 0.79, "sound"], ["C", 0.75, "sound"], ["D", 0.7, "sound"]), "strong", 6)), "offer3");
  assert.equal(kind(d(candidates(["A", 0.8, "sound"], ["B", 0.64, "sound"]), "strong", 6)), "offer1");
  // Literal tier.
  assert.equal(kind(d(candidates(["Activity Monitor", 0.85, "word"], ["Monitor", 0.74, "sound"]), "strong", 8)), "act");
  assert.equal(kind(d(candidates(["Activity Monitor", 0.85, "word"], ["Monitor", 0.76, "sound"]), "strong", 8)), "offer2", "lead < 0.10");
  // Exact names.
  assert.equal(kind(d(candidates(["Spotify", 1, "exact"]), "bare", 7)), "act");
  assert.equal(kind(d(candidates(["Notes", 1, "exact"], ["Notes", 1, "alias"]), "strong", 5)), "offer2", "two apps with the same name");
  assert.equal(kind(d(candidates(["Calendar", 1, "exact"]), "bare", 8, true)), "offer1");
  assert.equal(kind(d(candidates(["TV", 1, "exact"]), "bare", 2)), "offer1");
  assert.equal(kind(d(candidates(["News", 1, "exact"]), "bare", 4)), "offer1");
  assert.equal(kind(d(candidates(["Calendar", 1, "exact"]), "weak", 8, true)), "act", "exact names act for weak verbs");
  assert.equal(kind(d([], "strong", 5)), "none");
  // The lead is measured on ranks (frecency/running boosts), the thresholds on scores.
  assert.equal(kind(d(candidates(["Pages", 0.85, "sound", 0.85], ["Pastes", 0.8, "sound", 0.8]), "strong", 6)), "offer2");
  assert.equal(kind(d(candidates(["Pages", 0.85, "sound", 0.95], ["Pastes", 0.8, "sound", 0.8]), "strong", 6)), "act");
});

test("resolveSpoken reports the heard name, the guard, the ranked matches and exact evidence", () => {
  const page = small.resolveSpoken("the page is app", "strong");
  assert.equal(page.heard, "page is");
  assert.equal(page.heardIsWord, false);
  assert.equal(page.decision?.kind === "act" && page.decision.match.app.bundleId, "com.apple.Pages");
  assert.equal(page.decision?.kind === "act" && page.decision.match.label, "Pages");
  assert.equal(page.exact, undefined);
  const nation = small.resolveSpoken("nation", "strong");
  assert.deepEqual([nation.heard, nation.heardIsWord, nation.decision?.kind], ["nation", true, "offer"]);
  assert.equal(small.resolveSpoken("Spotify", "strong").exact?.app.bundleId, "com.spotify.client");
  // An injected dictionary decides the guard (the default is lexicon.ts).
  assert.equal(small.resolveSpoken("nation", "strong", { isCommonWord: () => false }).heardIsWord, false);
  assert.ok(small.resolveSpoken("x".repeat(200), "strong").heard.length <= 80);
});

// ---------------------------------------------------------------- phonetic and lexicon

/** Golden codes from double-metaphone@2.0.1 and cologne-phonetic@1.1.1 (the vendored originals). */
const PHONETIC_GOLDEN: readonly (readonly [string, string, string, string])[] = [
  ["notion", "NXN", "NXN", "626"], ["nation", "NXN", "NXN", "626"], ["calender", "KLNTR", "KLNTR", "45627"],
  ["calendar", "KLNTR", "KLNTR", "45627"], ["pages", "PJS", "PKS", "148"], ["pageis", "PJS", "PKS", "148"], ["keynote", "KNT", "KNT", "462"],
  ["kienout", "KNT", "KNT", "462"], ["spotify", "SPTF", "SPTF", "8123"], ["spotifei", "SPTF", "SPTF", "8123"],
  ["telegram", "TLKRM", "TLKRM", "25476"], ["telegramm", "TLKRM", "TLKRM", "25476"], ["ghostty", "KST", "KST", "482"],
  ["gousti", "KST", "KST", "482"], ["raycast", "RKST", "RKST", "7482"], ["recast", "RKST", "RKST", "7482"], ["xcode", "SKT", "SKT", "4842"],
  ["excode", "AKST", "AKST", "04842"], ["claude", "KLT", "KLT", "452"], ["cloud", "KLT", "KLT", "452"], ["brave", "PRF", "PRF", "173"],
  ["grave", "KRF", "KRF", "473"], ["safari", "SFR", "SFR", "837"], ["sofari", "SFR", "SFR", "837"], ["orca", "ARK", "ARK", "074"],
  ["okra", "AKR", "AKR", "047"], ["systemeinstellungen", "SSTMNSTLNJN", "SSTMNSTLNKN", "88266825646"],
  ["kalender", "KLNTR", "KLNTR", "45627"], ["musik", "MSK", "MSK", "684"], ["nouschen", "NXN", "NSKN", "686"],
  ["michael", "MKL", "MXL", "645"], ["schmidt", "XMT", "SMT", "862"], ["chianti", "KNT", "KNT", "462"], ["edge", "AJ", "AJ", "024"],
  ["laugh", "LF", "LF", "54"], ["thomas", "TMS", "TMS", "268"], ["school", "SKL", "SKL", "85"], ["sugar", "XKR", "SKR", "847"],
  ["caesar", "SSR", "SSR", "487"], ["focaccia", "FKX", "FKX", "348"], ["jose", "HS", "HS", "08"], ["wasserman", "ASRMN", "FSRMN", "38766"],
  ["breaux", "PR", "PR", "1748"], ["zhao", "J", "J", "8"], ["filipowicz", "FLPTS", "FLPFX", "35138"], ["czerny", "SRN", "XRN", "876"],
  ["orchestra", "ARKSTR", "ARKSTR", "074827"], ["architect", "ARKTKT", "ARKTKT", "074282"], ["island", "ALNT", "ALNT", "08562"],
  ["gallegos", "KLKS", "KKS", "4548"], ["mueller", "MLR", "MLR", "657"], ["muller", "MLR", "MLR", "657"],
  ["wikipedia", "AKPT", "FKPT", "3412"], ["breschnew", "PRXN", "PRXNF", "17863"], ["meier", "MR", "MR", "67"], ["mayr", "MR", "MR", "67"],
  ["lotion", "LXN", "LXN", "526"], ["feather", "F0R", "FTR", "327"], ["ghost", "KST", "KST", "482"], ["mehl", "ML", "ML", "65"],
  ["oscar", "ASKR", "ASKR", "087"], ["chatgpt", "XTKPT", "XTKPT", "42412"],
];

test("phonetic: the vendored Double Metaphone and Kölner Phonetik reproduce the original packages", () => {
  for (const [word, primary, secondary, cologne] of PHONETIC_GOLDEN) {
    assert.deepEqual(doubleMetaphone(word), [primary, secondary], word);
    assert.equal(colognePhonetic(word), cologne, word);
  }
  assert.equal(colognePhonetic("Müller-Lüdenscheidt"), "65752682");
  assert.deepEqual(phoneticKeys("pagescreatorstudio").dm.length >= 1, true);
  assert.deepEqual(phoneticKeys("1234"), { dm: [], koeln: "" });
  assert.deepEqual(phoneticKeys("notion"), { dm: ["NXN"], koeln: "626" });
  assert.equal(firstSound(phoneticKeys("lotion")), "L");
  assert.equal(firstSound(phoneticKeys("")), "");
});

test("edit and phonetic similarity", () => {
  assert.equal(damerau("", "abc"), 3);
  assert.equal(damerau("notion", "notion"), 0);
  assert.equal(damerau("calender", "calendar"), 1);
  assert.equal(damerau("ab", "ba"), 1, "an adjacent transposition costs 1");
  assert.equal(damerau("kitten", "sitting"), 3);
  assert.equal(editSimilarity("", ""), 1);
  assert.equal(editSimilarity("pages", "paces"), 0.8);
  assert.equal(phoneticSimilarity(phoneticKeys("nation"), phoneticKeys("notion")), 1);
  assert.equal(phoneticSimilarity(phoneticKeys("abc"), { dm: [], koeln: "" }), 0);
  // Kölner Phonetik counts only for German speech.
  const nambers = phoneticKeys("nambers");
  const numbers = phoneticKeys("numbers");
  assert.ok(phoneticSimilarity(nambers, numbers, true) > phoneticSimilarity(nambers, numbers, false));
});

test("lexicon: a compact EN + DE common-word list (30–50k words) with English plurals", () => {
  warmLexicon();
  assert.ok(LEXICON_WORD_COUNT >= 30_000 && LEXICON_WORD_COUNT <= 50_000, String(LEXICON_WORD_COUNT));
  for (const word of ["feather", "nation", "lotion", "mall", "door", "file", "pages", "batteries", "boxes", "telegramm", "kalender", "mehl", "wetter", "weiter", "tur", "fenster", "rechner"]) {
    assert.equal(isCommonWord(word), true, word);
  }
  for (const word of ["spotify", "ghostty", "raycast", "xcode", "gousti", "spotifei", "kienout", "tom", "boston", "google", "claude", "tv", "ok", "page is", ""]) {
    assert.equal(isCommonWord(word), false, word);
  }
  assert.equal(isCommonWord("Feather"), true, "case-insensitive");
});

test("voice URL guard: only known spoken domains open without a confirm", () => {
  for (const host of ["github.com", "www.youtube.com", "de.wikipedia.org", "mail.google.com", "spiegel.de", "WWW.GITHUB.COM", "news.ycombinator.com", "claude.ai", "github.com."]) {
    assert.equal(isKnownSpokenHost(host), true, host);
  }
  // Recognizers turn "github dot com" into real but wrong domains (r3/asr outputs).
  for (const host of ["guests.com", "up.com", "opengisub.com", "getup.com", "opengitsup.com", "openbeatle.com", "tiktok.com", "github.io", "github.com.example.net", "com"]) {
    assert.equal(isKnownSpokenHost(host), false, host);
  }
  assert.ok(KNOWN_SPOKEN_DOMAINS.size >= 40);
  for (const host of KNOWN_SPOKEN_DOMAINS) assert.match(host, /^[a-z0-9.-]+\.[a-z]{2,}$/);
  // Every site the grammar opens by name is a known spoken domain.
  for (const url of Object.values(SITE_HOME)) assert.equal(isKnownSpokenHost(new URL(url).hostname), true, url);
  for (const text of ["Open YouTube.", "Open GitHub.", "Open Gmail.", "Öffne Wikipedia.", "Open ChatGPT.", "Open Claude.", "Open Hacker News."]) {
    const outcome = decide(new AppMatcher([]), text, /^Öffne/.test(text) ? "de" : "en");
    assert.ok(outcome.kind === "act" && outcome.url && isKnownSpokenHost(outcome.url), `${text}: ${JSON.stringify(outcome)}`);
  }
});

// ---------------------------------------------------------------- corpus replay (r3/mapping)

type Expect =
  | { kind: "open_app"; bundleId: string }
  | { kind: "url"; host: string }
  | { kind: "web" | "file_search" | "calc" | "refuse" }
  | { kind: "system"; op: string }
  | { kind: "agent"; okApp?: string };
interface Item { text: string; lang: string; src: string; expect: Expect }

/** [spoken name, bundle id, German names, DE template picks, picks per German name, mixed picks]: build.py's seed-7 samples. */
const CORPUS_APPS: readonly (readonly [string, string, readonly string[], readonly number[], readonly (readonly number[])[], readonly number[]])[] = [
  ["Pages", "com.apple.Pages", [], [20, 9, 25, 3, 4, 34, 6, 23, 38, 32, 13, 1, 2, 31], [], [3, 0]],
  ["Keynote", "com.apple.Keynote", [], [15, 5, 35, 27, 3, 36, 7, 14, 37, 25, 33, 39, 1, 17], [], [1, 2]],
  ["Numbers", "com.apple.Numbers", [], [26, 9, 34, 7, 36, 19, 35, 11, 6, 12, 23, 3, 17, 22], [], [0, 4]],
  ["Notion", "notion.id", [], [3, 39, 13, 31, 34, 27, 20, 29, 37, 23, 19, 7, 25, 5], [], [5, 1]],
  ["Brave", "com.brave.Browser", [], [5, 36, 19, 33, 31, 21, 28, 18, 4, 7, 26, 41, 24, 10], [], [1, 3]],
  ["Safari", "com.apple.Safari", [], [26, 2, 4, 35, 36, 20, 21, 22, 31, 29, 39, 41, 40, 8], [], [3, 0]],
  ["Spotify", "com.spotify.client", [], [3, 19, 36, 28, 18, 24, 22, 1, 29, 35, 10, 40, 41, 15], [], [0, 1]],
  ["Xcode", "com.apple.dt.Xcode", [], [18, 8, 15, 25, 38, 31, 5, 10, 28, 37, 17, 33, 4, 26], [], [3, 4]],
  ["Raycast", "com.raycast.macos", [], [17, 26, 22, 24, 14, 9, 5, 11, 36, 37, 32, 0, 15, 40], [], [4, 1]],
  ["Orca", "com.stablyai.orca", [], [16, 18, 0, 9, 26, 34, 23, 20, 8, 32, 3, 14, 28, 27], [], [5, 4]],
  ["System Settings", "com.apple.systempreferences", ["Systemeinstellungen", "Einstellungen"], [25, 41, 40, 39, 6, 30, 38, 3, 12, 4, 13, 14, 5, 34], [[21, 38, 3, 6, 0, 36], [9, 34, 6, 23, 1, 4]], [1, 4]],
  ["Calendar", "com.apple.iCal", ["Kalender"], [24, 9, 16, 22, 23, 30, 7, 35, 31, 29, 36, 15, 40, 2], [[9, 6, 21, 16, 30, 10]], [4, 0]],
  ["Telegram", "ru.keepcoder.Telegram", [], [13, 33, 23, 9, 34, 1, 40, 19, 5, 16, 39, 29, 35, 11], [], [1, 4]],
  ["Ghostty", "com.mitchellh.ghostty", [], [34, 32, 21, 14, 12, 15, 25, 38, 37, 31, 22, 23, 0, 29], [], [2, 3]],
  ["ChatGPT", "com.openai.codex", [], [16, 12, 38, 22, 28, 39, 23, 5, 14, 6, 33, 15, 32, 10], [], [1, 3]],
  ["Zed", "dev.zed.Zed", [], [39, 41, 0, 30, 22, 5, 7, 24, 12, 38, 11, 13, 25, 20], [], [2, 0]],
  ["Notion Calendar", "com.cron.electron", [], [25, 29, 41, 5, 10, 37, 8, 1, 9, 40, 33, 19, 26, 30], [], [3, 2]],
  ["Activity Monitor", "com.apple.ActivityMonitor", ["Aktivitätsanzeige"], [9, 35, 40, 8, 1, 0, 6, 33, 38, 27, 12, 26, 32, 39], [[1, 16, 13, 18, 32, 15]], [4, 2]],
  ["Finder", "com.apple.finder", [], [16, 34, 26, 8, 3, 22, 29, 33, 39, 32, 38, 17, 4, 41], [], [4, 0]],
  ["Terminal", "com.apple.Terminal", [], [28, 11, 38, 0, 9, 40, 37, 30, 7, 3, 20, 21, 16, 29], [], [4, 3]],
  ["Mail", "com.apple.mail", [], [6, 35, 3, 15, 12, 17, 2, 41, 32, 28, 1, 24, 33, 40], [], [3, 2]],
  ["Notes", "com.apple.Notes", ["Notizen"], [39, 32, 38, 40, 12, 17, 28, 41, 30, 34, 15, 22, 16, 35], [[16, 35, 12, 28, 8, 26]], [0, 3]],
  ["Claude", "com.anthropic.claudefordesktop", [], [28, 20, 4, 15, 27, 39, 13, 19, 7, 9, 23, 36, 8, 41], [], [1, 3]],
  ["1Password", "com.1password.1password", [], [14, 6, 25, 31, 10, 41, 37, 27, 32, 39, 21, 13, 40, 11], [], [2, 0]],
  ["Messages", "com.apple.MobileSMS", ["Nachrichten"], [23, 1, 21, 35, 29, 28, 40, 24, 39, 18, 4, 3, 37, 25], [[14, 6, 5, 16, 17, 2]], [1, 2]],
  ["Music", "com.apple.Music", ["Musik"], [8, 27, 16, 25, 9, 34, 32, 31, 20, 5, 17, 1, 38, 22], [[11, 27, 4, 17, 1, 5]], [2, 0]],
  ["Photos", "com.apple.Photos", ["Fotos"], [38, 14, 4, 16, 7, 29, 0, 21, 26, 17, 8, 1, 41, 22], [[15, 7, 10, 16, 3, 11]], [1, 2]],
  ["Preview", "com.apple.Preview", ["Vorschau"], [40, 19, 33, 13, 18, 28, 32, 11, 17, 22, 1, 8, 31, 0], [[1, 32, 35, 12, 40, 30]], [1, 3]],
  ["TextEdit", "com.apple.TextEdit", [], [6, 27, 31, 34, 25, 32, 19, 13, 14, 21, 12, 26, 28, 22], [], [5, 1]],
  ["QuickTime Player", "com.apple.QuickTimePlayerX", [], [25, 22, 3, 8, 0, 4, 16, 27, 10, 39, 5, 21, 26, 12], [], [4, 2]],
  ["Reminders", "com.apple.reminders", ["Erinnerungen"], [38, 15, 18, 2, 29, 11, 10, 17, 28, 0, 16, 36, 35, 34], [[20, 15, 2, 19, 13, 22]], [1, 0]],
  ["Weather", "com.apple.weather", ["Wetter"], [21, 24, 5, 30, 17, 32, 12, 15, 36, 0, 39, 8, 26, 2], [[9, 25, 37, 2, 40, 1]], [2, 5]],
  ["cmux", "com.cmuxterm.app", [], [40, 14, 5, 37, 33, 9, 24, 20, 31, 36, 18, 23, 19, 34], [], [1, 0]],
  ["Ollama", "com.electron.ollama", [], [32, 40, 27, 41, 8, 33, 38, 1, 14, 5, 34, 31, 4, 20], [], [2, 0]],
  ["Tailscale", "io.tailscale.ipn.macsys", [], [24, 28, 35, 3, 1, 34, 15, 31, 16, 0, 29, 25, 2, 23], [], [4, 5]],
  ["App Store", "com.apple.AppStore", [], [5, 33, 4, 30, 16, 39, 37, 15, 13, 14, 29, 34, 27, 12], [], [0, 3]],
  ["Calculator", "com.apple.calculator", ["Rechner", "Taschenrechner"], [18, 2, 39, 12, 4, 9, 21, 16, 19, 8, 0, 15, 1, 30], [[17, 6, 13, 31, 18, 33], [18, 29, 40, 39, 7, 35]], [1, 2]],
  ["Cyberduck", "ch.sudo.cyberduck", [], [5, 30, 1, 18, 29, 4, 32, 28, 17, 24, 13, 37, 40, 6], [], [0, 4]],
  ["GarageBand", "com.apple.garageband10", [], [5, 9, 33, 16, 23, 8, 32, 17, 7, 37, 14, 15, 28, 29], [], [3, 5]],
  ["Shortcuts", "com.apple.shortcuts", ["Kurzbefehle"], [1, 10, 0, 31, 28, 25, 19, 9, 26, 22, 24, 40, 3, 33], [[21, 0, 20, 41, 25, 7]], [1, 0]],
];

const EN_T: readonly string[] = [
  "open {a}", "Open {a}.", "Open {a}", "open the {a} app",
  "Open {a} app.", "Can you open {a}?", "Could you open {a} please?", "Please open {a}.",
  "Open {a}, please.", "Open up {a}.", "Launch {a}.", "Start {a}.",
  "Start the {a} app.", "Run {a}.", "Switch to {a}.", "Go to {a}.",
  "Bring up {a}.", "Pull up {a}.", "Fire up {a}.", "Show me {a}.",
  "Take me to {a}.", "Jump to {a}.", "Switch over to {a}.", "Get me {a}.",
  "I want to open {a}.", "I'd like to open {a}.", "Let's open {a}.", "Go ahead and open {a}.",
  "Okay, open {a}.", "Um, open {a}.", "So open {a}.", "Hey, open {a}.",
  "Hey pi, open {a}.", "Open {a} for me.", "Can you open {a} for me?", "Can you please open the {a} app?",
  "Would you mind opening {a}?", "Open the {a} application.", "Open, {a}.", "Open {a}!",
  "Just open {a}.", "{a}.", "{a}", "{a}, please.",
  "Open open {a}.", "Open {a} app please.", "Can you launch {a}?", "Could you start {a}?",
  "Switch to the {a} window.", "Go to the {a} app.", "Focus {a}.", "Activate {a}.",
  "Bring {a} to the front.", "Open {a} now.", "Open {a}?", "Okay so open {a} please.",
];

const DE_T: readonly string[] = [
  "öffne {a}", "Öffne {a}.", "{a} öffnen", "{a} öffnen.", "{a} bitte öffnen.",
  "Öffne bitte {a}.", "Öffne mir bitte {a}.", "Öffne mal {a}.", "Mach {a} auf.", "Mach mal {a} auf.",
  "Mach bitte {a} auf.", "Starte {a}.", "Starte mal {a}.", "{a} starten.", "Starte die {a} App.",
  "Kannst du {a} öffnen?", "Kannst du mal {a} aufmachen?", "Könntest du bitte {a} starten?", "Wechsel zu {a}.", "Wechsle zu {a}.",
  "Geh zu {a}.", "Geh mal zu {a}.", "Zeig mir {a}.", "Hol {a} nach vorne.", "Ruf {a} auf.",
  "{a} aufmachen.", "{a} aufrufen.", "Ich will {a} öffnen.", "Ich möchte {a} öffnen.", "Öffne die App {a}.",
  "Öffne das Programm {a}.", "Öffne {a} für mich.", "Bitte {a} öffnen.", "{a} bitte.", "Okay, öffne {a}.",
  "Äh, öffne {a}.", "Also öffne {a}.", "Hey pi, öffne {a}.", "Öffne {a} bitte.", "Mach mir mal {a} auf.",
  "Kannst du bitte {a} starten?", "Starte bitte {a}.",
];

const MIX_T: readonly string[] = [
  "open {a} bitte", "Öffne {a} please.", "open mal {a}", "Bitte open {a}.", "Mach {a} open.", "Kannst du {a} opennen?",
];

/** Simulated ASR errors per bundle: [near forms (should act), far forms (an offer is the best outcome)]. */
const ASR: Readonly<Record<string, readonly [readonly string[], readonly string[]]>> = {
  "com.apple.Pages": [["pages", "Pages app", "page", "Page's", "Paige's", "paiges", "Pages's"], ["page is", "paces", "pace", "Paige", "pätsches", "Peitsches", "peaches", "patches", "pay jays"]],
  "com.apple.Keynote": [["key note", "keynotes", "key notes", "Key-note"], ["Kienout", "keen note", "key not", "kino"]],
  "com.apple.Numbers": [["number", "Numbers app"], ["numbas", "Nambers", "Nummers", "numb us"]],
  "notion.id": [["notions", "Notion's"], ["motion", "nation", "Nouschen", "no shun", "ocean"]],
  "com.brave.Browser": [["Brave browser", "the Brave browser", "Braves"], ["grave", "Breyv", "bray", "brief", "breve"]],
  "com.apple.Safari": [["safaris", "Safari browser"], ["Sofari", "so far e", "Zafari", "sa fari"]],
  "com.spotify.client": [["spot ify", "Spotify's", "Spotify app"], ["spot if I", "spotty fi", "Spotifei", "spotted fly"]],
  "com.apple.dt.Xcode": [["X code", "X-Code", "ex code", "excode"], ["ecks code", "Excote", "eggs code"]],
  "com.raycast.macos": [["Ray cast", "ray-cast", "Raycasts"], ["ray kast", "Rey Käst", "ray cost", "race cast"]],
  "com.stablyai.orca": [["Orka", "orcas"], ["or car", "Oscar", "Okra", "Arca"]],
  "com.apple.systempreferences": [["system setting", "systems settings", "System Preferences", "settings", "the settings", "Systemeinstellungen", "Einstellungen"], ["system sittings", "sister settings"]],
  "com.apple.iCal": [["Calender", "Kalender", "calendars", "my calendar"], ["colander", "Kalendar"]],
  "ru.keepcoder.Telegram": [["Telegramm", "tele gram", "telegrams"], ["tell a gram", "Telly gram"]],
  "com.mitchellh.ghostty": [["ghosty", "ghost T", "ghost tea", "ghost tee"], ["Gousti", "gusty", "ghost", "goes tea"]],
  "com.openai.codex": [["chat GPT", "chat g p t", "Chat-GPT", "ChatGTP", "chat GBT"], ["Chet GPT", "Chad GPT", "Tschätt G P T", "chat cheap tea"]],
  "dev.zed.Zed": [["Zed editor", "zed"], ["said", "Zet", "set", "zad", "sed"]],
  "com.cron.electron": [["Notion calender", "notion Kalender"], ["motion calendar", "Nouschen Kälender"]],
  "com.apple.ActivityMonitor": [["activity monitors", "activities monitor", "Aktivitätsanzeige", "task manager"], ["activity monitoring", "activity Monica"]],
  "com.apple.finder": [["finders", "the Finder"], ["finer", "Fynder", "find her", "fender"]],
  "com.apple.Terminal": [["terminals", "the terminal", "Terminal app"], ["Terminel", "terminate", "Germinal"]],
  "com.apple.mail": [["mails", "Mail app", "apple mail"], ["male", "mel", "Mehl"]],
  "com.apple.Notes": [["note", "Notizen", "notes app", "apple notes"], ["nodes", "knots", "nots"]],
  "com.anthropic.claudefordesktop": [["Claude app", "Claud", "Claude's"], ["cloud", "clod", "Klod", "clawed", "Clyde"]],
  "com.1password.1password": [["one password", "1 password", "1 Password app"], ["won password", "one passwords"]],
  "com.apple.MobileSMS": [["message", "Nachrichten", "iMessage"], ["massages", "messy jazz"]],
  "com.apple.Music": [["musik", "Apple music", "music app"], ["muse ick", "mew sick"]],
  "com.apple.Photos": [["fotos", "photo", "photo's"], ["photus", "foto's app"]],
  "com.apple.Preview": [["previews", "pre view", "Vorschau"], ["pre-few", "free view"]],
  "com.apple.TextEdit": [["text edit", "text-edit", "textedit app"], ["text editor", "text it it"]],
  "com.apple.QuickTimePlayerX": [["QuickTime", "quick time", "quick time player"], ["quick team", "quick-time player"]],
  "com.apple.reminders": [["reminder", "Erinnerungen", "reminders app"], ["remainders", "remind us"]],
  "com.apple.weather": [["the weather app", "Wetter app", "weather app"], ["whether", "wetter"]],
  "com.cmuxterm.app": [["C mux", "c-mux"], ["see mux", "C max", "see mucks", "C mocks"]],
  "com.electron.ollama": [["o llama", "Olama"], ["Obama", "a llama", "oh llama", "llama"]],
  "io.tailscale.ipn.macsys": [["tail scale", "tail-scale"], ["tale scale", "tails scale", "tail skate"]],
  "com.apple.AppStore": [["app store", "apps store", "Appstore", "the App Store"], ["app stor", "up store"]],
  "com.apple.calculator": [["calculator app", "Rechner", "Taschenrechner", "calc"], ["calculate her", "calculus"]],
  "ch.sudo.cyberduck": [["cyber duck", "Cyber-Duck"], ["Siberduck", "cyber dock"]],
  "com.apple.garageband10": [["garage band", "Garage-Band"], ["garage bend", "Karaoke band"]],
  "com.apple.shortcuts": [["shortcut", "Kurzbefehle", "shortcuts app"], ["short cuts", "shot cuts"]],
};

const FRAMES: readonly string[] = [
  "Open {x}.", "open {x}", "Launch {x}.", "Öffne {x}.", "Can you open {x}?", "Switch to {x}.",
];

const OTHER: readonly (readonly [string, string, Expect])[] = [
  ["Open GitHub.com.", "en", {"kind": "url", "host": "github.com"}],
  ["open github dot com", "en", {"kind": "url", "host": "github.com"}],
  ["Go to YouTube dot com.", "en", {"kind": "url", "host": "youtube.com"}],
  ["Open YouTube.", "en", {"kind": "url", "host": "www.youtube.com"}],
  ["Go to YouTube.", "en", {"kind": "url", "host": "www.youtube.com"}],
  ["open gmail", "en", {"kind": "url", "host": "mail.google.com"}],
  ["Geh auf spiegel punkt de.", "de", {"kind": "url", "host": "spiegel.de"}],
  ["Öffne YouTube.", "de", {"kind": "url", "host": "www.youtube.com"}],
  ["Visit wikipedia.org.", "en", {"kind": "url", "host": "wikipedia.org"}],
  ["Open google.", "en", {"kind": "url", "host": "www.google.com"}],
  ["Google flights to Lisbon.", "en", {"kind": "web"}],
  ["Search the web for best pizza in Berlin.", "en", {"kind": "web"}],
  ["Search YouTube for lo-fi beats.", "en", {"kind": "web"}],
  ["Such im Internet nach Pizza in Berlin.", "de", {"kind": "web"}],
  ["Look up the weather in Hamburg online.", "en", {"kind": "web"}],
  ["Google Wetter Hamburg.", "de", {"kind": "web"}],
  ["Find my invoice from March.", "en", {"kind": "file_search"}],
  ["Search my computer for tax return 2025.", "en", {"kind": "file_search"}],
  ["Where is my CV?", "en", {"kind": "file_search"}],
  ["Finde meine Steuererklärung.", "de", {"kind": "file_search"}],
  ["Suche nach Rechnung März.", "de", {"kind": "file_search"}],
  ["Find the PDF from Telekom.", "en", {"kind": "file_search"}],
  ["What's 17 times 23?", "en", {"kind": "calc"}],
  ["What is fifteen percent of two hundred forty?", "en", {"kind": "calc"}],
  ["17 x 23", "en", {"kind": "calc"}],
  ["Was ist 17 mal 23?", "de", {"kind": "calc"}],
  ["Square root of 144.", "en", {"kind": "calc"}],
  ["250 divided by 8.", "en", {"kind": "calc"}],
  ["Was sind 15 Prozent von 240?", "de", {"kind": "calc"}],
  ["Turn the volume down.", "en", {"kind": "system", "op": "volume.step"}],
  ["Volume up.", "en", {"kind": "system", "op": "volume.step"}],
  ["Mute.", "en", {"kind": "system", "op": "volume.mute"}],
  ["Turn it up.", "en", {"kind": "system", "op": "volume.step"}],
  ["Make it louder.", "en", {"kind": "system", "op": "volume.step"}],
  ["Lauter.", "de", {"kind": "system", "op": "volume.step"}],
  ["Leiser, bitte.", "de", {"kind": "system", "op": "volume.step"}],
  ["Set the volume to 50%.", "en", {"kind": "system", "op": "volume.set"}],
  ["Set volume to fifty percent.", "en", {"kind": "system", "op": "volume.set"}],
  ["Stell die Lautstärke auf 50 Prozent.", "de", {"kind": "system", "op": "volume.set"}],
  ["Ton aus.", "de", {"kind": "system", "op": "volume.mute"}],
  ["Turn off the screen.", "en", {"kind": "system", "op": "display.sleep"}],
  ["Turn the volume down a bit.", "en", {"kind": "system", "op": "volume.step"}],
  ["Can you turn the volume up?", "en", {"kind": "system", "op": "volume.step"}],
  ["Mach mal lauter.", "de", {"kind": "system", "op": "volume.step"}],
  ["Mach den Ton aus.", "de", {"kind": "system", "op": "volume.mute"}],
  ["Could you mute the sound please?", "en", {"kind": "system", "op": "volume.mute"}],
  ["Volume 30.", "en", {"kind": "system", "op": "volume.set"}],
];

const NEG: readonly (readonly [string, string])[] = [
  ["open the door", "en"], ["Open a new tab.", "en"], ["Open a new window.", "en"],
  ["Open the last email from Anna.", "en"], ["Open my latest invoice.", "en"], ["Open the file I downloaded yesterday.", "en"],
  ["Start a timer for five minutes.", "en"], ["Start a new document.", "en"], ["Start writing an email to Tom.", "en"],
  ["Run the tests.", "en"], ["Go to sleep.", "en"], ["Go to the next slide.", "en"],
  ["Go back.", "en"], ["Switch to dark mode.", "en"], ["Switch to the next tab.", "en"],
  ["Show me the weather.", "en"], ["Show me my calendar for tomorrow.", "en"], ["Launch the rocket.", "en"],
  ["What pages do I need?", "en"], ["The notion of time.", "en"], ["The Brave Little Toaster.", "en"],
  ["How are you?", "en"], ["Tell me a joke.", "en"], ["Open sesame.", "en"],
  ["Open the pod bay doors.", "en"], ["Start over.", "en"], ["Start again.", "en"],
  ["Open source.", "en"], ["Go home.", "en"], ["Launch it.", "en"],
  ["Open it.", "en"], ["Open that.", "en"], ["Open the second one.", "en"],
  ["Open the link in a new tab.", "en"], ["Show desktop.", "en"], ["Run a speed test.", "en"],
  ["Start recording.", "en"], ["Start screen recording.", "en"], ["Open camera.", "en"],
  ["Start dictation.", "en"], ["Show me pictures of cats.", "en"], ["Close Pages.", "en"],
  ["Quit Spotify.", "en"], ["Pause Spotify.", "en"], ["Play music.", "en"],
  ["Next song.", "en"], ["Hide Pages.", "en"], ["Minimize Pages.", "en"],
  ["Open the Pages document I wrote yesterday.", "en"], ["Open my budget spreadsheet in Numbers.", "en"], ["Open settings for Wi-Fi.", "en"],
  ["Turn on Bluetooth.", "en"], ["Restart the computer.", "en"], ["Shut down.", "en"],
  ["Log out.", "en"], ["Lock the screen.", "en"], ["Open Figma.", "en"],
  ["Open WhatsApp.", "en"], ["Open Slack.", "en"], ["Open Chrome.", "en"],
  ["Open VS Code.", "en"], ["Open Word.", "en"], ["Open the window.", "en"],
  ["Open a terminal tab and run npm test.", "en"], ["Start Spotify and play my liked songs.", "en"], ["Open the settings in Notion.", "en"],
  ["Thanks.", "en"], ["Okay.", "en"], ["Yes.", "en"],
  ["No.", "en"], ["Hmm.", "en"], ["Open.", "en"],
  ["Launch.", "en"], ["Start.", "en"], ["Photos of my dog from last summer.", "en"],
  ["Message Anna that I'm late.", "en"], ["Mail the report to Tom.", "en"], ["Note to self buy milk.", "en"],
  ["Delete page is.", "en"], ["Delete motion.", "en"], ["Turn the page.", "en"],
  ["Set an alarm for 7.", "en"], ["Call mom.", "en"], ["Öffne die Tür.", "de"],
  ["Öffne einen neuen Tab.", "de"], ["Starte einen Timer für fünf Minuten.", "de"], ["Mach das Fenster auf.", "de"],
  ["Mach die Musik leiser.", "de"], ["Geh zur nächsten Folie.", "de"], ["Zeig mir das Wetter.", "de"],
  ["Starte die Präsentation.", "de"], ["Schließe Pages.", "de"], ["Beende Spotify.", "de"],
  ["Pages schließen.", "de"], ["Mach mal Pause.", "de"], ["Öffne den Link.", "de"],
  ["Starte neu.", "de"], ["Starte den Computer neu.", "de"], ["Wie geht es dir?", "de"],
  ["Danke.", "de"], ["Öffne das.", "de"], ["Öffne die letzte Mail von Anna.", "de"],
  ["Zeig mir meine Termine.", "de"], ["Mach das Licht an.", "de"], ["Öffne Figma.", "de"],
  ["Schreib Anna dass ich später komme.", "de"], ["Spiel Musik.", "de"], ["Nächster Song.", "de"],
  ["Öffne Word.", "de"],
];

const REFUSE: readonly (readonly [string, string])[] = [
  ["Delete Pages.", "en"], ["Uninstall Notion.", "en"], ["Remove Brave.", "en"], ["Lösche Spotify.", "de"], ["Move Pages to the trash.", "en"], ["Empty the trash.", "en"], ["Papierkorb leeren.", "de"], ["Remove the Telegram app.", "en"],
];

// build_neg.py (seed 11): every verb with a sample of nouns.
const NEG_EN_VERBS: readonly string[] = [
  "Open", "Open the", "Launch", "Start", "Run", "Switch to",
  "Go to", "Bring up", "Pull up", "Show me", "Can you open", "Open up",
];

const NEG_EN_NOUNS: readonly string[] = [
  "door", "window", "fridge", "garage", "bottle", "file", "folder", "tab", "link", "email from Anna",
  "chat", "meeting", "timer", "alarm", "stopwatch", "recording", "presentation", "slideshow", "game", "movie",
  "song", "playlist", "video call", "project", "repo", "last one", "first result", "downloads folder", "dark mode", "do not disturb",
  "focus mode", "wifi", "bluetooth", "menu", "sidebar", "spotlight", "broadcast", "forecast", "review", "lotion",
  "potion", "binder", "finger", "ocean", "motion", "crave", "brain", "sahara", "telegraph", "ghost story",
  "magic", "llama", "scale", "cyber", "remainder", "passages", "short cut", "lumber", "feather", "leather",
  "order", "orchestra", "cloud storage", "iCloud", "the mall", "a meal", "said", "zen", "bed", "sad",
  "set", "next slide", "previous page", "camera", "photo booth app store", "terminal tab", "new terminal window", "keynote speech", "pages 3 to 5", "page 2",
  "control center", "notification center", "launchpad", "mission control", "trash", "recycle bin", "my documents", "the budget spreadsheet", "the PDF", "the invoice",
  "my resume", "settings for wifi", "privacy settings", "sound settings", "display settings", "keyboard shortcuts",
];

const NEG_EN_PICKS: readonly (readonly number[])[] = [[57, 71, 59, 95, 65, 75, 24, 23, 91, 60, 80, 78, 88, 12, 92, 38, 18, 11, 68, 5, 50, 81, 20, 1, 67, 8, 7, 4, 89, 30], [76, 3, 59, 41, 56, 75, 25, 66, 29, 81, 37, 63, 0, 10, 58, 35, 52, 70, 82, 32, 40, 87, 65, 36, 94, 8, 13, 51, 69, 85], [49, 8, 2, 87, 0, 27, 26, 6, 60, 48, 50, 53, 9, 72, 80, 25, 34, 43, 11, 39, 42, 1, 52, 15, 17, 31, 12, 74, 7, 59], [62, 22, 87, 71, 24, 57, 65, 91, 16, 53, 82, 49, 14, 50, 86, 27, 0, 34, 75, 38, 2, 26, 23, 85, 12, 5, 18, 80, 56, 33], [1, 78, 42, 37, 49, 9, 90, 11, 26, 74, 81, 31, 95, 76, 47, 85, 79, 58, 16, 75, 61, 73, 17, 91, 23, 19, 39, 29, 84, 24], [20, 94, 80, 70, 25, 87, 49, 61, 77, 10, 53, 6, 13, 83, 4, 65, 32, 30, 50, 79, 85, 62, 37, 66, 22, 8, 16, 29, 88, 9], [35, 27, 26, 2, 8, 34, 52, 57, 31, 7, 5, 22, 36, 47, 67, 73, 16, 11, 46, 17, 88, 42, 66, 76, 4, 92, 60, 45, 39, 71], [2, 76, 81, 9, 61, 8, 39, 40, 17, 92, 86, 57, 69, 47, 5, 16, 43, 45, 10, 60, 85, 53, 3, 63, 1, 48, 70, 71, 75, 77], [11, 81, 14, 32, 53, 42, 49, 88, 74, 58, 56, 59, 69, 10, 66, 65, 3, 39, 76, 95, 61, 2, 29, 93, 63, 62, 92, 1, 47, 38], [18, 86, 78, 25, 66, 21, 43, 84, 56, 63, 30, 41, 51, 32, 92, 55, 81, 27, 49, 28, 74, 40, 26, 17, 72, 94, 44, 5, 8, 35], [21, 14, 57, 60, 35, 27, 52, 48, 80, 66, 63, 40, 79, 93, 41, 9, 4, 91, 77, 5, 78, 73, 45, 39, 2, 17, 51, 58, 24, 3], [34, 30, 18, 6, 80, 14, 57, 13, 91, 68, 83, 81, 47, 9, 25, 84, 60, 32, 22, 1, 79, 86, 4, 77, 28, 95, 44, 66, 64, 20]];

const NEG_DE_VERBS: readonly string[] = [
  "Öffne", "Öffne die", "Starte", "Mach", "Zeig mir", "Wechsel zu", "Geh zu", "Kannst du öffnen",
];

const NEG_DE_NOUNS: readonly string[] = [
  "Tür", "Fenster", "Kühlschrank", "Garage", "Flasche", "Datei", "Ordner", "Link", "Präsentation", "Timer",
  "Aufnahme", "Spiel", "Film", "Video", "Besprechung", "Waschmaschine", "Licht", "Dunkelmodus", "nächsten Tab", "Kamera",
  "Startseite", "nächste Folie", "Route", "Termine", "Rechnung", "Steuererklärung", "Bewerbung", "Einkaufsliste", "Wecker", "Stoppuhr",
  "Spotlight", "Lotion", "Notizbuch", "Kalenderwoche", "Seite drei", "Papierkorb", "Downloads", "Schreibtisch", "Bildschirmschoner", "Mitteilungen",
];

const NEG_DE_PICKS: readonly (readonly number[])[] = [[25, 14, 5, 26, 24, 8, 28, 29, 12, 20, 33, 0, 31, 17, 18, 30, 16, 10, 38, 22, 6, 3], [7, 13, 15, 24, 5, 19, 20, 16, 1, 11, 32, 2, 31, 14, 10, 17, 38, 8, 37, 0, 6, 28], [27, 2, 11, 34, 21, 8, 30, 9, 28, 33, 31, 15, 18, 22, 38, 24, 7, 14, 16, 17, 32, 20], [10, 33, 32, 35, 16, 19, 24, 13, 34, 27, 4, 17, 36, 8, 18, 15, 6, 37, 28, 3, 30, 0], [38, 24, 1, 34, 2, 33, 25, 7, 31, 35, 22, 5, 30, 17, 14, 13, 12, 8, 32, 15, 20, 4], [21, 27, 30, 33, 20, 6, 12, 26, 1, 29, 8, 4, 22, 24, 0, 31, 34, 28, 7, 25, 9, 10], [22, 15, 31, 6, 37, 7, 32, 16, 12, 39, 33, 28, 13, 0, 35, 20, 27, 29, 19, 5, 17, 36], [34, 13, 33, 38, 39, 8, 14, 22, 11, 10, 19, 30, 6, 27, 24, 26, 3, 4, 7, 32, 2, 35]];

const NEG_QUESTIONS: readonly string[] = [
  "How do I export a PDF in Pages?", "Is Notion down?", "Is Brave better than Safari?", "What is Raycast?",
  "Tell me about Notion.", "How do I use Keynote?", "Why is Spotify so slow?", "Pages or Keynote?",
  "Spotify pause.", "Can Notion do databases?", "Write an email to Anna.", "Remind me to call mom.",
  "Play some music.", "What time is it?", "Good morning.", "What's up?",
  "How are you?", "I need help.", "Translate hello into German.", "Who won the game?",
  "Set a timer for ten minutes.", "What's the weather like?", "Summarize this.", "Make a note.",
  "Take a screenshot.", "Send a message to Tom.", "Call Anna.", "Turn on do not disturb.",
  "Close all windows.", "Quit Safari.", "Hide Finder.", "Where is my iPhone?",
  "Find my phone.", "Check my mail.", "Read my messages.", "What's on my calendar?",
  "Add milk to my list.", "Wie spät ist es in Tokio?", "Schreib Anna eine Nachricht.", "Erinnere mich an den Zahnarzt.",
  "Was steht in meinem Kalender?", "Spiel Musik.", "Mach ein Foto.", "Wie funktioniert Notion?",
  "Ist Brave besser als Safari?", "Was ist Raycast?", "Lies meine Mails vor.", "Fass das zusammen.",
  "Danke schön.", "Guten Morgen.", "Kannst du mir helfen?", "Beende Spotify.",
  "Schließe alle Fenster.", "Neuer Tab.", "Neues Dokument.", "Neue Notiz.",
  "New tab.", "New document.", "New note.", "Next song.",
  "Previous song.", "Skip.", "Pause.", "Play.",
  "Louder please and open Pages.", "Open Pages and write a letter.", "Open Notion then create a page.", "Öffne Pages und schreib einen Brief.",
];

const NEG_WORDS: readonly string[] = [
  "Hello.", "Help.", "Pizza.", "Coffee.", "Email.", "Zoom.", "Teams.", "Slack.", "Word.", "Excel.", "Chrome.", "Figma.",
  "Discord.", "Yes.", "No.", "Okay.", "Thanks.", "Hmm.", "Test.", "Testing.", "Hi there.", "Good night.", "Wait.", "Again.",
  "Nothing.", "Whatever.", "Later.", "Now.", "Today.", "Tomorrow.", "Monday.", "Berlin.", "Anna.", "Tom.", "Mom.", "Hallo.",
  "Hilfe.", "Kaffee.", "Ja.", "Nein.", "Danke.", "Später.", "Heute.", "Morgen.", "Genau.", "Moment.", "Weiter.", "Zurück.",
];


const NEG_OK_APPS: Readonly<Record<string, string>> = { "Show me the weather.": "com.apple.weather", "Zeig mir das Wetter.": "com.apple.weather" };
const NEG_APP_NOUNS: readonly (readonly [string, string])[] = [
  ["Open the news.", "com.apple.news"], ["Show me the weather.", "com.apple.weather"], ["Zeig mir das Wetter.", "com.apple.weather"],
  ["Run the numbers.", "com.apple.Numbers"], ["Open the notes.", "com.apple.Notes"], ["Start the music.", "com.apple.Music"], ["Weather.", "com.apple.weather"],
  ["Music.", "com.apple.Music"], ["Photos.", "com.apple.Photos"], ["Open podcast.", "com.apple.podcasts"], ["Open the calendar.", "com.apple.iCal"],
  ["Open my mail.", "com.apple.mail"], ["Open the clock.", "com.apple.clock"],
];
/** build_neg.py: acting on these named apps is acceptable. */
const NEG_SUFFIX_OK: Readonly<Record<string, string>> = { game: "com.apple.games", "mission control": "com.apple.exposelauncher", "Email.": "com.apple.mail" };
const DE_QUESTION_START = new Set(["Wie", "Schreib", "Erinnere", "Was", "Spiel", "Mach", "Ist", "Lies", "Fass", "Danke", "Guten", "Kannst", "Beende", "Schließe", "Neuer", "Neues", "Neue", "Öffne"]);
const DE_WORDS = new Set(["Hallo.", "Hilfe.", "Kaffee.", "Ja.", "Nein.", "Danke.", "Später.", "Heute.", "Morgen.", "Genau.", "Moment.", "Weiter.", "Zurück."]);

/** r3/mapping/corpus/build.py → corpus.json (3,380 items), in its order. */
function mappingCorpus(): Item[] {
  const items: Item[] = [];
  const add = (text: string, lang: string, src: string, expect: Expect): void => void items.push({ text, lang, src, expect });
  for (const [name, bundleId, deNames, dePicks, namePicks, mixPicks] of CORPUS_APPS) {
    const open: Expect = { kind: "open_app", bundleId };
    for (const t of EN_T) add(t.replaceAll("{a}", name), "en", "wrapper-en", open);
    for (const i of dePicks) add(DE_T[i]!.replaceAll("{a}", name), "de", "wrapper-de", open);
    deNames.forEach((deName, k) => {
      for (const i of namePicks[k]!) add(DE_T[i]!.replaceAll("{a}", deName), "de", "wrapper-de-name", open);
    });
    for (const i of mixPicks) add(MIX_T[i]!.replaceAll("{a}", name), "mix", "wrapper-mix", open);
  }
  for (const [bundleId, [near, far]] of Object.entries(ASR)) {
    const frame = (i: number, x: string): [string, string] => [FRAMES[i % FRAMES.length]!.replace("{x}", x), FRAMES[i % FRAMES.length]!.startsWith("Öffne") ? "de" : "en"];
    near.forEach((x, i) => add(...frame(i, x), "asr-near", { kind: "open_app", bundleId }));
    far.forEach((x, i) => add(...frame(i + 2, x), "asr-far", { kind: "open_app", bundleId }));
  }
  for (const [text, lang, expect] of OTHER) add(text, lang, "other", expect);
  for (const [text, lang] of NEG) add(text, lang, "negative", NEG_OK_APPS[text] ? { kind: "agent", okApp: NEG_OK_APPS[text] } : { kind: "agent" });
  for (const [text, lang] of REFUSE) add(text, lang, "refuse", { kind: "refuse" });
  return items;
}

/** r3/mapping/corpus/build_neg.py → negatives.json (665 items). */
function mappingNegatives(): Item[] {
  const items: Item[] = [];
  const add = (text: string, lang: string, src: string, okApp?: string): void => {
    const suffixOk = Object.entries(NEG_SUFFIX_OK).find(([k]) => text === k || text.endsWith(` ${k}.`))?.[1];
    const ok = okApp ?? suffixOk;
    items.push({ text, lang, src: `neg-${src}`, expect: ok ? { kind: "agent", okApp: ok } : { kind: "agent" } });
  };
  NEG_EN_VERBS.forEach((verb, v) => NEG_EN_PICKS[v]!.forEach((i) => add(`${verb} ${NEG_EN_NOUNS[i]}.`, "en", "open-noun")));
  NEG_DE_VERBS.forEach((verb, v) => NEG_DE_PICKS[v]!.forEach((i) => {
    const noun = NEG_DE_NOUNS[i]!;
    add(verb === "Kannst du öffnen" ? `Kannst du ${noun} öffnen?` : verb === "Mach" ? `Mach ${noun} auf.` : `${verb} ${noun}.`, "de", "open-noun");
  }));
  for (const q of NEG_QUESTIONS) add(q, /[äöüß]/.test(q) || DE_QUESTION_START.has(q.split(" ")[0]!) ? "de" : "en", "question");
  for (const w of NEG_WORDS) add(w, DE_WORDS.has(w) ? "de" : "en", "word");
  for (const [text, app] of NEG_APP_NOUNS) add(text, text.includes("Zeig") ? "de" : "en", "appnoun", app);
  return items;
}

interface Score { positives: number; acts: number; actOrOffer: number; wrongApps: number; negatives: number; falseActions: number; offersOnNegatives: number; other: number; otherOk: number; refusals: number; refused: number }

function replay(matcher: AppMatcher, items: readonly Item[], voice: boolean): Score {
  const s: Score = { positives: 0, acts: 0, actOrOffer: 0, wrongApps: 0, negatives: 0, falseActions: 0, offersOnNegatives: 0, other: 0, otherOk: 0, refusals: 0, refused: 0 };
  for (const item of items) {
    const outcome = decide(matcher, item.text, item.lang, voice);
    const e = item.expect;
    switch (e.kind) {
      case "open_app":
        s.positives++;
        if (outcome.kind === "act") {
          if (outcome.app === e.bundleId) s.acts++;
          else s.wrongApps++;
        }
        if (opened(outcome) === e.bundleId || offered(outcome).slice(0, 3).includes(e.bundleId)) s.actOrOffer++;
        break;
      case "agent":
        s.negatives++;
        if (outcome.kind === "act" && !(e.okApp && outcome.app === e.okApp)) s.falseActions++;
        if (outcome.kind === "offer") s.offersOnNegatives++;
        break;
      case "refuse":
        s.refusals++;
        if (outcome.kind === "refuse") s.refused++;
        break;
      default: {
        s.other++;
        const good = e.kind === "url" ? outcome.kind === "act" && outcome.intent === "url" && outcome.url === e.host
          : e.kind === "system" ? outcome.kind === "act" && outcome.op === e.op
          : e.kind === "web" ? outcome.kind === "act" && outcome.intent === "web"
          : e.kind === "file_search" ? outcome.kind === "list"
          : outcome.kind === "answer" && ["calc", "unit"].includes(outcome.intent);
        if (good) s.otherOk++;
      }
    }
  }
  return s;
}

const pct = (part: number, whole: number): string => `${((100 * part) / whole).toFixed(1)}%`;

test("corpus replay: open-app acts 46.9 % → 93.9 %, 0 false actions (today 20 on 665 negatives)", (t) => {
  const corpus = mappingCorpus();
  const negatives = mappingNegatives();
  const count = (items: Item[], src: string) => items.filter((item) => item.src === src).length;
  assert.deepEqual(
    ["wrapper-en", "wrapper-de", "wrapper-de-name", "wrapper-mix", "asr-near", "asr-far", "other", "negative", "refuse"].map((src) => count(corpus, src)),
    [2240, 560, 84, 80, 126, 126, 47, 109, 8],
  );
  assert.deepEqual(["neg-open-noun", "neg-question", "neg-word", "neg-appnoun"].map((src) => count(negatives, src)), [536, 68, 48, 13]);
  const matcher = new AppMatcher(FIXTURE_APPS);

  const before = replay(matcher, corpus, false);
  const beforeNeg = replay(matcher, negatives, false);
  t.diagnostic(`today: open-app acts ${before.acts}/${before.positives} (${pct(before.acts, before.positives)}), false actions ${beforeNeg.falseActions}/${beforeNeg.negatives}`);
  assert.ok(before.acts / before.positives > 0.45 && before.acts / before.positives < 0.49, pct(before.acts, before.positives));
  assert.ok(beforeNeg.falseActions >= 15, "today's literal tiers act on negatives (\"Bring up file.\" → Bluetooth File Exchange)");

  const after = replay(matcher, corpus, true);
  const afterNeg = replay(matcher, negatives, true);
  t.diagnostic(`voice: open-app acts ${after.acts}/${after.positives} (${pct(after.acts, after.positives)}), act or offered ${pct(after.actOrOffer, after.positives)}, `
    + `wrong apps ${after.wrongApps}, false actions ${after.falseActions + afterNeg.falseActions}/${after.negatives + afterNeg.negatives}, `
    + `offers on negatives ${afterNeg.offersOnNegatives}/${afterNeg.negatives}, other intents ${after.otherOk}/${after.other}, refused ${after.refused}/${after.refusals}`);
  assert.ok(after.acts / after.positives >= 0.935, `acts ${pct(after.acts, after.positives)}`);
  assert.ok(after.actOrOffer / after.positives >= 0.98, `act or offer ${pct(after.actOrOffer, after.positives)}`);
  assert.equal(after.wrongApps, 0);
  assert.equal(after.falseActions, 0);
  assert.equal(afterNeg.falseActions, 0);
  assert.ok(afterNeg.offersOnNegatives / afterNeg.negatives <= 0.07, `offers on negatives ${pct(afterNeg.offersOnNegatives, afterNeg.negatives)}`);
  assert.equal(after.otherOk, after.other);
  assert.equal(after.refused, after.refusals);
});

test("a voice open decision stays well inside the 60 ms instant budget", () => {
  const matcher = new AppMatcher(FIXTURE_APPS);
  const texts = mappingCorpus().filter((_, i) => i % 7 === 0);
  for (const item of texts.slice(0, 50)) decide(matcher, item.text, item.lang);
  const times: number[] = [];
  for (const item of texts) {
    const started = performance.now();
    decide(matcher, item.text, item.lang);
    times.push(performance.now() - started);
  }
  times.sort((a, b) => a - b);
  const p95 = times[Math.floor(times.length * 0.95)]!;
  // As instantPerf.test.ts: PI_OS_PERF_SLACK (e.g. 3) widens the latency bound on slower or loaded machines.
  const slack = Number(process.env.PI_OS_PERF_SLACK ?? "1") || 1;
  assert.ok(p95 < 5 * slack, `p95 ${p95.toFixed(2)} ms`);
});
