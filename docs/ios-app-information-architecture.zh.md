# iOS App 信息架构、页面、交互与状态

## 目标

这份文档定义 Dragon Radar 配套 iOS App 的产品结构。它基于
`docs/remote-multi-radar-architecture.zh.md`，服务于“最多 7 台 ESP + 7 台
iPhone 异地远程定位与同时语音”的产品形态。

iOS App 的首版定位：

- 负责账号、设备绑定、Wi-Fi/热点配网、房间管理、GPS/指南针上传和诊断。
- 不作为首版语音终端。语音采集和播放由 ESP 完成。
- 不渲染复杂地图作为主体验。ESP 圆屏是现场主显示，App 是设置、管理和备用状态台。

## 用户与对象模型

核心对象：

| 对象 | 含义 | App 内职责 |
| --- | --- | --- |
| `User` | iPhone App 登录用户 | 登录、设备归属、房间成员身份 |
| `Device` | 一块 ESP32-S3-Touch-AMOLED-1.75C | 绑定、配网、状态、固件版本 |
| `Room` | 最多 7 人的远程定位/语音会话 | 创建、加入、邀请、成员管理 |
| `RoomMember` | 房间中的一名用户和其活跃设备 | 在线、定位、语音、设备状态 |
| `LocationState` | iPhone 当前定位状态 | 上传 Relay，写给本机 ESP |
| `VoiceState` | 服务端语音混音状态 | 展示谁在说话、静音、丢包、延迟 |

关键约束：

- 每名成员首版只允许 1 台活跃 ESP。
- 每个房间最多 7 名成员。
- 第 8 名成员加入必须被拒绝，并显示明确原因。
- App 与 ESP 通过 BLE 配对和配网。
- ESP 与 Relay 通过 Wi-Fi/WSS 通信。
- App 与 Relay 通过 HTTPS/WSS 通信。

## 信息架构

首版使用 4 个主 Tab：

```text
App
├─ 雷达 Radar
│  ├─ 当前房间概览
│  ├─ 成员详情
│  ├─ 定位状态
│  └─ 语音状态
├─ 房间 Rooms
│  ├─ 我的房间
│  ├─ 创建房间
│  ├─ 加入房间
│  ├─ 邀请成员
│  └─ 房间设置
├─ 设备 Devices
│  ├─ 设备列表
│  ├─ 扫描 ESP
│  ├─ 绑定设备
│  ├─ Wi-Fi/热点配置
│  ├─ 设备详情
│  └─ 设备诊断
└─ 我的 Account
   ├─ 账号资料
   ├─ 定位权限
   ├─ 通知权限
   ├─ 隐私与安全
   └─ 帮助与故障排查
```

启动前置流程独立于 Tab：

```text
Launch
├─ 首次介绍
├─ 登录
├─ 权限引导
├─ 绑定第一台 ESP
├─ 配置 ESP 网络
└─ 创建或加入房间
```

## 全局导航规则

- 已登录、有设备、有房间：默认进入 `雷达`。
- 已登录、有设备、无房间：默认进入 `房间`，展示创建/加入入口。
- 已登录、无设备：默认进入 `设备`，展示扫描 ESP。
- 未登录：进入登录流程。
- 定位权限未授权：允许进入 App，但 `雷达` 和 `房间` 顶部显示定位不可用警示。
- ESP 未在线：允许进入 App，但 `雷达` 顶部显示设备离线，房间成员仍可从 App 侧看到。

## 页面规格

### 1. Launch

用途：

- 快速判断登录、设备、房间、权限状态，并分流。

显示：

- App 名称与设备连接状态检查。
- 失败时显示“无法连接服务”或“本地状态读取失败”。

交互：

- 自动跳转。
- 服务不可用时允许重试。

状态：

- `checkingLocalSession`
- `checkingServer`
- `needsLogin`
- `needsPermissions`
- `needsDevice`
- `needsRoom`
- `ready`
- `serverUnavailable`

### 2. 首次介绍

用途：

- 用 3 屏说明 App 与 ESP 的分工，不做营销页。

页面：

1. “iPhone 提供定位”：说明 GPS/指南针来自手机。
2. “ESP 做现场终端”：说明屏幕、麦克风、扬声器在 ESP 上。
3. “最多 7 人远程房间”：说明需要云端 Relay 和 Wi-Fi/热点。

交互：

- `继续`
- `跳过`

状态：

- `firstRun`
- `skipped`
- `completed`

### 3. 登录

用途：

- 建立用户身份和设备归属。

首版登录方式：

- Sign in with Apple。

交互：

- 点击登录。
- 登录成功后同步用户资料。
- 登录失败后显示错误并允许重试。

状态：

- `signedOut`
- `signingIn`
- `signedIn`
- `signInFailed`
- `networkUnavailable`

