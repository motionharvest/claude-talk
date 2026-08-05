#!/usr/bin/env bash
# claude-talk uninstaller
set -euo pipefail

"$HOME/.claude/talk.sh" stop >/dev/null 2>&1 || true

for f in "$HOME/.claude/talk.sh" "$HOME/.claude/commands/talk.md"; do
  if [[ -e "$f" ]]; then rm -f "$f"; echo "removed $f"; fi
  if [[ -e "$f.bak" ]]; then mv "$f.bak" "$f"; echo "restored $f from backup"; fi
done

rm -rf "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-talk"
echo "done — config at ~/.config/claude-talk left in place"
