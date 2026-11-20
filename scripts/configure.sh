#!/usr/bin/env bash
# 基线：thyme_stock-defconfig（由原厂 V14.0.6.0 config 生成）
# 只叠加 Droidspaces 官方 non-GKI 配置层 + 修 2 个运行时 bug，其余一项不动。
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${OUT:?OUT not set}"
: "${DIST:?DIST not set}"
: "${REPO_ROOT:?REPO_ROOT not set}"
DEFCONFIG="${DEFCONFIG:-thyme_stock-defconfig}"

export PATH="$HOME/zyc-clang/bin:$PATH"
export LC_ALL=C

CFG="$OUT/.config"
KCFG="$KERNEL_DIR/scripts/config"
mkdir -p "$OUT" "$DIST"

MK=(make -j"$(nproc)" -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 SUBARCH=arm64
    LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang
    CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-)

section() { echo; echo "=============== $* ==============="; }

section "1. 生成 .config（基线 $DEFCONFIG）"
if [ ! -f "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" ]; then
    echo "ERROR: $KERNEL_DIR/arch/arm64/configs/$DEFCONFIG 不存在"
    ls "$KERNEL_DIR/arch/arm64/configs/" | head -40
    exit 1
fi
# kbuild 的 %_defconfig 规则只认下划线（thyme_defconfig）；这份原厂配置是连字符命名，
# 且本身就是完整 .config 转储，所以直接落盘再 olddefconfig。
case "$DEFCONFIG" in
    *_defconfig)
        "${MK[@]}" "$DEFCONFIG"
        ;;
    *)
        echo "  $DEFCONFIG 不以 _defconfig 结尾，按完整 config 直接写入 .config"
        cp "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" "$CFG"
        ;;
esac

section "2. 叠加 Droidspaces non-GKI 配置（官方清单）"
"$KCFG" --file "$CFG" \
    -e SYSCTL \
    -e SYSVIPC \
    -e POSIX_MQUEUE \
    -e NAMESPACES \
    -e PID_NS \
    -e UTS_NS \
    -e IPC_NS \
    -e USER_NS \
    -e SECCOMP \
    -e SECCOMP_FILTER \
    -e CGROUPS \
    -e CGROUP_DEVICE \
    -e CGROUP_PIDS \
    -e MEMCG \
    -e CGROUP_SCHED \
    -e FAIR_GROUP_SCHED \
    -e CFS_BANDWIDTH \
    -e CGROUP_FREEZER \
    -e CGROUP_NET_PRIO \
    -e CGROUP_CPUACCT \
    -e DEVTMPFS \
    -e OVERLAY_FS \
    -e TMPFS_POSIX_ACL \
    -e TMPFS_XATTR \
    -e FW_LOADER \
    -e FW_LOADER_USER_HELPER \
    -e FW_LOADER_COMPRESS \
    -e NET_NS \
    -e VETH \
    -e BRIDGE \
    -e MACVLAN \
    -e NETFILTER \
    -e NETFILTER_ADVANCED \
    -e BRIDGE_NETFILTER \
    -e NF_CONNTRACK \
    -e NF_CONNTRACK_IPV4 \
    -e NF_CONNTRACK_IPV6 \
    -e IP_NF_IPTABLES \
    -e IP_NF_FILTER \
    -e NF_NAT \
    -e NF_TABLES \
    -e IP_NF_TARGET_MASQUERADE \
    -e NETFILTER_XT_TARGET_MASQUERADE \
    -e NETFILTER_XT_TARGET_TCPMSS \
    -e NETFILTER_XT_MATCH_ADDRTYPE \
    -e NF_CT_NETLINK \
    -e NF_CONNTRACK_NETLINK \
    -e NF_NAT_REDIRECT \
    -e NF_NAT_IPV4 \
    -e NF_NAT_IPV6 \
    -e IP_NF_NAT \
    -e IP_ADVANCED_ROUTER \
    -e IP_MULTIPLE_TABLES \
    -e IPV6 \
    -e IPV6_MULTIPLE_TABLES \
    -e IP6_NF_IPTABLES \
    -e IP6_NF_FILTER \
    -e IP6_NF_MANGLE \
    -e IP6_NF_NAT \
    -e IP6_NF_TARGET_MASQUERADE \
    -d ANDROID_PARANOID_NETWORK \
    -d PERF_HUMANTASK

section "3. 构建期微调（不改功能）"
"$KCFG" --file "$CFG" --set-str LOCALVERSION "-perf"
"$KCFG" --file "$CFG" -d LOCALVERSION_AUTO   # 固定版本串，便于核对
"$KCFG" --file "$CFG" -d DEBUG_INFO          # 只影响 vmlinux 调试段，不进 Image

section "4. olddefconfig"
"${MK[@]}" olddefconfig

section "4.5 基本完整性（防止 config 解析异常）"
for s in ARM64 ARCH_KONA MODULES BLOCK; do
    grep -qx "CONFIG_${s}=y" "$CFG" || { echo "ERROR: CONFIG_${s}=y 缺失，基线 config 没被正确加载"; exit 1; }
done
echo "  .config 行数: $(wc -l < "$CFG")"
[ "$(wc -l < "$CFG")" -gt 3500 ] || { echo "ERROR: .config 行数异常偏少，基线 config 可能未生效"; exit 1; }

