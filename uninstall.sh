#!/usr/bin/env bash
# claude-talk uninstaller
set -euo pipefail

"$HOME/.claude/talk.sh" stop >/dev/null 2>&1 || true

VENV="${XDG_DATA_HOME:-$HOME/.local/share}/claude-talk/venv"
if [[ -x "$VENV/bin/python" && -f "$HOME/.claude/talk-xtts.py" ]]; then
  "$VENV/bin/python" "$HOME/.claude/talk-xtts.py" stop >/dev/null 2>&1 || true
fi

for f in "$HOME/.claude/talk.sh" "$HOME/.claude/commands/talk.md" "$HOME/.claude/talk-xtts.py"; do
  if [[ -e "$f" ]]; then rm -f "$f"; echo "removed $f"; fi
  if [[ -e "$f.bak" ]]; then mv "$f.bak" "$f"; echo "restored $f from backup"; fi
done

rm -rf "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-talk"
echo "done — config at ~/.config/claude-talk left in place"

if [[ -d "$VENV" ]]; then
  echo
  echo "the XTTS virtualenv and model were left in place; remove them with:"
  echo "  rm -rf ${XDG_DATA_HOME:-$HOME/.local/share}/claude-talk"
  echo "  rm -rf ${XDG_DATA_HOME:-$HOME/.local/share}/tts/tts_models--multilingual--multi-dataset--xtts_v2"
fi
