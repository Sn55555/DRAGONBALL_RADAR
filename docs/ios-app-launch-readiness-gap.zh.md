# iOS App 未实现部分与上线实施拆分

更新时间：2026-06-11

> 本文保留为 2026-06-11 的工程推进记录。2026-07-15 之后的 App Store 提交状态、审核阻塞和可复制材料，以 `docs/app-store-submission-preparation.zh.md` 为准。

## 当前推进进度

截至 2026-06-11，本轮已落地并通过 `tools/verify_project.sh full` 的内容：

- 账号与会话：App 已有 `AuthSession`、Keychain 持久化、开发登录、Sign in with Apple 入口、token 刷新、Relay App WebSocket token 校验；登录入口已有 loading/success/failed 三态；Relay 已通过 Apple JWKS + RS256 校验 identity token 的签名、`iss`、`aud`、`exp`、`sub`；未登录不能创建/加入房间。
- 房间 API：Relay 已有 SQLite 持久化房间、成员、邀请和房间上限；App 房间列表、创建、加入、重命名已接服务端。
- 设备注册：Relay 已有 `POST /v1/devices/register-challenge`、`GET /v1/devices`、`DELETE /v1/devices/{device_id}`；App 绑定时使用服务端返回的 `pairing_response` 和 `device_token` 写入 ESP；绑定提交已有准备、注册中、成功、失败状态和 BLE/登录缺失提示。
- 设备安全：未登录不能注册设备；同一 `pairing_challenge` 被其他账号重复注册会返回 `device_already_bound`；解绑后旧 `device_token` 连接 Device WebSocket 会被拒绝；`pairing_response` 已升级为 `dra-pair:v2:<device_id>:<nonce>:<hmac_sha256>`，ESP 用当前 challenge 和共享配对密钥验 HMAC 后才置为 paired。
- 定位确认：`app_location` 带 `sequence`，Relay 返回 `app_location_ack`，`room_state.location.sequence` 回显服务端接受的最新定位。
- 定位隐私：App “我的 > 定位桥接”暂停共享后会向 Relay 发送 `location_paused`；Relay `room_state` 对该成员返回 `location_paused=true` 且不再暴露坐标；再次上传 `app_location` 后恢复 `location_paused=false`；房间成员、诊断包和 smoke 验收均已接入。
- 定位过期：Relay `room_state` 已增加 `location_stale` 和 `location_age_ms`，默认 30 秒未刷新即标记过期；App 成员模型会显示“定位已过期/过期”，避免把旧坐标当实时距离；smoke 用 1 秒阈值验证过期状态。
- 切房同步：`room_switch` 带 `request_id`，Relay ack 原样回传，App 增加切房状态机并在“准备 > 当前链路”显示 ESP 同步状态；Relay 不再让 `heartbeat` / `room_switch` 清空最近定位。
- 生产连接配置：App 已新增 Debug/Release 环境分离；Debug 可继续使用 `139.224.41.192` 测试服务器，Release build setting 只允许 `https://` HTTP API 和 `wss://` Relay；Release `Info.plist` 已移除 `NSAllowsArbitraryLoads`。
- Relay 审计：Relay 已新增 `audit_events` 持久化表和受 token 保护的 `GET /v1/audit/events`；可记录设备注册/解绑、房间创建/加入/邀请/改名/移除/解散、WebSocket 连接/断线、切房、房间满员和抢麦冲突。
- 错误合同：撤销后的 ESP `device_token` 连接 Device WebSocket 会返回稳定错误码 `device_revoked`，App 统一文案提示重新绑定，不再与普通 `unauthorized` 混淆；smoke 已覆盖该合同。
- 诊断包：App 设备页诊断区已支持一键复制 JSON 和登录后上传；上传流程已有 loading/success/failed 三态和未登录提示；诊断包包含 App/房间/Relay/定位/BLE/ESP/语音/room_state 摘要和最近事件，明确省略 token、Wi-Fi 密码和精确坐标历史；Relay 已有 `POST /v1/diagnostics` 持久化诊断报告并写入审计。
- 权限与隐私：App “我的”已增加“隐私与权限”二级页，展示定位上传对象、上传内容、关闭方式、蓝牙边界、通知用途、诊断数据范围和 App Store 隐私标签草案；通知权限已接 `UNUserNotificationCenter` 真实授权状态和请求入口。
- 定位可靠性：Release `Info.plist` 已启用 `UIBackgroundModes=location`；App 已区分“始终允许/使用期间/不可用”、精确定位/大致定位、后台定位能力、最近定位、最近上传和最近服务端确认；诊断包同步包含这些字段；退出登录会暂停定位共享、停止本机定位、停止语音观察并断开 Relay。
- App 去 Demo 化：无服务端房间时不再创建默认 `KAME-07` 房间；无服务端设备时不再显示默认 ESP；创建/加入房间失败不再本地伪造房间；没有房间时不启动 Relay；没有 device token 时不写空 `server_config`。
- 验证覆盖：Relay smoke 覆盖 auth、缺失 Apple token 拒绝、room API、device register/revoke、App/Device WS 鉴权、location ack、room switch ack、voice floor、抢麦冲突、诊断上传和审计查询；iOS 单元测试覆盖 `room_state` / `voice_floor` 解码、距离/方位投影、说话状态投影和 `room_full` 文案；iOS UI 测试覆盖未登录启动、无房间、无设备空状态、满员加入失败、服务端房间切换和定位权限拒绝；full 验证同时覆盖 ESP field 固件编译、iOS 单元/UI 测试、iOS Debug/Release no-sign 编译和 Release `https/wss` 门禁；已验证默认环境下 `identity_token=development` 会被拒绝，测试环境必须显式设置 `DRAGON_RADAR_ALLOW_DEVELOPMENT_AUTH=1`。

