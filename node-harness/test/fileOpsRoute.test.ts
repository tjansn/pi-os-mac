import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { AgentModelSettings } from "../src/agent/modelSettings.js";
import { AgentResourceSettings } from "../src/agent/resourceSettings.js";
import { loadConfig } from "../src/config.js";
import { parseFileOpRunResponse } from "../src/contracts/actions.js";
import type { VisibleItemsResult } from "../src/contracts/launcher.js";
import type { BashGuard } from "../src/contracts/piSession.js";
import type { HostClient } from "../src/hostClient.js";
import { FileOpStore } from "../src/instant/fileOps.js";
import { VisibleItemsCache } from "../src/instant/visible.js";
import { HarnessServer } from "../src/server.js";
import { captureLogs, fakeHost } from "./integrationFixtures.js";

/*
 * POST /fileops/run and the server's file-command gate (DESIGN6 §5, BUILD6): /instant answers a file command only in a
 * full pi session (macOS, trustedGlobal) whose bash guard is dcg and whose dcg resolves; the host runs the staged op
 * once through the token-authed route, which asks dcg (a fake one written into the test's temp dir) and runs argv on a
 * folder inside the temp dir. A bad body is a 400 that never echoes it; logs are content-free.
 */

const SKIP = process.platform === "win32" && "file ops run POSIX binaries and a /bin/sh fake dcg: macOS and Linux only";
const TOKEN = "route-token";

interface Scenario {
  platform?: NodeJS.Platform;
  mode?: "trustedGlobal" | "isolated";
  guard?: BashGuard;
  dcg?: "allow" | "deny" | "none";
}

interface Running {
  root: string;
  folder: string;
  settings: AgentResourceSettings;
  store: FileOpStore;
  post: (path: string, body: unknown, headers?: Record<string, string>) => Promise<Response>;
  instant: (text: string, extra?: Record<string, unknown>) => Promise<any>;
}

async function scenario(options: Scenario, run: (s: Running) => Promise<void>): Promise<void> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-os-fileops-route-")));
  const home = join(root, "home");
  const desktop = join(home, "Desktop");
  const folder = join(desktop, "test");
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, "a.txt"), "fixture");
  const dcgPath = join(root, "fake-dcg");
  const answer = options.dcg === "deny"
    ? `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"Recursive deletion was not approved."}}`
    : `{"dcg_verdict":"allow"}`;
  writeFileSync(dcgPath, `#!/bin/sh\ncat > /dev/null\nprintf '%s' '${answer}'\n`, { mode: 0o755 });
  const visible: VisibleItemsResult = {
    sources: [{ kind: "desktop", via: "ax", complete: true, path: desktop }],
    items: [{ token: "tok_routefixture01", name: "test", path: folder, contentType: "public.folder", isDirectory: true, isPackage: false, source: "desktop" }],
    truncated: false, elapsedMs: 1,
  };
  const settings = new AgentResourceSettings(join(root, "resources.json"));
  if ((options.mode ?? "trustedGlobal") === "trustedGlobal") settings.set("trustedGlobal", true);
  const store = new FileOpStore();
  const server = new HarnessServer({ ...loadConfig({}), port: 0, hostToken: TOKEN, agentEnabled: false }, {
    hostClient: fakeHost({ apps: { version: "1", apps: [] } }) as unknown as HostClient, supportDir: root, platform: options.platform ?? "darwin",
    resourceSettings: settings, modelSettings: new AgentModelSettings(join(root, "settings.json"), () => {}), onInvocation: async () => {},
    // The agent stack never loads here: the guard comes from the seam.
    loadAgentModules: () => new Promise(() => {}),
    instant: { visibleItems: new VisibleItemsCache(async () => structuredClone(visible)), homeDir: home },
    fileCommands: {
      store, dcg: () => (options.dcg === "none" ? null : dcgPath), bashGuard: async () => options.guard ?? "dcg", guard: { home, temp: [root] },
    },
  });
  const base = `http://127.0.0.1:${await server.listen()}`;
  const post = (path: string, body: unknown, headers: Record<string, string> = {}) => fetch(base + path, {
    method: "POST", headers: { "X-Harness-Token": TOKEN, "Content-Type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body),
  });
  let seq = 0;
  const instant = async (text: string, extra: Record<string, unknown> = {}) => {
    const response = await post("/instant", { text, phase: "final", seq: ++seq, locale: "de-DE", contextId: "ctx-route", takeId: `take-${seq}`, accept: ["confirm"], ...extra });
    assert.equal(response.status, 200);
    return response.json();
  };
  try {
    await run({ root, folder, settings, store, post, instant });
  } finally {
    await server.close();
    rmSync(root, { recursive: true, force: true });
  }
}

/** The first file command reads the guard in the background; the next one finds it known. */
async function primeGuard(s: Running): Promise<void> {
  await s.instant("lösche test", { phase: "typing" });
  await new Promise((resolve) => setTimeout(resolve, 20));
}

