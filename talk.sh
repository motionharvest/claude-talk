#!/usr/bin/env bash
# claude-talk — speak Claude Code's last response aloud.
# https://github.com/motionharvest/claude-talk
#
# Usage:
#   talk.sh                 speak the last response
#   talk.sh stop            stop playback
#   talk.sh --print         print what would be spoken, don't speak
#   talk.sh --engine NAME   auto | google | edge
#   talk.sh --voice NAME    use a different voice for this run
#   talk.sh --lang CODE     language code for this run (google only)
#   talk.sh --rate +30%     speed up / slow down for this run
#   talk.sh --key-file F    read the Google API key from F for this run
#   talk.sh --list-voices   list available voices
#   talk.sh --check-key     verify the Google API key works
#   talk.sh --doctor        check dependencies and audio setup
#
# Engines:
#   google  Google Cloud Text-to-Speech. Needs an API key and a network.
#           Streams: the first sentence plays while the rest is still being
#           synthesized. Billed per character.
#   edge    Microsoft's cloud voices through edge-tts. Free, no key, no
#           streaming.
#   auto    google when an API key is configured, edge otherwise.
#
# The Google API key is read from TALK_GOOGLE_KEY, or from a file — by default
# ~/.config/claude-talk/google-api-key. It is never passed on a command line.
#
# Config: environment variables, or ~/.config/claude-talk/config (shell syntax)
#   TALK_ENGINE            default auto
#   TALK_VOICE             default en-US-AriaNeural   edge voice name
#   TALK_GOOGLE_VOICE      default en-US-Neural2-F    google voice name
#   TALK_GOOGLE_KEY        the API key itself
#   TALK_GOOGLE_KEY_FILE   default ~/.config/claude-talk/google-api-key
#   TALK_GOOGLE_LANG       default: the voice name's own language
#   TALK_GOOGLE_SPEED      overrides TALK_RATE for google; 1.0 is normal
#   TALK_GOOGLE_PITCH      default 0        semitones, -20 to 20
#   TALK_GOOGLE_GAIN       default 0        volume in dB, -96 to 16
#   TALK_GOOGLE_PROFILE    audio effects profile, e.g. headphone-class-device
#   TALK_GOOGLE_JOBS       default 4        parallel synthesis requests
#   TALK_GOOGLE_ENCODING   default MP3      MP3 | OGG_OPUS | LINEAR16
#   TALK_GOOGLE_CHUNK      default 700      chars per request after the first
#   TALK_GOOGLE_FIRST_CHUNK default 180     chars in the opening chunk
#   TALK_GOOGLE_TIMEOUT    default 60       seconds per synthesis request
#   TALK_GOOGLE_WAIT       default 60       seconds to wait for the first chunk
#   TALK_STREAM            default 1; 0 waits for the whole file before playing
#   TALK_RATE           default +18%      e.g. +40% faster, -10% slower
#   TALK_PITCH          default +0Hz      (edge only)
#   TALK_MAXLEN         default 6000      chars before truncating
#   TALK_PLAYER         auto | windows | linux | macos
#   TALK_LATENCY_MSEC   default 200       PulseAudio buffer (Linux route)

set -uo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-talk"
CONFIG="$CONFIG_DIR/config"
[[ -f "$CONFIG" ]] && . "$CONFIG"

ENGINE="${TALK_ENGINE:-auto}"
VOICE="${TALK_VOICE:-en-US-AriaNeural}"
GOOGLE_VOICE="${TALK_GOOGLE_VOICE:-en-US-Neural2-F}"
GOOGLE_KEY_FILE="${TALK_GOOGLE_KEY_FILE:-$CONFIG_DIR/google-api-key}"
GOOGLE_LANG="${TALK_GOOGLE_LANG:-}"
GOOGLE_SPEED="${TALK_GOOGLE_SPEED:-}"
GOOGLE_PITCH="${TALK_GOOGLE_PITCH:-0}"
GOOGLE_GAIN="${TALK_GOOGLE_GAIN:-0}"
GOOGLE_PROFILE="${TALK_GOOGLE_PROFILE:-}"
GOOGLE_JOBS="${TALK_GOOGLE_JOBS:-4}"
GOOGLE_ENCODING="${TALK_GOOGLE_ENCODING:-MP3}"
GOOGLE_CHUNK="${TALK_GOOGLE_CHUNK:-700}"
GOOGLE_FIRST_CHUNK="${TALK_GOOGLE_FIRST_CHUNK:-180}"
GOOGLE_TIMEOUT="${TALK_GOOGLE_TIMEOUT:-60}"
RATE="${TALK_RATE:-+18%}"
PITCH="${TALK_PITCH:-+0Hz}"
MAXLEN="${TALK_MAXLEN:-6000}"
PLAYER="${TALK_PLAYER:-auto}"

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
STREAM="${TALK_STREAM:-1}"
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-talk"
STREAMDIR="$STATE_DIR/stream"
READYDIR="$STATE_DIR/ready"
PIDFILE="$STATE_DIR/play.pid"
AUDIO="$STATE_DIR/speech.mp3"
PLAYWAV="$STATE_DIR/play.wav"
SPEAKFILE="$STATE_DIR/speak.txt"
CLIENT="$STATE_DIR/google.py"
ERRLOG="$STATE_DIR/err.log"

