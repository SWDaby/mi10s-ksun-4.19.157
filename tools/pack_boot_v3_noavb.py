#!/usr/bin/env python3
"""Replace the kernel in a header-v3 boot partition image without AVB data."""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
from pathlib import Path


PAGE = 4096
HEADER_V3_SIZE = 1580


class BootImageError(ValueError):
    pass


def align(size: int, page: int = PAGE) -> int:
    return (size + page - 1) // page * page


def source_layout(boot: bytes) -> tuple[int, int, int, bytes]:
    if len(boot) < PAGE:
        raise BootImageError("boot image is smaller than one header page")
    if len(boot) % PAGE:
        raise BootImageError("boot partition image size is not page aligned")
    if boot[:8] != b"ANDROID!":
        raise BootImageError("Android boot magic is missing")

    kernel_size, ramdisk_size, _, header_size = struct.unpack_from("<4I", boot, 8)
    header_version = struct.unpack_from("<I", boot, 40)[0]
    if header_version != 3:
        raise BootImageError(f"unsupported boot header version {header_version}")
    if header_size != HEADER_V3_SIZE:
        raise BootImageError(f"unexpected header v3 size {header_size}")
    if not kernel_size or not ramdisk_size:
        raise BootImageError("kernel or ramdisk is empty")
    if boot[-64:-60] == b"AVBf":
        raise BootImageError("boot image has an AVB footer; use the AVB-aware packer")

    ramdisk_offset = PAGE + align(kernel_size)
    ramdisk_end = ramdisk_offset + ramdisk_size
    if ramdisk_end > len(boot):
        raise BootImageError("kernel and ramdisk exceed the partition image")
    kernel_padding = boot[PAGE + kernel_size : ramdisk_offset]
    if any(kernel_padding):
        raise BootImageError("source kernel padding contains non-zero data")
    if any(boot[ramdisk_end:]):
        raise BootImageError("source has non-zero data after ramdisk")

    return kernel_size, ramdisk_size, ramdisk_offset, boot[ramdisk_offset:ramdisk_end]


def pack_boot(source: bytes, image: bytes) -> bytes:
    if not image:
        raise BootImageError("replacement kernel Image is empty")
    _, ramdisk_size, _, ramdisk = source_layout(source)

    header = bytearray(source[:PAGE])
    struct.pack_into("<I", header, 8, len(image))
    payload = bytes(header) + image + bytes(align(len(image)) - len(image)) + ramdisk
    if len(payload) > len(source):
        raise BootImageError(
            f"new kernel + ramdisk need {len(payload)} bytes, partition has {len(source)}"
        )
    output = payload + bytes(len(source) - len(payload))

    # Postconditions: only kernel_size/header payload placement changed; ramdisk
    # bytes and every other header byte must remain exact.
    new_kernel_size, new_ramdisk_size, new_ramdisk_offset, new_ramdisk = source_layout(
        output
    )
    if new_kernel_size != len(image):
        raise BootImageError("packed kernel size does not match Image")
    if output[PAGE : PAGE + len(image)] != image:
        raise BootImageError("packed kernel bytes do not match Image")
    if new_ramdisk_size != ramdisk_size or new_ramdisk != ramdisk:
        raise BootImageError("ramdisk changed during packing")
    if source[12:PAGE] != output[12:PAGE]:
        raise BootImageError("boot header changed outside kernel_size")
    if any(output[new_ramdisk_offset + ramdisk_size :]):
        raise BootImageError("packed image tail is not zero-filled")
    return output


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--boot", required=True, type=Path)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    boot_path = args.boot.resolve()
    image_path = args.image.resolve()
    output_path = args.out.resolve()
    if output_path == boot_path:
        raise SystemExit("refusing to overwrite the source boot image")
    if output_path.exists() and not args.force:
        raise SystemExit(f"output already exists: {output_path}; pass --force to replace it")

    source = boot_path.read_bytes()
    image = image_path.read_bytes()
    old_kernel_size, ramdisk_size, old_ramdisk_offset, ramdisk = source_layout(source)
    output = pack_boot(source, image)
    new_ramdisk_offset = PAGE + align(len(image))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(output_path.name + ".tmp")
    temporary.write_bytes(output)
    os.replace(temporary, output_path)

    print(f"source boot : {boot_path}")
    print(f"source sha  : {file_sha256(boot_path)}")
    print(f"old kernel : {old_kernel_size:,} B")
    print(f"new Image  : {image_path} ({len(image):,} B)")
    print(f"Image sha  : {file_sha256(image_path)}")
    print(f"ramdisk    : {ramdisk_size:,} B, sha256 {hashlib.sha256(ramdisk).hexdigest()}")
    print(f"ramdisk off: {old_ramdisk_offset:,} -> {new_ramdisk_offset:,}")
    print(f"output boot: {output_path} ({len(output):,} B)")
    print(f"output sha : {file_sha256(output_path)}")
    print("verification: PASS (v3/no-AVB, header preserved, ramdisk exact, zero tail)")


if __name__ == "__main__":
    main()
