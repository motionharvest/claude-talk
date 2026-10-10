#!/usr/bin/env bash
# claude-talk — speak Claude Code's last response aloud.
# https://github.com/motionharvest/claude-talk
#
# Usage:
#   talk.sh                 speak the last response
#   talk.sh pause           pause playback where it is
#   talk.sh resume          continue from where pause or stop left off
#   talk.sh restart         play the same response again from the beginning
#   talk.sh stop            stop playback; resume still works afterwards
#   talk.sh --enqueue       queue the last response; speak it now only if
#                           nothing else is speaking
#   talk.sh next            speak the oldest queued response, or say
#                           "Nothing waiting."; never interrupts
#   talk.sh replay ID       speak the saved response with this id now,
#                           stopping whatever is speaking; the response stays
#                           saved (see "Saved responses" below)
#   talk.sh say             speak the reply read from stdin now, stopping
#                           whatever is speaking; it is saved like a queued
#                           reply. The caller hands over the text, so nothing
#                           is read from the transcript
#   talk.sh ack             speak a short acknowledgement read from stdin, or
#                           play the soft tone if something is speaking
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
#   TALK_PROJECT        name spoken before a queued reply ("For <project>.");
#                       default: the git root's name, else the directory's
#   TALK_REQUEST        what the reply answers, kept with it in the saved
#                       response (the Commander launcher sets it)
#   TALK_REPLIES_DIR    where saved responses are kept
#   TALK_REPLIES_KEEP   default 200      saved responses kept; older go first
#   TALK_DRY_RUN        1 writes what would be spoken to dry.log instead
#   TALK_DRY_SECONDS    default 0         how long a dry-run reply "plays"
#   TALK_LISTEN_STALE   default 20        seconds after which an unrefreshed
#                       listening flag is ignored
#   TALK_DUCK           default 1         0 leaves other audio alone
#   TALK_DUCK_LEVEL     default 0.2       other audio's loudness while speaking,
#                       as a fraction of its own (0.2 is about 14 dB quieter)
#
# Ducking (Linux with PipeWire): while a reply or acknowledgement plays, every
# other app's output stream is turned down to TALK_DUCK_LEVEL and put back
# within about a second of the player stopping, however it stops. See
# duck_guard for why it is each stream's software gain and not the device.
#
# The reply queue lives in the state directory:
#   queue/<ns>-<id>.json   one waiting reply: {id, project, text, time}
#   pending/<id>           one request still being worked on (written by the
#                          caller, not by this script)
# One player at a time holds speaker.lock while it speaks. It never interrupts:
# a reply that arrives while it is speaking waits, and when the player is done
# it plays a soft tone if anything is still waiting. `next` plays it.
#
#
# Saved responses are different from the queue: the queue holds what has not
# been spoken yet and loses a reply the moment it plays, while a saved response
# is a record that stays until someone deletes it. Every reply that is queued is
# also written to
#   $XDG_STATE_HOME/claude-talk/replies/<ns>-<id>.json   (default ~/.local/state)
# as {id, project, request, brief, text, time}: brief is the reply's first
# sentence, request is TALK_REQUEST, time is seconds since the epoch. Screen
# Prompt 2 lists them; `replay` speaks one again. The id is the same one the
# queue file carries, so a reply still waiting in the queue is taken off it when
# it is replayed.
#
#   listening              present while the user is dictating (written by
#                          Screen Prompt 2: its pid, refreshed every few
#                          seconds). While it is present the queue player
#                          speaks nothing: a reply, an acknowledgement or the
#                          tone waits, and a reply already playing is paused
#                          and resumed from the same place once it is gone.
#                          The flag is ignored when its pid is dead or it has
#                          not been refreshed for TALK_LISTEN_STALE seconds.

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

# pw-play defaults to media.role Music, and WirePlumber saves one volume per
# role, so speech shared Spotify's volume. Speech gets its own role, and with
# it its own saved volume. pw-play reads PIPEWIRE_PROPS; paplay reads PULSE_PROP.
export PIPEWIRE_PROPS="${PIPEWIRE_PROPS:-{ media.role = Speech \}}"
export PULSE_PROP="${PULSE_PROP:-media.role=Speech}"

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
STREAM="${TALK_STREAM:-1}"
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-talk"
STREAMDIR="$STATE_DIR/stream"
READYDIR="$STATE_DIR/ready"
PIDFILE="$STATE_DIR/play.pid"
PLAYERPID="$STATE_DIR/player.pid"
POSFILE="$STATE_DIR/pos"
RESUMEFILE="$STATE_DIR/resume"
SESSIONFILE="$STATE_DIR/session"
AUDIO="$STATE_DIR/speech.mp3"
PLAYWAV="$STATE_DIR/play.wav"
SPEAKFILE="$STATE_DIR/speak.txt"
CLIENT="$STATE_DIR/google.py"
ERRLOG="$STATE_DIR/err.log"
QUEUEDIR="$STATE_DIR/queue"
REPLIESDIR="${TALK_REPLIES_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-talk/replies}"
REPLIES_KEEP="${TALK_REPLIES_KEEP:-200}"
PENDINGDIR="$STATE_DIR/pending"
LOCKFILE="$STATE_DIR/speaker.lock"
SPEAKINGFILE="$STATE_DIR/speaking"
AUTOPLAYFILE="$STATE_DIR/autoplay"
FRESHFILE="$STATE_DIR/fresh"
HALTFILE="$STATE_DIR/halted"
DRYLOG="$STATE_DIR/dry.log"
LISTENFILE="$STATE_DIR/listening"
LISTEN_STALE="${TALK_LISTEN_STALE:-20}"
ASSETS="${TALK_ASSETS:-$HOME/.claude/talk-assets}"
TONE="$ASSETS/more.wav"
DRY="${TALK_DRY_RUN:-0}"
DUCK="${TALK_DUCK:-1}"
DUCK_LEVEL="${TALK_DUCK_LEVEL:-0.2}"
DUCKLOCK="$STATE_DIR/duck.lock"
DUCKSTATE="$STATE_DIR/duck.json"

# The chunk file name has to match what the encoder actually produced, because
# the feeder and the macOS player both find chunks by name.
case "$GOOGLE_ENCODING" in
  OGG_OPUS) STREAM_EXT=ogg ;;
  LINEAR16) STREAM_EXT=wav ;;
  *)        STREAM_EXT=mp3 ;;
esac

