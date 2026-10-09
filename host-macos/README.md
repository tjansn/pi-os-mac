# Native macOS host — development preview

Swift/AppKit, macOS 14+, no Swift dependencies. The repository now contains a
**computer-use parity candidate** on the original native-host/Node architecture:
window-scoped input, model settings, background results, permissions and packaging.
It is **not yet accepted full Windows parity or a notarized release**. The installed
app is now certificate-signed build 12, with the native Whisper glass interface,
conversational follow-ups, a persistent reader, scoped Brave tools and configurable credential input. Installed-host capture/input
passed the controlled AppKit fixture after user Screen Recording and Accessibility
approval; the broader parity matrix remains open.
See [PARITY.md](PARITY.md) for implemented features, evidence and remaining gaps.

## Build and launch

Requires Xcode/Command Line Tools, Swift 5.9+, Node 22.19+, and pi authentication
(`pi /login` or your normal provider environment). No shell profiles are evaluated
by the app. The checked-in lockfile pins pi SDK 1.0.0.

From the repository root:

```sh
npm --prefix node-harness ci
export PI_OS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
host-macos/scripts/build-app.sh
open host-macos/build/pi-os.app
```

The build script records **explicit absolute development Node/entry paths** in
the bundle, so launching this preview from Finder does not depend on launchd's
PATH. It still references the checkout's `node-harness/dist` and `node_modules`.
This is not distribution packaging and must not be shipped as a self-contained app.

Default hotkey: **Control–Option–Command–Space**. Press it over a window, type a
question, then Return (or hold it and speak, once voice is on — see below). **Shift–Return** adds a line; the composer grows as you type.
Escape dismisses the prompt; the working capsule has a Cancel button. Answers have
native Markdown typography and size to their content, with scrolling for longer replies.
**⌘⇧C** copies the original answer, with a brief “Copied” confirmation. Escape, Done,
or clicking elsewhere dismisses the answer; **π → Show Last Answer** brings it back
(in memory only, including after a later question fails).

The menu bar `π` item provides **Settings…** (provider, model and reasoning effort),
current-task access, permissions, diagnostics, About and Quit. The working capsule
can be hidden without cancelling; completion uses an opt-in notification or native
toast fallback. Once input begins, the capsule stays out of the target's way until
the result is ready. Appearance follows macOS, with reduced-motion/transparency and increased-
contrast handling. No animation delays the hotkey or keyboard dismissal.

Window identity and cursor are pinned **before** showing the nonactivating panel.
SCK and Node startup run asynchronously while you type. Screenshots explicitly
capture the pinned `CGWindowID + PID`, not the frontmost window at capture time.
A missing window or failed screenshot produces a typed error, not a text-only
invocation masquerading as a captured context.

## Whisper appearance

The default is a **480 × 50 pt one-line bar**, centered 32 pt above the pinned
window display's visible work-area lower edge. Multiline editing and answers grow
upward; the bar remains anchored. The Dock/menu bar are respected. This is native
AppKit, not the disposable HTML prototype or a WebView.

Click **π** for pinned context and appearance, or **π menu → Appearance…** when
idle. Presets: **System** (default), **Clear**, **Frost**, **Graphite**, **Warm**,
**Contrast**. Larger text, Reduce Transparency and lower-edge spacing (20/32/48 pt)
are persisted independently of model/control/security settings. Appearance never
repins a target, resets budgets or closes a valid thread. Trusted pi mode retains a
visible warning even in the minimal bar.

Apple glass (`NSGlassEffectView`) is used on macOS 26+, with native visual-effect
material on 14/15. Readable answer material is deliberately denser. System Reduce
Transparency or Increase Contrast takes priority and makes the surface opaque;
Reduce Motion replaces the spinner with a static status symbol. No UI entrance,
exit or keyboard-triggered animation is added.

Build 12 passed 17 reader/lifecycle checks through the installed signed bundle.
See `UI_NOTES.md` for the exact inspected visual scope and remaining acceptance.

## Conversational follow-ups

The answer reader stays open when you click elsewhere. Type a follow-up below the
answer and press Return (Shift-Return adds a line). The same in-memory pi session,
original model and pinned target continue; references/screenshots must be refreshed
before actions. Only one prompt runs at a time. A failed follow-up preserves the
previous answer and permits explicit retry when the thread still has authority.

