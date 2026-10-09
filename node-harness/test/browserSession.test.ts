import assert from "node:assert/strict";
import { test } from "node:test";
import { BrowserSession, validateAction, webURL } from "../src/browser/session.js";
import type { BrowserConnection, Cdp } from "../src/browser/cdp.js";
import type { HostClient } from "../src/hostClient.js";

const initial: BrowserConnection = { processId: 123, port: 9222, initialURL: "https://fixture.test/", url: "https://fixture.test/", bounds: { x: 10, y: 20, width: 800, height: 600 } };
class FakeCDP implements Cdp {
  calls: { method: string; params: any; sessionId?: string }[] = [];
  events: ((m: string, p: any, s?: string) => void)[] = [];
  targets = [{ type: "page", url: initial.url, targetId: "chosen" }, { type: "page", url: "https://private.test/", targetId: "unrelated" }];
  url = initial.url; loader = "doc1"; refs = ""; value = ""; mutated = 0; closed = false;
  deny?: string; failMutation = false; afterInspect?: () => void; afterAct?: () => void; settles: any[] = []; failCompact = false;
  async call(method: string, params: any = {}, sessionId?: string): Promise<any> {
    this.calls.push({ method, params, sessionId });
    if (method === "Target.getTargets") return { targetInfos: this.targets };
    if (method === "Browser.getWindowForTarget") return { bounds: { left: 10, top: 20, width: 800, height: 600, windowState: "normal" } };
    if (method === "Target.attachToTarget") { assert.equal(params.targetId, "chosen"); return { sessionId: "only-session" }; }
    if (method === "Page.getFrameTree") return { frameTree: { frame: { id: "frame", loaderId: this.loader, url: this.url } } };
    if (method === "Page.createIsolatedWorld") { assert.equal(params.grantUniveralAccess, undefined); return { executionContextId: 42 }; }
    if (method === "Runtime.evaluate") return { result: { objectId: "helper" } };
    if (method === "Runtime.callFunctionOn") {
      const [name, args] = params.arguments.map((a: any) => a.value);
      if (name === "snapshot") { this.refs = args[1]; return { result: { value: { text: `[${this.refs}1] button "Like fixture"\n[${this.refs}2] textbox "Test note"`, truncated: false } } }; }
      if (name === "snapshotCompact" && this.failCompact) return { exceptionDetails: { text: "fixture page error" } };
      if (name === "snapshotCompact") { this.refs = args[0]; return { result: { value: { text: `[${this.refs}page] page (scroll only)\n[${this.refs}1] button "Like fixture" pressed=true\nVisible text: Liked`, truncated: false } } }; }
      if (name === "settle") { this.settles.push({ args, awaitPromise: params.awaitPromise }); return { result: { value: true } }; }
      if (name === "inspect") {
        const error = this.deny && !(this.deny === 'credential_input_blocked' && args[3] === true);
        this.afterInspect?.();
        return { result: { value: error ? { error: this.deny } : { ok: true } } };
      }
      if (name === "act") {
        if (this.deny === 'credential_input_blocked' && args[4] !== true) return { result: { value: { error: this.deny } } };
        this.mutated++; if (this.failMutation) throw new Error("simulated uncertain delivery"); this.afterAct?.(); return { result: { value: { ok: true } } };
      }
      if (name === "verifyFill") return { result: { value: args[1] === this.value } };
    }
    if (method === "Input.insertText") this.value = params.text;
    return {};
  }
  onEvent(f: (m: string, p: any, s?: string) => void) { this.events.push(f); }
  emit(m: string, p: any = {}, s = "only-session") { for (const f of this.events) f(m, p, s); }
  close() { this.closed = true; this.emit("connection.closed"); }
}
function fixture(signal?: AbortSignal) {
  const cdp = new FakeCDP();
  const native = { ...initial, bounds: { ...initial.bounds } };
  const hostCalls: { name: string; args: any }[] = [];
  let nativeError = ""; let connections = 0;
  const host = { invokeTool: async (name: string, args: any) => {
    hostCalls.push({ name, args }); assert.equal(args.contextId, "ctx-fixed");
    if (nativeError) return { ok: false, error: { code: nativeError, message: "native refusal" } };
    return { ok: true, result: name === "browser.invalidate" ? true : native };
  } } as unknown as HostClient;
  const session = new BrowserSession(host, "ctx-fixed", signal, { verifyEndpoint: async () => {}, connect: async () => { connections++; return cdp; } });
  return { session, cdp, native, hostCalls, refuse: (code: string) => { nativeError = code; }, connects: () => connections };
}

