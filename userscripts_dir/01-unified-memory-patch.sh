#!/bin/bash

# Unified Memory Patch — DGX Spark / GB10 Blackwell
#
# Patches comfy/utils.py to use copy=False in tensor.to(), fixing the
# "double-VRAM" bug on unified memory systems (DGX Spark / GB10).
#
# Background:
#   On unified memory hardware, the default safetensors loader copies model
#   weights to "RAM" and then again to "VRAM". Because CPU and GPU share the
#   same physical memory pool on the GB10, this doubles peak memory usage
#   during model loading and can OOM even when the model fits comfortably.
#   Setting copy=False eliminates the redundant copy.
#
# References:
#   https://github.com/comfyanonymous/ComfyUI/issues/10896
#   https://github.com/luix93/DGX-Spark-ComfyUI
#
# Pre-requisites:
#   - COMFY_CMDLINE_EXTRA must include --disable-mmap (set in docker-compose.yml)
#   - COMFYUI_PATH must be set (exported by init.bash before userscripts run)
#
# New in this version:
#   Patch 2 — comfy/model_management.py: get_free_memory() fallback when
#   torch.cuda.mem_get_info() returns (0, 0) on GB10 unified memory.
#   Without this, ComfyUI thinks there's 0 MB free VRAM → triggers lowvram
#   offloading → CUBLAS GEMM failures.

set -e

error_exit() {
  echo "!! ERROR: $*"
  echo "!! Exiting unified-memory-patch script (ID: $$)"
  exit 1
}

UTILS_FILE="${COMFYUI_PATH}/comfy/utils.py"
MGMT_FILE="${COMFYUI_PATH}/comfy/model_management.py"

echo ""
echo "== Unified Memory Patch (copy=False fix)"
echo "   Target: ${UTILS_FILE}"

if [ ! -f "${UTILS_FILE}" ]; then
  error_exit "utils.py not found at ${UTILS_FILE} — is COMFYUI_PATH set correctly?"
fi

# Check whether the patch is already applied (idempotent)
if grep -q 'tensor\.to(device=device, copy=False)' "${UTILS_FILE}"; then
  echo "   Already patched (copy=False already present) — skipping."
  exit 0
fi

# Verify the target line exists before attempting to patch
if ! grep -q 'tensor\.to(device=device, copy=True)' "${UTILS_FILE}"; then
  echo "!! WARNING: Expected pattern 'tensor.to(device=device, copy=True)' not found in ${UTILS_FILE}"
  echo "!!          ComfyUI may have been updated. Patch NOT applied — please review manually."
  echo "!!          Continuing startup without patch."
  exit 0
fi

# Apply the patch
sed -i 's/tensor\.to(device=device, copy=True)/tensor.to(device=device, copy=False)/g' "${UTILS_FILE}" \
  || error_exit "sed patch failed on ${UTILS_FILE}"

# Confirm
if grep -q 'tensor\.to(device=device, copy=False)' "${UTILS_FILE}"; then
  echo "   Patch applied successfully — copy=True → copy=False"
else
  error_exit "Patch verification failed — copy=False not found after sed"
fi

# ── Patch 2: get_free_memory GB10 fallback ──────────────────────────
echo ""
echo "== Patch 2: model_management.py (get_free_memory fallback)"
if [ -f "${MGMT_FILE}" ] && ! grep -q 'GB10_UNIFIED_FALLBACK' "${MGMT_FILE}"; then
  sed -i '/mem_free_cuda, _ = torch.cuda.mem_get_info(dev)/a\            # GB10_UNIFIED_FALLBACK\n            if mem_free_cuda == 0: mem_free_cuda = mem_reserved' "${MGMT_FILE}"
  echo "   Applied: 0 → mem_reserved fallback"
else
  echo "   Skipped (already applied or not found)"
fi

exit 0
