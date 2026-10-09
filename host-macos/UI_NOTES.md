# Native UI polish

## 2026-10-07 Settings → Voice languages and Recognition, Settings → Dictionary, Recent takes (offscreen-verified only)

DESIGN4 §4.2, §4.4, §6.7, §6.8, D-T1, D-T7. The Settings window keeps its 560 × 708 size, its tabs and its manual
frames; Voice gains two sections and scrolls, Dictionary is a new tab after Voice. Buttons keep the window's Title
Case (“Add Word…”, “Delete All Takes”, “Forget Everything…”); labels and notes are sentence case. No new animation.

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| HIGH | `SettingsWindow.swift` (Voice → Languages I speak) | One language picker: a German take ran on the English recognizer | One checkbox row per language (English (US), Deutsch (Deutschland)) with its model status and **Download** when the dictation model is missing; every checked language runs at once and the arbiter picks (*pi-os listens for every checked language at once and picks the one you spoke.*); at least one stays checked; after the migration from the single language a one-time note: *New: pi-os now listens for English and German at the same time. Uncheck any language you don’t speak.* | Tom speaks both and mixes (D-T7); an unchecked language is never started and never chosen as the take's locale |
| HIGH | `RecognitionSettingsView.swift` (Voice → Recognition) | — | *Multilingual model · Parakeet TDT 0.6B v3 (483 MB) · Download…* behind a consent sheet (*Download enhanced recognition?*: size, Hugging Face repository at the pinned revision, the CC BY 4.0 line, *It stays on this Mac; audio never leaves pi-os.*); *Downloading 37%* + Cancel; *Preparing for the Neural Engine… (first time, about 30 s)*; *Waiting for the local AI benchmark to finish…* + Try Again; *Ready* + Delete (asks first); a failure's message + Retry; the note *Until it is ready, pi-os uses Apple’s recognition. Audio never leaves pi-os.* | 483 MB only after consent; the shipped model is pinned, so the row never reads “Not available in this build”; opening the page with voice on loads an installed model (never a download) |
| HIGH | `DictionarySettingsView.swift` (new Dictionary tab) | What pi learned was invisible and could not be undone | *Learn from my corrections* (Picks learn immediately / Ask / Off), *Apply to the recognizer*, *Explain to pi*; App names · Phrases · Fixes · Words · Recent takes; rows read *“recast” → opens Raycast* over *Parakeet · used 5 times · from “Did you mean”*; pin, on/off switch, Edit inline, delete with Undo; Add Word…; a shadowing entry is marked (*“siri” will open Spotify instead of Siri*) and Node's *Save anyway?* gets **Save Anyway**; Export… (0600 JSON), Import…, Forget Everything… (asks; also deletes kept takes) | Tom: “the app should improve from my corrections” — and he can see, fix and undo what it learned; every write refetches the recognizer's contextual strings |
| MEDIUM | `RecentTakesView.swift` (Dictionary → Recent takes) | — | *Keep my last voice takes to improve recognition* (off by default; switching off keeps what is there); newest first: *Today at 17:07 · 1.4 s*, what each engine heard (*Apple · English: “Open recast”*), the decision and outcome (*Did you mean… · You picked Raycast*, *Fixed: “…”*); ▶ plays one take at a time (stops on another list, another tab or close); **Fix…** → an app, or *Just fix the words* (keeps the first word, at most four words, never a command word; deletion and yes/no words teach nothing); delete one or **Delete All Takes** (asks) | Corrections from real takes, with a visible privacy switch |
| LOW | `SettingsWindow.swift` (Voice page) | Fixed height | The page scrolls (about 30 pt more with Recognition); the window size is unchanged | Fits the existing window |

Offscreen pass (`pi-os-ui-preview --snapshot DIR --states voice-settings,dictionary-settings,recent-takes-settings`,
light and dark; live fixture windows: `pi-os-ui-preview dictionary-settings` / `recent-takes-settings`):
`SettingsSnapshotTests` renders Voice with the Recognition row in every model state, Dictionary empty, populated,
shadowing and needs-confirmation, Recent takes, and the open Add Word and Fix forms in every preset, and checks that
nothing visible is clipped. The S3 review fixed a tab click that kept a take playing and a Fix that could rewrite a
command word.

