#!/usr/bin/env python3
# =============================================================================
#  inject-ioctl.py - send a frame through the patched qcacld frame injector
#
#  The PATCH_INJECT=1 driver adds a private IOCTL on the WLAN netdev:
#
#     SIOCDEVPRIVATE + 10      (0x89FA)
#     struct hdd_frame_inject_ioctl {
#         uint32_t cmd;          /* unused by the driver, pass 0            */
#         uint32_t frame_len;    /* 1..2304 (HDD_FRAME_INJECT_MAX_SIZE)     */
#         uint8_t *frame_data;   /* raw 802.11 frame, no radiotap           */
#         uint32_t tx_flags;
#         uint8_t  retry_count;
#         uint32_t tx_rate;      /* 0 = driver default                      */
#     };
#
#  Returns 0 when the frame was handed to the firmware. Typical failures:
#     EOPNOTSUPP (95) - adapter->injection_ctx is NULL: injection is not
#                       initialised for that interface yet. On this driver it
#                       is created when monitor mode is switched on
#                       (con_mode=4 -> hdd_enable_monitor_mode()), or on
#                       adapters whose injection context the patch hooks up.
#     EINVAL     (22) - bad length, or the frame failed validation
#     EPERM      (1)  - the injection security context denied the request
#
#  Run it from the Kali chroot (python3 there, and it shares the netns):
#     cp /data/local/tmp/inject-ioctl.py $CHROOT/tmp/ && chroot $CHROOT \
#         /usr/bin/python3 /tmp/inject-ioctl.py wlan0
#
#  Requires the PATCH_INJECT=1 + PATH_B=1 build to be flashed on
#  `lineage-23.2-20260917-nightly-milanf-signed.zip` - that LineageOS nightly is
#  required, because the patched wlan.ko must match that kernel's symbol CRCs.
#
#  TRAFFIC: default frame is a broadcast PROBE REQUEST (what an AP scan sends).
#
#  WARNING about `beacon`: measured on this device (2026-09-19), a probe request is
#  harmless - the association survives it. A beacon injected from the *associated*
#  STA interface is not: the link went down ~20 s later and Android's supplicant
#  never recovered (wpa_cli times out; only a reboot brings Wi-Fi back). Frames
#  that impersonate an AP belong on a monitor/AP interface (see con_mode), not on
#  the interface you are associated with.
# =============================================================================

import ctypes
import fcntl
import socket
import sys

SIOCDEVPRIVATE = 0x89F0
FRAME_INJECT = SIOCDEVPRIVATE + 10
IFNAMSIZ = 16


class HddFrameInjectIoctl(ctypes.Structure):
    _fields_ = [
        ("cmd", ctypes.c_uint32),
        ("frame_len", ctypes.c_uint32),
        ("frame_data", ctypes.POINTER(ctypes.c_uint8)),
        ("tx_flags", ctypes.c_uint32),
        ("retry_count", ctypes.c_uint8),
        ("tx_rate", ctypes.c_uint32),
    ]


def mac(text):
    parts = text.split(":")
    if len(parts) != 6:
        raise ValueError("MAC must be aa:bb:cc:dd:ee:ff")
    return bytes(int(p, 16) for p in parts)


def probe_request(src="02:00:00:11:22:33", ssid=b""):
    """Broadcast probe request: what every AP scan transmits."""
    f = bytearray()
    f += b"\x40\x00"          # frame control: probe request
    f += b"\x00\x00"          # duration
    f += b"\xff" * 6          # DA: broadcast
    f += mac(src)             # SA
    f += b"\xff" * 6          # BSSID: broadcast
    f += b"\x00\x00"          # sequence control
    f += bytes([0x00, len(ssid)]) + ssid          # SSID (wildcard by default)
    f += bytes([0x01, 0x04, 0x02, 0x04, 0x0B, 0x16])  # supported rates
    return bytes(f)


def beacon(src="02:00:00:11:22:33"):
    """Minimal beacon frame - the frame the driver's own self-test uses."""
    f = bytearray()
    f += b"\x80\x00"          # frame control: beacon
    f += b"\x00\x00"          # duration
    f += b"\xff" * 6          # DA: broadcast
    f += mac(src)             # SA
    f += mac(src)             # BSSID
    f += b"\x00\x00"          # sequence control
    f += b"\x00" * 8          # timestamp
    f += b"\x64\x00"          # beacon interval
    f += b"\x00\x00"          # capability
    f += bytes([0x00, 0x00])  # SSID (empty)
    f += bytes([0x01, 0x04, 0x02, 0x04, 0x0B, 0x16])
    return bytes(f)


def main():
    ifname = sys.argv[1] if len(sys.argv) > 1 else "wlan0"
    kind = sys.argv[2] if len(sys.argv) > 2 else "probe"

    frame = beacon() if kind == "beacon" else probe_request()
    print(f"interface : {ifname}")
    if kind == "beacon":
        print("WARNING   : beacon injection on an associated interface has been")
        print("            observed to drop the Wi-Fi link within ~20 s (reboot needed)")
    print(f"frame     : {kind}, {len(frame)} bytes")
    print("            " + " ".join(f"{b:02x}" for b in frame))

    frame_buf = ctypes.create_string_buffer(frame, len(frame))
    inj = HddFrameInjectIoctl()
    inj.cmd = 0
    inj.frame_len = len(frame)
    inj.frame_data = ctypes.cast(frame_buf, ctypes.POINTER(ctypes.c_uint8))
    inj.tx_flags = 0
    inj.retry_count = 0
    inj.tx_rate = 0

    # struct ifreq: 16-byte name, then the union - ifr_data is the pointer at
    # offset 16 on 64-bit. The driver does copy_from_user(ifr->ifr_data, 32).
    ifreq = ctypes.create_string_buffer(40)
    ifreq[0:len(ifname)] = ifname.encode()
    ptr = ctypes.c_void_p(ctypes.addressof(inj))
    ctypes.memmove(ctypes.addressof(ifreq) + 16, ctypes.byref(ptr), 8)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        fcntl.ioctl(sock.fileno(), FRAME_INJECT, ifreq, True)
    except OSError as exc:
        print(f"result    : FAILED - errno {exc.errno} ({exc.strerror})")
        if exc.errno == 95:
            print("            injection context not initialised for this interface")
        return 1
    finally:
        sock.close()

    print("result    : OK - the frame was submitted to the driver")
    return 0


if __name__ == "__main__":
    sys.exit(main())
