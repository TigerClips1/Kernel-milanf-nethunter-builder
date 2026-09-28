#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 06 — Compile Kernel"

is_step_done "06" && { log "Step 06 already done, skipping."; exit 0; }

[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel source not found. Run steps 02-05 first."
if [[ ! -f "${OUT_DIR}/.config" ]]; then
    warn ".config not found in ${OUT_DIR}; running step 05 to generate the kernel configuration first."
    bash "$(dirname "$0")/05_configure.sh"
fi
[[ -f "${OUT_DIR}/.config" ]] || die ".config not found after step 05. Run step 05 first, then rerun step 06."

# Ensure CAN driver symbols are enabled in the configuration before building.
# These may be missing if step 05 was previously run without adding them.
CONFIG_FILE="${OUT_DIR}/.config"
append_config() {
    local opt="$1" val="$2"
    if ! grep -q "^${opt}=" "${CONFIG_FILE}"; then
        echo "${opt}=${val}" >> "${CONFIG_FILE}"
        log "Added missing ${opt}=${val} to kernel config"
    else
        # If present but not set as desired, adjust it.
        local current=$(grep "^${opt}=" "${CONFIG_FILE}" | cut -d= -f2)
        if [[ "$current" != "$val" ]]; then
            sed -i "s/^${opt}=.*/${opt}=${val}/" "${CONFIG_FILE}"
            log "Updated ${opt} from $current to $val in kernel config"
        fi
    fi
}

append_config "CONFIG_CAN" "m"
append_config "CONFIG_CAN_DEV" "m"
append_config "CONFIG_CAN_ISOTP" "m"
append_config "CONFIG_CAN_USB" "m"
append_config "CONFIG_CAN_KVASER_USB" "m"
append_config "CONFIG_CAN_PEAK_USB" "m"
append_config "CONFIG_CAN_UCAN" "m"

export PATH="${CLANG_DIR}/bin:${PATH}"
CLANG_BIN="$(detect_clang)" || die "No suitable clang toolchain found. Expected AOSP clang 21 / r563880c or a compatible clang-21 binary."
CLANG_VER="$(${CLANG_BIN} --version 2>/dev/null | head -n 1 || echo unknown)"
log "Using ${CLANG_BIN}: ${CLANG_VER}"
require_cmd ld.lld

BUILD_LOG="${REPO_ROOT}/out/build.log"
mkdir -p "${OUT_DIR}" "${MODULES_DIR}" "${ZIP_DIR}"

log "Build log: ${BUILD_LOG}"
log "Using ${JOBS} parallel jobs"

# Preserve the stock kernel release so prebuilt vendor modules keep matching.
BUILD_TS="$(LC_ALL=C date -u)"
export KBUILD_BUILD_TIMESTAMP="${BUILD_TS}"
export KBUILD_BUILD_USER="TigerClips1"
export KBUILD_BUILD_HOST="NethunterBuilderMilanf"
log "Build metadata: user=${KBUILD_BUILD_USER}, host=${KBUILD_BUILD_HOST}; preserving stock kernel release"

# kamikaonashi 5.4 hardcodes LINUX_COMPILE_BY='kami' / HOST='yourMom' in
# scripts/mkcompile_h, ignoring KBUILD_BUILD_USER/HOST. Restore upstream
# behavior so env vars take effect.
MKCH="${KERNEL_DIR}/scripts/mkcompile_h"
if grep -qE "^LINUX_COMPILE_(BY|HOST)='[^$]" "${MKCH}"; then
    log "Patching scripts/mkcompile_h to honor KBUILD_BUILD_USER/HOST..."
    sed -i \
        -e "s|^LINUX_COMPILE_BY=.*|LINUX_COMPILE_BY=\"\${KBUILD_BUILD_USER:-\$(whoami)}\"|" \
        -e "s|^LINUX_COMPILE_HOST=.*|LINUX_COMPILE_HOST=\"\${KBUILD_BUILD_HOST:-\$(hostname)}\"|" \
        "${MKCH}"
fi
# Force compile.h regeneration so the new values land in this build.
rm -f "${OUT_DIR}/include/generated/compile.h" "${OUT_DIR}/init/version.o"

# Host OpenSSL without the ENGINE API (OpenSSL 3.x deprecates it, 4.x drops it)
# breaks linking scripts/extract-cert ("undefined reference to ENGINE_*").
# The only user is the pkcs11: key-URI branch, which Android kernels never use;
# constant-fold it away so the ENGINE symbols are never referenced. Idempotent.
EXTRACT_CERT="${KERNEL_DIR}/scripts/extract-cert.c"
if [[ -f "${EXTRACT_CERT}" ]] && grep -q 'if (!strncmp(cert_src, "pkcs11:", 7))' "${EXTRACT_CERT}"; then
    log "Patching scripts/extract-cert.c to skip the OpenSSL ENGINE (pkcs11) branch..."
    sed -i 's|if (!strncmp(cert_src, "pkcs11:", 7))|if (0 \&\& !strncmp(cert_src, "pkcs11:", 7))|' "${EXTRACT_CERT}"
fi

log "Starting kernel build..."

BUILD_START=$(date +%s)

pushd "${KERNEL_DIR}" > /dev/null
make -j"${JOBS}" \
    O="${OUT_DIR}" \
    ARCH=arm64 \
    CC="${CLANG_BIN}" \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    AR=llvm-ar \
    NM=llvm-nm \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    STRIP=llvm-strip \
    LD=ld.lld \
    LOCALVERSION= \
    KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP}" \
    KBUILD_BUILD_USER="${KBUILD_BUILD_USER}" \
    KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST}" \
    Image.gz modules \
    2>&1 | tee "${BUILD_LOG}"

