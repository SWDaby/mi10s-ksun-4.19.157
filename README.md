# thyme (Mi 10S) Droidspaces 内核 —— GitHub Actions 构建包

原厂基线：`V14.0.6.0.TGACNXM`（MIUI 14 / Android 13，kernel 4.19.157-perf-g9d90dd04aa7c）
基座源码：`KirinNova/android_kernel_xiaomi_sm8250` 分支 `HyperSU`（4.19.325，CAF + MIUI 树）
基座配置：`arch/arm64/configs/thyme_stock-defconfig`（由原厂 config 生成，与原厂差 100 项，多为废弃符号）

---

## 一、这个包做什么

| 步骤 | 内容 |
| --- | --- |
| 配置层 | 原厂 config 全保留，只叠加 Droidspaces 官方 non-GKI 清单（命名空间 / cgroup / devtmpfs / veth+bridge+macvlan / netfilter） |
| 关闭项 | `ANDROID_PARANOID_NETWORK`、`PERF_HUMANTASK`（Droidspaces 硬性要求） |
| 补丁 | `01` xt_qtaguid 内核 panic 修复；`02` cgroup 文件前缀恢复 |
| 构建期 | `LOCALVERSION_AUTO=n`、`DEBUG_INFO=n`（不进 Image，只提速） |
| 产物 | `Image`、`AnyKernel3-thyme-droidspaces.zip`、`config-final.txt`、`config-diff.txt`（与原厂配置逐行差异）、`build.log` |
| **不做** | 不碰 `vendor_boot` / `dtbo` / `vbmeta` / ramdisk；AnyKernel3 只写 `Image`，不写 dtb |

> `01` 补丁会自动跳过：原厂 config 里没有 `CONFIG_NETFILTER_XT_MATCH_QTAGUID`，该内核树也没有 `net/netfilter/xt_qtaguid.c`，panic 路径本来就不存在。补丁仍留在仓库里备查，脚本用 `git apply --check` 判断，不适用就跳过、不硬套。

> 为什么只换 Image：实测 `boot.img` 是 header **v3**（v3 结构里没有 dtb 字段）、kernel 内无 FDT，三个完整 kona DTB 都在 `vendor_boot.img` 里。只换 Image = 硬件初始化路径 100% 原厂。已用 Python 重打包工具做过**空跑验证**：用原厂 kernel 往返重打包，输出与 `m10s_boot.img` MD5 完全一致（03A3BE9B…）；再换成 60MB 假 kernel 验证扩容路径，ramdisk 逐字节不变、vbmeta 自动搬移且 footer 指针同步更新。

---

## 二、上传到 GitHub（一次性，约 3 分钟）

1. 新建仓库：<https://github.com/new>
   - 名字随意，例如 `thyme-droidspaces`
   - **Private / Public 都行**（Private 免费额度 2000 分钟/月，本构建约 40–60 分钟）
   - 不要勾 `Add a README`（避免冲突）
2. 点 **Add file → Upload files**
3. 把本目录（`droidspaces-kernel`）里的**全部文件和文件夹**拖进去（`.github`、`scripts`、`config`、`patches`、`anykernel`、`README.md`）
   - 网页上传支持拖文件夹；若拖拽不成功，就在本地把这几个目录逐个上传
4. 点 **Commit changes**

## 三、跑构建

