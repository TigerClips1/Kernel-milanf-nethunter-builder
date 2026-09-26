#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 08 — Package Flasheable ZIP"

is_step_done "08" && { log "Step 08 already done, skipping."; exit 0; }

KERNEL_IMAGE=""
# Device tree declares BOARD_KERNEL_IMAGE_NAME := Image; flash the raw
# ARM64 Image expected by the bootloader, never prefer a gzip variant.
for img_try in \
    "${OUT_DIR}/arch/arm64/boot/Image" \
    "${OUT_DIR}/arch/arm64/boot/Image.gz-dtb" \
    "${OUT_DIR}/arch/arm64/boot/Image.gz"; do
    if [[ -f "${img_try}" ]]; then
        KERNEL_IMAGE="${img_try}"
        break
    fi
done
[[ -n "${KERNEL_IMAGE}" ]] || die "No kernel image found. Run step 07 first."
log "Kernel image: ${KERNEL_IMAGE}"

export PATH="${CLANG_DIR}/bin:${PATH}"

log "Cleaning ${MODULES_DIR} to avoid stale modules from prior builds..."
# Builds anteriores con distinto LOCALVERSION dejan subdirs como
# lib/modules/5.4.302-Darkmoon-Reborn/ con .ko de CRCs antiguos. Si no se
# limpia, el glob de Realtek de abajo los recoge y termina empaquetando
# modulos que no matchean el kernel del ZIP → "disagrees about version of
# symbol module_layout" en dmesg al hacer insmod.
rm -rf "${MODULES_DIR}"
mkdir -p "${MODULES_DIR}"

log "Installing kernel modules..."
pushd "${KERNEL_DIR}" > /dev/null
make -j"${JOBS}" \
    O="${OUT_DIR}" \
    ARCH=arm64 \
    CC=clang \
    CROSS_COMPILE=aarch64-linux-gnu- \
    LOCALVERSION= \
    STRIP=llvm-strip \
    INSTALL_MOD_STRIP=1 \
    INSTALL_MOD_PATH="${MODULES_DIR}" \
    modules_install
check_error "modules_install failed"
popd > /dev/null
ok "Modules installed to ${MODULES_DIR}"

log "Building a matching custom vendor_boot image..."
bash "${REPO_ROOT}/scripts/08_repack_vendor_boot.sh"

log "Preparing AnyKernel3 workspace (KernelSU Next)..."
AK3_WORK="${REPO_ROOT}/out/anykernel3"
rm -rf "${AK3_WORK}"
cp -r "${AK3_DIR}" "${AK3_WORK}"
AK_VARIANT="${ANYKERNEL_DIR}/anykernel.sh"
[[ -f "${AK_VARIANT}" ]] || die "Missing anykernel variant: ${AK_VARIANT}"
[[ -n "${STOCK_BOOT_IMAGE}" && -s "${STOCK_BOOT_IMAGE}" ]] \
    || die "Set STOCK_BOOT_IMAGE to the matching LineageOS milanf boot.img; refusing to package a ZIP that would reuse TWRP's boot ramdisk."
log "Checking the supplied boot image for Magisk ramdisk patches..."
require_cmd python3 cpio lz4 gzip od
BOOT_CHECK_DIR="$(mktemp -d "${REPO_ROOT}/out/boot-check.XXXXXX")"
trap 'rm -rf "${BOOT_CHECK_DIR}"' EXIT
python3 "${MKBOOTIMG_DIR}/unpack_bootimg.py" \
    --boot_img "${STOCK_BOOT_IMAGE}" \
    --out "${BOOT_CHECK_DIR}/unpacked" \
    --format=info > "${BOOT_CHECK_DIR}/info"
