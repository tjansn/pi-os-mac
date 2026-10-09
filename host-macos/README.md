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
off, or on macOS 14–25, the hotkey behaves exactly as before, except that while voice is
off (and could run) a real hold shows “Voice is off — turn it on in Settings → Voice” in the
empty bar, at most three times and never again once voice was turned on. The status menu
has **Turn On Hold to Talk…** (or **Voice…**) next to Settings. A spoken “never mind”,
“cancel”, “stop” or “vergiss es” as the whole utterance ends the take without an agent run.

Voice needs **Microphone** and **Speech Recognition**. pi-os asks for them only from the
**Request Access…** buttons in Settings → Voice; the hotkey never shows a permission prompt.
If a grant is missing, a hold explains what to do and offers **Open Voice Settings…**.
The German speech model downloads only from that page's **Download** button. While voice is
on, the warm Node child stays ready for 600 s after use (instead of 120 s) so a hold rarely
waits for a cold start; an explicit `PI_OS_NODE_WARM_TTL_SECONDS` still wins.

**Instant commands.** Math, units, currencies, number bases, time zones, date math, opening
apps/links, web searches, file search and volume/display sleep are parsed by Node's instant
engine (no model) and **performed by this host** after `LauncherPolicy` (`LauncherService`).
While you type, the bar previews on every keystroke (at most one request per 33 ms, the
last text always sent; Node holds file search back until typing has been quiet for 150 ms):
`= 51`, “Open github.com”, or a file/app list above the bar. Spoken partials preview after
150 ms of quiet. Previews never act and stay on one line: a long number shrinks, then shows
as `≈ 1.27 × 10³⁰` (Return still gives the exact value), and hints keep their key words
(“↩ Sleep display”). VoiceOver hears each preview (“Equals 51”, “3 files… Return opens …”)
and every ↑/↓ selection change, but nothing while you dictate. Typed requests send the Mac's
formatting locale (language + effective Region, e.g. `en-DE` for English with Region
Germany), so `2,5 * 4` and `1.000 + 1` follow your Region's decimal comma.

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
outcome only in `logs/launcher-actions.jsonl`. Archives (zip, xip, tar, gz, rar, 7z…) are
revealed, not opened: Archive Utility can move an expanded archive to the Trash. Instant
commands work with no capturable window (Node warm-up and the window capture are separate;
only agent questions wait for the capture). Currency conversions download the ECB daily
reference rates on first use only; a final question whose answer is only a notice (rates
still downloading, an unknown currency) goes to the agent, as on `/invoke`. A Return that
is still resolving after 120 ms (typically a cold Node start) shows the “…” disc in the send slot.

**Auto model.** Settings lists **Auto (recommended)** first. It is the `pi-os/auto` catalog
entry: Node picks a fast adequate model and effort per request. Its levels appear as
**Prefer speed / Balanced / Prefer quality**; its Model row just says “Chosen per request”.
Any explicit model choice still works. The reader footer names the model Auto chose
(“Auto · gpt-6-luna · …”). To verify routing locally: `grep '\[perf\] stage=agent.response'
~/Library/Application\ Support/pi-os/logs/harness.log` and inspect
`~/Library/Application Support/pi-os/routing-stats.json` (model ids, counts and durations only).

**Codemode.** In full agent sessions (not Auto's light lane) the agent may run short scripts
in pi's QuickJS sandbox. A script can call only read-only tools — window/tab context
(`desktop_get_context`, `desktop_refresh_context`, `browser_snapshot`) and the instant
calculator, currency, time, file search and app list — never input, capture, `open_item` or
another script; it has a 15 s deadline (30 s at most) and bounded output. This is defense in
depth, not a filesystem sandbox: trusted global extensions and coding tools are not confined
by it.

**Streaming and cards.** Agent answers stream into the reader over one long-lived SSE
request (`GET /invocations/{id}/events`, ≤ 30 renders/s); if streaming is unavailable the
host falls back to today's status polling. The streaming reader never takes keyboard focus
from the app you are typing in (click it to scroll or select); its bar keeps the working
capsule's controls: **–** continues in the background, **■** stops the task, and Escape (or
the close button) hides it while the task keeps running. The completed answer takes focus as
before. Agent cards render natively and may only bind copy/open/reveal/ask actions;
recalled cards, and cards whose conversation closed, are read-only. Copy Answer always
copies the agent's original text. Nothing streams over a window the agent is acting in.

**Local classifier (Laya).** Settings → Classifier can turn on the optional local Laya
classifier. It is advisory only (it may ask Auto for a stronger model or a screenshot,
never choose or perform an action), runs on the CPU, needs about 5 GB of memory and ~18 s
to load, and is off by default. Choose its **Python** (a venv's `bin/python` with laya 0.3.5
and CPU torch; hidden `.venv` folders are shown and the venv path is kept) and **Model
folder** (the one containing `rl_agent_config.json`) on that page; both are stored in Node's
`classifier.json`, and the switch is enabled once Laya can start with them. Problems are
explained in plain sentences. `PI_OS_LAYA_PYTHON` / `PI_OS_LAYA_MODEL_DIR` remain a fallback,
but they only reach an app started from Terminal or `run-dev.sh`. Bundled builds ship the
helper script (`Resources/sidecars/laya/laya_intent_sidecar.py`), never a model.

