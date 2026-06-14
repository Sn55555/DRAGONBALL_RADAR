# 多雷达远程定位与 7 人房间抢麦语音架构

## 目标

多套设备异地使用：

- 用户 1：`ESP32-S3-Touch-AMOLED-1.75C-1` + `iPhone-1`
- 用户 2：`ESP32-S3-Touch-AMOLED-1.75C-2` + `iPhone-2`
- 用户 N：`ESP32-S3-Touch-AMOLED-1.75C-N` + `iPhone-N`

每块 ESP 连接自己的 iPhone 后，能在 ESP 圆屏上看到同一房间内其他成员的定位状态、距离、方位、在线状态，并通过 ESP 的麦克风/扬声器进行房间抢麦语音。

## 关键结论

远程异地不能只靠 BLE。BLE 只用于 ESP 和本机 iPhone 的近距离配对、Wi-Fi 配网、设备状态和低频控制。

远程定位和语音必须走云端中继：

```text
ESP-1  <==== Wi-Fi/WSS ====\
ESP-2  <==== Wi-Fi/WSS =====+====>  Relay Server  <==== HTTPS/WSS ==== iPhone-1
ESP-N  <==== Wi-Fi/WSS ====/          ^    ^     \==== HTTPS/WSS ==== iPhone-2
  ^                                    |    |      \=== HTTPS/WSS ==== iPhone-N
  | BLE                                |    |
  v                                    |    |
iPhone-1 / iPhone-2 / iPhone-N ========+====+
```

首版推荐让 ESP 直接连云端，而不是让 iPhone 转发 ESP 音频。原因：

- ESP32-S3 有 Wi-Fi，能直接通过 `wss://` 连接服务端。
- ESP32-S3 只有 Bluetooth LE，没有经典蓝牙音频；BLE 不适合稳定承载语音流。
- iPhone App 负责 GPS/指南针、账号、配对和多人房间管理；ESP 负责显示、麦克风、扬声器和云端实时链路。

## 硬件

必需硬件：

- 每名成员 1 块 `Waveshare ESP32-S3-Touch-AMOLED-1.75C`
- 每名成员 1 台 iPhone
- 每块 ESP 1 块 3.7V 锂电池，若购买的是 without-battery 版本
- 每块 ESP 1 条 USB-C 线，用于刷机、日志和充电
- 可上网的 Wi-Fi：家用路由器、随身 Wi-Fi、或 iPhone Personal Hotspot
- 1 台云服务器或托管容器平台，用于运行中继服务

板载硬件使用：

- 466x466 AMOLED：显示房间成员列表、选中成员位置、距离、方位、语音状态
- CST9217 触摸：接听、静音、音量、页面切换
- Wi-Fi：ESP 连接云端
- BLE：iPhone 配对 ESP、配网、传本机定位摘要和状态
- ES7210/双麦克风链路：ESP 采集语音
- ES8311 + NS4150B + 扬声器：ESP 播放远端语音
- QMI8658 IMU：本机手持姿态、方向 UI 动效
- AXP2101：电源/电池状态

不作为首版硬件：

- 外接 GNSS：定位由 iPhone 提供
- 外接蓝牙音频模块：不需要
- LoRa/UWB：首版远程依赖公网服务器

## 角色分工

### ESP 固件

职责：

- 显示房间内其他成员的位置、距离、方位、在线状态
- 读取触摸静音、音量和成员选择
- 采集本机麦克风
- 播放远端语音
- 通过 Wi-Fi 与云端保持 `wss://` 长连接
- 通过 BLE 与 iPhone 完成配对、配网、设备绑定

ESP 不负责：

- 获取 GPS
- 用户登录
- 好友邀请
- 复杂地图渲染
- NAT 穿透

### iPhone App

职责：

- 用户登录
- 创建设备绑定关系
- 扫描并绑定本机 ESP
- 给 ESP 配 Wi-Fi 或提示用户连接热点
- 获取本机 GPS、精度、速度、航向
- 将定位上传给云端
- 将本机定位摘要写给 ESP，用于本机屏幕状态
- 创建/加入多人房间
- 展示备用地图和诊断页

iPhone App 不负责首版语音转发。语音由 ESP 直接经云端中继。

### Relay Server

职责：

- 账号认证
- 设备注册和绑定
- 多人房间管理
- ESP WebSocket 接入
- iPhone WebSocket 接入
- 定位状态转发
- 最多 7 人语音房间管理
- 抢麦仲裁、当前发言权状态和单路语音转发
- 在线/断线/心跳管理

服务端负责鉴权、房间状态、抢麦仲裁、语音帧转发和发言权释放。

## 网络模式

### 模式 A：ESP 连接路由器 Wi-Fi

适合室内、固定地点。

