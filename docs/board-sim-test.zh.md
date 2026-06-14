# 旧单板 DBALL 模拟验收已废弃

旧版 `sim` 固件用于在一块板上模拟 7 个实体 DBALL 目标。实体寻宝玩法已经废弃，因此这条验收路径不再使用。

当前真板验收应改为远程房间链路：

- BLE 配置服务可被 iOS App 扫描和连接。
- App 能写入 `wifi_config`、`server_config`、`local_location`。
- ESP 能连接 Wi-Fi。
- ESP 能连接 Relay device WebSocket。
- Relay 能把 App 和 ESP 合并为同一个 room member。
- App 定位上传后，ESP 圆屏能显示其他成员距离、方位和在线状态。
- ESP 抢麦时 Relay 授予发言权；其他成员抢麦时收到 busy。
- 远端语音帧能被其他 ESP 播放或至少产生明确的播放状态。

推荐验证顺序：

1. 运行 `python3 tools/smoke_relay.py --url ws://127.0.0.1:8787 --room DRGN-SMOKE` 验证 Relay 协议。
2. 运行 `tools/build_radar.sh field` 验证 ESP 固件构建。
3. 用 iOS App 连接真板 BLE，写入 Wi-Fi 和 Relay 配置。
4. 用至少两组 `iPhone + ESP` 做同房间定位和抢麦实测。
