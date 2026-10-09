# Native UI polish

## 2026-10-01 Whisper — build 12 installed

Tom selected Whisper from the disposable prototypes. Native implementation uses
AppKit text editing / SF Symbols and Apple glass on macOS 26+, not HTML. The default
bar is 480 × 50 pt, display-bottom-centered, one line until multiline input needs
more room. It grows upward. The answer sits on a separate readable material above
it; context and native appearance preferences sit behind π. The menu bar also offers
Appearance without loading models or starting Node. System preset follows macOS.

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| MEDIUM | `PromptPanel.swift`, `Contracts.swift` | Large target-centered composer with header/footer rows | Slim display-bottom Whisper bar and upward-only expansion | One stable, quiet point of entry |
| MEDIUM | `PanelStyle.swift` | One heavily washed visual-effect surface | Real Apple glass command surface, readable answer material, safe older-OS and opaque fallbacks | Native depth without sacrificing answer readability |
| MEDIUM | `AppearanceSettings.swift`, `Appearance.swift` | No visual presets or user density/spacing preferences | Six native presets including System, larger text, opacity and edge spacing | Adaptable without affecting permissions or pinned authority |
| HIGH (fixed) | `PromptPanel.swift:layoutCurrent` | Early redesign hid the active editor during layout and could drop subsequent typed text | Preserve active text/answer scroll views and first responder while reflowing | Multiline fidelity and focus continuity |
| LOW | `PromptPanel.swift:presentAnswer` | Completion fade on a frequently used surface | Immediate presentation, no custom opening/closing/morphing | Keyboard interactions stay fast |

Verified: 67 Swift CPU/mock tests (older transient recall test remains skipped), 70
guarded Node tests, conformance, 17 final candidate and 17 installed reader/follow-up
checks. Signed default dark reader/bar screenshot inspected for native type, selection,
source/close/copy controls, one-line follow-up composer, gap, radii and footer spacing.
Installed screenshot: `qa/build12-whisper-reader-installed.png`. Native appearance
control wiring tests cover all presets and larger text/spacing with injected preferences;
Draft, history availability and security keys survive visual changes. The disposable
native preview confirmed a real anchored popover window exists; Orca could not match
its separate accessibility window, so that is **not** an end-to-end popup UI approval.

An earlier candidate passed 33 native checks. Final native rerun passed nine then
correctly stopped at NotificationCenter occlusion. No system app or OS protection was
stopped/disabled, and no occlusion exception was added.

Not verified: all-preset visual replay (especially busy backgrounds/light mode), full
VoiceOver/physical-keyboard matrix, native popup interaction end-to-end, hover/press
slow replay, Spaces/Stage Manager, and actual macOS 14/15 fallback rendering. User
permission state and models were not changed; fixture instances isolate appearance
preferences. No custom entrance animation was introduced.

**Approve only the inspected default Whisper reader/bar and fixture behavior.** Full
UI/accessibility/application acceptance is still pending; this is not full-parity sign-off.

## 2026-10-01 persistent reader / follow-up composer

Build 11 retains the reader across deactivation/outside clicks. Its answer remains
selectable with one vertical scroll region; a separate multiline follow-up editor
sits below it with Return/Shift-Return guidance and an accessible Send action. During
a turn it shrinks to the existing working capsule; completion restores the reader
with a fresh composer. Failed follow-ups preserve the previous answer and permit
explicit retry when the thread is still valid. Done/Escape/close terminate it.
Recall of a closed thread is answer-only, without a composer.

59 CPU/mock Swift tests pass (the older transient last-answer test remains skipped).
A signed reader fixture passed 16 candidate and 17 installed checks, including focus
loss, multiline submission, busy capsule, failed-turn recovery, warm reservation,
explicit close/revocation and unchanged canaries. The composer uses native AppKit
text/button controls, system semantic colors and existing layout surfaces. No custom
animation was introduced. This is behavior/accessibility-tree acceptance, not a full
VoiceOver, dark-mode, zoom, narrow-width or physical-keyboard polish sign-off.

