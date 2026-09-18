#!/usr/bin/env bash
# claude-talk — speak Claude Code's last response aloud.
# https://github.com/motionharvest/claude-talk
#
# Usage:
#   talk.sh                 speak the last response
#   talk.sh stop            stop playback
#   talk.sh --print         print what would be spoken, don't speak
#   talk.sh --engine NAME   auto | xtts | edge
#   talk.sh --voice NAME    use a different voice for this run
#   talk.sh --speaker FILE  clone the voice in a wav clip (xtts only)
#   talk.sh --lang CODE     language of the text (xtts only, default en)
#   talk.sh --rate +30%     speed up / slow down for this run
#   talk.sh --warm          load the xtts model now, before you need it
#   talk.sh --list-voices   list available voices
#   talk.sh --doctor        check dependencies and audio setup
#
# Engines:
#   xtts   XTTS-v2 on this machine. No network, clonable voices, needs a GPU
#          to run faster than real time. Install it with xtts/install-xtts.sh.
#   edge   Microsoft's cloud voices through edge-tts. Needs a network.
#   auto   xtts when it is installed, edge otherwise.
#
# Config: environment variables, or ~/.config/claude-talk/config (shell syntax)
#   TALK_ENGINE            default auto
#   TALK_VOICE             default en-US-AriaNeural   edge voice name
#   TALK_XTTS_VOICE        default Claribel Dervla    built-in xtts speaker
#   TALK_XTTS_SPEAKER_WAV  6-30s wav to clone instead of a built-in speaker
#   TALK_XTTS_LANG         default en
#   TALK_XTTS_SPEED        overrides TALK_RATE for xtts; 1.0 is normal
#   TALK_XTTS_IDLE         default 900   seconds idle before the model unloads
#   TALK_XTTS_PYTHON       python of the xtts venv
#   TALK_STREAM            default 1; 0 waits for the whole file before playing
#   TALK_RATE           default +18%      e.g. +40% faster, -10% slower
#   TALK_PITCH          default +0Hz      (edge only)
#   TALK_MAXLEN         default 6000      chars before truncating
#   TALK_PLAYER         auto | windows | linux | macos
#   TALK_LATENCY_MSEC   default 200       PulseAudio buffer (Linux route)

set -uo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-talk/config"
[[ -f "$CONFIG" ]] && . "$CONFIG"

ENGINE="${TALK_ENGINE:-auto}"
VOICE="${TALK_VOICE:-en-US-AriaNeural}"
XTTS_VOICE="${TALK_XTTS_VOICE:-Claribel Dervla}"
XTTS_SPEAKER_WAV="${TALK_XTTS_SPEAKER_WAV:-}"
XTTS_LANG="${TALK_XTTS_LANG:-en}"
XTTS_SPEED="${TALK_XTTS_SPEED:-}"
RATE="${TALK_RATE:-+18%}"
PITCH="${TALK_PITCH:-+0Hz}"
MAXLEN="${TALK_MAXLEN:-6000}"
PLAYER="${TALK_PLAYER:-auto}"

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XTTS_PYTHON="${TALK_XTTS_PYTHON:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-talk/venv/bin/python}"
XTTS_SERVER="${TALK_XTTS_SERVER:-}"
if [[ -z "$XTTS_SERVER" ]]; then
  for _c in "$HOME/.claude/talk-xtts.py" "$SELF_DIR/talk-xtts.py" "$SELF_DIR/xtts/xtts_server.py"; do
    [[ -f "$_c" ]] && { XTTS_SERVER="$_c"; break; }
  done
fi

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
STREAM="${TALK_STREAM:-1}"
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-talk"
STREAMDIR="$STATE_DIR/stream"
READYDIR="$STATE_DIR/ready"
PIDFILE="$STATE_DIR/play.pid"
AUDIO="$STATE_DIR/speech.mp3"
PLAYWAV="$STATE_DIR/play.wav"
SPEAKFILE="$STATE_DIR/speak.txt"
ERRLOG="$STATE_DIR/err.log"
PRINT_ONLY=0
VOICE_OVERRIDE=""
ENGINE_USED=""
VOICE_USED=""
DO_DOCTOR=0
DO_LIST=0
DO_WARM=0

mkdir -p "$STATE_DIR"

have() { command -v "$1" >/dev/null 2>&1; }

# XTTS is usable only when both its virtualenv and its server script are present.
xtts_ready() { [[ -n "$XTTS_SERVER" && -f "$XTTS_SERVER" && -x "$XTTS_PYTHON" ]]; }

