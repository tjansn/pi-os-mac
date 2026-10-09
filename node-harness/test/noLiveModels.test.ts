import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";

test("test bootstrap blocks Ollama and provider calls without opening a connection", async () => {
  assert.equal(process.env.PI_OFFLINE, "1");
  assert.equal(process.env.PI_OS_AGENT, "0");
  assert.equal(process.env.PI_OS_LAYA, "0", "the real Laya engine can never start under npm test");
  assert.ok(process.env.PI_OS_SUPPORT_DIR, "harness stores stay out of the user's support directory");
  for (const url of ["http://127.0.0.1:11434/health", "http://127.0.0.1:11434/api/generate",
    "http://localhost:8080/v1/chat/completions", "https://api.openai.com/v1/responses"]) {
    await assert.rejects(fetch(url), /forbidden in tests/);
  }
});

test("guard admits planned harness routes on loopback and keeps everything else blocked", async () => {
  let hits = 0;
  const server = createServer((_request, response) => { hits++; response.writeHead(204).end(); });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert(address && typeof address === "object");
  const base = `http://127.0.0.1:${address.port}`;
  try {
    // The final harness route set (protocol.md) plus host tool routes.
    const allowed: [string, string][] = [
      ["POST", "/instant"], ["POST", "/invocations/prepare"], ["GET", "/invocations/inv-1/events"],
      ["POST", "/invocations/inv-1/cancel"], ["POST", "/invocations/inv-1/followup"], ["POST", "/invocations/inv-1/close"],
      ["GET", "/settings/routing"], ["POST", "/settings/routing"],
      ["GET", "/settings/classifier"], ["POST", "/settings/classifier"],
      ["GET", "/settings/resources"], ["POST", "/settings/resources"],
      ["GET", "/invocations/inv-1"], ["GET", "/health"], ["POST", "/invoke"], ["GET", "/models"], ["POST", "/settings/model"],
      ["GET", "/tools"], ["POST", "/tools/launcher.searchFiles"], ["POST", "/tools/launcher.listApps"], ["POST", "/tools/launcher.open"],
    ];
    for (const [method, path] of allowed) {
      const response = await fetch(base + path, { method, ...(method === "POST" ? { body: "{}" } : {}) });
      assert.equal(response.status, 204, `${method} ${path}`);
    }
    assert.equal(hits, allowed.length);

    for (const url of [
      "https://example.com/instant", "http://api.example.test/invocations/prepare", `https://127.0.0.1:${address.port}/instant`,
      "http://127.0.0.1:11434/instant", "https://api.frankfurter.app/latest", "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml",
      "https://chatgpt.com/backend-api/codex/responses", "https://api.anthropic.com/v1/messages", "http://[::1]:11434/api/tags",
      `${base}/v1/chat/completions`, `${base}/instantx`, `${base}/settings/other`, `${base}/prepare`, `${base}/prepare/extra`,
      `${base}/models?refresh=1`, `${base}/instant?text=1`, `${base}/invocations/inv-1/events?after=1`,
      // The Phase-A long-poll query entries are retired: SSE replaced them, so no route takes a query.
      `${base}/invocations/inv-1?revision=3&waitMs=25000`, `${base}/invocations/inv-1?waitMs=10`,
      `${base}/invocations/inv-1?revision=1&prompt=x`, `${base}/invocations/inv-1?revision=abc`,
    ]) {
      await assert.rejects(fetch(url, { method: "POST", body: "{}" }), /forbidden in tests/, url);
    }
    assert.equal(hits, allowed.length, "Blocked requests never reach a server");
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
