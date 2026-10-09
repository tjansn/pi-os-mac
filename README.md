# pi-os

An OS-level AI layer: press a global hotkey in **any** application,
type an instruction, and a [pi](https://github.com/earendil-works/pi) agent
already knows what you were looking at and has tools to act on it.

**Windows:** current shipping functionality. **macOS 14+:** native AppKit host with
a signed build-12 native Whisper glass interface with pinned control, persistent reader and conversational
follow-ups (installed; full parity not yet accepted), plus push-to-talk voice, instant commands,
the Auto model and result cards on the `feat/voice-magic` line (built and tested offline, not yet installed); [build/run instructions](host-macos/README.md) and
[acceptance status](host-macos/STATUS.md). Computer-use parity is still gated by
the [migration plan](MACOS_MIGRATION.md).

Windows architecture:

```
Notepad, Explorer, Excel, browser, anything
        |
   Ctrl+Alt+Space
        |
        v
+---------------------------+      HTTP/JSON       +---------------------------+
|  C# host (hidden WPF)     | -------------------> |  node-harness             |
|  - pins context BEFORE    |   POST /invoke       |  - pi SDK AgentSession    |
|    the popup shows        | <------------------- |  - desktop tools          |
|  - prompt overlay         |  POST /tools/{name}  |  - observe/act loops      |
|  - screenshots, UIA, input|                      |    via pi extensions      |
+---------------------------+                      +---------------------------+
```

The core split:

- **C# host** = stable native substrate: hotkey, context pinning, screenshots,
  UI Automation, input primitives.
- **node-harness** = the intelligence: a real pi session that reasons, picks
  tools, and re-observes after actions.
- Everything rapidly changing lives on the node side or in sidecars — the host
  stays small.

## Repository layout

| Path | Purpose |
|------|---------|
| `host-dotnet/` | C# solution: `WindowsHarness.Host` (WPF background app) + `WindowsHarness.Contracts` (shared schema types) |
| `host-macos/` | Native Swift/AppKit host, SCK, gated input, model settings and lazy Node supervision (parity candidate) |
| `node-harness/` | Node service: HTTP server on port 17832, pi SDK agent sessions, desktop tool wrappers |
| `shared/schemas/` | Canonical TypeScript types for the context snapshot (`desktop-context.ts`) |
| `shared/protocol/` | The localhost HTTP contract (`protocol.md`) — ports, endpoints, error model |

## Development

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for prerequisites, build and test
commands, development workflows, environment variables, and instructions for
refreshing the installed application.

## Use it on Windows

1. Focus any desktop app (Notepad, Explorer, ...).
2. Press **Ctrl+Alt+Space**.
3. Type an instruction, press **Enter**. The overlay closes instantly and
   focus returns to your app.
4. The harness logs show the pinned snapshot, then the agent's answer.

A pi session receives the context summary and screenshot. It can observe the
captured window and use `desktop_act` to focus, click, type, press supported
keys or shortcuts, and scroll. Safe action traces are written to
`logs\host.log`; typed content is never logged. Agent mode requires pi
authentication through `pi /login` or a provider API key.

### Choosing the model

Right-click the tray icon → **Settings…** to pick the agent model and its
reasoning effort. The list shows models with configured authentication, and
effort options adapt to the selected model. The choice persists in
`%LOCALAPPDATA%\pi-os\settings.json`; every new hotkey invocation uses it
(a running task keeps its own model), both switches are logged to
`logs\host.log`.

## On macOS: voice, instant commands, Auto and cards

The macOS host ([details](host-macos/README.md#voice-instant-commands-auto-and-result-cards))
adds a faster path on top of the agent:

- **Push-to-talk (opt-in).** Turn on *Settings → Voice*, then hold the hotkey and speak
  (macOS 26+, on-device Apple speech recognition, English or German). A quick tap still
  opens the text bar; while voice is off, a hold says where to turn it on. Microphone and
  Speech Recognition are requested only from buttons in Settings, never from the hotkey. Audio and transcripts stay on the Mac and are never
  recorded or logged.
- **Instant commands.** Math, units, currencies, time zones, dates, opening apps and links,
  web searches, file search and volume run without a model, usually in milliseconds, with a
  live preview while you type or speak. The native host performs the action after its own
  policy check; nothing can delete, trash or move files. Return runs it, ⌥Return always asks
  pi. Currency conversions download the European Central Bank's daily reference rates on
  first use (no question or personal data is sent); that is the only new network request.
- **Auto model.** *Auto (recommended)* is listed first in Settings and picks a fast adequate
  model and effort per request (*Prefer speed / Balanced / Prefer quality*). It is the
  default when no model is stored; explicit choices still work.
- **Streaming and result cards.** Answers stream into the reader and can be native cards
  (tables, lists, files) with buttons limited to copy, open, reveal and ask.
- **Local classifier (opt-in).** The optional Laya classifier (*Settings → Classifier*) is
  advisory only, runs on the CPU, needs about 5 GB of memory, and is off by default. Choose
  its Python environment and model folder on that page, then switch it on.

Windows keeps its text prompt; it also sees *Auto* in its model list and quick answers
(math, conversions) arrive as ordinary answer text.

## Configuration

No environment variables are required for normal use. These optional settings
change user-visible behavior:

| Variable | Meaning |
|----------|---------|
| `PI_OS_HOTKEY` | Hotkey override, e.g. `Ctrl+Shift+F9` (default `Ctrl+Alt+Space`) |
| `PI_OS_INVOKE_TIMEOUT_MS` | Maximum time for each request in milliseconds (default `300000`; `0` disables the timeout) |

Other `PI_OS_*` variables are development and test controls documented in
[`DEVELOPMENT.md`](DEVELOPMENT.md).

Artifacts live under `%LOCALAPPDATA%\pi-os\`: `logs\host.log`,
`captures\shot-*.png`, plus `settings.json` (model + reasoning effort chosen
in the tray settings page).

## Reference files

| File | Read when |
|------|-----------|
| `shared/protocol/protocol.md` | You change any endpoint, port, or message shape |
| `shared/schemas/desktop-context.ts` | You touch the context snapshot shape (C# mirror must stay field-compatible) |
| `AGENTS.md` | You use a coding agent in this repository |
| `VOICE_MAGIC.md` | You want the voice/instant/Auto design, its measurements, the evaluations (macbrow, jev, json-render, Laya, Clef, pi-durable) and what is still unverified |

## Current Windows capabilities

- Starts from one desktop shortcut and remains available in the system tray.
- Captures the active window, screenshot, focused UI element, and monitor
  information before showing the prompt.
- Uses a pi agent to inspect and interact with the captured window.
- Supports focusing, clicking, typing, key presses, keyboard shortcuts, and
  scrolling.
- Provides model and reasoning-effort settings from the tray menu.
- Supports cancellation, request timeouts, and live task status.
- Blocks computer input in protected applications such as password managers
  and elevated windows.

## License

pi-os is available under the [MIT License](LICENSE). Third-party dependencies
remain subject to their own licenses.
