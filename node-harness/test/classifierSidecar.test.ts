import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, spawn, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { createInterface } from "node:readline";
import { type TestContext, test } from "node:test";
import { createClassifier } from "../src/classifier/factory.js";
import { LayaClassifier, LayaSidecar, LayaSidecarError, type LayaSidecarOptions, sidecarEnvironment } from "../src/classifier/laya.js";

// Fake engine only: no torch, no model, no network. Skips cleanly without python3 (e.g. Windows CI).
const SCRIPT = join(import.meta.dirname, "..", "..", "sidecars", "laya", "laya_intent_sidecar.py");

function findPython(): string | undefined {
  for (const candidate of [process.env.PI_OS_TEST_PYTHON, "python3", "python"]) {
    if (!candidate) continue;
    const probe = spawnSync(candidate, ["-I", "-B", "-c", "import sys; assert sys.version_info >= (3, 8); print(sys.executable)"], {
      encoding: "utf8", timeout: 10_000,
    });
    const path = probe.stdout?.trim();
    if (probe.status === 0 && path && isAbsolute(path)) return path;
  }
  return undefined;
}

const PYTHON = findPython();
const skip = PYTHON ? false : "python3 >= 3.8 is not available";
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitUntil(condition: () => boolean, ms = 5_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await sleep(10);
  }
}

function makeSidecar(t: TestContext, options: Partial<LayaSidecarOptions> = {}, args: string[] = []) {
  const logs: string[] = [];
  const sidecar = new LayaSidecar({
    python: PYTHON!, script: SCRIPT, args: ["--fake", ...args], log: (line) => logs.push(line), ...options,
  });
  t.after(() => sidecar.stop());
  return { sidecar, logs };
}

function rawSidecar(t: TestContext, args: string[] = []) {
  const child: ChildProcessWithoutNullStreams = spawn(PYTHON!, ["-I", "-B", SCRIPT, "--fake", ...args], { env: sidecarEnvironment() });
  const lines: Record<string, unknown>[] = [];
  const nonJson: string[] = [];
  let stderr = "";
  createInterface({ input: child.stdout }).on("line", (line) => {
    try { lines.push(JSON.parse(line) as Record<string, unknown>); } catch { nonJson.push(line); }
  });
  child.stderr.setEncoding("utf8").on("data", (data: string) => { stderr += data; });
  const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.stdin.end();
      await exited;
    }
  });
  const send = (message: Record<string, unknown> | string) =>
    child.stdin.write(`${typeof message === "string" ? message : JSON.stringify(message)}\n`);
  const reply = async (id: string | null, ms = 5_000): Promise<Record<string, unknown>> => {
    await waitUntil(() => lines.some((line) => line.id === id), ms);
    const index = lines.findIndex((line) => line.id === id);
    return lines.splice(index, 1)[0]!;
  };
  return { child, lines, nonJson, stderr: () => stderr, send, reply, exited };
}