PRINT_ONLY=0
VOICE_OVERRIDE=""
# Options given for this run that change how it sounds. The queue player is a
# separate process started by start_runner, so they are handed on to it;
# otherwise a sample asked for in one voice is spoken in the saved one.
RUNNER_OPTS=()
ENGINE_USED=""
VOICE_USED=""
DO_DOCTOR=0
DO_LIST=0
DO_CHECK=0
MODE=speak
REPLAY_ID=""
RUN_ARGS=()

mkdir -p "$STATE_DIR" "$QUEUEDIR" "$PENDINGDIR" "$REPLIESDIR"

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

kill_pids() {
  local f="$1" pid
  [[ -f "$f" ]] || return 0
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -- "-$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  done < "$f"
  rm -f "$f"
  return 0
}

kill_players() {
  # Anchored on the player binary so this can never match the shell running it.
  local p
  for p in ffplay mpv paplay pw-play afplay aplay mpg123; do
    pkill -f "^([^ ]*/)?$p .*claude-talk" 2>/dev/null
  done
  # WSL interop shows the Windows player as "/init /mnt/c/.../powershell.exe ..."
  pkill -f "^(/init )?([^ ]*/)?powershell\.exe .*claude-talk" 2>/dev/null
  return 0
}

halt_player() {
  kill_pids "$PLAYERPID"
  kill_players
  return 0
}

stop_playback() {
  halt_player
  kill_pids "$PIDFILE"
  return 0
}

playing() {
  local pid
  [[ -f "$PLAYERPID" ]] || return 1
  while read -r pid; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  done < "$PLAYERPID"
  return 1
}

# Each background job gets its own process group, so stopping playback can
# take down a loop together with the ffmpeg or player it is currently running.
bg() {
  if have setsid; then
    setsid nohup "$@" >/dev/null 2>>"$ERRLOG" 9>&- &
  else
    nohup "$@" >/dev/null 2>>"$ERRLOG" 9>&- &
  fi
  BG_PID=$!
  echo "$BG_PID" >> "$PIDFILE"
  disown 2>/dev/null
}

bg_player() {
  bg "$@"
  echo "$BG_PID" >> "$PLAYERPID"
  start_duck
}

# --- ducking -----------------------------------------------------------------
# Every way speech starts (a reply, an acknowledgement, resume, restart, replay,
# the resume after dictation) goes through bg_player, so that is the one place
# a duck guard is started. The guard follows the player pids in player.pid
# rather than being told when to stop: pause, stop, a killed player, or a crash
# in this script all end in the same way, with no player left alive, and the
# guard puts the volumes back after a short grace. It is not in play.pid, so a
# reply following straight on from another does not unduck between them.
duck_supported() {
  [[ "$PLATFORM" == linux && "$DUCK" != 0 && "$DRY" != 1 ]] \
    && have pw-dump && have pw-cli && have python3 && have flock
}

start_duck() {
  duck_supported || return 0
  # fd 9 is speaker.lock in the queue player; the guard must never hold it.
  if have setsid; then
    setsid nohup bash "$SELF" --duck-guard >/dev/null 2>>"$ERRLOG" 9>&- &
  else
    nohup bash "$SELF" --duck-guard >/dev/null 2>>"$ERRLOG" 9>&- &
  fi
  disown 2>/dev/null
  return 0
}

