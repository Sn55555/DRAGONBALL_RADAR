import SwiftUI
import UIKit

struct DevicesView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(PushToTalkGateway.self) private var pushToTalkGateway

    var body: some View {
        @Bindable var state = appState
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if appState.isReviewExperienceActive {
                    MangaPanel("本地审核体验") {
                        Text("设备页未创建或伪造任何雷达。演示期间不会扫描、绑定或连接真实硬件。")
                            .font(.headline.weight(.black))
                        ReviewExperienceSafetyNotice()
                        Button("返回演示雷达") {
                            state.selectedTab = .radar
                        }
                        .buttonStyle(InkButtonStyle())
                        .accessibilityIdentifier("devices.reviewExperience.backToRadar")
                    }
                } else {
                    ToyBezel {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top) {
                                Text("雷达状态")
                                    .font(.largeTitle.weight(.black))
                                Spacer()
                                StatusChip(text: bleBridge.userConnectionText, filled: bleBridge.isBLEConnected)
                            }

                            DeviceInventorySection()
                            DeviceConnectionGuidePanel()
                        }
                    }

                    DeviceActionMenuPanel()
                }
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("雷达")
        .accessibilityIdentifier("devices.screen")
        .sheet(isPresented: $state.showWifiSheet) {
            WifiConfigSheet()
        }
    }

    private var setupReady: Bool {
        locationBridge.snapshot != nil
            && !appState.devices.isEmpty
            && bleBridge.hasSavedRegistration
            && bleBridge.isVoiceGatewayReady
            && pushToTalkGateway.activeChannelUUID != nil
            && radarRuntime.relayPhase == .ready
            && !appState.inviteCode.isEmpty
    }

    private var espNetworkReady: Bool {
        bleBridge.isVoiceGatewayReady
            && radarRuntime.relayPhase == .ready
            && pushToTalkGateway.activeChannelUUID != nil
    }
}

struct DeviceInventorySection: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("我的雷达")
                    .font(.headline.weight(.black))
                Spacer()
                StatusChip(text: appState.devices.isEmpty ? "未绑定" : "\(appState.devices.count) 台", filled: !appState.devices.isEmpty)
            }

            if appState.devices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "display")
                        .font(.headline.weight(.black))
                        .frame(width: 36, height: 36)
                        .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.5))
                    Text("尚未绑定雷达")
                        .font(.headline.weight(.black))
                    Spacer()
                }
                .accessibilityIdentifier("devices.empty.radar")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(appState.devices) { device in
                        NavigationLink {
                            DeviceStatusDetailView(device: device)
                        } label: {
                            DeviceInlineRadarRow(
                                device: device,
                                status: bleBridge.deviceStatus,
                                connectionText: bleBridge.userConnectionText,
                                isConnected: bleBridge.isBLEConnected,
                                relayOnline: bleBridge.isVoiceGatewayReady && radarRuntime.relayPhase == .ready,
                                relayStatus: radarRuntime.localRelayDeviceStatus
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct DeviceInlineRadarRow: View {
    var device: RadarDevice
    var status: RadarBLEDeviceStatus?
    var connectionText: String
    var isConnected: Bool
    var relayOnline: Bool
    var relayStatus: RelayDeviceStatusSnapshot?

    private var displayName: String {
        guard let name = status?.name, !name.isEmpty else {
            return device.name
        }
        return name
    }

    private var statusText: String {
        if relayOnline {
            return "工作中"
        }
        return connectionText
    }

    private var statusReady: Bool {
        relayOnline || isConnected
    }

    private var secondaryText: String {
        if relayOnline {
            return "iPhone 网关在线"
        }
        if isConnected { return "已连接到 iPhone" }
        return connectionText == "正在连接" ? "App 正在自动连接" : "打开雷达后会自动连接"
    }

    private var batteryText: String {
        if let relayStatus, relayStatus.batteryDisplayText != "未上报" {
            return relayStatus.batteryDisplayText
        }
        if let status, status.batteryText != "未上报" {
            return status.batteryText
        }
        if device.battery >= 0 {
            return "\(device.battery)%"
        }
        return "未上报"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.headline.weight(.black))
                .frame(width: 36, height: 36)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.headline.weight(.black))
                Text(secondaryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .lineLimit(1)
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusChip(text: statusText, filled: statusReady)
                Text("电量 \(batteryText)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(MangaTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.black))
                .foregroundStyle(MangaTheme.ink)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MangaTheme.ink.opacity(0.16))
                .frame(height: 1)
        }
    }
}

struct DeviceConnectionGuidePanel: View {
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: currentSymbol)
                    .font(.title2.weight(.black))
                    .frame(width: 34, height: 34)
                    .background(MangaTheme.panelLight, in: Circle())
                    .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 1.6))

                VStack(alignment: .leading, spacing: 6) {
                    Text(bleBridge.userConnectionText)
                        .font(.title3.weight(.black))
                    Text(bleBridge.userConnectionDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                Spacer()
                StatusChip(text: bleBridge.isBLEConnected ? "已连接" : "自动连接", filled: bleBridge.isBLEConnected)
            }

            connectionAction
        }
        .accessibilityIdentifier("devices.radar.connection.status")
        .onAppear {
            bleBridge.resumeAutomaticConnection()
        }
    }

    private var currentSymbol: String {
        if bleBridge.isBLEConnected { return "checkmark.circle.fill" }
        if bleBridge.stateText != "可用" { return "gearshape.fill" }
        return "dot.radiowaves.left.and.right"
    }

    @ViewBuilder
    private var connectionAction: some View {
        if bleBridge.stateText != "可用" {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("打开蓝牙设置", systemImage: "gearshape.fill")
            }
            .buttonStyle(InkButtonStyle())
        } else if !bleBridge.isBLEConnected, bleBridge.hasSavedGateway {
            Button {
                bleBridge.resumeAutomaticConnection()
            } label: {
                Label("重新连接", systemImage: "arrow.clockwise")
            }
            .buttonStyle(InkButtonStyle())
        } else if !bleBridge.isBLEConnected {
            NavigationLink {
                BLEConfigDetailView()
            } label: {
                Label("首次连接雷达", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(InkButtonStyle())
        }
    }
}

