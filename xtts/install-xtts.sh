#!/usr/bin/env bash
set -euo pipefail

DEST="$HOME/.claude"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/claude-talk"
VENV="$DATA/venv"
SERVER="$DEST/talk-xtts.py"
LICENSE_URL="https://coqui.ai/cpml"
MODEL="tts_models/multilingual/multi-dataset/xtts_v2"

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); grn=$(tput setaf 2 2>/dev/null || true)
ylw=$(tput setaf 3 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)

have() { command -v "$1" >/dev/null 2>&1; }
ok()   { echo "  ${grn}v${rst} $*"; }
warn() { echo "  ${ylw}!${rst} $*"; }
bad()  { echo "  ${red}x${rst} $*"; }

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo
echo "${bold}claude-talk XTTS-v2${rst} — local neural speech, no network at speak time"
echo

if [[ ! -f "$SELF_DIR/xtts_server.py" ]]; then
  bad "xtts_server.py not found next to this script"
  exit 1
fi

echo "${bold}Checking the host${rst}"
have python3 || { bad "python3"; exit 1; }
PYVER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
ok "python3 $PYVER"

DEVICE=cpu
if have nvidia-smi && nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
  DEVICE=cuda
  ok "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
else
  warn "no GPU detected — XTTS-v2 on CPU is several times slower than real time"
fi

if have ffmpeg; then ok "ffmpeg"; else warn "ffmpeg missing — playback quality suffers"; fi

FREE_GB=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$FREE_GB" && "$FREE_GB" -lt 10 ]]; then
  warn "only ${FREE_GB}G free — torch and the model need about 8G"
else
  ok "disk space"
fi

echo
echo "${bold}License${rst}"
echo "  XTTS-v2 is released under the Coqui Public Model License."
echo "  It permits non-commercial use only. Read it at ${LICENSE_URL}"
echo
if [[ "${TALK_XTTS_ACCEPT_LICENSE:-}" == "1" ]]; then
  ok "accepted through TALK_XTTS_ACCEPT_LICENSE=1"
else
  read -r -p "  Do you accept the Coqui Public Model License? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ok "accepted" ;;
    *) echo; echo "Not accepted. Nothing was installed."; exit 1 ;;
  esac
fi

echo
echo "${bold}Building the environment${rst}  ${dim}$VENV${rst}"
mkdir -p "$DATA"
if have uv; then
  uv venv --python python3 "$VENV" >/dev/null
  ok "venv created with uv"
  PIP=(uv pip install --python "$VENV/bin/python" --quiet)
else
  python3 -m venv "$VENV"
  ok "venv created with python -m venv"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  PIP=("$VENV/bin/python" -m pip install --quiet)
fi

echo "  installing torch — this downloads a few gigabytes"
if [[ -n "${TALK_TORCH_INDEX:-}" ]]; then
  "${PIP[@]}" --index-url "$TALK_TORCH_INDEX" torch torchaudio
elif [[ "$DEVICE" == cpu ]]; then
  "${PIP[@]}" --index-url https://download.pytorch.org/whl/cpu torch torchaudio
else
  "${PIP[@]}" torch torchaudio
fi
ok "torch"

echo "  installing coqui-tts"
"${PIP[@]}" "coqui-tts>=0.26.0"
ok "coqui-tts"

echo
echo "${bold}Downloading XTTS-v2${rst}  ${dim}about 2G, once${rst}"
COQUI_TOS_AGREED=1 "$VENV/bin/python" - "$MODEL" <<'PY'
import sys
from TTS.utils.manage import ModelManager

ModelManager().download_model(sys.argv[1])
PY
ok "model downloaded"

echo
echo "${bold}Installing the module${rst}"
mkdir -p "$DEST"
[[ -e "$SERVER" ]] && cp "$SERVER" "$SERVER.bak"
cp "$SELF_DIR/xtts_server.py" "$SERVER"
chmod +x "$SERVER"
ok "$SERVER"

"$VENV/bin/python" "$SERVER" status || true

echo
echo "${bold}Done.${rst} /talk now uses XTTS-v2. Useful commands:"
echo
echo "    ${bold}/talk${rst}                     speak with XTTS-v2"
echo "    ${bold}/talk --engine edge${rst}       use the old cloud voice for one run"
echo "    ${bold}/talk --list-voices${rst}       list the built-in XTTS speakers"
echo "    ${bold}/talk --warm${rst}              load the model before you need it"
echo "    ${bold}/talk --doctor${rst}            check the whole setup"
echo
echo "${dim}Clone a voice: put a clean 6-30 second wav somewhere and set${rst}"
echo "${dim}  TALK_XTTS_SPEAKER_WAV=/path/to/voice.wav  in ~/.config/claude-talk/config${rst}"
echo
