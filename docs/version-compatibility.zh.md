# 胶囊版本兼容表

更新时间：2026-07-20

## 当前协议基线

| 组件 | 当前版本声明 | 最低兼容要求 | 说明 |
| --- | --- | --- | --- |
| iOS App | `protocol_version=2` | `min_relay_protocol_version=2` | App WebSocket `hello` 上报，收到 Relay `hello_ack` 后检查。 |
| Relay | `relay=2` | `min_app=2`、`min_device=2` | `/healthz` 和 WebSocket `hello_ack` 公告，`hello` 低于最低版本会返回 `protocol_unsupported` 并关闭连接。 |
| ESP 固件 | `protocol_version=2` | `min_relay_protocol_version=2` | Device WebSocket `hello` 和 `device_status` 上报。 |
| LocationFrame | `location_frame=1` | `1` | 本地定位帧仍为 v1；bit2 仅表示雷达本体绝对航向有效，口袋中的 iPhone 航向不得设置该位。 |
| 语音协议 | `voice=1` | `1` | 当前为 ESP 侧 PTT、单人抢麦和 PCM16 帧。 |

## OTA 发布基线

OTA 发布版本与 WebSocket 协议版本是两套独立编号，不能互相替代：

| 标识 | 当前合同 | 兼容规则 |
| --- | --- | --- |
| Manifest schema | `1` | 非 `1` 的发布拒绝展示和安装。 |
| Product | `dragon-radar` | App、ESP 和 Relay 精确匹配。 |
| Hardware | `esp32-s3-touch-amoled-1.75c` | 不允许跨硬件安装。 |
| 签名 | `ecdsa-p256-sha256` | canonical payload、DER 标准 Base64、受信 P-256 公钥。 |
| Key ID | `local-2026-01` | 当前三端固定；轮换必须先做多端兼容发布。 |
| `version` | 严格数字 `x.y.z`，每段不超过 UInt32 | 用户展示和 `minimum_version` 比较；拒绝 prerelease/build metadata 和超界段。 |
| `build` | `1...4294967295` | 同一数字版本内也必须递增。 |
| `security_counter` | `1...4294967295` | ESP 持久化最高已接受值，目标不得更低。 |
| OTA signing key | DER SPKI SHA-256 | supplied 发布公钥必须匹配 binary sidecar 记录的内置信任公钥。 |
| OTA transport | 生产根 CA | stable 包要求 root CA 且禁止 HTTP；HTTP 只用于显式开发 build。 |
| Release build | `release_build=true` | stable 包必须通过 `RADAR_RELEASE=1` 的生产 pairing-key preflight。 |
| Build environment | `field` | stable 包拒绝 diag 等不能完成正常 BLE boot-health 的构建。 |

完整字段顺序、HTTP 鉴权、发布和回滚步骤见 `docs/firmware-ota.zh.md`。

当前内部测试发布为 `1.0.11 / build 13 / security_counter 13`。该版本新增
ESP 圆屏 `6/12` 点握持方向切换、180° 触控映射和 NVS 持久化，并放宽第二块
实机 QMI8658 的严格静止启动门限；没有改变 Relay、App、LocationFrame 或语音
协议版本。

## 发布规则

1. Relay 可以先升级，只要继续接受当前 `min_app` 和 `min_device`。
2. App 或 ESP 引入不兼容字段前，先提升 Relay 的公告版本并保留旧版本一段灰度期。
3. 当 Relay 提升 `DRAGON_RADAR_MIN_APP_PROTOCOL_VERSION` 或 `DRAGON_RADAR_MIN_DEVICE_PROTOCOL_VERSION` 后，低版本客户端必须显示明确错误，不允许静默降级。
4. Release 前必须运行 `tools/verify_project.sh full`，其中 `tools/smoke_relay.py` 会检查 `/healthz`、`hello_ack` 和低版本拒绝路径。
5. OTA 不能用降低 `security_counter` 的旧包回滚；需要回退功能时，以更高 build 和 counter 重新签名发布。
6. 改变 partition table 只能走一次性 USB factory bootstrap，不能当普通 OTA app 包发布。
7. App 只把同源根相对 `artifact_url` 解析为绝对 HTTP(S) URL并检查 scheme/host/port；Release 环境必须是 HTTPS。ESP 下载使用 device Bearer token，token 不进入 URL。
8. ESP 不能只信任 App 的 URL 校验；必须以 `server_config.http_api_url` 独立核对 scheme、host、effective port 和固定 artifact path，再附加 device Bearer。
9. 旧 NVS 没有 `http_api_url` 时 OTA 不兼容，App 必须先重新同步设备配置；ESP 不允许从未签名 URL 自动建立信任 origin。
10. Relay 默认拒绝 development OTA metadata；`DRAGON_RADAR_ALLOW_DEVELOPMENT_OTA=1` 只允许本地 HTTP 联调，生产禁止设置。
11. `course_deg100` 始终表示 GPS 行进方向。当前 App 将 `heading_deg100` 写为 `0` 且不设置 bit2，不能用手机 heading 或 course 冒充雷达朝向。ESP 在本机 QMI8658 取得可信零偏后，只在真实开机显示一次提示；可信零偏来自本次严格静止验证，或来自结构有效且当前/保存温差不超过 6°C 的持久零偏。用户把雷达零点/12 点方向对准真北并静止长按屏幕，以 `C = wrap360(-G0)` 建立本机 IMU 会话偏移。该偏移不依赖成员 GPS，不改变 LocationFrame、不设置 bit2、不持久化，旧 App/Relay 无需协议升级；BOOT 短按只关闭尚在显示的提示并切换成员，不能触发或再次显示校准提示。主雷达静止长按 1.2 秒始终可以重校准；切成员、切房和网络重连保留偏移，待机清相对 yaw/北向偏移但保留本次供电会话的可信零偏，重启、IMU 重置或积分断档清除北向偏移，只有真实重启重新显示教学提示。
12. `screenDir=6/12` 是 ESP 本机 UI 设置，只旋转显示并反转触摸坐标，保存在 `dragonRadar` NVS；它不修改成员真北方位、北向校准会话偏移或任何跨端协议字段，因此旧 App 和 Relay 无需升级。

## 用户可见状态

- App “准备 > 当前链路”和“我的 > 链路状态”显示协议兼容状态。
- Relay 不兼容时，App 标记 Relay 为失败并显示当前版本与要求版本。
- 服务端审计记录 `protocol_unsupported`，包含客户端版本、要求版本和 Relay 版本。
- App 设备详情区分检查、可升级、下载/写入/校验/重启、成功和失败可重试状态。
- 签名错误、硬件不匹配、防降级拒绝和设备 token 吊销必须显示明确原因，不能静默安装。
