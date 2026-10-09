#!/usr/bin/env python3
"""pi-os Laya intent sidecar: stdio JSON-lines, CPU-only, offline, ADVISORY ONLY.

Spawned and supervised by node-harness (src/classifier/laya.ts), one child per harness.
It never executes anything, never opens a network socket, and writes only inside the
staging directory it is given. Its answers are routing hints; they never authorize an
action (DESIGN.md §3.4).

Protocol (proto 1, one UTF-8 JSON object per line; fd 1 carries protocol lines only):
  child -> parent  {"type":"ready","proto":1,"model":{...},"load_ms":...}
                   {"type":"fatal","error":{"code":...,"kind":...,"message":...}}   then exit 2
  parent -> child  {"id":"c1","op":"classify","text":"...","deadline_ms":250}
                   {"id":"p1","op":"predict","state":{...},"questions":{...},"deadline_ms":2000}
                   {"id":"h1","op":"health"}
                   {"id":"x1","op":"cancel","target":"c1"}        (handled before queued work)
                   {"id":"s1","op":"shutdown"}  or close stdin  ->  exit 0
  child -> parent  {"id":"c1","ok":true,"result":{...},"timing":{"queue_ms":..,"infer_ms":..}}
                   {"id":"c1","ok":false,"error":{"code":"...","message":"..."}}
Error codes: bad_request | state_too_long | expired | cancelled | internal.

Guards: socket kill-switch (exit 97 on any non-AF_UNIX connect, send, bind or name lookup), offline
HF/transformers env, MPS hidden + every parameter/buffer asserted on CPU, optional
sha256 of the weights, model directory staged (configs copied, weights linked) so the
user's checkpoint can never be rewritten, utterances capped at 500 characters, and a
token-room check that refuses instead of silently truncating. Inputs are never logged.

Run (real):  <laya 0.3.5 venv>/bin/python -I -B laya_intent_sidecar.py --model-dir DIR --stage-dir DIR
Run (tests): python3 -I -B laya_intent_sidecar.py --fake   (no torch import, deterministic)
"""
import argparse
import collections
import hashlib
import json
import os
import queue
import re
import shutil
import sys
import threading
import time

sys.dont_write_bytecode = True

PROTO = 1
QSET_VERSION = "pi-os-intent-v1"
MAX_TEXT_CHARS = 500
MAX_LINE_BYTES = 64 * 1024
MAX_STATE_CHARS = 4000
MAX_QUESTIONS = 16
MAX_INSTRUCTION_CHARS = 500
MAX_CRITERION_CHARS = 300
MAX_CHOICE_OPTIONS = 20  # upstream: keep choice questions under ~20 options
MAX_SCORE_LEVELS = 10
MAX_ID_CHARS = 64
MAX_CANCELLED = 256  # recent cancel targets remembered (oldest forgotten first)
EXIT_NETWORK = 97

# Intent labels as shown to the model (MASSIVE-style short labels measured best zero-shot:
# 0.551 vs 0.449 for descriptive options, ~35% fewer tokens) -> stable pi-os ids.
INTENT_LABELS = {
    "calculate": "calculate", "convert units or currency": "convert", "time or date": "time_date",
    "find file": "file_search", "open app": "app_launch", "web search": "web_search",
    "open website": "open_url", "system setting": "system_toggle", "dictate text": "dictation",
    "other task": "agent_task",
}
INTENT_IDS = list(INTENT_LABELS.values())
TIER_LEVELS = ["none", "little", "moderate", "heavy"]
SURFACES = ["browser", "native_app", "none"]
QUESTIONS = {
    "intent": {"type": "choice", "instructions": "What does the user want done with `utterance`?",
               "criteria": {label: None for label in INTENT_LABELS}},
    "tier": {"type": "score", "instructions": "How much AI reasoning does `utterance` need?",
             "criteria": ["none: a direct command or lookup a simple program does instantly",
                          "little: one short answer, explanation, translation or summary",
                          "moderate: several steps or actions in apps or on websites",
                          "heavy: coding, research, deep analysis or long planning"]},
    "screen": {"type": "noul", "instructions": "Does `utterance` refer to something currently shown on screen, "
               "such as this page, this email, this file, selected text or a visible error?"},
    "surface": {"type": "choice", "instructions": "Which user interface must the assistant read or operate for `utterance`?",
                "criteria": {"browser": "a web page or website in a browser",
                             "native_app": "a desktop application window",
                             "none": "no interface: answer, compute or change a setting directly"}},
}
WEIGHT_SUFFIXES = (".safetensors", ".bin", ".pt", ".pth")
TEMP_BUCKET = re.compile(r"^(choice|score|noul):(2|3-5|6-10|11\+)$")


