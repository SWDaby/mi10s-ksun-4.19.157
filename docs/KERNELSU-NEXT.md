# 小米 10S（thyme）KernelSU-Next 4.19.157 构建

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
| 内核源码 | `PixelExperience-Devices/kernel_xiaomi_thyme` |
| 内核 commit | `bc9f46dca6f2d608578180543cc2ff9ee5ee8a82` |
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

## 刷入前仍缺少的材料

普通 ADB shell 无权读取 `/dev/block/by-name/boot_a`，因此当时未能备份当前 boot 分区。
保存下来的几十字节只是 `Permission denied` 文本，**不是镜像，禁止用于打包或刷入**。

必须先通过以下任一可信来源取得当前 ROM 的真实 `boot.img`：

- ROM 作者提供的同一构建包；
- 已有 Recovery 中读取活动槽位；
- Fastboot/Recovery 的只读分区备份功能。

拿到后先核对：

```bash
sha256sum boot-current.img
python3 tools/make_boot_template.py --boot boot-current.img \
  --out-dir bootimg-current --name thyme-current --firmware current-port-rom
```

再用当前 boot 模板和 Actions 产出的 `Image` 重打包。不要使用仓库内
`bootimg/thyme-boot-template.bin`：那个模板来自官方
`V14.0.6.0.TGACNXM`，ramdisk 未必适配现在的 Android 14 移植系统。

## 真机验证顺序

以下步骤必须等重新连接设备并确认拥有可恢复的原 boot.img 后再做：

1. 校验新 boot 的 header、ramdisk、AVB footer，仅 kernel 区允许变化；
2. 优先使用 `fastboot boot boot-thyme-ksun-test.img` 临时启动；
3. 验证开机、触控、Wi-Fi、蜂窝、相机、指纹、音频和充电；
4. 验证 `uname -r` 仍为 `4.19.157-perf-g9d90dd04aa7c`；
5. 安装与该驱动 **UAPI 6** 匹配的 KernelSU-Next 管理器并验证授权；
6. 安装一个无害模块，软重启后验证模块链；
7. 全部通过后才考虑 `fastboot flash boot_a ...`。

不要直接刷 `dtbo`、`vendor_boot` 或仓库中其他 ROM 的 boot。也不要在尚未准备原 boot
回退文件时刷入 AnyKernel3 包。

## 已知取舍

- 基线流程关闭 KASLR 和 RELR，以匹配该源码树在 AOSP LLD 下已验证的启动路径；这会降低
  部分内核地址随机化防护。若后续恢复 KASLR，必须作为单独实验重新验证启动稳定性。
- `ALLOW_CRC_MISMATCH=1` 将原厂 vendor 模块的符号 CRC 不一致降级为警告，这是该公开源码树
  兼容原厂 Wi-Fi/音频模块的既有方案，不等同于源码和厂商私有树完全一致。
- 管理器必须与 UAPI 6 驱动匹配。不要仅因管理器提示“可更新”就跨 UAPI 更新。
