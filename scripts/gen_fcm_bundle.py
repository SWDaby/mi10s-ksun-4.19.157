#!/usr/bin/env python3
"""Extract the kernel requirements of one FCM level from a device compatibility matrix.

Run this on a phone dump of /system/etc/vintf/compatibility_matrix.5.xml to
regenerate config/fcm-4.19.110-level5.txt:

    python gen_fcm_bundle.py compatibility_matrix.5.xml config/fcm-4.19.110-level5.txt

The matrix carries several <kernel version="..."> blocks (4.14.180 / 4.19.110 /
5.4.61). libvintf picks the highest block that is <= the running kernel version,
so a 4.19.157 kernel is checked against the 4.19.110 block.
"""
import sys
import xml.etree.ElementTree as ET

KERNEL_VERSION = "4.19.110"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    root = ET.parse(src).getroot()
    blocks = [k for k in root.findall("kernel") if k.get("version") == KERNEL_VERSION]
    if not blocks:
        sys.exit(f"{src} has no <kernel version=\"{KERNEL_VERSION}\"> block")
    # Small sibling blocks only carry extra entries under <conditions>, which
    # libvintf evaluates itself; the biggest block is the base requirement set.
    blk = max(blocks, key=lambda k: len(k.findall("config")))
    reqs = [(c.find("key").text, c.find("value").text) for c in blk.findall("config")]

    with open(dst, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# Framework compatibility matrix (FCM level 5) kernel requirements\n")
        fh.write(f"# Extracted from {src}\n")
        fh.write(f"# <kernel version=\"{KERNEL_VERSION}\" level=\"{blk.get('level')}\">\n")
        fh.write("# Android 13 rejects the kernel at boot if any of these differ.\n")
        for key, val in reqs:
            fh.write(f"{key}={val}\n")
    print(f"wrote {len(reqs)} requirements -> {dst}")


if __name__ == "__main__":
    main()