class SidecarError(Exception):
    """A refusal with a protocol error code; the message never contains user input."""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


class LoadError(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code


# ---------------------------------------------------------------- process guards

def isolate_stdout():
    """Keep fd 1 exclusively for protocol lines; library print()s land on stderr."""
    proto = os.fdopen(os.dup(1), "wb")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return proto


def offline_guard():
    """Offline env plus a socket kill-switch: any network attempt ends the process (97)."""
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1",
                      HF_HUB_DISABLE_TELEMETRY="1", DO_NOT_TRACK="1", TOKENIZERS_PARALLELISM="false",
                      USE_TF="0", USE_TORCH="1", CUDA_VISIBLE_DEVICES="", PYTORCH_ENABLE_MPS_FALLBACK="0")
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
                 "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        os.environ.pop(name, None)
    import socket

    unix = getattr(socket, "AF_UNIX", None)

    def deny(*_args, **_kwargs):
        try:
            sys.stderr.write("laya-sidecar: network access attempted; exiting\n")
            sys.stderr.flush()
        finally:
            os._exit(EXIT_NETWORK)

    def unix_only(real):
        """AF_UNIX keeps working (local IPC); every other family ends the process."""
        def guarded(self, *args, **kwargs):
            if unix is not None and self.family == unix:
                return real(self, *args, **kwargs)
            deny()
        return guarded

    # Outbound (connect, connectionless sends) and inbound (bind, so no listener either).
    for name in ("connect", "connect_ex", "sendto", "sendmsg", "bind"):
        real = getattr(socket.socket, name, None)  # no sendmsg on Windows
        if real is not None:
            setattr(socket.socket, name, unix_only(real))
    for name in ("create_connection", "getaddrinfo", "gethostbyname", "gethostbyname_ex", "gethostbyaddr",
                 "getnameinfo"):
        setattr(socket, name, deny)


def peak_rss_bytes():
    try:
        import resource
    except ImportError:  # Windows
        return None
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(peak if sys.platform == "darwin" else peak * 1024)


# ---------------------------------------------------------------- model staging

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(8 * 2 ** 20)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def stage_model_dir(source, dest):
    """Mirror a checkpoint into `dest`: configs/tokenizer copied, weights linked.

    laya 0.3.5 rewrites tokenizer/tokenizer_config.json in place when it needs normalising,
    and open(..., "w") follows symlinks, so every non-weight file must be a regular copy.
    Existing staged files are replaced atomically; nothing in `source` is ever written.
    """
    source = os.path.realpath(source)
    for root, dirs, files in os.walk(source):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d != "__pycache__")
        rel = os.path.relpath(root, source)
        out = dest if rel == "." else os.path.join(dest, rel)
        os.makedirs(out, exist_ok=True)
        for name in sorted(files):
            if name.startswith("."):
                continue
            src, dst = os.path.join(root, name), os.path.join(out, name)
            temporary = "%s.%d.staging" % (dst, os.getpid())
            if name.endswith(WEIGHT_SUFFIXES):
                target = os.path.realpath(src)
                if os.path.islink(dst) and os.readlink(dst) == target:
                    continue
                try:
                    os.symlink(target, temporary)
                except (OSError, NotImplementedError):  # no symlink privilege: copy instead
                    shutil.copyfile(target, temporary)
            else:
                shutil.copyfile(src, temporary)
            os.replace(temporary, dst)
    return dest


def load_calibration(path):
    """{"questions":?, "temperature":[choice, score, noul], "temperature_by_options":{"choice:6-10": T}}."""
    with open(path, "rb") as handle:
        raw = handle.read(65537)
    if len(raw) > 65536:
        raise LoadError("calibration_invalid", "calibration file too large")
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise LoadError("calibration_invalid", "calibration must be a JSON object")
    if data.get("questions") not in (None, QSET_VERSION):
        raise LoadError("calibration_invalid", "calibration was fitted for another question set")
    temps = data.get("temperature")
    if temps is not None and (not isinstance(temps, list) or len(temps) != 3 or
                              not all(isinstance(t, (int, float)) and not isinstance(t, bool) for t in temps)):
        raise LoadError("calibration_invalid", "temperature must be three numbers")
    by_options = data.get("temperature_by_options", {})
    if not isinstance(by_options, dict) or not all(
            isinstance(k, str) and TEMP_BUCKET.match(k) and isinstance(v, (int, float)) and not isinstance(v, bool)
            for k, v in by_options.items()):
        raise LoadError("calibration_invalid", "temperature_by_options must map buckets to numbers")
    return {"temperature": temps, "temperature_by_options": by_options}


