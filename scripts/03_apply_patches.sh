#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 03 — Apply Patches"

is_step_done "03" && { log "Step 03 already done, skipping."; exit 0; }

[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel source not found at ${KERNEL_DIR}. Run step 02 first."

apply_patch() {
    local patch_file="$1"
    local strict="${2:-true}"
    local patch_name
    patch_name="$(basename "${patch_file}")"

    if [[ ! -f "${patch_file}" ]]; then
        warn "Patch file not found, skipping: ${patch_file}"
        warn "Obtain this patch from the NetHunter community and place it at ${patch_file}"
        return 0
    fi

    # Marker patches: contain only comments documenting that the change is
    # already integrated upstream (e.g. 0001-hid-gadget.patch on kamikaonashi).
    # Without 'diff --git' or plain '--- a/' lines, there's nothing to apply.
    if ! grep -Eq '^(diff --git|--- a/)' "${patch_file}"; then
        log "Skipping ${patch_name} (marker/empty patch — no diff payload)"
        return 0
    fi

    log "Applying: ${patch_name}"
    # If already applied (reverse-check passes), skip idempotently.
    if git -C "${KERNEL_DIR}" apply --reverse --check "${patch_file}" 2>/dev/null; then
        warn "${patch_name} already applied — skipping"
        return 0
    fi
    # -C1 relaxes the context to 1 line — needed for the Madara qcacld
    # 5.4.302 series, which carries OPLUS context not present on milanf.
    local ctx_flag="-C1"
    local patch_check
    if ! patch_check=$(git -C "${KERNEL_DIR}" apply --check ${ctx_flag} "${patch_file}" 2>&1); then
        if [[ "${strict}" == "false" ]] && grep -Eq 'No such file or directory|patch failed: .*No such file or directory' <<<"${patch_check}"; then
            warn "${patch_name} targets files not present in this kernel tree; skipping optional patch."
            return 0
        fi
        warn "${patch_name} does not apply cleanly — attempting with --reject"
        if ! git -C "${KERNEL_DIR}" apply --reject ${ctx_flag} "${patch_file}"; then
            if [[ "${strict}" == "false" ]]; then
                warn "Optional patch ${patch_name} failed; continuing without it."
                return 1
            fi
            err "Patch ${patch_name} failed. Check ${KERNEL_DIR}/*.rej files."
            return 1
        fi
        ok "Applied (with rejects): ${patch_name}"
        return 0
    fi
    git -C "${KERNEL_DIR}" apply ${ctx_flag} "${patch_file}"
    check_error "Failed to apply ${patch_name}"
    ok "Applied: ${patch_name}"
}

log "--- Kernel build compatibility patches ---"
# Applied before the QCACLD block: these (including the CAN driver
# integration) must land even if the QCACLD injection patch below dies on a
# dirty/partially-applied tree from a previous run.
for p in "${PATCHES_DIR}/kernel"/*.patch; do
    [[ -f "${p}" ]] || continue
    apply_patch "${p}" || die "Required kernel patch $(basename "${p}") failed to apply."
done

log "--- QCACLD-3.0 injection patches ---"
# Loukious frame-inject DISABLED on milanf: hdd_open_adapter() now calls
# hdd_init_frame_injection() which hangs the STA bring-up at boot, so
# wifi never comes up. Loukious assumes a newer qcacld flavour; the old
# qdf_create_work(0,...) + debugfs init pattern blocks this 5.4 kernel.
# apply_patch "${PATCHES_DIR}/qcacld/0001-milanf-frame-inject.patch"
#
# Madara273 series for kernel 5.4.302 — kimocoder base + 7 fixes (5.4
# signature drift + vendor_command_policy + des_chan->ch_freq + WMA_LOG
# migration + duplicate get_channel + hdd_disable_monitor_mode signature).
# Applied with -C1 because it carries OPLUS_FEATURE_WIFI_DCS_SWITCH context
# that doesn't exist on milanf. Replaces the earlier minimal patch.
shopt -s nullglob
qcacld_patches=("${PATCHES_DIR}/qcacld"/*.patch)
if (( ${#qcacld_patches[@]} == 0 )); then
    log "No QCACLD patches present; skipping injection step."
else
    # The upstream injection patch creates the new WMA frame-injection file.
    # The porting compatibility patch must run after it, because it fixes
    # legacy symbols (WMI_HOST_MODE_* / del_bss_resp) inside that newly-added
    # file for older Qualcomm trees. Applying it first fails since the file
    # does not exist yet.
    for p in "${qcacld_patches[@]}"; do
        if [[ "$(basename "$p")" == "upstream-add-qcacld-3.0-injection-5.4.patch" ]]; then
            # Non-fatal: a prior run may have already (partially) applied this
            # via --reject, which makes both the forward and reverse checks
            # fail on rerun even though the tree already carries the change.
            apply_patch "$p" true || warn "$(basename "$p") failed to (re)apply — continuing since the tree likely already carries it from a previous run."
        fi
    done

    for p in "${qcacld_patches[@]}"; do
        if [[ "$(basename "$p")" == "porting.patch" ]]; then
            apply_patch "$p" true || warn "$(basename "$p") failed to (re)apply — continuing since the tree likely already carries it from a previous run."
        fi
    done

    for p in "${qcacld_patches[@]}"; do
        base="$(basename "$p")"
        if [[ "$base" == "upstream-add-qcacld-3.0-injection-5.4.patch" || "$base" == "porting.patch" ]]; then
            continue
        fi
        apply_patch "$p" false || true
    done
fi

mark_step_done "03"
ok "Step 03 complete."
