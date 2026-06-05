# 龙珠雷达上板模拟测试指南

这一步用于在只有一块 Waveshare ESP32-S3-Touch-AMOLED-1.75C 主板、还没有
7 个实体龙珠信标时，先验证雷达软件能在真板上跑通。

它不需要 GPS。当前设计靠 BLE 龙珠信标做寻物逻辑；`sim` 固件会在雷达固件
内部注入 7 个确定性的 `DBALL-*` 目标，用来测试屏幕、触摸、IMU、BLE 初始化、
音效、7 次收集事件和最终召唤状态。

## 1. 接板并找串口

先用 USB 数据线连接开发板，然后运行：

```sh
tools/run_board_sim_test.py port-check
```

如果识别成功，会看到类似：

```text
Selected RADAR_PORT=/dev/cu.usbmodem101
```

如果只看到蓝牙、耳机或 `debug-console`，说明当前系统还没识别到 ESP32-S3。
换一根数据线、换 USB 口，确认开发板上电，再重新运行上面的命令。

需要更明确的排查报告时，运行：

```sh
tools/diagnose_usb_serial.py
```

它会生成：

```text
output/usb-serial-diagnosis.json
output/usb-serial-diagnosis.zh.md
```

报告会区分“没有任何串口”、“只看到蓝牙/耳机/debug-console”、“多个候选串口”
和“已找到唯一 ESP32-S3 候选”。
它还会记录 macOS USB 设备层是否看到了疑似 ESP32-S3、USB-JTAG、CP210、CH340
或 WCH 设备：如果 USB 层能看到板子但没有 `/dev/cu.*` 串口，优先按 BOOT/Reset、
关闭占用串口的软件，并检查 USB CDC/JTAG 驱动或权限；如果 USB 层也看不到板子，
优先换数据线、直连电脑 USB 口并确认主板供电。

如果你正在反复换线或按 BOOT/Reset，可以让工具等待串口出现并自动跑一块板
模拟验收：

```sh
tools/first_run_zh.py live
tools/wait_for_radar_port.py --run-auto
```

`tools/first_run_zh.py live` 是推荐的一键现场入口：它会先跑上板前模拟验收和
USB 诊断，再等待串口并自动跑一块板模拟。如果只想等待串口，运行
`tools/wait_for_radar_port.py --run-auto`。

等待工具会生成 `output/radar-port-watch/radar-port-watch.zh.md`，并且只有真正跑通
`auto` 上板模拟时才会把 `hardwareProof` 标记为 `true`。
等待报告也会记录每次轮询的 USB 设备层状态：如果从 `no-usb-devices` 变成
`radar-usb-present`，说明线缆/供电/BOOT 动作已经让系统看到板子；如果一直没有
串口，再重点查下载模式、USB CDC/JTAG 驱动、权限或串口占用。

## 2. 运行一块板模拟验收

把上一步识别出的串口填到 `RADAR_PORT`：

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/run_board_sim_test.py auto
```

这个命令会做四件事：

1. 校验 `output/release-current` 发布包是否完整。
2. 刷入发布包里的 `dragon-radar-sim-factory.bin`。
3. 监听 USB DIAG 串口。
4. 要求真板报告触摸、IMU、BLE、音频在线，并完成 7 个模拟龙珠收集和召唤。

从复制出去的发布包根目录运行时，命令相同：

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/run_board_sim_test.py auto
```

## 3. 通过标准

通过后会生成：

```text
output/board-sim-current/bench-sim-report.json
output/board-sim-current/bench-sim-report.md
output/board-sim-current/bench-sim-raw.log
output/board-sim-current/board-sim-summary.json
```

在复制出去的发布包中，对应目录是：

```text
evidence/board-sim/bench-sim-report.json
evidence/board-sim/bench-sim-report.md
evidence/board-sim/bench-sim-raw.log
evidence/board-sim/board-sim-summary.json
```

关键字段应为：

```json
{
  "status": "passed",
  "hardwareProof": true
}
```

`bench-sim-report.json` 中还应满足：

```json
{
  "status": "passed",
  "collectionCount": 7,
  "summon": true,
  "simulatedBle": true
}
```

这只能证明一块主板的显示、触摸、IMU、BLE 初始化、音频路径和 UI/收集流程
可用。它还不能证明 7 个实体 BLE 信标和真实场地玩法。

## 4. 无板自检

没有接硬件时，可以先验证发布包里的脚本、DIAG 解析器和报告生成器：

```sh
tools/run_preboard_acceptance.py
tools/selftest_release.py
tools/run_board_sim_test.py mock
```

推荐先跑 `tools/run_preboard_acceptance.py`。它会把发布包校验、mock 一块板模拟、
七球 DIAG 回放和中文边界报告聚合成一次上板前模拟验收，并生成：

```text
output/preboard-acceptance-current/preboard-acceptance-summary.json
output/preboard-acceptance-current/preboard-acceptance.zh.md
output/preboard-acceptance-current/release-selftest/board-sim-mock/bench-sim-report.json
```

也可以单独跑 `tools/selftest_release.py`。它会检查发布包完整性，再调用发布包里的
mock 上板模拟，并生成：

```text
output/release-selftest-current/release-selftest-summary.json
output/release-selftest-current/release-selftest-summary.md
```

mock 通过后会生成：

```text
output/board-sim-mock/board-sim-summary.json
```

其中必须是：

```json
{
  "status": "passed",
  "hardwareProof": false
}
```

`hardwareProof: false` 表示这不是硬件证明，不能用来结束项目验收。
`output/project-status.md` 会把这条证据列为 `Mock one-board simulation`；
真正接板后生成的 `output/bench-sim-report.json` 会单独列为
`Real one-board simulated bench`。

## 5. 常见失败处理

`No likely ESP32-S3 port found`

- 先运行 `tools/diagnose_usb_serial.py` 保存当前 USB/串口诊断报告。
- 也可以运行 `tools/wait_for_radar_port.py --run-auto`，再换线/按 BOOT/Reset，
  等它自动发现 ESP32-S3 后继续跑一块板模拟。
- 换 USB 数据线，确认是数据线不是纯充电线。
- 换电脑 USB 口或扩展坞端口。
- 按一下开发板 reset，再重新运行 `tools/run_board_sim_test.py port-check`。

`Display init failed` 或屏幕黑屏

- 确认刷的是 `sim` factory 固件。
- 重新运行 `RADAR_PORT=/dev/cu.usbmodem101 tools/run_board_sim_test.py auto --erase`。
- 如果仍失败，进入 `diag` bring-up：`RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh bringup`。

`touch/imu/ble/audio offline`

- 重新插拔并复位开发板。
- 确认没有同时开着其他串口监视器占用端口。
- 先跑 `tools/run_board_sim_test.py auto --raw` 看原始 DIAG 行。

`collectionCount` 小于 7 或 `summon` 不是 `true`

- 延长监听时间：`RADAR_PORT=/dev/cu.usbmodem101 tools/run_board_sim_test.py auto --timeout 90`。
- 确认刷入的是 `sim` 固件，而不是 `field` 或 `fielddiag`。

## 6. 下一步

一块板模拟验收通过后，再进入完整硬件闭环：

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all
```

完整闭环需要：

- 硬件 bring-up 通过。
- 一块板模拟验收通过。
- 7 个实体 `DBALL-1..7` BLE 信标都能被雷达看到。
- 一局真实 field hunt 记录到 7 次收集事件。
- 最终 `summon=true`。

只有这些都通过后，`output/project-status.md` 才能从 `Hardware completion:
NOT PROVEN` 变成 `Hardware completion: PASS`。
