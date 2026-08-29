#!/bin/bash
# SPDX-License-Identifier: GPL-3.0
set -e
set -E  # Inherit ERR trap in functions

SOURCE="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SOURCE")" && pwd -L)"

if [[ "$(basename "$SELF_DIR")" == "tools" ]]; then
    WORKSPACE_ROOT="$(cd "${SELF_DIR}/.." && pwd -L)"
else
    WORKSPACE_ROOT="$(cd "${SELF_DIR}/../.." && pwd -L)"
fi

REAL_BAZEL="${WORKSPACE_ROOT}/build/kernel/kleaf/bazel.sh"
KSU_MARKER="${WORKSPACE_ROOT}/froggerpro/.ksu_active"
KSU_MARKER_VARIANT="${WORKSPACE_ROOT}/froggerpro/.ksu_variant"
SUSFS_MARKER="${WORKSPACE_ROOT}/froggerpro/.susfs_active"
COMMON_DIR="${WORKSPACE_ROOT}/common"
BUILD_KERNEL_DIR="${WORKSPACE_ROOT}/build/kernel"
STAMP_BZL="${BUILD_KERNEL_DIR}/kleaf/impl/stamp.bzl"
DIST_DIR="${WORKSPACE_ROOT}/out/msm-kernel-sun-perf/dist"
CUSTOM_AVB_KEY="${WORKSPACE_ROOT}/froggerpro/avb_sign_key.key"
TESTKEY_AVB="${WORKSPACE_ROOT}/tools/mkbootimg/gki/testdata/testkey_rsa4096.pem"
AVBTOOL="${WORKSPACE_ROOT}/prebuilts/kernel-build-tools/linux-x86/bin/avbtool"
SIGN_CONF="${WORKSPACE_ROOT}/froggerpro/sign.conf"
SUSFS_REPO_URL="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android15-6.6"
SUSFS_COMMIT=""
SUSFS_CACHE_DIR="${WORKSPACE_ROOT}/froggerpro/.susfs4ksu_cache"
NOCLEAN_MARKER="${WORKSPACE_ROOT}/froggerpro/.noclean"

if [ ! -f "${REAL_BAZEL}" ]; then
    echo "ERROR: Kleaf bazel.sh not found at ${REAL_BAZEL}" >&2
    echo "DEBUG: SELF_DIR=${SELF_DIR}" >&2
    echo "DEBUG: WORKSPACE_ROOT=${WORKSPACE_ROOT}" >&2
    exit 1
fi

# ==========================================================
# Kernel config helper (wraps scripts/config)
# ==========================================================
_frogger_kconfig() {
    local config_script="${COMMON_DIR}/scripts/config"
    local defconfig="${COMMON_DIR}/arch/arm64/configs/gki_defconfig"

    if [ ! -f "${config_script}" ]; then
        echo "ERROR: scripts/config not found at ${config_script}" >&2
        return 1
    fi
    if [ ! -f "${defconfig}" ]; then
        echo "ERROR: gki_defconfig not found at ${defconfig}" >&2
        return 1
    fi

    "${config_script}" --file "${defconfig}" "$@"
}

# ==========================================================
# Full cleanup (kernel tree, KSU dirs, stamp.bzl, markers)
# ==========================================================
_frogger_do_clean() {
    echo "==> [Cleanup] Resetting common/ and removing KSU dirs ..."

    cd "${COMMON_DIR}"

    git reset --hard && git clean -fdx

    if [ -d "KernelSU" ]; then
        rm -rf KernelSU
    fi

    if [ -d "KernelSU-Next" ]; then
        rm -rf KernelSU-Next
    fi

    cd "${WORKSPACE_ROOT}"

    # Revert stamp.bzl patch via sed (restore original)
    echo "==> [Cleanup] Reverting stamp.bzl patch"
    if [ -f "${STAMP_BZL}" ]; then
        sed -i "s/echo \$scmversion | sed 's\/-dirty\/\/g'/echo \$scmversion/" "${STAMP_BZL}" 2>/dev/null || true
    fi
}

