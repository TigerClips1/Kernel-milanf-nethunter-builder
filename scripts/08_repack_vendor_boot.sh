#!/usr/bin/env bash
# Rebuild the stock vendor_boot image with the freshly built kernel modules.
#
# This is a safety-sensitive step: the ROM vendors a full set of prebuilt modules
# whose vermagic and .config ABI must match the kernel exactly. The script
# unpacks the original vendor_boot, stages the rebuilt modules under
# lib/modules/${KERNEL_RELEASE}, rewrites the ramdisk metadata list, and rewraps
# the image while preserving the original partition size and DTB.
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

require_cmd python3 lz4 cpio depmod truncate gzip od stat cmp

UNPACK_BOOTIMG="${MKBOOTIMG_DIR}/unpack_bootimg.py"
MKBOOTIMG="${MKBOOTIMG_DIR}/mkbootimg.py"
KERNEL_RELEASE="$(cat "${OUT_DIR}/include/config/kernel.release")"
MODULES_RELEASE_DIR="${MODULES_DIR}/lib/modules/${KERNEL_RELEASE}"
MODULES_BUILTIN="${OUT_DIR}/modules.builtin"
VENDOR_BOOT_OUTPUT="${ZIP_DIR}/vendor_boot-nethunter-milanf.img"
WORK_DIR="${REPO_ROOT}/out/vendor-boot-work"
UNPACK_DIR="${WORK_DIR}/unpacked"
ROOTFS_DIR="${WORK_DIR}/rootfs"
FLAT_ROOT="${WORK_DIR}/module-root"

[[ -s "${STOCK_VENDOR_BOOT_IMAGE}" ]] || die "Stock vendor_boot image missing: ${STOCK_VENDOR_BOOT_IMAGE}"
[[ -f "${UNPACK_BOOTIMG}" && -f "${MKBOOTIMG}" ]] || die "AOSP mkbootimg tools missing under ${MKBOOTIMG_DIR}."
[[ -d "${MODULES_RELEASE_DIR}" ]] || die "Installed modules missing for ${KERNEL_RELEASE}; run modules_install first."
[[ -s "${MODULES_BUILTIN}" ]] || die "Kernel modules.builtin missing; compile the kernel first."

rm -rf "${WORK_DIR}"
mkdir -p "${UNPACK_DIR}" "${ROOTFS_DIR}" "${FLAT_ROOT}/lib/modules/${KERNEL_RELEASE}"

python3 "${UNPACK_BOOTIMG}" \
    --boot_img "${STOCK_VENDOR_BOOT_IMAGE}" \
    --out "${UNPACK_DIR}" \
    --format=mkbootimg -0 > "${WORK_DIR}/mkbootimg.args"
python3 "${UNPACK_BOOTIMG}" \
    --boot_img "${STOCK_VENDOR_BOOT_IMAGE}" \
    --out "${WORK_DIR}/stock-check" \
    --format=info > "${WORK_DIR}/stock-info"
grep -Fq 'vendor boot image header version: 3' "${WORK_DIR}/stock-info" \
    || die "Expected the milanf vendor_boot v3 format; see ${WORK_DIR}/stock-info."

RAMDISK_MAGIC="$(od -An -tx1 -N4 "${UNPACK_DIR}/vendor_ramdisk" | tr -d ' \n')"
case "${RAMDISK_MAGIC}" in
    02214c18) lz4 -d -l -f "${UNPACK_DIR}/vendor_ramdisk" "${WORK_DIR}/ramdisk.cpio" >/dev/null ;;
    04224d18) lz4 -d -f "${UNPACK_DIR}/vendor_ramdisk" "${WORK_DIR}/ramdisk.cpio" >/dev/null ;;
    1f8b*)    gzip -dc "${UNPACK_DIR}/vendor_ramdisk" > "${WORK_DIR}/ramdisk.cpio" ;;
    *)        die "Unsupported vendor ramdisk compression magic: ${RAMDISK_MAGIC}" ;;
esac
( cd "${ROOTFS_DIR}" && cpio -idm --no-absolute-filenames --quiet < "${WORK_DIR}/ramdisk.cpio" )

