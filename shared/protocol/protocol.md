# Local HTTP/JSON Protocol Contract v0

Communication between a native host (C# Windows / Swift macOS) and the
TypeScript agent harness. Loopback only. The Mac parity candidate implements the
three observation tools and gated native input. GET /tools advertises input only
when the signed host, user setting and TCC grants permit it. Installed-build and
acceptance status are tracked separately in `host-macos/PARITY.md`.

This document defines the mechanism: endpoints, ports, message shapes, and
error handling. The tool catalog grows per phase; the live catalog always
comes from `GET /tools` on the host.

## Base URLs and ownership

| Service | Default URL | Owner |
|---------|-------------|-------|
| Native Host | `http://127.0.0.1:17831` | Native primitives: context store, screenshots, UIA/AX, input (per platform phase) |
| Node Agent Harness | `http://127.0.0.1:17832` | Reasoning, tool selection, observe/act loops |

Rules:

- Bind to `127.0.0.1` only. Never bind `0.0.0.0`.
- Ports are defaults, overridable by config/env (`PI_OS_HOST_PORT`,
  `PI_OS_NODE_PORT`) so two dev instances can run side by side.
- IPv6 `::1` binding is optional and must never replace the IPv4 binding.
- No CORS headers. No browser clients.

## Authentication

All requests except `GET /health` require the header:

```text
X-Harness-Token: <hex token>
```

- The native host generates a random 32-byte hex token at startup (or uses an explicit split-development token).
- The token reaches the Node harness through the environment variable
  `PI_OS_TOKEN`, set by whichever process launches the other.
- Wrong or missing token: `401`. An unconfigured token fails closed; only explicit
  `PI_OS_INSECURE_DEV=1` opts out in isolated development. Mac supervised mode cannot opt out.
- Rationale: loopback binding alone does not stop other local processes.

## Message conventions

- Encoding: UTF-8 JSON. Field names are camelCase, matching
  `shared/schemas/desktop-context.ts`.
- Timestamps: ISO-8601 strings with UTC offset.
- Enums: lowercase camelCase strings (for example `"window"`).
- Unknown fields must be ignored by receivers, not rejected. This keeps the
  schema extensible.
- `monitors` contains metadata for every active display; it does not imply
  visual capture of every display. Window `monitorId` values reference these
  stable device IDs.
- `focusedElement` means keyboard focus only and does not imply selection.
  For desktop captures, `selectedDesktopItems: []` explicitly means UIA
  selection was checked and no icons were selected; an omitted/null field
  means desktop selection was not applicable or unavailable. On macOS a pinned
  Finder desktop uses `targetWindow.surface: "finderDesktop"`, its real CG window ID,
  and an optional `desktopWorkArea` for exact AX geometry matching. Only explicit AX
  selection on that verified surface populates the desktop-selection fields. When
  `selectedDesktopItemsTruncated` is true, `selectedDesktopItemCount` remains
  the complete selection count.

### Two error layers

Transport problems use plain HTTP status codes. Domain outcomes inside a
successful tool call are data, not transport errors, because the agent must
read and react to them.

| Layer | Example | Shape |
|-------|---------|-------|
| HTTP error | malformed JSON, bad token, unknown route | status + `{"error":{"code","message","details"?}}` |
| Tool outcome | target window closed during task | HTTP 200 + `{"ok":false,"error":{...}}` |

HTTP statuses used:

| Status | Meaning |
|--------|---------|
| 200 | success (including `ok:false` tool outcomes) |
| 202 | accepted for async processing |
| 400 | malformed request or failed argument validation |
| 401 | missing/wrong token |
| 404 | unknown route or closed/expired thread |
| 409 | duplicate invocation, busy thread or retained-thread capacity reached |
| 413 | request body too large (`POST /instant` and `/invocations/prepare` > 4 KB, `/settings/routing` and `/settings/classifier` > 16 KB, others > 1 MB) |
| 500 | unexpected server failure |

Tool outcome codes (open set, snake_case):

| Code | Meaning |
|------|---------|
| `invalid_arguments` | arguments fail the tool's input schema |
| `target_gone` | pinned HWND no longer valid, process identity changed |
| `unknown_context` | context ID is unknown or expired |
| `target_elevated` | target runs at higher integrity; UIPI blocks automation |
| `policy_blocked` | action/surface is excluded by native safety policy, not an ordinary app-brand ban on Mac |
| `file_deletion_blocked` | recognized file-deletion UI action, shortcut or terminal command was rejected |
| `focus_failed` | the pinned target could not be verified as foreground |
| `input_failed` | Windows did not accept or safely complete native input |
| `capture_failed` | screenshot/window capture failed (including an existing but unavailable Mac window) |
| `no_target` | frontmost application has no capturable normal window |
| `permission_denied` | required macOS permission is absent |
| `capture_stale` | image is stale/unseen, or geometry changed; no input posted |
| `accessibility_denied` / `input_permission_denied` | native control grants are absent |
| `control_disabled` | native control is disabled or the installation is not certificate-signed |
| `credential_input_blocked` | clearly identified username/password field requires explicit pi-os Settings opt-in; other fields remain usable |
| `secure_input` / `focus_unknown` | destination input security/focus cannot be established safely; the OS-wide Secure Keyboard Entry flag alone is not a veto |
| `budget_exceeded` | invocation reached its bounded native input budget |
| `uia_failed` | UI Automation query/action failed |
| `busy` | operation was cancelled while waiting for the serialized input gate |
| `token_expired` | a launcher file token is unknown, expired or belongs to another context |
| `unsupported` | the host does not implement this operation (for example `system` `appearance.*` on macOS v1) |
| `internal_error` | unexpected failure inside the host |

## Native Host API (17831)

### `GET /health`

`200 {"service":"windows-host","version":"<semver>","uptimeSeconds":<int>}`
Mac uses `"service":"macos-host"`. No token required. Used for readiness checks.

### `GET /tools`

`200 {"tools":[ToolDescriptor]}` where `ToolDescriptor`:

```json
{
  "name": "desktop.captureWindow",
  "description": "Captures a fresh screenshot of a window.",
  "inputSchema": { "type": "object", "properties": {}, "required": [] }
}
```

`inputSchema` is JSON Schema draft 2020-12. This endpoint is the source of
truth for tool discovery (handoff section 10).

### `POST /tools/{toolName}`

Uniform tool invocation. Dotted tool names are used directly in the path,
for example `/tools/desktop.getContext`.

Request:

```json
{ "arguments": { "contextId": "ctx-123" } }
```

Response, always HTTP 200:

```json
{ "ok": true, "result": { } }
```

```json
{ "ok": false, "error": { "code": "target_gone", "message": "HWND 0x000A1234 no longer exists" } }
```

### Screenshot transfer

Hosts write PNGs into the explicitly shared `PI_OS_CAPTURES_DIR`. Node reads
`ScreenshotRef.filePath` after realpath containment, regular-file, size and PNG
signature checks, then attaches image bytes to the model. `imageId` identifies the
capture; no `GET /images/{imageId}` route is implemented. Mac captures include actual
`imageWidth`/`imageHeight`, capped at a 1280-pixel long edge and 1 MP to avoid common
provider/SDK image resizers changing the coordinate space. The Mac host removes
managed captures on context disposal/orderly shutdown (crash leftovers may remain).

### Pinned desktop tool catalog

All tools require `contextId: string`. The Node extension injects it; the model
cannot select or change it. Every action reloads the snapshot and validates the
HWND/process identity immediately before input. Actions are serialized and are
never retried by the host.

| Tool | Additional arguments | Result | Purpose |
|------|----------------------|--------|---------|
| `desktop.getContext` | none | `DesktopContextSnapshot` | Return the pinned snapshot |
| `desktop.refreshContext` | none | `DesktopContextSnapshot` | Refresh metadata and screenshot |
| `desktop.captureWindow` | none | `ScreenshotRef` | Capture a fresh PNG |
| `window.focus` | none | `{action:"focus"}` | Focus and verify the pinned target |
| `input.click` | `x:number`, `y:number` | `{action:"click",x,y}` | One left click |
| `input.typeText` | `text:string` (non-empty) | `{action:"typeText",characters:number}` | Type Unicode text without clipboard use |
| `input.pressKey` | `key:string` | `{action:"pressKey",key}` | Press one supported key |
| `input.keyChord` | `key:string`, `modifiers:string[]` | `{action:"keyChord",key}` | Press key with Ctrl/Alt/Shift |
| `input.scroll` | `deltaX?:number`, `deltaY?:number`, `x?:number`, `y?:number` | `{action:"scroll",deltaX,deltaY,x,y,wheelDeltaX,wheelDeltaY}` | Wheel scroll in normalized notches; optional screenshot-relative point |

Tool coordinates are pixels in the latest target-window screenshot, not global
screen coordinates. Windows currently captures physical pixels and computes
`screenX = bounds.x + x`, `screenY = bounds.y + y`. Mac wire bounds/cursor/monitors
use CG global top-left **points**; its private transform uses captured bounds and
actual returned image dimensions. On Mac, clicks and coordinate-based scrolls also
require a private `screenshotId` injected by the extension. It advances only after
successful image ingestion and must match the host's latest capture. Metadata-only
refresh does not authorize coordinates. Pure movement uses the current origin;
resizing or unseen/stale imagery returns `capture_stale` before input.

Mac input results contain `action` and `postedEvents`, plus optional character count
or image coordinates. Posted events are **not** proof that the UI accepted them;
the agent must visually verify. Any uncertain input outcome prevents further input
in the same context; observation tools remain available.

Scroll deltas use normalized wheel notches: `1` is one conventional notch and
the host converts it to 120 Windows wheel units (Mac: three native scroll lines). Negative `deltaY` scrolls
down; positive `deltaY` scrolls up. Supply both `x` and `y` to choose a
screenshot-relative scroll point, for example inside a nested scrolling panel.
Omit both coordinates to use the current target-window center. Supplying only
one coordinate, an out-of-bounds point, zero movement, or a non-zero delta too
small to produce one Windows wheel unit fails with `invalid_arguments`.

The Windows host writes a privacy-bounded action trace to `host.log`: sequence ID,
action name, context ID, target identity/bounds, safe arguments, pointer target
and actual position, window under the pointer, normalized wheel data, duration,
and outcome. Typed text is never logged; only its character count is recorded.

Supported keys: Enter, Tab, Escape, Backspace, Delete, Home, End, PageUp,
PageDown, arrow keys, F1-F12, letters, and digits. Supported modifiers: `ctrl`,
`alt`, and `shift` on Windows. The Mac schema additionally supports `cmd` and the
`space` key, with current-layout letter/digit mapping. System/window-escape shortcuts
are refused on Mac; ordinary app save/close/hide/minimize shortcuts are not blanket-banned.
Mac input additionally inspects actionable AX labels/identifiers and editing context
for file-deletion controls/shortcuts. These checks do not sandbox arbitrary scripts,
aliases, opaque custom controls or trusted extension code. Mac traces in `logs/host-actions.jsonl` record action/outcome,
duration and counts, without typed text, key values, titles or context capabilities.

Cancellation is honored while waiting for the host operation gate and between
typed UTF-16 characters. A cancelled or partially completed mutating action is
not retried. Domain failures use `invalid_arguments`, `unknown_context`,
`target_gone`, `target_elevated`, `policy_blocked`, `focus_failed`,
`input_failed`, `busy`, or `internal_error` as applicable. Responses never
contain typed text or raw stack traces.

### macOS private Brave adapter routes (build 11)

An optional snapshot `browser: {name:"Brave", mode:"cdp", pinned:boolean}` selects the
first-party browser route. It contains no socket endpoint or CDP target capability.
The native host retains the selected AX tab/window objects from before the prompt.
These authenticated `/tools/browser.*` routes are private adapter coordination,
not general agent tools in the public `/tools` discovery catalog:

- `browser.connection` / `browser.validate`: arguments `{contextId, mutation?:boolean,
  action?:"click"|"fill"|"press"|"scroll", characters?:number}`. Returns private
  `{processId,port,initialURL,url,bounds,allowCredentialFields}` only after native
  context, process identity, ownership, permission and selected-tab checks. Mutation
  validation also hides the capsule, focuses the exact window and charges the shared
  input budget. No model can supply this context, endpoint or target identity.
- `browser.invalidate`: `{contextId}` marks uncertain input; it does not re-enable,
  retarget or delete a context. All three routes require the shared host token.

The harness validates loopback-listener ownership and uses an explicit WebSocket
endpoint, no profile reads or arbitrary port scans. It attaches only after the
pinned URL/native bounds identify exactly one target. Session target IDs remain
private. Native `input.*` / `window.focus` return `browser_route_required` for this
context even if invoked directly; the agent instead gets `browser_snapshot` and
`browser_act` with semantic references, no arbitrary JS/CDP/cookie tools. Browser
scroll uses **CSS pixels, positive downward**, unlike native wheel-notch deltas.
References are consumed after action and invalidated by navigation. Tool calls
serialize; unknown outcomes poison writes and cannot trigger mutation retries.
Cancellation revokes the native context and closes the CDP connection. Cleanup
detaches only; it never closes the user's Brave process or tabs.

Additional domain errors include `browser_disabled`, `browser_tab_unknown`,
`browser_target_changed`, `browser_target_ambiguous`, `browser_page_unsupported`,
`browser_stale`, `browser_occluded`, `browser_dialog`, `browser_disconnected`,
`browser_timeout`, `browser_unsupported_action`, `browser_unsupported_link` and
`browser_script_failed`. Field-local credential refusal is `credential_input_blocked`;
file deletion remains `file_deletion_blocked`. The native Settings permission defaults
to false, is supplied only by the authenticated host and is rechecked before mutation.
Neither text snapshots nor opt-in expose stored field values; the setting allows input
only. It does not disable macOS Secure Keyboard Entry, which no longer blanket-blocks
ordinary typing, clicks or observation. Only a clearly pre-mutation `browser_stale`
authorizes taking a fresh snapshot; uncertain writes must not be retried.

This transport does not make opaque page scripts or trusted global extensions a
no-delete sandbox. Supported page scope, installation and acceptance limits are in
`host-macos/BROWSER_INTEGRATION.md`. Windows behavior/schema remains compatible;
the optional Mac browser hint is additive.

### Launcher routes (macOS)

Contract code: `node-harness/src/contracts/launcher.ts`; exact wire fixtures:
`shared/fixtures/launcher/*.json` (the conformance suite checks both sides). Same
envelope as every host tool (`{arguments}` → `{ok:true,result}` | `{ok:false,error}`);
`contextId` is optional on all three. The Windows host has none of these routes: Node
then registers only its engine-only instant tools and never calls them.

| Route | Kind | Arguments | Result |
|-------|------|-----------|--------|
| `launcher.searchFiles` | read | `nameGroups: string[][]` (OR of AND-groups, ≤ 6 words in total, each ≤ 64 chars, no control/format characters; words < 3 chars match whole words only), `contentType?` (UTI, `kMDItemContentTypeTree`), `scopes?: ("home"\|"applications"\|"icloud")[]` (default `["home"]`), `maxResults?` (≤ 200, default 100) | `{items: FileCandidate[], truncated, elapsedMs}` |
| `launcher.listApps` | read | none | `{version, apps: [{bundleId, name, aliases[], path, running}]}`; `version` changes with the index (Node caches by it) |
| `launcher.open` | effect | `action`: `openApp {bundleId}` \| `openURL {url}` (http/https) \| `openFile {token}` \| `revealFile {token}` | `{status, performed}`; `performed: "revealFile"` when an executable, script or installer was downgraded from `openFile` |

`FileCandidate = {token, name, path, contentType?, createdMs?, modifiedMs?, lastUsedMs?,
useCount?, isDirectory, isPackage}`. Tokens are host-minted per search (random 128-bit,
`tok_` + 32 hex, TTL 10 min, ≤ 500 live, scoped to the context, revoked with it); `.Trash`
paths are never returned. Node keeps `path` for ranking and display folders only: the
model sees refs (`f1`, `f2`, …) and names, cards carry tokens, and nothing logs either.
`launcher.open` appears in `GET /tools` only while computer control is enabled and refuses
with `policy_blocked` in read-only invocations and for every other action type (copyText,
system, anything delete/trash/move-like); an unknown or foreign token is `token_expired`.
Host messages can name apps or files, so Node logs launcher outcomes by code only.

### Host actions

The closed effect vocabulary (`node-harness/src/contracts/actions.ts`, Swift mirror
`InstantContracts.swift`). Node never performs any of them; it returns descriptors that
the native host validates against its own `LauncherPolicy` before acting.

```ts
type HostAction =
  | { type: "copyText"; text: string }                    // ≤ 4000 chars
  | { type: "typeIntoPinned"; text: string }              // instant lane only; through InputPolicy (input.typeText)
  | { type: "openURL"; url: string }                      // http/https only
  | { type: "openApp"; bundleId: string }                 // from the host app index
  | { type: "openFile" | "revealFile" | "copyPath"; token: string } // host-minted tokens only
  | { type: "system"; op: SystemOp; value?: number | boolean | "dark" | "light" } // instant lane only
  | { type: "askAgent"; prompt: string };                 // ≤ 500 chars; seeds a fresh /invoke
type SystemOp = "appearance.set" | "appearance.toggle" | "volume.set" | "volume.step" | "volume.mute" | "display.sleep";
```

There is no delete, trash, move, rename, write, power, lock or logout action. `volume.set`
takes a 0…1 fraction, `volume.step` a signed fraction within ±1, `volume.mute` a boolean,
`display.sleep` nothing; the macOS host refuses `appearance.*` with `unsupported` in v1.
Model-authored cards may bind only `copyText | openURL | openApp | openFile | revealFile |
copyPath | askAgent`, and file actions only with tokens from a host search in the same
thread. Agent tools may request only `openApp | openURL | openFile | revealFile` through
`launcher.open`.

## Node Harness API (17832)

### `GET /health`

Same shape as the host health endpoint, `"service":"node-harness"`.

### `POST /instant`

Deterministic instant lane (`node-harness/src/instant`; contracts
`node-harness/src/contracts/instant.ts`, Swift `InstantContracts.swift`, fixtures
`shared/fixtures/instant/*.json`). Synchronous `200`, token-authed, body ≤ 4 KB
(`413` above), strictly validated (`400`). The macOS host calls it for typed previews,
voice partials and the final utterance; the Windows host does not use it (it gets instant
answers through `/invoke`).

```ts
interface InstantRequest { text: string /* ≤ 500 */; phase: "typing" | "partial" | "final"; seq: number /* integer ≥ 0 */;
  takeId?: string; contextId?: string; locale?: string /* BCP 47 */; inputMode?: "text" | "voice"; silenceMs?: number }
type InstantResponse = { seq: number; elapsedMs: number; source: "grammar" | "classifier" } & (
  | { decision: "answer"; intent: InstantIntent; title: string; subtitle?: string; card: CardSpec }
  | { decision: "list"; intent: "file_search" | "open_app"; title: string; card: CardSpec; relaxed?: boolean }
  | { decision: "act"; intent: InstantIntent; title: string; action: HostAction; confirm: boolean; card?: CardSpec }
  | { decision: "refuse"; code: "file_deletion_blocked"; message: string; card: CardSpec }
  | { decision: "fallthrough"; reason: "no_match" | "deictic" | "compound" | "low_confidence" | "timeout" | "unknown_place" | "disabled";
      hints?: ClassifierHints });
```

- Anchored EN/DE grammar over the whole utterance: calculator/units/bases (fend), ECB
  currency, time zones, date math, open app/URL, web search, file search, volume/display
  sleep, and file-deletion refusal (every phase). Deictic words ("this", "hier", "markiert")
  and two-step requests fall through to the agent.
- `act` only on `phase: "final"`; `typing`/`partial` return previews (`answer`/`list`) or
  `fallthrough`. Node never performs effects: the host executes `action` after its own
  `LauncherPolicy` check. Budgets: 60 ms, 250 ms for file search and the first rate download.
  It never fails: errors and timeouts are `fallthrough`.
- Latest wins per take (`takeId`, else `contextId`): a newer `seq` aborts the dispatch still
  running for that take (it answers `fallthrough`/`timeout`), and a request older than the
  newest seen is answered `fallthrough`/`timeout` at once. The final wins: once a take's
  `final` arrived, later `typing`/`partial` requests for it are answered `fallthrough`/`timeout`
  and never abort it, and a `final` is only superseded by a newer `final`. Requests with
  neither `takeId` nor `contextId` are independent. Hosts drop responses by `seq`.
- File and app results come from the host's launcher routes; file rows bind host tokens
  (`openFile`/`revealFile`/`copyPath`), never paths. Every card passes the strict catalog
  check before it is returned (see Result cards).
- Currency: the first currency question (also a typed preview) downloads the ECB
  reference rates once (conditional GET, cached; disclosed in Settings; `PI_OS_FX_RATES=0`
  disables it). Until then the answer is a Notice card ("Downloading ECB reference rates…").
- On a grammar miss in `partial`/`final`, the optional advisory classifier (Settings; off by
  default) may add `hints` within 250 ms. Hints never trigger or authorize anything; for a
  `takeId` they are kept briefly so the following `/invoke` can raise (never lower) the
  routed tier or request the screenshot. The classifier receives the cleaned utterance
  (wake word and politeness removed); neither text nor hints are logged.

### `POST /invocations/prepare`

`{"contextId":"ctx-123","takeId":"take-7"}` → `202 {"accepted":true,"takeId":"take-7"}`
(macOS, at hotkey key-down once the context is pinned). Best effort: it warms the instant
engines (no network) and the host app index, and in agent mode pre-builds the take's agent
session (model runtime with `pi-os/auto`, resources, extensions, tool set) from the pinned
snapshot. `POST /invoke` with the same `takeId` **and** `contextId` adopts it when nothing it
was built from changed (input permissions, launcher routes, resource mode, model selection,
routing bias, Brave route); otherwise it is discarded and a fresh session is built. The
screenshot usually lands after the prepare: the prepared session is still adopted when the
routed turn attaches no screenshot (its seeded coordinate authority is then revoked), and
rebuilt from the current snapshot when the turn attaches one the session was not built
with, so an attached image always carries its authority. A prepared session lives 30 s, at
most 3 exist, a newer prepare for a take replaces it, and
`{"takeId":"take-7","cancel":true}` → `200 {"cancelled":true,"takeId":"take-7"}` discards it
(for example when the key is released without a request). A prepare for an unknown context
builds nothing.

### `POST /invoke`

Entry point for a hotkey submission. Request:

```json
{
  "invocationId": "inv-abc",
  "contextId": "ctx-123",
  "prompt": "Create a chart from this table",
  "invokedAt": "2026-08-24T12:00:00Z"
}
```

- `invocationId`: UUID, generated by the caller (host) for log correlation.
- `contextId`: references the pinned snapshot stored in the C# host.
- `retainSession?: boolean`: explicit opt-in to an in-memory conversational thread.
  Mac build 11 sends true; omission/false preserves the one-shot lifecycle of older
  hosts. At most 20 threads are retained, with a fixed 30-minute lazy TTL (409
  `thread_limit` before accepting a new retained invocation at capacity).
- The snapshot itself is NOT embedded; the agent fetches it via
  `desktop.getContext`.
- `takeId?: string` (`[A-Za-z0-9_-]{1,128}`): the push-to-talk/composer take (macOS).
  A host that sends it runs `POST /instant` itself (or bypassed it on purpose, ⌥↵ "Ask pi"),
  so `/invoke` then skips the instant lane; with a matching `contextId` the session
  prepared by `POST /invocations/prepare` for that take is reused, and advisory classifier
  hints that `/instant` already received for the take are fused into routing (never awaited).
- `input?: {mode: "text"|"voice", confidence?: 0..1, locale?: BCP 47, durationMs?: 0..3600000,
  engine?: string}` (strictly validated, 400 otherwise). Voice adds a short "spoken request,
  may be misheard" note (with the locale only) to the prompt. The record keeps
  `input: {mode}` only; none of it is logged.

Without a `takeId` (the Windows host, older Mac builds), a first-turn `/invoke` runs the
instant dispatcher on the prompt (`phase: "final"`, no classifier): an `answer` with a result
(calculator, units, currency, time, dates) completes the invocation at once with
`responseText` (the card's text form) and `card` (`cardComplete: true`), no model and no
session (`followupAvailable: false`; a follow-up is a fresh `/invoke`, e.g. "Earlier quick
answer: Q → A"). Everything else falls through to the agent: `act` and `list` need host
effects, an `answer` that carries only a Notice (for example "Downloading ECB reference
rates. Try again in a moment.") answers nothing, and `refuse` stays with the agent, which is
bound by the same file-deletion prohibition (the deletion grammar also matches some ordinary
edits, such as deleting a message or typed text, that Windows keeps handling as before).

Response: `202 {"accepted": true, "invocationId": "inv-abc"}`.
The agent then runs its observe/act loop asynchronously.

Agent sessions use the stored Settings model, or the Auto virtual model `pi-os/auto` when
none is stored (see Model settings). On Auto, `decide()` picks the physical model and level
from content-free heuristics before the prompt is sent (< 1 ms, no classifier wait) and
sets the turn's active tools (light quick/fast lanes leave `codemode` inactive until a
`pi_os_escalate` hand-off). The pinned screenshot is attached to the first prompt only
when that decision needs the screen (deixis, acting in the app, browsing without CDP); the
text context summary is always sent and `desktop_capture_window` stays available. Without
an attached image there is no coordinate authority until the model captures (macOS). A
manually chosen model keeps the previous behaviour (screenshot always attached).

### `GET /invocations/{invocationId}`

Execution status (hosts poll it; macOS streams it, see `/events`):

```json
{
  "invocationId": "inv-abc",
  "state": "running",
  "startedAt": "...",
  "finishedAt": null,
  "activity": "thinking",
  "steps": [
    { "tool": "desktop.getContext", "at": "...", "ok": true }
  ],
  "responseText": null,
  "failureMessage": null
}
```

`state`: `"queued" | "running" | "completed" | "failed" | "aborted" | "timed_out"`.

`steps` grows live while the invocation runs (one entry per host tool call
and per agent tool execution); clients poll this endpoint for progress.

Result-surfacing fields (ux-design-notes.md):

- `activity`: current live line for the host pill — a tool name while a tool
  executes, `"thinking"` during reasoning, absent when idle. Cleared when the
  invocation reaches a terminal state.
- `responseText`: final agent answer, capped (~8 KB); set on completion.
- `failureMessage`: why the invocation failed/aborted/timed out; terminal
  failure states only. Machine-readable prefixes include `session_closed:`,
  `not_idle:`, `control_disabled:` and `no_authenticated_model:` (Auto found no model with
  credentials; the user should pick a model or sign in to a provider).

Additive fields (all optional; Windows ignores them, its polling contract is unchanged):

- `revision`: increases with every change of the record (the SSE stream sends each once).
- `partialText`: visible text of the assistant message currently streaming (≤ 8000 chars,
  accumulated deltas); cleared when the turn ends.
- `card` / `cardComplete`: a result card (`pi-os-ui/1`, see Result cards). While the model
  streams `show_result`, partial cards arrive with `cardComplete: false` and their buttons
  must stay disabled; the validated card follows with `cardComplete: true`. A turn that
  ends without a complete card clears it. Instant answers set a complete card too.
  `responseText` always carries the plain-text fallback (lead sentence + card text).
- `route`: `{tier?, provider, model, thinkingLevel, reasons[], auto}` — the model the turn
  ran on. On Auto it starts as the decision (`tier`, content-free `reasons` such as
  `intent=answer`, `screenshot`, `explicit-deep`) and follows escalations and failovers
  (`cause=…`); for a manual model `auto: false` and no `tier`.
- `input`: `{mode: "text"|"voice"}` from the request.
- `timings`: stage milliseconds, e.g. `instantMs`, `contextMs`, `sessionMs`, `routeMs`,
  `ttftMs` (model time to first token), `firstTokenMs`, `totalMs`.
- `followup` requests may also carry `input` (same validation).

#### `GET /invocations/{invocationId}/events`

Server-sent events (macOS; use a separate long-lived HTTP session). Token-authed; `404`
for an unknown id. Each change of the record is sent as

```text
event: record
data: {"invocationId":"…","revision":7,"state":"running","partialText":"…",…}

```

with the **full** record JSON (same shape as `GET /invocations/{id}`), at most one write per
33 ms window (the latest revision wins; a reader that falls behind gets the latest record
once it catches up, never a backlog). The stream starts with the current record, ends
after the record reaches a terminal state (that record is always sent), and carries
`: ping` comments every 15 s. A follow-up turn is a new stream. Disconnecting is safe at
any time; polling `GET /invocations/{id}` remains the fallback and the Windows path.

#### `POST /invocations/{invocationId}/cancel`

Requests cancellation of a running invocation (A.3):

- `202 {"accepted": true, "invocationId": "..."}` — cancellation started;
  the record ends in state `aborted`.
- `409 {"error":{"code":"not_running"}}` — invocation exists but is not
  in flight (already finished, failed, or cancelled).
- `404 {"error":{"code":"not_found"}}` — unknown invocation id.

Each invocation also has a wall-clock timeout (`PI_OS_INVOKE_TIMEOUT_MS`,
default 300000, `0` disables). A timed-out invocation ends in state
`timed_out`; both terminal paths record a `cancel` / `timeout` step.

#### `POST /invocations/{invocationId}/followup`

Body: `{"prompt":"..."}` (nonblank, at most 20,000 characters).

- 202 accepts one sequential turn on the existing invocation/context/session/model.
  The status record is synchronously requeued; prior response/failure/activity are
  cleared before acknowledgement, while step history is retained.
- 409 `not_idle` rejects a concurrent turn; nothing is queued or replayed.
- 404 `session_closed` means no retained thread, reader closure, cancellation or expiry.
- Each turn gets a new cancellation/timeout controller. Abort listeners are removed
  when it settles. Cancel/timeout closes the thread; Mac revokes its native context.
- Host context is revalidated before a follow-up prompt. Permission loss cannot expand
  or resurrect the original tool/resource scope. First-turn model and settings stay fixed.
- Screenshots and browser references from earlier turns are historical: a follow-up
  clears action-reference authority and requires fresh observation. Native context TTL,
  cumulative input budgets and uncertain-input poisoning are never reset.
- `followupAvailable` in status identifies an open thread; a failed follow-up can retain
  it for an explicit retry if authority remains valid. It is false after close/revocation.

#### `POST /invocations/{invocationId}/close`

Idempotently returns `200 {"closed":true,"invocationId":"..."}` even for an unknown
thread. Revoke the entry before awaiting cleanup; abort an active turn and dispose
SDK, browser and provider-bootstrap resources. Closure during async startup must not
allow a late session to be retained. It does not close user tabs or terminate Brave.
Mac closes/revokes before releasing the harness reservation; its reader survives
outside clicks/deactivation. Escape, Done, close, a replacing hotkey, security-setting
changes and quit end that single native reader's thread. Recalled answers do not
recreate sessions. No idle status polling occurs.

### Model settings (settings page)

The host tray menu opens a settings page for agent model + reasoning effort.
The harness owns both the pi catalog and the stored choice. Every NEW hotkey thread
picks up the current setting; an existing thread and its follow-ups keep their model.

#### `GET /models`

Catalog for the settings page. Only models with configured authentication are
listed (`ModelRuntime.getAvailable()`), sorted provider then id, preceded by the Auto
virtual model whenever at least one physical model is usable:

```json
{
  "models": [
    { "provider": "pi-os", "id": "auto", "name": "Auto", "reasoning": true, "thinkingLevels": ["low", "medium", "high"] },
    {
      "provider": "openai",
      "id": "gpt-5.2",
      "name": "GPT-5.2",
      "reasoning": true,
      "thinkingLevels": ["off", "low", "medium", "high", "xhigh"]
    }
  ],
  "current": { "provider": "openai", "modelId": "gpt-5.2", "thinkingLevel": "low" }
}
```

- `thinkingLevels`: pi thinking levels this exact model accepts, ascending;
  non-reasoning models report `["off"]` only. Derived via pi-ai's
  `getSupportedThinkingLevels` (`thinkingLevelMap` null entries excluded).
- `current`: the stored selection. With nothing stored, Auto is the default:
  `current` is `{"provider":"pi-os","modelId":"auto","thinkingLevel":<bias level>}` plus an
  additive `"currentIsDefault": true`. `current` is `null` only when no model is usable
  (then `models` is empty).
- Auto (`pi-os/auto`) is a pi 1.0 virtual model: for every request it picks a physical
  model and thinking level among the authenticated models (heuristics, measured latency,
  routing settings) and escalates or fails over within the turn. Its thinking levels are
  the routing bias: `low` = prefer speed, `medium` = balanced, `high` = prefer quality.
  xhigh/max levels are reached only through explicit words ("think hard", "ultrathink",
  "gründlich") or tier overrides. Hosts may show it as "Auto (recommended)". pi's own
  `~/.pi` settings are never changed.

#### `POST /settings/model`

Request body `{"provider":"...","modelId":"...","thinkingLevel":"..."}`.
Validated against the live catalog before storing:

- Unknown/unauthenticated model → `400 {"error":{"code":"invalid_arguments"}}`.
- Level not in that model's supported list → `400` listing valid levels.
- Success → `200 {"current":{"provider","modelId","thinkingLevel"}}`; the
  switch is logged (`[settings] model switched: <old> -> <new>`).
- `{"provider":"pi-os","modelId":"auto","thinkingLevel":"low"|"medium"|"high"}` is always
  accepted (other levels → `400`) and also sets the routing `bias`.

The choice persists under the `model` key of `%LOCALAPPDATA%\pi-os\settings.json` on
Windows or `~/Library/Application Support/pi-os/settings.json` on macOS (an atomic
read-modify-write that keeps every other key, e.g. `routing`) and is re-applied to each
new invocation, which also logs the effective pair
(`[agent] model=<provider>/<id> effort=<level>`) as the session starts. A stored model
that is no longer registered falls back to Auto.

#### `GET /settings/routing` / `POST /settings/routing`

Auto's knobs, stored under the `routing` key of the same `settings.json`:

```json
{ "bias": "balanced", "maxAutoTier": "deep", "allowLocalModels": false,
  "tierOverrides": { "deep": { "provider": "openai-codex", "id": "gpt-6.1-sol", "thinkingLevel": "medium" } } }
```

- `bias`: `speed | balanced | quality` (default balanced). Changing it while the stored
  model is Auto also updates that selection's level.
- `maxAutoTier`: highest tier Auto picks on its own, one of `quick | fast | standard | deep |
  max` (default `deep`); explicit depth words may exceed it.
- `tierOverrides?`: pin `{provider, id (or modelId), thinkingLevel}` per tier; validated
  against the available catalog at save time (`400` naming the problem). `null` for a tier
  clears it; `"tierOverrides": null` clears all.
- `allowLocalModels`: route to loopback providers (default false: local inference is
  coordinated separately).
- POST takes a partial patch; unknown keys and invalid values are `400`. Both GET and POST
  return the full current settings object.

Measured latency per `provider/model@level` and temporary provider health blocks
(rate limits 60 s, quota 30 min, auth 10 min) persist in `routing-stats.json` next to
`settings.json` (ids, counts and averages only).

#### `GET /settings/classifier` / `POST /settings/classifier`

Optional advisory intent classifier, stored separately in `classifier.json`; default off.

```json
{ "kind": "off" | "laya" | "pi", "python": "/abs/venv/bin/python", "script": "/abs/…", "modelDir": "/abs/…",
  "sha256": "…", "calibration": "/abs/….json", "threads": 4, "provider": "cloudflare-workers-ai", "model": "typesafe/jev",
  "shadowLog": false,
  "status": { "kind": "laya", "state": "stopped", "reason": "…", "name": "laya", "shadowLog": false,
              "laya": { "failures": 0, "maxRestarts": 3, "lastError": "…", "model": { … }, "requestErrors": 0 } } }
```

- `laya`: a local CPU-only sidecar (stdio child of the harness, never the GPU), started
  lazily on first use and warmed at `/invocations/prepare`; it stops after 10 idle minutes
  and with the harness. ~5 GB RAM while loaded, ~18 s to load. `pi`: a pi catalog
  classifier (e.g. Cloudflare Workers AI Jev); this sends utterances to that provider.
- Paths must be absolute; `PI_OS_LAYA_PYTHON` / `PI_OS_LAYA_MODEL_DIR` fill missing ones.
- `status` is read-only (an echoed `status` in a POST is ignored): `state` is
  `off | unavailable | configured | stopped | starting | ready | stopping | backoff | failed`,
  with `reason`/`laya.lastError` such as `disabled_by_env`, `model_not_configured`,
  `network_blocked`, `ready_timeout`, `load_failed`, `spawn_failed`, `protocol_mismatch`,
  `crashed`.
- `shadowLog: true` appends labels, probabilities and latency (never text) to
  `logs/classifier-shadow.jsonl` for calibration; it pauses at 5 MiB.
- When enabled, Laya is also registered as the pi classifier provider `laya`
  (model `multilingual`) on every runtime; chat model lists are unaffected.
- Classifier output is advisory: it may raise Auto's tier or request the screenshot, never
  lower a rule-derived tier, select an instant action or authorize anything.

### Resource compatibility settings

`GET /settings/resources` returns
`{"current":{"mode":"isolated"|"trustedGlobal"},"warning":"..."}`.

`POST /settings/resources` accepts `{"mode":"isolated"}` or
`{"mode":"trustedGlobal","acknowledgeUnpinnedAccess":true}`. Enabling trusted mode
requires the host to advertise all native input routes and no explicit read-only
launch override; otherwise it returns 409 `control_disabled`. Missing acknowledgement
is 400. The authenticated setting is persisted atomically in `resources.json`, applies
to future sessions/catalog loads, and is suppressed whenever native control is unavailable.

Default Mac mode remains isolated. Trusted mode intentionally loads global pi resources
and coding tools; arbitrary trusted code can bypass native window restrictions. The UI
must show this distinction and obtain explicit confirmation, not imply sandboxing.
Project extensions/context are not trusted on Mac. Factory providers are registered
before model choice; catalog-only loading does not invoke a model or session-start hooks.

## Result cards

Answers can carry a native card: a json-render flat spec restricted to a closed, static
catalog (`format: "pi-os-ui/1"`; wire types `node-harness/src/contracts/cards.ts`, Zod
catalog and validation `node-harness/src/ui`, Swift `CardContracts.swift` + `CardView.swift`,
fixtures `shared/fixtures/cards/*.json`).

```ts
interface CardSpec { format: "pi-os-ui/1"; root: string; elements: Record<string, CardElement> }
interface CardElement { type: CardComponent; props: Record<string, unknown>; children?: string[];
                        on?: Record<string, { action: HostAction["type"]; params: Record<string, unknown> }> }
```

Components: `Answer {summary?}` (root only), `Markdown {source ≤ 4000}`, `ResultCard {kind:
math|conversion|currency|time|date|fact, input?, value, detail?, freshness?}` (event `copy` →
copyText only), `KeyValue {title?, items ≤ 24}`, `Table {title?, columns 1..6, rows ≤ 50}`,
`ItemList {title?, total?}` (children: `Item` only), `Item {title, subtitle?, icon?, detail?}`
(events `primary`/`secondary`/`tertiary`, e.g. openFile/revealFile/copyPath),
`Notice {tone, text ≤ 500}`, `Status {state, text, progress?}`, `Suggestion {prompt 1..160}`
(event `press` → askAgent with exactly that prompt).

Node enforces before any host sees a card: at most 150 elements and 64 KiB of UTF-8 JSON;
the root is `Answer` and `Answer` appears only there; `ItemList` holds only `Item`s and
every other component is a leaf; no missing, shared or cyclic children, no orphans;
unknown props/fields, `$`-keys and `visible`/`repeat`/`watch`/`state` are rejected; bindings
use declared events only and are exactly `{action, params}` forming a valid HostAction.
Model cards (`show_result`) bind only the model-card subset of Host actions, and their
file tokens must be live in the thread's ledger (the model writes refs `f1…`, Node fills
tokens). Instant cards pass the same strict check with the full action set. Element keys
are stable across partial updates; partial cards (`cardComplete: false`) carry real
bindings, so hosts keep their buttons disabled until the card is complete. Every card has a
plain-text fallback in `responseText`; a host that cannot decode a card shows that text.

## Invocation flow (happy path)

```text
User presses global hotkey
  |
  v
C# host: capture pinned context (BEFORE overlay), generate contextId
  |
  v
C# host: show overlay -> user submits prompt -> overlay closes
  |
  v
C# host --POST /invoke (contextId, prompt)--> Node harness   [202]
  |
  v
Node agent loop --POST /tools/desktop.getContext------------> C# host
  |                                                           [200]
  v
Node agent loop --POST /tools/<any tool>-- repeated --------> C# host
  |
  v
Node harness records steps; invocation completes/fails/is aborted/times out
```

macOS push-to-talk / composer flow (voice magic):

```text
hotkey down ── pin context ── POST /invocations/prepare {contextId, takeId}   [202]
  │  partial transcript / keystrokes ── POST /instant {phase: typing|partial} ── preview card
  ▼
release / Enter ── POST /instant {phase: final}
  ├─ answer / list / refuse ── host renders the card (no agent)
  ├─ act ── host LauncherService (LauncherPolicy) performs the HostAction
  └─ fallthrough ── POST /invoke {contextId, prompt, takeId, input}   [202]
                      └─ prepared session + Auto route ── GET /invocations/{id}/events (SSE)
```

Text fidelity/line breaks/no-default-clipboard and platform-specific typing mechanisms
are documented in [`docs/desktop-input-semantics.md`](../../docs/desktop-input-semantics.md).

## Non-goals for this version

- No MCP wrapping yet. The tool surface above maps cleanly onto MCP later;
  revisit once primitives stabilize (research question RQ5).
- No websockets and no steering/barge-in yet. Streaming is server-sent events on
  `GET /invocations/{id}/events` (macOS); polling `/invocations/{id}` stays fully supported
  (Windows polls; Mac falls back to it).
- No multi-tenant auth, no TLS. Loopback + token is the whole security story
  for this phase; deeper policy/approval design comes separately.
