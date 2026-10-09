# Windows → macOS parity tracker

Target: the Windows user-facing behavior, not a permanently read-only Mac product.
Status as of 2026-10-01: **signed implementation candidate installed; full parity NOT signed off**.
Build 12 is installed at `~/Applications/pi-os.app` with an Apple Development identity
and hardened runtime. The missing official Apple WWDR G3 intermediate was verified
against the built-in Apple root and added to the login keychain, with no trust override.
A changed, re-signed disposable build satisfied the same designated requirement.
The old ad-hoc Screen Recording grant was reset only for pi-os while stopped. The user
approved Screen Recording and Accessibility/input posting, and both grants survived
subsequent same-identity updates without a reset/reapproval.
The development install still links the repository's Node harness; it is not yet a
self-contained notarized distribution.

**Brave and credential-input update:** build 10's production browser route passed
18 checks through the installed signed host. Candidate browser/native suites passed
with the credential setting both off and on (18 / 30 checks per mode). Ordinary typing
and clicks are no longer vetoed by OS-wide Secure Keyboard Entry; only clearly marked
username/password fields are default-blocked, with explicit Settings opt-in. No OS
security feature was disabled. See [BROWSER_INTEGRATION.md](BROWSER_INTEGRATION.md).

## Whisper UI acceptance — build 12, 2026-10-01

Selected from Tom's prototype review: native 480 × 50 pt bar centered on the
selected display's visible lower edge, upward-only expansion and a detached answer.
Apple glass on 26+, native visual-effect fallback on 14/15, native appearance controls
and six visual presets (including System). Appearance is separate from authority;
trusted compatibility warnings remain visible. Accessibility opacity/motion overrides
and persistent reader/follow-up behavior are preserved.

70 guarded Node / 67 Swift tests and conformance pass. Final candidate and actual
installed reader suites each pass 17 checks. An earlier candidate native suite passed
33; the final rerun stopped after nine at a correctly refused NotificationCenter
occlusion. No workaround relaxed occlusion/security checks. Default signed dark
reader/bar screenshots inspected; all-preset visual, VoiceOver, physical keyboard,
Spaces/Stage Manager and older-OS fallback acceptance remain pending.
See `qa/build12-*.json` and `UI_NOTES.md`. No new live-model/browser acceptance claim.

## Upstream reconciliation — build 11 (history), 2026-10-01

The upstream audit confirmed PriNova/pi-os at `9ddcfd4` (matching local
`upstream/main`); the committed baseline remains `764effa`. The four later commits
are now reconciled for the Mac workflow, without copying Windows input mechanics:

- `5fc5123`: sequential follow-ups retain the same in-memory SDK session, original
  model/resources and pinned context. Authenticated followup/close routes reject
  concurrent turns; resource cleanup covers closure/startup races and shutdown.
- `e9437d4`: reader stays open on deactivation/outside clicks; explicit close ends
  the thread. Recall is an answer-only operation, never a session resurrection.
- `e7a3bb6` / `9ddcfd4`: native scalar-safe paced typing, real Return for line breaks,
  CRLF collapse, and no clipboard fallback. Brave normalizes breaks, fills only
  multiline receivers and verifies delivery. See `docs/desktop-input-semantics.md`.

**70 guarded Node / 59 Swift tests and conformance pass.** The real SDK's finalized
history was exercised with an in-memory stream fixture, not a live provider. Signed
candidate native fixtures passed 33 checks in each credential mode. The candidate
reader passed 16 checks; the actual installed build passed 17 checks, including the
Carbon hotkey, four sequential turns, failed-turn recovery, warm-child reservation,
explicit disposal/native revocation and canary preservation. Production Brave's
20-check default fixture passed; the enabled-mode rerun stopped before CDP attachment
with `browser_unavailable`. No connection prompt was approved automatically or retry
sent within that invocation. Build 10's enabled-mode evidence remains historical.
Evidence: `qa/build11-*.json`.

Scope differences remain explicit: Mac has **one native reader at a time**; a new
hotkey replaces/closes its old thread rather than keeping multiple Windows-style
readers concurrently. Cancel/timeout closes its input authority instead of permitting
reuse of a revoked lease. Native pacing has a bounded per-call preflight limit. These
safety/lifecycle choices and the acceptance gates below mean **full parity is still
NOT signed off**. No model-driven follow-up test or broad slow-editor matrix ran.

## Feature map