test("sidecar protocol: ready, classify, predict, refusals, cancel, expiry, health, shutdown", { skip }, async (t) => {
  const raw = rawSidecar(t);
  await waitUntil(() => raw.lines.some((line) => line.type === "ready"));
  const ready = raw.lines.shift()!;
  assert.equal(ready.proto, 1);
  assert.deepEqual([(ready.model as Record<string, unknown>).fake, (ready.model as Record<string, unknown>).questions], [true, "pi-os-intent-v1"]);

  raw.send({ id: "c1", op: "classify", text: "what time is it in Tokyo SENTINEL4711", deadline_ms: 1000 });
  const c1 = await raw.reply("c1");
  const result = c1.result as Record<string, Record<string, unknown>>;
  assert.equal(c1.ok, true);
  assert.equal(result.advisory as unknown, true);
  assert.equal(result.intent!.label, "time_date");
  assert.deepEqual(Object.keys(result.tier!.probs as object), ["none", "little", "moderate", "heavy"]);

  raw.send({
    id: "p1", op: "predict", state: { message: "this is urgent" }, questions: {
      kind: { type: "choice", instructions: "Which kind?", criteria: { bug: "a defect", urgent: "" } },
      level: { type: "score", instructions: "How much?", criteria: ["low", "mid", "high"] },
      visible: { type: "bool", instructions: "On screen?", criteria: { true: "yes", false: "no" } },
    },
  });
  const answers = ((await raw.reply("p1")).result as Record<string, Record<string, Record<string, unknown>>>).answers!;
  assert.deepEqual([answers.kind!.type, answers.kind!.choice, answers.level!.type, answers.visible!.type], ["choice", "urgent", "score", "bool"]);
  assert.equal(answers.visible!.probability, 0.9);

  const refusals: Array<[Record<string, unknown> | string, string | null, string]> = [
    [{ id: "r1", op: "classify", text: "x".repeat(501) }, "r1", "state_too_long"],
    [{ id: "r2", op: "classify", text: "__room__" }, "r2", "state_too_long"],
    [{ id: "r3", op: "classify", text: "   " }, "r3", "bad_request"],
    [{ id: "r4", op: "predict", state: { a: 1 }, questions: {} }, "r4", "bad_request"],
    [{ id: "r5", op: "predict", state: "text", questions: { q: { type: "bool", instructions: "x" } } }, "r5", "bad_request"],
    [{ id: "r6", op: "predict", state: {}, questions: { q: { type: "choice", instructions: "x", criteria: { only: "" } } } }, "r6", "bad_request"],
    [{ id: "r7", op: "predict", state: {}, questions: { q: { type: "freeform", instructions: "x" } } }, "r7", "bad_request"],
    [{ id: "r8", op: "predict", state: { big: "y".repeat(5000) }, questions: { q: { type: "bool", instructions: "x" } } }, "r8", "state_too_long"],
    [{ id: "r9", op: "rm" }, "r9", "bad_request"],
    ["not json", null, "bad_request"],
  ];
  for (const [message, id, code] of refusals) {
    raw.send(message);
    const response = await raw.reply(id);
    assert.equal(response.ok, false);
    assert.equal((response.error as Record<string, unknown>).code, code, JSON.stringify(message).slice(0, 80));
  }
  raw.send(`{"id":"big","op":"classify","text":"${"z".repeat(70_000)}"}`);
  assert.equal(((await raw.reply(null)).error as Record<string, unknown>).message, "line too long");

  // A cancel overtakes queued work; a request queued past its deadline is expired, not answered late.
  raw.send({ id: "s1", op: "classify", text: "__slow__ 300 open Spotify", deadline_ms: 5000 });
  raw.send({ id: "c9", op: "classify", text: "open Spotify" });
  raw.send({ id: "x1", op: "cancel", target: "c9" });
  raw.send({ id: "c10", op: "classify", text: "open Spotify", deadline_ms: 20 });
  assert.equal((await raw.reply("s1")).ok, true);
  assert.equal(((await raw.reply("c9")).error as Record<string, unknown>).code, "cancelled");
  assert.equal(((await raw.reply("c10")).error as Record<string, unknown>).code, "expired");

  raw.send({ id: "h1", op: "health" });
  assert.equal(((await raw.reply("h1")).health as Record<string, unknown>).pid, raw.child.pid);
  raw.send({ id: "q1", op: "shutdown" });
  assert.equal((await raw.reply("q1")).ok, true);
  assert.deepEqual(await raw.exited, { code: 0, signal: null });

  // stdout carries protocol lines only; library prints land on stderr; inputs never reach stderr.
  assert.deepEqual(raw.nonJson, []);
  assert.match(raw.stderr(), /simulated library print/u);
  assert.doesNotMatch(raw.stderr(), /SENTINEL4711|urgent/u);
});

test("socket kill-switch ends the sidecar with exit 97 before any connection", { skip }, () => {
  const run = spawnSync(PYTHON!, ["-I", "-B", SCRIPT, "--fake", "--selftest-network"], { encoding: "utf8", timeout: 10_000, env: sidecarEnvironment() });
  assert.equal(run.status, 97);
  assert.equal(run.stdout, "");
  assert.match(run.stderr, /network access attempted/u);

  // Listeners and connectionless sends are blocked too (loopback targets only, denied before any syscall);
  // AF_UNIX stays usable for local IPC.
  const guarded = (code: string) => spawnSync(PYTHON!, ["-I", "-B", "-c",
    `import sys; sys.path.insert(0, sys.argv[1]); import socket, laya_intent_sidecar as s; s.offline_guard(); ${code}`, dirname(SCRIPT)],
  { encoding: "utf8", timeout: 10_000, env: sidecarEnvironment() }).status;
  assert.equal(guarded("socket.socket(socket.AF_INET, socket.SOCK_STREAM).bind(('127.0.0.1', 0))"), 97);
  assert.equal(guarded("socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'x', ('127.0.0.1', 9))"), 97);
  assert.equal(guarded("socket.getaddrinfo('localhost', 80)"), 97);
  if (process.platform !== "win32") {
    assert.equal(guarded("a, b = socket.socketpair(); a.sendall(b'ok'); assert b.recv(2) == b'ok'"), 0);
  }
});