## 2026-09-22 credential-input setting

| Severity | Location | Before | After | Why |
|---|---|---|---|---|
| HIGH | `SettingsWindow.swift`, `CredentialFields.swift`, `AnswerRenderer.swift` | Global secure-input refusal told users to disable macOS protection; no field-level override | Unchecked credential-input option, explicit privacy confirmation, actionable field-specific refusal | Ordinary typing/clicks remain usable while clearly identified login fields require user consent |
| LOW | `SettingsWindow.swift` | No space for credential-policy explanation | Taller native window with aligned checkbox, wrapping hint and separate footer | Preserve readable grouping and avoid clipping |

Verified: mocked light-mode window screenshot and AX tree, label, default-off state,
wrapped hint, footer spacing, disabled preview state. No provider/model call was made.
Signed native/browser fixtures verified the effective setting in both modes with dummy
values. **Not verified:** enabled confirmation interaction, VoiceOver/keyboard matrix,
hover/press replay and dark-mode layout for this new row. No custom animation was added.
**Approve** for inspected layout/state paths only; not a claim of full UI acceptance.

## 2026-09-16 settings continuation (source-inspected, not live-UI validated)

| Severity | Location | Before | After | Why |
|---|---|---|---|---|
| HIGH | `Sources/PiOSMac/SettingsWindow.swift` | No explicit compatibility trust boundary | Unchecked trusted-global option, warning confirmation, grant gating, next-task semantics | Executable extensions/coding tools must not silently bypass pinned-only expectations |
| MEDIUM | `Sources/PiOSMac/PromptPanel.swift` | All controllable sessions labelled alike | “Trusted pi” badge and scope tooltip when unrestricted compatibility is active | Make the changed boundary visible at invocation time |
| MEDIUM | `Sources/PiOSMac/SettingsWindow.swift` | Concurrent reload/apply could race | Busy state disables dependent choices during catalog/compatibility updates | Prevent stale model selection and accidental double changes |

Resource/model HTTP behavior and persistence are covered by fixture tests. The actual
confirmation dialog, badge layout, keyboard traversal, hover/press and VoiceOver for
these new controls are **Not verified**; live GUI work remains paused for resource
coordination. No user compatibility preference was enabled by this implementation.


This pass changes presentation and interaction, not the agent, capture, auth,
read-only tool boundary, or lazy process architecture.

## Review / changes

| Severity | Location | Before | After | Why |
|---|---|---|---|---|
| HIGH | `Sources/PiOSMac/PromptPanel.swift:29` | Single-line field; no explicit composition handling | Growing native text editor; Return submits, Shift–Return adds a line; Return first commits marked IME text | Keyboard correctness, not decorative motion |
| MEDIUM | `Sources/PiOSMac/PanelStyle.swift:41` | Flat HUD treatment, fixed edge color | Appearance-aware popover material, continuous corners, native shadow, stable neutral ink, contrast/transparency fallbacks | Surface depth and legibility in light/dark mode |
| MEDIUM | `Sources/PiOSMac/PromptPanel.swift:230` | `π / title` plus development text | App icon, app name and truncating window title; explicit read-only badge; visible key hints and enabled/disabled Ask button | Clear target identity and hierarchy |
| MEDIUM | `Sources/PiOSMac/PromptPanel.swift:303` | Large centered working box | 360×68 capsule with source context, native activity indicator and an always-present cancel control | Less obstruction; ongoing work remains understandable without animation |
| MEDIUM | `Sources/PiOSMac/AnswerRenderer.swift:6` | Raw Markdown in a fixed 420-point reader | Native attributed headings, emphasis, lists, quotes, code and safe links; adaptive answer height, bounded scrolling | Readability and density appropriate to the answer |
| MEDIUM | `Sources/PiOSMac/PromptPanel.swift:435` | Clipboard write with no feedback | Fixed-width Copied/checkmark state, ⌘⇧C shortcut, accessibility announcement; original Markdown retained | Visible confirmation without shifting neighboring controls |
| MEDIUM | `Sources/PiOSMac/PromptPanel.swift:387` | Dismissal loses access to the result | Click-away/Escape dismissal; last successful answer remains recallable from the menu, even after a later failure | Reversible dismissal; no accidental loss of useful output |
| MEDIUM | `Sources/PiOSMac/AnswerRenderer.swift:116` | Technical error envelope shown as an answer | Concise reason, contextual symbol, recovery guidance and explicit permission CTA | Recovery rather than a dead end; permission display never requests a grant itself |
| LOW | `Sources/PiOSMac/PanelStyle.swift:84` | Generic untuned buttons | Native button semantics, focus rings, hover/disabled states and restrained 0.96 press feedback | Optical alignment, hit areas, and tactile feedback |
| LOW | `Sources/PiOSMac/Application.swift:74` | Shifting text status item; flat developer menu | Fixed-width template mark, state tooltip, grouped commands, enabled last-answer recall, diagnostics submenu, About and app icon | A quiet menu-bar resident, not developer scaffolding |