Escape, Done or the close button ends the conversation. A new hotkey replaces the
current thread. Cancellation, timeout, security-setting changes and quit also revoke
it. **Show Last Answer** recalls text, not an old session. No conversation is persisted
by pi-os. While the reader/thread is open, its harness reservation survives the normal
warm TTL; there is no idle status poller. Context authority still expires and budgets
remain cumulative across turns. Mac currently supports one reader at a time.

Build 11 passed 17 installed signed-host reader/lifecycle checks. The real SDK history
path also passed an in-memory stream-fixture test without contacting any provider.
No model-driven follow-up validation was performed during the local-GPU reservation.

## Voice, instant commands, Auto and result cards

**Push-to-talk (off by default).** Turn on **Settings → Voice → Hold the shortcut to talk**
(macOS 26+, on-device Apple SpeechAnalyzer/SpeechTranscriber; English (US) or Deutsch).
Then *hold* the hotkey for at least 250 ms and speak: the bar shows a live transcript
(finished words in normal ink, the still-changing tail in secondary ink) and an accent
waveform in the send slot. Let go to run it. A short *tap* keeps today's text bar; typing
while listening drops the audio and keeps the text; pressing the hotkey while the text bar
is open still closes it. The microphone opens at key-down so no syllable is clipped, which
means the orange menu-bar indicator can flash on a quick tap. Audio and transcripts stay in
the signed host process and are never recorded, sent to Node as audio, or logged. With voice
off, or on macOS 14–25, the hotkey behaves exactly as before.

Voice needs **Microphone** and **Speech Recognition**. pi-os asks for them only from the
**Request Access…** buttons in Settings → Voice; the hotkey never shows a permission prompt.
If a grant is missing, a hold explains what to do and offers **Open Voice Settings…**.
The German speech model downloads only from that page's **Download** button. While voice is
on, the warm Node child stays ready for 600 s after use (instead of 120 s) so a hold rarely
waits for a cold start; an explicit `PI_OS_NODE_WARM_TTL_SECONDS` still wins.

**Instant commands.** Math, units, currencies, number bases, time zones, date math, opening
apps/links, web searches, file search and volume/display sleep are parsed by Node's instant
engine (no model) and **performed by this host** after `LauncherPolicy` (`LauncherService`).
While you type (or speak) the bar previews the result after 150 ms of quiet: `= 51`, “Open
github.com”, or a file/app list above the bar. Previews never act.

| Key in the bar | Effect |
|---|---|
| Return | Run the instant action / open the selected result; otherwise ask pi |
| ⌥ Return | Always ask pi |
| ⌘ Return | Secondary: reveal the selected file in Finder, or type a computed value into the pinned window (needs computer control; otherwise copies it) |
| ↑ / ↓ | Move through a result list |
| ⌘⇧C | Copy the selected file's path while a list is focused or previewed; otherwise Copy Answer |

Successful actions show a brief “✓ Opened Figma” and the bar goes away. Answers, lists and
the file-deletion refusal appear as native cards in the reader; a follow-up there becomes a
fresh agent turn that starts with “Earlier quick answer: question → answer”. File results
use host-minted tokens bound to the take's context; they are revoked when the context is
discarded and expire after 10 minutes. Nothing deletes, trashes or moves files. Executables,
scripts and installers are revealed, never opened. Launcher actions are logged by kind and
outcome only in `logs/launcher-actions.jsonl`. Instant commands work with no capturable
window (Node warm-up and the window capture are separate; only agent questions wait for the
capture). Currency conversions download the ECB daily reference rates on first use only.

**Auto model.** Settings lists **Auto (recommended)** first. It is the `pi-os/auto` catalog
entry: Node picks a fast adequate model and effort per request. Its levels appear as
**Prefer speed / Balanced / Prefer quality**. Any explicit model choice still works.

**Streaming and cards.** Agent answers stream into the reader over one long-lived SSE
request (`GET /invocations/{id}/events`, ≤ 30 renders/s); if streaming is unavailable the
host falls back to today's status polling. Agent cards render natively and may only bind
copy/open/reveal/ask actions; recalled cards, and cards whose conversation closed, are read-only. Copy Answer always copies the
agent's original text. Nothing streams over a window the agent is acting in.

**Local classifier (Laya).** Settings → Classifier can turn on the optional local Laya
classifier. It is advisory only (it may ask Auto for a stronger model or a screenshot,
never choose or perform an action), runs on the CPU, needs about 5 GB of memory and ~18 s
to load, and is off by default. Its Python and model folder come from `PI_OS_LAYA_PYTHON`
and `PI_OS_LAYA_MODEL_DIR`.