BOOT_RAMDISK="${BOOT_CHECK_DIR}/unpacked/ramdisk"
BOOT_RAMDISK_CPIO="${BOOT_CHECK_DIR}/ramdisk.cpio"
BOOT_RAMDISK_MAGIC="$(od -An -tx1 -N4 "${BOOT_RAMDISK}" | tr -d ' \\n')"
case "${BOOT_RAMDISK_MAGIC}" in
    02214c18) lz4 -d -l -f "${BOOT_RAMDISK}" "${BOOT_RAMDISK_CPIO}" >/dev/null ;;
    04224d18) lz4 -d -f "${BOOT_RAMDISK}" "${BOOT_RAMDISK_CPIO}" >/dev/null ;;
    1f8b*)    gzip -dc "${BOOT_RAMDISK}" > "${BOOT_RAMDISK_CPIO}" ;;
    30373031|30373032) cp "${BOOT_RAMDISK}" "${BOOT_RAMDISK_CPIO}" ;;
    *) die "Unsupported stock boot ramdisk format (magic ${BOOT_RAMDISK_MAGIC})." ;;
esac
cpio -it < "${BOOT_RAMDISK_CPIO}" > "${BOOT_CHECK_DIR}/ramdisk-files" 2>/dev/null \
    || die "Could not inspect the supplied boot ramdisk."
if grep -Eq '(^|/)\.backup/\.magisk$|(^|/)overlay\.d/sbin/magisk\.xz$|(^|/)init\.magisk\.rc$' "${BOOT_CHECK_DIR}/ramdisk-files"; then
    die "${STOCK_BOOT_IMAGE} contains Magisk ramdisk patches; provide the clean boot.img from the same LineageOS build."
fi
ok "No Magisk ramdisk markers found"
cp "${AK_VARIANT}" "${AK3_WORK}/anykernel.sh"
cp "${STOCK_BOOT_IMAGE}" "${AK3_WORK}/stock_boot.img"
log "Using anykernel variant: $(basename "${AK_VARIANT}")"
log "Using stock boot image as ramdisk/header base: ${STOCK_BOOT_IMAGE}"

log "Copying kernel image..."
IMG_BASENAME="$(basename "${KERNEL_IMAGE}")"
cp "${KERNEL_IMAGE}" "${AK3_WORK}/${IMG_BASENAME}"
ok "${IMG_BASENAME} copied"

VENDOR_BOOT_IMAGE="${ZIP_DIR}/vendor_boot-nethunter-milanf.img"
[[ -s "${VENDOR_BOOT_IMAGE}" ]] || die "Custom vendor_boot image missing: ${VENDOR_BOOT_IMAGE}"
cp "${VENDOR_BOOT_IMAGE}" "${AK3_WORK}/vendor_boot.img"
ok "Custom vendor_boot image bundled for slot-aware flashing"

log "Detecting kernel release string..."
KERNEL_RELEASE=$(cat "${OUT_DIR}/include/config/kernel.release" 2>/dev/null || echo "${KERNEL_VERSION}")
ok "Kernel release: ${KERNEL_RELEASE}"

BUILD_DATE="$(date +%Y%m%d)"

# Los drivers Realtek se compilan out-of-tree en step 07 y los .ko quedan
# en sources/drivers/<drv>/*.ko. NO buscamos en $MODULES_DIR porque ahí
# solo están los modulos in-tree del kernel.
REALTEK_MODS=()
for drv in rtl8188eus rtl88x2bu; do
    while IFS= read -r ko; do
        REALTEK_MODS+=("${ko}")
    done < <(find "${DRIVERS_DIR}/${drv}" -maxdepth 1 -name "*.ko" -type f 2>/dev/null)
