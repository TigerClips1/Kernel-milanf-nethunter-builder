#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/utils.sh"

banner "Step 02 — Clone Sources"

is_step_done "02" && [[ -n "${SKIP_CLONE:-}" ]] && { log "Step 02 already done, skipping."; exit 0; }

clone_or_skip() {
    local dest="$1" url="$2" branch="${3:-}"
    if [[ -d "${dest}/.git" ]] && [[ -n "${SKIP_CLONE:-}" ]]; then
        log "Skipping (SKIP_CLONE set): ${dest}"
        return 0
    fi
    if [[ -d "${dest}/.git" ]]; then
        warn "Destination exists, removing: ${dest}"
        rm -rf "${dest}"
    fi
    local branch_args=()
    [[ -n "${branch}" ]] && branch_args=(-b "${branch}")
    log "Cloning ${url} ${branch:+(branch: $branch)}..."
    git clone --depth=1 "${branch_args[@]}" "${url}" "${dest}"
    check_error "Failed to clone ${url}"
    ok "Cloned: $(basename "${dest}")"
}

fetch_aosp_clang() {
    mkdir -p "$(dirname "${CLANG_DIR}")"
    local tarball="$(dirname "${CLANG_DIR}")/${CLANG_PREBUILT}.tar.gz"
    local url
    for url in "${CLANG_URLS[@]}"; do
        log "Downloading AOSP clang prebuilt archive: ${url}"
        rm -f "${tarball}"
        if ! curl -fL --retry 3 --connect-timeout 20 -o "${tarball}" "${url}"; then
            warn "Download failed: ${url}"
            continue
        fi
        rm -rf "${CLANG_DIR}"
        mkdir -p "${CLANG_DIR}"
        if ! tar -xzf "${tarball}" -C "${CLANG_DIR}"; then
            warn "Could not extract ${tarball}"
            continue
        fi
        rm -f "${tarball}"

        # AOSP ships bin/clang as a SYMLINK to bin/clang-NN, so the search must
        # accept symlinks (-type l) as well as regular files.
        local found
        found="$(find "${CLANG_DIR}" -path "*/${CLANG_SUBDIR}/bin/clang" \( -type f -o -type l \) | head -n 1 || true)"
        [[ -n "${found}" ]] || found="$(find "${CLANG_DIR}" -path '*/bin/clang' \( -type f -o -type l \) | head -n 1 || true)"

        if [[ -z "${found}" ]]; then
            warn "No bin/clang in archive. Top-level contents: $(ls "${CLANG_DIR}" | head -n 10 | tr '\n' ' ')"
            rm -rf "${CLANG_DIR}"
            continue
        fi

        # Hoist the real toolchain root so ${CLANG_DIR}/bin contains clang AND
        # ld.lld / llvm-ar / llvm-nm / ... (the build needs them on PATH).
        local root
        root="$(dirname "$(dirname "${found}")")"
        if [[ "${root}" != "${CLANG_DIR}" ]]; then
            rm -rf "${CLANG_DIR}.tmp"
            mv "${root}" "${CLANG_DIR}.tmp"
            rm -rf "${CLANG_DIR}"
            mv "${CLANG_DIR}.tmp" "${CLANG_DIR}"
        fi

        if is_valid_clang21 "${CLANG_DIR}/bin/clang"; then
            ok "Downloaded the requested AOSP toolchain (${CLANG_SUBDIR}) to ${CLANG_DIR}"
            return 0
        fi
        warn "clang found but rejected by version check: $("${CLANG_DIR}/bin/clang" --version 2>&1 | head -n 1)"
        rm -rf "${CLANG_DIR}"
    done
    return 1
}

log "--- Clang toolchain ---"
if [[ -x "${CLANG_DIR}/bin/clang" ]] && is_valid_clang21 "${CLANG_DIR}/bin/clang"; then
    log "AOSP clang toolchain found at ${CLANG_DIR}/bin/clang"
    CLANG_BIN="${CLANG_DIR}/bin/clang"