## Text input

Native typing preserves Unicode and normalizes LF/CRLF/CR to single line breaks,
using Return-key pairs and 20 ms stroke spacing. `PI_OS_TYPE_INTERVAL_MS` explicitly
configures pacing (0 disables). Calls whose scheduled pacing exceeds 20 seconds are
refused before input: split large text into smaller sequential calls. No default
clipboard substitution is used. Brave multiline fill uses verified `Input.insertText`
and refuses single-line fields before input. Details and regression boundaries:
[`docs/desktop-input-semantics.md`](../docs/desktop-input-semantics.md).

## Live Brave connection

The repository now integrates live-session CDP through **π → Brave Connection…**
(also available in Settings), with explicit opt-in and a configurable local debugging
port. Enable Brave's own setting at `brave://inspect/#remote-debugging`, then enable
this connection in pi-os. Debugging grants broad browser access; read the warning.
No new profile, cookie export or browser restart is used.

The hotkey pins the selected native tab before the prompt. The agent receives
`browser_snapshot` / `browser_act` for semantic page references instead of
`desktop_act`; identity/permission/field-local credential/deletion checks still apply. Duplicate
URL/window matches, tab changes and uncertain writes fail closed. Only HTTP(S)
main-page/open-shadow DOM controls, same-tab links, text entry and scrolling are
supported initially. Frames, canvas, browser settings, downloads and new-tab/external-protocol
links are not yet supported. No silent native-input or
separate-profile fallback occurs. This is not a guaranteed no-delete sandbox.

**Installation status:** build 12 is installed. Browser-specific build-11 evidence below
is historical; the browser adapter itself was not changed by Whisper. Its default production-browser candidate
fixture passed 20 checks including multiline input and turn-bound reference invalidation.
The enabled-mode rerun stopped at the connection boundary (`browser_unavailable`),
before CDP attachment. Earlier build 10 passed 18 signed installed-host browser checks
and both candidate credential modes; those reports remain historical. Brave connection is enabled on Tom's machine under his explicit approval.
See [BROWSER_INTEGRATION.md](BROWSER_INTEGRATION.md) for exact evidence and remaining limits.

### Username and password fields

**Settings → Allow input in username and password fields** is **off by default**.
Only clearly identified username/password fields are subject to this field-level block;
ordinary text fields, typing and clicks remain available. The setting applies to native
apps and Brave, requires explicit confirmation, and changing it cancels the current
task. It permits input, not retrieval of saved passwords. Credential field values remain
omitted from text snapshots even when enabled; screenshots can still contain visible
information. Anything supplied to the agent can reach the selected model/provider.

macOS **Secure Keyboard Entry is not disabled or used as a blanket stop**. A password
field's keyboard protection no longer blocks a Like click elsewhere. The field-level
refusal is `credential_input_blocked` and points to this pi-os setting. It does not
relax file-deletion, ownership, target or focus safeguards.

## Permissions and signing

Launch never requests Screen Recording, Accessibility, Input Monitoring, Microphone or
Speech Recognition. Microphone and Speech Recognition are requested only from the buttons
in Settings → Voice (Info.plist carries both usage strings; signed builds add the
`audio-input` entitlement).
Select **π → Permissions… → Allow Screen Recording** explicitly. macOS may require
a quit/relaunch after granting access. **Enable Computer Control…** explicitly
requests Accessibility; input-posting permission is checked separately. Control
requires a valid certificate-signed `.app`, both grants, and the Settings toggle.
Ad-hoc builds and explicit read-only mode never advertise native input tools.
Focused AX metadata is collected before the panel with a 25 ms budget; unavailable
or secure values are omitted. Refresh queries stay scoped to the pinned AX window.

The stable bundle identifier is `dev.pi-os.mac`. For TCC testing across builds,
configure a stable code-signing identity first:

```sh
security find-identity -v -p codesigning
PI_OS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" host-macos/scripts/build-app.sh
open host-macos/build/pi-os.app
```

If a new Apple Development identity appears under “Matching identities” but not
“Valid identities”, check its issuer chain. A 2026-09-21 installation was missing
Apple's WWDR G3 intermediate. Use the official Apple intermediate, verify it against
the built-in Apple root, and import it without any trust override—do not mark a new
root/certificate “Always Trust” to force signing through.

