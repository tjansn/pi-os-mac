# Voice corpus: local audio replay (DESIGN4 §9.2)

Synthetic speech for measuring pi-os voice recognition and the voice decision pipeline offline. Nothing here
runs in CI. CI replays the text fixtures instead: `node-harness/test/voiceCorpus.test.ts` runs
`node-harness/test/fixtures/voice/`.

```
corpus.json ──gen.py──▶ <root>/clean/*.wav ──degrade.py──▶ <root>/{tail,room,ptt2}/*.wav
      │                                                          │
      │                       pi-os-voice-bench (S5, production engine classes)
      │                                                          ▼
      └──────────────── node-harness/scripts/voice-eval.mts ◀── bench JSONL
```

## Rules

- **Files only.** `gen.py` always passes `say -o <file>`, so audio never plays. Nothing uses the microphone.
  Write the corpus outside the repository. `gen.py` refuses to write into the text-only fixtures.
- **Content-free logs.** Both scripts print counts and voice names only, never the spoken text.
  `voice-eval.mts` prints only counts and percentages unless you pass `--show-content`.
- **Local inference lock.** `gen.py` and `degrade.py` run on the CPU only (`say` and numpy).
  A bench run puts the recognizers on the ANE, so it holds a **non-blocking** flock on
  `/Users/tom/dev/Projects/_LOCAL_AI/.local-inference.lock` (or `$PI_LOCAL_INFERENCE_LOCK`); `pi-os-voice-bench`
  takes it itself (§3). If the lock is held, skip the run and say so. Never wait for the lock, and never create
  files in `_LOCAL_AI`.
- **Safety.** Use only harmless corpus commands, which open apps or answer questions. The corpus contains no deletion
  request, except the refusal checks in the text-only mapping corpus.

## 1. Render: `gen.py`

```sh
python3 host-macos/qa/voice/gen.py --out ~/voice-corpus             # 288 WAVs: <out>/clean/<id>.wav
python3 host-macos/qa/voice/gen.py --out ~/voice-corpus --dry-run   # check voices; write nothing
python3 host-macos/qa/voice/gen.py --out ~/voice-corpus --ids A001,H003 --force
```

- **Manifest.** The script reads `node-harness/test/fixtures/voice/corpus.json`. Each item gives `id`, `voice`,
  `rate` and `say`. The `say` field holds phonetic spellings for the accented categories.
- **Format.** Output is `say -v <voice> -r <rate> -o <file> --file-format=WAVE --data-format=LEI16@16000`:
  16 kHz mono 16-bit PCM, as the engines receive it.
- **Voices.** English items use the manifest's English voices (Samantha, Daniel, Karen, Moira, Tessa, Rishi,
  and the US Eddy, Flo, Reed, Rocko, Sandy and Shelley). The accented and German categories use the German
  voices, with Anna as the natural German voice. Pass `--fallback` to use Samantha or Anna when an item's voice
  is not installed.
- **Standalone.** The script needs only the Python standard library.
- **Verified on 2026-10-07 (macOS 27).** Output was byte-identical to the r3/asr audio for every id checked.

## 2. Degrade: `degrade.py`

```sh
uv run --with numpy python3 host-macos/qa/voice/degrade.py --root ~/voice-corpus            # tail, room, ptt2
uv run --with numpy python3 host-macos/qa/voice/degrade.py --root ~/voice-corpus --variants noisy2
```

| Variant | What it simulates |
|---|---|
| `tail` | Clean speech, 250 ms lead-in, key released 80 ms after the speech (early key-up) |
| `room` | Small-room reverb (RT60 0.3 s, DRR +10 dB), pink noise at 20 dB SNR, 80 Hz–7 kHz band, 250/400 ms |
| `ptt2` | `room` plus the early 80 ms release: realistic push-to-talk |
| `noisy2` | Opt-in: RT60 0.4 s, DRR +5 dB, pink noise at 10 dB SNR |

- **Origin.** This is a port of r3's `degrade2.py`.
- **Determinism.** Seeds are `crc32(id + variant)`, so the output is deterministic. Of the 32 files checked,
  31 were bit-identical to r3's audio. The 32nd differed by 1 LSB in one sample.
- **Dependencies.** The script needs numpy. It uses `wave` from the standard library for I/O.

## 3. Transcribe: `pi-os-voice-bench` (S5)

The bench feeds the WAVs through the production engine classes in 100 ms realtime or batch chunks. It writes one
JSONL line per utterance × variant × recognizer:

```jsonc
{"id": "A001",              // the WAV basename = corpus id
 "variant": "clean",        // clean | tail | room | ptt2 | …
 "source": "parakeet-v3",   // recognizer id: parakeet-v3, apple-dt/en-US, apple-dt/de-DE, apple-st/<locale>
 "role": "primary",         // primary | peer | secondary: the arbiter's role
 "text": "Open Pages.",     // "" when the take produced nothing
 "confidence": 0.91, "minConfidence": 0.4,   // optional, 0..1
 "nbest": ["Open pages"],   // optional, ≤ 2 whole-take alternatives
 "finalMs": 35, "firstPartialMs": 530,       // optional: key-up → final, key-down → first partial
 "locale": "en-US"}         // optional (additive): the hypothesis language; the bench does not write it yet
```

Write a take's lines in the arbiter's order: first tier best first, then the secondaries. The bench writes one line
per recognizer of the take: the recognizer's final, its n-best (≤ 2) in `nbest`, and `text: ""` for a recognizer
that heard nothing. With Parakeet loaded, `parakeet-v3` is `primary` and the Apple modules are `secondary`
(Phase B); with `--engines apple` the Apple modules are `peer`s (Phase A).