test("stdin EOF during a slow model load exits at once (parent gone)", { skip }, async (t) => {
  const raw = rawSidecar(t, ["--fake-load-ms", "20000"]);
  await sleep(300);
  const started = Date.now();
  raw.child.stdin.end();
  assert.deepEqual(await raw.exited, { code: 0, signal: null });
  assert.ok(Date.now() - started < 5_000);
  assert.equal(raw.lines.length, 0);
});

test("supervisor starts lazily, classifies through LayaClassifier and stops on stdin EOF", { skip }, async (t) => {
  const { sidecar, logs } = makeSidecar(t);
  assert.equal(sidecar.state, "stopped");
  assert.equal(sidecar.pid, undefined); // nothing spawned on construction
  const classifier = new LayaClassifier(sidecar, { deadlineMs: 2_000 });
  const signal = new AbortController().signal;
  assert.equal(await classifier.classify("what time is it in Tokyo", signal), null); // not ready yet: never waits for the load
  assert.ok(["starting", "ready"].includes(sidecar.state));
  assert.equal(await sidecar.warm(), true);
  assert.equal(sidecar.status().model?.fake, true);
  assert.equal(sidecar.status().model?.questions, "pi-os-intent-v1");

  const time = await classifier.classify("what time is it in Tokyo", signal);
  assert.deepEqual({ ...time, latencyMs: 0 }, {
    source: "laya", latencyMs: 0, intent: "answer", intentP: 0.91, tier: "instant", tierP: 0.9, needsScreen: 0.05,
  });
  const task = await classifier.classify("summarize this article for me", signal);
  assert.deepEqual([task?.intent, task?.tier, task?.needsScreen], ["other", "standard", 0.9]);

  const predicted = await sidecar.predict({
    state: { utterance: "is this a bug" },
    questions: { kind: { type: "choice", instructions: "Which?", criteria: { bug: "defect", question: "question" } } },
  });
  assert.equal(predicted.answers.kind?.type === "choice" ? predicted.answers.kind.choice : "", "bug");

  const pid = sidecar.pid;
  assert.equal((await sidecar.health())?.pid, pid);
  await sidecar.stop();
  assert.equal(sidecar.state, "stopped");
  assert.ok(logs.some((line) => line === `[laya] stopped pid=${pid} code=0 signal=null`), logs.join("\n"));
  assert.ok(!logs.some((line) => line.includes("killed pid")));
  assert.ok(logs.some((line) => line.startsWith("[laya:stderr] fake engine: simulated library print")));
  assert.ok(logs.includes("[laya:stderr] fake engine: simulated warning about <path>"), logs.join("\n")); // paths redacted
  assert.ok(!logs.some((line) => /Tokyo|summarize|is this a bug|non-JSON/u.test(line)), logs.join("\n"));
});

