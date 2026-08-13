#!/bin/bash
# froggerpro/build/bazel.sh -> linked as tools/bazel via manifest.xml symlink
# SPDX-License-Identifier: GPL-2.0
set -e
set -E  # Inherit ERR trap in functions

SOURCE="${BASH_SOURCE[0]}"

# If invoked via tools/bazel: SOURCE is "tools/bazel"
# -> logical workspace path, DO NOT resolve symlinks!
SELF_DIR="$(cd "$(dirname "$SOURCE")" && pwd -L)"

if [[ "$(basename "$SELF_DIR")" == "tools" ]]; then
    WORKSPACE_ROOT="$(cd "${SELF_DIR}/.." && pwd -L)"
else
    WORKSPACE_ROOT="$(cd "${SELF_DIR}/../.." && pwd -L)"
fi

REAL_BAZEL="${WORKSPACE_ROOT}/build/kernel/kleaf/bazel.sh"
KSU_MARKER="${WORKSPACE_ROOT}/froggerpro/.ksu_active"
KSU_MARKER_VARIANT="${WORKSPACE_ROOT}/froggerpro/.ksu_variant"
COMMON_DIR="${WORKSPACE_ROOT}/common"
BUILD_KERNEL_DIR="${WORKSPACE_ROOT}/build/kernel"
STAMP_BZL="${BUILD_KERNEL_DIR}/kleaf/impl/stamp.bzl"
DIST_DIR="${WORKSPACE_ROOT}/out/msm-kernel-sun-perf/dist"
CUSTOM_AVB_KEY="${WORKSPACE_ROOT}/froggerpro/avb_sign_key.key"
TESTKEY_AVB="${WORKSPACE_ROOT}/tools/mkbootimg/gki/testdata/testkey_rsa4096.pem"
SIGN_CONF="${WORKSPACE_ROOT}/froggerpro/sign.conf"

if [ ! -f "${REAL_BAZEL}" ]; then
    echo "ERROR: Kleaf bazel.sh not found at ${REAL_BAZEL}" >&2
    echo "DEBUG: SELF_DIR=${SELF_DIR}" >&2
    echo "DEBUG: WORKSPACE_ROOT=${WORKSPACE_ROOT}" >&2
    exit 1
fi

# ==========================================================
# Cleanup (always called at end, regardless of success/failure)
# ==========================================================
_frogger_cleanup() {
    echo "=========================================="
    echo "==> [Cleanup] Reverting all patches ..."
    echo "=========================================="

    cd "${COMMON_DIR}"

    # KSU cleanup
    if [ -f "setup.sh" ]; then
        bash setup.sh --cleanup || true
    fi
    git clean -fdx drivers/kernelsu KernelSU KernelSU-Next setup.sh 2>/dev/null || true

    # Revert froggerpro patches via git restore
    git restore arch/arm64/configs/gki_defconfig 2>/dev/null || true
    git restore drivers/Makefile drivers/Kconfig 2>/dev/null || true

    cd "${WORKSPACE_ROOT}"

    # Revert stamp.bzl patch via sed (restore original)
    echo "==> [Cleanup] Reverting stamp.bzl patch"
    if [ -f "${STAMP_BZL}" ]; then
        sed -i "s/echo \$scmversion | sed 's\/-dirty\/\/g'/echo \$scmversion/" "${STAMP_BZL}" 2>/dev/null || true
    fi

    # Remove markers
    rm -f "${KSU_MARKER}" "${KSU_MARKER_VARIANT}"

    echo "==> [Cleanup] All patches reverted."
}

# ==========================================================
# Parse sign.conf and return value for key
# ==========================================================
_get_sign_config() {
    local key="$1"
    local default="$2"
    local value=""

    if [ ! -f "${SIGN_CONF}" ]; then
        echo "${default}"
        return 0
    fi

    # Read config file, skip comments and empty lines
    value=$(grep -E "^${key}=" "${SIGN_CONF}" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "${value}" ]; then
        echo "${default}"
    else
        echo "${value}"
    fi
}