1. 仓库页 → **Actions** → 左边选 **Build thyme Droidspaces kernel** → 右边 **Run workflow**
2. 三个输入保持默认即可（`KirinNova/...`、`HyperSU`、`thyme_stock-defconfig`），点绿色 **Run workflow**
3. 等 40–60 分钟。**配置断言失败会在前 5 分钟就红叉**，日志里会直接写哪一项没存活
4. 绿勾后，进这次 run 页面底部 **Artifacts** → 下载 `thyme-droidspaces-<编号>.zip`
5. 把下载到的 zip 放到 `C:\Users\Administrator\Desktop\mi10s\`，告诉我 —— 我本地做最后一步：用原厂 `m10s_boot.img` 重打包出 `boot-droidspaces.img`（逐字节校验 ramdisk 未变、dtb 段未变），并核对 `Image` 的版本串与 config

---

## 四、刷机

产物有两种刷法，任选：

**A. 电脑 fastboot（最直接）**
```powershell
fastboot flash boot boot-droidspaces.img
fastboot reboot
```
> 注意：本镜像的 ramdisk 是原厂 ramdisk。如果你现在是 Magisk 打补丁的 boot，刷完会掉 root，开机后进 Magisk App → 安装 → 选择并修补文件 → 选 `boot-droidspaces.img` → 再 `fastboot flash boot` 一次即可（内核不会被 Magisk 改掉）。

**B. 手机上刷（保住现有 Magisk）**
用任意支持 AnyKernel3 的内核刷写器（Kernel Flasher / EX Kernel Manager / TWRP）刷 `AnyKernel3-thyme-droidspaces.zip`：
解包**当前** boot → 只换 kernel → 回写。Magisk 补丁的 ramdisk 会被保留，AK3 会自动做 Magisk 兼容处理。

**回退（30 秒）**
```powershell
fastboot flash boot m10s_boot.img
```

---

## 五、刷完怎么验收

```bash
uname -r                                   # 应为 4.19.325-perf
zcat /proc/config.gz | grep -E 'CONFIG_(PID_NS|IPC_NS|USER_NS|SYSVIPC|DEVTMPFS|MACVLAN|NF_TABLES|CGROUP_DEVICE|CGROUP_PIDS|CFS_BANDWIDTH)='
zcat /proc/config.gz | grep -E 'PARANOID|HUMANTASK'   # 两项都应为 "is not set"
```

1. Droidspaces App → **Check Requirements** 全绿
2. 起容器：`ip addr` / `ping` / `apt update`（验 NAT、veth、iptables）、`ps`、`mount`（验 devtmpfs、cgroup）
3. 原厂功能回归：通话、Wi-Fi、热点、相机前后摄、指纹、NFC、充电功率、zram（`cat /sys/block/zram0/mm_stat` 有数据）、触控增强
4. 压力：容器内 `stress-ng --cpu 4` 看 CPU 配额是否生效（CFS_BANDWIDTH）

---

## 六、已知取舍（只有这几项，且都绕不过去）

| 改动 | 影响 | 说明 |
| --- | --- | --- |
| 关 `PERF_HUMANTASK` | MIUI 性能提示 / 部分游戏调度特性降级 | Droidspaces 明文要求；该树自带的 `thyme_stock-defconfig` 本来也是关的 |
| 关 `ANDROID_PARANOID_NETWORK` | 失去 AID_INET 组级网络限制 | 容器联网必需；per-uid 网络管控仍由 netd/eBPF 负责，所有 MIUI 定制内核都如此 |
| 开 `USER_NS` | 增加内核攻击面 | 容器必需 |
| 4.19.325（原厂 4.19.157） | `uname -r` 变化；原厂 6 个非关键 vendor 模块（msm_rdbg / usb_gspca / dvb_mpq×2 / lcd_class / llcc_perfmon）CRC 不匹配会加载失败 | 全是非关键项，不影响开机与外设；`MODULE_SIG_FORCE=n`，不会因此拒绝启动 |
| 不刷 dtb | 无 | 原厂 DTB 在 vendor_boot，本来就是这台机器的正确 DTB |

---

## 七、目录说明

```
.github/workflows/build.yml     Actions 流程
scripts/configure.sh            基线 config + Droidspaces 层 + 断言 + 打补丁
scripts/build.sh                编译 Image + 打 AnyKernel3
config/stock-4.19.157-thyme.config   从原厂 boot 的 IKCONFIG 解出的完整 config（比对基线）
patches/01-fix-xt-qtaguid-panic.patch
patches/02-fix-cgroup-file-prefix.patch
anykernel/anykernel.sh          只写 Image、不写 dtb/dtbo
```
