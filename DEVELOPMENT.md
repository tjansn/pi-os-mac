# Development

This project has native C# Windows and Swift/AppKit macOS hosts and a shared
Node.js agent harness. Hosts own desktop UI and native operations; Node runs
the pi agent and its tools.

**macOS:** see [`host-macos/README.md`](host-macos/README.md) for build, launch,
permissions, tests, configuration and installed-preview refresh. The instructions
below cover Windows unless noted otherwise.

## Prerequisites

- .NET SDK 10
- Node.js 22.19 or later (required by the pi 1.0 SDK)
- pi authentication through `pi /login` or a provider API key

Install the Node dependencies once:

```powershell
cd node-harness
npm install
```

## Recommended workflow: one launch

Build the Node harness, then run the C# host. The host starts and stops the
Node process automatically.

```powershell
cd node-harness
npm run check
npm run build

cd ../host-dotnet/WindowsHarness.Host
dotnet run
```

Rebuild the Node harness after a TypeScript change. `dotnet run` rebuilds the
C# host after a C# or XAML change.

## Split workflow: Node live reload

Use two terminals when working frequently on the Node harness.

Choose one random token (for example, generate it with
`node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`) and set
the **same value in both terminals**. Do not commit it.

Terminal 1:

```powershell
$env:PI_OS_TOKEN = "<same-random-token>"
cd node-harness
npm run dev
```

Terminal 2:

```powershell
$env:PI_OS_SUPERVISOR = "0"
$env:PI_OS_TOKEN = "<same-random-token>"
cd host-dotnet/WindowsHarness.Host
dotnet run
```

Missing tokens now fail closed. Only for an isolated, intentionally unauthenticated
dev setup may you set `PI_OS_INSECURE_DEV=1` in both processes instead. Never use
that switch in an installed build; Mac supervised mode forbids it. In either mode the
Node harness refuses browser requests (`Origin` / `Sec-Fetch-Site` → 403) and request
bodies that are not `application/json` (415), so manual `curl` calls need
`-H 'Content-Type: application/json'`.

## Tests

Run the Node checks from `node-harness/`:

```powershell
npm run check
npm test
```

Run the .NET tests from the repository root:

```powershell
dotnet test host-dotnet/WindowsHarness.Host.Tests/WindowsHarness.Host.Tests.csproj
```

To run the Node harness without an LLM, set `PI_OS_AGENT=0`. The fake host in
`node-harness/test/fake-host.mjs` can provide deterministic desktop context for
headless checks.

`npm test` preloads `test/no-live-models.mjs`: it sets `PI_OFFLINE=1`,
`PI_OS_AGENT=0` and `PI_OS_LAYA=0`, points `PI_OS_SUPPORT_DIR` at a temporary
directory (macOS) and lets `fetch` reach only this project's loopback routes
(`/health`, `/tools/…`, `/invoke`, `/instant`, `/invocations/…`, `/models`,
`/settings/{model,resources,routing,classifier}`). Every other URL, including
provider APIs, the ECB rate feed and Ollama, throws. Do not bypass it. The
integration tests (`test/integration*.test.ts`) drive the HTTP surface end to end
with a fake host and an in-process provider (pi-ai's faux core), so real pi
sessions, the Auto router, SSE and cards run without any network or model.
`test/serverContext.test.ts` covers the context scope and the context shelf through the
same HTTP surface: strict `context` / `attachments` parsing (every shared fixture), general
vs window turns, a general turn that survives a lost window, attachments end to end, the
Brave page digest served by a fake `browser.page` route from `shared/fixtures/browser-ax`,
and log lines checked for the absence of request, attachment and page text. The
macOS conformance suite (`npm run test:macos`) additionally builds and starts the
Swift host in `--conformance` mode; it never installs or signs anything.

### Context scope and attachments (macOS)

Hosts without a context chip (Windows, older Mac builds) send no `context`: the harness
then runs today's window turn unchanged. A Mac request with `context.scope: "general"`
gets no screenshot, no desktop JSON and no window tools, only the app name and, when the
host allows a pull, the `use_active_window` tool; it continues even when the pinned window
is gone. `scope: "window"` keeps today's strictness and, for a Brave tab pinned in
Accessibility mode, stages the host's `browser.page` digest into the first prompt (read in
parallel, at most 1.5 s, never through DevTools). Attachments (`attachments[]`) are
validated against `PI_OS_CAPTURES_DIR`: shelf images must be `shelf-<id>.png` directly
inside it. See `shared/protocol/protocol.md` ("Context scope", "Attachments").

## Refresh the installed application

The desktop shortcut runs the installed copy, not the repository build. After
validating a change, refresh that copy from the repository root:

```powershell
.\refresh-install.ps1
```

Use `-ForceDeps` when the installed Node dependencies must be installed again.

## Environment variables

All variables are optional. The normal one-launch workflow uses their default
values.

