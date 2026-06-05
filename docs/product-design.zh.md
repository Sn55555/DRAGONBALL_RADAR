# 龙珠雷达产品设计与可行性说明

目标是做一个个人和朋友一起玩的龙珠雷达道具：拿在手里像动漫里的雷达，
开机有胶囊风格动画，主界面是绿色矩形坐标网格，靠近隐藏的 7 个“龙珠”
信标时出现目标点，收集完 7 个后进入召唤动画。

硬件目标板：

- Waveshare ESP32-S3-Touch-AMOLED-1.75C
- 官方页面：<https://www.waveshare.net/shop/ESP32-S3-Touch-AMOLED-1.75C.htm>

官方规格要点：1.75 英寸 466 x 466 AMOLED，CO5300 QSPI 显示驱动，
CST9217 电容触摸，ESP32-S3R8，8MB PSRAM，32MB Flash，BLE 5，
QMI8658 六轴 IMU，双麦克风、音频编解码与扬声器相关硬件，Type-C，
电池接口和 GPIO 焊盘。

## 结论

这个项目可行，但定位应是“近距离寻物 / 派对寻宝道具”，不是户外导航设备。

原因：

- 这块开发板没有板载 GPS/GNSS。
- 室内或小场地玩法本来也不适合依赖 GPS，GPS 在室内弱、漂移大。
- ESP32-S3 有 BLE，适合扫描 7 个低功耗广播信标。
- 板载 IMU 可用来估计玩家旋转方向，让目标点在雷达网格上呈现相对方向。
- AMOLED 圆屏、触摸、音频和铝合金外壳适合做成沉浸式道具。

因此第一版不加 GPS。用 7 个 `DBALL-1..7` BLE 信标作为“龙珠”，雷达只做
相对寻物和收集反馈。

## 不支持 GPS 怎么办

不需要为第一版补 GPS。

推荐方案：

1. 每个龙珠信标周期性广播 BLE 名称或制造商数据。
2. 雷达扫描 BLE RSSI，估计哪个信标更近。
3. 玩家缓慢转动雷达时，IMU 提供朝向变化，固件把不同朝向下的 RSSI 强度
   累积成 16 个方向 bins。
4. UI 把目标点吸附到矩形网格上，靠近时加快音频 ping，并出现收集锁定。
5. 收集满 7 个后，7 个目标沿横竖网格线汇聚到中心，进入召唤动画。

这套玩法的体验重点是“像雷达一样找东西”，不是地图定位。

## 是否能改装 GPS

可以改，但不建议作为第一版。

可行改装路径：

- 外接小型 GNSS 模块，通过 UART 或可用 GPIO 焊盘连接。
- 需要给 GNSS 天线留出朝天方向和无遮挡位置。
- 需要额外供电预算，电池续航会下降。
- 需要在固件里加入 NMEA 解析、坐标存储、地图比例和目标坐标管理。
- 室外才有明显价值，室内体验通常不如 BLE 信标稳定。

更推荐的升级路线：

- V1：BLE 信标 + IMU，相对寻物。
- V1.5：手机蓝牙桥接，手机提供 GPS/指南针，雷达仍只负责道具 UI。
- V2：UWB 信标，提高近距离方向和距离精度。
- V3：外接 GNSS，只用于户外大范围玩法。

## MVP 功能

必须完成：

- 开机动画：绿色网格唤醒、扫描带、胶囊风格 Logo、7 个进度 tick。
- 主 UI：圆形 AMOLED 内显示矩形坐标网格，不使用同心圆环。
- 正式模式无调试文字，只有目标点、锁定、收集和召唤反馈。
- `field` 模式：真实游玩，空网格开始，只响应实体 BLE 信标。
- `fielddiag` 模式：干净 UI + 隐藏串口记录，用于真实游玩验收。
- `sim` 模式：一块板模拟 7 个龙珠，用于上板测试。
- `diag` 模式：硬件 bring-up 和调试 HUD。
- 7 个 `DBALL-*` BLE 信标固件。
- 视觉 QA、固件 UI 契约审计、发布包自检和硬件验收脚本。

