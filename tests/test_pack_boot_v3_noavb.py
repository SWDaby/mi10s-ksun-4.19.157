import struct
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.pack_boot_v3_noavb import PAGE, BootImageError, align, pack_boot


def make_boot(kernel: bytes, ramdisk: bytes, *, total: int = 64 * 1024) -> bytes:
    header = bytearray(PAGE)
    header[:8] = b"ANDROID!"
    struct.pack_into("<4I", header, 8, len(kernel), len(ramdisk), 0x12345678, 1580)
    struct.pack_into("<I", header, 40, 3)
    payload = (
        bytes(header)
        + kernel
        + bytes(align(len(kernel)) - len(kernel))
        + ramdisk
    )
    if len(payload) > total:
        raise ValueError("fixture does not fit")
    return payload + bytes(total - len(payload))


class PackBootV3WithoutAvbTest(unittest.TestCase):
    def test_replaces_kernel_and_preserves_header_ramdisk_and_partition_size(self):
        source_kernel = b"old-kernel" * 400
        target_kernel = b"new-kernel" * 300
        ramdisk = b"ramdisk-data" * 700
        source = make_boot(source_kernel, ramdisk)

        output = pack_boot(source, target_kernel)

        self.assertEqual(len(source), len(output))
        self.assertEqual(source[:8], output[:8])
        self.assertEqual(len(target_kernel), struct.unpack_from("<I", output, 8)[0])
        self.assertEqual(source[12:PAGE], output[12:PAGE])
        self.assertEqual(target_kernel, output[PAGE : PAGE + len(target_kernel)])
        ramdisk_offset = PAGE + align(len(target_kernel))
        self.assertEqual(ramdisk, output[ramdisk_offset : ramdisk_offset + len(ramdisk)])
        self.assertEqual(
            bytes(len(output) - ramdisk_offset - len(ramdisk)),
            output[ramdisk_offset + len(ramdisk) :],
        )

    def test_accepts_a_larger_kernel_when_payload_still_fits(self):
        source = make_boot(b"A" * 4097, b"R" * 5000)
        target = b"B" * 12000

        output = pack_boot(source, target)

        self.assertEqual(target, output[PAGE : PAGE + len(target)])

    def test_rejects_unknown_nonzero_data_after_ramdisk(self):
        source = bytearray(make_boot(b"K" * 5000, b"R" * 5000))
        source[-100] = 1

        with self.assertRaisesRegex(BootImageError, "non-zero data after ramdisk"):
            pack_boot(bytes(source), b"N" * 4000)

    def test_rejects_boot_with_avb_footer(self):
        source = bytearray(make_boot(b"K" * 5000, b"R" * 5000))
        source[-64:-60] = b"AVBf"

        with self.assertRaisesRegex(BootImageError, "AVB footer"):
            pack_boot(bytes(source), b"N" * 4000)

    def test_rejects_non_v3_boot(self):
        source = bytearray(make_boot(b"K" * 5000, b"R" * 5000))
        struct.pack_into("<I", source, 40, 2)

        with self.assertRaisesRegex(BootImageError, "header version"):
            pack_boot(bytes(source), b"N" * 4000)


if __name__ == "__main__":
    unittest.main()