# Extract the stock vendor ramdisk metadata automatically from the bundled
# vendor_boot.img when no ROM file was pre-pulled. This preserves the original
# module order without requiring adb pull /vendor/lib/modules/modules.load.
cache_vendor_module_metadata() {
    local cache_dir="${REPO_ROOT}/out/vendor-repack/vendor-tree/modules"
    local file candidate
    mkdir -p "${cache_dir}"
    for file in modules.load modules.load.recovery modules.blacklist modules.alias modules.dep modules.softdep modules.symbols modules.weakdep; do
        for candidate in \
            "${ROOTFS_DIR}/lib/modules/${file}" \
            "${ROOTFS_DIR}/lib/modules/${KERNEL_RELEASE}/${file}" \
            "${ROOTFS_DIR}/vendor/lib/modules/${file}" \
            "${ROOTFS_DIR}/vendor/lib/modules/${KERNEL_RELEASE}/${file}"; do
            if [[ -s "${candidate}" ]]; then
                cp -f "${candidate}" "${cache_dir}/${file}"
                if [[ "${file}" == "modules.load" ]]; then
                    STOCK_VENDOR_MODULES_LOAD="${cache_dir}/${file}"
                fi
                break
            fi
        done
    done
}
cache_vendor_module_metadata
if [[ -n "${STOCK_VENDOR_MODULES_LOAD}" && -s "${STOCK_VENDOR_MODULES_LOAD}" ]]; then
    :
else
    warn "ROM modules.load missing: ${STOCK_VENDOR_MODULES_LOAD:-<unset>}; falling back to the rebuilt vendor module order."
    warn "To keep the stock ROM order exactly, pull /vendor/lib/modules/modules.load and set STOCK_VENDOR_MODULES_LOAD."
fi