test("browser connects lazily and attaches only the unique pinned page; bounded tools never return endpoint IDs", async () => {
  const f = fixture(); assert.equal(f.connects(), 0);
  const snap = await f.session.snapshot();
  assert.match(snap.text, /Like fixture/); assert(!JSON.stringify(snap).includes("only-session"));
  const attaches = f.cdp.calls.filter(x => x.method === "Target.attachToTarget");
  assert.deepEqual(attaches.map(x => x.params.targetId), ["chosen"]);
  assert(!f.cdp.calls.some(x => x.method.startsWith("Network.") || x.method.includes("Cookie")));
  await f.session.dispose();
  assert(f.cdp.closed); assert(f.cdp.calls.some(x => x.method === "Target.detachFromTarget"));
  assert(!f.cdp.calls.some(x => x.method === "Browser.close" || x.method === "Target.closeTarget"));
});

test("duplicate URLs in the pinned window are ambiguous before any page attach", async () => {
  const f = fixture(); f.cdp.targets.push({ ...f.cdp.targets[0]!, targetId: "duplicate" });
  await assert.rejects(f.session.snapshot(), /browser_target_ambiguous/);
  assert.equal(f.cdp.calls.filter(x => x.method === "Target.attachToTarget").length, 0);
  await assert.rejects(f.session.snapshot()); assert.equal(f.connects(), 1); await f.session.dispose();
});

test("pin changes during typing/permission waits fail before attach or action", async () => {
  const f = fixture(); f.native.url = "https://fixture.test/changed";
  await assert.rejects(f.session.snapshot(), /browser_target_changed/);
  assert.equal(f.connects(), 0); await f.session.dispose();
  const g = fixture(); await g.session.snapshot(); g.refuse("browser_target_changed");
  await assert.rejects(g.session.act({ action: "click", ref: g.cdp.refs + "1" }), /browser_target_changed/);
  assert.equal(g.cdp.mutated, 0); await g.session.dispose();
});

test("actions bind private session/context, verify fill, and consume refs even on success", async () => {
  const f = fixture(); await f.session.snapshot(); const ref = f.cdp.refs + "2";
  const result = await f.session.act({ action: "fill", ref, text: "Grüß dich 👋" });
  assert.match(result.verification, /Text value verified/);
  assert.equal(f.cdp.value, "Grüß dich 👋");
  assert.equal(f.hostCalls.find(x => x.args.mutation)?.args.characters, "Grüß dich 👋".length);
  assert(f.cdp.calls.filter(x => x.method === "Input.insertText").every(x => x.sessionId === "only-session"));
  await assert.rejects(f.session.act({ action: "click", ref }), /browser_stale/);
  assert.equal(f.cdp.mutated, 1); await f.session.dispose();
});

test("new user turn requires fresh refs without reconnecting or clearing uncertain outcomes", async () => {
  const f = fixture(); await f.session.snapshot(); const old = f.cdp.refs + "1";
  f.session.invalidateReferences();
  await assert.rejects(f.session.act({ action: "click", ref: old }), /browser_stale/);
  await f.session.snapshot(); f.cdp.failMutation = true;
  await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }));
  f.session.invalidateReferences(); f.cdp.failMutation = false; await f.session.snapshot();
  await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }), /input_failed/);
  assert.equal(f.connects(), 1); await f.session.dispose();
});

test("browser multiline fill normalizes CRLF/CR and verifies canonical newlines without key events", async () => {
  const f = fixture(); await f.session.snapshot();
  await f.session.act({ action: "fill", ref: f.cdp.refs + "2", text: "First ü😀\r\n\r\n日本語\rLast\n" });
  assert.equal(f.cdp.value, "First ü😀\n\n日本語\nLast\n");
  assert(!f.cdp.calls.some(c => c.method === "Input.dispatchKeyEvent")); await f.session.dispose();
});

test("navigation invalidates refs; re-snapshot stays on the same target and issues different refs", async () => {
  const f = fixture(); await f.session.snapshot(); const old = f.cdp.refs + "1";
  f.cdp.url = f.native.url = "https://fixture.test/next"; f.cdp.loader = "doc2";
  f.cdp.emit("Page.frameNavigated");
  await assert.rejects(f.session.act({ action: "click", ref: old }), /browser_stale/);
  await f.session.snapshot(); assert.notEqual(f.cdp.refs + "1", old);
  await assert.rejects(f.session.act({ action: "click", ref: old }), /browser_stale/);
  await f.session.act({ action: "click", ref: f.cdp.refs + "1" });
  assert.equal(f.cdp.calls.filter(x => x.method === "Target.attachToTarget").length, 1); await f.session.dispose();
});

