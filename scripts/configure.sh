#!/usr/bin/env bash
# 基线：内核树自带的 thyme_stock-defconfig（维护者按原厂 V14.0.6.0 config 移植的完整 .config 转储）
# 参考：config/stock-4.19.157-thyme.config（设备原厂 boot 解出的真 config，只用于核对）
# 只叠加 Droidspaces 官方 non-GKI 配置层 + 树结构必需项 + 修 2 个运行期 bug。
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
STOCK_CFG="$REPO_ROOT/config/stock-4.19.157-thyme.config"

# 主动关闭、且已在 README「已知差异」里说明理由的项（不参与原厂保真核对）。
INTENTIONAL_OFF_SYMS="TOUCHSCREEN_ST"
INTENTIONAL_OFF_NOTE="TOUCHSCREEN_ST 与 TOUCHSCREEN_ST_FTS_V521 是同源 fts 驱动（都注册 st,fts），同时开启必然 duplicate symbol；维护者自己的 thyme_defconfig 也只留 FTS_V521"

mkdir -p "$OUT" "$DIST"

MK=(make -j"$(nproc)" -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 SUBARCH=arm64
    LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang
    CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-)

section() { echo; echo "=============== $* ==============="; }

section "1. 生成 .config（基线 $DEFCONFIG）"
BASE="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"
if [ ! -f "$BASE" ]; then
    echo "ERROR: $BASE 不存在"
    ls "$KERNEL_DIR/arch/arm64/configs/" | head -40
    exit 1
fi
# 这份文件是完整 .config 转储（名字里是连字符，不是 make 目标），直接落盘再 olddefconfig。
cp "$BASE" "$CFG"
cp "$BASE" "$DIST/config-base.txt"
BASE_SYMS=$(grep -cE '^(# )?CONFIG_' "$CFG" || true)
echo "  基线符号数: $BASE_SYMS"
[ "$BASE_SYMS" -gt 3500 ] || { echo "ERROR: 基线 config 内容异常（不是完整转储？）"; exit 1; }

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

section "2.5 树结构必需项 + 原厂行为还原"
# 这棵树里 arch/arm64/net/bpf_jit_comp.c 等代码无条件调用 trace_android_vh_*，
# 而 include/trace/hooks/vendor_hooks.h 关闭该选项时指向本树根本不存在的
# DECLARE_EVENT_NOP 宏 —— 即 CAF 代码要求必须开启（原厂 config 里没有这个选项，
# 属于用这棵 4.19.325 树必须付的代价；开的是静态键 tracepoint，没人注册时零开销）。
# 原厂 =y，维护者的 stock 移植遗漏：开机内存回收行为与原厂一致
# 原厂 =y，容器网桥下的 IGMP 组播行为与原厂一致
# 原厂 =n，维护者移植里多开的块层特性，关掉回到原厂行为
# TOUCHSCREEN_ST 和 TOUCHSCREEN_ST_FTS_V521 在本树里是两份同源 fts 驱动
# （都注册 "st,fts"，fts_521 是新版带手势/FOD 的完整实现），同时打开会
# duplicate symbol 链接失败。维护者自己的 thyme_defconfig 用的是 FTS_V521，
# 这里保持一致：只留 FTS_V521。
# MACH_XIAOMI_THYME：这棵树把小米私有充电/电池驱动挂在 CONFIG_MACH_XIAOMI
# 的目录门控下（drivers/power/supply/{renesas,nuvolta,ti,maxim,lionsemi}/），
# 而 thyme_stock-defconfig 是原厂 4.19.157 的 config 转储，里面没有这个新符号
# → 那些 =y 的驱动被静默跳过，链接期报 idtp_op_ble_flag / rx_op_ble_flag 未定义。
# 维护者自己的 thyme_defconfig 是 MACH_XIAOMI_THYME=y，这里保持一致。
"$KCFG" --file "$CFG" \
    -e ANDROID_VENDOR_HOOKS \
    -e BOOTUP_RECLAIM \
    -e BRIDGE_IGMP_SNOOPING \
    -e MACH_XIAOMI_THYME \
    -d BLK_WBT \
    -d BLK_WBT_MQ \
    -d BLK_WBT_SQ \
    -d IOSCHED_BFQ \
    -d BFQ_GROUP_IOSCHED \
    -d TOUCHSCREEN_ST

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
LINES=$(wc -l < "$CFG")
echo "  .config 行数: $LINES"
[ "$LINES" -gt 3500 ] || { echo "ERROR: .config 行数异常偏少，基线 config 可能未生效"; exit 1; }

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
    ANDROID_VENDOR_HOOKS BOOTUP_RECLAIM BRIDGE_IGMP_SNOOPING
)
missing=0
for s in "${CRITICAL[@]}"; do
    if ! grep -qx "CONFIG_${s}=y" "$CFG"; then
        echo "  MISSING: CONFIG_${s}=y"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "ERROR: 关键配置未存活"; exit 1; }
