# Review of MACOS_MIGRATION.md: better, leaner, faster

Date: 2026-09-02. Reviewed against the repo at commit 764effa plus the untracked plan, on this Mac
(macOS 26.5.2, Xcode 26.6, Swift 6.3.3, Node 24, pi 0.84.2 installed at `~/.local/bin/pi`, no dotnet).
This file is untracked; delete it once its content has been folded into the plan.

How to read the confidence tags:

- **verified**: finding survived three independent adversarial verifiers (facts, invariants, engineering).
- **measured**: backed by a probe run on this machine during the review (numbers quoted).
- **unverified**: finder output whose verification agents did not run (session quota); treat as a strong lead.

Probe sources are in the session scratchpad under `rpcprobe/`, `swiftprobe/`, `probe/`, `axprobe/`; they
are throwaway and can be recreated from the descriptions below.

---

## 1. Headline

The plan ports the Windows *topology* to macOS: a second HTTP server inside Node, a hand-written HTTP/1.1
server in Swift, a shared bearer token, a 700 ms status poll, a shared screenshots directory with
path-containment hardening, and a warm-Node state machine. Every one of those parts re-implements
something the installed `pi` CLI already provides in `--mode rpc`, or exists only because two processes
talk over TCP. Replacing node-harness with `pi --mode rpc -e pi-os.ts` over stdio removes roughly 1,000 of
the 1,356 Node lines, the Swift HTTP server and client, both ports, the token, the poller, the TTL timer,
the stdin-EOF Node patch, the captures directory, and M0 items 6 and 7. Measured cold start of that child
is 0.38 s with the pi-os extension only.

The second lever is safety, and it is independent of transport: the current harness gives the desktop
agent pi's default `bash`/`edit`/`write` tools plus every globally installed pi extension (on this Mac
that includes `pi-computer-use`, whose `gui_*` tools click anywhere on screen with no window pinning),
and a child of pi-os.app inherits pi-os.app's Accessibility and Screen Recording grants. The plan's
fail-closed guarantees therefore only hold for one of several input paths. A default-deny tool
allowlist and no global extensions is a one-flag change and also the fastest configuration.

---

## 2. Target architecture (reconciles all surviving findings)

```text
pi-os.app (signed LSUIElement AppKit app, macOS 14+)
│
├─ main thread: NSStatusItem, one pre-created nonactivating NSPanel (prompt / pill / reader), Carbon hotkey
├─ desktop serial queue: CG identity pin, SCK one-shot capture, (M4) AX + CGEvent + policy gate
│
└─ per invocation, spawned at hotkey, killed at result/cancel (no TTL, no idle timer):
     node <pi-install>/dist/cli.js --mode rpc --no-session --offline
          --no-extensions --no-skills --no-prompt-templates --no-context-files --no-approve
          --no-builtin-tools -e <bundle>/pi-os.ts --tools desktop_get_context,desktop_refresh_context,desktop_capture_window[,desktop_act]
          [--model provider/id:level]        cwd = ~/Library/Application Support/pi-os/agent-cwd (empty, 0700)
       stdin  <- JSONL: prompt {text, images:[base64 PNG]}, abort, extension_ui_response
       stdout -> JSONL: tool_execution_start, message_update, message_end, agent_settled, extension_ui_request
       fd 3   <-> newline JSON tool callbacks {id, tool, arguments} / {id, ok, result|error}, PNG inline
```

Dropped from the plan: node-harness HTTP server and invocation store, Swift bounded HTTP/1.1 server,
URLSession client, X-Harness-Token, ports 17831/17832, 700 ms polling, 120 s warm TTL, supervised
stdin flag and Node EOF patch, shared captures directory and realpath hardening, Darwin
model-settings path, bundled Node runtime, M0 items 6 and 7, M0 item 5 (moves to M4).

Kept from the plan: Swift/AppKit host, Carbon exclusive hotkey, nonactivating NSPanel, CGWindowID+PID
identity, CG top-left wire geometry with one AppKit flip, ScreenCaptureKit with macOS 14 floor, public
APIs only, flock single-instance gate, permissions only from an explicit onboarding action, host-side
CGEvent for M4, exact-window verification before input, read-only first.

---

## 3. Ranked recommendations

### R1. Spawn `pi --mode rpc` instead of running node-harness  (leaner, faster; verified + measured)

**What.** The Mac child is `pi` itself. The host writes one `prompt` line on submit (snapshot summary
as text, PNG as `images[]`), renders `tool_execution_start.toolName` and `thinking_delta` into the pill,
treats `agent_settled` as terminal, reads the answer from the last assistant `message_end`, cancels with
`{"type":"abort"}`. node-harness shrinks to one file: the extension plus a ~40-line callback client.