test("full session with dcg: /instant stages \"lösche test\", POST /fileops/run deletes it once after dcg allowed, the answer is one line", { skip: SKIP }, async () => {
  await scenario({}, async (s) => {
    // Until the guard is known the lane is off: today's full-session hand-off to pi.
    const before = await s.instant("lösche test");
    assert.deepEqual([before.decision, before.reason], ["fallthrough", "no_match"]);
    assert.equal(s.store.size, 0);
    await primeGuard(s);

    const act = await s.instant("lösche test");
    assert.deepEqual([act.decision, act.intent, act.title, act.confirm, act.action.type], ["act", "file_op", "Löschen: test", false, "fileOp"]);
    assert.ok(!JSON.stringify(act).includes(s.root), "no path on the wire");
    const { result, lines } = await captureLogs(async () => {
      const response = await s.post("/fileops/run", { opId: act.action.opId });
      assert.equal(response.status, 200);
      return response.json();
    });
    assert.deepEqual(result, { ok: true, outcome: "done", line: "„test“ gelöscht." });
    assert.deepEqual(parseFileOpRunResponse(result), result);
    assert.equal(existsSync(s.folder), false);
    const logged = lines.filter((line) => line.includes("stage=fileops.run"));
    assert.equal(logged.length, 1);
    assert.match(logged[0]!, /op=delete outcome=done verdict=allow/);
    for (const line of lines) for (const content of [s.root, "test", "gelöscht", "rm -r"]) assert.ok(!line.includes(content), `${content} in ${line}`);

    // Single use.
    const again = await (await s.post("/fileops/run", { opId: act.action.opId })).json();
    assert.deepEqual(again, { ok: true, outcome: "expired", line: "That expired — please say it again." });
  });
});

test("dcg denies: the folder stays and the line carries dcg's reason; switching the full session off refuses a staged op", { skip: SKIP }, async () => {
  await scenario({ dcg: "deny" }, async (s) => {
    await primeGuard(s);
    const act = await s.instant("lösche test");
    const denied = await (await s.post("/fileops/run", { opId: act.action.opId })).json();
    assert.deepEqual(denied, { ok: true, outcome: "denied", line: "dcg hat das Löschen abgelehnt: Recursive deletion was not approved." });
    assert.ok(existsSync(s.folder));
    // Staged in a full session, run after it was switched off: nothing runs.
    const staged = await s.instant("lösche test");
    s.settings.set("isolated", false);
    const off = await (await s.post("/fileops/run", { opId: staged.action.opId })).json() as { ok: boolean; outcome: string };
    assert.deepEqual([off.ok, off.outcome], [true, "failed"]);
    assert.ok(existsSync(s.folder));
    // And /instant is today's isolated lane again: a refusal.
    assert.equal((await s.instant("lösche test")).decision, "refuse");
  });
});

test("the lane stays off without dcg as the guard, without a resolvable dcg, in isolated mode and on Windows: today's decisions", { skip: SKIP }, async () => {
  for (const [label, options, expected] of [
    ["guard other", { guard: "other" }, "fallthrough"],
    ["guard none", { guard: "none" }, "fallthrough"],
    ["no dcg", { dcg: "none" }, "fallthrough"],
    ["isolated", { mode: "isolated" }, "refuse"],
    ["Windows", { platform: "win32" }, "refuse"],
  ] as const) {
    await scenario(options, async (s) => {
      await primeGuard(s);
      const response = await s.instant("lösche test");
      assert.equal(response.decision, expected, label);
      assert.equal(s.store.size, 0, label);
      assert.ok(existsSync(s.folder), label);
    });
  }
});

test("POST /fileops/run: token, origin and media type as every route; a bad body is a 400 {ok:false} that never echoes it; unknown ids expire", { skip: SKIP }, async () => {
  await scenario({}, async (s) => {
    assert.equal((await s.post("/fileops/run", { opId: "op_7Hq2Lr9xVb4Nc8Ws1Ke5Ty" }, { "X-Harness-Token": "wrong" })).status, 401);
    assert.equal((await s.post("/fileops/run", { opId: "op_7Hq2Lr9xVb4Nc8Ws1Ke5Ty" }, { Origin: "https://evil.example" })).status, 403);
    assert.equal((await s.post("/fileops/run", { opId: "op_7Hq2Lr9xVb4Nc8Ws1Ke5Ty" }, { "Content-Type": "text/plain" })).status, 415);
    assert.equal((await s.post("/fileops/run", { opId: "x".repeat(5_000) })).status, 413);
    for (const body of [{}, { opId: "short-secret" }, { token: "tok_routefixture01" }, "{", "[]", "null"]) {
      const response = await s.post("/fileops/run", body);
      assert.equal(response.status, 400, JSON.stringify(body));
      const answer = await response.json() as { ok: boolean; error: string };
      assert.deepEqual([answer.ok, typeof answer.error], [false, "string"], JSON.stringify(body));
      for (const value of ["short-secret", "tok_route"]) assert.ok(!answer.error.includes(value), answer.error);
    }
    const unknown = await (await s.post("/fileops/run", { opId: "op_7Hq2Lr9xVb4Nc8Ws1Ke5Ty" })).json();
    assert.deepEqual(unknown, { ok: true, outcome: "expired", line: "That expired — please say it again." });
    assert.ok(existsSync(s.folder));
  });
});