# The chunk file name has to match what the encoder actually produced, because
# the feeder and the macOS player both find chunks by name.
case "$GOOGLE_ENCODING" in
  OGG_OPUS) STREAM_EXT=ogg ;;
  LINEAR16) STREAM_EXT=wav ;;
  *)        STREAM_EXT=mp3 ;;
esac

PRINT_ONLY=0
VOICE_OVERRIDE=""
ENGINE_USED=""
VOICE_USED=""
DO_DOCTOR=0
DO_LIST=0
DO_CHECK=0

mkdir -p "$STATE_DIR"

have() { command -v "$1" >/dev/null 2>&1; }

# The key is never read into a shell variable — only the client process, which
# needs it to sign the request, ever sees its contents.
google_ready() { [[ -n "${TALK_GOOGLE_KEY:-}" || -s "$GOOGLE_KEY_FILE" ]]; }

active_engine() {
  case "$ENGINE" in
    google|edge) printf '%s' "$ENGINE" ;;
    auto)        google_ready && printf 'google' || printf 'edge' ;;
    *)           printf 'edge' ;;
  esac
}

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM=wsl; else PLATFORM=linux; fi ;;
  *)      PLATFORM=linux ;;
esac

stop_playback() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      kill -- "-$pid" 2>/dev/null
      kill "$pid" 2>/dev/null
    done < "$PIDFILE"
    rm -f "$PIDFILE"
  fi
  # Anchored on the player binary so this can never match the shell running it.
  local p
  for p in ffplay mpv paplay pw-play afplay aplay mpg123; do
    pkill -f "^([^ ]*/)?$p .*claude-talk" 2>/dev/null
  done
  # WSL interop shows the Windows player as "/init /mnt/c/.../powershell.exe ..."
  pkill -f "^(/init )?([^ ]*/)?powershell\.exe .*claude-talk" 2>/dev/null
  return 0
}

# --- streaming playback ----------------------------------------------------
# The synthesis client drops finished chunks into a directory as NNN.<ext> and
# writes END after the last one. A feeder converts each chunk to the sink's
# format and a single long lived player walks the sequence, so there is no
# process start between chunks and no gap the ear can hear.
stream_feed() {
  local src="$1" dst="$2" rate="$3" ch="$4" ext="$5" i=0 f out
  while :; do
    f=$(printf '%s/%03d.%s' "$src" "$i" "$ext")
    if [[ -f "$f" ]]; then
      out=$(printf '%s/%03d' "$dst" "$i")
      ffmpeg -y -loglevel error -i "$f" \
        -af "aresample=resampler=soxr:precision=28:osf=s16" \
        -ar "$rate" -ac "$ch" -c:a pcm_s16le -f wav "$out.part" 2>/dev/null \
        && mv -f "$out.part" "$out.wav"
      i=$((i + 1))
    elif [[ -f "$src/END" || -f "$src/ERR" ]]; then
      : > "$dst/END"
      return 0
    else
      sleep 0.05
    fi
  done
}

stream_play_seq() {
  local dir="$1" player="$2" ext="${3:-wav}" i=0 f
  export PULSE_LATENCY_MSEC="${TALK_LATENCY_MSEC:-200}"
  while :; do
    f=$(printf '%s/%03d.%s' "$dir" "$i" "$ext")
    if [[ -f "$f" ]]; then
      "$player" "$f" >/dev/null 2>&1
      i=$((i + 1))
    elif [[ -f "$dir/END" || -f "$dir/ERR" ]]; then
      return 0
    else
      sleep 0.05
    fi
  done
}

stream_play_windows() {
  powershell.exe -NoProfile -Command "
\$dir = '$1'
\$i = 0
while (\$true) {
  \$f = Join-Path \$dir ('{0:D3}.wav' -f \$i)
  if (Test-Path \$f) { (New-Object Media.SoundPlayer \$f).PlaySync(); \$i++ }
  elseif (Test-Path (Join-Path \$dir 'END')) { break }
  else { Start-Sleep -Milliseconds 50 }
}" >/dev/null 2>&1
}

# Asking Windows for its temp directory costs a third of a second and the
# answer never changes, so it is cached for the life of the runtime directory.
win_tmp() {
  local cache="$STATE_DIR/wintmp" answer
  if [[ -s "$cache" ]]; then cat "$cache"; return 0; fi
  answer=$(powershell.exe -NoProfile -Command '$env:TEMP' 2>/dev/null | tr -d '\r')
  [[ -n "$answer" ]] || return 1
  printf '%s' "$answer" > "$cache"
  printf '%s' "$answer"
}

