# 小米 10S（thyme）KernelSU-Next 4.19.157 构建

> [!CAUTION]
> 本文中 Actions run #8 的 PE 源码产物已被真机证实不兼容：启动失败并记录
> `reboot,bpfloader-failed`。该产物仅保留为失败分析证据，**不得继续刷入或临时启动**。
> 工作流现已改用 `bcggxx/android_kernel_xiaomi_moon_sm8250` 的 exact-stock commit；其
> `thyme_stock_defconfig` 与设备 `/proc/config.gz` 逐字节相同。新的产物必须重新构建并通过
> 无 KSU 基线测试与 KSU 测试后才可使用。

本分支为一台实机的精确内核基线增加 KernelSU-Next。它只编译内核和 AnyKernel3 包，
**不会在 CI 中生成或发布可直接刷入的 `boot.img`**。当前 ROM 的 ramdisk 必须保留，不能拿
别的 ROM 的 boot 镜像代替。

## 已核对的目标

| 项 | 值 |
| --- | --- |
| 设备 | Xiaomi Mi 10S，`M2102J2SC` / `thyme` / SM8250-AC |
| 实际内核 | `4.19.157-perf-g9d90dd04aa7c` |
| 内核构建时间 | `Mon Sep 4 10:51:57 UTC 2023` |
| 原编译器 | Android NDK Clang `10.0.7`，GNU ld `2.27` |
| 当前 Android | API 34 / Android 14 移植系统 |
| 当前系统指纹 | `Xiaomi/thyme/thyme:14/UKQ1.231003.002/V816.0.8.0.UNACNXM:user/release-keys` |
| 活动槽位 | `a` |
| Bootloader | Fastboot 实测 `unlocked: yes`、`Device critical unlocked: true` |
| SELinux | `Enforcing` |
| 页大小 / VA | 4 KiB / VA39 |
| 设备 `.config` SHA-256 | `bc9a7b9a57a12554fe7b170b1db82f2b3ddfe07482710d5d39c77fba39baaee9` |

系统属性里的 `ro.boot.flash.locked=1` 和 `verifiedbootstate=green` 与 Fastboot 真实结果矛盾；
锁状态以 bootloader 的 `fastboot getvar unlocked` 和 `fastboot oem device-info` 为准。

设备导出的 `/proc/config.gz` 解压后与
`config/stock-4.19.157-thyme.config` **逐字节相同**，不是“相近配置”。系统指纹中的
`V816.0.8.0.UNACNXM` 原本属于其他机型，因此不能据此下载 boot.img；必须使用当前移植 ROM
实际安装的 boot 镜像。

## 固定的构建输入

| 组件 | 固定值 |
| --- | --- |
| 内核源码 | `bcggxx/android_kernel_xiaomi_moon_sm8250` |
| 内核 commit | `931792aa4683961ed6457e577477d68f164e779b` |
| KernelSU-Next | `e5f5ec998de88b9fc43c62cff8f7ae12d3f4800a`（`legacy` 历史） |
| 工具链 | AOSP Clang `r416183b`（基线仓库已验证） |
| 目标版本串 | `4.19.157-perf-g9d90dd04aa7c` |

工作流不会启用 4.19 上风险较高的 KSU kprobes hook，而是使用：

```text
CONFIG_KSU=y
# CONFIG_KSU_MANUAL_HOOK is not set
# CONFIG_KSU_KPROBES_HOOK is not set
CONFIG_KSU_SYSCALL_TABLE_HOOK=y
# CONFIG_KPROBES is not set
```

另外补入两个 UAPI 6 所需的路径：

1. `reboot()` supercall hook：管理器通过它取得 KernelSU driver fd；
2. `newfstat()` 返回 hook：让 Android init 读取 KSU 注入的 `post-fs-data` 配置，模块系统才能启动。

`scripts/patch_ksun_419.py` 会根据目标内核是否真的回移了
`copy_to_kernel_nofault()` 决定是否禁用 KSU 的兼容 shim。此目标内核**没有**该回移，必须保留
shim；错误禁用会造成编译或运行问题。

## GitHub Actions

