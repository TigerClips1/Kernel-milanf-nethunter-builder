# =============================================================================
# ak_patches/nethunter_kernel_features.sh
# =============================================================================
# Sourced by anykernel.sh (step 4) while the AnyKernel zip is being flashed.
#
# Only do things here that are safe at flash time, i.e. that touch mounted
# partitions and nothing else:
#   * do NOT write to /system or /vendor  (Android 16: read-only + AVB)
#   * do NOT try to load modules          (the ROM's modules live in vendor_boot)
#   * do NOT rely on the kernel being booted - it is not
#
# The kernel-side work (HID nodes, init.nethunter.rc import) is done directly
# in anykernel.sh, and the boot-time work is done by init.nethunter.rc.
# =============================================================================

ui_print "- NetHunter: preparing /data/local/nhsystem";

# NetHunter chroot + kernel state directories. /data is mounted in recovery.
if [ -d /data ] && [ ! -d /data/local/nhsystem ]; then
	mkdir -p /data/local/nhsystem/kali-arm64
	mkdir -p /data/local/nhsystem/.krnl
	chown -R 0:0 /data/local/nhsystem
	chmod 0755 /data/local/nhsystem
	ui_print "- Created /data/local/nhsystem";
fi;

# Report what the flasher installed so it is visible in the recovery log.
if [ -f $ramdisk/init.nethunter.rc ]; then
	ui_print "- init.nethunter.rc installed";
else
	ui_print "- WARNING: init.nethunter.rc was not installed";
fi;

if [ -f $ramdisk/ueventd.rc ] && grep -q "/dev/hidg" $ramdisk/ueventd.rc; then
	ui_print "- HID gadget permissions present (/dev/hidg*)";
fi;