clear_dir() {
  mkdir -p "$1" || return 1
  rm -f "$1"/*.wav "$1"/*.mp3 "$1"/*.part "$1/END" "$1/ERR" 2>/dev/null
  return 0
}

sink_format() {
  local spec rate ch
  spec=$(pactl info 2>/dev/null | sed -n 's/^Default Sample Specification:[[:space:]]*//p')
  rate=$(grep -oE '[0-9]+Hz' <<<"$spec" | tr -d 'Hz')
  ch=$(grep -oE '[0-9]+ch' <<<"$spec" | tr -d 'ch')
  printf '%s %s' "${rate:-48000}" "${ch:-2}"
}

stream_start_pulse() {
  local rate ch player
  have ffmpeg || return 1
  if   have pw-play; then player=pw-play
  elif have paplay;  then player=paplay
  else return 1
  fi
  read -r rate ch < <(sink_format)
  clear_dir "$READYDIR" || return 1
  bg bash "$SELF" --stream-feed "$STREAMDIR" "$READYDIR" "$rate" "$ch" "$STREAM_EXT"
  bg bash "$SELF" --stream-play-seq "$READYDIR" "$player" wav
}

stream_start_windows() {
  local windir lindir
  have ffmpeg && have wslpath || return 1
  windir=$(win_tmp) || return 1
  lindir="$(wslpath -u "$windir")/claude-talk-stream"
  clear_dir "$lindir" || return 1
  bg bash "$SELF" --stream-feed "$STREAMDIR" "$lindir" 48000 1 "$STREAM_EXT"
  bg bash "$SELF" --stream-play-windows "$windir\\claude-talk-stream"
}

# afplay decodes mp3 itself, so the macOS route plays the chunks as they land
# and never needs ffmpeg at all.
stream_start_macos() {
  have afplay || return 1
  bg bash "$SELF" --stream-play-seq "$STREAMDIR" afplay "$STREAM_EXT"
}

stream_start() {
  case "$PLAYER" in
    windows) stream_start_windows; return $? ;;
    macos)   stream_start_macos;   return $? ;;
    linux)   stream_start_pulse;   return $? ;;
  esac
  case "$PLATFORM" in
    macos) stream_start_macos && return 0 ;;
    wsl)   stream_start_windows && return 0 ;;
  esac
  stream_start_pulse
}

doctor() {
  local engine; engine=$(active_engine)
  echo "platform:   $PLATFORM"
  echo "player:     $PLAYER"
  echo "engine:     $ENGINE -> $engine   streaming: $STREAM"
  echo "rate:       $RATE   pitch: $PITCH   maxlen: $MAXLEN"
  echo
  echo "edge voice: $VOICE"
  echo "gcp voice:  $GOOGLE_VOICE   lang: ${GOOGLE_LANG:-from voice name}"
  if [[ -n "${TALK_GOOGLE_KEY:-}" ]]; then
    echo "gcp key:    set in TALK_GOOGLE_KEY"
  elif [[ -s "$GOOGLE_KEY_FILE" ]]; then
    echo "gcp key:    $GOOGLE_KEY_FILE ($(stat -c '%a' "$GOOGLE_KEY_FILE" 2>/dev/null || stat -f '%Lp' "$GOOGLE_KEY_FILE" 2>/dev/null))"
  else
    echo "gcp key:    NOT SET — see README, or set TALK_GOOGLE_KEY"
  fi
  if google_ready; then
    echo -n "gcp status: "
    google_client check 2>&1 | head -2
  fi
  echo
  for c in jq python3 edge-tts ffmpeg; do
    printf '%-12s %s\n' "$c" "$(have "$c" && command -v "$c" || echo 'MISSING')"
  done
  for c in afplay paplay pw-play ffplay mpv powershell.exe; do
    have "$c" && printf '%-12s %s\n' "$c" "$(command -v "$c")"
  done
  if have pactl; then
    echo
    pactl info 2>/dev/null | sed -n 's/^Default Sample Specification: /sink format: /p'
  fi
  echo
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  if [[ -n "$sid" ]]; then
    echo "session:    $sid"
    local f; f=$(find_transcript)
    echo "transcript: ${f:-NOT FOUND}"
  else
    echo "session:    CLAUDE_CODE_SESSION_ID unset (run this through /talk, not directly)"
  fi
}

