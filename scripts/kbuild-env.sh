#!/usr/bin/env bash
# Source from bash: Kconfig probes and the build must use the same target tools.
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$HOME/aosp-clang}"
if [ ! -x "$TOOLCHAIN_ROOT/bin/clang" ]; then
    echo "ERROR: clang not executable: $TOOLCHAIN_ROOT/bin/clang" >&2
    return 1
fi
export PATH="$TOOLCHAIN_ROOT/bin:$PATH"
export LC_ALL=C

KERNEL_CLANG_TARGET=aarch64-linux-android
STACK_GUARD_FLAGS=-mstack-protector-guard=global

KBUILD=(make O="${OUT:?}" ARCH=arm64
    CC=clang LLVM=1 LLVM_IAS=1 LD="${KERNEL_LD:-ld.lld}"
    CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_COMPAT=arm-linux-androideabi-
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip)

if [ "${KERNEL_LD:-ld.lld}" = aarch64-linux-android-ld.bfd ]; then
    # Snapdragon 10 has no AArch64 -mstack-protector-guard switch. Its Linux
    # target uses the kernel's global guard; the Android target reads bionic TLS.
    KERNEL_CLANG_TARGET=aarch64-linux-gnu
    STACK_GUARD_FLAGS=''
    # The NDK clang defaults to ARM. This tree's OpenSSL 3 host tools use
    # diagnostic pragmas between if/else statements that GCC cannot parse.
    KBUILD+=(CLANG_TRIPLE="$KERNEL_CLANG_TARGET-" HOSTCC=/usr/bin/clang HOSTCXX=/usr/bin/clang++ LD_COMPAT=arm-linux-androideabi-ld.bfd)
fi