### 4. 权限引导

用途：

- 获取定位、蓝牙和通知权限。

权限：

- `Location When In Use`：必需。
- `Precise Location`：推荐。
- `Bluetooth`：必需，用于 ESP 配对和配网。
- `Notifications`：可选，用于房间邀请和设备离线提示。

交互：

- 每个权限一行，显示状态和动作。
- 已拒绝权限时跳转系统设置。

状态：

- `notDetermined`
- `authorized`
- `denied`
- `restricted`
- `reducedAccuracy`
- `precise`

### 5. 雷达 Tab：当前房间概览

用途：

- App 侧备用状态台，显示房间、成员、定位和语音状态。

布局：

- 顶部：当前房间名、在线人数、语音状态。
- 主区：最多 7 个成员列表，按距离或最近活跃排序。
- 每个成员行：
  - 名称
  - 在线/离线
  - 距离
  - 方位
  - 定位精度
  - 是否正在说话
  - 设备在线状态
- 底部：本机 ESP 状态条。

交互：

- 点击成员进入成员详情。
- 长按成员打开成员操作菜单。
- 点击 ESP 状态条进入设备详情。
- 点击定位警示进入权限页。

成员操作：

- 设为关注成员。
- 静音该成员在 App 侧提示音，不影响 ESP 混音。
- 查看定位详情。
- 从房间移除，仅房主可见。

状态：

- `noActiveRoom`
- `roomLoading`
- `roomReady`
- `roomFull`
- `memberOffline`
- `memberLocationInvalid`
- `deviceOffline`
- `voiceActive`
- `voiceDegraded`

### 6. 成员详情

用途：

- 查看某个房间成员的定位、设备和语音状态。

显示：

- 成员名、头像或缩写。
- 距离、方位、定位精度、更新时间。
- 设备状态：ESP 在线、Wi-Fi RSSI、电量、固件版本。
- 语音状态：静音、VAD 活跃、上行帧、下行混音帧。

交互：

- `关注此成员`
- `取消关注`
- `复制诊断信息`
- 房主可执行 `移出房间`

状态：

- `selected`
- `followed`
- `offline`
- `staleLocation`
- `speaking`
- `muted`

### 7. 房间 Tab：我的房间

用途：

- 创建、加入、管理最多 7 人房间。

显示：

- 当前活跃房间。
- 最近加入的房间。
- 创建房间入口。
- 加入房间入口。

交互：

- 点击房间进入房间详情。
- 点击创建进入创建房间流程。
- 点击加入输入邀请码或扫描二维码。

状态：

- `empty`
- `loading`
- `hasActiveRoom`
- `joinPending`
- `joinRejectedRoomFull`
- `joinRejectedInvalidCode`

### 8. 创建房间

用途：

- 创建一个最多 7 人远程房间。

字段：

- 房间名。
- 是否允许邀请链接重复使用。
- 邀请码有效期。
- 成员上限，首版固定 `7`，不可调。

交互：

- `创建`
- 创建成功后进入邀请页。

状态：

- `editing`
- `creating`
- `created`
- `createFailed`

### 9. 加入房间

用途：

- 通过邀请码加入已有房间。

输入：

- 6-8 位邀请码。
- 或扫描二维码。

交互：

- 输入自动格式化。
- 加入前显示房间名和当前人数。
- 满员时禁用加入。

状态：

- `editingCode`
- `checkingCode`
- `previewRoom`
- `joining`
- `joined`
- `invalidCode`
- `expiredCode`
- `roomFull`

### 10. 邀请成员

用途：

- 房主邀请其他成员加入。

显示：

- 邀请码。
- 二维码。
- 当前成员数：`n / 7`。
- 过期时间。

交互：

- 复制邀请码。
- 分享邀请链接。
- 刷新邀请码。

状态：

- `available`
- `expired`
- `roomFull`
- `refreshing`

### 11. 房间设置

用途：

- 管理当前房间。

功能：

- 修改房间名。
- 查看成员列表。
- 移除成员。
- 刷新邀请码。
- 解散房间。

状态：

- `owner`
- `member`
- `saving`
- `deleteConfirm`
- `deleted`

### 12. 设备 Tab：设备列表

用途：

- 管理当前用户绑定的 ESP。

显示：

- 已绑定设备。
- 当前活跃设备。
- 设备在线状态。
- 电量、Wi-Fi、云连接状态。
- 扫描新设备入口。

交互：

- 点击设备进入详情。
- 点击扫描进入 BLE 扫描。
- 切换活跃设备。

状态：

- `empty`
- `scanningSuggested`
- `deviceOnline`
- `deviceOffline`
- `cloudDisconnected`
- `wifiDisconnected`

### 13. 扫描 ESP