struct ConnectionStepRow: View {
    var index: Int
    var title: String
    var detail: String
    var isReady: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.caption2.weight(.black))
                .frame(width: 22, height: 22)
                .background(isReady ? MangaTheme.ink : MangaTheme.panelLight, in: Circle())
                .foregroundStyle(isReady ? MangaTheme.paper : MangaTheme.ink)
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 1.2))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.black))
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct DeviceActionMenuPanel: View {
    var body: some View {
        MangaPanel("更多") {
            NavigationLink {
                DeviceSetupDetailView()
            } label: {
                DeviceMenuRow(
                    symbol: "checklist",
                    title: "配置流程",
                    detail: "授权、绑定、房间和进入雷达；OTA 网络按需设置。"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                BLEConfigDetailView()
            } label: {
                DeviceMenuRow(
                    symbol: "dot.radiowaves.left.and.right",
                    title: "连接雷达",
                    detail: "首次扫描连接，之后由 App 自动连接。"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                DeviceDiagnosticsDetailView()
            } label: {
                DeviceMenuRow(
                    symbol: "stethoscope",
                    title: "状态检查",
                    detail: "查看连接、授权、语音、网络和房间详情。"
                )
            }
            .buttonStyle(.plain)

            FirmwareSummaryRow()
        }
    }
}

struct DeviceMenuRow: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .frame(width: 34, height: 34)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .lineLimit(2)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.black))
                .foregroundStyle(MangaTheme.ink)
        }
        .padding(.vertical, 7)
    }
}

struct DeviceStatusDetailView: View {
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    var device: RadarDevice

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ESPWorkingStatusPanel()
                MangaPanel("雷达详情") {
                    DeviceCard(
                        device: device,
                        status: bleBridge.deviceStatus,
                        relayStatus: radarRuntime.localRelayDeviceStatus,
                        registrationText: bleBridge.registrationText,
                        configChannelText: bleBridge.connectedPeripheralName
                    )
                }
                MangaPanel("固件") {
                    FirmwareSummaryRow()
                }
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("雷达详情")
    }
}

struct DeviceSetupDetailView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                DeviceSetupFlowPanel()
                ESPRegistrationChecklist()
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("配置流程")
    }
}

