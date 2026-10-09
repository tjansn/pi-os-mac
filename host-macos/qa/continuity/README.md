# Continuity QA fixtures and the live QA plan (Q1–Q11)

DESIGN5 §12 (WP6), with TOM-ANSWERS (2026-10-08) taking precedence over DESIGN5 D1–D3. The live plan below is run
**only together with Tom**, in a window he agrees to. Nothing here is run unattended, and CI never shows a window.

## What is in this folder

| Path | What it is |
|---|---|
| `page-fixture/server.mjs` | Loopback page server, `127.0.0.1` only. It sets no cookies, makes no external requests and logs nothing per request. Pages report counts to `POST /echo`, and `GET /state` returns them. |
| `page-fixture/pages/*.html` | `/search` (`input type=search autofocus`), `/combobox` (`textarea role=combobox aria-label=Search autofocus`, where Return submits), `/delayed?ms=` (focus moves in after a delay), `/loading?ms=` (autofocus while the page keeps loading), `/consent` (a consent-like modal dialog holds focus), `/iframe` (autofocus inside an iframe), `/login` (dummy sign-in that cannot submit), `/article` (an article for page questions, with a focused search box), `/moving?ms=` (focus jumps between two boxes), `/editor` (contenteditable) and `/` (index) |
| `native-fixture.sh` | Opt-in launcher (`PI_OS_CONTINUITY_QA=1`) for `pi-os-input-fixture <state.json> --continuity`. It shows windows, so it is for live QA only |
| `ax-counts.swift` | Read-only AX probe. It prints the frontmost flag, window and tab counts, and the focused element's role, subrole, settable flag, length, web-area depth, `AXLoaded` and toolbar/dialog flags. It never reads `AXValue`, a title or a label, and never prompts |
| `node-harness/src/instant/grammar/testSites.ts` | Spoken names that work only when `PI_OS_TEST_SITES_PORT=<port>` is in the harness environment: "fixture search", "fixture page", "fixture login", and the others listed below. Unset, the table is empty |

### Native continuity surfaces (`--continuity`)