仍未完成的上线项：

- 生产配对密钥 preflight 已固定：`tools/prepare_release_pairing_key.sh` 会拒绝默认开发 key、短 key 和服务端/固件 key 不一致；`RADAR_RELEASE=1 tools/build_radar.sh field` 会强制检查 `PAIRING_HMAC_KEY`。真实生产密钥生成、保管和轮换仍需运营执行。
- 生产 `wss://` 真实域名和 TLS 终止仍未完成；App 侧发布环境切换、Release 门禁、Relay 结构化审计、HTTP/WS 限流、消息大小限制、健康检查配置、部署备份/健康检查/自动回滚脚本和三端协议版本兼容检查已完成。
- 定位后台 30 分钟矩阵、TestFlight 发布流程、生产 APNs 证书配置和真实远程推送投递验收仍未完成；App 内通知授权、APNs token 注册上传、Relay `dry_run/live` 投递骨架、房间邀请/设备离线/抢麦异常 dry-run smoke 和 App Store 隐私标签草案已完成。

## 依据

本文基于以下当前项目资料和代码状态整理：

- `docs/product-design.zh.md`
- `docs/remote-multi-radar-architecture.zh.md`
- `docs/ios-app-information-architecture.zh.md`
- `ios/DragonRadarMVP/DragonRadarMVP/Sources/*`
- `relay/server.py`
- `firmware/DragonRadar/DragonRadar.ino`

目标不是重新定义产品，而是把 iOS App 从当前 MVP 推到可上线版本。上线版本仍遵循现有产品方向：App 负责账号、房间、设备配置、定位桥接和状态管理；ESP 负责现场显示、麦克风采集和扬声器播放；Relay 是房间、定位和抢麦状态的权威来源。

## 当前已具备的 App 基础

- 已有 4 个主 Tab：`雷达`、`房间`、`设备`、`我的`。
- 已有黑白漫画风 UI、App Icon 和基础页面结构。
- 已有 CoreLocation 获取、过滤默认模拟定位、定位快照和 Relay 上传逻辑。
- 已有 App 启动、回到前台、周期心跳时自动维持 Relay 和上传定位的运行宿主。
- 已有 BLE 扫描、连接、协议特征发现和以下写入能力：`pairing_response`、`wifi_config`、`server_config`、`local_location`。
- 已有 Relay WebSocket 客户端，能连接 `/v1/radar/app/ws`，发送 `hello`、`app_location`、`heartbeat`、`room_switch`，并解析 `room_state`。
- 已有房间成员列表从 Relay `room_state` 回填，距离、方位、定位精度和语音活跃状态有基础展示。
- 已有房间创建、加入、切换、重命名的本地 UI 流程。
- 已有设备页、准备页、诊断页和“我的”里的定位桥接管理入口。

## 总体缺口判断

当前 App 是“可联调 MVP”，不是“可上线产品”。核心原因：

- 用户、设备、房间仍主要是本地 `DemoAppState`，没有真实账号体系和服务端持久化。
- Relay 已有生产鉴权、SQLite 持久化、审计日志、限流、健康检查和部署自动回滚脚本；仍缺生产 TLS 域名、横向扩展和真实云环境回滚演练。
- BLE 绑定是 MVP 响应，不是服务端签名的安全绑定。
- 房间创建/加入/邀请在 App 内有 UI，但没有真实 API 合同。
- 语音由 ESP 负责是正确方向，但 App 侧对抢麦权、当前说话者、busy 原因、上下行健康度的解析和呈现还不完整。
- 定位上传已具备链路，但缺后台可靠性、权限降级处理、服务端确认、隐私开关和故障可视化。
- 上线所需的错误处理、可观测性、测试矩阵、隐私合规和发布流程还未完成。

## P0 上线阻断项

### 1. 账号与会话

目标：

- App 必须有真实用户身份，后续设备绑定、房间归属、邀请、移除成员和隐私控制都依赖它。

当前差距：

- App 已有 Sign in with Apple 入口、Keychain 会话、token 刷新、Relay token 校验和 Apple identity token 服务端验签。
- 当前仍需真机/TestFlight 验收 Apple 登录，并确认生产服务配置 `DRAGON_RADAR_APPLE_AUDIENCE` 或 `DRAGON_RADAR_APPLE_AUDIENCES` 与最终 Bundle ID 一致。
- 开发登录只允许测试环境显式设置 `DRAGON_RADAR_ALLOW_DEVELOPMENT_AUTH=1`；生产默认拒绝 `identity_token=development`。