```text
ESP -> Home Wi-Fi -> Internet -> Relay Server
iPhone -> Wi-Fi/Cellular -> Relay Server
```

### 模式 B：ESP 连接 iPhone Personal Hotspot

适合户外。iPhone 提供蜂窝网络，ESP 通过热点上网。

```text
ESP -> iPhone Hotspot -> Cellular -> Relay Server
iPhone App -> Cellular/Wi-Fi -> Relay Server
```

注意：App 不能可靠地自动开启 iPhone Personal Hotspot。首版交互应提示用户手动开启热点，然后 ESP 使用已保存的 SSID/密码连接。

## 协议

### BLE 设备绑定服务

ESP 广播名：

```text
CapsuleRadar-<shortId>
```

BLE Service：

```text
service_uuid = 7d540100-f82d-4b2f-91c6-4f0f88aa5a11
```

Characteristics：

| 名称 | 方向 | 用途 |
| --- | --- | --- |
| `pairing_challenge` | ESP -> App notify | 设备绑定挑战码 |
| `pairing_response` | App -> ESP write | App 签名后的绑定响应 |
| `wifi_config` | App -> ESP write | Wi-Fi SSID/密码，需加密写入 |
| `local_location` | App -> ESP write | 本机 GPS 摘要 |
| `device_status` | ESP -> App notify | 电量、Wi-Fi、云连接、音频状态 |
| `server_config` | App -> ESP write | Relay URL、room token、device token |

首版 iOS/ESP 固件使用以下特征 UUID 合同：

| 名称 | UUID |
| --- | --- |
| `pairing_challenge` | `7d540101-f82d-4b2f-91c6-4f0f88aa5a11` |
| `pairing_response` | `7d540102-f82d-4b2f-91c6-4f0f88aa5a11` |
| `wifi_config` | `7d540103-f82d-4b2f-91c6-4f0f88aa5a11` |
| `local_location` | `7d540104-f82d-4b2f-91c6-4f0f88aa5a11` |
| `device_status` | `7d540105-f82d-4b2f-91c6-4f0f88aa5a11` |
| `server_config` | `7d540106-f82d-4b2f-91c6-4f0f88aa5a11` |

### 本机定位包

iPhone 写给 ESP，也上传给 Relay。

```c
struct LocationFrame {
  uint8_t  version;          // 1
  uint8_t  flags;            // bit0 valid, bit1 reduced_accuracy, bit2 heading_valid
  int32_t  lat_e7;           // latitude * 1e7
  int32_t  lon_e7;           // longitude * 1e7
  int32_t  altitude_cm;      // altitude meters * 100, unknown = INT32_MIN
  uint16_t h_accuracy_cm;    // horizontal accuracy
  uint16_t v_accuracy_cm;    // vertical accuracy
  uint16_t speed_cms;        // speed m/s * 100
  uint16_t course_deg100;    // course degrees * 100
  uint16_t heading_deg100;   // compass heading degrees * 100
  uint32_t unix_time_s;
};
```

### ESP WebSocket

ESP 连接：

```text
wss://api.example.com/v1/radar/device/ws?device_id=<id>
```

认证：

- 首次绑定后，App 下发 `device_token`
- ESP 使用 `Authorization: Bearer <device_token>`
- Token 可撤销，可刷新

上行消息：

| type | 内容 |
| --- | --- |
| `hello` | 固件版本、硬件版本、能力列表 |
| `heartbeat` | 电量、RSSI、heap、audio状态 |
| `voice_join` | 加入房间语音 |
| `voice_leave` | 离开房间语音 |
| `mute_update` | 本机静音/取消静音 |
| `audio_frame` | 本机麦克风语音帧 |
| `device_event` | 触摸、错误、断线、重连 |

下行消息：

| type | 内容 |
| --- | --- |
| `room_state` | 房间成员、在线状态 |
| `member_location` | 某个房间成员的 iPhone 定位 |
| `member_display_state` | 某个房间成员相对本机的显示状态 |
| `voice_state` | 房间语音成员、静音、当前抢麦者 |
| `voice_frame` | 当前抢麦者发给其他设备的语音帧 |
| `voice_busy` | 本机抢麦失败，房间已有发言者 |
| `config_update` | 服务器配置 |

## 7 人房间抢麦语音

首版不做多人同时混音。房间最多 7 名成员，但同一时刻只有 1 名成员持有发言权。

每台 ESP：

- 按住抢麦键后发送 `voice_claim`。
- Relay 若当前无人发言，则返回 `voice_granted`，该 ESP 才开始上传麦克风帧。
- Relay 若已有其他成员发言，则返回 `voice_busy`，该 ESP 不上传语音。
- 下行只接收当前抢麦者的一路 `voice_frame`。

松开抢麦键、静音、断线、或超时无帧时，Relay 释放发言权并广播新的 `voice_state`。

