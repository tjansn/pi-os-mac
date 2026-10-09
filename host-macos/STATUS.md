# macOS port — implementation and acceptance

2026-09-15. Target machine: Apple Silicon, macOS 26.5.2, Xcode 26.6 / Swift 6.3.3,
Node 24.15.0. Deployment target is macOS 14; that OS has not been exercised here.

## 2026-10-02 voice magic — Mac wiring (C2), built and tested offline, NOT installed

Branch `wp/c2-mac` (on `feat/voice-magic`). The Whisper bar/reader are extended, not
replaced: same 480 × 50 pt bar, upward growth, separate reader, presets and no animations.

Built:
- **Hotkey → TalkGesture first.** Carbon press/release drive the B6 gesture before today's
  toggle: hold ≥ 250 ms = voice, tap = today's composer, typing while listening abandons voice
  and keeps the text, a press while the composer is open cancels, a press while working
  reveals. Voice is **off by default**; off (or macOS 14–25) is exactly today's behaviour.
- **Preparation split.** Key-down starts Node warm-up (then `POST /invocations/prepare
  {contextId, takeId}`) and the window capture as separate tasks. Instant commands wait on
  warm only and work with no capturable window; agent submits wait on both, as before.
- **Voice.** One `VoiceInput` for the app's lifetime (mic first at key-down, contextual
  strings = pinned app + window title), cached readiness refreshed at launch, on Settings
  changes and after any voice failure, `prepare(language)` off the hotkey path. Live
  transcript in the bar (finished/tentative ink), 150 ms debounced latest-wins
  `/instant {phase:"partial"}` previews (never acting), release → `finish()` →
  `/instant {phase:"final"}` → act / card / agent (`input:{mode:"voice",locale,durationMs,engine}`,
  `takeId`). Utterances over 500 characters and any instant failure go straight to the agent.
  `microphone_denied` / `speech_denied` / `voice_unavailable` / `voice_asset_missing` show
  “Open Voice Settings…”; nothing on the hotkey path requests a permission.
- **Typing.** Debounced `/instant {phase:"typing"}` previews (`= 51`, hints, a typed result
  list above the bar). Return = instant action or selected result, else the agent;
  ⌥Return = always the agent; ⌘Return = reveal / type the value into the pinned window
  (copy without control); ↑/↓ move the list; ⌘⇧C copies a path only from a focused or
  previewed list, otherwise Copy Answer. `confirm:true` acts need a second Return.
