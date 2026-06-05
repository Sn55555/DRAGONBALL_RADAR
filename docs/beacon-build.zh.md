# 龙珠 BLE 信标制作与部署指南

这份指南用于制作 7 个实体龙珠信标：`DBALL-1` 到 `DBALL-7`。雷达主板不需要 GPS；每颗“龙珠”只负责广播 BLE 信号，雷达根据 BLE 名称、厂商数据、RSSI 强弱和 IMU 朝向分箱来做接近感与方向感。

## 结论

- 可以不改装 GPS：个人和朋友游玩时，BLE 信标比 GPS 更适合室内、院子、小公园和展会摊位。
- 需要 7 个可供电的 ESP32 信标板，或者先用 1 到 2 个信标做小范围测试。
- 验收不能只看“能烧录”：必须让雷达诊断固件同时看到 7 个 `DBALL-*`，并且主板的 `touch`、`imu`、`ble`、`audio` 都在线。
- 真正完成目标还要跑一次干净 UI 的实地收集，看到 7 次收集事件和召唤动画。

## 需要准备

- 7 块备用 ESP32 开发板。优先用带 USB-C、可稳定供电、带板载天线的板子。
- 7 根短 USB 线，烧录时逐个连接电脑。
- 7 个移动电源，或小锂电池加充电保护板和开关。
- 非金属外壳：塑料球、亚克力盒、纸盒、3D 打印壳都可以。
- 打印标签：用 `tools/generate_beacon_labels.py` 生成 `DBALL-1..7` 标签。
- 绝缘胶带、魔术贴、扎带、记号笔。
- 可选：橙色透明球壳，让实体道具更像“龙珠”。

不要把 ESP32 天线贴在金属、大片水体、人体、地面或电池金属壳旁边。BLE 信号被遮挡后，RSSI 会抖动，方向感会变差。

## 信标广播协议

每个信标固件都会广播：

- BLE 名称：`DBALL-n`，其中 `n` 是 `1..7`。
- Manufacturer data：3 个字节，`0x44 0x42 <index>`。
- Scan response 里的服务 UUID：`7d540001-f82d-4b2f-91c6-4f0f88aa5a11`。

雷达会优先识别 `DBALL-*` 名称，也接受上述 3 字节厂商数据作为备用签名。这样即使某些 BLE 广播包暂时不带完整名称，也能更稳地识别。

## 先构建全部固件

在项目根目录运行：

```sh
tools/build_beacons.sh
```

默认目标板是 `esp32-s3-devkitc1-n8r8`。如果备用 ESP32 不是这个型号，用 PlatformIO board id 覆盖：

```sh
BEACON_BOARD=esp32dev tools/build_beacons.sh
```

广播间隔有三个预设：

```sh
BEACON_PROFILE=fast tools/build_beacons.sh
BEACON_PROFILE=balanced tools/build_beacons.sh
BEACON_PROFILE=battery tools/build_beacons.sh
```

建议第一次联调用 `balanced`，正式藏点用 `battery`。`fast` 反应更快，但更耗电；`battery` 省电，但雷达更新会慢一些。

## 逐个烧录

只烧录一个编号：

```sh
tools/upload_beacon.sh 1
tools/upload_beacon.sh 2
tools/upload_beacon.sh 7
```

多块串口设备同时连接时，指定端口：

```sh
BEACON_PORT=/dev/cu.usbmodem101 tools/upload_beacon.sh 3
```

只想检查命令和编译，不上传：

```sh
BEACON_DRY_RUN=1 tools/upload_beacon.sh 1
```

烧录后串口会打印类似：

```text
Advertising DBALL-1
Interval 100-200 ms
```

如果编号打印错了，重新烧录对应编号，不要靠贴标签修正。

## 一次制作 7 个

推荐用引导脚本。它会提示你一次只插入一块 ESP32，按顺序烧成 `DBALL-1` 到 `DBALL-7`，并写入制作记录：

```sh
tools/flash_beacon_set.sh all
```

正式游玩更建议使用省电配置：

```sh
BEACON_PROFILE=battery tools/flash_beacon_set.sh all
```

如果要先看流程但不接硬件：

```sh
BEACON_SET_DRY_RUN=1 tools/flash_beacon_set.sh 1 2
```

默认输出：

- `output/beacon-set-manifest.md`
- `output/beacon-set-flash.log`

这两个文件可以作为“这套 7 个信标确实按编号烧录过”的制作记录。

## 贴标签和装壳

生成标签：

```sh
tools/generate_beacon_labels.py
```

