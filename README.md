# pi-os

An OS-level AI layer: press a global hotkey in **any** application,
type an instruction, and a [pi](https://github.com/earendil-works/pi) agent
already knows what you were looking at and has tools to act on it.

**Windows:** current shipping functionality. **macOS 14+:** native AppKit host with
a signed build-12 native Whisper glass interface with pinned control, persistent reader and conversational
follow-ups (installed; full parity not yet accepted), plus push-to-talk voice, instant commands,
the Auto model and result cards on the `feat/voice-magic` line, and general-by-default questions with a
context shelf, pointing and dialog-free Brave on `feat/context-shelf` (both built and tested offline, not yet
installed); [build/run instructions](host-macos/README.md) and
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
  English, German or a mix (macOS 26+). Apple's on-device dictation listens for every language
  you check under *Languages I speak* at once; an optional multilingual model (NVIDIA Parakeet
  TDT 0.6B v3, 483 MB, downloaded only after you confirm in *Settings → Voice → Recognition*)
  also runs on the Mac. A quick tap still opens the text bar; while voice is off, a hold says
  where to turn it on. Microphone and Speech Recognition are requested only from buttons in
  Settings, never from the hotkey. Audio never leaves the Mac and is never logged; takes are kept
  only if you turn on *Keep my last voice takes to improve recognition* (the last 50, on this Mac).
- **Corrections and a dictionary.** A misheard app name gets *Did you mean …?*, a doubtful
  reading one Return, and a short garbled take *Did I hear that right?* instead of an LLM turn
  that asks back. Picks, confirms and "No, I meant …" teach a personal dictionary (with Undo)
  that applies from the next take; *Settings → Dictionary* shows and edits it. Learned rules can
  only open an app, open a web page or change the volume.
- **Instant commands.** Math, units, currencies, time zones, dates, opening apps and links,
  web searches, file search and volume run without a model, usually in milliseconds, with a
  live preview while you type or speak. The native host performs the action after its own
  policy check; nothing can delete, trash or move files. Return runs it, ⌥Return always asks
  pi. Currency conversions download the European Central Bank's daily reference rates on
  first use (no question or personal data is sent); that is the only network request instant
  commands make.
- **It continues where you are** ([details](VOICE_MAGIC.md#pass-5-2026-10-08-continuity)). After *open Safari*,
  *open google* opens in that Safari window: links go to the browser in front, or to the one pi-os is still
  launching, and only otherwise to your default browser. When a text field has the caret, what you say goes into it,
  questions included; commands, requests for pi (*schreib …*, *fasse … zusammen*) and questions about the page
  (*what is this page about*, *was steht da*) never do. Return is pressed only in search boxes and the address bar.
  *nein* within 5 s undoes the typing (the note's *Undo* too), *tippe …* always types, *frag pi …* always asks pi.
  Password, code and payment fields get text only when you say *tippe …* and allow it in *Settings → General*; words
  spoken there that no command takes are hidden as *•••*, never sent to pi on their own and never kept. Switch
  typing off in *Settings → Voice → Type into the focused field*; it needs computer control. Typing into fields is on
  the `feat/continuity` branch (built and tested offline, not installed); links following the browser in front are
  installed.
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

## On macOS: general by default, the context shelf and pointing

The bar no longer assumes every question is about the window in front
([details](host-macos/README.md#general-by-default-the-context-shelf-and-pointing)):

- **It opens general.** The hotkey shows *Ask anything…*; the window is not captured up front. A
  **context chip** at the right of the bar shows the frontmost app: *off* (just its icon),
  *suggested* (outlined, when you refer to what is on screen — “summarize this page”, “die Mail”,
  “make it shorter” — or point at something in it) or *on* (filled). **What the chip shows when
  you press Return is what goes with your question**; only then is the window captured. If the
  question turns out to need the window anyway, pi may look (the bar says *Looking at Brave…*, the
  answer *Looked at Brave*) unless you left it out with Tab (the chip is then struck through) or
  chose *Only when I ask*. After pi looked, the follow-up chip starts on.
- **Tab** (or a click on the chip) includes or leaves out the window; your choice sticks for that
  question. **⇧ + the hotkey** (⌃⌥⌘⇧Space by default; tap to type, hold to talk) or the menu's
  *Ask About This Window…* opens with the window included. *Settings → Context → Active window*:
  *Only when I ask*, *Suggest* (default) or *Always include*.
- **The context shelf.** Select text or an image anywhere and press **⌃⌥⌘C** (“Add to pi”):
  a small *Added to pi* note confirms it, and pi neither opens nor takes focus. Opening pi with
  text selected adds that selection too. Drop files, links, text or images on the bar or on the
  menu-bar π; *Grab an Area…* (the chip's menu, or *Add Screen Area to pi…* in the menu bar)
  adds part of the screen, and the menu bar's *Add Selection to pi* does what ⌃⌥⌘C does.
  Dropped or copied files are references pi can open or reveal for you but does not read; image
  files are attached as images. Something you just copied shows as a dashed *Clipboard …* chip
  and is read only when you click its **+**. Chips show exactly what will be sent (click one to see
  it), **⊗** removes one, **⌫** in an empty bar removes the last, and they stay across hotkey
  presses until sent or cleared (8 items, 4 images, 20,000 characters per text).
- **Point pi at things.** Drag the chip (or π) onto any window: a line follows the pointer, a
  purple frame shows the window, and dropping makes it the question's window. Hold **⌥** while
  dragging (or choose *Point at an Element…*, also in the menu bar) to point at one button,
  paragraph or field: an orange frame names it, the window it is in goes with the question, and
  your message reads “Pointing at Button “Send””. Pointing works on a new question (not in the
  follow-up composer). Password and username fields are never read.
- **Brave without dialogs.** pi reads your Brave tab through macOS Accessibility (*Settings →
  Context → Brave access: Accessibility*, the default): no “Allow remote debugging?” prompt and
  no automation banner. With *Act in Brave in the background* (default on) it presses buttons and
  fills fields without bringing Brave forward; deletion, credential and budget checks still apply.
  DevTools is an explicit opt-in. You can now switch off *Allow remote debugging for this browser
  instance* at brave://inspect (*Open brave://inspect…* in Settings) — pi no longer needs it.

## Configuration

No environment variables are required for normal use. These optional settings
change user-visible behavior:

| Variable | Meaning |
|----------|---------|
| `PI_OS_HOTKEY` | Hotkey override, e.g. `Ctrl+Shift+F9` (default `Ctrl+Alt+Space`; macOS `Ctrl+Option+Cmd+Space`, whose ⇧ variant opens with the window included) |
| `PI_OS_ADD_HOTKEY` | macOS only: the “Add to pi” chord (default `Ctrl+Option+Cmd+C`) |
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
| `VOICE_MAGIC.md` | You want the voice/instant/Auto design, its measurements, the evaluations (macbrow, jev, json-render, Laya, Clef, pi-durable), the pass-3 voice reliability work (EN/DE recognition, Parakeet, the dictionary), pass-5 continuity (links in the browser in front, typing into the focused field) and what is still unverified |

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