**Why.** RPC mode covers every function of server.ts, invocations.ts, NodeInvoker.cs polling and the
cancel route (rpc.md: prompt with images, abort, get_state, events, extension UI sub-protocol). Measured
here: `pi --mode rpc --no-session --no-extensions ... -e probe.ts` answers `get_state` in 0.37–0.39 s
including TypeScript compile of the extension, with no node_modules anywhere near the extension
(typebox and pi-ai resolve from pi's own install); it exits 0 on stdin EOF, also mid-stream; a 1.1 MB
inline PNG prompt was accepted in 381 ms and answered by the model.

**Caveats the verifiers attached.**
- Spawn at hotkey, not at submit, so the 0.4 s boot overlaps typing (the plan already does this for Node).
- One pi process per invocation. This makes `PI_OS_CONTEXT_ID` in the environment valid and deletes the
  TTL. If a warm child is ever reused, `new_session` must precede each prompt and the context must be
  bound host-side.
- `--no-extensions` is a product change: agentRunner.ts:21-22 loads the user's global extensions on
  purpose. See R3 for why the default must flip anyway.
- pi echoes every image 3–5× on stdout (message_start/end, tool_execution_end, turn_end, agent_end),
  about 10 MB per Retina capture. The Swift reader needs a buffered LF splitter that peeks `type` and skips
  decoding oversized lines it does not need. Responses can arrive out of order: correlate by `id`. Drain
  stderr (extension console.log lands there). Ignore SIGPIPE. Write large prompt lines off the main thread.
- `{"type":"response","command":"prompt","success":false}` is a terminal failure with no later events.
- Answer any dialog-type `extension_ui_request` with `cancelled:true`, never auto-select; ignore
  fire-and-forget methods (or use `setStatus`/`notify` to drive the pill, see R9).
- Model choice becomes host-owned: `--model provider/id:level` at spawn. Do **not** call `set_model` or
  `set_thinking_level` on the live child; both persist into the user's `~/.pi/agent/settings.json`.

**Important correction from a refuted finding.** The claim that node-harness pays the 2–7 s
extension-load cost is false. Measured: the harness's per-invocation `reload()` with 11 global
extensions is ~150 ms; the pi CLI's extra 1.3–2 s is `session.bindExtensions()` firing global
extensions' `session_start` hooks, which the harness never calls. Consequence: RPC mode **with** global
extensions on is slower than today's harness; RPC mode with `-ne` is as fast or faster. That is the
real reason the default must be `--no-extensions`.

**Affects.** §1, §3, §4 steps 8–11, §6 supervision and auth, §8 items 2/3/6, M0 item 6, M3, protocol.md
"Node Harness API".

### R2. No listening HTTP server anywhere: stdio down, inherited fd or Unix socket up  (leaner, better; verified + measured)

**What.** Host→agent needs no auth: stdin/stdout are private to parent and child. Agent→host tool
callbacks go over an inherited `socketpair` end (fd 3 via posix_spawn file actions; the extension opens
`new net.Socket({fd: 3})`), newline-delimited JSON with the existing `{ok,result}|{ok:false,error}`
envelopes plus an `id`. Measured working on this Mac with pi 0.84.2.

**Why.** The plan's biggest self-declared risk is a hand-written bounded HTTP/1.1 parser on NWListener,
gated by M0 item 7, to carry ~10 JSON messages per invocation from a child the host itself spawned. The
token it protects is delivered via `PI_OS_TOKEN` in the child environment, which any same-UID process
reads with `ps -Eww` (measured). The token only excludes other UIDs and browser cross-site POSTs; an
inherited fd excludes everything that did not inherit it.

**Alternatives, in order.**
1. Inherited socketpair fd (recommended for v1 with the default-deny tool set from R3). Caveat: fd 3 is
   inherited by every grandchild of pi (Node cannot set CLOEXEC), so it is only as strong as the tool set.
2. Unix domain socket in `~/Library/Application Support/pi-os/run/` (0700) with `getsockopt(LOCAL_PEERPID)`
   compared to the child pid. Requires a BSD `socket/bind/listen/accept` + DispatchSource server (~150–250
   Swift lines); NWListener can bind a unix path via `requiredLocalEndpoint` but exposes no peer credentials.
   Mind the 104-byte `sun_path` limit. Use this variant if bash or global extensions are ever enabled.
3. Zero-socket tunnel: the extension calls `ctx.ui.input(title, JSON)` from a tool and the host replies
   `extension_ui_response {value: JSON}`. Measured round-trip 8 MB in 72 ms. It abuses UI semantics and
   fails when issued inside `session_start`; keep it as an M0 fallback only.

Not the right layer: `@earendil-works/pi-protocol` / `pi-client` (CBOR). They are the remote-session
control protocol, marked experimental with no compatibility guarantees.

**Affects.** §3 "Local HTTP implementation", §6 "Local authentication", M0 item 7, M1 "/health and
/tools", §11 auth tests, §12 parser risk row, protocol.md "Authentication" (make it transport-conditional:
Windows HTTP+token, macOS private channels).

### R3. Default-deny tool surface, no global extensions, fixed empty cwd  (better; verified + measured)

This is the single largest deviation from "fail closed" in the design, and it exists in the Windows
build today.

**Facts.**
- agentRunner.ts passes no `tools`, so every session gets pi's built-in `read`, `bash`, `edit`, `write`
  (sdk.md:523), and it builds `DefaultResourceLoader` on the user's real `~/.pi/agent`, so every package in
  settings.json loads. globalResources.test.ts asserts this as desired.
- On this Mac that means 26 extension tools including pi-computer-use's `gui_click`, `gui_type`,
  `gui_hotkey`, `gui_batch`, `gui_clipboard_read/write`: screen-wide input by app name with a Swift helper
  compiled at first use, AppleScript keystrokes via a clipboard swap, no CGWindowID pin, no policy, no
  secure-field check. `bash` is a second bypass (osascript). `pi-web-access` is an exfiltration channel.