# ==========================================================
# Sign boot.img with AVB
# ==========================================================
_frogger_sign_boot() {
    echo "=========================================="
    echo "==> [AVB] Post-Build Boot Signing"
    echo "=========================================="

    if [ ! -d "${DIST_DIR}" ]; then
        echo "==> [AVB] Warning: dist directory not found at ${DIST_DIR}"
        return 0
    fi

    local boot_img="${DIST_DIR}/boot.img"
    if [ ! -f "${boot_img}" ]; then
        echo "==> [AVB] Warning: boot.img not found"
        return 0
    fi

    # Determine which key to use
    local avb_key="${TESTKEY_AVB}"
    if [ -f "${CUSTOM_AVB_KEY}" ]; then
        avb_key="${CUSTOM_AVB_KEY}"
        echo "==> [AVB] Using custom key: ${avb_key}"
    else
        echo "==> [AVB] Using test key: ${avb_key}"
    fi

    # Read signing config
    local rollback_index=$(_get_sign_config "rollback_index" "0")
    local props=$(_get_sign_config "props" "")

    echo "==> [AVB] Config: rollback_index=${rollback_index}"
    if [ -n "${props}" ]; then
        echo "==> [AVB] Config: props=${props}"
    fi

    # Remove existing AVB footer
    echo "==> [AVB] Removing existing AVB footer from boot.img"
    avbtool erase_footer --image="${boot_img}" 2>/dev/null || true

    # Build prop arguments
    local prop_args=""
    if [ -n "${props}" ]; then
        IFS=',' read -ra PROPS_ARRAY <<< "${props}"
        for prop in "${PROPS_ARRAY[@]}"; do
            prop_args="${prop_args} --prop ${prop}"
        done
    fi

    # Sign boot.img
    echo "==> [AVB] Signing boot.img with selected key"
    # shellcheck disable=SC2086
    avbtool add_hash_footer \
        --image="${boot_img}" \
        --partition_name="boot" \
        --partition_size=100663296 \
        --key="${avb_key}" \
        --algorithm="SHA256_RSA4096" \
        --rollback_index="${rollback_index}" \
        ${prop_args} || {
        echo "ERROR: AVB signing failed" >&2
        return 1
    }

    echo "==> [AVB] Boot signing completed successfully"
}

# ==========================================================
# Trap handlers
# ==========================================================
trap _frogger_cleanup EXIT
trap _frogger_cleanup INT   # CTRL+C
trap _frogger_cleanup TERM  # SIGTERM

# ==========================================================
# Apply Froggerpro base patches
# ==========================================================
_frogger_base_patch() {
    echo "=========================================="
    echo "==> [Pre-Flight] Applying Froggerpro base patches ..."
    echo "=========================================="

    echo "==> [Patch] Updating stamp.bzl (scmversion patch)"
    if [ -f "${STAMP_BZL}" ]; then
        sed -i "s/echo \$scmversion$/echo \$scmversion | sed 's\/-dirty\/\/g'/" "${STAMP_BZL}" || true
    fi

    cd "${COMMON_DIR}"
    echo "==> [Patch] Updating arch/arm64/configs/gki_defconfig"
    if [ -f "arch/arm64/configs/gki_defconfig" ]; then
        sed -i '/^CONFIG_MODULE_SIG_PROTECT=y$/d' arch/arm64/configs/gki_defconfig || true
    fi
    cd "${WORKSPACE_ROOT}"

    echo "==> [Patch] Froggerpro base patches applied."
}