echo "  OK: ${#CRITICAL[@]} 项全部为 y"

section "5.5 断言：小米私有硬件驱动必须真的被编进来"
# 这些符号在原厂 config 里本来就是 =y；但本树把它们放在 CONFIG_MACH_XIAOMI
# 的目录门控下，缺了 MACH_XIAOMI 就会“符号 =y 但文件不编译”，静默丢功能
# （无线充、双电芯电荷泵、电池验真、1-wire）。这里逐项兜底。
XIAOMI_HW=(
    MACH_XIAOMI MACH_XIAOMI_SM8250 MACH_XIAOMI_THYME
    IDT_P9415 RX1619 RX1619_TRIM RX1619_REMOVE
    BQ2597X_CHARGE_PUMP BQ_PUMP_WIRELESS_CHARGE
    BATT_VERIFY_BY_DS28E16 ONEWIRE_GPIO LN8282
)
missing=0
for s in "${XIAOMI_HW[@]}"; do
    if ! grep -qx "CONFIG_${s}=y" "$CFG"; then
        echo "  MISSING: CONFIG_${s}=y"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "ERROR: 小米私有硬件驱动没启用（MACH_XIAOMI 门控失效）"; exit 1; }
echo "  OK: ${#XIAOMI_HW[@]} 项全部为 y"

section "6. 断言：必须关闭的项"
for s in ANDROID_PARANOID_NETWORK PERF_HUMANTASK BLK_WBT IOSCHED_BFQ $INTENTIONAL_OFF_SYMS; do
    if grep -qx "CONFIG_${s}=y" "$CFG"; then
        echo "ERROR: CONFIG_${s} 应关闭，但被 Kconfig 重新打开了"
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

section "7.5 原厂硬件功能核对（原厂 =y 的硬件项不许被关掉）"
# 只核对硬件相关子系统；容器相关的功能项不在此列。
CRIT_PAT='TOUCHSCREEN|DRM_MSM|DRM_PANEL|KGSL|ADRENO|VIDC|CAMERA|ICNSS|CNSS|WLAN|SND|LPASS|UFS|MMC|USB|MHI|PINCTRL|SPMI|RTC|THERMAL|QPNP|SMB|CHARGER|FUEL_GAUGE|BATTERY|REGULATOR|ZRAM|MIUI|HAPTIC|HALL|NFC|FINGERPRINT|SDE|ION|DMABUF|BQ[0-9]'
lost=0
: > "$DIST/stock-gaps.txt"
while read -r line; do
    sym="${line#CONFIG_}"
    sym="${sym%%=*}"
    if grep -qx "CONFIG_${sym}=y" "$CFG"; then
        continue
    fi
    if grep -qE "^(# )?CONFIG_${sym}(=| is not set)" "$CFG"; then
        case " $INTENTIONAL_OFF_SYMS " in
            *" $sym "*)
                echo "  BY DESIGN: CONFIG_${sym}（原厂 y，本包主动关闭）"
                continue ;;
        esac
        echo "  DISABLED: CONFIG_${sym}（原厂 y）"
        lost=$((lost + 1))
    else
        echo "$sym" >> "$DIST/stock-gaps.txt"
    fi
done < <(grep -E "^CONFIG_(${CRIT_PAT})[A-Z0-9_]*=y$" "$STOCK_CFG" || true)
GAPS=$(wc -l < "$DIST/stock-gaps.txt")
[ "$lost" -eq 0 ] || { echo "ERROR: 原厂开启的硬件功能被关掉了（见上）"; exit 1; }
echo "  OK: 原厂 =y 的硬件项全部保留"
echo "  NOTE: 主动关闭: $INTENTIONAL_OFF_NOTE"
echo "  NOTE: $GAPS 项原厂 =y 的硬件/功能符号在本内核树里已不存在（清单见 dist/stock-gaps.txt）"
if [ "$GAPS" -gt 0 ]; then
    sed 's/^/    - /' "$DIST/stock-gaps.txt" | head -20
    [ "$GAPS" -gt 20 ] && echo "    ...（共 $GAPS 项）"
fi

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
diff -u "$STOCK_CFG" "$CFG" > "$DIST/config-diff.txt" || true

echo
echo "================ 与原厂配置的差异（只列 CONFIG 行）================"
grep -E '^[+-](CONFIG_|# CONFIG_)' "$DIST/config-diff.txt" | grep -vE '^\+\+\+|^---' | sed 's/^/  /' || true
echo
echo "配置阶段完成。uname -r 预期: $(awk '$1=="VERSION"{v=$3}$1=="PATCHLEVEL"{p=$3}$1=="SUBLEVEL"{s=$3}END{print v"."p"."s}' "$KERNEL_DIR/Makefile")$(grep '^CONFIG_LOCALVERSION=' "$CFG" | cut -d'"' -f2)"