# ---------------------------------------------------------------- request validation

def normalize_text(text):
    if not isinstance(text, str):
        raise SidecarError("bad_request", "op=classify needs a text string")
    text = " ".join(text.split())
    if not text:
        raise SidecarError("bad_request", "op=classify needs non-empty text")
    if len(text) > MAX_TEXT_CHARS:
        raise SidecarError("state_too_long", "max %d chars" % MAX_TEXT_CHARS)
    return text


def _short_string(value, limit, what, allow_empty=False):
    if not isinstance(value, str) or len(value) > limit or (not allow_empty and not value.strip()):
        raise SidecarError("bad_request", "%s must be a string of at most %d chars" % (what, limit))
    return value


def validate_predict(state, questions):
    """pi ClassifierContext ({state, questions} with choice/score/bool) -> Laya-native questions."""
    if not isinstance(state, dict):
        raise SidecarError("bad_request", "state must be a JSON object")
    if len(json.dumps(state, ensure_ascii=False)) > MAX_STATE_CHARS:
        raise SidecarError("state_too_long", "state over %d chars" % MAX_STATE_CHARS)
    if not isinstance(questions, dict) or not 1 <= len(questions) <= MAX_QUESTIONS:
        raise SidecarError("bad_request", "questions must hold 1..%d entries" % MAX_QUESTIONS)
    native, kinds = {}, {}
    for qid, question in questions.items():
        _short_string(qid, MAX_ID_CHARS, "question id")
        if not isinstance(question, dict):
            raise SidecarError("bad_request", "question %r must be an object" % qid)
        qtype = question.get("type")
        instructions = _short_string(question.get("instructions"), MAX_INSTRUCTION_CHARS, "instructions")
        criteria = question.get("criteria")
        if qtype == "choice":
            if not isinstance(criteria, dict) or not 2 <= len(criteria) <= MAX_CHOICE_OPTIONS:
                raise SidecarError("bad_request", "choice %r needs 2..%d options" % (qid, MAX_CHOICE_OPTIONS))
            options = {}
            for key, desc in criteria.items():
                _short_string(key, 80, "option label")
                if desc is not None:
                    _short_string(desc, MAX_CRITERION_CHARS, "option description", allow_empty=True)
                options[key] = desc or None
            native[qid] = {"type": "choice", "instructions": instructions, "criteria": options}
        elif qtype == "score":
            if not isinstance(criteria, list) or not 2 <= len(criteria) <= MAX_SCORE_LEVELS:
                raise SidecarError("bad_request", "score %r needs 2..%d levels" % (qid, MAX_SCORE_LEVELS))
            native[qid] = {"type": "score", "instructions": instructions,
                           "criteria": [_short_string(c, MAX_CRITERION_CHARS, "score level") for c in criteria]}
        elif qtype == "bool":
            crit = criteria if isinstance(criteria, dict) else {}
            native[qid] = {"type": "noul", "instructions": instructions, "criteria": {
                "false": _short_string(crit.get("false") or "", MAX_CRITERION_CHARS, "false criterion", True) or None,
                "true": _short_string(crit.get("true") or "", MAX_CRITERION_CHARS, "true criterion", True) or None}}
        else:
            raise SidecarError("bad_request", "question type must be choice, score or bool")
        kinds[qid] = qtype
    return native, kinds


# ---------------------------------------------------------------- result shaping

def _argmax(probs, order):
    best = order[0]
    for key in order:
        if probs.get(key, 0.0) > probs.get(best, 0.0):
            best = key
    return best


