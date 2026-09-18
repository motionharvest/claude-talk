#!/usr/bin/env python3
"""XTTS-v2 speech synthesis for claude-talk.

XTTS-v2 runs locally and needs ten to twenty seconds to load. This script keeps
the loaded model resident in a daemon and talks to it over a unix socket, so
only the first request of a session pays the load cost.

Modes:
    serve     run the daemon in the foreground
    say       synthesize text to a wav file, starting the daemon if needed
    speakers  print the built-in speaker names
    status    print daemon, device and model state
    stop      shut the daemon down

The wire protocol is one JSON object per line in each direction.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path

MODEL_NAME = "tts_models/multilingual/multi-dataset/xtts_v2"
MODEL_CACHE = "tts_models--multilingual--multi-dataset--xtts_v2"
DEFAULT_SPEAKER = "Claribel Dervla"
DEFAULT_LANGUAGE = "en"
SAMPLE_RATE = 24000
CHUNK_LIMIT = 220
GAP_SECONDS = 0.08
START_TIMEOUT = 60.0
REQUEST_TIMEOUT = 900.0
_BOUNDARY = re.compile(r"(?<=[.!?;:])\s+|\n+")


def state_dir() -> Path:
    """Return the runtime directory shared with talk.sh."""
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    path = Path(base) / "claude-talk"
    path.mkdir(parents=True, exist_ok=True)
    return path


def default_socket() -> Path:
    """Return the unix socket path the daemon listens on."""
    override = os.environ.get("TALK_XTTS_SOCKET")
    return Path(override) if override else state_dir() / "xtts.sock"


def model_dir() -> Path:
    """Return the directory the XTTS-v2 checkpoint is cached in."""
    try:
        from TTS.utils.generic_utils import get_user_data_dir

        base = Path(get_user_data_dir("tts"))
    except Exception:
        share = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
        base = Path(share) / "tts"
    return base / MODEL_CACHE


def idle_timeout() -> float:
    """Return the seconds of inactivity after which the daemon exits."""
    try:
        return float(os.environ.get("TALK_XTTS_IDLE", "900"))
    except ValueError:
        return 900.0


def _wrap(piece: str, limit: int) -> list[str]:
    """Break one long run of words into pieces no longer than limit."""
    out: list[str] = []
    current = ""
    for word in piece.split():
        while len(word) > limit:
            if current:
                out.append(current)
                current = ""
            out.append(word[:limit])
            word = word[limit:]
        if not current:
            current = word
        elif len(current) + 1 + len(word) <= limit:
            current = f"{current} {word}"
        else:
            out.append(current)
            current = word
    if current:
        out.append(current)
    return out


def split_text(text: str, limit: int = CHUNK_LIMIT) -> list[str]:
    """Split text into chunks XTTS-v2 can synthesize in one pass.

    XTTS-v2 truncates any input over roughly 250 characters, so the caller must
    never hand it a whole response. Splitting happens at sentence boundaries
    first and at word boundaries only when one sentence is itself too long.
    """
    chunks: list[str] = []
    current = ""
    for part in (p.strip() for p in _BOUNDARY.split(text)):
        if not part:
            continue
        pieces = _wrap(part, limit) if len(part) > limit else [part]
        for piece in pieces:
            if not current:
                current = piece
            elif len(current) + 1 + len(piece) <= limit:
                current = f"{current} {piece}"
            else:
                chunks.append(current)
                current = piece
    if current:
        chunks.append(current)
    return chunks


def write_wav(path: str, samples, rate: int) -> None:
    """Write float samples in the range -1 to 1 as a 16-bit mono wav file."""
    import numpy as np

    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(pcm.tobytes())


def _allow_xtts_unpickling() -> None:
    """Register the XTTS config classes torch refuses to unpickle by default."""
    try:
        import torch
        from TTS.config.shared_configs import BaseDatasetConfig
        from TTS.tts.configs.xtts_config import XttsConfig
        from TTS.tts.models.xtts import XttsArgs, XttsAudioConfig

        torch.serialization.add_safe_globals(
            [XttsConfig, XttsAudioConfig, BaseDatasetConfig, XttsArgs]
        )
    except Exception:
        pass


class Engine:
    """Holds the XTTS-v2 model and every speaker latent computed so far."""

    def __init__(self, device: str | None = None):
        self.requested_device = device
        self.device = device or "cpu"
        self.model = None
        self.sample_rate = SAMPLE_RATE
        self.latents: dict = {}

    def _pick_device(self) -> str:
        """Return cuda when a usable GPU is present, otherwise cpu."""
        if self.requested_device:
            return self.requested_device
        try:
            import torch

            return "cuda" if torch.cuda.is_available() else "cpu"
        except Exception:
            return "cpu"

    def load(self) -> None:
        """Load the model into memory. Later calls return immediately."""
        if self.model is not None:
            return
        cache = model_dir()
        if not cache.is_dir():
            raise RuntimeError(
                f"XTTS-v2 is not downloaded at {cache}. Run install-xtts.sh first."
            )
        self.device = self._pick_device()
        _allow_xtts_unpickling()
        from TTS.api import TTS as CoquiAPI

        try:
            api = CoquiAPI(MODEL_NAME, progress_bar=False)
        except TypeError:
            api = CoquiAPI(MODEL_NAME)
        api.to(self.device)
        self.model = api.synthesizer.tts_model
        rate = getattr(api.synthesizer, "output_sample_rate", SAMPLE_RATE)
        self.sample_rate = int(rate or SAMPLE_RATE)

    def speakers(self) -> list[str]:
        """Return the names of the speakers built into the checkpoint."""
        self.load()
        manager = getattr(self.model, "speaker_manager", None)
        if manager is None:
            return []
        return sorted(manager.speakers.keys())

    def conditioning(self, speaker: str | None, speaker_wav: str | None):
        """Return the conditioning latents for a speaker name or reference clip."""
        if speaker_wav:
            reference = os.path.abspath(speaker_wav)
            if not os.path.isfile(reference):
                raise RuntimeError(f"speaker clip not found: {reference}")
            key = ("clip", reference, os.path.getmtime(reference))
        else:
            key = ("name", speaker or DEFAULT_SPEAKER)
        cached = self.latents.get(key)
        if cached is not None:
            return cached
        if speaker_wav:
            gpt, embedding = self.model.get_conditioning_latents(
                audio_path=[os.path.abspath(speaker_wav)]
            )
        else:
            manager = getattr(self.model, "speaker_manager", None)
            name = speaker or DEFAULT_SPEAKER
            if manager is None or name not in manager.speakers:
                raise RuntimeError(f"unknown speaker: {name}")
            entry = manager.speakers[name]
            gpt = entry["gpt_cond_latent"]
            embedding = entry["speaker_embedding"]
        gpt = gpt.to(self.device)
        embedding = embedding.to(self.device)
        self.latents[key] = (gpt, embedding)
        return gpt, embedding

    def synthesize(
        self,
        text: str,
        out: str,
        speaker: str | None = None,
        speaker_wav: str | None = None,
        language: str = DEFAULT_LANGUAGE,
        speed: float = 1.0,
    ) -> int:
        """Synthesize text to a wav file and return the number of chunks used."""
        import numpy as np

        self.load()
        gpt, embedding = self.conditioning(speaker, speaker_wav)
        chunks = split_text(text)
        if not chunks:
            raise RuntimeError("nothing to speak")
        gap = np.zeros(int(self.sample_rate * GAP_SECONDS), dtype=np.float32)
        pieces = []
        last = len(chunks) - 1
        for index, chunk in enumerate(chunks):
            result = self.model.inference(
                text=chunk,
                language=language,
                gpt_cond_latent=gpt,
                speaker_embedding=embedding,
                speed=speed,
                enable_text_splitting=False,
            )
            pieces.append(np.asarray(result["wav"], dtype=np.float32).reshape(-1))
            if index != last:
                pieces.append(gap)
        write_wav(out, np.concatenate(pieces), self.sample_rate)
        return len(chunks)


def _reply(stream, payload: dict) -> None:
    """Write one JSON response line and flush it."""
    stream.write((json.dumps(payload) + "\n").encode("utf-8"))
    stream.flush()


def _handle(conn, engine: Engine, state: dict) -> None:
    """Read one request from a connection and answer it."""
    with conn.makefile("rwb") as stream:
        line = stream.readline()
        if not line:
            return
        try:
            request = json.loads(line.decode("utf-8"))
        except ValueError as exc:
            _reply(stream, {"ok": False, "error": f"bad request: {exc}"})
            return
        op = request.get("op", "synthesize")
        try:
            if op == "ping":
                _reply(
                    stream,
                    {
                        "ok": True,
                        "loaded": engine.model is not None,
                        "device": engine.device,
                        "model": MODEL_NAME,
                    },
                )
            elif op == "preload":
                engine.load()
                _reply(stream, {"ok": True, "device": engine.device})
            elif op == "speakers":
                _reply(stream, {"ok": True, "speakers": engine.speakers()})
            elif op == "shutdown":
                state["stop"] = True
                _reply(stream, {"ok": True})
            elif op == "synthesize":
                text = request.get("text") or ""
                if not text.strip():
                    raise RuntimeError("no text to speak")
                out = request.get("out") or str(state_dir() / "speech.wav")
                started = time.time()
                count = engine.synthesize(
                    text=text,
                    out=out,
                    speaker=request.get("speaker"),
                    speaker_wav=request.get("speaker_wav"),
                    language=request.get("language") or DEFAULT_LANGUAGE,
                    speed=float(request.get("speed") or 1.0),
                )
                _reply(
                    stream,
                    {
                        "ok": True,
                        "out": out,
                        "chunks": count,
                        "seconds": round(time.time() - started, 2),
                        "device": engine.device,
                        "rate": engine.sample_rate,
                    },
                )
            else:
                _reply(stream, {"ok": False, "error": f"unknown op: {op}"})
        except Exception as exc:
            _reply(stream, {"ok": False, "error": f"{type(exc).__name__}: {exc}"})


def _reaper(server: socket.socket, path: Path, state: dict) -> None:
    """Close the listening socket once the daemon has been idle long enough."""
    limit = idle_timeout()
    if limit <= 0:
        return
    while not state["stop"]:
        time.sleep(5.0)
        if state["busy"]:
            continue
        if time.time() - state["last"] > limit:
            state["stop"] = True
            try:
                server.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            server.close()
            return


def serve(args) -> int:
    """Run the daemon until it is told to stop or goes idle."""
    path = Path(args.socket)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(2.0)
        try:
            probe.connect(str(path))
            probe.close()
            print("talk-xtts: daemon already running", file=sys.stderr)
            return 1
        except OSError:
            probe.close()
            path.unlink()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    os.chmod(path, 0o600)
    server.listen(4)
    engine = Engine(args.device)
    state = {"last": time.time(), "stop": False, "busy": False}
    threading.Thread(target=_reaper, args=(server, path, state), daemon=True).start()
    if args.preload:
        try:
            engine.load()
        except Exception as exc:
            print(f"talk-xtts: preload failed: {exc}", file=sys.stderr)
        state["last"] = time.time()
    while not state["stop"]:
        try:
            conn, _ = server.accept()
        except OSError:
            break
        state["busy"] = True
        try:
            with conn:
                _handle(conn, engine, state)
        finally:
            state["busy"] = False
            state["last"] = time.time()
    try:
        server.close()
    except OSError:
        pass
    if path.exists():
        try:
            path.unlink()
        except OSError:
            pass
    return 0


def talk(sock: Path, payload: dict, timeout: float = REQUEST_TIMEOUT) -> dict:
    """Send one request to the daemon and return its response."""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(str(sock))
    with conn, conn.makefile("rwb") as stream:
        stream.write((json.dumps(payload) + "\n").encode("utf-8"))
        stream.flush()
        line = stream.readline()
    if not line:
        raise RuntimeError("the daemon closed the connection")
    return json.loads(line.decode("utf-8"))


def daemon_command(socket_path: str, device: str | None = None) -> list[str]:
    """Return the argv that starts the daemon.

    The socket is a top level option and has to precede the subcommand, while
    the device belongs to the subcommand and has to follow it.
    """
    command = [sys.executable, os.path.abspath(__file__), "--socket", str(socket_path), "serve"]
    if device:
        command += ["--device", device]
    return command


def spawn(args) -> None:
    """Start the daemon as a detached background process."""
    log = open(state_dir() / "xtts.log", "ab")
    command = daemon_command(args.socket, args.device)
    subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
        close_fds=True,
    )


def ensure_daemon(args) -> None:
    """Make sure the daemon is listening, starting it when it is not."""
    sock = Path(args.socket)
    try:
        talk(sock, {"op": "ping"}, timeout=5.0)
        return
    except (OSError, RuntimeError, ValueError):
        pass
    spawn(args)
    deadline = time.time() + START_TIMEOUT
    while time.time() < deadline:
        time.sleep(0.2)
        try:
            talk(sock, {"op": "ping"}, timeout=5.0)
            return
        except (OSError, RuntimeError, ValueError):
            continue
    raise RuntimeError(f"the daemon did not start; see {state_dir() / 'xtts.log'}")


def _read_text(args) -> str:
    """Return the text to speak from a file or from the command line."""
    if args.text_file:
        return Path(args.text_file).read_text(encoding="utf-8")
    return args.text or ""


def say(args) -> int:
    """Synthesize text and print the path of the wav file that was written."""
    text = _read_text(args)
    if not text.strip():
        print("talk-xtts: no text to speak", file=sys.stderr)
        return 1
    out = args.out or str(state_dir() / "speech.wav")
    ensure_daemon(args)
    reply = talk(
        Path(args.socket),
        {
            "op": "synthesize",
            "text": text,
            "out": out,
            "speaker": args.speaker,
            "speaker_wav": args.speaker_wav,
            "language": args.language,
            "speed": args.speed,
        },
    )
    if not reply.get("ok"):
        print(f"talk-xtts: {reply.get('error', 'synthesis failed')}", file=sys.stderr)
        return 1
    print(reply["out"])
    return 0


def speakers(args) -> int:
    """Print every built-in speaker name, one per line."""
    ensure_daemon(args)
    reply = talk(Path(args.socket), {"op": "speakers"})
    if not reply.get("ok"):
        print(f"talk-xtts: {reply.get('error', 'failed')}", file=sys.stderr)
        return 1
    for name in reply.get("speakers", []):
        print(name)
    return 0


def status(args) -> int:
    """Print whether the model is downloaded and whether the daemon is up."""
    cache = model_dir()
    print(f"model:      {MODEL_NAME}")
    print(f"cache:      {cache}  {'present' if cache.is_dir() else 'MISSING'}")
    print(f"socket:     {args.socket}")
    print(f"python:     {sys.executable}")
    try:
        import torch

        device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"torch:      {torch.__version__}  device: {device}")
    except Exception as exc:
        print(f"torch:      MISSING ({type(exc).__name__})")
    try:
        import TTS

        print(f"coqui-tts:  {getattr(TTS, '__version__', 'unknown')}")
    except Exception:
        print("coqui-tts:  MISSING")
    try:
        reply = talk(Path(args.socket), {"op": "ping"}, timeout=5.0)
        print(f"daemon:     running  loaded: {reply.get('loaded')}  device: {reply.get('device')}")
    except OSError:
        print("daemon:     not running")
    return 0


def stop(args) -> int:
    """Shut the daemon down if it is running."""
    try:
        talk(Path(args.socket), {"op": "shutdown"}, timeout=10.0)
        print("daemon stopped")
    except OSError:
        print("daemon not running")
    return 0


def preload(args) -> int:
    """Start the daemon and load the model so the next request is fast."""
    ensure_daemon(args)
    reply = talk(Path(args.socket), {"op": "preload"})
    if not reply.get("ok"):
        print(f"talk-xtts: {reply.get('error', 'failed')}", file=sys.stderr)
        return 1
    print(f"model loaded on {reply.get('device')}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Return the command line parser for every mode."""
    parser = argparse.ArgumentParser(prog="talk-xtts", description=__doc__)
    parser.add_argument("--socket", default=str(default_socket()))
    sub = parser.add_subparsers(dest="mode", required=True)

    serve_cmd = sub.add_parser("serve", help="run the daemon")
    serve_cmd.add_argument("--device", default=os.environ.get("TALK_XTTS_DEVICE") or None)
    serve_cmd.add_argument("--preload", action="store_true")
    serve_cmd.set_defaults(func=serve)

    say_cmd = sub.add_parser("say", help="synthesize text to a wav file")
    say_cmd.add_argument("--text")
    say_cmd.add_argument("--text-file")
    say_cmd.add_argument("--out")
    say_cmd.add_argument("--speaker", default=os.environ.get("TALK_XTTS_VOICE") or DEFAULT_SPEAKER)
    say_cmd.add_argument("--speaker-wav", default=os.environ.get("TALK_XTTS_SPEAKER_WAV") or None)
    say_cmd.add_argument("--language", default=os.environ.get("TALK_XTTS_LANG") or DEFAULT_LANGUAGE)
    say_cmd.add_argument("--speed", type=float, default=1.0)
    say_cmd.add_argument("--device", default=os.environ.get("TALK_XTTS_DEVICE") or None)
    say_cmd.set_defaults(func=say)

    speakers_cmd = sub.add_parser("speakers", help="list the built-in speakers")
    speakers_cmd.add_argument("--device", default=os.environ.get("TALK_XTTS_DEVICE") or None)
    speakers_cmd.set_defaults(func=speakers)

    preload_cmd = sub.add_parser("preload", help="load the model now")
    preload_cmd.add_argument("--device", default=os.environ.get("TALK_XTTS_DEVICE") or None)
    preload_cmd.set_defaults(func=preload)

    status_cmd = sub.add_parser("status", help="print daemon and model state")
    status_cmd.set_defaults(func=status)

    stop_cmd = sub.add_parser("stop", help="shut the daemon down")
    stop_cmd.set_defaults(func=stop)

    return parser


def main(argv: list[str] | None = None) -> int:
    """Parse arguments and run the chosen mode."""
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"talk-xtts: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
