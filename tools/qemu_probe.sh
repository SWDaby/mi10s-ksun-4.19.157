#!/usr/bin/env bash
# 在 WSL 的 QEMU 里启动内核 Image，抓串口日志（完全不碰手机）。
#
# 用法：
#   bash tools/qemu_probe.sh <Image 路径> [日志路径]
#
# 为什么要把 qcom,kona 塞进 QEMU 设备树：
#   PE thyme 树的 Kconfig.platforms 里没有 ARCH_VIRT（只有 ARCH_QCOM / ARCH_KONA 等），
#   QEMU 默认的 "linux,dummy-virt" 匹配不到任何 machine_desc，内核会在
#   setup_machine_fdt() 直接 panic，看不到后面的启动过程。把 compatible 改成
#   "qcom,kona" 就能匹配 ARCH_KONA，继续走通用 arm64 启动路径。
set -uo pipefail

IMG="${1:?用法: qemu_probe.sh <Image> [log]}"
LOG="${2:-/tmp/qemu-serial.log}"
WORK="$(mktemp -d)"
DTB=""

echo "Image : $IMG ($(stat -c %s "$IMG") 字节)"
echo "日志  : $LOG"

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "ERROR: 没有 qemu-system-aarch64，先 apt-get install -y qemu-system-arm" >&2
    exit 1
fi

# 1) 让 QEMU 导出自己的设备树，并把 qcom,kona 放到 compatible 最前面
qemu-system-aarch64 -M virt,dumpdtb="$WORK/virt.dtb" -cpu cortex-a72 -m 2048 -smp 2 >/dev/null 2>&1
if [ -s "$WORK/virt.dtb" ] && command -v dtc >/dev/null 2>&1; then
    dtc -I dtb -O dts -o "$WORK/virt.dts" "$WORK/virt.dtb" 2>/dev/null
    python3 - "$WORK/virt.dts" <<'PY'
import re
import sys

p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()
if "qcom,kona" in s:
    sys.exit(0)
m = re.search(r'compatible = "([^"]+)"', s)
if not m:
    sys.exit("设备树里找不到 compatible")
s = s.replace(m.group(0), 'compatible = "qcom,kona", "%s"' % m.group(1), 1)
open(p, "w", encoding="utf-8").write(s)
print("设备树: compatible 已改为 qcom,kona 优先")
PY
    if dtc -I dts -O dtb -o "$WORK/virt-kona.dtb" "$WORK/virt.dts" 2>/dev/null; then
        DTB="$WORK/virt-kona.dtb"
        echo "设备树: 使用 $DTB"
    fi
fi

APPEND="console=ttyAMA0 earlycon=pl011,0x09000000 panic=1 ignore_loglevel loglevel=8"

# 2) 跑 QEMU：180 秒上限，panic 后不重启
timeout 180 qemu-system-aarch64 \
    -M virt -cpu cortex-a72 -m 2048 -smp 2 \
    -kernel "$IMG" ${DTB:+-dtb "$DTB"} \
    -append "$APPEND" \
    -display none -monitor none -serial "file:$LOG" -no-reboot
RC=$?
echo "qemu 退出码: $RC（124 = 超时/卡住；0 或 1 = 正常结束）"

# 3) 结果摘要
echo "--- 关键标记 ---"
for pat in "Booting Linux" "Linux version" "Machine model" "Memory:" "smp:" "initcall" \
           "Freeing unused kernel memory" "Run /init" "Kernel panic" \
           "No machine compatible" "Unable to handle kernel" "rcu" "watchdog"; do
    n=$(grep -c -- "$pat" "$LOG" 2>/dev/null || true)
    printf "  %-32s %s\n" "$pat" "$n"
done

echo "--- 日志末尾 30 行 ---"
tail -n 30 "$LOG" 2>/dev/null | sed 's/^/  /'
echo "完整日志: $LOG"
rm -rf "$WORK"
