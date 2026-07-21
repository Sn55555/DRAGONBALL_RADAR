import SwiftUI

struct SetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ToyBezel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("上线顺序")
                            .font(.largeTitle.weight(.black))
                        Text("一次性完成授权、绑定和房间加入；日常语音由 iPhone 联网转发。")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MangaTheme.subtle)
                        SetupReadinessStrip(
                            locationReady: locationReady,
                            espReady: bindingReady,
                            roomReady: roomReady,
                            relayReady: radarRuntime.relayPhase == .ready
                        )
                    }
                }

                LazyVStack(spacing: 12) {
                    SetupStepCard(
                        index: 1,
                        title: "我的授权",
                        detail: userAuthorizationDetail,
                        isReady: locationReady,
                        primaryTitle: locationReady ? "管理授权" : "开启定位",
                        primarySymbol: "location.fill",
                        primaryAction: openLocationSettings
                    )

                    SetupStepCard(
                        index: 2,
                        title: "雷达一次性绑定",
                        detail: espRegistrationDetail,
                        isReady: bindingReady,
                        primaryTitle: bindingReady ? "查看雷达" : "绑定雷达",
                        primarySymbol: "link",
                        primaryAction: openPairing
                    )

                    SetupStepCard(
                        index: 3,
                        title: "OTA 网络（可选）",
                        detail: espNetworkDetail,
                        isReady: true,
                        primaryTitle: espNetworkReady ? "查看 OTA 网络" : "按需设置",
                        primarySymbol: "wifi",
                        primaryAction: openWifiConfig
                    )

                    SetupStepCard(
                        index: 4,
                        title: "进入远程房间",
                        detail: roomDetail,
                        isReady: roomReady,
                        primaryTitle: "管理房间",
                        primarySymbol: "person.3.sequence.fill",
                        primaryAction: openRooms
                    )

                    SetupStepCard(
                        index: 5,
                        title: "进入雷达",
                        detail: radarEntryDetail,
                        isReady: radarRuntime.relayPhase == .ready,
                        primaryTitle: "打开雷达",
                        primarySymbol: "scope",
                        primaryAction: openRadar
                    )
                }
                .mangaCard("推荐流程")

                MangaPanel("当前状态") {
                    RuntimeRow(title: "房间连接", phase: radarRuntime.relayPhase, detail: roomConnectionDetail)
                    RuntimeRow(title: "雷达连接", phase: radarRuntime.espPhase, detail: radarConnectionDetail)
                    RuntimeRow(title: "语音", phase: radarRuntime.voicePhase, detail: voiceConnectionDetail)
                }

                MangaPanel("日常使用") {
                    SetupUsageRow(
                        symbol: "person.crop.circle",
                        title: "我的",
                        detail: "管理 iPhone 定位桥接、蓝牙权限和登录身份。"
                    )
                    SetupUsageRow(
                        symbol: "dot.radiowaves.left.and.right",
                        title: "设备",
                        detail: "首次绑定后，App 会按保存记录自动连接雷达。"
                    )
                    SetupUsageRow(
                        symbol: "scope",
                        title: "雷达",
                        detail: "日常通过蓝牙连接 iPhone，不要求 ESP 连接 Wi-Fi。"
                    )
                }
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("准备")
    }

    private var espNetworkReady: Bool {
        if let status = bleBridge.deviceStatus {
            return status.wifi == "connected" && status.server == 1
        }
        return bleBridge.persistedServerConfigured
    }

    private var locationReady: Bool {
        locationBridge.isSharing && locationBridge.snapshot != nil
    }

    private var bindingReady: Bool {
        !appState.devices.isEmpty && bleBridge.isRegistrationComplete
    }

    private var roomReady: Bool {
        !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var userAuthorizationDetail: String {
        "\(locationBridge.permissionText) · \(locationBridge.sharingText) · \(locationBridge.coordinateText)"
    }

    private var espRegistrationDetail: String {
        if bindingReady {
            return bleBridge.registrationText
        }
        if appState.devices.isEmpty, bleBridge.hasSavedRegistration {
            return "雷达保留旧配置 · 当前账户未绑定"
        }
        if bleBridge.isBLEConnected {
            return "雷达已连接 · 等待完成绑定"
        }
        return "\(bleBridge.registrationText) · \(bleBridge.connectedPeripheralName)"
    }

    private var espNetworkDetail: String {
        guard let status = bleBridge.deviceStatus else {
            return "日常语音无需配网 · 固件更新时再设置"
        }
        return status.wifi == "connected"
            ? "\(status.wifiText) · 可用于固件更新"
            : "日常语音无需配网 · 固件更新时再设置"
    }

    private var roomDetail: String {
        guard roomReady else {
            return "未进入房间 · 不影响网络连接"
        }
        return "\(appState.activeRoomName) · \(appState.inviteCode) · \(appState.onlineMembers)/\(appState.roomCapacity)"
    }

    private var radarEntryDetail: String {
        guard roomReady else {
            return "未进入房间"
        }
        return "\(appState.onlineMembers)/\(appState.roomCapacity) 在线 · \(radarRuntime.relayPhase.rawValue)"
    }

    private var roomConnectionDetail: String {
        guard roomReady else {
            return "未进入房间"
        }
        return radarRuntime.relayPhase == .ready ? "房间已连接" : "正在连接房间"
    }

    private var radarConnectionDetail: String {
        if bindingReady { return "雷达已绑定" }
        if appState.devices.isEmpty, bleBridge.hasSavedRegistration {
            return "雷达有旧配置 · 当前账户未绑定"
        }
        if bleBridge.isBLEConnected { return "雷达已连接" }
        return "未连接雷达"
    }

    private var voiceConnectionDetail: String {
        radarRuntime.voicePhase == .ready ? "可用" : "等待房间连接"
    }

    private func openLocationSettings() {
        locationBridge.startSharing()
        appState.selectedTab = .account
    }

    private func openPairing() {
        appState.selectedTab = .devices
        appState.showPairingSheet = true
    }

    private func openWifiConfig() {
        appState.selectedTab = .devices
        appState.showWifiSheet = true
    }

    private func openRooms() {
        appState.selectedTab = .rooms
    }

    private func openRadar() {
        appState.selectedTab = .radar
    }
}

