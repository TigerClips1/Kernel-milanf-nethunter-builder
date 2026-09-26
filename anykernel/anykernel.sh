## AnyKernel3 Ramdisk Mod Script — KernelSU Next variant
## osm0sis @ xda-developers

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

# LineageOS and the custom kernel are installed on slot B. TWRP may be running
# from either slot; this package always targets B explicitly.
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=1;
SLOT_SELECT=active;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

## AnyKernel methods (DO NOT CHANGE)
. tools/ak3-core.sh;

## The custom kernel and vendor_boot are a matched pair on slot B. Do not
## derive the destination from TWRP's active slot: recovery may run from A
## while the bootloader still reports B as active (or vice versa).
SLOT="_b";
BLOCK="/dev/block/bootdevice/by-name/boot_b";

## ── Banner + educational-use warning ────────────────────────────────────────
ui_print " ";
ui_print "================================================";
ui_print "                                                ";
ui_print "   ___    _ _              _   _    _           ";
ui_print "  | __|__| | |__  __ _ ___| |_(_)__| |__ _      ";
ui_print "  | _|/ _\` | '_ \\/ _\` (_-<  _| / _\` / _\` |     ";
ui_print "  |___\\__,_|_.__/\\__,_/__/\\__|_\\__,_\\__,_|     ";
ui_print "                                                ";
ui_print "    >>  D A R K   H U N T E R   M O O N  <<     ";
ui_print "        ~ Reborn Edition · KernelSU Next ~     ";
ui_print "                                                ";
ui_print "    NetHunter Kernel  ·  Linux 5.4.302          ";
ui_print "    Motorola G Stylus 5G 2022 (milanf)         ";
ui_print "                                                ";
ui_print "    Root: KernelSU Next built into this kernel. ";
ui_print "                                                ";
ui_print "================================================";
ui_print " ";
ui_print "  /!\\  AVISO  /  WARNING                        ";
ui_print "                                                ";
ui_print "  Este kernel se distribuye EXCLUSIVAMENTE      ";
ui_print "  con fines educativos y de investigacion en    ";
ui_print "  seguridad. El uso contra sistemas o redes     ";
ui_print "  sin autorizacion expresa es ILEGAL. El        ";
ui_print "  autor (Edbastida) no se responsabiliza del    ";
ui_print "  mal uso de este software.                     ";
ui_print "                                                ";
ui_print "  Provided for EDUCATIONAL and SECURITY         ";
ui_print "  RESEARCH purposes only. Unauthorized use      ";
ui_print "  against any system or network is illegal.     ";
ui_print "  The author assumes no liability for misuse.   ";
ui_print "                                                ";
ui_print "================================================";
ui_print " ";

## AnyKernel install
[ -e "$BLOCK" ] || abort "Target boot_b partition was not found; aborting without flashing.";
ui_print "Target slot: B (fixed)";
STOCK_BOOT_IMAGE="$AKHOME/stock_boot.img";
[ -s "$STOCK_BOOT_IMAGE" ] || abort "Matching stock LineageOS boot.img is missing. Refusing to reuse the recovery boot ramdisk.";
CUSTOM_VENDOR_BOOT_IMAGE="$AKHOME/vendor_boot.img";
[ -s "$CUSTOM_VENDOR_BOOT_IMAGE" ] || abort "Matching custom vendor_boot.img is missing. Refusing to flash only the kernel.";
VENDOR_BOOT_BLOCK="/dev/block/bootdevice/by-name/vendor_boot_b";
[ -e "$VENDOR_BOOT_BLOCK" ] || abort "Target vendor_boot partition $VENDOR_BOOT_BLOCK was not found.";
[ "$(wc -c < "$CUSTOM_VENDOR_BOOT_IMAGE")" -le "$(wc -c < "$VENDOR_BOOT_BLOCK")" ] || abort "Custom vendor_boot.img is larger than $VENDOR_BOOT_BLOCK.";
FLASH_BLOCK="$BLOCK";
BLOCK="$STOCK_BOOT_IMAGE";
split_boot;
BLOCK="$FLASH_BLOCK";
flash_boot;
flash_generic vendor_boot;

## Install the bundled USB Wi-Fi driver module for KernelSU Next.
install_nethunter_module() {
  local SRC="$AKHOME/ksu_module";
  local DEST="/data/adb/modules/nethunter-realtek-drivers";

  [ -d "$SRC" ] || { ui_print " " "Warning: KSU Next driver module is missing from this ZIP."; return 0; };
  if [ ! -d /data/media/0 ]; then
    ui_print " " "Warning: /data is not decrypted; USB Wi-Fi module was not installed.";
    ui_print " " "You can install it later from KernelSU Next Manager.";
    return 0;
  fi;

  ui_print " " "Installing USB Wi-Fi drivers as a KernelSU Next module...";
  if ! mkdir -p "$DEST" || ! cp -rf "$SRC"/. "$DEST"/; then
    ui_print " " "Warning: could not copy the USB Wi-Fi module; install it later from KernelSU Next Manager.";
    return 0;
  fi;
  set_perm_recursive 0 0 0755 0644 "$DEST";
  [ -f "$DEST/service.sh" ] && set_perm 0 0 0755 "$DEST/service.sh";
  ui_print " " "USB Wi-Fi driver module installed.";
}
install_nethunter_module;
## end install
