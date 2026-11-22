#!/usr/bin/env python3
"""Build a boot.img layout template from a stock Android boot image (header v3).

The template keeps everything that must stay byte-identical when only the kernel
is replaced, and drops the stock kernel itself:

    [ 4096 B header page (kernel_size zeroed) ]
    [ ramdisk, page aligned                    ]
    [ AVB vbmeta blob                          ]
    [ AVB footer (64 B)                        ]

Together with the JSON manifest produced next to it, this is all that
`pack_boot.py` needs to rebuild a full partition-sized boot.img.

Usage (once, from a device dump):

    python3 tools/make_boot_template.py \
        --boot stock_boot.img \
        --out-dir bootimg \
        --name thyme-boot-template \
        --firmware V14.0.6.0.TGACNXM
"""
import argparse
import hashlib
import json
import os
import struct
import sys

PAGE = 4096
AVB_FOOTER_LEN = 64


def align(n, page=PAGE):
    return (n + page - 1) // page * page


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", required=True, help="stock boot.img (header v3)")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--name", default="thyme-boot-template")
    ap.add_argument("--firmware", default="", help="firmware build this dump came from")
    args = ap.parse_args()

    boot = open(args.boot, "rb").read()
    if boot[:8] != b"ANDROID!":
        sys.exit("not an Android boot image")
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack("<4I", boot[8:24])
    header_version = struct.unpack("<I", boot[40:44])[0]
    if header_version != 3:
        sys.exit(f"unsupported boot header version {header_version}")

    kernel_off = PAGE
    ramdisk_off = kernel_off + align(kernel_size)
    ramdisk_end = ramdisk_off + align(ramdisk_size)
    ramdisk = boot[ramdisk_off:ramdisk_end]

    avb_off = boot.rfind(b"AVBf")
    if avb_off < 0 or avb_off + AVB_FOOTER_LEN != len(boot):
        sys.exit("no AVB footer at the end of the image; this tool needs one")

    _, _, orig_image_size, vbmeta_off, vbmeta_size = struct.unpack(">IIQQQ", boot[avb_off + 4:avb_off + 36])
    if vbmeta_off + vbmeta_size > avb_off:
        sys.exit("vbmeta blob does not fit before the footer")
    vbmeta = boot[vbmeta_off:vbmeta_off + vbmeta_size]
    footer = boot[avb_off:]
    footer_masked = bytearray(footer)
    footer_masked[12:28] = b"\x00" * 16  # original_image_size + vbmeta_offset

    header = bytearray(boot[:PAGE])
    struct.pack_into("<I", header, 8, 0)  # kernel_size: filled in by pack_boot.py
    header = bytes(header)
    cmdline = header[64:64 + 512].split(b"\x00")[0].decode("ascii", "replace")

    template = header + ramdisk + vbmeta + footer
    os.makedirs(args.out_dir, exist_ok=True)
    tpl_path = os.path.join(args.out_dir, args.name + ".bin")
    with open(tpl_path, "wb") as f:
        f.write(template)

    manifest = {
        "comment": "Android boot.img v3 layout template; only the kernel payload is replaced",
        "firmware": args.firmware,
        "page": PAGE,
        "header_version": header_version,
        "header_size": header_size,
        "total_size": len(boot),
        "kernel_offset": kernel_off,
        "ramdisk_size": ramdisk_size,
        "ramdisk_md5": hashlib.md5(ramdisk[:ramdisk_size]).hexdigest(),
        "os_version": os_version,
        "cmdline": cmdline,
        "header_sha256": hashlib.sha256(header).hexdigest(),
        "vbmeta_offset": vbmeta_off,
        "vbmeta_size": vbmeta_size,
        "vbmeta_sha256": hashlib.sha256(vbmeta).hexdigest(),
        "footer_sha256": hashlib.sha256(footer).hexdigest(),
        "footer_sha256_masked": hashlib.sha256(bytes(footer_masked)).hexdigest(),
        "footer_original_image_size": orig_image_size,
        "template_md5": hashlib.md5(template).hexdigest(),
        "template_size": len(template),
        "source_boot_md5": hashlib.md5(boot).hexdigest(),
    }
    mf_path = os.path.join(args.out_dir, args.name + ".json")
    with open(mf_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"boot     : {args.boot} ({len(boot):,} B, kernel {kernel_size:,}, ramdisk {ramdisk_size:,})")
    print(f"template : {tpl_path} ({len(template):,} B)")
    print(f"manifest : {mf_path}")
    print(f"cmdline  : {cmdline}")
    print(f"vbmeta   : @{vbmeta_off:,} ({vbmeta_size} B)")


if __name__ == "__main__":
    main()
