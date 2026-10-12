# Immersive pi-os: a shared-attention layer, not another chatbot

Research + disposable prototypes, 2026-10-09. **No production changes, installation refresh, microphone capture or real computer actions.** Detailed independent notes are under `docs/research/immersive-hci/` (that directory is ignored by the existing git configuration); this synthesis and the visual prototype live together in `prototypes/interaction-lab/`.

## Recommendation

Build toward **the computer following the user's attention with minimal ceremony**:

- one object/selection can be pointed at, spoken about, transformed, copied or used as the next action's input;
- familiar actions are deterministic and immediate, not agent turns;
- reusable recipes have the same meaning from keyboard, selection, voice and an action menu;
- a small visible contract says *what is included, where the action goes and what happened*;
- ambient voice can be continuously available while choosing **silence and no action** most of the time.

“Immersive” here means remaining inside the current task—not full-screen spectacle, constant conversation, hidden surveillance or maximal autonomy. Neither supplied reference establishes that more features or an always-on mic improve flow empirically.

## What to borrow from the five references

| Reference | Useful pattern | What not to import |
|---|---|---|
| [Tinycast](https://github.com/abue-ammar/tinycast) | State-preserving drill-down; selected-text diff previews; intentional keyboard/pointer ownership; spatial “Rooms”; pure logic separated from effects | A wholesale launcher replacement or unreviewed extensions/scripts. Tinycast is AGPL-3.0-or-later; pi-os is MIT. Study the patterns and implement independently; code reuse needs a deliberate license decision. The “under 100 MB” README claim is not our measurement. |
| [ped.ro / Raycast](https://ped.ro/writing/youre-probably-only-using-3-percent-of-raycast) | **Composition**: selection/clipboard → argument → command; snippets with typed placeholders; selected item's action menu; one command across aliases/hotkeys/AI | Empty Trash/deletion commands, silent clipboard-history retention or “3%” as a measured usage statistic |
| [Thomas Paul Mann post](https://x.com/thomaspaulmann/status/2082089501397229758?s=20) | Search-first discovery, then shortcuts; small personal workflows; AI as a layer over existing tools | Inventing the inaccessible X page/video. Official syndication verifies the July 28 post as a link to *Getting Productive with Raycast*; its full article body was accessible only through a labeled unofficial mirror. |
| [macbrow](https://github.com/timpratim/macbrow) | Typed tool boundaries, browser-aware targets, cheap URL/search routing, act → observe feedback | Its cloud voice/model pipeline or unrestricted AppleScript/browser authority as the ambient-local substrate |
| [jev-voice-browser](https://github.com/moritzkremb/jev-voice-browser) | Separate typed questions: addressedness, completeness, intent, target and risk; latest-wins cancellation; verbatim span selection | Web Speech as a guarantee of local recognition, remote Jev decisions for room speech, or execution on partial transcripts |

These are source/design observations, **not** live comparative benchmarks. Independent notes: [Tinycast](../../docs/research/immersive-hci/tinycast.md), [Raycast + exact X verification](../../docs/research/immersive-hci/raycast-and-post.md), [browser/voice repos](../../docs/research/immersive-hci/browser-voice-repos.md).

## Avoid rebuilding what pi-os already has

Read [VOICE_MAGIC.md](../../VOICE_MAGIC.md), [root README](../../README.md) and [macOS status](../../host-macos/STATUS.md) together; code presence is not live validation of the installed build.

Already present: native host-owned input policy, context choice/shelf/pointing, local push-to-talk EN/DE recognition, recognizer arbitration, instant commands, previews on partials, dictionary/corrections, result cards, continuity and focus-bound typing/Undo logic. macbrow and jev were already evaluated in VOICE_MAGIC. **The opportunity is the connective tissue**, not adding these features again.

Gaps worth exploring:

1. **A reusable attention contract** across preview, follow-up and action; a pointed element currently supplies context, not click/edit authority.
2. **Result-to-action composition** and bounded user-authored recipes, without scripts or an extension marketplace.
3. **Always-on addressed-speech gating**. A push-to-talk hold currently supplies explicit intent; ambient audio does not.
4. **Calibrated local decisions with abstention**. Existing recognizer confidence/language arbitration is not an addressedness model; Laya's documented zero-shot results do not justify autonomous routing.
5. **A low-interruption receipt language**: previewing, applied, pending, not acted, target changed, cancellation acknowledged. Undo only where the effect is actually reversible and still owned by pi-os.

## Eight interaction ideas

### 1. Point → speak → preview → act

Select/point at a paragraph: “Make this shorter.” Show a draft next to the relevant object, with one clear Apply action. Preserve keyboard-only selection and a visible menu alternative. If the window, selection or content changed during the draft, require a new binding rather than applying to whatever is now focused.

**Experiment:** the visual lab's first study uses a canned rewrite and mock note. Existing pointing is the foundation; this study explores preview/target/receipt continuity, not a new capture feature. Measure how often the user looks away from the document and whether they can name the actual target before Apply.

### 2. One recipe, four entry points

“Find this ticket” should mean the same bounded capability from a selected issue ID, a command menu, an alias/hotkey or voice. Save structure, not private content, stale window identities or host file tokens. Teach through a reviewed “Save this workflow” action—not silent learning of arbitrary commands from background speech.

**Experiment:** study two validates `PI-218` and previews a fixed-host URL; another recipe combines selected text with a fixture date. No live URL, account or clipboard effect. Avoid generic string interpolation into shell commands/deeplinks.

### 3. A short conversational aperture

After “Pi, explain this term,” allow “in German” without another wake phrase for a short, visibly scoped interval. Bind it to the same conversation, speaker evidence and context; switching app/target, locking, muting or expiring the timer closes it. Try 3/5/8-second windows as experiments—not product defaults. Acoustic speaker similarity can be a hint, never identity/authorization proof.

### 4. Talk-to-computer and dictate are separate states

Ambient availability must **not** inherit push-to-talk's “everything except commands goes into the focused field” fallback. A text caret is not consent to transcribe a meeting into Mail. “Pi, dictate here” starts an explicit, bounded dictation session with a destination cue and stop gesture; “Pi, ask…” stays a question. Ordinary field editing remains permitted; credentials stay field-local, opt-in and absent from snapshots/logs.

### 5. Quiet receipts, strong interruption

Reversible local mock actions get a brief receipt rather than a narrated paragraph. Pending/ambiguous actions expose one precise question. Escape/mute revoke queued work before effects; eventual stale completions cannot revive it. Future local spoken output must be optional, interruptible and protected against the assistant hearing itself.

An extra confirmation for every harmless action harms flow. Conversely, a high model score must not authorize prohibited deletion or an unknown destination. Explicitly requested ordinary final clicks remain valid under existing pi-os policy; the ambient proposal's confirmation layer is not a new app-brand or account-action ban.

### 6. Opt-in memory of objects, not a recording of life

The shelf can become an explicitly curated working set: “use this with that,” then clear it. Later, user-saved recipes/preferences could persist without storing all room audio, every copied secret or every screen. Start with session memory and a visible clear action; durable history needs its own retention/export/erasure design.

### 7. An attention room, not an automatic desktop takeover

Choose two or three sources—issue, note, screenshot—and see them as a small spatial working set. One is the explicit actionable target; the others are read-only references. “Compare these” has clear operands, and returning to the source preserves the query, selected row and context exclusions. Tinycast's Rooms suggest a concrete project-level interface, but v0 should move only mock cards, never real windows or hidden desktops. A later window-layout feature needs its own native ownership/recovery design.

### 8. Let the app teach the command layer

An explicit “Find a command in this app” can search bounded AX menu titles and show the path/shortcut, rather than asking an agent to guess UI coordinates. Initially read-only discovery, with duplicate labels disambiguated. For a future richer result list, preserve stable item IDs and keyboard ownership when results reorder under a stationary pointer; navigation back must restore the whole frame, not just its query. Keep pi-os's Tab/context and hide/cancel semantics, rather than copying another launcher's shortcuts.

## Fully local always-on voice: two modes, not one magic switch

**Local recognition is necessary but insufficient.** Sending recognized background transcripts to a cloud decision model still exposes the room. For the proposed strict-local ambient mode, keep audio, raw/partial/final transcripts, addressedness/intent/target decisions and optional TTS local. No remote fallback when a model is missing or slow. Normal hotkey/agent mode can retain its separately visible provider choice.

A requested web search is a deliberate external *effect*, not remote speech processing; show the destination and send only the requested query. Asset downloads are separate, explicit setup actions. Neither exception permits uploading background speech, context or classifier telemetry.

### A. Local sentinel — preferred first hardware experiment

Always-running local VAD/wake detector + bounded in-memory pre-roll; run full ASR only after explicit activation, then the local decision gate. This is less intrusive and potentially lower power, but loses some address-free naturalness. It requires a real EN/DE-compatible wake-word evaluation; “Pi” is short and can occur in ordinary speech (“Raspberry Pi”). A configurable phrase such as “Hey Pi” is a candidate, not a validated detector.

### B. Local ambient — the more ambitious research mode

VAD-triggered local ASR for nearby speech, then a local model predicts whether it was addressed to the computer. Rejected segments are discarded; no passive journal, cloud classifier, continuous screenshot capture or default field insertion. The raw audio/transcript must exist briefly for recognition: say **not retained**, not “never processed.”

Continuous decoding has a different power, thermal, Bluetooth and privacy profile from short push-to-talk takes. Only opt-in, clearly indicated and easy to mute. Suspend/clear on lock, user switch, microphone loss, sleep and mode exit. Meeting suppression should use explicit preferences/signals, not hidden inference that the whole device is safe to monitor.

### Proposed pipeline (not an existing protocol)

```text
mic + optional playback reference
  → local echo suppression / self-TTS exclusion
  → local VAD + bounded RAM pre-roll / segment limits
  → on-device ASR (EN/DE/mixed), volatile → finalized transcript
  → addressed-to-computer decision (+ activation/follow-up evidence)
  → typed intent + span/target candidates + uncertainty
  → deterministic policy + target lease + risk/permission checks
  → ignore | preview | clarify | confirm | bounded action
  → native execution gate → re-observe → small receipt
```

Keep three questions distinct: **speech?** **addressed to us?** **authorized action?** Voice activity is not addressedness; addressedness is not authorization; ASR confidence is not either. A final transcript is not necessarily a complete intention (a silence gap can precede “actually, don't”). Partials can warm/preview, never act. Cancel is latest-wins across recognition, classification, preview and queued execution.

Critically, gate *before* existing normalization/routing: `instant/normalize.ts` strips “Hey Pi” as text cleanup; that is not acoustic wake detection or ambient authorization. A proposal envelope would carry mode/session/sequence, finalizedness, local decision outputs and short-lived context authority without extending model-card action privileges. Preserve existing host gates and fresh target observations.

### Candidate stack

- **Existing Apple SpeechAnalyzer/DictationTranscriber:** first reuse candidate for local streaming EN/DE. [Apple's WWDC session](https://developer.apple.com/videos/play/wwdc2025/277/) documents on-device, long-form/conversational use and explicitly describes volatile guesses improving before finalization. This does not measure always-on power or Tom's mixed-language accuracy.
- **Existing Parakeet via FluidAudio:** compare against the current engine in a coordinated hardware window. pi-os pins FluidAudio **0.17.5**, so current upstream features are not automatically available. [Upstream VAD docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/VAD/GettingStarted.md) describe Silero Core ML streaming segmentation and explicit `.cpuOnly` staging; inspect the pinned API/assets before proposing an upgrade. No download/inference was performed here.
- **Local addressedness/intent model:** start shadow-only with the project's local embedding + small classifier approach, or a compact multilingual encoder with calibrated decision heads; choose only after a labeled EN/DE dataset comparison. Include `none/uncertain`, out-of-domain and acoustic/context features. No evidence here establishes an off-the-shelf model as ready for autonomous ambient actions. Avoid a heavyweight always-running general LLM in the hot path.
- **Laya:** useful candidate experiment, not today's authority. VOICE_MAGIC records confidently wrong zero-shot classifications and roughly 5 GB memory; fine-tuning/calibration and a separately held-out dataset are required.
- **Wake detection:** [openWakeWord](https://github.com/dscripka/openWakeWord) is worth studying, but its README says current language support is English; code is Apache-2.0 while included weights are **CC BY-NC-SA 4.0**. Neither a custom bilingual “Pi” model nor unrestricted weight reuse follows from the code license.
- **Local output/echo:** investigate native voice-processing/echo APIs and a local TTS stack only after core gating. Echo cancellation, diarization or a speaker verifier cannot prove audio originated from the intended human; recordings can contain the same voice.

All local-provider/catalog/GPU probes and microphone validation remain deferred under the repository's inference-coordination rules. Do not silently claim CPU/ANE paths are exempt from the agreed hardware window for this evaluation.

## Test the dangerous ambiguity, not just recognizer accuracy

Suggested dataset: EN, DE and code-switching; intended commands, ordinary discussion, quotations, negation, delayed corrections, TV/podcasts/calls, self-TTS, silence/noise, two nearby people, low-confidence app names, stale selection, wrong field, missing assets and disconnection. Use only consented local samples, dummy credentials and harmless mock controls. Split by recording session and speaker; related augmentations cannot cross train/test.

Measure separately:

- false activations/hour, **false executed actions/hour**, missed intended commands and unnecessary clarifications;
- correct addressedness/intent/target/effect together, plus calibration and abstention coverage;
- end-of-speech → preview/action/receipt p50/p95, cold readiness, cancellation latency;
- CPU/RAM/energy/thermal load and headset route behavior;
- context/destination comprehension, focus switches and task time against existing push-to-talk.

Synthetic fixture scores test plumbing, **not calibrated probabilities or model accuracy**. Wake detections/hour are not safe-action rates. Even zero false actions over a short demo is weak evidence: under a simple Poisson assumption, zero events over H listening hours gives an approximate 95% upper rate of **3/H**; demonstrating less than one per 100 hours would require roughly 300 clean listening hours, representative conditions and an explicitly justified statistical model.

Promotion sequence: **fixture replay → local shadow-only hardware capture → previews only → small reversible action set → broader explicitly requested actions**. Keep microphone opt-in, hard policy, cancellation and action revalidation at every stage. Unlabeled controls, arbitrary scripts and trusted extensions are not made safe by a native shortcut/AX gate; this is not a filesystem sandbox.

## What exists from this session

Open [index.html](index.html): three offline studies—attention/preview/Undo, bounded recipes, and scripted ambient UX. All are mock-only. [README](README.md) explains how to try them; [review-checks.json](review-checks.json) records 24 initial browser observations and 14 post-review checks, with source hashes, steps and limitations. [Review follow-up](REVIEW-FOLLOWUP.md) records the accessibility/state fixes and remaining gaps. Node tests were written but blocked by dcg; no bypass or passing-test claim.

A separate [ambient-gate replay prototype](../ambient-gate/README.md) now contains 22 EN/DE/mixed scenarios and 47 intended test cases. It separates addressedness and intent, rejects untrusted/playback/partial/stale events, binds confirmation and follow-up scope, and changes only a dummy in-memory note/counter. It includes target-independent cancel/mute and explicit dictation activation. Syntax checks passed; the Node runner was blocked, so **runtime assertions and CLI replay are not yet validated**. Its prefilled origin/speaker/score labels are not a trained decision model or acoustic evidence. [Local voice research](../../docs/research/immersive-hci/local-ambient-voice.md) explains candidate APIs, privacy and the evaluation plan.

The first actual product step I would choose is **a small “Use this…” action/recipe layer over the existing shelf and cards**. In parallel, evaluate the strict-local sentinel/ambient gate in shadow mode. That tests the two strongest hypotheses—composition preserves flow, and addressedness can abstain reliably—without betting the installed computer-control path on them.