房间容量：

- `max_members = 7`
- 每名成员最多绑定 1 台活跃 ESP
- 每个房间同一时刻最多 1 路上行发言音频
- 每台非发言 ESP 最多 1 路下行语音

首版编码以当前固件实现为准，使用 `PCM16 16kHz mono` 20 ms 帧。后续若网络带宽需要压缩，再引入 G.711 或 Opus；压缩不是当前 MVP 完成条件。

固定参数：

- 采样率：`16000 Hz`
- 声道：`mono`
- 编码：`PCM16_LE`
- 帧长：`20 ms`
- 每帧 PCM 样本：`320`
- 每帧大小：`640 bytes`

ESP 上行语音帧：

```c
struct AudioFrameHeader {
  uint16_t magic;       // 0xDA7A
  uint8_t  version;     // 1
  uint8_t  codec;       // 1 = PCM16_LE
  uint32_t session_id;
  uint16_t seq;
  uint32_t timestamp_ms;
  uint8_t  flags;       // bit0 muted, bit1 vad_active
};
// followed by 640 bytes PCM16 payload
```

服务端抢麦规则：

- Relay 维护每个房间的 `floor_holder`。
- `floor_holder` 为空时，第一个合法 `voice_claim` 获得发言权。
- `floor_holder` 非空时，其他成员的 `voice_claim` 返回 `voice_busy`。
- 只有 `floor_holder` 的 `audio_frame` 会被 Relay 转发给其他成员。
- 若 `floor_holder` 静音、释放、断线、或 300 ms 内没有音频帧，Relay 释放发言权。
- Relay 下发 `voice_state`，包含当前抢麦者、静音状态、帧计数和延迟。
- ESP 端只播放 Relay 下发的 `voice_frame`，不做多路混音。

ESP 端回声处理：

- 首版必须提供触摸静音。
- 播放下行语音时，本机默认不持有发言权，避免本机扬声器被麦克风再次采集。
- 抢麦时如果本机正在播放远端语音，固件应先停止播放或显著压低播放音量。
- 如果实测回声明显，下一步再增加回声抑制；它不是当前抢麦 MVP 的前置条件。

## 定位显示

定位由每台 iPhone 上传给 Relay。Relay 为每个 ESP 下发同房间其他成员的定位摘要和相对显示状态。

ESP 屏幕显示：

- 房间成员在线/离线
- 成员 GPS 是否有效
- 成员水平精度
- 成员距离
- 成员相对方位
- 最近更新时间
- 正在说话的成员列表

距离/方位计算推荐在服务端完成，同时把原始定位也下发给 ESP。这样 ESP 端只需要显示，不承担复杂地理计算。

下发给 ESP 的显示包：

```c
struct MemberDisplayState {
  uint8_t  version;
  uint32_t room_member_id;
  uint32_t user_id;
  uint32_t device_id;
  uint8_t  online;
  uint8_t  location_valid;
  uint8_t  speaking;
  uint8_t  selected;
  int32_t  lat_e7;
  int32_t  lon_e7;
  uint32_t distance_m;
  uint16_t bearing_deg100;
  uint16_t accuracy_m;
  uint32_t age_ms;
  char     display_name[24];
};
```

ESP 屏幕不能同时清晰展示大量成员，首版 UI 采用两层：

- 总览页：显示最多 7 个成员点位，按距离排序。
- 成员页：触摸选择一个成员后，显示该成员的大号距离、方位、精度和通话状态。
- 语音覆盖层：显示当前活跃发声成员，最多同时显示 3 个名称，其余用 `+N` 表示。

## 服务端数据模型

```text
users
  id
  apple_sub
  display_name
  created_at

devices
  id
  owner_user_id
  public_name
  hardware_model
  firmware_version
  device_secret_hash
  last_seen_at

rooms
  id
  owner_user_id
  invite_code
  state
  created_at

room_members
  room_id
  user_id
  device_id
  role
  joined_at

location_states
  user_id
  room_id
  lat_e7
  lon_e7
  accuracy_cm
  heading_deg100
  updated_at

voice_sessions
  room_id
  active_member_count
  started_at
  last_mix_at

voice_member_states
  room_id
  device_id
  muted
  vad_active
  last_audio_frame_at
  uplink_frame_count
  downlink_frame_count
```

## iOS App 模块

- `AuthModule`
  - Sign in with Apple
  - 获取用户 token

- `PairingModule`
  - CoreBluetooth 扫描 `CapsuleRadar-*`
  - BLE challenge/response 绑定设备
  - 下发 Relay URL、device token、room token

- `LocationModule`
  - CoreLocation 获取定位、速度、course、heading
  - 上传到 Relay
  - 写入 ESP `local_location`

