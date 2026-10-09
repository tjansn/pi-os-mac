import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fauxAssistantMessage, fauxToolCall, type AssistantMessage, type JsonObject } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import {
  createLiveSession, defersPreparation, FULL_SESSION_UNAVAILABLE, planTurn, promptFirst, promptFollowup, promptVariant, sessionSetupKey,
  type AgentRunOptions,
} from "../src/agent/agentRunner.js";
import { FULL_SESSION_SECTION, fullSessionSystemPrompt, scopedSystemPrompt, USE_ACTIVE_WINDOW_TOOL } from "../src/agent/computerUseExtension.js";
import {
  continuesLastSession, fullPromptVariant, isFullSession, isPrivacyProtected, piSessionBucket, PI_SESSION_DIR_ENV, readsProtectedFolder,
  resolveWorkingDirectory, sessionDirectory,
} from "../src/agent/fullSession.js";
import { PI_OS_SYSTEM_PROMPT } from "../src/agent/resources.js";
import { FULL_INVOKE_TIMEOUT_MS, loadConfig, type HarnessConfig } from "../src/config.js";
import { AgentResourceSettings } from "../src/agent/resourceSettings.js";
import { DEFAULT_ROUTING_SETTINGS } from "../src/agent/routing/index.js";
import type { ContextWire } from "../src/contracts/context.js";
import { parseResourceStatus, PI_DEFAULT_ACTIVE_TOOLS } from "../src/contracts/piSession.js";
import type { HostClient } from "../src/hostClient.js";
import { agentHost, agentRun, fakeHost, fauxRuntimes, seen, snapshot, start, tempCaptures, type SeenRequest } from "./integrationFixtures.js";

/**
 * Full pi sessions (protocol.md "Full pi session (macOS)") on the in-process faux provider: pi's coding tools and the
 * user's global extensions with no allowlist, the folder the user was looking at, pi's project trust, saved and
 * continued pi session files, the lean vs coding prompt, the bash guard of a global extension, the resource status,
 * and isolated / Windows sessions that stay exactly as they were.
 *
 * Every agent dir is a temporary copy of a fixture (never the user's ~/.pi, never the real dcg: the fixture guard
 * only blocks commands with the marker `fixture-destructive` and spawns nothing). Commands touch temporary files only.
 */

const FIXTURES = resolve("test/fixtures");
const MACOS_ONLY = process.platform !== "darwin" && "full pi sessions are macOS-only: POSIX folders, bash and pi's session buckets";
const general = (): ContextWire => ({ scope: "general", pull: "allowed", source: "default" });

/** A temporary root: a copy of a fixture agent dir, a home folder and a project folder inside it (all real paths). */
function fullRoot(fixture = "guard-agent-dir") {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-os-full-")));
  const agentDir = join(root, "agent");
  cpSync(join(FIXTURES, fixture), agentDir, { recursive: true });
  const home = join(root, "home");
  const project = join(home, "project");
  mkdirSync(project, { recursive: true });
  return { root, agentDir, home, project, close: () => rm(root, { recursive: true, force: true }) };
}
type Dirs = ReturnType<typeof fullRoot>;

type Part = { type: string; text?: string };
type Message = SeenRequest["messages"][number];
const partsOf = (message: Message | undefined): Part[] => !message ? []
  : typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content as Part[];
const textOf = (message: Message | undefined) => partsOf(message).filter(part => part.type === "text").map(part => part.text).join("\n");
const lastToolResult = (request: SeenRequest) => {
  const result = request.messages.findLast(message => message.role === "toolResult");
  return { text: textOf(result), isError: result?.isError === true };
};
const say = (text: string) => () => fauxAssistantMessage(text);
const callMessage = (name: string, args: JsonObject) => fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
const call = (name: string, args: JsonObject) => () => callMessage(name, args);

interface FullScenarioOptions {
  prompt: string;
  workingDirectory?: string;
  context?: ContextWire;
  /** Default: the manual fx/fast model; null: Auto. */
  modelSelection?: AgentRunOptions["modelSelection"];
  resourceSelection?: AgentRunOptions["resourceSelection"];
  platform?: NodeJS.Platform;
}

/** A control-enabled session with a temporary agent dir and home; records each provider request and tool start. */
async function scenario(dirs: Dirs, options: FullScenarioOptions) {
  const captures = tempCaptures();
  const pinned = captures.snapshot();
  const host = agentHost(captures.dir, pinned);
  const runtimes = fauxRuntimes();
  const toolCalls: string[] = [];
  const run = agentRun(host, runtimes, captures.dir, pinned, {
    prompt: options.prompt,
    resourceSelection: options.resourceSelection ?? { mode: "trustedGlobal" },
    ...(options.workingDirectory !== undefined ? { workingDirectory: options.workingDirectory } : {}),
    ...(options.modelSelection !== undefined ? { modelSelection: options.modelSelection } : {}),
    ...(options.context ? { context: options.context } : {}),
    onToolCall: name => toolCalls.push(name),
    services: { agentDir: dirs.agentDir, home: dirs.home, platform: options.platform ?? "darwin" },
  });
  const live = await createLiveSession(run);
  const requests: SeenRequest[] = [];
  const reply = (answer: (request: SeenRequest) => AssistantMessage) =>
    (context: unknown, _options: unknown, _state: unknown, model: { provider: string; id: string }) => {
      const request = seen(context, model);
      requests.push(request);
      return answer(request);
    };
  const first = async () => {
    const plan = planTurn(live, { text: run.prompt, snapshot: run.snapshot, followup: false, settings: DEFAULT_ROUTING_SETTINGS,
      ...(run.context ? { context: run.context } : {}) });
    return promptFirst(live, { ...run, attachScreenshot: plan.attachScreenshot });
  };
  const followup = (text: string) => {
    planTurn(live, { text, snapshot: pinned, followup: true, settings: DEFAULT_ROUTING_SETTINGS });
    return promptFollowup(live, text);
  };
  return {
    run, live, runtimes, requests, toolCalls, reply, first, followup,
    async close() { await live.close(); await captures.close(); },
  };
}

