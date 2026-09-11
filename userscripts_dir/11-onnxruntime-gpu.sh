#!/bin/bash

# Pre-requisites (run first):
# - 00-nvidiaDev.sh

# Install onnxruntime-gpu from PyPI
#
# https://onnxruntime.ai/
# https://github.com/microsoft/onnxruntime

# --- CONFIGURATION ---
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
# ---------------------

# Building it from source takes a long time: try not to delete it if that is your goal
# ONLY set to true if you built from source (ie no wheel available --there are some for x86_64)
ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT="${ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT:-false}"

# --- COLOR CODES (for console)---
LOG_ERR=$(printf '\033[0;41m') # White on RED BG
# LOG_ERR=$(printf '\033[0;91m') # Red on Black BG
# LOG_ERR=$(printf '\033[0m') # No Color

LOG_WARN=$(printf '\033[0;33m') # Yellow
# LOG_WARN=$(printf '\033[0m') # No Color 

LOG_OK=$(printf '\033[0;32m') # GREEN
# LOG_OK=$(printf '\033[0m') # No Color 

# LOG_INFO=$(printf '\033[0;32m') # Green 
LOG_INFO=$(printf '\033[0m') # No Color

NC=$(printf '\033[0m') # No Color
# --------------------------------

set -e

error_exit() {
  echo -n -e "${LOG_ERR}!! ERROR: ${NC}"
  echo $*
  echo -e "!! Exiting onnxruntime-gpu Script (ID: $$)"
  exit 1
}

source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"

echo "Checking for existing onnxruntime installations..."

SITE_PACKAGES="/comfy/mnt/venv/lib/python3.12/site-packages"
BUILD_BASE_FILE="/comfy/mnt/venv/.build_base.txt"

# `pip show` only proves the dist-info survived. Uninstalling the CPU `onnxruntime` deletes the Python
# layer shared with the GPU package (onnxruntime/__init__.py etc) while leaving onnxruntime_gpu's
# dist-info behind, so the package still looks installed while `import onnxruntime` yields an empty
# namespace package -- which surfaces as "module 'onnxruntime' has no attribute 'InferenceSession'".
# Ask the interpreter instead of the package database.
ort_python_layer_ok() {
    python -c "import onnxruntime, sys; sys.exit(0 if onnxruntime.__file__ and hasattr(onnxruntime, 'InferenceSession') else 1)" >/dev/null 2>&1
}

# Reinstall the GPU package from the source-built wheel it originally came from, restoring the Python
# layer without a rebuild (building from source on aarch64/GB10 takes a very long time).
ort_restore_gpu_from_wheel() {
    local ort_version wheel="" found
    ort_version=$(pip show onnxruntime-gpu 2>/dev/null | awk '/^Version:/{print $2}')

    # pip records the exact wheel it installed, so trust that provenance before guessing at a path
    if [ -n "$ort_version" ] && [ -f "$SITE_PACKAGES/onnxruntime_gpu-${ort_version}.dist-info/direct_url.json" ]; then
        wheel=$(python - "$SITE_PACKAGES/onnxruntime_gpu-${ort_version}.dist-info" <<'PY'
import json, os, sys, urllib.parse
try:
    path = urllib.parse.urlparse(json.load(open(os.path.join(sys.argv[1], "direct_url.json")))["url"]).path
    print(path if os.path.isfile(path) else "")
except Exception:
    print("")
PY
)
    fi

    if [ -z "$wheel" ] && [ -f "$BUILD_BASE_FILE" ]; then
        # torch gets upgraded independently of this wheel, so the live torch version is not a reliable
        # directory key -- search every Torch_* tree, preferring the version already installed.
        local candidates
        candidates=$(find "/comfy/mnt/src/$(cat "$BUILD_BASE_FILE")"/Torch_*/onnxruntime/build/Linux/Release/dist \
            -name "onnxruntime_gpu-*.whl" 2>/dev/null | sort)
        if [ -n "$ort_version" ]; then
            found=$(echo "$candidates" | grep "/onnxruntime_gpu-${ort_version}-" || true)
            [ -n "$found" ] && candidates="$found"
        fi
        wheel=$(echo "$candidates" | grep . | tail -1)
    fi

    if [ -z "$wheel" ]; then
        echo "${LOG_ERR}ERROR:${NC} No pre-built onnxruntime-gpu wheel found under /comfy/mnt/src/*/*/onnxruntime/build/Linux/Release/dist — onnxruntime will be broken. Set ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT=false to trigger a rebuild."
        return 1
    fi

    # --no-deps: the wheel's dependencies are unpinned, so re-resolving them here can move numpy/protobuf
    # under a working venv. Only the package's own files are missing.
    pip install --no-deps --force-reinstall "$wheel" || error_exit "Failed to reinstall onnxruntime-gpu from wheel"
    if ! ort_python_layer_ok; then
        echo "${LOG_ERR}ERROR:${NC} onnxruntime still not importable after installing $wheel"
        return 1
    fi
    echo "${LOG_OK}OK:${NC} onnxruntime-gpu Python layer restored from $wheel"
}