发布包里也会包含 `docs/beacon-labels.html`。打印时用 100% 比例，每个标签贴到对应信标上。建议标签上保留 4 个状态：

- flashed：已烧录。
- verified：雷达已看到。
- hidden：已藏好。
- found：玩家已找到。

装壳时注意：

- 天线不要被电池贴住。
- 外壳不要用金属漆或铝箔。
- 保留充电口或电源开关。
- 标签可以藏在内侧，但维护时必须能快速区分编号。
- 每颗信标都先开机 5 分钟，确认不会掉电重启。

## 雷达验收 7 个信标

把 7 个信标全部上电，先不要藏起来，放在桌面或房间不同位置。接上雷达主板后运行：

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/verify_beacon_set.sh all
```

这个流程会刷入雷达诊断固件，并要求：

- `touch` 在线。
- `imu` 在线。
- `ble` 在线。
- `audio` 在线。
- 至少看到 7 个 `DBALL-*`。

验收输出：

- `output/beacon-set-verify-report.json`
- `output/beacon-set-verify-report.md`
- `output/beacon-set-verify-raw.log`

只有报告里 `status` 为 `passed`，且 `beaconCount >= 7`，才算实体信标组通过。

## 摆放建议

第一次不要直接上大场地。推荐三轮：

1. 桌面 1 米测试：7 个信标都摆在可见位置，确认雷达能看到完整编号。
2. 房间测试：距离拉到 2 到 6 米，确认转身扫动时橙色 blip 会向强信号方向稳定。
3. 正式藏点：每个点位避免金属柜、地面贴合、人体长时间遮挡和水源旁边。

藏点建议：

- 不要把 7 个点位堆在同一侧，否则方向感会混在一起。
- 每个点位留一个“能靠近但不容易误触”的区域。
- 外壳位置尽量离地 40 厘米以上。
- 先记录编号和位置，再开始给朋友玩。
- 室外只适合短距离和干燥天气；这套信标默认没有防水设计。

## 调校收集距离

默认收集阈值是接近 `-50 dBm` 并保持约 1.2 秒。不同外壳、电池、房间会改变 RSSI。

如果收集太容易，改得更严格：

```sh
COLLECT_RSSI=-45 COLLECT_HOLD_MS=1500 tools/build_radar.sh field upload
```

如果收集太难，改得更宽松：

```sh
COLLECT_RSSI=-55 COLLECT_HOLD_MS=1000 tools/build_radar.sh field upload
```

更可靠的做法是跑校准：

```sh
DIAG_CALIBRATE=1 RADAR_PORT=/dev/cu.usbmodem101 tools/verify_beacon_set.sh monitor
tools/recommend_field_tuning.py output/beacon-set-verify-report.json
```

再按工具给出的 `COLLECT_RSSI` 和 `COLLECT_HOLD_MS` 重新构建 field 固件。

## 常见问题

### 找不到信标烧录串口

先只插一块 ESP32，拔掉无关 USB 设备。macOS 常见端口是 `/dev/cu.usbmodem*` 或 `/dev/cu.wchusbserial*`。仍然找不到时，换一根支持数据传输的 USB 线。

### 雷达只看到部分 DBALL

先把 7 个信标放近一点，确认都已开机。再检查是否有重复编号：重复的 `DBALL-3` 会让某个编号缺失。必要时逐个上电，看报告里的编号变化。

### 信号太跳

换到非金属外壳，天线远离电池和桌面。把信标放高一点。正式游玩时让玩家慢慢转身 1 到 2 秒，不要边跑边看方向。

### 反应太慢

把信标改成 `balanced` 或 `fast`：

```sh
BEACON_PROFILE=balanced tools/flash_beacon_set.sh all
```

如果只是个别信标慢，可能是供电不稳或天线被外壳遮挡。

### 手机 BLE App 能不能代替

可以临时代替 1 到 2 个信标，只要能广播 `DBALL-1` 这种名称。但手机系统可能限制后台广播，稳定性不如 ESP32。正式 7 颗建议使用独立 ESP32 信标。

## 完成标准

这套信标完成后，应当至少有三份证据：

- `output/beacon-set-manifest.md`：7 个编号已按顺序制作。
- `output/beacon-set-verify-report.json`：雷达看到 7 个实体信标，硬件模块在线。
- `output/field-hunt-report.json`：真实干净 UI 游玩中完成 7 次收集，并进入召唤状态。

没有第三项之前，软件和信标可以算“准备好”，但项目目标还不能算完成。
