# Attaching pi-os to the existing Brave session

Status: 2026-10-01. **Signed build 12 (Whisper UI) is installed and running.** Browser-specific evidence below is from builds 10/11; the adapter was not changed by the UI update. Production browser tools passed the signed-host fixture, including a rerun through the installed bundle. Brave connection is enabled under Tom's prior explicit approval. Credential-field input remains **off by default**, with a pi-os Settings opt-in. No macOS security feature, TCC requirement or resident model was disabled.

## Implemented integration

- Native **π → Brave Connection…** (also in Settings) provides explicit opt-in, the
  broad-debugging-access warning and a loopback port (default 9222). Opening this
  setup does not start Node, enumerate models or enable Brave's setting automatically.
- `BrowserPin.capture` retains the exact selected AX tab and native window **before**
  the prompt, with a bounded 120 ms budget. It inspects browser chrome, not page
  content. Public AX verification detects tab selection/window identity changes.
- The host's authenticated internal `browser.connection` / `browser.validate` routes
  revalidate the context lease, PID fingerprint/UID, permissions, selected tab and
  geometry. The OS-wide Secure Keyboard Entry flag is not a blanket input veto. Mutations also hide the capsule, focus the exact window
  and consume the shared input budget. `browser.invalidate` poisons uncertain input.
- The TypeScript adapter verifies that the explicitly configured loopback listener
  belongs to the pinned Brave process using bounded `ps`/`lsof`, without reading profile
  files or probing arbitrary ports. It opens one bounded WebSocket, never reconnects,
  then matches the pinned URL and native window bounds to exactly one page target.
  Identical URLs in one window are refused as ambiguous; no other page is attached.
- `runAgent` registers **browser_snapshot / browser_act** in the real isolated SDK
  allowlist for these invocations, replacing `desktop_act`. The native host also
  refuses native mutations for a browser-bound context, preventing that fallback.
- Page operations use fixed first-party code in a CDP isolated world. The model gets
  semantic DOM text/references, not JavaScript, raw CDP, endpoint or target arguments.
  Snapshots omit sensitive input values, cap output at 24,000 characters/300 controls,
  and support a text filter. This is a bounded DOM reader, not a complete accessibility
  implementation for every widget/framework.
- Actions support click, replace field text, a small non-modifier key set, and scroll.
  References are consumed after each action and invalidated on navigation; element,
  surrounding-item context, visibility/occlusion, field-local credential policy and
  recognized deletion checks run again immediately before activation. Unicode fill verifies delivery.
- Clearly identified username/password fields are blocked by default. **Settings →
  Allow input in username and password fields** explicitly enables input in both
  native apps and Brave. It does not extract stored credentials or reveal field values
  in text snapshots. The authenticated host supplies the live permission, never the
  model; it is checked again immediately before the action. Changing the UI setting
  cancels the active task. A credential-field refusal does not disable other fields.
- Calls serialize per invocation. Timeout/disconnect/cancel never replays a mutation;
  uncertain actions disable further writes. Host cancellation now revokes the native
  context lease immediately. Finalization clears references/releases handles and
  detaches, without closing Brave or its tabs. Isolated worlds are reused by helper
  code version rather than accumulating one world per task.

No blanket ordinary-app block was added. The integration is optional; when disabled,
new Brave tasks use the existing native route. While enabled, failures do not silently
switch tools, profiles, tabs or browsers. Trusted global extensions remain arbitrary
trusted code, not sandboxed by this adapter.

**Current supported scope:** ordinary HTTP(S) documents with an inspectable tab strip,
main-document/open-shadow DOM controls, same-tab links, text fields and scrolling.
Frames, canvas/closed-shadow widgets, downloads, new-tab/external-protocol links and
browser settings are not supported by this first adapter. Clearly marked credential
fields require the explicit Settings opt-in; ordinary fields remain available. Duplicate URL/window
matches fail closed. Full-page/framework/Spaces/display parity is not claimed.

### Build 11 follow-up / input update

A browser-bound conversational thread retains the SAME BrowserSession and target;
it does not reconnect/retarget for a follow-up. New turns clear old DOM references
and screenshot authority; uncertainty and cumulative native budgets remain in force.
Thread closure disposes SDK/provider/browser resources, detaching without closing tabs.
Brave fill canonicalizes CRLF/CR to LF, permits multiline only on textarea/contenteditable
receivers, and verifies the resulting value without putting it in tool output.