struct BLEConfigDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if appState.devices.isEmpty, bleBridge.hasSavedRegistration {
                    RadarBindingRecoveryPanel()
                }
                BLEScanPanel()
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("连接雷达")
    }
}

private struct RadarBindingRecoveryPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        MangaPanel("重新绑定") {
            Text("雷达保留着旧账户配置，当前账户不能直接覆盖绑定。请先在雷达本机完成安全恢复。")
                .font(.subheadline.weight(.semibold))

            ConnectionStepRow(index: 1, title: "打开系统菜单", detail: "短按雷达侧键", isReady: false)
            ConnectionStepRow(index: 2, title: "选择 RST", detail: "滑动到 RST 后点按进入", isReady: false)
            ConnectionStepRow(index: 3, title: "确认恢复", detail: "在圆屏中央持续按住 4 秒，等待雷达重启", isReady: false)

            Text("恢复会清除原所有者、Wi-Fi 和房间配置。雷达重启后保持靠近手机，再点下方按钮。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MangaTheme.subtle)

            Button {
                bleBridge.startFreshScan()
            } label: {
                Label("重新扫描并绑定", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle())
        }
        .accessibilityIdentifier("devices.binding.recovery")
    }
}

struct DeviceDiagnosticsDetailView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                DiagnosticsPanel()
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("状态检查")
    }
}

struct ESPWorkingStatusPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(PushToTalkGateway.self) private var pushToTalkGateway

    var body: some View {
        MangaPanel("雷达工作状态") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(overallTitle)
                        .font(.title2.weight(.black))
                    Text(overallDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                        .lineLimit(2)
                }
                Spacer()
                StatusChip(text: setupReady ? "当前可用" : "未确认", filled: setupReady)
            }

            HStack(spacing: 10) {
                ESPStatusMetric(title: "配置", value: configValue, isReady: bindingReady)
                ESPStatusMetric(title: "网关", value: networkValue, isReady: phoneGatewayReady)
                ESPStatusMetric(title: "房间", value: appState.inviteCode, isReady: roomReady)
            }

            InfoRow(label: "电量", value: batteryValue)
            InfoRow(label: "语音", value: phoneGatewayReady ? "可用" : "正在准备")
            InfoRow(label: "房间", value: roomReady ? appState.activeRoomName : "未进入房间")
        }
        .accessibilityIdentifier("devices.radar.work.status")
    }

    private var setupReady: Bool {
        locationReady && bindingReady && phoneGatewayReady && roomReady
    }

    private var bindingReady: Bool {
        !appState.devices.isEmpty && bleBridge.hasSavedRegistration
    }

    private var locationReady: Bool {
        locationBridge.isSharing && locationBridge.snapshot != nil
    }

    private var phoneGatewayReady: Bool {
        bleBridge.isVoiceGatewayReady
            && radarRuntime.relayPhase == .ready
            && pushToTalkGateway.activeChannelUUID != nil
    }

    private var roomReady: Bool {
        !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var relayValue: String {
        guard roomReady else {
            return "未进入房间"
        }
        return bleBridge.deviceStatus?.relayText ?? radarRuntime.relayPhase.rawValue
    }

    private var batteryValue: String {
        if let relayStatus = radarRuntime.localRelayDeviceStatus,
           relayStatus.batteryDisplayText != "未上报" {
            return "\(relayStatus.batteryDisplayText) · 实时"
        }
        if let status = bleBridge.deviceStatus, status.batteryText != "未上报" {
            return "\(status.batteryText) · 实时"
        }
        return "未上报"
    }

    private var configValue: String {
        if bindingReady {
            return bleBridge.hasLiveDeviceStatus ? "已确认" : "上次保存"
        }
        if bleBridge.hasSavedRegistration {
            return "账户未绑定"
        }
        return appState.devices.isEmpty ? "未完成" : "待确认"
    }

    private var networkValue: String {
        if phoneGatewayReady { return "在线" }
        if !bleBridge.isVoiceGatewayReady { return "连接中" }
        if radarRuntime.relayPhase != .ready { return "连接房间中" }
        return "正在准备"
    }

    private var overallTitle: String {
        if setupReady {
            return "雷达可以投入使用"
        }
        if appState.devices.isEmpty, bleBridge.hasSavedRegistration {
            return "雷达保留旧配置，账户未绑定"
        }
        if bindingReady, !bleBridge.hasLiveDeviceStatus {
            return "雷达当前状态未确认"
        }
        if !bindingReady {
            return "雷达还未完成绑定"
        }
        if !phoneGatewayReady {
            return "正在准备语音连接"
        }
        if !locationReady {
            return "等待 iPhone 定位桥接"
        }
        return "等待房间配置"
    }

    private var overallDetail: String {
        if setupReady {
            return "雷达已通过 iPhone 联网，房间语音和远程唤醒均可使用。"
        }
        return "日常工作不再要求雷达连接 Wi-Fi；Wi-Fi 配置仅在 OTA 更新时使用。"
    }
}

