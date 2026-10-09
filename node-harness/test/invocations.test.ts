import assert from "node:assert/strict";
import { test } from "node:test";
import { clip, InvocationStore, wellFormed } from "../src/invocations.js";

/** A lone high surrogate escape that is not followed by a low one (what Swift's JSONDecoder rejects). */
const LONE_ESCAPE = /\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])/i;
const isWellFormed = (text: string | undefined): boolean => text !== undefined && wellFormed(text) === text;

test("truncation never splits a surrogate pair: responseText, partialText and failureMessage stay well-formed", () => {
  const store = new InvocationStore();
  const record = store.create("ctx", "prompt", new Date().toISOString());
  const id = record.invocationId;
  const split = `${"x".repeat(7_999)}😀 tail`;

  store.setPartialText(id, split);
  assert.ok(isWellFormed(record.partialText));
  assert.equal(record.partialText, `${"x".repeat(7_999)}…`);
  assert.doesNotMatch(JSON.stringify(record), LONE_ESCAPE);

  store.setResponse(id, split);
  assert.ok(isWellFormed(record.responseText));
  assert.equal(record.responseText, `${"x".repeat(7_999)}… [truncated]`);
  assert.doesNotMatch(JSON.stringify(record), LONE_ESCAPE);

  store.finish(id, "failed", `${"y".repeat(1_999)}😀 more`);
  assert.ok(isWellFormed(record.failureMessage));
  assert.equal(record.failureMessage, "y".repeat(1_999));
  assert.doesNotMatch(JSON.stringify(record), LONE_ESCAPE);
});

test("a pair that fits is kept whole; activity and lone surrogates in deltas are repaired", () => {
  const store = new InvocationStore();
  const record = store.create("ctx", "prompt", new Date().toISOString());
  const id = record.invocationId;
  store.setResponse(id, `${"x".repeat(7_998)}😀 tail`);
  assert.equal(record.responseText, `${"x".repeat(7_998)}😀… [truncated]`);
  // A stream delta that ends on a high surrogate (the low half arrives with the next delta).
  store.setPartialText(id, "partial \ud83d");
  assert.equal(record.partialText, "partial �");
  store.setActivity(id, `${"a".repeat(79)}😀`);
  assert.ok(isWellFormed(record.activity));
  assert.equal(record.activity, "a".repeat(79));
  assert.equal(clip("ab", 8), "ab");
  assert.equal(clip("\udc00 lone low", 50), "� lone low");
});

test("unchanged activity and partial text publish no new revision (no no-op stream frames)", () => {
  const store = new InvocationStore();
  const record = store.create("ctx", "prompt", new Date().toISOString());
  const id = record.invocationId;
  store.setActivity(id, "Thinking");
  store.setPartialText(id, "Hello");
  const revision = record.revision;
  store.setActivity(id, "Thinking");
  store.setPartialText(id, "Hello");
  store.setActivity(id, "a".repeat(200));
  const afterLong = record.revision;
  store.setActivity(id, "a".repeat(300)); // clips to the same 80 chars
  assert.equal(afterLong, revision + 1);
  assert.equal(record.revision, afterLong);
  store.setPartialText(id, undefined);
  store.setPartialText(id, undefined);
  assert.equal(record.revision, afterLong + 1);
});

test("context and attachment summaries: unchanged values publish no revision; a follow-up keeps the scope and clears the summaries", () => {
  const store = new InvocationStore();
  const record = store.create("ctx-1", "explain DNS", new Date().toISOString(), "inv-ctx");
  store.setContext("inv-ctx", { scope: "general", source: "default", pulled: false, included: false });
  const revision = record.revision;
  store.setContext("inv-ctx", { scope: "general", source: "default", pulled: false, included: false });
  store.setAttachments("inv-ctx", undefined);
  assert.equal(record.revision, revision, "no-op updates are no new revision");
  store.setContext("inv-ctx", { scope: "general", source: "default", pulled: true, included: true });
  store.setAttachments("inv-ctx", [{ kind: "text", origin: "selection", chars: 12 }]);
  assert.deepEqual([record.context, record.attachments], [{ scope: "general", source: "default", pulled: true, included: true }, [{ kind: "text", origin: "selection", chars: 12 }]]);
  // The user narrows the pulled thread: `pulled` stays, `included` turns false (a new revision).
  const pulledRevision = record.revision;
  store.setContext("inv-ctx", { scope: "general", source: "user", pulled: true, included: false });
  assert.equal(record.revision, pulledRevision + 1);
  store.setContext("inv-ctx", { scope: "general", source: "default", pulled: true, included: true });
  store.finish("inv-ctx", "completed");
  assert(store.requeueForFollowup("inv-ctx", "and DHCP?"));
  assert.deepEqual(record.context, { scope: "general", source: "default", pulled: true, included: true }, "the thread's scope stays");
  assert.equal(record.attachments, undefined, "attachments belong to their turn");
  store.setContext("inv-ctx", undefined);
  assert.equal("context" in record, false);
});
