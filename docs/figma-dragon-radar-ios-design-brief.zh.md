# Figma 设计稿 Brief：Dragon Radar iOS App

目标文件：

```text
Dragon Radar iOS App 功能设计图
https://www.figma.com/design/wLBJq4AGUVQIc2heMXekeS
```

当前状态：

- Figma 文件已创建。
- Figma MCP Starter plan 已触发调用额度限制，暂时无法继续写入画板。
- 这份 brief 作为恢复写入后的 Figma 生成规格。

## 设计目标

做一版 iOS App 功能设计图，用于说明 Dragon Radar App 的信息架构、关键页面、用户流和状态。

产品前提：

- 最多 7 名成员。
- 每名成员 1 台 iPhone + 1 块 ESP32-S3-Touch-AMOLED-1.75C。
- iPhone 负责登录、BLE 绑定、配网、定位上传、房间管理和诊断。
- ESP 负责圆屏显示、麦克风、扬声器和云端语音链路。
- 远程定位和最多 7 人房间抢麦语音通过 Relay Server。

## 视觉方向

关键词：

- Apple iOS 原生结构
- Liquid Glass / system material
- 漫画分镜感
- 能量线
- 雷达绿色
- 胶囊道具感

禁止项：

- 不使用官方龙珠角色、logo、龙珠星球图案或版权插画。
- 不做 Web SaaS 仪表盘风。
- 不把 App 做成营销 landing page。

设计语气：

- iOS 信息层级清晰、可实现。
- 功能界面为主，漫画风格只作为背景能量线、分镜边框、状态徽章和启动页氛围。
- 真实业务状态优先于装饰。

## Figma 页面结构

建议创建 4 个 Figma Pages：

```text
01 Overview
02 iOS Screens
03 Flows And States
04 Design Notes
```

## 01 Overview

### Cover

尺寸：`1440 x 900`

内容：

- 标题：`Dragon Radar iOS App 功能设计图`
- 副标题：`最多 7 人房间抢麦 · iPhone 定位桥接 · ESP 圆屏现场终端`
- 架构简图：
  - iPhone 1..7
  - ESP 1..7
  - Relay Server
  - BLE：iPhone <-> ESP
  - WSS：ESP/App <-> Relay

视觉：

- 深绿色背景。
- 雷达网格细线。
- 漫画速度线从边缘向中心收束。
- iOS glass 卡片承载架构说明。

### App IA Map

尺寸：`1440 x 1200`

内容：

```text
Launch
Login
Permissions
Tabs
├─ Radar
├─ Rooms
├─ Devices
└─ Account
```

每个主 Tab 下列出核心页面：

- Radar：房间概览、成员详情、定位状态、语音状态
- Rooms：我的房间、创建、加入、邀请、房间设置
- Devices：设备列表、扫描 ESP、绑定、Wi-Fi/热点配置、设备详情、诊断
- Account：账号、权限、隐私、安全、帮助

## 02 iOS Screens

统一设备框：

- iPhone 15/16 Pro 纵向画板。
- 画板尺寸：`393 x 852` 或 `402 x 874`。
- 使用 iOS tab bar、navigation title、large title、sheet、list row、system button 语法。

### Screen 1：Launch / Intro

目的：

- 解释 iPhone 与 ESP 分工。

内容：

- 标题：`iPhone 定位，ESP 做雷达`
- 三个说明模块：
  - `GPS / 指南针来自 iPhone`
  - `圆屏 / 麦克风 / 扬声器在 ESP`
  - `最多 7 人远程房间`
- 主按钮：`开始设置`

状态：

- firstRun
- serverUnavailable

### Screen 2：Permissions

目的：

- 授权定位、蓝牙、通知。

内容：

- Large title：`准备连接雷达`
- 权限列表：
  - 定位：必需
  - 精准定位：推荐
  - 蓝牙：必需
  - 通知：可选
- 每行显示状态 chip。

交互状态：

- 未授权
- 已授权
- 被拒绝
- 低精度定位

### Screen 3：Device Scan

目的：

- BLE 扫描附近的 `CapsuleRadar-*`。

内容：

- Large title：`绑定 ESP 雷达`
- 扫描状态条。
- 设备列表：
  - `CapsuleRadar-A17C`
  - RSSI
  - 已绑定/可绑定状态
- 空状态：`附近没有发现 CapsuleRadar 设备`

主操作：

- `重新扫描`
- `绑定`

### Screen 4：Pairing Progress

目的：

- 展示 BLE challenge/response 绑定步骤。

内容：

步骤：

1. 连接 BLE
2. 读取挑战码
3. 注册设备
4. 写入服务器配置
5. 绑定完成

状态：