struct ESPStatusMetric: View {
    var title: String
    var value: String
    var isReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(MangaTheme.subtle)
            Text(value)
                .font(.headline.weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isReady ? MangaTheme.ink : MangaTheme.ink.opacity(0.45), lineWidth: isReady ? 2 : 1.3))
    }
}

struct DeviceSetupFlowPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        MangaPanel("配置流程") {
            SetupReadinessStrip(
                locationReady: locationReady,
                espReady: bindingReady,
                roomReady: roomReady,
                relayReady: radarRuntime.relayPhase == .ready
            )

            DeviceSetupActionRow(
                index: 1,
                title: "我的授权",
                detail: "\(locationBridge.permissionText) · \(locationBridge.sharingText)",
                isReady: locationReady,
                buttonTitle: locationReady ? "管理" : "开启",
                symbol: "location.fill",
                action: openAccount
            )
            DeviceSetupActionRow(
                index: 2,
                title: "绑定雷达",
                detail: bindingDetail,
                isReady: bindingReady,
                buttonTitle: bindingReady ? "查看" : "绑定",
                symbol: "link",
                action: openPairing
            )
            DeviceSetupActionRow(
                index: 3,
                title: "OTA 网络（可选）",
                detail: espNetworkDetail,
                isReady: true,
                buttonTitle: espNetworkReady ? "查看" : "按需设置",
                symbol: "wifi",
                action: openWifi
            )
            DeviceSetupActionRow(
                index: 4,
                title: "房间",
                detail: roomDetail,
                isReady: roomReady,
                buttonTitle: "管理",
                symbol: "person.3.sequence.fill",
                action: openRooms
            )
            DeviceSetupActionRow(
                index: 5,
                title: "进入雷达",
                detail: radarEntryDetail,
                isReady: radarRuntime.relayPhase == .ready,
                buttonTitle: "打开",
                symbol: "scope",
                action: openRadar
            )
        }
    }

    private var locationReady: Bool {
        locationBridge.isSharing && locationBridge.snapshot != nil
    }

    private var bindingReady: Bool {
        !appState.devices.isEmpty && bleBridge.isRegistrationComplete
    }

    private var bindingDetail: String {
        if bindingReady {
            return bleBridge.registrationText
        }
        if appState.devices.isEmpty, bleBridge.hasSavedRegistration {
            return "雷达保留旧配置 · 当前账户未绑定"
        }
        return bleBridge.registrationText
    }

    private var roomReady: Bool {
        !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var espNetworkReady: Bool {
        if let status = bleBridge.deviceStatus {
            return status.wifi == "connected" && status.server == 1
        }
        return bleBridge.persistedServerConfigured
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
        return "\(appState.activeRoomName) · \(appState.inviteCode)"
    }

    private var radarEntryDetail: String {
        guard roomReady else {
            return "未进入房间"
        }
        return "\(appState.onlineMembers)/\(appState.roomCapacity) 在线 · \(radarRuntime.relayPhase.rawValue)"
    }

    private func openAccount() {
        locationBridge.startSharing()
        appState.selectedTab = .account
    }

    private func openPairing() {
        appState.showPairingSheet = true
    }

    private func openWifi() {
        appState.showWifiSheet = true
    }

    private func openRooms() {
        appState.selectedTab = .rooms
    }

    private func openRadar() {
        appState.selectedTab = .radar
    }
}

