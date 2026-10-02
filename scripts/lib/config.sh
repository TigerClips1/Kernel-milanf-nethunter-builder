#!/usr/bin/env bash
# Global variables and paths — single source of truth for all scripts

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

KERNEL_DEVICE="${KERNEL_DEVICE:-milanf}"
# Use the LineageOS milanf 5.4.302 source tree as the baseline. The checked-in
# clone is pinned to the same commit as the user's LineageOS tree; override
# KERNEL_DIR to build against another checkout.
KERNEL_BRANCH="${KERNEL_BRANCH:-nethunter}"
KERNEL_VERSION="${KERNEL_VERSION:-5.4.302}"
DEVICE_CONFIG="${DEVICE_CONFIG:-${REPO_ROOT}/config/milanf_device.config}"
# Path to the stock boot image used for repacking. Allows override via env var.
STOCK_BOOT_IMAGE="${STOCK_BOOT_IMAGE:-${REPO_ROOT}/Required_los_image-nethunter/boot.img}"
JOBS="${JOBS:-$(nproc)}"
SKIP_CLONE="${SKIP_CLONE:-}"

# ZIP naming — override via env vars if needed
KERNEL_NAME="${KERNEL_NAME:-LineageOS_milanf}"
KERNEL_AUTHOR="${KERNEL_AUTHOR:-TigerClips1}"
ROM_TARGET="${ROM_TARGET:-LineageOS-23.2}"       # e.g. LineageOS-23.2, Aosp14

# Kernel 5.4 requires KernelSU Next's built-in legacy driver. Pin the current
# legacy branch head explicitly so the checkout and repo validation remain
# reproducible while matching the script's exact SHA checks.
KSU="${KSU:-ksunext}"
case "${KSU}" in
    ksunext) ;;
    *) echo "[config] Invalid KSU='${KSU}' — this milanf build supports ksunext" >&2; exit 1 ;;
esac
KSU_NEXT_REPO="${KSU_NEXT_REPO:-https://github.com/KernelSU-Next/KernelSU-Next.git}"
KSU_NEXT_REF="${KSU_NEXT_REF:-cd739c78802333455391df973db17d9f28328b83}"
KSU_NEXT_DIR="${REPO_ROOT}/sources/KernelSU-Next"
KSU_STATE_FILE="${REPO_ROOT}/.ksu_mode"
# Prefer the exact Clang toolchain identified by the running device config.
# Fall back to the bundled compiler when the LineageOS checkout is unavailable.
LINEAGEOS_ROOT="${LINEAGEOS_ROOT:-/mnt/steamgames/Games/los/android/lineage}"
LINEAGE_CLANG_DIR="${LINEAGEOS_ROOT}/prebuilts/clang/host/linux-x86/clang-r563880c"
CLANG_PREBUILT="${CLANG_PREBUILT:-clang-r563880c}"
CLANG_TAG="${CLANG_TAG:-android-16.0.0_r2}"
CLANG_SUBDIR="${CLANG_SUBDIR:-clang-r563880c}"
CLANG_URLS=(
    "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/${CLANG_TAG}/${CLANG_SUBDIR}.tar.gz"
)

TOOLCHAIN_BIN="${REPO_ROOT}/.toolchain_bin"
export PATH="${TOOLCHAIN_BIN}:${PATH}"

if [[ -z "${CLANG_DIR:-}" ]]; then
    if [[ -x "${LINEAGE_CLANG_DIR}/bin/clang" ]]; then
        CLANG_DIR="${LINEAGE_CLANG_DIR}"
    else
        CLANG_DIR="${REPO_ROOT}/sources/toolchain/clang21"
    fi
fi
KERNEL_DIR="${REPO_ROOT}/sources/kernel"
DRIVERS_DIR="${REPO_ROOT}/sources/drivers"
AK3_DIR="${REPO_ROOT}/sources/anykernel3"

OUT_DIR="${REPO_ROOT}/out/kernel"
MODULES_DIR="${REPO_ROOT}/out/modules"
ZIP_DIR="${REPO_ROOT}/out/zip"
# Always resolve the stock vendor_boot image relative to the repo root so the
# build works even when the current shell directory is not the project root.
STOCK_VENDOR_BOOT_IMAGE="${STOCK_VENDOR_BOOT_IMAGE:-${REPO_ROOT}/Required_los_image-nethunter/vendor_boot.img}"
STOCK_VENDOR_MODULES_LOAD="${STOCK_VENDOR_MODULES_LOAD:-${REPO_ROOT}/out/vendor-repack/vendor-tree/modules/modules.load}"
# Keep the AOSP mkbootimg helper scripts in the repository-root tools directory so
# this project remains portable and GitHub-friendly without depending on a machine-
# specific home-directory checkout.
MKBOOTIMG_DIR="${MKBOOTIMG_DIR:-${REPO_ROOT}/tools}"

PATCHES_DIR="${REPO_ROOT}/patches"
CONFIG_DIR="${REPO_ROOT}/config"
ANYKERNEL_DIR="${REPO_ROOT}/anykernel"
KSU_CONFIG="${CONFIG_DIR}/milanf_kernelsu.config"

# Motorola milanf uses the vendor QGKI base defconfig plus ext_config fragments.
BASE_DEFCONFIG="${BASE_DEFCONFIG:-vendor/holi-qgki_defconfig}"
ROM_FRAGMENTS=(
    "arch/arm64/configs/vendor/ext_config/lineage_moto-holi.config"
    "arch/arm64/configs/vendor/ext_config/moto-holi-milanf.config"
)
NETHUNTER_CONFIG="${CONFIG_DIR}/milanf_nethunter.config"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/TigerClips1/kali-nethunter-milanf-kernel}"
AK3_REPO="https://github.com/osm0sis/AnyKernel3"
CLANG_REPO="https://github.com/ZyCromerZ/Clang"
# Git-mirror fallback used when the AOSP googlesource archive is unreachable.
# Branches in this repo don't carry the compiler itself — each one has a
# Clang-*-link.txt pointing at the actual GitHub Releases tarball for that
# build. Pinned to a known-good clang21 branch for reproducibility; override
# via env var if it ever goes stale.
CLANG_BRANCH="${CLANG_BRANCH:-21.0.0git-20250715}"

declare -A DRIVER_REPOS=(
    [rtl8188eus]="https://github.com/aircrack-ng/rtl8188eus"
    [rtl88x2bu]="https://github.com/RinCat/RTL88x2BU-Linux-Driver"
    [rtl8192eu]="https://github.com/clnhub/rtl8192eu-linux"
    [rtl8812au]="https://github.com/aircrack-ng/rtl8812au"
    [rtl8188fu]="https://github.com/kelebek333/rtl8188fu"
)
declare -A DRIVER_BRANCHES=(
    [rtl8812au]="v5.6.4.2"
)
# Kernel-in-tree CAN extension drivers that must be cloned into the kernel
# source tree so the generated Kconfig/Makefile entries can build them.
declare -A KERNEL_CAN_DRIVERS=(
    [usb-can-2-module]="https://github.com/V0lk3n/usb-can-2-module"
    [can-isotp]="https://github.com/V0lk3n/can-isotp"
)
