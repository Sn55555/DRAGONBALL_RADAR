import SwiftUI
import UIKit

struct DevicesView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge

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
                                StatusChip(text: setupReady ? "准备完成" : "继续配置", filled: setupReady)
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
        .sheet(isPresented: $state.showPairingSheet) {
            PairingSheet()
        }
        .sheet(isPresented: $state.showWifiSheet) {
            WifiConfigSheet()
        }
    }

    private var setupReady: Bool {
        locationBridge.snapshot != nil
            && bleBridge.hasSavedRegistration
            && (bleBridge.isLiveNetworkConfirmed || radarRuntime.localDeviceOnline)
            && !appState.inviteCode.isEmpty
    }

    private var espNetworkReady: Bool {
        bleBridge.isLiveNetworkConfirmed || radarRuntime.localDeviceOnline
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
                                relayOnline: radarRuntime.localDeviceOnline,
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
        guard let status else {
            return device.state.rawValue
        }
        if status.wifi == "connected", status.server == 1 {
            return "在线可用"
        }
        if status.paired == 1 {
            return "已绑定"
        }
        return "待配置"
    }

    private var statusReady: Bool {
        if relayOnline { return true }
        guard let status else { return device.state == .cloudConnected }
        return status.wifi == "connected" && status.server == 1
    }

    private var secondaryText: String {
        if relayOnline {
            if let relayStatus, relayStatus.wifi == "connected" {
                return relayStatus.ip ?? "在线"
            }
            return "在线"
        }
        guard let status else {
            return device.wifiName
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
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
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
                    Text(currentTitle)
                        .font(.title3.weight(.black))
                }
                Spacer()
                StatusChip(text: setupReady ? "当前可用" : "未确认", filled: setupReady)
            }

            resolutionActions

            VStack(spacing: 7) {
                ConnectionStepRow(index: 1, title: "手机蓝牙", detail: bluetoothDetail, isReady: bleBridge.stateText == "可用")
                ConnectionStepRow(index: 2, title: "配置连接", detail: bleConnectionDetail, isReady: bleBridge.isBLEConnected)
                ConnectionStepRow(index: 3, title: "绑定配置", detail: pairingDetail, isReady: bleBridge.hasSavedRegistration)
                ConnectionStepRow(index: 4, title: "当前联网", detail: espNetworkDetail, isReady: espNetworkReady)
                ConnectionStepRow(index: 5, title: "当前房间", detail: roomDetail, isReady: roomReady && radarRuntime.relayPhase == .ready)
            }
        }
        .accessibilityIdentifier("devices.radar.connection.status")
    }

    private var setupReady: Bool {
        locationBridge.snapshot != nil
            && bleBridge.hasSavedRegistration
            && espNetworkReady
            && roomReady
            && radarRuntime.relayPhase == .ready
    }

    private var bleCharacteristicsReady: Bool {
        RadarBLECharacteristic.requiredProvisioningRoles.allSatisfy { bleBridge.hasCharacteristic($0) }
    }

    private var espProtocolReady: Bool {
        bleCharacteristicsReady && bleBridge.pairingChallengeText != "未读取"
    }

    private var roomReady: Bool {
        !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var espNetworkReady: Bool {
        bleBridge.isLiveNetworkConfirmed || radarRuntime.localDeviceOnline
    }

    private var bluetoothDetail: String {
        switch bleBridge.stateText {
        case "可用": return "可用"
        case "蓝牙关闭": return "手机蓝牙关闭"
        case "未授权": return "App 蓝牙权限未开启"
        default: return bleBridge.stateText
        }
    }

    private var bleConnectionDetail: String {
        if bleBridge.isBLEConnected { return "\(bleBridge.connectedPeripheralName) 已连接" }
        if radarRuntime.localDeviceOnline { return "配置连接未开启，不影响雷达工作" }
        if bleBridge.scanTimedOut { return "没有找到雷达" }
        if bleBridge.isScanning { return bleBridge.candidates.isEmpty ? "正在查找雷达" : "发现雷达，进入连接" }
        return "未连接，仅用于配置"
    }

    private var pairingDetail: String {
        if bleBridge.hasSavedRegistration {
            return bleBridge.hasLiveDeviceStatus ? "当前已确认" : "上次已保存"
        }
        return bleBridge.isBLEConnected ? "未完成" : "等待连接雷达"
    }

    private var espNetworkDetail: String {
        if let relayStatus = radarRuntime.localRelayDeviceStatus {
            if relayStatus.wifi == "connected" {
                return relayStatus.ip.map { "\($0) · 在线" } ?? "在线"
            }
            if radarRuntime.localDeviceOnline {
                return "在线"
            }
        }
        if radarRuntime.localDeviceOnline {
            return "在线"
        }
        guard let status = bleBridge.deviceStatus else {
            return bleBridge.hasSavedRegistration ? "未拿到当前状态" : "未配置"
        }
        if status.wifi == "connected", status.server == 1 { return "已联网" }
        if status.wifi != "connected" { return "Wi-Fi 未连接" }
        return "服务器未连接"
    }

    private var roomDetail: String {
        guard roomReady else { return "未进入房间" }
        return radarRuntime.relayPhase == .ready ? "\(appState.activeRoomName) 已连接" : "\(appState.activeRoomName) 连接中"
    }

    private var currentTitle: String {
        if bleBridge.stateText != "可用" { return "蓝牙不可用" }
        if radarRuntime.localDeviceOnline { return "雷达正在工作" }
        if bleBridge.scanTimedOut { return "没有找到雷达" }
        if !bleBridge.isBLEConnected { return bleBridge.isScanning ? "正在查找雷达" : "未连接雷达" }
        if !espProtocolReady { return "雷达连接未就绪" }
        if !bleBridge.hasSavedRegistration { return "雷达未绑定" }
        if !espNetworkReady { return bleBridge.hasLiveDeviceStatus ? "雷达网络未连接" : "雷达状态未确认" }
        if !roomReady { return "未进入房间" }
        if radarRuntime.relayPhase != .ready { return "房间连接中" }
        return "雷达当前可用"
    }

    private var currentSymbol: String {
        if setupReady { return "checkmark.seal.fill" }
        if bleBridge.stateText != "可用" { return "gearshape.fill" }
        if radarRuntime.localDeviceOnline { return "checkmark.seal.fill" }
        if !bleBridge.isBLEConnected || !espProtocolReady { return "dot.radiowaves.left.and.right" }
        if !bleBridge.hasSavedRegistration { return "link" }
        if !espNetworkReady { return "wifi.exclamationmark" }
        if !roomReady || radarRuntime.relayPhase != .ready { return "person.3.sequence.fill" }
        return "scope"
    }

    @ViewBuilder
    private var resolutionActions: some View {
        HStack(spacing: 10) {
            if bleBridge.stateText != "可用" {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开设置", systemImage: "gearshape.fill")
                }
                .buttonStyle(InkButtonStyle())
            } else if radarRuntime.localDeviceOnline {
                Button {
                    appState.selectedTab = .radar
                } label: {
                    Label("打开雷达", systemImage: "scope")
                }
                .buttonStyle(InkButtonStyle())

                NavigationLink {
                    BLEConfigDetailView()
                } label: {
                    Label("配置连接", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(InkButtonStyle(filled: false))
            } else if !bleBridge.isBLEConnected {
                NavigationLink {
                    BLEConfigDetailView()
                } label: {
                    Label("进入连接", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(InkButtonStyle())

                Button {
                    bleBridge.startScan()
                } label: {
                    Label(bleBridge.isScanning ? "重新扫描" : "扫描雷达", systemImage: "arrow.clockwise")
                }
                .buttonStyle(InkButtonStyle(filled: false))
            } else if !espProtocolReady {
                Button {
                    bleBridge.refreshCharacteristics()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(InkButtonStyle())

                Button {
                    bleBridge.disconnect()
                } label: {
                    Label("断开重连", systemImage: "xmark.circle")
                }
                .buttonStyle(InkButtonStyle(filled: false))
            } else if !bleBridge.hasSavedRegistration {
                Button {
                    appState.showPairingSheet = true
                } label: {
                    Label("打开绑定", systemImage: "link")
                }
                .buttonStyle(InkButtonStyle())
            } else if !espNetworkReady {
                Button {
                    appState.showWifiSheet = true
                } label: {
                    Label("重新配网", systemImage: "wifi")
                }
                .buttonStyle(InkButtonStyle())

                NavigationLink {
                    BLEConfigDetailView()
                } label: {
                    Label("连接确认", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(InkButtonStyle(filled: false))
            } else if !roomReady || radarRuntime.relayPhase != .ready {
                Button {
                    appState.selectedTab = .rooms
                } label: {
                    Label("打开房间", systemImage: "person.3.sequence.fill")
                }
                .buttonStyle(InkButtonStyle())
            } else {
                Button {
                    appState.selectedTab = .radar
                } label: {
                    Label("打开雷达", systemImage: "scope")
                }
                .buttonStyle(InkButtonStyle())
            }
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
                    detail: "授权、绑定、配网、房间和进入雷达。"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                BLEConfigDetailView()
            } label: {
                DeviceMenuRow(
                    symbol: "dot.radiowaves.left.and.right",
                    title: "连接雷达",
                    detail: "扫描附近雷达，并建立配置连接。"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                DeviceDiagnosticsDetailView()
            } label: {
                DeviceMenuRow(
                    symbol: "stethoscope",
                    title: "状态检查",
                    detail: "检查雷达、网络、定位和房间状态。"
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
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                BLEScanPanel()
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("连接雷达")
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
                ESPStatusMetric(title: "配置", value: configValue, isReady: bleBridge.hasSavedRegistration)
                ESPStatusMetric(title: "联网", value: networkValue, isReady: espNetworkReady)
                ESPStatusMetric(title: "房间", value: appState.inviteCode, isReady: roomReady)
            }

            InfoRow(label: "电量", value: batteryValue)
            InfoRow(label: "Wi-Fi", value: bleBridge.deviceStatus?.wifiText ?? (bleBridge.hasSavedRegistration ? "上次已配置 · 当前未确认" : "未确认"))
            InfoRow(label: "定位桥接", value: locationBridge.snapshot == nil ? locationBridge.sharingText : locationBridge.coordinateText)
            InfoRow(label: "最近状态", value: bleBridge.deviceStatus?.last ?? "等待雷达当前状态")
        }
        .accessibilityIdentifier("devices.radar.work.status")
    }

    private var setupReady: Bool {
        locationReady && bleBridge.hasSavedRegistration && espNetworkReady && roomReady
    }

    private var locationReady: Bool {
        locationBridge.isSharing && locationBridge.snapshot != nil
    }

    private var espNetworkReady: Bool {
        bleBridge.isLiveNetworkConfirmed
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
        if bleBridge.hasLiveDeviceStatus {
            return bleBridge.hasSavedRegistration ? "已确认" : "未完成"
        }
        return bleBridge.hasSavedRegistration ? "上次保存" : "未完成"
    }

    private var networkValue: String {
        guard let status = bleBridge.deviceStatus else {
            return bleBridge.hasSavedRegistration ? "未确认" : "未配置"
        }
        return status.wifi == "connected" ? "在线" : status.wifi
    }

    private var overallTitle: String {
        if setupReady {
            return "雷达可以投入使用"
        }
        if bleBridge.hasSavedRegistration, !bleBridge.hasLiveDeviceStatus {
            return "雷达当前状态未确认"
        }
        if !bleBridge.hasSavedRegistration {
            return "雷达还未完成绑定"
        }
        if !espNetworkReady {
            return "雷达网络未确认"
        }
        if !locationReady {
            return "等待 iPhone 定位桥接"
        }
        return "等待房间配置"
    }

    private var overallDetail: String {
        if setupReady {
            return "已拿到雷达当前状态，网络和房间都可用。"
        }
        return "这里显示实时工作状态；历史配置不会被当成当前可用。"
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
                espReady: bleBridge.isRegistrationComplete,
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
                detail: bleBridge.registrationText,
                isReady: bleBridge.isRegistrationComplete,
                buttonTitle: bleBridge.isRegistrationComplete ? "查看" : "绑定",
                symbol: "link",
                action: openPairing
            )
            DeviceSetupActionRow(
                index: 3,
                title: "网络和服务器",
                detail: espNetworkDetail,
                isReady: espNetworkReady,
                buttonTitle: espNetworkReady ? "查看" : "配网",
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
            return bleBridge.persistedServerConfigured
                ? "已写入雷达 · 可独立使用"
                : bleBridge.lastWriteEvent
        }
        return "\(status.wifiText) · \(status.serverText)"
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
        bleBridge.startScan()
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
                title: "联网配置",
                detail: bleBridge.persistedServerConfigured ? "已保存到雷达，可独立使用" : "未写入",
                isReady: bleBridge.persistedServerConfigured || (bleBridge.deviceStatus?.server ?? 0) == 1
            )
            if let status = bleBridge.deviceStatus {
                DeviceSetupStatusRow(
                    title: "雷达联网",
                    detail: status.wifiText,
                    isReady: status.wifi == "connected"
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
            InfoRow(label: "权限", value: bleBridge.authorizationText)
            InfoRow(label: "蓝牙", value: bleBridge.stateText)
            InfoRow(label: "雷达", value: bleBridge.connectedPeripheralName)
            RuntimeRow(
                title: "扫描状态",
                phase: bleBridge.isScanning ? .connecting : (bleBridge.selectedPeripheralID == nil ? .idle : .ready),
                detail: scanStatusText
            )

            if bleBridge.candidates.isEmpty {
                Text("未发现雷达。确认雷达已开机并靠近手机；重启后等待十秒再扫描。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            } else {
                ForEach(bleBridge.candidates) { candidate in
                    BLECandidateRow(candidate: candidate)
                }
            }

            HStack(spacing: 10) {
                Button {
                    bleBridge.startScan()
                } label: {
                    Label(bleBridge.isScanning ? "重新扫描" : "开始扫描", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(InkButtonStyle())

                Button {
                    if bleBridge.isScanning {
                        bleBridge.stopScan()
                    } else {
                        bleBridge.disconnect()
                    }
                } label: {
                    Label(bleBridge.isScanning ? "停止" : "断开", systemImage: "xmark.circle")
                }
                .buttonStyle(InkButtonStyle(filled: false))
            }
        }
        .onAppear {
            if !bleBridge.isBLEConnected, !bleBridge.isScanning {
                bleBridge.startScan()
            }
        }
    }

    private var scanStatusText: String {
        if bleBridge.isBLEConnected {
            return "雷达已连接"
        }
        if bleBridge.isScanning {
            return bleBridge.candidates.isEmpty ? "正在查找附近的雷达" : "请选择你的雷达"
        }
        return "未连接"
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
                Text("\(candidate.rssiText) · \(candidate.lastSeenText)")
                    .font(.caption)
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
            StatusChip(text: candidate.isConnectable ? "可连接" : "广播", filled: candidate.isConnectable)
            Button {
                bleBridge.connect(candidate)
            } label: {
                Image(systemName: "link")
                    .font(.headline.weight(.black))
            }
            .buttonStyle(InkIconButtonStyle())
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
            InfoRow(label: "联网配置", value: status?.serverText ?? registrationText)
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

struct PairingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(\.dismiss) private var dismiss
    @State private var pairingPhase: AppOperationPhase = .idle

    private let steps = ["连接雷达", "确认可配置", "绑定账号", "保存网络和房间", "完成"]

    private var canFinish: Bool {
        pairingReadinessError == nil && !pairingPhase.isLoading
    }

    var body: some View {
        NavigationStack {
            List {
                Section("发现雷达") {
                    LabeledContent("蓝牙", value: bleBridge.stateText)
                    LabeledContent("权限", value: bleBridge.authorizationText)
                    LabeledContent("状态", value: pairingScanStatus)
                    if bleBridge.candidates.isEmpty {
                        Text("未发现雷达")
                    } else {
                        ForEach(bleBridge.candidates.prefix(4)) { candidate in
                            Button {
                                bleBridge.connect(candidate)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.name)
                                            .font(.headline.weight(.bold))
                                        Text(candidate.rssiText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "link")
                                }
                            }
                        }
                    }
                }
                Section("系统蓝牙配对") {
                    Label("连接后，iPhone 会弹出系统蓝牙配对窗口。", systemImage: "lock.shield.fill")
                        .font(.subheadline.weight(.bold))
                    Text("请把雷达圆屏上临时显示的 6 位数字输入 iPhone。配对码会自动变化；不要把配对码发给其他人。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LabeledContent(
                        "链路保护",
                        value: bleBridge.deviceStatus?.bleSecurityText ?? "连接雷达后自动检查"
                    )
                }
                Section("绑定流程") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack {
                            Image(systemName: pairingStepPassed(index) ? "checkmark.circle.fill" : "circle.dashed")
                            Text(step)
                        }
                    }
                }
                Section("当前卡点") {
                    LabeledContent("下一步", value: pairingNextStep)
                    if let readinessError = pairingReadinessError {
                        Text(readinessError)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Section("雷达状态") {
                    LabeledContent("连接", value: bleBridge.connectedPeripheralName)
                    LabeledContent("绑定状态", value: bleBridge.registrationText)
                    if let status = bleBridge.deviceStatus {
                        LabeledContent("Wi-Fi", value: status.wifiText)
                        LabeledContent("房间连接", value: status.server == 1 ? "已连接" : "未连接")
                    } else {
                        LabeledContent("雷达", value: bleBridge.isBLEConnected ? "等待状态更新" : "未连接")
                    }
                }
                Section("提交状态") {
                    OperationStatusView(phase: pairingReadinessPhase)
                }
            }
            .navigationTitle("绑定雷达")
            .scrollContentBackground(.hidden)
            .background(MangaBackground())
            .onAppear {
                bleBridge.startScan()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pairingPhase.isLoading ? "绑定中" : "完成") {
                        Task {
                            await finishPairing()
                        }
                    }
                    .disabled(!canFinish)
                }
            }
        }
    }

    @MainActor
    private func finishPairing() async {
        guard !pairingPhase.isLoading else { return }
        if let readinessError = pairingReadinessError {
            bleBridge.refreshCharacteristics()
            pairingPhase = .failed(readinessError)
            return
        }
        guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pairingPhase = .failed("请先创建或加入房间，再绑定雷达。")
            return
        }
        pairingPhase = .loading

        do {
            let device = try await appState.registerDevice(
                pairingChallenge: bleBridge.pairingChallengeText,
                name: bleBridge.connectedPeripheralName == "未连接" ? "Capsule Radar" : bleBridge.connectedPeripheralName
            )
            let pairingWriteStartedAt = Date()
            guard bleBridge.writePairingResponse(device.pairingResponse) else {
                await appState.cancelRegisteredDevice(device)
                pairingPhase = .failed("绑定失败。请重新连接雷达后再试。")
                return
            }
            guard await bleBridge.confirmPairingResponse(startedAt: pairingWriteStartedAt) else {
                await appState.cancelRegisteredDevice(device)
                pairingPhase = .failed("雷达未确认本次绑定，请保持连接后重试。")
                return
            }
            let serverConfigWriteStartedAt = Date()
            guard bleBridge.writeServerConfig(
                relayURL: radarRuntime.relayBaseURL,
                roomToken: appState.inviteCode,
                deviceToken: device.deviceToken
            ) else {
                await appState.cancelRegisteredDevice(device)
                pairingPhase = .failed("配置写入失败。请确认雷达仍然连接，然后重试。")
                return
            }
            guard await bleBridge.confirmServerConfig(
                deviceToken: device.deviceToken,
                startedAt: serverConfigWriteStartedAt
            ) else {
                pairingPhase = .failed("雷达未确认新设备身份，App 未切换到该身份。请保持连接后重试。")
                return
            }
            appState.commitRegisteredDevice(device)
            appState.simulatePairingComplete()
            await radarRuntime.provisionESP(
                deviceName: device.name,
                roomCode: appState.inviteCode
            )
            pairingPhase = .success("雷达已绑定并保存配置")
            try? await Task.sleep(nanoseconds: 450_000_000)
            dismiss()
        } catch {
            pairingPhase = .failed("绑定失败 · \(AppError.userFacingMessage(for: error))")
        }
    }

    private var pairingReadinessPhase: AppOperationPhase {
        if pairingPhase.isLoading { return pairingPhase }
        if case .success = pairingPhase { return pairingPhase }
        if case .failed = pairingPhase { return pairingPhase }
        if let readinessError = pairingReadinessError {
            return .failed(readinessError)
        }
        return .success("已准备绑定雷达")
    }

    private var pairingNextStep: String {
        if !appState.isSignedIn { return "先登录" }
        if bleBridge.stateText != "可用" { return "打开 iPhone 蓝牙" }
        if bleBridge.selectedPeripheralID == nil { return "扫描并连接雷达" }
        if bleBridge.deviceStatus?.bleSecure != 1 { return "完成 iPhone 系统蓝牙配对" }
        if !bleBridge.hasCharacteristic(.pairingResponse) || !bleBridge.hasCharacteristic(.serverConfig) {
            return "等待雷达准备完成"
        }
        if bleBridge.pairingChallengeText == "未读取" { return "等待雷达确认身份" }
        if !bleBridge.isRegistrationComplete { return "点击完成绑定" }
        return "已完成"
    }

    private var pairingReadinessError: String? {
        if !appState.isSignedIn {
            return AppError.notSignedIn.localizedDescription
        }
        if bleBridge.authorizationText == "已拒绝" || bleBridge.stateText == "未授权" {
            return AppError.ble(.unauthorized).localizedDescription
        }
        if bleBridge.stateText == "蓝牙关闭" {
            return AppError.ble(.poweredOff).localizedDescription
        }
        if bleBridge.selectedPeripheralID == nil {
            return AppError.ble(.deviceNotConnected).localizedDescription
        }
        if let status = bleBridge.deviceStatus, status.bleSecure != 1 {
            return "请先在 iPhone 系统配对窗口输入雷达屏幕显示的 6 位数字。"
        }
        if !bleBridge.hasCharacteristic(.pairingResponse) {
            return "雷达还没准备好。请等待几秒，或重新扫描连接雷达。"
        }
        if !bleBridge.hasCharacteristic(.serverConfig) {
            return "雷达还没准备好。请等待几秒，或重新扫描连接雷达。"
        }
        if bleBridge.pairingChallengeText == "未读取" {
            return "雷达还在准备身份确认。请等待几秒，或重新连接雷达。"
        }
        if
            let status = bleBridge.deviceStatus,
            status.paired == 1,
            status.server == 1
        {
            return "这台雷达已经绑定。请返回设备页恢复现有绑定，不要重复创建绑定。"
        }
        return nil
    }

    private var pairingScanStatus: String {
        if bleBridge.isBLEConnected {
            return "雷达已连接"
        }
        if bleBridge.isScanning {
            return bleBridge.candidates.isEmpty ? "正在查找附近的雷达" : "请选择你的雷达"
        }
        return "未连接"
    }

    private func pairingStepPassed(_ index: Int) -> Bool {
        switch index {
        case 0:
            bleBridge.selectedPeripheralID != nil
        case 1:
            RadarBLECharacteristic.requiredProvisioningRoles.allSatisfy { bleBridge.hasCharacteristic($0) }
                && bleBridge.pairingChallengeText != "未读取"
                && bleBridge.deviceStatus?.bleSecure == 1
        case 2:
            bleBridge.persistedPaired || (bleBridge.deviceStatus?.paired ?? 0) == 1 || bleBridge.lastWriteEvent.contains("pairing_response_verified")
        case 3:
            bleBridge.persistedServerConfigured || (bleBridge.deviceStatus?.server ?? 0) == 1 || bleBridge.lastWriteEvent.contains("server_config")
        case 4:
            bleBridge.isRegistrationComplete
        default:
            false
        }
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
            .navigationTitle("Wi-Fi / 热点配置")
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
            writePhase = .failed("雷达未连接，不能写入配网")
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
            writePhase = .failed(userFacingWriteFailure(defaultMessage: "联网配置写入失败"))
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