Without an identity, `build-app.sh` produces an explicitly warned **ad-hoc UI-only
build**. Its default designated requirement is the executable's cdhash, which
changes on rebuild. It is not a stable identity for permission-bearing updates.
Use the separate UI preview executable when no certificate is configured.
A shell-launched app may inherit its terminal's permissions; use `open` for TCC QA.

### Repeated Screen Recording prompts after an update

This was confirmed on 2026-09-15: TCC retained the earlier executable's code
requirement after an ad-hoc refresh. Its logs reported **“Failed to match existing
code requirement”**. Toggling the checkbox and restarting did not replace that
stale requirement. The request failed before reaching the agent.

For this specific failure, quit pi-os completely, then reset **only this app's
Screen Recording grant**:

```sh
tccutil reset ScreenCapture dev.pi-os.mac
open "$HOME/Applications/pi-os.app"
```

Choose **π → Permissions… → Allow Screen Recording** and approve the current app.
Quit/reopen once more if macOS requests it. Do not rebuild or re-sign the app
between the reset and approval. This does not grant access automatically, reset
other apps, or require resetting Accessibility/Input Monitoring.

For subsequent updates, use the same stable signing certificate. Do not weaken
the code requirement to an identifier-only rule or modify the TCC database.

## Refresh the installed preview

Quit the existing pi-os from its menu, then:

```sh
host-macos/scripts/refresh-install.sh
open "$HOME/Applications/pi-os.app"
```

This refreshes `~/Applications/pi-os.app` (override `PI_OS_INSTALL_PATH`). The
installer now **refuses ad-hoc installs by default**, before touching the current
app. Set `PI_OS_SIGN_IDENTITY` to a stable code-signing certificate. Only an
explicitly approved disposable test may opt out with `PI_OS_ALLOW_ADHOC_INSTALL=1`;
that can require the scoped repair above and is not a routine update workflow.
Scripts refuse to overwrite a running executable and **never kill another application**.
They stage complete bundles instead of merging old/new files. An incompatible code
requirement is blocked; a deliberate one-time migration requires
`PI_OS_ALLOW_SIGNING_CHANGE=1` and a scoped Screen Recording repair afterward.
The default development build still references this checkout's Node harness.
After Swift changes, rebuild/refresh; repo builds do not update installed binaries.
The Windows stable install is separate and still uses `refresh-install.ps1` on Windows.

## Self-contained packaging (release gate)

With a stable certificate and an official standalone Node binary:

```sh
PI_OS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
PI_OS_BUNDLE_RUNTIME=1 \
PI_OS_BUNDLED_NODE_PATH="/absolute/path/to/official-node/bin/node" \
host-macos/scripts/build-app.sh
```

The bundle then includes Node, the built harness and locked production dependencies.
Native modules are signed; Node receives its JIT entitlement. The official Node
LICENSE is included (`PI_OS_NODE_LICENSE_PATH` overrides its default location).
A signed-runtime SDK-import smoke runs with live provider access blocked. Homebrew Node with
external `@rpath`/Homebrew libraries is rejected rather than copied into a broken app.
No credentials, model settings or captures are bundled. This packaging path has not
been exercised with a certificate here. For a **Developer ID** self-contained build,
`PI_OS_NOTARY_PROFILE=<explicit-keychain-profile> host-macos/scripts/notarize-app.sh`
submits to Apple, staples/validates the ticket, assesses the app, and publishes a fresh
ZIP + SHA-256 only after acceptance. Apple Development/ad-hoc builds and linked dev
bundles are rejected. No upload has been performed here. Fresh-machine validation
remains a release gate; a successful build alone is not a distribution claim.

## Configuration

