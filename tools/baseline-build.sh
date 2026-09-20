#!/bin/bash
# =============================================================================
# baseline-build.sh - "is the ROM-module CRC mismatch OUR fault?"
# =============================================================================
# Builds the kernel with ONLY the ROM's own running config - no NetHunter
# fragment, no extra options, nothing of ours - into a separate O= directory
# (kernel/out-baseline) so the real build in kernel/out is left untouched.
#
# Why you would run this
# ----------------------
# `./build-nethunter-kernel.sh verify` compares every one of the ROM's prebuilt
# modules against the freshly built Module.symvers. If it reports mismatches,
# those symbol CRCs each depend on a large shared struct (struct device,
# sk_buff, task_struct, crypto_alg, ...). This script answers the obvious
# question - is it our config, or something else entirely?
#
#   * baseline ALSO mismatches  -> the config is exonerated; the cause is
#                                  outside it (source tree / commit / build
#                                  inputs / wrong stock config)
#   * baseline MATCHES          -> one of our options is responsible, and the
#                                  fragment can be bisected
#
# On this device the answer was: baseline matched (0/77), and the culprit was
# CONFIG_BRIDGE_NETFILTER - which is exactly why Path B exists.
#
# Usage
# -----
#   tools/baseline-build.sh [path/to/stock-running-kernel.config.txt]
#
# The stock config must be the ROM's own running config, i.e. the output of:
#     adb shell 'zcat /proc/config.gz' > stock-running-kernel.config.txt
# taken BEFORE this kernel was flashed (afterwards /proc/config.gz shows OUR
# config, which would make the experiment meaningless).
# Without an argument the script tries, in order:
#     $1  ->  output/rom-config.txt  ->  `adb shell zcat /proc/config.gz`
#
# Afterwards:
#   tools/verify-module-crc.sh kernel/out-baseline/Module.symvers output/rom-modules
#
# Notes
# -----
# * The release string the baseline produces is irrelevant: genksyms CRCs are
#   computed from type tables, not from the version string.
# * Same rule as everywhere else in this project: never run two builds against
#   one O= directory at the same time.
# =============================================================================
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$PROJECT/kernel/out-baseline"
JOBS="${JOBS:-$(nproc)}"

# --- locate the toolchain (whatever clang-* is unpacked here) ---------------
CLANG_DIR="$(find "$PROJECT/toolchains" -maxdepth 1 -mindepth 1 -type d -name 'clang-*' 2>/dev/null | sort | head -1)"
[ -n "$CLANG_DIR" ] || {
	echo "no clang toolchain found - run: ./build-nethunter-kernel.sh toolchains" >&2
	exit 1
}

# --- locate the stock config ------------------------------------------------
ROM_CONFIG="${1:-}"
if [ -z "$ROM_CONFIG" ]; then
	if [ -f "$PROJECT/output/rom-config.txt" ]; then
		ROM_CONFIG="$PROJECT/output/rom-config.txt"
	elif command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
		ROM_CONFIG="$PROJECT/output/rom-config.txt"
		echo "=== pulling the running config off the connected device ==="
		adb shell 'zcat /proc/config.gz' | tr -d '\r' > "$ROM_CONFIG"
		echo "    (only meaningful if that device still runs the STOCK ROM kernel)"
	fi
fi
[ -n "$ROM_CONFIG" ] && [ -f "$ROM_CONFIG" ] || {
	echo "usage: $0 [path/to/stock-running-kernel.config.txt]" >&2
	echo "  e.g. adb shell 'zcat /proc/config.gz' > stock-running-kernel.config.txt" >&2
	exit 1
}

export PATH="$CLANG_DIR/bin:$PATH"
export ARCH=arm64

# Must match the flags build-nethunter-kernel.sh uses, otherwise Kconfig probes
# (LD_IS_LLD / LTO_CLANG / CFI_CLANG) resolve differently and the comparison is
# meaningless. LOCALVERSION is deliberately absent - it does not affect CRCs.
ARGS=(
	"ARCH=arm64"
	"CC=clang" "LD=ld.lld" "AR=llvm-ar" "NM=llvm-nm"
	"OBJCOPY=llvm-objcopy" "OBJDUMP=llvm-objdump" "READELF=llvm-readelf"
	"OBJSIZE=llvm-size" "STRIP=llvm-strip"
	"CROSS_COMPILE=aarch64-linux-gnu-" "CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
	"CLANG_TRIPLE=aarch64-linux-gnu-" "LLVM_IAS=1"
)

[ -x "$CLANG_DIR/bin/clang" ] || { echo "clang missing in $CLANG_DIR" >&2; exit 1; }
[ -d "$PROJECT/kernel" ] || { echo "kernel source missing - run: ./build-nethunter-kernel.sh source" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$ROM_CONFIG" "$OUT/.config"
echo "=== baseline: ROM config copied verbatim ($(grep -c '' "$OUT/.config") lines) ==="

cd "$PROJECT/kernel"

echo "=== olddefconfig ==="
make O="$OUT" "${ARGS[@]}" olddefconfig

echo "=== building Image ==="
make -j"$JOBS" O="$OUT" "${ARGS[@]}" Image

echo "=== building modules (for Module.symvers) ==="
make -j"$JOBS" O="$OUT" "${ARGS[@]}" modules

echo "=== baseline build finished ==="
echo "release: $(cat "$OUT/include/config/kernel.release" 2>/dev/null)"
echo "next   : tools/verify-module-crc.sh kernel/out-baseline/Module.symvers output/rom-modules"
