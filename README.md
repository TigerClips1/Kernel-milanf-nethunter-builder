# NetHunter Kernel Builder - Moto G Stylus 5G (2022) `milanf`

Custom Kali NetHunter kernel for the **Moto G Stylus 5G (2022)**, built from the
LineageOS 23.2 kernel source with LineageOS' own configuration chain plus a
NetHunter fragment.

| | |
|---|---|
| **Device** | Motorola Moto G Stylus 5G (2022) - XT2215-1 / -3 / -4 |
| **Codename** | `milanf` |
| **SoC** | Qualcomm SM6375 (Snapdragon 695), platform `holi`, arm64 |
| **ROM** | LineageOS 23.2 (Android 16) - **`lineage-23.2-20260917-nightly-milanf-signed.zip` is required**, see below |
| **Kernel** | 5.4.302, `lineage-23.2` branch of `LineageOS/android_kernel_motorola_sm6375` |
| **ROM kernel release** | `5.4.302-moto-gc8bc4b74db62` (built 2026-09-17 from commit `c8bc4b74db62`, 2026-09-08) |
| **Toolchain** | AOSP clang 21 (`clang-r563880c`) + lld + LLVM integrated as, LTO + CFI |
| **Image** | uncompressed `Image` (`CONFIG_BUILD_ARM64_UNCOMPRESSED_KERNEL=y`) |
| **Partitions** | A/B device: `boot` (kernel+ramdisk), `vendor_boot` (ROM kernel modules), `dtbo` |

---

## Table of contents