Without `locale`, `voice-eval.mts` sends `en-US` as the `/instant` locale hint for bench takes (the CI fixtures carry
precomputed locales). On the current fixtures, dropping `locale` changes no Phase A or Phase B score.

**The bench takes the lock itself.** `pi-os-voice-bench` holds a non-blocking flock on the lock file for the whole
run (`FileInferenceLock.standard`, which honours `$PI_LOCAL_INFERENCE_LOCK`). When the lock is held it runs
nothing and exits 75; without the lock file (another machine) there is nothing to coordinate with and it runs. Run
it directly. **Do not wrap it in a second flock:** a flock belongs to one open file
description, so the bench would see the wrapper's own hold as held and refuse every run.

```sh
swift build -c release --package-path host-macos --product pi-os-voice-bench
CFFIXED_USER_HOME=~/voice-corpus/home \
  host-macos/.build/release/pi-os-voice-bench --manifest node-harness/test/fixtures/voice/corpus.json \
  --audio-root ~/voice-corpus --variant clean \
  --models "$HOME/Library/Application Support/pi-os/models/parakeet-tdt-v3" \
  --out ~/voice-corpus/bench.clean.jsonl
# exit 75: the local-inference lock is held; nothing ran (say so and try in a coordinated window)
```

| Option | Meaning |
|---|---|
| `--out <file.jsonl>` | Required. The only file that holds transcripts. |
| `--input <dir>` | Every `*.wav` in the directory (id = basename), sorted. Use this or `--manifest`. |
| `--manifest <json> --audio-root <dir>` | A JSON array (or `{"items": [...]}`) of objects with `id`; audio from `<audio-root>/<variant>/<id>.wav`, else `<audio-root>/<id>.wav`. The fixture `corpus.json` works as is. |
| `--variant <name>` | Default `clean`; written into every line. |
| `--mode realtime\|batch` | `realtime` (default) feeds 100 ms chunks at real time through a take, as the microphone would; `batch` feeds them as fast as possible. |
| `--engines apple,parakeet` | Default both. `apple` alone is Phase A. `parakeet` alone decodes each file once, without a take (no partials, no real-time feed). |
| `--models <dir>` | The Parakeet v3 Core ML folder. Default `<support>/models/parakeet-tdt-v3` (`$PI_OS_SUPPORT_DIR`, else `~/Library/Application Support/pi-os`). |
| `--languages en-US,de-DE` | The Apple languages (default both). |
| `--contextual <file>` | Contextual strings for Apple's dictation, one per line (default none). |
| `--limit N` | Only the first N files. |

- **Exit codes:** 0 done, 75 lock held (nothing ran), 64 usage, 1 failure.
- **stderr** gets only counts and timings: per-stage and per-recognizer p50/p90/max (`stage primary`, `stage
  complete`, `<recognizer> final`, `<recognizer> first partial`, and `parakeet-v3 decode` with `--engines parakeet`).
- **`CFFIXED_USER_HOME`** keeps Core ML's compiled-model caches out of `~/Library`. It also moves `~` for the
  default `--models` path, so pass `--models` with the real path (as above). It does not move the lock: the lock
  path is resolved from the account's real home.
- **Model files** are only read. Use the folder Settings → Voice → Recognition installed, or another verified copy of
  `FluidInference/parakeet-tdt-0.6b-v3-coreml`; the bench never downloads.
- **Measured** (36 `say` utterances, 12 English, 12 German, 12 mixed; release build; real time; under the lock):
  Parakeet key-up → final p50 38 ms (p90 40, max 41); the `.primary` stage 39 / 42 / 44 ms; the `.complete` stage
  54 / 111 / 156 ms; first partial from key-down Parakeet p50 562 ms (p90 1,079), Apple ≈ 0.86 s; one Parakeet decode
  per file (`--engines parakeet`) 33 ms p50. Synthetic voices only: see VOICE_MAGIC.md (pass 3) for the keyword hits and the caveats.

Any other tool that puts a recognizer on the ANE or GPU and does **not** lock itself is wrapped like this:

```sh
python3 - <command> [args…] <<'EOF'
import fcntl, os, subprocess, sys
lock = os.environ.get("PI_LOCAL_INFERENCE_LOCK", "/Users/tom/dev/Projects/_LOCAL_AI/.local-inference.lock")
fd = os.open(lock, os.O_RDONLY)                     # never create it
try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit("local-inference lock held; skipping the run")
sys.exit(subprocess.call(sys.argv[1:]))
EOF
```

## 4. Score: `voice-eval.mts`

```sh
cd node-harness
npx tsx scripts/voice-eval.mts bench-clean.jsonl                       # recognizers + stacks, content-free
npx tsx scripts/voice-eval.mts --stack phaseA,phaseB --details run.jsonl
npx tsx scripts/voice-eval.mts --learn clean:ptt2 clean.jsonl ptt2.jsonl # one correction, another take
```

The script prints three tables:

- **Per recognizer.** WER, exact match, intent, wrong acts, empty takes, and final and first-partial latency.
- **Per stack.** One row each for `asis`, `phaseA`, `phaseB`, `single:<source>` and `legacy:<source>`:
  - categories A and F–I, Tom-mix at once, with one Return, and offered;
  - wrong acts at once and behind a Return;
  - agent-bound items acted on or held.
- **Cross-take learning.** This runs the real DictionaryStore and learn lane in a temporary directory.

The script scores the same metrics as `voiceCorpus.test.ts`, so a bench run lines up with the CI gates
(DESIGN4 §9.1). Ids without a gold label are skipped. The gold is in the fixture `corpus.json`, and the voice
journal's takes have no gold label yet.
