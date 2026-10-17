# F.06 stock-baseline 实机测试

## 先准备回滚

保留手机当前 F.06 的原厂 boot，并确认已有刷写工具可以重新刷回。
不要覆盖你在备份目录中的原文件。仓库 `boot/boot.img` 是同一镜像，SHA256：

```text
2dca84788aa3d5d60a839cf393319fac6da05cff19f34b17897af941378cb9e9
```

如果测试失败，沿用已经验证可恢复的工具，把**原厂 boot 写回原来测试的 boot 分区**。
无需格式化 userdata，也不要为了这轮测试更改 vbmeta、dtbo 或其他分区。

仅在设备已经确认支持 fastboot 刷写时使用下面的示例。先检查设备和分区：

```powershell
fastboot devices
fastboot getvar current-slot
fastboot getvar has-slot:boot
```

非 A/B 的 boot 分区，回滚示例：

```powershell
fastboot flash boot "stock-boot.img"
fastboot reboot
```

如果确认 boot 是 A/B 分区，记录当前 slot；对该 slot 使用明确的分区名，
例如当前是 a 时写 `boot_a`，当前是 b 时写 `boot_b`。测试与回滚写同一分区，
不猜测 slot，不同时改写两槽，不主动切槽。不支持 fastboot 时继续使用已验证的原刷写工具。

## 最小测试

1. 确认当前运行 F.06，原厂 boot 正常启动，Bootloader 已解锁。
2. 下载 stock-baseline artifact，检查 `sha256sums.txt`、`repack/repack-check.txt` 和配置差异。
3. 使用既有刷写方式，仅将 `boot-stockbaseline.img` 写到对应 boot 分区。
4. 立即按 `DEBUG-BOOTLOOP.md` 抓日志。
5. 若进入系统，观察至少 10 分钟，检查屏幕、触控、Wi-Fi、移动网络、音频、充电，再正常重启一次。
6. 若循环重启或关键功能异常，保存日志并刷回原厂 boot，确认恢复。

回传 Actions run 链接、测试镜像 SHA256、能否进入系统/持续多久、关键功能结果和日志。
首轮仅测试 stock-baseline，不安装 ReSukiSU 或额外内核模块。

只有这个阶段通过实机测试，才构建 minimal ReSukiSU；Guard 和 path_umount 的 A/B 测试放在后续阶段。
