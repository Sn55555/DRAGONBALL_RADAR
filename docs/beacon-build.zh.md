# 实体 DBALL 信标方案已废弃

本文件原本用于制作实体 `DBALL-*` BLE 信标。该玩法已经从 Dragon Radar 当前目标中移除。

当前不再制作：

- 实体 DBALL 信标。
- 信标编号、烧录、标签、隐藏点位。
- 7 个信标可见性验收。
- field hunt 收集和召唤验收。

当前项目只保留“房间多人实时定位 + ESP 抢麦语音”方向。请以以下文档为准：

- `docs/product-design.zh.md`
- `docs/remote-multi-radar-architecture.zh.md`
- `docs/ios-app-information-architecture.zh.md`

如果需要验收，请验证 App、ESP、Relay 三端链路：

1. App 通过 BLE 配置 ESP。
2. ESP 通过 Wi-Fi 连接 Relay。
3. App 上传本机定位。
4. Relay 下发 room_state。
5. ESP 显示同房间远端成员。
6. ESP 抢麦上行语音，Relay 拒绝其他并发抢麦。
7. 其他 ESP 收到远端语音并播放。
