#!/usr/bin/env bash
# claude-talk uninstaller
set -euo pipefail

"$HOME/.claude/talk.sh" stop >/dev/null 2>&1 || true

for f in "$HOME/.claude/talk.sh" "$HOME/.claude/commands/talk.md"; do
  if [[ -e "$f" ]]; then rm -f "$f"; echo "removed $f"; fi
  if [[ -e "$f.bak" ]]; then mv "$f.bak" "$f"; echo "restored $f from backup"; fi
done

# Left over from the versions that shipped a local XTTS engine.
XTTS_VENV="${XDG_DATA_HOME:-$HOME/.local/share}/claude-talk"
if [[ -e "$HOME/.claude/talk-xtts.py" ]]; then
  rm -f "$HOME/.claude/talk-xtts.py"
  echo "removed $HOME/.claude/talk-xtts.py"
fi

rm -rf "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-talk"
echo "done — config and API key at ~/.config/claude-talk left in place"

if [[ -d "$XTTS_VENV" ]]; then
  echo
  echo "the old XTTS virtualenv and model are still on disk; remove them with:"
  echo "  rm -rf $XTTS_VENV"
  echo "  rm -rf ${XDG_DATA_HOME:-$HOME/.local/share}/tts/tts_models--multilingual--multi-dataset--xtts_v2"
fi