# ==========================================================
# Apply KSU variant patches
# ==========================================================
_frogger_ksu_patch() {
    local target="$1"
    local variant=""
    local ksu_url=""

    # Extract variant name and determine URL
    case "$target" in
        *//froggerpro:kernel_ksu)
            variant="ksu"
            ksu_url="https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_ksun)
            variant="ksun"
            ksu_url="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/dev/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_sukisu)
            variant="sukisu"
            ksu_url="https://raw.githubusercontent.com/sukisu-ultra/sukisu-ultra/main/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_resukisu)
            variant="resukisu"
            ksu_url="https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh"
            ;;
        *)
            echo "ERROR: Unknown KSU variant in target: $target" >&2
            return 1
            ;;
    esac

    echo "=========================================="
    echo "==> [Pre-Flight] Applying KSU variant: ${variant}"
    echo "==> [KSU] URL: ${ksu_url}"
    echo "=========================================="

    cd "${COMMON_DIR}"

    # Download & apply KernelSU
    echo "==> [KSU] Downloading KernelSU setup script (${variant})"
    curl -LSs "${ksu_url}" | bash -
    curl -LSs "${ksu_url}" -o setup.sh

    # Patch drivers for KSU
    echo "==> [KSU] Patching drivers/ for KernelSU integration"
    if ! grep -q "obj-y += kernelsu/" drivers/Makefile; then
        echo "obj-y += kernelsu/" >> drivers/Makefile
    fi
    if ! grep -q "source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig; then
        echo "source \"drivers/kernelsu/Kconfig\"" >> drivers/Kconfig
    fi

    # Fix KSU paths in Kbuild
    echo "==> [KSU] Fixing KSU paths in Kbuild"
    local ksu_abs_path="${COMMON_DIR}/drivers/kernelsu"
    local kbuild_file="${COMMON_DIR}/drivers/kernelsu/Kbuild"

    if [ -f "${kbuild_file}" ]; then
        if grep -q "KSU_SRC :=" "${kbuild_file}"; then
            echo "==> [KSU Classic] Fixing KSU_SRC in Kbuild..."
            sed -i "s|KSU_SRC :=.*|KSU_SRC := ${ksu_abs_path}|g" "${kbuild_file}"
        fi
        if grep -q "MDIR :=" "${kbuild_file}"; then
            echo "==> [KSU-Next] Fixing MDIR in Kbuild..."
            sed -i "s|MDIR := \$(.*|MDIR := ${ksu_abs_path}|g" "${kbuild_file}"
        fi
    else
        echo "==> [KSU] Warning: Kbuild not found at ${kbuild_file}"
    fi

    cd "${WORKSPACE_ROOT}"

    touch "${KSU_MARKER}"
    echo "${variant}" > "${KSU_MARKER_VARIANT}"

    echo "==> [Pre-Flight] KSU variant ${variant} applied."
}

# ==========================================================
# Main
# ==========================================================
_ACTION="${1:-}"
_FROGGERPRO_TARGET_FOUND=0
_KSU_TARGET_FOUND=0

if [[ "${_ACTION}" == "build" || "${_ACTION}" == "run" ]]; then
    # Scan all args for froggerpro targets
    for arg in "$@"; do
        case "$arg" in
            *//froggerpro:kernel*)
                _FROGGERPRO_TARGET_FOUND=1
                # Check if it's a KSU variant
                case "$arg" in
                    *//froggerpro:kernel_ksu|*//froggerpro:kernel_ksun|*//froggerpro:kernel_resukisu|*//froggerpro:kernel_sukisu)
                        _KSU_TARGET_FOUND=1
                        _frogger_ksu_patch "$arg"
                        ;;
                esac
                ;;
        esac
    done

    # If any froggerpro target was found, apply base patches
    if [[ "${_FROGGERPRO_TARGET_FOUND}" -eq 1 ]]; then
        _frogger_base_patch
    fi
fi

# Use exec but disable set -e temporarily to let trap run
set +e
"${REAL_BAZEL}" "$@"
_BAZEL_EXIT=$?

# Post-build signing (only on successful build)
if [[ ${_BAZEL_EXIT} -eq 0 && "${_FROGGERPRO_TARGET_FOUND}" -eq 1 ]]; then
    _frogger_sign_boot
fi

exit $_BAZEL_EXIT