- **Actions and cards.** `LauncherHost.standard()` is wired into `DesktopService`; instant
  acts and card buttons call `LauncherService.perform` directly (after `LauncherPolicy`),
  `typeIntoPinned` goes through `DesktopService.act(.typeText)` (InputPolicy, credential,
  deletion and budget gates), `askAgent` becomes an agent turn (fresh `/invoke` prefixed
  “Earlier quick answer: Q → A” after an instant answer; the thread's follow-up otherwise).
  File tokens are revoked when a context is discarded; launcher actions are logged by kind
  and outcome only (`logs/launcher-actions.jsonl`). One `CardView` lives in the reader;
  agent cards must use only the model action subset or fall back to `responseText`.
- **Streaming.** `GET /invocations/{id}/events` on a second, long-timeout `URLSession`;
  partial text / cards render at ≤ 30 Hz into the reader (never over a window the agent is
  acting in); any stream failure falls back to the existing 250 ms polling; Windows' polling
  contract is untouched.
- **Settings.** General / Voice / Classifier pages. Auto (recommended) first with
  Prefer speed / Balanced / Prefer quality; Voice switch, language, Microphone and Speech
  Recognition rows with explicit Request/Open System Settings buttons, speech model status
  and Download; the Laya switch (advisory, CPU, ~5 GB) bound to `/settings/classifier`.
  Every existing control keeps its behaviour; only loading the model catalog starts Node.
- **Warm TTL** defaults to 600 s while voice is on (explicit `PI_OS_NODE_WARM_TTL_SECONDS` wins).

Verified offline (no microphone, no speech model, no provider, no window shown):
`npm run check`, `npm run build`, guarded `npm test` 324/324, `swift build` 0 warnings,
`PI_OFFLINE=1 PI_OS_AGENT=0 swift test` 227/227 (180 earlier + 47 new: controller flow with
FakeVoiceInput and a scripted harness, final decisions from the shared instant fixtures,
preparation split, SSE parser/client/fallback triggers, settings view model, offscreen render
smoke tests), `npm run test:macos` conformance 1/1. Under XCTest the panel now lays out
without ordering on screen. Offscreen PNGs of every new state (System/Frost/Contrast/Graphite,
light and dark) were rendered by `pi-os-ui-preview --snapshot` and inspected.

Review fixes (same day): typed requests send the Mac locale as a plain language tag
(`en-US`, not `en-US-u-rg-dezzzz`, which the harness rejects with `invalid_arguments` and which
failed every typed `/invoke` whenever Region differs from Language); the 500-character instant
limit counts UTF-16 units like Node; a prepared session is cancelled (`POST /invocations/prepare
{takeId, cancel:true}`) when its take ends without `/invoke`; agent cards whose thread closed are
read-only; an installed speech model is also reserved on a language change. `swift test` 231/231.

Still needs a signed build and a live window (coordinated with the DRACO benchmark owner):
microphone/Speech Recognition TCC on the signed `dev.pi-os.mac`; whether SpeechTranscriber
truly needs Speech Recognition; key-down-to-text latency; Carbon key-up/auto-repeat on real
keyboards; German model download size/UX; Spotlight results in TCC-protected folders for the
signed app; real Codex latency per Auto tier; glass/vibrancy legibility over real wallpapers;
VoiceOver and the physical-keyboard matrix. `CFBundleVersion` is still 12 (Info.plist is not
owned by this package). The installed copy is stale relative to this branch.

## 2026-10-01 Whisper native UI — build 12 installed

Tom selected Whisper from the disposable HTML studies. The production UI is now
native AppKit: a 480 × 50 pt, bottom-centered command bar, one line by default,
growing upward only for multiline input. Answers float on a separate readable
material above the bar, with the same retained-thread composer and explicit close.
Context and appearance sit behind π; trusted compatibility still has a visible
warning in the bar rather than hiding its unconfined authority.

The command surface uses **NSGlassEffectView on macOS 26+**, with a native
NSVisualEffectView fallback on 14/15. System / Clear / Frost / Graphite / Warm /
Contrast presets, larger text, opaque material and 20/32/48 pt lower-edge spacing
are native preferences. System Reduce Transparency/Increase Contrast force opacity;
Reduce Motion stops the spinner. No open/close or keyboard-triggered animations.
Appearance controls do not start the harness or discover providers. Test instances
use separate appearance preference suites; normal credential permission remains off.

Validation: **70 guarded Node / 67 Swift tests and conformance pass** (the older
transient last-answer test remains skipped). The final signed candidate and actual
installed bundle each passed **17 reader/follow-up checks**. An earlier build-12
candidate passed all 33 native checks; a final rerun passed nine, then correctly
refused a click covered by NotificationCenter. That rerun is blocked evidence,
not a full native pass. No system window/process/protection was disabled. The
native controls exercise all presets with injected visual preferences in CPU tests.
Signed screenshots cover the default dark reader/bar; other preset visual and
VoiceOver/physical-keyboard acceptance remains incomplete.

A real fixture caught per-keystroke hiding of the text receiver dropping later
multiline input. Layout now preserves the active scroll view/first responder;
unit and signed multiline follow-up regressions pass. Pinned native/CDP authority,
input budgets, deletion/credential policy and model/resource lifetimes are unchanged.

Build 12 was installed only after verifying the old host idle, with no children or
visible windows, and gracefully stopping its exact executable/PID. The existing
certificate was reused; signature, version, health and candidate/installed SHA-256
match were verified. No TCC reset or ad-hoc install. Evidence: `qa/build12-*.json`
and `qa/build12-whisper-reader-installed.png`. Full parity/distribution gates remain.

## 2026-10-01 follow-ups, reader lifecycle and input contract — build 11 (history)

Reconciled upstream `5fc5123`, `e9437d4`, `e7a3bb6` and `9ddcfd4` for Mac:
retained in-memory SDK conversations with authenticated sequential followup/close,
persistent answer reader with an accessible multiline composer, and native/browser
line-ending fidelity without default clipboard paste. Native input is scalar-safe,
20 ms paced and deadline-preflighted; balanced pairs are not an atomic OS transaction.

Original pinned context/model/resources and cumulative budgets survive turns.
Screenshots/DOM refs do not. New hotkey, explicit close, cancel, timeout, security
changes and quit dispose/revoke; closure/startup races cannot resurrect the thread.
The Node child is reserved while the reader lives, with no idle status polling.
Mac retains one reader at a time, not multiple Windows-style concurrent readers.

Validation: **70 guarded Node / 59 Swift tests**, type check/build and Swift↔Node
conformance passed. The real SDK conversation test uses only an in-memory stream
fixture. Signed native candidate suites passed **33 checks in each credential mode**;
Brave default passed **20**, while the enabled rerun was **transport-blocked before
CDP attachment**. Reader candidate passed 16 and actual installed build passed **17**,
including four turns, simulated follow-up failure/explicit retry, warm-TTL reservation,
Carbon pinning and close/native revocation. All receiving text/credentials were dummy
fixture data; zero live model calls, account actions, clipboard replacements or actual
file deletions. The older transient last-answer presentation test remains skipped.

The installed idle host was verified by exact executable/PID and no child, gracefully
terminated, refreshed with the existing certificate and reopened. Build/signature/health
were verified; candidate and installed native executable SHA-256 match. No TCC reset,
permission weakening or credential preference change. Reader fixture setup initially
stopped on incidental input; its observation now restores fixture A before the shortcut.
No production focus/identity safeguard was relaxed. Evidence: `qa/build11-*.json`.

Pending: live model-driven conversations, enabled Brave connection reacceptance,
framework/slow-editor matrix, other parity/application/display acceptance and
self-contained/notarized distribution. These are component-accepted changes, not a
full Windows-parity declaration. See `PARITY.md` and `docs/desktop-input-semantics.md`.

## 2026-09-22 field-local credential input and Brave, build 10 (history)

Tom clarified that ordinary typing must work too. The OS-wide Secure Keyboard Entry
veto is removed without disabling macOS protection. Native and browser input block
only clearly identified username/password fields by default, with the explicit
**Settings → Allow input in username and password fields** opt-in. It remains off on
Tom's installed app. Values are omitted from text snapshots even when input is enabled;
other fields/clicks remain available after a field-specific refusal. Deletion policy,
identity, ownership, focus, ambiguity and uncertain-input checks remain in place.

59 guarded Node tests, 57 Swift CPU/fixture tests and HTTP/lifecycle conformance pass.
The same-certificate candidate passed 30 native and 18 Brave fixture checks in EACH
credential mode. The installed bundle then passed the 18-check default Brave suite.
Only fixture text, simulated Like/Delete controls and dummy credentials were used;
no model/provider call, real account action or file deletion was performed.
Evidence: `qa/build10-{native,brave}-{default,enabled}.json` and
`qa/build10-installed-brave.json`. The live run also fixed protocol-readiness and
transient navigation/web-area timing, without relaxing native tab identity.

Build 10 was installed under the same certificate after verifying the old host idle.
Health/signature checked; no TCC reset/reapproval. Brave connection is enabled under
the earlier user approval, but credential input remains default-blocked. The Settings
row's light-mode mock layout/AX label/unchecked default were inspected without loading
real providers; the full live confirmation/accessibility matrix remains unverified.
No full Windows/browser parity or filesystem no-delete guarantee is claimed.

## 2026-09-21 Brave integration, build 9 (historical, superseded)

Production first-party CDP integration is implemented in `node-harness/src/browser/`
and the native `BrowserPin` / `BrowserSetup` components. It is opt-in, binds the
selected native tab before the prompt, exposes bounded semantic page tools instead
of native mutation, and retains native permission/identity/secure-input gates.
54 guarded Node tests, 53 CPU/fixture Swift tests and native HTTP/lifecycle conformance
pass. No model call, account action, profile copy or file deletion was used for QA.

The same-certificate signed candidate passed native pin/tool-routing checks, then
correctly refused its first browser snapshot because macOS Secure Keyboard Entry is
active. Its reported owner is UserNotificationCenter; no visible dialog was exposed.
The protection was not bypassed and the process was not stopped. Full live adapter
acceptance is pending; see `qa/brave-integration-build9-blocked.json` and
`BROWSER_INTEGRATION.md`. **Installed native build 8 is now stale for this feature**;
it was deliberately not refreshed before completing the signed-host fixture. The
linked Node harness contains the new code, but build 8 does not produce browser pins
or expose the new setup/guard routes. Do not describe that hotkey path as integrated.

## 2026-09-21 action policy, build 8 (historical)

Tom explicitly requested normal app use, with harmful actions blocked rather than
whole apps. The Mac app-brand denylist is removed (except recursive control of pi-os
itself); existing ownership/focus and secure-field checks remain. The shared prompt
now allows explicitly requested normal final actions such as Like and prohibits file
deletion. Native action guards inspect recognized deletion controls/shortcuts and
obvious terminal deletion commands while preserving ordinary text editing.

33 Node and 49 CPU/fixture Swift tests pass. A signed candidate passed the complete
fixture including a harmless Like toggle and simulated Delete-file control (counter
remained zero). No X account action or actual deletion was performed. One installed
rerun correctly stopped for a real loginwindow overlay; that check was not bypassed.
Build 8 was refreshed under the same signing identity. There is no blanket app block
on Orca, Brave or terminal apps. Opaque scripts/aliases/custom controls/trusted code
remain outside any guaranteed filesystem no-delete boundary; these checks must not
be represented as a sandbox.

## 2026-09-21 installed-host input verification (history)

Build 6 is installed and running under the same Apple Development identity. The user
approved capture/control once; those grants survived the subsequent signed fixes with
no reset. A LaunchServices-launched instance of the installed app passed 25 model-free
checks against a disposable two-window receiver: PNG capture, Unicode typing, named
keys, Command-S, moved-window click, scrolling, stale/unseen image and secure/ambiguous/
closed-target refusals, canary preservation and the result reader. See
`qa/installed-host-macos27.json` and `PARITY.md` for exact scope.

The real test found a macOS 27 main-queue requirement in TIS keyboard-layout lookup
and an occlusion false-positive from WindowServer's cursor. Both are fixed with
regression tests. The existing user instance was only refreshed while idle; all test
instances/receivers were scoped by owned PID. No provider call or resident-model change
was made. The broader application/display matrix remains open.

## 2026-09-21 first signed installation (history)

Apple Development identity is now valid after adding Apple's official WWDR G3
intermediate to the login keychain. Verification used the existing Apple root;
no certificate trust settings were overridden. The signed/hardened build and a
modified/re-signed disposable copy satisfy the same designated requirement.

Build 3 replaced the idle ad-hoc installation using the explicit one-time signing
migration path. Only `ScreenCapture` for `dev.pi-os.mac` was reset, with pi-os stopped.
The installed app validates, serves `/health`, rejects unauthenticated tools with 401,
and has no Node child at idle. Screen Recording and Accessibility approval must come
from the user. 31 Node tests and 40 CPU/fixture Swift tests pass on macOS 27 / Xcode 27;
no Ollama/local-model call or mutating desktop probe was run. This supersedes the
older “no identity / stale installed copy” status below; full live parity QA remains.

## 2026-09-16 continuation

Finder desktop identity/selection and strict desktop focus are now implemented behind
public CG/AX checks, with eight offline policy tests. Trusted global pi compatibility
is implemented as an explicitly acknowledged, Node-owned setting, with isolated mode
still the default. Mock Settings API tests cover persistence, model/effort validation,
read-only suppression, custom provider registration and loader lifetime. Release
scripts now include licenses, guarded SDK smoke and explicit notarization/stapling
stages. A read-only Finder geometry/count probe (no item names, screenshots or input)
found one AX container spanning two CG desktop windows; matching and keyboard scope
were corrected for that real shape. No signing, notarization upload, live provider
call or mutating Finder probe was performed. Current evidence and limitations are in [PARITY.md](PARITY.md).

## Current parity candidate (supersedes the read-only implementation status below)

See [PARITY.md](PARITY.md) for the authoritative capability/acceptance matrix.
The repository now has gated native input, exact-window AX focus, Command/Space,
private viewed-screenshot binding, serialized/cancellable actions, secure/ownership
policy, model settings, background notification/toast handling, login registration
and optional bundled-runtime packaging. Full Windows parity is **not signed off**:
real Finder/native/app/display acceptance QA and distribution gates remain. The installed app is **stale relative to these native changes** and remains
read-only; no ad-hoc overwrite was performed without a signing certificate.

During the _LOCAL_AI benchmark reservation, verification used 25 guarded Node tests,
32 Swift CPU/fixture tests (one transient UI test explicitly skipped), and the native
HTTP conformance test with no model call. Live UI and local-GPU inference probes are
paused; the resident Qwen LaunchAgent was not stopped or altered.

## Read-only slice / UI history

### UI polish follow-up

The working read-only flow now has a native light/dark composer, compact working
capsule, adaptive Markdown reader, copy feedback, last-answer recall, actionable
errors, keyboard/IME handling and a finished menu/app icon. No agent, capture,
authentication or tool capability changed in this UI pass. See [UI_NOTES.md](UI_NOTES.md)
for the before/after review and verification limits.

Build 2 was refreshed into `~/Applications/pi-os.app` and relaunched. Health/auth
checks pass; the idle installed host has no Node child and a sampled physical
footprint of 17,859,520 bytes (~17.0 MiB). The signature is still ad-hoc, not a
claim of stable TCC identity or distribution readiness.

## Screen Recording incident and repair

After the UI refresh, macOS TCC retained the old ad-hoc requirement
`cdhash ac706b3f…`, while the installed executable had `cdhash 22de638a…`.
TCC logs explicitly reported “Failed to match existing code requirement” for
`dev.pi-os.mac` / `kTCCServiceScreenCapture`, including after the user toggled
access and restarted. Agent logs showed startup but no invocation: capture was
correctly failing closed before submission.

The repair stopped only pi-os, ran `tccutil reset ScreenCapture dev.pi-os.mac`,
and reopened the **unchanged** installed binary (SHA-256 verified before/after).
No grant was enabled automatically; fresh user approval for this build is required.
No other app's permissions were reset. No certificate was installed and no TCC
code requirement was weakened.

`refresh-install.sh` now refuses implicit ad-hoc installation before touching the
installed app. A stable signing identity is required for normal updates; any
throwaway ad-hoc override requires explicit consent. A regression test covers
this guard and preservation of the existing executable. There was no native
runtime change in this repair, so rebuilding/reinstalling would be counterproductive.
Capture after fresh approval still needs user verification.

## Scope and plan interpretation

The normative architecture in `MACOS_MIGRATION.md` is retained: Swift/AppKit host,
existing Node SDK harness, authenticated loopback APIs, lazy child with 120-second
warm TTL. The later review's proposed RPC replacement is **not** silently adopted.

The initial slice was an **experimental M1–M3 implementation, not an accepted release**. Some M0
signed/hardware gates are still blocked, so scaffolding and deterministic tests
must not be mistaken for passing the plan's go/no-go review. At that checkpoint, no computer-use input was implemented on Mac; the current
candidate and outstanding acceptance gates are now described in `PARITY.md`. Model UI, Finder selection metadata, notifications, signing,
notarization, bundled runtime and login launch remain planned/deferred, not removed
from the eventual parity scope.

## Implemented

- Native LSUIElement menu-bar app and pre-created nonactivating panel: multiline
  prompt, compact cancellable working capsule, formatted/selectable/copyable reader. No SwiftUI, Electron, webview
  or third-party Swift packages.
- Exclusive Carbon hotkey; table-based F-key parsing; known Apple shortcut conflict
  warning. Provisional default Ctrl+Option+Cmd+Space avoids the documented input-source
  conflict with Ctrl+Option+Space.
- `flock` single-instance gate, explicit port errors, bounded loopback-only NWListener
  HTTP/1.1 server. Header/body limits, deadlines, connection cap, no chunked requests
  or keepalive. Both directions authenticate all non-health routes.
- Pre-panel CG window ID/PID pin, cursor, CG-point monitor geometry and one AppKit
  coordinate flip. Null target fails with `no_target`, never substitutes another window.
- Explicit SCK window filter, point-sized output, actual-dimension private transform,
  resize/movement race retry, bounded callback deadlines, cancellation and real PNGs.
  Context TTL/size eviction is lazy; managed captures are removed on context disposal
  and orderly application shutdown. Crashes may leave PNGs in the captures directory.
- Direct posix_spawn, atomic child process-group creation, held stdin EOF supervision,
  termination backstop, cold start while typing, terminal-only warm retention, active-only
  polling, submit/cancel/result handling. Node spawn identity checked during readiness.
- Darwin paths, realpath PNG containment, strict local auth, immutable read-only Mac
  tool allowlist, untrusted project resources excluded, startup-abort race handling.
- Windows auth asymmetry fixed by passing the actual supervisor token into the host
  API; split-development token choice is now explicit. Windows UI/input untouched.

## Verified in this session

- Swift: 21 tests passing, including seven presentation/interaction tests and ~900 coordinate cases across 0.5×/1×/2× image
  scales and negative/mixed display origins, Codable golden fixtures, malformed/
  fragmented HTTP framing, auth, lock, TTL, callback deadlines, and real Node lifecycle.
- Node: 20 tests passing, including the ad-hoc install guard, existing Windows resource/tool behavior and
  Mac exact active/registered tool-set equality with a planted project extension.
- Explicit Swift ↔ Node conformance suite passing: all three host tool routes,
  real PNG ingestion, missing/wrong/correct tokens, invalid JSON, body bounds, unknown
  routes, disconnect/connection close, deterministic invocation and stdin-EOF exit.
- Release `.app` builds and verifies with an **ad-hoc development signature**.
  Refreshed and launched `~/Applications/pi-os.app` via `open -g`; `/health` responds,
  unauthenticated `/tools` returns 401, and the installed host has no Node child at idle.
- Live desktop smoke over a disposable TextEdit document: hotkey pins TextEdit,
  asynchronous SCK screenshot excludes the overlapping pi-os panel, real harness
  callback recaptures it, reader shows `[slice] round-trip capture ok (PI_OS_AGENT=0)`.
- Native echo reader retains Unicode (`ü`, `⌘`, Japanese). This automation used AX
  text replacement and restored-window Return delivery; it does **not** establish
  natural typing semantics in every nonactivating/full-screen configuration.
- After a two-second test retention TTL, the live host had no child Node process.

## Measurements (samples, not acceptance guarantees)

- Full Node entry: **423–444 ms** cold-start-to-listening across two probes; native
  supervisor readiness including health probing: **523–632 ms**. These are different
  measurement boundaries, not a latency distribution.
- Supervised Node stdin-EOF shutdown: **5.8 ms** in the conformance probe.
- Installed host idle physical footprint: **17,646,528 bytes (~16.8 MiB)**, zero Node
  children, sampled CPU **0.0%**. Native `.app` is 884 KB, excluding the external Node
  runtime and checkout-linked harness/dependencies.
- Live host physical footprint after first capture: **22,365,120 bytes (~21.3 MiB)**;
  RSS ~95 MB. Sampled CPU **0.0%**. No sustained idle CPU run has been performed.
- Initial cold prompt: **62.0 ms** to visible-occlusion proxy, **25.0 ms** to panel
  order, frontmost app preserved at the ordering boundary.
- After adding TCC-free backing-store/field-editor prewarming without taking key
  status: first-show sample **47.7 ms** visible proxy / **21.8 ms** ordering,
  frontmost preserved. **One sample, not p95**; the automated repeat attempt was
  interrupted by the desktop automation focus guard. No p95 claim is made.
- Retina fixture window produced an exact 673×439-point PNG at 673×439 pixels.
  Visual legibility and occlusion passed for this fixture only.

## Blocking / remaining acceptance work

1. **Signing/TCC:** `security find-identity -v -p codesigning` returned zero identities.
   Obtain a stable development identity; verify grants survive rebuild/reinstall and
   test launch via Finder/`open` without inheriting terminal permissions. Do not infer
   consent stability from the shell-launched smoke test.
2. **M0 UI matrix:** natural prompt keystrokes, activation/focus, Escape, first-show
   p95 over repeated runs, full-screen Spaces, Stage Manager; Chromium/Electron and a
   non-native app. Dark/light and long-answer preview inspection is complete;
   full VoiceOver and physical focus/click-away matrix coverage remain.
3. **M0 capture matrix:** real 1×/mixed displays; moved/resized/minimized/closed/off-Space
   targets; display topology changes; screen permission denied/granted/relaunch-required;
   resize race and capture-latency distribution. Automated transforms alone are not
   physical-display round-trip proof.
4. **AX:** deliberately omitted rather than read after the panel has become key.
   If restoring focused-element metadata, use the plan's bounded pre-panel fallback
   and validate Chromium AX activation without delaying the prompt beyond budget.
5. **Agent acceptance:** real model/provider end-to-end request not executed; deterministic
   mode proves transport/capture/lifecycle only. Verify provider failures, active cancellation,
   timeout and model-settings persistence with real credentials on the installed bundle.
6. **Windows:** new C# auth tests are present, but .NET/WPF tests could not run on this Mac
   (no .NET SDK / Windows desktop). Run them on Windows before shipping the shared fix.
   Windows installed copy has **not** been refreshed; `refresh-install.ps1` requires Windows.
7. **M4 remains blocked:** public exact-window focus/AX match, secure-field policy,
   permission and identity refusal, image-space model resizing contract, zero-event
   assertions, keyboard-layout mapping. No CGEvent input code is authorized by this preview.
8. **M5:** bundled/signed compatible Node and native dependencies, notarization, login
   launch, fresh-machine permission flow, macOS 14/current/non-US keyboard QA.
9. `npm ci` reported 3 existing dependency advisories (1 moderate, 2 high). No dependency
   upgrade or `audit fix --force` was performed as part of this behavior-preserving port.