# Check if onnxruntime-gpu is installed
if pip show onnxruntime-gpu > /dev/null 2>&1; then
    # Check if standard onnxruntime (CPU) is ALSO installed
    if pip show onnxruntime > /dev/null 2>&1; then
        # Case: GPU installed AND CPU installed -> Remove both, then install GPU
        echo "${LOG_WARN}Warning:${NC} Found BOTH onnxruntime and onnxruntime-gpu."
        if [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "true" ]; then
            echo "${LOG_WARN}Warning:${NC} ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT is true. Keeping onnxruntime-gpu..."
            echo "Uninstalling CPU onnxruntime..."
            pip uninstall -y onnxruntime || error_exit "Failed to uninstall onnxruntime"
            # The CPU package overwrites the GPU package's Python files, so removing it leaves the
            # Python layer (onnxruntime/__init__.py etc.) deleted. Reinstall from the pre-built wheel
            # to restore those files without triggering a full rebuild.
            if ! ort_python_layer_ok; then
                echo "${LOG_WARN}Warning:${NC} onnxruntime Python files missing after CPU removal — restoring from pre-built wheel..."
                ort_restore_gpu_from_wheel || true
            else
                echo "${LOG_OK}OK:${NC} onnxruntime Python files still intact after CPU removal."
            fi
            exit 0
        else
            echo "Uninstalling both to ensure clean GPU installation..."
            pip uninstall -y onnxruntime onnxruntime-gpu || error_exit "Failed to uninstall conflicting packages"
        fi
    else
        # Case: GPU installed AND CPU NOT installed
        if [ "$FORCE_REINSTALL" = "false" ] || [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "true" ]; then
            # A previous boot (or a manual uninstall) can leave the Python layer deleted with only the
            # dist-info remaining, so verify the import rather than trusting `pip show` -- otherwise the
            # broken venv is declared clean on every restart and never repairs itself.
            if ort_python_layer_ok; then
                echo "${LOG_INFO}INFO:${NC} onnxruntime-gpu is already installed and clean."
                echo "     (Set FORCE_REINSTALL=true in script to force reinstall)"
            else
                echo "${LOG_WARN}Warning:${NC} onnxruntime-gpu is installed but not importable — restoring from pre-built wheel..."
                ort_restore_gpu_from_wheel || true
            fi
            exit 0
        else
            pip uninstall -y onnxruntime-gpu || error_exit "Failed to uninstall onnxruntime-gpu"
        fi
     fi
else
    # Check if standard onnxruntime (CPU) is installed
    if pip show onnxruntime > /dev/null 2>&1; then
        # Case: GPU NOT installed AND CPU installed -> Remove CPU, then install GPU
        echo "${LOG_WARN}Warning:${NC} Found onnxruntime (CPU). Uninstalling it to replace with GPU version..."
        pip uninstall -y onnxruntime || error_exit "Failed to uninstall onnxruntime"
    else
        # Case: GPU NOT installed AND CPU NOT installed -> Install GPU
        echo "${LOG_INFO}INFO:${NC} No conflicting 'onnxruntime' (CPU) package found. Proceeding..."
    fi
fi

# We need both uv and the cache directory to enable build with uv
use_uv=true
uv="/comfy/mnt/venv/bin/uv"
uv_cache="/comfy/mnt/uv_cache"
if [ ! -x "$uv" ] || [ ! -d "$uv_cache" ]; then use_uv=false; fi

# If aarch64 (GB10), we must build (no whl available)
if [ "$(uname -m)" == "aarch64" ]; then must_build=true; fi