test("deadline, latest-wins and abort all resolve null without waiting for the sidecar", { skip }, async (t) => {
  const { sidecar } = makeSidecar(t);
  assert.equal(await sidecar.warm(), true);
  let started = performance.now();
  assert.equal(await sidecar.classify("__slow__ 900 open Spotify", { deadlineMs: 60 }), null);
  assert.ok(performance.now() - started < 700); // did not wait for the 900 ms answer
  assert.equal(sidecar.status().requestErrors.timeout, 1);
  await sleep(950);

  const older = sidecar.classify("__slow__ 300 open Spotify", { deadlineMs: 3_000 });
  const newer = sidecar.classify("what time is it", { deadlineMs: 3_000 });
  assert.equal(await older, null);
  assert.equal((await newer)?.intent.label, "time_date");
  assert.equal(sidecar.status().requestErrors.superseded, 1);

  const controller = new AbortController();
  started = performance.now();
  const aborted = sidecar.classify("__slow__ 900 what time", { deadlineMs: 3_000, signal: controller.signal });
  setTimeout(() => controller.abort(), 20);
  assert.equal(await aborted, null);
  assert.ok(performance.now() - started < 700);
  await sleep(950);

  const [a, b] = await Promise.all([
    sidecar.classify("open Spotify", { deadlineMs: 3_000, latestWins: false }),
    sidecar.classify("what time is it", { deadlineMs: 3_000, latestWins: false }),
  ]);
  assert.deepEqual([a?.intent.label, b?.intent.label], ["app_launch", "time_date"]);
  assert.equal(await sidecar.classify("x".repeat(501)), null);

  // A request line the sidecar would drop (> 64 KiB, id-less error) fails at once, not at its timeout.
  const criteria = Object.fromEntries(Array.from({ length: 20 }, (_, i) => [`o${i}`, "d".repeat(300)]));
  const questions = Object.fromEntries(Array.from({ length: 16 }, (_, q) => [`q${q}`, { type: "choice" as const, instructions: "i".repeat(500), criteria }]));
  started = performance.now();
  await assert.rejects(sidecar.predict({ state: {}, questions }, { timeoutMs: 20_000 }),
    (error: unknown) => error instanceof LayaSidecarError && error.code === "bad_request");
  assert.ok(performance.now() - started < 1_000);
  assert.equal(sidecar.state, "ready");
});

test("a ready line that arrives after stop() does not revive the sidecar", { skip }, async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "pi-os-laya-late-"));
  const script = join(dir, "late_ready.py");
  // Ignores stdin until it has announced readiness, like a load that finishes just as the harness stops it.
  writeFileSync(script, [
    "import json, sys, time",
    "time.sleep(0.4)",
    "print(json.dumps({'type': 'ready', 'proto': 1, 'model': {'questions': 'pi-os-intent-v1', 'fake': True}, 'load_ms': 1}), flush=True)",
    "sys.stdin.read()",
    "",
  ].join("\n"));
  const { sidecar } = makeSidecar(t, { script, stopGraceMs: 5_000 });
  const warm = sidecar.warm();
  await sleep(100);
  const stopped = sidecar.stop();
  assert.equal(await warm, false);
  assert.notEqual(sidecar.state, "ready");
  assert.equal(await sidecar.classify("open Spotify"), null);
  await stopped;
  assert.equal(sidecar.state, "stopped");
  assert.equal(sidecar.status().model, undefined);
  assert.deepEqual(sidecar.status().requestErrors, {});
});

test("crashes restart lazily with backoff, at most maxRestarts times, then stay failed until reset", { skip }, async (t) => {
  const { sidecar, logs } = makeSidecar(t, { maxRestarts: 2, restartBackoffMs: 300 });
  assert.equal(await sidecar.warm(), true);
  const first = sidecar.pid;
  assert.equal(await sidecar.classify("__crash__", { deadlineMs: 2_000 }), null);
  await waitUntil(() => sidecar.state === "backoff");
  assert.deepEqual([sidecar.status().failures, sidecar.status().lastError], [1, "crashed"]);
  assert.ok(logs.some((line) => line.includes("restart 1/2 allowed in 300 ms")));
  assert.equal(await sidecar.warm(), false); // still backing off
  await sleep(350);
  assert.equal(await sidecar.warm(), true);
  assert.notEqual(sidecar.pid, first);

  await sidecar.classify("__crash__", { deadlineMs: 2_000 });
  await waitUntil(() => sidecar.state === "backoff");
  await sleep(650); // 300 ms * 2
  assert.equal(await sidecar.warm(), true);
  await sidecar.classify("__crash__", { deadlineMs: 2_000 });
  await waitUntil(() => sidecar.state === "failed");
  assert.equal(sidecar.status().failures, 3);
  assert.equal(sidecar.available, false);
  assert.equal(await sidecar.warm(), false);
  assert.equal(await sidecar.classify("open Spotify"), null);
  assert.equal(sidecar.pid, undefined);

  sidecar.reset();
  assert.equal(sidecar.state, "stopped");
  assert.equal(await sidecar.warm(), true);
});

