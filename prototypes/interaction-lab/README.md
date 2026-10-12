# Interaction lab — disposable, offline studies

Open **`index.html`** directly in your browser. No server, install or build needed:

```sh
open prototypes/interaction-lab/index.html
```

This is a design/testing artifact, not an embedded web UI proposal or a change to installed pi-os.
There is **no microphone, ASR, trained decision model, network request, clipboard access, app-owned local storage,
real application control, account action or filesystem mutation**. All content is fictional. Privacy follows this source's lack of capture/egress/storage code;
the CSP additionally restricts connections and media, but is not a microphone-permission or universal egress sandbox.
Browser history, extensions and the browser's own persistence are outside this prototype's guarantees. The voice buttons supply fixture events; their origin labels are ground truth,
not an acoustic classifier. The rewrite is canned, not AI-generated.

## Three experiments

1. **Point, then speak:** click **Include this paragraph**, preview “Make this shorter”, Apply, Undo.
   Test a focus change or human edit between preview and Apply: stale proposals must not act.
   A human edit after Apply must prevent unsafe Undo. This studies the *attention contract*,
   not actual AX target binding (pi-os already has pointing and a context shelf).
2. **Compose a habit:** a validated issue ID becomes a preview URL, or a snippet incorporates
   a reproducible fixture date. Three **invocation-fixture buttons** call the same compiler. No ⌘K shortcut, real selection menu or voice adapter is registered.
   No URL is opened. The public `linear.app/example` URL is illustrative, not a working integration.
3. **Listen without interrupting:** try room speech, explicit address, video playback, ambiguous
   references and cancelled partials. Mute immediately blocks events. Escape discards the attention preview
   or mutes ambient replay. This is scripted UX, not evidence of recognition/model accuracy.

## Questions for Tom

- Does pointing plus one small receipt feel more direct than opening a chat?
- Would you prefer draft → Apply, or immediate reversible edits after explicit commands?
- Which repeated workflow should become the first bounded recipe?
- For voice: always available with “Pi”, or a short address-free follow-up window after explicit engagement?
- Is an unobtrusive mic status enough, or do you want an audible acknowledgement as well?

## Files

- `state.js`: pure mock attention session and a bounded recipe compiler; browser + Node compatible.
- `lab.js`: UI-only wiring and scripted ambient cases.
- `state.test.mjs`: eleven unit tests (context/undo validity, recipe bounds, date validity, CSP).
- `review-checks.json`: manual browser checks and explicit unverified areas.
- `attention-v2.png`, `recipe-v2.png`, `ambient-v2.png`, `narrow-v2.png`: post-review captures. Earlier captures are retained as historical artifacts.
- `RESEARCH.md`: synthesis of the five supplied references and a strict-local ambient architecture.
- `REVIEW-FOLLOWUP.md`: independent review findings, fixes and remaining limitations.

## Verification

Interactive browser checks use a dedicated **`pi-os-interaction-lab`** agent-browser session, not the user’s
Brave profile or tabs. No live provider calls were made.

`node --check` passed for `state.js`, `lab.js` and `state.test.mjs` (syntax only, no assertions executed).
The Node test runner was **blocked by dcg**, not run:

```sh
node --test prototypes/interaction-lab/state.test.mjs
```

The guard reported `heredoc.script_files:unverified` (“test/watch runners select additional sources dynamically”).
No allowlist or workaround was applied. At the initial block it offered **`dcg allow-once 850485`** for human approval;
that approval may expire, so use a fresh guard receipt if necessary. Passing browser flows does not claim the Node
unit tests passed. After approving the exact test command, run it normally from the repository root.

**Not verified:** actual microphone capture, streaming ASR, addressed-speech classification, playback/echo rejection,
native focus/AX identity, physical latency/energy, Safari, VoiceOver and real-world accessibility.
Do not promote this prototype to production from the fixture results.