BUILD_STATUS=${PIPESTATUS[0]}
popd > /dev/null

BUILD_END=$(date +%s)
BUILD_ELAPSED=$(( BUILD_END - BUILD_START ))
BUILD_MINS=$(( BUILD_ELAPSED / 60 ))
BUILD_SECS=$(( BUILD_ELAPSED % 60 ))

if [[ ${BUILD_STATUS} -ne 0 ]]; then
    err "Build failed after ${BUILD_MINS}m ${BUILD_SECS}s"
    err "Check the build log:"
    grep -n "error:" "${BUILD_LOG}" | head -20
    exit ${BUILD_STATUS}
fi

# Accept the built ARM64 kernel image formats produced by this device tree.
KERNEL_IMAGE=""
for img_try in \
    "${OUT_DIR}/arch/arm64/boot/Image.gz-dtb" \
    "${OUT_DIR}/arch/arm64/boot/Image.gz" \
    "${OUT_DIR}/arch/arm64/boot/Image"; do
    if [[ -f "${img_try}" ]]; then
        KERNEL_IMAGE="${img_try}"
        break
    fi
done
[[ -n "${KERNEL_IMAGE}" ]] || die "No kernel image found after build — check ${BUILD_LOG}"

ok "Kernel build successful in ${BUILD_MINS}m ${BUILD_SECS}s"
ok "Kernel image: ${KERNEL_IMAGE} ($(du -sh "${KERNEL_IMAGE}" | cut -f1))"

# ---------------------------------------------------------------------------
# Install kernel modules into the output tree.
# "make modules" only builds the .ko files inside the build directory; they are
# not placed in a installable location. Running "make modules_install" with
# INSTALL_MOD_PATH points the installation into ${OUT_DIR}, creating the
# typical lib/modules/<version>/ hierarchy.
log "Running make modules_install to install compiled modules"
pushd "${KERNEL_DIR}" > /dev/null
make -j"${JOBS}" \
    O="${OUT_DIR}" \
    ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="${OUT_DIR}" \
    modules_install
popd > /dev/null

# Collect installed .ko files into a flat out/kernel/ directory for easy
# packaging and visibility.
log "Collecting installed kernel modules (*.ko) into ${OUT_DIR}/kernel/"
mkdir -p "${OUT_DIR}/kernel"
find "${OUT_DIR}" -type f -name "*.ko" -exec cp -v {} "${OUT_DIR}/kernel/" \; || true