70 guarded Node / 59 Swift tests plus conformance pass. The signed production-browser
candidate passed **20 default-mode checks**, including real multiline Unicode delivery,
turn-bound reference invalidation, navigation, deletion refusal and unrelated-tab
preservation (`qa/build11-brave-default.json`). An enabled-mode rerun stopped with
`browser_unavailable` **before CDP attachment or input** (`qa/build11-brave-enabled-blocked.json`).
It was not bypassed/reconnected; no connection-approval prompt was automated. Build 10's
successful enabled-mode evidence below is historical, not a successful build 11 rerun.

The installed build 11 passed its separate 17-check native reader/thread lifecycle
fixture. Model-driven browser follow-ups, live enabled-mode reacceptance and additional
framework/slow-target cases remain pending.

### Verification — build 10 (historical)

- **59 guarded Node tests**, **57 CPU/fixture Swift tests**, and Swift ↔ Node
  authenticated HTTP/lifecycle conformance pass. The transient Swift presentation
  test remains explicitly skipped. No model/provider call was made.
- Signed candidate native fixture: **30 checks in each setting mode**, including
  username/password default refusal, opt-in dummy credential delivery, Like with a
  credential field focused, ordinary Unicode entry, stale/ambiguous/closed-target
  refusals and an unchanged canary. Evidence: `qa/build10-native-{default,enabled}.json`.
- Signed candidate production-browser fixture: **18 checks in each setting mode**,
  covering field-local policy, value omission, Like, Unicode input, same-tab navigation,
  stale references, zero-event Delete refusal, one-target attachment, detach and
  preservation of all unrelated tab IDs/URLs. Evidence: `qa/build10-brave-{default,enabled}.json`.
- The **installed** signed build 10 passed the same 18-check default browser fixture:
  [`qa/build10-installed-brave.json`](qa/build10-installed-brave.json). Signature/health
  were checked; same-identity refresh required no TCC reset or reapproval.
- The credential Settings row's light-mode layout, label, unchecked default and disabled
  preview state were visually/AX inspected with a mocked model catalog. The enabled
  confirmation interaction and full accessibility matrix remain unverified.

Live testing exposed two timing issues, both fixed without relaxing tab identity:
WebSocket upgrade precedes protocol readiness, so connection now waits for a bounded
`Browser.getVersion` response; Chromium temporarily removes its web area on navigation,
so a still-verified retained selected tab reports `browser_stale` while loading and
permits observation-only refresh. The tab/window identity checks are retained.

Build 9's blanket `secure_input` refusal is historical evidence only
(`qa/brave-integration-build9-blocked.json`). Tom explicitly replaced that over-broad
rule with field-local, configurable credential protection. Neither this change nor QA
disables macOS Secure Keyboard Entry.

Rerun on a coordinated idle desktop (only dummy fixture fields are changed):

```sh
PI_OS_INSTALLED_TEST=1 PI_OS_TEST_APP="$PWD/host-macos/build/pi-os.app" \
  python3 host-macos/scripts/test-brave-installed.py
```

This runs the **production** extension/adapter against one fresh local fixture using
an actual signed native pin and authenticated routes, but no model. Its per-instance
Brave setting uses NSArgumentDomain; it does not alter the installed host's stored
settings. It leaves the fixture tab open and stops its server. Set
`PI_OS_TEST_CREDENTIALS=1` to test the permission-enabled mode with dummy values.
Routine updates continue to use the same-certificate `refresh-install.sh`.

## Initial observation (before user approval)

- Installed Brave bundle version: `153.1.95.101`; `agent-browser`: `0.27.0`.
- The running Brave main process had no remote-debugging arguments and no TCP listener at inspection time.
- Opened one diagnostic tab in the existing Brave window, without navigating or closing any pre-existing tab.
- Public accessibility inspection confirmed that `brave://inspect/#remote-debugging` contains an unchecked **Allow remote debugging for this browser instance** checkbox.
- Brave's displayed warning says this allows external apps to request **full browser control**, including read access to saved data, cookies/site data, and navigation to any URL.
- Left that checkbox **off** and the diagnostic tab open. No debugging connection, restart, profile copy, cookie export, account action, or local-model call was performed.
- macOS denied a read of Brave's `Local State` (`Operation not permitted`). No permission changes or workaround were attempted. An earlier existence check for `DevToolsActivePort` is consequently not proof that the file is absent; future discovery must distinguish access denial from missing files.

## Approved live-session test — passed

The user explicitly approved enabling debugging and running the harmless fixture test.
The checkbox was enabled through its public AX control and read back as checked. Brave
then exposed a loopback-only listener at `127.0.0.1:9222`, owned by the same existing
Brave process. HTTP `/json/version` returned 404; a direct WebSocket connection at
`/devtools/browser` succeeded. No browser-profile access or launch-time flag was needed.