# One guard at a time. A second one waits briefly for the lock: either the first
# is still ducking (and keeps going, because the new player is alive), or it is
# on its way out, and the second takes over.
#
# Why each stream's software gain (PipeWire's softVolumes) rather than the
# output device Screen Prompt 2 ducks while dictating: the device volume would
# turn the speech down too, and on a device with a hardware volume control it
# cannot be won back by boosting the speech without clipping. Why not the
# stream volume pactl shows: WirePlumber remembers that against the app's name,
# so a stream that ended while ducked would leave the app quiet next time.
# softVolumes is the gain actually applied and is never saved. Sending the
# stream's own volume again (or anyone moving it) puts that back in charge, so
# the worst a lost restore can do is leave one stream that is already playing
# quiet until it ends or its volume is touched.
duck_guard() {
  exec 8>"$DUCKLOCK"
  flock -w 5 8 || exit 0
  exec python3 - "$PLAYERPID" "$DUCKSTATE" "$DUCK_LEVEL" "$STATE_DIR" "$ASSETS" <<'PY'
import json, os, signal, subprocess, sys, time

player_file, state_file, level, *exempt = sys.argv[1:]
level = min(1.0, max(0.0, float(level)))
TICK, GRACE = 0.25, 0.75   # seconds between looks; how long with no player


def run(argv):
    """stdout, or None if the command failed."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=5)
        return out.stdout if out.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def player_alive():
    try:
        with open(player_file) as fh:
            pids = [int(l) for l in fh.read().split() if l.isdigit()]
    except OSError:
        return False
    for pid in pids:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            pass
    return False


def streams():
    """{node id: {serial, pid, vol}} for every output stream, or None if unknown.

    vol is channelVolumes, the stream's own volume. softVolumes is not read:
    once it has been set, PipeWire goes on reporting the set value even after
    a channelVolumes change has taken over again, so it cannot be trusted.
    """
    raw = run(["pw-dump"])
    if not raw:
        return None
    # pw-dump prints a further array for anything that changes while it runs:
    # a later entry updates the earlier one, and a null info means it has gone.
    at, objects, dec = 0, {}, json.JSONDecoder()
    while True:
        while at < len(raw) and raw[at].isspace():
            at += 1
        if at >= len(raw):
            break
        try:
            chunk, at = dec.raw_decode(raw, at)
        except ValueError:
            return None
        for o in chunk if isinstance(chunk, list) else []:
            if not isinstance(o, dict) or "id" not in o:
                continue
            if o.get("info") is None:
                objects.pop(o["id"], None)
            elif o["id"] in objects:
                objects[o["id"]].setdefault("info", {}).update(o["info"])
            else:
                objects[o["id"]] = o
    if not objects:
        return None
    clients = {o.get("id"): ((o.get("info") or {}).get("props") or {})
               for o in objects.values() if o.get("type") == "PipeWire:Interface:Client"}
    found = {}
    for node, o in objects.items():
        if o.get("type") != "PipeWire:Interface:Node":
            continue
        info = o.get("info") or {}
        props = info.get("props") or {}
        if props.get("media.class") != "Stream/Output/Audio":
            continue
        vol = None
        for p in (info.get("params") or {}).get("Props") or []:
            if isinstance(p, dict) and p.get("channelVolumes"):
                vol = [float(v) for v in p["channelVolumes"]]
                break
        if not vol:
            continue
        pid = props.get("application.process.id") \
            or clients.get(props.get("client.id"), {}).get("application.process.id")
        found[node] = {"serial": props.get("object.serial"), "pid": pid, "vol": vol}
    return found


def is_ours(pid):
    """The speech and the tone: players whose command line names our files."""
    try:
        with open(f"/proc/{int(pid)}/cmdline", "rb") as fh:
            cmd = fh.read().decode(errors="replace")
    except (OSError, TypeError, ValueError):
        return False
    return "claude-talk" in cmd or any(e and e in cmd for e in exempt)


def set_props(node, key, vols):
    return run(["pw-cli", "set-param", str(node), "Props",
                "{ %s: [ %s ] }" % (key, ", ".join("%.6f" % v for v in vols))]) is not None


def same(a, b):
    return len(a) == len(b) and all(abs(x - y) < 1e-4 for x, y in zip(a, b))


ducked = {}     # node id -> {serial, vol}: its own volume when it was ducked
left = set()    # nodes not to touch: ours, or the user moved their volume


def save():
    try:
        if ducked:
            with open(state_file + ".part", "w") as fh:
                json.dump([{"id": k, **v} for k, v in ducked.items()], fh)
            os.replace(state_file + ".part", state_file)
        elif os.path.exists(state_file):
            os.remove(state_file)
    except OSError:
        pass


def put_back(entries, tries=8):
    """Undo the duck on each stream that is still the one ducked.

    Undoing is sending the stream's own volume again, unchanged: that makes
    PipeWire apply it in place of the ducked gain, which is exactly the state
    before the duck. A stream whose volume was moved by hand while ducked was
    already switched back by that move and is left alone. True when every
    entry is settled; False if PipeWire could not be read or written.
    """
    owed = list(entries)
    for _ in range(tries):
        now = streams()
        if now is None:
            time.sleep(0.2)
            continue
        failed = []
        for node, e in owed:
            s = now.get(node)
            if not s or s["serial"] != e["serial"] or not same(s["vol"], e["vol"]):
                continue                        # gone, replaced, or moved by hand
            if not set_props(node, "channelVolumes", s["vol"]):
                failed.append((node, e))
        if not failed:
            return True
        owed = failed
        time.sleep(0.2)
    return False


def tick():
    now = streams()
    if now is None:
        return
    for node in list(ducked):
        s = now.get(node)
        if not s or s["serial"] != ducked[node]["serial"]:
            del ducked[node]                    # ended; nothing was saved
        elif not same(s["vol"], ducked[node]["vol"]):
            del ducked[node]                    # moved by hand: theirs now
            left.add(node)
    for node, s in now.items():
        if node in ducked or node in left:
            continue
        if is_ours(s["pid"]):
            left.add(node)
            continue
        target = [v * level for v in s["vol"]]
        if all(t >= v for t, v in zip(target, s["vol"])):
            continue
        # Recorded before the write, so a crash in between still restores it.
        ducked[node] = {"serial": s["serial"], "vol": s["vol"]}
        save()
        set_props(node, "softVolumes", target)
    save()


def stop(*_):
    raise SystemExit(0)


for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
    signal.signal(sig, stop)

try:
    # A guard that died without restoring left its streams here.
    try:
        with open(state_file) as fh:
            old = [(e["id"], {"serial": e["serial"], "vol": e["vol"]})
                   for e in json.load(fh) if isinstance(e, dict)]
        if not put_back(old):
            ducked.update(old)      # still owed; restored with the rest
    except (OSError, ValueError, KeyError, TypeError):
        pass
    quiet_since = None
    while True:
        if player_alive():
            quiet_since = None
            tick()
        elif quiet_since is None:
            quiet_since = time.monotonic()
        elif time.monotonic() - quiet_since >= GRACE:
            break
        time.sleep(TICK)
finally:
    # Left on disk if it could not be confirmed, for the next guard to retry.
    if put_back(list(ducked.items())):
        ducked.clear()
    save()
PY
}

save_session() {
  local kv
  : > "$SESSIONFILE"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$SESSIONFILE"; done
}

load_session() {
  [[ -s "$SESSIONFILE" ]] || return 1
  S_ROUTE=""; S_DIR=""; S_WINDIR=""; S_PLAYER=""; S_EXT=""; S_AUDIO=""; S_POS=""
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      route)  S_ROUTE="$v" ;;
      dir)    S_DIR="$v" ;;
      windir) S_WINDIR="$v" ;;
      player) S_PLAYER="$v" ;;
      ext)    S_EXT="$v" ;;
      audio)  S_AUDIO="$v" ;;
      pos)    S_POS="$v" ;;
    esac
  done < "$SESSIONFILE"
  [[ -n "$S_ROUTE" ]]
}

mark_position() {
  local idx="$1" offset="${2:-0}" file="$3"
  [[ -n "$file" ]] || return 0
  printf '%s %s\n' "$idx" "$(( $(date +%s) - offset ))" > "$file"
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
  local dir="$1" player="$2" ext="${3:-wav}" posf="${4:-}" i="${5:-0}" offset="${6:-0}" f head
  export PULSE_LATENCY_MSEC="${TALK_LATENCY_MSEC:-200}"
  head="$dir/resume.$ext"
  if [[ -f "$head" ]]; then
    mark_position "$(( i > 0 ? i - 1 : 0 ))" "$offset" "$posf"
    "$player" "$head" >/dev/null 2>&1
    rm -f "$head"
  fi
  while :; do
    f=$(printf '%s/%03d.%s' "$dir" "$i" "$ext")
    if [[ -f "$f" ]]; then
      mark_position "$i" 0 "$posf"
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
\$i = ${2:-0}
\$offset = ${3:-0}
\$pos = Join-Path \$dir 'pos'
\$head = Join-Path \$dir 'resume.wav'
function Mark([int]\$n, [int]\$back) {
  \$t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - \$back
  Set-Content -Path \$pos -Value (\$n.ToString() + ' ' + \$t.ToString())
}
if (Test-Path \$head) {
  Mark ([Math]::Max(\$i - 1, 0)) \$offset
  (New-Object Media.SoundPlayer \$head).PlaySync()
  Remove-Item \$head -ErrorAction SilentlyContinue
}
while (\$true) {
  \$f = Join-Path \$dir ('{0:D3}.wav' -f \$i)
  if (Test-Path \$f) { Mark \$i 0; (New-Object Media.SoundPlayer \$f).PlaySync(); \$i++ }
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
  rm -f "$1"/*.wav "$1"/*.mp3 "$1"/*.part "$1/END" "$1/ERR" "$1/pos" 2>/dev/null
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
  save_session route=seq "dir=$READYDIR" "player=$player" ext=wav "pos=$POSFILE"
  bg bash "$SELF" --stream-feed "$STREAMDIR" "$READYDIR" "$rate" "$ch" "$STREAM_EXT"
  bg_player bash "$SELF" --stream-play-seq "$READYDIR" "$player" wav "$POSFILE" 0 0
}

stream_start_windows() {
  local windir lindir
  have ffmpeg && have wslpath || return 1
  windir=$(win_tmp) || return 1
  lindir="$(wslpath -u "$windir")/claude-talk-stream"
  clear_dir "$lindir" || return 1
  save_session route=windows "dir=$lindir" "windir=$windir\\claude-talk-stream" ext=wav "pos=$lindir/pos"
  bg bash "$SELF" --stream-feed "$STREAMDIR" "$lindir" 48000 1 "$STREAM_EXT"
  bg_player bash "$SELF" --stream-play-windows "$windir\\claude-talk-stream" 0 0
}

# afplay decodes mp3 itself, so the macOS route plays the chunks as they land
# and never needs ffmpeg at all.
stream_start_macos() {
  have afplay || return 1
  save_session route=seq "dir=$STREAMDIR" player=afplay "ext=$STREAM_EXT" "pos=$POSFILE"
  bg_player bash "$SELF" --stream-play-seq "$STREAMDIR" afplay "$STREAM_EXT" "$POSFILE" 0 0
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
  bg_player powershell.exe -NoProfile -Command \
    '(New-Object Media.SoundPlayer "$env:TEMP\claude-talk.wav").PlaySync()'
}

# macOS CoreAudio plays mp3 natively and never needed any of this.
play_macos() { have afplay && bg_player afplay "$AUDIO"; }

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
      have pw-play && { bg_player pw-play "$PLAYWAV"; return 0; }
      bg_player paplay "$PLAYWAV"; return 0
    fi
  fi
  have mpv    && { bg_player mpv --no-video --really-quiet "$AUDIO"; return 0; }
  have ffplay && { bg_player ffplay -nodisp -autoexit -loglevel quiet "$AUDIO"; return 0; }
  [[ "$AUDIO" == *.mp3 ]] && have mpg123 && { bg_player mpg123 -q "$AUDIO"; return 0; }
  return 1
}

play_file() {
  local offset="${1:-0}"
  mark_position 0 "$offset" "$POSFILE"
  case "$PLAYER" in
    windows) play_windows && return 0 ;;
    macos)   play_macos   && return 0 ;;
    linux)   play_linux   && return 0 ;;
    auto)
      case "$PLATFORM" in
        macos) play_macos   && return 0 ;;
        wsl)   play_windows && return 0 ;;
      esac
      play_linux && return 0 ;;
  esac
  return 1
}

media_seconds() {
  have ffprobe || return 1
  local d
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null)
  [[ -n "$d" && "$d" != N/A ]] || return 1
  printf '%s' "${d%%.*}"
}

seek_head() {
  local src="$1" dst="$2" offset="$3" ext="$4" size fmt
  have ffmpeg || return 1
  case "$ext" in
    wav) fmt=wav ;;
    ogg) fmt=ogg ;;
    *)   fmt=mp3 ;;
  esac
  case "$ext" in
    wav) ffmpeg -y -loglevel error -ss "$offset" -i "$src" -c:a pcm_s16le -f "$fmt" "$dst.part" 2>>"$ERRLOG" || return 1 ;;
    *)   ffmpeg -y -loglevel error -ss "$offset" -i "$src" -c copy -f "$fmt" "$dst.part" 2>>"$ERRLOG" || return 1 ;;
  esac
  size=$(stat -c%s "$dst.part" 2>/dev/null || stat -f%z "$dst.part" 2>/dev/null)
  if [[ -z "$size" ]] || (( size < 1024 )); then rm -f "$dst.part"; return 1; fi
  mv -f "$dst.part" "$dst"
}

start_playback() {
  local idx="$1" offset="$2" src head dur
  load_session || { echo "talk: nothing has been spoken yet — run /talk first" >&2; return 1; }
  halt_player

  case "$S_ROUTE" in
    seq|windows)
      src=$(printf '%s/%03d.%s' "$S_DIR" "$idx" "$S_EXT")
      [[ -f "$src" ]] || { idx=0; offset=0; src=$(printf '%s/000.%s' "$S_DIR" "$S_EXT"); }
      [[ -f "$src" ]] || { echo "talk: the audio for that response is gone — run /talk again" >&2; return 1; }
      dur=$(media_seconds "$src") || dur=""
      if (( offset > 0 )) && [[ -n "$dur" ]] && (( offset >= dur )); then
        offset=0
        idx=$((idx + 1))
        [[ -f "$(printf '%s/%03d.%s' "$S_DIR" "$idx" "$S_EXT")" ]] \
          || { echo "talk: that response finished playing — /talk restart plays it again" >&2; return 1; }
      fi
      head="$S_DIR/resume.$S_EXT"
      rm -f "$head"
      if (( offset > 0 )) && seek_head "$src" "$head" "$offset" "$S_EXT"; then
        idx=$((idx + 1))
      else
        offset=0
      fi
      if [[ "$S_ROUTE" == windows ]]; then
        bg_player bash "$SELF" --stream-play-windows "$S_WINDIR" "$idx" "$offset"
      else
        bg_player bash "$SELF" --stream-play-seq "$S_DIR" "$S_PLAYER" "$S_EXT" "$S_POS" "$idx" "$offset"
      fi
      ;;
    single)
      [[ -s "$S_AUDIO" ]] || { echo "talk: the audio for that response is gone — run /talk again" >&2; return 1; }
      dur=$(media_seconds "$S_AUDIO") || dur=""
      if (( offset > 0 )) && [[ -n "$dur" ]] && (( offset >= dur )); then
        echo "talk: that response finished playing — /talk restart plays it again" >&2; return 1
      fi
      AUDIO="$S_AUDIO"
      if (( offset > 0 )) && seek_head "$S_AUDIO" "$STATE_DIR/resume.mp3" "$offset" mp3; then
        AUDIO="$STATE_DIR/resume.mp3"
      else
        offset=0
      fi
      play_file "$offset" || { echo "talk: no working audio player found — run 'talk.sh --doctor'" >&2; return 1; }
      ;;
    *)
      echo "talk: nothing has been spoken yet — run /talk first" >&2; return 1 ;;
  esac
  return 0
}

halt_and_mark() {
  local word="$1" idx=0 start="" now off
  # Tells a queue player waiting on this playback that it was stopped by hand,
  # so it ends quietly instead of playing the waiting tone.
  : > "$HALTFILE"
  local live=1
  playing || live=0
  if load_session && [[ -s "$S_POS" ]]; then
    read -r idx start < <(tr -d '\r' < "$S_POS")
  fi
  halt_player
  if (( live == 0 )); then
    if [[ -s "$RESUMEFILE" ]]; then
      echo "Already paused. (/talk resume to continue)"
    else
      echo "Nothing is playing."
    fi
    return 0
  fi
  now=$(date +%s)
  idx="${idx:-0}"
  start="${start:-$now}"
  off=$(( now - start ))
  (( off < 0 )) && off=0
  printf '%s %s\n' "$idx" "$off" > "$RESUMEFILE"
  case "$word" in
    pause) echo "Paused. (/talk resume to continue)" ;;
    *)     echo "Playback stopped. (/talk resume to continue)" ;;
  esac
}

talk_resume() {
  local idx off
  [[ -s "$RESUMEFILE" ]] || { echo "talk: nothing is paused — run /talk to speak the last response" >&2; exit 1; }
  read -r idx off < "$RESUMEFILE"
  off="${off:-0}"
  (( off > 1 )) && off=$((off - 1)) || off=0
  start_playback "${idx:-0}" "$off" || exit 1
  rm -f "$RESUMEFILE"
  echo "Resumed. (/talk pause to interrupt)"
}

talk_restart() {
  start_playback 0 0 || exit 1
  rm -f "$RESUMEFILE"
  echo "Restarted from the beginning. (/talk pause to interrupt)"
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
  --duck-guard)           duck_guard;                       exit $? ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    stop|--stop)       halt_and_mark stop;  exit 0 ;;
    pause|--pause)     halt_and_mark pause; exit 0 ;;
    resume|--resume)   talk_resume;         exit 0 ;;
    restart|--restart) talk_restart;        exit 0 ;;
    enqueue|--enqueue) MODE=enqueue; shift ;;
    next|--next)       MODE=next;    shift ;;
    ack|--ack)         MODE=ack;     shift ;;
    say|--say)         MODE=say;     shift ;;
    replay|--replay)   MODE=replay;  REPLAY_ID="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
    --queue-run)       MODE=run; shift; RUN_ARGS=("$@"); break ;;
    --print)       PRINT_ONLY=1; shift ;;
    --engine)      ENGINE="${2:-$ENGINE}"; RUNNER_OPTS+=("$1" "${2:-}"); shift 2 ;;
    --voice)       VOICE_OVERRIDE="${2:-}"; VOICE="${2:-$VOICE}"; RUNNER_OPTS+=("$1" "${2:-}"); shift 2 ;;
    --lang)        GOOGLE_LANG="${2:-$GOOGLE_LANG}"; RUNNER_OPTS+=("$1" "${2:-}"); shift 2 ;;
    --key-file)    GOOGLE_KEY_FILE="${2:-$GOOGLE_KEY_FILE}"; shift 2 ;;
    --rate)        RATE="${2:-$RATE}"; RUNNER_OPTS+=("$1" "${2:-}"); shift 2 ;;
    --speed)       GOOGLE_SPEED="${2:-$GOOGLE_SPEED}"; RUNNER_OPTS+=("$1" "${2:-}"); shift 2 ;;
    --pitch)       PITCH="${2:-$PITCH}"; RUNNER_OPTS+=("$1" "${2:-}"); shift 2 ;;
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

extract_text() {
local TRANSCRIPT RAW RAWFILE
# `say` hands the reply over on stdin. The transcript cannot be trusted for the
# newest reply: when /talk runs in the same turn as that reply, the reply has
# not been written to the transcript yet, and the one before it is found.
if [[ -n "${SAY_TEXT+x}" ]]; then
RAW="$SAY_TEXT"
else
TRANSCRIPT=$(find_transcript)
[[ -f "$TRANSCRIPT" ]] || { echo "talk: could not find session transcript" >&2; return 1; }

# --- extract the last response --------------------------------------------
# The final response is the trailing run of assistant messages carrying text
# but no tool calls. Walking backwards and stopping at the first message with a
# tool_use skips the "let me check X" progress lines emitted between tools.
#
# When /talk is run through the Skill tool, this script runs while that call
# is being expanded, so the transcript ends with the call and its expansion.
# Only what came before the last such call is read, and the call itself is not
# a tool step. A final response saved with no text block, only a thinking
# block (seen 2026-10-09: the reply was shown on screen but stored as
# thinking), is spoken from that thinking; any text in the run wins over it.
RAW=$(jq -rs '
  def talknoise:
    (. // "") | sub("^\\s+"; "")
    | test("^Speaking [0-9]+ words? / [0-9]+ characters? as .* to interrupt\\)")
      or test("^Playback stopped\\.")
      or test("^Paused\\.")
      or test("^Resumed\\.")
      or test("^Restarted from the beginning\\.")
      or test("^Already paused\\.")
      or test("^Nothing is playing\\.")
      or test("^Speaking now\\.")
      or test("^Queued for later")
      or test("^Playing the next reply")
      or test("^Will play the next reply")
      or test("^talk: ")
      or test("The command above already ran and its output is shown\\.");
  def talkcall:
    .type == "tool_use" and .name == "Skill" and ((.input.skill // "") | test("^/?talk$"));
  [ .[]
    | select((.isSidechain // false) | not)
    | if .type == "assistant" then
        { a: true,
          talk: (([ .message.content[]? | select(talkcall) ] | length) > 0),
          tool: (([ .message.content[]? | select(.type == "tool_use") | select(talkcall | not) ] | length) > 0),
          txt:  ([ .message.content[]? | select(.type == "text") | .text ] | join("\n\n")),
          think: ([ .message.content[]? | select(.type == "thinking") | (.thinking // "")
                    | select(test("\\S")) ] | join("\n\n")) }
      elif .type == "user" then
        { a: false, talk: false, tool: false, think: "",
          txt: (if (.message.content | type) == "string" then .message.content
                else ([ .message.content[]? | select(.type == "text") | .text ] | join("\n\n")) end) }
      else empty end
    | select((.txt | talknoise) | not)
  ]
  | ([ to_entries[] | select(.value.talk) | .key ] | last) as $call
  | (if $call == null then . else .[0:$call + 1] end)
  | reverse as $rev
  | ( reduce $rev[] as $x ({ stop: false, acc: [], th: [] };
        if .stop then .
        elif ($x.a and ($x.tool | not)) then .acc = ([ $x.txt ] + .acc) | .th = ([ $x.think ] + .th)
        else .stop = true end)
      | { txt: (.acc | map(select(. != "")) | join("\n\n")),
          think: (.th | map(select(. != "")) | join("\n\n")) } ) as $final
  | if ($final.txt | length) > 0 then $final.txt
    elif ($final.think | length) > 0 then $final.think
    else ( [ $rev[] | select(.a) | .txt | select(. != "") ] | first // "" ) end
' "$TRANSCRIPT")
fi

[[ -n "${RAW//[[:space:]]/}" ]] || { echo "talk: no previous response found to speak" >&2; return 1; }

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

[[ -n "${TEXT//[[:space:]]/}" ]] || { echo "talk: nothing speakable in the last response" >&2; return 1; }
}

announce() {
  local words chars
  words=$(wc -w <<<"$TEXT" | tr -d ' ')
  chars=${#TEXT}
  echo "Speaking $words words / $chars characters as ${VOICE_USED} via ${ENGINE_USED}. (/talk pause to interrupt)"
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
  return 1
}

# Synthesizes $TEXT and starts it playing. Returns once playback has started,
# not when it ends; wait_playback is the one that waits.
speak_text() {
  if [[ "$DRY" == 1 ]]; then
    printf 'speak: %s\n' "$TEXT" >> "$DRYLOG"
    return 0
  fi
  # A plain `talk.sh` interrupts on purpose. The queue player has already made
  # sure nothing is playing, so for it this only clears what is left of the
  # last run: its pid files, which would otherwise pile up and let `playing`
  # trust a pid the system has since reused.
  stop_playback
  rm -f "$STATE_DIR/speech.mp3" "$STATE_DIR/speech.wav" "$PLAYWAV" \
        "$RESUMEFILE" "$POSFILE" "$SESSIONFILE" "$STATE_DIR/resume.mp3"
  : > "$ERRLOG"

  case "$(active_engine)" in
    google)
      synth_google_stream && { announce; return 0; }
      if ! synth_google; then
        [[ "$ENGINE" == auto ]] || { synthesis_failed; return 1; }
        synth_edge || { speak_offline && return 0; synthesis_failed; return 1; }
      fi ;;
    edge)
      synth_edge || { speak_offline && return 0; synthesis_failed; return 1; } ;;
  esac

  save_session route=single "audio=$AUDIO" "pos=$POSFILE"
  play_file 0 && { announce; return 0; }
  echo "talk: no working audio player found — run 'talk.sh --doctor'" >&2
  return 1
}

# --- listening -----------------------------------------------------------------
# Whether the user is dictating right now. The flag counts only while the
# process named in it is alive and it has been refreshed recently, so an app
# that crashed mid-recording cannot silence the queue for good.
listening() {
  [[ -f "$LISTENFILE" ]] || return 1
  local pid age
  pid=$(tr -cd '0-9' < "$LISTENFILE" 2>/dev/null)
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then return 1; fi
  age=$(( $(date +%s) - $(stat -c %Y "$LISTENFILE" 2>/dev/null || stat -f %m "$LISTENFILE" 2>/dev/null || echo 0) ))
  (( age <= LISTEN_STALE ))
}

# Blocks until the user has stopped dictating. Used before anything the queue
# player says or plays, so nothing starts speaking over them.
hold_while_listening() {
  listening || return 0
  [[ "$DRY" == 1 ]] && echo "hold: listening" >> "$DRYLOG"
  while listening; do sleep 0.2; done
  [[ "$DRY" == 1 ]] && echo "hold: done" >> "$DRYLOG"
  return 0
}

# Recording started while a reply is playing: stop the player where it is,
# wait for the user to finish, then carry on from about a second before the
# point it reached. Unlike `talk.sh pause` this leaves no halt marker, so the
# queue player goes on to whatever is waiting afterwards. A `talk.sh stop` or
# `pause` given while held wins, and nothing resumes.
pause_for_listening() {
  local idx=0 start="" now off
  if load_session && [[ -s "$S_POS" ]]; then
    read -r idx start < <(tr -d '\r' < "$S_POS")
  fi
  halt_player
  now=$(date +%s)
  start="${start:-$now}"
  off=$(( now - start ))
  (( off < 0 )) && off=0
  while listening; do sleep 0.2; done
  [[ -e "$HALTFILE" ]] && return 0
  (( off > 1 )) && off=$((off - 1)) || off=0
  start_playback "${idx:-0}" "$off" >/dev/null 2>&1
  return 0
}

wait_playback() {
  if [[ "$DRY" == 1 ]]; then
    # A dry reply "plays" for TALK_DRY_SECONDS, and is held while listening
    # the same way a real one is, so the hold can be tested without audio.
    local left=$(( ${TALK_DRY_SECONDS:-0} * 5 ))
    while (( left > 0 )); do
      if listening; then
        echo "pause: listening" >> "$DRYLOG"
        while listening; do sleep 0.2; done
        echo "resume" >> "$DRYLOG"
      fi
      sleep 0.2
      left=$((left - 1))
    done
    return 0
  fi
  while playing; do
    listening && pause_for_listening
    sleep 0.2
  done
  return 0
}

# --- reply queue -------------------------------------------------------------
# A waiting reply is one JSON file. The name starts with the enqueue time in
# nanoseconds, so the alphabetical order a glob returns is the arrival order.
# Files being written start with a dot and are never matched.
oldest_item() {
  local f
  for f in "$QUEUEDIR"/*.json; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

queue_count() {
  local n=0 f
  for f in "$QUEUEDIR"/*.json; do [[ -f "$f" ]] && n=$((n + 1)); done
  printf '%s' "$n"
}

project_name() {
  if [[ -n "${TALK_PROJECT:-}" ]]; then printf '%s' "$TALK_PROJECT"; return 0; fi
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  basename "$root"
}

# One JSON document, written to both places: the queue, where it waits to be
# spoken, and the saved responses, where it stays. Both are written under a dot
# name and renamed, so nobody reads half a file. The brief is the first
# sentence, or the first 140 characters when there is no end to it in sight.
enqueue_text() {
  local id name record
  id=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  name="$(date +%s%N)-$id.json"
  ENQUEUED_ID="$id"
  record=$(jq -n --arg id "$id" --arg project "$(project_name)" --arg text "$TEXT" \
        --arg request "${TALK_REQUEST:-}" --argjson time "$(date +%s)" '
      ($text | gsub("\\s+"; " ") | sub("^ "; "")) as $flat
      | (($flat | capture("^(?<s>.{1,160}?[.!?])(\\s|$)").s)
         // (if ($flat | length) > 140 then ($flat[0:139] + "…") else $flat end)) as $brief
      | {id: $id, project: $project, request: ($request | gsub("\\s+"; " ") | .[0:300]),
         brief: $brief, text: $text, time: $time}') || return 1
  printf '%s\n' "$record" > "$QUEUEDIR/.$name.part" \
    && mv -f "$QUEUEDIR/.$name.part" "$QUEUEDIR/$name" || return 1
  # The queue is what makes the reply speak, so it is written first and its
  # failure is the one that counts. Keeping a copy is best effort: a folder that
  # cannot be written costs the record, never the reply.
  { printf '%s\n' "$record" > "$REPLIESDIR/.$name.part" \
      && mv -f "$REPLIESDIR/.$name.part" "$REPLIESDIR/$name" && prune_replies; } 2>/dev/null
  return 0
}

# Saved responses are kept up to a limit, oldest first out. The names start with
# the time in nanoseconds, so the alphabetical order is the age order.
prune_replies() {
  local f n=0 extra
  for f in "$REPLIESDIR"/*.json; do [[ -f "$f" ]] && n=$((n + 1)); done
  extra=$(( n - REPLIES_KEEP ))
  (( extra > 0 )) || return 0
  for f in "$REPLIESDIR"/*.json; do
    (( extra > 0 )) || break
    rm -f "$f"; extra=$((extra - 1))
  done
  return 0
}

# The file of the saved response with this id. The id is hex, and checked to be,
# because it is put into a pattern.
saved_reply() {
  local f
  [[ "$1" =~ ^[0-9a-f]+$ ]] || return 1
  for f in "$REPLIESDIR"/*-"$1".json; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# Whether anything is speaking: a queue player holding the lock, or playback
# started outside the queue, such as `talk.sh resume`.
speaking() {
  playing && return 0
  ( flock -n 9 ) 9>"$LOCKFILE" && return 1
  return 0
}

# The soft two-note tone that means "more replies are waiting". Generated once.
ensure_tone() {
  [[ -s "$TONE" ]] && return 0
  mkdir -p "$ASSETS" || return 1
  python3 - "$TONE.part" <<'PY' || return 1
import math, struct, sys, wave

RATE = 48000
out = wave.open(sys.argv[1], "wb")
out.setnchannels(1)
out.setsampwidth(2)
out.setframerate(RATE)
frames = bytearray()
for freq, ms in ((660, 110), (880, 160)):
    n = int(RATE * ms / 1000)
    for i in range(n):
        # Short attack, long exponential tail: a soft chime rather than a beep.
        env = min(i / (RATE * 0.006), 1.0) * math.exp(-4.0 * i / n)
        frames += struct.pack("<h", int(32767 * 0.12 * env * math.sin(2 * math.pi * freq * i / RATE)))
out.writeframes(bytes(frames))
out.close()
PY
  mv -f "$TONE.part" "$TONE"
}

play_tone() {
  hold_while_listening
  if [[ "$DRY" == 1 ]]; then echo "tone" >> "$DRYLOG"; return 0; fi
  ensure_tone || return 0
  case "$PLATFORM" in
    macos) have afplay && afplay "$TONE" >/dev/null 2>&1 ;;
    *)
      if   have pw-play; then pw-play "$TONE" >/dev/null 2>&1
      elif have paplay;  then paplay "$TONE" >/dev/null 2>&1
      elif have aplay;   then aplay -q "$TONE" >/dev/null 2>&1
      fi ;;
  esac
  return 0
}

start_runner() {
  if have setsid; then
    setsid nohup bash "$SELF" ${RUNNER_OPTS[@]+"${RUNNER_OPTS[@]}"} --queue-run "$@" </dev/null >/dev/null 2>>"$ERRLOG" 9>&- &
  else
    nohup bash "$SELF" ${RUNNER_OPTS[@]+"${RUNNER_OPTS[@]}"} --queue-run "$@" </dev/null >/dev/null 2>>"$ERRLOG" 9>&- &
  fi
  disown 2>/dev/null
  return 0
}

# Speaks the oldest waiting reply, prefixed with its project, and removes it
# from the queue the moment it starts.
speak_item() {
  local item="$1" current="$STATE_DIR/current.json" project text
  # Still counted as waiting while the user talks; taken off the queue only
  # when it can actually be spoken.
  hold_while_listening
  [[ -e "$HALTFILE" ]] && return 1
  mv -f "$item" "$current" 2>/dev/null || return 1
  project=$(jq -r '.project // ""' "$current")
  text=$(jq -r '.text // ""' "$current")
  rm -f "$current"
  printf 'reply %s\n' "$project" > "$SPEAKINGFILE"
  TEXT="${project:+For $project. }$text"
  speak_text >/dev/null 2>&1 && wait_playback
  return 0
}

# Speaks a saved response where it is and leaves it saved. A repeat, not the
# reply's one turn on the queue, so nothing is taken off anything.
replay_item() {
  local item="$1" project text
  hold_while_listening
  [[ -e "$HALTFILE" ]] && return 1
  project=$(jq -r '.project // ""' "$item") || return 1
  text=$(jq -r '.text // ""' "$item") || return 1
  printf 'reply %s\n' "$project" > "$SPEAKINGFILE"
  TEXT="${project:+For $project. }$text"
  speak_text >/dev/null 2>&1 && wait_playback
  return 0
}

# The one queue player. Exactly one runs at a time, holding speaker.lock for as
# long as it is speaking. Modes:
#   drain  started by --enqueue: speak the oldest waiting reply
#   next   started by `next`: the same, or "Nothing waiting."
#   ack    speak the acknowledgement in file $2
#   replay speak the saved response in file $2, which stays where it is; the
#          one mode that waits for the lock, because `replay` has just stopped
#          whatever held it
# None of the others interrupts. When the lock is taken, each leaves word for the
# player that holds it instead: drain marks the queue fresh (and asks for it
# to be played straight away if what is speaking is only an acknowledgement),
# next asks for the next reply to follow the current one, and ack plays the
# tone over whatever is speaking.
#
# When the player finishes, a waiting reply is played only if `next` asked for
# it while it was speaking. Otherwise a reply still waiting gets the tone.
queue_run() {
  local mode="${1:-drain}" ackfile="${2:-}" item want=0 spoke=0
  exec 9>"$LOCKFILE"
  # A replay was asked for by hand and has just stopped the player that holds
  # the lock, so it waits for that player to let go instead of leaving word.
  local flock_args=(-n)
  [[ "$mode" == replay ]] && flock_args=(-w 10)
  if ! flock "${flock_args[@]}" 9; then
    case "$mode" in
      ack)  play_tone ;;
      next) : > "$AUTOPLAYFILE" ;;
      replay) ;;
      *)    : > "$FRESHFILE"
            [[ "$(cat "$SPEAKINGFILE" 2>/dev/null)" == ack ]] && : > "$AUTOPLAYFILE" ;;
    esac
    [[ -n "$ackfile" ]] && rm -f "$ackfile"
    return 0
  fi
  rm -f "$HALTFILE"

  if [[ "$mode" == ack ]]; then
    if playing; then
      play_tone
    else
      echo ack > "$SPEAKINGFILE"
      hold_while_listening
      TEXT=$(cat "$ackfile" 2>/dev/null)
      [[ -n "${TEXT//[[:space:]]/}" ]] && speak_text >/dev/null 2>&1 && wait_playback
      spoke=1
    fi
    rm -f "$ackfile"
  elif [[ "$mode" == replay ]]; then
    # $2 is the saved response to speak. It is not removed afterwards.
    [[ -f "$ackfile" ]] && replay_item "$ackfile"
    spoke=1
  elif playing; then
    # Playback started outside the queue, by resume or restart. Let it finish.
    echo other > "$SPEAKINGFILE"
    wait_playback
    [[ "$mode" == next ]] && : > "$AUTOPLAYFILE"
  else
    want=1
  fi

  while [[ ! -e "$HALTFILE" ]]; do
    if (( ! want )); then
      [[ -e "$AUTOPLAYFILE" ]] || break
      rm -f "$AUTOPLAYFILE"
    fi
    want=0
    rm -f "$FRESHFILE"
    if item=$(oldest_item); then
      speak_item "$item"
      spoke=1
    else
      if [[ "$mode" == next ]] && (( ! spoke )); then
        echo nothing > "$SPEAKINGFILE"
        hold_while_listening
        TEXT="Nothing waiting."
        speak_text >/dev/null 2>&1 && wait_playback
        spoke=1
      fi
      break
    fi
  done

  rm -f "$AUTOPLAYFILE" "$SPEAKINGFILE" "$FRESHFILE"
  [[ ! -e "$HALTFILE" ]] && oldest_item >/dev/null && play_tone
  flock -u 9
  exec 9>&-
  # A reply that arrived after the last look at the queue, while the lock was
  # still held, found the player busy and was left for it. Nothing is speaking
  # now, so it gets the treatment any reply gets when nothing is speaking.
  if [[ -e "$FRESHFILE" ]]; then
    rm -f "$FRESHFILE"
    exec bash "$SELF" --queue-run drain
  fi
  return 0
}

# --- dispatch ------------------------------------------------------------------
case "$MODE" in
  run)
    queue_run "${RUN_ARGS[@]}"
    exit 0 ;;

  enqueue)
    extract_text || exit 1
    if [[ "$PRINT_ONLY" -eq 1 ]]; then printf '%s\n' "$TEXT"; exit 0; fi
    enqueue_text || { echo "talk: could not write to the queue in $QUEUEDIR" >&2; exit 1; }
    if speaking; then
      n=$(queue_count)
      echo "Queued for later; $n waiting. (say \"what else\" or run talk.sh next)"
    else
      echo "Speaking now. (/talk pause to interrupt)"
    fi
    start_runner drain
    exit 0 ;;

  next)
    if speaking; then
      echo "Will play the next reply after this one."
    else
      echo "Playing the next reply."
    fi
    start_runner next
    exit 0 ;;

  replay)
    item=$(saved_reply "$REPLAY_ID") || { echo "talk: no saved response with id '$REPLAY_ID'" >&2; exit 1; }
    # Stopping whatever is speaking is the point of asking by hand. A reply that
    # was still waiting is taken off the queue, so it is not also spoken a
    # second time when its turn comes.
    rm -f "$QUEUEDIR"/*-"$REPLAY_ID".json
    halt_and_mark stop >/dev/null
    start_runner replay "$item"
    echo "Playing the saved response."
    exit 0 ;;

  say)
    # What the user just asked is the priority: its reply is saved like any
    # queued reply, then taken off the queue and spoken now, stopping whatever
    # is speaking. Older waiting replies stay waiting.
    SAY_TEXT=$(cat)
    extract_text || exit 1
    if [[ "$PRINT_ONLY" -eq 1 ]]; then printf '%s\n' "$TEXT"; exit 0; fi
    enqueue_text || { echo "talk: could not write to the queue in $QUEUEDIR" >&2; exit 1; }
    if item=$(saved_reply "$ENQUEUED_ID"); then
      rm -f "$QUEUEDIR"/*-"$ENQUEUED_ID".json
      halt_and_mark stop >/dev/null
      start_runner replay "$item"
    else
      # No saved copy to replay from, so it plays from the queue instead.
      halt_and_mark stop >/dev/null
      start_runner drain
    fi
    echo "Speaking now. (/talk pause to interrupt)"
    exit 0 ;;

  ack)
    if [[ -t 0 ]]; then
      extract_text || exit 1
    else
      TEXT=$(cat)
    fi
    [[ -n "${TEXT//[[:space:]]/}" ]] || exit 0
    ackfile="$STATE_DIR/ack-$$.txt"
    printf '%s' "$TEXT" > "$ackfile"
    start_runner ack "$ackfile"
    exit 0 ;;
esac

extract_text || exit 1
if [[ "$PRINT_ONLY" -eq 1 ]]; then printf '%s\n' "$TEXT"; exit 0; fi
speak_text
exit $?
