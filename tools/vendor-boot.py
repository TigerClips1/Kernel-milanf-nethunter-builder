#!/usr/bin/env python3
"""
vendor-boot.py - inspect / unpack / repack an Android vendor_boot image.

Why this exists
---------------
The Moto G Stylus 5G (2022) does NOT keep its modules in a vendor_dlkm
partition: /vendor/lib/modules sits on the "vendor" logical partition inside
super, which is read-only and dm-verity protected. What it DOES have is a
vendor_boot ramdisk that already contains lib/modules/*.ko - first-stage modules
loaded by init before /vendor is even mounted.

Path B builds its own module set (the kernel config changes make the ROM's
prebuilt modules unusable) and ships it through that ramdisk, so the layout of
the vendor_boot image must be reproducible. This tool does the container:
header parsing, section offsets, reassembly; compression/decompression of the
ramdisk is left to lz4/gzip so no Python libraries are needed.

vendor_boot layout, header v3 (used on this device):
    [header 2112 B][pad to page][vendor_ramdisk][pad to page][dtb][pad to page]
v4 adds a vendor ramdisk table + bootconfig after the dtb (not used here).

Usage
-----
    vendor-boot.py info   <img>
    vendor-boot.py unpack <img> <dir>     # dir/ramdisk.raw, dir/dtb.bin, dir/header.json
    vendor-boot.py pack   <dir> <out.img> [--no-pad]
                                          # uses dir/ramdisk.new (already compressed);
                                          # pads over the stale AVB footer by default
"""

import hashlib
import json
import os
import struct
import sys

MAGIC = b"VNDRBOOT"


def align(n, page):
    return (n + page - 1) // page * page


def ramdisk_format(d):
    """Identify the ramdisk container by magic bytes."""
    if d[:2] == b"\x1f\x8b":
        return "gzip"
    if d[:4] == b"\x04\x22\x4d\x18":
        return "lz4"
    if d[:4] == b"\x02\x21\x4c\x18":
        return "lz4-legacy"
    if d[:6] == b"070701" or d[:6] == b"070702":
        return "cpio"
    if d[:6] == b"\xfd7zXZ\x00":
        return "xz"
    return "unknown"


def parse(d):
    if d[:8] != MAGIC:
        raise SystemExit(f"not an Android vendor_boot image (magic {d[:8]!r})")
    h = {}
    h["header_version"] = struct.unpack_from("<I", d, 8)[0]
    h["page_size"] = struct.unpack_from("<I", d, 12)[0]
    h["kernel_addr"] = struct.unpack_from("<I", d, 16)[0]
    h["ramdisk_addr"] = struct.unpack_from("<I", d, 20)[0]
    h["vendor_ramdisk_size"] = struct.unpack_from("<I", d, 24)[0]
    h["cmdline"] = d[28:28 + 2048].split(b"\0", 1)[0].decode(errors="replace")
    h["tags_addr"] = struct.unpack_from("<I", d, 2076)[0]
    h["name"] = d[2080:2096].split(b"\0", 1)[0].decode(errors="replace")
    h["header_size"] = struct.unpack_from("<I", d, 2096)[0]
    h["dtb_size"] = struct.unpack_from("<I", d, 2100)[0]
    h["dtb_addr"] = struct.unpack_from("<Q", d, 2104)[0]

    if h["header_version"] >= 4:
        h["vendor_ramdisk_table_size"] = struct.unpack_from("<I", d, 2112)[0]
        h["vendor_ramdisk_table_entry_num"] = struct.unpack_from("<I", d, 2116)[0]
        h["vendor_ramdisk_table_entry_size"] = struct.unpack_from("<I", d, 2120)[0]
        h["bootconfig_size"] = struct.unpack_from("<I", d, 2124)[0]
    else:
        h["vendor_ramdisk_table_size"] = 0
        h["vendor_ramdisk_table_entry_num"] = 0
        h["vendor_ramdisk_table_entry_size"] = 0
        h["bootconfig_size"] = 0

    page = h["page_size"]
    h["off_ramdisk"] = align(h["header_size"], page)
    h["off_dtb"] = align(h["off_ramdisk"] + h["vendor_ramdisk_size"], page)
    h["off_table"] = align(h["off_dtb"] + h["dtb_size"], page)
    h["off_bootconfig"] = align(h["off_table"] + h["vendor_ramdisk_table_size"], page)
    h["size_sections"] = align(h["off_bootconfig"] + h["bootconfig_size"], page)
    return h


def cmd_info(img):
    d = open(img, "rb").read()
    h = parse(d)
    print(f"  image            : {img} ({len(d)} bytes)")
    print(f"  magic            : {d[:8].decode(errors='replace')}")
    print(f"  header_version   : {h['header_version']}  (header {h['header_size']} B, page {h['page_size']})")
    print(f"  name             : {h['name']!r}")
    print(f"  cmdline          : {h['cmdline'][:90]!r}")
    print(f"  vendor_ramdisk   : off {h['off_ramdisk']}, size {h['vendor_ramdisk_size']}, "
          f"format {ramdisk_format(d[h['off_ramdisk']:h['off_ramdisk'] + 8])}")
    print(f"  dtb              : off {h['off_dtb']}, size {h['dtb_size']}")
    print(f"  ramdisk table    : size {h['vendor_ramdisk_table_size']}, "
          f"entries {h['vendor_ramdisk_table_entry_num']}")
    print(f"  bootconfig       : off {h['off_bootconfig']}, size {h['bootconfig_size']}")
    print(f"  sections end at  : {h['size_sections']} of {len(d)}")
    tail = d[h["size_sections"]:]
    print(f"  trailing bytes   : {len(tail)} (all zero: {tail.count(0) == len(tail)})")