struct DeviceSetupActionRow: View {
    var index: Int
    var title: String
    var detail: String
    var isReady: Bool
    var buttonTitle: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.black))
                .frame(width: 26, height: 26)
                .background(isReady ? MangaTheme.ink : MangaTheme.panelLight, in: Circle())
                .foregroundStyle(isReady ? MangaTheme.paper : MangaTheme.ink)
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 1.6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.black))
                    Text(title)
                        .font(.headline.weight(.black))
                }
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .lineLimit(2)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(InkButtonStyle(filled: !isReady))
                .frame(width: 78)
        }
        .padding(.vertical, 5)
    }
}

struct ESPRegistrationChecklist: View {
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        MangaPanel("注册状态") {
            DeviceSetupStatusRow(
                title: "连接雷达",
                detail: bleBridge.connectedPeripheralName,
                isReady: bleBridge.isBLEConnected
            )
            DeviceSetupStatusRow(
                title: "账号绑定",
                detail: bleBridge.persistedPaired ? "已绑定到当前账号" : "未绑定",
                isReady: bleBridge.persistedPaired || (bleBridge.deviceStatus?.paired ?? 0) == 1
            )
            DeviceSetupStatusRow(
                title: "设备身份",
                detail: bleBridge.persistedServerConfigured ? "房间凭证已保存" : "绑定时自动写入",
                isReady: bleBridge.persistedServerConfigured || (bleBridge.deviceStatus?.server ?? 0) == 1
            )
            if let status = bleBridge.deviceStatus {
                DeviceSetupStatusRow(
                    title: "OTA 网络（可选）",
                    detail: status.wifi == "connected" ? status.wifiText : "未连接 · 日常语音无需 Wi-Fi",
                    isReady: true
                )
            }
        }
    }
}

struct DeviceSetupStatusRow: View {
    var title: String
    var detail: String
    var isReady: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
                .font(.headline.weight(.black))
                .foregroundStyle(MangaTheme.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct BLEScanPanel: View {
    @Environment(BLEDeviceBridge.self) private var bleBridge

    var body: some View {
        MangaPanel("连接雷达") {
            HStack(spacing: 12) {
                Image(systemName: bleBridge.isBLEConnected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.black))
                VStack(alignment: .leading, spacing: 3) {
                    Text(bleBridge.userConnectionText)
                        .font(.title3.weight(.black))
                    Text(bleBridge.userConnectionDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                Spacer()
            }

            if !bleBridge.isBLEConnected {
                if bleBridge.candidates.isEmpty {
                    Text("请打开雷达并放在手机附近。首次连接成功后，以后会自动连接。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                ForEach(bleBridge.candidates) { candidate in
                    BLECandidateRow(candidate: candidate)
                }
                Button {
                    if bleBridge.hasSavedGateway {
                        bleBridge.startFreshScan()
                    } else {
                        bleBridge.startScan()
                    }
                } label: {
                    Label(
                        bleBridge.isScanning || bleBridge.hasSavedGateway ? "重新扫描" : "开始扫描",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(InkButtonStyle())
            }
        }
        .onAppear {
            if bleBridge.hasSavedGateway {
                bleBridge.resumeAutomaticConnection()
            } else if !bleBridge.isBLEConnected, !bleBridge.isScanning {
                bleBridge.startScan()
            }
        }
    }
}

struct BLECandidateRow: View {
    @Environment(BLEDeviceBridge.self) private var bleBridge
    var candidate: BLEDeviceCandidate

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.name)
                    .font(.headline.weight(.black))
                Text("附近的雷达")
                    .font(.caption)
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
            Button {
                bleBridge.connect(candidate)
            } label: {
                Text("连接")
            }
            .buttonStyle(InkButtonStyle())
            .disabled(!candidate.isConnectable)
        }
        .padding(10)
        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MangaTheme.ink.opacity(0.72), lineWidth: 1.4))
    }
}

struct DeviceSummaryCard: View {
    var device: RadarDevice
    var status: RadarBLEDeviceStatus?
    var relayOnline: Bool = false
    var relayStatus: RelayDeviceStatusSnapshot?

    private var displayName: String {
        guard let name = status?.name, !name.isEmpty else {
            return device.name
        }
        return name
    }

    private var statusText: String {
        if relayOnline {
            return "工作中"
        }
        guard let status else {
            return device.state.rawValue
        }
        if status.wifi == "connected", status.server == 1 {
            return "在线可用"
        }
        if status.paired == 1, status.server == 1 {
            return "等待联网"
        }
        if status.paired == 1 {
            return "已绑定"
        }
        return "待配置"
    }

