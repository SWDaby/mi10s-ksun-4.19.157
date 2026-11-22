#!/usr/bin/env bash
# 编译 Image + 打 AnyKernel3（只放 Image，不碰 dtb/dtbo/vendor_boot）
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${OUT:?OUT not set}"
: "${DIST:?DIST not set}"
: "${REPO_ROOT:?REPO_ROOT not set}"

EXPECTED_RELEASE="${EXPECTED_RELEASE:-4.19.157-perf-g9d90dd04aa7c}"

# AOSP clang 在 aarch64-linux-android 目标下默认使用 TLS 栈保护守卫
# （canary 从 tpidr_el0 + 0x28 读取）。这是 bionic 用户态的约定，内核态
# tpidr_el0 恒为 0，于是 start_kernel 函数序言一读 canary 就在 0x28 缺页；
# 该异常发生在 SP 尚未切到任务栈之前，被判定为 "kernel stack overflow"，
# 随后 panic -> dump_stack_minidump 再踩空 -> die() 递归抢 die_lock 死锁，
# 外部表现就是完全没有串口输出的静默卡死。
# 4.19 arm64 内核的 canary 是全局变量 __stack_chk_guard，必须强制 global。
STACK_GUARD_FLAGS="-mstack-protector-guard=global"

export PATH="$HOME/aosp-clang/bin:$PATH"
export LC_ALL=C
mkdir -p "$DIST"

section() { echo; echo "=============== $* ==============="; }

section "0. 栈保护守卫模式预检"
# 防止工具链又回到 TLS 守卫：编译一个小函数，确认 canary 来自 __stack_chk_guard
# 而不是 tpidr_el0。这个检查只要 1 秒，但能避免又白等 15 分钟并刷一次砖。
# 注意必须用 -fstack-protector-all：-strong 的启发式在 -O2 下可能把局部数组
# 优化掉，导致根本不生成 canary，预检就形同虚设。
SP_DIR=$(mktemp -d)
cat > "$SP_DIR/sp_probe.c" <<'EOF'
__attribute__((noinline)) int sp_probe(const char *s)
{
    return s[0];
}
EOF
SP_COMMON="-fstack-protector-all -O2 -c"

# 1) 先记录工具链默认守卫，方便以后回溯
clang --target=aarch64-linux-android $SP_COMMON \
    "$SP_DIR/sp_probe.c" -o "$SP_DIR/probe-default.o"
llvm-objdump -dr "$SP_DIR/probe-default.o" > "$SP_DIR/probe-default.txt"
if grep -q 'tpidr_el0' "$SP_DIR/probe-default.txt"; then
    echo "  工具链默认守卫: tpidr_el0（TLS/sysreg，内核不可用）"
elif grep -q 'sp_el0' "$SP_DIR/probe-default.txt"; then
    echo "  工具链默认守卫: sp_el0（sysreg）"
elif grep -q '__stack_chk_guard' "$SP_DIR/probe-default.txt"; then
    echo "  工具链默认守卫: __stack_chk_guard（global）"
else
    echo "  工具链默认守卫: 未识别（canary 可能被优化掉）"
fi

# 2) 强制 global：必须看到 __stack_chk_guard，且不能出现 tpidr_el0
clang --target=aarch64-linux-android $SP_COMMON \
    $STACK_GUARD_FLAGS "$SP_DIR/sp_probe.c" -o "$SP_DIR/probe-global.o"
llvm-objdump -dr "$SP_DIR/probe-global.o" > "$SP_DIR/probe-global.txt"
if grep -q 'tpidr_el0' "$SP_DIR/probe-global.txt"; then
    echo "ERROR: 强制 global 后仍然使用 tpidr_el0（内核会在 0x28 缺页卡死）"
    cat "$SP_DIR/probe-global.txt"
    rm -rf "$SP_DIR"
    exit 1
fi
if ! grep -q '__stack_chk_guard' "$SP_DIR/probe-global.txt"; then
    echo "ERROR: 强制 global 后没有看到 __stack_chk_guard，编译选项可能没生效"
    cat "$SP_DIR/probe-global.txt"
    rm -rf "$SP_DIR"
    exit 1
fi
echo "  强制后守卫: __stack_chk_guard（global）✓"
rm -rf "$SP_DIR"

section "1. 编译 arm64 Image"
cd "$KERNEL_DIR"
set -o pipefail
make -j"$(nproc)" O="$OUT" ARCH=arm64 \
    CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld \
    KCFLAGS="$STACK_GUARD_FLAGS" \
    CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_COMPAT=arm-linux-androideabi- \
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    Image 2>&1 | tee "$DIST/build.log"

section "2. 校验产物"
IMG="$OUT/arch/arm64/boot/Image"
[ -f "$IMG" ] || { echo "ERROR: Image 不存在"; exit 1; }
SIZE=$(stat -c %s "$IMG")
echo "  Image 大小: $SIZE 字节 ($((SIZE / 1024 / 1024)) MB)"
# boot 分区 128MB = 134217728；原厂 Image 约 40MB。留足余量，超过 100MB 视为异常。
if [ "$SIZE" -lt 20000000 ] || [ "$SIZE" -gt 104857600 ]; then
    echo "ERROR: Image 大小异常，疑似配置被裁剪或膨胀"
    exit 1