实施步骤：

1. 新增 `AuthSession` 模型：`userID`、`displayName`、`appleUserID`、`accessToken`、`refreshToken`、`expiresAt`。
2. 接入 Sign in with Apple，登录成功后调用服务端 `POST /v1/auth/apple` 换取业务 token。已完成。
3. token 存入 Keychain，不放 UserDefaults。已完成。
4. App 启动时先恢复 Keychain 会话，过期时刷新 token。已完成。
5. Relay WebSocket 连接增加 `Authorization: Bearer <token>` 或等价 query token。已完成。
6. 未登录时进入登录流程；已登录但无设备/无房间时进入对应引导页。已完成基础分流，待 TestFlight 验收。
7. 增加退出登录：清理本机 session、断开 Relay、停止定位上传，但不自动解绑 ESP。已完成。
8. 服务端校验 Apple identity token：拉取 Apple `https://appleid.apple.com/auth/keys`，用 `kid` 选择 RSA 公钥，验证 RS256 签名，并校验 `iss=https://appleid.apple.com`、`aud`、`exp` 和 `sub`。已完成。

验收标准：

- 首次安装必须登录后才能创建/加入房间。
- 关闭 App 后再次打开能恢复登录态。
- token 过期后能刷新；刷新失败时回到登录页。
- Relay 拒绝无 token 或无效 token 的连接。
- Relay 拒绝缺失、伪造或 `sub` 不匹配的 Apple identity token；本地 development token 不在生产默认放行。

### 2. 服务端房间 API 与 App 房间数据真实化

目标：

- 房间列表、创建、加入、邀请、重命名、成员上限和成员身份都由服务端管理。

当前差距：

- `RoomsView` 的创建/加入/切换走本地 `DemoAppState`。
- Relay 当前只根据 WebSocket query 里的 `room` 创建内存房间。
- 房间空了就从内存删除，没有持久化。
- 没有房主、成员角色、邀请码有效期、邀请链接、移出成员、解散房间。

实施步骤：

1. 定义 HTTP API：
   - `GET /v1/rooms`
   - `POST /v1/rooms`
   - `GET /v1/rooms/{room_id}`
   - `POST /v1/rooms/join`
   - `PATCH /v1/rooms/{room_id}`
   - `POST /v1/rooms/{room_id}/invite`
   - `DELETE /v1/rooms/{room_id}/members/{member_id}`
   - `DELETE /v1/rooms/{room_id}`
2. 服务端新增持久化表：
   - `users`
   - `devices`
   - `rooms`
   - `room_members`
   - `room_invites`
3. App 新增 `RoomsRepository`，替换 `DemoAppState.createRoom/joinRoom/switchRoom` 的本地逻辑。
4. 房间列表只显示服务端返回的房间。
5. 创建房间成功后使用服务端返回的 `room_id`、`room_code`、`role`。
6. 加入房间前先预览房间名、当前人数、是否满员。
7. 切换房间时先更新 App active room，再同步 ESP 的 `server_config` 或云端 `room_switch`。
8. 第 8 名成员加入时，App 显示服务端明确错误 `room_full`。

验收标准：

- App 重装后登录同一账号仍能看到之前的房间。
- 房间名修改后另一台 App 能看到更新。
- 满 7 组后第 8 组加入失败，错误文案明确。
- 切房后 ESP 自动进入同一房间，不依赖重新 BLE 配网。

### 3. 设备绑定与注册安全

目标：

- ESP 绑定必须可追溯、可撤销、不可被任意 App 冒充。

当前差距：

- `pairing_response` 已不再是 `mvp-response:<challenge>`；服务端签发 v2 HMAC 响应，ESP 验证当前 challenge、device_id、nonce 和 HMAC 后才确认 paired。
- `device_token` 已由服务端签发并可撤销。
- `wifi_config` 明文 JSON 写入 BLE；上线前至少需要明确安全边界和短连接暴露策略。
- 设备列表已接服务端；App、Relay 和 ESP 已实现两阶段安全释放，仍需真机验证多账号恢复及释放后重新绑定。
- 当前 v2 使用共享 HMAC key，不是每台设备独立公私钥；发布 preflight 已防止默认开发 key 和服务端/固件 key 不一致，泄露后的轮换流程仍需运营文档和真机演练。

实施步骤：