    private var statusReady: Bool {
        if relayOnline {
            return true
        }
        guard let status else {
            return device.state == .cloudConnected
        }
        return status.wifi == "connected" && status.server == 1
    }

    private var secondaryText: String {
        if relayOnline {
            if let relayStatus, relayStatus.wifi == "connected" {
                return relayStatus.ip.map { "\($0) · 在线" } ?? "在线"
            }
            return "在线"
        }
        guard let status else {
            return "\(device.wifiName) · 本地记录"
        }
        return status.wifiText
    }

    private var batteryText: String {
        if let relayStatus, relayStatus.batteryDisplayText != "未上报" {
            return relayStatus.batteryDisplayText
        }
        if let status, status.batteryText != "未上报" {
            return status.batteryText
        }
        if device.battery >= 0 {
            return "\(device.battery)%"
        }
        return "未上报"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display")
                .font(.title3.weight(.black))
                .frame(width: 42, height: 42)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(MangaTheme.ink, lineWidth: 1.8))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.headline.weight(.black))
                Text(secondaryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .lineLimit(1)
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusChip(text: statusText, filled: statusReady)
                Text("电量 \(batteryText)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(MangaTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.black))
                .foregroundStyle(MangaTheme.ink)
        }
        .padding(10)
        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MangaTheme.ink.opacity(0.72), lineWidth: 1.4))
    }
}

struct DeviceCard: View {
    var device: RadarDevice
    var status: RadarBLEDeviceStatus?
    var relayStatus: RelayDeviceStatusSnapshot?
    var registrationText: String
    var configChannelText: String

    private var displayName: String {
        guard let name = status?.name, !name.isEmpty else {
            return device.name
        }
        return name
    }

    private var stateText: String {
        guard let status else {
            return device.state.rawValue
        }
        if status.wifi == "connected", status.server == 1 {
            return "已配置"
        }
        if status.ble == 1 {
            return "配置通道"
        }
        if status.paired == 1 {
            return "已绑定"
        }
        return "待配置"
    }

    private var stateReady: Bool {
        if let status {
            return status.wifi == "connected" && status.server == 1
        }
        return device.state == .cloudConnected
    }

    private var batteryText: String {
        if let relayStatus, relayStatus.batteryDisplayText != "未上报" {
            return "\(relayStatus.batteryDisplayText) · 实时"
        }
        if let status, status.batteryText != "未上报" {
            return "\(status.batteryText) · 实时"
        }
        if device.battery >= 0 {
            return "\(device.battery)% · 最近一次"
        }
        return "未上报"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(displayName)
                        .font(.title3.weight(.black))
                    Text(status == nil ? "本地记录" : "来自雷达")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                Spacer()
                StatusChip(text: stateText, filled: stateReady)
            }

            InfoRow(label: "电量", value: batteryText)
            InfoRow(label: "Wi-Fi", value: status?.wifiText ?? "\(device.wifiName) · 本地记录")
            InfoRow(label: "设备身份", value: status?.serverText ?? registrationText)
            InfoRow(label: "配置连接", value: configChannelText)
            InfoRow(label: "定位", value: status?.locationText ?? "等待雷达上报")
            InfoRow(label: "固件", value: status?.firmwareText ?? "未上报")
            InfoRow(label: "硬件", value: status?.hardware ?? "未上报")
            InfoRow(label: "最近状态", value: status?.last ?? "等待雷达上报")
        }
        .padding(12)
        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MangaTheme.ink, lineWidth: 1.6))
    }
}

