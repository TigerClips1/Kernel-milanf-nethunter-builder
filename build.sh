#!/usr/bin/env bash
# Entry point — orchestrates the full milanf NetHunter build pipeline.
#
# This script is intentionally dumb and orchestration-only: it resolves the repo
# root from the script location, loads the shared config/utilities, and then
# runs the numbered steps in order. That keeps the workflow stable even when it
# is launched from /tmp or any other directory outside the repo checkout.
#
# Usage:
#   bash build.sh                       # full build (steps 01–08)
#   bash build.sh --ksu=ksunext         # build with KernelSU Next (default)
#   bash build.sh --step=configure      # integrate KSU Next + configure
#   bash build.sh --step=compile        # integrate + configure + compile
#   bash build.sh --step=package        # integrate + configure + compile + package
#   bash build.sh --clean               # remove .done_* markers to force re-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export REPO_ROOT="${SCRIPT_DIR}"

STEP=""
CLEAN=0
for arg in "$@"; do
    case "${arg}" in
        --step=*)  STEP="${arg#--step=}" ;;
        --ksu=*)   export KSU="${arg#--ksu=}" ;;
        --clean)   CLEAN=1 ;;
        *)         echo "Unknown argument: ${arg}" >&2; exit 1 ;;
    esac
done

source "${SCRIPT_DIR}/scripts/lib/config.sh"
source "${SCRIPT_DIR}/scripts/lib/utils.sh"

# Tee all output to build-main.log (only when not already redirected)
if [[ -z "${_BUILD_LOGGING:-}" ]]; then
    export _BUILD_LOGGING=1
    mkdir -p "${REPO_ROOT}/out"
    exec > >(tee "${REPO_ROOT}/out/build-main.log") 2>&1
fi

if [[ ${CLEAN} -eq 1 ]]; then
    log "Removing build markers and KernelSU mode cache..."
    rm -f "${REPO_ROOT}"/.done_* "${KSU_STATE_FILE}"
    ok "Done markers removed. Next run will re-execute all steps."
    exit 0
fi

# The build caches step completion and the current KernelSU mode. If the
# integration mode, pinned ref, or validation policy changes, downstream
# config/build/package steps must be rerun because they depend on the specific
# hook set and module ABI.
KSU_STATE="${KSU}:${KSU_NEXT_REF}:manual-hooks-v2"
PREVIOUS_KSU_STATE=""
[[ -f "${KSU_STATE_FILE}" ]] && PREVIOUS_KSU_STATE="$(cat "${KSU_STATE_FILE}")"
if [[ "${PREVIOUS_KSU_STATE}" != "${KSU_STATE}" ]]; then
    log "KernelSU build mode changed; invalidating integration/config/build/package markers..."
    rm -f "${REPO_ROOT}/.done_04" "${REPO_ROOT}/.done_04_add_drivers" "${REPO_ROOT}/.done_05" "${REPO_ROOT}/.done_06" \
          "${REPO_ROOT}/.done_07" "${REPO_ROOT}/.done_08"
    printf '%s\n' "${KSU_STATE}" > "${KSU_STATE_FILE}"
fi

run_step() {
    local num="$1"
    bash "${SCRIPT_DIR}/scripts/${num}.sh"
}

case "${STEP}" in
    "")
        banner "nethunter-milanf — Full Build"
        run_step "01_setup_env"
        run_step "02_clone_sources"
        run_step "03_apply_patches"
        run_step "04_integrate_ksu"
        run_step "04_add_drivers"
        run_step "05_configure"
        run_step "06_build"
        run_step "07_package"
        ;;
    configure)
        run_step "04_integrate_ksu"
        run_step "05_configure"
        ;;
    compile)
        run_step "04_integrate_ksu"
        run_step "05_configure"
        run_step "06_build"
        ;;
    package)
        run_step "04_integrate_ksu"
        run_step "05_configure"
        run_step "06_build"
        run_step "07_package"
        ;;
    *)
        die "Unknown step: ${STEP}. Valid: configure | compile | package"
        ;;
esac
