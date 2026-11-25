#!/usr/bin/env python3
"""Apply the KernelSU-Next UAPI 6 hooks needed by non-GKI Linux 4.19."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


NOFAULT_GUARD = "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)"
NOFAULT_BACKPORT_GUARD = (
    "#if 0  /* kernel already provides copy_to_kernel_nofault() */"
)
STRSCPY_PAD_VERSION_GUARD = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 222)"
)
STRSCPY_PAD_FALLBACK_GUARD = (
    "#if 0  /* kernel does not provide strscpy_pad() */"
)


def read(path: Path) -> str:
    if not path.is_file():
        raise RuntimeError(f"required source file is missing: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def write_if_changed(path: Path, before: str, after: str, changes: list[str]) -> None:
    if before != after:
        path.write_text(after, encoding="utf-8")
        changes.append(path.as_posix())


def patch_can_umount_guard(root: Path, changes: list[str]) -> None:
    path = root / "drivers/kernelsu/Kbuild"
    before = read(path)
    old = "^static int can_umount"
    new = "^static (inline )?int can_umount"
    if new in before:
        return
    if before.count(old) != 1:
        raise RuntimeError("expected one KernelSU can_umount detection expression")
    write_if_changed(path, before, before.replace(old, new, 1), changes)


def kernel_has_copy_to_kernel_nofault(root: Path) -> bool:
    candidates = [root / "include/linux/uaccess.h", root / "mm/maccess.c"]
    return any(path.is_file() and "copy_to_kernel_nofault" in read(path) for path in candidates)


def patch_nofault_compatibility(root: Path, changes: list[str]) -> None:
    path = root / "drivers/kernelsu/hook/patch_memory.c"
    before = read(path)
    has_backport = kernel_has_copy_to_kernel_nofault(root)

    if has_backport:
        if NOFAULT_BACKPORT_GUARD in before:
            return
        if before.count(NOFAULT_GUARD) != 1:
            raise RuntimeError("expected one KernelSU pre-5.8 nofault compatibility guard")
        after = before.replace(NOFAULT_GUARD, NOFAULT_BACKPORT_GUARD, 1)
        write_if_changed(path, before, after, changes)
        return

    if NOFAULT_BACKPORT_GUARD in before:
        raise RuntimeError(
            "KernelSU nofault shim is disabled, but this kernel has no "
            "copy_to_kernel_nofault() backport"
        )
    if before.count(NOFAULT_GUARD) != 1:
        raise RuntimeError("KernelSU pre-5.8 nofault compatibility guard is missing")


def patch_strscpy_pad_compatibility(root: Path, changes: list[str]) -> None:
    kernel_string_header = root / "include/linux/string.h"
    kernel_has_helper = bool(
        re.search(r"\bstrscpy_pad\s*\(", read(kernel_string_header))
    )
    path = root / "drivers/kernelsu/compat/kernel_compat.h"
    before = read(path)

    if kernel_has_helper:
        if STRSCPY_PAD_FALLBACK_GUARD in before:
            raise RuntimeError(
                "KernelSU strscpy_pad() call is disabled even though the kernel "
                "declares the helper"
            )
        if before.count(STRSCPY_PAD_VERSION_GUARD) != 1:
            raise RuntimeError("KernelSU strscpy_pad() compatibility guard is missing")
        return

    if STRSCPY_PAD_FALLBACK_GUARD in before:
        return
    if before.count(STRSCPY_PAD_VERSION_GUARD) != 1:
        raise RuntimeError("expected one KernelSU strscpy_pad() version guard")
    after = before.replace(
        STRSCPY_PAD_VERSION_GUARD, STRSCPY_PAD_FALLBACK_GUARD, 1
    )
    write_if_changed(path, before, after, changes)


def patch_reboot_hook(root: Path, changes: list[str]) -> None:
    path = root / "kernel/reboot.c"
    before = read(path)
    call = "ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);"
    if call in before:
        if before.count("ksu_handle_sys_reboot") != 2:
            raise RuntimeError("unexpected duplicate or incomplete KernelSU reboot hook")
        if before.index(call) > before.index("ns_capable", before.index(call)):
            raise RuntimeError("KernelSU reboot hook must run before capability checks")
        return

    lines = before.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if "SYSCALL_DEFINE4(reboot" in line]
    if len(starts) != 1:
        raise RuntimeError(f"expected one reboot syscall, found {len(starts)}")

    anchor = next(
        (
            i
            for i in range(starts[0], min(starts[0] + 50, len(lines)))
            if "int ret = 0;" in lines[i]
        ),
        None,
    )
    if anchor is None:
        raise RuntimeError("could not find the reboot syscall declaration anchor")

    hook = [
        "#ifdef CONFIG_KSU\n",
        "\textern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\n",
        f"\t{call}\n",
        "#endif\n",
        "\n",
    ]
    lines[anchor + 1 : anchor + 1] = hook
    after = "".join(lines)
    if after.count("ksu_handle_sys_reboot") != 2:
        raise RuntimeError("failed to insert exactly one KernelSU reboot hook")
    if after.index(call) > after.index("ns_capable", after.index(call)):
        raise RuntimeError("inserted reboot hook is after the capability check")
    write_if_changed(path, before, after, changes)


def patch_newfstat_hook(root: Path, changes: list[str]) -> None:
    ksu_source = root / "drivers/kernelsu/runtime/ksud_integration.c"
    if "void ksu_handle_newfstat_ret(" not in read(ksu_source):
        raise RuntimeError("KernelSU-Next no longer exports ksu_handle_newfstat_ret()")

    path = root / "fs/stat.c"
    before = read(path)
    call = "ksu_handle_newfstat_ret(&fd, &statbuf);"
    if call in before:
        if before.count("ksu_handle_newfstat_ret") != 2:
            raise RuntimeError("unexpected duplicate or incomplete KernelSU newfstat hook")
        return

    lines = before.splitlines(keepends=True)
    starts = [
        i
        for i, line in enumerate(lines)
        if re.match(r"^[ \t]*SYSCALL_DEFINE2\(newfstat\b", line)
    ]
    if len(starts) != 1:
        raise RuntimeError(f"expected one native newfstat syscall, found {len(starts)}")
    start = starts[0]

    return_index = None
    copy_index = None
    for i in range(start, min(start + 40, len(lines))):
        if i > start and "SYSCALL_DEFINE" in lines[i]:
            break
        if "cp_new_stat(&stat, statbuf)" in lines[i]:
            copy_index = i
        if lines[i].strip() == "return error;":
            return_index = i
            break
    if copy_index is None or return_index is None or copy_index >= return_index:
        raise RuntimeError("could not identify the native newfstat return path")

    call_lines = [
        "\n",
        "#ifdef CONFIG_KSU\n",
        f"\t{call}\n",
        "#endif\n",
    ]
    lines[return_index:return_index] = call_lines
    declaration = [
        "#ifdef CONFIG_KSU\n",
        "extern void ksu_handle_newfstat_ret(unsigned int *, struct stat __user **);\n",
        "#endif\n",
    ]
    lines[start:start] = declaration
    after = "".join(lines)

    if after.count("ksu_handle_newfstat_ret") != 2:
        raise RuntimeError("failed to insert exactly one KernelSU newfstat hook")
    if after.index("extern void ksu_handle_newfstat_ret") > after.index(
        "SYSCALL_DEFINE2(newfstat"
    ):
        raise RuntimeError("newfstat hook declaration is not at file scope")
    if after.index("cp_new_stat(&stat, statbuf)") > after.index(call):
        raise RuntimeError("newfstat hook must run after cp_new_stat()")
    if after.index(call) > after.index("return error;", after.index(call)):
        raise RuntimeError("newfstat hook must run before return")
    write_if_changed(path, before, after, changes)


def patch_tree(root: Path) -> list[str]:
    root = root.resolve()
    changes: list[str] = []
    patch_can_umount_guard(root, changes)
    patch_nofault_compatibility(root, changes)
    patch_strscpy_pad_compatibility(root, changes)
    patch_reboot_hook(root, changes)
    patch_newfstat_hook(root, changes)
    return changes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel_tree", type=Path)
    args = parser.parse_args()
    changes = patch_tree(args.kernel_tree)
    if changes:
        print("Patched KernelSU-Next for Linux 4.19:")
        for path in changes:
            print(f"  {path}")
    else:
        print("KernelSU-Next Linux 4.19 patches already applied")


if __name__ == "__main__":
    main()