1. ESP 生成一次性 `pairing_challenge`，包含 `device_short_id`、随机 nonce、时间戳。
2. App 读取 challenge 后调用 `POST /v1/devices/register-challenge`。
3. 服务端校验用户身份，返回签名后的 `pairing_response`、`device_id`、`device_token`。已完成，签名合同为 v2 HMAC-SHA256。
4. App 写入 `pairing_response`，等待 ESP `device_status.paired = 1`。已完成基础链路和绑定页三态反馈；ESP 无效响应不会置 paired。
5. App 写入 `server_config`，内容使用服务端签发的 `device_token`。已完成。
6. 服务端保存用户和设备绑定关系。已完成。
7. App 设备列表改为 `GET /v1/devices`。已完成。
8. 增加释放设备闭环：App 先通过所有者 BLE 会话执行
   `prepare_release`，再由服务端撤销 device token，最后发送
   `commit_release`；ESP 确认后清除所有者、Wi-Fi、房间配置和 BLE 绑定并重启。
   服务端失败时发送 `cancel_release`，不改变 ESP 的物理绑定。代码、固件构建和
   iOS 状态机单测已完成，待两台真机执行释放后重新绑定验收。
9. BLE 配网写入前要求设备处于未绑定或当前用户已绑定状态。
10. 发布构建时设置生产密钥：Relay 使用 `DRAGON_RADAR_PAIRING_HMAC_KEY`，固件构建使用 `PAIRING_HMAC_KEY=... RADAR_RELEASE=1 tools/build_radar.sh field`。已完成 preflight。
11. 使用 `tools/prepare_release_pairing_key.sh check` 验证当前环境；使用 `tools/prepare_release_pairing_key.sh write-env output/release-current/secrets` 生成 `relay.env`、`firmware.env` 和不含 secret 的 fingerprint manifest。已完成并纳入 `tools/verify_project.sh quick/full`。

验收标准：

- 未登录用户不能绑定设备。
- 已绑定到其他用户的设备不能被直接覆盖绑定。
- 解绑后 ESP 使用旧 token 连接 Relay 会被拒绝。
- 非当前所有者或未完成 BLE 所有者授权时，ESP 拒绝释放命令。
- 云端撤销失败时 ESP 保持原绑定；云端成功且 ESP 确认提交后，App 才清理本地凭证。
- App 重装后能从服务端恢复已绑定设备。
- ESP 收到伪造或与当前 challenge 不匹配的 `pairing_response` 不会置为 paired。代码已实现并通过固件构建，待真机 BLE 负向验收。
- 发布构建不能使用默认开发配对 key；服务端和固件 key 不一致会在 preflight 阶段失败。已由 `tools/prepare_release_pairing_key.sh self-test` 验证。

### 4. 生产 Relay 与 WSS 安全连接

目标：

- App 上线不能使用裸 `ws://139.224.41.192:8787` 作为最终形态，必须迁移到生产域名、TLS、鉴权和可观测部署。

当前差距：

- Release 环境已强制使用 `https://` 和 `wss://` 配置，Debug 仍可使用测试服务器。
- Relay 已有 App token、device token、SQLite 房间/设备持久化、审计日志、HTTP body 上限、HTTP fixed-window 限流、WS 单消息大小限制、WS 每连接消息频率限制和 WS idle timeout。
- Relay `/healthz` 已返回房间数、连接数和当前限制配置，可用于部署健康检查。
- `tools/deploy_relay_update.sh` 已支持部署前备份、部署后 `/healthz` 检查、失败自动恢复备份，以及手动 `rollback` 指定备份。
- 仍缺真实生产域名、TLS 终止、云侧限流/WAF、进程级横向扩展和正式云环境回滚演练。

实施步骤：

1. 申请生产域名，例如 `relay.dragon-radar.example`。
2. 使用 Nginx/Caddy/云负载均衡终止 TLS，Relay 对外只暴露 `wss://`。
3. Relay 增加 token 验证：App token 和 device token 分开校验。已完成。
4. Relay 使用数据库或 Redis 维护房间成员和连接状态。SQLite 持久化已完成，横向扩展仍需 Redis/Postgres 或连接状态外置。
5. 增加连接限流、消息大小限制、心跳超时、异常关闭码。已完成基础实现：`DRAGON_RADAR_HTTP_MAX_BODY_BYTES`、`DRAGON_RADAR_HTTP_RATE_LIMIT_PER_MINUTE`、`DRAGON_RADAR_WS_MAX_MESSAGE_BYTES`、`DRAGON_RADAR_WS_MESSAGE_RATE_LIMIT_PER_SECOND`、`DRAGON_RADAR_WS_IDLE_TIMEOUT_SECONDS`。
6. App 新增环境配置：`Debug`、`Staging`、`Production`。已完成。
7. `relayBaseURL` 从配置读取，不写死在业务类。已完成。
8. 增加 Relay 健康检查接口和部署脚本回滚策略。健康检查已完成并返回 limits；部署脚本已支持备份、`/healthz` 检查、失败自动回滚和手动 rollback；仍需云环境演练。

验收标准：

- App Store/真机 Release 包只连接 `wss://` 生产或 staging 域名。
- 无 token 连接会被拒绝。
- Relay 超大 HTTP 请求返回 `request_too_large`，WS 超大消息、过快消息和 idle timeout 有明确关闭路径。HTTP body 上限与 limits smoke 已验证。
- Relay 重启后已登录用户能重新连接并恢复房间状态。协议和持久化已具备，仍需部署环境重启演练。
- 服务端能查到每次连接、断线、房间加入、房间满员、抢麦冲突的日志。基础审计已完成。