| Environment variable | Meaning |
|---|---|
| `PI_OS_HOTKEY` | Chord override; e.g. `Ctrl+Shift+F9`. Exclusive Carbon registration and known system-shortcut conflict diagnostics. Unknown third-party shortcut precedence still requires manual testing. |
| `PI_OS_NODE_PATH` | Explicit absolute Node executable path; overrides bundled/build-time configuration. |
| `PI_OS_NODE_ENTRY` | Explicit absolute built `node-harness/dist/index.js`. |
| `PI_OS_NODE_WARM_TTL_SECONDS` | One-shot warm retention after result/normal cancellation; default 120 (600 while push-to-talk is on), range 0–3600; an explicit value always wins. With voice off, prompt cancellation stops an unused child immediately; with voice on it keeps the TTL. |
| `PI_OS_HOST_PORT` / `PI_OS_NODE_PORT` | Loopback ports; defaults 17831 / 17832. |
| `PI_OS_TOKEN` | Optional explicit shared token for testing; normally 32 random bytes generated by the host. Never printed. |
| `PI_OS_SUPPORT_DIR` | Default `~/Library/Application Support/pi-os`. Contains a lock, private agent cwd, captures, logs, and Node-owned settings. |
| `PI_OS_CAPTURES_DIR` | Shared PNG directory override; passed explicitly to the child. |
| `PI_OS_INVOKE_TIMEOUT_MS` | Existing Node request timeout (300000; 0 disables). |
| `PI_OS_ECHO=1` | TCC-free prompt/echo UI probe: **no capture and no Node**. |
| `PI_OS_AGENT=0` | Real pinned screenshot + host/harness round trip, but **no model call**. |
| `PI_OS_READ_ONLY=1` | Explicitly suppress computer control, even with grants. |
| `PI_OS_PERF=1` | Diagnostic timings without prompt/title/image content: panel ordering, visible-occlusion proxy, SCK enumeration/capture and actual image dimensions. |

For environment-based probes, use `host-macos/scripts/run-dev.sh`; remember its
shell-inherited TCC caveat. Normal bundle launches use the build-time development paths.

Every Mac invocation negotiates the native host catalog. It gets the three observation
tools plus `desktop_act` only when the host can authorize control (browser-bound
tasks use `browser_snapshot` / `browser_act` instead). Default **pinned-only**
mode excludes global extensions and coding tools, even when native input is available.
This is a tool capability boundary, **not an OS sandbox**. Built-in providers,
`models.json`, authentication and model settings remain available.

**Settings → Use trusted global pi extensions and coding tools** restores the global
pi resource behavior explicitly. It requires native control grants and a warning
confirmation: these tools and arbitrary extension code are **not confined to the
pinned window** and can read/write files or run commands. The prompt displays “Trusted
pi” while active. The setting is stored in `resources.json` and applies to new tasks;
read-only/control-denied invocations suppress it. Mac project extensions/context files
are still not trusted; the agent cwd never comes from the target's folder. Providers
registered by trusted extension factories become available to model selection. No
user setting was changed automatically by the port. Windows behavior remains global
by default.

Mouse coordinates are pixels in the exact last image delivered to the model. The
extension privately binds its image ID; metadata-only refresh cannot authorize a
click on an unseen image. Host captures stay below common downstream resize limits
(1280 long edge, 1 MP). Resizes, wrong focus, unavailable permissions and exhausted
budgets fail closed. Identified username/password fields are blocked unless the
credential-input setting is explicitly enabled. Normal apps (including Orca, browsers and terminals) are not blocked
by brand. Recognized file-deletion controls, file-removal shortcuts and explicit
terminal deletion commands are rejected; normal text editing remains available.
The agent is instructed to finish authorized ordinary actions, including an explicitly
requested Like, rather than treating every final click as forbidden.

**Limit:** this is not a guaranteed no-delete filesystem sandbox. Arbitrary scripts,
shell aliases, opaque controls and trusted extensions can have effects that AX labels
and command-pattern checks cannot prove. Do not mistake prompt guidance or these
checks for OS-level prevention of every possible file deletion. Uncertain input poisons further input
for that context but leaves observation available. Traces in `logs/host-actions.jsonl`
contain action/outcome/counts, never typed text, key values, titles or context tokens.

## Finder desktop context

A Finder desktop invocation can pin the actual Finder-owned CG desktop surface and
read a uniquely matched AX desktop container. Selection is explicit and bounded:
`null` means unavailable, `[]` means checked and empty, and truncation preserves the
complete selection count. No directory listing is substituted for selection.
Desktop input must prove the exact focused desktop recipient and point ownership;
unsupported/ambiguous AX profiles fail closed. Finder may expose one AX desktop
container across several displays; only the explicit CG desktop union is accepted,
and keyboard selection must still be confined to the pinned display. Capture uses
the specific SCK window, never a silent whole-display fallback. Read-only metadata
inspection confirmed this shared-container shape on this Mac; actual capture/input
and the full mixed-display matrix remain acceptance gates.

## UI preview (no agent or permissions)

The separate preview executable uses disposable content and does not bind ports,
capture your desktop, register a hotkey, or start Node. It is not installed in the app.