done
HAVE_MODS=0
[[ ${#REALTEK_MODS[@]} -gt 0 ]] && HAVE_MODS=1
if [[ ${HAVE_MODS} -eq 0 ]]; then
    err "No Realtek .ko found in ${DRIVERS_DIR}/{rtl8188eus,rtl88x2bu}/"
    err "Step 07 debe haberlos compilado out-of-tree."
    err "Ejecuta: bash build.sh --clean"
    die "Aborto: el ZIP no debe distribuirse sin módulos Realtek"
fi

log "Staging Realtek modules as a KernelSU Next module..."
rm -rf "${AK3_WORK}/modules/system/lib/modules" "${AK3_WORK}/ksu_module"
MOD_STAGE="${AK3_WORK}/ksu_module/system/lib/modules"
mkdir -p "${MOD_STAGE}"

if [[ ${HAVE_MODS} -eq 1 ]]; then
    for ko in "${REALTEK_MODS[@]}"; do
        cp "${ko}" "${MOD_STAGE}/"
        log "  + $(basename "${ko}")"
    done
    ok "${#REALTEK_MODS[@]} Realtek module(s) staged"
else
    die "No Realtek .ko modules found; refusing to create a KSU ZIP without its driver module"
fi

cat > "${AK3_WORK}/ksu_module/module.prop" <<EOF
id=nethunter-realtek-drivers
name=NetHunter Realtek Drivers
version=v1.0-${BUILD_DATE}
versionCode=${BUILD_DATE}
author=Community
description=RTL8188EUS and RTL88x2BU USB Wi-Fi drivers for milanf
EOF

cat > "${AK3_WORK}/ksu_module/load.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/local/tmp/realtek_drivers.log

echo "[$(date)] Loading NetHunter Realtek drivers on demand" >> "$LOG"
for ko in "$MODDIR"/system/lib/modules/*.ko; do
    [ -f "$ko" ] || continue
    module=$(basename "$ko" .ko)
    if grep -q "^${module} " /proc/modules 2>/dev/null; then
        echo "${module}: already loaded" >> "$LOG"
    elif insmod "$ko" 2>>"$LOG"; then
        echo "${module}: loaded" >> "$LOG"
    else
        echo "${module}: insmod failed" >> "$LOG"
    fi
done
EOF
cat > "${AK3_WORK}/ksu_module/action.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
exec "$MODDIR/load.sh"
EOF
cp "${ANYKERNEL_DIR}/usb-role-service.sh" "${AK3_WORK}/ksu_module/service.sh"
chmod 0755 "${AK3_WORK}/ksu_module/load.sh" "${AK3_WORK}/ksu_module/action.sh" "${AK3_WORK}/ksu_module/service.sh"

ROOT_VARIANT="KernelSU-Next"
log "Root provider: ${ROOT_VARIANT} (built into the kernel)"

ZIP_NAME="${KERNEL_NAME}-By_${KERNEL_AUTHOR}.NH_${ROM_TARGET}.${ROOT_VARIANT}.${BUILD_DATE}.zip"
ZIP_PATH="${ZIP_DIR}/${ZIP_NAME}"
mkdir -p "${ZIP_DIR}"

log "Creating ZIP: ${ZIP_NAME}..."
pushd "${AK3_WORK}" > /dev/null
zip -r9 "${ZIP_PATH}" . \
    -x ".git*" \
    -x "*.placeholder" \
    -x "*.md" \
    -x "LICENSE"
check_error "zip failed"
popd > /dev/null

ok "ZIP created: ${ZIP_PATH} ($(du -sh "${ZIP_PATH}" | cut -f1))"

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  DONE: ${ZIP_NAME}${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "Flash kernel:"
echo "  TWRP → Install → ${ZIP_NAME}"
echo "  Installer repacks the stock boot image and flashes boot_b + vendor_boot_b as a pair."
echo ""
echo "Root: KernelSU Next is built into this kernel. Install the KernelSU Next"
echo "      Manager app after boot. The ZIP installs USB Wi-Fi drivers as a"
echo "      KernelSU Next module when /data is decrypted in recovery; load them"
echo "      on demand using the module action in KernelSU Next Manager."
echo "Verify after boot:"
echo "  adb shell su -c id"
echo "  adb shell ls /data/adb/modules/nethunter-realtek-drivers/system/lib/modules"
echo "  adb shell lsmod | grep -E '8188eu|88x2bu'"

mark_step_done "08"
ok "Step 08 complete."
