import SwiftUI

enum CapsulePairingVisualState: Equatable {
    case scanning
    case discovered
    case connecting
    case ready
    case completing
    case connected
    case failed(String)
}

struct CapsuleRadarPairingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(\.dismiss) private var dismiss

    @State private var pairingPhase: AppOperationPhase = .idle
    @State private var shouldFinishAfterConnection = false
    @State private var didStartPairing = false
    var continueAfterSystemPicker = false

    var body: some View {
        CapsuleRadarPairingCard(
            state: visualState,
            deviceName: displayedDeviceName,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            batteryText: batteryText,
            primaryTitle: primaryTitle,
            primaryDisabled: primaryDisabled,
            primaryAction: primaryAction,
            closeAction: dismiss.callAsFunction
        )
        .presentationDetents([.height(574)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(30)
        .presentationBackground(.white)
        .interactiveDismissDisabled(pairingPhase.isLoading)
        .onAppear {
            if continueAfterSystemPicker {
                shouldFinishAfterConnection = true
            }
            if !continueAfterSystemPicker, !bleBridge.isBLEConnected, !bleBridge.isScanning {
                bleBridge.startScan()
            }
        }
        .onChange(of: canFinishPairing) { _, canFinish in
            guard canFinish, shouldFinishAfterConnection, !didStartPairing else { return }
            Task { await finishPairing() }
        }
        .task(id: visualState) {
            guard visualState == .connected else { return }
            bleBridge.refreshCharacteristics()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, visualState == .connected else { return }
            dismiss()
        }
        .accessibilityIdentifier("devices.pairing.airpodsStyleSheet")
    }

    private var visualState: CapsulePairingVisualState {
        switch pairingPhase {
        case .loading:
            return .completing
        case .success:
            return .connected
        case .failed(let message):
            return .failed(message)
        case .idle:
            break
        }

        if bleBridge.stateText == "蓝牙关闭" {
            return .failed("请先打开 iPhone 蓝牙")
        }
        if bleBridge.authorizationText == "已拒绝" || bleBridge.stateText == "未授权" {
            return .failed("请在“设置”中允许 Capsule Radar 使用蓝牙")
        }
        if bleBridge.isBLEConnected, bleBridge.isRegistrationComplete {
            if appState.devices.isEmpty {
                return .failed("雷达保留着旧绑定，请先在雷达本机恢复后重新绑定")
            }
            return .connected
        }
        if bleBridge.selectedPeripheralID == nil {
            if bleBridge.candidates.first != nil {
                return .discovered
            }
            if bleBridge.scanTimedOut {
                return .failed("没有找到附近的 Capsule Radar")
            }
            return .scanning
        }
        if !bleBridge.isBLEConnected {
            return .connecting
        }
        if !canFinishPairing {
            return .connecting
        }
        return .ready
    }

    private var displayedDeviceName: String {
        if bleBridge.connectedPeripheralName != "未连接" {
            return bleBridge.connectedPeripheralName
        }
        return bleBridge.candidates.first?.name ?? "Capsule Radar"
    }

    private var batteryText: String {
        guard let status = bleBridge.deviceStatus else { return "电量待同步" }
        return status.batteryText == "未上报" ? "电量待同步" : status.batteryText
    }

    private var batteryPercent: Int? {
        bleBridge.deviceStatus?.batteryPercentValue
    }

    private var isCharging: Bool {
        bleBridge.deviceStatus?.battery?.charging == true
    }

    private var primaryTitle: String {
        switch visualState {
        case .scanning:
            return "正在搜索…"
        case .discovered:
            return "连接"
        case .connecting, .completing:
            return "正在连接…"
        case .ready:
            return "连接"
        case .connected:
            return "完成"
        case .failed:
            return requiresLocalBindingReset ? "关闭" : "重试"
        }
    }

    private var primaryDisabled: Bool {
        switch visualState {
        case .scanning, .connecting, .completing:
            return true
        case .discovered, .ready, .connected, .failed:
            return false
        }
    }

    private var canFinishPairing: Bool {
        pairingReadinessError == nil && !pairingPhase.isLoading
    }

    private func primaryAction() {
        switch visualState {
        case .discovered:
            guard let candidate = bleBridge.candidates.first else {
                bleBridge.startScan()
                return
            }
            shouldFinishAfterConnection = true
            bleBridge.connect(candidate)
        case .connected:
            dismiss()
        case .ready:
            shouldFinishAfterConnection = true
            Task { await finishPairing() }
        case .failed:
            if requiresLocalBindingReset {
                dismiss()
                return
            }
            pairingPhase = .idle
            didStartPairing = false
            shouldFinishAfterConnection = false
            if bleBridge.isBLEConnected {
                bleBridge.refreshCharacteristics()
            } else {
                bleBridge.startScan()
            }
        case .scanning, .connecting, .completing:
            break
        }
    }

    private var requiresLocalBindingReset: Bool {
        appState.devices.isEmpty && bleBridge.isRegistrationComplete
    }

    @MainActor
    private func finishPairing() async {
        guard !didStartPairing, !pairingPhase.isLoading else { return }
        guard pairingReadinessError == nil else { return }
        guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pairingPhase = .failed("请先创建或加入房间，再连接雷达")
            return
        }

        didStartPairing = true
        pairingPhase = .loading

        do {
            let device = try await appState.registerDevice(
                pairingChallenge: bleBridge.pairingChallengeText,
                name: displayedDeviceName
            )
            let pairingWriteStartedAt = Date()
            guard bleBridge.writePairingResponse(device.pairingResponse) else {
                await appState.cancelRegisteredDevice(device)
                throw CapsulePairingFailure("绑定失败，请重新连接雷达后再试")
            }
            guard await bleBridge.confirmPairingResponse(startedAt: pairingWriteStartedAt) else {
                await appState.cancelRegisteredDevice(device)
                throw CapsulePairingFailure("雷达没有确认本次绑定，请保持设备靠近后重试")
            }

            let serverConfigWriteStartedAt = Date()
            guard bleBridge.writeServerConfig(
                relayURL: radarRuntime.relayBaseURL,
                roomToken: appState.inviteCode,
                deviceToken: device.deviceToken
            ) else {
                await appState.cancelRegisteredDevice(device)
                throw CapsulePairingFailure("配置写入失败，请确认雷达仍然连接")
            }
            guard await bleBridge.confirmServerConfig(
                deviceToken: device.deviceToken,
                startedAt: serverConfigWriteStartedAt
            ) else {
                throw CapsulePairingFailure("雷达没有确认新设备身份，请保持连接后重试")
            }

            appState.commitRegisteredDevice(device)
            appState.simulatePairingComplete()
            await radarRuntime.provisionESP(
                deviceName: device.name,
                roomCode: appState.inviteCode
            )
            pairingPhase = .success("已连接")
        } catch let error as CapsulePairingFailure {
            pairingPhase = .failed(error.message)
            didStartPairing = false
        } catch {
            pairingPhase = .failed("连接失败 · \(AppError.userFacingMessage(for: error))")
            didStartPairing = false
        }
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
        if bleBridge.selectedPeripheralID == nil || !bleBridge.isBLEConnected {
            return AppError.ble(.deviceNotConnected).localizedDescription
        }
        if let status = bleBridge.deviceStatus, status.bleSecure != 1 {
            return "请在系统配对窗口输入雷达屏幕显示的 6 位数字"
        }
        if !bleBridge.hasCharacteristic(.pairingResponse)
            || !bleBridge.hasCharacteristic(.serverConfig)
            || bleBridge.pairingChallengeText == "未读取" {
            return "正在等待雷达准备完成"
        }
        if
            let status = bleBridge.deviceStatus,
            status.paired == 1,
            status.server == 1
        {
            return appState.devices.isEmpty
                ? "雷达保留着旧绑定，请先在雷达本机恢复后重新绑定"
                : "这台雷达已经绑定"
        }
        return nil
    }
}

