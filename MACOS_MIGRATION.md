# pi-os macOS Migration Plan

Implementation evidence and outstanding acceptance gates: [`host-macos/STATUS.md`](host-macos/STATUS.md).
The certificate-signed control/settings candidate is now installed (build 8, 2026-09-21).
Fresh user permissions and remaining acceptance gates are tracked in [`host-macos/PARITY.md`](host-macos/PARITY.md);
implementation is not full-parity or M0/M4 acceptance sign-off.

User policy clarification (2026-09-21): ordinary apps are not blocked by brand and
explicitly requested normal actions are completed; file deletion is prohibited.
Action-level safeguards replace the earlier blanket app/final-action restrictions.
Opaque code is not a filesystem sandbox; see `host-macos/PARITY.md` for limitations.

Working execution plan for porting pi-os to macOS. This revision supersedes the original
439-line analysis. It incorporates the independent architecture review and two xhigh follow-up
rounds in the originating Claude Fable session (`b27e47e5-b51e-4d06-aa83-c00e4396639b`, workflow
`wf_603a0fd5-d31`).

The earlier statement that the first draft was "all verified clean" was incorrect. Its completeness
critic returned `verdict: complete` while still reporting factual errors and gaps. Those findings are
resolved here. Future review automation must trigger revision whenever `gaps` or `factErrors` is
non-empty, regardless of the verdict label.

---

## 1. Decision

Build **one dependency-free native Swift/AppKit host in `host-macos/`** and retain the existing
TypeScript `node-harness` as the intelligence layer.

The resident Mac process owns only platform primitives:

- Carbon global hotkey
- nonactivating AppKit prompt/pill/reader panel
- pinned window identity and context store
- ScreenCaptureKit screenshots
- Accessibility (AX) metadata
- future CGEvent input synthesis and policy enforcement
- the localhost host API
- lazy supervision of `node-harness`

The first useful Mac release is deliberately **read-only**: hotkey → prompt → pinned context and
screenshot → pi agent → answer. Computer-use parity follows only after the coordinate and exact-window
focus spikes pass.

### Why this architecture

- It preserves the existing native-host/Node boundary.
- AppKit provides the required nonactivating `NSPanel` behavior directly.
- The native host can remain small, event-driven, and low-memory.
- `node-harness` already treats `contextId` and `hwnd` as opaque strings.
- It avoids .NET/Avalonia runtime and UI overhead while also avoiding a latency-sensitive Node-root
  topology.

### Explicitly rejected for this port

- Avalonia/.NET host plus Swift shim
- Node as the long-lived root process
- SwiftUI for the small resident UI
- third-party Swift HTTP/UI dependencies
- private `_AXUIElementGetWindow` SPI
- an always-running Node process

Minimum target: **macOS 14**, required for `SCScreenshotManager.captureImage`.

---

## 2. Success criteria and resource budgets

The budgets are measurement targets, not guarantees. M0 establishes baselines on the target Macs.

| Metric | Target |
|---|---:|
| Node processes at ordinary idle | **0** |
| Host idle CPU | **≤ 0.1%** |
| Host idle physical footprint | **≤ 35 MB target** |
| Hotkey to first visible prompt frame, p95 | **≤ 50 ms** |
| Idle periodic timers/polling | **none** |
| Screenshot/input mapping | exact on 1×, 2×, and mixed-display fixtures |
| Wrong-window input | fail closed; zero events posted |

Additional acceptance rules:

- ScreenCaptureKit and AX work never block the hotkey-to-panel path.
- Node starts while the user types and exits after a short configurable idle period.
- The host uses public macOS APIs only.
- Port bind failures and permission failures are visible, typed failures—not silent degradation.
- The Windows host continues shipping unchanged except for small shared security/protocol fixes that
  are independently tested.

---

## 3. Lean runtime architecture

