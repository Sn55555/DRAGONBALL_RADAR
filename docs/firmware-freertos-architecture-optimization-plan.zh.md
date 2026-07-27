# Capsule Radar ESP32-S3 FreeRTOS 架构后续优化计划

> 文档状态：计划已完成，尚未开始架构实施
> 计划日期：2026-07-27
> 当前分支：`codex/ble-phone-gateway`
> 计划基线提交：`a2ea201`，外加当前工作树中尚未提交的语音、BLE 网关、iOS、Relay 与 OTA 调整
> 强制启动条件：昨晚的语音效果调优完成真机验收、冻结并形成可回退检查点
> 执行原则：先固定声音，再改变调度；先测量，再拆分；每一阶段都可独立验证和回滚

## 1. 计划结论

当前项目已经使用 FreeRTOS，但还没有充分发挥它的任务隔离、实时调度、队列解耦和运行时诊断能力：

- Arduino 框架本身运行在 FreeRTOS 上，项目把 Arduino `setup/loop` 与事件任务固定在 Core 1。
- 当前 BLE 语音下行已经使用 FreeRTOS Queue，OTA 下载已经使用独立 FreeRTOS Task。
- 绝大多数 IMU、触控、系统状态、BLE 网关、语音采集/播放、UI 绘制和功耗控制仍集中在约 10,034 行的 `DragonRadar.ino` 中，由一个协作式 `loop()` 顺序轮询。
- 语音帧周期是 20 ms，但一次全屏 AMOLED 绘制可能明显超过 20 ms；当前只能在语音活跃期间停掉 UI 绘制来保护音频。
- QMI8658 的加速度计和陀螺仪配置在约 224～250 Hz，但当前循环只能单点轮询，显示刷新会把有效采样率压到约 15 Hz。
- 当前一个 BLE 队列同时承载控制事件和音频帧，音频突发可能挤压抢麦、停止、断连等控制事件。

因此，后续优化不应理解为“把所有代码都改成任务”或“立即迁移纯 ESP-IDF”。正确路线是：

1. 冻结并验收昨晚的语音效果基线。
2. 增加可观测性，取得调度、队列、内存、IMU、UI 和音频基线。
3. 在不改变运行行为的前提下先拆分文件和硬件所有权。
4. 优先把 20 ms 音频链路迁入单一 `MediaTask`。
5. 拆分控制、音频上下行、IMU 快照和 UI 事件队列。
6. 把 IMU 改为独立任务并利用 FIFO。
7. 把 UI 改为独立低优先级任务，再依据实测选择缓存、局部刷新或 DMA。
8. 最后处理低功耗、双麦增强、鲁棒性、灰度 OTA 和旧路径清理。

架构优化正式开始以后，也必须从第一阶段持续完成到发布、灰度、回滚演练和文档收口；任何只完成“建任务”或“拆文件”的状态都不算完成。

## 2. 决策依据与适用边界

### 2.1 参考文章中值得采用的思路