### 5. 定位桥接的上线级可靠性

目标：

- 打开 App 后自动上传定位，后台或锁屏时按 iOS 能力边界尽量持续；失败时用户能看懂原因。

当前差距：

- CoreLocation 和自动上传已经存在，但缺少后台模式完整验证。
- 服务端 ack/序列号已经接入并由 smoke 覆盖；仍需在真机后台和弱网下验收。
- Reduced Accuracy、权限关闭、定位长时间不更新、后台能力等状态已有清晰 UI、诊断字段和 Relay stale 标记；后台挂起仍需真机长测验证。
- `local_location` 写给 ESP 仍依赖 BLE 连接；现在 ESP 主要应通过 Relay room_state 获得本机 App 位置，BLE 只是注册配置阶段补充。

实施步骤：

1. 在 Xcode Capabilities 中确认 Location background mode 是否启用，并记录原因。已完成，Release `Info.plist` 包含 `UIBackgroundModes=location`。
2. `LocationSnapshot` 增加 `sequence` 和 `source`，上传时带序号。已完成基础序列号。
3. Relay 对 `app_location` 返回 ack 或在 `room_state` 中回显最新 `sequence`。已完成并由 `tools/verify_project.sh quick/full` 验证。
4. App 显示最近上传时间、最近服务端确认时间、定位精度、是否 Reduced Accuracy。已完成 App UI 和诊断字段，仍需真机权限弹窗复核。
5. 定位权限页增加“精确定位未开启”的明确提示。已完成，大致定位会显示为“精确定位未开启/大致定位”。
6. App 前台、后台、锁屏、蜂窝网络、Wi-Fi 切换各做 30 分钟稳定性测试。
7. 当 BLE 未连接时，不阻塞定位上传；当 ESP 在线时由 Relay 下发本机定位。
8. 只有用户关闭定位共享或退出登录时停止上传。已完成退出登录停止定位、暂停 Relay 共享和断开 Relay。

验收标准：

- 打开 App 后无需手动点击即可进入房间并上传定位。
- 手机移动后 2 秒到 10 秒内，Relay `room_state` 能看到最新位置。协议层已验证，仍需真机移动测试。
- ESP 重启后能通过 Relay 恢复本机定位和远端定位。
- 权限关闭、低精度、定位过期、无网络时 App 明确显示原因。权限关闭、低精度和 stale 旧坐标 UI 已完成；无网络由 Relay 失败状态显示，仍需真机弱网复核。

### 6. 房间切换与 ESP 同步闭环

目标：

- App 切房后，本机 ESP 必须自动进入同一房间，且用户能看到同步是否完成。

当前差距：

- App 会发送 `room_switch`，Relay 有 pending room switch；但 App 侧没有完整确认状态机。
- BLE 写 `server_config` 失败后只有 pending 文案，没有持续重试策略。
- ESP 是否已经切到目标房间，需要从 `device_status` 或 `room_state` 做明确回填。

实施步骤：

1. App 增加 `RoomSwitchState`：`idle`、`appSwitching`、`notifyingESP`、`waitingESPJoin`、`synced`、`failed`。
2. Relay 的 `room_switch_ack` 增加 `request_id`，App 用它关联一次切房操作。
3. ESP 进入新房间后在 `device_status` 或 `hello` 中带 `room_token`。
4. App 只有看到本机 group 的 ESP 出现在目标 room_state 后，才显示“ESP 已同步”。
5. BLE 可用时写 `server_config`；BLE 不可用但 ESP 已在线时走 Relay `room_switch`。
6. 两条路径都失败时，给出可操作错误：连接 BLE、检查 Wi-Fi、检查 Relay。

验收标准：

- 切换房间后，不重启 ESP，也不重新配网，ESP 自动跟随。
- App 能明确显示“App 已切房 / ESP 同步中 / ESP 已同步”。
- Relay 断开后恢复，ESP 仍能回到最后选中的房间。

## P1 上线体验项

### 7. App 状态模型去 Demo 化

目标：

- 消除本地 demo 数据对真实状态的干扰。

当前差距：

- `DemoAppState` 已拆成 `SessionStore`、`RoomsStore`、`DevicesStore`、`DiagnosticsStore` 和 repository；README 已更新当前真实能力。
- 默认房间、默认设备、测试输入默认值和服务端失败后的本地房间 fallback 已移除。
- 诊断初始项仍是本地状态摘要，但不再伪造通过；后续应继续把更多检查绑定到真实 BLE、Relay、定位和 ESP 状态。

实施步骤：

1. 将 `DemoAppState` 拆成真实状态容器：
   - `SessionStore`
   - `RoomsStore`
   - `DevicesStore`
   - `LocationStore`
   - `DiagnosticsStore`
2. 本地 demo 房间移入 Preview 或 Debug-only mock。
3. App 首屏根据真实 session/device/room 状态分流。已完成基础空状态：无房间不连 Relay，无设备不显示默认 ESP。
4. 房间列表、设备列表、诊断项全部来自真实 repository。房间和设备列表已接服务端权威数据；诊断项仍需继续增强真实检查粒度。
5. 更新 `ios/DragonRadarMVP/README.md`，说明当前真实能力和未完成项。已完成。