active_engine() {
  case "$ENGINE" in
    xtts|edge) printf '%s' "$ENGINE" ;;
    auto)      xtts_ready && printf 'xtts' || printf 'edge' ;;
    *)         printf 'edge' ;;
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
  # A stream keeps rendering on the GPU after the sound is cut, so tell the
  # daemon to drop it rather than leaving it to finish into a dead directory.
  if [[ "${1:-}" != "--keep-stream" ]] && xtts_ready; then
    "$XTTS_PYTHON" "$XTTS_SERVER" cancel >/dev/null 2>&1
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
# The daemon drops finished chunks into a directory as NNN.wav and writes END
# after the last one. A feeder converts each chunk to the sink's format and a
# single long lived player walks the sequence, so there is no process start
# between chunks and no gap the ear can hear.
stream_feed() {
  local src="$1" dst="$2" rate="$3" ch="$4" i=0 f out
  while :; do
    f=$(printf '%s/%03d.wav' "$src" "$i")
    if [[ -f "$f" ]]; then
      out=$(printf '%s/%03d' "$dst" "$i")
      ffmpeg -y -loglevel error -i "$f" \
        -af "aresample=resampler=soxr:precision=28:osf=s16" \
        -ar "$rate" -ac "$ch" -c:a pcm_s16le -f wav "$out.part" 2>/dev/null \
        && mv -f "$out.part" "$out.wav"
      i=$((i + 1))
    elif [[ -f "$src/END" ]]; then
      : > "$dst/END"
      return 0
    else
      sleep 0.05
    fi
  done
}

