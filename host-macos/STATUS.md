# macOS port — implementation and acceptance

2026-09-15. Target machine: Apple Silicon, macOS 26.5.2, Xcode 26.6 / Swift 6.3.3,
Node 24.15.0. Deployment target is macOS 14; that OS has not been exercised here.

## 2026-10-08 continuity — Mac side; stage A installed (main e9ab5ca), the rest built and tested offline, NOT installed

Branch `feat/continuity`. Tom: after "open Safari", the next command acts in that Safari window, and the next words go
into the field that has the caret, while questions about the page still go to the agent. Overview, Tom's decisions,
the decision order and what is measured: [VOICE_MAGIC.md](../VOICE_MAGIC.md#pass-5-2026-10-08-continuity); wire:
[protocol.md](../shared/protocol/protocol.md) "Continuity"; live QA plan: [qa/continuity/README.md](qa/continuity/README.md).
**Installed:** stage A only (links in the browser in front, the wire contract). Everything else here is not in the
installed app; refresh only with `PI_OS_SIGN_IDENTITY` (never ad hoc).

- **Links in the browser in front** (stage A, installed; `LauncherService.swift`, `PiOSCore/BrowserFamily.swift`):
  `execute(.openURL)` picks a browser after `validateURL` (a browser pi-os launched ≤ 5 s ago with no other activation
  since, unless the take chose its target explicitly; else the take's pinned app if it is one of 20 allowlisted bundle
  ids, matched case-insensitively; else the default handler) and opens through `NSWorkspace.open([url],
  withApplicationAt:)` with `activates = true`, for instant acts and the agent's `launcher.open` alike. A refusal falls
  back to the default browser with an `open_fallback` note. `PendingLaunches` keeps the launched app's
  `NSRunningApplication` (dropped on another activation, failure, quit or after 5 s). `launcher-actions.jsonl` gets the
  closed `browser` label (launching, pinned, default, fallback). No Apple Events, no new permission.
- **Anchor and race** (`PiOSCore/Continuity.swift`, `Application.swift`, `ContextChipController.swift`): the 120 s
  anchor from a successful pi-os open on either route; settle (front app, first on-screen window and focused window
  agree; 25 ms polls, ≤ 1.5 s / 4 s cold; the first AX message to the new app, which also wakes a Chromium web tree, is
  paid there); dropped on another activation, quit, process change, window off screen at key-down, 120 s, Not
  this / No I meant on the opening take, sleep, lock, session resign and computer control off. A take that starts while
  a launch is pending or settling (≤ 5 s) is marked awaiting (no field bound, chip "Safari (opening…)"), re-pins through
  `retarget(…, include: false)` when the launching app is in front with a window before the final, and waits ≤ 150 ms
  at the final. Explicit choices (Tab, ⇧ chord, tether, pointing, Ask About This Window…) ignore the anchor and skip a
  pending launch for links. Chip tooltip "· opened by your last command".
- **Field facts** (`PiOSCore/FieldKind.swift`, `FieldFacts.swift`, `DesktopAX.swift`, `CredentialFields.swift`): four
  quick reads after today's key-down summary (inside the existing 25 ms cap), the classification off the main thread
  after the bar (≤ 24 ancestors, labels matched against closed EN/DE lists and dropped, lengths only, nothing for a
  credential field), and the app's own focused element re-read at the final as the `BoundField` (`CFEqual`, else pid,
  role, frame and DOM id). Kinds: credential, rename (Finder), confirm, sensitive, terminal, address, search, text,
  multiline. Not ready: frame mostly outside the window, a loading or nested web area, an incomplete ancestor walk with
  no web area seen, a selection in a text field, text area or terminal, focus that moved between two eligible fields
  during the hold. WebKit's `AXValueAutofillType` credentials/strong password marks a credential field.
  `AXManualAccessibility` is set only for allowlisted Chromium browsers, once per process (never Electron apps, C9).