参考文章：[ESP32-S3多模态开发板硬件架构与嵌入式AI系统设计](https://blog.csdn.net/nut55/article/details/155725272)

可迁移到本项目的通用方法包括：

- 用 BSP 隔离具体板卡引脚、总线、供电和外设初始化。
- 用 FreeRTOS Task 隔离不同实时等级的工作。
- 用 Queue、Ring Buffer、EventGroup 代替跨模块全局变量。
- 给传感器、音频和控制事件使用统一单调时钟。
- 对 IMU 使用 FIFO 和批量读取。
- 明确使用内部 SRAM、PSRAM、DMA 内存和任务栈的边界。
- 用状态机统一管理运行、语音、OTA、熄屏、待机和关机。
- 在功能稳定后通过动态频率和 Light Sleep 做功耗优化。

### 2.2 不能直接照搬的内容

文章描述的并不是当前 Waveshare 1.75C 圆屏板，不能照抄其引脚、屏幕、存储和传感器结论。以下内容不得作为本项目设计输入：

- 文章中的 1.8 英寸、368×448、SD 卡等硬件描述。
- 把 ESP32-S3 主核描述为 RISC-V 异构双核。
- 把 ESP32-S3 当成支持经典蓝牙 A2DP/HFP。
- 把 QMI8658 当成包含磁力计或气压计。
- 把显示 QSPI 与触摸 I2C 当成同一总线。
- 直接用文章中的帧缓冲计算、引脚编号或任务优先级。
- 因文章建议而立即整体迁移 LVGL 或纯 ESP-IDF。

### 2.3 本计划的真实硬件和运行边界

目标硬件为 Waveshare ESP32-S3-Touch-AMOLED-1.75C：

| 模块 | 当前硬件 |
|---|---|
| MCU | ESP32-S3R8，双核 Xtensa LX7 |
| 存储 | 32 MB Flash、8 MB PSRAM |
| 屏幕 | 466×466 CO5300 AMOLED，QSPI |
| 触摸 | CST9217，I2C |
| IMU | QMI8658，六轴加速度计和陀螺仪 |
| 采集 | ES7210 双麦 ADC |
| 播放 | ES8311 DAC、NS4150B 功放、扬声器 |
| 电源 | AXP2101 |

当前生效的网络拓扑是：

```text
ES7210 / QMI8658 / Touch / AMOLED / Speaker
                    │
                 ESP32-S3
                    │ BLE
                    ▼
                 iPhone App
                    │ HTTPS / WSS
                    ▼
                  Relay
```

边界要求：

- `kBlePhoneGatewayEnabled = true` 时，iPhone 是公网和房间网关。
- ESP 的 Wi-Fi 平时关闭，只在显式 OTA 会话中打开。
- ESP 负责麦克风采集、ADPCM 编解码、扬声器播放、圆屏 UI、触控和 IMU。
- App 当前不采集或播放首版语音，只负责 BLE 转发、房间状态、配置和 OTA 控制。
- Relay 负责鉴权、房间、定位、抢麦仲裁、单路语音转发和诊断。
- 所有架构改动必须同时考虑固件、App 和 Relay 的版本兼容，不能只改 ESP。

## 3. 目标、非目标和完成定义

### 3.1 总体目标

1. 20 ms 音频帧不再被 UI、JSON、I2C 或其他非实时工作阻塞。
2. 控制事件不会被音频突发淹没。
3. IMU 采样不再受全屏绘制频率限制。
4. UI 在语音期间仍能以低帧率显示必要状态。
5. 每个硬件外设只有一个明确的软件所有者。
6. 共享总线、状态、队列和内存有清晰的并发规则。
7. 能从日志回答“哪一帧迟了、哪个队列满了、哪个任务栈不够、哪次总线锁超时”。
8. 每个阶段都能通过编译开关或独立检查点回退。
9. 架构变更不破坏现有 BLE 配对、NVS、OTA 签名、防降级、航向和语音效果。
10. 形成可维护的模块边界，使后续双麦、功耗和本地轻量 AI 能力有稳定承载面。

### 3.2 本轮非目标

- 不在架构重构开始时迁移到纯 ESP-IDF。
- 不整体替换为 LVGL。
- 不改变房间最多 7 人、单人抢麦的产品模型。
- 不在核心调度重构期间同时改 ADPCM 格式、采样率或主观音色。
- 不立即做本地 ASR、TTS 或大模型推理。
- 不声称 QMI8658 可以提供绝对真北；现有北向校准仍是会话偏移。
- 不把系统重任务放到 Core 0 与 NimBLE/Wi-Fi 协议栈争抢。
- 不通过整片擦除解决 NVS 或迁移问题。

### 3.3 全局完成定义

只有同时满足下列条件，整项架构优化才能标记为完成：

- 所有阶段 P0～P14 都有对应证据或明确的“不采用”决策记录。
- `tools/verify_project.sh full` 通过。
- `tools/build_radar.sh field` 通过，Flash、静态 RAM、DIRAM 和 PSRAM 使用未越过预算。
- 两套真实 ESP + 两个独立手机网关完成双向可听语音验收。
- 连续 60 分钟语音压力测试无音频 deadline miss、持续堆增长或队列持续堆积。
- 抢麦、busy、松手、静音、断连、重连和远端播放尾音均有真机证据。
- IMU 在 UI 刷新和语音并发时达到选定有效采样率，FIFO 无未处理溢出。
- 已通过现有航向静止锁定、转动解锁、北向会话校准回归。
- 语音期间 UI 保持 5～10 FPS 的必要状态显示，且不造成音频退化。
- 屏幕常亮、熄屏、待机、语音、OTA 五类功耗状态都有实测电流和切换验证。
- OTA 下载、写入中断、健康检查失败回滚、防降级和旧版本兼容完成真机测试。
- 新 App/旧固件、旧 App/新固件、新 App/新固件的兼容矩阵通过。
- 已完成灰度发布、回滚演练、运行手册和旧路径清理。

## 4. 总体执行顺序与门禁

| 阶段 | 名称 | 依赖 | 主要产物 | 未通过时 |
|---|---|---|---|---|
| P0 | 昨晚语音调优冻结 | 无 | 可听基线、配置清单、检查点 | 禁止开始架构改动 |
| P1 | 可观测性和性能基线 | P0 | 基线报告、指标日志 | 不允许凭感觉定任务/队列 |
| P2 | 无行为变化的模块拆分 | P1 | 模块目录、硬件所有权 | 回退单个拆分检查点 |
| P3 | 队列合同和统一时间 | P2 | 固定结构、分队列、事件位 | 保留旧单队列开关 |
| P4 | MediaTask 迁移 | P3 | 独立音频实时任务 | 回退旧 `loop()` 音频路径 |
| P5 | ControlTask/状态机 | P4 | 状态转换表、集中控制 | 保留现有状态字段适配层 |
| P6 | SensorTask 和 IMU FIFO | P5 | 稳定高频 IMU 快照 | 回退单点轮询 |
| P7 | UiTask 和显示优化 | P6 | 独立 UI、渲染/刷新预算 | 回退同步全屏刷新 |
| P8 | I2C、存储和电源所有权 | P7 | 总线锁、异步存储、关机时序 | 回退同步控制 |
| P9 | 双麦与后续音质增强 | P8 | 双麦诊断和可回退增强 | 保持 P0 冻结音色 |
| P10 | 低功耗优化 | P9 | 状态功耗表、PM locks | 关闭 DFS/Light Sleep |
| P11 | 鲁棒性和安全加固 | P10 | 故障注入、coredump、WDT | 逐项关闭风险功能 |
| P12 | App/Relay 兼容迁移 | P11 | 协议能力协商、兼容矩阵 | 保持旧合同 |
| P13 | 全链路验收和灰度 | P12 | 真机报告、灰度包、回滚记录 | 停止晋升 |
| P14 | 清理、文档和维护 | P13 | 删除旧路径、运维手册 | 继续保留 feature flag |

硬门禁：

- P0 未通过，P1～P14 全部状态必须保持 `blocked-by-voice-baseline`。
- P1 没有测量结果，不得开始 P4、P6、P7 或 P10 的性能设计。
- P4 未稳定，不得开始双麦算法或 Light Sleep。
- P13 未完成两设备可听验收，不得发布正式 OTA。
- 任一阶段出现音质、航向、OTA 安全、BLE 配对或 NVS 回归，立即回到最近检查点，不带病进入下一阶段。

## 5. 目标 FreeRTOS 架构

### 5.1 核心分配原则

```text
Core 0：ESP-IDF / Arduino 系统任务
  NimBLE Host、BLE Controller、Wi-Fi、TCP/IP、OTA 网络活动
  原则：不主动放置持续占用 CPU 的应用任务

Core 1：Capsule Radar 应用任务
  MediaTask       20 ms 音频硬实时边界
  SensorTask      IMU FIFO 和 Fusion
  ControlTask     状态机、输入、业务控制
  UiTask          绘制和 QSPI 刷新
  Housekeeping    电量、诊断、NVS、低频维护
```

第一版不需要把每个模块都变成任务。建议任务拓扑如下：

| 任务 | 建议 Core | 相对优先级 | 唤醒方式 | 唯一所有权 |
|---|---:|---:|---|---|
| `MediaTask` | 1 | 应用最高 | 20 ms 周期 + 音频队列通知 | I2S1、ES7210/ES8311 运行态、PA |
| `SensorTask` | 1 | 次高 | FIFO watermark/固定周期 | QMI8658、Fusion、IMU 快照 |
| `ControlTask` | 1 | 中 | 控制队列、输入事件、周期 tick | 运行状态机、PTT 意图、模式转换 |
| `UiTask` | 1 | 中低 | UI 事件 + 帧截止时间 | `gfx`、Canvas、Panel、QSPI |
| `HousekeepingTask` | 1 或不固定 | 低 | 低频定时、存储请求 | NVS 写入、诊断汇总、电量慢任务 |
| `radar-ota` | 保持现状 | 受控 | OTA 请求 | OTA 下载、校验、写分区 |

实施时先把现有 Arduino `loopTask` 当作 `ControlTask` 使用，避免一开始又创建一个重复的控制任务。只有在指标证明有必要时，才把控制循环显式迁入自建 Task，并让 `loop()` 只做 supervisor 或阻塞等待。

建议的初始应用优先级不是永久常量，应以基线测量校准：

```text
MediaTask        6
SensorTask       5
ControlTask      4
UiTask           3
Housekeeping     1
```

不得把 App 任务优先级抬到系统关键任务之上；不得通过高优先级掩盖长临界区、阻塞 I/O 或错误锁设计。

### 5.2 硬件所有权

| 资源 | 所有者 | 其他模块访问方式 |
|---|---|---|
| I2S1 RX/TX | `MediaTask` | 发命令或送/取音频帧 |
| ES7210、ES8311、PA | `MediaTask` | `AudioCommand` |
| CO5300、Canvas、QSPI | `UiTask` | 不可变 `UiSnapshot` |
| QMI8658、Fusion | `SensorTask` | 单槽覆盖式 `ImuSnapshot` |
| CST9217 触摸 | `ControlTask` 或输入子模块 | 输出 `InputEvent` |
| AXP2101 | `PowerManager` | 有界 I2C 事务 |
| BLE GATT | `BleGateway` | 回调只校验、复制、入队 |
| NVS | `Housekeeping/SettingsStore` | `StorageCommand` |
| OTA 分区 | `OtaManager` | 由控制状态机授权 |

### 5.3 I2C 总线规则

显示 QSPI 与触控 I2C 不是同一总线，不要错误地为二者建立共享锁。但 QMI8658、CST9217、AXP2101 和音频 codec 控制寄存器实际共享 `Wire`，需要遵守：

1. 使用一个有界 `I2cBusMutex`。
2. 持锁范围只覆盖一次短 I2C 事务，不能持锁做 `delay()`、日志拼接或状态等待。
3. 获取超时必须计数并上报，不能无限等待。
4. `MediaTask` 的 20 ms PCM 数据不走 I2C；只在启停、音量或电源切换时短暂访问 codec 寄存器。
5. 关机、待机和 OTA 状态转换必须按固定顺序暂停任务后再操作总线和供电。
6. 不在 BLE 回调、ISR 或显示刷屏临界段中同步等待 I2C。

## 6. 消息、队列、状态和时间合同

### 6.1 队列拆分

当前单一 BLE 语音事件队列必须分拆：

| 队列 | 初始深度 | 元素 | 满队列策略 | 目标 |
|---|---:|---|---|---|
| `controlQueue` | 8 | 固定大小控制事件 | 不静默丢弃；记录并进入安全恢复 | 控制 p95 < 20 ms，max < 40 ms |
| `audioDownQueue` | 6 帧 | 编码下行帧 | 丢最旧帧，限制延迟 | 缓冲 60～120 ms |
| `audioUpQueue` | 4 帧 | 编码上行帧 | 丢当前最旧未发帧并计数 | 不反压 I2S 采集 |
| `imuSnapshotQueue` | 1 | 最新姿态快照 | `xQueueOverwrite` | 消费者永远拿最新状态 |
| `uiEventQueue` | 8 | 模式/提示事件 | 合并可合并事件 | UI 不阻塞控制 |
| `storageQueue` | 8 | 小型持久化请求 | 去重同 key 请求 | NVS 不阻塞实时路径 |

队列深度只是初始值，必须用 P1 指标确认，不能通过无限加深音频队列掩盖卡顿。实时语音优先低延迟而不是“每帧必达”。

### 6.2 固定结构

所有跨任务消息必须：

- 使用固定大小 POD 结构，避免在热路径传递 Arduino `String`。
- 带 `event_id`、`sequence`、`timestamp_us` 和明确版本。
- 使用 `esp_timer_get_time()` 的单调微秒时间，不用墙上时钟排序实时事件。
- 长数据使用固定内存池或所有权明确的 buffer，不能传局部栈指针。
- 明确生产者、消费者和释放责任。
- 记录 enqueue/dequeue 时间以计算排队延迟。

建议事件结构：

```cpp
enum class ControlEventKind : uint8_t {
  PttPressed,
  PttReleased,
  FloorGranted,
  FloorBusy,
  RemoteBegin,
  RemoteEnd,
  BleConnected,
  BleDisconnected,
  ScreenWake,
  ScreenSleep,
  OtaRequested,
  OtaFinished,
  ShutdownRequested,
};

struct ControlEvent {
  ControlEventKind kind;
  uint8_t version;
  uint16_t payload_size;
  uint32_t sequence;
  int64_t timestamp_us;
  uint32_t arg0;
  uint32_t arg1;
};
```

### 6.3 EventGroup

只把持续状态放进 EventGroup，不把一次性事件塞进位标志：

```text
AUDIO_ACTIVE
PTT_ACTIVE
REMOTE_PLAYING
SCREEN_ON
BLE_CONNECTED
OTA_ACTIVE
SHUTDOWN_PENDING
SENSOR_READY
```

规则：

- EventGroup 是快速状态协同，不是业务数据载体。
- 业务状态仍由 `RuntimeState` 拥有并形成只读快照。
- Event bit 修改必须集中在明确所有者，避免多个任务竞争设置和清除。
- OTA、关机、睡眠等复合状态以状态机为真相源，EventGroup 只提供任务门控。

### 6.4 BLE 回调规则

BLE GATT 回调只允许：

1. 校验长度、版本、序列和基本字段。
2. 复制到固定 buffer。
3. 入对应队列。
4. 更新最小必要的原子计数。
5. 立即返回。

禁止在 BLE 回调中：

- ADPCM 解码或 PCM 播放。
- I2S 读写。
- `delay()`。
- 大量 `String` 拼接或 JSON 构造。
- NVS 写入。
- 绘制 UI。
- 等待控制状态完成。

## 7. 内存与实时预算

### 7.1 当前已知基线

最近一次已验证的 field 构建约为：

- 固件：2,645,319 bytes，占 8 MiB OTA app 槽约 31.5%。
- 静态 RAM：54,484 / 327,680 bytes，约 16.6%。
- DIRAM：156,299 / 341,760 bytes，约 45.73%。
- 全屏 RGB565 Canvas：466 × 466 × 2 = 434,312 bytes，约 424 KiB。

这些数据只作为计划输入。P0 冻结后必须对确切检查点重新构建并记录，不得把旧数字当最终验收值。

### 7.2 内存分配原则

- 帧缓冲、UI 静态缓存和大诊断缓冲优先放 PSRAM。
- I2S DMA buffer、FreeRTOS 内核对象和时间敏感队列放内部可 DMA SRAM。
- 音频热路径不得频繁 `malloc/free`。
- 队列元素不能为了方便继续使用接近 500 字节的通用包体承载短控制事件。
- 每个任务栈先保守分配，再依据 `uxTaskGetStackHighWaterMark()` 收敛。
- 同时记录：
  - `heap_caps_get_free_size(MALLOC_CAP_INTERNAL)`
  - `heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL)`
  - `heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)`
  - PSRAM free/min/largest block
- 任何阶段都要比较启动后、语音前、语音 30/60 分钟后、OTA 后和待机唤醒后的内存。
- 出现最小空闲持续下降或最大连续块持续缩小，必须先排查泄漏/碎片，不能通过增加 PSRAM 掩盖。

### 7.3 初始性能预算

| 指标 | 初始目标 |
|---|---:|
| 音频周期 | 20 ms |
| 音频 deadline miss | 0 |
| 控制队列延迟 | p95 < 20 ms，max < 40 ms |
| 下行抖动缓存 | 60～120 ms |
| UI 语音期间帧率 | 5～10 FPS |
| UI 非语音交互帧率 | 依据实测保持当前体验或更好 |
| IMU 有效更新率 | 至少 100 Hz，或有证据选择的其他频率 |
| IMU 采样断档 | 不超过现有航向算法允许的 250 ms |
| I2C 单事务持锁 | 以实测 p99 建阈值，禁止无界等待 |
| 连续语音压力测试 | 60 分钟 |
| 队列长期积压 | 0 |
| 任务栈余量 | 高水位后仍保留足够安全余量 |

## 8. P0：昨晚语音效果调优冻结

### 8.1 目的

先回答“当前声音到底是否满意且稳定”，再改变任务和调度。P0 不属于架构重构，但它是后续所有阶段的强制入口。

### 8.2 冻结范围

至少记录并冻结：

- 固件提交、dirty patch 摘要、固件 version/build/security counter。
- App 提交和内部测试构建版本。
- Relay 提交与部署环境。
- 两块 ESP 的短 ID、硬件批次、当前 NVS 是否保留。
- ES7210 初始化寄存器、物理麦增益、通道映射。
- AXP2101 音频模拟电源配置。
- ES8311 codec 音量和运行时音量预设。
- I2S 端口、采样率、位宽、通道、MCLK/BCLK/LRCK。
- 20 ms 帧、320 samples、ADPCM 版本和包头。
- PTT pending/granted/active/cancel 的状态变化。
- 播放尾音、功放预热、I2S 超时和自动增益配置。
- 当前队列深度、每 tick 消费数、drop 计数。
- 诊断编译模式与串口日志字段。

### 8.3 真机验收步骤

1. 对两块 ESP 做普通配置保留式刷写，不执行 erase-flash。
2. 记录刷写前后 NVS 配对、房间、所有者和服务器配置。
3. 每块 ESP 分别连接独立 iPhone；只有一部 iPhone 时只能做辅助验证，不能完成最终双设备语音结论。
4. 两个 App 使用不同房间成员身份加入同一房间。
5. 确认两块设备的 BLE、网关、房间、抢麦状态均 ready。
6. A 抢麦，等待明确 `floor_granted` 后说固定测试语句。
7. 在 B 端人工确认可听、清晰度、音量、底噪、爆音、首字丢失和尾音截断。
8. B 向 A 反向重复。
9. A 持有发言权时 B 抢麦，确认 B 收到 busy 且不会上传音频。
10. 分别验证松手、静音、BLE 断开、App 进后台、Relay 短断线和自动重连。
11. 验证远端播放时本机扬声器不会重新进麦；当前 PTT 半双工策略不能被意外破坏。
12. 用安静环境、正常说话、较大音量和近距离四组输入检查削波、RMS、peak 和听感。
13. 连续双向交替通话至少 30 分钟；架构最终验收时延长到 60 分钟。
14. 记录每端 `voiceTx/voiceRx`、sequence、lost、queue drops、short reads/writes 和重连次数。
15. 检查语音结束后 UI、IMU、触控、音量设置、熄屏和待机恢复。

### 8.4 P0 产物

执行时建立：

```text
output/architecture-baseline/<timestamp>/
  baseline-manifest.json
  firmware-build-metadata.json
  git-status.txt
  firmware-diff.patch
  app-relay-revisions.txt
  device-a-serial.log
  device-b-serial.log
  voice-test-matrix.md
  voice-listening-notes.md
  metrics-before.json
  metrics-after-30min.json
```

不得把 token、Wi-Fi 密码、签名私钥、完整精确位置历史或个人联系方式放进产物。

### 8.5 P0 完成门槛

- 两个方向均有人工可听证据。
- 无持续爆音、严重底噪、首字持续丢失或尾音持续截断。
- busy、松手、静音、断线均能可靠释放发言权。
- 30 分钟无增长性 queue drop、heap 下降或崩溃。
- 当前调音参数被记录为 Golden Voice Baseline。
- 把语音调优改动和相关 App/Relay 合同形成独立检查点；不要与架构第一阶段混成一个提交。
- 未达到听感目标时继续语音调优，P1 保持阻塞。

## 9. P1：可观测性和性能基线

### 9.1 原则

本阶段只增加测量，不改变调度、音频格式、IMU 算法或 UI 视觉结果。

### 9.2 必加指标

任务和循环：

- `loop()` 周期、最大周期、p50/p95/p99。
- 每个 tick 函数的累计耗时和最大耗时。
- task runtime、CPU 占比、stack high-water mark。
- task watchdog 告警。

音频：

- I2S read/write 用时。
- 20 ms deadline miss。
- short read/write 次数和字节数。
- 上下行 sequence gap、队列当前/最大深度。
- enqueue-to-play、capture-to-notify 延迟。
- ADPCM 编解码耗时。
- RMS、peak、clipping。
- 功放和 codec 启停耗时。

IMU：

- 实际样本率、最大样本间隔。
- I2C 事务耗时。
- FIFO watermark、overflow、丢样。
- Fusion 更新耗时。
- stationary/yawLocked 切换计数。

UI：

- `drawFrame()` CPU 绘制耗时。
- `gfx->flush()` QSPI 传输耗时。
- 跳帧数量。
- 语音期间和非语音期间 FPS。
- UI snapshot 生成与消费延迟。

系统：

- internal heap/PSRAM free、minimum、largest block。
- BLE RSSI、notify/write 失败、重连时间。
- control queue latency。
- I2C mutex wait/hold。
- 电池电压、电量和每个电源状态的实测电流。
- OTA task 时长、最大内存占用和与音频/屏幕的互斥状态。

### 9.3 日志格式

- 使用单行、固定 key 的 `DIAG` 结构。
- 高频指标在内存聚合，1～5 秒输出摘要，不逐帧刷串口干扰实时性。
- 严格限制日志中敏感字段。
- 用 `session_id`、`boot_id`、固件 build、设备短 ID 关联同一次测试。
- 记录 `timestamp_us` 和 `sequence`，便于 App 与 Relay 诊断对齐。

### 9.4 基线场景

每个场景至少运行 5 分钟，长时场景运行 30 分钟：

1. 空闲常亮。
2. 快速 UI 动画。
3. 触摸和按键高频操作。
4. 单独 IMU 旋转。
5. 单独语音上行。
6. 单独远端语音下行。
7. 语音 + UI 状态更新。
8. 语音 + 快速转动。
9. BLE 弱信号和重传。
10. App 前后台切换。
11. OTA 检查和真实 OTA。
12. 熄屏、待机、唤醒。

### 9.5 P1 完成门槛

- 能分开回答 UI 慢是 CPU 绘制还是 QSPI flush。
- 能确认 IMU 的真实采样率和最大断档。
- 能确认音频 deadline miss、队列和 BLE 延迟来源。
- 能给每个任务的栈和 CPU 分配提供数据。
- 输出一份冻结基线报告，并把后续每阶段结果和它比较。

## 10. P2：无行为变化的模块拆分

### 10.1 目标目录

建议逐步形成：

```text
firmware/DragonRadar/
  DragonRadar.ino
  app/
    AppContext.h
    AppConfig.h
  board/
    BoardSupport.h
    BoardSupport.cpp
    I2cBus.h
    I2cBus.cpp
  audio/
    AudioPipeline.h
    AudioPipeline.cpp
    AudioTypes.h
  ble/
    BleGateway.h
    BleGateway.cpp
    BleMessages.h
  imu/
    ImuFusion.h
    ImuFusion.cpp
    ImuTypes.h
  runtime/
    RuntimeState.h
    RuntimeState.cpp
    ControlEvents.h
  ui/
    UiRenderer.h
    UiRenderer.cpp
    UiSnapshot.h
  power/
    PowerManager.h
    PowerManager.cpp
  storage/
    SettingsStore.h
    SettingsStore.cpp
  diagnostics/
    Diagnostics.h
    Diagnostics.cpp
```

### 10.2 拆分顺序

每移动一个模块都执行编译和对应回归：

1. 移出纯类型、常量和无状态工具函数。
2. 移出硬件 pin、I2C 地址和板级初始化。
3. 移出诊断计数器和格式化。
4. 移出 ADPCM/音频状态和 codec 控制。
5. 移出 BLE GATT 服务与消息解析。
6. 移出 IMU/Fusion/北向校准。
7. 移出 UI 绘制和 UI snapshot。
8. 移出电源和关机时序。
9. 移出 NVS 持久化。
10. 最后把 `.ino` 缩为装配、`setup()` 和最小控制循环。

### 10.3 拆分纪律

- 本阶段不创建新的实时任务。
- 不更改函数调用顺序。
- 不更改现有延时、采样率、队列深度、音量或视觉。
- 不顺手重命名协议字段。
- 不在同一个提交里同时移动大量代码并改变逻辑。
- 每个模块移动提交都应是机械性变更，便于 `git diff --color-moved` 审查。
- 对当前工作树中用户已有改动逐段保留，不覆盖或还原。

### 10.4 P2 完成门槛

- field 构建和 quick/full 门禁保持通过。
- 固件大小和 RAM 变化可解释。
- 真机语音听感与 P0 一致。
- 航向、触控、UI、电源和 OTA 无回归。
- `.ino` 不再承担具体驱动实现。
- 每个硬件所有者能在代码中一眼定位。

## 11. P3：队列合同、状态快照和统一时间

### 11.1 实施步骤

1. 定义 `ControlEvent`、`AudioFrame`、`ImuSnapshot`、`UiSnapshot`、`StorageCommand`。
2. 为每个结构增加版本和尺寸静态断言。
3. 引入统一 `MonotonicClock` 包装 `esp_timer_get_time()`。
4. 建立 `controlQueue`，先迁移抢麦授权、busy、取消、断连。
5. 建立 `audioDownQueue`，只承载 ADPCM 下行。
6. 建立 `audioUpQueue`，只承载待 BLE notify 的上行。
7. 建立单槽 `imuSnapshotQueue`。
8. 建立 `uiEventQueue` 和不可变 `UiSnapshot`。
9. 建立 EventGroup 及唯一修改者。
10. 为旧单队列保留编译时回退开关。

### 11.2 关键策略

- 控制队列满属于故障，不能静默 drop。
- 音频下行满时丢最旧帧，降低延迟，不播放过期语音。
- 音频上行满时记录 drop，不阻塞 I2S。
- sequence gap 必须跨 ESP、App、Relay 保持可追踪。
- `RemoteEnd`、`PttCancel`、`BleDisconnected` 等终止事件不得排在大量音频帧之后。
- UI 接收快照，不跨任务读取大量可变全局字段。

### 11.3 P3 验证

- 用原生单元测试覆盖队列满、乱序、重复、过期和断连。
- 注入连续音频帧后发送 `PttCancel`，验证控制延迟。
- 注入旧 sequence，验证拒绝或计数。
- 模拟 App 重连，验证旧会话帧不会进入新会话。
- 对每个队列记录 max depth 和最坏延迟。

### 11.4 P3 完成门槛

- 控制与音频队列完全分离。
- BLE 回调不再执行播放或复杂解析。
- 所有跨任务事件有统一时间和序列。
- 旧路径开关能在一轮构建内回退。

## 12. P4：MediaTask 迁移

### 12.1 设计原则

I2S1 是共享全双工时钟和配置的资源。第一版使用单一 `MediaTask` 同时拥有 RX、TX、codec 和 PA，比拆成两个互相竞争的录音/播放任务更安全。

### 12.2 迁移顺序

1. 创建 `MediaTask` 骨架、启动/停止协议和健康心跳。
2. 只迁移 I2S/codec 初始化所有权，行为保持一致。
3. 迁移远端下行：`audioDownQueue -> ADPCM decode -> PCM -> I2S TX`。
4. 验证远端播放、尾音、功放预热和 short write。
5. 迁移上行：`I2S RX -> mono selection -> level -> ADPCM -> audioUpQueue`。
6. 由 BLE Gateway 从 `audioUpQueue` notify，MediaTask 不直接做复杂 GATT 状态处理。
7. 迁移 PTT pending/granted/active/cancel 命令。
8. 迁移 audio idle suspend/resume。
9. 添加 20 ms deadline 监控、任务心跳和 WDT 策略。
10. 删除 `loop()` 中已经迁走的 `voiceCaptureTick/audioTick/audioPowerTick` 调用。

### 12.3 调度细节

- 使用 `vTaskDelayUntil()` 或任务通知维持稳定周期，不用漂移式 `delay()`。
- 下行队列到达可用 task notification 立即唤醒。
- 每次循环先处理终止/控制命令，再处理音频。
- 不持有 I2C mutex 等待 I2S。
- 不在热路径打印逐帧串口日志。
- 对 codec 开关使用状态机，禁止重复初始化。
- OTA 或关机时执行：
  1. 停止接受新 PTT。
  2. 清空/丢弃过期上行。
  3. 播放完或丢弃下行尾部，按策略记录。
  4. mute PA。
  5. 停 I2S。
  6. 关闭 codec/音频电源。
  7. 回报 `MediaStopped`。

### 12.4 P4 验收

- 语音期间 UI 和 IMU 活动不产生音频 deadline miss。
- 上下行均与 P0 Golden Voice Baseline 做 AB 对比。
- 60 分钟语音无持续 queue growth。
- busy、取消、断连的控制延迟满足预算。
- task stack 余量、CPU 占比和 internal heap 在预算内。
- 编译开关可切回旧 `loop()` 音频路径。

## 13. P5：ControlTask 与统一状态机

### 13.1 状态维度

建立正交但受统一转换规则管理的状态：

- 设备生命周期：`Booting / Running / ScreenOff / Standby / ShutdownPending`。
- 语音：`Idle / PttPending / Capturing / RemotePlaying / Muted / Recovering`。
- 网络：`BleDisconnected / BleConnected / GatewayReady / GatewayDegraded`。
- OTA：`Idle / Preparing / Downloading / Verifying / RebootPending / Failed`。
- 传感器：`Uninitialized / Calibrating / Ready / Suspended / Fault`。

### 13.2 实施步骤

1. 从现有布尔字段整理完整状态和转换表。
2. 为每个转换明确触发事件、前置条件、副作用和拒绝原因。
3. 所有输入先转成 `ControlEvent`。
4. `ControlTask` 成为运行状态唯一写入者。
5. 其他任务只接命令并回报完成/失败。
6. 用 `RuntimeSnapshot` 向 UI、BLE 状态上报和诊断提供只读视图。
7. 逐步移除跨模块直接写全局布尔值。
8. 对超时转换使用单调 deadline，而不是分散的 `millis()` 差值。
9. 明确冲突优先级：
   - OTA > 新 PTT。
   - Shutdown > 新 PTT。
   - 已授权语音 > 非语音提示音。
   - Remote playback 与本机 capture 遵守半双工策略。
10. 给每次拒绝记录稳定 reason code。

### 13.3 必测转换

- PTT 按下 -> pending -> granted -> active -> release -> idle。
- PTT pending -> busy -> idle。
- active -> BLE disconnect -> recovering -> idle。
- remote playing -> local PTT 请求的产品策略。
- screen off 状态收到远端语音。
- standby 状态收到语音/唤醒事件。
- OTA 请求发生在 PTT、remote playback、低电量或关机确认期间。
- shutdown 发生在队列有音频帧时。
- IMU fault 不阻断基础语音，但 UI 显示降级。

### 13.4 P5 完成门槛

- 状态转换有表、有测试、有日志。
- 不再依赖多个任务同时改同一布尔字段。
- UI 和 BLE 状态来自同一 snapshot。
- 断连、睡眠、OTA 和关机不会留下 codec、PA、队列或 event bit 的脏状态。

## 14. P6：SensorTask 与 QMI8658 FIFO

### 14.1 目标

把 IMU 采样与 466×466 全屏绘制解耦，同时保留已经验证的 Fusion 6DOF、零偏复核、静止 ZARU、yaw lock 和北向会话校准。

### 14.2 实施步骤

1. 在 P1 记录当前真实采样率、断档和 Fusion 耗时。
2. 使用 SensorLib 已有的 `configFIFO()` 和 `readFromFifo()`。
3. 选择与 QMI8658 ODR 匹配的 FIFO watermark。
4. 每次以短 I2C 事务批量 drain FIFO。
5. 依据 ODR 和最后读取时间重建每个样本的单调时间。
6. 按样本逐个更新 Fusion，不能把一批样本只当成一次更新。
7. 把最新姿态写入单槽 `imuSnapshotQueue`。
8. UI 只取最新快照，不反压 SensorTask。
9. FIFO overflow 时：
   - 增加计数。
   - 丢弃不可信批次。
   - 清除会话北向偏移或按现有断档规则降级。
   - 重新初始化采样时序。
10. standby/关机前显式 suspend，唤醒后重新建立可信 bias。

### 14.3 采样频率决策

- 不盲目追求 250 Hz。
- 先比较 100/112.5、200/224.2 和现有 ODR 对 CPU、I2C、功耗、手感和航向稳定的影响。
- 最终频率必须能保证：
  - UI 动画平滑。
  - 静止检测可靠。
  - yaw lock 转动后立即解锁。
  - 语音并发时无 FIFO overflow。
  - Light Sleep 策略可实现。

### 14.4 回归矩阵

- 静止 5 分钟漂移。
- 大约 90° 转动再放下。
- 快速往返转动。
- 不同温度启动，验证保存 bias 只作为 seed。
- 屏幕全速刷新时旋转。
- 双向语音时旋转。
- 熄屏/待机/唤醒后重校准。
- 北向长按 1.2 秒入口、BOOT 短按和触控方向。

### 14.5 P6 完成门槛

- 有效 IMU 更新率达到选定目标。
- FIFO overflow 在正常场景为 0。
- 最大断档不超过算法门槛。
- 已有航向稳定证据不回退。
- SensorTask 不阻塞 MediaTask 或 UI。

## 15. P7：UiTask 与显示性能优化

### 15.1 原则

首先分离“画图慢”和“传屏慢”。未测量前不迁移 LVGL，不假设 DMA 一定能解决问题。

### 15.2 第一阶段：任务所有权

1. `UiTask` 独占 Canvas、CO5300 panel 和 QSPI。
2. `ControlTask` 产生不可变 `UiSnapshot`。
3. UiTask 根据事件和帧 deadline 决定是否绘制。
4. 语音活跃时将帧率降到 5～10 FPS，而不是完全停画。
5. 提示、PTT、busy、远端说话者和 OTA overlay 使用高优先 UI 事件。
6. UI 永远不能调用音频或状态机内部实现。

### 15.3 第二阶段：依据瓶颈选择优化

若 CPU 绘制占主导：

- 缓存静态圆环、刻度和不变背景。
- 预计算几何、弦长、三角函数表。
- 避免每帧大量字符串格式化。
- 只更新发生变化的文本和 marker。
- 降低语音期间非必要动画复杂度。

若 QSPI flush 占主导：

- 验证驱动是否支持局部窗口更新。
- 计算 dirty rectangles 并合并相邻区域。
- 对雷达扫描线、成员 marker、语音状态做局部刷新。
- 评估 queued/DMA flush，但必须确认 buffer 位于可 DMA 内存且生命周期安全。
- 对双缓冲做内存预算，不能为了消除撕裂耗尽内部 RAM。

### 15.4 UI 保护规则

- 所有方向和触控映射保持现有产品合同。
- UI 优化不能改变 GPS 真北、QMI yaw 符号和北向偏移公式。
- 语音状态不能用遮挡雷达的大弹窗。
- 非语音提示音不得打断远端播放或进入麦克风。
- OTA、关机确认和恢复出厂的关键 overlay 不可因丢帧消失。

### 15.5 P7 完成门槛

- 语音期间必要 UI 达到 5～10 FPS。
- 音频 deadline miss 仍为 0。
- CPU draw 和 QSPI flush 分别有 before/after 数据。
- 触控、方向、雷达 marker 和语音 UI 真机通过。
- 未证明收益前不引入 LVGL。

## 16. P8：I2C、存储和电源所有权

### 16.1 I2C

- 实现有界 mutex 和事务计数。
- 为 QMI、Touch、AXP2101、ES7210、ES8311 控制分别记录 wait/hold。
- 长寄存器初始化拆成明确启动序列，不在实时运行期重复执行。
- 总线错误后先恢复总线/外设，不直接死循环重启。

### 16.2 NVS

- 所有 NVS 写请求发给 `SettingsStore/Housekeeping`。
- 相同 key 的连续修改去重/合并。
- 给音量、亮度等高频 UI 设置加 debounce。
- 记录 schema 版本和迁移结果。
- 架构迁移不得清除所有者、配对、房间、Wi-Fi 或服务器配置。
- 测试写入中断、电量不足和旧 schema。

### 16.3 电源状态转换

每个状态使用固定进入和退出顺序：

`Running -> ScreenOff`

1. UI 完成最后关键帧。
2. Panel 降亮度/关闭。
3. 保留 BLE、房间和语音能力。
4. 降低 UI tick 和状态 notify 频率。

`ScreenOff -> Standby`

1. 拒绝新 PTT 或按产品合同处理。
2. MediaTask idle 后关 codec/I2S/PA。
3. SensorTask suspend。
4. BLE 保持必要能力。
5. 记录 wake source。

`Any -> OTA`

1. ControlTask 验证电量、授权和语音空闲。
2. 阻止新 PTT、关音频、冻结非必要 UI。
3. 打开 Wi-Fi。
4. 获取 PM lock。
5. 运行 OTA；完成或失败后恢复一致状态。

`Any -> Shutdown`

1. 停止新工作。
2. 让 MediaTask、SensorTask、UiTask 回报 stopped。
3. 刷新必要 NVS。
4. 关闭外设和 rail。
5. 请求 AXP2101 真关机。
6. 超时才走有日志的 fallback。

### 16.4 P8 完成门槛

- 无无界 I2C 等待。
- NVS 写不出现在音频、BLE 回调或 UI 热路径。
- 熄屏、待机、OTA、关机的进入/退出顺序有测试。
- 反复 100 次状态切换不出现 codec、IMU、屏幕或 BLE 脏状态。

## 17. P9：双麦与后续音质增强

本阶段必须在 P0 Golden Voice Baseline 和 P4 稳定 MediaTask 之后执行。它属于“架构稳定后的声音增强”，不能回头污染架构重构归因。

### 17.1 当前事实

ES7210 和板卡有双麦能力，但当前 I2S 采到双通道后只取第一路。应先利用已有第二路做诊断和鲁棒选择，不直接上复杂波束形成。

### 17.2 递进步骤

1. 同时记录左右通道 RMS、peak、clipping、DC、噪声底。
2. 验证物理 MIC1/MIC2 与 I2S 左右通道映射。
3. 在不同握持方向、距离和环境噪声下建立数据集。
4. 实现可回退的“固定主通道 + 故障切换”。
5. 评估按窗口选择较高 SNR 通道。
6. 评估限幅后的加权合并，防止相位抵消。
7. 再评估轻量噪声抑制、AGC 和 VAD 参数。
8. 只有明确要做免提全双工时，才评估 AEC。
9. 只有麦距、相位和 CPU 预算支持时，才评估 beamforming。

### 17.3 AB 规则

- 每个增强都有 feature flag。
- 同一硬件、音量、距离、语句和网络做 Golden vs Candidate AB。
- 同时比较听感、丢帧、CPU、内存和功耗。
- 任一关键场景退化可立即切回单麦基线。

### 17.4 P9 完成门槛

- 至少完成双通道诊断和物理映射。
- 若启用自适应选择/合并，必须有多场景 AB 证据。
- 不增加音频 deadline miss。
- 不破坏半双工、VAD、busy 和功放时序。

## 18. P10：低功耗优化

### 18.1 先测量

使用同一电源、亮度、音量和网络条件测量：

- 启动峰值。
- 常亮空闲。
- UI 动画。
- BLE 连接空闲。
- 本机 PTT。
- 远端播放。
- 熄屏。
- 待机。
- OTA 下载和写入。
- 关机漏电。

### 18.2 优化顺序

1. 关闭空闲 codec/I2S/PA。
2. 降低熄屏后的 UI、诊断和状态 notify 频率。
3. 让阻塞等待替代高频空轮询。
4. 开启动态频率调节。
5. 为 MediaTask、显示刷新和 OTA 设置明确 PM lock。
6. 在 BLE 连接稳定前提下评估 automatic light sleep。
7. 明确唤醒源：按键、触摸、AXP IRQ、BLE/定时。
8. 验证待机进入/退出不会破坏 IMU bias、BLE 会话或音频 codec。

### 18.3 目标设置

绝对 mA 目标必须在 P1 测量后确定。初始使用相对目标：

- 熄屏相对常亮空闲明显下降。
- 待机相对熄屏进一步下降。
- 语音和 OTA 不因节能产生 deadline miss 或吞吐下降。
- 唤醒延迟满足用户可感知体验。

### 18.4 P10 完成门槛

- 五类运行状态有真实电流表。
- DFS/Light Sleep 都有 feature flag 和 PM lock。
- BLE 断连率、语音首帧、UI 唤醒和 IMU 恢复无回归。
- 反复 100 次睡眠/唤醒稳定。

## 19. P11：鲁棒性、安全和故障恢复

### 19.1 Task Watchdog

- 监控 Media、Sensor、Control、UI 关键任务。
- WDT 前尽量输出最近状态、队列深度和任务心跳。
- 不用频繁喂狗掩盖死锁。
- 通过故障注入验证 watchdog 和重启原因记录。

### 19.2 Coredump

当前分区表已经预留 64 KiB coredump 分区，但必须继续确认：

- 编译配置是否真正启用 coredump。
- 64 KiB 是否足够当前任务栈和回溯需求。
- 如何通过受控工具读取、脱敏和清除。
- coredump 不包含 token、Wi-Fi 密码或音频内容。
- App/Relay 诊断只上报摘要，不自动上传原始内存。

### 19.3 故障注入矩阵

- `controlQueue` 满。
- `audioDownQueue` 连续 overflow。
- BLE sequence 乱序、重复、丢失。
- BLE 在 PTT pending、active、remote playback 中断。
- I2C 超时、QMI8658 暂时失联、Touch IRQ 抖动。
- I2S short read/write 和 codec init 失败。
- PSRAM 分配失败。
- NVS 写失败、schema 旧、断电中断。
- 电池低、brownout、USB 拔插。
- OTA 下载断网、下载中断电、写入中断电、校验失败。
- 新固件健康检查失败、rollback。
- App 新旧协议字段缺失或超限。

### 19.4 安全合同不得回退

- BLE 所有者 challenge/proof 每连接轮换。
- 配置、所有者释放和 OTA 写操作继续要求授权。
- token/proof 不进入日志和状态 JSON。
- OTA 保持 ECDSA P-256/SHA-256、内容哈希、硬件/version/build/security counter 校验。
- stable OTA 只允许 HTTPS、可信根 CA，禁止 `setInsecure`。
- 防降级计数不能因回滚功能而降低。
- 需要回退功能时，用更高 build/security counter 发布修复包。
- partition table 改动只能通过有计划的 USB factory 流程。

### 19.5 P11 完成门槛

- 每种可恢复故障都有预期状态和日志。
- 不可恢复故障可得到重启原因或 coredump。
- 无死锁、无限阻塞或静默控制事件丢失。
- OTA、BLE、NVS 安全门禁全部回归通过。

## 20. P12：iOS 与 Relay 的兼容迁移

### 20.1 能力协商

增加或扩展版本字段：

- firmware version/build。
- BLE provisioning/voice/owner service version。
- voice codec/version/frame duration。
- queue/diagnostic schema version。
- App gateway capability bits。
- Relay protocol minimum/maximum。

### 20.2 兼容策略

- 新固件必须能识别旧 App 缺少的新字段并回退旧行为。
- 新 App 必须能识别旧固件不支持任务诊断、双麦或新状态字段。
- Relay 不得把架构内部状态变成无法兼容的硬依赖。
- 所有新增 JSON/BLE 字段先 optional，至少跨一个发布窗口后再考虑 required。
- 105 状态通知继续遵守当前 BLE 长度预算，完整诊断优先走 Relay。
- 不增加敏感数据到 App 诊断包。

### 20.3 Feature flags

建议至少保留：

```text
DRAGON_RADAR_RT_MEDIA_TASK
DRAGON_RADAR_SPLIT_VOICE_QUEUES
DRAGON_RADAR_IMU_FIFO_TASK
DRAGON_RADAR_ASYNC_UI_TASK
DRAGON_RADAR_DIRTY_RECT
DRAGON_RADAR_DUAL_MIC_SELECT
DRAGON_RADAR_PM_LIGHT_SLEEP
```

flag 规则：

- 默认值与灰度阶段明确。
- 状态上报中只显示安全的 capability，不泄露内部敏感配置。
- flag 组合必须受支持矩阵限制，避免任意组合。
- 删除旧 flag 前至少经过一次稳定发布窗口。

### 20.4 兼容矩阵

| App | 固件 | Relay | 必测结果 |
|---|---|---|---|
| 旧 | 旧 | 新 | 现有功能不退化 |
| 旧 | 新 | 新 | 新固件回退旧合同 |
| 新 | 旧 | 新 | App 显示不支持而非报错 |
| 新 | 新 | 新 | 新任务和诊断能力生效 |
| 新 | 新 | 旧/最低兼容 | 明确拒绝或安全降级 |

### 20.5 P12 完成门槛

- 兼容矩阵自动化和真机均通过。
- 用户看得到稳定、可理解的降级状态。
- 旧 App 不会触发新固件危险状态。
- 新诊断不会突破 BLE 包长度和隐私合同。

## 21. P13：完整验证、灰度和发布

### 21.1 自动化验证

每个阶段最少执行：

```bash
tools/verify_project.sh quick
tools/build_radar.sh field
```

里程碑和发布候选执行：

```bash
tools/verify_project.sh full
```

同时保持：

- ADPCM/网关状态机测试。
- heading stability C++ 回归。
- BLE 安全和所有者释放测试。
- OTA 合同、打包、签名、retain、rollback 测试。
- Relay room、voice floor、busy、limits smoke。
- iOS unit/UI、Debug/Release no-sign build、生产 URL 门禁。

### 21.2 真机完整矩阵

硬件：

- 至少两块 ESP。
- 至少两个独立 iPhone 网关。
- 如计划支持 7 人房间，补充模拟成员做 room/floor 压力，但不能替代两块 ESP 的可听验证。

场景：

1. 全新未绑定设备。
2. 保留 NVS 升级设备。
3. 旧固件升级新固件。
4. 新固件配旧 App。
5. 双向语音。
6. 抢麦冲突。
7. 语音中 BLE 弱信号。
8. App 前后台和进程重启。
9. Relay 重连。
10. UI + IMU + 语音并发。
11. 熄屏收到远端语音。
12. 待机和唤醒。
13. 低电量拒绝 OTA。
14. OTA 断网、断电、健康失败和 rollback。
15. 60 分钟语音 soak。
16. 8～24 小时空闲/重连 soak。

### 21.3 灰度步骤

1. 建立 release candidate 检查点和不可变二进制摘要。
2. 内部诊断构建只刷测试设备，不直接晋升 stable。
3. 先灰度 1 台，观察 24 小时。
4. 再灰度 2～5 台，观察 72 小时。
5. 比较：
   - crash/reboot。
   - 音频 drop/deadline。
   - BLE 重连。
   - IMU overflow。
   - heap minimum。
   - OTA 成功/rollback。
   - 电池续航。
6. 指标稳定后才扩大发布。
7. 任何严重回归停止晋升，用更高 build/security counter 发布回退实现。

### 21.4 P13 完成门槛

- 所有自动化门禁通过。
- 所有必须真机场景有记录。
- 灰度期无阻断问题。
- 回滚演练真实执行过。
- 发布包、元数据、签名和保留策略可复现。

## 22. P14：旧路径清理、文档和维护

### 22.1 清理条件

只有 P13 灰度稳定后才能：

- 删除旧单一 BLE 语音队列。
- 删除 `loop()` 中旧音频路径。
- 删除旧 IMU 单点轮询。
- 删除同步 UI 旧路径。
- 删除过渡适配层和已经过期的 feature flag。
- 收紧不再需要的全局变量和公开接口。

### 22.2 文档更新

同步更新：

- `README.md`
- `docs/remote-multi-radar-architecture.zh.md`
- `docs/version-compatibility.zh.md`
- `docs/firmware-ota.zh.md`
- `docs/esp-radar-ui-spec.zh.md`
- 新增 task/queue/ownership 图
- 新增串口诊断字段字典
- 新增 coredump 读取和脱敏手册
- 新增真机语音验收手册
- 新增功耗测试手册

### 22.3 长期维护

- 每次 release 保存性能基线。
- 每次新增任务都要求所有权、优先级、栈、阻塞点和退出协议。
- 每次新增队列都要求容量计算、满队列策略和延迟指标。
- 每次改音频参数都回到 Golden Voice AB。
- 每次改 IMU 都跑航向稳定矩阵。
- 每次改 OTA、NVS 或 partition 都跑断电与兼容测试。
- 每季度复查 stack high-water、heap minimum、coredump 和功耗。

## 23. 全量测试矩阵

| 领域 | 自动化 | 单板真机 | 双板真机 | 长时 | 通过标准 |
|---|---|---|---|---|---|
| 构建 | field/full | 启动 | 两板一致 | 否 | 无编译/链接门禁失败 |
| 音频编码 | ADPCM 单测 | 本地采播 | 双向可听 | 60 min | deadline miss=0 |
| 抢麦 | Relay smoke | pending/granted | busy 冲突 | 30 min | 无双占用 |
| BLE 队列 | 队列注入 | 断连/重连 | 两网关 | 60 min | 控制延迟达标 |
| IMU | C++ 回归 | 静止/转动 | 可选 | 5 min | 采样率/漂移达标 |
| UI | snapshot 单测 | 方向/触控 | 语音状态 | 30 min | 语音期 5～10 FPS |
| I2C | mock/故障注入 | 设备失联恢复 | 否 | 100 次 | 无死锁 |
| NVS | schema 单测 | 保留升级 | 两设备 | 100 次 | 无配置丢失 |
| 电源 | 状态机单测 | 各状态电流 | 可选 | 100 次 | 唤醒稳定 |
| OTA | 合同/签名 | 真升级/回滚 | 分批 | 中断矩阵 | 安全门禁保持 |
| App 兼容 | unit/UI | 新旧组合 | 两网关 | 否 | 安全降级 |
| Relay | smoke/limits | 真实连接 | 2～7 成员 | 8～24 h | 无状态漂移 |
| 安全 | 静态门禁 | 非 owner 写入 | 重放/撤销 | 否 | 全部拒绝 |

## 24. 提交、检查点和回滚策略

### 24.1 检查点结构

建议每个阶段至少包含：

1. `refactor-only`：机械拆分，不改行为。
2. `feature-behind-flag`：新路径默认关闭。
3. `tests-and-metrics`：自动化和诊断。
4. `enable-internal`：诊断构建启用。
5. `enable-field`：通过真机后 field 默认启用。
6. `remove-legacy`：灰度稳定后清理。

### 24.2 回滚层级

- 运行时回滚：关闭 feature flag。
- 构建回滚：使用旧路径编译。
- Git 回滚：回到阶段前检查点。
- OTA 回滚：由 boot health 触发双分区 rollback。
- 发布回滚：发布更高 build/security counter 的旧实现。

### 24.3 禁止事项

- 不用 `git reset --hard` 清理当前工作树。
- 不把现有未提交语音调优和架构变更混为一个不可分提交。
- 不通过降低 security counter 安装旧包。
- 不为测试方便关闭生产 TLS、签名或 owner auth。
- 不在未记录 NVS 的情况下执行 factory erase。

## 25. 文件影响地图

| 范围 | 预计动作 | 风险 |
|---|---|---|
| `firmware/DragonRadar/DragonRadar.ino` | 逐步缩为装配和 supervisor | 高，必须小步移动 |
| `firmware/DragonRadar/OtaManager.*` | 接入 EventGroup、PM lock、状态回报 | 高，保持 rollback |
| `firmware/DragonRadar/VoiceAdpcm.h` | 原则上不在架构期改格式 | 高，跨端合同 |
| `firmware/DragonRadar/HeadingStability.h` | 接 SensorTask/FIFO，算法保持 | 高，真机回归 |
| `lib/SensorLib/...SensorQMI8658.hpp` | 优先复用 FIFO API | 中，不轻易 fork |
| `boards/...json` | 核心配置只核对，非必要不改 | 高 |
| `partitions_dragon_radar_32mb.csv` | 仅核对 coredump，不在普通 OTA 改 | 极高 |
| `ios/.../BLEDeviceBridge.swift` | 新 capability、队列诊断和兼容 | 高 |
| `ios/.../RadarRuntime.swift` | 新状态投影和降级 | 中 |
| `relay/server.py` | optional 诊断/能力字段 | 高 |
| `tools/test_gateway_voice.py` | 队列/状态/协议回归 | 中 |
| `tools/verify_project.sh` | 纳入架构静态和运行门禁 | 中 |
| `docs/*.zh.md` | 同步真实架构和验收 | 低 |

## 26. 工作量与推进建议

以下是单人顺序实施的粗略工程量，不含等待硬件、主观听音和 App Store/生产环境外部时间：

| 阶段 | 建议投入 |
|---|---:|
| P0 语音冻结 | 1～2 天 |
| P1 指标基线 | 2～4 天 |
| P2 模块拆分 | 4～7 天 |
| P3 队列和时间合同 | 2～4 天 |
| P4 MediaTask | 4～7 天 |
| P5 状态机 | 3～5 天 |
| P6 SensorTask/FIFO | 3～5 天 |
| P7 UiTask/显示 | 4～7 天 |
| P8 总线/存储/电源 | 3～5 天 |
| P9 双麦增强 | 3～8 天，取决于算法深度 |
| P10 低功耗 | 3～6 天 |
| P11 鲁棒性/安全 | 3～6 天 |
| P12 跨端兼容 | 3～5 天 |
| P13 验收/灰度 | 至少 4～7 天观察 |
| P14 清理/文档 | 2～3 天 |

总计约 44～86 个工程日。实际排期应在 P1 后依据数据重新估算。为了缩短墙上时间，可以并行准备测试工具和文档，但不能并行修改同一实时链路，也不能越过阶段门禁。

## 27. 风险登记

| 风险 | 早期信号 | 预防 | 回退 |
|---|---|---|---|
| 音质在重构后变化 | RMS/peak、首尾音、听感变化 | P0 Golden、P4 AB | 旧 media flag |
| 控制事件被音频挤压 | cancel/busy 延迟 | 分队列、控制优先 | 单独清队列/恢复 |
| Core 1 饥饿 | UI/IMU/Media 抖动 | 测 CPU、短临界区 | 降低非实时负载 |
| Core 0 协议栈受影响 | BLE/Wi-Fi 重连增加 | 不放重 App task | 恢复任务亲和 |
| I2C 死锁 | mutex wait 上升 | 单锁、有界事务 | 总线恢复/任务重启 |
| PSRAM 碎片 | largest block 下降 | 固定 buffer/启动分配 | 关闭缓存/双缓冲 |
| IMU FIFO 时间错误 | 航向跳变 | ODR 重建时间、gap 规则 | 单点轮询 flag |
| 局部刷新视觉错误 | 残影/撕裂 | dirty rect 合并测试 | 全屏 flush |
| Light Sleep 破坏 BLE | 断连/首帧慢 | PM lock、分状态灰度 | 关闭 Light Sleep |
| OTA 与任务停止死锁 | OTA 卡住 | 明确 stop ack/timeout | OTA 失败恢复 |
| 新旧 App 不兼容 | 状态空白/写入失败 | capability/optional 字段 | 旧合同 |
| 当前 dirty 工作丢失 | diff 混乱 | P0 patch/checkpoint | 恢复独立 patch |

## 28. 执行清单

### 28.1 开工前

- [ ] 昨晚语音调优继续完成。
- [ ] 两块 ESP、两个 iPhone 可用。
- [ ] 记录当前 Git branch、HEAD 和 dirty diff。
- [ ] 冻结 firmware/App/Relay 版本。
- [ ] 完成双向可听、busy、断连和 30 分钟测试。
- [ ] 保存 Golden Voice 参数与日志。
- [ ] 建立可回退检查点。

### 28.2 架构实施

- [ ] P1 指标完整。
- [ ] P2 模块拆分完成。
- [ ] P3 队列/时间合同完成。
- [ ] P4 MediaTask 完成。
- [ ] P5 状态机完成。
- [ ] P6 SensorTask/FIFO 完成。
- [ ] P7 UiTask/显示优化完成。
- [ ] P8 I2C/NVS/电源所有权完成。
- [ ] P9 双麦评估完成。
- [ ] P10 低功耗完成。
- [ ] P11 故障恢复和安全完成。
- [ ] P12 App/Relay 兼容完成。

### 28.3 发布收口

- [ ] quick、firmware、full 全通过。
- [ ] 双板双向语音 60 分钟通过。
- [ ] IMU/航向完整回归通过。
- [ ] UI/触控/方向通过。
- [ ] 功耗表和 100 次睡眠唤醒通过。
- [ ] OTA 中断、防降级、rollback 通过。
- [ ] 新旧兼容矩阵通过。
- [ ] 1 台 24 小时灰度通过。
- [ ] 2～5 台 72 小时灰度通过。
- [ ] 正式回滚演练通过。
- [ ] P14 旧路径清理和文档更新完成。

## 29. 正式开工入口

当且仅当 P0 全部完成后，按以下顺序开始架构优化：

1. 新建架构优化工作分支或明确检查点。
2. 重新运行 `tools/verify_project.sh full` 和 field 构建。
3. 生成 P1 基线数据，不修改行为。
4. 审核基线并锁定任务优先级、栈和队列初值。
5. 从 P2 模块拆分开始，小步提交。
6. 每个阶段都执行自动化、单板和必要双板验证。
7. 任何 Golden Voice、航向、OTA 安全或 NVS 回归立即停止并回退。
8. 连续推进到 P14，完成灰度、回滚和旧路径清理后才宣告结束。

在 P0 之前，本计划的状态应保持：

```text
ARCHITECTURE_OPTIMIZATION = PLANNED
EXECUTION = BLOCKED_BY_GOLDEN_VOICE_BASELINE
NEXT_ACTION = FINISH_AND_FREEZE_LAST_NIGHT_VOICE_TUNING
```