验收标准：

- Release 包不出现任何旧演示房间、第三方作品相关名称或默认测试码。源码扫描已清除默认测试房/测试码。
- 没有服务端数据时，App 显示空状态和创建/加入入口。已完成。
- 诊断页不再显示硬编码通过项。已完成基础处理，仍需真机故障场景验收。

### 8. 语音状态展示完整化

目标：

- App 不采集和播放语音，但必须清楚展示当前谁在说话、谁抢麦失败、ESP 语音链路是否健康。

当前差距：

- Relay 已有 `voice_floor` 和 `voice_status` 字段。
- App 已解析 `voice_floor`、`ptt`、`floor_granted`、`speaker`、`received_sequence`、`lost_frames`、`rms` 和 `peak`。
- `RoomMember.isSpeaking` 已优先使用 `voice_floor.speaker_group_id` / `speaker_peer_id`，再回退到 `speaker`、`floor_granted`、`ptt`、`vad` 和最后事件类型。
- App 已处理 Relay `voice_busy`，会在语音状态里显示抢麦失败和当前占用者；仍需真机 ESP 抢麦失败场景验收。
- 雷达页、房间成员槽位、成员详情和诊断包已展示当前语音状态、发言权剩余时间、上行/下行序号、丢帧、电平和 codec 摘要。

实施步骤：

1. `RelayRoomStateSnapshot` 增加解析 `voice_floor`。已完成。
2. `RelayVoiceStatusSnapshot` 增加字段：
   - `ptt`
   - `floorGranted`
   - `speaker`
   - `receivedSequence`
   - `lostFrames`
   - `rms`
   - `peak`
   已完成。
3. `RoomMember.isSpeaking` 以 `voice_floor.speaker_group_id` 为第一优先级。已完成。
4. 雷达页和房间详情显示当前说话者、抢麦倒计时、busy 状态。已完成 App 侧显示，仍需真机 ESP 抢麦验收。
5. 设备详情显示 ESP 麦克风在线、扬声器在线、上行帧序号、下行帧序号。App 已展示上行/下行序号和音频健康摘要；麦克风/扬声器在线仍需固件上报独立字段。

验收标准：

- 一台 ESP 按住 BOOT 说话时，另一台 App 能在 1 秒内显示说话者。
- 第二台 ESP 同时抢麦失败时，App 能显示 busy 原因。
- 松手后 App 能看到发言权释放。

### 9. 诊断包与现场排障

目标：

- 上线后用户和开发者能快速定位是 App、BLE、Wi-Fi、Relay、ESP 还是定位权限问题。

当前差距：

- App 侧复制/上传、Relay 持久化和审计已完成。
- 仍需要在真实 TestFlight 包和真实设备现场故障中验证用户复制内容、上传报告查询和隐私字段。

实施步骤：

1. 定义诊断包 JSON：
   - App 版本、build、环境
   - 登录状态，不包含 token
   - 当前 room_id/room_code
   - Relay URL 和连接状态
   - 最近 20 条 Relay 事件
   - 最近 20 条 BLE 事件
   - 最近定位时间、精度、上传序号
   - 当前 ESP device_status
   - 当前 room_state 摘要
2. 诊断页增加“复制诊断包”。已完成。
3. 服务端增加 `POST /v1/diagnostics`。已完成。
4. 错误状态统一归类：权限、网络、服务器、设备、房间、语音。已完成基础分类。
5. 现场验收时每个失败步骤必须能导出诊断包。待真实硬件和 TestFlight 验收。

验收标准：

- 用户截图之外，可以复制一段 JSON 给开发者复现状态。App 侧已实现，待真机验收。
- 诊断包不包含 Wi-Fi 密码、token、精确完整历史轨迹。代码与 smoke 已覆盖服务端上传路径。
- 登录用户可以上传诊断包，服务端返回 `diag_` 报告号并记录 `diagnostics_submit` 审计事件。已由 `tools/verify_project.sh quick/full` 验证。

### 10. 权限、隐私与合规

目标：

- 定位、蓝牙、通知和数据使用必须可解释、可关闭、可恢复。

当前差距：

- `Info.plist` 有定位说明，App 内“隐私与权限”页已展示定位、蓝牙、通知、诊断和 App Store 隐私标签草案。
- 通知权限请求流程已接 `UNUserNotificationCenter`；App 授权后会注册 APNs token，并在已登录时上传 `/v1/push/register`；Relay 已支持 `DRAGON_RADAR_APNS_MODE=disabled|dry_run|live`，房间邀请、设备离线和抢麦异常可触发 APNs 投递。`dry_run` 已纳入 smoke，`live` 仍需生产 Team ID、Key ID、Topic、`.p8` 私钥和真机 APNs 回执验收。
- 定位共享关闭后的服务端状态处理已完成；仍需 TestFlight 真机验收文案、权限弹窗和 App Store Connect 隐私问卷一致性。

实施步骤：