Each surface is its own window. The state file holds counts and booleans only: per field `length` (UTF-16 units, like
`AXNumberOfCharacters`), `scalars`, `characters`, `lineBreaks`, `replacements` (U+FFFD, a split surrogate),
`keyDowns`/`returnKeys` split into `piOS` (events carrying pi-os's `0x50494F53` marker) and `external`, `submits`,
`focused` and `expectedKind`. The Delete and Cancel buttons are counted in `presses`. Each window also shows its own
counts in a static line at the bottom.

| Window | Field (`name`) | Built as | Expected kind (`InstantFieldKind`) |
|---|---|---|---|
| Search | `search` | `NSSearchField`, "Search fixture" | `search` (`AXSearchField`) |
| Search | `title` | `NSTextField`, "Title" | `text` |
| Verification | `code` | `NSTextField`, "Verification code" | `sensitive` (policy T5) |
| Verification | `codeSearch` | `NSSearchField`, "Code search" | `search`: the negative case for T5 |
| "Delete fixture item?" (`AXDialog`) | `confirm` | `NSTextField`, "Type DELETE to confirm", next to a default **Delete** button that only counts presses | `confirm` (policy T6) |
| Notes | `notes` | `NSTextView`, "Notes body" | `multiline` |
| Terminal-like | `terminal` | `NSTextView` with AX description "Terminal input" (an `InputSurfaceInspector` marker); nothing ever runs | `terminal` |

Commands go on stdin as one JSON object per line: `{"command":"focus","field":"search"}`, `{"command":"prefill","field":"title"}`
(types the fixed word "prefilled"), `{"command":"clear","field":"notes"}`, `{"command":"reset"}`, `{"command":"state"}` and
`{"command":"quit"}`. EOF quits. Unlike the A/B fixture, clicks and keys from Tom are **counted, not fatal**: the state
holds no values.

### Test-site names (`PI_OS_TEST_SITES_PORT`)

| Name (EN / DE) | Page |
|---|---|
| fixture home | `/` |
| fixture search / fixture suche | `/search` |
| fixture combobox / fixture combo box | `/combobox` |
| fixture delayed | `/delayed` |
| fixture loading | `/loading` |
| fixture consent | `/consent` |
| fixture frame / fixture iframe | `/iframe` |
| fixture login / fixture anmeldung | `/login` |
| fixture page / fixture seite / fixture article / fixture artikel | `/article` |
| fixture moving | `/moving` |
| fixture editor | `/editor` |

A name opens like a known site ("open fixture search", "öffne fixture suche"): `launch.ts` looks it up after the real
site names, and an exact installed app name still wins. `toWebUrl` never yields a loopback URL, which is why the table
exists.

## Self-tests (CI, no window)

- `npm test` (node-harness, under the no-live-models guard) runs `test/testSites.test.ts`. It covers the flag-off and
  flag-on tables, the names parsing as open targets, and the page fixture: loopback binding, the Host guard, headers and
  CSP, every page's surface, the closed `/echo` schema, `/state`, `/reset`, bounded delays and the silent CLI. It also
  checks this README. On macOS it runs the native self-test when a fixture build containing it exists, and skips
  otherwise.
- `host-macos/.build/debug/pi-os-input-fixture --self-test` builds the native surfaces with activation policy
  `.prohibited`, in deferred off-screen windows that are never ordered in. It checks roles and subroles, PiOSCore's
  `CredentialPolicy` and `DeletionPolicy` vocabulary, the dialog subrole, the length echo and that the state has no
  content. It prints one `PASS pi-os-continuity-self-test-v1: …` line.

## Binding expectations (TOM-ANSWERS over DESIGN5)

- **Commands win.** Instant commands, explicit pi tasks (write/schreib, summarize/fasse zusammen, …), page and window
  questions ("this page", "diese Seite", "hier"), "frag pi …/ask pi …" and every policy case are never typed.
- **Everything else is typed** into an eligible focused field, questions included. Eligible means any visible editable
  text field or area, search box, address bar or combobox, empty or not, single-line or multiline.
- **Return** is pressed once, automatically, only after a fill into a search box, a combobox search or the address bar.
  It is never pressed in `text`, `multiline`, `terminal`, `sensitive`, `credential`, `confirm` or `rename` fields.
- **Never typed implicitly:** credential and 2FA/payment (`sensitive`) fields need an explicit "tippe …" **and** the
  Settings opt-in. `confirm` and Finder rename fields are never typed. A terminal gets the one-Return card "↩ Type into
  Terminal" (text only, never Return).
- **Undo:** a bare "nein/no" within 5 s of a fill undoes it, and "tippe nein" types the word.
- **Browser:** links open in the browser in front or in the one pi-os is launching; with no browser in front, in the
  default browser (Brave).
- **Typed bar input addresses pi.** A typed take fills only through an explicit "tippe …" (DESIGN5 §5.4), so the
  implicit-fill rows need voice, which means Tom.

## Preconditions (all of them, before the first step)

1. Tom is present and has agreed the window. Stop at once if he leaves.
2. Use the build Tom approves, signed with `PI_OS_SIGN_IDENTITY`. Never refresh pi-os with an ad hoc build, and never
   set `PI_OS_ALLOW_ADHOC_INSTALL` without Tom's explicit OK (AGENTS.md). Note what is installed: the installed copy
   is a snapshot.
3. Before any voice step (Parakeet on the Neural Engine) or agent step, check
   `/Users/tom/dev/Projects/_LOCAL_AI/.local-inference.lock` and coordinate with its owner. The file existing is not
   proof that anyone holds the lock. The fill and open checks need no model.
4. No account actions and no deletion. Use dummy credentials only: the username and the password are both
   `dummy-credential-QA-only`.
5. No automated typing into google.com or wikipedia.org. Tom checks those by hand at the end of Q11.
6. AX probes print roles, booleans and counts only (`ax-counts.swift`).
7. Stop only processes you started, by their exact PID: the page fixture, the native fixture, and the pi-os you
   launched. Never kill by image name.
8. Leave Tom's Safari, Brave, Settings and Spaces as they were. Tom changes any setting himself (Safari Tabs, the
   credential opt-in, Secure Keyboard Entry) and reverts it at teardown.

## Setup

1. **Page fixture:** run `node host-macos/qa/continuity/page-fixture/server.mjs` and wait for
   `continuity page fixture ready port=47391`. The counts are at `curl -s http://127.0.0.1:47391/state`, and
   `curl -s -X POST http://127.0.0.1:47391/reset` clears them between steps.
