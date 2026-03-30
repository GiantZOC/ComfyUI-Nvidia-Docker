#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh
# - 11-onnxruntime-gpu.sh  (insightface requires onnxruntime)

# Install insightface from PyPI
#
# https://github.com/deepinsight/insightface

# --- CONFIGURATION ---
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
# ---------------------

# --- COLOR CODES (for console)---
LOG_ERR=$(printf '\033[0;41m') # White on RED BG

LOG_WARN=$(printf '\033[0;33m') # Yellow

LOG_OK=$(printf '\033[0;32m') # GREEN

LOG_INFO=$(printf '\033[0m') # No Color

NC=$(printf '\033[0m') # No Color
# --------------------------------

set -e

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo -e "!! Exiting insightface Script (ID: $$)"
  exit 1
}

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

# Check if onnxruntime-gpu is installed (required by insightface)
if ! pip show onnxruntime-gpu > /dev/null 2>&1; then
    echo "${LOG_WARN}Warning:${NC} onnxruntime-gpu is not installed. insightface requires onnxruntime."
    echo "         Run 11-onnxruntime-gpu.sh first, or insightface will fall back to CPU onnxruntime."
fi

# Check if insightface is already installed
if pip show insightface > /dev/null 2>&1; then
    if [ "$FORCE_REINSTALL" = "false" ]; then
        echo "${LOG_INFO}INFO:${NC} insightface is already installed."
        echo "     (Set FORCE_REINSTALL=true to force reinstall)"
        exit 0
    else
        echo "${LOG_WARN}Warning:${NC} FORCE_REINSTALL=true. Reinstalling insightface..."
        pip uninstall -y insightface || error_exit "Failed to uninstall insightface"
    fi
fi

# We need both uv and the cache directory to enable build with uv
use_uv=true
uv="/comfy/mnt/venv/bin/uv"
uv_cache="/comfy/mnt/uv_cache"
if [ ! -x "$uv" ] || [ ! -d "$uv_cache" ]; then use_uv=false; fi

echo "== PIP3_CMD: \"${PIP3_CMD}\""
if [ "A$use_uv" == "Atrue" ]; then
  echo "== Using uv"
  echo " - uv: $uv"
  echo " - uv_cache: $uv_cache"
else
  echo "== Using pip"
fi

CMD="${PIP3_CMD} insightface"
echo "CMD: \"${CMD}\""
${CMD} || error_exit "Failed to install insightface"

# insightface pulls in CPU onnxruntime as a dependency, which conflicts with onnxruntime-gpu.
# Remove the CPU version if the GPU version is present (or was present before this install).
if pip show onnxruntime > /dev/null 2>&1; then
    if pip show onnxruntime-gpu > /dev/null 2>&1; then
        echo "${LOG_WARN}Warning:${NC} insightface installed CPU onnxruntime alongside GPU version. Removing CPU version..."
        pip uninstall -y onnxruntime || error_exit "Failed to remove CPU onnxruntime"
        echo "${LOG_INFO}INFO:${NC} CPU onnxruntime removed. GPU version retained."
    else
        echo "${LOG_WARN}Warning:${NC} Only CPU onnxruntime is present. Run 11-onnxruntime-gpu.sh to install the GPU version."
    fi
fi

echo "${LOG_OK}SUCCESS:${NC} insightface installed"

exit 0
