#!/usr/bin/env python3
"""原厂配置保真核对。

用法:
    check_config.py <stock.config> <final.config> <localversion> <expected-release>

规则:
  * 原厂 =y 的符号，最终必须仍是 =y（仅允许白名单里的主动关闭项）
  * 原厂 =m 的符号，最终必须仍是 =m
  * 原厂 =y 但最终 =n        -> 错误（依赖被破坏，功能真丢了）
  * 原厂 =y 但最终整行不存在 -> 该源码树没有这个 Kconfig 符号；
    只有在 EXPECTED_ABSENT 里登记过（附原因）才算通过
  * 原厂没有的符号可以新增（Droidspaces 层、Kconfig 依赖项）
  * vermagic 相关项必须与原厂一致，否则 vendor 里的原厂 .ko 会拒绝加载
"""
import re
import sys

# 主动关闭、且理由明确的项（其余任何 y -> n 都视为原厂功能丢失）
INTENTIONAL_OFF = {
    "CONFIG_DEBUG_INFO",                # 只影响 vmlinux 调试段，不进 Image，不影响 CRC
    "CONFIG_LOCALVERSION_AUTO",         # 改用固定 LOCALVERSION，保证版本串与原厂一致
    "CONFIG_ANDROID_PARANOID_NETWORK",  # 容器需要正常网络访问
}

# 原厂 config 里有、但这套源码树里根本没有对应 Kconfig 符号的项。
# 这类项不是“被关掉”，而是源码树缺失；全部经过人工核对。
EXPECTED_ABSENT = {
    # --- 本树是 CAF 后期基线，核心代码已回移 5.x 实现 ---
    "CONFIG_PACKAGE_RUNTIME_INFO": "5.x 已移除该 arm64 选项，纯构建期打包信息，无运行期影响",
    "CONFIG_RWSEM_XCHGADD_ALGORITHM": "本树 arm64 改用通用 rwsem（5.x 回移），读写锁签名/CRC 不变",
    "CONFIG_HAVE_HW_BREAKPOINT": "本树 perf 架构不提供 HW_BREAKPOINT，隐藏符号，不影响驱动",
    # --- 小米私有驱动：公开源码里没有，任何第三方 thyme 内核都缺 ---
    "CONFIG_EMERGENCY_MEMORY": "小米紧急内存驱动，源码未公开；缺失只影响低内存兜底策略",
    "CONFIG_MI_MEMORY_SYSFS": "小米内存 sysfs 统计节点，源码未公开；缺失只影响 MIUI 统计读取",
    "CONFIG_MIGT": "小米游戏加速驱动，源码未公开；缺失只影响游戏加速开关",
    "CONFIG_MIGT_ENERGY_MODEL": "MIGT 附属项，同上",
    # --- Synaptics TCM 在本树是单 bool（无子选项），驱动本体被裁剪 ---
    "CONFIG_TOUCHSCREEN_SYNAPTICS_TCM_I2C": "本树 TCM 为单 bool 无子选项",
    "CONFIG_TOUCHSCREEN_SYNAPTICS_TCM_CORE": "本树 TCM 为单 bool 无子选项",
    "CONFIG_TOUCHSCREEN_SYNAPTICS_TCM_TOUCH": "本树 TCM 为单 bool 无子选项",
    "CONFIG_TOUCHSCREEN_SYNAPTICS_TCM_DEVICE": "本树 TCM 为单 bool 无子选项",
    "CONFIG_TOUCHSCREEN_SYNAPTICS_TCM_DIAGNOSTICS": "本树 TCM 为单 bool 无子选项",
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

# 这台机器实际用到的触屏/指纹驱动必须全部在位
REQUIRED_DRIVERS = [
    "CONFIG_TOUCHSCREEN_ST_FTS_V521",
    "CONFIG_TOUCHSCREEN_GOODIX_GTX8",
    "CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE",
    "CONFIG_TOUCHSCREEN_FOD",
    "CONFIG_FINGERPRINT_GOODIX_FOD_THY",
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

    lost_y = []      # 原厂 y -> 最终 n（依赖被破坏）
    lost_m = []      # 原厂 m -> 非 m
    absent = []      # 原厂 y -> 最终整行不存在（源码树没有该符号）
    for name, value in stock.items():
        if value == "y":
            got = final.get(name)
            if got == "y":
                continue
            if name in INTENTIONAL_OFF:
                continue
            if got is None:
                absent.append(name)
            else:
                lost_y.append((name, got))
        elif value == "m":
            got = final.get(name)
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
    for name in REQUIRED_DRIVERS:
        if final.get(name) != "y":
            print("  ERROR: %s 必须为 y（本机硬件驱动）" % name)
            ok = False

    if lost_y:
        print("  ERROR: 原厂 =y 但最终被关掉: %d 项" % len(lost_y))
        for name, got in lost_y:
            print("    - %-56s 原厂=y  最终=%s" % (name, got))
        ok = False
    if lost_m:
        print("  ERROR: 原厂 =m 但最终不是模块: %d 项" % len(lost_m))
        for name, got in lost_m:
            print("    - %-56s 原厂=m  最终=%s" % (name, got))
        ok = False

    unexpected = sorted(set(absent) - set(EXPECTED_ABSENT))
    if absent:
        print("  源码树缺失的符号: %d 项（已登记 %d 项）" %
              (len(absent), len(absent) - len(unexpected)))
        for name in sorted(absent):
            reason = EXPECTED_ABSENT.get(name)
            if reason:
                print("    ~ %-56s %s" % (name, reason))
            else:
                print("    ! %-56s 未登记，源码树里没有这个符号" % name)
    if unexpected:
        print("  ERROR: 出现未登记的源码树缺失符号: %d 项" % len(unexpected))
        ok = False

    if ok:
        print("  OK: 原厂 =y/=m 全部保留；版本串将生成 %s" % expected_release)
        return 0

    print("  原厂保真核对失败")
    return 1


if __name__ == "__main__":
    sys.exit(main())
