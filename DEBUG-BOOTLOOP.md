# F.06 启动日志与判读

测试前在正常系统上授权此电脑的 ADB。刷入后立刻开两个 PowerShell 窗口。

窗口一：

```powershell
adb wait-for-device
adb logcat -b all -v threadtime > bootloop-logcat.txt
```

窗口二：

```powershell
adb wait-for-device
adb shell dmesg > bootloop-dmesg.txt
```

ColorOS user build 可能拒绝 dmesg；保留拒绝信息和 logcat 即可。
不要为了获取日志，先给 baseline 加 root。如果 ADB 断开，保留已捕获文件；
用新的文件名重新运行抓取，避免覆盖前一次日志。

重启后，如果 Recovery 确实开放 ADB shell：

```powershell
adb shell ls -la /sys/fs/pstore
adb pull /sys/fs/pstore pstore
```

没有权限或目录为空都应如实记录，不能据此认定没有 panic。
回滚前尽量保存 `console-ramoops*`、`dmesg-ramoops*`、`pmsg-ramoops*`。

## 判读顺序

- `Kernel panic`、`Oops`、`BUG:`、`Call trace`：定位 kernel runtime。
- `disagrees about version of symbol`、`Unknown symbol`、`invalid module format`：对照 `Module.symvers` 和 vendor 模块。
- `module verification failed`、`Required key not available`：检查实际签名证书与 MODULE_SIG_FORCE。
- `watchdog`、`init`、`system_server`、`zygote`、`vold`、HAL fatal：区分服务退出与 kernel panic。
- 后续 ReSukiSU 阶段再重点检查 `ksu`、`oplus_root`、`oplus_exec`、`oplus_mount`。

如果已有原厂 vendor `.ko`，另外回传其 `modinfo` 输出（vermagic、depends、signer、sig_key）、
`readelf -S` 输出及文件哈希。不要单凭 uname/UTS_RELEASE 相同判断 ABI 已兼容。

OPLUS Root Guard 的函数名含 reboot，不等于直接重启整机；需要看调用路径和日志。
Recovery 的“系统损坏”提示也不能独立证明 userdata 已损坏。

无论测试结果如何，回传构建产物中的 config diff 和日志；
stock-baseline 本身失败时，先查公开源码、工具链、配置、ABI 和模块签名，不继续叠加 root 功能。
