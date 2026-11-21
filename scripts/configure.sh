#!/usr/bin/env bash
# 基线：bcggxx/android_kernel_xiaomi_moon_sm8250 (4.19.157 原厂源码导入)
#   arch/arm64/configs/stock/thyme_stock_defconfig 与设备 /proc/config.gz
#   逐符号 0 差异（5286 项），即这台机器原厂内核的源码/配置。
# 叠加：Droidspaces 官方 non-GKI 配置层 + 2 个运行期 bug 补丁。
# 原则：原厂 =y 的硬件/功能项一个都不许丢；uname -r 与原厂完全一致。
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${OUT:?OUT not set}"
: "${DIST:?DIST not set}"
: "${REPO_ROOT:?REPO_ROOT not set}"
DEFCONFIG="${DEFCONFIG:-stock/thyme_stock_defconfig}"

# 原厂：CONFIG_LOCALVERSION="-perf" + LOCALVERSION_AUTO=y + git 提交 9d90dd04aa7c
# → 4.19.157-perf-g9d90dd04aa7c。vendor 里的原厂 .ko 按这个 vermagic 编译。
EXPECTED_RELEASE="${EXPECTED_RELEASE:-4.19.157-perf-g9d90dd04aa7c}"
LOCALVERSION_STR="-perf-g9d90dd04aa7c"

export PATH="$HOME/aosp-clang/bin:$PATH"
export LC_ALL=C

CFG="$OUT/.config"
KCFG="$KERNEL_DIR/scripts/config"
STOCK_CFG="$REPO_ROOT/config/stock-4.19.157-thyme.config"

mkdir -p "$OUT" "$DIST"

# 与 bcggxx 仓库 CI 验证过的参数一致（AOSP clang r416183b）。
MK=(make -j"$(nproc)" -C "$KERNEL_DIR" O="$OUT" ARCH=arm64
    CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld
    CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_COMPAT=arm-linux-androideabi-
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip)

section() { echo; echo "=============== $* ==============="; }

section "1. 生成 .config（基线 $DEFCONFIG）"
BASE="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"
if [ ! -f "$BASE" ]; then
    echo "ERROR: $BASE 不存在"
    ls "$KERNEL_DIR/arch/arm64/configs/" | head -40
    exit 1
