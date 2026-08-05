#!/usr/bin/env bash
# claude-talk — speak Claude Code's last response aloud.
# https://github.com/motionharvest/claude-talk
#
# Usage:
#   talk.sh                 speak the last response
#   talk.sh stop            stop playback
#   talk.sh --print         print what would be spoken, don't speak
#   talk.sh --voice NAME    use a different voice for this run
#   talk.sh --rate +30%     speed up / slow down for this run
#   talk.sh --list-voices   list available voices
#   talk.sh --doctor        check dependencies and audio setup
#
# Config: environment variables, or ~/.config/claude-talk/config (shell syntax)
#   TALK_VOICE          default en-US-AriaNeural
#   TALK_RATE           default +18%      e.g. +40% faster, -10% slower
#   TALK_PITCH          default +0Hz
#   TALK_MAXLEN         default 6000      chars before truncating
#   TALK_PLAYER         auto | windows | linux | macos
#   TALK_LATENCY_MSEC   default 200       PulseAudio buffer (Linux route)

set -uo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-talk/config"
[[ -f "$CONFIG" ]] && . "$CONFIG"

VOICE="${TALK_VOICE:-en-US-AriaNeural}"
RATE="${TALK_RATE:-+18%}"
PITCH="${TALK_PITCH:-+0Hz}"
MAXLEN="${TALK_MAXLEN:-6000}"
PLAYER="${TALK_PLAYER:-auto}"

STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-talk"
PIDFILE="$STATE_DIR/play.pid"
AUDIO="$STATE_DIR/last.mp3"
WAV="$STATE_DIR/last.wav"
ERRLOG="$STATE_DIR/err.log"
PRINT_ONLY=0

mkdir -p "$STATE_DIR"

have() { command -v "$1" >/dev/null 2>&1; }

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM=wsl; else PLATFORM=linux; fi ;;
  *)      PLATFORM=linux ;;
esac

stop_playback() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid=$(<"$PIDFILE")
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  # Anchored on the player binary so this can never match the shell running it.
  local p
  for p in ffplay mpv paplay pw-play afplay aplay mpg123; do
    pkill -f "^([^ ]*/)?$p .*claude-talk/last\." 2>/dev/null
  done
  # WSL interop shows the Windows player as "/init /mnt/c/.../powershell.exe ..."
  pkill -f "^(/init )?([^ ]*/)?powershell\.exe .*claude-talk\.wav" 2>/dev/null
  return 0
}

doctor() {
  echo "platform:   $PLATFORM"
  echo "player:     $PLAYER"
  echo "voice:      $VOICE   rate: $RATE   pitch: $PITCH"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    stop|--stop)   stop_playback; echo "Playback stopped."; exit 0 ;;
    --print)       PRINT_ONLY=1; shift ;;
    --voice)       VOICE="${2:-$VOICE}"; shift 2 ;;
    --rate)        RATE="${2:-$RATE}"; shift 2 ;;
    --pitch)       PITCH="${2:-$PITCH}"; shift 2 ;;
    --player)      PLAYER="${2:-$PLAYER}"; shift 2 ;;
    --list-voices) edge-tts --list-voices; exit 0 ;;
    --doctor)      doctor; exit 0 ;;
    -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             shift ;;
  esac
done

have jq       || { echo "talk: jq not found"      >&2; exit 1; }
have python3  || { echo "talk: python3 not found" >&2; exit 1; }
have edge-tts || { echo "talk: edge-tts not found — pip install edge-tts" >&2; exit 1; }

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

announce() { echo "Speaking $(wc -w <<<"$TEXT" | tr -d ' ') words as ${VOICE}. (/talk stop to interrupt)"; }
bg() { nohup "$@" >/dev/null 2>&1 & echo $! > "$PIDFILE"; disown 2>/dev/null; }

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
stop_playback
rm -f "$AUDIO" "$WAV"
if ! timeout 120 edge-tts --voice "$VOICE" --rate "$RATE" --pitch "$PITCH" \
      --text "$TEXT" --write-media "$AUDIO" >/dev/null 2>"$ERRLOG"; then
  speak_offline && exit 0
  echo "talk: synthesis failed" >&2
  tail -3 "$ERRLOG" >&2
  exit 1
fi
[[ -s "$AUDIO" ]] || { echo "talk: no audio produced" >&2; exit 1; }

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
         -ar "$rate" -ac "$ch" -c:a pcm_s16le "$WAV" 2>>"$ERRLOG"; then
      export PULSE_LATENCY_MSEC="${TALK_LATENCY_MSEC:-200}"
      have pw-play && { bg pw-play "$WAV"; return 0; }
      bg paplay "$WAV"; return 0
    fi
  fi
  have mpv    && { bg mpv --no-video --really-quiet "$AUDIO"; return 0; }
  have ffplay && { bg ffplay -nodisp -autoexit -loglevel quiet "$AUDIO"; return 0; }
  have mpg123 && { bg mpg123 -q "$AUDIO"; return 0; }
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