- TCC attributes a child to its responsible app. Measured twice independently: an ad-hoc-signed binary
  compiled seconds earlier and launched under the terminal reported AXIsProcessTrusted, PostEvent and
  ScreenCapture true with no prompt. Once pi-os.app holds Screen Recording (M2) or Accessibility (M4),
  everything pi runs holds them too.
- The SDK path node-harness uses trusts the project by default (`settings-manager.js:150`
  `projectTrusted ?? true`; no `resolveProjectTrust` supplied), so any `<cwd>/.pi/extensions`,
  `.pi/SYSTEM.md`, `.pi/settings.json` load and execute. cwd today is `node-harness/dist`, so the repo's
  own AGENTS.md (Windows taskkill guidance) is injected into every desktop prompt. Deriving cwd from the
  target document would make an attacker-controlled folder the project.

**Do.**
- RPC: `--no-builtin-tools --no-extensions --no-skills --no-prompt-templates --no-context-files --no-approve
  -e pi-os.ts --tools <exact allowlist>`. SDK equivalent if Windows keeps the harness:
  `createAgentSession({ tools: [...] })` (this filters extension tools too and removes them from the
  registry), `DefaultResourceLoader({ noExtensions:true, noSkills:true, noPromptTemplates:true,
  noContextFiles:true, extensionFactories:[piOs] })`, `SettingsManager.create(cwd, agentDir, { projectTrusted:false })`.
  Keep `agentDir` at `~/.pi/agent` so auth.json and models.json still work.
- cwd = a host-created empty 0700 directory; never the target's folder, the install dir, or `$HOME`.
- Write the invariant into §5/§6: "the agent process tree has no capability the host tool API does not
  mediate", and note that TCC grants to pi-os.app are grants to everything it spawns.
- Invert globalResources.test: the fixture tool must be absent from both active and registered tools;
  assert exact set equality with the allowlist.
- Add `pi-computer-use` to §1 "Explicitly rejected" with the reason (frontmost-app targeting, Apple
  Events TCC, `swiftc` at runtime, clipboard typing).
- If power users want their extensions, offer an explicit allowlist setting of extension paths, off by
  default. Note this also drops extension-registered providers (the user's ollama/ds4 provider
  extensions), so pi-os sessions see only models.json and built-in providers unless allowlisted.

**Affects.** §1, §2 acceptance rules, §5, §6, §8, §11, §12, M3, M4; agentRunner.ts; globalResources.test.ts.

### R4. Send images inline; make the host the only resizer; validate coordinates in image space  (better, leaner; unverified but source-checked)

**Inline bytes.** With RPC the initial PNG rides in `prompt.images[]`; `desktop_capture_window` returns
`{png: base64, bounds, imageWidth, imageHeight}` over the callback channel. This deletes
screenshotImage.ts, `PI_OS_CAPTURES_DIR`, the Darwin captures path, realpath hardening (§6, §8 items 3–4),
the "real PNG through containment" test, and fixes an existing leak: no code path ever deletes a
capture, so every hotkey press leaves a window screenshot on disk indefinitely. Never embed bytes in
`DesktopContextSnapshot.screenshot`; that object is stringified into model text (truncate 6000) and
logged. protocol.md's `GET /images/{imageId}` is unimplemented on both sides; delete it.

**Size cap (this is a correctness bug, on Windows too).** §5.3 says tool coordinates are "pixels in the
latest screenshot" and treats 1 px per point as a free target. Two resizers sit between host and model:
pi 0.84 normalizes every *tool-result* image to ≤2000×2000 / 4.5 MB and appends a "multiply coordinates
by N" note (`utils/tool-result-images.js`, verified in the installed pi; prompt images are *not*
resized, so first and later screenshots follow different rules today), and the Anthropic API downsizes
long edges above 1568 px (standard tier) or 2576 px (Claude 4.7+), returning coordinates relative to
the resized image. A 1728×1117-pt window exceeds 1568 at 1 px/pt, so clicks land at ~84 % of the
intended offset. Windows already has this bug: PrintWindow at physical pixels on 150–200 % displays.

Rule: capture at native resolution with SCK, downscale so the long edge ≤ 1568 (raise to 2576 only when
the selected model is known to accept it), never upscale, return actual `imageWidth`/`imageHeight` on
`ScreenshotRef` (two optional fields; receivers ignore unknown fields). The "private transform keyed by
contextId" (§5.3 step 7) is then redundant: scale = `bounds.width / imageWidth` from the stored snapshot.
Accept a click iff `0 ≤ sx < imageWidth` and `0 ≤ sy < imageHeight`; return `capture_stale` if the
current window size differs from the capture's bounds (Windows silently re-bases on resize today, add
the check to `ReloadAndValidateTarget` as a shared fix). Screen point = `origin + (sx + 0.5) * scale`
as doubles; CGEvent takes CGPoint, no flooring.

**Legibility.** Open decision 3 (1× vs 2×) is a false choice once the cap exists. Keep the native
capture in memory for the latest context and add a read-only `desktop_zoom {x,y,w,h}` tool that crops
and returns the region at up to 2× (also capped). Anthropic's own guidance for dense screenshots is a
crop tool.

**Affects.** §5.3, §6, §8 items 3/4/8, §11, §12 open decision 3, M0 items 2 and 8, M2, M4;
ScreenshotService.cs (shared fix); protocol.md coordinates paragraph.