fi

VERSION_STR=$(strings -a "$IMG" | grep -m1 '^Linux version' || true)
echo "  $VERSION_STR"
case "$VERSION_STR" in
    "Linux version ${EXPECTED_RELEASE} "*) : ;;
    *)
        echo "ERROR: 内核版本串不是 $EXPECTED_RELEASE"
        echo "       原厂 vendor 模块的 vermagic 会对不上，模块全部拒绝加载。"
        exit 1
        ;;
esac

# 防止 KernelPatch / KernelSU 之类的第三方 payload 混进来（上一轮 panic 日志里出现过）。
if strings -a "$IMG" | grep -qiE 'KernelPatch|KernelSU|kpatch'; then
    echo "ERROR: Image 里检测到 KernelPatch/KernelSU 字样，原厂行为会被破坏"
    strings -a "$IMG" | grep -iE 'KernelPatch|KernelSU|kpatch' | head -10
    exit 1
fi

# 端到端复核：直接反汇编真正参与链接的 vmlinux，确认 start_kernel 不再从
# tpidr_el0 读 canary（预检只看编译选项，这里看实际产物）。
if [ -f "$OUT/vmlinux" ]; then
    if llvm-objdump -d --disassemble-symbols=start_kernel "$OUT/vmlinux" \
            > "$DIST/start_kernel.dis" 2>/dev/null && [ -s "$DIST/start_kernel.dis" ]; then
        if grep -q 'tpidr_el0' "$DIST/start_kernel.dis"; then
            echo "ERROR: start_kernel 仍然从 tpidr_el0 读栈保护 canary"
            head -20 "$DIST/start_kernel.dis"
            exit 1
        fi
        echo "  start_kernel 栈保护守卫: 已确认不使用 tpidr_el0 ✓"
    else
        echo "  WARN: 无法反汇编 vmlinux 的 start_kernel，跳过端到端复核"
        rm -f "$DIST/start_kernel.dis"
    fi
else
    echo "  WARN: 没有 vmlinux，跳过端到端复核"
fi

cp "$IMG" "$DIST/Image"
# 记录本轮模块 CRC 校验模式，方便回溯（configure.sh 已对源码打过补丁）。
if grep -q 'disagrees about version of symbol %s (ignored)' "$KERNEL_DIR/kernel/module.c"; then
    echo "  CRC 模式: 允许原厂模块不匹配（仅警告）"
    echo "allow" > "$DIST/crc-mode.txt"
else
    echo "  CRC 模式: 严格"
    echo "strict" > "$DIST/crc-mode.txt"
fi
# 同时保存导出的符号 CRC 清单，供与原厂 Image 做 MODVERSIONS 兼容性比对。
[ -f "$OUT/Module.symvers" ] && cp "$OUT/Module.symvers" "$DIST/Module.symvers" || true

# 原厂 vendor 模块的硬依赖符号：缺一个就是整组模块加载失败，必须在产物里确认导出。
if [ -f "$OUT/Module.symvers" ]; then
    missing_syms=""
    for s in __dynamic_pr_debug __dynamic_dev_dbg xlogchar_kwrite; do
        awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$OUT/Module.symvers" || missing_syms="$missing_syms $s"
    done
    if [ -n "$missing_syms" ]; then
        echo "ERROR: 内核没有导出这些符号，原厂 vendor 模块会加载失败:$missing_syms"
        echo "       检查 CONFIG_DYNAMIC_DEBUG 与 drivers/misc/xlogchar_stub.c"
        exit 1
    fi
    echo "  vendor 模块依赖符号: __dynamic_pr_debug / __dynamic_dev_dbg / xlogchar_kwrite 均已导出 ✓"
else
    echo "  WARN: 没有 Module.symvers，跳过 vendor 依赖符号检查"
fi
# 符号表：真机卡死时没有任何日志，只能靠 QEMU + gdb 抓 PC，再把地址翻译成函数名。
# System.map 只有几 MB，比 vmlinux 小得多，上传成本低。
[ -f "$OUT/System.map" ] && cp "$OUT/System.map" "$DIST/System.map" || echo "  WARN: 没有 System.map"

section "3. 打包 AnyKernel3（仅 Image）"
rm -rf "$DIST/ak3"
git clone --depth=1 https://github.com/osm0sis/AnyKernel3 "$DIST/ak3"
cp "$REPO_ROOT/anykernel/anykernel.sh" "$DIST/ak3/anykernel.sh"
cp "$IMG" "$DIST/ak3/Image"
[ -f "$DIST/ak3/tools/ak3-core.sh" ] || { echo "ERROR: ak3-core.sh 缺失"; exit 1; }
[ -f "$DIST/ak3/META-INF/com/google/android/update-binary" ] || { echo "ERROR: update-binary 缺失"; exit 1; }
(
    cd "$DIST/ak3"
    rm -rf .git
    zip -r9 -q "$DIST/AnyKernel3-thyme-droidspaces.zip" . -x '*.git*'
)
echo "  AnyKernel3: $(stat -c %s "$DIST/AnyKernel3-thyme-droidspaces.zip") 字节"

section "4. 完成"
ls -l "$DIST"
