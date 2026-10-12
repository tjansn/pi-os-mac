# Desktop input semantics

Reconciled with PriNova/pi-os upstream `9ddcfd4` on 2026-10-01. The shared
contract is text fidelity, line-break fidelity and no default clipboard fallback.
Win32 mechanics do not belong in the shared harness or the Mac host. Browser focus
and cancellation-safe key release were selectively ported from upstream `92075c8`
on 2026-10-09; the Accessibility-default transport and compact observations remain.

## Contract

1. Preserve character order and Unicode, including surrogate pairs, emoji and
   combining marks. Do not substitute a keyboard-layout approximation for text.
2. LF (`\n`), CRLF (`\r\n`) and lone CR (`\r`) each represent **one** line break.
   Consecutive breaks preserve blank lines. Canonical receiving text uses LF.
3. Do not mutate the user's clipboard as the default input mechanism.
4. Allocate releases before posting presses; balance each pair even on cancellation.
   If any input might have been posted before an interruption, return an uncertain
   failure and never replay it. OS event posting is not proof of application delivery.
5. Identity, exact focus, live credential policy, deletion checks and cumulative
   budgets still apply before every native stroke. Permission to type in a credential
   field never permits reading its value.

## Native macOS

`PiOSCore/TextInput.swift` builds scalar-safe strokes and collapses CRLF. The native
controller sends Unicode scalar pairs and real Return-key pairs for line breaks.
Pairs are consecutive and balanced, **not an atomic OS transaction**; macOS provides
no equivalent of a Win32 `SendInput` batch guarantee.

Default spacing is 20 ms between strokes. `PI_OS_TYPE_INTERVAL_MS` accepts 0–1000 ms;
0 explicitly disables pacing. Invalid values use the safe default. Large paced
requests are refused **before focus/input** if their scheduled pacing exceeds 20 s,
leaving headroom under the 30 s HTTP tool deadline. At the default, split text above
1000 scalar/newline strokes into smaller sequential calls. The existing 20,000 UTF-16
unit argument limit also applies. Do not silently truncate to fit a deadline.

Return can submit a single-line form or execute a terminal command. Only request
multiline native entry when the destination is an identified multiline editor and
those semantics are authorized; do not use multiline text to bypass action policy.

## Scoped Brave/CDP

The browser adapter normalizes CRLF/CR to LF and uses `Input.insertText`, not a burst
of keystrokes or clipboard paste. It verifies the resulting field value privately.
Multiline fill is accepted only for a textarea or contenteditable receiver; it is
refused before focus/input for single-line controls. No Enter-key submission is
synthesized by multiline fill. Unexpected framework transformations are uncertain
failures, not reasons to retry.

Browser fill and keypress recheck the active control, every shadow host and page
focus before delivery. Fill also requires a complete replacement selection;
selection-less input types (including email/number) are refused for fill rather
than appended to blindly. Their focused keypresses remain available. Observed
focus or selection loss stops delivery without refocusing or replay. These CDP
checks and input calls are separate: they reduce the race but do not provide
atomic recipient isolation.

Browser key-down/up use the same target session. Cancellation before key-down
sends neither event. Once key-down can have been sent, release is attempted before
action cancellation or reader disposal closes the socket. Each leg has a separate
1.5 s maximum deadline. Socket loss or a failed release is an uncertain outcome:
no reconnect or replay, and no further mutations in that task. These rules apply
to the opt-in CDP transport, not the default Accessibility path.

## Windows upstream

Upstream introduced paced typing (`e7a3bb6`) and the documented contract/newline fix
(`9ddcfd4`): 20 ms per character, CRLF collapse, Return for breaks, and paired Unicode
`SendInput`. The local Windows host has not been rebased to those commits or tested
here. This document records their contract, not a claim of a Windows regression run.

## Regression evidence

- Swift event-sequence tests: Unicode, surrogate pairing, line endings, blank lines,
  pacing, oversized preflight refusal and balanced interruption.
- Signed native receiving fixture: exact multiline Unicode text, pacing duration and
  unchanged clipboard change count, plus unchanged unrelated-window canary.
- Browser helper/session tests and signed Brave fixture: multiline normalization,
  private value verification, single-line refusal and stale-reference protection.
- Offline browser helper/session/loopback transport tests: focus redirection,
  shadow-host and replacement-range checks, cancellation before/after key-down,
  release-before-disposal, lost sockets and compact post-action observation.
  The new focus/release cases have not been accepted against a live browser here.

These fixtures do not establish fidelity across every editor, framework, keyboard
layout or OS release. Add a harmless receiving fixture before changing defaults or
claiming support for another application pipeline.