### R5. One pi process per invocation; delete the warm-TTL machinery  (leaner; verified + measured)

Spawn at hotkey, close stdin at result shown or Escape, SIGTERM after ~2 s, SIGKILL after another ~2 s.
pi's RPC mode already exits on stdin EOF (`rpc-mode.js:639-641`, measured exit 0 in <20 ms, also mid-stream),
so §8 item 2 (Node `process.stdin.resume()` patch) and the supervised env flag have nothing to implement.
Delete §4 steps 6 (unused-child special case) and 11, §3's TTL exception, M3 "configurable 120-second
warm TTL", §12 open decision 6. §2 "0 Node processes at ordinary idle" then holds unconditionally.

Why it is affordable: an idle pi RPC child holds 160–185 MB RSS (measured), five times the host budget,
for two minutes after every answer, to save a 0.4 s boot that already overlaps typing. Keep the
SIGTERM→SIGKILL backstop: pi's shutdown awaits extension `session_shutdown` handlers without a timeout,
and pi's bash tool spawns detached children (own pgid) that a group kill cannot reach; only pi's own
abort path kills them, which is one more reason `bash` stays off.

ContextStore: keep lazy expiry on `Get()` (already present) plus a size cap; do not port the 5-minute
sweep Timer.

### R6. Read-only slice requests Screen Recording only; when AX lands, read it before the panel  (leaner, better; measured, unverified)

**Defer Accessibility to M4.** PostEvent access is a distinct TCC service but lives under the same
Accessibility toggle (one consent, two DB rows). Once M2 asks for Accessibility to read the focused
element, the "read-only" build already holds the only permission needed to post input, and children
inherit it (R3). If M1–M3 request only Screen Recording, read-only is enforced by TCC itself, M2
onboarding is one prompt, and M0 item 5 leaves the slice. Cost: no `focusedElement` in v1; the
screenshot carries the same visible content. Window titles from `kCGWindowName` need Screen Recording
anyway; the TCC-free M1 label can show the app name (`NSRunningApplication.localizedName`) but not the
window title.

**When AX arrives (M4), the plan's step order is wrong.** §4 shows the panel (step 4) and reads focused
AX metadata in parallel (step 5), leaving "post-panel AX focus semantics" as an open decision. Measured
here with a `.nonactivatingPanel` from an `.accessory` app: the target app stays frontmost and
`NSRunningApplication.current.isActive` stays false, but the system-wide `AXFocusedUIElement`
immediately becomes pi-os's own text field and the target's per-app focused element degrades from
`AXTextArea` to `AXWindow` while the panel is key; both revert after `orderOut`. There is no post-panel
query that returns the user's focused element. Read AX on the desktop queue **before** showing the
panel with `AXUIElementSetMessagingTimeout` ≈ 20–30 ms and show the panel at min(reads done, ~25 ms);
warm cost measured at 7 ms, so the 50 ms budget holds. Use `orderFrontRegardless`, not
`makeKeyAndOrderFront`; `NSApp.isActive` reads true while the panel is key, so the "does not steal
activation" gate must use `NSWorkspace.shared.frontmostApplication`. Drop FocusService: a
nonactivating panel never activated pi-os, so there is nothing to restore.

**Chromium/Electron caveat.** Chromium does not build its AX tree until an assistive client engages
it and returns `kAXErrorAttributeUnsupported` (-25212) for `AXFocusedUIElement` (measured on Brave). On
Windows UIA engages it implicitly; on the Mac `focusedElement` will be null for Chrome, Brave, VS Code,
Slack, Electron apps unless pi-os sets `AXManualAccessibility=true` on the app element once per PID
(a mutation that turns on Chromium accessibility mode; needs the grant; belongs in M4). The M4
secure-field refusal, which reads the focused subrole, sees nothing for web password fields until then.
Rewrite M0 item 5 accordingly and repeat the measurement with the browser frontmost.

### R7. The provisional default hotkey is dead on this Mac and registration cannot detect it  (plan-error; measured)

`com.apple.symbolichotkeys` entry 61, "Select next source in Input menu", is enabled with parameters
`[32, 49, 786432]` = Space with Control+Option, and two keyboard layouts are active (German, ABC-QWERTZ),
so Ctrl+Option+Space is live. `RegisterEventHotKey(kVK_Space, controlKey|optionKey, kEventHotKeyExclusive)`
returns `noErr` regardless: exclusive registration only detects other Carbon registrations (duplicate →
-9878), not system or CGEventTap consumers (Cmd+Space returned 0 although a launcher owns it here).

