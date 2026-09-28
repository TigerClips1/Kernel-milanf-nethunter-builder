#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 05 — Configure Kernel"

is_step_done "05" && { log "Step 05 already done, skipping."; exit 0; }

[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel source not found. Run steps 02-05 first."
[[ -f "${NETHUNTER_CONFIG}" ]] || die "NetHunter config not found: ${NETHUNTER_CONFIG}"
[[ -f "${KSU_CONFIG}" ]] || die "KernelSU config not found: ${KSU_CONFIG}"
[[ -L "${KERNEL_DIR}/drivers/kernelsu" ]] || die "KernelSU Next is not integrated. Run step 04 first."

export PATH="${CLANG_DIR}/bin:${PATH}"
require_cmd clang

# Kconfig evaluates CC_IS_CLANG / LTO / CFI / SCS from the compiler, so the
# config MUST be generated with the same toolchain flags as step 07; otherwise
# step 07 restarts config and auto-answers (NEW) symbols.
KCC=(CC="$(command -v clang)" CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
     LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip)

mkdir -p "${OUT_DIR}"

# milanf's fallback is the Motorola QGKI base plus its LineageOS vendor
# fragments. Never select a standalone generic config for this device.
BASE_CFG="${BASE_DEFCONFIG:-vendor/holi-qgki_defconfig}"
case "${BASE_CFG}" in
    *qgki*) ;;
    *) die "milanf requires its Motorola QGKI base config; refusing ${BASE_CFG}." ;;
esac

pushd "${KERNEL_DIR}" > /dev/null

if [[ -f "${DEVICE_CONFIG:-}" ]]; then
    if ! grep -q "Linux/arm64 ${KERNEL_VERSION} Kernel Configuration" "${DEVICE_CONFIG}"; then
        die "Device config ${DEVICE_CONFIG} is not for Linux ${KERNEL_VERSION}; refusing to seed this kernel build from it."
    fi
    log "Loading the supplied running-device config: ${DEVICE_CONFIG}"
    cp "${DEVICE_CONFIG}" "${OUT_DIR}/.config"

    MERGE_CONFIGS=("${OUT_DIR}/.config")
    for fragment in "${ROM_FRAGMENTS[@]}"; do
        if [[ -f "${KERNEL_DIR}/${fragment}" ]]; then
            MERGE_CONFIGS+=("${KERNEL_DIR}/${fragment}")
        fi
    done
    MERGE_CONFIGS+=("${NETHUNTER_CONFIG}")
    MERGE_CONFIGS+=("${KSU_CONFIG}")
    scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" "${MERGE_CONFIGS[@]}"
    check_error "merge_config.sh (device+nethunter) failed"

else
    [[ -f "${KERNEL_DIR}/arch/arm64/configs/${BASE_CFG}" ]] \
        || die "Milanf QGKI base config is missing: ${BASE_CFG}."
    [[ -f "${KERNEL_DIR}/arch/arm64/configs/vendor/ext_config/moto-holi-milanf.config" ]] \
        || die "Milanf device fragment is missing: vendor/ext_config/moto-holi-milanf.config"

    log "Loading Motorola QGKI base config: ${BASE_CFG}"
    make O="${OUT_DIR}" ARCH=arm64 "${KCC[@]}" "${BASE_CFG}"
    check_error "Milanf QGKI base config failed"

    log "Merging the LineageOS common and milanf vendor fragments with NetHunter/KernelSU additions..."
    MERGE_CONFIGS=("${OUT_DIR}/.config")
    for fragment in "${ROM_FRAGMENTS[@]}"; do
        [[ -f "${KERNEL_DIR}/${fragment}" ]] && MERGE_CONFIGS+=("${KERNEL_DIR}/${fragment}")
    done
    MERGE_CONFIGS+=("${NETHUNTER_CONFIG}" "${KSU_CONFIG}")
    scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" "${MERGE_CONFIGS[@]}"
    check_error "merge_config.sh (milanf QGKI+nethunter+KernelSU) failed"
fi

log "Step 3: Resolving dependencies (olddefconfig)..."
    make O="${OUT_DIR}" ARCH=arm64 "${KCC[@]}" olddefconfig
    check_error "olddefconfig failed"
    ok "Config finalized"
    # Enable core CAN subsystem and specific CAN drivers as modules
    # The base QGKI config disables CAN entirely, so we must first enable the
    # core CAN framework before adding individual driver options.
    echo "CONFIG_CAN=m" >> "${OUT_DIR}/.config"
    echo "CONFIG_CAN_DEV=m" >> "${OUT_DIR}/.config"
    echo "CONFIG_CAN_ISOTP=m" >> "${OUT_DIR}/.config"
    echo "CONFIG_CAN_USB=m" >> "${OUT_DIR}/.config"
    echo "CONFIG_CAN_KVASER_USB=m" >> "${OUT_DIR}/.config"
    echo "CONFIG_CAN_PEAK_USB=m" >> "${OUT_DIR}/.config"
    echo "CONFIG_CAN_UCAN=m" >> "${OUT_DIR}/.config"
popd > /dev/null

log "Verifying critical config options..."
CONFIG_FILE="${OUT_DIR}/.config"
check_config() {
    local opt="$1" expected="$2"
    local actual
    actual=$(grep "^${opt}=" "${CONFIG_FILE}" | cut -d= -f2 || echo "NOT_SET")
    if [[ "${actual}" != "${expected}" ]]; then
        warn "${opt}=${actual} (expected ${expected})"
    else
        ok "${opt}=${actual}"
    fi
}

check_config "CONFIG_MODULES" "y"
check_config "CONFIG_USB_CONFIGFS_F_HID" "y"
check_config "CONFIG_BT_HCIBTUSB" "y"
check_config "CONFIG_MODULE_SIG" "n"
check_config "CONFIG_KSU" "y"
check_config "CONFIG_KSU_MANUAL_HOOK" "y"
if grep -q '^CONFIG_KSU_SYSCALL_TABLE_HOOK=y' "${CONFIG_FILE}"; then
    die "KernelSU syscall-table mode must stay disabled for this 5.4 QGKI port."
fi
ok "CONFIG_KSU_SYSCALL_TABLE_HOOK is disabled"

mark_step_done "05"
ok "Step 05 complete."
