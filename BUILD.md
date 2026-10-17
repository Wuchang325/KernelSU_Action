# Reno7 SE F.06：Stage 1 stock baseline

本阶段只验证 OPPO 公开源码重新编译后能否运行在 `PFCM00domestic_11_F.06`。
不集成 KernelSU、ReSukiSU、SUSFS、path_umount、KPM 或 hide_stuff。
现有 ReSukiSU workflow 保留；请明确选择 **Reno7 SE F.06 Stock Baseline**。

## 固定输入

版本和来源统一放在 `config/reno7se-stock-baseline.env`：

- 官方 kernel：`cce8dd6161b12b9ce24176dbf5aa1a5a757cc91b`。
- 官方 modules/vendor：`b4d84c6739c700f260da59d6df4efec8413264d2`。
- Android 12 release 的 `clang-r383902`，Clang 11.0.1；配套 AOSP GCC 4.9 仓库提供交叉 binutils，
  这些版本已不含 GCC 编译器，实际 C/汇编编译使用 Clang。
- F.06 实机 config：`config/PFCM00-F06-stock-kernel.config`。
- 原厂 boot：`boot/boot.img`，SHA256：
  `2dca84788aa3d5d60a839cf393319fac6da05cff19f34b17897af941378cb9e9`。

原厂 boot 已替换仓库原有的 Qualcomm 示例文件。其内嵌 config 的 SHA256 为
`0abae937608160934018ef390390bf4a3361bf3b4ac717f571c955c6e67703d3`，与实机配置一致。
配置文本先统一 LF 换行再校验；工具链按不可变的 AOSP commit 下载并记录下载包哈希。

## 构建

GitHub Actions → **Reno7 SE F.06 Stock Baseline** → **Run workflow**。
main 上构建相关文件发生变化时也会自动触发。无需选择 ReSukiSU 功能。

本地编译需要 x86_64 Linux、约 30 GB 可用空间及 workflow 中列出的依赖：

```bash
bash scripts/stock-baseline.sh
```

脚本要求新的 `kernel_workspace`，不会覆盖已有源码目录。Windows 可以直接运行 Python 镜像检查；
完整内核编译使用 GitHub Actions 或具备 Linux 编译环境的主机。

## 与原厂的差异

先将完整实机配置复制为 `out/.config`，执行 `olddefconfig`，保存变化；不从公开 defconfig 重建配置。
随后仅关闭公开源码缺少 `cust.dtsi` 的两项 DT 镜像构建开关，并再次执行 `olddefconfig`。
kernel-only 重打包保留原厂 DTB 的整个厂商封装区域，不生成或刷写 dtbo。

源码层面恢复 OPPO vendor 相对链接，修正七个 charger 的完整 Android 目录引用，
让 charger 子目录继承内核头文件搜索路径。这些改动完整保存在源码 diff 中。
默认不批量关闭 `-Werror`，不修改 guard 代码或宏。make 的 include 搜索目录显式包含源码根目录，
确保 `O=out` 子构建仍能读取 OPPO 自带的 feature makefiles；其中也明确记录了当前 TARGET_PRODUCT。

MODVERSIONS、模块签名强制校验、KALLSYMS、KPROBES、OverlayFS、四项 OPLUS Guard
必须保留实机配置值，否则构建失败。其他 `olddefconfig` 差异也会保留供审查；
大量差异意味着需要调查公开 Kconfig 与生产源码之间的差异。

## 产物

下载 `Reno7SE-F06-stock-baseline-<run number>` artifact，包含：

- `Image`、`Image.gz`、`boot-stockbaseline.img`。
- `config.original`、`config.after-olddefconfig`、`config.build-input`、`config.final`、`.config` 和差异文件。
- `Module.symvers`、`System.map`、`vmlinux.gz`、`utsrelease.h`、`compile.h`。
- 构建日志、源码版本、编译器版本、源码修改 diff、SHA256 清单。
- `repack/` 中的前后 metadata、校验报告和镜像哈希。

失败也会上传已经生成的诊断文件。不会上传模块签名私钥。
启用 MODULE_SIG_FORCE 不代表 CI 生成的签名证书能验证原厂外置模块；
产物会记录构建证书指纹，实际加载结果仍需设备日志确认。

## 单独重打包

工具仅支持本项目提供的 F.06 原厂 boot-v2 / 2048 布局，拒绝其他 stock 哈希：

```powershell
python tools/stock_boot.py inspect boot/boot.img
python tools/stock_boot.py repack --stock boot/boot.img --kernel Image.gz --output boot-stockbaseline.img --avbtool avbtool.py --report-dir repack-report
```

`avbtool.py` 必须来自 AOSP AVB commit
`8261ecd67956f6e9647ff5fd4aeb829f75fb3f66`；CI 自动下载，下载地址见构建脚本。
无需猜测 mkbootimg 参数，输出路径不能覆盖任何输入。

工具重新解析输出，逐项验证原始 ramdisk、整个 DTB 区域、cmdline、地址、OS version、header 和 page size。
允许变化的是 kernel、kernel size、header checksum 及必须重算的 AVB metadata。
OEM 私钥不可用，因此 AVB 使用 **NONE（未签名）** 的新 hash descriptor，并执行 AOSP `verify_image`。
这不是有效的 OEM 签名，适用于已解锁设备的测试；工具不会修改设备 vbmeta。

构建与重打包成功只证明产物生成和结构校验通过。实机稳定启动之前，不进入 ReSukiSU 阶段。

参考：[AOSP AVB](https://android.googlesource.com/platform/external/avb/+/8261ecd67956f6e9647ff5fd4aeb829f75fb3f66/README.md)。