当前仓库已经实现这些软件交付物，硬件闭环仍需要真板和实体信标报告证明。

## 创新点

- GPS-free 龙珠雷达：不依赖地图和坐标，靠 BLE + IMU 做相对雷达感。
- 动漫式 UI 约束自动化：固件审计会防止主界面误改成圆环雷达或调试 HUD。
- 干净 UI 与隐藏诊断分离：朋友看到的是道具界面，电脑能记录完整 DIAG 证据。
- 一块板模拟验收：没有 7 个信标时，也能先验证屏幕、触摸、IMU、BLE、音频和召唤流程。
- 发布包自检：交给别人前可以无硬件验证包完整性和 mock 链路。
- 现场工具化：信标标签、field kit、中文 quickstart、可复现的报告和 checksum。
- 私有 Logo 钩子：本地可以编译胶囊风格开机图形，发布包不泄露私有源文件。

## 硬件组成

主雷达：

- ESP32-S3-Touch-AMOLED-1.75C 主板。
- Type-C 数据线。
- 可选锂电池版本或外接 3.7V 电池。
- 可选挂绳、外壳保护、屏幕保护膜。

7 个龙珠信标：

- 任意能跑 ESP32 Arduino BLE 广播的小 ESP32 开发板。
- 每个信标刷入一个编号：`DBALL-1` 到 `DBALL-7`。
- 每个信标独立供电，推荐小电池盒或带开关锂电模块。
- 打印 `docs/beacon-labels.html`，贴编号和隐藏位置记录。

## 软件模式

| 模式 | 用途 | 是否干净 UI | 是否有串口 DIAG |
| --- | --- | --- | --- |
| `field` | 真实游玩 | 是 | 否 |
| `fielddiag` | 真实游玩记录 | 是 | 是 |
| `sim` | 一块板上板模拟 | 是 | 是 |
| `diag` | 硬件 bring-up | 否，带 HUD | 是 |
| `debug` | UI/方向调试 | 否，带 HUD | 可选 |

## 验收路径

无硬件：

```sh
tools/selftest_release.py
```

这只证明发布包和 mock 链路，报告中必须是 `hardwareProof=false`。

一块主板：

```sh
tools/run_board_sim_test.py port-check
RADAR_PORT=/dev/cu.usbmodem101 tools/run_board_sim_test.py auto
```

通过后证明真板上的屏幕、触摸、IMU、BLE 初始化、音频和 7 个模拟收集流程。

完整硬件：

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all
```

完成条件：

- 硬件 bring-up passed。
- 一块板 sim bench passed。
- 7 个实体信标都被看到。
- field hunt 记录 7 次收集事件。
- 最终 `summon=true`。
- `output/project-status.md` 显示 `Hardware completion: PASS`。

## 风险与规避

BLE RSSI 波动：

- 目标点做滤波和网格吸附。
- 玩法设计成“越近越强”和“转动找方向”，不承诺精确米级定位。
- 通过 `recommend_field_tuning.py` 按场地调 `COLLECT_RSSI`。

室内遮挡和人体吸收：

- 信标不要贴在金属盒里。
- 让朋友隐藏在布袋、纸盒、塑料球里更稳定。
- 先用 `verify_beacon_set.sh` 确认 7 个信标都能被看到。

电池和续航：

- 信标广播间隔不要太短。
- 每轮游戏前用 field kit 勾选电量和开关状态。

Logo 和版权边界：

- 私有胶囊风格开机图形只在本地编译进固件。
- 发布包只包含 `private_boot_logo.h.example`，不复制私有 Logo 源文件。

硬件串口不可见：

- 换数据线，优先排除纯充电线。
- 运行 `tools/run_board_sim_test.py port-check`。
- 只看到蓝牙、耳机或 debug-console 时，不要继续刷机。

## 当前状态

截至当前仓库状态：

- 软件包、预览、视觉 QA、固件 UI 契约、自检和发布包校验均已通过。
- 发布包位置：`output/release-current.tar.gz`。
- 真板串口尚未识别到，硬件验收报告缺失。
- 因此项目状态应继续保持 `Hardware completion: NOT PROVEN`，不能标记 goal 完成。