test("deletion and secure-field refusals never mutate or fall back", async () => {
  for (const code of ["file_deletion_blocked", "secure_input"]) {
    const f = fixture(); await f.session.snapshot(); f.cdp.deny = code;
    await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }), new RegExp(code));
    assert.equal(f.cdp.mutated, 0); assert(!f.hostCalls.some(x => x.args.mutation));
    f.cdp.deny = undefined; await f.session.snapshot();
    await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }), /input_failed/);
    await f.session.dispose();
  }
});

test("only authenticated host metadata can permit credential input; a refusal does not disable ordinary fields", async () => {
  const f = fixture(); await f.session.snapshot(); f.cdp.deny = 'credential_input_blocked';
  await assert.rejects(f.session.act({ action: 'fill', ref: f.cdp.refs + '2', text: 'fixture-secret', allowCredentialFields: true } as any), /credential_input_blocked/);
  assert.equal(f.cdp.mutated, 0);
  f.cdp.deny = undefined;
  await f.session.act({ action: 'fill', ref: f.cdp.refs + '2', text: 'ordinary text' });
  f.native.allowCredentialFields = true; f.cdp.deny = 'credential_input_blocked'; await f.session.snapshot();
  await f.session.act({ action: 'fill', ref: f.cdp.refs + '2', text: 'fixture credential' });
  assert.equal(f.cdp.value, 'fixture credential');
  f.native.allowCredentialFields = false; await f.session.snapshot();
  await assert.rejects(f.session.act({ action: 'fill', ref: f.cdp.refs + '2', text: 'must not appear' }), /credential_input_blocked/);
  assert.equal(f.cdp.value, 'fixture credential'); await f.session.dispose();
});

test("credential permission is rechecked after native mutation authorization", async () => {
  const f = fixture(); f.native.allowCredentialFields = true; await f.session.snapshot(); f.cdp.deny = 'credential_input_blocked';
  f.cdp.afterInspect = () => { f.native.allowCredentialFields = false; };
  await assert.rejects(f.session.act({ action: 'fill', ref: f.cdp.refs + '2', text: 'must not appear' }), /credential_input_blocked/);
  assert.equal(f.cdp.mutated, 0); assert(!f.cdp.calls.some(c => c.method === 'Input.insertText'));
  await f.session.dispose();
});

test("uncertain mutations poison the native context and are never retried", async () => {
  const f = fixture(); await f.session.snapshot(); f.cdp.failMutation = true;
  await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }), /uncertain/);
  assert(f.hostCalls.some(x => x.name === "browser.invalidate"));
  f.cdp.failMutation = false; await f.session.snapshot();
  await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }), /input_failed/);
  assert.equal(f.cdp.mutated, 1); await f.session.dispose();
});

test("dialogs, revoked control, and cancellation fail closed; no automatic dialog acceptance", async () => {
  const f = fixture(); await f.session.snapshot(); f.cdp.emit("Page.javascriptDialogOpening");
  await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }), /browser_dialog/);
  assert(!f.cdp.calls.some(x => x.method === "Page.handleJavaScriptDialog")); await f.session.dispose();
  const g = fixture(); await g.session.snapshot(); g.refuse("control_disabled");
  await assert.rejects(g.session.act({ action: "click", ref: g.cdp.refs + "1" }), /control_disabled/); assert.equal(g.cdp.mutated, 0); await g.session.dispose();
  const abort = new AbortController(), h = fixture(abort.signal); await h.session.snapshot(); abort.abort();
  await assert.rejects(h.session.act({ action: "click", ref: h.cdp.refs + "1" })); assert(h.cdp.closed); assert.equal(h.cdp.mutated, 0); await h.session.dispose();
});

test("sibling actions serialize and cannot consume the same snapshot twice", async () => {
  const f = fixture(); await f.session.snapshot();
  const results = await Promise.allSettled([f.session.act({ action: "click", ref: f.cdp.refs + "1" }), f.session.act({ action: "click", ref: f.cdp.refs + "1" })]);
  assert.equal(results.filter(x => x.status === "fulfilled").length, 1); assert.equal(f.cdp.mutated, 1); await f.session.dispose();
});