const jsonl = (dir: string) => existsSync(dir) ? readdirSync(dir).filter(file => file.endsWith(".jsonl")) : [];
const userMessages = (file: string) => SessionManager.open(file).getEntries()
  .filter(entry => entry.type === "message" && entry.message.role === "user");

// ---------------------------------------------------------------------------------------------
// Pure decisions

test("continue-session requests: explicit EN/DE requests to continue a pi session only", () => {
  for (const text of [
    "continue my last pi session", "Continue the last pi session please", "resume my previous pi-session", "pick up my last pi session and run the tests",
    "go back to my latest pi session", "mach mit der letzten pi-Session weiter", "Mach mit meiner letzten pi Session weiter",
    "setze die letzte pi-Sitzung fort", "weiter mit der letzten pi-Session", "continue my pi session",
  ]) assert.equal(continuesLastSession(text), true, text);
  for (const text of [
    "what did my last pi session do?", "delete my last pi session", "continue", "continue the last session", "continue my last chat",
    "erkläre die letzte pi-Session", "weiter", "pi is 3.14159, continue the series", "continue writing my session notes",
  ]) assert.equal(continuesLastSession(text), false, text);
});

test("prompt variant: quick and fast lanes keep the lean prompt; standard and up, coding asks and continued sessions get pi's coding prompt", () => {
  assert.equal(fullPromptVariant("what is the capital of France?"), "lean");
  assert.equal(fullPromptVariant("what is the capital of France?", { tier: "fast" }), "lean");
  assert.equal(fullPromptVariant("what is the capital of France?", { tier: "standard" }), "coding");
  assert.equal(fullPromptVariant("what is the capital of France?", { tier: "deep" }), "coding");
  assert.equal(fullPromptVariant("fix the failing unit tests in this repo"), "coding");
  assert.equal(fullPromptVariant("fix the failing unit tests in this repo", { tier: "quick" }), "coding", "a coding turn on a light lane");
  assert.equal(fullPromptVariant("hello", { resume: true }), "coding");
  assert.equal(fullPromptVariant("open Safari"), "lean");
  // A pi command runs on pi's own prompt, as in terminal pi, whatever lane it routes to.
  assert.equal(fullPromptVariant("/skill:fixture-global-skill hi"), "coding");
  assert.equal(fullPromptVariant("  /fixture-review alpha", { tier: "quick" }), "coding");
});

test("privacy-protected folders: Desktop, Documents, Downloads, iCloud and File Provider storage, volumes; lexical and case-insensitive", async () => {
  const home = "/Users/fixture";
  for (const path of ["/Users/fixture/Desktop", "/Users/fixture/Desktop/project", "/Users/fixture/desktop", "/Users/fixture/Documents/a/b",
    "/Users/fixture/Downloads", "/Users/fixture/Library/Mobile Documents/com~apple~CloudDocs/x", "/Users/fixture/Library/CloudStorage/Dropbox",
    "/Volumes/USB", "/volumes/Backup/x"]) assert.equal(isPrivacyProtected(path, home), true, path);
  for (const path of ["/Users/fixture", "/Users/fixture/Desktopx", "/Users/fixture/dev/Desktop", "/Users/fixture/Library",
    "/Users/fixture/Pictures", "/Volumesx", "/Users/other/Desktop"]) assert.equal(isPrivacyProtected(path, home), false, path);
});

test("working directory at use: an existing directory of the user's (its real path), else the home folder", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot();
  try {
    const link = join(dirs.home, "link");
    symlinkSync(dirs.project, link);
    const file = join(dirs.project, "file.txt");
    writeFileSync(file, "fixture");
    assert.equal(await resolveWorkingDirectory(dirs.project, dirs.home), dirs.project);
    assert.equal(await resolveWorkingDirectory(link, dirs.home), dirs.project, "the real path, like terminal pi's process.cwd()");
    for (const value of [undefined, join(dirs.home, "missing"), file, "/dev", "/usr", "relative", `${dirs.project}/`]) {
      assert.equal(await resolveWorkingDirectory(value, dirs.home), dirs.home, String(value));
    }
    // Key-down builds never read inside a protected folder or follow a link that may lead into one.
    mkdirSync(join(dirs.home, "Desktop"));
    assert.equal(await readsProtectedFolder(join(dirs.home, "Desktop"), dirs.home), true);
    assert.equal(await readsProtectedFolder(link, dirs.home), true);
    // A link earlier on the path (a terminal's logical $PWD through a linked folder) is not followed either.
    mkdirSync(join(dirs.project, "sub"));
    assert.equal(await readsProtectedFolder(join(link, "sub"), dirs.home), true);
    assert.equal(await readsProtectedFolder(join(dirs.project, "sub"), dirs.home), false);
    assert.equal(await readsProtectedFolder(dirs.project, dirs.home), false);
    assert.equal(await readsProtectedFolder(undefined, dirs.home), false, "no folder: the home folder, read at key-down like before");
    assert.equal(await readsProtectedFolder("relative", dirs.home), false, "an invalid value falls back to home");
  } finally { await dirs.close(); }
});

