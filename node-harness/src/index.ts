import { loadConfig } from "./config.js";
import { HarnessServer } from "./server.js";
import { perfLog } from "./telemetry.js";

/**
 * Harness entry point. Instant-first (DESIGN4 §7 item 5): server.js imports only the instant lane,
 * the dictionary and the HTTP surface, so /health, /instant and /dictionary/* serve as soon as the port
 * is bound; the agent stack is imported right after listen() and the routes that need it await it.
 */
async function main(): Promise<void> {
  const config = loadConfig();
  const server = new HarnessServer(config);
  let shuttingDown = false;
  const shutdown = async (): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log("[harness] shutting down");
    const deadline = setTimeout(() => process.exit(0), 1500);
    deadline.unref();
    await server.close().catch(() => {});
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
  if (process.env.PI_OS_SUPERVISED === "1") {
    // Held pipe from the native parent; EOF is an event-driven parent-death signal.
    process.stdin.once("end", () => void shutdown());
    process.stdin.once("error", () => void shutdown());
    process.stdin.resume();
  }
  await server.listen();

  // Milliseconds since the process started (performance.timeOrigin): the instant lane is ready now.
  perfLog("harness.listen", performance.now(), {});
  console.log(`[harness] node harness listening on http://127.0.0.1:${config.port}`);
  console.log(`[harness] host expected at ${config.hostBaseUrl}`);
}

void main().catch((error) => {
  console.error("[harness] fatal:", error);
  process.exit(1);
});
