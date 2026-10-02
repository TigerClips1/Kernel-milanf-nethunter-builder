<h1 align="center">Kali_nethunter kernel builder</h1>
<p align="center"><i>NetHunter Kernel for Motorola Moto G Stylus 5G 2022 (milanf)</i></p>

<p align="center">
  <img src="https://img.shields.io/badge/kernel-5.4.302-blue?style=flat-square" alt="Kernel" />
  <img src="https://img.shields.io/badge/Android-16-green?style=flat-square" alt="Android" />
  <img src="https://img.shields.io/badge/external%20WiFi%20modules-included-success?style=flat-square" alt="External WiFi modules" />
</p>

> **Device:** milanf
> **SoC:** Snapdragon 695 5G (SM6375)
> **Kernel:** 5.4.302 (nethunter-milanf)
> **Tested ROM:** lineage-23.2-20260917-nightly

This repo builds a Kali NetHunter-style kernel for the `milanf` device using the Motorola 5.4 QGKI base, custom NetHunter config fragments, and a vendor-boot repack flow designed for flashing alongside a matching LineageOS install.

---

## Features

### WiFi & Injection
- External USB WiFi adapter support through the included RTL8188EUS and RTL88x2BU modules
- mac80211 injection support for compatible external adapters
- Internal `wlan0` monitor mode and injection are not enabled by this port; the Motorola qcacld driver in this LineageOS tree does not expose the required monitor-mode controls
- Monitor channel change without restrictions (cfg80211 patch)
- Custom kernel release with the rebuilt module set preloaded from a matching vendor_boot image
- RTL8188EU driver — TL-WN722N v2/v3 (RTL8188EUS)
- RTL88x2BU driver — AC1200 dual-band adapters
- External USB WiFi adapter support

### Kernel
- Loadable kernel module support (.ko)
- USB HID gadget — BadUSB ready
- USB configfs: RNDIS / CDC-ECM
- KernelSU service recovers the milanf DWC3 peripheral role when a data cable is connected and Android has selected a USB data function
- Netfilter / iptables / ip6tables
- Bluetooth attack support + external BT adapter (hcibtusb)
- LTO Clang ThinLTO
- Built-in root via KernelSU Next's legacy driver for this Linux 5.4 kernel

### CAN, SDR & NFS
- SocketCAN protocols and virtual/serial CAN interfaces, with in-tree USB, SPI, and platform controller drivers configured as modules
- HLCAN USB analyzer and CAN ISO-TP are integrated as optional modules; the packaging step adds them to the vendor module load list when built
- SDR support for AirSpy, HackRF, Mirics MSi2500, and RTL2832U-based receivers
- NFS client support for v2/v3/v4 and NFS server support for v3/v4

---

## Build

### Requirements
- Ubuntu 22.04+ (or Docker)
- LineageOS clang `clang-r563880c` (Clang 21), selected automatically from `LINEAGEOS_ROOT`; the bundled AOSP compiler is used when that checkout is unavailable
- binutils-aarch64-linux-gnu
- Internet access when source trees, KernelSU Next, toolchains, or driver sources need downloading

### Quick start
```bash
git clone https://github.com/TigerClips1/Kernel-milanf-nethunter-builder.git
cd Kernel-milanf-nethunter-builder
bash build.sh
# ZIP → out/zip/<zipname>.zip
```

The scripts resolve paths from the repo root rather than the current shell directory, so they can be launched from any `$PWD` with an absolute path:

```bash
bash /path/to/Kernel-milanf-nethunter-builder/build.sh
```

### Build options
```bash
bash build.sh                    # full build with KernelSU Next
bash build.sh --step=configure   # integrate KernelSU Next + configure
bash build.sh --step=compile     # configure and compile
bash build.sh --step=package     # configure, compile, and package
bash build.sh --clean            # clear completion markers to force steps to run again
```

The full build runs these stages in order:

1. Install/check host build dependencies and select or download Clang 21.
2. Fetch the kernel, toolchain, AnyKernel3, Realtek driver sources, and CAN driver submodules; stage the CAN-ISOTP UAPI header.
3. Apply the kernel and QCACLD compatibility/injection patches.
4. Fetch and integrate the pinned KernelSU Next revision; verify the out-of-tree Realtek sources.
5. Merge the device config with the NetHunter and KernelSU fragments, then resolve Kconfig dependencies.
6. Build the kernel and in-tree modules, then build RTL8188EUS and RTL88x2BU out-of-tree.
7. Reinstall modules, repack `vendor_boot.img` (step 08), and create the flashable AnyKernel ZIP.

The `--step` shortcuts do not run the initial environment, source-clone, or
patch stages; use them only when those inputs are already prepared. `--clean`
removes completion markers and the cached KernelSU mode, but does not directly
delete downloaded sources or `out/` files. A normal full build may re-clone the
kernel source; set `SKIP_CLONE=1` to reuse existing source checkouts.

The final ZIP and `vendor_boot-nethunter-milanf.img` are written to `out/zip/`.
The main build log is `out/build-main.log`; kernel and external-driver logs are
written under `out/` as well.

### GitHub CI and releases
Every branch push and pull request runs validation checks for shell and Python
syntax, duplicate active assignments within each config file, patch-file
format, and the required boot images. A successful validation is followed by a
full kernel build. The Actions run also keeps the flashable ZIP and checksum as
a 30-day build artifact.

Push a version tag such as `v1.0.0` to build the flashable ZIP from that tag's
commit and publish it, with `SHA256SUMS`, in GitHub Releases:

```bash
git tag v1.0.0
git push origin v1.0.0
```

