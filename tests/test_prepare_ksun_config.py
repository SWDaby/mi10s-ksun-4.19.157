import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.prepare_ksun_config import prepare_config


class PrepareKernelSUNextConfigTest(unittest.TestCase):
    def write_config(self, content: str) -> Path:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / ".config"
        path.write_text(content, encoding="utf-8")
        return path

    def test_replaces_stale_ksu_options_with_419_syscall_table_hook(self):
        path = self.write_config(
            "CONFIG_MODULES=y\n"
            "CONFIG_OVERLAY_FS=y\n"
            "CONFIG_KSU=y\n"
            "CONFIG_KSU_KPROBES_HOOK=y\n"
            "# CONFIG_KSU_SYSCALL_TABLE_HOOK is not set\n"
            "# CONFIG_KPROBES is not set\n"
        )

        prepare_config(path)

        result = path.read_text(encoding="utf-8")
        self.assertEqual(1, result.count("CONFIG_KSU=y"))
        self.assertIn("# CONFIG_KSU_MANUAL_HOOK is not set", result)
        self.assertIn("# CONFIG_KSU_KPROBES_HOOK is not set", result)
        self.assertIn("CONFIG_KSU_SYSCALL_TABLE_HOOK=y", result)
        self.assertIn("# CONFIG_KPROBES is not set", result)
        self.assertNotIn("CONFIG_KSU_KPROBES_HOOK=y", result)

    def test_preserves_unrelated_kernel_options(self):
        path = self.write_config(
            "CONFIG_MODULES=y\n"
            "CONFIG_OVERLAY_FS=y\n"
            "CONFIG_LOCALVERSION=\"-perf-g9d90dd04aa7c\"\n"
        )

        prepare_config(path)

        result = path.read_text(encoding="utf-8")
        self.assertIn('CONFIG_LOCALVERSION="-perf-g9d90dd04aa7c"', result)

    def test_is_idempotent(self):
        path = self.write_config("CONFIG_MODULES=y\nCONFIG_OVERLAY_FS=y\n")
        prepare_config(path)
        first = path.read_bytes()

        prepare_config(path)

        self.assertEqual(first, path.read_bytes())

    def test_rejects_config_without_overlayfs(self):
        path = self.write_config("CONFIG_MODULES=y\n")

        with self.assertRaisesRegex(RuntimeError, "CONFIG_OVERLAY_FS=y"):
            prepare_config(path)


if __name__ == "__main__":
    unittest.main()
