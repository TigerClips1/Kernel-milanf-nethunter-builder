#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 03 — Apply Patches"

is_step_done "03" && { log "Step 03 already done, skipping."; exit 0; }

[[ -d "${KERNEL_DIR}/.git" ]] || die "Kernel source not found at ${KERNEL_DIR}. Run step 02 first."

apply_patch() {
    local patch_file="$1"
    local patch_name
    patch_name="$(basename "${patch_file}")"

    if [[ ! -f "${patch_file}" ]]; then
        warn "Patch file not found, skipping: ${patch_file}"
        warn "Obtain this patch from the NetHunter community and place it at ${patch_file}"
        return 0
    fi

    # Marker patches: contienen solo comentarios documentando que el cambio
    # ya está integrado upstream (ej: 0001-hid-gadget.patch en kamikaonashi).
    # Sin lineas 'diff --git' no hay nada que aplicar.
    if ! grep -q '^diff --git' "${patch_file}"; then
        log "Skipping ${patch_name} (marker/empty patch — no diff payload)"
        return 0
    fi

    log "Applying: ${patch_name}"
    # Si ya está aplicado (reverse-check pasa), saltar idempotentemente.
    if git -C "${KERNEL_DIR}" apply --reverse --check "${patch_file}" 2>/dev/null; then
        warn "${patch_name} already applied — skipping"
        return 0
    fi
    # -C1 relaja el contexto a 1 línea — necesario para la serie Madara
    # qcacld 5.4.302 que arrastra contexto OPLUS no presente en milanf.
    local ctx_flag="-C1"
    git -C "${KERNEL_DIR}" apply --check ${ctx_flag} "${patch_file}" 2>/dev/null || {
        warn "${patch_name} does not apply cleanly — attempting with --reject"
        git -C "${KERNEL_DIR}" apply --reject ${ctx_flag} "${patch_file}" || {
            err "Patch ${patch_name} failed. Check ${KERNEL_DIR}/*.rej files."
            exit 1
        }
        ok "Applied (with rejects): ${patch_name}"
        return 0
    }
    git -C "${KERNEL_DIR}" apply ${ctx_flag} "${patch_file}"
    check_error "Failed to apply ${patch_name}"
    ok "Applied: ${patch_name}"
}

log "--- QCACLD-3.0 injection patches ---"
# Loukious frame-inject DISABLED on milanf: hdd_open_adapter() now calls
# hdd_init_frame_injection() which hangs the STA bring-up at boot, so
# wifi never comes up. Loukious assumes a newer qcacld flavour; the old
# qdf_create_work(0,...) + debugfs init pattern blocks this 5.4 kernel.
# apply_patch "${PATCHES_DIR}/qcacld/0001-milanf-frame-inject.patch"
#
# Madara273 series para kernel 5.4.302 — base kimocoder + 7 fixes (drift
# de signatures 5.4 + vendor_command_policy + des_chan->ch_freq + WMA_LOG
# migration + duplicate get_channel + hdd_disable_monitor_mode signature).
# Aplica con -C1 porque arrastra contexto OPLUS_FEATURE_WIFI_DCS_SWITCH
# que no existe en milanf. Reemplaza al patch minimal anterior.
for p in "${PATCHES_DIR}/qcacld/*.patch"; do
    apply_patch "$p"
done

log "--- Kernel build compatibility patches ---"
for p in "${PATCHES_DIR}/kernel"/*.patch; do
    [[ -f "${p}" ]] && apply_patch "${p}"
done

mark_step_done "03"
ok "Step 03 complete."
