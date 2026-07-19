# 胶囊 App Store 隐私标签答题映射

更新时间：2026-07-15

> 本文只覆盖提交 App Store 的 iOS App，包含 App 内通过 BLE 扫描、绑定、配置外设及诊断上传的数据流，不覆盖外设固件自身行为。它是按当前代码与服务端数据流整理的问卷底稿，不是法律意见。最终答案仍须与生产数据库、日志、云服务商和 App Store Connect 页面逐项核对。Apple 参考：[App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/) 与 [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)。

## 建议总答复

- “Do you or your third-party partners collect data from this app?”：**Yes**。
- Tracking：**No**，前提是生产包继续没有广告 SDK、数据经纪商、跨 App/网站广告归因或其他跟踪用途。
- ATT：当前不需要弹出跟踪授权，前提是上述事实不变。
- 下列数据均按保守口径选择 `Linked to the User = Yes`、`Tracking = No`。
- 当前所选数据用途均为 `App Functionality`。

## App Store Connect 逐项映射

| App Store 数据类型 | 是否选择 | 当前来源与用途 | Linked | Tracking | Purpose |
| --- | --- | --- | --- | --- | --- |
| Contact Info > Name | Yes | Sign in with Apple 首次授权姓名、App 显示名和房间成员显示 | Yes | No | App Functionality |
| Identifiers > User ID | Yes | Apple subject、业务 user ID、房间成员标识 | Yes | No | App Functionality |
| Identifiers > Device ID | Yes | APNs token、安装/连接标识，以及已绑定雷达的 `device_id` / `device_token` | Yes | No | App Functionality |
| Location > Precise Location | Yes | 用户主动开启后上传经纬度、精度、速度、时间和序号，用于私人房间内计算距离与方位 | Yes | No | App Functionality |
| Location > Coarse Location | Yes | 用户只允许大致位置时可能上传 Reduced Accuracy 位置 | Yes | No | App Functionality |
| Usage Data > Product Interaction | Yes | 登录、房间操作、提醒、举报、屏蔽、设备绑定/配置、固件更新、诊断提交和安全审计事件 | Yes | No | App Functionality |
| User Content > Other User Content | Yes | 显示名、房间名、用户主动填写的举报说明 | Yes | No | App Functionality |
| Diagnostics > Performance Data | Yes | 用户主动上传状态包时包含房间/Relay 延迟、位置发送与确认时效、Wi-Fi RSSI、语音丢帧等状态指标 | Yes | No | App Functionality |
| Diagnostics > Other Diagnostic Data | Yes | 用户主动上传状态包时包含 App/环境、房间、BLE、设备、固件/OTA 状态、IP 和脱敏事件/错误 | Yes | No | App Functionality |

当前 `PrivacyInfo.xcprivacy` 声明相同的 9 类数据，全部 linked、not tracking，Purpose 为 `App Functionality`。隐私清单不能代替 App Store Connect 问卷，两边必须分别维护并保持一致。

## 当前不选择的数据类型

只有在最终生产行为保持不变时，以下结论才成立：

| 数据类型 | 建议 | 依据 |
| --- | --- | --- |
| Email Address | No | App 只请求 Apple full name，当前服务端不保存 email；若上线前开始保存则改为 Yes |
| Phone Number / Physical Address / Other Contact Info | No | 当前无采集入口 |
| Health / Fitness | No | 不使用 HealthKit、运动或医疗数据 |
| Payment Info / Purchase History / Credit Info | No | 当前无付费、IAP 或订阅 |
| Photos or Videos | No | 头像通过系统 PhotosPicker 选取后只保存在本机，不上传服务端 |
| Audio Data | No | Release 不请求麦克风，不采集、上传或播放用户音频 |
| Gameplay Content | No | 当前不是游戏，也不保存游戏进度 |
| Emails or Text Messages | No | 没有自由文本私聊；“查看雷达”提醒是结构化事件 |
| Browsing History / Search History | No | 无相关功能 |
| Advertising Data | No | 无广告 |
| Crash Data | No | 当前未接入远程崩溃采集 SDK；若接入需改为 Yes |
| Environment Scanning / Hands / Head | No | 不使用相关 API |

## 数据流与留存核对