def cmd_unpack(img, outdir):
    d = open(img, "rb").read()
    h = parse(d)
    os.makedirs(outdir, exist_ok=True)

    rd = d[h["off_ramdisk"]:h["off_ramdisk"] + h["vendor_ramdisk_size"]]
    dtb = d[h["off_dtb"]:h["off_dtb"] + h["dtb_size"]]
    bc = d[h["off_bootconfig"]:h["off_bootconfig"] + h["bootconfig_size"]]

    open(os.path.join(outdir, "ramdisk.raw"), "wb").write(rd)
    open(os.path.join(outdir, "dtb.bin"), "wb").write(dtb)
    if bc:
        open(os.path.join(outdir, "bootconfig.bin"), "wb").write(bc)

    h["source_image"] = os.path.basename(img)
    h["source_size"] = len(d)
    h["ramdisk_format"] = ramdisk_format(rd)
    h["sha256_ramdisk"] = hashlib.sha256(rd).hexdigest()
    h["sha256_dtb"] = hashlib.sha256(dtb).hexdigest()
    with open(os.path.join(outdir, "header.json"), "w") as fh:
        json.dump(h, fh, indent=1, sort_keys=True)
        fh.write("\n")

    print(f"  ramdisk.raw : {len(rd)} bytes ({h['ramdisk_format']})")
    print(f"  dtb.bin     : {len(dtb)} bytes")
    if bc:
        print(f"  bootconfig  : {len(bc)} bytes")
    print(f"  header.json : written")
    print(f"  now decompress, e.g.:  lz4 -d -l -f {outdir}/ramdisk.raw {outdir}/ramdisk.cpio")


def cmd_pack(outdir, out, pad=True):
    h = json.load(open(os.path.join(outdir, "header.json")))
    rd_path = os.path.join(outdir, "ramdisk.new")
    if not os.path.exists(rd_path):
        raise SystemExit(f"{rd_path} missing (copy the repacked ramdisk there)")
    rd = open(rd_path, "rb").read()
    dtb = open(os.path.join(outdir, "dtb.bin"), "rb").read()
    bc_path = os.path.join(outdir, "bootconfig.bin")
    bc = open(bc_path, "rb").read() if os.path.exists(bc_path) else b""

    if h["header_version"] >= 4 and h["vendor_ramdisk_table_entry_num"]:
        raise SystemExit("v4 vendor_boot with a ramdisk table is not supported by this tool; "
                         "the table entries would need offset fixups")

    page = h["page_size"]
    hdr = bytearray(h["header_size"])
    hdr[0:8] = MAGIC
    struct.pack_into("<I", hdr, 8, h["header_version"])
    struct.pack_into("<I", hdr, 12, h["page_size"])
    struct.pack_into("<I", hdr, 16, h["kernel_addr"])
    struct.pack_into("<I", hdr, 20, h["ramdisk_addr"])
    struct.pack_into("<I", hdr, 24, len(rd))
    cmdline = h["cmdline"].encode()
    hdr[28:28 + len(cmdline)] = cmdline
    struct.pack_into("<I", hdr, 2076, h["tags_addr"])
    name = h["name"].encode()
    hdr[2080:2080 + len(name)] = name
    struct.pack_into("<I", hdr, 2096, h["header_size"])
    struct.pack_into("<I", hdr, 2100, len(dtb))
    struct.pack_into("<Q", hdr, 2104, h["dtb_addr"])

    out_bytes = bytearray()
    out_bytes += bytes(hdr).ljust(align(len(hdr), page), b"\0")
    out_bytes += rd.ljust(align(len(rd), page), b"\0")
    out_bytes += dtb.ljust(align(len(dtb), page), b"\0")
    if bc:
        out_bytes += bc.ljust(align(len(bc), page), b"\0")

    # The stock dump is a whole-partition image: it ends with an AVB hash footer
    # ("AVBf" in the last 64 bytes) pointing at an "AVB0" vbmeta struct that sits
    # right after the sections. Both would be stale (and the footer would point
    # into our new ramdisk), so pad over them unless told otherwise. Verification
    # is disabled on this device (unlocked bootloader + patched vbmeta), so the
    # image boots unsigned - same as the AnyKernel3 boot images we already flash.
    content = len(out_bytes)
    if pad and len(out_bytes) < h["source_size"]:
        out_bytes += b"\0" * (h["source_size"] - len(out_bytes))

    open(out, "wb").write(out_bytes)
    print(f"  wrote {out}: {len(out_bytes)} bytes (sections {content}, "
          f"padded to partition size: {len(out_bytes) > content})")
    print(f"    ramdisk : {len(rd)} bytes ({h['ramdisk_format']})")
    print(f"    dtb     : {len(dtb)} bytes")
    if content > h["source_size"]:
        print(f"  WARNING: sections need {content} bytes but the partition holds "
              f"{h['source_size']} - trim the payload!")
    else:
        print(f"    fits partition: {content} / {h['source_size']} bytes "
              f"({h['source_size'] - content} spare)")
    print(f"    flash with: fastboot flash vendor_boot_a {out}")


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    cmd = argv[1]
    if cmd == "info" and len(argv) == 3:
        cmd_info(argv[2])
    elif cmd == "unpack" and len(argv) == 4:
        cmd_unpack(argv[2], argv[3])
    elif cmd == "pack" and len(argv) >= 4:
        cmd_pack(argv[2], argv[3], pad=(len(argv) < 5 or argv[4] != "--no-pad"))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
