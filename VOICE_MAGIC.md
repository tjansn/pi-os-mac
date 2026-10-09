# Voice magic — what was built, what was evaluated, what is still open

Branch `feat/voice-magic` (2026-10-02). Goal: say or type something and it happens at
once, with pi choosing a fast adequate model when a model is needed at all. Built on the
Whisper native UI (build 12), which it extends rather than replaces. User-facing docs:
[README](README.md#on-macos-voice-instant-commands-auto-and-cards),
[host-macos/README](host-macos/README.md), wire contract:
[shared/protocol/protocol.md](shared/protocol/protocol.md), Laya:
[sidecars/laya/README.md](sidecars/laya/README.md).

## How a request flows now

```
hold hotkey ≥ 250 ms ─► mic opens at key-down (Apple SpeechTranscriber, on-device)
  │  in parallel: pin context · Node warm-up · POST /invocations/prepare · window capture
  ├─ partial transcript / keystrokes ─► POST /instant (typing|partial) ─► live preview ("= 51")
  └─ release / Return ─► POST /instant (final)
        ├─ answer · list · refuse ─► native card, no model
        ├─ act ─► host LauncherPolicy ─► LauncherService (open app/URL/file, volume …)
        └─ fallthrough ─► POST /invoke ─► Auto router (pi-os/auto) ─► pi 1.0 session
                                   streaming via GET /invocations/{id}/events (SSE)
```

Node parses and describes; the native host performs every launcher effect after its own
policy check. Nothing can delete, trash or move files.

## Measured (offline, this Mac, no providers)

| Path | Result |
|---|---|
| `POST /instant` over HTTP, warm, p50 | calc 0.36 ms · units 0.49 · currency 0.20 · time 0.17 · dates 0.13 · app match 0.18 · file search 0.77 (fake host) |
| Cold Node child → ready | 433–450 ms (overlaps speech; warm TTL 600 s while voice is on) |
| `/invoke` → first streamed text via SSE (faux model) | ~34 ms + the real model's time-to-first-token |
| Swift↔Node wire | 3,244 real `/instant` responses decoded by the Swift types: 0 failures; all 138 actions pass `LauncherPolicy` |
| Before this branch | every request ran `openai-codex/gpt-6-astra@xhigh` (inherited pi default; ~181 s TTFT per Artificial Analysis). Auto's quick lane is `gpt-6-luna@off` (~0.67 s prior) |

Auto ladder for the current `openai-codex` login (balanced): quick `gpt-6-luna@off`, fast
`gpt-6-sol@off`, standard `gpt-6.1-sol@low`, deep `gpt-6.1-sol@medium`, max
`gpt-6-astra@high` only on "think hard / ultrathink / gründlich". Priors are re-ranked from
locally measured TTFT and tokens/s (`routing-stats.json`). Auto is the macOS default when no
model is stored; on Windows it is listed but opt-in.

## Evaluations (the questions asked)

| Item | Verdict | What pi-os took |
|---|---|---|
| **pi 1.0** | Adopted (`pi-coding-agent`/`pi-ai` 1.0.0). | Virtual models (Auto), classifier API, codemode, `setActiveTools`. Fixed on the way: pi ≥ 0.87 image auto-resize would have skewed click coordinates (`images.autoResize:false` per session); a successful automatic retry was reported as failure; chord's unsigned esbuild binaries are pruned from the bundle. |
| **timpratim/macbrow** | Not a library: a cloud prototype (Jev, Gradium, LiveKit, AppleScript). Its policy contradicts AGENTS.md. | Ideas only: direct site/search URL tables, spoken URLs ("github dot com"), act-then-observe (`browser_act` returns a compact snapshot after a settle wait). Not taken: trusted CDP clicks, `<select>`, multi-Chromium, AppleScript tools. |
| **moritzkremb/jev-voice-browser** | Strong control architecture on cloud pieces (Web Speech → Google, TypeSafe Jev). | Deterministic fast paths, previews on partial speech, latest-wins aborts, warm-up at key-down, spoken "never mind". pi-os never *acts* on partial speech (push-to-talk release is the endpoint). Not yet: number-pick disambiguation, spoken corrections/undo. |
| **vercel-labs/json-render** | Core adopted headless in Node; no React/WebView. | `pi-os-ui/1` catalog + per-element validation (`@json-render/core` + zod), `show_result` tool (`terminate:true`, streamed partial cards), native AppKit `CardView`. Model cards may only bind copy/open/reveal/ask; file actions only via host-minted tokens. |
| **NandhaKishorM/laya** | Integrated, **advisory only, off by default.** Zero-shot it scored 45–55 % intent accuracy on 49 EN/DE pi-os commands, confidently wrong; CPU batch of 4 questions ≈ 114–176 ms p50; load ≈ 18 s; peak RSS ≈ 5.2 GiB. MPS is not used (exclusive GPU lock). | CPU stdio sidecar, pi classifier provider `laya`, shadow log (labels only, opt-in), fine-tune toolkit with promotion gates (`sidecars/laya/finetune/`, not run). Uncalibrated Laya may only request the screenshot; it never lowers a tier, answers or acts. |
| **"clev by Cloudflare" = Clef** | Not better for the local hot path. Clef / Clef-flash (27B / 9.4B, Apache-2.0, released 2026-10-01) are cloud decision models on Workers AI (Clef-flash ≈ 39 ms median server-side + network), CUDA weights only, not in pi-ai 1.0.0 (in pi `main`). | Pluggable today through classifier kind `pi` (e.g. Cloudflare-hosted Jev in pi's catalog) once credentials exist; remote classifiers see final utterances only, never partials. |
| **pi codemode vs `@cloudflare/codemode`** | pi's (QuickJS-WASI worker) adopted; Cloudflare's needs workerd (`cloudflare:workers`). | Codemode on, with `desktop_act`, `browser_act` and `desktop_capture_window` model-only (scripts can neither capture nor act, closing a coordinate-authority gap); scripts call read-only and instant tools (`instant_calc`, `find_files`, …). |
| **pi-durable** | Useful later, not now: experimental, ≥ 100 ms before the first token, no codemode/MCP/extension parity. | Nothing yet. Candidate for a background-task lane ("tell me later"). File-backed sessions for persistent threads are deferred until a retention policy exists. |
| **pi-voice** | Not used: a TUI extension, Metal backend by default (GPU-lock conflict), no partial transcripts. | Apple SpeechAnalyzer/SpeechTranscriber in the Swift host instead. |

## Safety (unchanged rules, new surfaces)

AGENTS.md policy holds across the new paths: deletion, Move to Trash and Empty Trash are
refused (ordinary text edits are not); executables, scripts, installers and archives are
revealed, never opened; URLs are http(s) only; agent-initiated opens are refused in
read-only mode and guarded against query-string exfiltration; credential-field and
identity/focus/ownership checks are untouched; permissions are never requested from the
hotkey; logs carry kinds and timings only.

## Verification status

Offline, all green at the final merge: guarded `npm test` 390/390, `swift build` with 0
warnings, `swift test` 268/268, `npm run test:macos` conformance. Work was done by research,
build, integration and an eight-lens adversarial review (31 agents, every medium+ finding
skeptic-verified before fixing). Offscreen snapshots of every new state were inspected in all
appearance presets.

**Not yet verified live** (needs a build signed with `PI_OS_SIGN_IDENTITY` and, for anything
on the Neural Engine/GPU, a window coordinated with the DRACO benchmark owner): Microphone and
Speech Recognition TCC on the signed app, Carbon key-up timing on hardware, German speech
asset download, Spotlight results inside protected folders, real Codex time-to-first-token
per Auto tier, Bluetooth headset route changes, VoiceOver end to end. The macOS CI job cannot
build this host on the macOS 26.5 SDK (the Whisper UI already needed the macOS 27 SDK).

## Next steps

Fine-tune and calibrate Laya before letting it route; number-pick and corrections for voice;
gated browser navigation (back/reload/same-tab) and `<select>`; a pi-durable background lane;
persistent threads with a retention policy; dark mode / lock screen (need Apple Events or
private APIs); Windows voice and cards.
