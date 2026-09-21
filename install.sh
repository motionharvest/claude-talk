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
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-talk"
KEY_FILE="$CONFIG_DIR/google-api-key"

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

if have ffmpeg; then ok "ffmpeg"; else warn "ffmpeg (recommended — needed on WSL and for clean Linux playback)"; fi
if have edge-tts; then ok "edge-tts (free fallback engine)"; else warn "edge-tts — the free engine; pip install edge-tts"; fi

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

# Earlier versions shipped a local XTTS engine. It is gone; clean up after it
# so /talk doesn't look like it still has a second engine installed.
if [[ -e "$DEST/talk-xtts.py" ]]; then
  rm -f "$DEST/talk-xtts.py"
  warn "removed the old XTTS server ($DEST/talk-xtts.py)"
  XTTS_VENV="${XDG_DATA_HOME:-$HOME/.local/share}/claude-talk"
  [[ -d "$XTTS_VENV" ]] && \
    warn "its virtualenv and model are still using disk: ${dim}rm -rf $XTTS_VENV${rst}"
fi

# --- google api key --------------------------------------------------------
# Read straight into the key file. Typing it at a prompt keeps it out of shell
# history, out of the process list, and out of this script's arguments.
echo
if [[ -s "$KEY_FILE" ]]; then
  ok "Google API key already at $KEY_FILE"
elif [[ -t 0 ]]; then
  echo "${bold}Google Cloud Text-to-Speech${rst} ${dim}(optional — edge-tts works without it)${rst}"
  echo "  Enable the API and make a key at ${dim}https://console.cloud.google.com/apis/credentials${rst}"
  echo "  Leave blank to skip."
  printf '  API key: '
  read -rs GOOGLE_KEY || GOOGLE_KEY=""
  echo
  if [[ -n "$GOOGLE_KEY" ]]; then
    mkdir -p "$CONFIG_DIR"
    (umask 077; printf '%s' "$GOOGLE_KEY" > "$KEY_FILE")
    unset GOOGLE_KEY
    if "$DEST/talk.sh" --check-key; then
      ok "$KEY_FILE"
    else
      warn "saved to $KEY_FILE anyway — fix it there, or delete the file"
    fi
  fi
else
  echo "${bold}Google Cloud Text-to-Speech${rst} ${dim}(optional)${rst}"
  echo "  ${dim}mkdir -p $CONFIG_DIR${rst}"
  echo "  ${dim}printf '%s' 'YOUR_KEY' > $KEY_FILE && chmod 600 $KEY_FILE${rst}"
fi

echo
echo "${bold}Done.${rst} Start a new Claude Code session (or run ${bold}/reload${rst}) and try:"
echo
echo "    ${bold}/talk${rst}              speak the last response"
echo "    ${bold}/talk stop${rst}         stop playback"
echo "    ${bold}/talk --doctor${rst}     check your audio setup"
echo
echo "${dim}Config: ~/.config/claude-talk/config  (see README)${rst}"
echo