elif CLANG_BIN="$(detect_clang)"; then
    log "clang toolchain found: ${CLANG_BIN} — creating symlink tree at ${CLANG_DIR}/bin"
    mkdir -p "${CLANG_DIR}/bin"
    real_clang="$(command -v "${CLANG_BIN}")"
    for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip llvm-readelf llvm-size; do
        sys_bin="$(command -v "${tool}" 2>/dev/null || true)"
        link="${CLANG_DIR}/bin/${tool}"
        if [[ -n "${sys_bin}" ]]; then
            ln -sf "${sys_bin}" "${link}"
        elif [[ "${tool}" == "clang" || "${tool}" == "clang++" ]]; then
            ln -sf "${real_clang}" "${link}"
        fi
    done
    ln -sf "${real_clang}" "${CLANG_DIR}/bin/clang-21"
    ok "Clang toolchain symlink tree ready: ${CLANG_DIR}/bin"
elif fetch_aosp_clang; then
    CLANG_BIN="${CLANG_DIR}/bin/clang"
    log "Using downloaded AOSP clang toolchain: ${CLANG_BIN}"
else
    die "No valid AOSP clang 20/21 toolchain found. Download failed and a compatible local toolchain is not installed."
fi

log "--- Kernel source ---"
if [[ -d "${KERNEL_DIR}/.git" ]] && [[ -n "${SKIP_CLONE:-}" ]]; then
    log "Skipping kernel clone (SKIP_CLONE set)"
else
    if [[ -d "${KERNEL_DIR}/.git" ]]; then
        warn "Removing existing kernel dir — invalidating downstream steps 03-08"
        rm -rf "${KERNEL_DIR}"
        # Reclonar el kernel borra los patches aplicados y los drivers Realtek
        # copiados al árbol. Sin invalidar estos markers, los steps se saltan
        # y el kernel se compila incompleto (módulos Realtek faltantes).
        rm -f "$(step_done_file 03)" "$(step_done_file 04)" \
              "$(step_done_file 05)" "$(step_done_file 06)" \
              "$(step_done_file 07)" "$(step_done_file 08)"
    fi
    kernel_cloned=0
    for branch_try in "${KERNEL_BRANCH}" "main" "master" "android-14.0" "lineage-20.0" "lineage-21.0" "android-15.0"; do
        log "Trying kernel branch: ${branch_try}..."
        if git clone --depth=1 -b "${branch_try}" "${KERNEL_REPO}" "${KERNEL_DIR}" 2>&1; then
            # The milanf BoardConfigCommon selects this Motorola QGKI base;
            # milanf BoardConfig.mk adds the named device fragment below.
            found_cfg="${BASE_DEFCONFIG}"
            milanf_fragment="${KERNEL_DIR}/arch/arm64/configs/vendor/ext_config/moto-holi-milanf.config"

            if [[ -f "${KERNEL_DIR}/arch/arm64/configs/${found_cfg}" && -f "${milanf_fragment}" ]]; then
                ok "Kernel cloned on branch: ${branch_try} (Motorola QGKI base: ${found_cfg}; milanf fragment found)"
                kernel_cloned=1
                break
            else
                warn "Branch ${branch_try} is missing the milanf QGKI base or vendor/ext_config/moto-holi-milanf.config; trying next..."
                rm -rf "${KERNEL_DIR}"
            fi
        else
            warn "Branch ${branch_try} not found, trying next..."
            rm -rf "${KERNEL_DIR}" 2>/dev/null || true
        fi
    done
    [[ ${kernel_cloned} -eq 1 ]] || die "No usable milanf kernel config found on any branch."
fi
ok "Kernel source ready. Motorola QGKI base: arch/arm64/configs/${BASE_DEFCONFIG}"

log "--- AnyKernel3 ---"
clone_or_skip "${AK3_DIR}" "${AK3_REPO}"

log "--- Realtek drivers ---"
for drv in rtl8188eus rtl88x2bu rtl8192eu rtl8812au rtl8188fu; do
    url="${DRIVER_REPOS[$drv]}"
    branch="${DRIVER_BRANCHES[$drv]:-}"
    clone_or_skip "${DRIVERS_DIR}/${drv}" "${url}" "${branch}"
done

mark_step_done "02"
ok "Step 02 complete."
