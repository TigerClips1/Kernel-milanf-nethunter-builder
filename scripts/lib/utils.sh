#!/usr/bin/env bash
# Shared utilities: logging, error handling, banners

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_error() {
    local exit_code=$?
    local msg="${1:-Command failed}"
    if [[ $exit_code -ne 0 ]]; then
        err "$msg (exit $exit_code)"
        exit $exit_code
    fi
}

die() {
    err "$*"
    exit 1
}

banner() {
    local msg="$*"
    local len=${#msg}
    local border
    border=$(printf '═%.0s' $(seq 1 $((len + 4))))
    echo -e "\n${BOLD}${CYAN}╔${border}╗${NC}"
    echo -e "${BOLD}${CYAN}║  ${msg}  ║${NC}"
    echo -e "${BOLD}${CYAN}╚${border}╝${NC}\n"
}

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}

is_valid_clang21() {
    local compiler="${1:-}"
    [[ -n "${compiler}" ]] || return 1
    local version
    version=$("${compiler}" --version 2>/dev/null | head -n 1 || true)

    # Accept the real AOSP Android 16 toolchain family used by LineageOS 23.2.
    # Public prebuilts are generally AOSP clang 20/21-compatible; some builds
    # report r547379 or r563880c, while generic Debian/Ubuntu clang builds are
    # not compatible with this 5.4-based kernel tree.
    [[ "${version}" != *"Debian clang version"* ]] || return 1
    [[ "${version}" == *"clang version 20"* || "${version}" == *"clang version 21"* || "${version}" == *"r547379"* || "${version}" == *"r563880c"* ]]
}

detect_clang() {
    local candidate
    if [[ -x "${CLANG_DIR}/bin/clang" ]]; then
        if is_valid_clang21 "${CLANG_DIR}/bin/clang"; then
            echo "${CLANG_DIR}/bin/clang"
            return 0
        fi
    fi
    for candidate in "${CLANG_BIN:-}" clang-r547379 clang-r563880c clang-21 clang; do
        [[ -z "${candidate}" ]] && continue
        if command -v "${candidate}" &>/dev/null; then
            local resolved
            resolved="$(command -v "${candidate}")"
            if is_valid_clang21 "${resolved}"; then
                echo "${resolved}"
                return 0
            fi
        fi
    done
    return 1
}

step_done_file() {
    echo "${REPO_ROOT}/.done_${1}"
}
 
is_step_done() {
    local step="${1:-}"
    local marker
    marker="$(step_done_file "${step}")"
    [[ -f "${marker}" ]] || return 1

    case "${step}" in
        03)
            local can_makefile="${KERNEL_DIR}/drivers/net/can/Makefile"
            if [[ ! -f "${can_makefile}" ]] || ! grep -q 'can-isotp/' "${can_makefile}" || ! grep -q 'usb-can-2-module/' "${can_makefile}"; then
                warn "Stale Step 03 marker found: ${marker} but the CAN driver integration patch is missing; clearing it."
                rm -f "${marker}"
                return 1
            fi
            ;;
        04_add_drivers)
            local driver_file="${DRIVERS_DIR}/rtl8188eus/hal/rtl8188e/usb/usb_halinit.c"
            if [[ ! -f "${driver_file}" ]] || grep -Eq 'if \(\(IS_FULL_SPEED_USB\(Adapter\)\)[[:space:]]*$' "${driver_file}"; then
                warn "Stale Step 04_add_drivers marker found: ${marker} but the rtl8188eus warning fix is missing; clearing it."
                rm -f "${marker}"
                return 1
            fi
            ;;
        05)
            if [[ ! -f "${OUT_DIR}/.config" ]]; then
                warn "Stale Step 05 marker found: ${marker} but ${OUT_DIR}/.config is missing; clearing it."
                rm -f "${marker}"
                return 1
            fi
            if ! grep -q '^CONFIG_KSU=y$' "${OUT_DIR}/.config" || \
               ! grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "${OUT_DIR}/.config" || \
               grep -q '^CONFIG_KSU_SYSCALL_TABLE_HOOK=y$' "${OUT_DIR}/.config"; then
                warn "Stale Step 05 marker found: ${marker} but KernelSU hook options are not in the expected manual-hook state; clearing it."
                rm -f "${marker}"
                return 1
            fi
            ;;
        06)
            if [[ ! -f "${OUT_DIR}/arch/arm64/boot/Image.gz" && \
                  ! -f "${OUT_DIR}/arch/arm64/boot/Image.gz-dtb" && \
                  ! -f "${OUT_DIR}/arch/arm64/boot/Image" ]]; then
                warn "Stale Step 06 marker found: ${marker} but no kernel image exists in ${OUT_DIR}; clearing it."
                rm -f "${marker}"
                return 1
            fi
            ;;
    esac
    return 0
}

mark_step_done() {
    touch "$(step_done_file "$1")"
}

