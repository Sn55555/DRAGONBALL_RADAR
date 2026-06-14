# Dragon Radar 版本兼容表

更新时间：2026-06-11

## 当前协议基线

| 组件 | 当前版本声明 | 最低兼容要求 | 说明 |
| --- | --- | --- | --- |
| iOS App | `protocol_version=2` | `min_relay_protocol_version=2` | App WebSocket `hello` 上报，收到 Relay `hello_ack` 后检查。 |
| Relay | `relay=2` | `min_app=2`、`min_device=2` | `/healthz` 和 WebSocket `hello_ack` 公告，`hello` 低于最低版本会返回 `protocol_unsupported` 并关闭连接。 |
| ESP 固件 | `protocol_version=2` | `min_relay_protocol_version=2` | Device WebSocket `hello` 和 `device_status` 上报。 |
| LocationFrame | `location_frame=1` | `1` | iPhone 到 ESP 的本地定位帧格式仍为 v1。 |
| 语音协议 | `voice=1` | `1` | 当前为 ESP 侧 PTT、单人抢麦和 PCM16 帧。 |

## 发布规则

1. Relay 可以先升级，只要继续接受当前 `min_app` 和 `min_device`。
2. App 或 ESP 引入不兼容字段前，先提升 Relay 的公告版本并保留旧版本一段灰度期。
3. 当 Relay 提升 `DRAGON_RADAR_MIN_APP_PROTOCOL_VERSION` 或 `DRAGON_RADAR_MIN_DEVICE_PROTOCOL_VERSION` 后，低版本客户端必须显示明确错误，不允许静默降级。
4. Release 前必须运行 `tools/verify_project.sh full`，其中 `tools/smoke_relay.py` 会检查 `/healthz`、`hello_ack` 和低版本拒绝路径。

## 用户可见状态

- App “准备 > 当前链路”和“我的 > 链路状态”显示协议兼容状态。
- Relay 不兼容时，App 标记 Relay 为失败并显示当前版本与要求版本。
- 服务端审计记录 `protocol_unsupported`，包含客户端版本、要求版本和 Relay 版本。