用途：

- 通过 BLE 找到附近的 `CapsuleRadar-*`。

显示：

- 扫描中状态。
- 发现的设备列表。
- 每个设备显示：
  - BLE 名称
  - shortId
  - RSSI
  - 是否已绑定

交互：

- 点击未绑定设备进入绑定。
- 已绑定设备显示“已绑定”。
- 手动刷新扫描。

状态：

- `bluetoothUnauthorized`
- `scanning`
- `noDevicesFound`
- `devicesFound`
- `deviceAlreadyBound`
- `scanFailed`

### 14. 绑定设备

用途：

- 完成 BLE challenge/response 绑定。

流程：

1. App 连接 ESP BLE。
2. ESP 发 `pairing_challenge`。
3. App 向服务端换取绑定响应。
4. App 写入 `pairing_response`。
5. ESP 确认绑定。
6. App 下发 `server_config`。

交互：

- 显示绑定进度。
- 失败后允许重试。

状态：

- `connectingBle`
- `readingChallenge`
- `registeringDevice`
- `writingResponse`
- `writingServerConfig`
- `bound`
- `bleConnectionFailed`
- `challengeExpired`
- `serverRejected`

### 15. Wi-Fi/热点配置

用途：

- 让 ESP 可以上公网连接 Relay。

首版推荐模式：

- iPhone 开 Personal Hotspot，ESP 作为 Wi-Fi STA 连接 iPhone 热点。
- 也支持家庭路由器 Wi-Fi。

显示：

- 当前 ESP Wi-Fi 状态。
- 已保存网络。
- 新网络 SSID/密码输入。
- iPhone 热点操作指引。

交互：

- 写入 `wifi_config`。
- 等待 ESP 连接。
- 显示云端连接结果。

状态：

- `needsWifi`
- `editingCredentials`
- `writingCredentials`
- `connectingWifi`
- `wifiConnected`
- `cloudConnecting`
- `cloudConnected`
- `wrongPassword`
- `ssidNotFound`
- `hotspotNotAvailable`
- `cloudFailed`

### 16. 设备详情

用途：

- 查看和调试本机 ESP。

显示：

- 设备名、shortId、绑定用户。
- BLE 状态。
- Wi-Fi SSID、RSSI。
- Relay 连接状态。
- 电量。
- 固件版本。
- 音频上行/下行状态。
- 最近错误。

交互：

- 重命名。
- 重新配网。
- 设为活跃设备。
- 解绑。
- 进入诊断。

状态：

- `online`
- `offline`
- `bleConnected`
- `bleDisconnected`
- `wifiConnected`
- `cloudConnected`
- `audioHealthy`
- `audioDegraded`
- `unbindConfirm`

### 17. 设备诊断

用途：

- 给开发和现场排障使用。

诊断项：

- BLE 连接。
- Wi-Fi 连接。
- Relay WSS。
- 定位上传。
- ESP `device_status`。
- 房间状态。
- 语音上行帧。
- 混音下行帧。
- 丢包和延迟。

交互：

- 一键运行诊断。
- 复制诊断包。
- 上传诊断包到服务端。

状态：

- `idle`
- `running`
- `passed`
- `failed`
- `partial`

### 18. 我的 Tab

用途：

- 账号、权限、安全和帮助。

页面：

- 账号资料。
- 定位权限。
- 蓝牙权限。
- 通知权限。
- 隐私与安全。
- 帮助与故障排查。
- 退出登录。

状态：

- `signedIn`
- `permissionWarning`
- `signingOut`
- `signedOut`

## 关键用户流

### A. 首次使用

```text
Launch
-> 首次介绍
-> Sign in with Apple
-> 权限引导
-> 扫描 ESP
-> 绑定设备
-> Wi-Fi/热点配置
-> 创建房间
-> 邀请成员
-> 雷达 Tab
```

成功标准：

- App 已登录。
- ESP 已绑定。
- ESP 已连云端。
- iPhone 定位有效。
- 房间已创建。

### B. 加入朋友房间

```text
Launch
-> 登录
-> 设备检查
-> 加入房间
-> 输入邀请码 / 扫二维码
-> 房间预览
-> 加入
-> 雷达 Tab
```

失败处理：

- 房间满员：显示 `房间已满，最多 7 人`。
- 邀请码过期：提示找房主刷新。
- 无活跃设备：先跳转设备绑定。

### C. ESP 连接 iPhone 热点

```text
设备详情
-> Wi-Fi/热点配置
-> 提示开启 iPhone 个人热点
-> 输入或选择热点 SSID
-> 写入 ESP
-> 等待 Wi-Fi
-> 等待 Relay
-> 成功返回设备详情
```

注意：

