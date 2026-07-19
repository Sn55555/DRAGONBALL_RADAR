# 胶囊 App Store 上架准备主清单

更新时间：2026-07-15

> 本文只覆盖 iOS App 上架。它基于当前仓库代码与配置整理，不能替代最终真机、TestFlight、生产环境和 App Store Connect 页面核验。凡是写有 `[[...]]` 的字段都禁止原样提交。

## 结论

当前版本**还不能提交审核**。开发者分发权限通过，只代表账号具备分发资格；当前仍有以下 P0 阻塞：

- Release 生产域名仍是占位值；
- 隐私政策与支持页尚无公开 HTTPS URL；
- Sign in with Apple 与 APNs 尚未完成生产配置和真机闭环；
- 尚未取得可用的分发签名与 App Store profile，未完成 Archive、Validate 和 TestFlight；
- 生产账户删除及 Apple token 撤销尚未验收；
- App Store 元数据、截图、隐私问卷和审核联系人尚未定稿。

本次上架的产品范围只有 iOS App：

- 使用 Sign in with Apple 创建和登录账号；
- 创建或加入私人房间；
- 由用户主动开启 iPhone 定位共享；
- 查看房间成员的相对方向、距离和在线状态；
- 向房间成员发送“查看雷达”提醒；
- 举报或屏蔽房间成员，并管理屏蔽列表；
- 在 App 内永久删除账户。

以上是“代码存在”的范围，不等于生产配置或审核验收已经完成。

## 状态标记

- `已具备代码`：仓库中存在实现，仍可能需要构建或生产验收。
- `待验收`：必须用签名 Release、TestFlight 和生产服务验证。
- `外部阻塞`：需要隼人提供账号资料、证书、域名或公开资料。
- `未实现`：提交前仍需修改产品或代码。

## P0 提交阻塞

| 项目 | 当前证据 | 状态 | 完成标准 |
| --- | --- | --- | --- |
| 原创品牌与视觉权利 | 面向用户的名称已改为原创品牌“胶囊/胶囊雷达”，App 图标和页面视觉已转为原创雷达表达 | 已具备代码/待最终归档复核 | 人工复核最终 App 图标、启动图、全部页面、截图和签名归档二进制；不得出现或暗示任何第三方角色、标志、道具图案或作品关系 |
| 生产 API 与 Relay | Release 仍指向 `relay.dragon-radar.example` 占位域名 | 外部阻塞 | 提供真实域名；部署有效 TLS；Release 包内只有真实 `https/wss` 地址；审核期间后端持续在线 |
| 隐私政策与支持页 | App 内已有政策/支持链接 UI，但 Release 的 URL setting 仍为空，仓库内草案也不是公开页面 | 已具备代码/外部阻塞 | 发布真实 HTTPS 页面并写入 Release setting；真机确认登录页和“我的”均可打开；App Store Connect 填入相同链接 |
| Sign in with Apple 生产闭环 | 已有 nonce、identity token 验证、授权码交换、refresh token 加密和撤销代码路径 | 待验收 | Apple Team、Key、Client 和 Bundle ID 配置正确；生产首次登录、恢复、刷新、退出、撤销凭证和删除账户均真机通过 |
| Distribution 签名能力 | project 使用 Automatic Signing，并声明 Push 与 Sign in with Apple；当前尚无可用 Apple Distribution 证书和 App Store profile | 待验收 | 当前 Mac 具备有效分发证书与包含 Push、Sign in with Apple 的 profile；Xcode 26+ 签名 Archive 成功并通过 Validate App |
| APNs 生产投递 | App 与 Relay 已有 push token 注册和提醒投递代码 | 待验收 | APNs key、topic 和 production environment 正确；TestFlight 前台、后台、杀进程三种“查看雷达”提醒通过；失效 token 能停用 |
| 审核可完整体验 | App 已有公开可见的本地审核体验，可操作成员方向、距离与目标切换；真实登录、房间、位置上传、提醒和账户删除仍需生产链路 | 已具备部分体验/待验收 | 准备稳定审核房间、第二测试成员和明确步骤；审核员能独立完成所有核心路径；本地体验只作为方向/距离展示的辅助，不替代真实生产验收 |
| 用户生成内容治理 | App 已提供举报、屏蔽、案件号回执、社区规则入口和屏蔽列表；Relay 已有过滤、限流、举报记录及屏蔽隔离路径 | 已具备代码/待生产与运营验收 | 配置强 moderation HMAC key 与阻断词；TestFlight 验证举报、屏蔽、解除屏蔽和共同房间处理；发布社区规则、滥用联系渠道、处置时限和申诉流程 |
| 账户删除生产验收 | App 入口和服务端删除事务已存在 | 待验收 | TestFlight 删除真实 Apple 登录账户；用户、会话、房间、成员关系、推送订阅和可关联审计数据均删除；Apple token 撤销成功；重新登录成为新账户状态 |
| 数据留存制度 | Relay 已实现审计、提醒和举报记录自动清理 | 已具备代码/待生产验收 | 生产核对实际期限、健康检查和过期数据清理；补齐 HTTP、反代日志与备份期限；隐私政策必须与生产实况一致 |
| 中国大陆发行 | 尚未决定首发是否包含中国大陆 | 外部阻塞 | 明确首发地区；如没有匹配主体与所需合规资料，首版先排除中国大陆 |
| App Store 元数据 | 品牌名已定为“胶囊”；版权主体、联系资料、URL、截图和审核资料仍未定稿 | 外部阻塞 | 本文所有 `[[...]]` 已替换，内容权利、年龄分级、隐私问卷完成并复核 |
| Release/TestFlight 验收 | 无签名 Release 编译成功不能证明可上传或生产可用 | 待验收 | Xcode 26+ 归档上传；TestFlight 真机回归通过；登录、房间、定位、提醒、举报/屏蔽、断网、拒绝权限和账户删除均有记录 |