stream_play_seq() {
  local dir="$1" player="$2" i=0 f
  export PULSE_LATENCY_MSEC="${TALK_LATENCY_MSEC:-200}"
  while :; do
    f=$(printf '%s/%03d.wav' "$dir" "$i")
    if [[ -f "$f" ]]; then
      "$player" "$f" >/dev/null 2>&1
      i=$((i + 1))
    elif [[ -f "$dir/END" ]]; then
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
  rm -f "$1"/*.wav "$1"/*.part "$1/END" 2>/dev/null
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
  bg bash "$SELF" --stream-feed "$STREAMDIR" "$READYDIR" "$rate" "$ch"
  bg bash "$SELF" --stream-play-seq "$READYDIR" "$player"
}

stream_start_windows() {
  local windir lindir
  have ffmpeg && have wslpath || return 1
  windir=$(win_tmp) || return 1
  lindir="$(wslpath -u "$windir")/claude-talk-stream"
  clear_dir "$lindir" || return 1
  bg bash "$SELF" --stream-feed "$STREAMDIR" "$lindir" 48000 1
  bg bash "$SELF" --stream-play-windows "$windir\\claude-talk-stream"
}

stream_start_macos() {
  have afplay || return 1
  bg bash "$SELF" --stream-play-seq "$STREAMDIR" afplay
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
  if [[ -n "$XTTS_SPEAKER_WAV" ]]; then
    echo "xtts voice: $XTTS_SPEAKER_WAV (cloned)   lang: $XTTS_LANG"
  else
    echo "xtts voice: $XTTS_VOICE   lang: $XTTS_LANG"
  fi
  echo
  if xtts_ready; then
    echo "xtts:       installed"
    echo "  python    $XTTS_PYTHON"
    echo "  server    $XTTS_SERVER"
    "$XTTS_PYTHON" "$XTTS_SERVER" status 2>&1 | sed 's/^/  /'
  else
    echo "xtts:       NOT installed — run xtts/install-xtts.sh"
    [[ -n "$XTTS_SERVER" ]] && echo "  server    $XTTS_SERVER"
    [[ -x "$XTTS_PYTHON" ]] || echo "  python    $XTTS_PYTHON (missing)"
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
    --speaker)     XTTS_SPEAKER_WAV="${2:-}"; shift 2 ;;
    --lang)        XTTS_LANG="${2:-$XTTS_LANG}"; shift 2 ;;
    --rate)        RATE="${2:-$RATE}"; shift 2 ;;
    --speed)       XTTS_SPEED="${2:-$XTTS_SPEED}"; shift 2 ;;
    --pitch)       PITCH="${2:-$PITCH}"; shift 2 ;;
    --player)      PLAYER="${2:-$PLAYER}"; shift 2 ;;
    --warm)        DO_WARM=1; shift ;;
    --list-voices) DO_LIST=1; shift ;;
    --doctor)      DO_DOCTOR=1; shift ;;
    -h|--help)     awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    *)             shift ;;
  esac
done

case "$ENGINE" in
  auto|xtts|edge) ;;
  *) echo "talk: unknown engine '$ENGINE' — use auto, xtts or edge" >&2; exit 1 ;;
esac

if [[ "$DO_DOCTOR" -eq 1 ]]; then doctor; exit 0; fi

if [[ "$DO_WARM" -eq 1 ]]; then
  xtts_ready || { echo "talk: xtts is not installed — run xtts/install-xtts.sh" >&2; exit 1; }
  exec "$XTTS_PYTHON" "$XTTS_SERVER" preload
fi

if [[ "$DO_LIST" -eq 1 ]]; then
  if [[ "$(active_engine)" == xtts ]]; then
    exec "$XTTS_PYTHON" "$XTTS_SERVER" speakers
  fi
  have edge-tts || { echo "talk: edge-tts not found — pip install edge-tts" >&2; exit 1; }
  exec edge-tts --list-voices
fi

have jq       || { echo "talk: jq not found"      >&2; exit 1; }
have python3  || { echo "talk: python3 not found" >&2; exit 1; }
if [[ "$(active_engine)" == edge ]] && ! have edge-tts; then
  if [[ "$ENGINE" == auto ]]; then
    echo "talk: no engine available — install xtts (xtts/install-xtts.sh) or edge-tts (pip install edge-tts)" >&2
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

announce() { echo "Speaking $(wc -w <<<"$TEXT" | tr -d ' ') words as ${VOICE_USED} via ${ENGINE_USED}. (/talk stop to interrupt)"; }
# Each background job gets its own process group, so stopping playback can
# take down a loop together with the ffmpeg or player it is currently running.
bg() {
  if have setsid; then
    setsid nohup "$@" >/dev/null 2>&1 &
  else
    nohup "$@" >/dev/null 2>&1 &
  fi
  echo $! >> "$PIDFILE"
  disown 2>/dev/null
}

# --- offline fallback ------------------------------------------------------
# edge-tts is a network service. If it is unreachable, use a local voice so
# /talk still works offline.
speak_offline() {
  case "$PLATFORM" in
    macos)
      have say || return 1
      bg say "$TEXT"; echo "Speaking via macOS 'say' (edge-tts unreachable)."; return 0 ;;
    wsl)
      have powershell.exe || return 1
      local wintmp lintmp
      wintmp=$(powershell.exe -NoProfile -Command '$env:TEMP' 2>/dev/null | tr -d '\r') || return 1
      lintmp=$(wslpath -u "$wintmp" 2>/dev/null) && [[ -d "$lintmp" ]] || return 1
      printf '%s' "$TEXT" > "$lintmp/claude-talk.txt" || return 1
      bg powershell.exe -NoProfile -Command \
        'Add-Type -AssemblyName System.Speech;
         $s = New-Object System.Speech.Synthesis.SpeechSynthesizer;
         $s.Speak([IO.File]::ReadAllText("$env:TEMP\claude-talk.txt"))'
      echo "Speaking via Windows SAPI (edge-tts unreachable)."; return 0 ;;
    *)
      if have spd-say;   then bg spd-say -w "$TEXT"; echo "Speaking via spd-say (edge-tts unreachable)."; return 0; fi
      if have espeak-ng; then bg espeak-ng "$TEXT";  echo "Speaking via espeak-ng (edge-tts unreachable)."; return 0; fi
      return 1 ;;
  esac
}

# --- synthesize ------------------------------------------------------------
# TALK_RATE is an edge-tts percentage. XTTS takes a speed multiplier instead,
# so "+18%" becomes 1.18 and the one config knob drives both engines.
rate_to_speed() {
  local raw="${RATE//[%+[:space:]]/}"
  [[ -n "$raw" ]] || raw=0
  awk -v r="$raw" 'BEGIN { s = 1 + r / 100; if (s < 0.5) s = 0.5; if (s > 2.0) s = 2.0; printf "%.3f", s }'
}

synth_xtts() {
  xtts_ready || return 1
  AUDIO="$STATE_DIR/speech.wav"
  local speed voice
  speed="${XTTS_SPEED:-$(rate_to_speed)}"
  voice="${VOICE_OVERRIDE:-$XTTS_VOICE}"
  local args=(say --text-file "$SPEAKFILE" --out "$AUDIO"
              --language "$XTTS_LANG" --speed "$speed")
  if [[ -n "$XTTS_SPEAKER_WAV" ]]; then
    args+=(--speaker-wav "$XTTS_SPEAKER_WAV")
  else
    args+=(--speaker "$voice")
  fi
  printf '%s' "$TEXT" > "$SPEAKFILE" || return 1
  timeout "${TALK_XTTS_TIMEOUT:-900}" "$XTTS_PYTHON" "$XTTS_SERVER" "${args[@]}" \
    >/dev/null 2>"$ERRLOG" || return 1
  [[ -s "$AUDIO" ]] || return 1
  ENGINE_USED="XTTS-v2"
  if [[ -n "$XTTS_SPEAKER_WAV" ]]; then
    VOICE_USED="$(basename "$XTTS_SPEAKER_WAV")"
  else
    VOICE_USED="$voice"
  fi
  return 0
}

# Streaming hands the first chunk to the player while the rest still render.
# Synthesis runs about twice as fast as speech plays, so the player never
# starves, and the wait drops from the whole answer to one short sentence.
synth_xtts_stream() {
  [[ "$STREAM" == 1 ]] || return 1
  xtts_ready || return 1
  local speed voice
  speed="${XTTS_SPEED:-$(rate_to_speed)}"
  voice="${VOICE_OVERRIDE:-$XTTS_VOICE}"
  local args=(stream --text-file "$SPEAKFILE" --outdir "$STREAMDIR"
              --language "$XTTS_LANG" --speed "$speed")
  if [[ -n "$XTTS_SPEAKER_WAV" ]]; then
    args+=(--speaker-wav "$XTTS_SPEAKER_WAV")
  else
    args+=(--speaker "$voice")
  fi
  printf '%s' "$TEXT" > "$SPEAKFILE" || return 1
  timeout "${TALK_XTTS_TIMEOUT:-900}" "$XTTS_PYTHON" "$XTTS_SERVER" "${args[@]}" \
    >/dev/null 2>"$ERRLOG" || return 1
  [[ -f "$STREAMDIR/000.wav" ]] || return 1
  if ! stream_start; then
    "$XTTS_PYTHON" "$XTTS_SERVER" cancel >/dev/null 2>&1
    return 1
  fi
  ENGINE_USED="XTTS-v2, streaming"
  if [[ -n "$XTTS_SPEAKER_WAV" ]]; then
    VOICE_USED="$(basename "$XTTS_SPEAKER_WAV")"
  else
    VOICE_USED="$voice"
  fi
  return 0
}

synth_edge() {
  have edge-tts || return 1
  AUDIO="$STATE_DIR/speech.mp3"
  timeout 120 edge-tts --voice "$VOICE" --rate "$RATE" --pitch "$PITCH" \
    --text "$TEXT" --write-media "$AUDIO" >/dev/null 2>"$ERRLOG" || return 1
  [[ -s "$AUDIO" ]] || return 1
  ENGINE_USED="edge-tts"
  VOICE_USED="$VOICE"
  return 0
}

synthesis_failed() {
  echo "talk: synthesis failed" >&2
  tail -5 "$ERRLOG" >&2
  exit 1
}

stop_playback
rm -f "$STATE_DIR/speech.mp3" "$STATE_DIR/speech.wav" "$PLAYWAV"
: > "$ERRLOG"

[[ "$ENGINE" == edge ]] || { synth_xtts_stream && { announce; exit 0; }; }

case "$ENGINE" in
  xtts)
    xtts_ready || { echo "talk: xtts is not installed — run xtts/install-xtts.sh" >&2; exit 1; }
    synth_xtts || { echo "talk: XTTS synthesis failed" >&2; tail -5 "$ERRLOG" >&2; exit 1; } ;;
  edge)
    synth_edge || { speak_offline && exit 0; synthesis_failed; } ;;
  auto)
    synth_xtts || synth_edge || { speak_offline && exit 0; synthesis_failed; } ;;
esac

# --- playback --------------------------------------------------------------
# On WSL the Linux sink is WSLg's RDPSink, which streams audio to Windows over
# RDP with no buffer headroom: it starves mid-playback and crackles regardless
# of how the stream is formatted. Handing the file to Windows removes that path
# entirely. TALK_PLAYER=linux forces the PulseAudio route.
play_windows() {
  have powershell.exe && have wslpath && have ffmpeg || return 1
  local wintmp lintmp
  wintmp=$(powershell.exe -NoProfile -Command '$env:TEMP' 2>/dev/null | tr -d '\r')
  [[ -n "$wintmp" ]] || return 1
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
  local rate ch spec
  spec=$(pactl info 2>/dev/null | sed -n 's/^Default Sample Specification:[[:space:]]*//p')
  rate=$(grep -oE '[0-9]+Hz' <<<"$spec" | tr -d 'Hz')
  ch=$(grep -oE '[0-9]+ch' <<<"$spec" | tr -d 'ch')
  : "${rate:=48000}" "${ch:=2}"

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
