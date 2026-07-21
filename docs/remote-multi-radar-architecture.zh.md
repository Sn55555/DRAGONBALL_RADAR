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
- CST9217 触摸：北向校准、系统菜单、音量、亮度和 6/12 点屏幕方向切换
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
- 持久化本机 6/12 点握持方向，并让显示与触摸坐标共同旋转 180°；该设置不进入 Relay 或 LocationFrame

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
  uint8_t  flags;            // bit0 valid, bit1 reduced_accuracy, bit2 radar_heading_valid
  int32_t  lat_e7;           // latitude * 1e7
  int32_t  lon_e7;           // longitude * 1e7
  int32_t  altitude_cm;      // altitude meters * 100, unknown = INT32_MIN
  uint16_t h_accuracy_cm;    // horizontal accuracy
  uint16_t v_accuracy_cm;    // vertical accuracy
  uint16_t speed_cms;        // speed m/s * 100
  uint16_t course_deg100;    // 行进方向 degrees * 100，不代表设备朝向
  uint16_t heading_deg100;   // 雷达本体绝对朝向 * 100；bit2=0 时必须忽略
  uint32_t unix_time_s;
};
```

当前 v1 合同必须遵守以下边界：

- iPhone 通常放在口袋中，手机 `CLHeading` 与手持雷达 12 点方向不存在可验证的姿态关系。
- App 因此始终令 `radar_heading_valid`（bit2）为 `0`，并把 `heading_deg100` 写为 `0`；手机航向只允许进入本机诊断，不上传 Relay，也不能用于旋转雷达目标。
- `course_deg100` 是 GPS 行进方向，只能用于成员运动标记，不能替代雷达朝向。
- 当前 QMI8658 使用 Fusion 6DOF AHRS 提供重力方向、倾斜补偿和相对 yaw；静止检测同时检查加速度、全向角速度、重力轴角速度和方差。温度匹配的持久零偏只作为热启动种子，本次严格静止窗口会重新验证并替换失配值；严格静止时执行零角速度更新并锁住 yaw，检测到转动后恢复积分。启动动画结束后，ESP 只在本次真实开机显示一次北向零点教学提示；用户将雷达尽量平放、把机身零点/屏幕 12 点方向对准真北 N，并静止长按屏幕 1.2 秒。BOOT 短按只关闭提示并切换成员，不能重新唤出或触发校准；提示关闭后不再显示教学层，但主雷达静止长按 1.2 秒的校准入口永久可用，已校准时再次长按会覆盖旧偏移。设此刻 QMI 逆时针相对 yaw 为 `G0`，会话偏移 `C = wrap360(-G0)`，统一屏幕旋转 `R = wrap360(G+C)`，任一成员真北方位 `B_i` 的屏幕角为 `wrap360(B_i+R)`。
- 校准只接受 QMI `RelativeStable`、250ms 内的新样本和不高于 3°/s 的角速度；不再使用成员 GPS 方位、成员距离、GPS 精度或手机 `CLHeading` 建立偏移。严格静止验证得到的零偏会立即保存；后续开机只有在保存结构有效、当前/保存温度均可用且温差不超过 6°C 时才作为快速启动种子，并在设备继续静止时自动完成本次严格复核。待机只清相对 yaw 与北向偏移、不清该可信零偏。物理触摸满 1.2 秒后即消费为长按；若首次使用或温差过大，手指仍按住时继续严格学习，在线学习显示 `HOLD STILL`，只有 IMU 离线或样本过期显示 `IMU WAIT`。松手前仍未通过则保持未校准且不得再误判为短触；成功只表示用户已设定北向零点，固件无法验证机身是否真的对准真北。
- GPS 只更新东/北世界坐标，不参与旋转偏移。远程定位先做精度相关平滑，再按原有半格步长吸附并增加换格滞回，最后让绿色网格、成员和运动方向使用同一帧旋转矩阵整体转动；主雷达不额外绘制外圈 `N` 或目标真实方位刻度线。
- 北向偏移是雷达本机的 IMU 会话状态，不设置 LocationFrame bit2，也不写入 NVS。切成员、切房、GPS 更新和网络重连不得修改；熄屏且 IMU 持续运行时保留；待机、重启、IMU 重置或积分采样断档时清除。只有真实重启会重新显示一次教学提示；待机唤醒或运行中断档不弹提示，用户通过常驻长按手势重新校准。将来只有雷达本体产生经过质量门限验证的绝对航向时，才允许设置 bit2；旧 App/Relay 仍按 bit2=0 兼容。

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

App 房间提醒使用独立的受鉴权命令和定向事件：

- `POST /v1/rooms/{room_code}/radar-reminders`：仅房间成员可调用，服务端从持久成员关系派生其他收件人，不接受客户端指定目标、标题或跳转链接。
- `radar_reminder`：只定向发送给收件人的 App WebSocket；相同事件同时尝试通过 APNs 覆盖后台或离线 App，ESP 不接收。
- 服务端按 `room + sender` 做业务冷却和请求幂等，响应只返回收件人数、在线投递数和聚合推送状态，不暴露用户 ID、member/group ID 或设备 token。

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

雷达端用户 UI 的完整屏幕状态、异常文案、PTT 反馈、设置页和验收标准见
`docs/esp-radar-ui-spec.zh.md`。该文档是固件 UI 调整的产品合同；架构文档只保留职责和数据流。

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
  - CoreLocation 获取定位、速度和 course；手机 heading 仅用于诊断，不充当雷达 heading
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
