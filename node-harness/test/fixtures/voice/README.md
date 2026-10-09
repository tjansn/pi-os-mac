# Voice corpus fixtures (text only)

These fixtures feed `test/voiceCorpus.test.ts` (the gates in DESIGN4 §9.1) and `scripts/voice-eval.mts`. Every
file is text: transcripts that speech recognizers produced from **synthetic `say` speech**, plus gold labels.
No user content is stored here. There is no audio and no microphone recording, the app index has no personal
app names, and no transcript comes from a real user.

## Files

| File | What it holds |
|---|---|
| `corpus.json` | The 288 utterances. Fields: `id`, `cat`, `lang`, `voice`, `rate`, `gold`, `say`, `kw` and `expect` (§ Gold). |
| `bench/<run>.<variant>.jsonl` | Recognizer output in the shared bench JSONL schema (§ Schema). There is one file per recognizer run and audio variant. |

| Run | Recognizer (r3/asr configuration) | Variants |
|---|---|---|
| `apple-dt-dual` | Apple DictationTranscriber en-US + de-DE in one SpeechAnalyzer, with 117 app names as contextual strings and alternatives plus confidence. Fed in realtime (100 ms chunks). Each line is a Phase A peer; en-US carries the whole-take n-best. | clean |
| `apple-dt` | DictationTranscriber per locale with no contextual strings. Clean was fed in realtime, the others in batch. There are no confidences. | clean, tail, room, ptt2 |
| `apple-st-en` | Today's engine: SpeechTranscriber en-US with pi-os's options (volatile + fast results). | clean, tail, room, ptt2 |
| `parakeet-v3` | NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML, ANE). | clean, tail, room, ptt2 |
| `whisper-turbo` | Whisper large-v3-turbo via WhisperKit, with automatic language detection. | clean, tail, room, ptt2 |
| `whisper-turbo-prompt` | The same, with the dictionary as the prompt. | clean |

Total size is about 1 MB. The test enforces a limit of 6 MB.

## Provenance

- **Speech.** The utterances come from `r3/asr`, the research for DESIGN4 (2026-10-07). They were rendered with
  macOS `say` to 16 kHz mono 16-bit WAV files and never played. `host-macos/qa/voice/gen.py` reproduces those
  files byte for byte.
- **Categories.**

  | Category | Language | Speech |
  |---|---|---|
  | A | English | Native voices |
  | B | English | Spoken by German voices |
  | C | German | Several German voices |
  | D | Mixed DE/EN | Several German voices |
  | E | English | Phonetic German-accent spellings |
  | F | English | Anna |
  | G | Accented English | Anna |
  | H | German | Anna |
  | I | Mixed | Anna |

  DESIGN4's "Tom-mix" is the mean of F, G, H and I.
- **Variants.** r3's `degrade2.py` produced them; `host-macos/qa/voice/degrade.py` ports it:

  | Variant | Simulates |
  |---|---|
  | `tail` | Early key-up |
  | `room` | Reverb + noise + mic band |
  | `ptt2` | `room` + early key-up |
- **Recognizers.** r3 ran them on a developer Mac under the `_LOCAL_AI` lock. The raw r3 result files are the
  `results/lat-apple-dtdual-apps.jsonl` and `results/merged/*.jsonl` that `import-r3` names.
- **Conversion.** `npx tsx scripts/voice-eval.mts import-r3 --r3 <r3 dir> --lid <lid-map.json>` converted the
  output:
  - **Peer order.** Apple peers are in `VoiceArbiter.final` order: P(own language) × confidence. P comes from
    NLLanguageRecognizer constrained to en/de, run over r3's `design4/lid` under a non-blocking flock. Ties go to en-US.
  - **N-best.** The whole-take n-best is built as `VoiceModuleTranscript.alternatives` builds it. The take's
    final segments are the suffix of the per-result alternative lists that spells the transcript. One segment is
    swapped at a time, the segment's own text and case variants are excluded, and at most 2 are kept.
  - **Locale.** `locale` on the Parakeet and Whisper lines is NLLanguageRecognizer's pick.
  - **Timings.** `finalMs` and `firstPartialMs` appear only where r3 measured in realtime or streamed.
    `minConfidence` is absent because r3 did not record word-level minima. The check gate's confidence signal
    is therefore not exercised by this replay.
- **App index.** The 104-app index that the fixtures use is `test/instantSpoken.test.ts`'s `APP_ROWS`. That is
  r3/mapping's `apps.json` without three personal apps, with `~/Applications` paths moved. It is read from that
  file's source and not copied. The r3/mapping phrasing corpus (3,380 + 665 negatives) is regenerated the same
  way, from instantSpoken's seeded tables, so it is not stored here either.

## Gold

`expect` is what the **real** instant lane decides for the gold text, sent as a voice final:

- `app:<bundleId>`, `url:<host>`, `sys:<op>`, `answer:<intent>`, `files` or `refuse`;
- `none` for agent-bound requests.

An item is **instant-able** when `expect` is not `none`. This is r3/design4 `stack*.mts`'s definition, giving
210/288 items: A 32, F 23, G 21, H 23, I 22. At generation the labels matched r3/design4's prototype labels for
all 288 items.

A deliberate mapping change that moves a label fails `voiceCorpus.test.ts`. Re-label from the committed corpus
(no r3 data needed):

```sh
npx tsx scripts/voice-eval.mts relabel     # prints only the ids whose label changed
```

## Schema

There is one line per utterance × audio variant × recognizer. S5's `pi-os-voice-bench` writes the same schema:

```jsonc
{"id": "A001", "variant": "clean", "source": "apple-dt/en-US", "role": "peer", "text": "Open Pages",
 "confidence": 0.7315, "nbest": ["…"], "finalMs": 20.3, "firstPartialMs": 914.2, "locale": "en-US"}
```

- **Required.** `id` (the corpus id), `variant`, `source` (a recognizer id), `role` (`primary` / `peer` /
  `secondary`) and `text` (`""` when nothing was heard).
- **Optional.** `confidence`, `minConfidence` (0..1), `nbest` (≤ 2), `finalMs`, `firstPartialMs` and `locale`
  (BCP 47).
- **Order.** A take's lines are in the arbiter's order.