| Windows capability | Mac implementation | Acceptance |
|---|---|---|
| Sequential follow-ups in the answer reader (current upstream) | Retained in-memory SDK thread, same model/target, fresh per-turn action refs | Real SDK stream-fixture test and 17 installed native lifecycle checks pass; no live model |
| Reader remains open until explicit close (current upstream) | Outside clicks/deactivation do not dismiss; explicit close disposes thread | Signed installed-host fixture passes |
| Current upstream text-input semantics | Native scalar-safe pacing/Return/CRLF; browser multiline fill; no default clipboard | Signed native and browser multiline fixtures pass; broad slow-editor matrix pending |
| Global hotkey / pinned target | Carbon, CGWindowID + PID, precreated AppKit panel | Existing slice tested; full-screen/Stage Manager matrix still pending |
| Pinned screenshot | Explicit SCK window filter; actual dimensions; bounded PNG | Existing capture worked; new 1280-edge/1 MP cap has property tests |
| Focused UI metadata | Public AX, pre-panel 25 ms budget; secure values omitted | Implemented; AppKit spike; Chromium/non-native metadata matrix pending |
| Refresh / under-cursor metadata | Pinned AX window, fresh cursor, nullable summary | Implemented, not full live matrix |
| Exact window focus | Public bounds/title AX match + CG front order + system-wide AX focused application/window | Controlled two-window focus spike passed |
| Live Brave DOM control (additional Mac capability) | Explicit setup, retained native selected-tab identity, unique URL/window CDP match, bounded semantic browser tools, no native-input fallback | 70 Node / 67 Swift tests and conformance pass; build 11 default browser fixture passes; enabled rerun transport-blocked; installed build 10 browser evidence is historical |
| Click / type / key / chord / scroll | Serialized native CGEvents, layout-aware key mapping, Command + Space support | Mock refusal suite passes; see limited native evidence below |
| Harmful-action refusal | No ordinary app-brand denylist; same non-root UID, exact identity/focus, configurable field-local credential protection, recognized file-deletion actions refused | Unit and harmless Like/Delete-control fixture checks pass; not a filesystem sandbox |
| Cancellation / timeout | Revocable context lease, queued-operation cancellation, balanced key releases, existing invocation timeout | Automated gate/partial-input/lifecycle tests pass |
| No mutation retry | Uncertain input prevents further input in that context; observation remains possible | Implemented; controller interruption tests pass |
| Model + reasoning settings | Native provider/model/effort window; Node-owned persisted selections; authenticated catalog validation | Mock HTTP round-trip/persistence tests pass; live UI acceptance pending |
| Pill / answer / copy | Native Whisper glass bar, detached formatted reader, explicit close/copy, upward display-bottom anchoring | Build 12 installed reader/follow-up fixture passes; default dark screenshot inspected; all-preset/VoiceOver/background-notification acceptance pending |
| Visual presets and accessibility | System / Clear / Frost / Graphite / Warm / Contrast; larger text, opacity and edge spacing; native glass with older-OS fallback | Native control wiring and draft/authority isolation tests pass; broad visual/older-OS acceptance pending |
| Dismiss to background / result notification | Hide without cancel; optional UN notification; native toast fallback; result recall | Implemented; notification permission/click-through acceptance pending |
| Start once / tray resident | Native `.app` and status item | Existing install works |
| Login launch | Explicit Settings toggle using SMAppService.mainApp | Implemented, requires signed installed-app QA |
| Self-contained install | Standalone Node + locked production harness, licenses, signed native dependencies and guarded SDK-import smoke; staged replacement | Implemented scripts and negative gate tests; real signing/runtime validation pending |
| Explorer active folder / document path | Exact AX window document URL → Finder shellFolderPath or documentPath during capture | Implemented as nullable public AX data; live application matrix pending |
| Desktop selected items / desktop actions | Finder-owned CG desktop layer; unique direct AX desktop container; bounded explicit selection; public focus + exact verification | Candidate implemented with eight policy/selection tests; real Finder/CG/SCK geometry inspected read-only, input/capture acceptance still pending |
| Global pi extensions / built-ins | Default pinned-only; explicit acknowledged trusted-global compatibility, suppressed by read-only/control denial | Persistence, project exclusion, provider bootstrap/lifecycle and HTTP gates pass with fixtures; real user configuration not loaded |
| Notarized release | Explicit Developer ID/notary profile gate; submit, staple, assess, then publish fresh archive + SHA-256 | Script/negative gates implemented; no upload performed |

## Finder and trusted-resource additions

