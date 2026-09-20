#!/system/bin/sh
# =============================================================================
#  inject-selftest.sh - verify the PATCH_INJECT=1 built-in Wi-Fi injection
#
#  Run it on the phone as root (device-side script):
#
#    adb push tools/inject-selftest.sh tools/inject-ioctl.py /data/local/tmp/
#    adb shell 'su -c "sh /data/local/tmp/inject-selftest.sh"'
#    adb shell 'su -c "cat /data/local/tmp/inject-selftest.log"'
#
#  Requires a PATCH_INJECT=1 + PATH_B=1 build (patched wlan.ko in vendor_boot)
#  flashed on the LineageOS build this targets,
#  `lineage-23.2-20260917-nightly-milanf-signed.zip` - that nightly is required,
#  because the patched module must match that kernel's symbol CRCs.
#
#  This is the test that actually works on this driver, verified 2026-09-19. It
#  never touches Wi-Fi state - no `svc wifi disable` (on Path B that unloads the
#  driver, the reload picks the ROM's /vendor/lib/modules/wlan.ko and fails with
#  "disagrees about version of symbol module_layout", and Wi-Fi is gone until the
#  next reboot).
#
#  What it checks:
#    0. the running driver really is the patched one (/proc/kallsyms)
#    1. the patch's sysfs controls exist and injection is enabled
#    2. hands a raw frame to the firmware through the patch's private IOCTL
#       SIOCDEVPRIVATE+10, via tools/inject-ioctl.py (a probe request by default;
#       `--beacon` adds a beacon, which is expected to drop the Wi-Fi link)
#    3. reads the driver's own log back out of /dev/kmsg - the proof is the
#       wma_send_injection_frame_to_fw() line carrying our frame
#
#  TRAFFIC: one broadcast PROBE REQUEST (what an AP scan already sends). No
#  association, no deauth, nothing aimed at any network.
#
#  SAFETY NOTE, measured on this device 2026-09-19: a probe request is harmless -
#  the association survived it (verified twice). A *beacon* is not: injected from
#  the associated STA interface the link went down ~20 s later and Android's
#  supplicant never recovered (wpa_cli times out, only a reboot brings Wi-Fi back).
#  That is why this script injects a probe only; `--beacon` adds the beacon case
#  for when you want to see it happen, and you should expect to reboot after.
# =============================================================================

LOG=/data/local/tmp/inject-selftest.log
KMSG=/data/local/tmp/kmsg-inject.log
SYSFS=/sys/kernel/frame_injection
CHROOT=/data/local/nhsystem/kali-arm64
IF=wlan0

: >"$LOG"
exec >>"$LOG" 2>&1

echo "=== injection self-test $(date) ==="
echo "release: $(uname -r)"
VERDICT=UNKNOWN

# probe only by default - see the safety note above
FRAMES="probe"
EXPECT=1
if [ "$1" = "--beacon" ]; then
	FRAMES="probe beacon"
	EXPECT=2
	echo "NOTE: --beacon was given; expect the Wi-Fi link to drop and need a reboot"
fi

# ---- 0. patched driver? -----------------------------------------------------
SYMS=$(grep -cE 'hdd_.*frame_inject' /proc/kallsyms 2>/dev/null)
echo
echo "--- 0. driver"
echo "injection symbols in the running kernel: $SYMS (expect 9)"
if [ "$SYMS" -eq 0 ]; then
	echo "VERDICT: UNPATCHED - vendor_boot does not carry the patched wlan.ko"
	echo "=== end $(date) ==="
	exit 1
fi
echo "VERDICT: patched driver is running"
grep -E 'hdd_(frame_inject|init_frame_injection)' /proc/kallsyms | head -9 | sed 's/^/    /'

# ---- 1. sysfs controls ------------------------------------------------------
echo
echo "--- 1. /sys/kernel/frame_injection (the patch's control surface)"
if [ -d "$SYSFS" ]; then
	for f in "$SYSFS"/*; do
		echo "    $(basename "$f") = $(cat "$f" 2>/dev/null)"
	done
	[ "$(cat $SYSFS/global_enable 2>/dev/null)" = "1" ] || echo "    (global_enable is not 1 - injection is off)"
else
	echo "    MISSING - is this really the PATCH_INJECT build?"
fi

# ---- 2. inject --------------------------------------------------------------
echo
echo "--- 2. handing frames to the driver (private IOCTL)"
echo 5 >"$SYSFS/debug_level" 2>/dev/null
rm -f "$KMSG"
timeout 90 cat /dev/kmsg >"$KMSG" 2>/dev/null &
sleep 2
# /dev/kmsg replays what is already in the ring buffer, so count a baseline and
# report only this run's frames
BEFORE=$(grep -c "wma_send_injection_frame_to_fw" "$KMSG" 2>/dev/null)
BEFORE_OK=$(grep -c "Frame injection IOCTL completed successfully" "$KMSG" 2>/dev/null)
if [ ! -x "$CHROOT/usr/bin/python3" ]; then
	echo "    no python3 in $CHROOT - cannot run the client"
else
	cp -f /data/local/tmp/inject-ioctl.py "$CHROOT/tmp/" 2>/dev/null
		for kind in $FRAMES; do
		echo "  -- $kind:"
		timeout 30 chroot "$CHROOT" /usr/bin/python3 /tmp/inject-ioctl.py "$IF" "$kind" 2>&1 | sed 's/^/    /'
		sleep 1
	done
fi
sleep 3

# ---- 3. driver-side proof ---------------------------------------------------
echo
echo "--- 3. what the driver did (from /dev/kmsg)"
grep -iE "frame injection ioctl|injection frame\[|completed successfully" "$KMSG" 2>/dev/null | tail -20 | sed 's/^/    /'
SUBMITTED=$(( $(grep -c "wma_send_injection_frame_to_fw" "$KMSG" 2>/dev/null) - ${BEFORE:-0} ))
echo "    frames handed to the firmware: $SUBMITTED (expect $EXPECT)"
OKCALLS=$(( $(grep -c "Frame injection IOCTL completed successfully" "$KMSG" 2>/dev/null) - ${BEFORE_OK:-0} ))
echo "    IOCTLs reported successful:    $OKCALLS"

if [ "$SUBMITTED" -ge "$EXPECT" ] && [ "$OKCALLS" -ge "$EXPECT" ]; then
	VERDICT="PASS - injection reaches the firmware (frames: $SUBMITTED)"
else
	VERDICT="INCONCLUSIVE - see the errors above (frames: $SUBMITTED, ok: $OKCALLS)"
fi

# ---- 4. restore -------------------------------------------------------------
echo
echo "--- 4. restore"
echo 3 >"$SYSFS/debug_level" 2>/dev/null
echo "    debug_level back to $(cat $SYSFS/debug_level 2>/dev/null)"
echo "    $IF is untouched: $(ip -br addr show $IF 2>/dev/null | head -1)"
echo
echo "VERDICT: $VERDICT"
echo "=== end $(date) ==="