## General by default, the context shelf and pointing

Branch `feat/context-shelf` (2026-10-05), built and tested offline, **not installed**.

**The bar opens general.** Key-down pins only the window's identity (CG window, process
fingerprint at insert, and the focused element, which can only be read before the bar takes
keys). There is no screenshot and no DevTools connection at key-down; the Brave tab pin runs
right after the bar is on screen. The placeholder is *Ask anything…*.

**The context chip** sits left of the send button and shows the frontmost app:

| State | Looks | Means |
|---|---|---|
| off | the app icon in a quiet circle | not included (the agent may still look if you refer to it, unless you excluded it) |
| suggested | icon + name, accent outline | your words refer to the screen (Node rules v2 `scope`, averaged with the on-device scorer; the local score never decides alone) |
| on | icon + name, accent fill | included: Tab/click, ⇧ + hotkey, *Ask About This Window…*, a tether, or *Always include* |

What the chip shows at Return is what `/invoke` carries (`context: {scope, pull, source,
scopeHint}`). An off chip still allows the agent to look (`pull: "allowed"`, the bar then says
*Looking at …*) unless Tab left the window out (tooltip “pi won’t look”, the icon struck
through) or the setting is *Only when I ask*. The window is captured only when the chip first becomes suggested or on (usually
while you are still typing), never for a general question, which never waits for or fails on a
capture. A window question whose capture fails continues without the screenshot and says so.
**Tab** toggles the chip (not while IME text is marked or a typed list owns the keys); a click
does the same; the choice sticks for the take. **⇧ + the hotkey** (⌃⌥⌘⇧Space) opens included,
tap or hold; over an open bar it includes the window. The reader names the app only when the
window was included (or the agent looked: “Looked at Brave”); the follow-up composer carries the
same chip, bound to the thread's window and starting from the record's `included` (on after the
agent looked, off after you narrowed): it widens a general thread only on a strong,
screen-anchored reference (“this page”, a UI verb) and never narrows one by itself. Only the
harness captures for a follow-up. *Settings →
Context → Active window*: *Only when I ask* / *Suggest* (default) / *Always include*. With an
attachment on the shelf, “this”, “the selection” or “this image” mean the attachment and the
window is not suggested; a pointed-at element of the window includes it instead.

**The context shelf** (chips above the composer, in memory only):

- **⌃⌥⌘C “Add to pi”** (second Carbon chord, no Input Monitoring; `PI_OS_ADD_HOTKEY` overrides):
  the frontmost app is taken at the press, before anything of pi-os appears. The selection is
  read through Accessibility (WebKit/Chromium text markers included); when an app does not share
  it (Electron, images), its own **Edit ▸ Copy** runs and the previous clipboard is put back
  byte-identical, unless another app wrote meanwhile or the clipboard holds password-manager,
  concealed or Handoff content (then nothing is touched). *Settings → Context → Use the app's Copy*
  turns that fallback off, and read-only mode never uses it (it is input). The menu bar's *Add
  Selection to pi* runs the same path. A non-activating *Added to pi* note confirms (or says “Nothing
  selected · Grab an area?” with a **Grab Area** button); the bar is not opened.
- **The pi hotkey with text selected** adds it as a removable chip (Accessibility only, never the
  clipboard). It belongs to that question: Escape removes it again. *Settings → Context → Add
  selected text when you open pi*.
- **Drag and drop** onto the bar, the reader or the menu-bar π: files (references; their
  contents are not read, but when the question is sent each gets a launcher token for that
  question's context, so the agent can open or reveal it for you), image files and images
  (re-encoded ≤ 1280 px into pi-os's own PNGs; the user's file is untouched), links (as text,
  never fetched) and text. A drop never activates pi-os. Finder ⌘C and ⌃⌥⌘C in Finder give the
  same file references and images.
- **Grab an Area…** (chip menu or the menu-bar *Add Screen Area to pi…*): the system's
  `screencapture -i` selection (Esc cancels); the bar steps aside meanwhile.
- **Clipboard suggestion:** something copied while pi-os runs shows as a dashed chip; only its
  types are looked at until you click **+**. pi-os's own copies (Copy Answer, copy actions) are
  never suggested.

Click a chip to see exactly what will be sent; **⊗** removes it; **⌫** in an empty composer
removes the last one. Caps: 8 items, 4 images, 20,000 characters per text, 40,000 in total. The
shelf empties after 15 idle minutes, when its question is sent (the PNGs stay until that thread
closes, because Node reads them after `/invoke` returns), or with **Clear Attachments** in the
menu-bar menu, which also shows the count. Attachments are untrusted data in the prompt, never
instructions or click authority, and an image makes Auto pick a vision model.

**Pointing (attention overlay).** Drag the chip (or π) onto any window: a transparent,
non-activating overlay draws a line from the bar (straight under Reduce Motion) and a purple frame
around the window under the pointer; dropping re-pins the question on that window with full
identity (fingerprint, Brave tab pin, ownership checks) and includes it. Hold **⌥** while dragging,
or choose **Point at an Element…** in the chip's menu (or the menu bar; VoiceOver: show menu on the
chip) and click once, to attach one element: an orange frame with its role, then a chip
“⌖ Button “Send”” and “Pointing at …” on your message. An element of the question's window
includes that window (a suggestion that goes with the element chip). An element of another
window makes that window the question's window, unless you included the current one or pointed
at it already: then the element goes with a read-only chip of its own window, so the agent knows
which app it is in. Pointing works on a new question, not in the follow-up composer. Secure and
username/password fields are never read (one field rule for native apps and Brave web content:
names, native and DOM ids, label elements). One actionable window per question; acting
still goes through that window's normal gated tools.