private struct CapsulePairingFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

struct CapsuleRadarPairingCard: View {
    var state: CapsulePairingVisualState
    var deviceName: String
    var batteryPercent: Int?
    var isCharging: Bool
    var batteryText: String
    var primaryTitle: String
    var primaryDisabled: Bool
    var primaryAction: () -> Void
    var closeAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var productFloating = false
    @State private var productTurned = false
    @State private var screenVisible = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .systemGray5), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            CapsuleRadarProductAnimation(
                isFloating: productFloating,
                isTurned: productTurned,
                screenVisible: screenVisible,
                isBusy: state == .connecting || state == .completing
            )
            .frame(height: 284)
            .padding(.top, -8)

            Text("Capsule Radar")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            stateLine
                .frame(minHeight: 44, alignment: .top)
                .padding(.top, 5)
                .padding(.horizontal, 28)

            CapsuleBatteryStatus(
                percent: batteryPercent,
                isCharging: isCharging,
                detail: batteryText
            )
            .padding(.top, 3)

            Spacer(minLength: 10)

            Group {
                if state == .connected {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark")
                        Text("设置完成，正在关闭…")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .background(
                        Color(uiColor: .systemGray6),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .accessibilityLabel("设置完成，窗口即将自动关闭")
                } else {
                    Button(action: primaryAction) {
                        HStack(spacing: 9) {
                            if state == .connecting || state == .completing {
                                ProgressView()
                                    .tint(.white)
                                    .controlSize(.small)
                            }
                            Text(primaryTitle)
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(
                        primaryDisabled ? Color(uiColor: .systemGray3) : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .disabled(primaryDisabled)
                    .accessibilityIdentifier("devices.pairing.primaryAction")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .onAppear {
            guard !reduceMotion else {
                screenVisible = true
                return
            }
            withAnimation(.easeOut(duration: 0.55)) {
                screenVisible = true
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                productFloating = true
            }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                productTurned = true
            }
        }
        .onChange(of: state) { _, newState in
            guard !reduceMotion else { return }
            if newState == .connected {
                screenVisible = false
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72).delay(0.12)) {
                    screenVisible = true
                }
            }
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        switch state {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在搜索附近的雷达…")
            }
            .font(.system(size: 16))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
        case .discovered:
            Text(deviceName)
                .font(.system(size: 16))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        case .connecting:
            Text("按雷达屏幕提示完成系统蓝牙配对")
                .font(.system(size: 15))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        case .ready:
            Text(deviceName)
                .font(.system(size: 16))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        case .completing:
            Text("正在完成设置…")
                .font(.system(size: 16))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        case .connected:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("已连接")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 16))
        case .failed(let message):
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
}

private struct CapsuleBatteryStatus: View {
    var percent: Int?
    var isCharging: Bool
    var detail: String

    private var symbolName: String {
        if isCharging {
            return "bolt.fill"
        }
        guard let percent else {
            return "battery.0percent"
        }
        switch percent {
        case 76...:
            return "battery.100percent"
        case 51...:
            return "battery.75percent"
        case 26...:
            return "battery.50percent"
        case 11...:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
    }

    private var tint: Color {
        if isCharging {
            return .green
        }
        guard let percent else {
            return Color(uiColor: .tertiaryLabel)
        }
        return percent <= 20 ? .red : .green
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
            Text(percent.map { "电量 \($0)%" } ?? detail)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            if isCharging {
                Text("充电中")
                    .foregroundStyle(tint)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(uiColor: .systemGray6), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct CapsuleRadarProductAnimation: View {
    var isFloating: Bool
    var isTurned: Bool
    var screenVisible: Bool
    var isBusy: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Image("CapsuleRadarPairingProduct")
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)

                Image("CapsuleRadarBootScreen")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: side * 0.505, height: side * 0.505)
                    .clipShape(Circle())
                    .offset(y: -side * 0.002)
                    .opacity(screenVisible ? 1 : 0)
                    .scaleEffect(screenVisible ? 1 : 0.94)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(isFloating ? 1.015 : 0.985)
            .offset(y: isFloating ? -4 : 3)
            .rotation3DEffect(
                .degrees(isTurned ? 8 : -8),
                axis: (x: 0.08, y: 1, z: 0),
                anchor: .center,
                perspective: 0.18
            )
            .rotationEffect(.degrees(isTurned ? 0.8 : -0.8))
            .opacity(isBusy ? 0.88 : 1)
            .animation(.easeInOut(duration: 0.65), value: isBusy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ESP32-S3 Touch AMOLED 1.75C 雷达")
    }
}

#Preview("AirPods style · discovered") {
    CapsuleRadarPairingCard(
        state: .discovered,
        deviceName: "CapsuleRadar-F2A0",
        batteryPercent: 86,
        isCharging: false,
        batteryText: "86%",
        primaryTitle: "连接",
        primaryDisabled: false,
        primaryAction: {},
        closeAction: {}
    )
    .frame(width: 393, height: 574)
}

#Preview("AirPods style · connected") {
    CapsuleRadarPairingCard(
        state: .connected,
        deviceName: "CapsuleRadar-F2A0",
        batteryPercent: 86,
        isCharging: false,
        batteryText: "86%",
        primaryTitle: "完成",
        primaryDisabled: false,
        primaryAction: {},
        closeAction: {}
    )
    .frame(width: 393, height: 574)
}