```text
pi-os.app (signed LSUIElement AppKit application)
│
├─ main thread
│  ├─ NSStatusItem
│  ├─ pre-created nonactivating NSPanel
│  ├─ Carbon hotkey handler
│  └─ application lifecycle
│
├─ desktop serial queue
│  ├─ CG/SCWindow identity and geometry
│  ├─ ScreenCaptureKit one-frame capture
│  ├─ bounded AX reads
│  └─ future focus/input/policy gate
│
├─ loopback transport
│  ├─ NWListener host API on 127.0.0.1:17831
│  └─ URLSession client to node-harness on 127.0.0.1:17832
│
└─ lazy child process
   └─ bundled or explicitly configured Node → node-harness
```

### Resident host rules

- Pure AppKit; no SwiftUI.
- No new Swift package dependencies.
- Pre-create the prompt panel, but **do not** enumerate `SCShareableContent` at launch. SCK enumeration
  may be expensive and may trigger Screen Recording consent.
- No periodic idle work. A single one-shot Node-retention timer is allowed only while Node is warm
  after an invocation.
- Poll invocation status only while an invocation is active.
- Use a nonblocking `flock` on an Application Support lockfile as the authoritative single-instance
  gate. A port-bind failure reports "port occupied or startup fault" and does not assume another
  pi-os instance.

### Local HTTP implementation

Use a small, bounded HTTP/1.1 implementation over `NWListener`:

- bind only `127.0.0.1`
- support only the required methods/routes
- require and validate `Content-Length`
- reject `Transfer-Encoding: chunked`
- cap headers and body size
- apply read/write timeouts
- return `Connection: close`
- propagate request cancellation where practical

M0 must prove compatibility with Node's current `fetch` implementation before this choice is locked.
If the parser cannot remain small and robust, reconsider a narrowly scoped library; do not grow an
ad hoc general HTTP server.

---

## 4. Hotkey-to-answer event sequence

1. Carbon delivers the configured hotkey.
2. On the main thread, synchronously pin only cheap identity:
   - `NSWorkspace.frontmostApplication.processIdentifier`
   - the frontmost normal layer-0 `CGWindowID` for that PID
   - one cursor sample
   - current display geometry
3. Mint a `contextId` and store the pinned `CGWindowID + PID` identity.
4. Show the already-created nonactivating prompt panel immediately.
5. In parallel:
   - enumerate the pinned `SCWindow`, re-read its frame, and capture it with SCK;
   - read focused AX metadata with a strict messaging timeout;
   - spawn/warm `node-harness` if it is not already running.
6. If the user cancels, cancel outstanding capture work and terminate a newly started, unused Node
   child rather than waiting for the normal warm TTL.
7. On submit, await capture/context completion. If capture failed, show a typed error and do not send
   a context that claims to contain a screenshot.
8. Put the panel in a simple pill state and `POST /invoke`.
9. Poll only this invocation while it is active.
10. Show the result in the reader, or show cancel/failure state.
11. Keep Node warm for a configurable TTL—initially **120 seconds** after terminal/cancel—then stop it
    if no new invocation started.

The semantic invariant changes from "the entire snapshot was captured before the overlay existed" to:

> **Target identity and cursor are pinned before the overlay appears. Rich context is then captured
> explicitly against that pinned target without activating or capturing the pi-os panel.**

M0 must verify that the nonactivating panel preserves focused-element semantics in Chromium/Electron,
AppKit, and at least one non-native application. If it does not, capture the focused element before
showing the panel with a strict timeout, or omit it from the read-only slice rather than delaying the
prompt indefinitely.

---

## 5. Normative identity and coordinate contracts

These are safety invariants, not implementation suggestions.

### 5.1 Window identity

- Canonical identity is `CGWindowID + owner PID`.
- Encode `CGWindowID` as the existing opaque `hwnd` string, e.g. `"0x1234"`.
- Revalidate both values before every future mutating action.
- Never use `_AXUIElementGetWindow` or another private bridge.
- `CGWindowID` non-reuse is not treated as a guarantee; the PID check remains load-bearing.
- A closed window is `target_gone`.
- A minimized or off-Space window that still exists but cannot be captured is `capture_failed`, not
  `target_gone`.

### 5.2 Geometry

