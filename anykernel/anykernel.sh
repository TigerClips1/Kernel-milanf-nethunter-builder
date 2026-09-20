# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers
# NetHunter additions for Moto G Stylus 5G (2022) - milanf / SM6375
#
# This file REPLACES the anykernel.sh that ships with AnyKernel3.
# It must stay compatible with the official AK3 core (tools/ak3-core.sh),
# which is cloned from https://github.com/osm0sis/AnyKernel3 by the build
# script - do not replace it with a hand-rolled flasher.

## AnyKernel setup
# begin properties
properties() { '
kernel.string=NetHunter kernel for Moto G Stylus 5G (2022) (milanf)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=milanf
device.name2=XT2215-1
device.name3=XT2215-3
device.name4=XT2215-4
supported.versions=
supported.patchlevels=
'; } # end properties

# boot shell variables
#
# AnyKernel3's core (tools/ak3-core.sh) reads these as UPPERCASE names. Older
# AK3 releases also accepted lowercase (block=, is_slot_device=, ...), but the
# current core does not - lowercase leaves $BLOCK empty and the installer
# aborts in recovery with:
#     Unable to determine  partition. Aborting...
# So these MUST stay uppercase.
#
# milanf is A/B: the core appends $SLOT itself, so boot resolves to boot_a.
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## AnyKernel install
# dump_boot unpacks the CURRENT boot.img from the device into $RAMDISK and
# keeps everything we do not replace: the device tree blob, the rest of the
# ramdisk and vendor_boot.img (with the ROM's kernel modules) are untouched.
dump_boot;

## ---------------------------------------------------------------------------
## NetHunter additions
## ---------------------------------------------------------------------------

# IMPORTANT - verified on milanf (2026-09-19) by unpacking the stock boot image:
# this device uses a GENERIC (GKI-style) boot ramdisk:
#     kernel 39328256 bytes, ramdisk 19452257 bytes (lz4), header v3
#     contains   : init, first_stage_ramdisk/, .backup/.magisk, ...
#     does NOT contain: init.rc, ueventd.rc
# The real rc files live on the system/vendor partitions
# (/system/etc/ueventd.rc, /vendor/etc/ueventd.rc), so there is no init.rc here
# to hook "import /init.nethunter.rc" into and no ueventd.rc to add /dev/hidg*
# rules to.
#
# That is fine: the kernel already provides everything NetHunter needs
# (CONFIG_USB_CONFIGFS_F_HID, ipset, the external Wi-Fi drivers, ...) and on
# this device the Kali chroot and the HID gadget are set up by the NetHunter
# app together with Magisk (Magisk is installed - .backup/.magisk in this very
# ramdisk - and /data/local/nhsystem already exists). A kernel-only flash is
# therefore complete.
#
# The hooks below are kept for non-GKI layouts, where init.rc IS in the ramdisk,
# and are skipped cleanly here.
if [ -f $RAMDISK/init.rc ]; then
	# 1) NetHunter ramdisk files (init.nethunter.rc, ...)
	if [ -d $AKHOME/ramdisk-patch ]; then
		ui_print "- Installing NetHunter ramdisk files";
		cp -af $AKHOME/ramdisk-patch/. $RAMDISK/;
		if [ -f $RAMDISK/init.nethunter.rc ]; then
			chown 0:0 $RAMDISK/init.nethunter.rc;
			chmod 0750 $RAMDISK/init.nethunter.rc;
		fi;
	fi;

	# 2) make init import the NetHunter rc file
	if ! grep -q "init.nethunter.rc" $RAMDISK/init.rc; then
		ui_print "- Adding 'import /init.nethunter.rc' to init.rc";
		echo "" >> $RAMDISK/init.rc;
		echo "import /init.nethunter.rc" >> $RAMDISK/init.rc;
	fi;

	# 3) HID gadget permissions (/dev/hidg*) for BadUSB / HID attacks
	if [ -f $RAMDISK/ueventd.rc ] && ! grep -q "/dev/hidg" $RAMDISK/ueventd.rc; then
		ui_print "- Adding /dev/hidg* rules to ueventd.rc";
		echo "" >> $RAMDISK/ueventd.rc;
		echo "# NetHunter HID gadget" >> $RAMDISK/ueventd.rc;
		echo "/dev/hidg0 0666 root root" >> $RAMDISK/ueventd.rc;
		echo "/dev/hidg1 0666 root root" >> $RAMDISK/ueventd.rc;
		echo "/dev/hidg2 0666 root root" >> $RAMDISK/ueventd.rc;
	fi;
else
	ui_print "- Generic (GKI-style) ramdisk: no init.rc / ueventd.rc to patch";
	ui_print "  NetHunter userspace (Kali chroot, HID gadget) is handled by the";
	ui_print "  NetHunter app + Magisk on this device - the kernel is self-contained";
fi;

# 4) extra, optional patches shipped in ak_patches/
for p in $(find $AKHOME/ak_patches -name '*.sh' 2>/dev/null); do
	ui_print "- Applying $p";
	. $p;
done;

## AnyKernel install
write_boot;

## end install