2. **pi-os with the test sites:** the host passes its own environment to the harness (`HarnessClient`). pi-os runs as
   a single instance (`host.lock`) and `open` ignores `--env` for an app that is already running, so Tom quits the
   running pi-os first (`pgrep -x pi-os` prints nothing). Then launch the approved app through Launch Services, which
   keeps the app's own permission identity:
   `QA="$(mktemp -d -t pi-os-continuity-qa)"; open --env PI_OS_TEST_SITES_PORT=47391 --env PI_OS_PERF=1 --stdout "$QA/pi-os.out" --stderr "$QA/pi-os.err" "<approved pi-os.app>"`.
   `PI_OS_PERF=1` writes the content-free `[perf]` and `[launcher]` lines to `$QA/pi-os.out`. Never start the app's
   binary from a shell: it would run with the terminal's permissions instead of pi-os's (the `run-dev.sh` caveat) and
   could raise new permission prompts for the terminal. If Tom prefers not to relaunch, open the fixture pages by hand
   (bookmark or address bar) and skip the open-by-name rows.
3. **Native fixture:** run `PI_OS_CONTINUITY_QA=1 host-macos/qa/continuity/native-fixture.sh`. It prints the state path.
4. **Probe:** run `swift host-macos/qa/continuity/ax-counts.swift com.apple.Safari com.brave.Browser dev.pi-os.input-fixture`
   before and after each step.

## Content-free checks

| Check | Where it comes from |
|---|---|
| Frontmost app, window and tab counts | `ax-counts.swift` (`frontmost`, `windows`, `tabsPerWindow`) |
| Focused role, subrole, settable flag, length, iframe depth, loading, toolbar | `ax-counts.swift` (`focused`) |
| Page loads (no double open), lengths, Return keys, submits, focus | page fixture `/state` (`served`, `pages.<page>.fields`, `submits`) |
| Native lengths, Return keys by origin, submits, Delete presses | native state file (`fields`, `returnKeys.piOS`, `presses.delete`) |
| Decision, field kind, Return | pi-os's content-free lines (closed vocabulary and counts only): the host's `[perf] fill kind=… outcome=… return=none\|pressed\|notPressed verify=… ms=…` (with `PI_OS_PERF=1`); Node's `[perf] stage=instant.dispatch … decision=act kind=fill … via=field fill=<label> field=<kind>` (`fill` labels: implicit, explicit, held, replace, search, offer, secret, web, pi); and `logs/voice-perf.log` `decision=act … via=field`. Neither the tier nor the anchor state is logged: read the tier off the field kind (DESIGN5 §5.3) and the anchor off the chip. Fills do not go through the launcher, so `launcher-actions.jsonl` has no line for them |
| Link route | `logs/launcher-actions.jsonl` (`browser`: launching, pinned, default or fallback) and the `[launcher] … browser=…` line with `PI_OS_PERF=1` |
| Latency | `[perf]` lines (key-down → panel, key-up → first and last character) |
| No content in logs (R27) | grep `~/Library/Application Support/pi-os/logs/`, `$QA/pi-os.out` and `$QA/pi-os.err` for every test string used (for example "Albert", "Einstein", "Katzen", "Marie Curie", "Eiffelturm", "Laterne", "dummy-credential", "Kellsmoor", "127.0.0.1:47391"). The pass is 0 hits |
| Not journaled | the count of entries in `voice-takes/` before and after a credential or sensitive take (count only). The journal is opt-in: when it is off, this check proves nothing, so record it as "journal off" |

## Steps