1. 将本分支推送到自己的 GitHub 仓库。
2. 打开 **Actions**。
3. 选择 **Build thyme KernelSU-Next 4.19.157**。
4. 点击 **Run workflow**。
5. 第一次保持默认值：固定 KSU commit，`droidspaces_layer=false`。

成功后下载 `thyme-4.19.157-ksun-<run>` artifact。关键文件：

- `Image`：内置 KSU-Next 的裸内核；
- `AnyKernel3-thyme-ksun.zip`：只替换 kernel 的 Recovery 包；
- `config-final.txt` / `ksun-config.txt`：最终配置；
- `Module.symvers` / `System.map`：模块兼容和故障定位；
- `build.log` / `diagnostics.txt`：构建证据；
- `SHA256SUMS`：所有产物校验值。

## 已废弃的 PE 源码产物（仅供失败分析）

以下旧构建来自错误的 PE 基线，虽然编译和静态检查成功，但真机启动失败。不得使用。
[Actions run #8](https://github.com/SWDaby/mi10s-ksun-4.19.157/actions/runs/45613755967)，
仓库 commit `834b8990a0a42aa5194205a4ae208b17faa52e58`。所有 Actions step 均成功，
artifact ZIP 的 SHA-256 与 GitHub API 返回的 digest 一致，内部 `SHA256SUMS` 15 项全部复算通过。

| 文件 / 项 | 结果 |
| --- | --- |
| Artifact | `thyme-4.19.157-ksun-8` |
| Artifact ZIP SHA-256 | `013151b8a5378960d0c55d3d4a9df999c92f37748832a6c2bda03dbe6f19c4f3` |
| `Image` | 49,299,472 B |
| `Image` SHA-256 | `a82f5506e82a4e430c3d932a1fafb26f615c1ffd3d8e3ce86c9ada59224f4658` |
| `AnyKernel3-thyme-ksun.zip` | 24,932,540 B |
| AnyKernel ZIP SHA-256 | `128c5213b212af2cb7e82a5423ddd922532d97495cf1350abea31f38876fbbcb` |
| KSU 驱动 | version `33327`、UAPI `6`、built-in、syscall-table hook |
| 版本串 | `4.19.157-perf-g9d90dd04aa7c` |
| FCM | Android 13 level 5 的 251 项全部通过 |
| AnyKernel 门禁 | `do.devicecheck=1`、仅允许 `thyme`、不含任何分区镜像、内嵌 Image 哈希一致 |

最终 Image 的 `System.map` 已确认包含 `kernelsu_init`、`ksu_handle_sys_reboot`、
`ksu_handle_newfstat_ret`、`ksu_syscall_table_hook_init` 和 `path_umount`。构建日志无 compiler/linker error。

### 配套管理器

该驱动是 UAPI 6；正式 Release `v3.4.2` 的管理器是 UAPI 5，**不能使用**。已核对的配套版本：

| 项 | 值 |
| --- | --- |
| 上游 commit | `32e25d58fc1a187e1abe7278904c31571235fc83` |
| 上游 Actions run | [`44888862619`](https://github.com/KernelSU-Next/KernelSU-Next/actions/runs/44888862619) |
| Artifact | 普通 `manager`，不是 `manager-spoofed` |
| Artifact ZIP SHA-256 | `6ec8002a10e862930e1170a131b7319ebb4f603d86e0efdfcfabfc1dbb55de7f` |
| APK | `KernelSU_Next_v3.4.2-200-g32e25d58_33555-release.apk` |
| APK SHA-256 | `be27972d50a2b44258541778fd021d06005e2e6cdeee254e66bb161580e0b1cb` |

## 使用方式（等待 exact-stock 新产物后恢复）

以下流程只描述未来 exact-stock 产物的验证顺序。旧 run #8 的文件名和哈希不得用于操作。

### A. 推荐：用当前 boot 临时启动验证

先取得并备份**当前移植 ROM** 的真实 `boot.img`，再用最终 artifact 中的 `Image` 重新打包：

```bash
python3 tools/make_boot_template.py --boot boot-current.img \
  --out-dir bootimg-current --name thyme-current --firmware current-port-rom

python3 tools/pack_boot.py \
  --template bootimg-current/thyme-current.bin \
  --manifest bootimg-current/thyme-current.json \
  --image Image \
  --out boot-thyme-ksun-test.img
```

先检查设备和实时槽位，不要沿用旧记录硬编码槽位：

```bash
fastboot getvar product
fastboot getvar current-slot
fastboot boot boot-thyme-ksun-test.img
```

`product` 必须为 `thyme`。`fastboot boot` 只临时启动，不写分区；如果该 bootloader 不支持，
不要因此直接改成 `flash`，先回到 Recovery 备份 boot。临时启动成功后检查：

```bash
adb shell uname -r
adb shell getenforce
```

版本串应仍为 `4.19.157-perf-g9d90dd04aa7c`，SELinux 应为 `Enforcing`。安装上面的 UAPI 6
管理器，打开后确认驱动可用；给 shell 授权后再检查：

```bash
adb shell su -c id
```

预期包含 `uid=0(root)`。随后逐项测试触控、Wi-Fi、蜂窝、通话、相机、指纹、音频、NFC、
蓝牙和充电。全部通过并已有可恢复的原 boot 后，才考虑永久写入当前 boot 槽。

### B. Recovery：刷 AnyKernel3

`AnyKernel3-thyme-ksun.zip` 会从当前 boot 解包，只替换 kernel Image，保留当前 ramdisk；它不带
也不写 `dtbo`、`vendor_boot` 或 `vbmeta`，并开启 `thyme` 设备检查。操作前仍必须在 Recovery
备份 Boot；刷入后若不能启动，用 Fastboot/Recovery 恢复该备份。

此路径会直接改 boot，不如方案 A 的临时启动安全。不要在没有 boot 备份时尝试，也不要把 ZIP
用于小米 10（`umi`）、小米 10 Pro（`cmi`）或其他 SM8250 设备。

## 已废弃 PE Image 的无 AVB 重打包记录

以下输出使用了已确认不兼容的旧 PE Image，**不得启动或刷入**；记录仅用于证明打包结构本身无误。
当前 Recovery 备份是 201,326,592 B 的 header-v3 原始 boot 分区镜像，不含 AVB footer/vbmeta。
仓库原有的 AVB 模板工具不能用于该镜像，因此使用经过单元测试的
`tools/pack_boot_v3_noavb.py` 重打包，并在未知尾部存在非零数据时强制拒绝。

> **真机纠正（2026-11-26）：** 不得把非零 kernel padding 或 header 所声明 ramdisk
> 之后的 opaque 数据搬到新偏移。该做法即使能做到逐字节“保留”，也会使 `thyme` 循环重启。
> 该工具现在只接受 padding 和尾部都为零的规范 v3 镜像；遇到非零数据必须改用设备上的
> `magiskboot unpack/repack` 规范化，不能添加跳过参数。

| 项 | 值 |
| --- | --- |
| 原 boot SHA-256 | `b0b9c64cd9e19fd9a33f5993c60574416791391037b9c9c40d23559378ff7936` |
| 原 kernel | 52,849,120 B，版本 `4.19.157-perf-g9d90dd04aa7c` |
| 新 kernel | 49,299,472 B |
| ramdisk | 60,676,559 B |
| ramdisk SHA-256 | `f2d75076e9006f72a94b6ae9489c8d7838d1e6b2e86bcf223fb0156cd50d457f` |
| 输出 boot | `boot-thyme-ksun-test.img`，201,326,592 B |
| 输出 SHA-256 | `60f3a74b7d695c02416d23936e1e1deef9d8ef1c1512cae6a282f0b986b7ba1d` |

独立复核确认：header 除 `kernel_size` 外逐字节不变；新 kernel 与最终 `Image` 相同；ramdisk
逐字节不变；kernel padding 与分区尾部均为零；镜像无 AVB 数据。该结果仅说明结构正确，仍需
先用 `fastboot boot` 完成真机启动和硬件功能验证。

## 原 boot 回退文件

后续提供的 Recovery boot 备份已确认有效，其 SHA-256 为
`b0b9c64cd9e19fd9a33f5993c60574416791391037b9c9c40d23559378ff7936`，并包含完全匹配的
原内核和当前移植 ROM ramdisk。必须保留至少两份副本，作为不能启动时的回退文件。

早期普通 ADB shell 读取分区时保存的几十字节只是 `Permission denied` 文本，仍然不是镜像，
禁止使用。也不要使用仓库内来自官方 `V14.0.6.0.TGACNXM` 的 boot 模板替代当前移植 ROM。

### 当前 ROM 的 clean ramdisk 基底

APatch 的 `/data/adb/ap/ori.img` 排除了 APatch 的 KernelPatch，但其 ramdisk 仍是此前的 Magisk
patched ramdisk：`magiskboot cpio ramdisk.cpio test` 返回 `1`。2024-11-15 的 TWRP 备份也是同一
原厂 kernel，但带另一版 Magisk ramdisk，不能只改后缀后直接作为 clean boot 使用。

必须先让 `magiskboot cpio ramdisk.cpio restore` 使用 `.backup` 恢复 ramdisk，并确认恢复后及
二次解包后的 `cpio ... test` 都返回 `0`。本次得到的当前 ROM 干净基底为：

- 文件：`boot-current-rom-clean-restored.img`
- 大小：201,326,592 B
- SHA-256：`aaf203465bff13ca5a4762f9bb8427925aba645ce0101dbcf54454fccd8714d5`
- 原厂 kernel SHA-256：`621437a91f77c3b53629f39f914ee3f58fea9f97827776e345300c99dc177970`
- ramdisk 状态：`stock (0)`，无 Magisk/APatch overlay

该基底已真机启动成功；原厂 kernel banner、Android 启动完成和“无 `su`/无 root daemon”三项均
符合预期。后续所有 KSU/对照镜像都必须从它通过 `magiskboot` 重打包。

### Strict CRC 对照的真机结论

clean ramdisk + exact-stock 无 KSU/KASLR-off 重编 kernel 能进入 Android 并一度报告
`sys.boot_completed=1`，但随后重启。失败启动的 `/proc/modules` 为 0。对 41 个原厂 vendor
`.ko` 的 `__versions` 实测显示：其 1,127 个依赖符号中有 736 个 CRC 与公开源码构建不同；
`module_layout` 为 `0xaad0c453`，而 baseline 为 `0xaf517461`。因此公开树虽有相同 config、release
和 banner，仍不是小米私有模块 ABI 的逐 CRC 对应源码；真机版本必须使用
`ALLOW_CRC_MISMATCH=1`，strict 产物禁止刷入。

## 真机验证顺序

以下步骤必须等重新连接设备并确认拥有可恢复的原 boot.img 后再做：

1. 校验新 boot 的 header 和 ramdisk，仅 kernel 区允许变化，并确认该备份本来就没有 AVB 数据；
2. 优先使用 `fastboot boot boot-thyme-ksun-test.img` 临时启动；
3. 验证开机、触控、Wi-Fi、蜂窝、相机、指纹、音频和充电；
4. 验证 `uname -r` 仍为 `4.19.157-perf-g9d90dd04aa7c`；
5. 安装与该驱动 **UAPI 6** 匹配的 KernelSU-Next 管理器并验证授权；
6. 安装一个无害模块，软重启后验证模块链；
7. 全部通过并重新核对实时槽位后，才考虑永久写入当前 boot。

不要直接刷 `dtbo`、`vendor_boot` 或仓库中其他 ROM 的 boot。也不要在尚未准备原 boot
回退文件时刷入 AnyKernel3 包。

## 已知取舍

- 基线流程关闭 KASLR 和 RELR，以匹配该源码树在 AOSP LLD 下已验证的启动路径；这会降低
  部分内核地址随机化防护。若后续恢复 KASLR，必须作为单独实验重新验证启动稳定性。
- `ALLOW_CRC_MISMATCH=1` 将原厂 vendor 模块的符号 CRC 不一致降级为警告，这是该公开源码树
  兼容原厂 Wi-Fi/音频模块的既有方案，不等同于源码和厂商私有树完全一致。
- 管理器必须与 UAPI 6 驱动匹配。不要仅因管理器提示“可更新”就跨 UAPI 更新。