find_transcript() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" f
  if [[ -n "$sid" ]]; then
    for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do
      [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
  fi
  local slug; slug=$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')
  f=$(ls -t "$HOME/.claude/projects/$slug"/*.jsonl 2>/dev/null | head -1)
  [[ -n "$f" ]] && printf '%s' "$f"
}

# --- google cloud text-to-speech client ------------------------------------
# Written out at run time rather than installed, so /talk stays two files. It
# does the sentence splitting, the parallel HTTP, and the base64 decode in one
# process; there is no daemon and nothing to warm up.
write_google_client() {
  cat > "$CLIENT.part" <<'PY'
#!/usr/bin/env python3
"""Google Cloud Text-to-Speech client for claude-talk.

Modes:
    stream <outdir>   synthesize into NNN.<ext>, in order, then touch END
    single <outfile>  synthesize the whole text into one audio file
    voices            print every voice the key can reach
    check             verify the key and print the voice count

Everything else arrives in the environment, so the API key is never visible
in the process list.
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DEFAULT_API = "https://texttospeech.googleapis.com/v1"
RETRY_CODES = {408, 429, 500, 502, 503, 504}
RETRIES = 3

# Sentences first, clauses when a sentence is too long, words as a last resort.
_SENTENCE = re.compile(r"(?<=[.!?])\s+|\n+")
_CLAUSE = re.compile(r"(?<=[;:,])\s+")


class Failure(Exception):
    """An error worth showing the user verbatim."""


def setting(name: str, default: str = "") -> str:
    return os.environ.get(name, "").strip() or default


def number(name: str, default: float) -> float:
    try:
        return float(setting(name, str(default)))
    except ValueError:
        return default


def api_key() -> str:
    key = os.environ.get("TALK_GOOGLE_KEY", "").strip()
    if key:
        return key
    path = setting("TALK_GOOGLE_KEY_FILE")
    if path and Path(path).is_file():
        return Path(path).read_text(encoding="utf-8").strip()
    raise Failure(
        "no Google API key — put one in "
        f"{path or '~/.config/claude-talk/google-api-key'} or set TALK_GOOGLE_KEY"
    )


API = setting("TALK_GOOGLE_API", DEFAULT_API).rstrip("/")
VOICE = setting("TALK_GOOGLE_VOICE", "en-US-Neural2-F")
LANGUAGE = setting("TALK_GOOGLE_LANG") or "-".join(VOICE.split("-")[:2])
SPEED = min(max(number("TALK_GOOGLE_SPEED", 1.0), 0.25), 4.0)
PITCH = min(max(number("TALK_GOOGLE_PITCH", 0.0), -20.0), 20.0)
GAIN = min(max(number("TALK_GOOGLE_GAIN", 0.0), -96.0), 16.0)
PROFILE = setting("TALK_GOOGLE_PROFILE")
ENCODING = setting("TALK_GOOGLE_ENCODING", "MP3")
EXTENSION = setting("TALK_GOOGLE_EXT", "mp3")
JOBS = max(int(number("TALK_GOOGLE_JOBS", 4)), 1)
TIMEOUT = number("TALK_GOOGLE_TIMEOUT", 60.0)
CHUNK_LIMIT = int(number("TALK_GOOGLE_CHUNK", 700))
FIRST_LIMIT = int(number("TALK_GOOGLE_FIRST_CHUNK", 180))

# Chirp and Studio voices reject speakingRate and pitch. The first rejection
# turns them off for the rest of the run rather than being predicted from the
# voice name, which would go stale every time Google ships a tier.
_prosody = True


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


def _pieces(text: str, limit: int) -> list[str]:
    """Return the atomic pieces of text, none longer than limit.

    Whole sentences come first. A sentence too long for one request falls back
    to clause breaks, and a clause still too long falls back to word breaks. So
    a chunk ends mid sentence only when one sentence on its own exceeds limit.
    """
    out: list[str] = []
    for sentence in (p.strip() for p in _SENTENCE.split(text)):
        if not sentence:
            continue
        if len(sentence) <= limit:
            out.append(sentence)
            continue
        for clause in (c.strip() for c in _CLAUSE.split(sentence)):
            if not clause:
                continue
            out.extend(_wrap(clause, limit) if len(clause) > limit else [clause])
    return out


def split_text(text: str, limit: int, first_limit: int) -> list[str]:
    """Split text into chunks, with a shorter opening chunk.

    Streaming playback waits on the first chunk before any sound starts, so it
    is capped well below the rest. The remaining chunks are synthesized in
    parallel and land long before the opening one has finished playing, so
    there is no floor to protect against the player running dry.
    """
    chunks: list[str] = []
    current = ""
    for piece in _pieces(text, limit):
        if not current:
            current = piece
            continue
        cap = limit if chunks else first_limit
        if len(current) + 1 + len(piece) <= cap:
            current = f"{current} {piece}"
        else:
            chunks.append(current)
            current = piece
    if current:
        chunks.append(current)
    return chunks


def message_of(error: urllib.error.HTTPError) -> str:
    try:
        return json.loads(error.read().decode("utf-8"))["error"]["message"]
    except Exception:
        return f"HTTP {error.code}"


def call(path: str, body: dict | None = None) -> dict:
    headers = {"X-Goog-Api-Key": KEY}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(f"{API}/{path}", data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)


def audio_config() -> dict:
    config = {"audioEncoding": ENCODING}
    if _prosody:
        config["speakingRate"] = SPEED
        config["pitch"] = PITCH
        config["volumeGainDb"] = GAIN
    if PROFILE:
        config["effectsProfileId"] = [PROFILE]
    return config


def synthesize(text: str) -> bytes:
    global _prosody
    delay = 0.5
    for attempt in range(RETRIES + 1):
        body = {
            "input": {"text": text},
            "voice": {"languageCode": LANGUAGE, "name": VOICE},
            "audioConfig": audio_config(),
        }
        try:
            return base64.b64decode(call("text:synthesize", body)["audioContent"])
        except urllib.error.HTTPError as error:
            text_of_error = message_of(error)
            lowered = text_of_error.lower()
            if _prosody and error.code == 400 and any(
                word in lowered for word in ("pitch", "rate", "volume")
            ):
                _prosody = False
                continue
            if error.code in RETRY_CODES and attempt < RETRIES:
                time.sleep(delay)
                delay *= 2
                continue
            raise Failure(text_of_error) from None
        except urllib.error.URLError as error:
            if attempt < RETRIES:
                time.sleep(delay)
                delay *= 2
                continue
            raise Failure(f"could not reach Google Cloud: {error.reason}") from None
    raise Failure("synthesis failed")


def read_text() -> str:
    path = setting("TALK_SPEAKFILE")
    if not path:
        raise Failure("TALK_SPEAKFILE is not set")
    return Path(path).read_text(encoding="utf-8")


def write_atomically(path: Path, data: bytes) -> None:
    partial = path.with_name(path.name + ".part")
    partial.write_bytes(data)
    os.replace(partial, path)


def stream(outdir: str) -> None:
    directory = Path(outdir)
    directory.mkdir(parents=True, exist_ok=True)
    for stale in directory.iterdir():
        if stale.is_file():
            try:
                stale.unlink()
            except OSError:
                pass

    chunks = split_text(read_text(), CHUNK_LIMIT, FIRST_LIMIT)
    try:
        with ThreadPoolExecutor(max_workers=JOBS) as pool:
            for index, audio in enumerate(pool.map(synthesize, chunks)):
                write_atomically(directory / f"{index:03d}.{EXTENSION}", audio)
    except Exception:
        # Without this marker the player would sit through its whole timeout
        # waiting for a first chunk that is never coming.
        (directory / "ERR").touch()
        raise
    (directory / "END").touch()


def single(outfile: str) -> None:
    chunks = split_text(read_text(), CHUNK_LIMIT, CHUNK_LIMIT)
    with ThreadPoolExecutor(max_workers=JOBS) as pool:
        audio = b"".join(pool.map(synthesize, chunks))
    write_atomically(Path(outfile), audio)


def voices() -> None:
    for voice in sorted(call("voices").get("voices", []), key=lambda v: v["name"]):
        print(
            f'{voice["name"]}\t{",".join(voice.get("languageCodes", []))}'
            f'\t{voice.get("ssmlGender", "")}'
        )


def check() -> None:
    found = call(f"voices?{urllib.parse.urlencode({'languageCode': LANGUAGE})}")
    count = len(found.get("voices", []))
    print(f'key works — {count} voice{"" if count == 1 else "s"} for {LANGUAGE}')


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    try:
        KEY = api_key()
        if mode == "stream":
            stream(sys.argv[2])
        elif mode == "single":
            single(sys.argv[2])
        elif mode == "voices":
            voices()
        elif mode == "check":
            check()
        else:
            raise Failure(f"unknown mode {mode}")
    except Failure as failure:
        print(f"talk: {failure}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.HTTPError as error:
        print(f"talk: {message_of(error)}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as error:
        print(f"talk: could not reach Google Cloud: {error.reason}", file=sys.stderr)
        sys.exit(1)
PY
  chmod 700 "$CLIENT.part" && mv -f "$CLIENT.part" "$CLIENT"
}

# The key travels in the environment, which only this user can read. A command
# line argument would be readable by everyone on the machine.
google_env() {
  export TALK_GOOGLE_KEY="${TALK_GOOGLE_KEY:-}"
  export TALK_GOOGLE_KEY_FILE="$GOOGLE_KEY_FILE"
  export TALK_GOOGLE_VOICE="${VOICE_OVERRIDE:-$GOOGLE_VOICE}"
  export TALK_GOOGLE_LANG="$GOOGLE_LANG"
  export TALK_GOOGLE_SPEED="${GOOGLE_SPEED:-$(rate_to_speed)}"
  export TALK_GOOGLE_PITCH="$GOOGLE_PITCH"
  export TALK_GOOGLE_GAIN="$GOOGLE_GAIN"
  export TALK_GOOGLE_PROFILE="$GOOGLE_PROFILE"
  export TALK_GOOGLE_JOBS="$GOOGLE_JOBS"
  export TALK_GOOGLE_ENCODING="$GOOGLE_ENCODING"
  export TALK_GOOGLE_EXT="$STREAM_EXT"
  export TALK_GOOGLE_CHUNK="$GOOGLE_CHUNK"
  export TALK_GOOGLE_FIRST_CHUNK="$GOOGLE_FIRST_CHUNK"
  export TALK_GOOGLE_TIMEOUT="$GOOGLE_TIMEOUT"
  export TALK_SPEAKFILE="$SPEAKFILE"
  [[ -n "${TALK_GOOGLE_API:-}" ]] && export TALK_GOOGLE_API
  return 0
}

google_client()    { write_google_client && google_env && python3 "$CLIENT" "$@"; }
google_client_bg() { write_google_client && google_env && bg python3 "$CLIENT" "$@"; }

# Internal entry points. The streaming loops run as detached background jobs,
# and re-entering this same file keeps them in one place instead of a second
# installed script.
case "${1:-}" in
  --stream-feed)          shift; stream_feed "$@";          exit $? ;;
  --stream-play-seq)      shift; stream_play_seq "$@";      exit $? ;;
  --stream-play-windows)  shift; stream_play_windows "$@";  exit $? ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    stop|--stop)   stop_playback; echo "Playback stopped."; exit 0 ;;
    --print)       PRINT_ONLY=1; shift ;;
    --engine)      ENGINE="${2:-$ENGINE}"; shift 2 ;;
    --voice)       VOICE_OVERRIDE="${2:-}"; VOICE="${2:-$VOICE}"; shift 2 ;;
    --lang)        GOOGLE_LANG="${2:-$GOOGLE_LANG}"; shift 2 ;;
    --key-file)    GOOGLE_KEY_FILE="${2:-$GOOGLE_KEY_FILE}"; shift 2 ;;
    --rate)        RATE="${2:-$RATE}"; shift 2 ;;
    --speed)       GOOGLE_SPEED="${2:-$GOOGLE_SPEED}"; shift 2 ;;
    --pitch)       PITCH="${2:-$PITCH}"; shift 2 ;;
    --player)      PLAYER="${2:-$PLAYER}"; shift 2 ;;
    --list-voices) DO_LIST=1; shift ;;
    --check-key)   DO_CHECK=1; shift ;;
    --doctor)      DO_DOCTOR=1; shift ;;
    -h|--help)     awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    *)             shift ;;
  esac
done

case "$ENGINE" in
  auto|google|edge) ;;
  *) echo "talk: unknown engine '$ENGINE' — use auto, google or edge" >&2; exit 1 ;;
esac

# --- synthesize ------------------------------------------------------------
# TALK_RATE is an edge-tts percentage. Google takes a speaking rate multiplier
# instead, so "+18%" becomes 1.18 and the one config knob drives both engines.
rate_to_speed() {
  local raw="${RATE//[%+[:space:]]/}"
  [[ -n "$raw" ]] || raw=0
  awk -v r="$raw" 'BEGIN { s = 1 + r / 100; if (s < 0.25) s = 0.25; if (s > 4.0) s = 4.0; printf "%.3f", s }'
}

if [[ "$DO_DOCTOR" -eq 1 ]]; then doctor; exit 0; fi

if [[ "$DO_CHECK" -eq 1 ]]; then
  google_ready || { echo "talk: no Google API key configured — see README" >&2; exit 1; }
  google_client check; exit $?
fi

if [[ "$DO_LIST" -eq 1 ]]; then
  if [[ "$(active_engine)" == google ]]; then
    google_client voices; exit $?
  fi
  have edge-tts || { echo "talk: edge-tts not found — pip install edge-tts" >&2; exit 1; }
  exec edge-tts --list-voices
fi

have jq       || { echo "talk: jq not found"      >&2; exit 1; }
have python3  || { echo "talk: python3 not found" >&2; exit 1; }
if [[ "$(active_engine)" == edge ]] && ! have edge-tts; then
  if [[ "$ENGINE" == auto ]]; then
    echo "talk: no engine available — add a Google API key (see README) or install edge-tts (pip install edge-tts)" >&2
  else
    echo "talk: edge-tts not found — pip install edge-tts" >&2
  fi
  exit 1
fi

TRANSCRIPT=$(find_transcript)
[[ -f "$TRANSCRIPT" ]] || { echo "talk: could not find session transcript" >&2; exit 1; }

# --- extract the last response --------------------------------------------
# The final response is the trailing run of assistant messages carrying text
# but no tool calls. Walking backwards and stopping at the first message with a
# tool_use skips the "let me check X" progress lines emitted between tools.
RAW=$(jq -rs '
  [ .[]
    | select((.isSidechain // false) | not)
    | if .type == "assistant" then
        { a: true,
          tool: (([ .message.content[]? | select(.type == "tool_use") ] | length) > 0),
          txt:  ([ .message.content[]? | select(.type == "text") | .text ] | join("\n\n")) }
      elif .type == "user" then { a: false, tool: false, txt: "" }
      else empty end
  ]
  | reverse as $rev
  | ( reduce $rev[] as $x ({ stop: false, acc: [] };
        if .stop then .
        elif ($x.a and ($x.tool | not)) then .acc = ([ $x.txt ] + .acc)
        else .stop = true end)
      | .acc | map(select(. != "")) | join("\n\n") ) as $final
  | if ($final | length) > 0 then $final
    else ( [ $rev[] | select(.a) | .txt | select(. != "") ] | first // "" ) end
' "$TRANSCRIPT")

[[ -n "${RAW//[[:space:]]/}" ]] || { echo "talk: no previous response found to speak" >&2; exit 1; }

# --- markdown -> speakable prose ------------------------------------------
RAWFILE="$STATE_DIR/raw.txt"
printf '%s' "$RAW" > "$RAWFILE"

TEXT=$(MAXLEN="$MAXLEN" RAWFILE="$RAWFILE" python3 <<'PY'
import os, re, unicodedata

with open(os.environ["RAWFILE"], encoding="utf-8") as fh:
    s = fh.read()

s = re.sub(r"```.*?```", " Code block omitted. ", s, flags=re.S)
s = re.sub(r"~~~.*?~~~", " Code block omitted. ", s, flags=re.S)
s = re.sub(r"^\s*\|.*\|\s*$", "", s, flags=re.M)          # tables
s = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", s)           # images
s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", s)            # links
s = re.sub(r"`([^`]*)`", r"\1", s)                        # inline code
s = re.sub(r"^\s{0,3}#{1,6}\s*", "", s, flags=re.M)       # headings
s = re.sub(r"^\s*>\s?", "", s, flags=re.M)                # quotes
s = re.sub(r"^\s*[-*+]\s+", "", s, flags=re.M)            # bullets
s = re.sub(r"^\s*\d+\.\s+", "", s, flags=re.M)            # numbered
s = re.sub(r"^\s*[-*_]{3,}\s*$", "", s, flags=re.M)       # rules
s = re.sub(r"(\*\*|__|\*|_|~~)", "", s)                   # emphasis
s = re.sub(r"<[^>]+>", "", s)                             # html

s = "".join(c for c in s if unicodedata.category(c) not in ("So", "Sk", "Cn"))
s = re.sub(r"[ \t]+", " ", s)
s = re.sub(r"\n{3,}", "\n\n", s).strip()

limit = int(os.environ.get("MAXLEN", "6000"))
if len(s) > limit:
    cut = s[:limit]
    dot = cut.rfind(". ")
    s = (cut[: dot + 1] if dot > limit * 0.5 else cut) + " ... Response truncated."

print(s)
PY
)

[[ -n "${TEXT//[[:space:]]/}" ]] || { echo "talk: nothing speakable in the last response" >&2; exit 1; }

if [[ "$PRINT_ONLY" -eq 1 ]]; then printf '%s\n' "$TEXT"; exit 0; fi

announce() {
  local words chars
  words=$(wc -w <<<"$TEXT" | tr -d ' ')
  chars=${#TEXT}
  echo "Speaking $words words / $chars characters as ${VOICE_USED} via ${ENGINE_USED}. (/talk stop to interrupt)"
}

# Each background job gets its own process group, so stopping playback can
# take down a loop together with the ffmpeg or player it is currently running.
bg() {
  if have setsid; then
    setsid nohup "$@" >/dev/null 2>>"$ERRLOG" &
  else
    nohup "$@" >/dev/null 2>>"$ERRLOG" &
  fi
  echo $! >> "$PIDFILE"
  disown 2>/dev/null
}

# --- offline fallback ------------------------------------------------------
# Both engines are network services. If neither is reachable, use a local voice
# so /talk still works offline.
speak_offline() {
  case "$PLATFORM" in
    macos)
      have say || return 1
      bg say "$TEXT"; echo "Speaking via macOS 'say' (no network engine reachable)."; return 0 ;;
    wsl)
      have powershell.exe || return 1
      local wintmp lintmp
      wintmp=$(win_tmp) || return 1
      lintmp=$(wslpath -u "$wintmp" 2>/dev/null) && [[ -d "$lintmp" ]] || return 1
      printf '%s' "$TEXT" > "$lintmp/claude-talk.txt" || return 1
      bg powershell.exe -NoProfile -Command \
        'Add-Type -AssemblyName System.Speech;
         $s = New-Object System.Speech.Synthesis.SpeechSynthesizer;
         $s.Speak([IO.File]::ReadAllText("$env:TEMP\claude-talk.txt"))'
      echo "Speaking via Windows SAPI (no network engine reachable)."; return 0 ;;
    *)
      if have spd-say;   then bg spd-say -w "$TEXT"; echo "Speaking via spd-say (no network engine reachable)."; return 0; fi
      if have espeak-ng; then bg espeak-ng "$TEXT";  echo "Speaking via espeak-ng (no network engine reachable)."; return 0; fi
      return 1 ;;
  esac
}

google_names() {
  ENGINE_USED="$1"
  VOICE_USED="${VOICE_OVERRIDE:-$GOOGLE_VOICE}"
}

# Streaming hands the first chunk to the player while the rest are still being
# fetched. The chunks after the first are synthesized in parallel, so they are
# all in hand long before the opening sentence finishes playing.
synth_google_stream() {
  [[ "$STREAM" == 1 ]] || return 1
  google_ready || return 1
  clear_dir "$STREAMDIR" || return 1
  printf '%s' "$TEXT" > "$SPEAKFILE" || return 1
  google_client_bg stream "$STREAMDIR" || return 1

  local first wait
  first=$(printf '%s/000.%s' "$STREAMDIR" "$STREAM_EXT")
  wait="${TALK_GOOGLE_WAIT:-60}"
  wait=$((SECONDS + ${wait%%.*}))
  while (( SECONDS < wait )); do
    [[ -f "$first" ]] && break
    [[ -f "$STREAMDIR/ERR" ]] && { stop_playback; return 1; }
    sleep 0.05
  done
  [[ -f "$first" ]] || { stop_playback; return 1; }

  stream_start || { stop_playback; return 1; }
  google_names "Google Cloud TTS, streaming"
  return 0
}

synth_google() {
  google_ready || return 1
  AUDIO="$STATE_DIR/speech.mp3"
  printf '%s' "$TEXT" > "$SPEAKFILE" || return 1
  google_client single "$AUDIO" 2>>"$ERRLOG" || return 1
  [[ -s "$AUDIO" ]] || return 1
  google_names "Google Cloud TTS"
  return 0
}

synth_edge() {
  have edge-tts || return 1
  AUDIO="$STATE_DIR/speech.mp3"
  timeout 120 edge-tts --voice "$VOICE" --rate "$RATE" --pitch "$PITCH" \
    --text "$TEXT" --write-media "$AUDIO" >/dev/null 2>>"$ERRLOG" || return 1
  [[ -s "$AUDIO" ]] || return 1
  ENGINE_USED="edge-tts"
  VOICE_USED="$VOICE"
  return 0
}

# Two engines failing over the same broken key would otherwise report it twice.
synthesis_failed() {
  echo "talk: synthesis failed" >&2
  tail -5 "$ERRLOG" | awk '!seen[$0]++' >&2
  exit 1
}

stop_playback
rm -f "$STATE_DIR/speech.mp3" "$STATE_DIR/speech.wav" "$PLAYWAV"
: > "$ERRLOG"

case "$(active_engine)" in
  google)
    synth_google_stream && { announce; exit 0; }
    if ! synth_google; then
      [[ "$ENGINE" == auto ]] || synthesis_failed
      synth_edge || { speak_offline && exit 0; synthesis_failed; }
    fi ;;
  edge)
    synth_edge || { speak_offline && exit 0; synthesis_failed; } ;;
esac

# --- playback --------------------------------------------------------------
# On WSL the Linux sink is WSLg's RDPSink, which streams audio to Windows over
# RDP with no buffer headroom: it starves mid-playback and crackles regardless
# of how the stream is formatted. Handing the file to Windows removes that path
# entirely. TALK_PLAYER=linux forces the PulseAudio route.
play_windows() {
  have powershell.exe && have wslpath && have ffmpeg || return 1
  local wintmp lintmp
  wintmp=$(win_tmp) || return 1
  lintmp=$(wslpath -u "$wintmp" 2>/dev/null) && [[ -d "$lintmp" ]] || return 1
  # SoundPlayer needs PCM WAV; 48 kHz is what the Windows mixer runs natively
  ffmpeg -y -loglevel error -i "$AUDIO" \
    -af "aresample=resampler=soxr:precision=28:osf=s16" \
    -ar 48000 -ac 1 -c:a pcm_s16le "$lintmp/claude-talk.wav" 2>>"$ERRLOG" || return 1
  bg powershell.exe -NoProfile -Command \
    '(New-Object Media.SoundPlayer "$env:TEMP\claude-talk.wav").PlaySync()'
}

# macOS CoreAudio plays mp3 natively and never needed any of this.
play_macos() { have afplay && bg afplay "$AUDIO"; }

# Match the sink's exact format so the sound server resamples nothing — a
# cheap inline resampler on a non-integer ratio is a classic source of clicks.
play_linux() {
  local rate ch
  read -r rate ch < <(sink_format)

  if have ffmpeg && { have paplay || have pw-play; }; then
    if ffmpeg -y -loglevel error -i "$AUDIO" \
         -af "aresample=resampler=soxr:precision=28:osf=s16" \
         -ar "$rate" -ac "$ch" -c:a pcm_s16le "$PLAYWAV" 2>>"$ERRLOG"; then
      export PULSE_LATENCY_MSEC="${TALK_LATENCY_MSEC:-200}"
      have pw-play && { bg pw-play "$PLAYWAV"; return 0; }
      bg paplay "$PLAYWAV"; return 0
    fi
  fi
  have mpv    && { bg mpv --no-video --really-quiet "$AUDIO"; return 0; }
  have ffplay && { bg ffplay -nodisp -autoexit -loglevel quiet "$AUDIO"; return 0; }
  [[ "$AUDIO" == *.mp3 ]] && have mpg123 && { bg mpg123 -q "$AUDIO"; return 0; }
  return 1
}

case "$PLAYER" in
  windows) play_windows && { announce; exit 0; } ;;
  macos)   play_macos   && { announce; exit 0; } ;;
  linux)   play_linux   && { announce; exit 0; } ;;
  auto)
    case "$PLATFORM" in
      macos) play_macos   && { announce; exit 0; } ;;
      wsl)   play_windows && { announce; exit 0; } ;;
    esac
    play_linux && { announce; exit 0; } ;;
esac

echo "talk: no working audio player found — run 'talk.sh --doctor'" >&2
exit 1