All wire geometry uses **CG global top-left points**:

- `WindowContext.bounds`
- `ScreenshotRef.bounds`
- monitor bounds/work areas
- cursor position
- AX element bounds

AppKit's bottom-left coordinate system is confined to one tested panel-placement boundary.

### 5.3 Screenshot coordinates

Tool coordinates are **pixels in the latest screenshot**, not "physical screen pixels."

For a window capture:

1. Re-read `SCWindow.frame`.
2. Configure SCK output width/height to the rounded frame size in points.
3. Enable scaling-to-fit and ignore single-window shadows so image content aligns with the frame.
4. Capture.
5. Verify returned dimensions and aspect ratio.
6. Retry once if the frame changed during configuration/capture.
7. Store the actual image dimensions and captured frame in a private transform keyed by `contextId`.

```text
scaleX = capturedFrame.width  / actualImageWidth
scaleY = capturedFrame.height / actualImageHeight

screenX = currentWindowOrigin.x + screenshotX * scaleX
screenY = currentWindowOrigin.y + screenshotY * scaleY
```

The 1-image-pixel-per-point output is a resource and simplicity target, not an assumed equality.
The transform always uses the actual returned dimensions.

`ScreenshotRef.bounds` carries the captured frame, so no `shotScale` wire field is required. The
optional `dpi` field remains in the shared schema for Windows but is omitted by the Mac host; no Mac
placement or input math may depend on it.

At future action time:

- pure window movement is allowed: use the current origin;
- size/content-frame change since the latest screenshot returns `capture_stale` before posting input;
- the agent may recapture after `capture_stale` because no mutation occurred;
- identity loss returns `target_gone`.

### 5.4 Exact-window focus for computer use

The read-only release does not focus or raise target windows.

When computer use lands:

1. Revalidate `CGWindowID + PID`.
2. Activate the owner application.
3. Verify that the exact pinned `CGWindowID` is its frontmost normal window.
4. If not, match AX windows using public PID + bounds + title data and require one unambiguous match.
5. Raise that AX window and verify the exact pinned CG window again.
6. If any step is ambiguous or fails, return `focus_failed` and post no input.

"The application is frontmost" is never sufficient evidence that the pinned window is frontmost.

---

## 6. Permissions, security, and process lifetime

### TCC and consent