test("session folder: pi's own bucket for the folder, the settings' sessionDir, and pi's environment override only for the user's agent dir", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot();
  const previous = process.env.PI_CODING_AGENT_DIR;
  try {
    // The same bucket pi computes itself (getDefaultSessionDir) when this is pi's agent dir.
    process.env.PI_CODING_AGENT_DIR = dirs.agentDir;
    assert.equal(SessionManager.create(dirs.project).getSessionDir(), piSessionBucket(dirs.project, dirs.agentDir));
  } finally {
    if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = previous;
  }
  try {
    const env = { [PI_SESSION_DIR_ENV]: "~/pi-sessions" };
    assert.equal(sessionDirectory(dirs.project, dirs.agentDir, { home: dirs.home }), piSessionBucket(dirs.project, dirs.agentDir));
    assert.equal(sessionDirectory(dirs.project, dirs.agentDir, { home: dirs.home, configured: join(dirs.root, "configured") }), join(dirs.root, "configured"));
    // A relative sessionDir is relative to the session's folder, as terminal pi (its process cwd) reads it.
    assert.equal(sessionDirectory(dirs.project, dirs.agentDir, { home: dirs.home, configured: "pi-sessions" }), join(dirs.project, "pi-sessions"));
    assert.equal(sessionDirectory(dirs.project, dirs.agentDir, { home: dirs.home, env, defaultAgentDir: true }), join(dirs.home, "pi-sessions"));
    assert.equal(sessionDirectory(dirs.project, dirs.agentDir, { home: dirs.home, env }), piSessionBucket(dirs.project, dirs.agentDir),
      "a fixture agent dir never follows the environment");
  } finally { await dirs.close(); }
});

test("setup key and key-down builds: a full session is built for its folder and its request; isolated and Windows ignore both", async () => {
  const base: AgentRunOptions = {
    hostClient: {} as HostClient, contextId: "ctx-pinned", prompt: "", snapshot: snapshot(), capturesDir: "/captures", log: () => {},
    readOnly: false, resourceSelection: { mode: "trustedGlobal" }, services: { platform: "darwin", home: "/Users/fixture" },
  };
  const key = (overrides: Partial<AgentRunOptions>) => sessionSetupKey({ ...base, ...overrides });
  assert.equal(key({ workingDirectory: "/Users/fixture/a" }), key({ workingDirectory: "/Users/fixture/a" }));
  assert.notEqual(key({ workingDirectory: "/Users/fixture/a" }), key({ workingDirectory: "/Users/fixture/b" }));
  assert.notEqual(key({ workingDirectory: "/Users/fixture/a" }), key({}));
  assert.notEqual(key({ prompt: "continue my last pi session" }), key({ prompt: "" }), "a continued session is never a prepared one");
  assert.equal(key({ prompt: "write a haiku" }), key({ prompt: "" }));
  for (const other of [{ resourceSelection: { mode: "isolated" as const } }, { readOnly: true }, { services: { platform: "win32" as const } }]) {
    assert.equal(key({ ...other, workingDirectory: "/Users/fixture/a", prompt: "continue my last pi session" }), key(other), JSON.stringify(other));
  }
  assert.equal(isFullSession("darwin", false, { mode: "trustedGlobal" }), true);
  assert.equal(isFullSession("darwin", true, { mode: "trustedGlobal" }), false);
  assert.equal(isFullSession("win32", false, { mode: "trustedGlobal" }), false);
  assert.equal(isFullSession("darwin", false, { mode: "isolated" }), false);
  assert.equal(await defersPreparation({ ...base, workingDirectory: "/Users/fixture/Desktop" }), true);
  assert.equal(await defersPreparation({ ...base, resourceSelection: { mode: "isolated" }, workingDirectory: "/Users/fixture/Desktop" }), false);
  assert.equal(await defersPreparation({ ...base, services: { platform: "win32" }, workingDirectory: "/Users/fixture/Desktop" }), false);
});

// ---------------------------------------------------------------------------------------------
// Sessions on the faux provider

test("full pi session: pi's coding tools, the user's global extensions and pi-os tools with no allowlist; bash runs in the requested folder", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("global-agent-dir");
  const s = await scenario(dirs, { prompt: "run pwd here", workingDirectory: dirs.project, context: general() });
  try {
    s.runtimes.respond([s.reply(call("bash", { command: "pwd -P" })), s.reply(request => fauxAssistantMessage(`cwd: ${lastToolResult(request).text}`))]);
    const result = await s.first();
    const tools = s.requests[0]!.tools;
    for (const name of [...PI_DEFAULT_ACTIVE_TOOLS, "fixture_global_tool", "show_result", "instant_calc", "codemode", USE_ACTIVE_WINDOW_TOOL]) {
      assert.ok(tools.includes(name), name);
    }
    assert.ok(result.responseText.includes(dirs.project), "bash ran in the working directory");
    assert.deepEqual(s.toolCalls, ["bash"]);
  } finally { await s.close(); await dirs.close(); }
});

test("a session folder pi cannot open fails with a content-free error that never names the folder", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("global-agent-dir");
  // The settings' sessionDir runs through a regular file, so pi cannot create it.
  const blocker = join(dirs.root, "blocker");
  writeFileSync(blocker, "fixture");
  writeFileSync(join(dirs.agentDir, "settings.json"), JSON.stringify({ sessionDir: join(blocker, "sessions") }));
  const captures = tempCaptures();
  try {
    const pinned = captures.snapshot();
    const run = agentRun(agentHost(captures.dir, pinned), fauxRuntimes(), captures.dir, pinned, {
      prompt: "say hello", resourceSelection: { mode: "trustedGlobal" }, workingDirectory: dirs.project,
      services: { agentDir: dirs.agentDir, home: dirs.home, platform: "darwin" },
    });
    await assert.rejects(createLiveSession(run), (error: Error) => {
      assert.equal(error.message, FULL_SESSION_UNAVAILABLE);
      assert.ok(!error.message.includes(dirs.root));
      return true;
    });
  } finally { await captures.close(); await dirs.close(); }
});

