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

CPU_INDEX="https://download.pytorch.org/whl/cpu"

# A torch wheel built for a newer CUDA than the driver supports imports fine and
# then fails at torch.cuda.init(), so pick the index from the driver's own
# reported CUDA version rather than trusting the default wheel.
torch_index() {
  local reported major minor
  reported=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
  [[ -n "$reported" ]] || return 1
  major=${reported%%.*}
  minor=${reported##*.}
  if   (( major >= 13 ));                then printf 'https://download.pytorch.org/whl/cu130'
  elif (( major == 12 && minor >= 8 )); then printf 'https://download.pytorch.org/whl/cu128'
  elif (( major == 12 && minor >= 6 )); then printf 'https://download.pytorch.org/whl/cu126'
  else return 1
  fi
}

DEVICE=cpu
TORCH_INDEX="$CPU_INDEX"
if have nvidia-smi && nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
  ok "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
  if resolved=$(torch_index); then
    DEVICE=cuda
    TORCH_INDEX="$resolved"
    ok "driver supports CUDA $(nvidia-smi | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)"
  else
    warn "the driver is older than CUDA 12.6 — falling back to CPU; update the GPU driver for speed"
  fi
else
  warn "no GPU detected — XTTS-v2 on CPU is slower than real time"
fi
[[ -n "${TALK_TORCH_INDEX:-}" ]] && TORCH_INDEX="$TALK_TORCH_INDEX"

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
  uv venv --python "${TALK_XTTS_PYVER:-3.11}" "$VENV" >/dev/null
  ok "venv created with uv on python ${TALK_XTTS_PYVER:-3.11}"
  PIP=(uv pip install --python "$VENV/bin/python" --quiet)
else
  python3 -m venv "$VENV"
  ok "venv created with python -m venv"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  PIP=("$VENV/bin/python" -m pip install --quiet)
fi

echo "  installing torch from $TORCH_INDEX — this downloads a few gigabytes"
"${PIP[@]}" --index-url "$TORCH_INDEX" torch torchaudio
ok "torch"

# coqui-tts asks for transformers>=4.57 with no upper bound, and transformers 5
# dropped isin_mps_friendly, which coqui-tts still imports. Resolve both in one
# call so the solver picks a 4.x release instead of installing 5 and downgrading.
echo "  installing coqui-tts"
"${PIP[@]}" "coqui-tts>=0.26.0" "transformers>=4.57,<5"
ok "coqui-tts"

# From torch 2.9 coqui-tts refuses to import without torchcodec. Its CUDA build
# links libnppicc, which torch does not preload, so the CPU build is the one
# that works; nothing here decodes video and audio decoding is unaffected.
echo "  installing torchcodec"
"${PIP[@]}" --index-url "$CPU_INDEX" torchcodec
ok "torchcodec"

echo
echo "${bold}Checking the environment${rst}"
"$VENV/bin/python" - "$DEVICE" <<'PY'
import sys
import warnings

warnings.filterwarnings("ignore")
import torch
from TTS.tts.models.xtts import Xtts  # noqa: F401

print(f"  torch {torch.__version__}")
if sys.argv[1] == "cuda":
    if torch.cuda.is_available():
        print(f"  cuda ready on {torch.cuda.get_device_name(0)}")
    else:
        print("  WARNING: torch cannot reach the GPU; speech will run on the CPU")
print("  coqui-tts imports")
PY

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