| Capability | Check/request | Needed when |
|---|---|---|
| AX metadata and window raise | `AXIsProcessTrustedWithOptions` | M2/M4 |
| Screenshots | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` | M2 |
| CGEvent synthesis | `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` | M4 |
| Input Monitoring | **not required** | never for the chosen hotkey/input path |
| Finder Apple Events | deferred | post-parity only |
| Notifications | deferred | post-slice only |

Permission prompts occur only from an explicit onboarding/permissions action, not from launch-time
warming. Use a stable bundle identifier and stable development signing identity from the first TCC
build. Add a documented `tccutil reset` recovery command during M2.

Secure-input policy for M4:

- read `kAXSubroleAttribute` and compare it with `kAXSecureTextFieldSubrole`;
- also check `IsSecureEventInputEnabled()` as a conservative global policy signal;
- do not claim either signal necessarily fires before the other;
- refuse input before posting any event.

### Local authentication

Use one random host-session token and pass it to every lazy Node child.

- `/health` remains unauthenticated.
- Every other endpoint in both directions requires `X-Harness-Token`.
- The Mac host validates the token on its tool API.
- The Node harness validates the same token on invoke/status/settings routes.
- Close the current host-auth asymmetry in v1; do not defer it to v1.1.
- Update split-development documentation so explicit manual host/Node launches share a token.

### Node supervision

- Spawn Node directly; never run `zsh -lc` or user shell profiles.
- Development uses an explicit configured Node path.
- The first distributed build bundles and signs a compatible Node runtime.
- Start Node on hotkey so the existing static pi imports warm while the user types.
- Do not add dynamic imports or a `/warm` endpoint unless M0 measurements justify them.
- Put the child in its own process group.
- In supervised mode, give it a held stdin pipe. Node calls `process.stdin.resume()` and exits on
  stdin `end`; host death closes the pipe without polling.
- On normal shutdown: SIGTERM the process group, allow a short grace period, then SIGKILL if needed.
- On child exit, surface a clear harness-unreachable state and clean up the process group.
- Do not add a `process.ppid` polling watchdog.

Node model settings remain Node-owned. `AgentModelSettings` reloads its persisted file on every spawn;
the host does not push model/effort state. Fix the Darwin default path to:

```text
~/Library/Application Support/pi-os/settings.json
```

Also pass or derive the shared captures directory explicitly. Harden screenshot containment with
realpath resolution so `/tmp` versus `/private/tmp` aliases cannot escape the trusted root.

### Startup

- M0–M3: manual/dev launch is sufficient.
- Productization may register `SMAppService.mainApp` for login launch.
- `SMAppService.mainApp` is **not** crash KeepAlive.
- Do not add a helper or LaunchAgent solely for restart-on-crash in the first release.

---

## 7. Platform implementation map

| Windows behavior | Lean macOS implementation | Phase |
|---|---|---|
| WPF hidden app/tray | `NSApplication` with `LSUIElement`, `NSStatusItem` | M1 |
| `RegisterHotKey` | Carbon `RegisterEventHotKey(...kEventHotKeyExclusive)` | M0/M1 |
| Duplicate hotkey failure | handle `eventHotKeyExistsErr`; separately test system shortcut precedence | M0/M1 |
| WPF overlay | fixed-style nonactivating `NSPanel`, pure AppKit controls | M0/M1 |
| WS_EX_NOACTIVATE focus dance | nonactivating panel; defensive behavior verified empirically | M0/M1 |
| Physical-pixel placement | CG points plus one AppKit Y-flip boundary | M1 |
| HWND/PID | `CGWindowID + PID` | M2 |
| `PrintWindow` | `SCScreenshotManager` + desktop-independent window filter | M0/M2 |
| UIA | AX C API with strict messaging timeout and nullable degradation | M0/M2 |
| `SendInput` | CGEvent posting after exact-window verification | M4 |
| UAC/elevation policy | other-UID/root/unknown refusal plus TCC/secure-input checks | M4 |
| Win32 job object | process group + supervised stdin EOF | M3 |
| Kestrel host API | bounded `NWListener` HTTP/1.1 | M0/M1 |
| `HttpClient` to harness | `URLSession` | M3 |
| WinForms settings window | deferred; pi default/existing settings file first | post-slice |
| balloon notifications | deferred | post-slice |
| Explorer shell metadata | Finder Apple Events, deferred | post-parity |

Carbon remains present and non-deprecated in the current macOS 26.5 SDK, but it is legacy API surface.
M0 verifies behavior rather than treating current header availability as a permanent guarantee.

---

## 8. Required Node and shared-contract changes

The Mac port does **not** leave `node-harness` literally unmodified. Keep changes narrow and
platform-conditional:

1. Darwin captures and model-settings paths.
2. Supervised stdin-EOF shutdown, enabled only by a supervised env flag.
3. Explicit shared captures path and host URL/token on each spawn.
4. Realpath screenshot containment hardening.
5. Platform-neutral prompt wording:
   - target identity was pinned before the prompt appeared;
   - coordinates are pixels in the latest screenshot;
   - macOS terminology and shortcuts on Darwin.
6. Host authentication enforcement and split-dev token documentation.
7. M4 only: `cmd` modifier, `space` key, `capture_stale` handling, and platform-specific tool schema
   or guidance.
8. Replace Windows-only fake-host paths with platform-plausible fixtures and a real PNG.

Do not restructure all of `protocol.md` during the read-only slice. Make only the semantic corrections
required by the implementation. A broader transport-neutral rewrite is deferred.

Compatibility means **message-shape and behavior compatibility**, not literal byte-for-byte output.
JSON key order, timestamps, service names, and OS-specific optional fields are not byte-identical.

---

## 9. Milestones

### M0 — risk-first feasibility spike (3 working days, go/no-go)

Build disposable, signed probes before scaffolding the product host.

Required experiments:

1. Nonactivating panel receives prompt keystrokes without activating the host in:
   - normal desktop
   - full-screen Space
   - Stage Manager
2. SCK capture:
   - point-sized output and actual dimensions
   - occluded window
   - minimized/off-Space failure behavior
   - frame-resize race and one retry
   - capture latency
   - 1× small-text legibility
3. Carbon hotkey:
   - duplicate exclusive registration
   - silent system-shortcut precedence loss
   - candidate shipped default; do not assume Ctrl+Option+Space is available
4. Stable signed TCC identity across rebuild/reinstall.
5. Public-only `CGWindowID + PID` pinning and post-panel AX focus semantics in AppKit and
   Chromium/Electron.
6. Full `node-harness` cold start, warm RSS, invocation peak, and shutdown latency. Run `npm ci`
   first; the current checkout has no `node_modules`.
7. Bounded `NWListener` server against Node `fetch`, including auth, malformed JSON, body limits,
   unknown routes, cancellation, and connection close.
8. Coordinate-transform fixtures for 1×, 2×, and mixed displays.

Go/no-go gates:

- hotkey-to-panel p95 meets or credibly approaches 50 ms;
- panel does not steal application activation;
- SCK returns a transform that round-trips controlled screenshot targets exactly;
- no private API is needed for read-only pinning;
- Node can warm within the normal prompt-typing interval on target hardware;
- host server interop is deterministic.

A failure in public exact-window focus blocks M4, not the read-only slice. A failure in panel behavior
or screenshot transforms reopens the host architecture decision.

### M1 — TCC-free shell and conformance (about 1 week)

Deliver:

- `host-macos/` Xcode/Swift project and signed `.app`
- `LSUIElement`, `NSStatusItem`, Quit and diagnostic status
- flock gate and fatal bind handling
- exclusive Carbon hotkey with env override
- pre-created nonactivating prompt and simple echo reader
- `/health` and `/tools` over bounded `NWListener`
- contract Codable types and small golden fixtures
- repaired fake-host fixtures with a real PNG

Demo: hotkey → prompt → Enter/Escape → echo result, with no activation theft and no TCC prompt.

### M2 — pinned read-only context (about 1 week)

Deliver:

- cheap pre-panel `CGWindowID + PID` pin
- cursor and monitor metadata in CG top-left points
- SCK capture and private transform
- bounded AX focused-element summary with nullable degradation
- `ContextStore` and read-only host tools
- minimal explicit permission screen/status action
- stable signing/TCC development workflow

Demo: hotkey shows immediately; pinned snapshot and PNG complete asynchronously and validate against
shared fixtures.

### M3 — lazy agent vertical slice (about 1 week)

Deliver:

- direct Node resolution for dev and process-group spawn
- supervised stdin-EOF lifecycle
- host-session token in both directions
- invocation submit/poll/cancel
- simple static pill activity and reader result
- configurable 120-second initial warm TTL
- harness-unreachable/error state
- Darwin settings/captures paths and containment hardening

Demo: hotkey over a document → ask a read-only question → receive answer → Node exits after TTL.

**Read-only vertical slice estimate: 2.5–3.5 weeks including M0 for one Swift/AppKit-fluent engineer.**

### M4 — computer-use parity, spike-gated

Start only if M0 proves exact-window focus can fail closed using public APIs.

Deliver:

- exact target focus/raise and post-raise verification
- `CGPreflightPostEventAccess` onboarding/check
- serialized click, type, key, chord, and scroll primitives
- private screenshot transform and `capture_stale`
- `cmd` modifier and `space` key
- secure-field and secure-event-input refusal
- bundle-ID policy blocklist and other-UID/root refusal
- no retries after uncertain mutations
- privacy-bounded traces without typed text

Demo: controlled save/type/click task succeeds in the pinned window; ambiguous windows, password
fields, and stale captures post zero events.

### M5 — distribution and parity QA

Deliver:

- bundled compatible Node runtime
- Developer ID signing, hardened runtime, notarization, and staple
- login launch through `SMAppService.mainApp`
- fresh-machine permission flow
- mixed-display/non-US keyboard QA
- macOS 14/current release matrix
- updates only after identity-preservation behavior is proven

**Full parity estimate: 8–10 weeks total.**

---

## 10. Deferred scope

Deferred from the read-only slice:

- computer-use actions and `cmd`/`space` until M4
- notification permission and fallback panel toast
- dismiss-pill-to-notification behavior
- model/settings UI
- Finder `shellFolderPath` and selected desktop items
- Apple Events permission
- Sparkle or another updater
- LaunchAgent/helper crash restart
- fancy pulse, sweep, elapsed timer, and activity-merge animations
- Windows pill-logic extraction
- broad `protocol.md` restructuring
- Linux transport preparation
- enterprise/MDM PPPC profiles

The simple pill remains visible until result or cancel in the first slice; no notification fallback is
required to avoid losing a dismissed result.

---

## 11. Testing and conformance

### Required automated coverage

- Swift Codable round-trip against shared JSON fixtures.
- Node `hostClient` against the Swift host for every implemented route.
- Real PNG ingestion through the same file-path containment checks used in production.
- Hotkey parser table, including non-contiguous macOS F-key codes.
- Panel placement across negative origins and mixed displays.
- Capture-transform property tests and golden examples.
- Context TTL and identity revalidation.
- Auth: missing/wrong/correct token in both directions.
- Parent death via stdin EOF and clean process-group shutdown.
- M4: no-event assertions for stale, ambiguous, secure, denied, and gone targets.

### Manual matrix

- AppKit, Chromium/Electron, Java/non-native app where available
- full-screen Spaces and Stage Manager
- one Retina display, one 1× display, and mixed arrangement
- occluded, moved, resized, minimized, and closed target windows
- Screen Recording denied/granted/relaunch-required states
- Accessibility denied/granted states
- system hotkey conflicts
- installed app launched outside a developer shell

### Review automation rule

A review cannot report "clean" solely because agents exited successfully. The final gate fails when
any of these is non-empty:

- factual errors
- gaps
- unresolved contradictions
- untested load-bearing claims
- silently degraded conformance fixtures

---

## 12. Primary risks and decision gates

| Risk | Current mitigation / gate |
|---|---|
| Screenshot-point mapping posts input at the wrong place | actual-dimension transform, M0 mixed-display fixtures, M4 stale-size refusal |
| Wrong window receives input | `CGWindowID + PID`, exact frontmost verification, public AX match, ambiguity fails |
| Panel steals activation or changes AX focus | M0 app matrix; move bounded focused-element read earlier or omit if needed |
| SCK permission/latency harms first gesture | no launch warm; no SCK on panel path; explicit permission action |
| Node dominates idle RAM | zero Node at ordinary idle; spawn on hotkey; measured TTL |
| GUI launch cannot find Node | explicit dev path; bundled signed runtime for distribution |
| Child survives host death | supervised stdin EOF plus process group |
| Local process invokes TCC-powered tools | token required both directions, loopback only, strict request bounds |
| Carbon/system shortcut collision | exclusive registration plus empirical precedence probe and configurable chord |
| Hand-written HTTP parser grows unsafe | M0 interop/fuzz-like cases; reconsider a narrow library if it cannot stay bounded |
| TCC grants disappear across builds | stable bundle ID/signature and signed refresh workflow |
| Scope expands before useful release | read-only M0–M3 definition and explicit deferred list |

Open decisions after M0:

1. Shipped default Mac hotkey.
2. Whether SCK shareable-content caching materially improves capture latency.
3. Whether 1×-target screenshots preserve enough small-text detail; resolution may increase without a
   wire change because the private transform uses actual dimensions.
4. Whether focused AX metadata remains reliable after the nonactivating panel becomes key.
5. Whether public exact-window focus is reliable enough to authorize M4.
6. Final Node warm TTL based on measured cold start, RAM, and actual invocation cadence.