test("bash guard: the user's global dcg extension intercepts bash like in terminal pi; a destructive command is blocked and its reason reaches the answer", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("guard-agent-dir");
  const blockedMarker = join(dirs.project, "blocked-ran");
  const allowedMarker = join(dirs.project, "allowed-ran");
  const s = await scenario(dirs, { prompt: "clean up this folder", workingDirectory: dirs.project, context: general() });
  try {
    let blocked: ReturnType<typeof lastToolResult> | undefined;
    let allowed: ReturnType<typeof lastToolResult> | undefined;
    s.runtimes.respond([
      s.reply(call("bash", { command: `touch ${JSON.stringify(blockedMarker)} # fixture-destructive` })),
      s.reply(request => { blocked = lastToolResult(request); return callMessage("bash", { command: `touch ${JSON.stringify(allowedMarker)}` }); }),
      s.reply(request => { allowed = lastToolResult(request); return fauxAssistantMessage(`The guard stopped the first command: ${blocked!.text}`); }),
    ]);
    const result = await s.first();
    assert.equal(blocked!.isError, true);
    assert.match(blocked!.text, /fixture dcg guard: denied/);
    assert.equal(existsSync(blockedMarker), false, "the blocked command never ran");
    assert.match(result.responseText, /fixture dcg guard: denied/, "the block reason reaches the answer");
    assert.equal(allowed!.isError, false);
    assert.equal(existsSync(allowedMarker), true, "an ordinary command runs");
    assert.deepEqual(s.toolCalls, ["bash", "bash"], "both calls show as bash activity; pi-os added no confirm of its own");
  } finally { await s.close(); await dirs.close(); }
});

