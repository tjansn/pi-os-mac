# pi-os — disposable native glass studies

**Selected: Whisper (2026-10-01).** Implemented natively in installed build 12;
see `../../host-macos/UI_NOTES.md`. These prototype files remain disposable and do
not power the native UI.

**Design prototypes only.** No AppKit changes, installation refresh, model calls,
application control, real permissions, preference persistence or clipboard writes.
These files are intentionally isolated from the shipped app and harness.

## Open

Double-click `compare.html`, or from the repository root:

```sh
open prototypes/native-glass/compare.html
```

No server, package installation, CDN, remote image or build is required. The wallpaper
is an original local SVG. All simulated content is fictional.

- **Compare:** `compare.html` — same preset/state across three directions.
- **Playground:** `index.html` — interactive, full-size desktop preview.
- **Clear:** `index.html?direction=clear` — 640 × 58, continuous glass capsule.
- **Shelf:** `index.html?direction=shelf&theme=frost` — 680 × 60, native utility shelf.
- **Whisper:** `index.html?direction=whisper&theme=graphite` — 480 × 50, minimal chrome.

CSS pixels approximate Mac points at normal browser zoom. Compare thumbnails are
scaled; use the full-size playground to judge typography and hit areas.

## What to judge

1. Which silhouette: capsule, soft rectangle, or micro capsule?
2. Detached answer above the bar, or Shelf's connected answer/composer?
3. Clear vs Frost vs Graphite vs Warm vs Contrast? They work with every silhouette.
4. Does the bottom placement feel right at 20, 32 or 48 pt?
5. How much context should stay visible? Shelf shows Notes; the other two tuck it
   behind π. Whisper also puts appearance options there.

**Focus view** hides the review controls, not the application. The preview stays
bottom-centered, 32 px above the viewport's lower edge by default, growing upward.
The optional simulated Dock adds clearance instead of overlapping the bar.

Appearance options: five presets, larger text, reduced transparency, Dock preview
and lower-edge distance. They never change the fictional pinned target or permissions.
URL values make visual combinations shareable; prompt text is never put in the URL.
Nothing is saved to local storage.

## Interactions

- Type and Return: simulated work, then a static demo answer after 1.8 seconds.
- Shift-Return: newline; the default remains one line until multiline input is needed.
- Answer: follow-up composer below; outside clicks don't dismiss it.
- Escape: closes an open popover first, then explicitly closes the conversation.
- Working: cancel, or hide/show the simulated task without restarting it.
- Error: explicit unavailable-target state; never silently switch to another target.
- Copy: feedback preview only. The user's real clipboard remains unchanged.
- `⌘K` / `Ctrl-K`: focus the composer. The actual pi-os global hotkey is NOT registered.
- Top state buttons: hold Ready / Working / Answer / Error for visual inspection.

## Native implementation direction, once selected

Keep the Swift/AppKit host. These are not proposals for an embedded website.

- Position against the **pinned target display's visible work area**, not the cursor
  or the pinned window's center. Respect the Dock, menu bar, display scaling and safe areas.
- Use system font and real SF Symbols, native text editing, native control semantics,
  keyboard focus and accessibility labels. Hand-drawn SVGs here are stand-ins.
- Use the OS's available native glass/material API, with a compatible material fallback
  on supported older macOS versions. CSS blur cannot reproduce native Apple refraction.
- Make themes a small appearance-token layer. Default to system appearance and honor
  Reduce Transparency, Increase Contrast and Reduce Motion. Presets must not override
  those accessibility choices or change target/security/cancellation behavior.
- Keep a readable denser material for the answer, not transparent text over busy content.
- Open/close and keyboard actions should be immediate, not animated. Only small pointer
  press/hover feedback; no decorative morphing on a high-frequency command surface.
- Preserve retained conversations, fresh per-turn action authority, and explicit close.

## Prototype validation

`node test-prototypes.mjs` uses an **isolated headless agent-browser session** named
`pi-os-native-prototypes`. It never auto-connects to the user's Brave. **72 checks pass**:
3 directions × 5 presets × 4 states, narrow layout / larger type / Dock clearance,
multiline submission, simulated results, outside-click persistence, appearance/context
separation, opaque fallback, explicit close/cancel and background completion.

`review-checks.json` contains the bounded result. Screenshots are under `screenshots/`.
Inspected visually: Clear ready/answer, Frost Shelf answer over a mock document,
Graphite Whisper ready/appearance, comparison ready/answer, and the additional captures.

Small issues corrected during prototyping:

| Before | After | Why |
| --- | --- | --- |
| Shelf's divider added an extra pixel to its bar | Divider is inside the composer box | Stable 60 px bottom anchor |
| Showing a background demo could clear its completion timer | Show restores the same pending simulation | No accidental replay/restart |
| Popover placement assumed a one-line editor | Popover follows measured composer height | Multiline input stays unobstructed |
| Small light/warm placeholder text was too faint | Darker neutral placeholder tokens | Better readability through the material |

**Not verified:** native Apple glass rendering, VoiceOver, Safari, physical keyboard,
10%-speed motion replay, contrast over every possible wallpaper, and all OS accessibility
preferences. There is no approval of production UI or native behavior from these tests.

For this inspected disposable scope: **Approve for design comparison**, not implementation
or full accessibility sign-off. Pick a direction (or a hybrid) before touching AppKit.