1. “我的”里增加隐私页。已完成。
2. 增加“暂停定位共享”时对 Relay 发送 `location_paused`。已完成。
3. 服务端对 paused 成员显示“定位已暂停”，而不是误判失联。已完成；Relay `room_state` 返回 `location_paused=true`，App 成员模型和诊断包已展示。
4. 增加通知权限申请，用于房间邀请、设备离线、抢麦异常。已完成 App 内授权流程、APNs token 上传和 Relay 投递骨架；房间邀请、设备离线和抢麦异常 `dry_run` 已验证。
5. 准备 App Store 隐私标签所需的数据收集说明。已完成 `docs/app-store-privacy-labels.zh.md` 草案。

验收标准：

- 用户能在 App 内看到定位用途、上传对象、关闭方法。已通过 iOS Debug build 验证页面编译。
- 关闭定位共享后其他成员看到明确状态。协议、App 模型和 smoke 已验证，仍需双真机 UI 验收。
- 登录用户授权通知后，App 可注册 APNs token 并上传 Relay；Relay smoke 已验证 `/v1/push/register`、房间邀请/设备离线/抢麦异常 `push_delivery` dry-run 和 `/healthz.notifications` 状态。
- App Store 审核所需权限文案和隐私说明一致。草案已完成，仍需 App Store Connect 提交前复核。

## P2 上线前质量项

### 11. 错误处理和状态文案统一

实施步骤：

1. 定义统一错误枚举：`AppError`、`RelayError`、`BLEError`、`RoomError`。已完成基础定义，并由房间 API 错误复用 `RoomError` 用户文案。
2. Relay 错误码整理为稳定合同：`room_full`、`unauthorized`、`device_revoked`、`invalid_room`、`voice_busy`。`device_revoked` 已由 Relay Device WebSocket 和 smoke 固定。
3. UI 只显示用户可理解文案，调试详情进入诊断包。房间创建/加入、诊断上传、绑定提交和登录已使用用户可理解文案；更多 BLE/Relay 细节仍需继续收敛到诊断包。
4. 所有异步按钮都有 loading、success、failed 三态。创建房间、加入房间、诊断上传、绑定提交、登录入口已完成三态；后续新增异步按钮继续复用同一组件。

验收标准：

- 断网、房间满、token 失效、BLE 未授权、定位未授权都有明确下一步。房间相关、定位权限说明、诊断上传、绑定提交和登录入口已完成基础提示；真实弱网、BLE 权限弹窗和 TestFlight 登录仍需真机复核。

### 12. App 性能和耗电

实施步骤：

1. 对雷达页、房间页、设备页做 Instruments Time Profiler。
2. 定位上传节流保持 2 秒到 10 秒区间，后台按 iOS 策略降低频率。
3. 房间 `room_state` 刷新从固定 3 秒心跳改为服务端推送优先，心跳只做保活。
4. 降低 SwiftUI 大列表频繁刷新，成员行使用稳定 ID。
5. 清理 Swift 6 编译警告，尤其是 CoreBluetooth/CoreLocation 旧 delegate 协议跨 actor 的并发边界。
6. 真机连续运行 2 小时记录电量、温度和网络流量。

当前进展：

- CoreBluetooth central 已固定在 main queue，`BLEDeviceBridge` 的 `CBCentralManagerDelegate`/`CBPeripheralDelegate` 旧协议边界已用 `@preconcurrency` 标注。
- CoreLocation manager 在主线程持有，`LocationBridge` 的 `CLLocationManagerDelegate` 旧协议边界已用 `@preconcurrency` 标注。
- Debug build 已不再出现 Swift 6 main actor delegate conformance 警告；仍需真机 Instruments、电量和后台定位矩阵验收。

验收标准：

- iPhone 前台 30 分钟无明显卡顿。
- 后台定位不造成异常发热。
- 7 人房间 room_state 高频更新时 UI 不掉帧。

### 13. 测试矩阵

实施步骤：

1. 单元测试：
   - 距离计算
   - 方位计算
   - `room_state` 解码
   - `voice_floor` 解码
   - 房间满员错误解析
   已完成首批自动化覆盖：`RelayModelTests` 覆盖距离/方位投影、`room_state` / `voice_floor` 解码、语音状态投影和 `room_full` 用户文案。
2. 集成测试：
   - App Relay 连接
   - 定位上传到 Relay
   - 房间切换通知 ESP
   - BLE 写入成功/失败
3. UI 测试：
   - 未登录启动
   - 无设备
   - 无房间
   - 满员加入失败
   - 切换房间
   - 定位权限拒绝
   已完成自动化覆盖：`LaunchReadinessUITests` 使用 `DRAGON_RADAR_UI_TESTING` 启动参数隔离 Keychain/UserDefaults，验证未登录、无服务端房间、无注册 ESP 时不会显示 demo 房间或 demo 设备；使用 `DRAGON_RADAR_UI_TESTING_AUTHENTICATED` + `DRAGON_RADAR_UI_TESTING_ROOM_FULL` 验证满员加入失败文案；使用 `DRAGON_RADAR_UI_TESTING_SEEDED_ROOMS` 验证服务端房间切换会更新当前房间；使用 `DRAGON_RADAR_UI_TESTING_LOCATION_DENIED` 验证定位权限拒绝时“我的”页首屏会显示可理解的阻断原因。真机系统权限弹窗和设置页跳转仍需 TestFlight 复核。