1. [Read this first: module compatibility](#read-this-first-module-compatibility)
2. [Path B: shipping our own modules](#path-b-shipping-our-own-modules)
3. [How the kernel is configured](#how-the-kernel-is-configured)
4. [Feature status](#feature-status)
5. [NetHunter documentation compliance](#nethunter-documentation-compliance)
6. [Building](#building)
7. [Flashing](#flashing)
8. [Verifying](#verifying)
9. [Verified on device (2026-09-19)](#verified-on-device-2026-09-19)
10. [External Wi-Fi adapters](#external-wi-fi-adapters)
11. [Known limitations](#known-limitations)
12. [Troubleshooting](#troubleshooting)
13. [Repository layout](#repository-layout)
14. [Resources](#resources)
15. [License](#license)

---

## Read this first: module compatibility

> **The LineageOS build is part of the requirement.** Everything here is pinned to
> one nightly: **`lineage-23.2-20260917-nightly-milanf-signed.zip`** (kernel
> `5.4.302-moto-gc8bc4b74db62`, LineageOS source commit `c8bc4b74db62`, built
> 2026-09-17). **That ROM is required for this kernel to work** - the release
> string and the source commit are taken from it, so a different build (even
> another 23.2 nightly) changes both. Flash this ROM first, confirm Wi-Fi,
> touchscreen and charging work on it, then flash the kernel. If you must run a
> different build, rebuild with `STOCK_RELEASE="$(adb shell uname -r)"` **and**
> update `KERNEL_COMMIT`, or the ROM's modules are rejected (see below).

This device does **not** run a monolithic kernel. The ROM ships **kernel modules
in `vendor_boot.img`**, and that partition is *not* touched when you flash a
kernel with AnyKernel3:

* Read off the device: `/vendor/lib/modules/` holds 82 files, **77 of them
  `.ko`**, plus `modules.load` (`/lib/modules` in the boot ramdisk is empty).
  Wi-Fi, charger, fingerprint, audio and the `mmi_*` drivers are all modules
  (`=m`) in the stock LineageOS config - see `CONFIG_QCA_CLD_WLAN=m`, `CONFIG_MMI_CHARGER=m`,
  `CONFIG_INPUT_EGIS_FPS_MMI=m`,
  `CONFIG_TOUCHSCREEN_NT36xxx_HOSTDL_SPI_MMI=m`, ...
* The stock kernel has `CONFIG_MODVERSIONS=y` and no `CONFIG_MODULE_SIG`, so a
  module is only accepted when **both** match:

  1. **vermagic** - the kernel release string must be byte-identical
     (`5.4.302-<localversion> SMP preempt mod_unload modversions aarch64`).
     Verified on this device:
     `strings /vendor/lib/modules/mmi_charger.ko | grep vermagic` gives
     `5.4.302-moto-gc8bc4b74db62 SMP preempt mod_unload modversions aarch64`.
     If you build with a different string (e.g. `LOCALVERSION="-NetHunter-milanf"`),
     every one of those modules is rejected with *"version magic ... should be
     ..."* and the phone boots without Wi-Fi, touchscreen or charging.
  2. **symbol CRCs** - any config option that changes the memory layout of a
     struct used by an exported symbol changes its CRC (`CONFIG_MODVERSIONS`).
     This is why `config/nethunter_milanf.fragment` (the default, *Path A*)
     deliberately does **not** enable `CONFIG_CFG80211_WEXT`,
     `CONFIG_MAC80211_MESH` or `CONFIG_WIRELESS_WDS`: they alter the
     cfg80211/mac80211 structures and would stop the stock WLAN module from
     loading. **Path B enables them on purpose** - it ships its own `wlan.ko`,
     so nothing of the ROM's is loaded - see below.

Therefore:

* Build with the release string the ROM actually uses:
  ```bash
  STOCK_RELEASE="$(adb shell uname -r)" ./build-nethunter-kernel.sh
  ```
  The script converts it into `CONFIG_LOCALVERSION` (and disables
  `CONFIG_LOCALVERSION_AUTO` so the git hash of your checkout cannot leak into
  the version). It refuses to create the zip if the built release differs.
* The script is already pinned to the values read off this device, so plain
  `./build-nethunter-kernel.sh` also does the right thing when the phone is
  reachable over adb:

  | | value | where it comes from |
  |---|---|---|
  | ROM kernel release | `5.4.302-moto-gc8bc4b74db62` | `adb shell uname -r` on 2026-09-19 |
  | Kernel source commit | `c8bc4b74db62d4d4b24c575046f140f4e6732898` | the 12 hex chars after `-g` in the release string |
  | `CONFIG_LOCALVERSION` | `-moto-gc8bc4b74db62` | release string minus `5.4.302` |

  The `-g<hash>` part is what `scripts/setlocalversion` appends for
  `CONFIG_LOCALVERSION_AUTO=y` (12 hex characters of the kernel commit the ROM
  was built from), which is why the source is checked out at that exact commit:
  it keeps exported symbol CRCs identical to the ROM's prebuilt modules.

  **After every LineageOS update**, refresh all three:
  `adb shell uname -r`, then update `KERNEL_COMMIT` / `DEFAULT_STOCK_RELEASE`
  in `build-nethunter-kernel.sh` and `CONFIG_LOCALVERSION` in
  `config/nethunter_milanf.fragment` (or just pass `STOCK_RELEASE=...`, which
  overrides the release string; the commit still has to be updated by hand).
* Keep NetHunter features **built-in (`=y`)** so nothing has to be shipped next
  to the ROM's modules. That is what `config/nethunter_milanf.fragment` does.
* Only if you change the release string on purpose (e.g. you want `uname -r` to
  say `-NetHunter-milanf`) must you also rebuild **every** module and repack
  `vendor_boot.img` (`BOARD_VENDOR_KERNEL_MODULES_LOAD` from
  `device/motorola/milanf/modules.load`). That is outside what AnyKernel3 can do.

---

## Path B: shipping our own modules

Some NetHunter features need kernel options that change the layout of a struct
in a widely included header:

| Option | What it adds | Consequence |
|---|---|---|
| `CONFIG_CAN` | `netns_can` member in `struct net` (`#if IS_ENABLED(CONFIG_CAN)`, `net_namespace.h`) | `device_register`, `__alloc_skb`, `wake_up_process`, `crypto_register_alg` ... all rehash |
| `CONFIG_BRIDGE_NETFILTER` | `struct nf_bridge_info` in `skbuff.h` | same |
| `CONFIG_NETFILTER_XT_MATCH_REALM` | selects `IP_ROUTE_CLASSID` (routing structs) | same |
| `CONFIG_NETFILTER_XT_MATCH_CONNLABEL` | selects `NF_CONNTRACK_LABELS` (`struct nf_conn`) | same |

`CONFIG_MODVERSIONS=y` rejects any module whose symbol CRCs disagree, and the
CRCs come from `genksyms`, which hashes each translation unit's **type table** -
so those four options make the ROM's own modules unusable. That is why they are
disabled in `config/nethunter_milanf.fragment` (*Path A*, what this repo ships by
default: the ROM's modules keep loading and nothing has to be flashed alongside).

**Path B** flips it around: `config/pathb.fragment` enables those options *and*
the build produces the complete module set, delivered where this ROM already
keeps its own first-stage modules:

```
vendor_boot.img  (header v3, page 4096)
+- header 2112 B
+- vendor_ramdisk (lz4 legacy)
|  +- first_stage_ramdisk/fstab.qcom        preserved
|  +- lib/modules/*.ko                      REPLACED with our set
|  +- lib/modules/modules.load              EMPTY in the stock image -> filled in
|  +- lib/modules/modules.dep/.alias/.softdep   regenerated by depmod
|  +- system/bin/{e2fsck,fsck.f2fs,linker64} preserved
|  +- system/lib64/*.so                     preserved
+- dtb + padding
```

The stock `lib/modules/modules.load` is **0 bytes**: on this ROM the modules sit
on the `/vendor` logical partition (inside `super`) and are loaded by *second-stage*
init, which runs before Magisk mounts anything - so a Magisk module cannot replace
kernel modules here. The vendor_boot ramdisk is loaded by *first-stage* init,
before `/vendor` is even mounted, which makes it the correct hook: our modules win,
and when second-stage init later tries the `/vendor` copies their names are already
in the kernel, so init skips them ("...already loaded" - that handling was verified
to exist in this device's `init`).

### Doing a Path B build

```sh
PATH_B=1 ./build-nethunter-kernel.sh config    # also merges config/pathb.fragment
PATH_B=1 ./build-nethunter-kernel.sh build     # Image + ALL modules, stripped
PATH_B=1 ./build-nethunter-kernel.sh payload   # vendor_boot image with our modules
PATH_B=1 ./build-nethunter-kernel.sh zip       # AK3 zip with the Path B kernel
```

`build` stages modules in `output/modules-flat/lib/modules/<release>/` (flat,
`INSTALL_MOD_STRIP=1`, `depmod` run) and warns if the ROM loads a module name this
tree does not build. `payload` then rewrites the vendor_boot ramdisk and reports
the image budget; the result is `output/vendor_boot-pathb-milanf.img`.

### Flashing Path B

```sh
fastboot flash vendor_boot_a output/vendor_boot-pathb-milanf.img
# and the kernel itself, e.g. the AK3 zip in recovery/sideload
```

**The two halves belong together.** A Path B kernel with the stock vendor_boot
loses Wi-Fi/camera/charger (the ROM's modules are rejected), and Path B modules
under a stock kernel will not load either.

### Verified on device (2026-09-19)

Built and flashed the same day, and it boots:

* `output/vendor_boot-pathb-milanf.img` carries **77 modules** (28.9 MB) and was
  written to `vendor_boot_a`, then hash-verified against the payload before the
  reboot. The stock dump was proven byte-identical to the partition first, so the
  rollback image is known-good.
* `output/nethunter-kernel-milanf.zip` flashed, device boots with Wi-Fi, camera,
  audio and charging intact.
* That last point is the proof the ramdisk delivery works: with a Path B kernel
  the ROM's prebuilt modules can no longer pass their CRC checks, so a working
  `wlan.ko` can only have come from `lib/modules/` in the vendor_boot ramdisk.
* `coverage: every module the ROM loads is built here` - including `wlan.ko`
  from the in-tree `qcacld-3.0` - so nothing is left behind on `/vendor`.
* Re-verified from **recovery**, which is the cleanest possible test because
  recovery does *not* mount `/vendor`: **77 modules were loaded anyway**, so every
  one of them came from our vendor_boot ramdisk.
* `CAN_RAW` and `CAN_BCM` appear in `/proc/net/protocols`, `/proc/net/can/` is
  populated with `rcvlist_*`/`stats`, and `realm` + `connlabel` are registered in
  `/proc/net/ip_tables_matches` (57 match types) - the options that forced Path B
  are live. (Recovery has no `ip` binary, so test `vcan0` from a booted system.)
* Our modules are builds of the *same sources* as the ROM's, not lookalikes:
  `tcpc_class.ko` is 424832 B vs the ROM's 424848 B with an **identical set of
  imported symbol names**, and every USB/Type-C module matches the ROM's in size
  and symbol counts.

Re-check any time the device is plugged in:

| Check | Command |
|---|---|
| Kernel + build stamp | `adb shell 'uname -r; cat /proc/version'` |
| Module set loaded | `adb shell su -c 'wc -l < /proc/modules'` |
| No ABI rejections | `adb shell su -c 'dmesg \| grep -iE "disagrees about version\|version magic"'` |
| CAN, no dongle needed | `adb shell su -c 'ip link add dev vcan0 type vcan; ip link set vcan0 up; ip -d link show vcan0'` |
| xtables extras live | `adb shell su -c 'grep -E "realm\|connlabel" /proc/net/ip_tables_matches'` |
| Path B options live | `adb shell su -c 'zcat /proc/config.gz \| grep -E "^CONFIG_(CAN\|BRIDGE_NETFILTER\|IP_ROUTE_CLASSID\|NF_CONNTRACK_LABELS)="'` |

### Docs-parity build verified live (2026-09-19 21:40)

The second Path B build - the one that adds `config/nethunter-docs.fragment` -
was flashed and re-tested on the running device:

| What | Result |
|---|---|
| Kernel | `5.4.302-moto-gc8bc4b74db62 #2 SMP PREEMPT Sat Sep 19 21:25:05 EDT 2026`, `Image` = 45.4 MB (`boot_a` is 96 MB) |
| All 58 symbols of `config/nethunter-docs.fragment` | live in `/proc/config.gz` |
| **HID attacks** | `usbarsenal -t win -f adb,hid -v 0x18d1 -p 0x4e11` -> `/dev/hidg0` + `/dev/hidg1` (0666), gadget carries `hid.0` + `hid.1` |
| **CARsenal** | `vcan0` created and `UP,LOWER_UP` (`link/can`, mtu 72); `CAN_RAW`/`CAN_BCM` in `/proc/net/protocols`; `/proc/net/can/*` populated |
| **EvilTwin / MITM** | `realm` + `connlabel` registered in `/proc/net/ip_tables_matches`; `REDIRECT`/`TPROXY`/`MASQUERADE`/NAT already `=y` |
| Metasploit prerequisite | SysV IPC live: `/proc/sys/kernel/{sem,shmall,shmmax,msgmax}` |
| **External Wi-Fi + SDR** | driver-level: registered in `/sys/bus/usb/drivers/`: `carl9170 mt7601u zd1211rw ath6kl_usb ath9k_htc rt2800usb rt73usb rtl8xxxu rtl8187 zd1201 rndis_wlan dvb_usb_rtl28xxu btusb` |
| No regressions | Wi-Fi connected (IPv4 + IPv6), charger `Full`, `usb-online=1`, USB `mode=peripheral` with `connected=true`, camera "Number of camera devices: 5", audio HAL threads running, fingerprint provider responding, 90 GB free |
| Still not loading | `silead_fps_mmi`, `rbs_fps_mmi`, `rmnet_offload`, `rmnet_shs` - unchanged from the first Path B build |

Anything that needs a USB dongle (Wi-Fi injection/monitor mode, SDR capture, BT
Arsenal adapters, EvilTwin AP) is registered at the driver level but cannot be
exercised without the hardware. Bluetooth comes up (`dumpsys bluetooth_manager`:
state ON, valid address) with `btpower` + `bt_fm_slim` loaded.

### USB stops enumerating after flashing Path B (fixed 2026-09-19)

Symptom: the phone charges, but the PC sees no USB device at all and the "USB
preferences" notification never appears - so no adb and no file transfer.

Measured on the device:

| Probe | Value | Meaning |
|---|---|---|
| `lsusb` on the PC | nothing | the phone never enumerates |
| `/sys/class/udc/4e00000.dwc3/state` | `not attached` | controller sees no session |
| `/sys/devices/platform/soc/4e00000.ssusb/mode` | **`none`** | controller is in *no* role |
| `extcon0` (`1628000.qcom,msm-eud`) | `USB=0 SDP=0` | nothing reported a host |
| `extcon3` (`soc:rt-pd-manager`) | `USB=0 USB-HOST=0` | same, from the PD manager |
| `power_supply/charger/usb_type` | `Unknown` | BC1.2 found no data partner |
| `power_supply/usb` | `online=1 type=USB_PD` | VBUS/PD are fine |

The PC's own kernel log cleared the hardware: in recovery the same cable and port
enumerated (`18d1:d001`, the phone's own serial number) and only lost it at the reboot into
LineageOS. So the vendor USB role handshake (charger/PD-manager -> extcon ->
`msm-dwc3`) simply never asserts `USB`, leaving the controller in `mode=none`.

**Fix** - assert device mode ourselves, which is exactly what the handshake fails
to do. Both halves are in this repo (`magisk/`), installed as Magisk hooks
(systemless, no system partition changes):

```bash
adb push magisk/nh-usb-mode-postfs.sh magisk/nh-usb-mode-service.sh /sdcard/
adb shell 'su -c "mkdir -p /data/adb/post-fs-data.d /data/adb/service.d
  cp /sdcard/nh-usb-mode-postfs.sh  /data/adb/post-fs-data.d/nh-usb-mode-postfs.sh
  cp /sdcard/nh-usb-mode-service.sh /data/adb/service.d/nh-usb-mode-service.sh
  chmod 0755 /data/adb/post-fs-data.d/nh-usb-mode-postfs.sh /data/adb/service.d/nh-usb-mode-service.sh
  chcon u:object_r:magisk_file:s0 /data/adb/post-fs-data.d/nh-usb-mode-postfs.sh /data/adb/service.d/nh-usb-mode-service.sh"'
```

* `/data/adb/post-fs-data.d/nh-usb-mode-postfs.sh` - writes `peripheral` early in
  boot, then spawns a watchdog (`setsid $0 --watch`) if one is not already running
* `/data/adb/service.d/nh-usb-mode-service.sh` - writes it again at `service`
  time and spawns its own watchdog (**two** loops on purpose: if one is killed -
  OOM, a stray `pkill` - the other keeps repairing the mode)

The watchdog loop is 3 s: whenever something resets the mode (`unplug`/`replug`
makes `msm-dwc3` reset it to `none`) it writes `peripheral` back, waits 5 s, then
**checks whether the framework noticed** - `dumpsys usb | grep connected=true`.
Only if it still has not does it fall back to `svc usb setFunctions <sys.usb.config>`,
because that call makes `UsbDeviceManager` re-evaluate its state but also restarts
`adbd`, which drops *every* adb session (USB and wireless) for a few seconds.
Everything it does is logged to `/data/local/tmp/nh-usb-mode.log`, e.g.

```
watchdog: started (pid 23247)
watchdog: 'none' -> peripheral (cable event)
watchdog: framework already sees USB - no nudge needed
```

**This is the replug bug.** A replug leaves the mode at `none`, and on this device
the vendor USB HAL never notices: the extcon cable state stays `USB=0` (and
`extcon/*/state`, `charger/usb_type`, `pc_port/online` are all read-only, so
nothing can assert it from userspace), so the framework keeps believing nothing is
connected and the "Charging this device via USB" notification never comes back.
The mode write is what actually restores `connected=true` and the notification -
and because the repair happens in a background loop, it only works while a
watchdog is alive. A dead watchdog is indistinguishable from an unpatched USB
stack, which is why the loop now runs twice.

The `chcon` matters: without it the file is labelled `adb_data_file` and Magisk
will not run it.

Verified across a reboot: the host enumerates `18d1:4e11`, USB adb works, and
`dumpsys usb` reports `connected=true` / `kernel_state=CONFIGURED`, so the USB
preferences/file-transfer popup is available again.

Caveats: USB **host (OTG)** mode is not available while this is installed, and
this masks the vendor handshake rather than repairing it - the reason the extcons
stay at `USB=0` (starting with the charger's BC1.2 detection returning `Unknown`)
was not tracked down. `adb` also still works over Wi-Fi (Developer options ->
Wireless debugging) if you want a channel that does not depend on it. Remove with:

```sh
su -c 'rm -f /data/adb/post-fs-data.d/nh-usb-mode-postfs.sh /data/adb/service.d/nh-usb-mode-service.sh'
su -c 'pkill -f "nh-usb-mode.*[-]-watch"'
```

### Rolling back

Always keep a whole-partition dump of the stock image first:

```sh
adb shell su -c 'dd if=/dev/block/bootdevice/by-name/vendor_boot_a of=/sdcard/vendor_boot-stock.img'
adb pull /sdcard/vendor_boot-stock.img output/vendor_boot-stock-milanf.img
fastboot flash vendor_boot_a output/vendor_boot-stock-milanf.img   # rollback
```

`tools/vendor-boot.py` (`info` / `unpack` / `pack`) rewrites the image; `pack`
round-trips an untouched ramdisk byte-for-byte and pads over the stale AVB footer,
which is harmless here (`ro.boot.veritymode` is unset, `verifiedbootstate=orange`).

For the injection experiment, roll back with the **Path B unpatched** payload
(`output/vendor_boot-pathb-nopatch.img`) instead of the stock image: it is the same
Path B kernel with an unpatched Wi-Fi driver, so a single `dd` puts the Wi-Fi back
without losing any NetHunter feature. Keep it next to the patched one - see
"Optional: injection on the built-in Wi-Fi" for how both are built.

---

## How the kernel is configured

LineageOS builds this device from **three** pieces (device tree:
`device/motorola/sm6375-common` + `device/motorola/milanf`):

```make
# sm6375-common/BoardConfigCommon.mk
TARGET_KERNEL_CONFIG := vendor/holi-qgki_defconfig \
                        vendor/ext_config/lineage_moto-holi.config
# milanf/BoardConfig.mk
TARGET_KERNEL_CONFIG += vendor/ext_config/moto-holi-milanf.config
```

`config/nethunter_milanf.fragment` is merged on top of those three files:

```
arch/arm64/configs/vendor/holi-qgki_defconfig                  (base)
arch/arm64/configs/vendor/ext_config/lineage_moto-holi.config  (LineageOS)
arch/arm64/configs/vendor/ext_config/moto-holi-milanf.config   (milanf)
config/nethunter_milanf.fragment                               (NetHunter)
```

> ⚠️ The fragment is **not** a defconfig. Running
> `make nethunter_milanf_defconfig` on it throws away `CONFIG_MILANF_DTB`,
> `CONFIG_ARCH_HOLI`, the display/touch/charger options and everything else the
> ROM needs, and produces a kernel that will not boot. The build script uses
> `scripts/kconfig/merge_config.sh` and then verifies that the device options
> survived.

---

## Feature status

Verified against the kernel config running on LineageOS 23.2 for `milanf`:

| Feature | Config | State |
|---|---|---|
| HID gadget `/dev/hidg*` (BadUSB/HID attacks) | `USB_CONFIGFS_F_HID`, `USB_F_HID`, `USB_F_FS`, `INPUT_UINPUT` | **already in stock** - no config change needed, the flasher only adds ueventd permissions |
| USB Arsenal / gadget modes | `USB_CONFIGFS_RNDIS/ECM/ECM_SUBSET` | added |
| USB serial adapters (RS232, FTDI, CP210x, PL2303, CH341, ...) | `USB_SERIAL*` | added (stock had `# CONFIG_USB_SERIAL is not set`) |
| USB WWAN/LTE dongles | `USB_NET_QMI_WWAN`, `USB_WDM`, `USB_SERIAL_OPTION/WWAN` | added |
| USB traffic capture (usbmon/Wireshark) | `USB_MON` | added |
| Bluetooth (onboard QCA) | `BT_HCIUART*`, `BT_RFCOMM`, `BT_HIDP` | already in stock |
| Bluetooth USB dongles | `BT_HCIBTUSB`, `BT_HCIBCM203X`, `BT_HCIBPA10X` | added (stock had them all disabled) |
| **External Wi-Fi adapters** (monitor/injection) | `WLAN_VENDOR_RALINK/ATH/REALTEK/MEDIATEK/ZYDAS` + drivers | **added** - every WLAN vendor was disabled in stock |
| Legacy wireless-extensions tools (`iwconfig`, aircrack-ng, wifite, hostapd WEXT) | `CFG80211_WEXT` | **enabled in Path B** (see docs compliance below) |
| 802.11s mesh | `MAC80211_MESH` | **enabled in Path B** |
| Netfilter / iptables + **ipset** | `IP_SET*`, `NETFILTER_XT_MATCH_*`, `NETFILTER_XT_TARGET_*` | core already in stock; ipset + missing matches/targets added |
| Bridge filtering (MITM/tethering) | `BRIDGE_NETFILTER` | added |
| NFS client + server | `NFS_FS`, `NFSD`, v3/v4 | added |
| CAN bus (vcan, vxcan, slcan, USB adapters) | `CAN`, `CAN_VCAN`, `CAN_SLCAN`, `CAN_*_USB` | added |
| LTO + CFI hardening | `LTO_CLANG`, `CFI_CLANG` | already in stock (slower builds, keep it) |
| KASLR | `RANDOMIZE_BASE` | already in stock |

Built-in Qualcomm Wi-Fi (`WCN6750`) cannot do monitor mode or injection - an
external USB adapter is required for wireless work.

---

## NetHunter documentation compliance

Audited 2026-09-19 against every option in the official kernel-configuration
chapters (`nethunter-kernel-2-config-1` .. `nethunter-kernel-9-config-8`) by
diffing each documented symbol against `/proc/config.gz` on the device.

**108 options checked: 72 were already live in the stock config, 6 cannot exist
in this tree at all, and the rest are enabled by `config/nethunter-docs.fragment`
(Path B) - 58 symbols, which include the dependency helpers `RC_CORE`,
`DVB_CORE`, `DVB_USB_V2`, `CAN_M_CAN` and `MEDIA_SUBDRV_AUTOSELECT=y`.**

### The five features NetHunter's capability table marks as "custom kernel only"

| Feature | Kernel side | State |
|---|---|---|
| **HID attacks** (HID keyboard, DuckHunter, BadUSB) | `USB_CONFIGFS_F_HID`, `USB_F_HID`, `USB_F_FS`, `INPUT_UINPUT` | stock `=y` - verified live (`/dev/hidg0`, `/dev/hidg1`, 0666) |
| **Wi-Fi injection** | the documented external adapters: `RT2800USB`(+all sub-options), `ATH9K_HTC`, `RTL8187`, `RTL8192CU`, `RTL8XXXU`, `MT76x0U`/`MT76x2U`, `CFG80211_WEXT`, plus Path B's `CARL9170`, `ATH6KL`, `MT7601U`, `RT2500USB`, `RT73USB`, `ZD1211RW`, `USB_ZD1201`, `RNDIS_WLAN` | `=y` - needs a dongle to test |
| **BT Arsenal** | `BT_HCIBTUSB`(+`_BCM`/`_RTL`), `BT_HCIUART`(+`_H4`/`_BCM`/`_3WIRE`/`_LL`/`_QCA`/`_INTEL`/`_ATH3K`/`_MRVL`), `BT_HCIBCM203X`, `BT_HCIBPA10X`, `BT_HCIBFUSB`, `BT_HCIVHCI`, `BT_ATH3K`, `BT_MRVL`, `BT_BNEP`, `BT_RFCOMM`, `BT_HIDP` | `=y` (Path B added the UART/Marvell/Atheros/BNEP parts) |
| **CARsenal** | `CAN`+`RAW`/`BCM`/`GW`/`DEV`/`CALC_BITTIMING`, `CAN_VCAN`, `CAN_SLCAN`, `CAN_*_USB` (EMS, ESD, GS_USB = CANable, Kvaser, PEAK, 8dev, UCAN, MCBA), `CAN_MCP251X`, `CAN_HI311X`, `USB_SERIAL_CH341`/`_FTDI_SIO` | `=y` - `vcan0` verified live; Path B added 8dev/MCP251x/HI311x/Softing/GRCAN/Xilinx/M_CAN |
| **EvilTwin** | userspace (hostapd + dnsmasq + captive portal) on an adapter with AP mode; kernel only needs mac80211 AP + `IP_NF_TARGET_REDIRECT`, `NETFILTER_XT_TARGET_REDIRECT`, `NF_NAT_REDIRECT`, `NETFILTER_XT_NAT`, `IP_NF_TARGET_MASQUERADE`, `NETFILTER_XT_TARGET_TPROXY`, `NETFILTER_XT_MATCH_IPRANGE` | all already `=y` - nothing to add, only a dongle is missing |

### Also added by `config/nethunter-docs.fragment`

* **General** - `SYSVIPC` (Metasploit's PostgreSQL uses SysV semaphores),
  `MODULE_FORCE_UNLOAD`.
* **Network** - `CFG80211_WEXT`, `MAC80211_MESH`, `NETLINK_DIAG`, `VSOCKETS`.
* **SDR** - `MEDIA_DIGITAL_TV_SUPPORT`, `MEDIA_SDR_SUPPORT`, `DVB_CORE`,
  `RC_CORE`, `DVB_USB`, `DVB_USB_V2`, `USB_AIRSPY`, `USB_HACKRF`,
  `USB_MSI2500`, `DVB_RTL2830/_RTL2832/_RTL2832_SDR/_SI2168/_ZD1301_DEMOD`,
  **`DVB_USB_RTL28XXU`** (the RTL2832U USB bridge without which the documented
  RTL-SDR stick never appears) and the tuners `MEDIA_TUNER_R820T` (RTL-SDR),
  `_E4000`, `_FC0012`, `_FC0013`, `_FC2580`, `_MT2060`.
* **USB gadget** - `USB_CONFIGFS_OBEX`, `USB_CONFIGFS_EEM`, `USB_SERIAL_CONSOLE`.
* **CAN** - `CAN_8DEV_USB`, `CAN_MCP251X`, `CAN_HI311X`, `CAN_SOFTING`,
  `CAN_GRCAN`, `CAN_XILINXCAN`, `CAN_M_CAN`(+`_PLATFORM`), `LEDS_TRIGGER_NETDEV`.

### Impossible in this tree

| Docs ask for | Why not |
|---|---|
| `BT_HCIUART_RTL` ("Realtek protocol support") | `depends on ACPI` (+ `BT_HCIUART_SERDEV`, `GPIOLIB`) - arm64 Android has no ACPI. Realtek USB dongles (TP-Link UB500) work through `BT_HCIBTUSB_RTL`. |
| `CAN_CC770_PLATFORM`, `CAN_C_CAN_PLATFORM`, `CAN_SJA1000_PLATFORM` | Motorola pruned the controller cores (`CAN_CC770`, `CAN_C_CAN`, `CAN_SJA1000`, `CAN_RX_OFFLOAD`) from this tree, so the platform drivers can never be selected. They are inert on a phone anyway. |
| `NET_SCH_CAN` | not in 5.4. |
| `CAN_ISOTP`, `CAN_HLCAN` | the docs have you `git submodule add` them - out-of-tree drivers, not config options. |
| `BUILD_ARM64_APPENDED_DTB_IMAGE` / `IMG_GZ_DTB` | this device uses an uncompressed `Image` and keeps the DTB in vendor_boot. |

### Deliberate deviations from the docs

| Docs say | We do | Why |
|---|---|---|
| clear "Local version" so the kernel version prints *Kali* | keep `5.4.302-moto-gc8bc4b74db62` | cosmetic; any other release string makes the ROM's `/vendor` modules (zram, fingerprint, charging) refuse to load |
| clear `MEDIA_SUBDRV_AUTOSELECT`, then hand-pick frontends | keep autoselect ON, pin the frontends/tuners by hand | with it off, **every** tuner/frontend in the tree defaults to `=m` (that is the "unselect all" the docs do by hand) and ~100 unused modules get built; autoselect pulls in exactly what `DVB_USB_RTL28XXU` declares |
| `CAN_LEDS` ("LED triggers for Netlink drivers") | `LEDS_TRIGGER_NETDEV` | `CAN_LEDS` now `depends on BROKEN`; its own Kconfig says the netdev trigger replaces it |

### Not covered: injection on the *built-in* Wi-Fi

The internal `qcacld-3.0` driver in this Motorola tree has the monitor vdev
plumbing (`WMI_VDEV_TYPE_MONITOR`) but **no** `gEnableMonitorMode`/`setMonMode`
knob, so there is nothing to switch on from the config - it needs a real driver
patch, and `/vendor/etc/wifi/WCNSS_qcom_cfg.ini` is read-only. External adapters
are the supported path. Since Path B ships our own `wlan.ko`, that driver patch is
now available as an opt-in - see "Optional: injection on the *built-in* Wi-Fi
(`PATCH_INJECT=1`)".

---

## Building

### Requirements

* Linux with an **ext4** filesystem (netfilter sources break on NTFS/exFAT)
* ~40 GB free disk, 16 GB RAM (more is better: LTO + CFI link step is heavy)
* `sudo ./requirements.sh` (or the apt line in that script)
* the ROM this is built against: **`lineage-23.2-20260917-nightly-milanf-signed.zip`**
  (release string `5.4.302-moto-gc8bc4b74db62`). Another build means another
  `uname -r` and another source commit - see "Read this first" above.
* a working `adb` connection to the phone is recommended, so the script can read
  `uname -r` off the device instead of trusting the pinned default

### Quick start

```bash
chmod +x build-nethunter-kernel.sh

# recommended: tell it what the ROM reports so the vendor modules keep working
STOCK_RELEASE="$(adb shell uname -r)" ./build-nethunter-kernel.sh

# result
output/nethunter-kernel-milanf.zip
```

Step by step:

```bash
./build-nethunter-kernel.sh doctor        # show plan, detect the device release
./build-nethunter-kernel.sh toolchains    # download AOSP clang
./build-nethunter-kernel.sh source        # clone LineageOS kernel + AnyKernel3
./build-nethunter-kernel.sh config        # merge configs, report dropped symbols
./build-nethunter-kernel.sh build         # compile Image (~30-90 min)
./build-nethunter-kernel.sh verify        # can the ROM's modules still load? (Path A)
./build-nethunter-kernel.sh zip           # flashable AnyKernel3 zip
```

Path B additionally needs `modules` + `payload` - see the Path B section above.

Useful variables:

| Variable | Meaning |
|---|---|
| `STOCK_RELEASE` | exact `uname -r` of the ROM kernel (pins `CONFIG_LOCALVERSION`) |
| `KERNEL_COMMIT` | lineage-23.2 commit to build from (default: the commit the ROM built) |
| `JOBS` | parallel make jobs (default: all cores) |
| `CLANG_PREBUILT` | clang prebuilt to fetch (default `clang-r563880c` = clang 21, the ROM's compiler) |
| `CLANG_TAG` | AOSP tag holding that prebuilt (default `android-16.0.0_r4`) |
| `FORCE=1` | package the zip even if the release string does not match |

### What the build actually does

```bash
make O=out vendor/holi-qgki_defconfig
scripts/kconfig/merge_config.sh -m -O out out/.config \
    arch/arm64/configs/vendor/ext_config/lineage_moto-holi.config \
    arch/arm64/configs/vendor/ext_config/moto-holi-milanf.config \
    config/nethunter_milanf.fragment
    # PATH_B=1 appends config/pathb.fragment + config/nethunter-docs.fragment here
make O=out olddefconfig
make O=out syncconfig            # keeps include/config/auto.conf in step with .config
make -s O=out kernelrelease      # must equal $STOCK_RELEASE, otherwise the script aborts
make -j"$(nproc)" O=out CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
     OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf \
     OBJSIZE=llvm-size STRIP=llvm-strip \
     CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
     CLANG_TRIPLE=aarch64-linux-gnu- LLVM_IAS=1 LOCALVERSION= Image
```

> ⚠️ `LOCALVERSION=` (even empty) and the `syncconfig` refresh are **not
> optional**. Without them `scripts/setlocalversion` appends `+`, `-g<sha>` or
> `-dirty` to the release string (a stale `include/config/auto.conf` carrying
> `CONFIG_LOCALVERSION_AUTO=y` is enough), the vermagic changes, and every one of
> the ROM's modules is rejected. That is why the script pins the string and
> refuses to package a zip when it does not match.

No GCC is needed: the device tree sets `TARGET_KERNEL_NO_GCC := true` and the
stock config confirms a clang-only build (`CONFIG_CC_IS_CLANG=y`,
`CONFIG_LD_IS_LLD=y`, `CONFIG_AS_IS_LLVM=y`, `CONFIG_GCC_VERSION=0`).

The `config` step prints every symbol that Kconfig dropped or overrode, e.g.

```
  ! CONFIG_NFSD_DEBUG                             wanted=y              effective=n
```

That is normal for options that do not exist in 5.4 or whose dependencies are
not met - fix them in the fragment instead of wondering why a feature is missing.
This fragment was validated against the real tree: all 106 of its symbols apply
exactly (104 settings - 93 of them `=y`, the rest strings such as
`CONFIG_LOCALVERSION` - plus two explicit `# ... is not set` lines,
`LOCALVERSION_AUTO` and `R8188EU`), and the `config` step prints anything Kconfig
rejects. Three USB-serial symbols that no longer exist upstream were removed, and
`R8188EU` stays off because it is module-only (`depends on m`).

### Verify before flashing: can the ROM's modules still load?

`vermagic` matching is necessary but not sufficient. With `CONFIG_MODVERSIONS=y`
the kernel also compares the CRC of **every symbol a module imports**, and a
config option that changes a struct layout in a shared header changes CRCs while
leaving the version string identical. The classic trap on this device is
`CONFIG_CFG80211_WEXT`, which adds a `wext` member to `struct wiphy`.

The tooling does that check for you:

```bash
# after ./build-nethunter-kernel.sh build
tools/verify-module-crc.sh
```

It pulls all ~77 modules from `/vendor/lib/modules` (once) into
`output/rom-modules/`, reads the exact CRCs they expect with
`modprobe --dump-modversions`, and compares them against the freshly built
`kernel/out/Module.symvers`. Output:

```
OK       wlan.ko: all 432 imported symbols match
OK       mmi_charger.ko: all 68 imported symbols match
...
All checked modules can be loaded by this kernel.
```

Any `MISMATCH`/`MISSING` line identifies the symbol (and therefore the
subsystem) you need to change, before anything is flashed.

If you ever need to prove that a mismatch is caused by *our* config and not by
the source tree, `tools/baseline-build.sh` rebuilds the kernel with the ROM's own
config verbatim into `kernel/out-baseline` and runs the same comparison.

---

## Flashing

> ⚠️ Back up `boot` (and `vendor_boot`) first — this is an A/B device, so the
> active slot's node is `boot_a`/`boot_b`; there is **no** bare `boot`:
> `adb shell su -c 'dd if=/dev/block/bootdevice/by-name/boot_a of=/sdcard/boot-stock.img'`

```bash
adb reboot recovery      # or TWRP
# flash output/nethunter-kernel-milanf.zip
adb reboot
```

AnyKernel3 unpacks the current boot image, replaces only the kernel and repacks
it - the DTB and the ramdisk stay as they were, and `vendor_boot` is never
touched. On this device the ramdisk patches are a deliberate no-op: the boot
ramdisk is GKI-style (no `init.rc`/`ueventd.rc` to hook into), so `anykernel.sh`
detects that and reports it instead of installing files nothing would ever read.
The NetHunter userspace side is brought up by the NetHunter app + Magisk, not
from the ramdisk - see "The boot ramdisk here is generic (GKI-style)".

To recover: `fastboot flash boot_a boot-stock.img` (`boot_b` for the other slot)

---

## Verifying

```bash
adb shell uname -r                     # must equal STOCK_RELEASE if vendor modules are kept
adb shell cat /proc/version
adb shell 'strings /vendor/lib/modules/mmi_charger.ko | grep vermagic'   # must show the same string
adb shell 'zcat /proc/config.gz | grep -E "CONFIG_(IP_SET|CAN|NFSD|RT2800USB|ATH9K_HTC|MT76x0U|USB_SERIAL)="'
adb shell dmesg | grep -iE "version magic|disagrees about version|Unknown symbol"
adb shell ls /vendor/lib/modules | head    # 82 modules on the stock LineageOS build
```

Expected `dmesg` output when the release string or a CRC does not match
(and the corresponding feature dies):

```
wlan: version magic '5.4.302-NetHunter-milanf ...' should be '5.4.302-moto-gc8bc4b74db62 ...'
```

---

## Verified on device (2026-09-19)

Flashed with `adb sideload` and booted. Results:

| Check | Result |
|---|---|
| Kernel really running | `/proc/version` -> `5.4.302-moto-gc8bc4b74db62`, built `Sat Sep 19 18:25:58 EDT 2026`, clang 21 (stock build was Sep 17) |
| Modules loaded | 76 in `/proc/modules`, incl. `wlan` (9.3 MB), `mmi_charger`, `aw882xx_acf`, `nova_0flash_mmi`, `zram`, `lzo` |
| ABI errors | none - no `disagrees about version of symbol` / `version magic` in the kernel log |
| Internal Wi-Fi | `wlan0` UP / LOWER_UP, reporting signal strength |
| Rollback | `output/boot-stock-milanf.img` -> `fastboot flash boot ...` |

Those modules are exactly the ones that failed CRC verification in earlier
builds, so this is the end-to-end proof that keeping the ROM's exact config for
shared headers was the right fix.

### The boot ramdisk here is generic (GKI-style)

Unpacking the stock boot image shows:

```
header v3, kernel 39328256 B, ramdisk 19452257 B (lz4)
contains        : init, first_stage_ramdisk/, .backup/.magisk, init.recovery.qcom.rc, ...
does NOT contain: init.rc, ueventd.rc
```

So there is **no `init.rc` to hook `import /init.nethunter.rc` into** and no
`ueventd.rc` to add `/dev/hidg*` rules to - the real ones live on the
system/vendor partitions (`/system/etc/ueventd.rc`,
`/vendor/etc/ueventd.rc`). `anykernel.sh` detects this and reports it instead of
"installing" files nothing would ever read; the ramdisk hooks still run on
non-GKI layouts where `init.rc` is present.

This is not a limitation: the kernel already provides
`CONFIG_USB_CONFIGFS_F_HID`, ipset and the external Wi-Fi drivers, and on this
device the Kali chroot and HID gadget are brought up by the **NetHunter app +
Magisk** (Magisk is installed - see `.backup/.magisk`; `/data/local/nhsystem`
already exists).

If you want `/dev/hidg*` world-writable without relying on the app's root shell,
add a Magisk hook yourself (the zip deliberately does not modify your system):

```bash
adb shell 'mkdir -p /data/adb/post-fs-data.d'
adb shell 'printf "#!/system/bin/sh\nfor n in /dev/hidg0 /dev/hidg1 /dev/hidg2; do [ -e \$n ] && chmod 0666 \$n; done\n" > /data/adb/post-fs-data.d/nethunter-hid.sh'
adb shell 'chmod 0755 /data/adb/post-fs-data.d/nethunter-hid.sh'
```

### AnyKernel3 gotcha: the variables are UPPERCASE

`anykernel/anykernel.sh` must use `BLOCK`, `IS_SLOT_DEVICE`,
`RAMDISK_COMPRESSION`, `PATCH_VBMETA_FLAG` and `$AKHOME` / `$RAMDISK`. The older
lowercase names (`block=`, `is_slot_device=`, `$home`, `$ramdisk`) are silently
ignored by the current AK3 core: in recovery that yields
`Unable to determine  partition. Aborting...`, and it would otherwise flash a
"successful" kernel with none of the ramdisk changes applied.

---

## External Wi-Fi adapters

Enabled in this kernel (in-tree, built-in):

| Adapter / chipset | Driver |
|---|---|
| Alfa AWUS036NH, AWUS036NHA, AWUS036H, Panda PAU05/PAU06/PAU09, RT5370/RT5572/RT3070 sticks | `rt2800usb` |
| Alfa AWUS036NHA (AR9271), TP-Link TL-WN722N v1 | `ath9k_htc` |
| Alfa AWUS036ACHM, Archer T2U Plus/T3U (MT7610U/MT7612U) | `mt76x0u`, `mt76x2u` |
| RTL8188EU/8192CU/8723/8821 sticks | `rtl8192cu`, `rtl8xxxu` (see note) |
| RTL8188EU-class dongles | `rtl8xxxu` (`CONFIG_RTL8XXXU_UNTESTED=y`) |

`config/nethunter-docs.fragment` (Path B only) adds the rest of the documented
adapters: `carl9170` (Atheros AR9170), `ath6kl_usb`, `mt7601u` (very common cheap
stick), `rt2500usb`, `rt73usb`, `zd1211rw`, `usb_zd1201` and `rndis_wlan` - and
the whole SDR block, so an RTL2832U stick shows up as `/dev/swradio0`
(`rtl_test`, `gqrx`, RF Analyzer) with the R820T tuner, and HackRF / Airspy /
Mirics MSi2500 are supported as well.

> `r8188eu` (the staging driver for very cheap 8188EU sticks) is **not** enabled:
> its Kconfig says `depends on m`, so it can only ever be a module, and this
> kernel ships no modules next to the ROM's. `rtl8xxxu` covers the same
> RTL8188EU/8192EU/8723BU class and *can* be built-in.

Not supported out of the box:

| Adapter | Why |
|---|---|
| Alfa AWUS036ACH / AWUS036ACS (RTL8812AU/8821AU) | needs the out-of-tree `88XXAU` driver: build it as an external module against this kernel **and** ship it in a repacked `vendor_boot.img` (or every module, see above) |

All of these need `CONFIG_CFG80211_WEXT` only for very old tooling
(`iwconfig`); modern `iw`, `aircrack-ng`, `bettercap`, `kismet` use nl80211 and
work with what is enabled here.

### Optional: injection on the *built-in* Wi-Fi (`PATCH_INJECT=1`)

This is built and tested against the ROM above -
**`lineage-23.2-20260917-nightly-milanf-signed.zip` is required**, because the
patched `wlan.ko` must be loaded against exactly this kernel's symbol CRCs (a
different build means a different source commit and the module set has to be
rebuilt).

NetHunter's `add-qcacld-3.0-injection-5.4.patch` **does** apply to this tree, and
Path B is what makes it usable - the patched `wlan.ko` is simply part of the
module set we ship in `vendor_boot`:

```sh
PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh build     # patches + compiles
PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh payload   # patched wlan.ko in vendor_boot
```

`patches/inject/` holds the vendored upstream patch plus `porting.patch` - the
**3 lines** it needs to compile here:

| File | Fix |
|---|---|
| `core/wma/src/wma_utils.c` | the hunk's `struct del_bss_resp *resp;` declaration landed in `wma_mon_mlme_vdev_stop_send` while its *use* landed in the twin function `wma_mon_mlme_vdev_down_send` -> move the declaration into the function that uses it |
| `core/wma/src/wma_frame_inject.c` (2 sites) | `vstart.channel.phy_mode` is `enum wlan_phymode` here, so use this tree's `WLAN_PHYMODE_11G`/`_11A` instead of the WMI constants (**a blind cast would be wrong**: WMI `MODE_11G` = 2, `WLAN_PHYMODE_11G` = 3) |

Verified here: with those applied the driver compiles and links - the shipped
module is `wlan.ko`, **13,401,936 B** stripped and `nm` still shows all nine
injection symbols (`hdd_init_frame_injection`, `hdd_frame_inject_enable/_disable/
_ioctl/_netlink`, plus their CFI jump tables), against **13,244,072 B and zero**
in the unpatched build. The build is idempotent and every other module keeps its
CRCs.

**`PATCH_INJECT` describes the source tree, not just the run.** The patch edits
`drivers/staging/qcacld-3.0` and `qca-wifi-host-cmn` in place and nothing reverts
it, so building with `PATCH_INJECT=0` on a tree that is still patched would ship a
patched `wlan.ko` under an "unpatched" name - and a rollback image built that way
could not roll anything back (this really happened while testing the patch). The
build driver therefore refuses that build:

```
[ fail ] the kernel tree still contains the injection patch, but PATCH_INJECT=0.
[ fail ] Refusing to build: the payload would be called 'unpatched' while wlan.ko is patched,
[ fail ] so a rollback image built this way could not roll anything back.
[ fail ] Revert the two staging trees (only those two directories are touched):
[ fail ]   git -C "<kernel>" reset -q
[ fail ]   git -C "<kernel>" checkout -- .
[ fail ]   git -C "<kernel>" clean -fdq drivers/staging/qcacld-3.0 drivers/staging/qca-wifi-host-cmn
[ fail ] or re-run with PATCH_INJECT=1, or NH_KEEP_INJECT=1 to build the tree as it is.
```

So the two payloads have to be built in this order, and the images should be kept
under separate names (`vendor_boot-pathb-milanf.img` is simply the newest build and
gets overwritten):

```sh
# unpatched first, from the pristine tree - this is the rollback
PATH_B=1 ./build-nethunter-kernel.sh build && PATH_B=1 ./build-nethunter-kernel.sh payload
cp output/vendor_boot-pathb-milanf.img output/vendor_boot-pathb-nopatch.img

# then patched (the driver applies the patches itself)
PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh build && PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh payload
cp output/vendor_boot-pathb-milanf.img output/vendor_boot-pathb-patched.img
```

Monitor mode is then driven with standard tools - `svc wifi disable`,
then `iw phy phy0 interface add mon0 type monitor` (the patch also adds a WEXT
monitor-frequency handler, which is exactly why Path B's `CFG80211_WEXT=y`
matters) - while injection goes through QCA vendor subcommands
`FRAME_INJECT`/`_STATS`/`_RESET` (200/201/202) or a private IOCTL. Neither
NetHunter nor this repo ships a userspace injector for those.

**Verified on device (2026-09-19).** Injection works from the ordinary STA
interface - monitor mode is *not* required (`require_monitor_mode = 0`). Userspace
-> private IOCTL -> frame validation -> WMA -> firmware is confirmed in the kernel
log, with the exact bytes handed over (see the log below). **Still unverified:**
whether the firmware radiates the injected frame *in monitor mode*, and how
Android's WLAN HAL reacts to `con_mode=4`; checking the air would need a second
radio. Full story: `patches/inject/README.md`.

Three control surfaces exist:

| Surface | How |
|---|---|
| private IOCTL | `SIOCDEVPRIVATE+10` on the netdev with `struct hdd_frame_inject_ioctl` - `tools/inject-ioctl.py` |
| QCA vendor subcmds | `QCA_NL80211_VENDOR_SUBCMD_FRAME_INJECT` / `_STATS` / `_RESET` = 200/201/202, same handlers as the generic-netlink family `hdd_frame_inject` |
| sysfs | `/sys/kernel/frame_injection/` - `global_enable`, `require_monitor_mode`, `debug_level`, `max_frame_rate`, `max_frame_size`, `max_queue_size`, `rate_window_ms` |

```sh
# 1. keep the rollback image next to the patched one. The unpatched payload must
#    come from a pristine kernel tree - the build driver refuses PATCH_INJECT=0
#    while the patch is still in the source (see the guard below), precisely so
#    this file cannot lie about what it contains
ls -l output/vendor_boot-pathb-nopatch.img output/vendor_boot-pathb-patched.img
#    patched:   wlan.ko 13401936 B, 9 frame_inject symbols
#    unpatched: wlan.ko 13244072 B, 0

# 2. flash the patched payload and reboot (slot _a on this device). The kernel
#    Image is identical in both payloads - only the module changes
adb push output/vendor_boot-pathb-patched.img /sdcard/
adb shell su -c 'dd if=/sdcard/vendor_boot-pathb-patched.img of=/dev/block/bootdevice/by-name/vendor_boot_a'
adb reboot

# 3. is the patched driver the one running?
adb shell su -c 'grep -cE "hdd_.*frame_inject" /proc/kallsyms'   # expect 9

# 4. inject a broadcast PROBE REQUEST (what an AP scan already sends).
#    No association, no deauth, nothing aimed at a network
adb push tools/inject-ioctl.py /data/local/tmp/
adb shell su -c 'C=/data/local/nhsystem/kali-arm64; cp /data/local/tmp/inject-ioctl.py $C/tmp/'
adb shell su -c 'echo 5 > /sys/kernel/frame_injection/debug_level'
adb shell su -c 'chroot /data/local/nhsystem/kali-arm64 /usr/bin/python3 /tmp/inject-ioctl.py wlan0 probe'

# 5. the driver's own confirmation (dmesg is short here, so capture it while injecting)
adb shell su -c 'timeout 30 cat /dev/kmsg | grep -i inject'
adb shell su -c 'echo 3 > /sys/kernel/frame_injection/debug_level'
```

A working injection reaches the firmware TX API - this is the actual log from the
test on this device:

```
wlan: [I:HDD] __hdd_ioctl: Processing frame injection ioctl: 0x89fa
wlan: [I:HDD] hdd_frame_inject_ioctl: Frame injection IOCTL called: cmd=0x89fa
wlan: [I:WMA] wma_send_injection_frame_to_fw: Injection frame[2]: desc_id=8193 vdev=0
             len=32 fc_type=0x00 fc_subtype=0x40 tx_chanfreq=5785 cmd_chanfreq=0
             addr1=ff:ff:ff:ff:ff:ff addr2=02:00:00:11:22:33 addr3=ff:ff:ff:ff:ff:ff
wlan: [I:HDD] hdd_frame_inject_ioctl: Frame injection IOCTL completed successfully
```

`tx_chanfreq` is the channel the frame goes out on; with `cmd_chanfreq = 0` the
driver uses whatever channel the STA is already on (5785 = ch149 here), so to
inject on a chosen channel either associate there or set the channel field. From
the IOCTL: `EOPNOTSUPP` (95) = no injection context for that adapter, `EINVAL`
(22) = bad length or a frame the validator rejected.

**What is safe to inject from an associated interface (measured).** A broadcast
probe request is harmless: after one, the link was polled every 5 s for 90 s and
stayed `UP` on its address the whole time (and the association also survived it on
two earlier runs). A **beacon** is not: injected from the associated STA interface
the link went down within ~20 s (`wlan0 DOWN`, supplicant `DISCONNECTED`) and it did
not come back on its own - `wpa_cli reconnect` on the supplicant socket timed out,
so only a reboot restored Wi-Fi. Frames that do not impersonate an AP (probe
requests, and the raw-TX of normal tooling) are fine on the STA interface; anything
that looks like an AP (beacon, probe response) belongs on a monitor/AP interface,
which is what `con_mode=4` is for - and there is no association to lose there.
`tools/inject-selftest.sh` injects a probe only unless you pass `--beacon`.

**Do not use `svc wifi disable` on Path B.** It unloads the driver; the reload
then picks up the ROM's own `/vendor/lib/modules/wlan.ko`, and this kernel rejects
it (`wlan: disagrees about version of symbol module_layout`), so Wi-Fi does not
come back until a reboot. That is Path B working as designed (ROM modules cannot
match our kernel) - it just makes that one command fatal. If you want monitor
mode, use the driver's own parameter instead:

```sh
adb shell su -c 'echo 4 > /sys/module/wlan/parameters/con_mode'   # monitor only
adb shell su -c 'iwpriv wlan0 setMonChan 6 0'                     # pick a channel
adb shell su -c 'tcpdump -i wlan0 -c 10 -e'                       # RX in monitor mode
adb shell su -c 'echo 0 > /sys/module/wlan/parameters/con_mode'   # back to STA
```

`con_mode` is a writable module parameter (STA = 0, monitor = 4) and
`hdd_enable_monitor_mode()` is what creates the injection context for a monitor
adapter. Note the driver's WEXT has `standard = NULL`: `iwconfig wlan0 mode
monitor` can never work on this tree, and `iw phy phy0 interface add mon0 type
monitor` returns EINVAL - only the private commands (`iwpriv`) and `con_mode`
switch modes. If a monitor-mode experiment does leave Wi-Fi down,
`echo 0 > /sys/module/wlan/parameters/con_mode` (or a reboot) is the way back.

If everything else fails, one dd + reboot restores the unpatched Path B kernel and
modules - Wi-Fi comes back with all NetHunter features intact:

```sh
adb shell su -c 'dd if=/sdcard/vendor_boot-pathb-nopatch.img of=/dev/block/bootdevice/by-name/vendor_boot_a'
adb reboot
```

---

## Known limitations

* **Four ROM modules never load**: `silead_fps_mmi`, `rbs_fps_mmi` (fingerprint)
  and `rmnet_offload`, `rmnet_shs` (data offload). They are built and staged but do
  not show up in `/proc/modules`; the fingerprint HAL still reports its provider
  and data/Wi-Fi are unaffected, so this was left for a later day.
* **Built-in Wi-Fi injection** exists only as the opt-in `PATCH_INJECT=1` patch set
  (`patches/inject/`) and is **not verified on hardware** - it compiles, links and
  keeps every other module's CRCs, but whether this phone's firmware accepts TX in
  monitor mode can only be answered by testing. The external-adapter path is the
  tested one.
* **zRAM/swap is off under Path B**: the payload copies the ROM's own
  `modules.load` verbatim (72 modules, ROM order, `mmi_charger` last) and that list
  contains neither `zram` nor `lzo*`. Adding them is possible - the `.ko` files are
  in the ramdisk - but it means touching the charging-chain load order that is
  currently proven, so it was left alone.
* **USB host (OTG) mode is unavailable** while the `magisk/` device-mode fix is
  installed, and that fix masks the vendor handshake rather than repairing it (the
  extcons still report `USB=0`; the charger's BC1.2 detection returning `Unknown`
  is the first broken link and was not tracked down).
* **Anything that needs a dongle is untested**: Wi-Fi injection/monitor mode, SDR
  capture, BT Arsenal adapters and EvilTwin were verified at the driver and config
  level only - there is no external adapter here to test with.
* **`CONFIG_IP_NF_TARGET_NATTYPE` / `_TRIGGER`** (Qualcomm NAT extras) stay off:
  `ipt_TRIGGER.c` does not compile with this tree's `-Werror,-unused-variable`.

---

## Troubleshooting

**"version magic should be ..." / "disagrees about version of symbol"**
Your kernel release string (or a struct layout) does not match what the ROM's
modules were built for. Rebuild with `STOCK_RELEASE="$(adb shell uname -r)"`. On
**Path A** make sure the fragment does not enable `CFG80211_WEXT` /
`MAC80211_MESH` / `WIRELESS_WDS`; on **Path B** those are enabled on purpose, so
this error there means you flashed only one of the two halves (kernel without the
matching `vendor_boot`, or the other way round). Symptom: boots, but no Wi-Fi /
no touch.

**Kernel panics or does not boot at all**
Almost always a config merge failure. Run `./build-nethunter-kernel.sh config`
and confirm it prints *"base/device options intact"* and that
`out/.config` contains `CONFIG_MILANF_DTB=y`.

**`No rule to make target 'net/netfilter/xt_HL.o'`**
You are building on a case-insensitive filesystem (NTFS/exFAT/APFS). Build on
ext4.

**Build fails in the LTO/CFI link step / OOM**
LTO + CFI needs a lot of RAM. Reduce jobs (`JOBS=4 ./build-nethunter-kernel.sh build`)
or add swap. Do not disable `LTO_CLANG`/`CFI_CLANG` unless you accept a kernel
that differs from the ROM's hardening.

**clang download fails (404 / timeout)**
`clang-r563880c` no longer exists on the AOSP `main` branch; it lives in the
release tag that LineageOS' manifest (`default.xml`, remote `aosp`,
`revision="refs/tags/android-16.0.0_r4"`) pins `prebuilts/clang/host/linux-x86`
to. The script therefore fetches:

```
https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/android-16.0.0_r4/clang-r563880c.tar.gz
```

Overrides: `CLANG_TAG=<tag>` / `CLANG_PREBUILT=<clang-rXXXX>`, or copy a clang
from your own LineageOS tree (`prebuilts/clang/host/linux-x86/clang-<ver>`) to
`toolchains/clang-r563880c`.

**A NetHunter feature is missing despite being in the fragment**
Run the `config` step and look at the "dropped" list: the symbol either does not
exist in 5.4 or one of its dependencies (often `DEBUG_FS`, which is disabled in
the stock config) is not met.

**HID attacks fail even though the kernel supports them**
The kernel side needs no change (`USB_CONFIGFS_F_HID=y` in stock), but
`/dev/hidg*` only appears once a HID *function* is bound to the USB gadget, and
this ROM's init never creates one. Ask NetHunter's own USB Arsenal to do it (it
keeps adb alive):

```bash
su -c 'nohup /data/data/com.offsec.nethunter/scripts/usbarsenal \
        -t win -f adb,hid -v 0x18d1 -p 0x4e11 > /data/local/tmp/usbarsenal.log 2>&1 &'
ls -l /dev/hidg*      # hidg0 = keyboard (proto 1, subclass 1), hidg1 = mouse
```

The script does `echo none > /config/usb_gadget/g1/UDC` and `stop adbd`, so USB
re-enumerates once (~20 s) - run it detached and log to a file. It is **not
persistent**: the USB HAL rebuilds the gadget on reboot, and any change of USB
mode drops it again, so re-run it (or use NetHunter -> USB Arsenal). Check
`adb shell 'getenforce'` too - NetHunter needs root.

---

## Repository layout

```
build-nethunter-kernel.sh          build driver (doctor/toolchains/source/config/build/modules/payload/verify/zip/clean)
config/nethunter_milanf.fragment   NetHunter config fragment (merged on top of LineageOS)
config/pathb.fragment              Path B overlay: the CRC-sensitive options (CAN, bridge netfilter, xt_REALM/CONNLABEL)
config/nethunter-docs.fragment     docs parity: SDR/RTL-SDR, extra Wi-Fi + BT dongles, WEXT/mesh, SYSVIPC, CAN extras
config/local.config                variables for Kali's optional kernel-builder (not used here)
patches/inject/                    opt-in: NetHunter's qcacld injection patch + our 3-line porting fix
                                   (applied with PATCH_INJECT=1, see its README)
anykernel/anykernel.sh             AnyKernel3 script with NetHunter additions
anykernel/ramdisk-patch/           ramdisk files for non-GKI layouts (a no-op on this device)
anykernel/ak_patches/              extra shell snippets run by anykernel.sh
magisk/                            Magisk hooks for the USB device-mode fix (post-fs-data + service half)
tools/verify-module-crc.sh         compares the ROM's modules against a freshly built Module.symvers
tools/vendor-boot.py               inspect / unpack / repack vendor_boot.img (Path B module delivery)
tools/extract-ramdisk.py           helper for pulling a ramdisk out of a boot/vendor_boot image
tools/baseline-build.sh            "is the CRC mismatch our fault?" experiment (ROM config verbatim)
tools/inject-selftest.sh           on-device test for the patched injection (probe request; driver log as proof)
tools/inject-ioctl.py              userspace client for the patch's SIOCDEVPRIVATE+10 inject IOCTL
requirements.sh                    apt packages for the build host
devices.yml                        entry for the NetHunter installer registry
LICENSE                            GPL-2.0
kernel/                            LineageOS kernel source (cloned, gitignored)
anykernel3/                        official AnyKernel3 (cloned, gitignored)
toolchains/                        AOSP clang prebuilt (downloaded, gitignored)
output/                            build logs, built modules, images, flashable zip (gitignored)
```

## Resources

* Kali NetHunter docs - <https://www.kali.org/docs/nethunter/>
* LineageOS device wiki - <https://wiki.lineageos.org/devices/milanf/>
* Kernel source - <https://github.com/TigerClips1/kali-nethunter-milanf-kernel> (`nethunter`)
* Device tree - <https://github.com/LineageOS/android_device_motorola_milanf>
* AnyKernel3 - <https://github.com/osm0sis/AnyKernel3>

---

## License

GPL-2.0 - see [`LICENSE`](LICENSE). The kernel this builds is the Linux kernel
(LineageOS' `lineage-23.2` branch, GPL-2.0), and AnyKernel3 is fetched at build
time under its own license.
