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

    def test_preserves_opaque_trailer_when_explicitly_requested(self):
        source_kernel = b"K" * 4097
        ramdisk = b"R" * 5000
        source = bytearray(make_boot(source_kernel, ramdisk))
        trailer_offset = PAGE + align(len(source_kernel)) + len(ramdisk)
        trailer = b"opaque-vendor-trailer\x00with-internal-zero"
        source[trailer_offset : trailer_offset + len(trailer)] = trailer
        target_kernel = b"N" * 8193

        output = pack_boot(
            bytes(source), target_kernel, preserve_opaque_trailer=True
        )

        new_trailer_offset = PAGE + align(len(target_kernel)) + len(ramdisk)
        self.assertEqual(
            trailer,
            output[new_trailer_offset : new_trailer_offset + len(trailer)],
        )
        self.assertFalse(any(output[new_trailer_offset + len(trailer) :]))

    def test_rejects_avb_data_inside_opaque_trailer(self):
        source = bytearray(make_boot(b"K" * 4097, b"R" * 5000))
        trailer_offset = PAGE + align(4097) + 5000
        source[trailer_offset : trailer_offset + 8] = b"AVB0data"

        with self.assertRaisesRegex(BootImageError, "AVB data"):
            pack_boot(bytes(source), b"N" * 8193, preserve_opaque_trailer=True)

    def test_preserves_nonzero_vendor_kernel_padding_when_length_matches(self):
        source_kernel = b"K" * 4097
        target_kernel = b"N" * 8193
        source = bytearray(make_boot(source_kernel, b"R" * 5000))
        source_pad_start = PAGE + len(source_kernel)
        source[source_pad_start : source_pad_start + 4] = b"VEND"

        output = pack_boot(bytes(source), target_kernel)

        target_pad_start = PAGE + len(target_kernel)
        self.assertEqual(b"VEND", output[target_pad_start : target_pad_start + 4])

    def test_rejects_nonzero_vendor_padding_when_new_padding_length_differs(self):
        source_kernel = b"K" * 4097
        source = bytearray(make_boot(source_kernel, b"R" * 5000))
        source[PAGE + len(source_kernel) : PAGE + len(source_kernel) + 4] = b"VEND"

        with self.assertRaisesRegex(BootImageError, "vendor kernel padding"):
            pack_boot(bytes(source), b"N" * 8194)

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