struct DiagnosticsPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @State private var diagnosticsActionText = "尚未导出状态包"
    @State private var uploadPhase: AppOperationPhase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MangaPanel("连接详情") {
                InfoRow(label: "用户状态", value: bleBridge.userConnectionText)
                InfoRow(label: "手机蓝牙", value: "\(bleBridge.stateText) · \(bleBridge.authorizationText)")
                InfoRow(label: "已保存设备", value: bleBridge.hasSavedGateway ? bleBridge.persistedDeviceName : "无")
                InfoRow(label: "系统连接", value: bleBridge.isBLEConnected ? bleBridge.connectedPeripheralName : "未连接")
                InfoRow(label: "配置服务", value: provisioningServiceDetail)
                InfoRow(label: "所有者授权", value: bleBridge.ownerSessionAuthorized ? "已通过" : "未完成")
                InfoRow(label: "语音服务", value: voiceServiceDetail)
                InfoRow(label: "最近事件", value: bleBridge.lastEvent)

                Button {
                    if bleBridge.isBLEConnected {
                        bleBridge.refreshCharacteristics()
                    } else {
                        bleBridge.resumeAutomaticConnection()
                    }
                } label: {
                    Label("重新检查连接", systemImage: "arrow.clockwise")
                }
                .buttonStyle(InkButtonStyle(filled: false))
            }

            MangaPanel("状态检查") {
                ForEach(appState.diagnostics) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(MangaTheme.ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.headline.weight(.black))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(MangaTheme.subtle)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    appState.runDiagnostics()
                    Task {
                        guard appState.isSignedIn else { return }
                        guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        await radarRuntime.connectRelay(
                            roomCode: appState.inviteCode,
                            deviceToken: appState.activeDeviceToken,
                            appAccessToken: appState.accessToken
                        )
                    }
                } label: {
                    Label("重新检查", systemImage: "stethoscope")
                }
                .buttonStyle(InkButtonStyle())

                Button {
                    let json = DiagnosticPackageFactory.makeJSONString(
                        appState: appState,
                        radarRuntime: radarRuntime,
                        locationBridge: locationBridge,
                        bleBridge: bleBridge
                    )
                    UIPasteboard.general.string = json
                    diagnosticsActionText = "状态包已复制 · \(json.utf8.count) bytes"
                } label: {
                    Label("复制状态包", systemImage: "doc.on.doc")
                }
                .buttonStyle(InkButtonStyle(filled: false))

                Button {
                    Task { await uploadDiagnostics() }
                } label: {
                    Label(uploadPhase.isLoading ? "上传中" : "上传状态包", systemImage: "arrow.up.doc")
                }
                .buttonStyle(InkButtonStyle(filled: false))
                .disabled(uploadPhase.isLoading)

                OperationStatusView(phase: diagnosticsUploadPhase)

                Text(diagnosticsActionText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
        }
    }

    private var provisioningServiceDetail: String {
        let found = RadarBLECharacteristic.requiredProvisioningRoles.filter { bleBridge.hasCharacteristic($0) }.count
        return "已发现 \(found)/\(RadarBLECharacteristic.requiredProvisioningRoles.count) 项"
    }

    private var voiceServiceDetail: String {
        let roles: [RadarBLECharacteristic] = [.voiceControl, .voiceAudioUplink, .voiceAudioDownlink]
        let found = roles.filter { bleBridge.hasCharacteristic($0) }.count
        return bleBridge.isVoiceGatewayReady ? "已就绪" : "已发现 \(found)/\(roles.count) 项"
    }

    @MainActor
    private func uploadDiagnostics() async {
        guard appState.isSignedIn else {
            uploadPhase = .failed(AppError.notSignedIn.localizedDescription)
            return
        }
        uploadPhase = .loading
        let report = DiagnosticPackageFactory.makeReport(
            appState: appState,
            radarRuntime: radarRuntime,
            locationBridge: locationBridge,
            bleBridge: bleBridge
        )
        do {
            let repository = DiagnosticsRepository(accessToken: appState.accessToken)
            let reportID = try await repository.submit(report: report)
            diagnosticsActionText = "状态包已上传 · \(reportID)"
            uploadPhase = .success("状态包已上传 · \(reportID)")
        } catch {
            let message = "上传失败 · \(AppError.userFacingMessage(for: error))"
            diagnosticsActionText = message
            uploadPhase = .failed(message)
        }
    }

    private var diagnosticsUploadPhase: AppOperationPhase {
        if appState.isSignedIn {
            return uploadPhase
        }
        return .failed(AppError.notSignedIn.localizedDescription)
    }
}