| Q | What | Steps (fixtures only) | Pass (content-free) |
|---|---|---|---|
| Q1 | Targeted open (Phase 1a) | Safari in front: typed "open fixture search". Brave in front: the same. Finder in front: the same. Cold chain: "open Safari", then within 5 s "open fixture search". Tom sets Safari's "Open pages in tabs instead of windows" to Never, then Automatically, and repeats the Safari row. Then repeat the cold chain with `PI_OS_SAFARI_SAME_TAB=1` (one more `--env`; the route is off by default) | The page lands in the browser in front or in the launching one, and in the default browser when Finder is in front. `served["/search"]` rises by exactly 1 each time (no double open through the fallback). Brave's window and tab counts do not change in the Safari chain. Record the Safari start tab: reused (tabs +0) or not (+1). With the same-tab flag: tabs +0 and a web area appears. This decides D4 and `PI_OS_SAFARI_SAME_TAB` |
| Q2 | Launch race | Native `search` focused and empty. Dictionary is not running; it opens no document, so nothing has to be discarded afterwards. Voice: "open Dictionary" ("öffne Lexikon"), then hold again within 0.4 s and say "Laterne" | Native `search.length` stays 0 and its `keyDowns.piOS` stays 0. The take re-pins to Dictionary (its search box gets the word and 1 Return), or does not fill. The chip shows "Dictionary (opening…)" then "Dictionary". No typing into the previous app |
| Q3 | Field detection per engine | In Safari (WebKit) and Brave (Chromium), open each page, plus the address bar (Tom clicks it) and the native surfaces | Kinds: `/search`, `/combobox`, `/article`, native `search` and `codeSearch` are `search`. The address bar is `address` (`inToolbar`). `/login` is `credential`. `/editor` and native `notes` are `multiline`. Native `title` is `text`, `code` is `sensitive`, `confirm` is `confirm` and `terminal` is `terminal`. `/consent`: no eligible field until a button is pressed. `/iframe`: `webAreaAncestors` ≥ 2, so not ready and no implicit fill. `/loading?ms=3000`: `nearestWebAreaLoaded` false until the load ends. `/delayed`: no field at load, then `search`. `/moving`: the bound element changes, so no fill lands in the second box. The Brave web field is readable at the final, after pi-os sets `AXManualAccessibility`. Key-down AX stays within the 25 ms cap (`[perf]`). Bound-element identity (`CFEqual` per-app ↔ system-wide, C2) holds for the web fields: pass or fail for Phase 2 |
| Q4 | Fill chain | Typed first: "tippe Albert Einstein" into `/search` and into native `title`. Voice: "open fixture search" → "Albert Einstein"; "nein" within 5 s; "such nach Katzen"; "nein, Marie Curie" within 30 s; "Albert Einstein", then a bare "frag pi" within 5 s; "wie hoch ist der Eiffelturm"; "frag pi wie hoch ist der Eiffelturm"; "tippe nein"; "Albert Einstein" into native `notes` and `title`; "open fixture page" with `/search` focused. Address bar (Tom focuses it in Safari, then Brave): "tippe http://127.0.0.1:47391/article" (with the scheme, so neither browser can read it as a search). Never let another question or phrase reach a real address bar in this step: text plus Return there goes to the browser's search engine | `/search`: `length` 15 after the fill, then exactly 1 Return and 1 submit. "nein" deletes nothing (the search already ran): the note says "Already searched — go back with ⌘[" and the note after the fill offers Ask pi only, no Undo. "such nach Katzen" types only the 6 characters of the query, then 1 Return. "nein, Marie Curie" undoes that fill and types the 11 characters instead, with 1 Return. The bare "frag pi" undoes the fill (length back) and starts an agent turn with the filled words. The question is typed and gets 1 Return. "frag pi …" types nothing and reaches the agent. "tippe nein" adds 4. Native `notes` and `title`: the length matches, with `returnKeys.piOS` 0, `submits` 0 and `lineBreaks` 0. "open fixture page" opens the page (served +1) and types nothing. Address bar: exactly 1 Return and `served["/article"]` +1 |
| Q5 | Chunked typing (`PI_OS_TYPE_CHUNK=1`, one more `--env`; off by default) | Per engine (native `notes`, `/search` and `/editor` in Safari and Brave): "tippe Grüße aus Köln ☕️ Straße 👩‍💻" | `length`, `scalars` and `characters` match the expected counts exactly, and `replacements` is 0 (no split surrogate). `/editor` `inputs` shows the chunking. Enable chunking per engine only on a pass |
| Q6 | Key-up payload fix | "tippe Albert Einstein" into native `notes` (AppKit), `/editor` in Safari (WebKit) and `/editor` in Brave (Chromium). Electron only in a harmless field Tom chooses, never sent | Lengths are exactly 15 everywhere: no doubled text |
| Q7 | Panel order-out → browser focus restore | 10 consecutive fills into `/search`, in Safari and in Brave | The delay is measured from `[perf]` (it sets DESIGN5 §7 row 12b and the C3 wait cap), and there are 0 `focus_unknown` failures |
| Q8 | Safety | `/login` with the username focused: voice "dummy-credential-QA-only"; typed "tippe dummy-credential-QA-only" with the opt-in off, then on (Tom toggles it). If a browser offers to save the dummy password, Tom chooses Not Now (no account action). Native `code`: voice "123456", then "tippe 123456" with the opt-in off and on. Native `confirm`: voice "DELETE" and "tippe DELETE". Native `terminal`: voice "hello from the fixture" (dictation-like, so the card ↩ appears; a task-like phrase such as "list files", classified `search_computer`, can go to the agent instead) and "tippe rm -rf pi-os-qa-nonexistent" (a path that cannot exist, in case it ever reaches a real shell). Tom turns Secure Keyboard Entry on: "tippe Albert Einstein" into native `title` | Implicit credential or sensitive: nothing typed (`filled` false, `length` 0), a local masked card, no agent turn, not journaled. Explicit without the opt-in: refused. With the opt-in: typed (`dummyMatches` true), 0 Return, the sensitive field asks one confirm first. `confirm`: `keyDowns.piOS` 0 and `presses.delete` 0, both ways. Terminal: the card types text only (`returnKeys.piOS` 0, `lineBreaks` 0), and the `rm` line is refused with 0 events. With Secure Keyboard Entry on, the ordinary field still fills (length 15). The opt-in and Secure Keyboard Entry are off again afterwards |
| Q9 | Page questions with a field focused | Brave on `/article` (search focused): "what is this page about" and "worum geht es auf dieser Seite". Then Safari on `/article` | An agent window turn, with the digest in Brave and a screenshot in Safari. 0 characters typed (`length` 0, `returnKeys` 0). The answer is about the Lantern Library of Kellsmoor (Tom judges). This needs the lock check and Tom's OK for the model call |
| Q10 | Spaces, second display, full screen, Stage Manager | Safari's window on another Space or in full screen; the native fixture on the second display; Stage Manager on (Tom arranges it) | No Space switch and no typing across Spaces (off-screen fixture lengths unchanged). A note when the anchor window is off screen. Links still land in the right browser |
| Q11 | Voice with Tom (EN, DE, mixed) | N1, N3, N5, N10 and N19 on the fixtures. Then Tom by hand on the real sites: "öffne Safari" → "öffne Google" → "Albert Einstein"; "open wikipedia" → "Albert Einstein" | The DESIGN5 §1 table as amended by TOM-ANSWERS: filled, plus 1 Return in search boxes. Key-up → last character ≈ 120 ms + 27 ms per character on v1 ("Albert Einstein" ≈ 510 ms) and ≤ 150 ms after chunking, from `[perf]` |

