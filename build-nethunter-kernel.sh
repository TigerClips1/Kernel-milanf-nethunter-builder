#!/usr/bin/env bash
# =============================================================================
# NetHunter kernel build script - Moto G Stylus 5G (2022), milanf / SM6375
# =============================================================================
# Builds a Kali NetHunter kernel from the LineageOS 23.2 kernel source using
# the SAME configuration chain the ROM uses, plus config/nethunter_milanf.fragment:
#
#   vendor/holi-qgki_defconfig
#   vendor/ext_config/lineage_moto-holi.config
#   vendor/ext_config/moto-holi-milanf.config
#   config/nethunter_milanf.fragment          <- NetHunter additions
#
# Usage:
#   ./build-nethunter-kernel.sh                 # everything (default)
#   ./build-nethunter-kernel.sh doctor          # show plan / detect stock release
#   ./build-nethunter-kernel.sh toolchains      # download AOSP clang
#   ./build-nethunter-kernel.sh source          # clone kernel + AnyKernel3
#   ./build-nethunter-kernel.sh config          # merge + validate config
#   ./build-nethunter-kernel.sh build           # compile Image (+ modules for CRC check)
#   ./build-nethunter-kernel.sh verify          # compare CRCs against the ROM's modules
#   ./build-nethunter-kernel.sh zip             # assemble flashable AK3 zip
#   ./build-nethunter-kernel.sh clean
#
# PATH B - ship our own module set: enables the options that change shared
# struct layouts (bridge netfilter, CAN/SLCAN, xt_REALM, xt_CONNLABEL) and
# therefore alter symbol CRCs. The ROM's prebuilt modules cannot be used any
# more, so this path builds the full module set and delivers it through the
# vendor_boot ramdisk (its lib/modules, loaded by first-stage init):
#
#   PATH_B=1 ./build-nethunter-kernel.sh config    # also merges config/pathb.fragment
#                                                 # + config/nethunter-docs.fragment
#   PATH_B=1 ./build-nethunter-kernel.sh build     # Image + ALL modules, stripped
#   PATH_B=1 ./build-nethunter-kernel.sh payload   # vendor_boot image with our modules
#
# config/nethunter-docs.fragment is the "everything the Kali NetHunter kernel
# docs ask for" file (SDR/RTL-SDR, ZyDAS/MT7601U/ATH6KL/CARL9170, mac80211
# mesh + WEXT, BT dongles, SYSVIPC for Metasploit, the remaining CAN drivers).
# It is Path B only for the same CRC reason as pathb.fragment.
#
#   flash boot        : the AK3 zip (or `fastboot flash boot`)
#   flash vendor_boot : fastboot flash vendor_boot_a output/vendor_boot-pathb-milanf.img
#   A Path B kernel ONLY works together with that vendor_boot image (and vice versa).
#   Verify first: PATH_B=1 ./build-nethunter-kernel.sh verify   (expect the ROM's
#   prebuilt modules to MISMATCH - that is exactly why we ship our own).
#
# PATCH_INJECT - optional frame injection on the BUILD-IN QUALCOMM WI-FI:
#   applies patches/inject/*.patch to drivers/staging/qcacld-3.0 (and
#   qca-wifi-host-cmn) before compiling, i.e. monitor mode + frame injection on
#   the internal chip instead of an external USB adapter. Needs Path B, because
#   the patched wlan.ko has to be shipped in the vendor_boot ramdisk.
#
#   PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh build
#   PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh payload
#
#   See patches/inject/README.md. The patches touch only driver sources, so the
#   release string, the kernel Image and every other module stay unchanged.
#
# ALWAYS build like this so the ROM's prebuilt vendor modules keep loading:
#   STOCK_RELEASE="$(adb shell uname -r)" ./build-nethunter-kernel.sh
# See README.md -> "Module compatibility (read this first)".
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------- device info
DEVICE_CODENAME="milanf"
DEVICE_MODEL="Moto G Stylus 5G (2022)"
SOC="sm6375"
PLATFORM="holi"
ARCH="arm64"
KERNEL_VERSION="5.4"
KERNEL_BRANCH="lineage-23.2"
KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm6375"
AK3_REPO="https://github.com/osm0sis/AnyKernel3"

# Kernel commit the ROM kernel was built from. `uname -r` on the device ends in
# "-g<12 hex chars>" (scripts/setlocalversion), which is the beginning of this
# sha. Building from the same commit keeps symbol CRCs identical to the ROM's
# prebuilt modules. Update it (and STOCK_RELEASE) whenever LineageOS updates.
KERNEL_COMMIT="${KERNEL_COMMIT:-c8bc4b74db62d4d4b24c575046f140f4e6732898}"

# Base configuration chain - must match device/motorola/sm6375-common
# (TARGET_KERNEL_CONFIG) and device/motorola/milanf (BoardConfig.mk).
BASE_DEFCONFIG="vendor/holi-qgki_defconfig"
ROM_FRAGMENTS=(
	"arch/arm64/configs/vendor/ext_config/lineage_moto-holi.config"
	"arch/arm64/configs/vendor/ext_config/moto-holi-milanf.config"
)
NH_FRAGMENT_REL="config/nethunter_milanf.fragment"

# The stock kernel is built with CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL=y
KERNEL_IMAGE_NAME="Image"

# AOSP clang prebuilt. LineageOS 23.2 uses clang 21 (r563880c): the device's
# kernel reports "clang version 21.0.0 ... based on r563880c" and LineageOS'
# manifest pins prebuilts/clang/host/linux-x86 to the AOSP tag below, which is
# the only place that still carries r563880c (the main branch has up to
# clang-r547379 = clang 20).
CLANG_PREBUILT="${CLANG_PREBUILT:-clang-r563880c}"
CLANG_TAG="${CLANG_TAG:-android-16.0.0_r4}"
CLANG_URLS=(
	"https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/${CLANG_TAG}/${CLANG_PREBUILT}.tar.gz"
	"https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/${CLANG_PREBUILT}.tar.gz"
)

# Stock release string (output of `uname -r` on the device running the ROM).
# Precedence: $STOCK_RELEASE -> adb -> the value recorded below.
STOCK_RELEASE="${STOCK_RELEASE:-}"
DEFAULT_STOCK_RELEASE="5.4.302-moto-gc8bc4b74db62"   # read from the device 2026-09-19

