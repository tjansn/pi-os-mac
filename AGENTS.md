# pi-os Project Notes

## Command working directories

The repository root has no `package.json`. Run npm scripts from
`node-harness/`, or use `npm --prefix node-harness run <script>` from the root.

## Process safety

Never kill processes by image name (`taskkill /IM node.exe`, `pkill node`, and
similar). Shared runtimes also host unrelated tooling and live user sessions.

Kill only the specific PID this project started:

1. Resolve it: `netstat -ano | grep :<my-port>` — note the PID in the last column.
2. Verify it is not a known live-session process.
3. Kill exactly that PID: `taskkill //PID <pid> //F` (Git Bash: double slashes).

This rule exists because an image-wide `node.exe` kill destroyed a live agent
session on 2026-08-24.

## Stable install is a snapshot

`%LOCALAPPDATA%\pi-os\` (desktop shortcut target) only changes when someone
re-publishes. After implementation changes, run `refresh-install.ps1`
(repo root) — or the README recipe it wraps — and if that is not possible,
explicitly tell the user the installed copy is now stale. Never assume a
freshly built `bin/Debug` or repo state is what runs when the user presses
the hotkey.

## macOS signing and permission identity

Do not refresh a Screen Recording-authorized app with an ad-hoc build. Its default
code requirement is a build-specific cdhash, not just the bundle identifier. The
2026-09-15 UI refresh left a stale TCC requirement and caused an endless permission
loop even after the user toggled access and relaunched.

Use a stable signing certificate via `PI_OS_SIGN_IDENTITY` for installed updates.
`PI_OS_ALLOW_ADHOC_INSTALL=1` is only for an explicit user-approved disposable test;
never set it silently to get an install through. Do not weaken code requirements,
edit TCC databases, disable SIP, or trust a new certificate globally as a shortcut.
For an existing stale grant, repair only `ScreenCapture` for `dev.pi-os.mac` using
`tccutil`, with the app stopped, then let the user approve the unchanged app again.

## Computer-use policy (Tom's clarification, 2026-09-21)

Do not block ordinary apps by brand (including Orca, browsers and terminals), or
refuse a normal final click that the user explicitly requested. Block destructive
actions instead: file deletion, Move to Trash and Empty Trash are prohibited. Keep
identity/focus and ownership checks. Preserve ordinary text editing.

Credential input is a field-local rule (Tom's further clarification): block only
clearly identified username/password fields by default, with an explicit pi-os
Settings opt-in to allow input there. The macOS-wide Secure Keyboard Entry flag
must not veto ordinary typing, clicks or browser observation, and pi-os must not
disable that OS protection. Check click destinations, not an unrelated focused
password field. Keep credential values out of text snapshots even with input enabled;
use only dummy credentials in fixtures. This opt-in does not relax deletion policy.

Native AX/shortcut/known-command checks are defense in depth, not a filesystem
sandbox. Do not claim they can prove arbitrary scripts, shell aliases, unlabeled
controls or trusted extensions cannot delete files. No account actions or deletion
should be performed as part of QA; use harmless fixture buttons and counters.

## Local inference coordination

Tom's `_LOCAL_AI` DRACO benchmark coordinates local GPU ownership through
`/Users/tom/dev/Projects/_LOCAL_AI/.local-inference.lock`. While its benchmark
reservation is active, do not issue live Ollama/local-provider calls, including
model-catalog or GUI-grounding probes. Use fixture data and CPU-only tests; ask
for a coordinated window before local-GPU validation. Do not stop, unload, or
reconfigure the resident Qwen LaunchAgent. File existence alone is not proof of
advisory lock ownership; coordinate with the benchmark owner.

`npm test` installs a no-live-provider guard and runs serially. Swift lifecycle
tests start the harness through the same guard. Do not bypass it for convenience.

## Progress tracker commits

Do not create separate commits for `docs/progress-tracker.md` status updates.
Include tracker updates in the same commit as the related implementation work
(when applicable). A standalone tracker commit is only acceptable when no
implementation change exists in the same session.