struct WifiConfigSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""
    @State private var writePhase: AppOperationPhase = .idle

    private var canSave: Bool {
        !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !writePhase.isLoading
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("此网络只供 ESP 固件 OTA 更新使用。日常房间、语音和远程唤醒由 iPhone 联网转发，不需要雷达连接 Wi-Fi。")
                        .foregroundStyle(.secondary)
                }
                Section("推荐：iPhone 个人热点") {
                    Text("请手动开启个人热点，SSID 填 iPhone 热点名称，密码填个人热点页面显示的 Wi-Fi 密码。")
                        .foregroundStyle(.secondary)
                }
                Section("网络") {
                    TextField("SSID / 热点名称", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Wi-Fi 密码", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("状态") {
                    wifiWriteStatusView
                    LabeledContent("雷达连接", value: bleBridge.connectedPeripheralName)
                    LabeledContent("雷达 Wi-Fi", value: wifiStatusText)
                    LabeledContent("房间连接", value: serverStatusText)
                }
            }
            .navigationTitle("OTA Wi-Fi / 热点")
            .scrollContentBackground(.hidden)
            .background(MangaBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(writePhase.isLoading ? "写入中" : "写入") {
                        Task {
                            await writeConfiguration()
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private var wifiWriteStatusView: some View {
        switch writePhase {
        case .idle:
            Label("等待写入雷达", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在写入雷达")
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @MainActor
    private func writeConfiguration() async {
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSSID.isEmpty else { return }

        guard bleBridge.isBLEConnected else {
            writePhase = .failed("雷达未连接，不能写入 OTA 网络")
            return
        }

        writePhase = .loading
        let writeStartedAt = Date()
        guard bleBridge.writeWifiConfig(ssid: cleanSSID, password: password) else {
            writePhase = .failed(userFacingWriteFailure(defaultMessage: "Wi-Fi 写入失败"))
            return
        }
        appState.applyWifiConfig(ssid: cleanSSID)

        let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceToken = appState.activeDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomCode.isEmpty else {
            writePhase = .success("Wi-Fi 已写入，房间未配置")
            return
        }
        guard !deviceToken.isEmpty else {
            writePhase = .success("Wi-Fi 已写入，雷达未完成绑定")
            return
        }

        guard bleBridge.writeServerConfig(
            relayURL: radarRuntime.relayBaseURL,
            roomToken: roomCode,
            deviceToken: deviceToken
        ) else {
            writePhase = .failed(userFacingWriteFailure(defaultMessage: "设备身份写入失败"))
            return
        }

        await radarRuntime.provisionESP(
            deviceName: appState.activeDevice?.name ?? "雷达",
            roomCode: roomCode
        )
        await waitForESPNetworkConfirmation(since: writeStartedAt)
    }

    @MainActor
    private func waitForESPNetworkConfirmation(since writeStartedAt: Date) async {
        for _ in 0..<12 {
            bleBridge.readDeviceStatus()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let lastStatusAt = bleBridge.lastDeviceStatusAt, lastStatusAt >= writeStartedAt {
                if bleBridge.isLiveNetworkConfirmed {
                    writePhase = .success("雷达已联网")
                    return
                }
                if let status = bleBridge.deviceStatus, status.wifi != "connecting" {
                    writePhase = .success("已写入雷达，等待联网确认")
                }
            }
        }

        if bleBridge.isLiveNetworkConfirmed {
            writePhase = .success("雷达已联网")
        } else if let status = bleBridge.deviceStatus {
            writePhase = .success("已写入雷达，当前状态：\(status.wifiText)")
        } else {
            writePhase = .success("已写入雷达，等待雷达上报")
        }
    }

    private var wifiStatusText: String {
        guard let status = bleBridge.deviceStatus else {
            return "等待雷达上报"
        }
        if status.wifi == "connected" {
            return status.ip.isEmpty ? "已连接" : "\(status.ip) · \(status.rssi)dBm"
        }
        if writePhase.isLoading {
            return "正在连接"
        }
        return status.wifiText
    }

    private var serverStatusText: String {
        guard let status = bleBridge.deviceStatus else {
            return "等待雷达上报"
        }
        return status.server == 1 ? "已配置" : "未配置"
    }

    private func userFacingWriteFailure(defaultMessage: String) -> String {
        if !bleBridge.isBLEConnected {
            return "雷达未连接，不能写入"
        }
        if bleBridge.lastWriteEvent.contains("不可用") {
            return "雷达连接未准备好，不能写入"
        }
        if bleBridge.lastWriteEvent.contains("失败") {
            return bleBridge.lastWriteEvent
        }
        return defaultMessage
    }
}