Do: ship a default outside Apple's Space-bar table (ids 60/61/64/65 = Ctrl, Ctrl+Opt, Cmd, Cmd+Opt + Space
are all reserved). Candidates: Ctrl+Option+Cmd+Space (no Apple default, natural mapping from Windows
Ctrl+Alt) or Option+Space (Alfred's default; also removes non-breaking-space entry system-wide). At
registration read `AppleSymbolicHotKeys` from UserDefaults (public, no TCC), compare `parameters[1]`
(keycode) and `parameters[2]` (Carbon modifier bits) of every enabled entry with the configured chord,
and warn from the status item on a match or on `eventHotKeyExistsErr` instead of registering into a
black hole (~40 lines; turns the M0 "precedence probe" into a permanent runtime check). Register once at
launch: the first Carbon call costs 22 ms. Carbon itself is confirmed right: it type-checks and links with
no deprecation on the macOS 14 and 26 targets and needs no TCC; NSEvent global monitors need Input
Monitoring and cannot consume the key, CGEventTap needs Accessibility.

### R8. Define the "frontmost app has no window" path  (plan-error; unverified, mechanism confirmed)

§4 step 2 pins "the frontmost normal layer-0 CGWindowID for that PID" and everything downstream assumes
it exists. On macOS it often does not: Finder on the bare desktop (the desktop is a
`kCGDesktopIconWindowLevel` window, not layer 0), and any app whose last window was closed stays
frontmost. The shared schema allows `targetWindow: null`, the harness summary tolerates it, but
OverlayWindow throws on it and the plan is silent. Windows needed `DesktopBackgroundPolicy` (Explorer
class names) for the same case.

Rule: if the frontmost PID has no on-screen layer-0 window, mint the context with `targetWindow: null`
plus app PID/name, anchor the panel to the `NSScreen` containing the cursor (`visibleFrame`, already
AppKit coordinates), label with the app name, either omit the screenshot with a typed reason or capture
the cursor's display via `SCContentFilter(display:excludingApplications:[pi-os])`, and return a typed
`no_target` (not `target_gone`) from `desktop_capture_window`. Add a null-target Codable fixture and a
placement test. Drop `DesktopBackgroundPolicy` on the Mac; the null check replaces it. Also apply the
layer-0 and owner-uid filters at pin time (menu-bar extras, Control Center, Spotlight are layer > 0;
measured Control Center items at layer 25).

### R9. Minimal AppKit panel, no FocusService, one flip, named budgets  (leaner; measured, unverified)

**Panel.** OverlayWindow.xaml.cs (804 LOC) plus XAML (165) splits cleanly. Port (~250 Swift lines): prompt
(target label + text field, Enter/Esc), static pill with an always-visible cancel button, reader
(`NSTextView` read-only, Esc and click-away close, clipboard copy), the pure centering math. Defer
(§10 already does): anti-flicker merge, pulse/gradient/elapsed timer, terminal flash, hover buttons,
dismiss-to-toast. Do not port: the two-pass SetWindowPos/DPI dance, WS_EX_NOACTIVATE toggling,
DllImports, SizeToContent workaround, DesktopBackgroundPolicy, FocusService.TryRestore. One
`NSPanel` subclass with `[.nonactivatingPanel, .borderless]`, `.floating`, `[.canJoinAllSpaces,
.fullScreenAuxiliary]`, `hidesOnDeactivate = false`, `canBecomeKey` following mode.

**Placement.** AppKit points already abstract backing scale, so none of the DPI code survives. Exactly one
flip is unavoidable (`kCGWindowBounds` top-left, `NSWindow` frames bottom-left); do it with
`NSScreen.screens[0].frame.height` (the primary screen), not `NSScreen.main`. `CGEvent(source:nil).location`
already gives the cursor in CG coordinates. Two pure functions with unit tests replace 120 Windows lines.

**Budgets (§2) are not decidable as written.** Measured: a minimal accessory app with NSStatusItem and a
pre-created NSPanel, ScreenCaptureKit linked, has `phys_footprint` 12–14 MB but RSS 44–74 MB. Name the
metric: `task_vm_info.phys_footprint` (Activity Monitor "Memory", `footprint -p`). "First visible prompt
frame" needs an in-process proxy: Carbon handler entry → `NSWindow.didChangeOcclusionState == .visible`.
First-ever show of a pre-created panel took 46 ms, later shows ~10 ms; the first `CGWindowListCopyWindowInfo`
costs 35–45 ms and the first AX call 27 ms, then sub-millisecond. Warm both at launch (one throwaway CG
call, one panel show at alpha 0 then orderOut; neither touches TCC) or the first hotkey alone eats the
50 ms budget.

**Dismiss.** Notifications stay deferred (UNUserNotificationCenter needs a bundle and a prompt), but the
NSStatusItem is a permissionless surface: title "π…" while running, "π ✓/!" on completion, click reopens
the reader. ~25 lines; removes "fallback panel toast" from the deferred list.

**Pill from the extension.** `ctx.ui.setStatus`/`notify` surface as `extension_ui_request` lines on stdout
in RPC mode (measured), so the extension can push status without any socket; `tool_execution_start`
already gives tool names.

### R10. Build no model-settings subsystem on the Mac  (leaner; verified)

`~/.pi/agent/settings.json` (`defaultProvider`/`defaultModel`/`defaultThinkingLevel`; here
`openai-codex/gpt-5.6-sol/xhigh`) already governs a bare RPC child with zero pi-os code (measured). Drop §6
"Node model settings remain Node-owned" and the Darwin path fix, §8 item 1's settings half, and reclassify
§10 "model/settings UI" from deferred to not planned. Optional host override: one string in UserDefaults
passed as `--model provider/id:level` (resolve it first; pi exits 1 on an unknown model). A future picker
reads `get_available_models` from a throwaway child and applies the choice by respawning. Do not delete
modelSettings.ts / modelCatalog.ts / the two routes from the shared harness while Windows ships the
SettingsWindow; decide Windows explicitly.

### R11. Structural injection gates for M4  (better; verified as design, effort depends on R1)

Today every anti-injection measure is prompt text. Screenshots, titles and AX values are
attacker-controlled by construction. With the RPC child, `pi.on("tool_call")` + `ctx.ui.confirm(...,
{timeout})` gives a fail-closed human gate for free: the confirm arrives as an `extension_ui_request` the
host renders in the pill with Allow / Allow-all-this-task / Deny; timeout resolves to deny. Under the
SDK-in-harness design the default `noOpUIContext` returns false immediately, so the gate would silently
deny everything unless `session.bindExtensions({uiContext})` and new host routes are added.

Add host-side budgets independent of the model: max desktop_act per invocation, max typed characters per
action and per invocation, and a chord denylist for system and target-escape chords (Cmd+Tab, Cmd+Space,
Cmd+Q, Cmd+Shift+Q, Cmd+Ctrl+Q, Cmd+Option+Esc, Ctrl+Up/Down). Windows has no denylist either: Alt+Tab,
Alt+F4, Ctrl+Shift+Esc are sendable today, so this is a shared fix. Record `blocked_by_user` /
`budget_exceeded` as typed outcomes so the agent stops rather than retries.

**Capture policy.** `ComputerUsePolicy` gates only `window.focus` and `input.*`; `desktop.captureWindow`
and `refreshContext` are not gated, so a blocklisted 1Password window can still be screenshotted to a
cloud model every turn. Add a separate, smaller no-capture list (password managers, credential/consent/
auth dialogs, Keychain Access, System Settings › Passwords) evaluated at pin time and surfaced in the
panel; keep terminals and agents on the no-input list only, or the read-only slice cannot be used over a
terminal. Do not gate capture on the global secure-input flag.

**Secure input.** `IsSecureEventInputEnabled()` (Carbon import) is session-global and is held by
Terminal/iTerm "Secure Keyboard Entry", unlocked password managers, and browsers on password fields.
Refusing all typing whenever it is true makes M4 permanently unusable for exactly the target audience.
Make it target-aware: look up the holder PID via IORegistry (`kCGSSessionSecureInputPID`, verify the key
in M0), refuse only when holder == target or unknown, re-check between typed chunks, and treat an
unreadable focused element as `focus_unknown` rather than letting null pass.

**Mac blocklist.** Match bundle IDs, never `localizedName` (localized, user-renameable). Include pi-os
itself, `com.apple.SecurityAgent`, `com.apple.loginwindow`, `com.apple.systempreferences` (where pi-os's
own TCC toggles live), `com.apple.keychainaccess`, `com.apple.Spotlight`, `com.apple.controlcenter`,
password managers, terminals (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm, cmux), other
agents. Refuse nil bundle IDs and `kCGWindowLayer != 0`. The "other-UID" refusal is real: the on-screen
list here contains uid 88 (WindowServer) windows; read the owner uid with `sysctl(KERN_PROC_PID)`.

**Exact-window focus (§5.4) can be simpler.** Bind the AX window at pin time (`kAXFocusedWindow` of the
pinned PID, require its frame to equal the pinned CG bounds; measured unambiguous) and store the
`AXUIElementRef` next to CGWindowID+PID. At act time revalidate with
`CGWindowListCreateDescriptionFromArray([wid])` (0.15 ms), raise through AX (`kAXRaiseAction` /
`kAXFrontmostAttribute`) and verify with one call: `CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow,
wid)` filtered to layer 0 must be empty (0.2–0.5 ms). This drops `NSRunningApplication.activate()` from a
never-active LSUIElement process (cooperative activation may decline it) and the bounds+title matcher.
Add an M0 item: raise a non-frontmost window from a never-active background app via AX on 14/26. Borrow
three CGEvent details from pi-computer-use: `.mouseMoved` before down/up, `kCGMouseEventClickState` for
multi-click, `scrollWheelEvent2Source` with the location set; type with
`keyboardEventKeyboardSetUnicodeString` per UTF-16 chunk (no clipboard, no System Events).

### R12. Require an installed pi; resolve `node` and `cli.js`; do not bundle Node  (leaner; unverified)

Authentication comes from `pi /login` / `~/.pi/agent/auth.json`, so bundling Node never removes the pi
dependency; it duplicates pi (139 MB here; a production `npm ci` of node-harness is 304 MB). The real
GUI-app problem is PATH: `~/.local/bin/pi` is a symlink to `dist/cli.js` with `#!/usr/bin/env node`, and
launchd's default PATH has no `node` (measured). Resolve two paths from a probe list plus a settings
override (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.volta/bin`,
`~/.bun/bin`, `/etc/profiles/per-user/$USER/bin`, `~/.nvm/versions/node/*/bin`, and pi's own installer
layout under `~/.pi/agent/install/` with node at `~/.local/share/pi-node/current/bin/node`), follow
symlinks, spawn `node <cli.js>` directly (bypasses the shebang), read pi's version and `engines.node`
from the resolved package.json (no extra process), and surface "pi not found / too old" as a typed panel
error. State a minimum pi version whose rpc.md the host was built against. Delete Node signing and
notarization from M5. Trade-off: pi-os is not self-contained, and a pi upgrade can change behaviour
under pi-os.

### R13. Add a signing-identity prerequisite to M0  (risk; measured)

`security find-identity -v -p codesigning` reports 0 valid identities on this machine. Ad-hoc signatures
are identified by cdhash, which changes every build, so Screen Recording and Accessibility grants reset on
each rebuild and M0 item 4 cannot run. Obtain a free "Apple Development" certificate (Xcode › Settings ›
Accounts, any Apple ID) or a self-signed code-signing certificate; then M0 item 4 is a 30-minute check
with a fixed bundle ID. Document `tccutil reset ScreenCapture <bundle-id>` beside it.

### R14. Ship the Windows fixes as one separate PR, before Mac work  (better; verified)

Cannot be built here (no dotnet). Independent of the port:
1. **Host auth (confirmed).** `HostApiServer.Authorized` reads `PI_OS_TOKEN` from the host's own
   environment; `NodeSupervisor` sets it only for the child; nothing calls `SetEnvironmentVariable`. In
   every supervised run the host tool API skips token validation. Practical exposure is bounded by the
   unguessable 30-minute `ctx-<guid>` (no enumeration endpoint), but contextIds are logged to host.log
   at five host sites and in the child. Fix: `HostApiServer(store, pipeline, token)` with the token
   chosen as "PI_OS_TOKEN from the host environment if set, else random" in one place and passed to both
   NodeInvoker and HostApiServer, only when the supervisor actually started the child (otherwise the
   `PI_OS_SUPERVISOR=0` split workflow 401s). Then make "no token configured" fail closed on both sides
   behind an explicit `PI_OS_INSECURE_DEV=1`, update DEVELOPMENT.md's split workflow to export one shared
   token, and add the first auth tests (none exist on either side). Stop logging contextIds at info level.
2. `GET /tools` is served without the token check (`HostApiServer.cs:64`), contradicting protocol.md:27.
3. ContextStore's 5-minute sweep Timer is redundant with lazy expiry in `Get()`.
4. Chord denylist (R11) and the screenshot size cap / image-space bounds / `capture_stale` (R4) are
   correctness fixes on Windows too.
5. `NodeSupervisor` walks up from the exe directory to the drive root looking for
   `node-harness/dist/index.js`; if any ancestor is user-writable that is a search-order hijack. The
   plan already replaces it with explicit paths on macOS.
6. Token comparison uses `==` (not constant-time); Kestrel's default 30 MB body limit vs Node's 1 MB.

### R15. Plan and doc hygiene  (plan-error; verified)

- protocol.md specifies `GET /images/{imageId}`; neither host implements it and Node never calls it. The
  real transport (shared directory + `filePath` + `PI_OS_CAPTURES_DIR` + containment) is documented only in
  DEVELOPMENT.md. Under R4 delete the route and `ScreenshotRef.imageId`; otherwise document the truth.
- protocol.md:4, desktop-context.ts:8, AGENTS.md:33 and a dozen C# comments cite
  `docs/windows-agent-harness-handoff.md`, `ux-design-notes.md`, `docs/progress-tracker.md`, all under
  `/docs/`, which `.gitignore` excludes. Replace with inline text or un-ignore a `docs/public/`.
- README, DEVELOPMENT.md and AGENTS.md are Windows-only (netstat/taskkill, PowerShell, `%LOCALAPPDATA%`).
  Add a platform matrix and a macOS section (`lsof -i :17831`).
- The plan's preamble (session id, workflow id, "439-line" predecessor, critic verdict) and §11 "Review
  automation rule" describe the authoring process, not the software, and are not checkable from the repo
  (single commit, plan untracked). Move the process bullets to AGENTS.md, keep only "conformance fixtures
  must fail loudly" in §11, and commit the plan so revisions are diffable.
- Version drift: package-lock pins pi-coding-agent 0.83.0; the machine runs 0.84.2; npm latest is 0.84.4.
  Decide the pin before M3, or let R1 make it moot (the contract becomes rpc.md + the extension API).
- §8 item 5 (platform-neutral prompt wording) has no milestone home; put it in M3. Under R1, ship the
  prose as `prompts/darwin.md` in the bundle via `--append-system-prompt` (note: any explicit append list
  suppresses discovery of the user's `~/.pi/agent/APPEND_SYSTEM.md`; acceptable for a desktop agent) and
  keep one extension file with a two-entry `process.platform` table for `cmd` and `space`.

### R16. Offer persisted sessions as an opt-in feature  (better; verified)

With pi as the child, dropping `--no-session` (fixed cwd so `cd <cwd> && pi -r` lists desktop
conversations, or a custom `--session-dir` with the picker's "All" scope) and passing `--name "pi-os:
<app> — <title>"` lets the user continue a desktop task in terminal pi with full history, fork it, or
export it, at zero code cost. A "Continue in terminal" affordance in the reader should copy
`pi --session /abs/path.jsonl`. Costs: base64 screenshots land in the JSONL (roughly one PNG per capture),
and from M4 `desktop_act type_text` arguments would be persisted verbatim, which breaks protocol.md's
"typed text is never logged". Default to `--no-session`; make persistence an explicit toggle labelled
with both facts, or persist only invocations with zero mutating tool calls.

---

## 4. What the plan gets right (confirmed, keep as is)

- Swift/AppKit host, no SwiftUI, no third-party Swift packages.
- Carbon `RegisterEventHotKey` with `kEventHotKeyExclusive`: type-checks on macOS 14 and 26 targets with no
  deprecation, no TCC, duplicate returns -9878 exactly as §7 says. Input Monitoring is genuinely never
  required.
- Nonactivating `NSPanel`: the target app stays frontmost while the panel is key (measured); key status
  releases on `orderOut`.
- `CGWindowID + PID` identity, hex `hwnd` encoding, no `_AXUIElementGetWindow`; the layer-0 filter is
  load-bearing (the first on-screen window for the frontmost PID here was a 190×19 layer-103 overlay).
- CG top-left points on the wire with one AppKit flip; AX frames matched CG bounds in the probes.
- ScreenCaptureKit with a macOS 14 floor: `SCScreenshotManager.captureImage(contentFilter:)` is
  `API_AVAILABLE(macos(14.0))`; `captureImage(in:)` is 15.2, so stick to the filter API.
  `CGWindowListCreateImage` is `SCREEN_CAPTURE_OBSOLETE(10.5, 14.0, 15.0)`; there is no TCC-free
  window-capture path on 14+, so nobody should spend M0 time looking for one. Gate every SCK call on
  `CGPreflightScreenCaptureAccess()` and never call `CGRequestScreenCaptureAccess` outside onboarding.
- flock as the single-instance gate; zero idle timers; `SMAppService.mainApp` is not KeepAlive.
- Host-side CGEvent for M4 rather than an extension-side helper.
- Read-only first, explicit deferred list, exact-window verification before input, no retries after
  uncertain mutations.
- "node-harness treats contextId and hwnd as opaque strings", "no node_modules in the checkout", "Carbon
  present in the 26.5 SDK": all verified true. "AgentModelSettings reloads on every spawn" is true per
  process, not per invocation.

## 5. Ideas that did not survive

- **"Warm the session, not the imports."** Refuted by measurement (see R1). The harness's post-submit
  work is ~150 ms; the plan's import warming targets the dominant cost.
- **pi-protocol / pi-client CBOR as the host channel.** Wrong layer; experimental.
- **Reusing pi-computer-use's Swift helper.** Not leaner: `swiftc` at runtime (needs Xcode CLT), a process
  per event with sleeps, name-based targeting with silent frontmost fallback, largest-window ranking
  instead of CGWindowID, clipboard-swap typing needing Automation TCC, deprecated
  `activateIgnoringOtherApps`.
- **Long-polling `/invocations/{id}`.** Correct on its own terms (700 ms polling hides short tools and
  delays the answer up to 700 ms), but moot under R1 where events stream.
- **Serving screenshots from `GET /images/{imageId}`.** Sound under an HTTP design; moot under R1/R2.
- **Collapsing the TCC table to two grants.** Not exactly: Accessibility, PostEvent and ListenEvent are
  three services, but PostEvent has no pane of its own and is granted by the Accessibility toggle, so the
  user-visible surface is two panes. Keep `CGPreflightPostEventAccess` as an M4 preflight and verify the
  coupling with a probe launched via `open`, not from a shell (a shell-launched probe inherits the
  terminal's grants).

## 6. Revised M0 (much of it runnable today with throwaway scripts)

Already answered on this machine:
- Carbon availability and exclusive-registration semantics (type-check + probe).
- pi RPC cold start, stdin-EOF exit, inline image acceptance, extension UI round-trip.
- Hotkey collision for Ctrl+Option+Space.
- Nonactivating panel keeps the target frontmost; AX focus must be read before the panel.
- First-call CG/AX/Carbon costs; phys_footprint of the minimal host.
- CGWindowListCreateImage obsolescence; no TCC-free capture path.

Still needed, and needing a signed bundle:
1. Signing identity + fixed bundle ID; TCC grant survives rebuild (R13).
2. Nonactivating panel receives keystrokes without activating pi-os, in a normal desktop, a full-screen
   Space, and Stage Manager (unchanged from the plan).
3. SCK: `SCShareableContent` enumeration latency separately from `captureImage`; occluded, minimized,
   off-Space behaviour; resize race; Retina output size and the downscale filter's legibility at 1568.
4. Coordinate fixtures at 1×, 2× and mixed displays using `imageWidth`/`imageHeight` (R4).
5. `--tools` allowlist yields exactly the desktop_* tools; a planted `.pi/extensions/evil.ts` and an
   `AGENTS.md` in the cwd's parent change nothing (R3).
6. M4 only: PostEvent flips true with Accessibility alone (probe via `open`); AX raise from a never-active
   background app; `AXManualAccessibility` on Chromium; secure-input holder PID key on 26.

Gone: M0 item 6 (`npm ci`, harness cold start), item 7 (NWListener vs Node fetch), item 5 in its current
form.

## 7. Method and caveats

Seven finder agents (transport, harness, capture, identity, UI, plan, security) read the repo, the plan,
pi's rpc/extensions/sdk docs and the installed pi source, and ran Swift and Node probes. Each finding was
to be checked by three adversarial verifiers. The run hit the session quota twice: the transport, plan and
security areas were fully verified (20 findings, 1 refuted); the capture, identity, UI and harness
areas were not, and their findings above are tagged accordingly, though several are independently
backed by two finders or by the orchestrator's own probes. The completeness critic and synthesis
agents never ran; this document is the orchestrator's synthesis. One offline image test still reached
the model (pi's `--offline` disables only startup network calls) and cost one small request on the
default model.