Ran [`scripts/test-brave-cdp.mjs`](scripts/test-brave-cdp.mjs), an opt-in, deterministic
probe using the existing `ws` dependency. It is **not** an agent-browser or installed
pi-os integration test. Nine checks passed:

- Attached to the already-running Brave endpoint (Chromium `153.0.8010.37`).
- Created two identical local fixture tabs with separate target IDs.
- Resolved the named textbox through CDP's accessibility tree.
- Delivered Unicode input and verified its value and input event.
- Clicked the named Like fixture through its resolved DOM node; verified exactly one click and pressed state.
- The duplicate fixture canary received no text or clicks.
- All pre-existing page targets remained open at their original URLs.
- Attached page sessions belonged only to the two newly created fixture targets.
- Explicitly detached both fixture sessions, closed the test connection/server and left Brave running.

A separate native AX observation confirmed the rendered text, pressed button and
`Like clicks: 1` / `Input events: 1`. No account action, cookie/auth-store read,
profile copy, browser restart, file deletion or local-model call was performed.
Target IDs and pre-existing tab URLs were compared only in memory, not saved in evidence.

No connection-approval dialog was clicked by the agent. A separate dialog was not
observed during this run; do not infer or promise that this Brave build prompts on
every connection. The user-approved debugging setting **remains enabled**. The two
fixture tabs remain open for inspection; their temporary HTTP server has stopped.

Evidence: [`qa/brave-live-session-macos27.json`](qa/brave-live-session-macos27.json).
Re-running creates two more harmless tabs and requires a currently verified Brave
PID/loopback listener plus explicit approval:

```sh
PI_OS_BRAVE_TEST=1 PI_OS_BRAVE_PID=<verified-pid> PI_OS_BRAVE_PORT=<verified-port> \
  node host-macos/scripts/test-brave-cdp.mjs
```

This verifies live attachment, semantic interaction and basic target isolation. It
is not proof of the full production invocation policy, cancellation/revocation,
reference invalidation on navigation, or an absolute no-delete guarantee.

## Recommended transport

Use Brave's **user-consented, live-session CDP connection**, not a second browser launched with a copied profile. Chromium's newer remote-debugging UI is present in this installed Brave, so the old recommendation to quit Brave and relaunch with `--remote-debugging-port` is not the preferred path here.

Proposed setup:

1. The user enables the checkbox in Brave, understanding the broad access warning.
2. pi-os discovers the endpoint of that explicitly selected Brave instance, then opens one bounded connection and waits for the user to approve Brave's connection dialog. Do not automate approval or repeatedly reconnect while consent is pending.
3. Select/bind the requested existing tab. Authentication remains in the running browser; no cookie/state transfer is required.
4. Inspect the page's accessibility/DOM structure and act on verified element references. Use screenshots as a verification/fallback aid rather than guessing screen coordinates for every web action.
5. On cancellation/disconnect, detach only. Never close/relaunch the user's browser, close its tabs, or silently fall back to an isolated profile.

The setting, endpoint discovery, attachment, preservation of existing tab IDs/URLs,
and DOM interaction have now been verified on this machine. Consent UX across new
connections/browser versions and production integration still need acceptance tests.

## Why not just expose `agent-browser --auto-connect`?

The installed CLI can consume an explicit CDP WebSocket endpoint. Its version-tagged upstream source also includes Brave's macOS data directory in auto-discovery. However, that is not sufficient for pi-os's target and safety contract:

- Generic auto-discovery tries Chrome/Canary/Chromium before Brave, then common ports. It can select the wrong browser.
- In v0.27.0, `auto_connect_cdp()` attempts to **remove `DevToolsActivePort` after a failed probe**. Do not use this cleanup path under this project's no-file-deletion rule. A consent timeout must not be treated as permission to alter browser files.
- Its probe uses a short timeout, then reconnects for the actual session. A human-consent connection needs a suitable pending-consent state, not repeated probes and dialogs.
- `discover_and_attach_targets()` attaches to all tracked page targets and initially selects the first, not necessarily the tab in pi-os's pinned window. A CLI `--session` name does not confine access to one tab of an attached browser.
- It exposes arbitrary evaluation, cookies/storage, navigation, uploads and many other powers. Native `DesktopInputController`/`DeletionPolicy` guards do not intercept CDP operations.
- Disable automatic dialog handling for real-session use; no automatic acceptance of before-unload dialogs. Audit streaming, event collection and persisted artifacts before using a general-purpose client against private tabs.