def shape_intent(answers, input_tokens, state_tokens):
    """Laya answers for QUESTIONS -> the advisory result node-harness maps to ClassifierHints."""
    intent = {INTENT_LABELS[k]: round(float(v), 4) for k, v in answers["intent"]["probabilities"].items()}
    tier = {TIER_LEVELS[int(k)]: round(float(v), 4) for k, v in answers["tier"]["probabilities"].items()}
    surface = {k: round(float(v), 4) for k, v in answers["surface"]["probabilities"].items()}
    intent_label, tier_label = _argmax(intent, INTENT_IDS), _argmax(tier, TIER_LEVELS)
    surface_label = _argmax(surface, SURFACES)
    return {
        "advisory": True,  # consumers must never treat this as authorization
        "questions": QSET_VERSION,
        "intent": {"label": intent_label, "p": intent[intent_label], "probs": intent},
        "tier": {"label": tier_label, "p": tier[tier_label], "expected": round(float(answers["tier"]["score"]), 4),
                 "probs": tier},
        "screen": {"p": round(float(answers["screen"]["noul"]), 4)},
        "surface": {"label": surface_label, "p": surface[surface_label], "probs": surface},
        "usage": {"input_tokens": int(input_tokens), "state_tokens": int(state_tokens)},
    }


def public_answers(answers, kinds):
    """Laya answers -> pi ClassifierResult answers. confidence = max probability (not entropy)."""
    out = {}
    for qid, kind in kinds.items():
        answer = answers[qid]
        if kind == "bool":
            out[qid] = {"type": "bool", "probability": round(float(answer["noul"]), 4)}
            continue
        probs = {k: round(float(v), 4) for k, v in answer["probabilities"].items()}
        top = max(probs.values()) if probs else 0.0
        if kind == "choice":
            out[qid] = {"type": "choice", "choice": answer["choice"], "probabilities": probs, "confidence": top}
        else:
            out[qid] = {"type": "score", "score": round(float(answer["score"]), 4), "probabilities": probs,
                        "confidence": top}
    return out


# ---------------------------------------------------------------- engines

class LayaEngine:
    """Real engine: laya 0.3.5 Agent on CPU (MPS hidden), loaded from a staged checkpoint."""

    def __init__(self, model_dir, stage_dir, threads=4, expected_sha256=None, calibration=None):
        import functools

        if not model_dir or not os.path.isfile(os.path.join(model_dir, "rl_agent_config.json")):
            raise LoadError("model_dir_invalid", "model directory has no rl_agent_config.json")
        if not stage_dir:
            raise LoadError("stage_dir_missing", "--stage-dir is required for the real engine")
        weights = os.path.realpath(os.path.join(model_dir, "model.safetensors"))
        if not os.path.isfile(weights):
            raise LoadError("model_dir_invalid", "model directory has no model.safetensors")
        if expected_sha256 and sha256_file(weights) != expected_sha256.lower():
            raise LoadError("sha256_mismatch", "weights sha256 mismatch")
        cal = load_calibration(calibration) if calibration else None
        staged = stage_model_dir(model_dir, stage_dir)
        try:
            import torch
        except ImportError:
            raise LoadError("torch_missing", "torch is not importable from this interpreter")

        def hide(fn):
            @functools.wraps(fn)  # torch._dynamo introspects __wrapped__
            def unavailable(*_args, **_kwargs):
                return False
            return unavailable

        if hasattr(torch.backends, "mps"):
            torch.backends.mps.is_available = hide(torch.backends.mps.is_available)
            torch.backends.mps.is_built = hide(torch.backends.mps.is_built)
        torch.set_num_threads(threads)
        torch.set_num_interop_threads(1)
        try:
            from laya import Agent, __version__
            from laya.common import build_sequence, clamp_temperature, render_options, serialize_state
        except ImportError:
            raise LoadError("laya_missing", "laya is not importable from this interpreter")
        self.torch, self.build_sequence, self.render_options = torch, build_sequence, render_options
        self.serialize_state = serialize_state
        self.agent = Agent(staged, device="cpu")
        devices = {p.device.type for p in self.agent.model.parameters()}
        devices |= {b.device.type for b in self.agent.model.buffers()}
        if devices != {"cpu"} or self.agent.device.type != "cpu":
            raise LoadError("non_cpu_tensors", "model is not entirely on the CPU")
        if cal:
            if cal["temperature"] is not None:
                self.agent.temperature = [clamp_temperature(t) for t in cal["temperature"]]
            self.agent.temperature_by_options = {k: clamp_temperature(v)
                                                 for k, v in cal["temperature_by_options"].items()}
        self.max_len = self.agent.cfg.get("max_len", 512)
        self.head_max_len = self.agent.cfg.get("head_max_len", 192)
        self.room = self.state_room(QUESTIONS)
        self.info = {"name": "laya-" + os.path.basename(os.path.normpath(model_dir)), "laya": __version__,
                     "torch": torch.__version__, "device": "cpu", "threads": threads, "questions": QSET_VERSION,
                     "state_token_room": self.room, "calibrated": bool(cal), "fake": False}
        for _ in range(2):  # warm kernels/allocator so the first user request is not the cold one
            self.classify("open Spotify")

    def state_room(self, questions):
        """Smallest state budget over the questions; refuses option sets that overflow the head."""
        room = None
        for qid, question in questions.items():
            internal = self.agent._to_internal(question)
            ids, markers = self.build_sequence(self.agent.tok, "", internal, self.max_len, self.head_max_len)
            if len(markers) != len(self.render_options(internal)):
                raise SidecarError("bad_request", "options of %r exceed the head budget" % qid)
            question_room = self.max_len - len(ids)
            room = question_room if room is None else min(room, question_room)
        return room or 0

    def state_tokens(self, state):
        text = self.serialize_state(state).replace(self.agent.tok.mask_token, " ")
        return len(self.agent.tok(text, add_special_tokens=False)["input_ids"])

    def _predict(self, state, questions, room):
        tokens = self.state_tokens(state)
        if tokens > room:  # laya would silently truncate the state; refuse instead
            raise SidecarError("state_too_long", "state needs %d tokens, room %d" % (tokens, room))
        with self.torch.inference_mode():
            result = self.agent.predict(state, questions)
        return result, tokens

    def classify(self, text):
        result, tokens = self._predict({"utterance": text}, QUESTIONS, self.room)
        return shape_intent(result["answers"], result["usage"]["input_tokens"], tokens)

    def predict(self, state, questions, kinds):
        result, tokens = self._predict(state, questions, self.state_room(questions))
        return {"advisory": True, "answers": public_answers(result["answers"], kinds),
                "usage": {"input_tokens": int(result["usage"]["input_tokens"]), "state_tokens": tokens}}


