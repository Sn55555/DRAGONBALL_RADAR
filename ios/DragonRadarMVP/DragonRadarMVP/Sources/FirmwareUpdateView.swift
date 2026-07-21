import SwiftUI

struct FirmwareUpdateView: View {
    @Environment(AppState.self) private var appState
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(FirmwareUpdateCoordinator.self) private var firmwareUpdate
    @State private var showingConfirmation = false
    @State private var showingWifiConfiguration = false
    @State private var ownerSessionRecoveryInFlight = false
    @State private var ownerSessionRecoveryDetail = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                currentFirmwarePanel
                updatePanel
                readinessPanel
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("固件更新")
        .task {
            await refreshOTAState()
        }
        .task(id: ownerSessionRecoveryID) {
            await recoverOwnerSessionIfNeeded()
        }
        .confirmationDialog(
            "确认更新雷达固件？",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("开始更新") {
                firmwareUpdate.startUpdate(bleBridge: bleBridge)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
        .sheet(isPresented: $showingWifiConfiguration) {
            WifiConfigSheet {
                firmwareUpdate.startUpdate(bleBridge: bleBridge)
            }
        }
        .accessibilityIdentifier("devices.firmware.update")
    }

    private var currentFirmwarePanel: some View {
        MangaPanel("当前固件") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bleBridge.reportedFirmwareVersion ?? "版本未上报")
                        .font(.title2.weight(.black))
                    Text("硬件 \(bleBridge.reportedHardware ?? "未上报")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                Spacer()
                StatusChip(
                    text: bleBridge.bleSecurityRepairRequired
                        ? "需要重新配对"
                        : (bleBridge.supportsFirmwareOTA ? "支持无线更新" : "需要初始化"),
                    filled: bleBridge.supportsFirmwareOTA && !bleBridge.bleSecurityRepairRequired
                )
            }

            InfoRow(label: "构建号", value: currentBuildText)
            InfoRow(label: "安全计数器", value: bleBridge.deviceStatus?.securityCounter.map(String.init) ?? "未上报")
            InfoRow(label: "更新通道", value: "stable")
            InfoRow(label: "最近读取", value: lastStatusText)
        }
    }

    private var updatePanel: some View {
        MangaPanel("检查与更新") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(phaseTitle)
                        .font(.headline.weight(.black))
                    Text(firmwareUpdate.detail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                Spacer()
                StatusChip(text: phaseChip, filled: phaseReady)
            }

            if let release = firmwareUpdate.availableRelease {
                InfoRow(label: "可用版本", value: "\(release.manifest.version)（\(release.manifest.build)）")
                InfoRow(label: "固件大小", value: release.manifest.formattedSize)
                InfoRow(label: "最低基线", value: release.manifest.minimumVersion)
                InfoRow(label: "签名", value: "ECDSA P-256 · 已验证")
                if let notes = release.manifest.releaseNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
            }

            if firmwareUpdate.phase.isBusy || firmwareUpdate.progress > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(firmwareUpdate.progress), total: 100)
                        .tint(MangaTheme.ink)
                    Text("\(firmwareUpdate.progress)% · \(progressDetail)")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(MangaTheme.subtle)
                }
                .accessibilityIdentifier("devices.firmware.progress")
            }

            if firmwareUpdate.phase == .bootstrapRequired || (!bleBridge.supportsFirmwareOTA && firmwareUpdate.availableRelease != nil) {
                Text("这台雷达的旧分区/旧协议无法安全接收 OTA。请先通过 USB 刷入支持双分区、107/108 通道和回滚确认的新固件；以后即可在这里无线更新。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .padding(10)
                    .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(MangaTheme.ink, lineWidth: 1.2))
                    .accessibilityIdentifier("devices.firmware.bootstrap.required")
            }

            actionButtons
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            Task {
                await refreshOTAState()
                await firmwareUpdate.checkForUpdates(
                    accessToken: appState.accessToken,
                    deviceStatus: bleBridge.deviceStatus
                )
            }
        } label: {
            Label(firmwareUpdate.phase == .checking ? "正在检查" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(InkButtonStyle(filled: firmwareUpdate.phase != .available))
        .disabled(firmwareUpdate.phase.isBusy || bleBridge.bleSecurityRepairRequired)
        .accessibilityIdentifier("devices.firmware.check")

        if firmwareUpdate.phase == .available {
            Button {
                if needsInitialOTANetworkConfiguration {
                    showingWifiConfiguration = true
                } else {
                    showingConfirmation = true
                }
            } label: {
                Label(
                    needsInitialOTANetworkConfiguration ? "设置 OTA 网络并继续" : "安装已验证更新",
                    systemImage: needsInitialOTANetworkConfiguration ? "wifi" : "arrow.down.circle.fill"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle())
            .disabled(!canStartUpdate)
            .accessibilityIdentifier("devices.firmware.install")
        }

        if firmwareUpdate.phase == .failed || firmwareUpdate.phase == .rolledBack {
            Button {
                firmwareUpdate.retry(bleBridge: bleBridge)
            } label: {
                Label("重试更新", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle())
            .disabled(firmwareUpdate.availableRelease == nil || !canStartUpdate)
            .accessibilityIdentifier("devices.firmware.retry")
        }

        if [.sending, .canceling, .downloading, .verifying].contains(firmwareUpdate.phase) {
            Button {
                firmwareUpdate.cancel(bleBridge: bleBridge)
            } label: {
                Label(
                    firmwareUpdate.phase == .canceling ? "等待取消确认" : "取消更新",
                    systemImage: "xmark.circle"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle(filled: false))
            .disabled(firmwareUpdate.phase == .canceling)
        }

        if firmwareUpdate.phase == .sending, bleBridge.deviceStatus?.wifi != "connected" {
            Button {
                showingWifiConfiguration = true
            } label: {
                Label("更换 OTA 网络并自动重试", systemImage: "wifi.exclamationmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle(filled: false))
            .accessibilityIdentifier("devices.firmware.network.retry")
        }

        Button {
            Task {
                await refreshOTAState()
                if bleBridge.ownerSessionAuthorized || bleBridge.deviceStatus?.ownerAuthRequired != 1 {
                    _ = bleBridge.writeFirmwareAction("status")
                }
            }
        } label: {
            Label("重新读取雷达状态", systemImage: "wave.3.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(InkButtonStyle(filled: false))
        .disabled(!bleBridge.isBLEConnected)
    }

    private var readinessPanel: some View {
        MangaPanel("更新条件") {
            FirmwareGateRow(title: "配置连接", detail: bleBridge.isBLEConnected ? "雷达已连接" : "请先连接附近雷达", passed: bleBridge.isBLEConnected)
            FirmwareGateRow(
                title: "蓝牙安全连接",
                detail: bleSecurityGateDetail,
                passed: !bleBridge.bleSecurityRepairRequired && bleBridge.deviceStatus?.bleSecure == 1
            )
            FirmwareGateRow(title: "OTA 通道", detail: bleBridge.supportsFirmwareOTA ? "107 控制与 108 状态可用" : "旧固件需 USB 初始化", passed: bleBridge.supportsFirmwareOTA)
            FirmwareGateRow(title: "绑定与凭证", detail: provisioningGateDetail, passed: bleBridge.deviceStatus?.isOTAProvisioningReady == true)
            FirmwareGateRow(title: "所有者会话", detail: ownerSessionGateDetail, passed: ownerSessionGatePassed)
            FirmwareGateRow(title: "更新源", detail: originGateDetail, passed: bleBridge.deviceStatus?.isOTAOriginConfirmed == true)
            FirmwareGateRow(title: "硬件型号", detail: hardwareGateDetail, passed: hardwareGatePassed)
            FirmwareGateRow(title: "更新网络", detail: otaNetworkGateDetail, passed: otaNetworkGatePassed)
            FirmwareGateRow(title: "电量", detail: batteryGateDetail, passed: batteryGatePassed)
            FirmwareGateRow(title: "升级基线", detail: baselineGateDetail, passed: baselineGatePassed)
            FirmwareGateRow(title: "防降级", detail: releaseGateDetail, passed: releaseGatePassed)

            if ownerSessionRecoveryDetail.contains("不匹配") {
                Divider()
                    .overlay(MangaTheme.ink.opacity(0.25))
                VStack(alignment: .leading, spacing: 6) {
                    Label("需要在雷达上确认恢复绑定", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.black))
                    Text("短按雷达侧键打开菜单，滑动到 RST，点按进入后在圆屏中央持续按住 4 秒。雷达会清除原所有者、Wi-Fi 和房间配置并重启，然后回到“设备 → 绑定雷达”重新配置。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                    Text("恢复必须在雷达本机完成，附近用户不能仅通过蓝牙强制解绑。")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
            }
        }
    }

    private var currentBuildText: String {
        (bleBridge.deviceStatus?.firmwareBuild ?? bleBridge.firmwareStatus?.build).map(String.init) ?? "未上报"
    }

    private var lastStatusText: String {
        guard let date = bleBridge.lastFirmwareStatusAt ?? bleBridge.lastDeviceStatusAt else { return "未读取" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private var batteryGatePassed: Bool {
        bleBridge.deviceStatus?.isOTAPowerReady == true
    }

    private var batteryGateDetail: String {
        if bleBridge.deviceStatus?.battery?.charging == true {
            let percent = bleBridge.deviceStatus?.batteryPercentValue.map { "\($0)% · " } ?? ""
            return "\(percent)充电中 · 可以更新"
        }
        guard let battery = bleBridge.deviceStatus?.batteryPercentValue else { return "未上报，暂不允许更新" }
        return battery >= 30 ? "\(battery)% · 可以更新" : "\(battery)% · 至少需要 30%，或连接电源"
    }

    private var hardwareGatePassed: Bool {
        bleBridge.reportedHardware == FirmwareManifestVerifier.expectedHardware
    }

    private var ownerSessionGatePassed: Bool {
        bleBridge.deviceStatus?.ownerAuthRequired != 1 || bleBridge.ownerSessionAuthorized
    }

    private var ownerSessionGateDetail: String {
        if bleBridge.deviceStatus?.ownerAuthRequired != 1 { return "当前固件不要求会话证明" }
        if bleBridge.ownerSessionAuthorized { return "当前连接已由设备凭证确认" }
        if ownerSessionRecoveryInFlight { return "正在确认当前账号下的雷达凭证" }
        if !ownerSessionRecoveryDetail.isEmpty { return ownerSessionRecoveryDetail }
        return "等待确认当前连接的设备凭证"
    }

    private var ownerSessionRecoveryID: String {
        let status = bleBridge.deviceStatus
        return [
            bleBridge.pairingChallengeText,
            String(status?.paired ?? -1),
            String(status?.ownerAuthRequired ?? -1),
            String(status?.ownerAuth ?? -1),
        ].joined(separator: "|")
    }

    @MainActor
    private func recoverOwnerSessionIfNeeded() async {
        guard
            appState.isSignedIn,
            bleBridge.deviceStatus?.paired == 1,
            bleBridge.deviceStatus?.ownerAuthRequired == 1,
            !bleBridge.ownerSessionAuthorized,
            bleBridge.pairingChallengeText.hasPrefix("CR-"),
            !ownerSessionRecoveryInFlight
        else { return }

        ownerSessionRecoveryInFlight = true
        ownerSessionRecoveryDetail = ""
        defer { ownerSessionRecoveryInFlight = false }

        do {
            let devices = try await appState.devicesRepository.listDevices()
            guard !devices.isEmpty else {
                ownerSessionRecoveryDetail = "当前账号没有已绑定的雷达凭证"
                return
            }

            let activeDeviceID = appState.devicesStore.activeDevice?.deviceID
            let orderedDevices = devices.sorted { lhs, rhs in
                lhs.deviceID == activeDeviceID && rhs.deviceID != activeDeviceID
            }
            guard let matchedToken = await bleBridge.recoverOwnerSession(
                deviceTokens: orderedDevices.map(\.deviceToken)
            ), let matchedDevice = orderedDevices.first(where: { $0.deviceToken == matchedToken }) else {
                ownerSessionRecoveryDetail = "当前账号的雷达凭证与这台 ESP 不匹配，请重新绑定"
                return
            }

            appState.devicesStore.applyServerDevice(matchedDevice)
            ownerSessionRecoveryDetail = "当前连接已由设备凭证确认"
            synchronizeOTAOriginIfNeeded()
            firmwareUpdate.refreshFromDevice(bleBridge: bleBridge)
        } catch {
            ownerSessionRecoveryDetail = "无法从服务器读取雷达凭证，请检查账号和网络"
        }
    }

    private var hardwareGateDetail: String {
        bleBridge.reportedHardware ?? "未上报，暂不允许更新"
    }

    private var baselineGatePassed: Bool {
        guard
            let release = firmwareUpdate.availableRelease,
            let currentText = bleBridge.reportedFirmwareVersion,
            let current = FirmwareSemanticVersion(currentText),
            let minimum = release.manifest.minimumSemanticVersion
        else { return false }
        return current >= minimum
    }

    private var baselineGateDetail: String {
        guard let release = firmwareUpdate.availableRelease else { return "检查更新后确认" }
        return baselineGatePassed ? "满足最低版本 \(release.manifest.minimumVersion)" : "低于或无法确认 \(release.manifest.minimumVersion)"
    }

    private var provisioningGateDetail: String {
        guard let status = bleBridge.deviceStatus else { return "状态未上报" }
        if status.isOTAProvisioningReady { return "已绑定，服务器凭证已配置" }
        if status.paired != 1 { return "雷达尚未绑定" }
        return "服务器/设备凭证尚未配置"
    }

    private var originGateDetail: String {
        if bleBridge.deviceStatus?.isOTAOriginConfirmed == true {
            return "更新源已同源绑定"
        }
        if bleBridge.hasCharacteristic(.serverConfig) {
            return "正在等待雷达确认 HTTP API 更新源"
        }
        return "请重新连接雷达并同步服务器配置"
    }

    private var releaseGatePassed: Bool {
        guard
            let manifest = firmwareUpdate.availableRelease?.manifest,
            let currentBuild = bleBridge.deviceStatus?.firmwareBuild ?? bleBridge.firmwareStatus?.build
        else { return false }
        let buildPassed = manifest.build > currentBuild
        let securityPassed = bleBridge.deviceStatus?.securityCounter.map { manifest.securityCounter >= $0 } ?? true
        return buildPassed && securityPassed
    }

    private var releaseGateDetail: String {
        guard let manifest = firmwareUpdate.availableRelease?.manifest else { return "检查更新后确认" }
        let currentBuild = bleBridge.deviceStatus?.firmwareBuild ?? bleBridge.firmwareStatus?.build
        if let currentBuild, manifest.build <= currentBuild {
            return "目标构建 \(manifest.build) 必须大于当前 \(currentBuild)"
        }
        if let currentSecurity = bleBridge.deviceStatus?.securityCounter, manifest.securityCounter < currentSecurity {
            return "目标安全计数器 \(manifest.securityCounter) 低于当前 \(currentSecurity)"
        }
        return "构建号与安全计数器单调递增"
    }

    private var canStartUpdate: Bool {
        bleBridge.isBLEConnected
            && !bleBridge.bleSecurityRepairRequired
            && bleBridge.supportsFirmwareOTA
            && bleBridge.deviceStatus?.isOTAProvisioningReady == true
            && ownerSessionGatePassed
            && bleBridge.deviceStatus?.isOTAOriginConfirmed == true
            && hardwareGatePassed
            && batteryGatePassed
            && baselineGatePassed
            && releaseGatePassed
    }

    private var phaseTitle: String {
        switch firmwareUpdate.phase {
        case .idle: "准备检查"
        case .checking: "正在验证发布清单"
        case .upToDate: "已经是最新版本"
        case .available: "发现可用更新"
        case .sending: "等待雷达接收"
        case .canceling: "等待雷达确认取消"
        case .downloading: "正在下载"
        case .verifying: "正在验证固件"
        case .installing: "正在安装"
        case .rebooting: "正在重启确认"
        case .succeeded: "更新完成"
        case .failed: "更新失败"
        case .bootstrapRequired: "需要 USB 初始化"
        case .rolledBack: "已安全回滚"
        case .canceled: "更新已取消"
        }
    }

    private var phaseChip: String {
        switch firmwareUpdate.phase {
        case .succeeded, .upToDate: "已完成"
        case .available: "可更新"
        case .failed, .rolledBack: "需处理"
        case .bootstrapRequired: "USB"
        case .idle, .canceled: "待检查"
        default: "进行中"
        }
    }

    private var phaseReady: Bool {
        [.succeeded, .upToDate].contains(firmwareUpdate.phase)
    }

    private var progressDetail: String {
        guard
            let received = bleBridge.firmwareStatus?.receivedBytes,
            let total = bleBridge.firmwareStatus?.totalBytes,
            total > 0
        else { return firmwareUpdate.detail }
        let receivedText = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return "\(receivedText) / \(totalText)"
    }

    private var confirmationText: String {
        guard let release = firmwareUpdate.availableRelease else { return "将开始无线更新。" }
        let network = recordedOTANetworkName.map { "雷达会临时连接“\($0)”下载固件。" } ?? "雷达会临时连接 OTA 网络下载固件。"
        return "将安装 \(release.manifest.version)（\(release.manifest.formattedSize)）。清单签名已验证。\(network)更新时保持雷达供电并靠近手机。"
    }

    private var recordedOTANetworkName: String? {
        guard let name = appState.activeDevice?.wifiName.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        guard !name.isEmpty, name != "未同步", name != "未配置" else { return nil }
        return name
    }

    private var needsInitialOTANetworkConfiguration: Bool {
        bleBridge.deviceStatus?.wifi != "connected" && recordedOTANetworkName == nil
    }

    private var otaNetworkGatePassed: Bool {
        bleBridge.deviceStatus?.wifi == "connected" || recordedOTANetworkName != nil
    }

    private var otaNetworkGateDetail: String {
        if let status = bleBridge.deviceStatus, status.wifi == "connected" {
            return status.wifiText
        }
        if firmwareUpdate.phase == .sending {
            let network = recordedOTANetworkName.map { "“\($0)”" } ?? "已保存的网络"
            return "正在连接 \(network)；请保持热点或 Wi-Fi 开启"
        }
        if let network = recordedOTANetworkName {
            return "已保存“\(network)”；开始更新后雷达会临时联网"
        }
        return "尚未保存；安装前设置一次 Wi-Fi 或个人热点"
    }

    private func synchronizeOTAOriginIfNeeded() {
        guard let status = bleBridge.deviceStatus else { return }
        guard status.isOTAOriginConfirmed != true else { return }
        guard status.ownerAuthRequired != 1 || bleBridge.ownerSessionAuthorized else { return }
        let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceToken = appState.activeDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !roomCode.isEmpty,
            !deviceToken.isEmpty,
            bleBridge.hasCharacteristic(.serverConfig)
        else { return }
        _ = bleBridge.writeServerConfig(
            relayURL: radarRuntime.relayBaseURL,
            roomToken: roomCode,
            deviceToken: deviceToken
        )
    }

    @MainActor
    private func refreshOTAState() async {
        await bleBridge.refreshOTAReadiness()
        if bleBridge.bleSecurityRepairRequired {
            firmwareUpdate.handleDeviceReadinessFailure(bleBridge.bleSecurityRepairText)
            return
        }
        await recoverOwnerSessionIfNeeded()
        synchronizeOTAOriginIfNeeded()
        firmwareUpdate.refreshFromDevice(bleBridge: bleBridge)
    }

    private var bleSecurityGateDetail: String {
        if bleBridge.bleSecurityRepairRequired {
            return bleBridge.bleSecurityRepairText
        }
        if bleBridge.deviceStatus?.bleSecure == 1 {
            return "系统加密配对已完成"
        }
        return "等待系统安全配对"
    }
}

private struct FirmwareGateRow: View {
    var title: String
    var detail: String
    var passed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.headline.weight(.black))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.black))
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct FirmwareSummaryRow: View {
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(FirmwareUpdateCoordinator.self) private var firmwareUpdate

    var body: some View {
        NavigationLink {
            FirmwareUpdateView()
        } label: {
            DeviceMenuRow(
                symbol: "memorychip",
                title: "固件更新",
                detail: summary
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("devices.firmware.open")
    }

    private var summary: String {
        if firmwareUpdate.phase.isBusy { return "更新进行中 · \(firmwareUpdate.progress)%" }
        if let version = bleBridge.reportedFirmwareVersion { return "当前 \(version) · 检查签名更新" }
        return "读取当前版本并检查签名更新"
    }
}
