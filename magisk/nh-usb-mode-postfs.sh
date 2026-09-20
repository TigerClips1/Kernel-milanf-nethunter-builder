#!/system/bin/sh
# NetHunter Path B - USB device-mode fix for milanf (one-shot half)
#
# On this device the vendor USB role handshake never asserts USB on the extcons
# (extcon0 = 1628000.qcom,msm-eud, extcon3 = soc:rt-pd-manager both report USB=0
# even with a host attached, and the charger reports usb_type=Unknown), so
# msm-dwc3 leaves the controller at "mode=none": nothing enumerates, no adb and
# no "USB preferences" notification.
#
# Writing "peripheral" restores USB data immediately (verified: host enumerates
# 18d1:4e11 and adb works, dumpsys usb -> connected=true, CONFIGURED).
#
# Install (both halves, systemless Magisk):
#   adb push magisk/nh-usb-mode-postfs.sh magisk/nh-usb-mode-service.sh /sdcard/
#   adb shell 'su -c "mkdir -p /data/adb/post-fs-data.d /data/adb/service.d
#     cp /sdcard/nh-usb-mode-postfs.sh  /data/adb/post-fs-data.d/nh-usb-mode.sh
#     cp /sdcard/nh-usb-mode-service.sh /data/adb/service.d/nh-usb-mode.sh
#     chmod 0755 /data/adb/post-fs-data.d/nh-usb-mode.sh /data/adb/service.d/nh-usb-mode.sh
#     chcon u:object_r:magisk_file:s0 /data/adb/post-fs-data.d/nh-usb-mode.sh \
#           /data/adb/service.d/nh-usb-mode.sh"'
#
#   The chcon is required: without it the file is labelled adb_data_file and
#   Magisk refuses to run it.
#
# Cost: USB *host* (OTG) mode is not usable while this is installed.
# Remove both halves with:
#   su -c 'rm -f /data/adb/post-fs-data.d/nh-usb-mode.sh /data/adb/service.d/nh-usb-mode.sh'
LOG=/data/local/tmp/nh-usb-mode.log
MODE=/sys/devices/platform/soc/4e00000.ssusb/mode

[ -e "$MODE" ] || exit 0
cur=$(cat "$MODE" 2>/dev/null)
if [ "$cur" != "peripheral" ]; then
    echo peripheral > "$MODE" 2>/dev/null
    echo "$(date) post-fs-data: '$cur' -> peripheral" >> "$LOG"
fi

# Redundancy: spawn a watcher from here as well. The service.d half spawns its
# own, and if either one is killed (OOM, an impatient pkill, ...) the other keeps
# repairing the mode - a dead single watcher is exactly how "USB data never comes
# back after a replug" happens. Duplicate watchers are harmless: they only write
# when the mode is not already "peripheral".
pgrep -f 'nh-usb-mode.*[-]-watch' >/dev/null 2>&1 ||
	setsid "$0" --watch </dev/null >>"$LOG" 2>&1 &