# ------------------------------------------------------------------- paths
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$PROJECT_DIR/kernel"
OUT_DIR="$KERNEL_DIR/out"
TOOLCHAINS_DIR="$PROJECT_DIR/toolchains"
CLANG_DIR="$TOOLCHAINS_DIR/$CLANG_PREBUILT"
AK3_DIR="$PROJECT_DIR/anykernel3"
OUTPUT_DIR="$PROJECT_DIR/output"
ANYKERNEL_SRC="$PROJECT_DIR/anykernel"
NH_FRAGMENT="$PROJECT_DIR/$NH_FRAGMENT_REL"
LOCALVERSION_FRAGMENT="$OUTPUT_DIR/localversion.fragment"
ZIP_NAME="nethunter-kernel-${DEVICE_CODENAME}.zip"

# Path B (see the usage header): our own module set + vendor_boot payload.
PATH_B_MODE="${PATH_B:-0}"
PATHB_FRAGMENT="$PROJECT_DIR/config/pathb.fragment"
DOCS_FRAGMENT="$PROJECT_DIR/config/nethunter-docs.fragment"   # docs parity (Path B)
# Optional: monitor mode + injection on the built-in Qualcomm Wi-Fi (Path B only).
PATCH_INJECT_MODE="${PATCH_INJECT:-0}"
INJECT_DIR="$PROJECT_DIR/patches/inject"
INJECT_UPSTREAM="$INJECT_DIR/upstream-add-qcacld-3.0-injection-5.4.patch"
INJECT_PORTING="$INJECT_DIR/porting.patch"
MODULES_STAGE="$OUTPUT_DIR/modules"            # modules_install root (nested layout)
MODULES_FLAT_ROOT="$OUTPUT_DIR/modules-flat"   # flat lib/modules/<rel>/*.ko + depmod output
VENDOR_BOOT_STOCK="$OUTPUT_DIR/vendor_boot-stock-${DEVICE_CODENAME}.img"
VENDOR_BOOT_PATHB="$OUTPUT_DIR/vendor_boot-pathb-${DEVICE_CODENAME}.img"
VENDOR_BOOT_WORK="$OUTPUT_DIR/vendor_boot-work"

JOBS="${JOBS:-$(nproc)}"

# Toolchain arguments for BOTH the config and the build step.
# The config step needs them just as much as the build: Kconfig probes the
# compiler/linker/assembler to derive CONFIG_LD_IS_LLD, CONFIG_LTO_CLANG and
# CONFIG_CFI_CLANG, and (verified on this device) every ROM module imports
# __cfi_slowpath, which only exists with CONFIG_CFI_CLANG=y. Generating the
# config without these flags silently produces a kernel without LTO/CFI that
# cannot load any of the ROM's modules.
TOOLCHAIN_ARGS=(
	"ARCH=$ARCH"
	"CC=clang"
	"LD=ld.lld"
	"AR=llvm-ar"
	"NM=llvm-nm"
	"OBJCOPY=llvm-objcopy"
	"OBJDUMP=llvm-objdump"
	"READELF=llvm-readelf"
	"OBJSIZE=llvm-size"
	"STRIP=llvm-strip"
	"CROSS_COMPILE=aarch64-linux-gnu-"
	"CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
	"CLANG_TRIPLE=aarch64-linux-gnu-"
	"LLVM_IAS=1"
	# Set LOCALVERSION explicitly (even though it is empty) so that
	# scripts/setlocalversion skips its scm-version block:
	#   if test "${LOCALVERSION+set}" != "set"; then ... res="$res${scm:++}"
	# With LOCALVERSION unset and HEAD not at an exact signed tag, that block
	# appends "+" to the release string. A "+" changes the module vermagic, so
	# the ROM's prebuilt vendor modules (Wi-Fi/touch/charger) would refuse to
	# load. Verified on this tree:
	#   without LOCALVERSION -> 5.4.302-moto-gc8bc4b74db62+
	#   with    LOCALVERSION -> 5.4.302-moto-gc8bc4b74db62   (what the ROM runs)
	"LOCALVERSION="
)

# ------------------------------------------------------------------- output
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[ info ]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn ]${NC} $*"; }
err()  { echo -e "${RED}[ fail ]${NC} $*" >&2; }
die()  { echo -e "${RED}[ fail ]${NC} $*" >&2; exit 1; }

# =============================================================================
# dependencies
# =============================================================================
check_deps() {
	local missing
	missing="$(missing_deps)"
	if [ -n "$missing" ]; then
		die "missing tools: ${missing//$'\n'/ }
  Install: sudo apt install -y build-essential bc bison flex libssl-dev libelf-dev \\
           libncurses-dev device-tree-compiler xz-utils lz4 zip unzip git wget \\
           curl cpio python3 rsync kmod"
	fi
}

missing_deps() {
	local cmd out=""
	for cmd in git make bc bison flex zip unzip wget curl cpio python3 depmod cc; do
		command -v "$cmd" >/dev/null 2>&1 || out+=" $cmd"
	done
	echo "$out"
}

# =============================================================================
# toolchains - clang only (device tree sets TARGET_KERNEL_NO_GCC := true)
# =============================================================================
fetch_toolchains() {
	if [ -x "$CLANG_DIR/bin/clang" ]; then
		ok "clang already present: $("$CLANG_DIR/bin/clang" --version | head -n1)"
		return 0
	fi

	mkdir -p "$TOOLCHAINS_DIR"
	local tmp="$TOOLCHAINS_DIR/clang.tar.gz" url got=0
	for url in "${CLANG_URLS[@]}"; do
		log "downloading ${CLANG_PREBUILT} from ${url%%/+archive*}"
		if wget -q --show-progress "$url" -O "$tmp" || curl -fsSL "$url" -o "$tmp"; then
			rm -rf "$CLANG_DIR"
			mkdir -p "$CLANG_DIR"
			if tar -xzf "$tmp" -C "$CLANG_DIR"; then
				if [ -x "$CLANG_DIR/bin/clang" ]; then
					got=1
					break
				fi
				warn "archive extracted but bin/clang is missing"
			else
				warn "could not extract $(basename "$tmp")"
			fi
		fi
		rm -f "$tmp"
	done
	rm -f "$tmp"

	if [ "$got" != "1" ]; then
		die "could not fetch clang prebuilt '$CLANG_PREBUILT' (tag ${CLANG_TAG}).
  Options:
    - another version:  CLANG_PREBUILT=clang-r547379 ./build-nethunter-kernel.sh toolchains
    - another tag:      CLANG_TAG=android-16.0.0_r1 ./build-nethunter-kernel.sh toolchains
    - or copy one from a LineageOS tree (prebuilts/clang/host/linux-x86/clang-*)
      to $CLANG_DIR"
	fi

	local ver
	ver="$("$CLANG_DIR/bin/clang" --version | head -n1)"
	ok "clang: $ver"
	case "$ver" in
		*"clang version 21"*) : ;;
		*) warn "LineageOS 23.2 builds this kernel with clang 21.0.0 (r563880c)."
		   warn "A different major version still builds and boots, but the ROM's"
		   warn "prebuilt modules were compiled with clang 21 (relevant for CFI)." ;;
	esac
}