# ==========================================================
# Cleanup (always called at end, regardless of success/failure)
# ==========================================================
_frogger_cleanup() {
    local noclean=0
    if [ -f "${NOCLEAN_MARKER}" ]; then
        noclean=1
    fi

    echo "=========================================="
    if [ "${noclean}" -eq 1 ]; then
        echo "==> [Cleanup] --noclean detected, keeping kernel patches in place"
    else
        echo "==> [Cleanup] Reverting all patches ..."
    fi
    echo "=========================================="

    if [ "${noclean}" -eq 0 ]; then
        _frogger_do_clean
    fi

    # Remove markers
    rm -f "${KSU_MARKER}" "${KSU_MARKER_VARIANT}" "${SUSFS_MARKER}"

    echo "==> [Cleanup] Done."
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

    local avb_key="${TESTKEY_AVB}"
    if [ -f "${CUSTOM_AVB_KEY}" ]; then
        avb_key="${CUSTOM_AVB_KEY}"
        echo "==> [AVB] Using custom key: ${avb_key}"
    else
        echo "==> [AVB] Using test key: ${avb_key}"
    fi

    local rollback_index=$(_get_sign_config "rollback_index" "0")
    local props=$(_get_sign_config "props" "")

    echo "==> [AVB] Config: rollback_index=${rollback_index}"
    if [ -n "${props}" ]; then
        echo "==> [AVB] Config: props=${props}"
    fi

    if [ ! -x "${AVBTOOL}" ]; then
        echo "==> [AVB] ERROR: avbtool not found at ${AVBTOOL}" >&2
        return 1
    fi

    echo "==> [AVB] Removing existing AVB footer from boot.img"
    "${AVBTOOL}" erase_footer --image="${boot_img}" 2>/dev/null || true

    local prop_args=""
    if [ -n "${props}" ]; then
        IFS=',' read -ra PROPS_ARRAY <<< "${props}"
        for prop in "${PROPS_ARRAY[@]}"; do
            prop_args="${prop_args} --prop ${prop}"
        done
    fi

    echo "==> [AVB] Signing boot.img with selected key"
    # shellcheck disable=SC2086
    "${AVBTOOL}" add_hash_footer \
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
    _frogger_kconfig --disable CONFIG_MODULE_SIG_PROTECT || true
    
    echo "==> [Patch] Updating build.config.gki"
    if [ -f "build.config.gki" ]; then
        sed -i -e 's/POST_DEFCONFIG_CMDS="check_defconfig"/POST_DEFCONFIG_CMDS=""/g' build.config.gki || true
    fi
    
    cd "${WORKSPACE_ROOT}"

    echo "==> [Patch] Froggerpro base patches applied."
}

# ==========================================================
# Fetch susfs4ksu repo (cached, shallow clone)
# ==========================================================
_frogger_fetch_susfs() {
    # If SUSFS_COMMIT is set, pin to that commit; otherwise use branch HEAD
    local ref="${SUSFS_BRANCH}"
    if [ -n "${SUSFS_COMMIT}" ]; then
        ref="${SUSFS_COMMIT}"
    fi

    if [ -d "${SUSFS_CACHE_DIR}/.git" ]; then
        local target_ref="origin/${ref}"
        if [ -n "${SUSFS_COMMIT}" ]; then
            target_ref="${ref}"
        fi
        echo "==> [SUSFS] Using cached susfs4ksu repo, updating (ref: ${ref})..."
        (cd "${SUSFS_CACHE_DIR}" && git fetch --depth 1 origin "${ref}" && git reset --hard "${target_ref}") || {
            echo "==> [SUSFS] Cache update failed, re-cloning..."
            rm -rf "${SUSFS_CACHE_DIR}"
        }
    fi

    if [ ! -d "${SUSFS_CACHE_DIR}/.git" ]; then
        if [ -n "${SUSFS_COMMIT}" ]; then
            echo "==> [SUSFS] Cloning susfs4ksu (commit: ${SUSFS_COMMIT})..."
            (
                git clone "${SUSFS_REPO_URL}" "${SUSFS_CACHE_DIR}"
                cd "${SUSFS_CACHE_DIR}"
                git fetch --depth 1 origin "${SUSFS_COMMIT}"
                git checkout --detach "FETCH_HEAD"
            ) || {
                echo "==> [SUSFS] Clone failed, re-cloning..."
                rm -rf "${SUSFS_CACHE_DIR}"
                git clone "${SUSFS_REPO_URL}" "${SUSFS_CACHE_DIR}"
                (cd "${SUSFS_CACHE_DIR}" && git fetch --depth 1 origin "${SUSFS_COMMIT}" && git checkout --detach "FETCH_HEAD")
            }
        else
            echo "==> [SUSFS] Cloning susfs4ksu (branch HEAD: ${SUSFS_BRANCH})..."
            git clone --depth 1 -b "${SUSFS_BRANCH}" "${SUSFS_REPO_URL}" "${SUSFS_CACHE_DIR}"
        fi
    fi
}

