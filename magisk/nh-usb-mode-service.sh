#!/system/bin/sh
# NetHunter Path B - USB device-mode fix for milanf (service.d half: watchdog)
#
# Why: on this device the vendor USB role handshake never asserts "USB" on the
# extcons (extcon0 = 1628000.qcom,msm-eud and extcon3 = soc:rt-pd-manager both
# report USB=0 with a host attached, charger usb_type=Unknown), so msm-dwc3 stays
# at mode=none - nothing enumerates: no adb, no USB preferences notification.
#
# Writing "peripheral" fixes it instantly (host enumerates 18d1:4e11, adb works,
# `dumpsys usb` -> connected=true / kernel_state=CONFIGURED). msm-dwc3 resets the
# mode whenever the port state changes (e.g. unplug/replug), so this script also
# keeps a tiny watchdog running that re-asserts it.
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
# Cost: USB *host* (OTG) mode is unusable while this is installed. It does
# nothing if the vendor handshake ever works again (it only corrects "not
# peripheral").
#
# Remove with:
#   su -c 'rm -f /data/adb/post-fs-data.d/nh-usb-mode.sh /data/adb/service.d/nh-usb-mode.sh'
MODE=/sys/devices/platform/soc/4e00000.ssusb/mode
LOG=/data/local/tmp/nh-usb-mode.log

[ -e "$MODE" ] || exit 0

# The vendor USB HAL never sees a cable event on this device: the extcon cable
# state stays "USB=0" and those files are read-only (r--r--r--), and so are
# charger/usb_type and pc_port/online. So after an unplug/replug the framework
# still believes nothing is connected and the "Charging this device via USB"
# notification never comes back, even though the controller works again.
# Re-applying the *current* USB function list makes UsbDeviceManager re-evaluate
# its state ("svc usb setFunctions" is the only framework lever that exists -
# "cmd usb" has no shell implementation).
nudge_framework() {
	# Last resort only. Re-applying the USB functions makes UsbDeviceManager
	# re-read the port state, but it also restarts adbd, which drops every adb
	# session (including wireless debugging) for a few seconds - so it is only
	# worth doing when the plain mode fix was not enough.
	local fn
	fn="$(getprop sys.usb.config)"
	[ -n "$fn" ] || return 0
	if dumpsys usb 2>/dev/null | grep -q "connected=true"; then
		echo "$(date) watchdog: framework already sees USB - no nudge needed" >> "$LOG"
		return 0
	fi
	echo "$(date) watchdog: framework does NOT see USB - nudging ('$fn')" >> "$LOG"
	svc usb setFunctions "$fn" >/dev/null 2>&1
	echo "$(date) watchdog: nudge sent (adbd restarts, adb drops for a moment)" >> "$LOG"
}

if [ "$1" = "--watch" ]; then
	echo "$(date) watchdog: started (pid $$)" >> "$LOG"
	while true; do
		cur="$(cat "$MODE" 2>/dev/null)"
		if [ "$cur" != "peripheral" ]; then
			if echo peripheral > "$MODE" 2>/dev/null; then
				echo "$(date) watchdog: '$cur' -> peripheral (cable event)" >> "$LOG"
				sleep 5
				nudge_framework
			fi
		fi
		sleep 3
	done
	exit 0
fi

cur=$(cat "$MODE" 2>/dev/null)
if [ "$cur" != "peripheral" ]; then
    echo peripheral > "$MODE" 2>/dev/null
    echo "$(date) service: '$cur' -> peripheral" >> "$LOG"
fi
setsid "$0" --watch >/dev/null 2>&1 &
echo "$(date) service: watchdog started" >> "$LOG"
exit 0