4. 硬件联调：
   - 2 组真实 iPhone + ESP
   - 7 组压力测试，其中可用 Mac 模拟补齐
   - ESP 断网重连
   - Relay 重启恢复
   - 抢麦冲突

验收标准：

- `tools/verify_project.sh full` 通过，并自动执行 iOS 单元测试和 UI 测试。
- 至少 2 组真实硬件完成端到端定位和抢麦语音。
- 7 组房间压力测试能稳定 30 分钟。

### 14. 发布与运维

实施步骤：

1. 建立 `Debug`、`Staging`、`Release` 配置。
2. Bundle ID、Team、Capabilities、后台定位、蓝牙权限确认。
3. TestFlight 内测包签名和安装流程固定。
4. 服务端部署脚本支持备份、回滚、健康检查。已完成脚本能力，仍需生产云环境演练。
5. 建立版本兼容表：App 版本、ESP 固件版本、Relay 协议版本。已完成，见 `docs/version-compatibility.zh.md`。
6. App 启动时检查最低兼容固件和 Relay 协议版本。已完成：Relay 通过 `hello_ack.protocol` 检查，ESP 通过 `room_state.members[].protocol_version` 检查。

验收标准：

- TestFlight 包可安装、可登录、可绑定、可进房间、可上传定位。
- 服务端升级后旧 App/旧固件有明确兼容策略；低版本 `hello` 会返回 `protocol_unsupported`。

## 推荐实施顺序

### 第一阶段：真实身份和真实房间

1. 做 Sign in with Apple 和服务端 token。
2. 做房间持久化 API。
3. App 房间列表从服务端读取。
4. 创建/加入/切换房间全部改为真实 API。
5. Relay 接入 token 校验和 room membership 校验。

完成标志：

- App 重装后，登录同一账号能恢复房间和设备。

### 第二阶段：设备注册和切房闭环

1. 服务端实现设备注册和 device token。
2. BLE `pairing_response` 改为服务端签名。
3. App 设备列表真实化。
4. 切房后 ESP 自动同步，并有确认状态。
5. 释放设备和 token 撤销闭环已完成代码与自动化验证，待实体 ESP 重新绑定验收。

完成标志：

- BLE 断开后，ESP 仍可靠按本地持久化配置联网进房间；切房不要求重新配网。

### 第三阶段：定位可靠性和状态透明

1. 定位 ack 和 sequence。已完成。
2. Reduced Accuracy、权限拒绝、后台状态 UI。
3. Relay last-known location、`location_paused` 和 stale 状态。已完成：`location_paused` 会隐藏坐标；`location_stale` 会保留最后坐标但标记过期，并带 `location_age_ms`。
4. App/ESP/Relay 重连恢复测试。

完成标志：

- 两组真实设备异地移动时，ESP 圆屏持续显示正确距离变化。

### 第四阶段：抢麦语音上线化

1. Relay `voice_floor` 合同定版。
2. App 完整解析并显示当前说话者和 busy。
3. ESP 真实 PCM16 上下行联调。
4. 只允许一个成员说话，其他人被明确拒绝。
5. 音频优先级确认：按住说话时本机提示音和远端播放都不干扰麦克风。

完成标志：

- 两台 ESP 能完成真实抢麦语音通话；第三台同时抢麦会收到 busy。

### 第五阶段：上线质量

1. 诊断包真机验收与后台查询流程固定。
2. 错误文案统一。
3. 性能和耗电测试。
4. TestFlight 流程。
5. 隐私说明和 App Store 元数据。

完成标志：

- 非开发用户拿到 TestFlight 包后，可以按 App 指引完成登录、绑定、配网、进房间、定位显示和抢麦语音。

## 当前最应该先做的 5 个具体任务

1. 固定生产域名、TLS 和 `wss://` Relay 入口；HTTP/WebSocket 限流和部署健康检查基础已完成，仍需云侧 TLS/证书/反代配置。
2. 固定真实生产配对密钥的保管和轮换方案；代码侧 preflight 已确保服务端 `DRAGON_RADAR_PAIRING_HMAC_KEY` 与固件 `PAIRING_HMAC_KEY` 一致且不是默认开发 key。
3. 做 TestFlight 真机矩阵：Apple 登录、绑定、配网、房间切换、暂停定位、后台 30 分钟、2 组 ESP 端到端定位。
4. TestFlight 真机复核隐私说明页、通知权限弹窗和 App Store 隐私标签文案；App 内流程和草案已完成。
5. 抢麦语音做硬件端到端验收：7 组房间只允许一人说话，busy、当前说话者、提示音优先级都能稳定复现。

这 5 项完成后，App 才能从“本地/局域联调可用”进入“可交给外部用户 TestFlight 验收”的状态。