# =============================================================================
# sources
# =============================================================================
fetch_source() {
	if [ -d "$KERNEL_DIR/.git" ]; then
		log "kernel source present - fetching $KERNEL_BRANCH"
		git -C "$KERNEL_DIR" fetch --depth=1 origin "$KERNEL_BRANCH"
	else
		rm -rf "$KERNEL_DIR"
		log "cloning $KERNEL_REPO ($KERNEL_BRANCH)"
		git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
	fi

	# Pin to the commit the ROM's kernel (and therefore its modules) was built
	# from, so exported symbol CRCs stay identical.
	if [ -n "$KERNEL_COMMIT" ]; then
		if git -C "$KERNEL_DIR" fetch --depth=1 origin "$KERNEL_COMMIT" >/dev/null 2>&1; then
			git -C "$KERNEL_DIR" checkout --detach --force FETCH_HEAD >/dev/null 2>&1
			ok "kernel pinned to ${KERNEL_COMMIT:0:12} (matches the ROM build)"
		else
			warn "could not fetch commit ${KERNEL_COMMIT:0:12} - staying on the tip of $KERNEL_BRANCH"
			warn "the ROM's prebuilt modules may then be rejected with a symbol CRC error."
			warn "Set KERNEL_COMMIT='' to silence this, or fix the sha."
		fi
	fi
	ok "kernel source: $KERNEL_DIR ($(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD 2>/dev/null))"

	if [ -d "$AK3_DIR/.git" ]; then
		git -C "$AK3_DIR" pull --ff-only || true
	else
		rm -rf "$AK3_DIR"
		log "cloning AnyKernel3"
		git clone --depth=1 "$AK3_REPO" "$AK3_DIR"
	fi
	ok "AnyKernel3: $AK3_DIR"
}

# =============================================================================
# configuration
# =============================================================================
# Some host tools inside this 5.4 tree are older than the host's OpenSSL.
# scripts/extract-cert.c uses the OpenSSL ENGINE API (PKCS#11 support) which was
# REMOVED in OpenSSL 4.0, so linking fails with undefined references to
# ENGINE_by_id/ENGINE_init/ENGINE_ctrl_cmd*:
#
#   collect2: error: ld returned 1 exit status
#   make[2]: *** [scripts/Makefile.host:107: scripts/extract-cert] Error 1
#
# The pkcs11 branch is only reachable when CONFIG_SYSTEM_TRUSTED_KEYS or
# CONFIG_MODULE_SIG_KEY is a "pkcs11:" URI (neither is the case here; this
# kernel has MODULE_SIG off and an empty trusted keyring), so make it fail at
# runtime instead of failing to build. Host-tool only - the kernel image and
# every config option stay identical, so module CRCs are unaffected.
fix_host_tools() {
	local f="$KERNEL_DIR/scripts/extract-cert.c"
	[ -f "$f" ] || return 0
	if [ "${NH_NO_HOST_PATCH:-0}" = "1" ]; then
		warn "host-tool patch skipped (NH_NO_HOST_PATCH=1)"
		return 0
	fi
	grep -q "OPENSSL_VERSION_NUMBER >= 0x40000000L" "$f" && return 0

	# NOTE: do not trust `openssl version` here - on mismatched hosts the CLI
	# can report 3.x while the headers (and the libcrypto that -lcrypto resolves
	# to) are 4.x. Just apply the guard; it is a no-op on older OpenSSL.
	log "patching host tool scripts/extract-cert.c (OpenSSL ENGINE/pkcs11 path)"
	sed -i '/pkcs11:/,+1 s|^#ifdef OPENSSL_IS_BORINGSSL$|#if defined(OPENSSL_IS_BORINGSSL) \|\| OPENSSL_VERSION_NUMBER >= 0x40000000L|' "$f"
	grep -q "OPENSSL_VERSION_NUMBER >= 0x40000000L" "$f" \
		|| die "could not patch scripts/extract-cert.c - apply patches/host-openssl4-extract-cert.patch manually"
	ok "host tool patched (pkcs11 support now errors at runtime instead of failing the link)"
}

stock_suffix() {
	# "5.4.302-moto-g1234abc" -> "-moto-g1234abc"   |   "5.4.302" -> ""
	if [[ "$STOCK_RELEASE" == *-* ]]; then
		echo "-${STOCK_RELEASE#*-}"
	else
		echo ""
	fi
}

detect_stock_release() {
	[ -n "$STOCK_RELEASE" ] && return
	if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
		STOCK_RELEASE="$(adb shell uname -r 2>/dev/null | tr -d '\r')"
		if [ -n "$STOCK_RELEASE" ]; then
			ok "stock release read from device: $STOCK_RELEASE"
			return
		fi
	fi
	STOCK_RELEASE="$DEFAULT_STOCK_RELEASE"
	warn "no device reachable over adb - using the recorded release: $STOCK_RELEASE"
	warn "If your ROM has been updated since 2026-09-19, re-check with 'adb shell uname -r'"
	warn "and update STOCK_RELEASE / KERNEL_COMMIT (and CONFIG_LOCALVERSION in the fragment)."
}

generate_localversion_fragment() {
	mkdir -p "$OUTPUT_DIR"
	local suffix=""
	if [ -n "$STOCK_RELEASE" ]; then
		suffix="$(stock_suffix)"
		{
			echo "# generated by build-nethunter-kernel.sh - pins the kernel release"
			echo "# string to the ROM build so the prebuilt vendor modules keep loading."
			echo "CONFIG_LOCALVERSION=\"$suffix\""
			echo "# CONFIG_LOCALVERSION_AUTO is not set"
		} > "$LOCALVERSION_FRAGMENT"
		ok "pinning kernel release to '$STOCK_RELEASE' (CONFIG_LOCALVERSION=\"$suffix\")"
	else
		rm -f "$LOCALVERSION_FRAGMENT"
		warn "STOCK_RELEASE not set - using CONFIG_LOCALVERSION from the fragment."
		warn "If it does not match the ROM build, the prebuilt vendor modules in"
		warn "vendor_boot.img (Wi-Fi, touch, charger) will refuse to load."
		warn "Use:  STOCK_RELEASE=\"\$(adb shell uname -r)\" ./build-nethunter-kernel.sh"
	fi
}

