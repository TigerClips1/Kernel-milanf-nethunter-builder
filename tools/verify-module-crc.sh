#!/usr/bin/env bash
# =============================================================================
# verify-module-crc.sh - prove the built kernel can load the ROM's modules
# =============================================================================
# The ROM ships prebuilt kernel modules in vendor_boot.img (extracted at runtime
# to /vendor/lib/modules). Because CONFIG_MODVERSIONS=y, the kernel accepts a
# module only if the CRC of EVERY symbol it imports matches the kernel's
# Module.symvers - otherwise you get "disagrees about version of symbol X" and
# the module (Wi-Fi, charger, ...) silently fails to load.
#
# vermagic matching is not enough: a config option that changes a struct layout
# in a shared header changes CRCs while leaving the version string identical.
# This script catches that BEFORE you flash.
#
# Usage:
#   tools/verify-module-crc.sh [Module.symvers] [rom-modules-dir]
#
# Defaults:
#   kernel/out/Module.symvers     (produced by ./build-nethunter-kernel.sh build)
#   output/rom-modules/           (pulled from the device over adb if empty)
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYMVERS="${1:-$PROJECT_DIR/kernel/out/Module.symvers}"
MODDIR="${2:-$PROJECT_DIR/output/rom-modules}"

# Modules to check. The whole directory is used; if it is empty the modules are
# pulled from the device (all of them - 77 .ko files on the stock build, which
# together import ~1800 unique kernel symbols).
MODULES_LOAD="/vendor/lib/modules"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }

[ -f "$SYMVERS" ] || { red "Module.symvers not found: $SYMVERS"; echo "  build the kernel first: ./build-nethunter-kernel.sh build"; exit 2; }
command -v modprobe >/dev/null 2>&1 || { red "modprobe not found (install kmod)"; exit 2; }

# ---------------------------------------------------------------- fetch modules
mkdir -p "$MODDIR"
if [ -z "$(find "$MODDIR" -maxdepth 1 -name '*.ko' -print -quit)" ]; then
	yellow "no modules in $MODDIR - pulling the whole $MODULES_LOAD from the device"
	command -v adb >/dev/null 2>&1 || { red "adb not available and no local modules"; exit 2; }
	adb pull "$MODULES_LOAD/." "$MODDIR/" >/dev/null 2>&1 || true
	echo "  pulled $(find "$MODDIR" -maxdepth 1 -name '*.ko' | wc -l) modules"
fi

mapfile -t kos < <(find "$MODDIR" -maxdepth 1 -name '*.ko' | sort)
[ "${#kos[@]}" -gt 0 ] || { red "no .ko files to check in $MODDIR"; exit 2; }

echo "kernel symvers : $SYMVERS ($(wc -l < "$SYMVERS") symbols)"
echo "modules        : ${#kos[@]} from $MODDIR"

# Symbols exported by the ROM's modules themselves (__ksymtab_<sym>) are
# resolved module-to-module at load time, not by the kernel - do not report
# those as "missing from the kernel".
MODULE_EXPORTS="$(mktemp)"
for ko in "${kos[@]}"; do
	nm "$ko" 2>/dev/null | awk '/__ksymtab_/{sub(/^.*__ksymtab_/, ""); print}'
done | sort -u > "$MODULE_EXPORTS"
trap 'rm -f "$MODULE_EXPORTS"' EXIT
echo "module exports : $(wc -l < "$MODULE_EXPORTS") symbols provided by other ROM modules"
echo

# ------------------------------------------------------------------- compare
# Module.symvers: <crc>\t<symbol>\t<module>\t<export>
# modprobe --dump-modversions: <crc>  <symbol>
failed=0
for ko in "${kos[@]}"; do
	name="$(basename "$ko")"
	total=0; bad=0; missing=0; modsupplied=0
	while read -r crc sym; do
		total=$((total + 1))
		kernel_crc="$(awk -v s="$sym" '$2 == s { print $1; exit }' "$SYMVERS")"
		if [ -z "$kernel_crc" ]; then
			if grep -qx "$sym" "$MODULE_EXPORTS"; then
				modsupplied=$((modsupplied + 1))
			else
				missing=$((missing + 1))
				[ "$missing" -le 5 ] && echo "  MISSING  $name: $sym"
			fi
		elif [ "$kernel_crc" != "$crc" ]; then
			bad=$((bad + 1))
			[ "$bad" -le 10 ] && echo "  MISMATCH $name: $sym expected=$crc kernel=$kernel_crc"
		fi
	done < <(modprobe --dump-modversions "$ko" | awk '{print $1" "$2}')

	if [ "$bad" -eq 0 ] && [ "$missing" -eq 0 ]; then
		green "OK       $name: $total imported symbols match ($modsupplied from other modules)"
	else
		failed=1
		red "FAIL     $name: $bad CRC mismatch(es), $missing symbol(s) not exported by the kernel (of $total)"
	fi
done

echo
if [ "$failed" -eq 0 ]; then
	green "All checked modules can be loaded by this kernel."
	echo "Remaining requirement: the release string must still match too"
	echo "(compare 'uname -r' with the release the modules were built for)."
	exit 0
fi

red "At least one module would be rejected by this kernel."
cat <<'EOF'
How to fix a CRC mismatch:
  * find the config option responsible - usually one that changes a struct in a
    shared header (classic examples on this device: CONFIG_CFG80211_WEXT changes
    struct wiphy, CONFIG_USB_MON adds members to struct usb_bus,
    CONFIG_MESH/WDS change other layouts)
  * disable it in config/nethunter_milanf.fragment and rebuild, or
  * accept it and rebuild + flash ALL modules (including vendor_boot.img), which
    AnyKernel3 cannot do for you
"symbol not exported by the kernel" means the module needs a symbol the kernel
config does not provide - enable the corresponding subsystem/module.
EOF
exit 1
