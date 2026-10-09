// Loaded BEFORE SDK/tsx imports by npm test. Unit/conformance tests must never warm
// a local model or accidentally spend provider tokens. Only this project's loopback
// test HTTP routes are allowed through fetch; no Ollama/provider APIs are permitted.
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.PI_OFFLINE = "1";
process.env.PI_OS_AGENT = "0";
// The real Laya engine can never start (tests inject the fake engine explicitly).
process.env.PI_OS_LAYA = "0";
// Keep harness stores (settings, routing stats, classifier.json, rate cache) out of the
// user's real support directory; macOS honours this override. Created lazily on first write.
process.env.PI_OS_SUPPORT_DIR ??= join(tmpdir(), "pi-os-test-support", String(process.pid));

const originalFetch = globalThis.fetch;
// Matched against pathname + query: the final harness route set (protocol.md) plus host tool
// routes. /invocations/... covers status, events (SSE), prepare, cancel, followup and close.
// No route takes a query string.
const testRoutes = /^(?:\/health|\/tools(?:\/[^?]*)?|\/invoke|\/instant|\/invocations\/[^?]*|\/models|\/settings\/(?:model|resources|routing|classifier))$/;
globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
  const loopback = url.hostname === "127.0.0.1" || url.hostname === "localhost";
  if (!loopback || url.protocol !== "http:" || url.port === "11434" || !testRoutes.test(url.pathname + url.search)) {
    throw new Error(`Live provider/network calls are forbidden in tests: ${url.origin}${url.pathname}`);
  }
  return originalFetch(input, init);
};
