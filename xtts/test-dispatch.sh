#!/usr/bin/env bash
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TALK="$SELF_DIR/../talk.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SID=11111111-2222-3333-4444-555555555555

mkdir -p "$WORK/home/.claude/projects/-test" "$WORK/run"

python3 - "$WORK/home/.claude/projects/-test/$SID.jsonl" <<'PY'
import json
import sys

rows = [
    {"type": "user", "message": {"content": "hi"}},
    {"type": "assistant", "message": {"content": [
        {"type": "text", "text": "Let me check."},
        {"type": "tool_use", "id": "t", "name": "Bash", "input": {}},
    ]}},
    {"type": "assistant", "message": {"content": [
        {"type": "text", "text": "The serializer is the bottleneck. Use `orjson` instead."},
    ]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row) + "\n")
PY

cat > "$WORK/stub.py" <<'PY'
"""Stand in for xtts_server.py so the dispatch can be tested without the model."""

import argparse
import math
import struct
import sys
import wave

parser = argparse.ArgumentParser()
parser.add_argument("--socket")
sub = parser.add_subparsers(dest="mode")
say = sub.add_parser("say")
for flag in ("--text-file", "--out", "--language", "--speed", "--speaker",
             "--speaker-wav", "--text", "--device"):
    say.add_argument(flag)
stream = sub.add_parser("stream")
for flag in ("--text-file", "--outdir", "--language", "--speed", "--speaker",
             "--speaker-wav", "--text", "--device", "--first-limit"):
    stream.add_argument(flag)
sub.add_parser("speakers")
sub.add_parser("status")
sub.add_parser("preload")
sub.add_parser("cancel")
args = parser.parse_args()


def tone(path, seconds=1.0):
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(24000)
        frames = int(24000 * seconds)
        handle.writeframes(
            b"".join(struct.pack("<h", int(8000 * math.sin(i / 20))) for i in range(frames))
        )

if args.mode == "say":
    text = open(args.text_file, encoding="utf-8").read()
    sys.stderr.write(
        f"STUB speed={args.speed} speaker={args.speaker} wav={args.speaker_wav} "
        f"lang={args.language} chars={len(text)}\n"
    )
    with wave.open(args.out, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(24000)
        handle.writeframes(
            b"".join(struct.pack("<h", int(8000 * math.sin(i / 20))) for i in range(24000))
        )
    print(args.out)
elif args.mode == "stream":
    import os

    text = open(args.text_file, encoding="utf-8").read()
    sys.stderr.write(
        f"STUB stream speed={args.speed} speaker={args.speaker} "
        f"wav={args.speaker_wav} lang={args.language} chars={len(text)}\n"
    )
    os.makedirs(args.outdir, exist_ok=True)
    for name in os.listdir(args.outdir):
        os.unlink(os.path.join(args.outdir, name))
    for index in range(3):
        tone(os.path.join(args.outdir, f"{index:03d}.wav"), 0.4)
    open(os.path.join(args.outdir, "END"), "wb").close()
    print(args.outdir)
elif args.mode == "cancel":
    pass
elif args.mode == "speakers":
    print("Claribel Dervla")
    print("Damien Black")
elif args.mode == "status":
    print("stub status: ok")
elif args.mode == "preload":
    print("model loaded on stub")
PY

# A fake sound server keeps the streaming tests silent while still proving the
# feeder converted each chunk and the player consumed them in order.
mkdir -p "$WORK/bin"
PLAYLOG="$WORK/played.txt"
for fake in pw-play paplay; do
  cat > "$WORK/bin/$fake" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$PLAYLOG"
SH
  chmod +x "$WORK/bin/$fake"
done

# The default run pins TALK_STREAM=0 so the single file path is what gets
# asserted, and so no check reaches a real sound server by accident.
run() {
  env HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run" CLAUDE_CODE_SESSION_ID="$SID" \
      TALK_XTTS_PYTHON=/usr/bin/python3 TALK_XTTS_SERVER="$WORK/stub.py" \
      TALK_STREAM=0 "$@"
}
run_streaming() {
  env HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run" CLAUDE_CODE_SESSION_ID="$SID" \
      TALK_XTTS_PYTHON=/usr/bin/python3 TALK_XTTS_SERVER="$WORK/stub.py" \
      TALK_STREAM=1 PATH="$WORK/bin:$PATH" PLAYLOG="$PLAYLOG" "$@"
}
await_playback() {
  local waited=0
  while [[ $waited -lt 100 ]]; do
    [[ -f "$WORK/run/claude-talk/ready/END" ]] && [[ $(wc -l < "$PLAYLOG" 2>/dev/null || echo 0) -ge 3 ]] && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}
without_xtts() {
  env HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run" CLAUDE_CODE_SESSION_ID="$SID" \
      TALK_XTTS_PYTHON=/nonexistent TALK_XTTS_SERVER=/nonexistent "$@"
}
ERRLOG="$WORK/run/claude-talk/err.log"
PASS=0
FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    echo "  PASS $1"; PASS=$((PASS + 1))
  else
    echo "  FAIL $1"; FAIL=$((FAIL + 1))
  fi
}

echo "syntax"
check "talk.sh parses"          'bash -n "$TALK"'
check "xtts_server.py compiles" 'python3 -m py_compile "$SELF_DIR/xtts_server.py"'
check "install-xtts.sh parses"  'bash -n "$SELF_DIR/install-xtts.sh"'

echo "chunking"
check "chunker holds its limits" 'python3 "$SELF_DIR/test-chunker.py"'

echo "dispatch"
check "help prints the engines"   'run bash "$TALK" --help | grep -q "Engines:"'
check "print extracts the answer" 'run bash "$TALK" --print | grep -q "serializer is the bottleneck"'
check "auto prefers xtts"         'run bash "$TALK" --doctor | grep -q "auto -> xtts"'
check "list-voices uses xtts"     'run bash "$TALK" --list-voices | grep -q "Damien Black"'
check "warm reaches the server"   'run bash "$TALK" --warm | grep -q "model loaded"'
check "unknown engine rejected"   '! run bash "$TALK" --engine bogus'
check "speaks through xtts"       'run bash "$TALK" --engine xtts --player linux | grep -q "via XTTS-v2"'
check "wav was produced"          '[ -s "$WORK/run/claude-talk/speech.wav" ]'
check "no stale mp3 remains"      '! [ -e "$WORK/run/claude-talk/speech.mp3" ]'
check "clone clip forwarded"      'run bash "$TALK" --engine xtts --speaker /tmp/v.wav --player linux; grep -q "wav=/tmp/v.wav" "$ERRLOG"'
check "voice override forwarded"  'run bash "$TALK" --engine xtts --voice "Damien Black" --player linux; grep -q "speaker=Damien Black" "$ERRLOG"'
check "language forwarded"        'run bash "$TALK" --engine xtts --lang fr --player linux; grep -q "lang=fr" "$ERRLOG"'
check "explicit speed wins"       'run bash "$TALK" --engine xtts --speed 1.5 --player linux; grep -q "speed=1.5" "$ERRLOG"'
check "rate becomes a multiplier" 'run env TALK_RATE=+18% bash "$TALK" --engine xtts --player linux; grep -q "speed=1.180" "$ERRLOG"'
check "rate clamps at 2.0"        'run env TALK_RATE=+900% bash "$TALK" --engine xtts --player linux; grep -q "speed=2.000" "$ERRLOG"'
check "rate clamps at 0.5"        'run env TALK_RATE=-99% bash "$TALK" --engine xtts --player linux; grep -q "speed=0.500" "$ERRLOG"'
check "missing xtts is explicit"  'without_xtts bash "$TALK" --engine xtts 2>&1 | grep -q "xtts is not installed"'
check "stop is clean"             'run bash "$TALK" stop | grep -q "Playback stopped"'

echo "streaming"
: > "$PLAYLOG"
check "streaming path is taken"   'run_streaming bash "$TALK" --engine xtts --player linux | grep -q "streaming"'
check "every chunk reaches a player" 'await_playback'
check "chunks play in order"      'diff <(cat "$PLAYLOG") <(printf "%s/run/claude-talk/ready/000.wav\n%s/run/claude-talk/ready/001.wav\n%s/run/claude-talk/ready/002.wav\n" "$WORK" "$WORK" "$WORK")'
check "converted chunks are real wav" 'file "$WORK/run/claude-talk/ready/000.wav" | grep -qi "wave audio"'
check "stream stops cleanly"      'run bash "$TALK" stop >/dev/null; sleep 0.5; ! pgrep -f "stream-feed $WORK" >/dev/null'
check "TALK_STREAM=0 uses one file" 'run_streaming env TALK_STREAM=0 bash "$TALK" --engine xtts --player linux | grep -q "via XTTS-v2\. "'

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