Not verified: any live window; NSAlert, NSSavePanel and NSOpenPanel; real playback through AVAudioPlayer; VoiceOver;
keyboard focus in the inline editors (Escape triggers the window's Done and drops an unsaved edit).

## 2026-10-07 voice decisions in the bar (offscreen-verified only)

DESIGN4 §3, §5.3, §6.6, §7. New states extend Whisper: the bar stays the bar, its composer keeps focus and the heard
words, and every decision sits on the reading material above it (as typed list previews do). No new animation; the
capsule and notes change state instantly.

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| HIGH | `CommandController.swift` (empty final) | A take that heard nothing returned silently (9 % of takes) | The empty composer says *Didn’t catch that. Hold and say it again.* (placeholder, announced); holding the hotkey again starts a new take instead of closing the bar | Never a silent failure |
| HIGH | `PromptPanel.swift` (did you mean) | A misheard name went to the LLM, which asked back | Title *Did you mean Raycast?* (one row) or *Did you mean…* (2–3), subtitle *Heard “recast”*, Node's rows without the redundant list header and numbered **1–3** in the row detail, key hints *1–2 or ↩ Open · ⌥↩ Ask pi instead*; Return, a click, 1–3, ↑/↓, or a spoken *yes / ja / the second / die zweite / zwei / <name>* on the next hold | One Return instead of a 3–6 s agent turn; spoken and keyboard answers both work |
| HIGH | `PromptPanel.swift` (check state) | A garbled final started an LLM run that asked “What would you like to do?” | *Did I hear that right?*, the heard text selected in the composer (typing replaces it), the other language's reading as a chip, *↩ Run it · ⌥↩ Ask pi*; holding the hotkey re-says it | Fix or re-say locally, in 0 s |
| MEDIUM | `PromptPanel.swift` (confirm) | “Return to confirm: Open Numbers” | *Open Numbers? ↩* as the inline hint; a spoken *ja / yes* on the next hold also confirms | Shorter, spoken-friendly |
| MEDIUM | `PromptPanel.swift` (acting) | “✓ Opened Figma” after waiting up to 3 s for the launch, then 1.2 s | *Opening Pages…* at once in the quiet non-key capsule (app glyph, not a checkmark: the launch is not awaited), gone after 0.4 s; a launch that fails afterwards is a note | The bar no longer holds after a correct hear |
| MEDIUM | `ShelfToastView.swift` (voice notes) | One optional button, 1.4/3 s | Up to two buttons and a 4 s dwell: *Opened Keynote (heard “kein note”) · Not this*, *Learned: “recast” → Raycast · Undo*, *Remember “motion” → Notion? · Remember · Not now*; non-activating, above the open bar or where the bar was (a note still up when the bar reopens or grows moves above it); announced with its buttons; width up to 600 pt | Undo and correction without stealing focus |

Offscreen pass (`pi-os-ui-preview --snapshot`, System/Frost/Contrast/Graphite × light/dark, standard and Larger text;
states `heard-nothing`, `did-you-mean`, `did-you-mean-two`, `check`, `voice-confirm`, `acting`, `not-this-toast`,
`learned-toast`, `ask-toast`, `launch-failed-toast`) found and fixed: Node's “Applications” list header repeated what
the title says (dropped for choice cards). `PanelPreviewTests` lays out and renders every state in every preset at both
text sizes and checks that no piece leaves the reading surface or overlaps another, the bar keeps its place and height,
the composer keeps focus, and notes are never truncated.

Not verified: any live window; VoiceOver with the decision header, chips and notes; real Escape after an act (the
launched app is key, so Escape cannot reach pi-os without a global key monitor, which pi-os does not install: “Not
this” is the note's button or a spoken/typed “no” within 5 s); glass over busy wallpapers; the 1–3 keys with
non-US keyboard layouts.

## 2026-10-05 context chip, shelf, tether and Brave access (offscreen-verified only)

New states extend Whisper (480 × 50 bar, glass presets, readable reader material); nothing replaces
them. No new animation: chip, chips, outline and toast change state instantly; the tether is a
functional affordance (straight and static under Reduce Motion). Nothing new takes the composer's
first responder.

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| HIGH | `PromptPanel.swift` (opening) | “Ask about this window…”; every take was about the pinned window | “Ask anything…”; a **context chip** left of the send slot: off (icon, 30 pt circle), suggested (icon + name ≤ 110 pt, 1 pt accent outline), on (quiet accent fill); its width comes out of the editor's | Tom: open general, pull the window in only when meant; what the chip shows is what is sent |
| MEDIUM | `ContextChipView.swift` | — | Label ink in every state (accent text at 12 pt on a tinted capsule measured < 4.5:1 in light and dark); Contrast/Increase Contrast: thicker outline, stronger fill; never first responder; VoiceOver checkbox “Brave window”, value changes silently on suggestions and is announced only for the user's own toggles | WCAG-safe, keyboard focus stays in the composer |
| MEDIUM | `PromptPanel.swift` (keys) | Tab inserted a tab | Tab toggles the chip (not with marked IME text or a typed list owning the keys); ⌫ in an empty composer removes the last attachment | DESIGN2 §3.3 / selection.md §8 |
| MEDIUM | `ShelfChipsView.swift` | — | A chip row above the composer (bar grows upward by 32 pt, 36 at Larger text): text in quotes (tail-truncated), image thumbnail + size, “⌖ Button “Send””, files (middle-truncated, keeps the extension); dashed accent outline + “+” for the clipboard suggestion; ⊗ on each; “+N” overflow; click previews exactly what is sent | Show exactly what will be sent; removable |
| LOW | `PanelStyle.swift` (`DropOutlineView`) | — | 2 pt accent outline + 8 % tint over the bar while a drop is accepted (drawn content, so it also appears in offscreen renders) | Drop target feedback without motion |
| MEDIUM | `PromptPanel.swift` (reader) | “TextEdit · title” on every answer; footer “Same pinned window” | Header only when the window was used; a general answer puts the question in the header row; footer “Ready for a follow-up”, “· Brave included” or “· Looked at Brave”; “⌖ Pointing at Button “Send”” after the question (label ink under Contrast) | No “pinned” framing unless included |
| LOW | `ShelfToastView.swift` | — | Non-activating “Added to pi” capsule (no key, no main, 1.4 s), or a note with one **Grab Area** button (3 s); above the bar when the bar is open, never over it | ⌃⌥⌘C must not take focus from the app |
| LOW | `SettingsWindow.swift` | General / Voice / Classifier | + **Context** page: Active window (segmented), shelf switches with the clipboard caveat, Brave access popup, *Open brave://inspect…*, *Act in Brave in the background*; General's button reads *Brave Access…* | One place for what pi sees |

Offscreen pass (`pi-os-ui-preview --snapshot`, System/Frost/Contrast/Graphite × light/dark, standard and
Larger text) found and fixed: shelf and toast labels truncating short text (label cells need padding);
the image chip's thumbnail overlapping its size at Larger text; accent “on” text too weak in dark;
the drop outline invisible offscreen (was a layer border); the tether preview composited with copy
(erased the desktop); the toast preview ignoring the preset's appearance.

Not verified: any live window; real app icons in the chip (layered macOS 26 icons render as a black
tile into offscreen bitmaps, so previews use a drawn stand-in); glass over busy wallpapers; drop
hover on the non-activating panel; the tether's live event path; VoiceOver with the chip and shelf.

## 2026-10-02 voice, instant previews, cards and streaming (offscreen-verified only)

New states extend Whisper; nothing replaces the bar, reader, presets or materials.

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| MEDIUM | `PromptPanel.swift` (listening) | No voice state | Same bar; transcript in the editor (finished words label ink, tentative tail secondary ink); accent waveform disc in the send slot whose opacity follows the input level (static under Reduce Motion); “Listening…” placeholder; dimmed ellipsis while transcribing | Voice feedback without new chrome or motion |
| MEDIUM | `PromptPanel.swift` (inline preview) | None | Right-aligned `= 51` (accent, monospaced digits), action hints in secondary ink, refusal with an orange symbol and readable ink; label ink in Contrast / Increase Contrast | Raycast-style answer before Return; WCAG-safe colours |
| MEDIUM | `PromptPanel.swift` (typed lists) | None | File/app results on the reader material above the bar (bar stays anchored, grows upward); the composer keeps focus; ↑/↓/Return/⌘Return/⌘⇧C act on the list | Keyboard-first results without moving focus |
| MEDIUM | `PromptPanel.swift` (reader cards) | Markdown only | One `CardView` in the reader for instant and agent cards; lists take focus, typing redirects to the follow-up composer; recalled cards read-only | B8 integration notes; first-responder/scroll preservation (HIGH rule kept: the focused card is never hidden during layout) |
| LOW | `PromptPanel.swift` (confirmation) | None | Small non-key capsule “✓ Opened Figma”, gone after 1.2 s | Confirms an action without stealing focus |
| MEDIUM | `PromptPanel.swift` (streaming) | Working capsule until done | Reader fills progressively (≤ 30 Hz), scroll kept, **without taking keyboard focus** (a click still focuses it); the bar keeps the capsule's controls: “–” continues in the background, “■” stops, Escape/close hides (“Answering… · Escape hides”); completion takes focus as before | Faster perceived answers without stealing keystrokes typed into the pinned app; a reflex Escape no longer cancels the run |
| LOW | `AnswerRenderer.swift` | Permission CTA only | Voice failures (`microphone_denied`, `speech_denied`, `voice_unavailable`, `voice_asset_missing`) with “Open Voice Settings…”; presenting never prompts | Recoverable failures |
| LOW | `SettingsWindow.swift` | One tall page | General / Voice / Classifier segmented pages, original General controls and order kept, Auto first with bias labels | Room for voice/classifier without a taller window |

Final-review fixes (same day, offscreen-verified):

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| MEDIUM | `PromptPanel.swift` (inline preview) | Word-wrapping label in a one-line frame: `2^100` showed a bare “=”, hints/warnings lost words, `= ≈ 1,55 miles`, value ~7 pt below the draft with Larger text | One line with a truncating paragraph style; values shrink (15→13→11 pt) and then show `≈ 1.27 × 10³⁰` (never dropping digits) or “Return for result”; no doubled sign; short drafts give hints room (“↩ Sleep display” when even that is short); the label sits on the draft's first line | Whole, legible previews at both text sizes |
| MEDIUM | `PromptPanel.swift` (failure reader) | Height from the layout manager, frame from the cell: the last line (the remedy) was clipped at Larger text | Measured with the field's own cell and one shared 139 pt inset; ellipsis if the 320 pt cap is ever reached | Recovery instructions always visible |
| MEDIUM | `PromptPanel.swift` / `CardView.swift` (VoiceOver) | Only `= value` was announced; list selection changed silently | Hints, warnings (medium priority) and lists (“3 files… Return opens …”) are announced once; ↑/↓ announce the row and “2 of 3”, post selected-children changes and move the VoiceOver cursor in the reader; nothing is spoken while listening | Return acts on what VoiceOver users heard |
| LOW | `PromptPanel.swift` (voice off) | A hold looked like a tap; voice was undiscoverable | “Voice is off — turn it on in Settings → Voice” as the empty composer's placeholder on a real hold (≤ 3 times, never once voice was on); status menu “Turn On Hold to Talk…” | Discoverable without changing the off default |
| LOW | `PromptPanel.swift` (listening disc) | Level-driven opacity down to 45–62 % | ≥ 85 %, full accent while transcribing and under Contrast / Increase Contrast | Glyph contrast ≥ 3:1 |
| LOW | `SettingsWindow.swift` | “Open System Setti…”; Auto named twice; Apply/Return on pages whose switches apply at once; Laya only via env vars | Buttons sized to their titles with row-specific VoiceOver labels; Auto's Model row reads “Chosen per request” (disabled); Voice/Classifier pages show one Done; Python and Model folder pickers with plain-sentence status | Settings that say what they do |

Verified: `pi-os-ui-preview --snapshot` rendered every new state offscreen (never a window)
for System, Frost, Contrast and Graphite in light and dark; contact sheets were inspected and
two issues fixed (duplicated streaming status; low-contrast orange refusal text, now a
coloured symbol + readable ink). Frost/Contrast are light presets by design, so their dark
renders match the light ones. Snapshot materials are approximations: native glass and
vibrancy only exist in the window server. 47 new CPU tests cover the flows and layouts.

The final-review states (big-1/2/3, instant-unit, hint-web, confirm-hint, voice-hint,
streaming with its new bar controls, the four voice failures, the classifier pickers) were
rendered for the same presets at standard **and** Larger text (`--larger`) and inspected.

Not verified: any live window, real glass over busy wallpapers, VoiceOver announcements
(previews, list selection, the reader's VoiceOver cursor following ↑/↓), whether a streaming
reader really leaves keystrokes with the pinned app, physical keyboard/IME during listening,
Carbon key-up timing, live microphone. No custom
animation was added; the level meter only changes opacity.

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
