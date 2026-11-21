#!/usr/bin/env python3
"""原厂配置保真核对。

用法:
    check_config.py <stock.config> <final.config> <localversion> <expected-release>

规则:
  * 原厂 =y 的符号，最终必须仍是 =y（仅允许白名单里的主动关闭项）
  * 原厂 =m 的符号，最终必须仍是 =m
  * 原厂没有的符号可以新增（Droidspaces 层、Kconfig 依赖项）
  * vermagic 相关项必须与原厂一致，否则 vendor 里的原厂 .ko 会拒绝加载
"""
import re
import sys

# 主动关闭、且理由明确的项（其余任何 y -> n 都视为原厂功能丢失）
INTENTIONAL_OFF = {
    "CONFIG_DEBUG_INFO",              # 只影响 vmlinux 调试段，不进 Image，不影响 CRC
    "CONFIG_LOCALVERSION_AUTO",       # 改用固定 LOCALVERSION，保证版本串与原厂一致
    "CONFIG_ANDROID_PARANOID_NETWORK",  # 容器需要正常网络访问
}

REQUIRED_Y = [
    "CONFIG_ARM64",
    "CONFIG_ARCH_KONA",
    "CONFIG_MODULES",
    "CONFIG_SMP",
    "CONFIG_PREEMPT",
    "CONFIG_MODULE_UNLOAD",
    "CONFIG_MODVERSIONS",
    "CONFIG_MODULE_SIG",
]


def load(path):
    data = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            m = re.match(
                r"^(?:# )?(CONFIG_[A-Za-z0-9_]+)(?:=(.*)| is not set)$", line
            )
            if not m:
                continue
            name = m.group(1)
            value = m.group(2) if m.group(2) is not None else "n"
            data[name] = value
    return data


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 2

    stock_path, final_path, localversion, expected_release = sys.argv[1:5]
    stock = load(stock_path)
    final = load(final_path)

    lost_y = []
    lost_m = []
    for name, value in stock.items():
        if value == "y":
            got = final.get(name, "MISSING")
            if got != "y" and name not in INTENTIONAL_OFF:
                lost_y.append((name, got))
        elif value == "m":
            got = final.get(name, "MISSING")
            if got != "m":
                lost_m.append((name, got))

    changed = []
    for name in sorted(set(stock) | set(final)):
        old = stock.get(name, "MISSING")
        new = final.get(name, "MISSING")
        if old != new:
            changed.append((name, old, new))

    print("  原厂符号: %d   最终符号: %d   差异: %d" %
          (len(stock), len(final), len(changed)))

    new_y = [c for c in changed if c[1] != "y" and c[2] == "y"]
    print("  新增/重新启用 (-> y): %d" % len(new_y))
    for name, old, new in new_y:
        print("    + %-56s %-10s -> %s" % (name, old, new))

    print("  主动关闭: %s" % ", ".join(sorted(INTENTIONAL_OFF)))

    # 版本串 / vermagic
    ok = True
    want_local = '"%s"' % localversion
    if final.get("CONFIG_LOCALVERSION") != want_local:
        print("  ERROR: CONFIG_LOCALVERSION=%s，期望 %s" %
              (final.get("CONFIG_LOCALVERSION"), want_local))
        ok = False
    if final.get("CONFIG_LOCALVERSION_AUTO") == "y":
        print("  ERROR: CONFIG_LOCALVERSION_AUTO 必须关闭，否则版本串会带 git 后缀")
        ok = False
    for name in REQUIRED_Y:
        if final.get(name) != "y":
            print("  ERROR: %s 必须为 y（vermagic/模块兼容性）" % name)
            ok = False

    if lost_y:
        print("  ERROR: 原厂 =y 但最终被关掉/丢失: %d 项" % len(lost_y))
        for name, got in lost_y:
            print("    - %-56s 原厂=y  最终=%s" % (name, got))
        ok = False
    if lost_m:
        print("  ERROR: 原厂 =m 但最终不是模块: %d 项" % len(lost_m))
        for name, got in lost_m:
            print("    - %-56s 原厂=m  最终=%s" % (name, got))
        ok = False

    if ok:
        print("  OK: 原厂 =y/=m 全部保留；版本串将生成 %s" % expected_release)
        return 0

    print("  原厂保真核对失败")
    return 1


if __name__ == "__main__":
    sys.exit(main())