validate_fragment() {
	local frag="$1" cfg="$OUT_DIR/.config" line sym wantv actual bad=0 ignore="${2:-}"
	# symbols mentioned in $2 (Path B / docs fragments, space separated) are
	# intentionally overridden by those fragments - do not report them dropped
	local ig=" " f
	for f in $ignore; do
		[ -f "$f" ] || continue
		ig="$ig$(grep -oE '^#? ?CONFIG_[A-Za-z0-9_]+' "$f" | grep -oE 'CONFIG_[A-Za-z0-9_]+' | sort -u | tr '\n' ' ')"
	done
	while IFS= read -r line; do
		if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then
			sym="${BASH_REMATCH[1]}"
			# drop an inline "# comment" and any whitespace around the value
			wantv="${BASH_REMATCH[2]%%#*}"
			wantv="${wantv//[[:space:]]/}"
		elif [[ "$line" =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
			sym="${BASH_REMATCH[1]}"; wantv=""
		else
			continue
		fi
		[[ "$ig" == *" $sym "* ]] && continue
		actual="$(sed -n "s/^${sym}=//p" "$cfg" | head -n1)"
		[ "$wantv" = "$actual" ] && continue
		printf '  ! %-46s wanted=%-14s effective=%s\n' "$sym" "${wantv:-n}" "${actual:-n}"
		bad=$((bad + 1))
	done < "$frag"
	if [ "$bad" -gt 0 ]; then
		warn "$bad symbol(s) in $(basename "$frag") were dropped or overridden by Kconfig."
		warn "Review the list above: either the symbol does not exist in 5.4 or its"
		warn "dependency is not met (usually a missing DEBUG_FS / BROKEN dependency)."
	else
		ok "every symbol in $(basename "$frag") took effect"
	fi
}

do_config() {
	[ -d "$KERNEL_DIR" ] || die "kernel source missing - run: $0 source"
	# Kconfig records the *target* compiler (CONFIG_CC_IS_CLANG, CONFIG_CLANG_VERSION,
	# all the CONFIG_CC_HAS_* capabilities that gate LTO/CFI/shadow-call-stack), so
	# the config must be generated with the same clang that will build it.
	[ -x "$CLANG_DIR/bin/clang" ] || die "clang missing - run: $0 toolchains (config must be generated with the real target compiler)"
	export PATH="$CLANG_DIR/bin:$PATH"
	generate_localversion_fragment

	cd "$KERNEL_DIR"
	export ARCH="$ARCH" SUBARCH="$ARCH"
	mkdir -p "$OUT_DIR"

	log "base config: $BASE_DEFCONFIG"
	make O="$OUT_DIR" "${TOOLCHAIN_ARGS[@]}" "$BASE_DEFCONFIG"

	local fragments=()
	local f
	for f in "${ROM_FRAGMENTS[@]}"; do
		[ -f "$f" ] || die "ROM fragment missing: $KERNEL_DIR/$f (kernel branch mismatch?)"
		fragments+=("$f")
	done
	# Absolute path: we are cd'ed into $KERNEL_DIR below, so a project-relative
	# path does not resolve. merge_config.sh aborts on a missing fragment
	# *before* writing anything, which used to leave a bare base .config behind.
	[ -f "$NH_FRAGMENT" ] || die "NetHunter fragment missing: $NH_FRAGMENT"
	fragments+=("$NH_FRAGMENT")
	# Path B deliberately overrides the CRC-sensitive "is not set" lines above,
	# so it must be merged AFTER the main fragment.
	if [ "$PATH_B_MODE" = "1" ]; then
		[ -f "$PATHB_FRAGMENT" ] || die "PATH_B=1 but $PATHB_FRAGMENT is missing"
		fragments+=("$PATHB_FRAGMENT")
		log "PATH B: also merging $(basename "$PATHB_FRAGMENT") - we ship our own modules"
		# docs parity: SDR/RTL-SDR, external Wi-Fi + BT dongles, mac80211
		# mesh/WEXT, SYSVIPC, remaining CAN drivers. Also CRC-sensitive.
		[ -f "$DOCS_FRAGMENT" ] || die "PATH_B=1 but $DOCS_FRAGMENT is missing"
		fragments+=("$DOCS_FRAGMENT")
		log "PATH B: also merging $(basename "$DOCS_FRAGMENT") - NetHunter docs parity"
	fi
	if [ -f "$LOCALVERSION_FRAGMENT" ]; then
		fragments+=("$LOCALVERSION_FRAGMENT")
	fi

	log "merging ROM fragments + NetHunter fragment"
	if ! scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "$OUT_DIR/.config" "${fragments[@]}" \
			>"$OUTPUT_DIR/merge_config.log" 2>&1; then
		tail -n 15 "$OUTPUT_DIR/merge_config.log" >&2
		die "fragment merge failed - full log: output/merge_config.log"
	fi
	make O="$OUT_DIR" "${TOOLCHAIN_ARGS[@]}" olddefconfig

	# sanity: the merge chain must have kept the device itself intact
	local must="CONFIG_MILANF_DTB CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL CONFIG_ARCH_HOLI"
	local m
	for m in $must; do
		grep -q "^${m}=y" "$OUT_DIR/.config" || die "config is broken: $m is not enabled - the base defconfig merge failed"
	done
	ok "base/device options intact (MILANF_DTB, holi, uncompressed Image)"

	for m in CONFIG_MODULES CONFIG_MODVERSIONS CONFIG_USB_CONFIGFS_F_HID CONFIG_USB_F_HID CONFIG_CFG80211 CONFIG_MAC80211; do
		grep -q "^${m}=y" "$OUT_DIR/.config" || warn "$m is not =y (should be, from the ROM config)"
	done

	if [ "$PATH_B_MODE" = "1" ]; then
		# every symbol Path B / docs parity touches is expected to differ from
		# the main fragment's "is not set" lines - do not report those dropped.
		validate_fragment "$NH_FRAGMENT" "$PATHB_FRAGMENT $DOCS_FRAGMENT"
		validate_fragment "$PATHB_FRAGMENT" "$DOCS_FRAGMENT"
		validate_fragment "$DOCS_FRAGMENT"
	else
		validate_fragment "$NH_FRAGMENT"
	fi

	# include/config/auto.conf mirrors .config and is *sourced* by
	# scripts/setlocalversion. Refreshing it explicitly matters: a stale copy
	# (e.g. still carrying the base defconfig's CONFIG_LOCALVERSION_AUTO=y and
	# CONFIG_LOCALVERSION="-moto") makes setlocalversion take its long scm path
	# and append "-g<sha>"/"-dirty" to the release string, which changes the
	# module vermagic and stops the ROM's prebuilt vendor modules from loading.
	make O="$OUT_DIR" "${TOOLCHAIN_ARGS[@]}" syncconfig >/dev/null 2>&1 \
		|| warn "syncconfig failed - the build refreshes auto.conf itself"

	# Fail fast: the release string is compiled into the kernel and into every
	# module, so verify it here rather than after a long build.
	local rel
	rel="$(make -s O="$OUT_DIR" "${TOOLCHAIN_ARGS[@]}" kernelrelease 2>/dev/null | tail -n1)"
	if [ -n "$rel" ]; then
		log "resulting release string: $rel"
		if [ -n "$STOCK_RELEASE" ] && [ "$rel" != "$STOCK_RELEASE" ]; then
			warn "release string '$rel' does not match the ROM's '$STOCK_RELEASE'."
			warn "Without an exact match the ROM's prebuilt vendor modules (Wi-Fi,"
			warn "touch, charger) in vendor_boot refuse to load."
			warn "Common causes: a stale include/config/auto.conf, or LOCALVERSION"
			warn "not set (scripts/setlocalversion then appends '+' / '-dirty')."
			[ "${FORCE:-0}" = "1" ] || die "fix the release string before building (FORCE=1 to override)"
		else
			[ -n "$STOCK_RELEASE" ] && ok "release string matches the ROM exactly"
		fi
	else
		log "resulting release string: $(grep '^CONFIG_LOCALVERSION=' "$OUT_DIR/.config" || echo '(unset)')"
	fi
	ok "config ready: $OUT_DIR/.config   (merge log: output/merge_config.log)"
}

# =============================================================================
# build
# =============================================================================
# ------------------------------------------------------------------- patches
# Optional injection patch for the built-in Wi-Fi (PATCH_INJECT=1).
# Two patches, applied in order:
#   upstream-...patch  Kali NetHunter's qcacld-3.0 monitor/injection feature patch
#   porting.patch      the 3 lines it needs to compile on THIS Motorola tree
# Idempotent: re-running build with PATCH_INJECT=1 does not re-apply anything.
apply_inject_patches() {
	local marker="$KERNEL_DIR/drivers/staging/qcacld-3.0/core/hdd/inc/wlan_hdd_frame_inject.h"

	# Guard, and it has to run BEFORE the early return below: the injection patch is
	# a change to the kernel SOURCE TREE, so PATCH_INJECT describes the tree, not
	# just this run. Building with PATCH_INJECT=0 on a tree that is still patched
	# (from an earlier PATCH_INJECT=1 build) silently produces a patched wlan.ko
	# under an "unpatched" name - and then the rollback copy rolls nothing back.
	if [ "$PATCH_INJECT_MODE" != "1" ] && [ -f "$marker" ]; then
		if [ "${NH_KEEP_INJECT:-0}" = "1" ]; then
			warn "kernel tree still contains the injection patch - building what is on disk (NH_KEEP_INJECT=1)"
			return 0
		fi
		err "the kernel tree still contains the injection patch, but PATCH_INJECT=0."
		err "Refusing to build: the payload would be called 'unpatched' while wlan.ko is patched,"
		err "so a rollback image built this way could not roll anything back."
		err "Revert the two staging trees (only those two directories are touched):"
		err "  git -C \"$KERNEL_DIR\" reset -q"
		err "  git -C \"$KERNEL_DIR\" checkout -- ."
		err "  git -C \"$KERNEL_DIR\" clean -fdq drivers/staging/qcacld-3.0 drivers/staging/qca-wifi-host-cmn"
		err "or re-run with PATCH_INJECT=1, or NH_KEEP_INJECT=1 to build the tree as it is."
		exit 1
	fi

	[ "$PATCH_INJECT_MODE" = "1" ] || return 0

	[ "$PATH_B_MODE" = "1" ] || die "PATCH_INJECT=1 requires PATH_B=1 - the patched wlan.ko must be shipped in the vendor_boot ramdisk"

	if [ -f "$marker" ]; then
		log "injection patch: already applied to the kernel source"
	else
		[ -f "$INJECT_UPSTREAM" ] || die "PATCH_INJECT=1 but $INJECT_UPSTREAM is missing"
		log "injection patch: applying $(basename "$INJECT_UPSTREAM")"
		if git -C "$KERNEL_DIR" apply -p1 "$INJECT_UPSTREAM" 2>/dev/null; then
			ok "upstream injection patch applied (45 files, 12 new sources)"
		else
			warn "git apply failed (not a git checkout?) - falling back to patch(1)"
			(cd "$KERNEL_DIR" && patch -p1 -N --forward <"$INJECT_UPSTREAM" >/dev/null) \
				|| die "could not apply the upstream injection patch"
			ok "upstream injection patch applied with patch(1)"
		fi
	fi

	if [ -f "$INJECT_PORTING" ]; then
		if git -C "$KERNEL_DIR" apply -R --check -p1 "$INJECT_PORTING" 2>/dev/null; then
			log "injection patch: porting fixes already applied"
		elif git -C "$KERNEL_DIR" apply -p1 "$INJECT_PORTING" 2>/dev/null; then
			ok "porting fixes applied (3 lines: enum type + declaration placement)"
		else
			warn "porting patch did not apply - if the build then fails, see patches/inject/README.md"
		fi
	fi

	# Safety: the patch must never touch the release string or exported symbols.
	warn "PATCH_INJECT=1: the built-in Wi-Fi driver is patched - it is NOT tested"
	warn "live yet (firmware must accept TX in monitor mode). To go back to an"
	warn "unpatched wlan.ko, revert the tree first - a plain rebuild refuses to run"
	warn "while the patch is still in the source (see the message it prints), e.g.:"
	warn "  git -C \"$KERNEL_DIR\" reset -q; git -C \"$KERNEL_DIR\" checkout -- ."
	warn "  git -C \"$KERNEL_DIR\" clean -fdq drivers/staging/qcacld-3.0 drivers/staging/qca-wifi-host-cmn"
	warn "See patches/inject/README.md."
}

do_build() {
	[ -f "$OUT_DIR/.config" ] || die "no .config - run: $0 config"
	[ -x "$CLANG_DIR/bin/clang" ] || die "clang missing - run: $0 toolchains"
	fix_host_tools
	apply_inject_patches

	cd "$KERNEL_DIR"
	export PATH="$CLANG_DIR/bin:$PATH"
	export ARCH="$ARCH" SUBARCH="$ARCH"

	# same toolchain arguments as the config step (see TOOLCHAIN_ARGS)
	local make_args=("O=$OUT_DIR" "${TOOLCHAIN_ARGS[@]}")

	log "compiling with $JOBS jobs (LTO + CFI on: expect 30-90 minutes)"
	make -j"$JOBS" "${make_args[@]}" "$KERNEL_IMAGE_NAME" 2>&1 | tee "$OUTPUT_DIR/build.log"

	[ -f "$OUT_DIR/arch/arm64/boot/$KERNEL_IMAGE_NAME" ] || die "build failed - see output/build.log"
	ok "kernel image: $OUT_DIR/arch/arm64/boot/$KERNEL_IMAGE_NAME"

	# Module.symvers is what the CRC verification needs; it only exists once
	# modules have been built. In Path A the modules are NOT shipped (the ROM's
	# own modules in vendor_boot stay in use) - they only provide the
	# exported-symbol table to verify against. BUILD_MODULES=0 skips this.
	# In Path B they ARE the product: the kernel's CRCs changed, so every module
	# must come from this build and is delivered via the vendor_boot ramdisk.
	if [ "$PATH_B_MODE" = "1" ] || { [ ! -f "$OUT_DIR/Module.symvers" ] && [ "${BUILD_MODULES:-1}" = "1" ]; }; then
		if [ "$PATH_B_MODE" = "1" ]; then
			log "building all modules (PATH B: these are shipped, not just for Module.symvers)"
		else
			log "building modules (for Module.symvers / CRC verification only)"
		fi
		make -j"$JOBS" "${make_args[@]}" modules 2>&1 | tee -a "$OUTPUT_DIR/build.log"
	fi
	if [ -f "$OUT_DIR/Module.symvers" ]; then
		ok "Module.symvers: $(wc -l < "$OUT_DIR/Module.symvers") exported symbols"
		[ "$PATH_B_MODE" = "1" ] || log "next: $0 verify"
	else
		warn "no Module.symvers produced - CRC verification not possible"
	fi

	if [ "$PATH_B_MODE" = "1" ]; then
		do_modules_stage
	fi

	local rel_file="$OUT_DIR/include/config/kernel.release"
	if [ -f "$rel_file" ]; then
		local rel; rel="$(cat "$rel_file")"
		ok "kernel release: $rel"
		if [ -n "$STOCK_RELEASE" ] && [ "$rel" != "$STOCK_RELEASE" ]; then
			warn "release mismatch: built '$rel' but the ROM runs '$STOCK_RELEASE'."
			warn "Flashed like this, the ROM's vendor modules (vendor_boot) will NOT load."
			if [ "$rel" = "${STOCK_RELEASE}+" ]; then
				warn "The trailing '+' comes from scripts/setlocalversion appending"
				warn "it because LOCALVERSION is unset and HEAD is not an exact tag."
				warn "LOCALVERSION= is part of TOOLCHAIN_ARGS - do not remove it."
			else
				warn "Fix CONFIG_LOCALVERSION (see config/nethunter_milanf.fragment section 1)."
			fi
			[ "${FORCE:-0}" = "1" ] || die "refusing to package a mismatching kernel (set FORCE=1 to override)"
		fi
	fi
}

# =============================================================================
# flashable zip (official AnyKernel3 + NetHunter additions)
# =============================================================================
do_zip() {
	local image="$OUT_DIR/arch/arm64/boot/$KERNEL_IMAGE_NAME"
	[ -f "$image" ] || die "kernel image not built - run: $0 build"
	[ -f "$AK3_DIR/tools/ak3-core.sh" ] || die "AnyKernel3 missing - run: $0 source"

	rm -rf "$OUTPUT_DIR/ak3"
	mkdir -p "$OUTPUT_DIR/ak3"
	cp -a "$AK3_DIR/." "$OUTPUT_DIR/ak3/"

	# remove AK3 example artefacts so only our kernel is picked up
	rm -f "$OUTPUT_DIR/ak3"/Image "$OUTPUT_DIR/ak3"/Image.gz "$OUTPUT_DIR/ak3"/Image.gz-dtb \
	      "$OUTPUT_DIR/ak3"/Image.lz4 "$OUTPUT_DIR/ak3"/zImage "$OUTPUT_DIR/ak3"/zImage-dtb \
	      "$OUTPUT_DIR/ak3"/kernel "$OUTPUT_DIR/ak3"/dtb "$OUTPUT_DIR/ak3"/dtbo.img

	cp -f "$ANYKERNEL_SRC/anykernel.sh" "$OUTPUT_DIR/ak3/anykernel.sh"
	cp -f "$image" "$OUTPUT_DIR/ak3/$KERNEL_IMAGE_NAME"
	cp -a "$ANYKERNEL_SRC/ramdisk-patch" "$OUTPUT_DIR/ak3/" 2>/dev/null || true
	cp -a "$ANYKERNEL_SRC/ak_patches"    "$OUTPUT_DIR/ak3/" 2>/dev/null || true

	rm -f "$OUTPUT_DIR/$ZIP_NAME"
	( cd "$OUTPUT_DIR/ak3" && zip -r9 "$OUTPUT_DIR/$ZIP_NAME" . -x '*.git*' -x '.gitignore' >/dev/null )
	ok "flashable zip: $OUTPUT_DIR/$ZIP_NAME  ($(du -h "$OUTPUT_DIR/$ZIP_NAME" | cut -f1))"
	log "flash it with TWRP (Install -> zip) or: adb sideload / push + flash"
}

# =============================================================================
# Path B: build the module set + the vendor_boot payload that delivers it
# =============================================================================
release_string() {
	[ -f "$OUT_DIR/include/config/kernel.release" ] || die "kernel.release missing - run: $0 build"
	cat "$OUT_DIR/include/config/kernel.release"
}

# Modules are installed stripped, then flattened: the vendor ramdisk keeps a
# flat lib/modules/*.ko (that is what the ROM's own ramdisk looks like), while
# modules_install writes a nested kernel/<subdir>/ layout.
do_modules_stage() {
	local rel; rel="$(release_string)"
	[ -n "$rel" ] || die "empty kernel release"

	log "installing modules (stripped) for release '$rel'"
	rm -rf "$MODULES_STAGE" "$MODULES_FLAT_ROOT"
	mkdir -p "$MODULES_FLAT_ROOT/lib/modules/$rel"
	make -j"$JOBS" "O=$OUT_DIR" "${TOOLCHAIN_ARGS[@]}" \
		INSTALL_MOD_PATH="$MODULES_STAGE" INSTALL_MOD_STRIP=1 modules_install \
		>&2 | tail -n 3

	find "$MODULES_STAGE/lib/modules/$rel" -name '*.ko' \
		-exec cp -f {} "$MODULES_FLAT_ROOT/lib/modules/$rel/" \;
	local flat="$MODULES_FLAT_ROOT/lib/modules/$rel" n
	n="$(ls -1 "$flat"/*.ko 2>/dev/null | wc -l)"
	[ "$n" -gt 0 ] || die "no .ko files were installed - did 'make modules' fail? see output/build.log"

	depmod -b "$MODULES_FLAT_ROOT" "$rel" 2>"$OUTPUT_DIR/depmod.log" \
		|| warn "depmod reported problems - see output/depmod.log"
	ok "$n modules staged (flat, stripped) in $flat ($(du -sk "$flat" | cut -f1) KiB)"

	# Coverage check: every module the ROM loads by name must exist in our set,
	# otherwise that module would simply never load again.
	if [ -f "$OUTPUT_DIR/rom-modules/modules.load" ]; then
		local missing
		missing="$(comm -23 \
			<(sed 's/#.*//' "$OUTPUT_DIR/rom-modules/modules.load" | tr -d ' \r' | grep -v '^$' | sort -u) \
			<(cd "$flat" && ls -1 *.ko | sed 's/\.ko$//' | sort -u) | tr '\n' ' ')"
		if [ -n "$missing" ]; then
			warn "the ROM loads these modules but this build does not produce them:"
			warn "  $missing"
			warn "those features will be missing in Path B - check the source tree."
		else
			ok "coverage: every module the ROM loads is built here"
		fi
	fi
}

# Take the stock vendor_boot, replace its first-stage module set with ours, and
# write a flashable image. Preserves the header/cmdline/dtb/bootconfig and the
# ramdisk's own container format (lz4 legacy on this device).
do_payload() {
	local rel; rel="$(release_string)"
	local flat="$MODULES_FLAT_ROOT/lib/modules/$rel"
	local tool="$PROJECT_DIR/tools/vendor-boot.py"

	[ -d "$flat" ] || die "no staged modules - run: PATH_B=1 $0 build"
	[ -f "$tool" ] || die "missing $tool"
	[ -f "$VENDOR_BOOT_STOCK" ] || die "missing stock image $VENDOR_BOOT_STOCK
  (dump it with: adb shell su -c 'dd if=/dev/block/bootdevice/by-name/vendor_boot_a of=/sdcard/vendor_boot.img')"

	rm -rf "$VENDOR_BOOT_WORK"; mkdir -p "$VENDOR_BOOT_WORK"
	log "unpacking $VENDOR_BOOT_STOCK"
	python3 "$tool" unpack "$VENDOR_BOOT_STOCK" "$VENDOR_BOOT_WORK" >/dev/null

	local fmt
	fmt="$(python3 -c "import json;print(json.load(open('$VENDOR_BOOT_WORK/header.json'))['ramdisk_format'])")"
	log "ramdisk container format: $fmt"
	case "$fmt" in
		lz4-legacy) lz4 -d -l -f "$VENDOR_BOOT_WORK/ramdisk.raw" "$VENDOR_BOOT_WORK/ramdisk.cpio" >/dev/null 2>&1 ;;
		lz4)        lz4 -d    -f "$VENDOR_BOOT_WORK/ramdisk.raw" "$VENDOR_BOOT_WORK/ramdisk.cpio" >/dev/null 2>&1 ;;
		gzip)       zcat "$VENDOR_BOOT_WORK/ramdisk.raw" > "$VENDOR_BOOT_WORK/ramdisk.cpio" ;;
		cpio)       cp -f "$VENDOR_BOOT_WORK/ramdisk.raw" "$VENDOR_BOOT_WORK/ramdisk.cpio" ;;
		*) die "unsupported ramdisk format: $fmt" ;;
	esac

	mkdir -p "$VENDOR_BOOT_WORK/rootfs"
	( cd "$VENDOR_BOOT_WORK/rootfs" && cpio -idm --no-absolute-filenames --quiet < "$VENDOR_BOOT_WORK/ramdisk.cpio" )
	ok "extracted $(find "$VENDOR_BOOT_WORK/rootfs" | wc -l) ramdisk entries"

	# swap the ROM's first-stage modules for ours
	local target="$VENDOR_BOOT_WORK/rootfs/lib/modules"
	mkdir -p "$target"
	rm -f "$target"/*.ko
	cp -f "$flat"/*.ko "$target/"
	local m
	for m in modules.dep modules.alias modules.softdep modules.order; do
		[ -f "$flat/$m" ] && cp -f "$flat/$m" "$target/$m"
	done

	# modules.load is what first-stage init loads. The ROM ships it EMPTY (its
	# modules live on /vendor and are loaded by second-stage init), so it has to be
	# filled in or nothing gets loaded - but it must list what the ROM lists, in the
	# ROM's order. Both matter, and both were measured on this device:
	#
	#   1. SET - the ROM's list deliberately omits modules it only needs in recovery
	#      (mmi_discrete_turbo_charger, bq2597x_mmi_iio, lzo*, zram). Loading the
	#      charger ones in a normal boot changes how the USB-C port is classified:
	#      the charger then reports usb_type=Unknown and pc_port stays offline, so
	#      the phone charges but never enumerates (no file-transfer popup, no adb).
	#   2. ORDER - the charger/Type-C/PD hand-off depends on probe order; the ROM
	#      loads qpnp_adaptive_charge -> tcpc_class -> tcpc_* -> rt_pd_manager ->
	#      sgm4154x_charger -> bq2589x_charger -> mmi_charger (last). An alphabetical
	#      list loads mmi_charger first and breaks that hand-off.
	if [ -f "$OUTPUT_DIR/rom-modules/modules.load" ]; then
		grep -vE '^[[:space:]]*(#|$)' "$OUTPUT_DIR/rom-modules/modules.load" | tr -d ' \r' \
			> "$target/modules.load"
		ok "modules.load taken from the ROM's own list ($(wc -l < "$target/modules.load") modules, ROM order)"
	else
		( cd "$flat" && ls -1 *.ko | sed 's/\.ko$//' | LC_ALL=C sort ) > "$target/modules.load"
		warn "no output/rom-modules/modules.load - using an alphabetical list instead"
		warn "that changes charger/Type-C probe order. Pull the ROM's list first:"
		warn "  adb pull /vendor/lib/modules/modules.load output/rom-modules/modules.load"
	fi

	# modules.load.recovery is left exactly as the ROM ships it (the charger/PD
	# modules recovery needs, because recovery does not mount /vendor); only the
	# .ko files behind those names are ours.
	if [ -f "$target/modules.load.recovery" ]; then
		ok "modules.load.recovery kept from the stock image ($(wc -l < "$target/modules.load.recovery") modules)"
	fi

	# every listed name must resolve to one of our .ko files (kernel module names
	# normalise '-' to '_', and the recovery list carries a ".ko" suffix)
	local missing
	missing="$(comm -23 \
		<({ cat "$target/modules.load"; cat "$target/modules.load.recovery" 2>/dev/null; } \
			| tr -d ' \r' | grep -v '^$' | sed 's/\.ko$//' | tr '-' '_' | sort -u) \
		<(cd "$flat" && ls -1 *.ko | sed 's/\.ko$//' | tr '-' '_' | sort -u) | tr '\n' ' ')"
	[ -n "$missing" ] && warn "listed in a load file but not built here: $missing"

	( cd "$VENDOR_BOOT_WORK/rootfs" && find . -print | LC_ALL=C sort \
		| cpio -o -H newc --owner=0:0 --reproducible --quiet ) > "$VENDOR_BOOT_WORK/ramdisk.cpio"
	case "$fmt" in
		lz4-legacy) lz4 -l -12 -f "$VENDOR_BOOT_WORK/ramdisk.cpio" "$VENDOR_BOOT_WORK/ramdisk.new" >/dev/null 2>&1 ;;
		lz4)        lz4    -12 -f "$VENDOR_BOOT_WORK/ramdisk.cpio" "$VENDOR_BOOT_WORK/ramdisk.new" >/dev/null 2>&1 ;;
		gzip)       gzip -9 -n -c "$VENDOR_BOOT_WORK/ramdisk.cpio" > "$VENDOR_BOOT_WORK/ramdisk.new" ;;
		cpio)       cp -f "$VENDOR_BOOT_WORK/ramdisk.cpio" "$VENDOR_BOOT_WORK/ramdisk.new" ;;
	esac
	[ -s "$VENDOR_BOOT_WORK/ramdisk.new" ] || die "repacked ramdisk is empty - check lz4/gzip output"

	python3 "$tool" pack "$VENDOR_BOOT_WORK" "$VENDOR_BOOT_PATHB"
	ok "Path B vendor_boot: $VENDOR_BOOT_PATHB"
	log "flash: fastboot flash vendor_boot_a $(basename "$VENDOR_BOOT_PATHB")"
}

# =============================================================================
# verify: can the ROM's prebuilt modules still load in this kernel?
# =============================================================================
do_verify() {
	[ -f "$OUT_DIR/Module.symvers" ] || die "no Module.symvers - run: $0 build"
	exec "$PROJECT_DIR/tools/verify-module-crc.sh" "$OUT_DIR/Module.symvers" "$OUTPUT_DIR/rom-modules"
}

# =============================================================================
# doctor / clean
# =============================================================================
doctor() {
	detect_stock_release
	echo "device          : $DEVICE_MODEL ($DEVICE_CODENAME, $SOC / $PLATFORM)"
	echo "kernel source   : $KERNEL_REPO ($KERNEL_BRANCH)"
	echo "base defconfig  : $BASE_DEFCONFIG"
	local f; for f in "${ROM_FRAGMENTS[@]}"; do echo "rom fragment    : $f"; done
	echo "nethunter frag  : $NH_FRAGMENT_REL"
	echo "clang           : $CLANG_PREBUILT -> $CLANG_DIR"
	echo "kernel commit   : ${KERNEL_COMMIT:-<branch tip>} (ROM build: ${DEFAULT_STOCK_RELEASE##*-g})"
	echo "stock release   : ${STOCK_RELEASE:-$DEFAULT_STOCK_RELEASE (recorded 2026-09-19)}"
	echo "jobs            : $JOBS"
	echo -n "kernel source   : "; [ -d "$KERNEL_DIR/.git" ] && echo present || echo "not cloned"
	echo -n "clang           : "; [ -x "$CLANG_DIR/bin/clang" ] && echo present || echo missing
	echo -n "anykernel3      : "; [ -d "$AK3_DIR/.git" ] && echo present || echo "not cloned"
	echo "host tools      : $( [ -z "$(missing_deps)" ] && echo "all present" || echo "missing:$(missing_deps)" )"
}

do_clean() {
	rm -rf "$OUT_DIR" "$OUTPUT_DIR/ak3" "$OUTPUT_DIR/$ZIP_NAME"
	ok "cleaned build output (kernel source, toolchains and anykernel3 kept)"
}

# =============================================================================
# main
# =============================================================================
main() {
	case "${1:-all}" in
		doctor)     doctor ;;
		toolchains) check_deps; fetch_toolchains ;;
		source)     check_deps; fetch_source ;;
		config)     check_deps; detect_stock_release; do_config ;;
		build)      check_deps; detect_stock_release; do_build ;;
		modules)    check_deps; do_modules_stage ;;
		payload)    check_deps; do_payload ;;
		verify)     do_verify ;;
		zip)        do_zip ;;
		clean)      do_clean ;;
		all)        check_deps; fetch_toolchains; fetch_source; detect_stock_release; do_config; do_build; do_verify; do_zip ;;
		*)          sed -n '2,30p' "$0"; exit 1 ;;
	esac
}

mkdir -p "$OUTPUT_DIR"
main "$@"