class FakeEngine:
    """Deterministic stand-in for tests: no torch, no model, same output shapes.

    Test hooks (fake engine only): text "__crash__" exits the process, "__slow__ <ms> <text>"
    sleeps before answering, "__room__" simulates a token-room refusal.
    """

    def __init__(self, load_ms=0):
        print("fake engine: simulated library print(); must land on stderr, not the protocol")
        print("fake engine: simulated warning about /private/models/laya/multilingual/model.safetensors")
        if load_ms:
            time.sleep(load_ms / 1000.0)
        self.info = {"name": "fake", "laya": None, "torch": None, "device": "none", "threads": 0,
                     "questions": QSET_VERSION, "state_token_room": 999, "calibrated": False, "fake": True}

    @staticmethod
    def _hooks(text):
        if text.startswith("__crash__"):
            os._exit(3)
        if text.startswith("__room__"):
            raise SidecarError("state_too_long", "state needs 1000 tokens, room 999")
        if text.startswith("__slow__"):
            parts = text.split(" ", 2)
            time.sleep(int(parts[1]) / 1000.0 if len(parts) > 1 and parts[1].isdigit() else 0.2)
            return parts[2] if len(parts) > 2 else "slow"
        return text

    def classify(self, text):
        t = self._hooks(text).lower()
        words = t.split()
        if any(c.isdigit() for c in t) and any(o in t for o in ("+", "-", "*", "/", " x ", "%", " times ", " mal ")):
            label = "calculate"
        elif re.search(r"\d+\s*\S+\s+(in|to|nach|zu)\s+\S+", t):
            label = "convert units or currency"
        elif "time" in words or "uhr" in t or "wie spät" in t or "date" in words:
            label = "time or date"
        elif t.startswith(("find ", "finde ", "such ")) and re.search(r"\b(file|pdf|datei|dokument|ordner)\b", t):
            label = "find file"
        elif t.startswith(("open ", "öffne ", "go to ")) and re.search(r"\.[a-z]{2,}\b", t):
            label = "open website"
        elif t.startswith(("open ", "öffne ", "switch to ", "wechsle zu ")):
            label = "open app"
        elif t.startswith(("search the web", "google ", "such im internet")):
            label = "web search"
        elif re.search(r"\b(turn (on|off)|volume|lautstärke|bluetooth|dark mode|dunkelmodus)\b", t):
            label = "system setting"
        elif t.startswith(("type:", "dictate", "schreib:", "tippe ein")):
            label = "dictate text"
        else:
            label = "other task"
        agent = label == "other task"
        answers = {
            "intent": {"probabilities": {k: (0.91 if k == label else 0.01) for k in INTENT_LABELS}},
            "tier": {"score": 2.0 if agent else 0.1,
                     "probabilities": {"0": 0.05, "1": 0.2, "2": 0.5, "3": 0.25} if agent
                     else {"0": 0.9, "1": 0.05, "2": 0.03, "3": 0.02}},
            "screen": {"noul": 0.9 if re.search(r"\b(this|these|that|dies\w*|hier)\b", t) else 0.05},
            "surface": {"probabilities": {"browser": 0.1, "native_app": 0.1, "none": 0.8}},
        }
        return shape_intent(answers, 0, len(words))

    def predict(self, state, questions, kinds):
        blob = json.dumps(state, ensure_ascii=False, sort_keys=True).lower()
        if "__room__" in blob:
            raise SidecarError("state_too_long", "state needs 1000 tokens, room 999")
        answers = {}
        for qid, question in questions.items():
            if kinds[qid] == "choice":
                keys = list(question["criteria"])
                chosen = next((k for k in keys if k.lower() in blob), keys[0])
                rest = round(0.2 / (len(keys) - 1), 4)
                answers[qid] = {"choice": chosen, "probabilities": {k: (0.8 if k == chosen else rest) for k in keys}}
            elif kinds[qid] == "score":
                levels = len(question["criteria"])
                probs = {str(i): (0.6 if i == 0 else round(0.4 / (levels - 1), 4)) for i in range(levels)}
                answers[qid] = {"score": sum(i * p for i, p in enumerate(probs.values())), "probabilities": probs}
            else:
                answers[qid] = {"noul": 0.9 if re.search(r"\b(this|true|dies\w*)\b", blob) else 0.1}
        return {"advisory": True, "answers": public_answers(answers, kinds),
                "usage": {"input_tokens": 0, "state_tokens": len(blob.split())}}