- **Fills** (`FillSession.swift`, `CommandController.swift`, `PromptPanel.swift`, `NativeInput.swift`,
  `PiOSCore/TextInput.swift`, `LauncherPolicy.swift`): finals carry the content-free `target`; `accept` gains `fill`
  only with the Settings switch on, computer control ready, a bound field, and for credential or code fields the
  credential opt-in. A fill hides the bar, types one line (`TextInput.singleLine`) through `DesktopService.act` bound to
  the field (focus regained within 120 ms, every event re-checked), adds one separating space after other text, then
  presses Return as its own gated `pressKey` only where `LauncherPolicy.pressesReturn` allows it for the host's bound
  field (search box, address bar) and the lengths show the field holds exactly the typed text. Undo (bare "nein/no" or
  the note within 5 s): exact element, lengths and caret match, typed range selected and read back, one gated
  Backspace; refused when unproven; after a submitted search nothing is deleted ("Already searched — go back with ⌘[").
  "nein, X" replaces within 30 s (`ownFill` on the wire), Ask pi undoes and asks. The check card's fill offer types the
  (edited) card text without Return. Read-only mode reports only credential or code fields (`reportedField`), never
  declares a fill.
- **Password and code fields** (critic C5): every undecided fallthrough (all reasons but `deictic` and `compound`, below
  the window band, not "frag pi …"), and a final with no answer, shows the masked card ("Password field — pi didn't send
  this anywhere", "•••", "↩ Type it" only with the opt-in and a bound field, else the reason; "⌥↩ Ask pi anyway"). The
  words never show in the bar or a live preview, are never journaled (`VoiceJournal.keeps(field:)`), never offered on
  Copy, and a secret fill keeps no text in memory.
- **Typing path for everyone:** the Unicode payload goes on key-down only (`PI_OS_TYPE_KEYUP_PAYLOAD=1` restores it),
  the per-event duplicate inspect is gone, and `PI_OS_TYPE_CHUNK` (off by default) sends ≤ 20 UTF-16 units per event.
- **Settings:** Voice → "Type into the focused field" (default on; the kill switch). General → "Allow input in username
  and password fields" keeps its title; its tooltip and consent text now name code, PIN and payment fields.
- **Safari same tab** (`SafariAddressRoute.swift`, `PI_OS_SAFARI_SAME_TAB=1`, default off): `AXValue` + `AXConfirm` on
  Safari's empty start page pi-os just opened, verified ≤ 1.5 s; an unknown outcome ends as a note with "Open in a new
  tab", never a second copy on its own.
- **QA fixtures** (`PiOSInputFixture --continuity`, `qa/continuity/page-fixture`, `ax-counts.swift`): live QA only,
  with Tom; `--self-test` and the page server's tests run in CI without a window.
- **Logs:** `[perf] fill kind=… outcome=… return=… verify=… ms=…` and the `[launcher] … browser=…` line of a link (with
  `PI_OS_PERF=1`), closed vocabulary only; never a value, label, title, URL or transcript. Fills go through
  `FillSession`, not the launcher, so `launcher-actions.jsonl` has no line for them (its `submit` label belongs to a
  launcher-path `typeIntoPinned` with `submit`, which no host path sends today).
- **Verified offline** (the integration head, `afb2f72` plus the docs): `npm run check` and `npm run build` clean;
  guarded `npm test` 731/731; `swift build` and `swift build --build-tests` after `swift package clean`, 0 warnings;
  `PI_OFFLINE=1 PI_OS_AGENT=0 swift test` 858 tests, 0 failures, 3 skipped (the 2 Parakeet opt-in tests and the opt-in
  live desktop probe); `npm run test:macos` 1/1.
- **Not verified live** (Q1–Q11 in the QA plan): Safari's empty-tab reuse and `AXConfirm`; WebKit/Chromium field kinds
  for real search boxes; `CFEqual` identity between the per-app and system-wide focused element for web fields (pass
  or fail for every fill); the 120 ms focus settle; selection read-back for Undo and the length check per engine;
  chunking and the key-up payload per engine (Electron); the race on a cold launch; Spaces, full screen, Stage Manager.

## 2026-10-08 visible items and auto-minimize — Mac side, installed 2026-10-08 (signed, main 1f114f1)

Branch `vis/swift` on `feat/visible-open` (contract `53ede15`). Tom: "öffne Radfotos" on the desktop should open the
desktop's folder first, and a request that ends by opening something can hide its answer. The installed build is
**stale** (refresh only with `PI_OS_SIGN_IDENTITY`).

- **Visible items** (`VisibleItems.swift`): at key-down (typed and spoken takes, and a tether's new pin) the host
  classifies the target (Finder desktop surface → `desktop`, another Finder window → `finderWindow`, anything else →
  none) and captures on a background queue: the desktop's icons through the same unambiguous container match desktop
  input uses (scroll area → group → AXImage icons with file URLs; ≈ 3–30 ms live), or the window's items whose URL is a
  direct child of its AXDocument folder (sidebar, path bar and expanded subfolders drop out). No readable item (icons
  hidden, no AX) → Spotlight `kMDItemDisplayName == "*"` scoped to the folder, direct children only (`kMDItemFSName ==
  "*"` matches nothing; a 13 000-item desktop subtree took ≈ 650 ms). AX budget 0.3 s, ≤ 2 000 elements, ≤ 200 items,
  hidden names out; no AppleScript, Apple Events, FileManager enumeration or file access (folder vs file from the URL's
  trailing "/", type from the extension). `POST /tools/launcher.visibleItems` (token-authed, read-only, served while
  control is off, cancelled when its client leaves) answers from the capture, waits ≤ 150 ms for one still running
  (then `complete:false`, no items), mints tokens only for returned items, bound to the take's context; the capture is
  dropped and its tokens revoked with the context. Served but not in `GET /tools` (the agent's launcher tools depend on
  exactly the advertised list). Perf line (PI_OS_PERF=1) carries kind, via, counts and durations only.
- **Bar** (`CommandController.swift`): an `open_item` act shows "Opening Radfotos…" and hides after the 0.4 s dwell (a
  reveal downgrade says "Revealed … in Finder"); did-you-mean and choice lists take file rows next to app rows (Return,
  click, 1–3, "ja", "die erste", the row's name — "Rad Fotos" matches "Radfotos", extensions optional), each performing
  its own action through `LauncherService.perform`; file rows and file acts never call `/dictionary/learn` and never
  offer "Not this".
- **Auto-minimize** (`AutoMinimize.swift`): `InvocationEffects` records the agent's last screen effect (a successful
  `launcher.open` for the invocation's context via `LauncherService.onAgentOpen`; any later input, capture, Brave or
  open attempt via a `DesktopService` observer; any later agent tool but `show_result`/`thinking`/`open_item`), and the
  completed record's step log must show no tool after the last `agent.open_item` but `agent.show_result`/`agent.run`
  (a Node-only tool such as `find_files` can end between two streamed records and leave no activity). A
  completed, visible answer that is not a question and whose card waits for nothing (no suggestion, no ask, < 2 rows)
  shows for 0.8 s, then `PromptPanel.stepAside()` orders it out with its thread and follow-up composer kept; the note
  "Opened Radfotos · Show" (Show, or Show Last Answer, brings it back). Settings → General "Hide the answer after pi
  opens something" (default on, applied at once). Failures, cancels, questions and instant acts never minimize.
- **Live check (read-only):** the production source on the real desktop found the folder whose key is "radfotos" as a
  directory via AX (3 desktop windows, 7 items each, complete; names and paths not printed).

## 2026-10-07 voice reliability (pass 3) — Mac side, built and tested offline, NOT installed

Branch `feat/voice-reliability` (`3036435` … `3764700` on `dd0126d`); overview, measurements and safety rules in
[VOICE_MAGIC.md](../VOICE_MAGIC.md#pass-3-2026-10-07-voice-reliability), UI changes in [UI_NOTES.md](UI_NOTES.md).
The installed build is **stale**: it still runs one SpeechTranscriber locale and today's bar. Refresh only with
`PI_OS_SIGN_IDENTITY` (never ad hoc), with `PI_OS_VOICE_JOURNAL_OPT_IN=1` the first time for Tom.

- **Engine, Apple both languages** (`VoiceInput.swift`, `VoiceArbiter.swift`): one SpeechAnalyzer per take with a
  DictationTranscriber for each checked language (short-form hint, volatile results, alternatives, word confidence),
  SpeechTranscriber fallback for a language without a dictation model, up to 100 contextual strings at key-down,
  the audio stream ended before the engine stops, a 16 kHz Int16 tee of the whole take (capped at the 125 s capture
  limit) for Parakeet and the journal. `finishTake()` returns a `VoiceFinal` (every hypothesis with source, role,
  confidence and minimum confidence, ≤ 2 n-best per language, content-free timing, the audio); an empty take is an
  explicit empty final. The arbiter merges DictationTranscriber's doubled finals by audio range, keeps the bar's
  live language stable, waits for the slower language until key-up + 150 ms and picks the locale hint with
  `NLLanguageRecognizer` among the checked languages.
- **Parakeet TDT v3** (`ParakeetEngine.swift`): FluidAudio 0.17.5 pinned exactly, `NemoTextProcessing` trait off,
  tools version 6.1 with every pi-os target in Swift 5 mode. CPU + Neural Engine, never the GPU; loads with
  `AsrModels.loadLocal` (only the verified install, never FluidAudio's own downloader); one decode at key-up,
  partial re-decodes every 0.5 s. A loaded model joins the take as the primary engine and the Apple modules become
  secondary; `finishTakeStages()` yields `.primary` (Parakeet) and then `.complete` (every engine). A failed or
  stalled Parakeet drops out and the take settles as in Phase A. FluidAudio's logger is set to errors only.
- **Speech model store** (`SpeechModelStore.swift`): Hugging Face `FluidInference/parakeet-tdt-0.6b-v3-coreml` at
  revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`, 21 files (483,105,645 bytes) with sizes and SHA-256 pinned in
  code (`SpeechModelDescriptor.parakeetV3` equals `ParakeetModel.descriptor`). Staged download, every file verified,
  one rename into `<support>/models/parakeet-tdt-v3/` (0600/0700, excluded from backups); cancel and delete clean up.
  The download and every load take a non-blocking flock on the local-inference lock (`deferredByLock` while held;
  a deferred download keeps waiting instead of falling back to "Download"); per-take inference takes none.
  `prepare()` never downloads.
- **App wiring** (`Application.swift`): one store in the harness's support directory (a fixture's
  `PI_OS_SUPPORT_DIR` in installed-test runs); `prepare()` detached at utility priority at launch with voice on, on
  any Voice setting change, when Settings → Voice opens with voice on, and after a take while deferred, never on
  the hotkey path. `migrateLanguages()` runs once before the first readiness check; takes start only the checked
  languages. With voice on, Node starts at launch (`startForVoice`, `/health` polled every 20 ms for the first
  second, no idle stop unless `PI_OS_NODE_WARM_TTL_SECONDS` is set), and cancelling a running task stops Node and
  starts a fresh one off the hotkey path. `HarnessClient.warm()` fix: a key-down warm that arrives while a restart waits for the old
  child to exit now joins that restart instead of timing out as "still stopping".
- **Command flow and bar** (`CommandController.swift`, `PromptPanel.swift`, `ShelfToastView.swift`): voice finals send
  `hypotheses`, `accept [suggest, check, confirm]` and the spoken locale. Two-step final: Parakeet's final goes alone
  (seq N); an act, answer or refusal settles the take, a list or fallthrough shows nothing and waits for the complete
  final (seq N+1, same `takeId`, every hypothesis), so one take never shows two decisions. Timeout keeps an unsettled
  Parakeet partial out of the primary slot. New states: "Didn't catch that", "Did you mean …?" (Return, click, 1–3,
  ↑/↓ or a spoken answer on the next hold), "Open X? ↩", "Did I hear that right?" (text selected, ≤ 2 other readings
  as chips, none when any reading mentions deletion), "Opening Pages…" (launch not awaited; a later failure is a
  note), "Not this" (note button or a spoken/typed "no" within 5 s, after sound, learned, alias, peer or secondary
  acts), "No, I meant X" (marks the earlier take undone, learns from the words that said it, asks once), the learned
  footer with Undo. Voice preview debounce 0; dwell 0.4 s. Suggestions on agent cards for a spoken request go
  through `/instant` first. `/invoke` reuses the take's `takeId` with `input.engine` of the deciding hypothesis.
- **Recognizer terms**: fetched at launch, whenever a learn or edit response (bar or Settings) brings a new
  revision, and after a take if the launch fetch never succeeded; never at key-down.
- **Voice journal** (`VoiceJournal.swift`, `VoiceJournalPolicy.swift`): opt-in `voiceJournalEnabled`, last 50 takes in
  `<support>/voice-takes/` (`<takeId>.wav` ≤ 15 s 16 kHz mono, `<takeId>.take` record), 0700/0600, atomic writes,
  never through a symlink, excluded from backups, self-repairing listing, no logging or network code (scanned by a
  test). Appends and updates run off the key-up path in order; learn requests that would commit a rule carry the
  accepted takes' text as the regression check.
- **Settings** (`SettingsWindow.swift`, `RecognitionSettingsView.swift`, `DictionarySettingsView.swift`,
  `RecentTakesView.swift`): Voice → Languages I speak (per-language Download) and Recognition (consent sheet, progress
  + Cancel, Neural Engine preparation, waiting for the lock + Try Again, Ready + Delete, never "Not available in this
  build" for the shipped model); a new Dictionary tab (learn mode, Apply to the recognizer, Explain to pi; App names,
  Phrases, Fixes, Words; edit, switch, pin, delete with Undo; Add Word…; Export… 0600 / Import…; Forget
  Everything…) with Recent takes (journal switch, ▶, Fix…, delete one or all). Every Settings write refetches the
  recognizer terms. Installed-test runs use a fixture voice-settings suite.
- **Voice timing log** (`VoiceTimingLog.swift`): `<support>/logs/voice-perf.log`, one content-free line per take
  (hold, first partial, finish, each recognizer's final, cut modules, hypotheses, finals sent, decide, hidden, decision
  kind, source, recognizer, via, reason), 256 KB × 2 generations.
- **Packaging** (`build-app.sh`, `refresh-install.sh`, `Info.plist`): FluidAudio's resource bundles are signed with
  the app's identity before the app; `THIRD_PARTY_NOTICES.md` and FluidAudio's licence texts ship in
  `Contents/Resources`; `refresh-install.sh` blocks a nested bundle without the app's certificate, rebuilds the Node
  dist only after every gate passed, and with `PI_OS_VOICE_JOURNAL_OPT_IN=1` turns the journal on once (only if the
  setting was never set). The microphone text now says audio is kept only with *Keep my last voice takes*, on this Mac;
  the bundle identifier and certificate, and so the code requirement, are unchanged.
- **Developer bench** (`PiOSVoiceBench`, `pi-os-voice-bench`): WAV files through the production engines, JSONL for
  `node-harness/scripts/voice-eval.mts`; holds the local-inference lock itself (exit 75 when held). See
  [qa/voice/README.md](qa/voice/README.md).

**Verified offline** (final tree `3764700`): `swift build` and `swift build --build-tests` 0 warnings;
`PI_OFFLINE=1 PI_OS_AGENT=0 swift test` 712 tests, 0 failures, 2 skipped (the `PI_OS_PARAKEET_MODELS` opt-in tests);
guarded `npm test` 652/652; `npm run test:macos` 1/1. The Apple and Phase B `say`-file replays ran under their own
non-blocking lock. Offscreen snapshots of every new bar state and Settings page in every preset, light and dark.
Synthetic measurements (`say` speech only) are in VOICE_MAGIC.md.

**Not verified live:** real microphone takes and accuracy on Tom's voice; the real Parakeet download, first Neural
Engine compile and loads in the running app; the real one-versus-two-finals split and latency (the timing log now
records it); the Node restart after a cancelled task in the running app; Microphone/Speech Recognition grants with the new
permission text; Bluetooth headsets; VoiceOver for the decision header, chips and notes; the 1–3 keys on non-US
layouts; NSAlert/NSSavePanel/NSOpenPanel and real AVAudioPlayer playback in Settings → Dictionary. Known gaps:
Escape does not count as "Not this" (no global key monitor); the journal record does not say which hypothesis
decided (Fix scopes to the first first-tier hypothesis); Phase B needs at least one Apple dictation model; the
check gate's 0.2 threshold was calibrated on Apple word confidence, not Parakeet's token confidence.

## 2026-10-05 final-review fixes (Mac side, wp2/f1-axwire), built and tested offline, NOT installed

- **One credential rule** (POL-1): native AX now runs the web rule (`CredentialFields.identified`
  over a `LiveAXNode`): native and DOM identifiers, a label element's title, value or description
  (never a text-entry label's value), fail closed on an unreadable label element. Pointing, ⌃⌥⌘C,
  the hotkey's selection, native typing and click destinations all use it, so a Brave field named
  only by `AXDOMIdentifier` or a static-text label is never read or typed into by default.
  `InputSurfaceInspector` reads the DOM id too (DeletionPolicy markers such as `delete-file`).
  The selection gate also fails closed when a role or a text input's subrole read goes unanswered
  (POL-3).
- **Follow-ups** (L1, wire-2, wire-1): the host never captures before `POST /followup`; the
  harness is the only follow-up capturer. The follow-up chip starts from the record's `included`
  (on after the agent pulled the window in, off after the user narrowed; `pulled` alone never
  re-widens; older harnesses keep the host's scope).
- **Files** (wire-3, C2): each path-only file attachment gets a launcher token for the request's
  context when the request is sent (`ShelfController.wireAttachments`), so the agent can open or
  reveal dropped and copied files (never read them); tokens are revoked with the context. Image
  files dropped or copied from Finder become shelf PNGs (up to the image cap; symlinks, undecodable
  and other files stay references; the user's file is untouched).
- **Pointing** (UX-1, UX-2): an element of the take's window includes that window as a
  non-sticky suggestion that follows the element chip (Tab and *Only when I ask* still win); a
  pointed-at element no longer counts as shelf content. An element of another window re-pins the
  take there (as the tether, without a sticky choice) unless the take is committed to its window;
  then the element goes with a read-only window chip (protocol pairing rule), added and removed
  together.
- **Chip and copy** (C1, UX-3, UX-5): `deixis-content` lets shelf content take “summarize the
  selection” / “what is this image”; the off chip tells “pi may look” from “left out · pi won’t
  look” (struck-through icon, AX value “left out”); Settings and README no longer promise that
  nothing is sent while the chip is off. The π popover hint fits its label (a long app name
  truncates in the middle); the menu bar gains *Add Selection to pi* (⌃⌥⌘C's path, after the menu
  closes) and *Point at an Element…*; the Suggest note names ⌃⌥⌘⇧Space.
- **Smaller fixes:** ⌃⌥⌘C's Copy fallback never runs in read-only mode (POL-4); the captures path
  is standardized once (wire-4); VoiceOver's show-menu opens the chip menu (UX-6); “Pointing at …”
  uses label ink without the ⌖ glyph (UX-9); a drag in the follow-up composer says “Pointing works
  on a new question” (C7).

**Verified offline:** `swift build` 0 warnings; `PI_OFFLINE=1 PI_OS_AGENT=0 swift test` 477/477;
node `npm run check`, `npm run build`, guarded `npm test` 515/515, `npm run test:macos` 1/1. The
installed build stays **stale**; refresh only with `PI_OS_SIGN_IDENTITY` (never ad hoc).

## 2026-10-05 general by default, context shelf, pointing, Brave access — Mac flow + UI (S12), built and tested offline, NOT installed

Branch `wp2/s12-mac` on `feat/context-shelf` (Phase-0 contracts and the seven Wave-1 components).
The installed build 12 is **stale**: it still opens every take on the window and uses CDP for Brave.
Refresh only with `PI_OS_SIGN_IDENTITY` (never ad hoc). The Node side has landed on this branch
(`context`/`attachments` parsing, wp2/n4-server 21a93e0; the Brave Accessibility transport in agent
sessions, 83daffc), so the remaining gate is the signed refresh itself and the live checks below.

- **Key-down** pins identity only (CG window, focused element before the panel; the process
  fingerprint at insert). No screenshot, no CDP. The Brave AX tab pin runs after the panel is on
  screen (`[perf] brave-pin-after-panel`). The window capture is lazy (`TakePreparation`
  `startCapture`): it starts when the chip first becomes suggested/on (`[perf] capture.window`),
  never for a general take; a general submit neither waits for nor fails on it; a window submit
  whose capture fails continues text-only with a note.
- **Context chip** (`ContextChipController`, `ContextChipView`): off/suggested/on from every
  `/instant` `scope` and the S6 on-device scorer through `ContextScoreThrottle`, fused only with the
  rules score of the same text. `ContextChoice.fuse` fixed: the local score never decides alone
  (DESIGN2 §4.2); follow-up upgrades now also need a screen-anchored reason (as Node's
  `followupScope`). Tab/click (sticky), ⇧ + hotkey (second Carbon chord), *Ask About This Window…*,
  *Settings → Context → Active window* (Only when I ask / Suggest / Always). `/invoke` and `/followup`
  carry exactly the chip's `context`; the follow-up composer has the thread's chip (debounced
  `/instant` typing scope, never retargeted; since the final-review fixes only the harness captures
  the thread's pin for a widening follow-up). Copy: “Ask anything…”, “Looking at Brave…”, reader header and “· Brave included” only
  when included, “Looked at Brave” when the agent pulled.
- **Context shelf** (`ShelfController`, `ShelfChipsView`, `ShelfToast`): ⌃⌥⌘C “Add to pi” (Carbon
  chord, target taken before anything is ordered front; non-activating “Added to pi”), the pi
  hotkey's live selection (AX only, take-scoped), drops on the bar/reader/menu-bar π (the editors no
  longer take drags), *Grab an Area…*, clipboard suggestion (types only until +; pi-os's own copies
  and ⌃⌥⌘C's restore are never suggested). ⊗, ⌫, preview popover, caps, idle expiry, menu-bar count
  and *Clear Attachments*. Sent items leave the shelf only once `/invoke` accepted them; their PNGs
  are deleted when the thread closes.
- **Attention overlay** (`AttentionController`): drag the chip or π → tether → window (re-pinned as
  the take's context with the Brave pin, included, captured anew, old pin removed unless an element
  still names it) or ⌥/“Point at an Element…” → element attachment; “Pointing at …” on the message.
- **Brave**: *Settings → Context → Brave access* (Accessibility default / DevTools opt-in through the
  existing sheet), *Act in Brave in the background*, the brave://inspect switch-off note; menu and
  General button renamed *Brave Access…*. S4's note fixed: only a DevTools pin makes ⌘Return copy;
  the “Brave tab” capability label only for DevTools.
- **Hotkey conflict check fixed**: compares the plist's NSEvent masks (⇧⌃⌥⌘ only, fn ignored) and
  knows unstored macOS defaults (⇧⌘3/4/5, ⌘Space, ⌃Space …); a stored entry wins.
- **build-app.sh** copies `context-scorer-weights.json` into `Contents/Resources` before codesign;
  signing rules unchanged.
- **Review fixes:** shelf content takes “this”/“it” but no longer hides a screen-anchored reference
  (“summarize this page”, “click Send” still suggest the window next to a selection); holding ⌫ to
  clear a draft no longer goes on to remove attachments (key repeat); a pending *Point at an
  Element…* pick is cancelled when the question is sent or the take ends (it would otherwise
  consume the next click in another app); a lost ⇧-chord release can no longer swallow the next
  hotkey release.

**Verified offline:** `swift build` 0 warnings; `PI_OFFLINE=1 PI_OS_AGENT=0 swift test` 458/458
(413 + 45 new: ContextFlowTests 17, ContextChipTests 10, ShelfUIFlowTests 11, ContextSettingsTests 6,
CommandFlowTests 1; ContextChoiceTests and PanelPreviewTests extended); node `npm run check`, `npm run build`, `npm test`
480/480, `npm run test:macos` 1/1. Offscreen `--snapshot` PNGs of every new state (System, Frost,
Contrast, Graphite × light/dark, standard and Larger text) were inspected; fixes from that pass are
in [UI_NOTES.md](UI_NOTES.md).

**Pending live checks** (signed build, coordinated desktop, harmless fixtures only): Carbon
registration of ⌃⌥⌘C and ⌃⌥⌘⇧Space next to Tom's shortcuts; ⌃⌥⌘C Copy fallback and clipboard
restore in a real active app (Electron, Office, Preview images); drops onto the non-activating
panel and the menu-bar icon (promised files from Mail/Photos); `screencapture -i` from the signed
app; the tether's global mouse monitors, ⌥ mid-drag, Esc, two displays, a full-screen Space and
no Input Monitoring prompt; Brave AX background press/fill with Brave behind another app; the
`PI_OS_PERF` numbers for the Brave pin after the panel and the lazy capture (DESIGN2 C2/C9); real
app icons in the chip (layered macOS 26 icons do not render offscreen); VoiceOver on the chip and
shelf.

**Node side:** `server.ts` parses `context` and `attachments` on `/invoke` and `/followup`
(`parseTurnContext`) and passes them to the turn and the prompt (wp2/n4-server, merged in 21a93e0);
the Brave Accessibility browser tools are wired into agent sessions (83daffc).

## 2026-10-02 final-review fixes (Mac side, d-swift), built and tested offline, NOT installed

- **File search latest-wins.** `FileSearch` counts searches: a running search skips its
  substring fallback once a newer one is waiting or its caller is gone. The loopback server
  cancels a launcher read (`launcher.searchFiles` / `listApps`, never an effect) when its client
  disconnects, so a search Node aborted never starts and never delays the final one. A
  superseded search whose caller still waits keeps its primary query (the agent's
  `find_files` calls may run in parallel).
- **Records survive a lone surrogate.** Status and SSE records pass through a byte-level
  sanitizer (unpaired `\uD800`–`\uDFFF` escapes → `\uFFFD`) before decoding, so a truncated
  emoji can no longer turn a completed answer into “Something interrupted your request”.
- **Laya can be enabled from the app.** Settings → Classifier has Python and Model folder
  pickers (venv path kept, hidden folders shown), posts them with every other stored field,
  reads `status.layaLaunch`, disables the switch while Laya cannot start, and explains every
  reason in a plain sentence. `bundle-runtime.sh` ships `sidecars/laya/laya_intent_sidecar.py`.
- **Typing previews** go out on the leading edge, then at most every 33 ms with the last text
  always sent (Node holds file search back for 150 ms of quiet); voice partials keep the 150 ms
  debounce. A value is held one interval across a fallthrough so the bar does not blink.
- **Streaming reader** never takes keyboard focus; its bar has “–” (continue in background)
  and “■” (stop); Escape/close hide it while the task runs; completion takes focus as before.
- **Inline preview** is one line, values shrink then compact (`≈ 1.27 × 10³⁰`), no `= ≈`,
  hints keep their key words, the label sits on the draft's first line. **Failure readers**
  measure with the field's own cell (no clipped remedy at Larger text).
- **VoiceOver** hears hints, warnings, lists (“… Return opens …”) and every ↑/↓ selection
  (“2 of 3”); the reader's VoiceOver cursor follows the selection; nothing while listening.
- **Locale and language names.** Typed requests send the formatting locale (`en-DE` for
  English with Region Germany); English sentences say “German (Germany)”.
- **Bluetooth headsets.** An `AVAudioEngineConfigurationChange` restarts capture once on a new
  engine (the old resampler's tail is kept, the 120 s cap is not extended); a second change ends
  the take with a message that suggests the built-in microphone. Unverified on hardware.
- **Smaller fixes.** First-run hint on a voice-off hold (≤ 3×) and a “Turn On Hold to Talk…”
  menu item; spoken “never mind / vergiss es” ends a take; Notice-only final answers go to the
  agent (as `/invoke` does); archives are revealed, not opened (Archive Utility can trash them);
  preview-list actions confirm or fail in the bar; ⌘Return copies over a pinned Brave tab;
  a slow Return shows the “…” disc; `no_authenticated_model:` failures say “Choose a model”
  with Open Settings…; the footer names Auto's model; Settings buttons fit, Auto's Model row
  is “Chosen per request”, Voice/Classifier pages have one Done; listening disc ≥ 85 % accent.

Verified offline (no microphone, speech model, provider, GPU or window): `npm run check`,
`npm run build`, guarded `npm test` 355/355, clean `swift build` 0 warnings,
`PI_OFFLINE=1 PI_OS_AGENT=0 swift test` 268/268, `npm run test:macos` 1/1 (now also aborts a
search and checks live searches still complete). Offscreen snapshots of the changed states at
standard and Larger text were rendered with `pi-os-ui-preview --snapshot` and inspected. The
installed app is stale relative to this branch until it is re-published with the stable
`PI_OS_SIGN_IDENTITY` (AGENTS.md).

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
- **Typing.** `/instant {phase:"typing"}` previews (debounced in C2; leading edge + 33 ms throttle since the final review) (`= 51`, hints, a typed result
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
VoiceOver and the physical-keyboard matrix (including preview/list announcements and the
reader's VoiceOver cursor following ↑/↓); Bluetooth/AirPods as default input: HFP profile
switch on mic open (hold ≥ 2 s on the first take after idle; the take must not end with “The
audio input changed while listening”), and connecting or disconnecting a headset mid-take —
the one-restart behaviour is unverified on hardware; that a streaming reader leaves
keystrokes with the pinned app; Laya pickers with a real venv and model folder. `CFBundleVersion` is still 12 (Info.plist is not
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
