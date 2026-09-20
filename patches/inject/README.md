# Optional: monitor mode + frame injection on the **built-in** Qualcomm Wi-Fi

Everything in this folder is applied by `PATCH_INJECT=1` and is **opt-in**. It is
the one thing the rest of the project deliberately does *not* do out of the box,
because it patches the Wi-Fi driver instead of just enabling config options.

> **Required ROM:** `lineage-23.2-20260917-nightly-milanf-signed.zip` - the
> LineageOS 23.2 nightly this was built and tested against (kernel release
> `5.4.302-moto-gc8bc4b74db62`, source commit `c8bc4b74db62`). The patched
> `wlan.ko` links against that kernel's symbol CRCs, so on any other build you
> have to rebuild the whole module set (`PATH_B=1 STOCK_RELEASE="$(adb shell
> uname -r)" ./build-nethunter-kernel.sh config` and refresh `KERNEL_COMMIT`) -
> otherwise the driver is rejected at load time.

```sh
PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh build     # applies patches + compiles
PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh payload   # patched wlan.ko into vendor_boot
PATH_B=1 PATCH_INJECT=1 ./build-nethunter-kernel.sh zip       # same kernel, flashable AK3 zip
```

The patches touch only `drivers/staging/qcacld-3.0/` and
`drivers/staging/qca-wifi-host-cmn/`, so the release string, the kernel `Image`
and every other module are byte-for-byte what they were without them. **Path B is
required**: the patched `wlan.ko` has to be delivered through the vendor_boot
ramdisk, which is exactly what Path B does.

## 1. `upstream-add-qcacld-3.0-injection-5.4.patch` (vendored, unmodified)

Kali NetHunter's patch, fetched 2026-09-19 from

<https://gitlab.com/kalilinux/nethunter/build-scripts/kali-nethunter-kernel-builder/-/raw/main/patches/5.4/add-qcacld-3.0-injection-5.4.patch>

GPL-2.0, (c) the NetHunter authors. 462 KB, 13,861 lines, 156 hunks, 45 files
(12 of them new sources such as `wlan_hdd_frame_inject.c` and
`wma_frame_inject.c`), applied with `git apply` and verified to apply cleanly to
this tree (`git apply --check` exits 0).

It builds the feature in **unconditionally** — its own Kbuild hunks set
`CONFIG_FEATURE_MONITOR_MODE_SUPPORT := y` and
`CONFIG_FEATURE_FRAME_INJECTION_SUPPORT := y` — so there is no `.ini` knob to
flip and the read-only `/vendor/etc/wifi/WCNSS_qcom_cfg.ini` is not a blocker.

## 2. `porting.patch` (ours, 3 lines)

What the upstream patch needs to compile on this Motorola tree:

| File | Why |
|---|---|
| `core/wma/src/wma_utils.c` | The upstream hunk declares `struct del_bss_resp *resp;` in `wma_mon_mlme_vdev_stop_send`, but its *use* lands in the twin function `wma_mon_mlme_vdev_down_send` (this tree has both almost identically). With `-Werror` that is "unused variable" in one function and "undeclared identifier" in the other. Fix: move the declaration into the function that uses it. |
| `core/wma/src/wma_frame_inject.c` (2 sites) | `vstart.channel.phy_mode` is `enum wlan_phymode` in this tree, not `WMI_HOST_WLAN_PHY_MODE`. Fix: use this tree's constants (`WLAN_PHYMODE_11G`/`WLAN_PHYMODE_11A`) instead of the WMI ones. **A blind cast would be wrong**: WMI `MODE_11G` is 2 while `WLAN_PHYMODE_11G` is 3 (`wlan_cmn.h`), i.e. a cast would silently select 11b on 2.4 GHz. |

Applied in that order it compiles and links cleanly here (verified:
`drivers/staging/qcacld-3.0/wlan.ko` links, and the module contains
`hdd_frame_inject_ioctl` / `hdd_init_frame_injection`).

## How the feature is driven once flashed

**Verified on this device (2026-09-19) - injection does not need monitor mode.**
`/sys/kernel/frame_injection/require_monitor_mode` is `0`, and the injection
context is created for the ordinary STA adapter too, so a raw frame can be handed
to the firmware straight from `wlan0` through the patch's private IOCTL
(`SIOCDEVPRIVATE+10`, client in `tools/inject-ioctl.py`). The driver then logs
`wma_send_injection_frame_to_fw: Injection frame[...]: len=32 fc_subtype=0x40
tx_chanfreq=5785` - i.e. the frame reached the WMI/firmware TX API with the bytes
userspace supplied.

Two things this driver does **not** accept:

* `iw phy phy0 interface add mon0 type monitor` -> `EINVAL`; the driver has no
  `NL80211_IFTYPE_MONITOR` support in `add_virtual_intf`.
