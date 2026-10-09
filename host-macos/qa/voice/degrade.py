#!/usr/bin/env python3
"""Degraded variants of the rendered voice corpus (DESIGN4 §9.2; port of r3/asr/corpus/degrade2.py).

Reads <root>/clean/<id>.wav (16 kHz mono 16-bit PCM from gen.py) and writes <root>/<variant>/<id>.wav:

    tail    clean speech with a 250 ms lead-in and the key released 80 ms after the speech (early key-up), no noise
    room    small-room reverb (RT60 0.3 s, direct-to-reverberant ratio +10 dB), pink noise at 20 dB SNR,
            80 Hz-7 kHz microphone band, 250 ms lead / 400 ms tail
    ptt2    room + the early 80 ms release: realistic push-to-talk
    noisy2  (opt-in) RT60 0.4 s, DRR +5 dB, pink noise at 10 dB SNR, 250/250 ms

Deterministic: each variant of each item draws from numpy's default_rng seeded with crc32(id + variant), as r3 did,
so the same corpus gives the same audio (the r3 recognizer results in the fixtures were measured on these variants).
Needs numpy (e.g. `uv run --with numpy python3 host-macos/qa/voice/degrade.py --root ~/voice-corpus`).
Files only; nothing is played. Log lines are content-free (counts).
"""
import argparse
import os
import sys
import tempfile
import wave
import zlib

try:
    import numpy as np
except ImportError:  # pragma: no cover - environment check
    raise SystemExit("degrade.py needs numpy: uv run --with numpy python3 host-macos/qa/voice/degrade.py ...")

SR = 16000
VARIANTS = {
    "tail": dict(lead=0.25, trail=0.08, room=None),
    "room": dict(lead=0.25, trail=0.40, room=(0.3, 10, 20)),
    "ptt2": dict(lead=0.25, trail=0.08, room=(0.3, 10, 20)),
    "noisy2": dict(lead=0.25, trail=0.25, room=(0.4, 5, 10)),
}
DEFAULT_VARIANTS = ("tail", "room", "ptt2")
SPEECH_THRESHOLD = 0.01


def pink(n, rng):
    w = rng.standard_normal(n)
    f = np.fft.rfft(w)
    k = np.arange(len(f))
    k[0] = 1
    return np.fft.irfft(f / np.sqrt(k), n)


def bandpass(x):
    f = np.fft.rfft(x)
    fr = np.fft.rfftfreq(len(x), 1 / SR)
    f[(fr < 80) | (fr > 7000)] = 0
    return np.fft.irfft(f, len(x))


def rir(rng, rt60, drr_db):
    """Exponentially decaying noise tail at the given direct-to-reverberant ratio, unit direct path."""
    n = int(rt60 * SR)
    t = np.arange(n) / SR
    tail = rng.standard_normal(n) * np.exp(-6.9 * t / rt60)
    tail[: int(0.003 * SR)] = 0
    tail *= np.sqrt(10 ** (-drr_db / 10) / np.sum(tail ** 2))
    tail[0] = 1.0
    return tail


def read_wav(path):
    """16-bit mono PCM → float64 in [-1, 1) (as soundfile reads it: sample / 32768)."""
    with wave.open(path, "rb") as handle:
        if handle.getnchannels() != 1 or handle.getsampwidth() != 2 or handle.getframerate() != SR:
            raise ValueError("expected 16 kHz mono 16-bit PCM")
        data = handle.readframes(handle.getnframes())
    return np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768.0


def write_wav(path, y):
    """float → 16-bit PCM exactly as r3's soundfile run wrote it (floor(32768 · x) in float32), atomically."""
    samples = np.floor(y.astype(np.float32) * np.float32(32768)).clip(-32768, 32767).astype("<i2")
    fd, tmp = tempfile.mkstemp(prefix=".degrade-", suffix=".wav", dir=os.path.dirname(path))
    os.close(fd)
    try:
        with wave.open(tmp, "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(SR)
            handle.writeframes(samples.tobytes())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def degrade(item_id, x, variant):
    p = VARIANTS[variant]
    idx = np.where(np.abs(x) > SPEECH_THRESHOLD)[0]
    if not len(idx):
        raise ValueError("silent")
    speech = x[idx[0]: idx[-1] + 1]
    rng = np.random.default_rng(zlib.crc32((item_id + variant).encode()))
    y = np.concatenate([np.zeros(int(p["lead"] * SR)), speech, np.zeros(int(p["trail"] * SR))])
    if p["room"]:
        rt60, drr, snr = p["room"]
        y = bandpass(np.convolve(y, rir(rng, rt60, drr))[: len(y)])
        s_rms = np.sqrt(np.mean(y[np.abs(y) > 0.005] ** 2))
        n = pink(len(y), rng)
        y = y + n / np.sqrt(np.mean(n ** 2)) * s_rms / (10 ** (snr / 20))
    if np.max(np.abs(y)) > 0.99:
        y = y / np.max(np.abs(y)) * 0.9
    return y


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", required=True, help="corpus root holding clean/<id>.wav (gen.py --out)")
    parser.add_argument("--variants", default=",".join(DEFAULT_VARIANTS), help=f"comma-separated subset of {', '.join(VARIANTS)}")
    parser.add_argument("--ids", default="", help="comma-separated ids (default: every clean WAV)")
    parser.add_argument("--force", action="store_true", help="rewrite files that exist")
    args = parser.parse_args(argv)

    variants = [v for v in args.variants.split(",") if v]
    unknown = [v for v in variants if v not in VARIANTS]
    if unknown:
        raise SystemExit(f"unknown variant(s): {', '.join(unknown)}")
    clean = os.path.join(args.root, "clean")
    ids = sorted(name[:-4] for name in os.listdir(clean) if name.endswith(".wav") and not name.startswith("."))
    wanted = {i for i in args.ids.split(",") if i}
    if wanted:
        ids = [i for i in ids if i in wanted]
    for variant in variants:
        os.makedirs(os.path.join(args.root, variant), exist_ok=True)

    counts = {"written": 0, "exists": 0, "failed": 0}
    for item_id in ids:
        try:
            x = read_wav(os.path.join(clean, f"{item_id}.wav"))
        except (OSError, ValueError, wave.Error):
            counts["failed"] += len(variants)
            continue
        for variant in variants:
            out = os.path.join(args.root, variant, f"{item_id}.wav")
            if os.path.exists(out) and not args.force:
                counts["exists"] += 1
                continue
            try:
                write_wav(out, degrade(item_id, x, variant))
                counts["written"] += 1
            except (OSError, ValueError):
                counts["failed"] += 1
    print(f"degrade: {len(ids)} items x {len(variants)} variants, " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