section "5. 断言：Droidspaces 关键项必须存活"
CRITICAL=(
    SYSCTL SYSVIPC POSIX_MQUEUE
    NAMESPACES PID_NS UTS_NS IPC_NS
    SECCOMP SECCOMP_FILTER
    CGROUPS CGROUP_DEVICE CGROUP_PIDS MEMCG CGROUP_SCHED
    FAIR_GROUP_SCHED CFS_BANDWIDTH CGROUP_FREEZER
    DEVTMPFS OVERLAY_FS
    NET_NS VETH BRIDGE MACVLAN NETFILTER BRIDGE_NETFILTER
    NF_CONNTRACK IP_NF_IPTABLES IP_NF_FILTER NF_NAT NF_TABLES
    IP_NF_TARGET_MASQUERADE NETFILTER_XT_TARGET_TCPMSS
    NETFILTER_XT_MATCH_ADDRTYPE NF_CT_NETLINK NF_NAT_REDIRECT
    NF_NAT_IPV6 IP6_NF_NAT IP6_NF_TARGET_MASQUERADE
    IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES
)
missing=0
for s in "${CRITICAL[@]}"; do
    if ! grep -qx "CONFIG_${s}=y" "$CFG"; then
        echo "  MISSING: CONFIG_${s}=y"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "ERROR: Droidspaces 关键配置未存活"; exit 1; }
echo "  OK: ${#CRITICAL[@]} 项全部为 y"

section "6. 断言：必须关闭的项"
for s in ANDROID_PARANOID_NETWORK PERF_HUMANTASK; do
    if grep -qx "CONFIG_${s}=y" "$CFG"; then
        echo "ERROR: CONFIG_${s} 被 Kconfig 重新打开，容器的启动/联网会出问题"
        exit 1
    fi
    echo "  OK: CONFIG_${s} 未启用"
done

section "7. 断言：关键驱动必须内建（不许变 =m）"
# 原厂只有 6 个无关紧要的 =m，新内核必须保持这一点，否则停机后 vendor 模块 CRC 不匹配会掉功能。
ALLOW_M="MSM_RDBG USB_GSPCA DVB_MPQ DVB_MPQ_DEMUX LCD_CLASS_DEVICE QCOM_LLCC_PERFMON"
bad=0
while read -r line; do
    sym="${line#CONFIG_}"; sym="${sym%%=*}"
    case " $ALLOW_M " in *" $sym "*) continue ;; esac
    case "$sym" in
        *WLAN*|*ICNSS*|*DRM*|*TOUCHSCREEN*|*CAM*|*FINGERPRINT*|*SDE*|*VIDC*|*ADRENO*|*KGSL*|*MMC*|*UFS*|*USB*|*AUDIO*|*SPMI*|*REGULATOR*|*RTC*|*THERMAL*|*PINCTRL*|*CLK*|*I2C*|*SPI*)
            echo "  NOTICE: $line （关键类驱动被设为模块）"; bad=1 ;;
        *) echo "  module: $line" ;;
    esac
done < <(grep '=m$' "$CFG" || true)
[ "$bad" -eq 0 ] || { echo "ERROR: 关键驱动变成模块，会与 vendor 里原厂模块冲突"; exit 1; }
echo "  模块数: $(grep -c '=m$' "$CFG" || true)"

section "8. 应用 Droidspaces 运行期补丁"
cd "$KERNEL_DIR"
apply_patch() {
    local p="$1" describe="$2"
    if [ ! -f "$p" ]; then echo "ERROR: 补丁不存在 $p"; exit 1; fi
    if git apply --check --whitespace=nowarn "$p" 2>/dev/null; then
        git apply --whitespace=nowarn "$p"
        echo "  applied: $describe"
    elif git apply --reverse --check --whitespace=nowarn "$p" 2>/dev/null; then
        echo "  already applied: $describe"
    else
        echo "ERROR: 补丁与当前内核树不兼容: $describe"
        git apply --check --whitespace=nowarn "$p" || true
        exit 1
    fi
}
if [ -f net/netfilter/xt_qtaguid.c ]; then
    apply_patch "$REPO_ROOT/patches/01-fix-xt-qtaguid-panic.patch" "xt_qtaguid panic 修复"
else
    echo "  skip: 本树无 xt_qtaguid，panic 路径不存在"
fi
apply_patch "$REPO_ROOT/patches/02-fix-cgroup-file-prefix.patch" "cgroup 文件前缀恢复"

section "9. 存档：最终配置 + 与原厂配置的差异"
cp "$CFG" "$DIST/config-final.txt"
diff -u "$REPO_ROOT/config/stock-4.19.157-thyme.config" "$CFG" > "$DIST/config-diff.txt" || true

echo
echo "================ 与原厂配置的差异（去掉纯时间戳/版本后）================"
grep -E '^[+-](CONFIG_|# CONFIG_)' "$DIST/config-diff.txt" | grep -vE '^\+\+\+|^---' | sed 's/^/  /' || true
echo
echo "配置阶段完成。uname -r 预期: $(grep '^CONFIG_LOCALVERSION=' "$CFG" | cut -d'"' -f2)-$(awk '$1=="VERSION"{v=$3}$1=="PATCHLEVEL"{p=$3}$1=="SUBLEVEL"{s=$3}END{print v"."p"."s}' "$KERNEL_DIR/Makefile")"