test("prompt: a quick ask keeps the lean pi-os prompt, a coding ask gets pi's coding prompt with project context; the first turn decides", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("global-agent-dir");
  writeFileSync(join(dirs.project, "AGENTS.md"), "FIXTURE_PROJECT_RULE: run the fixture tests first.");
  const lean = await scenario(dirs, { prompt: "what is the capital of France?", workingDirectory: dirs.project, context: general() });
  try {
    lean.runtimes.respond([lean.reply(say("Paris.")), lean.reply(say("Fixed."))]);
    await lean.first();
    await lean.followup("now fix the failing unit tests in this repo");
    const [first, second] = lean.requests;
    assert.equal(first!.system, fullSessionSystemPrompt(PI_OS_SYSTEM_PROMPT, { workingDirectory: dirs.project }));
    assert.equal(second!.system, first!.system, "follow-ups keep the first turn's prompt (prompt caching)");
    assert.doesNotMatch(first!.system, /expert coding assistant|FIXTURE_PROJECT_RULE|<cwd>|## pi-os rules/);
    assert.doesNotMatch(first!.request, /Trusted pi compatibility|Extensions execute code/);
    assert.ok(first!.tools.includes("bash"), "full tools on a lean prompt");
    assert.equal(promptVariant(lean.live), "lean");
  } finally { await lean.close(); }

  const coding = await scenario(dirs, { prompt: "fix the failing unit tests in this repo", workingDirectory: dirs.project, context: general() });
  try {
    coding.runtimes.respond([coding.reply(say("Done."))]);
    await coding.first();
    const { system, request } = coding.requests[0]!;
    assert.match(system, /^You are an expert coding assistant operating inside pi/);
    assert.match(system, /FIXTURE_PROJECT_RULE/, "the folder's AGENTS.md loads like in terminal pi");
    assert.ok(system.includes(`<cwd>\n${dirs.project}\n</cwd>`));
    assert.ok(system.endsWith(`\n\n${FULL_SESSION_SECTION.join("\n")}`));
    assert.doesNotMatch(system, /Trusted pi compatibility|## pi-os rules/);
    assert.doesNotMatch(request, /Trusted pi compatibility|Extensions execute code/);
    assert.equal(promptVariant(coding.live), "coding");
  } finally { await coding.close(); }

  // Auto: the router's lane decides (a short question routes to the quick lane).
  const auto = await scenario(dirs, { prompt: "what is the capital of France?", workingDirectory: dirs.project, context: general(), modelSelection: null });
  try {
    auto.runtimes.respond([auto.reply(say("Paris."))]);
    await auto.first();
    assert.equal(promptVariant(auto.live), "lean");
    assert.equal(auto.requests[0]!.system, fullSessionSystemPrompt(PI_OS_SYSTEM_PROMPT, { workingDirectory: dirs.project }));
  } finally { await auto.close(); await dirs.close(); }
});

test("saved sessions: a full thread is a pi session file in pi's bucket for its folder; follow-ups append; an explicit request continues it", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("global-agent-dir");
  const bucket = piSessionBucket(dirs.project, dirs.agentDir);
  try {
    const first = await scenario(dirs, { prompt: "say hello", workingDirectory: dirs.project, context: general() });
    try {
      first.runtimes.respond([first.reply(say("hello")), first.reply(say("again"))]);
      await first.first();
      await first.followup("once more");
    } finally { await first.close(); }
    const files = jsonl(bucket);
    assert.equal(files.length, 1, "one pi session file per thread");
    const file = join(bucket, files[0]!);
    assert.equal(userMessages(file).length, 2, "the follow-up appended to the same file");
    assert.equal(SessionManager.open(file).getHeader()?.cwd, dirs.project);
    assert.equal(SessionManager.continueRecent(dirs.project, bucket).getSessionFile(), file, "pi's own resume finds it");

    const resumed = await scenario(dirs, { prompt: "continue my last pi session", workingDirectory: dirs.project, context: general() });
    try {
      resumed.runtimes.respond([resumed.reply(say("continuing"))]);
      await resumed.first();
      const request = resumed.requests[0]!;
      assert.ok(request.messages.some(message => message.role === "user" && textOf(message).includes("say hello")), "the earlier conversation is in context");
      assert.match(request.request, /## Continued pi session\nThis thread continues the user's most recent pi session in this folder/);
      assert.equal(promptVariant(resumed.live), "coding");
    } finally { await resumed.close(); }
    assert.deepEqual(jsonl(bucket), files, "the continued thread appends to the same file");
    assert.equal(userMessages(file).length, 3);

    // A folder without a saved session: the note says so and a new file starts there.
    const fresh = await scenario(dirs, { prompt: "mach mit der letzten pi-Session weiter", workingDirectory: dirs.home, context: general() });
    try {
      fresh.runtimes.respond([fresh.reply(say("none yet"))]);
      await fresh.first();
      assert.match(fresh.requests[0]!.request, /## Continued pi session\nThe user asked to continue their last pi session, but this folder has no saved pi session yet/);
    } finally { await fresh.close(); }
    assert.equal(jsonl(piSessionBucket(dirs.home, dirs.agentDir)).length, 1);
    assert.equal(jsonl(bucket).length, 1);
  } finally { await dirs.close(); }
});

test("golden: isolated macOS and Windows sessions are unchanged by a working directory, a home or a continue request, and save nothing", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("guard-agent-dir");
  const capture = async (options: FullScenarioOptions) => {
    const s = await scenario(dirs, options);
    try {
      s.runtimes.respond([s.reply(say("Answer."))]);
      await s.first();
      const { system, tools, descriptions, request, requestImages } = s.requests[0]!;
      return { system, tools, descriptions, request, requestImages, variant: promptVariant(s.live) };
    } finally { await s.close(); }
  };
  try {
    const cases: [string, FullScenarioOptions][] = [
      ["isolated macOS", { prompt: "continue my last pi session", resourceSelection: { mode: "isolated" } }],
      ["isolated macOS, general", { prompt: "continue my last pi session", resourceSelection: { mode: "isolated" }, context: general() }],
      ["Windows", { prompt: "continue my last pi session", platform: "win32" }],
    ];
    for (const [name, options] of cases) {
      const plain = await capture(options);
      const extra = await capture({ ...options, workingDirectory: dirs.project });
      assert.deepEqual(extra, plain, name);
      assert.equal(plain.variant, undefined, name);
      assert.doesNotMatch(plain.request, /Continued pi session/, name);
      assert.doesNotMatch(plain.system, /pi-os desktop session|Working directory:/, name);
      if (options.platform === "win32") {
        assert.match(plain.system, /\n\n## pi-os desktop invocation\n\nThe user pressed the pi-os global hotkey while working in a Windows desktop application/);
        assert.ok(plain.system.includes(`<cwd>\n${process.cwd()}\n</cwd>`), "Windows keeps the harness's own folder");
      } else {
        assert.equal(plain.system, scopedSystemPrompt(PI_OS_SYSTEM_PROMPT, false), name);
        assert.ok(!plain.tools.includes("bash"), name);
      }
    }
    assert.equal(existsSync(join(dirs.agentDir, "sessions")), false, "isolated and Windows threads stay in memory");
  } finally { await dirs.close(); }
});

test("pi commands: a full session sends /skill:, prompt templates and extension commands to pi as typed, the desktop context after them; isolated and Windows stay wrapped", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("global-agent-dir");
  // The temporary agent dir gets a prompt template and an extension command (both fixtures; nothing of the user's).
  mkdirSync(join(dirs.agentDir, "prompts"));
  writeFileSync(join(dirs.agentDir, "prompts", "fixture-review.md"), "FIXTURE_TEMPLATE: review $1 carefully.\n");
  const noted = join(dirs.root, "noted");
  writeFileSync(join(dirs.agentDir, "extensions", "fixture-command.ts"), [
    'import { writeFileSync } from "node:fs";',
    `export default function fixtureCommand(pi: any): void { pi.registerCommand("fixture-note", { description: "Fixture command", handler: async (args: string) => { writeFileSync(${JSON.stringify(noted)}, args); } }); }`,
  ].join("\n"));
  const users = (request: SeenRequest) => request.messages.filter(message => message.role === "user");
  const CONTEXT_HEADER = "## pi-os context for the command above (from pi-os, not part of the command)\n";
  try {
    // A skill in a window turn: pi expands it from the trimmed request; the screenshot travels with the command and the
    // desktop context follows it in a hidden message. The thread runs on pi's coding prompt.
    const skill = await scenario(dirs, { prompt: "  /skill:fixture-global-skill check the build  ", workingDirectory: dirs.project });
    try {
      skill.runtimes.respond([skill.reply(say("Checked."))]);
      await skill.first();
      const [command, context, ...rest] = users(skill.requests[0]!);
      assert.equal(rest.length, 0);
      assert.match(textOf(command), /^<skill name="fixture-global-skill" location="[^"]+">\n/);
      assert.match(textOf(command), /# Fixture Global Skill/);
      assert.ok(textOf(command).endsWith("</skill>\n\ncheck the build"));
      assert.doesNotMatch(textOf(command), /## Request|## Desktop context|pi-os context/);
      assert.equal(partsOf(command).filter(part => part.type === "image").length, 1, "the window's screenshot travels with the command");
      assert.ok(textOf(context).startsWith(`${CONTEXT_HEADER}## Desktop context (target identity pinned before the prompt appeared)\n`));
      assert.doesNotMatch(textOf(context), /## Request|fixture-global-skill/, "the command is not repeated");
      assert.equal(promptVariant(skill.live), "coding");
      assert.match(skill.requests[0]!.system, /^You are an expert coding assistant operating inside pi/);
    } finally { await skill.close(); }

    // A prompt template in a general turn, then an extension command (pi runs it; no model request), then an ordinary
    // follow-up, which keeps today's wrapper.
    const templated = await scenario(dirs, { prompt: "/fixture-review alpha", workingDirectory: dirs.project, context: general() });
    try {
      templated.runtimes.respond([templated.reply(say("Reviewed.")), templated.reply(say("Bye."))]);
      await templated.first();
      const [command, context] = users(templated.requests[0]!);
      assert.match(textOf(command), /^FIXTURE_TEMPLATE: review alpha carefully\.\s*$/);
      assert.ok(textOf(context).startsWith(`${CONTEXT_HEADER}Active app: "TextEdit" (its window is not included).`));
      await templated.followup("/fixture-note hello there");
      assert.equal(readFileSync(noted, "utf8"), "hello there");
      assert.equal(templated.requests.length, 1, "an extension command makes no model request");
      await templated.followup("now say bye");
      assert.equal(templated.requests.length, 2);
      assert.ok(textOf(users(templated.requests[1]!).at(-1)).endsWith("## Request\nnow say bye"));
    } finally { await templated.close(); }

    // Isolated macOS and Windows sessions send a "/…" request inside today's wrapper, unexpanded.
    for (const [name, options] of [["isolated macOS", { resourceSelection: { mode: "isolated" } }], ["Windows", { platform: "win32" }]] as const) {
      const s = await scenario(dirs, { prompt: "/skill:fixture-global-skill check the build", ...options });
      try {
        s.runtimes.respond([s.reply(say("Answer."))]);
        await s.first();
        assert.ok(s.requests[0]!.request.endsWith("## Request\n/skill:fixture-global-skill check the build"), name);
        assert.doesNotMatch(JSON.stringify(s.requests[0]!.messages), /<skill name=|pi-os context for the command/, name);
      } finally { await s.close(); }
    }
    assert.equal(readFileSync(noted, "utf8"), "hello there", "no other command ran");
  } finally { await dirs.close(); }
});

// ---------------------------------------------------------------------------------------------
// HTTP

/** console.log lines while the test runs (for privacy checks and the prepare log). */
function recordLogs() {
  const lines: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => { lines.push(args.map(String).join(" ")); };
  return { lines, restore: () => { console.log = original; } };
}

test("HTTP: workingDirectory on prepare and /invoke, reuse only for the same folder, a saved session file, nothing echoed or recorded", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("guard-agent-dir");
  const runtimes = fauxRuntimes();
  const resourceSettings = new AgentResourceSettings(join(dirs.root, "resources.json"));
  resourceSettings.set("trustedGlobal", true);
  const f = await start({ runtimes, resourceSettings, agentServices: { agentDir: dirs.agentDir, home: dirs.home } });
  const logs = recordLogs();
  const ok = () => fauxAssistantMessage("done");
  const settle = async (count: number) => { for (let i = 0; i < 400 && runtimes.created < count; i++) await delay(5); };
  try {
    // Strict values: the issue code only, never the value; nothing is created.
    const bad = await f.post("/invoke", { invocationId: "bad-wd", contextId: "ctx-pinned", prompt: "hi", workingDirectory: "fixture/relative" });
    assert.equal(bad.status, 400);
    assert.deepEqual(await bad.json(), { error: { code: "invalid_arguments", message: "workingDirectory is invalid (not_absolute)" } });
    assert.equal((await f.get("/invocations/bad-wd")).status, 404);
    const badPrepare = await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-bad", workingDirectory: "/dev/fixture" });
    assert.deepEqual([badPrepare.status, await badPrepare.json()], [400, { error: { code: "invalid_arguments", message: "workingDirectory is invalid (blocked_root)" } }]);
    assert.equal((await f.post("/invocations/prepare", { takeId: "take-bad", cancel: true, workingDirectory: 42 })).status, 200, "a cancel ignores it");

    // The same folder: the prepared session is adopted; the thread is a pi session file, follow-ups append.
    assert.equal((await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-1", workingDirectory: dirs.project })).status, 202);
    await settle(1);
    runtimes.respond([ok]);
    await f.post("/invoke", { invocationId: "same", contextId: "ctx-pinned", prompt: "write a haiku", takeId: "take-1", workingDirectory: dirs.project, retainSession: true });
    const same = await f.terminal("same");
    assert.equal(same.state, "completed", same.failureMessage);
    assert.equal(runtimes.created, 1, "reused for the same folder");
    runtimes.respond([ok]);
    assert.equal((await f.post("/invocations/same/followup", { prompt: "another one", workingDirectory: dirs.home })).status, 202);
    assert.equal((await f.terminal("same")).state, "completed");
    const bucket = piSessionBucket(dirs.project, dirs.agentDir);
    assert.equal(jsonl(bucket).length, 1);
    assert.equal(userMessages(join(bucket, jsonl(bucket)[0]!)).length, 2, "the follow-up kept the thread's folder and file");

    // Another folder: the prepared session is not adopted.
    await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-2", workingDirectory: dirs.project });
    await settle(2);
    runtimes.respond([ok]);
    await f.post("/invoke", { invocationId: "other", contextId: "ctx-pinned", prompt: "write a haiku", takeId: "take-2", workingDirectory: dirs.home });
    assert.equal((await f.terminal("other")).state, "completed");
    assert.equal(runtimes.created, 3);
    assert.equal(jsonl(piSessionBucket(dirs.home, dirs.agentDir)).length, 1);

    // A privacy-protected folder is not read at key-down: the session is built at /invoke.
    const desktop = join(dirs.home, "Desktop");
    mkdirSync(desktop);
    await f.post("/invocations/prepare", { contextId: "ctx-pinned", takeId: "take-3", workingDirectory: desktop });
    for (let i = 0; i < 400 && !logs.lines.some(line => line.includes("[prepare] no session: deferred to invoke")); i++) await delay(5);
    assert.ok(logs.lines.some(line => line.includes("[prepare] no session: deferred to invoke")));
    assert.equal(runtimes.created, 3, "nothing was built at key-down");
    runtimes.respond([ok]);
    await f.post("/invoke", { invocationId: "desktop", contextId: "ctx-pinned", prompt: "write a haiku", takeId: "take-3", workingDirectory: desktop });
    assert.equal((await f.terminal("desktop")).state, "completed");
    assert.equal(jsonl(piSessionBucket(desktop, dirs.agentDir)).length, 1);

    // Privacy: no record or log line names a folder.
    for (const id of ["same", "other", "desktop"]) {
      assert.ok(!JSON.stringify(await (await f.get(`/invocations/${id}`)).json()).includes(dirs.root), id);
    }
    assert.ok(!logs.lines.some(line => line.includes(dirs.root)), "logs stay content-free");
  } finally { logs.restore(); await f.close(); await dirs.close(); }
});

test("invocation limit config: full sessions default to 60 minutes (PI_OS_FULL_INVOKE_TIMEOUT_MS), separate from PI_OS_INVOKE_TIMEOUT_MS", () => {
  assert.equal(FULL_INVOKE_TIMEOUT_MS, 60 * 60_000);
  assert.equal(loadConfig({}).fullInvokeTimeoutMs, FULL_INVOKE_TIMEOUT_MS);
  assert.equal(loadConfig({}).invokeTimeoutMs, 300_000, "isolated sessions and Windows keep 5 minutes");
  assert.equal(loadConfig({ PI_OS_FULL_INVOKE_TIMEOUT_MS: "120000" }).fullInvokeTimeoutMs, 120_000);
  assert.equal(loadConfig({ PI_OS_FULL_INVOKE_TIMEOUT_MS: "120000" }).invokeTimeoutMs, 300_000);
  assert.equal(loadConfig({ PI_OS_FULL_INVOKE_TIMEOUT_MS: "0" }).fullInvokeTimeoutMs, 0, "0 disables it, like PI_OS_INVOKE_TIMEOUT_MS");
  for (const raw of ["soon", "-1", ""]) assert.equal(loadConfig({ PI_OS_FULL_INVOKE_TIMEOUT_MS: raw }).fullInvokeTimeoutMs, FULL_INVOKE_TIMEOUT_MS, raw);
  assert.equal(loadConfig({ PI_OS_INVOKE_TIMEOUT_MS: "1000" }).fullInvokeTimeoutMs, FULL_INVOKE_TIMEOUT_MS);
});

test("HTTP: a full session's turns (first and follow-up) run under the full limit; an isolated turn keeps the invocation limit", { skip: MACOS_ONLY }, async () => {
  const dirs = fullRoot("guard-agent-dir");
  // A turn longer than the invocation limit (a long coding step, or dcg's approval dialog).
  const slow = async () => { await delay(3_500); return fauxAssistantMessage("done"); };
  let servers = 0;
  const serve = async (mode: "isolated" | "trustedGlobal", config: Partial<HarnessConfig>) => {
    const runtimes = fauxRuntimes();
    const resourceSettings = new AgentResourceSettings(join(dirs.root, `resources-${++servers}.json`));
    if (mode === "trustedGlobal") resourceSettings.set("trustedGlobal", true);
    const f = await start({ runtimes, resourceSettings, agentServices: { agentDir: dirs.agentDir, home: dirs.home }, config });
    const settled = async (id: string) => {
      for (let i = 0; i < 2_000; i++) {
        const status = await (await f.get(`/invocations/${id}`)).json() as { state: string; failureMessage?: string };
        if (!["queued", "running"].includes(status.state)) return status;
        await delay(10);
      }
      throw new Error("Invocation did not settle");
    };
    return { f, runtimes, settled };
  };
  try {
    const limits = { invokeTimeoutMs: 2_500, fullInvokeTimeoutMs: 60_000 };
    const full = await serve("trustedGlobal", limits);
    try {
      full.runtimes.respond([slow, slow]);
      await full.f.post("/invoke", { invocationId: "full", contextId: "ctx-pinned", prompt: "write a haiku", workingDirectory: dirs.project, retainSession: true });
      const first = await full.settled("full");
      assert.equal(first.state, "completed", first.failureMessage);
      assert.equal((await full.f.post("/invocations/full/followup", { prompt: "another one" })).status, 202);
      const followup = await full.settled("full");
      assert.equal(followup.state, "completed", followup.failureMessage);
    } finally { await full.f.close(); }

    const isolated = await serve("isolated", limits);
    try {
      isolated.runtimes.respond([slow]);
      await isolated.f.post("/invoke", { invocationId: "isolated", contextId: "ctx-pinned", prompt: "write a haiku" });
      assert.equal((await isolated.settled("isolated")).state, "timed_out");
    } finally { await isolated.f.close(); }

    // The full limit is a limit too (not just a longer one): shorter than the turn, the full session times out.
    const short = await serve("trustedGlobal", { invokeTimeoutMs: 60_000, fullInvokeTimeoutMs: 500 });
    try {
      short.runtimes.respond([slow]);
      await short.f.post("/invoke", { invocationId: "short", contextId: "ctx-pinned", prompt: "write a haiku", workingDirectory: dirs.project });
      assert.equal((await short.settled("short")).state, "timed_out");
    } finally { await short.f.close(); }
  } finally { await dirs.close(); }
});

test("GET /settings/resources status: the bash guard among the global extensions while full sessions are on; none otherwise, without loading them", async () => {
  const resourcesBody = async (options: { fixture: string; mode: "isolated" | "trustedGlobal"; platform?: NodeJS.Platform; readOnly?: boolean;
    host?: ReturnType<typeof fakeHost>; setup?: (agentDir: string) => void }) => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-os-status-")));
    const agentDir = join(root, "agent");
    cpSync(join(FIXTURES, options.fixture), agentDir, { recursive: true });
    options.setup?.(agentDir);
    const resourceSettings = new AgentResourceSettings(join(root, "resources.json"));
    if (options.mode === "trustedGlobal") resourceSettings.set("trustedGlobal", true);
    const f = await start({ resourceSettings, platform: options.platform ?? "darwin", agentServices: { agentDir },
      ...(options.host ? { host: options.host } : {}), ...(options.readOnly ? { config: { readOnly: true } } : {}) });
    try {
      const response = await f.get("/settings/resources");
      assert.equal(response.status, 200);
      return { body: await response.json() as any, root, agentDir };
    } finally { await f.close(); }
  };
  const roots: string[] = [];
  try {
    for (const [fixture, guard] of [["guard-agent-dir", "dcg"], ["other-guard-agent-dir", "other"], ["global-agent-dir", "none"]] as const) {
      const { body, root } = await resourcesBody({ fixture, mode: "trustedGlobal" });
      roots.push(root);
      assert.deepEqual(body.status, { fullSession: true, guard }, fixture);
      assert.deepEqual(parseResourceStatus(body.status), body.status);
      assert.deepEqual(body.current, { mode: "trustedGlobal" });
      assert.equal(typeof body.warning, "string");
      assert.ok(!JSON.stringify(body).includes(root), "content-free");
    }
    // A global extension that records being loaded: only a full-session status loads it.
    const marker = (agentDir: string) => join(agentDir, "..", "loaded");
    const setup = (agentDir: string) => writeFileSync(join(agentDir, "extensions", "audit-marker.ts"), [
      'import { writeFileSync } from "node:fs";',
      `export default function auditMarker(pi: any): void { writeFileSync(${JSON.stringify(marker(agentDir))}, "loaded"); pi.on("tool_call", () => undefined); }`,
    ].join("\n"));
    for (const [name, options] of [
      ["isolated", { mode: "isolated" }],
      ["Windows", { mode: "trustedGlobal", platform: "win32" }],
      ["read-only launch", { mode: "trustedGlobal", readOnly: true }],
      ["no computer control", { mode: "trustedGlobal", host: fakeHost({ tools: [] }) }],
    ] as const) {
      const { body, root, agentDir } = await resourcesBody({ fixture: "global-agent-dir", setup, ...options });
      roots.push(root);
      assert.deepEqual(body.status, { fullSession: false, guard: "none" }, name);
      assert.equal(existsSync(marker(agentDir)), false, `${name}: no global extension code ran`);
    }
    const { body, root, agentDir } = await resourcesBody({ fixture: "global-agent-dir", setup, mode: "trustedGlobal" });
    roots.push(root);
    assert.deepEqual(body.status, { fullSession: true, guard: "other" });
    assert.equal(existsSync(marker(agentDir)), true);
  } finally { await Promise.all(roots.map(root => rm(root, { recursive: true, force: true }))); }
});

test("GET /settings/resources status: the global extensions load once per process, again only when their folder, the agent dir's settings or the resource mode change", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-os-status-cache-")));
  const agentDir = join(root, "agent");
  const extensions = join(agentDir, "extensions");
  cpSync(join(FIXTURES, "other-guard-agent-dir"), agentDir, { recursive: true });
  // A global extension that counts how often its factory runs (a stand-in for one that fetches a model list).
  const counter = join(root, "loads");
  writeFileSync(join(extensions, "load-counter.ts"), [
    'import { appendFileSync } from "node:fs";',
    `export default function loadCounter(): void { appendFileSync(${JSON.stringify(counter)}, "x"); }`,
  ].join("\n"));
  const loads = () => existsSync(counter) ? readFileSync(counter, "utf8").length : 0;
  const resourceSettings = new AgentResourceSettings(join(root, "resources.json"));
  resourceSettings.set("trustedGlobal", true);
  const f = await start({ resourceSettings, platform: "darwin", agentServices: { agentDir } });
  const status = async () => {
    const response = await f.get("/settings/resources");
    assert.equal(response.status, 200);
    return (await response.json() as { status: unknown }).status;
  };
  // Explicit, distinct mtimes (seconds), so a change never hides within the file system's timestamp resolution.
  const touch = (path: string, seconds: number) => utimesSync(path, seconds, seconds);
  try {
    assert.deepEqual(await status(), { fullSession: true, guard: "other" });
    assert.equal(loads(), 1);
    assert.deepEqual(await status(), { fullSession: true, guard: "other" });
    assert.deepEqual(await status(), { fullSession: true, guard: "other" });
    assert.equal(loads(), 1, "later statuses reuse the first load");

    // An extension added to the folder: loaded again, and the new guard shows.
    cpSync(join(FIXTURES, "guard-agent-dir", "extensions", "dcg-guard.ts"), join(extensions, "dcg-guard.ts"));
    touch(extensions, 1_900_000_000);
    assert.deepEqual(await status(), { fullSession: true, guard: "dcg" });
    assert.equal(loads(), 2);
    assert.deepEqual(await status(), { fullSession: true, guard: "dcg" });
    assert.equal(loads(), 2);

    // The agent dir's settings (extension packages and paths live there): loaded again.
    writeFileSync(join(agentDir, "settings.json"), "{}\n");
    touch(join(agentDir, "settings.json"), 1_900_000_100);
    assert.deepEqual(await status(), { fullSession: true, guard: "dcg" });
    assert.equal(loads(), 3);

    // Isolated: nothing loads; back to full sessions: loaded again.
    assert.equal((await f.post("/settings/resources", { mode: "isolated" })).status, 200);
    assert.deepEqual(await status(), { fullSession: false, guard: "none" });
    assert.equal(loads(), 3);
    assert.equal((await f.post("/settings/resources", { mode: "trustedGlobal", acknowledgeUnpinnedAccess: true })).status, 200);
    assert.deepEqual(await status(), { fullSession: true, guard: "dcg" });
    assert.equal(loads(), 4);
    assert.deepEqual(await status(), { fullSession: true, guard: "dcg" });
    assert.equal(loads(), 4);
  } finally { await f.close(); await rm(root, { recursive: true, force: true }); }
});
