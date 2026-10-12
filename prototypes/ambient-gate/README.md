# Ambient gate — MOCK ONLY

A small deterministic **CPU-only policy replay**, not an always-on assistant. It accepts hand-authored EN/DE/mixed transcript envelopes and changes only an in-memory dummy counter/note. It has **no microphone, ASR, model, training, downloads, provider, network, filesystem writes, account access or OS actions**. Do not connect it to native execution or treat its fixture trust flags as security evidence.

## Run (Node 20+, no npm install)

From the repository root:

```sh
node prototypes/ambient-gate/replay.mjs --list
node prototypes/ambient-gate/replay.mjs
node prototypes/ambient-gate/replay.mjs --scenario en-replace-de-short-confirmation
node --test prototypes/ambient-gate/*.test.mjs
```

The CLI prints one JSON record per scenario: decision/reason sequence, synthetic-evidence label and final dummy state. No text is sent elsewhere. Imported `.mjs` fixtures are executable **trusted local code**, not a format for arbitrary untrusted uploads. There is no package manifest or dependency installation.

**Validation on 2026-10-09:** `node --check` succeeded for all four `.mjs` files. The exact `node --test prototypes/ambient-gate/*.test.mjs` command was **blocked before execution by dcg**, reason `Script-file inspection incomplete: test/watch runners select additional sources dynamically` (`heredoc.script_files:unverified`). No bypass, alternate test runner or allowlist was used; **tests and CLI replay remain unexecuted here**. The suite declares 22 scenario tests plus 25 invariant tests (47 intended cases); passing results must be established in an authorized environment, not inferred from syntax checks.

## What is separated

1. **Origin:** only a fixture-marked human microphone source with explicit trust and explicit `media:false` / `selfTts:false` survives. Unknown/missing fields, playback and self-output fail closed, even with both scores at 1.
2. **Finality/completeness:** final ASR and complete intention are separate required annotations. Missing flags, partials, quoted/negated/ambiguous speech abstain. No action on partials.
3. **Addressedness:** computer label + synthetic score + wake/PTT evidence, or a live narrowly scoped follow-up aperture. Recognized command words and a caret are insufficient.
4. **Intent:** its own enum and score; questions produce a canned answer, never default dictation. Unknown intent clarifies, never invokes an agent/OS fallback.
5. **Policy:** hard risk table + field role + fresh target lease + conservative EN/DE vocabulary veto. Confidence cannot override any of these. Deletion and external actions are always prohibited; credential input is always denied in this experiment.
6. **Effect:** reversible in-memory action, short confirmation, canned answer, clarify or silence. No real execution adapter exists.

**Every score is synthetic fixture data, not a calibrated probability.** `0.85` addressedness and `0.80` intent floors are plumbing choices, not product recommendations or measured accuracy. No ASR or trained decision model was tested.

## Mock actions / state

- `increment`: add one to the dummy counter, with one owned Undo.
- `replaceText`: preview a dummy note replacement; single-use matching confirmation required within **2 seconds**.
- `question` / scoped `questionDetail`: canned local answer ID, no text insertion.
- `startDictation`: explicitly confirm destination first; matching chunks only, within an absolute **5-second** mock session; `stopDictation` ends it. These small limits illustrate leases, not useful dictation durations.
- `undo`: restores the last mock change only while the same session/speaker/conversation/target owns it and the dummy version is unchanged. A fixture user edit/focus change invalidates it.
- `cancel` / `mute`: revoke pending work/apertures/dictation and increment a cancellation epoch. Mute is sticky; **only trusted fixture UI** can resume. Background audio cannot resume or confirm.

Follow-ups bind session + dummy speaker + conversation + app/window/element/content revision/field role + epoch; only offered kinds are accepted. Question follow-ups cannot arm dictation, and an Undo follow-up cannot execute a new command. Fresh focus is required for answers/field or counter actions/confirmation (1-second mock observation age), but addressed cancel/mute is target-independent—even at a stale or credential focus. Same-target refresh does not renew a confirmation TTL. Changing focus, a dummy user edit, cancel or mute revokes old-epoch late results. Sequence numbers reject duplicates; a newer addressed request replaces pending work.

## Files / API

- `gate.mjs`: pure state machine, `AmbientGate.step(event)`, `snapshot()`, `replay(events)` and `focusBinding(focus)`.
- `fixtures.mjs`: 22 bilingual scenarios with expected decisions and final dummy state; factories for tests.
- `gate.test.mjs`: `node:test` scenarios and boundary/invariant assertions.
- `replay.mjs`: optional stdout-only CLI.

Speech envelopes carry monotonic integer `at`, increasing `seq`, cancellation `epoch`, dummy scope IDs, source flags, finality/uncertainty annotations, language, utterance, separate `addressed` and `intent`, and the exact `targetBinding`. Optional transcript alternatives receive the same conservative vocabulary veto. `focus`, `control`, `fixtureEdit` and `tick` events have separate fixture-only origin labels; all unknown event types refuse. Time is injected—no sleeps, real clock, intervals or background jobs.

## Limits and privacy

This is not a classifier, wake detector, speaker authenticator, echo canceller, deletion-proof sandbox or production credential-input policy. The fixture already supplies the difficult labels; acoustic trust/complete-intention detection remains unsolved here. The tiny regex veto is deliberately overbroad (even some questions about deletion/negation abstain) and incomplete for arbitrary language, aliases and scripts.

Rejected background utterances are not retained in snapshots/results; accepted dummy dictation/replacement is deliberately visible in the mock note, and a short-lived pending replacement exists in process memory. This says nothing about real ASR memory, production journaling or telemetry. The existing field-local Settings credential opt-in is **not changed**; this mock has no opt-in and remains stricter. Its external-action refusal is a mock capability limit, **not** a new ban on ordinary explicitly requested pi-os clicks or actions. A global Secure Keyboard Entry flag is not an authorization signal or a typing veto.

Research, architecture boundaries, primary sources and the hardware/metrics plan: [`local-ambient-voice.md`](../../docs/research/immersive-hci/local-ambient-voice.md). No production files, install snapshots or permissions were changed.
