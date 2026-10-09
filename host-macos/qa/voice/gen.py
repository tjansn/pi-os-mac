#!/usr/bin/env python3
"""Renders the voice corpus to WAV files with macOS `say` (DESIGN4 §9.2). Never plays audio.

Every utterance of the corpus manifest (node-harness/test/fixtures/voice/corpus.json: id, voice, rate, say)
is rendered with

    say -v <voice> -r <rate> -o <out>/clean/<id>.wav --file-format=WAVE --data-format=LEI16@16000 <say>

which writes 16 kHz mono 16-bit PCM to a FILE (`-o` is always given, so nothing reaches the speakers).
English items use the manifest's English voices and German items Anna; a voice that is not installed falls
back to Samantha (English) or Anna (German) with --fallback, else the item is skipped and counted.
Output goes outside the repository (the fixtures stay text-only). Log lines are content-free: counts and
voice names only, never the spoken text.

    python3 host-macos/qa/voice/gen.py --out ~/voice-corpus            # all 288 items
    python3 host-macos/qa/voice/gen.py --out ~/voice-corpus --ids A001,H003 --force
    python3 host-macos/qa/voice/gen.py --out ~/voice-corpus --dry-run  # what would run, nothing written

Then degrade.py adds the tail/room/ptt2 variants, and pi-os-voice-bench (S5) transcribes them to bench JSONL
that node-harness/scripts/voice-eval.mts scores.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DEFAULT_MANIFEST = os.path.join(REPO, "node-harness", "test", "fixtures", "voice", "corpus.json")
FALLBACK = {"en": "Samantha", "de": "Anna", "mixed": "Anna"}
SAY = "/usr/bin/say"
FORMAT = ["--file-format=WAVE", "--data-format=LEI16@16000"]
ID_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")


def installed_voices():
    """Voice names `say -v ?` lists ("Anna (German (Germany))") plus their short forms ("Anna"), which `say -v` accepts."""
    out = subprocess.run([SAY, "-v", "?"], check=True, capture_output=True, text=True).stdout
    names = set()
    for line in out.splitlines():
        # "<name> <locale>    # <sample>": the locale is the last field before the comment.
        head = line.split("#", 1)[0].rstrip()
        parts = head.rsplit(None, 1)
        if len(parts) == 2:
            name = parts[0].strip()
            names.add(name)
            names.add(name.split(" (", 1)[0])
    return names


def load_manifest(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    items = data["items"] if isinstance(data, dict) else data
    for item in items:
        if not set(item["id"]) <= ID_CHARS or not item["id"]:
            raise SystemExit("manifest: invalid id")
        if not isinstance(item.get("say"), str) or not item["say"].strip():
            raise SystemExit("manifest: an item has no text to say")
    return items


def inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def render(item, voice, out_path):
    """`say` to a temporary file next to the target, then an atomic rename (never plays audio)."""
    directory = os.path.dirname(out_path)
    fd, tmp = tempfile.mkstemp(prefix=".gen-", suffix=".wav", dir=directory)
    os.close(fd)
    try:
        cmd = [SAY, "-v", voice, "-r", str(int(item.get("rate", 180))), "-o", tmp, *FORMAT, "--", item["say"]]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.getsize(tmp) <= 44:
            raise RuntimeError("empty")
        os.replace(tmp, out_path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST, help="corpus manifest (default: the fixture corpus.json)")
    parser.add_argument("--out", required=True, help="output root; WAVs go to <out>/clean/<id>.wav")
    parser.add_argument("--ids", default="", help="comma-separated ids (default: all)")
    parser.add_argument("--fallback", action="store_true", help="use Samantha/Anna when an item's voice is not installed")
    parser.add_argument("--force", action="store_true", help="re-render files that exist")
    parser.add_argument("--dry-run", action="store_true", help="report what would be rendered; write nothing")
    args = parser.parse_args(argv)

    if sys.platform != "darwin" or not os.path.exists(SAY):
        raise SystemExit("gen.py needs macOS `say`")
    if inside(args.out, os.path.join(REPO, "node-harness", "test", "fixtures")):
        raise SystemExit("refusing to write audio into the text-only fixtures")
    items = load_manifest(args.manifest)
    wanted = {i for i in args.ids.split(",") if i}
    if wanted:
        items = [item for item in items if item["id"] in wanted]
    voices = installed_voices()
    target = os.path.join(args.out, "clean")
    if not args.dry_run:
        os.makedirs(target, exist_ok=True)

    counts = {"rendered": 0, "exists": 0, "fallback": 0, "missing_voice": 0, "failed": 0}
    missing = set()
    for item in items:
        voice = item["voice"]
        if voice not in voices:
            missing.add(voice)
            if not args.fallback:
                counts["missing_voice"] += 1
                continue
            voice = FALLBACK.get(item.get("lang", "en"), "Samantha")
            if voice not in voices:
                counts["missing_voice"] += 1
                continue
            counts["fallback"] += 1
        out_path = os.path.join(target, f"{item['id']}.wav")
        if os.path.exists(out_path) and not args.force:
            counts["exists"] += 1
            continue
        if args.dry_run:
            counts["rendered"] += 1
            continue
        try:
            render(item, voice, out_path)
            counts["rendered"] += 1
        except (subprocess.CalledProcessError, RuntimeError, OSError):
            counts["failed"] += 1
    print(f"gen: {len(items)} items, " + ", ".join(f"{k} {v}" for k, v in counts.items())
          + (" (dry run)" if args.dry_run else "") + (f"; voices not installed: {', '.join(sorted(missing))}" if missing else ""))
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