| Variable | Purpose |
|----------|---------|
| `PI_OS_TOKEN` | Internal authentication token shared by the two processes. The supervisor generates and passes it automatically in normal launches; split development must explicitly share the same token. |
| `PI_OS_HOTKEY` | Overrides the global hotkey, for example `Ctrl+Shift+F9` (default `Ctrl+Alt+Space`). |
| `PI_OS_AGENT` | Set to `0` or `false` to use deterministic test mode without LLM calls. The agent is enabled by default. |
| `PI_OS_NODE_PORT` | Changes the Node harness listening port (default `17832`). Also set `PI_OS_NODE_URL` to the matching address for the C# host. |
| `PI_OS_HOST_PORT` | Changes the C# host listening port (default `17831`). Also set `PI_OS_HOST_URL` to the matching address for the Node harness. |
| `PI_OS_HOST_URL` | Changes the C# host address used by the Node harness (default `http://127.0.0.1:17831`). |
| `PI_OS_NODE_URL` | Changes the Node harness address used by the C# host (default `http://127.0.0.1:17832`). |
| `PI_OS_SUPERVISOR` | Set to `0` to prevent the C# host from starting the Node harness. Use this for the split workflow. |
| `PI_OS_NODE_ENTRY` | Overrides the Node entry file started by the supervisor. The default resolver finds `node-harness/dist/index.js`. |
| `PI_OS_INVOKE_TIMEOUT_MS` | Sets the maximum request time in milliseconds (default `300000`; `0` disables the timeout). |
| `PI_OS_CAPTURES_DIR` | Changes the shared screenshot directory (default `%LOCALAPPDATA%\pi-os\captures`). Both processes must use the same directory. |
| `PI_OS_SUPPORT_DIR` | macOS only: changes the pi-os support directory (default `~/Library/Application Support/pi-os`) that holds `settings.json`, `classifier.json`, `routing-stats.json`, `cache/fx-ecb.json` and `logs/`. Windows always uses `%LOCALAPPDATA%\pi-os`. |
| `PI_OS_READ_ONLY` | Set to `1` to start the harness without native input (observation tools only). macOS also negotiates input per invocation from the host's `GET /tools`. |
| `PI_OS_INSTANT` | Set to `0`, `false` or `off` to turn the deterministic instant lane off (`POST /instant` then always falls through; `/invoke` never answers instantly). On by default. |
| `PI_OS_FX_RATES` | Set to `0`, `false` or `off` to stop the on-demand ECB reference-rate download for currency answers. On by default: the first currency question downloads `eurofxref-daily.xml` once (conditional GET, cached in `cache/fx-ecb.json`, one retry per minute after a failure). Nothing is fetched at startup. |
| `PI_OS_WEB_SEARCH` | Default web-search URL for "search the web for …" with exactly one `%s` (http/https only), for example `https://www.google.com/search?q=%s`. Default DuckDuckGo. |
| `PI_OS_LAYA` | Set to `0` to keep the optional local Laya classifier from ever starting, whatever `classifier.json` says (the test guard does this). |
| `PI_OS_LAYA_PYTHON`, `PI_OS_LAYA_MODEL_DIR`, `PI_OS_LAYA_SCRIPT` | Absolute paths used when Laya is enabled in Settings but `classifier.json` names none: the venv interpreter (laya 0.3.5 + CPU torch; named `python`, `python3` or `python3.x`) and the checkpoint directory (then `laya/venv/bin/python` and `laya/model` in the support directory, when present). `PI_OS_LAYA_SCRIPT` overrides the bundled `sidecars/laya/laya_intent_sidecar.py` for development; the script is never a Settings field. Environment variables reach only an app started from Terminal or `run-dev.sh`. |

Environment variables apply only to processes started after the variables are
set. Remove a PowerShell override with, for example:

```powershell
Remove-Item Env:PI_OS_SUPERVISOR
```

## Harness settings files

The Node harness keeps its settings in the support directory (`%LOCALAPPDATA%\pi-os`
on Windows, `~/Library/Application Support/pi-os` on macOS). The hosts change them
through the authenticated settings routes (`shared/protocol/protocol.md`); hand edits
are read on the next request.

| File | Contents |
|------|----------|
| `settings.json` | Key-scoped JSON shared by several stores: `model` (the Settings model choice; absent means Auto, `pi-os/auto`, on macOS and pi's own default model on Windows) and `routing` (Auto's `bias`, `maxAutoTier`, `tierOverrides`, `allowLocalModels`). Each write is an atomic read-modify-write of one key: unknown keys survive, and an unreadable file is copied to `settings.json.corrupt` before it is replaced. |
| `resources.json` | Isolated or trusted pi resources (explicit acknowledgement required). |
| `classifier.json` | Optional advisory classifier: `off` (default), `laya` (local, CPU-only sidecar, started lazily on first use) or `pi` (a pi catalog classifier, which sends final utterances, never partials or previews, to that provider). |
| `routing-stats.json` | Auto's measured time to first token and tokens/s per `provider/model@level`, plus temporary provider health blocks. Ids and numbers only. |
| `cache/fx-ecb.json` | The cached ECB reference rates. |
| `logs/classifier-shadow.jsonl` | Only with the classifier's shadow log on: labels, probabilities and latency, never text (pauses at 5 MiB). |

Harness logs never contain prompts, transcripts, typed text, file names, classifier
inputs, attachment content, window titles, page text or paths; `[perf] stage=… ms=…` lines
carry stage names, durations, counts, codes and model ids. Per turn: `invoke.context`
(scope, source, pull, window availability, rules score, the host's `hint`, attachment
count and kinds), `context.label` (explicit user choices: label and scores only, for
retraining the scope scorer), `invoke.page` (Brave digest read: ok/code, length, refs),
`invoke.capture` (a follow-up's fresh capture of the pin, taken only by the harness when the
window comes in or the thread has no screenshot yet: ok/code),
`invoke.route` (tier, model, scope, screenshot, vision), `agent.response` (TTFT,
`createdMs` to the provider's stream start, `firstDelta` kind, tokens) and `invoke.total`
(model turns, scope, pulled, included, attachment count).

## Process safety

Stop foreground processes with `Ctrl+C`. If a process remains, find the PID
that owns the relevant port and stop only that PID. Do not stop every
`node.exe` process because other tools can use the same runtime.