The implemented adapter uses an **explicit endpoint and narrow first-party browser adapter** in the existing TypeScript harness, with `ws` pinned to 8.21.3 (already present transitively). It does not execute the general-purpose agent-browser CLI. Signed-host fixture acceptance is distinct from broad application/model-driven acceptance.

## Required pi-os integration boundaries

Keep the Swift/AppKit host + TypeScript harness architecture.

- Host captures the browser/window identity before showing the prompt, as today. Browser target selection must be explicit or unambiguous; titles/URLs or the first CDP target alone are insufficient when duplicate tabs/windows exist.
- Bind the invocation to browser identity, target ID, document/frame generation and a cancellable lease. Map the native window to the browser window and confirm the selected tab, or ask the user to select it. Do not silently retarget when tabs close/switch or the browser restarts.
- Keep endpoint addresses and target capabilities private to the adapter, not model-selected tool arguments. Validate loopback endpoint ownership/identity; do not accept arbitrary remote URLs or probe unrelated processes.
- Expose bounded tools such as snapshot, click-ref, fill-ref and scroll. Bind references to the selected document/frame and invalidate them on navigation/detachment. Revalidate element identity and state before mutation; verify the postcondition afterward.
- Deny arbitrary model-supplied CDP methods/JavaScript, cookie extraction, browser settings changes, unrelated tab access and silent profile fallback. Treat page text and attributes as untrusted content, not instructions.
- Enforce the action policy on this transport too: normal explicitly requested actions are allowed; file deletion, Move to Trash and Empty Trash remain prohibited. DOM labels and command filters are defense in depth, **not an absolute no-delete sandbox**. Remote web apps and opaque scripts can still cause deletion outside the adapter's knowledge.
- Pause on unexpected dialogs, ambiguous targets, revocation, uncertain mutation or cancellation. Do not retry an uncertain write.
- Log only bounded status/error information, not page content, titles, URLs with secrets, cookies, typed text or connection capabilities.

## Extension alternative

If consent-based CDP discovery is unsuitable, a companion Chromium extension can use `chrome.debugger.attach({tabId}, ...)` and communicate through Native Messaging. This reuses existing tabs without a launch-time debug port and can provide explicit per-tab selection. Native Messaging allowlists the extension ID; it is not browser discovery by itself.

The Playwright extension is an existing reference implementation for connecting to selected tabs of an already-running browser. Its official prerequisites list Chrome/Edge/Chromium, not an explicit Brave compatibility guarantee; validate Brave before adopting it. Neither extension permissions nor CDP alone enforce this project's no-delete policy.

No extension was installed. The debugging setting was enabled only after the user's
explicit approval; never silently enable it on another browser/profile or restart.

## Remaining acceptance work

1. Validate the enabled credential setting's confirmation flow and additional native/web field semantics using dummy data; do not exercise real logins for QA.
2. Expand real application tests for tab changes, navigation/reference invalidation, browser restarts, revocation, cancellation, uncertain writes and unexpected dialogs. CPU fixtures cover these policy paths; they do not replace the live matrix.
3. Verify consent behavior and revocation on this Brave version rather than assuming Chrome's documented dialog behavior. Do not automate approval prompts.
4. Keep account actions and file deletion out of QA. Do not read/copy login stores, alter profile files, silently widen permissions or launch replacement profiles.
5. Run an actual model-driven task in a coordinated provider window. Build 12 is installed, with the scoped historical browser evidence above; this is not a claim of full browser/Windows parity or a filesystem no-delete sandbox.

## Sources

- [Chrome's live-session consent flow](https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session) — enable the UI, approve each connection; distinct from launch-time flags.
- [Chrome 136 launch-time debugging restrictions](https://developer.chrome.com/blog/remote-debugging-port) — do not conflate these with the newer consent flow or assume identical Brave policy without verification.
- [agent-browser v0.27.0 discovery source](https://github.com/vercel-labs/agent-browser/blob/v0.27.0/cli/src/native/cdp/chrome.rs) — Brave paths, probes and stale-file cleanup.
- [agent-browser v0.27.0 connection source](https://github.com/vercel-labs/agent-browser/blob/v0.27.0/cli/src/native/browser.rs) — broad target attachment and disconnect-vs-close behavior.
- [Chrome debugger extension API](https://developer.chrome.com/docs/extensions/reference/api/debugger) — tab-based CDP and supported domains.
- [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) — extension/native-host channel and allowed origins.
- [Playwright extension](https://github.com/microsoft/playwright/blob/main/packages/extension/README.md) — existing-session and tab-selection reference.