## Motion / accessibility policy

- No entrance or exit animation on hotkey / Escape / ⌘W.
- One 140 ms opacity-only completion transition; recalling an answer is immediate.
- No animated frame resizing, layout springs, rainbow borders, sweep loops or idle timer.
- The native spinner runs only while the working capsule is visible. Reduced Motion
  substitutes a static hourglass; text remains the primary activity signal.
- Copy confirmation uses one cancellable 1.6-second delay, not polling.
- The surface responds to Reduce Transparency and Increase Contrast. System colors,
  SF Symbols, text selection, standard edit shortcuts and keyboard focus are retained.
- Click-away uses mouse-only event monitors while a reader is visible, plus native
  key-window notifications. Monitors are removed on dismissal; no keyboard event tap.
- Remote images/HTML are not loaded. Rendered links accept only explicit HTTP(S) URLs.
  Common Markdown is styled; this is not a full CommonMark/HTML/table renderer. Copy
  Answer always copies the complete original string, not the rendered/reflowed text.

## Verified

- Light/dark native screenshots: empty prompt, populated prompt, multiline editor,
  working capsule, short answer, long scrolling answer, and permission error.
- Native editor text entry; enabled Ask; both button and Return submission; simulated
  prompt → working → formatted answer transition using the real production panel.
- Copy feedback observed in the accessibility tree; clipboard matches original
  Markdown, including emphasis and inline code.
- Source-title clipping and multiline error wrapping found during visual inspection
  and corrected. Short-answer minimum is 168 points; long answers cap at 580 points.
- 21 Swift tests, 19 Node tests and the explicit Swift/Node conformance test pass.
  Presentation tests cover key/IME policy, adaptive sizing, Markdown/font behavior,
  malformed text, unsafe-link/image exclusion, permission non-escalation, and last-
  answer recall after dismissal, a new prompt and a subsequent error.

## Not verified

- Full-screen Spaces / Stage Manager, sustained VoiceOver use, real IME candidate
  interaction, non-US hardware keyboard matrix, and slow-motion capture of hover/press.
- Menu-bar interaction was source-inspected but not automated: Orca's provider does
  not expose menus, and the alternate GUI tool failed with an unrelated pi extension
  API mismatch (`ctx.modelRegistry.getApiKey`). This is not an app runtime error.
- System-wide Reduce Motion / Transparency / Increase Contrast were not toggled on
  the user's machine. Their branches were inspected, not empirically certified.
- Mixed-DPI physical-display input mapping and M4 focus safety remain outside this UI
  pass. No mutating desktop tool has been enabled.
- Remaining signed-release and macOS 14 acceptance gates remain in `STATUS.md`.

**Approve** for the inspected preview UI paths; this is not approval of the unverified
matrix or full macOS release. No known HIGH UI issue remains in the inspected paths.