N rows (DESIGN5 §10): N1 is Safari → Google; N3 is a chain plus a search; N5 is wikipedia → "Albert Einstein"; N10 is
"no …" after an act (a bare "no" within 5 s is Not this, while "No Country for Old Men" is a fill); N19 is mixed EN/DE.

Not exercised live: the Finder rename editor (`rename`, never typed). Opening one would put a real file name into edit
mode and a stray Return would rename it, so the `rename` kind is covered by WP3's classifier tests and WP2's corpus only.

## Stop conditions

Stop at once on any of these. Record the Q step and the content-free evidence (counts, kinds, route labels) and do not
retry blindly, because uncertain input is never replayed.

- **Unexpected Return:** any Return where none was expected. That means `returnKeys.piOS` or `submits` above the
  expected count, `presses.delete` above 0, or `lineBreaks` above 0 in a multiline or terminal field.
- **Typing outside the bound element:** `keyDowns.piOS` in a field that was not the target, a length change in another
  field, window or app, or typed text in the second `/moving` box.
- **Content in a log:** any value, label, URL, title or transcript in a log (the R27 grep finds a hit), or a credential
  value anywhere but the dummy field.
- **Wrong window, tab or Space:** a URL opened twice (`served` +2), a window or tab of an unrelated app changed, or a
  Space switch.
- **A real deletion or Trash dialog** appears in any app.
- **The local-inference reservation** is active and its owner has not agreed.

## Teardown

- Press Ctrl-C in the page fixture's terminal. Close the native fixture with Ctrl-D, or `{"command":"quit"}`.
- Quit the pi-os you launched with the flag, then Tom starts it normally, so `PI_OS_TEST_SITES_PORT` is gone.
- Tom closes the fixture tabs and windows the steps opened in Safari and Brave, and quits Dictionary (Q2).
- Tom reverts what he changed: the Safari Tabs setting, the credential opt-in, Secure Keyboard Entry and Stage Manager.
- Nothing is deleted: the temporary folders from `native-fixture.sh` and `$QA` hold only counts and content-free lines,
  and macOS clears them with its temporary files.
