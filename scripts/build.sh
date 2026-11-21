#!/usr/bin/env bash
# 编译 Image + 打 AnyKernel3（只放 Image，不碰 dtb/dtbo/vendor_boot）
set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR not set}"
: "${OUT:?OUT not set}"
: "${DIST:?DIST not set}"
: "${REPO_ROOT:?REPO_ROOT not set}"

EXPECTED_RELEASE="${EXPECTED_RELEASE:-4.19.157-perf-g9d90dd04aa7c}"

export PATH="$HOME/aosp-clang/bin:$PATH"
export LC_ALL=C
mkdir -p "$DIST"

section() { echo; echo "=============== $* ==============="; }

section "1. 编译 arm64 Image"
cd "$KERNEL_DIR"
set -o pipefail
make -j"$(nproc)" O="$OUT" ARCH=arm64 \
    CC=clang LLVM=1 LLVM_IAS=1 LD=ld.lld \
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

cp "$IMG" "$DIST/Image"
# 同时保存导出的符号 CRC 清单，供与原厂 Image 做 MODVERSIONS 兼容性比对。
[ -f "$OUT/Module.symvers" ] && cp "$OUT/Module.symvers" "$DIST/Module.symvers" || true

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