The Finder adapter pins only Finder's actual CG desktop-icon layer, not a window
found by a localized title. Read-only inspection on this Mac found two CG desktop
windows but ONE 3840×1080 AX desktop container. The adapter therefore accepts the
explicit union of Finder-owned desktop CG frames as well as an exact full frame or
contained monitor work area. This observed shape is saved in
`shared/fixtures/macos-finder-shape.json`. Keyboard input is separately refused when
selection spans outside the pinned desktop display (or shared-desktop selection is
empty/unknown); the union never widens mouse-coordinate authority. A single direct Finder collection is required;
normal Finder windows and sidebar rows cannot substitute for it. Selection uses AX's
count + bounded array reads: unavailable is null, checked-empty is `[]`, and truncated
selection retains its complete count. No filesystem enumeration or Apple Events is used.
Desktop focus uses only a settable public AX focus attribute, followed by verification;
there is no Show Desktop shortcut, hide-all-windows fallback or guessed activation.
This is coded and fixture-tested, not a claim that all Finder versions expose this profile.

Trusted compatibility is a separate acknowledged `resources.json` setting. Model catalog
and new invocations use it only while native control is allowed; otherwise resources stay
isolated. Factory-registered providers are initialized before model choice through the
public SDK, without a prompt or session-start hook. The bootstrap stays alive until its
loader is no longer used, avoiding stale ExtensionAPI closures. Desktop guards apply to
native tools only in this mode: arbitrary user-trusted code is not sandboxed. None of the
user's real global extensions/providers were loaded to test this feature.

## Input invariants

- Private screenshot identity is injected by the Node extension, never selected by
  the model. Only successfully loaded image content advances that identity. A metadata
  refresh cannot authorize coordinates based on an image the model has not seen.
- Pure movement rebases against the current origin. Resizing or invalid/outside points
  returns `capture_stale`/`invalid_arguments` before input. Each native action revalidates
  the process identity, ownership, permissions and exact window focus.
- Keyboard events are PID-scoped. Mouse/scroll events need WindowServer hit testing;
  exact focus, geometry and point occlusion are checked immediately before posting.
- The host's floating capsule stays hidden once native input begins, avoiding an
  overlay/event-delivery race. Result presentation or a background notification ends
  that phase. The status-menu cancel action remains available.
- Clearly identified username/password fields are default-blocked with an explicit
  Settings opt-in; values remain omitted from text snapshots. OS-wide Secure Keyboard
  Entry is not an input veto and is never disabled by pi-os. Ambiguous windows,
  foreign/root/unknown UIDs and unknown focused controls are still refused. Ordinary app brands are not banned. System/app-switching
  shortcuts that leave the pinned target remain blocked; ordinary save/close/hide
  shortcuts are not blanket-banned. This is not an OS sandbox and cannot make arbitrary desktop races atomic.
- Events are allocated before posting. Partial chords release only pressed modifiers;
  Unicode chunks never split a surrogate pair. After any uncertain outcome the model
  must not retry, and the native context refuses subsequent input.
- Input traces have no typed text, key values, titles or context capabilities.

## 2026-09-21 action-policy correction

Tom clarified that normal app use must work and harmful actions—not app brands—are
the boundary. Orca, terminals, coding apps and browsers are no longer identity-blocked.
The unconditional final-action prohibition was removed: explicit requests such as
“Like this post” authorize that exact action, with state checks and result verification.
No actual X account interaction was used for testing.

File deletion remains prohibited in agent guidance. Native guards reject recognized
Delete/Move to Trash/Empty Trash controls, file-removal shortcuts and obvious deletion
commands in recognized terminal surfaces, while preserving ordinary text editing.
A harmless fixture's Like button changed state and its Delete-file counter stayed zero.
These are defense-in-depth checks, **not a hard no-delete sandbox**: opaque controls,
arbitrary/encoded scripts, aliases and trusted extension code can have effects that
metadata/pattern matching cannot prove. Do not claim absolute prevention on those paths.

The signed candidate passed the full fixture including Like/Delete checks. A subsequent
installed rerun was stopped correctly by a real loginwindow overlay covering the scroll
point; that refusal was not bypassed or reported as a test success.

## Signed installed-host validation — 2026-09-21

**Passed:** 25 checks through the actual installed, hardened, certificate-signed app,
launched by LaunchServices (not a terminal-inherited probe). A held deterministic Node
stub kept a real invocation active; Python called the authenticated native routes using
that invocation's pinned context. Only a disposable two-window AppKit fixture received
input. No model/provider was loaded or called. Evidence:
[`qa/installed-host-macos27.json`](qa/installed-host-macos27.json).

Verified capture, exact-window focus, Unicode typing, Space/Backspace, Command-S saving,
moved-window clicking, nested scrolling, stale/unseen-image refusal, secure-field
refusal, ambiguous-window refusal, disappeared-process refusal, unchanged canary and
result reader. macOS 27 can retain a 1×1 CG descriptor after a window closes: that case
returned `capture_stale`, with no delivered input. Once its owning process exited,
`target_gone` was returned. Do not equate a posted-event count with delivery; the fixture
contents, saved file, click counter, scroll position and event counter were checked.