declare -A STAGED_MODULES=()
declare -A BUILTIN_MODULES=()
mapfile -d '' -t MODULE_FILES < <(find "${MODULES_RELEASE_DIR}" -type f -name '*.ko' -print0 | LC_ALL=C sort -z)
((${#MODULE_FILES[@]} > 0)) || die "No rebuilt .ko files found for ${KERNEL_RELEASE}."

for module in "${MODULE_FILES[@]}"; do
    module_file="$(basename "${module}")"
    module_name="${module_file%.ko}"
    module_key="${module_name//-/_}"
    if [[ -n "${STAGED_MODULES[${module_key}]:-}" ]]; then
        if ! cmp -s "${module}" "${FLAT_ROOT}/lib/modules/${KERNEL_RELEASE}/${STAGED_MODULES[${module_key}]}"; then
            die "Multiple different modules have the same flat name: ${module_file}."
        fi
        continue
    fi
    STAGED_MODULES["${module_key}"]="${module_file}"
    cp -p "${module}" "${FLAT_ROOT}/lib/modules/${KERNEL_RELEASE}/${module_file}"
done

while IFS= read -r module; do
    module_name="$(basename "${module}")"
    module_name="${module_name%.ko}"
    BUILTIN_MODULES["${module_name//-/_}"]=1
done < "${MODULES_BUILTIN}"

# Rebuild the module metadata under the staging root so the final ramdisk gets a
# complete modules.alias/modules.dep tree that matches the kernel release we just
# built. This is what allows the ROM to load the rebuilt vendor modules without
# a symbol mismatch at boot time.
depmod -b "${FLAT_ROOT}" "${KERNEL_RELEASE}" 2> "${WORK_DIR}/depmod.log" \
    || die "depmod failed; see ${WORK_DIR}/depmod.log."

RAMDISK_MODULES="${ROOTFS_DIR}/lib/modules"
mkdir -p "${RAMDISK_MODULES}"
rm -f "${RAMDISK_MODULES}"/*.ko
cp -p "${FLAT_ROOT}/lib/modules/${KERNEL_RELEASE}"/*.ko "${RAMDISK_MODULES}/"
for metadata in modules.alias modules.dep modules.devname modules.softdep modules.symbols modules.weakdep; do
    [[ -f "${FLAT_ROOT}/lib/modules/${KERNEL_RELEASE}/${metadata}" ]] \
        && cp -f "${FLAT_ROOT}/lib/modules/${KERNEL_RELEASE}/${metadata}" "${RAMDISK_MODULES}/${metadata}"
done

write_load_list() {
    local input="$1" output="$2" label="$3" line module_name module_key
    local -a missing=()
    [[ -f "${input}" ]] || die "${label} is missing from the stock ramdisk: ${input}"
    : > "${output}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "${line}" ]] || continue
        module_name="${line##*/}"
        module_name="${module_name%.ko}"
        module_key="${module_name//-/_}"
        if [[ -n "${STAGED_MODULES[${module_key}]:-}" ]]; then
            printf '%s\n' "${line}" >> "${output}"
        elif [[ -n "${BUILTIN_MODULES[${module_key}]:-}" ]]; then
            log "${label}: ${module_name} is built into the kernel; omit from load list"
        else
            missing+=("${module_name}")
        fi
    done < "${input}"
    ((${#missing[@]} == 0)) || die "${label} references modules not built or built-in: ${missing[*]}"
}

if [[ -n "${STOCK_VENDOR_MODULES_LOAD:-}" && -s "${STOCK_VENDOR_MODULES_LOAD}" ]]; then
    write_load_list "${STOCK_VENDOR_MODULES_LOAD}" "${RAMDISK_MODULES}/modules.load" "modules.load"
else
    : > "${RAMDISK_MODULES}/modules.load"
    find "${RAMDISK_MODULES}" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' \
        | LC_ALL=C sort > "${RAMDISK_MODULES}/modules.load"
fi
# Explicitly add the custom NetHunter CAN modules that are built as modules.
# These are not always present in the stock vendor modules.load file, so they
# must be appended to the rebuilt load list to auto-load during boot.
for extra_mod in hlcan can-isotp; do
    extra_file="${RAMDISK_MODULES}/${extra_mod}.ko"
    if [[ -f "${extra_file}" ]]; then
        if ! grep -qxF "${extra_mod}.ko" "${RAMDISK_MODULES}/modules.load" 2>/dev/null; then
            printf '%s\n' "${extra_mod}.ko" >> "${RAMDISK_MODULES}/modules.load"
            log "Auto-load enabled for ${extra_mod}.ko"
        fi
    fi
done
if [[ -f "${RAMDISK_MODULES}/modules.load.recovery" ]]; then
    write_load_list "${RAMDISK_MODULES}/modules.load.recovery" \
        "${WORK_DIR}/modules.load.recovery" "modules.load.recovery"
    cp -f "${WORK_DIR}/modules.load.recovery" "${RAMDISK_MODULES}/modules.load.recovery"
fi

( cd "${ROOTFS_DIR}" && find . -print0 | LC_ALL=C sort -z \
    | cpio --null -o -H newc --owner=0:0 --reproducible --quiet ) > "${WORK_DIR}/ramdisk.new.cpio"
case "${RAMDISK_MAGIC}" in
    02214c18) lz4 -l -12 -f "${WORK_DIR}/ramdisk.new.cpio" "${WORK_DIR}/vendor_ramdisk.new" >/dev/null ;;
    04224d18) lz4 -12 -f "${WORK_DIR}/ramdisk.new.cpio" "${WORK_DIR}/vendor_ramdisk.new" >/dev/null ;;
    1f8b*)    gzip -9 -n -c "${WORK_DIR}/ramdisk.new.cpio" > "${WORK_DIR}/vendor_ramdisk.new" ;;
esac

mapfile -d '' -t MKBOOTIMG_ARGS < "${WORK_DIR}/mkbootimg.args"
RAMDISK_ARGUMENT=0
for ((index = 0; index < ${#MKBOOTIMG_ARGS[@]}; index++)); do
    if [[ "${MKBOOTIMG_ARGS[index]}" == '--vendor_ramdisk' ]]; then
        MKBOOTIMG_ARGS[index + 1]="${WORK_DIR}/vendor_ramdisk.new"
        RAMDISK_ARGUMENT=1
        break
    fi
done
[[ "${RAMDISK_ARGUMENT}" == 1 ]] || die "AOSP unpacker did not emit a --vendor_ramdisk argument."

mkdir -p "${ZIP_DIR}"
python3 "${MKBOOTIMG}" "${MKBOOTIMG_ARGS[@]}" --vendor_boot "${VENDOR_BOOT_OUTPUT}"
ORIGINAL_SIZE="$(stat -c '%s' "${STOCK_VENDOR_BOOT_IMAGE}")"
BUILT_SIZE="$(stat -c '%s' "${VENDOR_BOOT_OUTPUT}")"
((BUILT_SIZE <= ORIGINAL_SIZE)) || die "Custom vendor_boot exceeds the stock partition image size."
truncate -s "${ORIGINAL_SIZE}" "${VENDOR_BOOT_OUTPUT}"

VERIFY_DIR="${WORK_DIR}/verify"
mkdir -p "${VERIFY_DIR}"
python3 "${UNPACK_BOOTIMG}" --boot_img "${VENDOR_BOOT_OUTPUT}" --out "${VERIFY_DIR}" --format=info > "${WORK_DIR}/verify-info"
grep -Fq 'vendor boot image header version: 3' "${WORK_DIR}/verify-info" \
    || die "Repacked vendor_boot failed v3 header verification."
cmp "${UNPACK_DIR}/dtb" "${VERIFY_DIR}/dtb" \
    || die "Repacked vendor_boot DTB differs from the stock DTB."
cmp "${WORK_DIR}/vendor_ramdisk.new" "${VERIFY_DIR}/vendor_ramdisk" \
    || die "Repacked vendor ramdisk did not survive image construction."

ok "Custom vendor_boot created: ${VENDOR_BOOT_OUTPUT}"
ok "Rebuilt modules included: ${#MODULE_FILES[@]} (release ${KERNEL_RELEASE})"
warn "Flash together with the kernel to vendor_boot_b; this image is unsigned and requires the unlocked/verification-disabled setup."