You can also run **Build NetHunter kernel** from the Actions tab. Leave
`release_tag` empty to keep the build as an Actions artifact, or enter an
existing tag to build and publish that tag. The boot and vendor_boot images
used by packaging are tracked under `Required_los_image-nethunter/`; no
repository secrets are currently required.

### Environment variables
| Variable | Default | Description |
|---|---|---|
| `SKIP_CLONE` | `` | Set to skip re-cloning repos |
| `KERNEL_BRANCH` | `nethunter` | Preferred kernel source branch; the clone script tries its fallback branches if needed |
| `LINEAGEOS_ROOT` | `/mnt/steamgames/Games/los/android/lineage` | LineageOS checkout used to select the matching compiler |
| `DEVICE_CONFIG` | `config/milanf_device.config` | Running-device kernel config used as the build baseline when present |
| `STOCK_BOOT_IMAGE` | repo-local `Required_los_image-nethunter/boot.img` | Matching LineageOS milanf `boot.img` used to preserve the Android ramdisk instead of a recovery ramdisk |
| `STOCK_VENDOR_BOOT_IMAGE` | repo-local `Required_los_image-nethunter/vendor_boot.img` | Matching stock vendor_boot v3 image used as the header and DTB base |
| `STOCK_VENDOR_MODULES_LOAD` | `out/vendor-repack/vendor-tree/modules/modules.load` | Ordered module list from the matching ROM's `/vendor/lib/modules/modules.load` |
| `JOBS` | `$(nproc)` | Parallel jobs |

Build with the boot image extracted from the same LineageOS build installed on
the phone. Do not use a TWRP boot image:

```bash
STOCK_BOOT_IMAGE=/path/to/matching/LineageOS/boot.img \
STOCK_VENDOR_BOOT_IMAGE=/path/to/matching/LineageOS/vendor_boot.img \
bash build.sh --step=package
```

The package step emits a custom vendor-boot image under `out/zip/` and bundles
it into the AnyKernel ZIP. The installer flashes it to the same verified slot
as the kernel. It replaces the stock first-stage ramdisk modules with the
rebuilt module set, keeps the ROM's module load order when present, and
preserves the stock v3 header and DTB. If the ROM's modules.load file is not
already available, the repack step automatically generates a fallback module
list from the rebuilt vendor tree and prints a warning. For a perfect stock
order, pull `/vendor/lib/modules/modules.load` from the matching ROM and set
`STOCK_VENDOR_MODULES_LOAD` to that file.

---

## Root

This device uses Linux 5.4. KernelSU Next requires its driver to be built into
the kernel on this kernel generation, so this build uses the pinned legacy
branch and explicit manual hooks, merged with the Motorola QGKI base and
LineageOS milanf vendor fragments.
Install the matching KernelSU Next Manager app after the ROM boots; root is
provided by the kernel.

The ZIP also installs RTL8188EUS and RTL88x2BU as a KernelSU Next module when
TWRP has decrypted `/data`. If `/data` is encrypted or unavailable in recovery,
install the bundled `ksu_module` directory through KernelSU Next Manager after
Android starts. The drivers do not load during boot; after Android starts,
use the module's action in KernelSU Next Manager to load them on demand.

## Flash

The installer repacks the matching clean LineageOS boot image and always
targets `boot_b` plus `vendor_boot_b`, regardless of the slot TWRP reports. It
checks that both B partitions exist and that the vendor_boot image fits before
flashing either one. After flashing, ensure slot B is selected for the next
boot; the installer does not choose the active slot for you.

1. Boot into TWRP
2. Install → select ZIP → Swipe to Flash. The installer writes the paired kernel and vendor_boot to slot B.
3. Reboot System and install/open KernelSU Next Manager

The custom kernel and vendor_boot image must be flashed as a pair. The
repackaged vendor_boot has no stock AVB footer; use the already-unlocked
bootloader and verification-disabled setup used for this device.

```bash
adb push out/zip/LineageOS_milanf-By_Community.NH_LineageOS-23.2.KernelSU-Next.*.zip /sdcard/Download/
adb reboot recovery
```

---

## Verify after flash

```bash
# Check built-in KernelSU Next root
su -c id

# Load the NetHunter Realtek Drivers action in KernelSU Next Manager first,
# then connect a supported USB Wi-Fi adapter and check its interface.
iwconfig   # wlan2 present

# Monitor mode
ip link set wlan2 down
iw dev wlan2 set type monitor
ip link set wlan2 up
iw dev wlan2 info   # type: monitor

# Injection test (requires aircrack-ng)
aireplay-ng --test wlan2
# Expected: "Injection is working!"
```

---

## Credits

- [TigerClips1](https://github.com/TigerClips1/kali-nethunter-milanf-kernel) — kernel base (milanf)
- [osm0sis](https://github.com/osm0sis/AnyKernel3) — AnyKernel3
- [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next) — built-in legacy kernel root support
- [kimocoder](https://github.com/aircrack-ng) — qcacld-3.0 packet injection upstream
- **Loukious** — co-author of the base injection patch
- **Madara273** — qcacld-3.0 5.4.302 port and ABI fixes
- **dr_rootsu, cyberknight777, HelloWorld, Robin, starsea** — debugging in the QCACLD-3 Telegram group
- [aircrack-ng](https://github.com/aircrack-ng/rtl8188eus) — RTL8188EUS driver
- [RinCat](https://github.com/RinCat/RTL88x2BU-Linux-Driver) — RTL88x2BU driver
- Kali NetHunter team — mac80211 injection patch

---

## License

GPL-2.0 — see [LICENSE](LICENSE)