* `iwconfig wlan0 mode monitor` -> `Operation not supported`; qcacld's WEXT has
  `standard = NULL` (only private commands exist: `iwpriv wlan0` lists them, and
  `setMonChan` is there under `FEATURE_MONITOR_MODE_SUPPORT`).

Monitor mode is switched with the driver's own module parameter instead - and
**never** with `svc wifi disable`, which on Path B unloads the driver and then
fails to reload it (the reload picks the ROM's `/vendor/lib/modules/wlan.ko`,
rejected with `disagrees about version of symbol module_layout`), leaving the
phone without Wi-Fi until a reboot:

```sh
su -c 'echo 4 > /sys/module/wlan/parameters/con_mode'   # QDF_GLOBAL_MONITOR_MODE
su -c 'iwpriv wlan0 setMonChan 6 0'                     # channel 6, band 0
su -c 'ifconfig wlan0 up'
su -c 'tcpdump -i wlan0 -w /sdcard/cap.pcap'            # capture (RX)
su -c 'echo 0 > /sys/module/wlan/parameters/con_mode'   # back to STA
```

Injection is exposed as QCA vendor subcommands
(`QCA_NL80211_VENDOR_SUBCMD_FRAME_INJECT` = 200, `_STATS` = 201, `_RESET` = 202,
in `qca-wifi-host-cmn/os_if/linux/qca_vendor.h`) and as a private IOCTL with
`struct hdd_frame_inject_ioctl { cmd, frame_len, frame_data, tx_flags,
retry_count, tx_rate }`. NetHunter ships only the kernel patch, so this repo adds
the missing client: `tools/inject-ioctl.py` (runs under the Kali chroot's python3,
which shares the network namespace). The patch also wires TX on a monitor netdev
through the same injector (`hdd_monitor_mode_tx_inject()` in `ol_txrx.c` /
`wlan_hdd_tx_rx.c`), which is what would let `aireplay-ng`/`mdk4`-style tools work
directly once a monitor interface exists (see `con_mode` above).

## Caveats - read before blaming the build

* **Partially verified live (2026-09-19)**: userspace -> private IOCTL -> frame
  validation -> WMA -> firmware works, confirmed from the kernel log with the
  exact frame bytes (see "How the feature is driven once flashed"). What is *not*
  verified is the air itself: whether the firmware radiates those frames in
  monitor mode, and whether normal raw-TX tools (`aireplay-ng`, `mdk4`) work on a
  `con_mode=4` monitor interface. Checking that needs a second radio.
* Verified **statically** (2026-09-19): the stripped `wlan.ko` inside the patched
  payload is **13,401,936 B** with all nine `frame_inject` symbols present
  (`nm` on the module unpacked from the image), against **13,244,072 B and zero**
  in the unpatched payload. That makes the difference provable without flashing.
* **Injecting a beacon drops the link (measured 2026-09-19).** From the associated
  STA interface a broadcast probe request is harmless - the link held its address
  through a 90 s poll after one - but a beacon took the link down within ~20 s
  (`wlan0 DOWN`, supplicant `DISCONNECTED`) and Android's supplicant never
  recovered from it: `wpa_cli reconnect` on the supplicant socket timed out and
  only a reboot restored Wi-Fi. `tools/inject-selftest.sh` therefore injects a
  probe only (add `--beacon` to see the other case), and `tools/inject-ioctl.py
  beacon` warns first. For real work with AP-like frames, switch to
  `con_mode=4` monitor mode first - there is no association to lose there.
* Expect **Wi-Fi regression risk** - the patch rewrites large parts of the driver.
  The kernel `Image` is identical either way, so only `vendor_boot` changes.
  Roll back with the **unpatched Path B payload**, built from a pristine tree:
  the patch edits `drivers/staging/qcacld-3.0` and `qca-wifi-host-cmn` in place and
  nothing reverts it, so the build driver now **refuses** `PATCH_INJECT=0` while the
  tree is still patched (that combination silently produced a patched module under
  an "unpatched" name, and a rollback image that rolled nothing back):

  ```sh
  git -C <kernel> reset -q && git -C <kernel> checkout -- .
  git -C <kernel> clean -fdq drivers/staging/qcacld-3.0 drivers/staging/qca-wifi-host-cmn
  PATH_B=1 ./build-nethunter-kernel.sh build && PATH_B=1 ./build-nethunter-kernel.sh payload
  ```

  `NH_KEEP_INJECT=1` builds the tree as it is, for when you know what you are doing.
* Android's Wi-Fi HAL must be stopped (`svc wifi disable`) before monitor mode
  behaves, and turning Wi-Fi back on in Settings may reset the interface.
* Only meaningful together with Path B. Path A cannot ship a patched `wlan.ko`
  (its ROM modules would be rejected).
