import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { test } from "node:test";
import {
  createAgentSession, createBashTool, createEditTool, createFindTool, createGrepTool, createLsTool, createPowerShellTool,
  createReadTool, createWriteTool, ModelRuntime, SessionManager, SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { parseContext } from "../src/contracts/context.js";
import {
  AGENT_STEP_PREFIX, agentStepName, BASH_GUARDS, bashGuardOf, GUARD_EVENT, isPiCodingTool, isUnderBlockedRoot, isWorkingDirectory,
  parseResourceStatus, parseWorkingDirectory, PI_CODING_TOOLS, PI_DEFAULT_ACTIVE_TOOLS, WORKING_DIRECTORY_BLOCKED_ROOTS,
  WORKING_DIRECTORY_ISSUES, WORKING_DIRECTORY_LIMITS, workingDirectoryIssue,
  type GuardCandidate, type ResourceSettingsResponse,
} from "../src/contracts/piSession.js";
import { loadAgentResources } from "../src/agent/resources.js";
import type { ResourceMode } from "../src/agent/resourceSettings.js";

const fixtures = join(import.meta.dirname, "..", "..", "shared", "fixtures", "pi-session");
const readJson = (path: string): any => JSON.parse(readFileSync(path, "utf8"));
const jsonFiles = (dir: string, prefix = ""): string[] => {
  const files = readdirSync(join(fixtures, dir)).filter((f) => f.endsWith(".json") && f.startsWith(prefix)).sort().map((f) => join(fixtures, dir, f));
  assert.ok(files.length > 0, `${dir}/${prefix}*`);
  return files;
};
const isBody = (file: string) => /^(invoke|prepare)-/.test(basename(file));

test("workingDirectory fixtures: every valid /invoke and /prepare body parses to exactly its value, null and absence to none", () => {
  const bodies = jsonFiles(".").filter(isBody);
  assert.ok(bodies.length >= 5);
  for (const file of bodies) {
    const body = readJson(file);
    const parsed = parseWorkingDirectory(body.workingDirectory);
    assert.equal(parsed.ok, true, file);
    if (!parsed.ok) continue;
    if (body.workingDirectory === undefined || body.workingDirectory === null) assert.deepEqual(parsed, { ok: true }, file);
    else assert.deepEqual(parsed, { ok: true, workingDirectory: body.workingDirectory }, file);
    // Additive: the rest of an /invoke body still parses as before.
    if (basename(file).startsWith("invoke-")) assert.equal(parseContext(body.context).ok, true, file);
  }
});

test("workingDirectory fixtures: every invalid body is rejected for the expected reason, without echoing the value", () => {
  for (const file of jsonFiles("invalid").filter(isBody)) {
    const body = readJson(file);
    assert.ok((WORKING_DIRECTORY_ISSUES as readonly string[]).includes(body._expect), `${file}: _expect`);
    const parsed = parseWorkingDirectory(body.workingDirectory);
    assert.equal(parsed.ok, false, file);
    if (parsed.ok) continue;
    assert.equal(parsed.code, body._expect, file);
    assert.equal(parsed.error, `workingDirectory is invalid (${body._expect})`, file);
    for (const fragment of ["fixture", "Projects", "System", "Library", "/dev", "sudo", "42"]) assert.ok(!parsed.error.includes(fragment), `${file} echoes ${fragment}`);
  }
});

test("workingDirectory boundary table: both sides agree on every value and issue code", () => {
  const cases = readJson(join(fixtures, "working-directory-cases.json")) as { valid: string[]; invalid: { value: unknown; _expect: string }[] };
  assert.ok(cases.valid.length >= 15 && cases.invalid.length >= 35);
  for (const value of cases.valid) {
    assert.equal(workingDirectoryIssue(value), undefined, JSON.stringify(value).slice(0, 60));
    assert.deepEqual(parseWorkingDirectory(value), { ok: true, workingDirectory: value });
    assert.ok(Buffer.byteLength(value) <= WORKING_DIRECTORY_LIMITS.maxBytes);
  }
  for (const { value, _expect } of cases.invalid) {
    assert.ok((WORKING_DIRECTORY_ISSUES as readonly string[]).includes(_expect), _expect);
    assert.equal(workingDirectoryIssue(value), _expect, JSON.stringify(value).slice(0, 60));
    assert.equal(isWorkingDirectory(value), false);
  }
  // Every issue code is exercised by the table.
  assert.deepEqual([...new Set(cases.invalid.map((entry) => entry._expect))].sort(), [...WORKING_DIRECTORY_ISSUES].sort());
  // The byte limit is about UTF-8 (PATH_MAX), so 601 characters can already be too long.
  const umlauts = cases.invalid.find((entry) => typeof entry.value === "string" && entry.value.startsWith("/ü"))!.value as string;
  assert.equal(umlauts.length, 601);
});

test("blocked roots: exact names, ASCII case-insensitive, whole components only", () => {
  assert.deepEqual(WORKING_DIRECTORY_BLOCKED_ROOTS, ["/System", "/private/var/db", "/var/db", "/dev"]);
  assert.equal(WORKING_DIRECTORY_LIMITS.maxBytes, 1_024);
  for (const path of ["/System", "/system/x", "/DEV", "/dev/fd/3", "/private/var/db", "/var/DB/x"]) assert.equal(isUnderBlockedRoot(path), true, path);
  for (const path of ["/Systems", "/device", "/private/var/dbx", "/private/var", "/var", "/Users/fixture/dev", "/\u017Fystem"]) {
    assert.equal(isUnderBlockedRoot(path), false, path);
  }
});

test("resources status fixtures: valid bodies parse exactly, legacy has none, invalid ones are rejected", () => {
  for (const file of jsonFiles(".", "resources-")) {
    const body = readJson(file) as ResourceSettingsResponse;
    const mode: ResourceMode = body.current.mode;
    assert.ok(mode === "isolated" || mode === "trustedGlobal", file);
    assert.equal(typeof body.warning, "string", file);
    if (basename(file) === "resources-legacy.json") { assert.equal(body.status, undefined); continue; }
    assert.deepEqual(parseResourceStatus(body.status), body.status, file);
    if (!body.status!.fullSession) assert.equal(body.status!.guard, "none", `${file}: no full session loads no global extension`);
  }
  for (const file of jsonFiles("invalid", "resources-")) assert.equal(parseResourceStatus(readJson(file).status), null, file);
  assert.deepEqual(BASH_GUARDS, ["dcg", "other", "none"]);
  assert.deepEqual(parseResourceStatus({ fullSession: true, guard: "dcg", path: "/Users/fixture/.pi" }), { fullSession: true, guard: "dcg" });
});

test("bashGuardOf: only file-backed global extensions that handle tool_call count, dcg by name", () => {
  const ext = (path: string, events: string[] = [GUARD_EVENT], scope = "user"): GuardCandidate => ({ path, scope, events });
  const home = "/Users/fixture/.pi/agent";
  assert.equal(bashGuardOf([]), "none");
  // pi-os's own inline extensions (the codemode policy handles tool_call) and pi built-ins never count.
  assert.equal(bashGuardOf([ext("<inline:pi-os-codemode-policy>"), ext("<inline>"), ext("builtin:mcp")]), "none");
  assert.equal(bashGuardOf([ext(`${home}/extensions/dcg-guard.ts`)]), "dcg");
  assert.equal(bashGuardOf([ext(`${home}/extensions/dcg.js`)]), "dcg");
  assert.equal(bashGuardOf([ext(`${home}/packages/node_modules/pi-dcg/index.ts`)]), "dcg");
  assert.equal(bashGuardOf([ext("C:\\Users\\fixture\\.pi\\agent\\extensions\\DCG_Guard.ts")]), "dcg");
  assert.equal(bashGuardOf([ext(`${home}/extensions/dcguard.ts`)]), "other");
  assert.equal(bashGuardOf([ext(`${home}/extensions/command-audit.ts`)]), "other");
  assert.equal(bashGuardOf([ext(`${home}/extensions/command-audit.ts`), ext(`${home}/extensions/dcg-guard.ts`)]), "dcg");
  // A dcg-named extension that does not see tool calls guards nothing; project or temporary extensions are not global.
  assert.equal(bashGuardOf([ext(`${home}/extensions/dcg-status.ts`, ["session_start"])]), "none");
  assert.equal(bashGuardOf([ext("/Users/fixture/Projects/demo/.pi/extensions/dcg-guard.ts", [GUARD_EVENT], "project")]), "none");
  assert.equal(bashGuardOf([ext("/tmp/dcg-guard.ts", [GUARD_EVENT], "temporary")]), "none");
  // A user name that happens to be "dcg" is not the extension's name.
  assert.equal(bashGuardOf([ext("/Users/dcg/.pi/agent/extensions/audit.ts")]), "other");
  // events may be any iterable (pi's handlers Map keys).
  assert.equal(bashGuardOf([{ path: `${home}/extensions/dcg-guard.ts`, scope: "user", events: new Map([[GUARD_EVENT, []]]).keys() }]), "dcg");
});

/** pi's loaded extensions as GuardCandidates (what Node passes to bashGuardOf). */
async function guardOfAgentDir(agentDir: string): Promise<string> {
  const cwd = await mkdtemp(join(tmpdir(), "pi-os-guard-"));
  try {
    const loader = await loadAgentResources([{ name: "fixture-inline-policy", factory(pi) { pi.on("tool_call", () => undefined); } }],
      cwd, agentDir, false);
    return bashGuardOf(loader.getExtensions().extensions.map((extension) => ({
      path: extension.path, scope: extension.sourceInfo.scope, events: extension.handlers.keys(),
    })));
  } finally { await rm(cwd, { recursive: true, force: true }); }
}

test("bashGuardOf on a real pi loader: fixture agent dirs only (never the user's ~/.pi or the real dcg)", async () => {
  assert.equal(await guardOfAgentDir(resolve("test/fixtures/guard-agent-dir")), "dcg");
  assert.equal(await guardOfAgentDir(resolve("test/fixtures/other-guard-agent-dir")), "other");
  assert.equal(await guardOfAgentDir(resolve("test/fixtures/global-agent-dir")), "none");
});

test("coding tool names: the shared fixture, pi's own tool factories and pi's default active set", async () => {
  const shared = readJson(join(fixtures, "coding-tools.json")) as { tools: string[]; defaultActive: string[] };
  assert.deepEqual(shared.tools, [...PI_CODING_TOOLS]);
  assert.deepEqual(shared.defaultActive, [...PI_DEFAULT_ACTIVE_TOOLS]);
  const cwd = await mkdtemp(join(tmpdir(), "pi-os-tools-"));
  try {
    const names = [createReadTool, createBashTool, createEditTool, createWriteTool, createGrepTool, createFindTool, createLsTool, createPowerShellTool]
      .map((create) => create(cwd).name);
    assert.deepEqual(names, [...PI_CODING_TOOLS], "pi renamed or added a coding tool: update piSession.ts, the fixture and the Swift labels");
    const dir = resolve("test/fixtures/global-agent-dir");
    const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: join(dir, "models.json") });
    const { session } = await createAgentSession({ cwd, agentDir: dir, modelRuntime: runtime,
      sessionManager: SessionManager.inMemory(cwd), settingsManager: SettingsManager.inMemory() });
    try {
      const active = session.getActiveToolNames();
      for (const tool of PI_DEFAULT_ACTIVE_TOOLS) assert.ok(active.includes(tool), tool);
      for (const tool of active.filter(isPiCodingTool)) assert.ok((PI_DEFAULT_ACTIVE_TOOLS as readonly string[]).includes(tool), tool);
    } finally { session.dispose(); }
  } finally { await rm(cwd, { recursive: true, force: true }); }
  assert.equal(isPiCodingTool("bash"), true);
  assert.equal(isPiCodingTool("desktop_act"), false);
  assert.equal(isPiCodingTool(undefined), false);
});

test("record fixture: activity and agent steps carry pi's coding tool names verbatim, never arguments", () => {
  const record = readJson(join(fixtures, "record-coding-activity.json"));
  assert.equal(isPiCodingTool(record.activity), true);
  const agentSteps = (record.steps as { tool: string }[]).map((step) => step.tool).filter((tool) => tool.startsWith(AGENT_STEP_PREFIX));
  assert.deepEqual(agentSteps, ["read", "grep", "edit", "bash"].map(agentStepName));
  for (const tool of agentSteps) assert.equal(isPiCodingTool(tool.slice(AGENT_STEP_PREFIX.length)), true, tool);
  for (const step of record.steps as Record<string, unknown>[]) assert.deepEqual(Object.keys(step).sort(), ["at", "ok", "tool"]);
});