This validation exposed and fixed two issues missed by the CPU mocks:
- Carbon/TIS layout lookup traps off the main queue on macOS 27. Layout mapping now
  hops to MainActor and has a worker-origin regression test.
- WindowServer's cursor window appears over the intended point in CG enumeration.
  Occlusion checks now exclude only the public cursor level with the verified dedicated
  WindowServer UID and system executable path; forged/ordinary overlays remain blocked.

The full cross-application/Spaces/display/layout matrix is still pending. This is
installed-host component acceptance, not a full-parity release claim.

## Earlier native evidence / history

A disposable two-window AppKit fixture was used before local-GPU coordination began.
Public AX + CG exact-window raising passed. Real Unicode typing and Command-S saving
the fixture text succeeded; the unrelated window stayed unchanged in those runs.
A moved-window click also succeeded in one run; stale-size, secure-field and ambiguous-
window refusals were observed. These are component observations, not a completed matrix.

At that earlier checkpoint, the entire native suite was **not green**. Later runs were interrupted: one
failed after pointer movement, and another canary changed while the desktop was in use.
The fixture now tags test events and exits before recording incidental external input.
Further mutating live runs were paused rather than treating those failures as proof of correctness.
A later CPU-only metadata inspection checked Finder AX roles/geometry/selection counts
and SCK desktop enumeration, without filenames, screenshots, focus changes or input.
That observation corrected the multi-display AX-container assumption; it is not an
end-to-end Finder capture/input test.
The latest complete focus/input/cancel/scroll/closed-window matrix must be rerun on an
idle desktop. Shell-inherited AX grants are not installed-app TCC proof.

## Automated verification in the coordinated CPU-only window

- 31 Node tests passed, including trusted-resource/model-settings API and release gates,
  platform schemas, immutable context/image binding,
  failed-image authority, no mutation retry and exact four-tool Mac control isolation.
- 40 Swift tests pass in the latest CPU-only run, including eight Finder selection/identity
  tests and 12 input/policy/catalog/gate tests. The transient
  AppKit window-presentation test was explicitly skipped while the benchmark ran.
- The explicit Swift NWListener ↔ Node fetch/HostClient conformance test passed,
  including real PNG ingestion and supervised child EOF. It performs no model call.
- Shell syntax and plist/entitlement validation pass. macOS/Windows CI definitions are
  prepared with no-live-provider guards, but no remote CI run or push was performed.
- Test bootstrap disables agent execution/model networking and rejects live provider
  fetches, including Ollama. Tests run serially / Swift builds use two jobs.

## Release blockers

1. Stable signing/migration and the current-machine grant-persistence check passed:
   builds 3→4→5→6 retained authorization, and installed-host capture/input worked after
   the updates without tccutil resets. Fresh-machine/OS-version acceptance is still pending.
2. The installed AppKit fixture suite is green. Continue with Chromium/Electron
   + non-native apps, full-screen/Stage Manager, mixed displays and non-US layouts. Verify
   real zero-event refusals and cancellation; do not infer delivery from posted-event counts.
3. Exercise Settings, permission actions, background toast/notifications and login launch
   from the signed bundle. No permission is granted automatically by these tests.
4. Validate the new Finder desktop adapter against actual single/mixed-display Finder AX
   trees and SCK desktop-window enumeration. It deliberately fails closed if the desktop
   container, full-frame/work-area geometry, focused recipient or selection is unavailable.
   No guessed/sidebar/directory selection and no full-display screenshot fallback is used.
5. Review and validate opt-in trusted pi compatibility with the user's actual configuration.
   This mode is NOT pinned-window-confined: arbitrary trusted extension code and coding tools
   can bypass native controls. It requires explicit acknowledgement and host control grants,
   changes future tasks only, and is visibly labelled. Default mode stays isolated.
6. Supply an official standalone Node binary (the installed Homebrew Node has external
   dylib dependencies), validate production native dependencies/JIT signing, and perform
   Developer ID notarization/stapling plus macOS 14/current fresh-machine QA.
7. Run Windows/.NET tests for the shared changes on Windows; no .NET SDK is available here.

No live Ollama/local-GPU validation is scheduled while the _LOCAL_AI DRACO benchmark
owns its reservation. Do not stop or alter its resident Qwen LaunchAgent. Ask for a
coordinated test window first. This is resource scheduling, not a worker handoff.