| 数据 | 发送对象 | 当前保存形态 | 提交前要求 |
| --- | --- | --- | --- |
| 姓名、Apple/业务用户 ID | 胶囊服务 | `users`、`room_members` | 保存至账户删除；隐私政策写明 |
| Apple refresh token | 胶囊服务；删除时调用 Apple | 服务端加密字段 | 生产必须配置加密密钥；删除时撤销并删除 |
| access/refresh token | 胶囊服务 | 业务会话；当前设计为哈希和轮换 | 验证有效期、轮换和退出/删除撤销；不得进日志 |
| 精确/大致位置 | 当前私人房间成员 | 实时房间最新状态，不应持久保存 | 明确最大缓存时长；暂停、离房或断线后移除；日志不得记录完整坐标 |
| APNs token | 胶囊服务、Apple APNs | `push_subscriptions` | 退出解绑、失效 token 停用、账户删除时删除 |
| 已绑定雷达 ID 与设备凭证 | 胶囊服务及用户本人的雷达 | 服务端 `devices` 与本机 Keychain | 解绑或删除账户时清理；日志不得记录完整 device token |
| 房间名、成员关系和提醒 | 胶囊服务与房间成员 | SQLite；提醒默认保留 90 天 | 核对生产留存值、删除语义和访问权限 |
| 内容举报与屏蔽 | 胶囊服务、授权治理人员 | 举报默认保留 365 天；屏蔽关系随账户存续 | 限制访问、留存处置依据，账户删除时按政策处理 |
| 审计事件 | 胶囊服务、授权运维 | 默认保留 90 天 | 核对自动清理、最小权限和外部日志期限 |
| 用户主动上传的状态包 | 胶囊服务、授权运维 | `diagnostics_reports`，与用户/房间关联，默认保留 30 天 | 核对清理任务和访问权限；账户删除时删除 |
| 头像 | 仅 iPhone 本地 | UserDefaults 中的压缩图片数据 | 退出或删除账户时清理；不计为 off-device collection |

生产还应确认客户端 IP 是否持久保存、能否与账号关联、保存多久，以及是否发送给云服务商或安全日志平台；若用 IP 推断位置，需要确保 Location 声明和隐私政策覆盖。

## 权限说明与用户控制

### 定位

- `When In Use`：用于向当前私人房间共享 iPhone 位置并计算成员相对距离/方位。
- `Always`：只在用户单独点击“开启口袋/锁屏共享”后请求，用于锁屏或放入口袋时继续共享。
- 用户控制：`我的 > iPhone 定位桥接 > 暂停共享`。
- 必须验证：暂停后服务端返回 `location_paused=true`，房间成员不再收到旧坐标。

### 通知

- 用户可拒绝，不影响登录、房间和基础雷达功能。
- 用途仅描述正式版本中真实提供的查看雷达提醒和房间邀请。
- APNs token 退出时解绑、失效时停用、账户删除时删除。

### 蓝牙

- 仅在用户进入设备流程并点击扫描时请求蓝牙权限。
- 用于扫描、绑定和配置用户本人的胶囊雷达，包括写入 Wi-Fi/服务器配置与执行固件 OTA。
- 不用于扫描联系人、识别附近人员或跨 App 跟踪。
- 用户拒绝后仍可使用登录、房间和 App 雷达功能，但设备扫描、绑定、配置与 OTA 不可用。

### PhotosPicker

- 使用系统选择器获取用户主动选择的单张头像，不申请完整照片库权限。
- 头像当前只保存在本机；若以后上传头像，必须更新隐私标签和政策。

Release 声明蓝牙权限，但仍不请求麦克风权限。

## 账户删除说明

App 内路径：

`我的 > 账号会话 > 永久删除账户 > 删除账户和全部数据`

当前删除范围应覆盖：

- 用户记录与业务会话；
- 用户拥有的房间和相关成员、邀请、提醒数据；
- 用户在其他房间的成员关系；
- APNs push subscription；
- 已绑定设备记录、device token 与本机设备凭证；
- 与账户关联的 `diagnostics_reports`；
- 用户举报、屏蔽及可关联的审计标识；
- 本机 Keychain 会话、用户名、头像和房间缓存；
- Sign in with Apple refresh token，并调用 Apple revoke endpoint。

提交前必须用真实生产 Apple 账号验证删除闭环：服务端撤销状态为 `revoked`，数据库、在线 WebSocket、APNs 订阅和本机缓存均无该账户；同一 Apple ID 再登录应表现为新账户。Apple 参考：[Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/) 与 [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)。

## 每次提交前的差异复核

1. 扫描新增 SDK、域名、系统权限、后台模式和第三方服务。
2. 对照生产数据库、日志平台、备份和清理任务，不只看 Swift 代码。
3. 抓包确认位置、token、提醒、举报和屏蔽的真实传输范围。
4. 打开最终 Archive 中的 `PrivacyInfo.xcprivacy`、`Info.plist` 和 entitlements。
5. 在 App Store Connect Product Page Preview 核对最终隐私标签。
6. 任一数据流或用途变化时，先更新问卷和政策，再发布对应版本。

## 当前 URL 门禁

- Privacy Policy URL 必须公开可访问，且 App 内同一入口可打开。
- Support URL 必须有真实联系信息和可响应渠道。
- 页面草案见 `docs/app-store-public-pages-draft.zh.md`；替换所有占位符并部署后才能填写 App Store Connect。
