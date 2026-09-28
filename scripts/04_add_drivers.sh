#!/usr/bin/env bash
# Step 05 — Verify Realtek drivers (compiled out-of-tree in step 07)
#
# Design note: the upstream rtl8188eus / rtl88x2bu Makefiles are written to be
# built OUT-OF-TREE (`make -C $KERNEL_SRC M=$PWD modules`), not for kbuild
# integration inside the kernel tree. Trying to drop them into the tree broke
# include resolution with a separate build dir (O=).
#
# That's why step 05 no longer copies drivers into the kernel tree or touches
# Kconfig/Makefile. The kernel is built WITHOUT them, and step 07 compiles
# them as out-of-tree modules after the kernel. The .ko files end up in
# sources/drivers/<drv>/ and step 08 collects them from there.
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 05 — Verify Realtek Drivers (out-of-tree)"

is_step_done "04_add_drivers" && { log "Step 04 driver verification already done, skipping."; exit 0; }

[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel source not found. Run step 02 first."

DRIVERS="rtl8188eus rtl88x2bu"

# Clean up any leftover copy that an older version of step 05 left in the
# kernel tree (in-tree). If those files stick around, the kernel build tries
# to compile them in-tree (via obj-$(CONFIG_RTL...)) and fails because their
# Makefiles aren't kbuild-friendly. Delete them and clean the entries in the
# parent Kconfig/Makefile.
REALTEK_IN_TREE="${KERNEL_DIR}/drivers/net/wireless/realtek"
for drv in ${DRIVERS}; do
    if [[ -d "${REALTEK_IN_TREE}/${drv}" ]]; then
        warn "Removing stale in-tree copy: ${REALTEK_IN_TREE}/${drv}"
        rm -rf "${REALTEK_IN_TREE}/${drv}"
    fi
done
# Clean up references to these drivers in realtek/Kconfig and realtek/Makefile
if [[ -f "${REALTEK_IN_TREE}/Kconfig" ]]; then
    sed -i '/rtl8188eus\|rtl88x2bu/d' "${REALTEK_IN_TREE}/Kconfig"
fi
if [[ -f "${REALTEK_IN_TREE}/Makefile" ]]; then
    sed -i '/rtl8188eus\|rtl88x2bu/d' "${REALTEK_IN_TREE}/Makefile"
fi

log "Verifying out-of-tree driver sources..."
for drv in ${DRIVERS}; do
    src="${DRIVERS_DIR}/${drv}"
    [[ -d "${src}" ]] || die "Driver source missing: ${src} (run step 02)"
    [[ -f "${src}/Makefile" ]] || die "Driver Makefile missing: ${src}/Makefile"
    ok "Found: ${drv} → ${src}"
done

# Apply repo-maintained driver patch files to the out-of-tree sources.
# The qcacld patches are tracked at the repo root and reference files under
# sources/drivers/...; applying them here ensures the source matches the
# checked-in compatibility fix instead of silently leaving the old warning in
# place during the out-of-tree build.
QCACLD_PATCH="${PATCHES_DIR}/qcacld/001-rtl8188e-usb_halinit-fix.patch"
if [[ -f "${QCACLD_PATCH}" ]]; then
    log "Applying rtl8188eus warning fix: $(basename "${QCACLD_PATCH}")"
    if ! git -C "${REPO_ROOT}" apply --check "${QCACLD_PATCH}" >/dev/null 2>&1; then
        warn "Patch does not apply cleanly yet — attempting with --reject"
        git -C "${REPO_ROOT}" apply --reject "${QCACLD_PATCH}" || true
    fi
    git -C "${REPO_ROOT}" apply "${QCACLD_PATCH}" || warn "Could not apply ${QCACLD_PATCH}; source may already be patched"
fi

# Apply Clang compat fixes directly to the out-of-tree source
log "Applying Clang compat fixes to driver sources..."
for drv in ${DRIVERS}; do
    drv_mk="${DRIVERS_DIR}/${drv}/Makefile"
    # GCC-only flags that Clang rejects
    sed -i '/stringop-overread/d' "${drv_mk}" 2>/dev/null || true
done
for drv_c in "${DRIVERS_DIR}"/*/core/rtw_br_ext.c; do
    [[ -f "${drv_c}" ]] || continue
    sed -i 's/#pragma GCC diagnostic ignored "-Wstringop-overread"/\/\/ pragma removed: GCC-only flag/g' "${drv_c}" 2>/dev/null || true
done
ok "Clang compat fixes applied"

# rtl8188eus uses kernel_read(), which on kernels >= 5.4 lives in the
# private namespace VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver.
# Without importing it, the module loads but fails with
# "Unknown symbol kernel_read". (rtl88x2bu upstream already imports it.)
RTL8188EUS_OSDEP="${DRIVERS_DIR}/rtl8188eus/os_dep/osdep_service.c"
if [[ -f "${RTL8188EUS_OSDEP}" ]] && ! grep -q "MODULE_IMPORT_NS" "${RTL8188EUS_OSDEP}"; then
    log "Patching rtl8188eus to import VFS internal namespace..."
    # Insert after the last #include
    awk '
        BEGIN { inserted = 0; last_include = 0 }
        /^#include/ { last_include = NR }
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (i == last_include && !inserted) {
                    print ""
                    print "#include <linux/module.h>"
                    print "MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);"
                    inserted = 1
                }
            }
        }
    ' "${RTL8188EUS_OSDEP}" > "${RTL8188EUS_OSDEP}.new"
    mv "${RTL8188EUS_OSDEP}.new" "${RTL8188EUS_OSDEP}"
    ok "Added MODULE_IMPORT_NS to rtl8188eus/os_dep/osdep_service.c"
fi

mark_step_done "04_add_drivers"
ok "Step 04 driver verification complete (drivers will compile out-of-tree in step 07)."