# ---------------------------------------------------------------- serving loop

OVERSIZED, INVALID = object(), object()


def reader(inbox, cancelled, cancel_lock, ready, ignore_eof):
    """Reads stdin on its own thread so EOF and cancels are seen even while the engine works."""
    stream = sys.stdin.buffer
    while True:
        try:
            raw = stream.readline(MAX_LINE_BYTES + 1)
        except (OSError, ValueError):
            raw = b""
        if not raw:
            if ignore_eof:  # fake-engine test hook: behave like a hung child
                threading.Event().wait()
            if not ready.is_set():
                os._exit(0)  # parent went away during the (long) model load
            inbox.put((time.perf_counter(), None))
            return
        arrived = time.perf_counter()
        if not raw.strip():
            continue
        if len(raw) > MAX_LINE_BYTES and not raw.endswith(b"\n"):
            while True:  # drain the rest of the oversized line
                more = stream.readline(MAX_LINE_BYTES)
                if not more or more.endswith(b"\n"):
                    break
            inbox.put((arrived, OVERSIZED))
            continue
        try:
            request = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            inbox.put((arrived, INVALID))
            continue
        if isinstance(request, dict) and request.get("op") == "cancel":
            target = request.get("target")
            if isinstance(target, str) and len(target) <= MAX_ID_CHARS:
                with cancel_lock:
                    cancelled[target] = True
                    while len(cancelled) > MAX_CANCELLED:  # targets that already finished never get consumed
                        cancelled.popitem(last=False)
            continue
        inbox.put((arrived, request))


