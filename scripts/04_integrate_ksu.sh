#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 04 — Integrate KernelSU Next for ${KERNEL_DEVICE}"

is_step_done "04" && { log "Step 04 already done, skipping."; exit 0; }
[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel source not found. Run step 02 first."

if [[ ! -d "${KSU_NEXT_DIR}/.git" ]]; then
    mkdir -p "$(dirname "${KSU_NEXT_DIR}")"
    log "Cloning KernelSU Next's legacy branch..."
    git clone --single-branch --branch legacy "${KSU_NEXT_REPO}" "${KSU_NEXT_DIR}"
fi

[[ -f "${KSU_NEXT_DIR}/kernel/Kconfig" && -f "${KSU_NEXT_DIR}/kernel/Kbuild" ]] \
    || die "KernelSU Next source is incomplete at ${KSU_NEXT_DIR}"

# Remove this port's compatibility patch before checking/resetting the pinned
# upstream checkout, then reapply it below. Do not hide any other local edits.
KSU_COMPAT_PATCH="${REPO_ROOT}/patches/kernelsu/0001-5.4-use-backported-nofault-api.patch"
[[ -f "${KSU_COMPAT_PATCH}" ]] || die "KernelSU 5.4 compatibility patch is missing: ${KSU_COMPAT_PATCH}"
if git -C "${KSU_NEXT_DIR}" apply --reverse --check "${KSU_COMPAT_PATCH}" 2>/dev/null; then
    git -C "${KSU_NEXT_DIR}" apply --reverse "${KSU_COMPAT_PATCH}"
fi

if [[ -n "$(git -C "${KSU_NEXT_DIR}" status --porcelain --untracked-files=normal)" ]]; then
    die "KernelSU Next source has local changes; refusing to reset it: ${KSU_NEXT_DIR}"
fi

# KSU's build metadata derives its reported version from the git history.
# Fetch the shallow clone's history once to avoid an implicit Kbuild fetch.
if [[ -f "${KSU_NEXT_DIR}/.git/shallow" ]]; then
    log "Fetching KernelSU Next history for reproducible version metadata..."
    git -C "${KSU_NEXT_DIR}" fetch --unshallow origin legacy
fi

if ! git -C "${KSU_NEXT_DIR}" cat-file -e "${KSU_NEXT_REF}^{commit}" 2>/dev/null; then
    git -C "${KSU_NEXT_DIR}" fetch origin "${KSU_NEXT_REF}"
fi
git -C "${KSU_NEXT_DIR}" checkout --detach "${KSU_NEXT_REF}"
[[ "$(git -C "${KSU_NEXT_DIR}" rev-parse HEAD)" == "${KSU_NEXT_REF}" ]] \
    || die "KernelSU Next checkout does not match pinned ref ${KSU_NEXT_REF}"
if ! git -C "${KSU_NEXT_DIR}" apply --reverse --check "${KSU_COMPAT_PATCH}" 2>/dev/null; then
    git -C "${KSU_NEXT_DIR}" apply --check "${KSU_COMPAT_PATCH}" \
        || die "KernelSU 5.4 compatibility patch no longer applies to ${KSU_NEXT_REF}"
    git -C "${KSU_NEXT_DIR}" apply "${KSU_COMPAT_PATCH}"
fi

DRIVERS_DIR_KERNEL="${KERNEL_DIR}/drivers"
KSU_LINK="${DRIVERS_DIR_KERNEL}/kernelsu"
KSU_TARGET="$(realpath "${KSU_NEXT_DIR}/kernel")"
if [[ -L "${KSU_LINK}" ]]; then
    [[ "$(realpath "${KSU_LINK}")" == "${KSU_TARGET}" ]] \
        || die "Unexpected existing KernelSU link: ${KSU_LINK} -> $(readlink "${KSU_LINK}")"
elif [[ -e "${KSU_LINK}" ]]; then
    die "Refusing to replace existing path: ${KSU_LINK}"
else
    ln -s "../../KernelSU-Next/kernel" "${KSU_LINK}"
fi

MAKEFILE="${DRIVERS_DIR_KERNEL}/Makefile"
KCONFIG="${DRIVERS_DIR_KERNEL}/Kconfig"
MAKE_ENTRY='obj-$(CONFIG_KSU) += kernelsu/'
KCONFIG_ENTRY='source "drivers/kernelsu/Kconfig"'

grep -Fqx "${MAKE_ENTRY}" "${MAKEFILE}" \
    || printf '\n%s\n' "${MAKE_ENTRY}" >> "${MAKEFILE}"
grep -Fqx "${KCONFIG_ENTRY}" "${KCONFIG}" \
    || sed -i "/^endmenu/i ${KCONFIG_ENTRY}" "${KCONFIG}"

grep -Fqx "${MAKE_ENTRY}" "${MAKEFILE}" || die "KernelSU Makefile entry was not added"
grep -Fqx "${KCONFIG_ENTRY}" "${KCONFIG}" || die "KernelSU Kconfig entry was not added"

# The syscall-table mode in this 5.4 tree does not intercept KernelSU's
# reboot-based driver-install supercall. Use the explicit legacy call sites.
KSU_HOOK_PATCH="${REPO_ROOT}/patches/kernelsu/0002-5.4-manual-hook-integration.patch"
[[ -f "${KSU_HOOK_PATCH}" ]] || die "KernelSU manual-hook patch is missing: ${KSU_HOOK_PATCH}"
if git -C "${KERNEL_DIR}" apply --reverse --check "${KSU_HOOK_PATCH}" 2>/dev/null; then
    log "KernelSU manual hooks are already applied."
else
    git -C "${KERNEL_DIR}" apply --check "${KSU_HOOK_PATCH}" \
        || die "KernelSU manual-hook patch no longer applies to ${KERNEL_DIR}"
    git -C "${KERNEL_DIR}" apply "${KSU_HOOK_PATCH}"
    ok "KernelSU manual hooks applied to the 5.4 kernel source."
fi

ok "KernelSU Next source pinned at ${KSU_NEXT_REF} and wired into drivers/"

mark_step_done "04"
ok "Step 04 complete."
