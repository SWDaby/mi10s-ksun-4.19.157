#!/usr/bin/env python3
"""Select the safe KernelSU-Next hook mode for non-GKI Linux 4.19."""

from __future__ import annotations

import argparse
from pathlib import Path


KSU_OPTIONS = (
    "CONFIG_KSU=y",
    "# CONFIG_KSU_MANUAL_HOOK is not set",
    "# CONFIG_KSU_KPROBES_HOOK is not set",
    "CONFIG_KSU_SYSCALL_TABLE_HOOK=y",
)


def is_ksu_option(line: str) -> bool:
    stripped = line.strip()
    if stripped.startswith("# CONFIG_KSU") and stripped.endswith(" is not set"):
        return True
    if stripped.startswith("CONFIG_KSU") and "=" in stripped:
        return True
    return False


def prepare_config(path: Path) -> None:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if "CONFIG_OVERLAY_FS=y" not in lines:
        raise RuntimeError("base kernel config must contain CONFIG_OVERLAY_FS=y")

    output = [line for line in lines if not is_ksu_option(line)]
    while output and not output[-1].strip():
        output.pop()
    output.extend(("", *KSU_OPTIONS))
    path.write_text("\n".join(output) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    prepare_config(args.config)
    print(f"Prepared KernelSU-Next syscall-table config: {args.config}")
    for option in KSU_OPTIONS:
        print(f"  {option}")


if __name__ == "__main__":
    main()
