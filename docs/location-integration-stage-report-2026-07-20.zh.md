# 双雷达定位联调阶段记录

更新时间：2026-07-20

## 阶段结论

两套真实 `iPhone + ESP` 设备在同一房间内的定位主链路已经基本完成联调：

```text
iPhone A -> 个人热点 -> 雷达 1 -> Relay
mini phone + 雷达 2 -> 同一局域网 -> Relay
两部 iPhone App -> Relay room -> 两块 ESP 圆屏互相显示
```

本阶段结论是“定位联调基本完成”，不是整套产品已经完成。双向 PTT 的远端可听
音频、长时间移动场景和弱网恢复仍是独立验收项。

## 已完成并验证

- 两个用户账号分别完成雷达绑定、Wi-Fi 写入、房间加入和 Relay 连接。
- Relay 把同一成员的 App/ESP 连接按 canonical member 合并；新连接替换旧连接，
  避免一个实体在房间中被重复显示为两个目标。
- 房间成员名称使用用户资料中的 display name，不再显示内部设备名或 peer id。
- 两部 iPhone 的定位序列持续递增并跨过 30 秒新鲜度窗口；静止时仍发送
  keepalive，避免圆形成员点在没有明显位移时周期性消失。
- 两块 ESP 都能收到 `room_state`，识别 `self=yes` 和 `remoteCount=1`，并在圆屏
  显示远端成员位置。
- 当前第二块实机正式固件启动后连续收到 `self=yes remoteCount=1`，证明普通刷写
  后 Wi-Fi、房间、设备凭证和定位链路仍保留。
- 两块板使用相同 App/固件版本时，先前“一块显示两个目标、另一块只显示一个”
  的差异已定位并由成员连接合并修复，不是固件版本差异。
- 第二块 QMI8658 的静止零偏约为 `6.4 dps`、静止加速度约为 `1.073 g`，高于第一
  块板。启动严格静止门限已按实机差异调整为允许稳定板间偏置，再由方差门限判断
  是否真正静止；长按北向校准已在第二块板多次成功，零偏持久化后可温度匹配启动。
- 后续桌面静置发现保存零偏在温升后仍可留下约 `0.5–0.8 dps` 全向残差，旧逻辑
  因热启动已受信任而无法再次进入严格静止窗口。研发分支改为 Fusion 6DOF 重力
  估计、持久零偏热启动后强制本次静止复核，以及 ZARU/静止 yaw 锁定。第二块实机
  在 `45.9–48.2°C` 连续静置超过 1 分钟时，原始重力轴速率约
  `-0.28～+0.18 dps`，应用航向保持 `0.0°` 且 `yawLocked=yes`。

## 本次固件增量

发布 `1.0.11 / build 13 / security_counter 13`：

- 系统菜单新增 `DIR`。
- 支持 USB/机身接口位于 6 点或 12 点两种握持方向。
- 切换时完整 UI 旋转 180°，触摸坐标同步反转。
- 方向写入 `dragonRadar` NVS，断电重启后保留；非法或缺失值回退为 6 点。
- 第二块 ESP 已实机完成 `12 -> 6 -> 12` 切换并硬重启，重启首个诊断状态恢复为
  `screenDir=12`；随后换回正式 field 固件。

OTA 发布包已完成 ECDSA P-256/SHA-256 离线校验并在线晋升：

- 版本：`1.0.11`
- build：`13`
- security counter：`13`
- artifact SHA-256：`c965a2f0caf616a4c1a3079c6028fb41edc63b879a319a99dade51b64b04f994`
- Relay 健康检查：`firmware.available=true`
- 保留旧发布快照：3 个

当前服务器仍是内部测试 HTTP OTA 通道，健康检查会标记
`development=true`。它不等于 Production HTTPS/WSS 发布；生产渠道仍必须配置
稳定根 CA、生产 pairing key，并关闭 development OTA 开关。

## 验收证据

- 第二块 ESP：`/dev/cu.usbmodem1101`
- 芯片 MAC：`28:84:85:90:5f:04`
- 方向数学与触摸映射：`display-orientation-math-ok`
- 项目快速门禁：`verify-project-ok (quick)`
- OTA 离线验签：`ota-release-ok version=1.0.11 build=13 security_counter=13`
- 实机正式固件房间状态：连续 `Relay room_state locations self=yes remoteCount=1`

## 后续未完成门禁

1. 两套设备边走动边测试距离、方位、半格吸附和锁定成员的连续稳定性。
2. iPhone 热点切换、蜂窝/局域网切换、App 进入后台及弱网断连重连的长时间 soak。
3. 完成双向 PTT 远端扬声器可听验收；当前按键、波纹和抢麦状态有效不等于音频已
   播放成功。
4. 在 OTA 双分区实机上补齐断网续传、升级中断电、防降级和 boot rollback。
5. Production 发布前完成 HTTPS/WSS、稳定根 CA 与生产 pairing key 的独立门禁。
