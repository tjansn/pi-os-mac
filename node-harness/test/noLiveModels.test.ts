import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";

test("test bootstrap blocks Ollama and provider calls without opening a connection", async () => {
  assert.equal(process.env.PI_OFFLINE, "1");
  assert.equal(process.env.PI_OS_AGENT, "0");
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
    const allowed: [string, string][] = [
      ["POST", "/instant"], ["POST", "/prepare"], ["POST", "/invocations/inv-1/steer"],
      ["GET", "/settings/routing"], ["POST", "/settings/routing"],
      ["GET", "/settings/classifier"], ["POST", "/settings/classifier"],
      ["GET", "/invocations/inv-1?revision=3&waitMs=25000"], ["GET", "/invocations/inv-1?waitMs=10"],
      ["GET", "/invocations/inv-1"], ["GET", "/health"], ["POST", "/invoke"], ["GET", "/models"], ["POST", "/settings/model"],
    ];
    for (const [method, path] of allowed) {
      const response = await fetch(base + path, { method, ...(method === "POST" ? { body: "{}" } : {}) });
      assert.equal(response.status, 204, `${method} ${path}`);
    }
    assert.equal(hits, allowed.length);

    for (const url of [
      "https://example.com/instant", "http://api.example.test/prepare", `https://127.0.0.1:${address.port}/instant`,
      "http://127.0.0.1:11434/instant",
      `${base}/v1/chat/completions`, `${base}/instantx`, `${base}/settings/other`, `${base}/prepare/extra`,
      `${base}/models?refresh=1`, `${base}/instant?text=1`, `${base}/invocations/inv-1/steer?revision=1`,
      `${base}/invocations/inv-1?revision=1&prompt=x`, `${base}/invocations/inv-1?revision=abc`,
    ]) {
      await assert.rejects(fetch(url, { method: "POST", body: "{}" }), /forbidden in tests/, url);
    }
    assert.equal(hits, allowed.length, "Blocked requests never reach a server");
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
