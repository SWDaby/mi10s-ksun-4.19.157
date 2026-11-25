import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.patch_ksun_419 import patch_tree


KBUILD = r'''ifeq ($(CONFIG_KSU_SYSCALL_TABLE_HOOK), y)
ifneq ($(shell grep -Eq "^static int can_umount" $(srctree)/fs/namespace.c; echo $$?),0)
$(info -- KSU_NEXT: adding function)
endif
'''

PATCH_MEMORY = r'''#include <linux/version.h>
// copy_to_kernel_nofault() was introduced in 5.8; before that it was
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#define copy_to_kernel_nofault(dst, src, size) probe_kernel_write(dst, src, size)
#endif
'''

KERNEL_COMPAT = r'''static inline ssize_t __strscpy_pad(char *dest, const char *src, size_t count)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 222)
    return strscpy_pad(dest, src, count);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 3, 0)
    return strscpy(dest, src, count);
#else
    return -E2BIG;
#endif
}
'''

REBOOT = r'''SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
                void __user *, arg)
{
    struct pid_namespace *pid_ns = task_active_pid_ns(current);
    char buffer[256];
    int ret = 0;

    if (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))
        return -EPERM;
    return ret;
}
'''

STAT = r'''#include <linux/fs.h>

SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
    struct kstat stat;
    int error = vfs_fstat(fd, &stat);

    if (!error)
        error = cp_new_stat(&stat, statbuf);
    return error;
}

COMPAT_SYSCALL_DEFINE2(newfstat, unsigned int, fd,
                       struct compat_stat __user *, statbuf)
{
    return 0;
}
'''


class PatchKernelSUNext419Test(unittest.TestCase):
    def make_tree(
        self,
        *,
        has_copy_to_kernel_nofault: bool = False,
        has_strscpy_pad: bool = False,
    ) -> Path:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)

        files = {
            "drivers/kernelsu/Kbuild": KBUILD,
            "drivers/kernelsu/hook/patch_memory.c": PATCH_MEMORY,
            "drivers/kernelsu/compat/kernel_compat.h": KERNEL_COMPAT,
            "drivers/kernelsu/runtime/ksud_integration.c": (
                "void ksu_handle_newfstat_ret(unsigned int *fd, "
                "struct stat __user **statbuf) {}\n"
            ),
            "kernel/reboot.c": REBOOT,
            "fs/stat.c": STAT,
            "include/linux/uaccess.h": (
                "long copy_to_kernel_nofault(void *dst, const void *src, size_t size);\n"
                if has_copy_to_kernel_nofault
                else "/* legacy 4.19 uaccess */\n"
            ),
            "include/linux/string.h": (
                "ssize_t strscpy_pad(char *dest, const char *src, size_t count);\n"
                if has_strscpy_pad
                else "ssize_t strscpy(char *dest, const char *src, size_t count);\n"
            ),
        }
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(content), encoding="utf-8")
        return root

    def test_keeps_legacy_nofault_shim_when_kernel_does_not_backport_helper(self):
        root = self.make_tree(has_copy_to_kernel_nofault=False)

        patch_tree(root)

        patch_memory = (root / "drivers/kernelsu/hook/patch_memory.c").read_text()
        self.assertIn(
            "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)", patch_memory
        )
        self.assertNotIn("4.19 already provides copy_to_kernel_nofault", patch_memory)

    def test_disables_legacy_nofault_shim_when_kernel_backports_helper(self):
        root = self.make_tree(has_copy_to_kernel_nofault=True)

        patch_tree(root)

        patch_memory = (root / "drivers/kernelsu/hook/patch_memory.c").read_text()
        self.assertIn(
            "#if 0  /* kernel already provides copy_to_kernel_nofault() */",
            patch_memory,
        )

    def test_inserts_uapi6_reboot_hook_before_capability_check(self):
        root = self.make_tree()

        patch_tree(root)

        reboot = (root / "kernel/reboot.c").read_text()
        call = "ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);"
        self.assertEqual(2, reboot.count("ksu_handle_sys_reboot"))
        self.assertLess(reboot.index(call), reboot.index("ns_capable"))

    def test_inserts_newfstat_return_hook_after_stat_copy(self):
        root = self.make_tree()

        patch_tree(root)

        stat = (root / "fs/stat.c").read_text()
        call = "ksu_handle_newfstat_ret(&fd, &statbuf);"
        self.assertEqual(2, stat.count("ksu_handle_newfstat_ret"))
        self.assertLess(stat.index("cp_new_stat(&stat, statbuf)"), stat.index(call))
        self.assertLess(stat.index(call), stat.index("return error;"))
        self.assertLess(
            stat.index("extern void ksu_handle_newfstat_ret"),
            stat.index("SYSCALL_DEFINE2(newfstat"),
        )

    def test_patch_is_idempotent(self):
        root = self.make_tree()
        patch_tree(root)
        first = {
            path.relative_to(root): path.read_bytes()
            for path in root.rglob("*")
            if path.is_file()
        }

        patch_tree(root)

        second = {
            path.relative_to(root): path.read_bytes()
            for path in root.rglob("*")
            if path.is_file()
        }
        self.assertEqual(first, second)

    def test_can_umount_detection_accepts_static_inline_definition(self):
        root = self.make_tree()

        patch_tree(root)

        kbuild = (root / "drivers/kernelsu/Kbuild").read_text()
        self.assertIn('^static (inline )?int can_umount', kbuild)

    def test_uses_local_strscpy_pad_fallback_when_vendor_kernel_lacks_helper(self):
        root = self.make_tree(has_strscpy_pad=False)

        patch_tree(root)

        compat = (root / "drivers/kernelsu/compat/kernel_compat.h").read_text()
        self.assertIn(
            "#if 0  /* kernel does not provide strscpy_pad() */", compat
        )

    def test_keeps_strscpy_pad_call_when_kernel_declares_helper(self):
        root = self.make_tree(has_strscpy_pad=True)

        patch_tree(root)

        compat = (root / "drivers/kernelsu/compat/kernel_compat.h").read_text()
        self.assertIn(
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 222)", compat
        )
        self.assertNotIn("kernel does not provide strscpy_pad", compat)


if __name__ == "__main__":
    unittest.main()
