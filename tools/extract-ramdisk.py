#!/usr/bin/env python3
"""Extract the ramdisk from an Android boot image (header v2/v3) for inspection.

Used to verify what AnyKernel3 actually put into the flashed boot partition:
compares the stock image with the one read back from the device.

usage: extract-ramdisk.py <boot.img> [more.img ...]
"""
import struct
import sys

PAGE = 4096


def extract(path):
    with open(path, "rb") as fh:
        d = fh.read()
    if d[:8] != b"ANDROID!":
        print(f"{path}: not an Android boot image (magic {d[:8]!r})")
        return None
    kernel_size, ramdisk_size = struct.unpack_from("<II", d, 8)
    header_version = struct.unpack_from("<I", d, 40)[0]
    cmdline = d[44:44 + 512].split(b"\0")[0]
    print(f"{path}")
    print(f"  header_version : {header_version}")
    print(f"  kernel_size    : {kernel_size}")
    print(f"  ramdisk_size   : {ramdisk_size}")
    print(f"  cmdline        : {cmdline.decode(errors='replace')}")
    ramdisk_off = PAGE + ((kernel_size + PAGE - 1) // PAGE) * PAGE
    rd = d[ramdisk_off:ramdisk_off + ramdisk_size]
    magic = rd[:4]
    names = {
        b"\x02\x21\x4c\x18": "lz4 (frame)",
        b"\x1f\x8b": "gzip",
        b"\x04\x22\x4d\x18": "lz4 legacy",
        b"\xfd7zXZ\x00"[:4]: "xz",
        b"BZh": "bzip2",
        b"070701": "cpio (uncompressed)",
        b"070702": "cpio (uncompressed, crc)",
    }
    print(f"  ramdisk offset : {ramdisk_off}")
    print(f"  ramdisk magic  : {magic.hex()}  ({names.get(magic, 'unknown')})")
    out = path + ".ramdisk"
    with open(out, "wb") as fh:
        fh.write(rd)
    print(f"  wrote {out}")
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for p in sys.argv[1:]:
        extract(p)
        print()
