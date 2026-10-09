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
per Auto tier, Bluetooth headset route changes, VoiceOver end to end. The macOS CI job builds
this host on the `macos-26` image with Xcode 26.6 (macOS 26.5 SDK); macOS 27 SDK code sits behind `#if compiler(>=6.4)`.

## Pass 2 (2026-10-05): general by default, the context shelf, pointing, dialog-free Brave

Branch `feat/context-shelf`. Tom's requests: open *generally* and pull the window in only when meant;
reach Brave in the background without “Allow remote debugging?”; faster everything; drag the agent's
attention to a window or element (the reference video); pull selected text or images in with a
copy-like action. How to use it: [README](README.md#on-macos-general-by-default-the-context-shelf-and-pointing).

```
key-down ─► identity pin only (CG window, focused element; fingerprint at insert) ─► bar visible
  │  after the bar: Brave AX tab pin · Node warm-up + prepare · the hotkey's live selection (AX only)
  ├─ typing / partials ─► POST /instant ─► scope {window, reasons} (rules v2) ─┐
  │                       on-device scorer (NLContextualEmbedding + LR, ~8 ms) ─┴─► chip off / suggested / on
  │                       first transition to window ─► lazy SCK capture (+ Brave AX digest in Node)
  ├─ Tab / click / ⇧+hotkey / menu / tether ─► explicit, sticky for the take
  ├─ ⌃⌥⌘C · drops · area grab · clipboard “+” · ⌥-point ─► context shelf (chips, ⊗)
  └─ Return ─► POST /invoke {context: what the chip shows, attachments: the shelf}
        general: no capture, no window JSON, app name + use_active_window (pull)
        window:  screenshot + compact window JSON (+ Brave page digest), Luna-first Auto tiers
```

| Decision | Taken |
|---|---|
| Active window default (D-T1) | **Suggest**; *Only when I ask* / *Always include* in Settings → Context |
| Who decides at Return | The host: the chip's state is the wire `context`; Node resolves scope only for clients without a chip (Windows sends none: legacy) |
| Local scorer (D-T5) | Ships; averaged with the rules, never alone; no lock (an OS framework call); weights bundled by `build-app.sh` |
| Brave (D-T2/D-T4) | Accessibility by default, background element actions on, DevTools opt-in; Tom can switch off brave://inspect remote debugging |
| Shelf selection | AX first; else the app's Copy with a byte-identical clipboard restore (never with password-manager/Handoff content) |
| Pointing (v1) | One actionable window per question; elements are read-only context, never secure fields |

**Verified offline** (S12 integration, 2026-10-05; re-run after the final-review fixes on
wp2/f1-axwire): `swift test` 477/477, `swift build` 0 warnings, guarded `npm test` 515/515,
`npm run test:macos` 1/1; offscreen snapshots of every new state in all presets, light/dark,
standard and Larger text. Node parses `context`/`attachments` on /invoke and /followup
(wp2/n4-server, 21a93e0), and the Brave Accessibility browser tools are wired into agent sessions
(83daffc). **Not yet live:** everything in [host-macos/STATUS.md](host-macos/STATUS.md) (signed
build, coordinated desktop, fixtures only).

## Pass 3 (2026-10-07): voice reliability

Branch `feat/voice-reliability`, merged into `main` as `4a60f72` and installed on 2026-10-07 with the stable
Apple Development identity (designated requirement unchanged, so the Screen Recording grant carries over); Tom's
voice journal was switched on at install with his recorded consent. The Parakeet model is **not** pre-installed:
it is one click in Settings → Voice → Recognition. The design note it implements (DESIGN4, which code comments
cite by section) is kept outside the repository. How to use it:
[README](README.md#on-macos-voice-instant-commands-auto-and-cards),
[host-macos/README](host-macos/README.md#spoken-commands-corrections-and-the-dictionary); wire contract:
[shared/protocol/protocol.md](shared/protocol/protocol.md) (`POST /instant` voice additions, `/dictionary/*`).

### What Tom asked

Speech "almost never understands me" and is "way too slow". "open pages" works typed, but spoken it often reaches
the LLM, which asks what he wants. He asked for a dictionary and for the app to improve from his corrections. He
speaks English and German and mixes them. His decisions the same day:

- "english and german. use a classifier that very quickly decides how to route the input"; never force one locale.
- Voice data: "Yes, opt-in, local only", switched on for his own install.
- Phase A (Apple, both languages) and Phase B (Parakeet TDT v3 download) now; no Whisper accuracy mode for now; the
  installed app stays live-linked to the repo's `node-harness/dist`.

**Why it failed** (measured during the research on `dd0126d`, mostly on synthetic `say` speech):

- One monolingual Apple SpeechTranscriber (en-US for Tom). Intent accuracy was 0 % on German and on mixed speech
  and 30–44 % on German-accented English. Empty finals were dropped silently.
- Its contextual strings changed 0 of 712 transcripts.
- The grammar acted on 46.9 % of 3,216 spoken open-app phrasings (20 false acts on 665 negatives), with no
  sound-alike matching and no "did you mean".
- Tom's own `harness.log`: 15 of 18 voice takes went to the agent, 1.7–6.8 s each (p50 2.66 s), often ending in a
  question. Transcription itself took 26–41 ms after key-up: the slow part was the LLM fallthrough, not ASR.

### How a take flows now

```
key-down ─► mic + one SpeechAnalyzer: a DictationTranscriber per checked language (en-US + de-DE for Tom),
  │         ≤ 100 contextual strings; Parakeet TDT v3 joins as the primary engine once its model is loaded
  ├─ partials (every engine, no debounce) ─► POST /instant phase:"partial" ─► preview only, never acts
  └─ key-up ─► Parakeet final (≈ 40 ms) ─► POST /instant final, seq N {text, hypotheses, accept, locale}
                 act · answer · refuse ─► settled, no second final
                 list · fallthrough   ─► wait for every engine (Apple ≤ key-up + 150 ms) ─► final seq N+1, all hypotheses
     Node, per final: policy on every hypothesis ─► per first-tier hypothesis: learned phrase → learned app name
       → spoken grammar + sound-alike matcher → learned fixes ─► arbitration ─► did-you-mean (≥ 0.66)
       ─► "Did I hear that right?" gate ─► else fallthrough (the near miss stays in the take memo for /invoke)
     host: "Opening Pages…" (launch not awaited, bar gone after 0.4 s) · "Did you mean …?" · "Open X? ↩"
           · "Did I hear that right?" · the agent (/invoke with the same takeId)
```

Without a loaded Parakeet model the only final is the complete one (Phase A: the Apple peers decide).

### What changed

| Piece | What it does now | Code |
|---|---|---|
| **Apple, both languages** (Phase A) | One SpeechAnalyzer per take with a DictationTranscriber for each checked language: short-form hint, volatile results, alternatives, word confidence. Up to 100 contextual strings are set at key-down (pinned app and window title, then the dictionary's ranked recognizer terms). A language without a dictation model falls back to SpeechTranscriber; one with no model at all is left out. The arbiter waits for the slower language until key-up + 150 ms. Key-up ends the audio stream before the engine stops. | `VoiceInput.swift`, `VoiceArbiter.swift` |
| **Parakeet TDT v3** (Phase B) | NVIDIA Parakeet TDT 0.6B v3 through FluidAudio 0.17.5 (pinned; its NeMo text-processing trait off), on the CPU and Neural Engine, never the GPU. One decode at key-up; partials re-decode every 0.5 s. **Settings → Voice → Recognition → Download…** opens a consent sheet, then fetches 21 files (483,105,645 bytes, shown as 483 MB; the design's 470 MB was an estimate) from Hugging Face `FluidInference/parakeet-tdt-0.6b-v3-coreml` at a pinned revision, checks each SHA-256 and installs them in one rename into `<support>/models/parakeet-tdt-v3/`. The model loads at launch with voice on, when a voice setting changes, when Settings → Voice opens, and after a take while a load was deferred, never on the hotkey path. Apple keeps working throughout, and Phase B still needs at least one Apple dictation model. | `ParakeetEngine.swift`, `SpeechModelStore.swift` |
| **Languages I speak** | Settings → Voice has one checkbox per language instead of one picker. The default is the system's preferred supported languages; a stored single language migrates once, with a note. Only checked languages run. There is no audio language ID: running every language and letting the arbiter pick is the "fast classifier" (a text language classifier alone routed worse in the research). `NLLanguageRecognizer` only sets the locale hint for `/instant` and `/invoke` `input.locale`. | `VoiceSettingsState.swift`, `SettingsWindow.swift`, `Application.swift` |
| **Spoken grammar and matcher** (Node) | `spokenCore()` strips EN/DE fillers, request wrappers, politeness, ASR commas, stutters and German particles. New forms include German verb-final ("Pages öffnen", "mach mal Pages auf", "hol mir Pages her") and "open up", "switch over to", "bring … up". Weak verbs ("show me", "zeig mir") open only exact names. App names also match by sound: 0.95 × (½ edit similarity + ½ Double Metaphone, maxed with Kölner Phonetik). A common EN/DE word (48,812 folded words from Tatoeba frequencies) never opens an app on sound alone. A sound-alike opens at ≥ 0.82 with a 0.08 lead; up to 3 candidates at ≥ 0.66 are offered. A spoken domain that is not a known site needs one Return. Typed input keeps its grammar. The Creator Studio Pages/Keynote/Numbers ids are known. | `normalize.ts`, `grammar/launch.ts`, `apps.ts`, `phonetic.ts`, `lexicon.ts` |
| **Arbitration** (Node) | One voice final carries up to 6 hypotheses (`primary` Parakeet, `peer` Apple languages in Phase A, `secondary` everything gated). A refusal by the primary or a peer refuses the take; deletion vocabulary anywhere turns the secondaries off. One actionable first-tier result, or several that agree, decide; a lone Phase A peer below confidence 0.4 needs one Return; peers that heard different apps get "Did you mean …?" with both. Only then a secondary may act (a literal app match consistent with the primary), else one Return. The check gate (≤ 8 words and a doubt signal: lowest word confidence < 0.2, a request the router cannot place, or first-tier readings sharing under half their words while the sent one's mean confidence is below 0.5) gives "Did I hear that right?" instead of the agent. | `voice.ts`, `dispatcher.ts` |
| **Bar decisions** | "Didn't catch that. Hold and say it again." instead of a silent drop; "Did you mean Raycast?" / "Did you mean…" with `Heard "recast"`; "Open Numbers? ↩"; "Did I hear that right?"; "Opening Pages…"; the "Not this", "Learned … · Undo" and "Remember …?" notes. Spoken answers on the next hold (see *Using it*). | `CommandController.swift`, `PromptPanel.swift`, `ShelfToastView.swift` |
| **Personal dictionary** (Node) | `<support>/dictionary.json`, written only by Node: app names, phrases (whole-utterance aliases), fixes and words, each scoped to the recognizer that misheard, or to every recognizer for typed input and entries added in Settings. Routes `POST /dictionary/learn`, `GET /dictionary`, `POST /dictionary/edit`, `GET /dictionary/recognizer-terms`. A take memo (last 20 takes, 2 minutes) is the only thing a gesture can teach against. Learned rules apply from the very next take; the host refetches recognizer terms whenever the revision changes. | `dictionary.ts`, `learned.ts`, `takeMemo.ts`, `server.ts` |
| **Voice journal** (host) | Opt-in: the last 50 takes (≤ 15 s of audio each, plus what every engine heard, the decision and the outcome) for Settings → Dictionary → Recent takes (play, Fix…, delete) and for the regression check before a rule is saved. | `VoiceJournal.swift`, `VoiceJournalPolicy.swift`, `RecentTakesView.swift` |
| **Agent fallback** (Node) | The spoken-input note now forbids open questions such as "What would you like to do?": do the most plausible harmless desktop action and say what was heard, or offer at most 3 concrete choices (a `show_result` card), installed apps only, never deletion. The near miss (heard name, top 3 candidates, other hypotheses) and up to 5 matching dictionary entries reach the first prompt as quoted data. A short spoken request no rule can place (≤ 8 words) goes to the quick lane with `list_apps`, `open_item` and `show_result`. | `agentRunner.ts`, `routing/{heuristics,decide}.ts` |
| **Latency after recognition** | Node is instant-first: `/health`, `/instant` and `/dictionary/*` answer before the agent stack loads (it loads after the first response, or 1 s after listen). With voice on, Node starts at app launch, polls `/health` every 20 ms for the first second and is never idle-stopped. An app open shows "Opening Pages…" at once instead of waiting for the launch (up to 3 s); a launch that fails later is a note. The bar goes 0.4 s after an act (was 1.2 s). Voice previews have no debounce (was 0.15 s). Cancelling a running task with voice on starts a fresh Node off the hotkey path. | `server.ts`, `HarnessClient.swift`, `LauncherService.swift`, `CommandController.swift` |

### Measured

All numbers below come from **synthetic speech** (macOS `say` voices rendered to files, never played) or from
transcripts of it. None is from Tom's voice, microphone, room or headset. "Tom-mix" is the mean of the corpus
categories F–I (English, German-accented English, German and mixed DE/EN), all spoken by the `say` voice Anna:
a proxy for Tom, about ±9 points per category (21–23 items each).

**CI corpus gates** (`node-harness/test/voiceCorpus.test.ts`, part of `npm test`; text replay of recognizer output
for 288 utterances through the real dispatcher with a 104-app fixture index; values from the run at `3764700`):

| Gate | Threshold | Measured |
|---|---|---|
| Spoken open-app phrasings acted on (3,216) | ≥ 93 % | **93.9 %** (98.4 % acted or offered, 0 wrong apps); today's path 46.9 % |
| False acts on 774 agent-bound phrasings | 0 | **0** (today's path: 20 of 665) |
| Phase A (Apple en-US + de-DE peers): Tom-mix acted at once | ≥ 64 % | **65.9 %** (73.8 % with one Return) |
| Phase A wrong acts at once | ≤ 2 | **2** (8 more held behind a Return) |
| Phase B (Parakeet + Apple, two-step final): Tom-mix at once | ≥ 80 % | **81.7 %** |
| Phase B with one Return | ≥ 86 % | **92.0 %** |
| Phase B wrong acts at once | ≤ 2 | **0** (8 held behind a Return, which Esc dismisses) |
| One correction, clean → `ptt2` (room + early key-up): wrong acts caused by learning, all 288 items, 5 engines | 0 | **0** |
| Learning gain at once: Parakeet / Apple DT en-US / Apple DT de-DE | ≥ +5 points | **+6.2 / +5.4 / +5.4** (not gated: SpeechTranscriber +3.8, Whisper +6.2) |
| One voice final with 6 hypotheses, dispatch p95 | < 5 ms | **1.8–1.9 ms** over two runs (p50 0.35–0.45 ms) |

For comparison on the same replay: today's engine (SpeechTranscriber en-US) acts at once on 23.8 % of Tom-mix, and
Parakeet alone on 77.2 %. The price: 34 (Phase A) and 30 (Phase B) of 78 agent-bound items are held for one step
("Did I hear that right?", a confirm or a list) before pi sees them. The fixtures have no word-level minimum
confidence, so the gate's confidence signal is not exercised here.

**Timing** (developer Mac):

| What | Result | How |
|---|---|---|
| Node cold spawn → `/health` | p50 **109 ms** (was 488 ms); agent stack ready ≈ 490 ms, no longer blocking | loopback benchmark, no host |
| Node started at launch with voice on → ready | 117 ms | the host's own start, 20 ms `/health` poll |
| Apple dual dictation: key-up → each language's final | 7–45 ms; first partial 0.53–0.86 s after key-down | 6 `say` phrases (EN, DE, mixed), 100 ms chunks in real time |
| Parakeet: key-up → final settled | p50 **38** / p90 40 / max 41 ms | `pi-os-voice-bench`, 36 `say` utterances (12 EN, 12 DE, 12 mixed), release build, real time, under the lock |
| First `/instant` final ready (`.primary` stage) | 39 / 42 / 44 ms | same |
| Every engine's final (`.complete` stage) | 54 / 111 / 156 ms (can pass the 150 ms cap slightly) | same |
| First partial, from key-down | Parakeet p50 562 ms (p90 1,079 ms); Apple p50 ≈ 0.86 s | same |
| Parakeet batch decode of one file | p50 33 ms, p90 35 ms | bench, `--engines parakeet` (one decode per file) |

**Keyword hits per recognizer** (the same 36-utterance bench; indicative only):

| Recognizer | English | German | Mixed |
|---|---|---|---|
| Parakeet v3 | 12/12 | 9/12 | 5/12 |
| Apple DT de-DE | 7/12 | 10/12 | 7/12 |
| Apple DT en-US | 10/12 | 4/12 | 0/12 |

Mixed German/English app names stay weak for every engine, which is why the instant lane looks at every hypothesis.

**Real engines on the installed build** (`pi-os-voice-bench` over all 288 corpus utterances rendered with
`host-macos/qa/voice/gen.py`, production engine classes, 100 ms real-time chunks for `clean` and batch for `ptt2`,
under the local-inference lock; scored with `scripts/voice-eval.mts`; synthetic voices only):

| Stack | Tom-mix at once | with one Return | wrong at once | wrong behind a Return | agent items held |
|---|---|---|---|---|---|
| Phase B (Parakeet + Apple), clean | **80 %** | 91 % | 0 | 7 | 30 of 78 |
| Phase B, `ptt2` (room + early release) | 72 % | 86 % | 2 | 13 | 35 of 78 |
| Phase A (Apple en-US + de-DE only), clean | 60 % | 69 % | 1 | 9 | 35 of 78 |
| Parakeet alone, clean | 77 % | 84 % | 0 | 2 | 30 of 78 |

Timings on that run: Parakeet key-up → final p50 39 ms (p90 47), first instant final p50 41 ms, every engine in
p50 51 ms (p90 97, max 171); Apple finals p50 37–42 ms; first partial Parakeet p50 562 ms, Apple ≈ 865 ms; model
load 13 s (first load, compiled cache in a scratch home). One correction on clean audio, tested on the `ptt2` take:
Parakeet +6.2 points, Apple en-US +5.4, Apple de-DE +4.6, with 1 learning-caused wrong act (Apple en-US) over all 288.

### Safety

The AGENTS.md rules hold on every new path, and tests cover each item below:

- **Closed targets.** A learned rule can do no more than open an app in the host's index, open an http(s) URL (no
  userinfo, ≤ 512 characters) or change the volume, and the same holds for what arbitration takes from another
  engine's reading. That is checked when a rule is learned, when the dictionary loads and when a rule is used; a
  learned fix that would produce anything else (for example display sleep) is not a hit. The host checks every
  action again with `LauncherPolicy`, and the existing instant grammar and its deletion refusal are unchanged.
- **No deletion.** Policy runs first and last on every hypothesis's original words. A refusal by the primary or a
  peer refuses the take. Deletion vocabulary (EN/DE, including "throw … away", "get rid of", "wirf … weg",
  "in den Müll", "discard", "verwerfen") and yes/no/cancel words can never become a heard phrase, an intended text or
  a phrase alias; Node and Swift share the same lists, and a test compares them. When any reading mentions deletion,
  the secondaries are off and "Did I hear that right?" offers no other readings as chips. With a hostile dictionary
  file loaded, every deletion request stays refused.
- **Only gestures teach.** A learn must name a take in the memo; a pick or confirm only a bundle that take offered
  or acted on; a correction only a target the lane itself resolves. No agent tool can reach `/dictionary/*`.
- **Exact rules.** Learned names and phrases match exactly and are never merged into the fuzzy matcher. Verb
  rewrites are never generalized: an edit that changes the verb becomes an exact phrase, and a Settings fix that
  touches an open or search verb is refused. The alias guard keeps "Oben", "Open", "Bitte", "Drei" and fillers
  out; shadowing an installed app's exact name asks first and stays scoped to that recognizer; two rejections
  disable a rule taught once.
- **Doubt costs a Return, not an act.** Partials never act; learned rules act on finals only. Secondary-engine
  readings, a lone low-confidence peer, a bare secondary name and an unknown spoken domain need one Return.
- **Agent fallback** never offers to delete, move or trash anything, and no agent tool can write the dictionary.

These checks are defense in depth, not a filesystem sandbox (AGENTS.md).

### Privacy

- Audio never goes to Node, never leaves the Mac and is never logged. Parakeet runs inside the app.
- **Voice journal: off by default.** Settings → Dictionary → Recent takes → *Keep my last voice takes to improve
  recognition* keeps the last 50 takes in `<support>/voice-takes/` (0700 folder, 0600 files, excluded from
  backups): ≤ 15 s of 16 kHz mono WAV each, plus a record of what each engine heard, the decision and the outcome.
  Switching it off keeps existing takes until you delete them (one, all, or with *Forget Everything…*). The only
  journal content that crosses the loopback is the text of accepted takes (≤ 50, ≤ 10 KB) sent with a learn request
  for the regression check. Tom's consent is applied at install time with `PI_OS_VOICE_JOURNAL_OPT_IN=1`, once, and
  only while the setting was never set.
- The dictionary (`<support>/dictionary.json`, 0600) is never logged and never sent to a remote classifier.
- The only new network request is the Parakeet download from Hugging Face, after the consent sheet (no cookies,
  credentials or cache).
- Logs stay content-free: the dictionary logs kinds, statuses and codes; `voice-perf.log` holds only timings and
  closed-vocabulary words; FluidAudio's logger is limited to errors with no console output.
- The microphone permission text now says audio is kept only with that opt-in, and only on this Mac.

### Using it

Turn on **Settings → Voice → Hold the shortcut to talk**, check the languages you speak, and optionally download
the multilingual model under **Recognition**. Hold the hotkey and speak English, German or both.

| You say (any mix of EN/DE) | You see |
|---|---|
| "open Pages", "öffne Pages", "Pages öffnen", "mach mal Pages auf", "can you open Pages for me" | *Opening Pages…*; the bar goes after 0.4 s |
| A name heard by sound, through a learned rule, or by the other engine | The bar hides and a 4 s note reads *Opened Keynote (heard "kein note") · Not this* |
| A name pi is unsure of | *Did you mean Raycast?* (or *Did you mean…* with up to 3 rows) and *Heard "recast"* |
| A doubtful reading or an unknown site | *Open Numbers? ↩* |
| A short, doubtful take | *Did I hear that right?*: the text is selected (type to fix it) and up to two other readings are chips. ↩ runs it, ⌥↩ asks pi, holding the hotkey says it again |
| Nothing recognized | *Didn't catch that. Hold and say it again.* |
| A real question | pi, as before. If the take is unclear, pi does the plausible harmless thing or offers at most 3 choices |

- **Answer a shown decision** with keys (Return, a click, 1–3, ↑/↓; ⌥Return asks pi instead) or by holding the
  hotkey again and saying *yes / ja / genau*, *no / nein*, *the first / die erste … die dritte*,
  *one … three / eins … drei*, *the last / die letzte*, or the app's name.
- **Not this:** the note's button, or a spoken or typed *no / nein* within 5 s. It counts against a learned rule,
  marks the take undone, then offers the act's other matches or asks pi `<words> (Not: Keynote)`. Escape does not
  count: the launched app has the keyboard, and pi-os installs no global key monitor.
- **No, I meant X** / *nein, ich meinte X* / *nein, X* (spoken or typed) within 2 minutes of an act: pi acts on X
  (at once, behind one Return or as a choice), marks the earlier take undone and asks once:
  *Remember "motion" → Notion? · Remember · Not now*.
- **What learns:** a pick from "Did you mean …?" or an app list, and Return on *Open X? ↩*, learn at once and
  show *Learned: "recast" → Raycast · Undo*. An edited "Did I hear that right?" that then acts, and "No, I meant",
  ask once. *Learn from my corrections* switches between *Picks learn immediately* (default), *Ask* and *Off*.
- *never mind / cancel / stop / vergiss es* as the whole utterance ends the take.
- **Settings → Dictionary** lists App names, Phrases, Fixes, Words and Recent takes: edit, switch off, pin, delete
  (with Undo), *Add Word…*, *Export…* / *Import…* and *Forget Everything…*. *Apply to the recognizer* feeds words
  and learned names to Apple's dictation as contextual strings (Parakeet gets no biasing; a word's sound-alikes are
  stored but not used yet). *Explain to pi* lets matching entries reach the agent's note. **Recent takes** plays a
  take, fixes it (*Open <app>* or *Just fix the words*) or deletes it.

### Developer settings and tests

| Variable | Effect |
|---|---|
| `PI_OS_PARAKEET_MODELS=<dir>` | Runs the two opt-in tests in `ParakeetEngineTests` against a Parakeet v3 Core ML folder (read-only): EN/DE `say` files through the real model, and the real store end to end from a `file://` mirror without the network. Skipped (the 2 skips in `swift test`) without it. |
| `PI_LOCAL_INFERENCE_LOCK=<file>` | Overrides the coordination file (default `<account home>/dev/Projects/_LOCAL_AI/.local-inference.lock`, resolved from the real home even under `CFFIXED_USER_HOME`). Opened read-only and never created; a missing file means nothing to coordinate with. The model store, the bench and the speech tests take a **non-blocking** flock on it: the store defers, the bench exits 75, the tests skip. |
| `PI_OS_SKIP_SPEECH_REPLAY=1` | Skips the two `say`-file replay tests in `VoiceInputTests` (Apple dual dictation, about 16 s; Phase B with a scripted primary, about 3 s). Without it they run when the en-US and de-DE dictation models and the Samantha and Anna voices are installed and the lock is free. |
| `CFFIXED_USER_HOME=<scratch>` | For the bench and the opt-in tests: keeps Core ML's compiled-model caches out of `~/Library`. It also moves the bench's default model folder, so pass `--models` explicitly. |
| `PI_OS_VOICE_JOURNAL_OPT_IN=1` | `refresh-install.sh` only: turns the journal on once for a user who consented (Tom). Never in CI. |

The local audio bench (`pi-os-voice-bench`) and the scorer (`node-harness/scripts/voice-eval.mts`) are described in
[host-macos/qa/voice/README.md](host-macos/qa/voice/README.md); the text fixtures in
[node-harness/test/fixtures/voice/README.md](node-harness/test/fixtures/voice/README.md).

**Voice timing log.** `<support>/logs/voice-perf.log`, one line per voice take, rotated at 256 KB into
`voice-perf.log.1`. Every value is a number or a closed-vocabulary word, so no transcript, heard name or app can
reach it:

```
at=2026-10-03T04:00:00.000Z decision=act hold=1200 first_partial=640 finish=47 final=apple-dt/de-DE:57,apple-dt/en-US:41 cut=1 hypotheses=4 finals=1 decide=2 hidden=401 source=grammar recognizer=apple-dt/de-DE via=sound reason=-
```

`hold` is key-down → key-up; `first_partial` key-down → first partial; `finish` key-up → the final that decided;
`final` key-up → each recognizer's final; `cut` modules left out at the 150 ms deadline; `finals` the voice finals
sent (1 when Parakeet's final settled the take, 2 otherwise); `decide` final → decision shown; `hidden` decision →
bar hidden. It is the tool for checking DESIGN4's rule to drop to 48 contextual strings if key-up → final p90
exceeds 150 ms on real takes (not implemented; it needs that data).

### Verification status

Offline, on the final tree (`3764700`): `npm run check` and `npm run build` clean; guarded `npm test` 652/652;
`swift build` and `swift build --build-tests` with 0 warnings; `PI_OFFLINE=1 PI_OS_AGENT=0 swift test` 712 tests,
0 failures, 2 skipped (the Parakeet opt-in tests); `npm run test:macos` 1/1. Both speech replays ran under their own
non-blocking lock. Every package had a separate review, and every integration-review fix has a regression test
that fails when the fix is reverted. Offscreen snapshots of every new bar state and Settings page were inspected in
all appearance presets, light and dark.

**Not verified live** (needs a build signed with `PI_OS_SIGN_IDENTITY` and, for anything on the Neural Engine, a
window coordinated with the `_LOCAL_AI` benchmark owner):

- Real microphone takes in English, German and mixed, and accuracy on Tom's voice: every number above is synthetic.
- The Parakeet download, first Neural Engine compile and load in the running app (at launch, on opening Settings,
  after a deferred take), and the real split between one and two voice finals per take.
- Whether the agent's spoken-input rule actually stops real models from asking open questions (tests use the faux
  provider only).
- The Node restart after a cancelled task in the running app; Bluetooth headsets; VoiceOver for the decision header, chips and
  notes; the 1–3 keys on non-US layouts; NSAlert/NSSavePanel/NSOpenPanel in Settings → Dictionary; real playback of
  kept takes.
- Microphone and Speech Recognition grants on the signed app with the new permission text.

**Install state.** Tom's installed app is **stale** relative to this branch. Updating it needs a signed
`host-macos/scripts/refresh-install.sh` with `PI_OS_SIGN_IDENTITY` (never ad hoc), plus
`PI_OS_VOICE_JOURNAL_OPT_IN=1` the first time. The installer rebuilds `node-harness/dist` only after every gate
passes. Because the installed app runs the repo's Node dist (Tom's decision), any `npm run build` in the main
checkout changes his live harness at once; the new Node side is backward compatible with the installed host.

## Pass 4 (2026-10-08): what you see first, and the answer steps aside

Tom: "when I open pi os on the desktop and say "öffne Radfotos" the application should check … the user visible
context first, e.g. … the desktop folder and only if it can't find a match there, ask me again. Also, when …
pi-os work ends with opening a folder or a program the result window can be auto minimized."

- **Visible items first.** At key-down the host reads what the take's target shows: the desktop icons when the
  target is the desktop, or the target Finder window's items, through Accessibility (3–28 ms on Tom's desktop,
  measured read-only); if icons are hidden, a Spotlight query of that folder's direct children (≈ 650 ms, so
  only a later request benefits). No AppleScript, no FileManager listing of ~/Desktop (no Desktop-folder
  prompt). Node asks `POST /tools/launcher.visibleItems` once per take (cached 3 s) and decides open forms in
  this order, after policy and learned rules: an exact name (case, accents, spaces and hyphens ignored, so
  "Rad Fotos" = "Radfotos"; "den Ordner …", "the … folder", "auf dem Desktop" understood) opens at once; a
  clear sound-alike needs one Return; then apps as before; then, for a full open verb that found nothing, a
  Spotlight "Did you mean …?" (≤ 3 rows, never an act) before pi is asked. An app said by its exact name beats
  a file of the same name ("Spotify.dmg"); only a same-named folder asks. File rows never teach the dictionary.
  "lösche Radfotos" stays refused.
- **The answer steps aside.** When an agent run's last effect was opening an app, folder, file or link, and the
  answer is not a question and waits for nothing, it shows for 0.8 s, then hides with a note "Opened … · Show"
  (Show, or the menu's Show Last Answer, brings it back; the thread stays). Settings → General: "Hide the answer
  after pi opens something" (on). Instant acts already hide after 0.4 s.
- **Verified:** Node 676/676, Swift 752 (0 failures, 0 warnings), conformance 1/1; the production provider found
  the real desktop's Radfotos folder via Accessibility (read-only probe). Not verified live: a regular Finder
  window's list/icon/column views (only fake trees), the step-aside in a real agent run.

## Pass 5 (2026-10-08): continuity

Branch `feat/continuity`. Stage A (links open in the browser in front, and the wire contract) is merged into `main` as
`e9ab5ca` and installed. Everything else below (the anchor, the launch race, typing into the focused field, Undo) is
built and tested offline on `feat/continuity` and is **not installed**. The design note it implements (DESIGN5, cited by
section in code comments) is kept outside the repository; Tom's answers of 2026-10-08 override its recommendations.
Wire contract: [protocol.md](shared/protocol/protocol.md) ("Continuity" under `POST /instant`, `typeIntoPinned.submit`
under Host actions, `context.target` under Context scope). Live QA plan:
[host-macos/qa/continuity/README.md](host-macos/qa/continuity/README.md).

### What Tom asked

"When I open a program, like i say "open Safari" and then there is no other action, pi-os needs to take safari as the
active context, and act in there. So that when my next command is "open google" the google page should open in that
exact safari window that just opened. Same for any other program. - if there is an active input field in the for the
user visible context, the voice input should directly fill in the input field. Example: I hold the shortcut and say
"Open wikipedia" and wikipedia.org opens. then there is a search field and the cursor is directly in the search field.
same for google. Then our application should know that and fill the next input directly in that input field. …
whilst preserving things like when there is a wbsite open and i ask about it, we need to kick off an agent that helps
answer the question."

### His decisions (2026-10-08, binding)

| # | Question | Tom's answer | What the code does |
|---|---|---|---|
| 1 | What gets typed into a focused field? | "Everything except commands", questions included | Commands, pi tasks, page questions, "frag pi …" and every policy case are never typed. Everything else is typed when an eligible field has the caret, empty or not, single-line or multiline |
| 2 | When is Return pressed? | "Auto in search boxes" | One gated Return after a fill into a search box or the browser's address bar. Never anywhere else |
| 3 | Where do links open? | "The browser in front" | The browser in front, or the one pi-os is launching; otherwise the default browser (Brave on Tom's Mac). Chromium closes a lone New Tab Page by itself (per its source, not checked live); Safari's empty start page is reused only behind a flag until live QA |
| 4 | A bare "nein" right after a fill | "Undo the typing" | Within 5 s of the note, "nein"/"no" (or the note's Undo) removes exactly what pi-os typed. "tippe nein" types the word |
| 5 | Password and code fields | Recommendation kept (not asked) | Typed only on an explicit request ("tippe …", or ↩ on the masked card) with the Settings opt-in. Never journaled, never sent to a remote classifier |

Where the code cannot do what an answer says, it says so instead (open questions at the end): after the automatic
Return in a search box, deleting the typed characters cannot undo the search that ran, so there is no Undo there.

### How a take flows now

```
key-down ─► pin the window in front (unchanged) ─► continuity: anchored · racing a pi-os launch · none
  │  field facts: today's focused-element summary + 4 quick reads (inside the existing 25 ms cap);
  │  after the bar, off the main thread: the field's kind (≤ 24 ancestors; labels matched, then dropped)
  │  caption under the transcript: "Speak to type into Safari · Search" (only where pi-os may type on its own)
  └─ key-up / Return ─► a racing take waits ≤ 150 ms for the launching app (re-pin) ─► the app's own focused
                        element is read again: the bound field
       POST /instant final { …, accept + "fill", target { app, anchor?, field? } }
       Node: policy ─► "frag pi …" ─► "nein, X" after pi-os's fill ─► "tippe …" ─► "such nach X" (browser)
             ─► instant commands as today ─► page and window questions ─► pi tasks ─► everything else: fill
       host: act fill ─► the bar steps aside ─► gated typing bound to that field ─► Return only in a search
             box or the address bar ─► note "Typed into Safari · Search" with Undo · Ask pi (5 s)
```

### The decision order

Step 0 runs on the host before `/instant`; the rest in Node (`instant/fill.ts`, `dispatcher.ts`). Node decides a fill
only for a final that declares `accept: "fill"` and carries a `target` with an eligible field; without either, every
decision is byte-identical to before.

| Step | Rule |
|---|---|
| 0 Host | An answer to a shown decision; whole-utterance cancel words. Within 5 s of a fill's note: a bare "nein/no/undo/rückgängig" undoes it, a bare "frag pi/ask pi" undoes it and sends the typed words to pi |
| 1 Policy | Deletion requests are refused as before. Deletion words never reach a field on their own. Deictic, compound and bare-edit takes keep today's path |
| 2 Escapes | "frag pi …/ask pi …/hey pi …/Pi, …" goes to pi; nothing is typed. "tippe …/tipp …/type …/type in …/dictate …/diktiere …/gib … ein" types the remainder (explicit). Not "schreib/write": that is a pi task |
| 3 Replace | "nein, X" / "No, I meant X" within 30 s of pi-os's own fill, while the field still holds exactly that fill: the host undoes it, then types X. Otherwise nothing is typed, and the correction is not aimed at an older act either |
| 4 Search forms | In a browser: "such nach X", "suche X", "search for X" type X into a focused search box or the address bar with one Return. Without such a field, the anchored page's own search (Wikipedia, YouTube, …) or the web search opens in that browser. "google X" on the Google page pi-os just opened goes into its box |
| 5 Commands | Instant commands as today: acts, answers (calculations, units, times), lists, refusals. An installed app's exact name said alone stays a command. A name said alone that only resembles an app ("Albert Einstein" → "Alfred?") is typed instead of "Did you mean …?" |
| 6 Page questions | Deictic and window wording ("this page", "diese Seite", "hier"), the window band (scope ≥ 0.7, or ≥ 0.5 with a window reason), "what does it say", "was steht da", "worum geht es", and German questions that point with "das"/"dem" ("ist das wahr", "kann ich dem trauen"; "Wie groß ist das Universum" is still typed) go to pi |
| 7 pi tasks | A task head in EN/DE (write/schreib, summarize/fasse zusammen, translate/übersetze, explain/erkläre, create/erstelle, remind/erinnere, plan, draft/entwirf, reply/antworte, open/öffne, …), a request addressed to pi ("can you …", "kannst du …"), a German verb-final command ("eine Mail an Anna schreiben"), device switches ("WLAN aus", "Timer 5 Minuten"), and the router's command intents are never typed: they keep today's path (pi, or "Did I hear that right?" when the recognizers doubt them) |
| 8 Control words | Yes/no/ok/cancel/enter/los/Escape and similar whole utterances are never typed |
| 9 Fill | Everything else is typed, **voice only** (a typed bar entry addresses pi). Recognizer doubt (the check gate's signals) turns it into the check card "↩ Type into Safari · ⌥↩ Ask pi"; a terminal always gets that card; a password or code field gets the masked card |

Typed finals get steps 1–4 (so "tippe …", "nein, X" and the search forms work typed too), never step 9.

### Field kinds and the Return rule

The host classifies the focused control (`PiOSCore/FieldKind.swift`, first match wins) from roles, subroles,
identifiers and labels. Labels are matched against closed EN/DE lists and dropped; a value is never read.

| Kind | How it is recognized | Typed | Return |
|---|---|---|---|
| `credential` | The native credential rule, `AXSecureTextField`, an unreadable label (fail closed), WebKit's credentials autofill type | Only explicitly, with the opt-in | Never |
| `rename` | Any Finder-owned editable field except its toolbar search (rename editors) | Never | Never |
| `confirm` | "Type DELETE to confirm" / "zur Bestätigung … eingeben" labels, or a sheet or dialog titled with deletion words that holds a destructive button | Never ("This field confirms a deletion, so pi-os won't type into it.") | Never |
| `sensitive` | Whole-word labels: verification/one-time/security code, OTP, 2FA, PIN, TAN, card number, CVV/CVC, IBAN, expiry (EN/DE); WebKit's credit-card autofill type | Only explicitly, with the opt-in; a spoken "tippe …" asks one Return first | Never |
| `terminal` | Terminal apps and terminal markers | Only explicitly, or ↩ on the card | Never |
| `address` | A browser's own address bar (a field in its toolbar with no web page above it, or Safari's `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD`) | Yes | **Once** |
| `search` | Subrole `AXSearchField`, or a text field or combo box whose identifier has a search word or whose label reads as a search box's ("Search Wikipedia", "Google-Suche"; `#channel` and `@contact` names ignored). A text area only by its subrole, so chat composers never count | Yes | **Once** |
| `text` | Any other single-line field | Yes | Never |
| `multiline` | Text areas and content-editable text (documents, chats, notes) | Yes | Never |

A field is **ready** when it is visible (at least half inside the window) and either native or in the tab's own loaded
page, never inside a frame. It is not ready while a text field, text area or terminal holds a selection (typing would
replace it), or when the focus moved during the hold from one eligible field to another. A field that is not ready gets
today's path. The Return is decided three times: Node sets `submit` only for `search` and `address`, its server drops any
other `submit`, and the host presses it only when its own bound field is a search box or address bar and the field
visibly holds exactly what was typed (otherwise the note says "Return not pressed").

### How it types

- The bar steps aside, the window is focused, and the bound field must have focus again within 120 ms. Every event
  checks that the focused element is still the bound one, on top of today's native gates (identity and fingerprint,
  exact front window, credential and deletion checks, the input budget, uncertain-input poisoning, no held modifiers).
- One line: line breaks, tabs and control characters become spaces; spoken punctuation ("Komma", "Fragezeichen",
  "question mark") is converted; ASR's trailing period goes in search boxes, the address bar and short single-line
  fragments. At most 500 characters.
- Text typed after other text gets one separating space, unless the character before the caret is a space, a line
  break, an opening bracket or a German low quote, or the text starts with closing punctuation (that one character is
  read and classified in memory, never for a password or code field). The space counts toward Undo.
- No clipboard, no `AXValue`, never ⌘Z. The Unicode string now rides on the key-down event only, for all native typing
  (Electron's contentEditable doubled text with the key-up payload); `PI_OS_TYPE_KEYUP_PAYLOAD=1` restores it. Chunking
  (`PI_OS_TYPE_CHUNK`) is off by default until live QA passes per engine.
- Notes: "Typed into Safari · Search" (Undo · Ask pi), "Searched in Safari · Search" (Ask pi only), "The field lost
  focus, so pi-os typed nothing" (Copy), "pi-os couldn't type there", "Typing was interrupted — check the field".
  Uncertain input is never retried.

### Undo, "tippe" and "frag pi"

| You say or press | What happens |
|---|---|
| "nein", "no", "undo", "rückgängig" alone, or the note's **Undo**, within 5 s | The typed text is removed: the very same element must still hold exactly that fill (same length, caret where the fill left it), the typed range is selected and read back, then one gated Backspace deletes it. Anything unproven: "Couldn't undo safely — press ⌘Z" |
| The same after a search box's automatic Return | Nothing is deleted (the search ran): "Already searched — go back with ⌘[" |
| "frag pi" / "ask pi" alone, or the note's **Ask pi**, within 5 s | The fill is undone (after a search's Return nothing is deleted) and the same words go to pi. If the Undo cannot be proven, the note says so and the words still go to pi |
| "nein, Marie Curie" within 30 s | The fill is replaced (and searched again in a search box). If the old fill cannot be removed safely: "Couldn't replace the text safely — nothing new was typed" |
| "tippe nein", "type hello", "gib Albert Einstein ein" | Typed as said (explicit), also into terminals; never with Return outside search boxes and the address bar |
| "frag pi wie hoch ist der Eiffelturm" | pi answers; nothing is typed |

A fill offers no "Not this", teaches the dictionary nothing, and "No, I meant X" never aims at it. A password or code
field's fill offers neither Undo nor Ask pi and keeps no words in memory.

### Links open in the browser in front (stage A, installed)

`NSWorkspace.open([url], withApplicationAt:)` with the app activated, after `LauncherPolicy.validateURL` as before; the
same path for instant acts and the agent's `launcher.open`. The browser is chosen in this order:

1. A browser pi-os launched at most 5 s ago, while no other app came to the front (a cold "öffne Safari" → "öffne
   Google"). A pending launch of a non-browser sends links to the default browser. A take whose target was chosen
   explicitly (Tab, ⇧ chord, tether, pointing) skips this step.
2. The take's pinned app, if it is on the closed allowlist of 20 browsers (Safari, Safari Technology Preview, Chrome and
   its channels, Brave and its channels, Edge and its channels, Chromium, Vivaldi, Opera, Firefox and its channels,
   Arc). The list routes links only; it never blocks an app.
3. Otherwise the default browser, as before.

The bar says "Opened www.google.com in Safari". If that browser refuses, the default browser opens it with the note
"Safari didn't open the link, so your default browser did." Where the page lands is the browser's choice: a new tab in
Chromium's most recent window (a lone New Tab Page is closed), a new tab or window in Safari depending on its "Open pages
in tabs" setting, possibly Little Arc in Arc. `logs/launcher-actions.jsonl` records which route a link took
(`browser`: launching, pinned, default or fallback), never the page. Safari's own empty start page can be reused through
its address field behind `PI_OS_SAFARI_SAME_TAB=1` (default off; it never opens a second copy on its own).

### The anchor and the launch race

- **The anchor** (host memory only, never persisted or logged): a successful pi-os open (instant or agent; an app, a
  link, a file or a folder) records "pi-os just opened X". It settles when the front app, its first on-screen window and
  its focused window agree (25 ms polls, up to 1.5 s, or 4 s for a cold launch); the first Accessibility message to the
  new app is paid there, off the hotkey path. It ends when another app comes to the front, the app quits or its process
  changes, its window is off screen at key-down, after 120 s, on "Not this" or "No, I meant X" for the opening take, on
  sleep, screen lock or session resign, and when computer control goes off. The wire carries only the opening take's id
  and whether it is still settling. The chip's tooltip adds "· opened by your last command".
- **The race.** A hold that starts while pi-os is still launching another app (≤ 5 s) pins the app in front as always,
  but types nothing there: no field is bound, and the chip says "Safari (opening…)". When the launching app comes to the
  front with a window before the final, the take re-pins to it (fingerprint, Brave pin and visible items run again); at
  the final it waits at most 150 ms, then proceeds where it is. An explicit choice always wins.
- **The agent.** Page questions keep their window turn (Brave also gets the page digest). A general turn stays general;
  its first `/invoke` adds one content-free sentence ("pi-os opened this app with the user's previous command, and a
  search field has the keyboard focus there; this request was not typed into it."). No URL, title or label crosses the
  wire. Follow-ups send none yet.

### Safety and privacy

- AGENTS.md holds: no deletion (deletion words are never typed on their own, `confirm` and rename fields are never typed,
  a terminal line still passes the `rm` check, the Return keeps its destructive-button check), identity, focus and
  ownership checks on every event, ordinary text editing preserved.
- Credential input stays field-local: a password, username, code or payment field gets text only on an explicit request
  with *Settings → General → Allow input in username and password fields* (its tooltip now names code, PIN and payment
  fields). Secure Keyboard Entry is never consulted and never switched off.
- A take spoken while a password or code field is focused may be the secret (critic C5). If no command or page question
  takes it, it is never sent to pi on its own: the bar shows "Password field — pi didn't send this anywhere" (or "Code or
  payment field — …") with "•••" in place of the words, "↩ Type it" only where typing is allowed (otherwise the footer says
  why not), and "⌥↩ Ask pi anyway". This fails closed: every undecided outcome counts (a miss, doubt, a timeout, instant
  commands off, an unknown reason, no answer from Node), only deictic and compound requests, the window band and
  "frag pi …" go to pi. The words never show in the bar or a live preview, the take is never journaled, Node sends no
  classifier hints and its take memo keeps no words. This holds in read-only mode too: without computer control the host
  reports only password and code fields and never declares a fill.
- Values are never read: only lengths (`AXNumberOfCharacters`, `AXSelectedTextRange`), and none for password or code
  fields. Logs carry closed vocabulary only: the host's `[perf] fill kind=… outcome=… return=… verify=… ms=…`, Node's
  `kind=fill via=field fill=<label> field=<kind>` and `voice-perf.log` `via=field`.
- Fills need computer control. **Settings → Voice → Type into the focused field** (default on) is the kill switch: off,
  pi-os never declares a fill and never types on its own.

### Intentional behaviour changes

| ID | Change |
|---|---|
| C1 | Links open in the browser in front or the one pi-os is launching, not always in the default browser |
| C2 | "such nach X / search for X" in a browser is a web search, or a fill with one Return into the focused search box or address bar. Outside a browser a file search stays a command, and a search no command took fills a focused search field with one Return |
| C3 | The check card can type: "↩ Type into TextEdit · ⌥↩ Ask pi" types the (possibly edited) card text, never with Return |
| C4 | A bare "nein" right after a fill is Undo, not "Not this" |
| C5 | A name said alone that only resembles an app is typed into a focused field instead of "Did you mean …?" |
| C6 | Takes at password and code fields are never journaled |
| C8 | A hold that starts during a pi-os launch can re-pin mid-take; the chip and VoiceOver announce the change |
| C9 | At a password or code field, a miss becomes the local masked card instead of an agent turn |
| — | The Unicode payload rides on key-down only for all native typing, including the agent's (`PI_OS_TYPE_KEYUP_PAYLOAD=1` restores it); the per-event duplicate inspect is gone (C14) |
| — | Questions are typed into a focused field (Tom's answer 1, overriding the design's critic C1, which kept them for pi) |

C7 (⌘↩ in the composer types into the field) was not built.

### Developer settings

| Variable | Effect |
|---|---|
| `PI_OS_SAFARI_SAME_TAB=1` | Safari's exact-tab route for a start page pi-os just opened (off by default; live QA Q1 decides) |
| `PI_OS_TYPE_CHUNK=1` (or `2`…`20`) | Up to 20 (or N) UTF-16 units per Unicode event, surrogate-safe; off by default until Q5 passes per engine |
| `PI_OS_TYPE_KEYUP_PAYLOAD=1` | Puts the Unicode string back on the key-up event too, for a receiver that needs it |
| `PI_OS_TEST_SITES_PORT=<port>` | Harness only: "fixture search", "fixture page", … open the loopback QA pages; unset, the table is empty |
| `PI_OS_PERF=1` | The `[perf] fill …` lines and the `[launcher] … browser=…` line of each link on stdout |

### Measured (offline, no providers)

All numbers are from the CI tests at the integration head (guarded `npm test`, 731/731). None is from Tom's voice or a
live app.

| Gate | Result |
|---|---|
| Continuity corpus: 188 EN/DE/mixed takes × 11 targets (no field, search, address, text, multiline, terminal, sensitive, credential, confirm, rename) | 319 fills, 41 offers, 82 secret misses, 24 web searches, 12 refusals, 1,245 decided as today; every class asserted per target |
| Golden equivalence over 5,055 corpus texts | Without `fill` or without a `target`: every decision byte-identical. With a search field: 299 changed (296 fills, 0 offers, 0 web searches) |
| Never typed: 40 deletion, 115 deictic and 312 window-band takes | 2,260 dispatches, 0 fills, 0 offers |
| Dispatch with 6 hypotheses and a focused field (178 takes, 33 fills) | p50 0.67–0.73 ms, p95 2.15–2.73 ms (gate < 5 ms), max 7.2–8.2 ms over two runs |
| Voice corpus gates (pass 3) | Unchanged: 93.9 % open-app acts, 0 false acts on 774 agent-bound phrasings, Phase B 81.7 % at once |

Swift: `FieldKindTests`, `FieldFactsTests` (a read recorder proves no `AXValue` read), `ContinuityTests`,
`LauncherServiceTests`, `BrowserFamilyTests`, `SafariAddressRouteTests` and `FillFlowTests` (typing order, 0 Returns
outside search fields, Undo, replace, Ask pi, the masked card, read-only mode, the race) on fakes; the totals are in
[host-macos/STATUS.md](host-macos/STATUS.md).

The design's latency estimate for v1 typing, not measured: key-up → last character ≈ 120 ms + 27 ms per character
("Albert Einstein" ≈ 510 ms), about 150 ms with chunking.

### Not verified live

Nothing here has run against a real browser or app yet. The coordinated plan
([host-macos/qa/continuity/README.md](host-macos/qa/continuity/README.md), Q1–Q11, fixtures only, with Tom) checks:

- whether Safari reuses its empty start tab for a link, and whether its `AXConfirm` navigates (decides
  `PI_OS_SAFARI_SAME_TAB`); private windows, Arc's Little Arc, Safari's tab setting (Q1);
- the launch race and its re-pin on a cold launch (Q2);
- the field kinds WebKit and Chromium report for Wikipedia's and Google's boxes, and the Chromium web field being
  readable at the final (Q3);
- **bound-element identity** between the app's own and the system-wide focused element for web fields (Q3, pass or fail
  for all of the fill: if it does not hold, every fill ends as "The field lost focus" with Copy);
- the 120 ms focus settle after the bar steps aside, and the browser's focus-restore delay (Q7);
- selection set and read-back for Undo, and the length check, in WebKit and Chromium (Q4);
- chunking and the key-up payload per engine, including Electron (Q5, Q6);
- dummy credentials, the opt-in, a deletion-confirm field, a terminal-like surface, Secure Keyboard Entry on (Q8);
- page questions with a field focused (Q9); Spaces, full screen, a second display, Stage Manager (Q10);
- Tom's voice in EN, DE and mixed, then Google and Wikipedia by hand (Q11).

### Decided by Tom (2026-10-09)

1. **Undo after a search:** no history-back. After the automatic Return there is no Undo; "nein" says "Already
   searched — go back with ⌘[".
2. **Editing the typing card:** current behaviour stays. With "↩ Type into …" on the check card, an edited text is typed
   on ↩.
3. **App names said alone:** fine as is. A German noun that is also an app ("Wetter", "Karten", "Fotos") said alone with
   Google's box focused opens the app (an exact app name stays a command).
4. **The agent sentence** keeps naming the focused field kind ("… has the keyboard focus there; this request was not typed
   into it").

Not built (later): spoken submit words ("los", "enter"), ⌘↩ typing from the composer, the ≤ 300 ms wait for a page
still loading with a "Search Wikipedia for …? ↩" card, an `AXValue` fast path, `context.target` on follow-ups, the
Safari and Chromium page digest.

**Install state.** Installed 2026-10-08 as `main` `661cb8e`, signed with the stable Apple Development identity
(designated requirement unchanged). Live smoke of the installed harness's `/instant` decisions with a simulated focused
field (no typing): "Albert Einstein." → fill + Return (search); a question → fill + Return (search); "Worum geht es auf
dieser Seite?" → deictic (pi); "Schreib eine Mail an Anna." → pi; "Öffne Google." → url; a calculation → answer;
dictation into a multiline field → fill without Return; a password field → nothing typed; a terminal → one-Return card;
"Tippe Hallo Welt." → fill without Return (2–55 ms each). Typing itself (Q3–Q8) is not verified live yet.

## Pass 6 (2026-10-09): a full pi session

Tom: "I need the pi desktop assistant to be able to act like a fully normal pi session, with terminal access and
everything." His decisions: destructive commands go through his dcg hook ("it should prompt its own approval dialogue
when hit"); the working folder is what he is looking at; full tools always, the lean prompt only for quick asks;
sessions are saved like normal pi sessions, keeping everything.

- **Full mode** is the macOS resource mode `trustedGlobal` (Settings → General → "Full pi session", with an
  acknowledgement; fresh installs stay isolated; it needs computer control). No tool allowlist: pi's coding tools
  (read, bash, edit, write, …), the user's global extensions, skills and prompt templates, and pi-os's own tools.
- **Destructive commands:** pi-os adds no confirm of its own. A global extension that guards bash (Tom's
  `~/.pi/agent/extensions/dcg-guard.ts`, which runs `dcg --desktop-review`) intercepts every bash call exactly as
  in terminal pi; Settings shows "Destructive commands: reviewed by dcg" or "No command guard found". Nothing in
  pi-os runs a shell outside the bash tool (codemode reaches tools through the same hook). The computer-use
  deletion policy for desktop actions is unchanged; typing into a Terminal window through `desktop_act` is covered
  by that policy's known-command checks, not by dcg.
- **Working folder:** the front Finder window's folder (the desktop → `~/Desktop`), the front terminal window's
  folder (Terminal, iTerm2, Ghostty, WezTerm, Warp, from the window's represented URL), the front editor's project
  (git root, walked up only outside privacy-protected folders), else home; never a Trash folder. Read at key-down
  without touching protected folders, sent as `workingDirectory` on prepare and /invoke, validated strictly.
- **Project context:** pi's own trust resolution (`~/.pi/agent/trust.json`), so a project's `AGENTS.md` loads as in
  terminal pi.
- **Prompt:** the first turn decides: quick and fast lanes keep the lean pi-os prompt; standard, deep and max,
  coding requests, `/` commands and resumed sessions get pi's coding prompt with project context. A request that
  starts with `/` reaches pi unwrapped, so `/skill:…`, prompt templates and extension commands work.
- **Saved sessions:** full threads are regular pi session files in pi's bucket for their folder (`pi --resume` there
  continues them); follow-ups append; "continue my last pi session" / "mach mit der letzten pi-Session weiter"
  resumes the folder's most recent one. Files keep exactly what the model saw (Tom's decision).
- **Time limit:** full sessions get 60 minutes (`PI_OS_FULL_INVOKE_TIMEOUT_MS`), time in dcg's dialog included;
  isolated sessions keep 5 minutes.
- **Bar:** "Running a command…", "Reading files…", "Editing files…"; "Waiting for your approval…" only while a dcg
  review process is open under the harness.
- **Not verified live yet:** the dcg dialog from a pi-os session (planned with Tom: an empty `/tmp` probe folder),
  terminal folders reported by each terminal app, long-running tasks in the bar.

## Next steps

Run the continuity live QA (Q1–Q11) with Tom on a signed build, then decide `PI_OS_SAFARI_SAME_TAB`, chunking per
engine and the open questions of pass 5. Calibrate the voice thresholds (`SPOKEN` in `apps.ts`, `VOICE` in `voice.ts`,
including the check gate on Parakeet's confidence) on a week of Tom's journal, then decide the Whisper accuracy mode;
record which hypothesis decided a take in the journal; an `apps` result block so the agent's app choices open in one tap; fine-tune and
calibrate Laya before letting it route; gated browser navigation (back/reload/same-tab) and `<select>`; a
pi-durable background lane; persistent threads with a retention policy; dark mode / lock screen (need Apple Events
or private APIs); Windows voice and cards.
