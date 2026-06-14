# Dragon Radar 产品设计与当前目标

## 当前结论

实体 `DBALL-*` 寻宝玩法已经废弃。当前项目目标改为：

- 多名成员加入同一个远程房间，首版上限 7 人。
- 每名成员使用 1 台 iPhone + 1 块 `Waveshare ESP32-S3-Touch-AMOLED-1.75C`。
- iPhone 负责定位、指南针、账号、房间、设备绑定和 Wi-Fi/热点配置。
- ESP 负责圆屏雷达显示、触摸控制、麦克风采集、扬声器播放和云端实时链路。
- 云端 Relay 负责房间状态、定位转发、在线状态、抢麦控制和语音帧转发。

旧的实体信标、收集、召唤、field hunt、七颗球验收不再作为产品目标，也不再作为完成标准。

## 产品形态

Dragon Radar 是一个多人远程定位与抢麦语音终端。

每个用户的使用链路：

```text
iPhone 获取定位/管理房间
        |
        | BLE 配对、配网、写入 server_config/local_location
        v
ESP 圆屏显示房间成员位置，并通过 Wi-Fi/WSS 连接 Relay
        |
        | WSS: device_status / voice_frame / heartbeat
        v
Relay Server
        ^
        | WSS: app_location / room_state / room_switch
        |
其他成员的 iPhone + ESP
```

## MVP 功能

必须完成：

- App 创建/加入房间，首版房间上限 7 人。
- App 通过 CoreLocation 获取本机定位，并上传 Relay。
- App 通过 CoreBluetooth 扫描 `CapsuleRadar-*`，完成设备绑定、Wi-Fi 配网和 server_config 写入。
- ESP 通过 BLE 暴露配置服务，接收 Wi-Fi、房间、Relay URL、设备 token 和本机定位摘要。
- ESP 通过 Wi-Fi 连接 Relay，维持 `/v1/radar/device/ws` 长连接。
- Relay 维护 room_state，把同一成员的 App 和 ESP 合并成一个成员状态。
- ESP 圆屏显示同房间其他成员的距离、方位、在线状态、定位新鲜度和说话状态。
- ESP 触摸或按键触发抢麦/释放麦。
- Relay 维护抢麦状态：同一时间只允许一个成员获得发言权，其他成员收到 `voice_busy`。
- ESP 上行麦克风语音帧，其他在线 ESP 下行播放远端语音帧。
- 断线后 App、ESP、Relay 都能恢复房间状态。

## 不做的功能

- 不做实体 `DBALL-*` 信标。
- 不做信标制作、隐藏、收集、召唤动画作为完成标准。
- 不做离线地图包。
- 不让 iPhone 转发 ESP 音频；语音由 ESP 直接走云端 Relay。
- 首版不做多人同时混音。当前语音目标是抢麦：一个成员说话，其他成员听。

## 模块职责

### ESP 固件

- BLE 配置服务：`pairing_challenge`、`pairing_response`、`wifi_config`、`local_location`、`device_status`、`server_config`。
- Wi-Fi STA：连接路由器或 iPhone Personal Hotspot。
- CloudClient：连接 Relay，发送 hello、heartbeat、device_status、voice_frame。
- RoomStateStore：解析 room_state，保存远端成员定位、在线状态和语音状态。
- RadarUI：圆屏矩形网格、远端成员 marker、距离/方位、网络状态、说话状态。
- VoiceController：抢麦、静音、VAD、音频帧上行、远端语音播放。

### iOS App

- 房间：创建、加入、切房、显示成员列表。
- 定位：上传本机 GPS/course/accuracy，并过滤模拟默认定位。
- BLE：扫描、绑定、写 Wi-Fi、写 server_config、写 local_location。
- 设备：展示 ESP 的 BLE、Wi-Fi、Relay、定位、语音状态。
- 诊断：展示 Relay room_state、device_status、voice_status 和最近错误。

### Relay Server

- 接入 `/v1/radar/app/ws` 和 `/v1/radar/device/ws`。
- 按 room + group 合并 App/ESP 成员。
- 广播 room_state。
- 转发 app_location 给同房间设备。
- 管理抢麦状态和 `voice_busy`。
- 转发 `voice_frame`，并记录抢麦、上行、下行语音帧日志。

## 验收标准

当前目标完成需要满足：

- 1 个房间内至少 2 组 `iPhone + ESP` 能同时在线。
- 任一 iPhone 定位变化后，同房间其他 ESP 能在圆屏显示距离/方位变化。
- 房间第 8 名成员加入会被 Relay 拒绝，并返回明确错误。
- ESP 断网后，其他成员在 room_state 中看到该设备离线。
- 一个 ESP 抢麦时，其他 ESP 不能同时抢到麦，并收到 busy 状态。
- 抢麦成员的语音帧能被 Relay 转发到其他 ESP，并触发播放状态。
- iOS App 能显示房间成员、定位、设备在线、Wi-Fi、Relay、语音状态。
- 固件和 App 均能重新连接 Relay 并恢复当前房间。

## 当前状态

截至当前工作区：

- Relay smoke 已能证明 App/Device 同房间、定位转发、voice_state 回填。
- iOS App 已有 4 Tab 信息架构、BLE 配置、定位上传、Relay room_state 解析。
- ESP 固件已具备 BLE 配置服务、Wi-Fi/WSS、room_state 解析、远端定位 marker、PTT/VAD/语音帧雏形。
- 还缺真实 2 组以上硬件联调、生产鉴权、持久化房间、TLS 部署和完整抢麦语音实测。
