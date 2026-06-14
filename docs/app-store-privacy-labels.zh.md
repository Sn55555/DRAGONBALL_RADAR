# Dragon Radar App Store 隐私标签草案

更新时间：2026-06-11

本文用于准备 App Store Connect 的隐私问卷和审核说明。最终提交前仍需以 TestFlight 真机行为为准复核。

## 数据类别

### 位置

- 数据：实时经纬度、水平精度、速度、方向、时间戳、上传序号。
- 用途：App 功能。
- 是否关联用户：是。定位通过登录用户所在房间和本机 ESP 绑定关系共享。
- 是否用于追踪：否。
- 共享范围：当前房间成员和本机 ESP；Relay 保存最近状态用于房间同步。
- 用户控制：`我的 > iPhone 定位桥接 > 暂停共享`；暂停后 Relay 返回 `location_paused=true` 且不再暴露坐标。

### 标识符

- 数据：Apple 用户 ID、Dragon Radar 用户 ID、设备 ID、device token、room/member ID。
- 用途：账号、设备绑定、房间成员身份、Relay 鉴权。
- 是否关联用户：是。
- 是否用于追踪：否。
- 用户控制：退出登录清理本机 session；解绑设备会撤销旧 device token。

### 诊断

- 数据：App 版本、build、环境、Relay/BLE/ESP/语音状态摘要、最近事件、room_state 摘要。
- 用途：故障排查。
- 是否关联用户：是，仅登录用户可上传诊断包。
- 是否用于追踪：否。
- 用户控制：用户手动点击设备页诊断上传；诊断包不包含 token、Wi-Fi 密码和精确历史轨迹。

### 用户内容

- 当前 iOS App 不采集、不录制、不播放语音。
- ESP 负责麦克风采集和扬声器播放；App 只展示 `voice_floor`、当前说话者、busy 和语音链路状态。

## 权限文案一致性

- 定位：用于向房间成员共享当前位置，并让 ESP 在 App 前后台切换后继续获得本机位置。
- 蓝牙：用于扫描、绑定和配置 ESP 雷达设备。
- 本地网络：Debug 环境用于连接开发 Relay；Release 环境应使用 `https/wss` 生产域名。
- 通知：用于房间邀请、设备离线和抢麦异常提醒。当前 App 已有通知授权流程；APNs 服务端投递仍待上线实现。

## 上线前复核项

1. TestFlight 真机确认暂停定位后其他成员看到“定位已暂停”。
2. TestFlight 真机确认诊断包不含 token、Wi-Fi 密码、精确历史轨迹。
3. 确认 App Store Connect 隐私问卷选择与本文一致。
4. 若后续加入 APNs 远程推送，补充推送 token 的收集和用途说明。