test("browser arguments reject scripts, arbitrary shortcuts, unsafe URL schemes, and excessive input", () => {
  for (const raw of ["file:///tmp/x", "javascript:alert(1)", "brave://settings", "https://user:secret@example.com/"]) assert.throws(() => webURL(raw));
  assert.equal(webURL("https://example.com"), "https://example.com/");
  assert.throws(() => validateAction({ action: "press", key: "Meta+A", ref: "r1" }));
  assert.throws(() => validateAction({ action: "fill", ref: "r1", text: "a".repeat(20001) }));
  assert.throws(() => validateAction({ action: "scroll", ref: "r1", deltaY: NaN }));
});

test("act with observe settles once, returns a compact snapshot and makes only its refs valid", async () => {
  const f = fixture(); await f.session.snapshot(); const old = f.cdp.refs + "1";
  const result = await f.session.act({ action: "click", ref: old }, undefined, { observe: true });
  assert.equal(f.cdp.mutated, 1);
  assert.deepEqual(f.cdp.settles, [{ args: [50, 150], awaitPromise: true }]);
  // Only the settle wait awaits a page promise; every other helper call stays synchronous.
  assert(f.cdp.calls.filter(c => c.method === "Runtime.callFunctionOn" && c.params.awaitPromise).length === 1);
  assert.match(result.verification, /^Action dispatched once\. Verify the requested postcondition in the compact snapshot/);
  assert.match(result.snapshot!.text, /pressed=true/);
  assert.equal(result.snapshotError, undefined);
  const fresh = f.cdp.refs + "1";
  assert.notEqual(fresh, old);
  await assert.rejects(f.session.act({ action: "click", ref: old }), /browser_stale/);
  const fill = await f.session.act({ action: "scroll", ref: f.cdp.refs + "page", deltaY: 400 }, undefined, { observe: true });
  assert.deepEqual(f.cdp.settles.at(-1), { args: [50, 100], awaitPromise: true });
  assert.match(fill.snapshot!.text, /Visible text/);
  await f.session.act({ action: "click", ref: f.cdp.refs + "1" });
  assert.equal(f.cdp.mutated, 3); await f.session.dispose();
});

test("a failed post-action observation is reported, never turned into a retryable action error", async () => {
  const f = fixture(); await f.session.snapshot();
  f.cdp.failCompact = true; const consumed = f.cdp.refs + "1";
  const result = await f.session.act({ action: "click", ref: consumed }, undefined, { observe: true });
  assert.equal(result.performed, true);
  assert.equal(result.snapshot, undefined);
  assert.equal(result.snapshotError, "browser_script_failed");
  assert.match(result.verification, /Take browser_snapshot/);
  assert.equal(f.cdp.mutated, 1);
  // Nothing from the failed observation became actionable; the old refs stay consumed.
  await assert.rejects(f.session.act({ action: "click", ref: consumed }), /browser_stale/);
  await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }), /browser_stale/);
  assert.equal(f.cdp.mutated, 1);
  f.cdp.failCompact = false; await f.session.snapshot();
  await f.session.act({ action: "click", ref: f.cdp.refs + "1" });
  assert.equal(f.cdp.mutated, 2); await f.session.dispose();
});

test("a navigating click skips the page settle and observes the new document through a fresh helper", async () => {
  const f = fixture(); await f.session.snapshot();
  f.cdp.afterAct = () => { f.cdp.url = f.native.url = "https://fixture.test/next"; f.cdp.loader = "doc2"; f.cdp.emit("Page.frameNavigated"); };
  const result = await f.session.act({ action: "click", ref: f.cdp.refs + "1" }, undefined, { observe: true });
  assert.match(result.snapshot!.text, /Like fixture/);
  assert.equal(f.cdp.settles.length, 0);
  assert.equal(f.cdp.calls.filter(c => c.method === "Page.createIsolatedWorld").length, 2);
  assert.equal(f.cdp.calls.filter(c => c.method === "Target.attachToTarget").length, 1);
  await f.session.act({ action: "click", ref: f.cdp.refs + "1" });
  assert.equal(f.cdp.mutated, 2); await f.session.dispose();
});

test("an uncertain observed action still throws and never observes or retries", async () => {
  const f = fixture(); await f.session.snapshot(); f.cdp.failMutation = true;
  const snapshots = () => f.cdp.calls.filter(c => c.method === "Runtime.callFunctionOn" && c.params.arguments[0].value.startsWith("snapshot")).length;
  const before = snapshots();
  await assert.rejects(f.session.act({ action: "click", ref: f.cdp.refs + "1" }, undefined, { observe: true }), /uncertain/);
  assert.equal(snapshots(), before); assert.equal(f.cdp.settles.length, 0);
  assert(f.hostCalls.some(x => x.name === "browser.invalidate"));
  await f.session.dispose();
});