struct SetupReadinessStrip: View {
    var locationReady: Bool
    var espReady: Bool
    var roomReady: Bool
    var relayReady: Bool

    var body: some View {
        HStack(spacing: 8) {
            SetupPip(title: "我", isReady: locationReady)
            SetupPip(title: "雷达", isReady: espReady)
            SetupPip(title: "房间", isReady: roomReady)
            SetupPip(title: "云", isReady: relayReady)
        }
        .padding(.top, 2)
    }
}

struct SetupPip: View {
    var title: String
    var isReady: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isReady ? MangaTheme.ink : MangaTheme.panelLight)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 1.2))
            Text(title)
                .font(.caption.weight(.black))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(MangaTheme.panelLight.opacity(0.95), in: Capsule())
        .overlay(Capsule().stroke(MangaTheme.ink, lineWidth: 1.4))
    }
}

struct SetupStepCard: View {
    var index: Int
    var title: String
    var detail: String
    var isReady: Bool
    var primaryTitle: String
    var primarySymbol: String
    var primaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index)")
                    .font(.headline.weight(.black))
                    .frame(width: 34, height: 34)
                    .background(MangaTheme.panelLight, in: Circle())
                    .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 2))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.black))
                    Text(detail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                        .lineLimit(2)
                }

                Spacer()
                StatusChip(text: isReady ? "完成" : "待处理", filled: isReady)
            }

            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: primarySymbol)
            }
            .buttonStyle(InkButtonStyle(filled: !isReady))
        }
        .padding(12)
        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MangaTheme.ink.opacity(0.72), lineWidth: 1.4))
    }
}

struct SetupUsageRow: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .frame(width: 30, height: 30)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(MangaTheme.ink, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