test("ready timeout, fatal load, missing interpreter and protocol mismatch fail closed", { skip }, async (t) => {
  const slow = makeSidecar(t, { readyTimeoutMs: 200, stopGraceMs: 1_000 }, ["--fake-load-ms", "20000"]);
  assert.equal(await slow.sidecar.warm(), false);
  await waitUntil(() => slow.sidecar.state === "backoff");
  assert.equal(slow.sidecar.status().lastError, "ready_timeout");
  assert.equal(slow.sidecar.pid, undefined);

  const fatal = makeSidecar(t, {}, ["--fake-fail-load"]);
  assert.equal(await fatal.sidecar.warm(), false);
  await waitUntil(() => fatal.sidecar.state === "failed");
  assert.equal(fatal.sidecar.status().lastError, "load_failed");
  assert.ok(fatal.logs.includes("[laya] load failed code=load_failed kind=LoadError"));

  const missing = makeSidecar(t, { python: join(tmpdir(), "pi-os-no-such-python", "python3") });
  assert.equal(await missing.sidecar.warm(), false);
  await waitUntil(() => missing.sidecar.state === "failed");
  assert.equal(missing.sidecar.status().lastError, "spawn_failed");

  // A network attempt (exit 97) disables Laya at once: no restart, no backoff.
  const blocked = makeSidecar(t, {}, ["--selftest-network"]);
  assert.equal(await blocked.sidecar.warm(), false);
  await waitUntil(() => blocked.sidecar.state === "failed");
  assert.deepEqual([blocked.sidecar.status().lastError, blocked.sidecar.status().failures], ["network_blocked", 1]);
  assert.equal(await blocked.sidecar.warm(), false);

  const dir = mkdtempSync(join(tmpdir(), "pi-os-laya-proto-"));
  const script = join(dir, "future_sidecar.py");
  writeFileSync(script, "import json, sys\nprint(json.dumps({'type': 'ready', 'proto': 2, 'model': {'questions': 'x'}}), flush=True)\nsys.stdin.read()\n");
  const future = makeSidecar(t, { script });
  assert.equal(await future.sidecar.warm(), false);
  await waitUntil(() => future.sidecar.state === "failed");
  assert.equal(future.sidecar.status().lastError, "protocol_mismatch");
});

test("idle shutdown stops the child; a hung child is killed by its own PID after the grace period", { skip }, async (t) => {
  const idle = makeSidecar(t, { idleShutdownMs: 150 });
  assert.equal(await idle.sidecar.warm(), true);
  assert.ok(await idle.sidecar.classify("open Spotify", { deadlineMs: 2_000 }));
  await waitUntil(() => idle.sidecar.state === "stopped", 3_000);
  assert.ok(idle.logs.some((line) => line.startsWith("[laya] idle for")));
  assert.equal(await idle.sidecar.warm(), true); // lazily restarted on demand
  await idle.sidecar.stop();

  const hung = makeSidecar(t, { stopGraceMs: 200 }, ["--fake-ignore-eof"]);
  assert.equal(await hung.sidecar.warm(), true);
  const pid = hung.sidecar.pid!;
  await hung.sidecar.stop();
  assert.equal(hung.sidecar.state, "stopped");
  assert.ok(hung.logs.includes(`[laya] killed pid=${pid}`), hung.logs.join("\n"));
  assert.throws(() => process.kill(pid, 0)); // gone
});

test("factory kind laya with the fake engine: lazy, advisory hints, dispose stops the child", { skip }, async (t) => {
  const logs: string[] = [];
  const managed = createClassifier({ kind: "laya" }, { fakeEngine: { python: PYTHON! }, log: (line) => logs.push(line) });
  t.after(() => managed.dispose());
  assert.equal(managed.kind, "laya");
  assert.equal(managed.status().state, "stopped");
  assert.equal(managed.sidecar?.pid, undefined);
  managed.warm();
  await waitUntil(() => managed.status().state === "ready");
  const hints = await managed.classify("open Spotify", new AbortController().signal);
  assert.deepEqual([hints?.source, hints?.intent, hints?.tier], ["laya", "open_launch", "instant"]);
  await managed.dispose();
  assert.equal(managed.status().state, "stopped");
});
