#!/usr/bin/env bash
# 在 WSL 的 QEMU 里启动内核 Image，抓串口日志（完全不碰手机）。
#
# 用法：
#   bash tools/qemu_probe.sh <Image 路径> [日志路径]
#
# 说明：
#   arm64 没有 machine_desc 表（arch/arm64/include/asm/mach/arch.h 不存在），
#   setup_machine_fdt() 只打印 "Machine model" 就继续走通用启动路径，
#   所以 QEMU 默认的 linux,dummy-virt 设备树可以直接用，不需要改 compatible。
#
#   探针版本必须打开 CONFIG_SERIAL_AMBA_PL011（workflow 里 qemu_probe=1），
#   否则 earlycon 认不出 PL011，串口一个字节都不会有。
set -uo pipefail

IMG="${1:?用法: qemu_probe.sh <Image> [log]}"
LOG="${2:-/tmp/qemu-serial.log}"

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "ERROR: 没有 qemu-system-aarch64，先 apt-get install -y qemu-system-arm" >&2
    exit 1
fi

echo "Image : $IMG ($(stat -c %s "$IMG") 字节)"
echo "日志  : $LOG"
: > "$LOG"

APPEND="console=ttyAMA0 earlycon=pl011,0x09000000 keep_bootcon panic=1 ignore_loglevel loglevel=8"

# -no-reboot + panic=1：panic 后 1 秒退出，不会挂着刷屏
timeout 180 qemu-system-aarch64 \
    -M virt -cpu cortex-a72 -m 2048 -smp 2 \
    -kernel "$IMG" \
    -append "$APPEND" \
    -display none -monitor none -serial "file:$LOG" -no-reboot
RC=$?
echo "qemu 退出码: $RC（124 = 超时/卡住；0 或 1 = 正常结束）"

echo "--- 关键标记 ---"
for pat in "Booting Linux" "Linux version" "Machine model" "Memory:" "smp:" \
           "console [ttyAMA" "Freeing unused kernel memory" "Run /init" \
           "Kernel panic" "Unable to handle kernel" "Internal error" "rcu"; do
    n=$(grep -c -- "$pat" "$LOG" 2>/dev/null || true)
    printf "  %-32s %s\n" "$pat" "$n"
done

echo "--- 日志末尾 30 行 ---"
tail -n 30 "$LOG" 2>/dev/null | sed 's/^/  /'
echo "完整日志: $LOG"