- `RoomModule`
  - 创建房间
  - 加入邀请码
  - 显示房间成员在线和设备状态

- `DeviceConfigModule`
  - Wi-Fi 配网
  - 音量、亮度、设备名
  - 固件版本和升级入口

- `DiagnosticsModule`
  - BLE 连接状态
  - Wi-Fi 连接状态
  - Relay 延迟
  - GPS 精度
  - 语音帧计数
  - 语音下行帧计数
  - 当前抢麦状态

## ESP 固件模块

- `DisplayUI`
  - 方位/距离/通话状态绘制
  - 断线/配网/低电提示

- `TouchInput`
  - 静音/取消静音
  - 音量调整
  - 成员选择
  - 设置页入口

- `BlePairing`
  - BLE 广播
  - GATT 服务
  - 配网和绑定

- `WifiManager`
  - STA 连接路由器或 iPhone 热点
  - 重连
  - 信号状态

- `CloudClient`
  - WSS 连接
  - 鉴权
  - 心跳
  - 消息分发

- `AudioCapture`
  - ES7210/I2S 麦克风采集
  - 8kHz mono 重采样
  - G.711 μ-law 编码

- `AudioPlayback`
  - G.711 μ-law 解码
  - ES8311/I2S 播放
  - 音量控制

- `VoiceController`
  - 本地静音状态
  - VAD 有声检测状态
  - 上行/下行语音 session 状态
  - 音频丢包和延迟统计

- `MemberStateStore`
  - 房间成员位置
  - 房间成员在线状态
  - 房间成员语音状态

## 安全

- 所有公网连接使用 TLS：`https://` 和 `wss://`
- 设备 token 由 App 绑定时下发
- BLE 配网写入必须加密，不能明文广播 Wi-Fi 密码
- 语音帧只在房间成员之间转发
- 服务端验证 `room_id + device_id + token`
- 邀请码一次性或短期有效
- 设备解绑后立即吊销 device token

## MVP 开发顺序

1. 服务端：账号、设备、房间、WSS 基础通道。
2. iOS：登录、BLE 扫描绑定、创建最多 7 人房间、上传定位。
3. ESP：Wi-Fi 连接、WSS hello/heartbeat、显示服务端下发文本。
4. 定位链路：任一 iPhone 上传定位，同房间其他 ESP 屏幕显示该成员位置。
5. 抢麦控制：1 台 ESP 成功获得发言权，其他 ESP 收到当前抢麦状态。
6. 单人语音上行：持有发言权的 ESP 上传麦克风帧，服务端收到并统计。
7. 单人语音下行：Relay 将当前抢麦者声音转发给其他在线 ESP；并发抢麦返回 `voice_busy`。
8. 断线重连：ESP、App、服务端分别做重连和状态恢复。
9. 现场测试：最多 7 名成员、不同网络、iPhone 热点、家用 Wi-Fi、弱网。

## 验收标准

- 最多 7 块 ESP 均能通过各自 iPhone App 完成绑定。
- 最多 7 块 ESP 均能通过 Wi-Fi 连接 Relay Server。
- 任一 iPhone 的定位变化能在同房间其他 ESP 屏幕上显示。
- 房间第 8 名成员尝试加入时，服务端拒绝并返回明确错误码。
- 1 人说话时，其余在线 ESP 都能播放该成员声音。
- 2-7 人同时抢麦时，只允许 1 人获得发言权，其余设备收到明确 busy 状态。
- 任一 ESP 本地静音后，服务端不再把该 ESP 的麦克风输入混入其他成员下行。
- 任一 ESP 断网后，其他成员 ESP 在 5 秒内显示该设备离线。
- 任一 iPhone 定位失效后，其他成员 ESP 显示该成员定位无效。
- 云端日志能追踪每次房间、设备、定位、抢麦 session、上行帧、下行语音帧。

## 官方依据

- ESP32-S3 支持 2.4GHz Wi-Fi 与 Bluetooth LE 5，适合 ESP 直连云端和 BLE 近场配对：<https://www.espressif.com/en/products/socs/esp32-s3>
- ESP-IDF 文档说明 ESP32-S3 支持 Bluetooth LE，BluFi 可通过蓝牙进行 Wi-Fi 配网：<https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/api-guides/ble/overview.html>
- iOS `URLSessionWebSocketTask` 支持 WebSocket binary/text message over TCP/TLS：<https://developer.apple.com/documentation/Foundation/URLSessionWebSocketTask>
- iOS 定位使用 CoreLocation：<https://developer.apple.com/documentation/corelocation>
- iOS 蓝牙使用 CoreBluetooth：<https://developer.apple.com/documentation/corebluetooth>
- iOS 音频采集/播放可用 AVAudioEngine：<https://developer.apple.com/documentation/avfaudio/avaudioengine>