## Text input

Native typing preserves Unicode and normalizes LF/CRLF/CR to single line breaks,
using Return-key pairs and 20 ms stroke spacing. `PI_OS_TYPE_INTERVAL_MS` explicitly
configures pacing (0 disables). Calls whose scheduled pacing exceeds 20 seconds are
refused before input: split large text into smaller sequential calls. No default
clipboard substitution is used. Brave multiline fill uses verified `Input.insertText`
and refuses single-line fields before input. Details and regression boundaries:
[`docs/desktop-input-semantics.md`](../docs/desktop-input-semantics.md).

## Brave access

**Accessibility (default, no prompts).** The hotkey pins Brave's selected tab through macOS
Accessibility: pi reads the page (`browser.page`: title, URL, text, headings, controls; field
values of credential fields are never read) with no “Allow remote debugging?” dialog, no
“controlled by automated test software” banner and no focus change. **Act in Brave in the
background** (default on) presses buttons and fills fields through element-addressed AX actions
(`browser.axAct`) while Brave stays behind your app; every identity, deletion, credential, budget
and uncertain-input check still runs, and native clicks and typing keep their focus checks.
⌘Return types a value into a Brave window like into any other (only a DevTools pin copies instead).
Credential fields are recognized by what Accessibility exposes (a secure field, its name or label
element, its native or DOM id), the same rule for pointing, ⌃⌥⌘C and native typing. Unlike the
DevTools page script, Accessibility does not expose a field's `name` or `autocomplete`
(`username`, `current-password`, `new-password`), so a login field marked only that way is not
recognized on this route.

**DevTools (opt-in).** *Settings → Context → Brave access: DevTools* (or **Brave Access…** in the
menu-bar menu) keeps the old CDP connection: Brave asks for approval on every connection and shows
the automation banner while connected. Build 11's switch is not carried over.

**Switch remote debugging off.** pi no longer needs Brave's *Allow remote debugging for this
browser instance* (brave://inspect/#remote-debugging; *Open brave://inspect…* in Settings opens
it). Switching it off closes Brave's local debugging port; pi-os never changes Brave's settings
itself. See [BROWSER_INTEGRATION.md](BROWSER_INTEGRATION.md) for the routes, limits and the
history of the CDP builds.

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
`build-app.sh` copies the on-device context scorer's weights into `Contents/Resources`
before signing (the app never looks for them outside its bundle; without them the chip
runs on the Node rules only).
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
| `PI_OS_HOTKEY` | Chord override; e.g. `Ctrl+Shift+F9`. Exclusive Carbon registration and known system-shortcut conflict diagnostics (now comparing the symbolic-hotkey plist's NSEvent masks, plus unstored macOS defaults such as ⇧⌘4). Its ⇧ variant is registered too (opens with the window included). Unknown third-party shortcut precedence still requires manual testing. |
| `PI_OS_ADD_HOTKEY` | “Add to pi” chord; default `Ctrl+Option+Cmd+C`. A chord that cannot be registered is reported under Diagnostics and never blocks the main hotkey. |
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
| `PI_OS_PERF=1` | Diagnostic timings without prompt/title/image content: panel ordering, visible-occlusion proxy, the Brave tab pin after the panel (`brave-pin-after-panel`), the lazy window capture (`capture.window`), SCK enumeration/capture and actual image dimensions. |

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
# instant-list, card, streaming, confirmation, voice-denied, voice-unavailable, speech-denied,
# asset-missing, big-1/2/3, instant-unit, hint-web, confirm-hint, voice-hint, auto-settings,
# voice-settings, classifier-settings, context-settings, chip-off, chip-suggested, chip-on, chip-on-draft,
# shelf, shelf-empty-draft, shelf-suggestion, drop-target, reader-general, reader-included,
# reader-pointing, followup-shelf; snapshot-only composites: tether, element, added-toast, nothing-toast.
# Settings use a mock catalog and a scripted voice service (no TCC).
```

**Offscreen snapshots** render every new state into PNGs without ever showing a window,
taking focus or adding a Dock icon (System/Frost/Contrast/Graphite × light/dark, plus a
contact sheet per variant):

```sh
swift build --package-path host-macos && \
  host-macos/.build/debug/pi-os-ui-preview --snapshot /tmp/pi-os-shots [--states listening,card] [--larger]
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
