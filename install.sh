#!/usr/bin/env bash
# claude-talk installer
#   curl -fsSL https://raw.githubusercontent.com/motionharvest/claude-talk/main/install.sh | bash
# or, from a clone:
#   ./install.sh

set -euo pipefail

REPO="motionharvest/claude-talk"
RAW="https://raw.githubusercontent.com/$REPO/main"
DEST="$HOME/.claude"
CMDS="$DEST/commands"

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); grn=$(tput setaf 2 2>/dev/null || true)
ylw=$(tput setaf 3 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)

have() { command -v "$1" >/dev/null 2>&1; }
ok()   { echo "  ${grn}✓${rst} $*"; }
warn() { echo "  ${ylw}!${rst} $*"; }
bad()  { echo "  ${red}✗${rst} $*"; }

echo
echo "${bold}claude-talk${rst} — speak Claude Code's last response aloud"
echo

# --- dependencies ----------------------------------------------------------
echo "${bold}Checking dependencies${rst}"
MISSING=()
for c in jq python3; do
  if have "$c"; then ok "$c"; else bad "$c"; MISSING+=("$c"); fi
done

if have edge-tts; then
  ok "edge-tts"
else
  bad "edge-tts"
  MISSING+=("edge-tts")
fi

if have ffmpeg; then ok "ffmpeg"; else warn "ffmpeg (recommended — needed on WSL and for clean Linux playback)"; fi

# a way to actually make sound
PLAYER_OK=0
case "$(uname -s)" in
  Darwin) have afplay && { ok "afplay (macOS audio)"; PLAYER_OK=1; } ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      have powershell.exe && { ok "powershell.exe (WSL → Windows audio)"; PLAYER_OK=1; }
    fi
    for p in paplay pw-play ffplay mpv mpg123; do
      have "$p" && { ok "$p"; PLAYER_OK=1; break; }
    done
    ;;
esac
[[ "$PLAYER_OK" -eq 1 ]] || warn "no audio player found — install ffmpeg or pulseaudio-utils"

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo
  echo "${bold}Install what's missing, then re-run:${rst}"
  for m in "${MISSING[@]}"; do
    case "$m" in
      edge-tts) echo "  pip install edge-tts        ${dim}# or: pipx install edge-tts${rst}" ;;
      jq)       echo "  ${dim}apt install jq${rst} / ${dim}brew install jq${rst}" ;;
      python3)  echo "  ${dim}apt install python3${rst} / ${dim}brew install python${rst}" ;;
    esac
  done
  echo
  exit 1
fi

# --- install ---------------------------------------------------------------
echo
echo "${bold}Installing${rst}"
mkdir -p "$CMDS"

# Only prefer local files when this script is genuinely running from a clone.
# Piped through `curl | bash` there is no script file, and $0 is just "bash" —
# resolving that to "." would copy whatever happens to sit in the cwd.
SELF_DIR=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

fetch() { # fetch <repo-relative-path> <dest>
  if [[ -n "$SELF_DIR" && -f "$SELF_DIR/$1" ]]; then
    cp "$SELF_DIR/$1" "$2"
  else
    curl -fsSL "$RAW/$1" -o "$2"
  fi
}

for f in "$DEST/talk.sh" "$CMDS/talk.md"; do
  [[ -e "$f" ]] && { cp "$f" "$f.bak"; warn "backed up existing $(basename "$f") → $(basename "$f").bak"; }
done

fetch talk.sh "$DEST/talk.sh"
chmod +x "$DEST/talk.sh"
ok "$DEST/talk.sh"

fetch commands/talk.md "$CMDS/talk.md"
ok "$CMDS/talk.md"

echo
echo "${bold}Done.${rst} Start a new Claude Code session (or run ${bold}/reload${rst}) and try:"
echo
echo "    ${bold}/talk${rst}              speak the last response"
echo "    ${bold}/talk stop${rst}         stop playback"
echo "    ${bold}/talk --doctor${rst}     check your audio setup"
echo
echo "${dim}Config: ~/.config/claude-talk/config  (see README)${rst}"
echo