# ==========================================================
# Apply SUSFS patches (must run AFTER KSU patch)
# ==========================================================
_frogger_susfs_patch() {
    local variant="$1"

    echo "=========================================="
    echo "==> [Pre-Flight] Applying SUSFS4KSU patches (variant: ${variant})"
    echo "=========================================="

    _frogger_fetch_susfs

    cd "${COMMON_DIR}"

    # 1. Copy fs/susfs.c
    echo "==> [SUSFS] Copying fs/susfs.c"
    mkdir -p fs
    cp -f "${SUSFS_CACHE_DIR}/kernel_patches/fs/susfs.c" fs/susfs.c
    cp -f "${SUSFS_CACHE_DIR}/kernel_patches/include/linux/susfs.h" include/linux/susfs.h
    cp -f "${SUSFS_CACHE_DIR}/kernel_patches/include/linux/susfs_def.h" include/linux/susfs_def.h

    # 2. Apply the generic kernel patch (fs/, include/, Makefile, Kconfig, etc.)
    echo "==> [SUSFS] Applying generic kernel patch (50_add_susfs_in_${SUSFS_BRANCH}.patch)"
    local generic_patch="${SUSFS_CACHE_DIR}/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
    if [ -f "${generic_patch}" ]; then
        patch -p1 --fuzz=3 --forward < "${generic_patch}" || {
            echo "ERROR: Failed to apply generic SUSFS patch" >&2
            return 1
        }
    else
        echo "ERROR: Generic SUSFS patch not found at ${generic_patch}" >&2
        return 1
    fi

    # 3. Apply KSU-fork-specific hook patch
    #    Only apply SUSFS patches for classic KernelSU variant
    local ksu_hook_patch="${SUSFS_CACHE_DIR}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
    echo "==> [SUSFS] Applying KSU hook patch for variant: ${variant}"
    
    if [ "${variant}" = "ksu" ]; then
    	cd "${COMMON_DIR}/KernelSU"
	if [ -f "${ksu_hook_patch}" ]; then
		if patch -p1 --fuzz=3 --dry-run < "${ksu_hook_patch}" ; then
			patch -p1 --fuzz=3 --forward < "${ksu_hook_patch}" || true
			echo "==> [SUSFS] KSU hook patch applied successfully."
		else
			echo "==> [SUSFS] Warning: KSU hook patch does not apply cleanly to '${variant}'."
			echo "==> [SUSFS] This fork may already have native SUSFS hooks, or needs manual patching."
		fi
	else
		echo "==> [SUSFS] Warning: KSU hook patch not found, skipping (fork may be pre-integrated)."
	fi
    elif [ "${variant}" = "ksun" ] || [ "${variant}" = "resukisu" ] || [ "${variant}" = "sukisu" ]; then
        echo "==> [SUSFS] ${variant} uses integrated patches, skipping SUSFS hook patch."
    fi
    
    # Add KSU configuration options to gki_defconfig
    _frogger_kconfig --enable CONFIG_KSU_SUSFS
    echo "==> [Pre-Flight] Added CONFIG_KSU_SUSFS=y to gki_defconfig"
    
    if [ "${variant}" = "ksun" ]; then
    	sed -i -e "s/static int security_context_to_sid_with_policy(/int security_context_to_sid_with_policy(/g" "${COMMON_DIR}/KernelSU-Next/kernel/feature/selinux_hide.c"
    	sed -i -e "s/static int security_sid_to_context_with_policy(/int security_sid_to_context_with_policy(/g" "${COMMON_DIR}/KernelSU-Next/kernel/feature/selinux_hide.c"
    	sed -i -e "s/static void security_compute_av_user_with_policy(/void security_compute_av_user_with_policy(/g" "${COMMON_DIR}/KernelSU-Next/kernel/feature/selinux_hide.c"
    	echo "==> [Pre-Flight] Add additional patches to KernelSU-Next/kernel/feature/selinux_hide.c"
    fi
    
    cd "${WORKSPACE_ROOT}"

    touch "${SUSFS_MARKER}"
    echo "==> [Pre-Flight] SUSFS4KSU patches applied for variant: ${variant}"
}