# https://github.com/thewh1teagle/spark-docs/blob/main/BUILD_ONNXRUNTIME.md
if [ "A$must_build" == "Atrue" ]; then
    echo "Building onnxruntime-gpu from source..."

    echo "Checking if nvcc is available"
    if ! command -v nvcc &> /dev/null; then
        error_exit " !! nvcc not found, canceling run"
    fi

    echo "Checking if setuptools is installed"
    if pip3 show setuptools &>/dev/null; then
        echo " ++ setuptools installed"
    else
        error_exit " !! setuptools not installed, canceling run"
    fi
    echo "Checking if ninja is installed"
    if pip3 show ninja &>/dev/null; then
        echo " ++ ninja installed"
    else
        error_exit " !! ninja not installed, canceling run"
    fi

    cd /comfy/mnt
    bb="venv/.build_base.txt"
    if [ ! -f $bb ]; then error_exit "${bb} not found"; fi
    BUILD_BASE=$(cat $bb)
    # extract CUDA version from build base
    CUDA_VERSION=$(echo $BUILD_BASE | grep -oP 'cuda\d+\.\d+')
    if [ -z "$CUDA_VERSION" ]; then error_exit "CUDA version not found in build base"; fi

    echo "CUDA version: $CUDA_VERSION"

    if pip3 show torch &>/dev/null; then
        torch_version=$(pip3 show torch | grep Version | awk '{print $2}' | cut -d'.' -f1-2)
    else
        error_exit "torch not installed, canceling run"
    fi

    echo "PIP3_CMD: \"${PIP3_CMD}\""
    if [ ! -d src ]; then mkdir src; fi
    cd src

    mkdir -p ${BUILD_BASE}
    if [ ! -d ${BUILD_BASE} ]; then error_exit "${BUILD_BASE} not found"; fi
    cd ${BUILD_BASE}

    if [ -z "$torch_version" ]; then error_exit "error getting torch version, canceling run"; fi
    td="Torch_${torch_version}"
    if [ ! -d $td ]; then mkdir $td; fi
    cd $td

    dd="/comfy/mnt/src/${BUILD_BASE}/$td/onnxruntime"
    if [ -d $dd ] && [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "false" ]; then
        # Source already present — check if a pre-built wheel exists and install it
        existing_wheel=$(find "$dd/build/Linux/Release/dist" -name "onnxruntime_gpu-*.whl" 2>/dev/null | head -1)
        if [ -n "$existing_wheel" ]; then
            echo "${LOG_INFO}INFO:${NC} Found pre-built wheel: $existing_wheel"
            echo "${LOG_INFO}INFO:${NC} Installing from existing wheel (delete $dd to force full rebuild)"
            source /comfy/mnt/venv/bin/activate || error_exit "Failed to activate virtualenv"
            pip install "numpy<2" || error_exit "Failed to install numpy"
            pip install "$existing_wheel" || error_exit "Failed to install onnxruntime-gpu wheel"
            echo "${LOG_OK}SUCCESS:${NC} onnxruntime-gpu installed from pre-built wheel"
            exit 0
        fi
        echo "${LOG_WARN}WARNING:${NC} onnxruntime source already present but no wheel found, you must delete $dd to force reinstallation"
        exit 0
    fi

    if [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "true" ]; then
        echo "${LOG_WARN}Not downloading from git, using existing source, if it exists"
        tdd=$dd
        if [ ! -d $tdd ]; then error_exit "$tdd not found, disable ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT to force reinstallation re-enabling it"; fi
    else
        tdd="$dd-`date +%Y%m%d%H%M%S`"
        mkdir -p $tdd
        git clone --recursive https://github.com/microsoft/onnxruntime $tdd
    fi

    cd $tdd

    cat > $tdd/build.cmd << EOF
#!/bin/bash
export CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)
export CPLUS_INCLUDE_PATH=/usr/local/cuda/targets/sbsa-linux/include/cccl:\$CPLUS_INCLUDE_PATH
export C_INCLUDE_PATH=/usr/local/cuda/targets/sbsa-linux/include/cccl:\$C_INCLUDE_PATH
export CPATH=/usr/local/cuda/targets/sbsa-linux/include/cccl:\$CPATH

source /comfy/mnt/venv/bin/activate

find . -type f -name 'CMakeCache.txt' -delete

./build.sh \
    --config Release \
    --build_shared_lib \
    --parallel \
    --use_cuda \
    --cuda_home /usr/local/cuda \
    --cudnn_home /usr \
    --cmake_extra_defines CMAKE_CUDA_ARCHITECTURES=121 \
    "CUDNN_INCLUDE_DIR=/usr/include/aarch64-linux-gnu" \
    "CUDNN_LIBRARY=/usr/lib/aarch64-linux-gnu/libcudnn.so" \
    --build_wheel \
    --skip_tests

if [ \$? -ne 0 ]; then echo "Failed to build onnxruntime-gpu"; exit 1; fi

${PIP3_CMD} "numpy<2"
${PIP3_CMD} build/Linux/Release/dist/onnxruntime_gpu-*.whl
EOF

    chmod +x $tdd/build.cmd
    script -a -e -c $tdd/build.cmd $tdd/build.log || error_exit "Failed to build onnxruntime-gpu"
    cd ..
    if [ "$ONNXRUNTIME_DO_NOT_DELETE_GPU_IF_PRESENT" = "false" ]; then
      mv $tdd $dd
    fi
    echo "${LOG_INFO}INFO:${NC} onnxruntime-gpu built successfully"
    exit 0
fi

echo "== PIP3_CMD: \"${PIP3_CMD}\""
if [ "A$use_uv" == "Atrue" ]; then
  echo "== Using uv"
  echo " - uv: $uv"
  echo " - uv_cache: $uv_cache"
else
  echo "== Using pip"
fi

CMD="${PIP3_CMD} onnxruntime-gpu"
echo "CMD: \"${CMD}\""
${CMD} || error_exit "Failed to install onnxruntime-gpu"
echo "${LOG_OK}SUCCESS:${NC} onnxruntime-gpu installed"

exit 0