```sh
swift run --package-path host-macos pi-os-ui-preview prompt --light
swift run --package-path host-macos pi-os-ui-preview multiline --dark
swift run --package-path host-macos pi-os-ui-preview answer --dark
swift run --package-path host-macos pi-os-ui-preview settings --light
swift run --package-path host-macos pi-os-ui-preview listening --dark   # scripted FakeVoiceInput, no microphone
# Also: draft, working, short, long, error, failed, instant-calc, instant-files, instant-answer,
# instant-list, card, streaming, confirmation, voice-denied, auto-settings, voice-settings,
# classifier-settings. Settings use a mock catalog and a scripted voice service (no TCC).
```

**Offscreen snapshots** render every new state into PNGs without ever showing a window,
taking focus or adding a Dock icon (System/Frost/Contrast/Graphite × light/dark, plus a
contact sheet per variant):

```sh
swift build --package-path host-macos && \
  host-macos/.build/debug/pi-os-ui-preview --snapshot /tmp/pi-os-shots [--states listening,card]
```

Native glass/vibrancy exists only in the window server, so snapshots paint an
approximated material behind the real view tree; judge layout, type and contrast there,
and glass refraction only on a real window.

Typing and submitting in the preview shows a simulated working state and sample
answer. Permission actions are simulated there, never system permission requests.
See [UI_NOTES.md](UI_NOTES.md) for polish choices and verification limits.

The app icon reuses the Windows cyan pulse mark in a native macOS tile. Its source
is `scripts/make-icon.swift`; `Resources/AppIcon.icns` is checked in, so nothing
compiles or generates icons at runtime.

## Tests

```sh
npm --prefix node-harness run check
npm --prefix node-harness test
npm --prefix node-harness run build
PI_OFFLINE=1 PI_OS_AGENT=0 swift test --jobs 2 --package-path host-macos
npm --prefix node-harness run test:macos
```

The explicit Mac conformance suite requires macOS and a built host; it fails rather
than silently skipping. It uses real NWListener + Node fetch/HostClient, a real PNG,
and the real supervised Node entry, with no LLM call or TCC grant. Swift lifecycle
tests launch only their own Node processes and assert process-group identity,
lazy startup, warm reuse, TTL teardown, restart, and unexpected exit reporting.

`npm test` runs serially with a no-live-provider bootstrap. It blocks Ollama/provider
fetches before SDK imports; Swift lifecycle children use the same guard. During the
_LOCAL_AI benchmark, also skip the transient UI test:

```sh
PI_OFFLINE=1 PI_OS_AGENT=0 swift test --jobs 2 --package-path host-macos \
  --skip PresentationTests/testLastAnswerSurvivesDismissalNewPromptAndError
```

The optional `scripts/test-native.py` requires an explicitly coordinated
`PI_OS_NATIVE_TEST=1` run. It raises and types/clicks only inside its disposable
fixture app. It uses existing terminal AX/Screen Recording grants, stops on external
input, and is **not** proof of installed TCC identity or the full app/display matrix.
Do not run live UI/inference probes during the coordinated local benchmark window.

### Installed-host permission/input test

On a coordinated idle desktop, `PI_OS_INSTALLED_TEST=1 python3 host-macos/scripts/test-installed.py`
launches a separate instance of the **installed signed app through LaunchServices**,
with private ports/support directory and a Node stub that cannot invoke a model. It
uses the real hotkey, capture, authenticated input routes and result UI against the
owned receiving fixture. It never replaces the normal running host or changes its
settings. `PI_OS_TEST_APP` can target a signed staged candidate before publishing.

The fixture checks delivered text, file save, click/scroll effects and refusals—not
just successful post calls. It stops on external input. The script requires the Orca
semantic accessibility CLI and no AI grounding. The optional point diagnostic prints
only numeric window/focus metadata, not titles or text. Build 6 passed on macOS 27;
see `qa/installed-host-macos27.json` for the result.

For idle memory use **physical footprint**, not RSS:

```sh
# Resolve and verify the exact pi-os PID first:
lsof -nP -iTCP:17831 -sTCP:LISTEN
footprint -p <verified-pi-os-pid> -f bytes
ps -p <verified-pi-os-pid> -o pid,%cpu,rss
```

No polling or recurring timer runs at ordinary idle. Active requests have bounded
read/write/capture deadlines; the Node retention timeout is one-shot. Model work
has the existing configurable invocation timeout. Panel status streams (SSE, falling
back to polling) only while an invocation is active.