# ==========================================================
# Apply KSU variant patches
# ==========================================================
_frogger_ksu_patch() {
    local target="$1"
    local variant=""
    local ksu_url=""
    local susfs_enabled=0

    # Extract variant name, URL, and whether _susfs suffix is present
    case "$target" in
        *//froggerpro:kernel_ksu_susfs)
            variant="ksu"
            susfs_enabled=1
            ksu_url="https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_ksu)
            variant="ksu"
            ksu_url="https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_ksun_susfs)
            variant="ksun"
            susfs_enabled=1
            ksu_url="https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_ksun)
            variant="ksun"
            ksu_url="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/dev/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_sukisu_susfs)
            variant="sukisu"
            susfs_enabled=1
            ksu_url="https://raw.githubusercontent.com/sukisu-ultra/sukisu-ultra/builtin/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_sukisu)
            variant="sukisu"
            ksu_url="https://raw.githubusercontent.com/sukisu-ultra/sukisu-ultra/main/kernel/setup.sh"
            ;;
        *//froggerpro:kernel_resukisu_susfs)
            variant="resukisu"
            susfs_enabled=1
            ksu_url="https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh"
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
    echo "==> [Pre-Flight] Applying KSU variant: ${variant} (susfs=${susfs_enabled})"
    echo "==> [KSU] URL: ${ksu_url}"
    echo "=========================================="

    cd "${COMMON_DIR}"

    # Download & apply KernelSU
    echo "==> [KSU] Downloading KernelSU setup script (${variant})"
    curl -LSs "${ksu_url}" -o setup.sh
    chmod +x setup.sh
    
    # Run setup.sh with the correct branch for the variant
    local ksu_branch=""
    if [[ "${variant}" == "sukisu" && "${susfs_enabled}" -eq 1 ]]; then
        ksu_branch="builtin"
    elif [[ "${variant}" == "ksun" && "${susfs_enabled}" -eq 1 ]]; then
        ksu_branch="dev-susfs"
    fi

    echo "==> [KSU] Running setup.sh (branch: ${ksu_branch:-default})"
    if [[ -n "${ksu_branch}" ]]; then
        ./setup.sh "${ksu_branch}"
    else
        ./setup.sh
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
    
    _frogger_kconfig --enable CONFIG_KSU
    echo "==> [Pre-Flight] Added CONFIG_KSU=y to gki_defconfig"

    cd "${WORKSPACE_ROOT}"

    touch "${KSU_MARKER}"
    echo "${variant}" > "${KSU_MARKER_VARIANT}"

    echo "==> [Pre-Flight] KSU variant ${variant} applied."

    # Now apply SUSFS on top, if requested
    if [[ "${susfs_enabled}" -eq 1 ]]; then
        _frogger_susfs_patch "${variant}"
    fi
}

# ==========================================================
# Main
# ==========================================================
_ACTION="${1:-}"
_FROGGERPRO_TARGET_FOUND=0
_KSU_TARGET_FOUND=0

# Filter out --noclean / --clean (not bazel flags) and pass the rest through
_NOCLEAN_FLAG=0
_CLEAN_FLAG=0
_BAZEL_ARGS=()
for arg in "$@"; do
    if [ "${arg}" == "--noclean" ]; then
        _NOCLEAN_FLAG=1
    elif [ "${arg}" == "--clean" ]; then
        _CLEAN_FLAG=1
    else
        _BAZEL_ARGS+=("${arg}")
    fi
done

if [[ "${_CLEAN_FLAG}" -eq 1 ]]; then
    echo "==> [Flags] --clean: cleaning all patches and exiting (no bazel build started)"
    _frogger_do_clean
    rm -f "${KSU_MARKER}" "${KSU_MARKER_VARIANT}" "${SUSFS_MARKER}" "${NOCLEAN_MARKER}"
    echo "==> [Flags] --clean: done."
    exit 0
fi

if [[ "${_NOCLEAN_FLAG}" -eq 1 ]]; then
    touch "${NOCLEAN_MARKER}"
    echo "==> [Flags] --noclean: created ${NOCLEAN_MARKER} (cleanup will keep kernel tree state)"
fi

if [[ "${_ACTION}" == "build" || "${_ACTION}" == "run" ]]; then
    # Scan all args for froggerpro targets
    for arg in "${_BAZEL_ARGS[@]}"; do
        case "$arg" in
            *//froggerpro:kernel*)
                _FROGGERPRO_TARGET_FOUND=1
                # Check if it's a KSU variant (with or without _susfs suffix)
                case "$arg" in
                    *//froggerpro:kernel_ksu|*//froggerpro:kernel_ksu_susfs| \
                    *//froggerpro:kernel_ksun|*//froggerpro:kernel_ksun_susfs| \
                    *//froggerpro:kernel_sukisu|*//froggerpro:kernel_sukisu_susfs| \
                    *//froggerpro:kernel_resukisu|*//froggerpro:kernel_resukisu_susfs)
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
"${REAL_BAZEL}" "${_BAZEL_ARGS[@]}"
_BAZEL_EXIT=$?

# Post-build signing (only on successful build)
if [[ ${_BAZEL_EXIT} -eq 0 && "${_FROGGERPRO_TARGET_FOUND}" -eq 1 ]]; then
    _frogger_sign_boot
fi

exit $_BAZEL_EXIT