Apple 当前要求上传包使用 Xcode 26 或更高版本和 iOS 26 SDK；年龄分级也已切换到新版问卷。参考：[Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/) 和 [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)。

App Store Connect 还要求如实处理 Content Rights、Privacy Policy URL 和中国大陆合规字段，参考：[App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)。

### 品牌与 Content Rights 口径

“胶囊”是本项目采用的原创品牌及产品命名。产品不声称、暗示或依附任何第三方影视、漫画、动画、游戏或角色 IP，也不使用第三方角色、标志、作品名称或版权美术。完成最终归档和截图的人工视觉复核后，App Store Connect 的 Content Rights 应按实际情况选择“不包含第三方内容”，审核备注不提交不存在的授权文件。

仓库中的 `DragonRadarMVP`、`DRAGON_RADAR_*` 和 `dragon-radar` 仅是既有 Bundle ID、源码路径、环境变量及协议的内部技术标识。它们不是用户可见品牌，不应出现在 App 名称、页面文案、截图或营销材料中。

## 安全发布门禁

### 服务端与密钥

生产环境必须逐项确认：

- `DRAGON_RADAR_ALLOW_DEVELOPMENT_AUTH` 未设置或为关闭。
- `DRAGON_RADAR_ALLOW_LEGACY_QUERY_AUTH` 未设置或为关闭。
- 配置强随机 `DRAGON_RADAR_DATA_ENCRYPTION_KEY`，Apple refresh token 不能明文落库。
- 配置 `DRAGON_RADAR_APPLE_TEAM_ID`、`DRAGON_RADAR_APPLE_SIGNIN_KEY_ID`、私钥路径和最终 Client ID/Bundle ID audience。
- APNs 使用 production topic，`DRAGON_RADAR_APNS_MODE` 不能停留在 `disabled` 或 `dry_run`。
- 配置真实 `DRAGON_RADAR_PUBLIC_RELAY_URL`，不能接受客户端任意指定外部 Relay。
- 配置至少 32 字节的 `DRAGON_RADAR_MODERATION_HMAC_KEY` 和生产阻断词；`/healthz` 中 moderation 必须为 production-ready。
- Relay 进程使用专用低权限用户，数据库和密钥文件采用最小权限；原始服务端口不暴露公网。
- 反向代理启用 TLS 1.2+、WebSocket upgrade、请求大小限制、连接/请求限流和安全响应头。
- 建立加密备份、恢复演练、密钥轮换、审计访问权限和安全事件响应联系人。
- HTTP、反代和系统日志不得记录 Authorization、refresh token、APNs token 或完整精确坐标。
- 明确并核对审计、提醒、举报、HTTP 日志和备份的实际保存期限。

### iOS App

- Release Archive 内不得存在测试 IP、`.example` 域名、开发登录按钮和 development entitlement。
- access/refresh token 必须保存在 Keychain；UserDefaults 只能保存非秘密设置。
- WebSocket token 只能放在 `Authorization` header，不能进入 URL、query、日志或错误提示。
- Sign in with Apple 必须使用随机 nonce，并由服务端验证后建立业务会话。
- 精确定位共享必须由用户明确开启；后台“始终允许”需要单独说明；暂停后同房间其他成员不得继续收到旧坐标。
- 房间邀请码必须具备足够随机性、有效期或撤销能力，并受请求频率限制。
- 屏蔽后双方不得继续通过提醒或房间事件互动；举报记录不得暴露举报人身份。
- App 不得声明为应急救援、人身安全监控或转向导航工具。