def serve(engine, inbox, cancelled, cancel_lock, send):
    def fail(rid, code, message):
        send({"id": rid, "ok": False, "error": {"code": code, "message": message[:200]}})

    while True:
        arrived, request = inbox.get()
        if request is None:
            return 0
        if request is OVERSIZED:
            fail(None, "bad_request", "line too long")
            continue
        if request is INVALID or not isinstance(request, dict):
            fail(None, "bad_request", "invalid JSON request")
            continue
        rid, op = request.get("id"), request.get("op")
        if not isinstance(rid, str) or not rid or len(rid) > MAX_ID_CHARS:
            fail(None, "bad_request", "id must be a short string")
            continue
        if op == "shutdown":
            send({"id": rid, "ok": True})
            return 0
        if op == "health":
            send({"id": rid, "ok": True, "health": {"model": engine.info, "pid": os.getpid(), "queue": inbox.qsize(),
                                                    "peak_rss_bytes": peak_rss_bytes()}})
            continue
        with cancel_lock:
            was_cancelled = cancelled.pop(rid, False)
        if was_cancelled:
            fail(rid, "cancelled", "cancelled before it started")
            continue
        waited = (time.perf_counter() - arrived) * 1000
        deadline = request.get("deadline_ms")
        if isinstance(deadline, (int, float)) and not isinstance(deadline, bool) and waited > deadline:
            fail(rid, "expired", "queued %.0f ms" % waited)
            continue
        started = time.perf_counter()
        try:
            if op == "classify":
                result = engine.classify(normalize_text(request.get("text")))
            elif op == "predict":
                native, kinds = validate_predict(request.get("state"), request.get("questions"))
                result = engine.predict(request["state"], native, kinds)
            else:
                raise SidecarError("bad_request", "unknown op")
        except SidecarError as error:
            fail(rid, error.code, str(error))
            continue
        except Exception as error:  # never echo inputs: report the exception type only
            fail(rid, "internal", type(error).__name__)
            continue
        send({"id": rid, "ok": True, "result": result,
              "timing": {"queue_ms": round(waited, 2), "infer_ms": round((time.perf_counter() - started) * 1000, 2)}})


def parse_args(argv):
    parser = argparse.ArgumentParser(description="pi-os Laya intent sidecar (stdio JSON-lines, CPU-only)")
    parser.add_argument("--model-dir", help="Laya checkpoint directory (multilingual)")
    parser.add_argument("--stage-dir", help="pi-os-owned directory the checkpoint is staged into")
    parser.add_argument("--sha256", help="expected sha256 of model.safetensors")
    parser.add_argument("--calibration", help="temperature calibration JSON")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--fake", action="store_true", help="deterministic fake engine (tests)")
    parser.add_argument("--fake-load-ms", type=int, default=0, help=argparse.SUPPRESS)
    parser.add_argument("--fake-fail-load", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--fake-ignore-eof", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--selftest-network", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not 1 <= args.threads <= 16:
        parser.error("--threads must be 1..16")
    if (args.fake_load_ms or args.fake_fail_load or args.fake_ignore_eof) and not args.fake:
        parser.error("fake-engine hooks need --fake")
    return args


def main(argv=None):
    args = parse_args(argv)
    out = isolate_stdout()
    offline_guard()
    if args.selftest_network:  # tests: the guard must end the process before any packet is sent
        import socket
        socket.create_connection(("127.0.0.1", 9), timeout=0.2)
        return 98
    lock = threading.Lock()

    def send(obj):
        line = (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with lock:
            out.write(line)
            out.flush()

    inbox, cancelled, cancel_lock, ready = queue.Queue(), collections.OrderedDict(), threading.Lock(), threading.Event()
    threading.Thread(target=reader, args=(inbox, cancelled, cancel_lock, ready, args.fake_ignore_eof),
                     daemon=True).start()
    started = time.perf_counter()
    try:
        if args.fake:
            if args.fake_fail_load:
                raise LoadError("load_failed", "simulated load failure")
            engine = FakeEngine(args.fake_load_ms)
        else:
            engine = LayaEngine(args.model_dir, args.stage_dir, args.threads, args.sha256, args.calibration)
    except Exception as error:  # report and exit non-zero; the parent keeps routing without Laya
        code = getattr(error, "code", "load_failed")
        send({"type": "fatal", "error": {"code": code, "kind": type(error).__name__, "message": str(error)[:200]}})
        return 2
    ready.set()
    send({"type": "ready", "proto": PROTO, "model": engine.info,
          "load_ms": round((time.perf_counter() - started) * 1000, 1)})
    return serve(engine, inbox, cancelled, cancel_lock, send)


if __name__ == "__main__":
    status = main()
    # Skip interpreter finalization: the daemon stdin reader may still hold the stdin buffer
    # lock (an "op":"shutdown" exit), which aborts CPython's shutdown. Protocol output is
    # flushed per line already.
    sys.stderr.flush()
    os._exit(status)