- connectingBle
- readingChallenge
- registeringDevice
- writingServerConfig
- bound
- serverRejected

### Screen 5：Wi-Fi / Hotspot Config

目的：

- 配置 ESP 上公网。

内容：

- 标题：`让 ESP 连接网络`
- 推荐卡片：`使用 iPhone 个人热点`
- 说明：`请手动开启个人热点，ESP 会作为 Wi-Fi 设备连接它`
- 字段：
  - SSID
  - Password
- 状态进度：
  - 写入 ESP
  - 连接 Wi-Fi
  - 连接 Relay

错误状态：

- wrongPassword
- ssidNotFound
- hotspotNotAvailable
- cloudFailed

### Screen 6：Rooms

目的：

- 创建或加入最多 7 人房间。

内容：

- 当前房间卡片。
- 成员数：`4 / 7`
- 操作：
  - `创建房间`
  - `加入房间`
  - `邀请成员`

状态：

- empty
- activeRoom
- roomFull
- invalidInvite

### Screen 7：Radar Overview

目的：

- App 侧备用状态台。

内容：

- 顶部：房间名、在线人数、语音质量。
- 成员列表最多 7 个：
  - 名称
  - 距离
  - 方位
  - 定位精度
  - 正在说话状态
  - ESP 在线状态
- 底部 iOS tab bar。

视觉重点：

- 成员行像 iOS list row。
- 说话成员用绿色声波徽章。
- 定位无效用橙色警示 chip。

### Screen 8：Member Detail

目的：

- 查看单个成员的定位、设备、语音状态。

内容：

- 成员名。
- 距离大数字。
- 方位罗盘。
- 定位精度。
- ESP 状态：
  - 在线
  - Wi-Fi RSSI
  - 电量
  - 固件版本
- 语音状态：
  - muted
  - vad_active
  - uplink frames
  - downlink frames

### Screen 9：Diagnostics

目的：

- 现场排障。

内容：

- 分组列表：
  - BLE
  - Wi-Fi
  - Relay
  - Location
  - Voice uplink
  - Voice mix downlink
- 每组状态：
  - passed
  - failed
  - partial
- 操作：
  - `运行诊断`
  - `复制诊断包`

## 03 Flows And States

### Flow 1：首次使用

```text
Intro -> Login -> Permissions -> Scan ESP -> Pair -> Wi-Fi/Hotspot -> Create Room -> Invite -> Radar
```

### Flow 2：加入朋友房间

```text
Login -> Device Check -> Join Room -> Invite Code -> Room Preview -> Radar
```

### Flow 3：ESP 连接 iPhone 热点

```text
Device Detail -> Wi-Fi Config -> Manual Hotspot Instruction -> Write Credentials -> Wi-Fi Connected -> Relay Connected
```

### Flow 4：定位上传

```text
CoreLocation -> Relay -> member_display_state -> ESP Round Screen
```

### Flow 5：7 人房间抢麦语音状态

```text
ESP voice_claim -> Relay floor grant/busy -> ESP audio_frame -> Relay voice_frame -> App voice_state display
```

## 04 Design Notes

### Apple iOS Rules

- 主导航使用 Tab Bar。
- 设置类页面使用 grouped list。
- 创建/加入流程使用 sheet 或 push stack。
- 状态提示使用 inline banner，不使用大面积弹窗。
- 危险操作使用 confirmation dialog。
- 文案短、直接、行动导向。

### Manga Style Rules

- 漫画感只在：
  - cover
  - radar background
  - voice active badge
  - section dividers
  - empty states
- 不影响表单、权限、诊断页面的可读性。
- 速度线透明度低，不能抢 iOS 层级。

### Color Tokens

建议 tokens：

```text
bgPrimary        #07110D
bgGrouped        #0D1713
surfaceGlass     rgba(255,255,255,0.10)
surfaceElevated  rgba(255,255,255,0.16)
radarGreen       #7CFF8A
energyYellow     #FFD86B
alertOrange      #FF9D42
signalBlue       #6CCBFF
textPrimary      #F4F8EE
textSecondary    #A9B8AA
lineSubtle       rgba(255,255,255,0.14)
```

### Typography

- 使用 Apple/SF 风格层级。
- Figma 中若无 SF，可用 Inter 代替。
- Large title：34
- Title：28
- Headline：17 semibold
- Body：15-17
- Caption：12-13

## Figma 生成顺序

1. 创建 `01 Overview` 页面和 cover。
2. 创建 IA map。
3. 创建 `02 iOS Screens` 页面。
4. 放置 9 个 iPhone 画板。
5. 创建 `03 Flows And States` 页面。
6. 创建 5 条流程图。
7. 创建 `04 Design Notes` 页面。
8. 加入 tokens、状态说明和实现注释。