fi
# stock/ 下是完整 .config 转储，直接落盘再 olddefconfig。
cp "$BASE" "$CFG"
cp "$BASE" "$DIST/config-base.txt"
BASE_SYMS=$(grep -cE '^(# )?CONFIG_' "$CFG" || true)
echo "  基线符号数: $BASE_SYMS"
# stock/ 下是完整 .config 转储；其他（vendor/*_defconfig）是精简 defconfig，符号数天然少。
case "$DEFCONFIG" in
    stock/*)
        [ "$BASE_SYMS" -gt 3500 ] || { echo "ERROR: 基线 config 内容异常（不是完整转储？）"; exit 1; }
        ;;
    *)
        [ "$BASE_SYMS" -gt 200 ] || { echo "ERROR: 基线 defconfig 内容异常"; exit 1; }
        ;;
esac

# RELR 重定位打包：原厂内核用 GNU ld 2.27 编译，binutils 2.27 不支持 RELR，
# 所以原厂 CONFIG_RELR 是关的；换 LLD 后 olddefconfig 会按 default y 自动打开。
# RELR 在 head.S 里、控制台注册之前执行，一旦有问题就是「无输出、卡开机 logo」，
# 所以默认关掉，与原厂保持一致。
if [ "${DISABLE_RELR:-1}" = "1" ]; then
    "$KCFG" --file "$CFG" -d RELR
    echo "  RELR: 关闭（与原厂一致）"
else
    echo "  RELR: 保留（DISABLE_RELR=0）"
fi

# KASLR：原厂 =y，但本树作者自己的 thyme 配置里明确写了
# "# CONFIG_RANDOMIZE_BASE is not set"。KASLR 的重定位同样在 head.S、
# 控制台之前完成；换 LLD 后若重定位表与原厂的 GNU ld 输出不同，
# 结果就是「无任何输出、卡开机 logo」。默认关掉，先确认能不能起来。
if [ "${DISABLE_KASLR:-1}" = "1" ]; then
    "$KCFG" --file "$CFG" -d RANDOMIZE_BASE
    echo "  KASLR: 关闭（与本树 thyme 配置一致）"
    # 关掉 KASLR 会连带让 RELOCATABLE 及其从属符号从 .config 里消失，
    # 属于同一处改动，登记给保真门禁，避免被当成"原厂功能丢失"。
    export INTENTIONAL_OFF_EXTRA="${INTENTIONAL_OFF_EXTRA:-} CONFIG_RANDOMIZE_BASE"
    export EXPECTED_ABSENT_EXTRA="${EXPECTED_ABSENT_EXTRA:-} CONFIG_RELOCATABLE CONFIG_RANDOMIZE_MODULE_REGION_FULL CONFIG_ARCH_HAS_RELR"
else
    echo "  KASLR: 保留（DISABLE_KASLR=0，与原厂一致）"
fi

# 早期 alternatives 补丁：这三项都在 setup_arch 阶段用 alternative 机制
# 改写异常向量/uaccess 代码，发生时间早于任何控制台输出。本树作者自己的
# thyme 配置把三项全关了；换 LLD 后若补丁点位对不上，就是「无输出卡 logo」。
if [ "${DISABLE_ARM64_HARDENING:-0}" = "1" ]; then
    "$KCFG" --file "$CFG" -d ARM64_SW_TTBR0_PAN
    "$KCFG" --file "$CFG" -d HARDEN_BRANCH_PREDICTOR
    "$KCFG" --file "$CFG" -d HARDEN_EL2_VECTORS
    echo "  ARM64 早期加固: 关闭 SW_TTBR0_PAN / HARDEN_BRANCH_PREDICTOR / HARDEN_EL2_VECTORS"
    export INTENTIONAL_OFF_EXTRA="${INTENTIONAL_OFF_EXTRA:-} CONFIG_ARM64_SW_TTBR0_PAN CONFIG_HARDEN_BRANCH_PREDICTOR CONFIG_HARDEN_EL2_VECTORS"
fi

# QEMU 探针（只用于本地验证，绝不刷真机）：
# 打开 QEMU virt 机器的 PL011 串口，这样内核即便在真机卡死的位置也能打印日志。
# 注意 PE thyme 树没有 ARCH_VIRT，本地验证时用打了 "qcom,kona" 的 QEMU 设备树
# 去匹配 ARCH_KONA 的 machine_desc（见 tools/qemu_probe.sh）。
if [ "${QEMU_PROBE:-0}" = "1" ]; then
    "$KCFG" --file "$CFG" \
        -e ARM_AMBA \
        -e SERIAL_AMBA_PL011 \
        -e SERIAL_AMBA_PL011_CONSOLE \
        -e SERIAL_EARLYCON \
        -e POWER_RESET \
        -e POWER_RESET_SYSCON
    echo "  QEMU 探针: PL011 串口已打开（仅本地验证，不要刷真机）"
fi

if [ "${DROIDSPACES_LAYER:-1}" != "1" ]; then
    echo "  模式: 不叠加 Droidspaces 层（纯原厂配置对照构建）"
else
section "2. 叠加 Droidspaces non-GKI 配置（官方清单）"
# 来源：bcggxx 仓库 .github/workflows/droidspaces.config（Droidspaces 作者 ravindu644）
# 官方清单里的 CGROUP_NET_PRIO 已去掉：本树的 net/core/netprio_cgroup.c 仍是
# 4.19 的 css->cgroup->id 写法，而 struct cgroup 已回移到 5.x（id 在 kernfs 里），
# 打开必编译失败。原厂本身也是关的，容器网络不依赖它。
"$KCFG" --file "$CFG" \
    -e SYSCTL \
    -e SYSVIPC \
    -e POSIX_MQUEUE \
    -e NAMESPACES \
    -e PID_NS \
    -e UTS_NS \
    -e IPC_NS \
    -e SECCOMP \
    -e SECCOMP_FILTER \
    -e CGROUPS \
    -e CGROUP_DEVICE \
    -e CGROUP_PIDS \
    -e MEMCG \
    -e CGROUP_SCHED \
    -e FAIR_GROUP_SCHED \
    -e CGROUP_FREEZER \
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
    -e BRIDGE_NETFILTER \
    -e NETFILTER_ADVANCED \
    -e NF_CONNTRACK \
    -e NF_CONNTRACK_IPV4 \
    -e NF_CONNTRACK_IPV6 \
    -e NF_CONNTRACK_NETLINK \
    -e IP_NF_IPTABLES \
    -e IP_NF_FILTER \
    -e NF_NAT \
    -e NF_NAT_IPV4 \
    -e NF_NAT_IPV6 \
    -e NF_NAT_REDIRECT \
    -e IP_NF_NAT \
    -e IP6_NF_IPTABLES \
    -e IP6_NF_FILTER \
    -e IP6_NF_MANGLE \
    -e IP6_NF_NAT \
    -e IP6_NF_TARGET_MASQUERADE \
    -e IP_NF_TARGET_MASQUERADE \
    -e NF_TABLES \
    -e NETFILTER_XT_TARGET_TCPMSS \
    -e NETFILTER_XT_MATCH_ADDRTYPE \
    -e NETFILTER_XT_MATCH_COMMENT \
    -e NETFILTER_XT_MATCH_STATE \
    -e NETFILTER_XT_MATCH_CONNTRACK \
    -e NETFILTER_XT_MATCH_MULTIPORT \
    -e NETFILTER_XT_MATCH_HL \
    -e NETFILTER_XT_MATCH_RECENT \
    -e NETFILTER_XT_MATCH_LIMIT \
    -e NETFILTER_XT_MATCH_HASHLIMIT \
    -e NETFILTER_XT_MATCH_OWNER \
    -e NETFILTER_XT_MATCH_PKTTYPE \
    -e NETFILTER_XT_MATCH_MARK \
    -e NETFILTER_XT_TARGET_MARK \
    -e NETFILTER_XT_TARGET_REJECT \
    -e NETFILTER_XT_TARGET_LOG \
    -e NETFILTER_XT_TARGET_NFLOG \
    -e IP_NF_TARGET_REJECT \
    -e IP_NF_TARGET_ULOG \
    -e IP_SET \
    -e IP_SET_HASH_IP \
    -e IP_SET_HASH_NET \
    -e NETFILTER_XT_SET \
    -e NETFILTER_NETLINK_QUEUE \
    -e NETFILTER_NETLINK_LOG \
    -e IP_ADVANCED_ROUTER \
    -e IP_MULTIPLE_TABLES \
    -e IPV6 \
    -e IPV6_MULTIPLE_TABLES \
    -d ANDROID_PARANOID_NETWORK
fi

section "2.5 版本串：与原厂 vermagic 完全一致"
# 原厂 .ko 的 vermagic 是 "4.19.157-perf-g9d90dd04aa7c SMP preempt mod_unload modversions aarch64"。
# 少一项模块就拒绝加载，所以这四项一个都不能动：
#   SMP=y / PREEMPT=y / MODULE_UNLOAD=y / MODVERSIONS=y
# 不管基线是原厂完整配置还是别的树的 defconfig，这里都强制拉回来。
"$KCFG" --file "$CFG" -e SMP -e PREEMPT -e MODULE_UNLOAD -e MODVERSIONS
"$KCFG" --file "$CFG" --set-str LOCALVERSION "$LOCALVERSION_STR"
"$KCFG" --file "$CFG" -d LOCALVERSION_AUTO
# 只影响 vmlinux 调试段，不进 Image，也不影响符号 CRC；关掉省一半构建时间/磁盘。
"$KCFG" --file "$CFG" -d DEBUG_INFO

section "3. olddefconfig"
"${MK[@]}" olddefconfig

section "4. 基本完整性（防止 config 解析异常）"
for s in ARM64 ARCH_KONA MODULES BLOCK MODVERSIONS MODULE_UNLOAD SMP PREEMPT; do
    grep -qx "CONFIG_${s}=y" "$CFG" || { echo "ERROR: CONFIG_${s}=y 缺失，基线 config 没被正确加载"; exit 1; }
done
LINES=$(wc -l < "$CFG")
echo "  .config 行数: $LINES"
[ "$LINES" -gt 3500 ] || { echo "ERROR: .config 行数异常偏少，基线 config 可能未生效"; exit 1; }

section "4.5 内核版本串核对"
# 直接从 Makefile + .config 推算，避免 O= 构建下 setlocalversion 路径问题。
REL="$(awk '$1=="VERSION"{v=$3}$1=="PATCHLEVEL"{p=$3}$1=="SUBLEVEL"{s=$3}$1=="EXTRAVERSION"{e=$3}END{print v"."p"."s e}' "$KERNEL_DIR/Makefile")$(grep '^CONFIG_LOCALVERSION=' "$CFG" | cut -d'"' -f2)"
echo "  kernelrelease = $REL"
[ "$REL" = "$EXPECTED_RELEASE" ] || {
    echo "ERROR: 内核版本串不是 $EXPECTED_RELEASE"
    echo "       原厂 vendor 模块的 vermagic 会对不上，模块全部拒绝加载。"
    exit 1
}

section "5. 断言：Droidspaces 关键项必须存活"
# 只列本树确实存在、且容器运行必需的项；可选/已被上游移除的项不在此列。
if [ "${DROIDSPACES_LAYER:-1}" = "1" ]; then
CRITICAL=(
    SYSVIPC POSIX_MQUEUE
    NAMESPACES PID_NS UTS_NS IPC_NS
    SECCOMP SECCOMP_FILTER
    CGROUPS CGROUP_DEVICE CGROUP_PIDS MEMCG CGROUP_SCHED
    FAIR_GROUP_SCHED CGROUP_FREEZER
    DEVTMPFS OVERLAY_FS TMPFS_POSIX_ACL TMPFS_XATTR
    FW_LOADER FW_LOADER_USER_HELPER
    NET_NS VETH BRIDGE MACVLAN BRIDGE_NETFILTER
    NETFILTER NETFILTER_ADVANCED NF_CONNTRACK NF_TABLES
    IP_NF_IPTABLES IP_NF_FILTER NF_NAT NF_NAT_REDIRECT
    IP_NF_TARGET_MASQUERADE NETFILTER_XT_TARGET_TCPMSS
    NETFILTER_XT_MATCH_ADDRTYPE
    IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES
    IP6_NF_IPTABLES IP6_NF_NAT IP6_NF_TARGET_MASQUERADE
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

section "6. 断言：必须关闭的项"
for s in ANDROID_PARANOID_NETWORK PERF_HUMANTASK; do
    if grep -qx "CONFIG_${s}=y" "$CFG"; then
        echo "ERROR: CONFIG_${s} 应关闭，但被 Kconfig 重新打开了"
        exit 1
    fi
    echo "  OK: CONFIG_${s} 未启用"
done
else
    echo "  跳过：未叠加 Droidspaces 层"
fi

section "7. 原厂保真核对（原厂 =y / =m 一个都不许丢）"
if [ "${ALLOW_CONFIG_DRIFT:-0}" = "1" ]; then
    echo "  跳过：ALLOW_CONFIG_DRIFT=1（诊断构建，基线不是原厂完整配置）"
else
python3 "$REPO_ROOT/scripts/check_config.py" \
    "$STOCK_CFG" "$CFG" "$LOCALVERSION_STR" "$EXPECTED_RELEASE" \
    | tee "$DIST/stock-check.txt"
fi

section "8. 应用 Droidspaces 运行期补丁"
cd "$KERNEL_DIR"
apply_patch() {
    local p="$1" describe="$2" optional="${3:-0}"
    if [ ! -f "$p" ]; then echo "ERROR: 补丁不存在 $p"; exit 1; fi
    if git apply --check --whitespace=nowarn "$p" 2>/dev/null; then
        git apply --whitespace=nowarn "$p"
        echo "  applied: $describe"
    elif git apply --reverse --check --whitespace=nowarn "$p" 2>/dev/null; then
        echo "  already applied: $describe"
    elif [ "$optional" = "1" ]; then
        echo "  skip: 补丁与当前基线树不匹配，已跳过（$describe）"
    else
        echo "ERROR: 补丁与当前内核树不兼容: $describe"
        git apply --check --whitespace=nowarn "$p" || true
        exit 1
    fi
}
if [ "${DROIDSPACES_LAYER:-1}" = "1" ]; then
if [ -f net/netfilter/xt_qtaguid.c ]; then
    apply_patch "$REPO_ROOT/patches/01-fix-xt-qtaguid-panic.patch" "xt_qtaguid panic 修复" "${PATCH_OPTIONAL:-0}"
else
    echo "  skip: 本树无 xt_qtaguid，panic 路径不存在"
fi
apply_patch "$REPO_ROOT/patches/02-fix-cgroup-file-prefix.patch" "cgroup 文件前缀恢复" "${PATCH_OPTIONAL:-0}"
else
    echo "  跳过 Droidspaces 运行期补丁（DROIDSPACES_LAYER=0）"
fi

# 原厂 41 个 vendor .ko 是用小米自己的 4.19.157 树编的，换基线后 genksyms 算出的 CRC
# 与之普遍不同（struct file/net/tracepoint 等实现不一样）。严格校验会让 WiFi
# (qca_cld3_qca6390.ko) 和全部音频模块 (audio_*.ko) 直接拒绝加载，所以降级为警告。
if [ "${ALLOW_CRC_MISMATCH:-1}" = "1" ]; then
    if ! grep -q 'disagrees about version of symbol %s (ignored)' kernel/module.c; then
        apply_patch "$REPO_ROOT/patches/03-allow-crc-mismatch.patch" \
            "原厂 vendor 模块 CRC 不匹配降级为警告" 1
    fi
    if ! grep -q 'disagrees about version of symbol %s (ignored)' kernel/module.c; then
        echo "  补丁上下文不匹配，改用结构化改写 kernel/module.c"
        python3 "$REPO_ROOT/scripts/patch_crc.py" kernel/module.c
    fi
    grep -q 'disagrees about version of symbol %s (ignored)' kernel/module.c \
        || { echo "ERROR: CRC 降级补丁没有生效"; exit 1; }
    echo "  模式: 允许 CRC 不匹配（只打印警告，不拒绝加载）"
else
    echo "  模式: 严格 CRC 校验（ALLOW_CRC_MISMATCH=0）"
fi

section "9. 存档：最终配置 + 与原厂配置的差异"
cp "$CFG" "$DIST/config-final.txt"
diff -u "$STOCK_CFG" "$CFG" > "$DIST/config-diff.txt" || true

echo
echo "================ 与原厂配置的差异（只列 CONFIG 行）================"
grep -E '^[+-](CONFIG_|# CONFIG_)' "$DIST/config-diff.txt" | grep -vE '^\+\+\+|^---' | sed 's/^/  /' || true
echo
echo "配置阶段完成。uname -r = $REL"