- iOS App 不能可靠地自动开启 Personal Hotspot。
- 页面必须明确告诉用户手动开启热点。
- 成功判断以 ESP `cloudConnected` 为准，不只看 Wi-Fi 连接。

### D. 定位上传

```text
LocationModule 获取定位
-> App 上传 Relay
-> App 写 local_location 给本机 ESP
-> Relay 转发 member_display_state 给其他 ESP
-> 其他 ESP 更新圆屏
```

状态处理：

- 精准定位关闭：显示低精度警示。
- 定位超过 10 秒未更新：显示 stale。
- 定位权限关闭：房间内该成员显示定位无效。

### E. 7 人同时语音状态展示

```text
ESP 上传 audio_frame
-> Relay 混音
-> Relay 下发 voice_state 给 App
-> App 在雷达 Tab 显示活跃说话成员
-> ESP 播放 audio_mix_frame
```

App 不播放首版语音，只展示：

- 谁正在说话。
- 谁静音。
- 谁的设备离线。
- 语音质量是否下降。

## 状态体系

### SessionState

```text
signedOut
signingIn
signedIn
refreshingToken
expired
```

### PermissionState

```text
locationMissing
locationReducedAccuracy
bluetoothMissing
notificationMissing
ready
```

### DeviceState

```text
unbound
bleScanning
bleConnected
bound
wifiMissing
wifiConnecting
wifiConnected
cloudConnecting
cloudConnected
cloudDisconnected
offline
```

### RoomState

```text
none
creating
joining
active
full
left
deleted
```

### LocationHealth

```text
validPrecise
validReduced
stale
invalid
permissionDenied
```

### VoiceHealth

```text
idle
active
muted
degraded
packetLossHigh
relayDisconnected
```

## 错误与空状态文案

| 场景 | 用户可见文案 | 主操作 |
| --- | --- | --- |
| 没有设备 | 还没有绑定 Dragon Radar 设备 | 扫描 ESP |
| 找不到 ESP | 附近没有发现 CapsuleRadar 设备 | 重新扫描 |
| BLE 未授权 | 需要蓝牙权限才能绑定 ESP | 打开设置 |
| ESP 未联网 | ESP 还没有连接可上网的 Wi-Fi | 配置网络 |
| 云端断开 | ESP 已连 Wi-Fi，但无法连接 Relay | 查看诊断 |
| 没有房间 | 创建或加入一个远程房间 | 创建房间 |
| 房间满员 | 房间已满，最多 7 人 | 返回 |
| 定位关闭 | 开启定位后才能共享位置 | 打开设置 |
| 低精度定位 | 当前是低精度定位，距离和方位可能不准 | 开启精准定位 |
| 语音质量差 | 当前网络下语音可能断续 | 查看诊断 |

## 首版范围

必须做：

- Sign in with Apple。
- BLE 扫描和设备绑定流程。
- Wi-Fi/热点配置流程。
- 创建、加入、邀请最多 7 人房间。
- iPhone 定位上传。
- 房间成员状态展示。
- ESP 状态展示。
- 语音状态展示。
- 诊断页。

首版不做：

- App 内语音播放/录音。
- 复杂地图导航。
- 多设备同时绑定到同一成员。
- 房间内分频道。
- UWB/GNSS 外设配置。
- App 内固件 OTA，除非固件团队已提供稳定接口。

## 实现拆分建议

Swift 模块：

```text
DragonRadarApp
├─ AppShell
├─ Auth
├─ Permissions
├─ BluetoothPairing
├─ DeviceConfig
├─ Rooms
├─ LocationBridge
├─ RelayClient
├─ Diagnostics
└─ SharedUI
```

核心 ViewModel：

- `AppSessionViewModel`
- `PermissionViewModel`
- `DeviceListViewModel`
- `PairingViewModel`
- `WifiConfigViewModel`
- `RoomListViewModel`
- `RoomDetailViewModel`
- `RadarOverviewViewModel`
- `MemberDetailViewModel`
- `DiagnosticsViewModel`

数据同步优先级：

1. 登录和 token。
2. 本机设备绑定状态。
3. 活跃房间状态。
4. 定位上传。
5. ESP 状态。
6. 语音状态。
7. 诊断指标。

## 验收标准

- 新用户能从零完成登录、授权、绑定 ESP、配网、创建房间。
- 第二名用户能通过邀请码加入房间。
- 第 8 名用户加入时被拒绝，文案明确。
- 任一成员定位变化后，App 内成员列表状态更新。
- ESP 离线、Wi-Fi 断开、云端断开能被区分展示。
- 定位权限关闭、低精度、过期定位能被区分展示。
- 房间语音状态能展示多个同时发声成员。
- 诊断页能复制包含 BLE、Wi-Fi、Relay、定位、语音帧统计的诊断包。