### 出口合规

当前 Release `Info.plist` 设置 `ITSAppUsesNonExemptEncryption = false`。这只是开发者声明，不等于自动完成法律判断。上传前须按最终二进制和自实现密码学重新回答 App Store Connect 问卷。参考：[Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)。

## App Review 准备

Apple 要求账号型 App 提供可完整操作的审核路径，且后端应在审核期间持续在线。参考：[App Review Guidelines 2.1](https://developer.apple.com/app-store/review/guidelines/) 和 [App Review](https://developer.apple.com/app-store/review/)。

### 审核环境

- 准备一个稳定的审核房间 `[[REVIEW_ROOM_CODE]]`。
- 安排一个持续在线的第二测试成员，使审核员能看到相对方向、距离和提醒结果。
- 审核期间保持生产 API、Relay 和 APNs 可用。
- 提供审核联系人、时间窗口和不含秘密的复现步骤。
- 可附 60–90 秒演示视频，但视频不能代替可操作审核路径。

### 审核员操作步骤

1. 安装审核 build，使用 Sign in with Apple 登录。
2. 进入“房间”，加入 `[[REVIEW_ROOM_CODE]]`，确认第二成员在线。
3. 进入“我的 > iPhone 定位桥接”，主动开启前台定位；后台/锁屏共享为单独可选项。
4. 进入“雷达”，观察房间成员的距离、相对方向、定位更新时间和在线状态。
5. 点击雷达目标或成员列表，打开成员详情查看定位精度和更新时间。
6. 进入“房间”，点击“提醒查看雷达”；第二测试成员应收到 App 内事件或系统通知。
7. 在成员菜单中测试“举报成员”“屏蔽成员”，再到“我的 > 安全与社区”查看案件号和屏蔽列表。
8. 进入“我的 > 账号会话 > 永久删除账户”，验证确认与完成提示。该步骤会销毁审核账户，建议最后执行。

### 本地雷达演示的定位

当前 App 的“房间”空状态提供“本地雷达演示”入口，可用本地演示数据查看多个成员的方向、距离、成员详情和目标切换。它不上传真实位置、不访问服务器，也不会发送真实提醒。

- 审核备注必须明确它只辅助展示雷达交互。
- Sign in with Apple、真实房间、定位共享、APNs、举报/屏蔽和账户删除必须在生产审核路径中可操作。
- 不得把本地演示结果写成生产链路已验收。

## 可复制的 App Review Notes（英文模板）

> 替换全部 `[[...]]` 后再提交。

```text
Capsule is an iPhone app for invited members of a private room. Members can choose to share their iPhone location, view each other's relative distance and bearing, send a “View Radar” reminder, report or block another member, and permanently delete their account.

Build: 1.0 (1)
Backend review window: [[START DATE/TIME, TIME ZONE]] through [[END DATE/TIME, TIME ZONE]]
Production API: [[HTTPS API URL]]
Production Relay: [[WSS RELAY URL]]
Review contact: [[FULL NAME]], [[PHONE]], [[EMAIL]]
Review room code: [[ROOM CODE]]

SIGN-IN
The app uses Sign in with Apple as its only production sign-in method. Please use an Apple review account to create a test account. No purchase or subscription is required.

CORE REVIEW STEPS
1. Sign in with Apple.
2. Open Rooms and join [[ROOM CODE]]. A second review member remains online during the review window.
3. Open Me > iPhone Location Bridge and tap Start Sharing. Background/lock-screen sharing is requested separately and is not required for basic use.
4. Open Radar to view the other room member's relative distance, bearing, location age, and online state.
5. Open Rooms and tap View Radar Reminder. The recipient receives an in-app event while online and an APNs alert while the app is in the background.
6. Open a member's menu to report or block the member. Reports return a reference number; blocked members are listed under Me > Safety & Community.
7. Account deletion is at Me > Account Session > Permanently Delete Account. It deletes account-linked rooms, memberships, push subscriptions, sessions, and associated data, and revokes the Sign in with Apple token.

OPTIONAL LOCAL RADAR PREVIEW
Rooms > Local Radar Demo shows local sample members so the radar interaction can be inspected without sharing real location. This preview is auxiliary and does not replace the production review steps above.

PRIVACY AND SAFETY
Location sharing is off by default and can be paused at any time. Precise location is shared only with members of the active private room. The feature is not intended for emergency response, rescue, turn-by-turn navigation, or safety-critical use.
Notifications are optional. The app has no advertising, tracking, in-app purchases, or subscriptions.

PRIVACY POLICY: [[URL]]
SUPPORT: [[URL]]
DEMO VIDEO: [[URL, OPTIONAL]]
CONTENT RIGHTS: Capsule is our original brand and visual identity. The app does not contain, claim, or imply any third-party character, logo, artwork, or franchise content.
```

## 元数据字段草案

| 字段 | 草案 | 提交前动作 |
| --- | --- | --- |
| App Name | `胶囊` | 复核同名冲突和商标可用性 |
| Subtitle | `私人房间方位雷达` | 最多 30 字符，最终以 App Store Connect 校验为准 |
| Bundle ID | 当前 `com.sn5.DragonRadarMVP` | 首次上传前确认是否接受永久保留带 `MVP` 的标识 |
| SKU | `[[例如 CAPSULE-IOS-001]]` | 创建 App Record 前固定，之后不可改 |
| Primary Language | `Simplified Chinese` | 如首发含英语市场，同时准备完整英文元数据 |
| Primary Category | `Utilities` | 避免选择 Navigation 后产生安全导航预期 |
| Secondary Category | `Lifestyle` 或留空 | 根据最终市场定位决定 |
| Version | `1.0` | 与 Archive 一致 |
| Copyright | `© 2026 [[合法主体全称]]` | 必须与权利主体一致 |
| Privacy Policy URL | `https://[[DOMAIN]]/privacy` | 必填，公开可访问且 App 内同样可打开 |
| Support URL | `https://[[DOMAIN]]/support` | 必填，必须显示真实联系渠道 |
| Marketing URL | `https://[[DOMAIN]]` | 可选，不能是空站或占位页 |
| Review contact | `[[姓名/电话/邮箱]]` | 审核期间可及时接听或回复 |
| Content Rights | `No third-party content` | 仅在最终归档和截图完成视觉复核后选择 |
| Price | `Free`（当前无 IAP） | 若后续收费需重新评估 App Store 支付规则 |
| Availability | `[[国家/地区列表]]` | 中国大陆单独决策 |

### Promotional Text 草案

```text
在私人房间中共享 iPhone 位置，查看成员相对方向与距离，并一键提醒成员查看雷达。
```

### Description 草案

```text
胶囊是一款面向私人房间成员的 iPhone 方位雷达 App。

你可以：
• 使用 Sign in with Apple 安全登录
• 创建或加入私人房间
• 在主动授权后，与当前房间成员共享 iPhone 位置
• 查看成员的相对距离、方向、定位更新时间和在线状态
• 一键提醒房间成员查看雷达
• 举报或屏蔽成员，并管理屏蔽列表
• 随时暂停定位共享，或在 App 内永久删除账户

隐私控制
定位共享默认关闭，仅在你主动开启后发送给当前私人房间成员。后台/锁屏共享需要单独开启。通知是可选的，App 不包含广告或跨 App 跟踪。

使用说明
距离和方向依赖 GPS 精度、手机姿态和网络状态，仅用于私人房间成员间的协同与娱乐体验，不用于应急救援、人员安全监控或转向导航。
```

### Keywords 草案

```text
雷达,方位,方向,距离,定位,位置共享,私人房间,成员,提醒,屏蔽
```

### 首版截图顺序

App 当前只面向 iPhone。至少上传 1 张、最多 10 张；优先提供最高分辨率的 6.9 英寸 iPhone 竖屏截图。官方尺寸见：[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)。

建议提交 6 张真实运行截图：

1. 雷达主页：两名成员、距离、相对方向和在线状态。
2. 成员详情：定位精度、更新时间与目标切换。
3. 房间页：成员列表和“提醒查看雷达”。
4. iPhone 定位共享：前台开关、暂停状态及后台共享的单独入口。
5. 安全与社区：举报入口、屏蔽确认和屏蔽列表。
6. 账号与隐私：权限说明、政策链接和永久删除账户入口。

截图必须来自提交 build，不能只放启动图或登录页；截图中的房间名、成员名和位置数据必须使用专门测试数据。

## 年龄分级答题预案

不要提前填写固定年龄，以 App Store Connect 计算结果为准。当前能力应按真实情况回答：

- Made for Kids：否。产品包含精确定位共享和用户命名内容，当前没有儿童产品所需的年龄或家长控制体系。
- User-Generated Content：是或按问卷对应能力勾选。房间名和显示名由用户生成。
- Messaging/Chat/Social capability：按问卷最新定义谨慎选择“有”。产品有私人房间、成员提醒、举报和屏蔽能力。
- Unrestricted Web Access：无。
- Advertising：无。
- Gambling、Loot Boxes、Contests、Sexual Content、Drug/Alcohol、Horror、Violence：开发者内容均无；仍需完成生产 UGC 治理后再提交。
- Parental Controls、Age Assurance：当前无，不要误选。

自 2026-07-09 起 App Store Connect 已加入社交媒体能力相关问题；提交当天应再次打开问卷核对。参考：[Age rating questionnaire now includes social media questions](https://developer.apple.com/news/?id=tlur8uvi)。

## 隐私与账户材料

- 隐私标签答题映射：见 `docs/app-store-privacy-labels.zh.md`，提交前还须复核该文件是否与 App-only 范围一致。
- 可发布页面文案草案：见 `docs/app-store-public-pages-draft.zh.md`。
- Apple 要求 iOS App 在 App Store Connect 填写隐私政策 URL，且 Guideline 5.1.1 要求 App 内也有易访问的隐私政策链接。
- 有账号创建能力的 App 必须允许用户在 App 内发起完整账户删除；Sign in with Apple 还应通过 REST API 撤销 token。参考：[Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/) 和 [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)。

## 最终提交顺序

1. 完成原创品牌、最终图标、页面视觉和 Bundle ID 复核。
2. 提供真实域名、合法主体、隐私邮箱、支持邮箱/电话和首发地区。
3. 发布隐私政策、隐私选择、支持页和社区规则 HTTPS 页面。
4. 部署生产 HTTPS/WSS、Sign in with Apple、APNs、UGC 治理和数据清理策略。
5. 创建或更新 Identifier、分发证书和 App Store profile，确认 Push 与 Sign in with Apple。
6. 用 Xcode 26+ 完成签名 Archive、Validate 和 TestFlight 上传。
7. 在至少两台 iPhone 上完成登录、私人房间、位置共享、方向/距离、提醒、举报/屏蔽和删除账户回归。
8. 完成 App Privacy、年龄分级、出口合规、Content Rights 和地区合规。
9. 上传截图、元数据、审核步骤和可选演示视频。
10. 先做 TestFlight 外部测试，再提交 App Review，并选择合适的发布方式。

## 需要隼人提供的输入

1. 生产域名及 DNS 控制权。
2. 开发者/版权合法主体全称。
3. 对外隐私邮箱、支持邮箱、审核联系电话和负责人姓名。
4. 首发是否包含中国大陆；若包含，提供匹配主体所需的合规资料。
5. 云服务商、服务器所在国家/地区，以及 HTTP/反代日志和备份的目标留存期限。
6. 目标用户最低年龄及是否明确排除未成年人。
7. App Store Connect 使用的 Apple Team、APNs key 和 Sign in with Apple 配置资料。

## 本次仓库核对入口

- 构建、Bundle ID、iPhone 目标和 Release URL：`ios/DragonRadarMVP/project.yml`
- 隐私/条款/支持 URL 解析与链接 UI：`ios/DragonRadarMVP/DragonRadarMVP/Sources/AppEnvironment.swift`、`ios/DragonRadarMVP/DragonRadarMVP/Sources/AppShellView.swift`
- 权限文案和出口合规：`ios/DragonRadarMVP/DragonRadarMVP/Info.plist`
- Push / Sign in with Apple entitlement：`ios/DragonRadarMVP/DragonRadarMVP/DragonRadarMVP.entitlements`
- 隐私清单：`ios/DragonRadarMVP/DragonRadarMVP/PrivacyInfo.xcprivacy`
- Apple 登录、Keychain、删除请求：`ios/DragonRadarMVP/DragonRadarMVP/Sources/AuthSupport.swift`
- App 内账户删除和隐私权限 UI：`ios/DragonRadarMVP/DragonRadarMVP/Sources/AccountView.swift`
- 定位主动开启与后台权限：`ios/DragonRadarMVP/DragonRadarMVP/Sources/LocationBridge.swift`
- 房间、提醒、举报和屏蔽 UI：`ios/DragonRadarMVP/DragonRadarMVP/Sources/RoomsView.swift`
- APNs token 与提醒展示：`ios/DragonRadarMVP/DragonRadarMVP/Sources/NotificationPermissionCenter.swift`
- 服务端账号、房间、提醒、APNs、举报/屏蔽和删除事务：`relay/server.py`