# ---------------------------------------------------------------------------
# Install compiled kernel modules into the output directory.
# The kernel build produces *.ko files under the output tree (e.g.,
# ${OUT_DIR}/drivers/... or ${OUT_DIR}/net/... ). The original script only
# built the modules but never copied them to the final out/kernel/ directory,
# which caused the expected can-isotp.ko and hlcan.ko files to be missing.
# We locate all generated .ko files inside ${OUT_DIR} and copy them into
# out/kernel/ so they are directly visible to the user and can be packaged.
# This approach works for both in-tree and out-of-tree drivers.
log "Collecting built kernel modules (*.ko) into ${OUT_DIR}/kernel/"
mkdir -p "${OUT_DIR}/kernel"
find "${OUT_DIR}" -type f -name "*.ko" -exec cp -v {} "${OUT_DIR}/kernel/" \; || true


# ── Out-of-tree Realtek drivers ──────────────────────────────────────────────
# The upstream rtl8188eus / rtl88x2bu Makefiles are written for
# `make -C $KERNEL M=$PWD modules`. Building them in-tree with kbuild breaks
# include resolution (drv_types.h, halrf_psd.h, etc). We build each one as an
# out-of-tree module against the already-built kernel.
log "Compiling Realtek drivers out-of-tree..."
# Each driver's upstream Makefile has
#   obj-$(CONFIG_RTL8188EU) := $(MODULE_NAME).o
# under `ifneq ($(KERNELRELEASE),)`. Since those CONFIG_* aren't in the
# kernel's .config (we removed them to avoid in-tree compilation), we have to
# pass them inline to the sub-make so kbuild activates the obj-m target.
declare -A DRIVERS_CFG=(
    [rtl8188eus]="CONFIG_RTL8188EU=m"
    [rtl88x2bu]="CONFIG_RTL8822BU=m"
)

for drv in "${!DRIVERS_CFG[@]}"; do
    drv_src="${DRIVERS_DIR}/${drv}"
    [[ -d "${drv_src}" ]] || die "Driver source missing: ${drv_src}"
    drv_cfg_var="${DRIVERS_CFG[$drv]%%=*}"
    drv_cfg_val="${DRIVERS_CFG[$drv]#*=}"

    log "  → ${drv} (${DRIVERS_CFG[$drv]})"
    DRV_LOG="${REPO_ROOT}/out/build-${drv}.log"

    # Clean up leftover artifacts (.ko / .o from a previous build).
    pushd "${drv_src}" > /dev/null
    make -C "${OUT_DIR}" \
        M="$(pwd)" \
        ARCH=arm64 \
        clean > /dev/null 2>&1 || true

    make -j"${JOBS}" \
        -C "${OUT_DIR}" \
        M="$(pwd)" \
        ARCH=arm64 \
        CC=clang \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE=aarch64-linux-gnu- \
        AR=llvm-ar \
        NM=llvm-nm \
        OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump \
        STRIP=llvm-strip \
        LD=ld.lld \
        LOCALVERSION= \
        "${drv_cfg_var}=${drv_cfg_val}" \
        modules \
        2>&1 | tee "${DRV_LOG}"
    DRV_STATUS=${PIPESTATUS[0]}
    popd > /dev/null

    if [[ ${DRV_STATUS} -ne 0 ]]; then
        err "Failed to build ${drv} — see ${DRV_LOG}"
        grep -n "error:" "${DRV_LOG}" | head -10
        exit ${DRV_STATUS}
    fi

    # Verify at least one .ko was produced in the source dir
    KO_COUNT=$(find "${drv_src}" -maxdepth 1 -name "*.ko" -type f | wc -l)
    if [[ ${KO_COUNT} -eq 0 ]]; then
        die "${drv}: build reported success but no .ko produced in ${drv_src}"
    fi
    # Strip debug symbols — unstripped .ko files are ~350MB each (vs ~3MB
    # stripped) and were inflating the final ZIP to 200MB+.
    while IFS= read -r ko; do
        llvm-strip --strip-debug "${ko}"
    done < <(find "${drv_src}" -maxdepth 1 -name "*.ko" -type f)
    ok "  ${drv}: $(find "${drv_src}" -maxdepth 1 -name "*.ko" -type f -printf '%f (%s bytes) ')"
done

ok "All Realtek drivers built out-of-tree"

mark_step_done "06"
ok "Step 06 complete."
