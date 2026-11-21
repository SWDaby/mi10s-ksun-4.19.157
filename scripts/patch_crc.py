#!/usr/bin/env python3
"""把 kernel/module.c 里 check_version() 的 CRC 不匹配从"拒绝加载"降级为"只警告"。

为什么需要这个脚本：
  patches/03-allow-crc-mismatch.patch 是按 pipa 树（5.x 回移，函数签名用
  struct load_info / info->name）写的。换到干净的 4.19.157 基线（PE thyme 树）
  后上下文对不上，git apply 会失败。这里用结构化改写代替上下文补丁：
    1. 找到 check_version() 里的 bad_version: 标签；
    2. 把它后面那句 "disagrees about version of symbol %s" 加上 (ignored)；
    3. 把紧随其后的 return 0; 改成 return 1;（继续加载）。

  这样不管源码里用的是 mod->name 还是 info->name，都不用改，兼容所有 4.19 树。

用法： python3 scripts/patch_crc.py kernel/module.c
"""
import re
import sys

MARK = "disagrees about version of symbol %s (ignored)"
ORIG = "disagrees about version of symbol %s\\n"
WINDOW = 1200


def fail(msg):
    print("ERROR: %s" % msg, file=sys.stderr)
    return 1


def main(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if MARK in src:
        print("  已经改写过，无需重复")
        return 0

    m = re.search(r"bad_version:\s*\n", src)
    if not m:
        return fail("找不到 bad_version 标签，check_version() 结构不认识")

    start = m.end()
    window = src[start:start + WINDOW]

    if ORIG not in window:
        return fail("bad_version 之后找不到 CRC 不匹配的 pr_warn 语句")

    window = window.replace(ORIG, "disagrees about version of symbol %s (ignored)\\n", 1)

    idx = window.find("return 0;")
    if idx < 0:
        return fail("bad_version 之后找不到 return 0;")
    window = window[:idx] + "return 1;" + window[idx + len("return 0;"):]

    out = src[:start] + window + src[start + WINDOW:]

    if MARK not in out:
        return fail("改写后没有出现预期标记")

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)

    print("  已把 CRC 不匹配降级为警告（结构化改写 kernel/module.c）")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: patch_crc.py kernel/module.c", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
