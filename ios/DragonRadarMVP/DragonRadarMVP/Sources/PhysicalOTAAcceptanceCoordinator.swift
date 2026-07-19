#if DEBUG
import CoreBluetooth
import Foundation

/// Explicitly launched, Debug-only hardware acceptance for the real
/// iPhone -> CoreBluetooth -> ESP -> Relay OTA path.
///
/// The normal app never runs this coordinator. It is enabled only when the
/// process is launched with `DRAGON_RADAR_PHYSICAL_OTA_ACCEPTANCE`.
@MainActor
enum PhysicalOTAAcceptanceCoordinator {
    private static var didStart = false
    private static let targetRadarName = "CapsuleRadar-F2A0"
    private static let targetVersion = "1.0.7"
    private static let targetBuild = 9
    private static let targetSecurityCounter = 9

    static func run(
        appState: AppState,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime,
        firmwareUpdate: FirmwareUpdateCoordinator
    ) async {
        guard !didStart else { return }
        didStart = true

        do {
            try await execute(
                appState: appState,
                bleBridge: bleBridge,
                radarRuntime: radarRuntime,
                firmwareUpdate: firmwareUpdate
            )
            log("RESULT", "success version=\(targetVersion) build=\(targetBuild) security_counter=\(targetSecurityCounter)")
        } catch {
            log("RESULT", "failed error=\(sanitized(error.localizedDescription))")
        }
    }

    private static func execute(
        appState: AppState,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime,
        firmwareUpdate: FirmwareUpdateCoordinator
    ) async throws {
        log("START", "transport=physical_corebluetooth")
        appState.selectedTab = .devices

        await appState.restoreSessionIfNeeded()
        if !appState.isSignedIn {
            let result = await appState.signInForDevelopmentAndWait()
            guard result.succeeded else { throw AcceptanceError.state(result.message) }
            log("AUTH", "development_user_signed_in")
            await appState.refreshRoomsFromServer()
            await appState.refreshDevicesFromServer()
        }
        guard appState.isSignedIn, !appState.accessToken.isEmpty else {
            throw AcceptanceError.state("当前 App 没有可用登录会话，已停止实机 OTA")
        }
        guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AcceptanceError.state("当前账号没有活动房间")
        }
        log("AUTH", "ready room_configured=true")

        do {
            try await wait(seconds: 30, description: "iPhone 蓝牙进入可用状态") {
                bleBridge.centralState == .poweredOn
            }
        } catch {
            throw AcceptanceError.state(
                "iPhone 蓝牙不可用，CoreBluetooth state=\(bleBridge.centralState.rawValue)"
            )
        }
        bleBridge.startScan()
        try await wait(seconds: 25, description: "发现实体 ESP") {
            bleBridge.candidates.contains { $0.name == targetRadarName }
        }
        guard let candidate = bleBridge.candidates.first(where: { $0.name == targetRadarName }) else {
            throw AcceptanceError.state("未找到目标雷达")
        }
        log("BLE", "discovered name=\(targetRadarName) rssi=\(candidate.rssi)")
        bleBridge.connect(candidate)

        try await wait(seconds: 30, description: "读取实体 ESP 的 101-108 GATT 通道") {
            bleBridge.isBLEConnected
                && RadarBLECharacteristic.allCases.allSatisfy { bleBridge.hasCharacteristic($0) }
                && bleBridge.pairingChallengeText.hasPrefix("CR-")
                && bleBridge.deviceStatus != nil
        }
        log("BLE", "connected characteristics=8")

        guard let initialStatus = bleBridge.deviceStatus else {
            throw AcceptanceError.state("雷达状态未上报")
        }
        if initialStatus.server == 1 {
            try await authorizeConfiguredDevice(appState: appState, bleBridge: bleBridge)
        } else {
            // A half-configured ESP can still accept a fresh v2 pairing response.
            // Clear any stale server token first so it cannot replace that one-time
            // authorization with an unverifiable v1 proof.
            bleBridge.configureOwnerSession(deviceToken: "")
            try await Task.sleep(for: .milliseconds(750))
            try await recoverAndProvision(
                appState: appState,
                bleBridge: bleBridge,
                radarRuntime: radarRuntime
            )
        }

        try await wait(seconds: 35, description: "确认绑定、服务器、更新源和所有者会话") {
            isFullyProvisioned(bleBridge)
        }
        guard let readyStatus = bleBridge.deviceStatus else {
            throw AcceptanceError.state("雷达状态未上报")
        }
        log(
            "READY",
            "fw=\(readyStatus.firmwareVersion ?? "unknown") build=\(readyStatus.firmwareBuild ?? -1) wifi=\(readyStatus.wifi) server=\(readyStatus.server) ota_origin=\(readyStatus.otaOrigin ?? 0) owner_auth=\(readyStatus.ownerAuth ?? 0) status_bytes=\(bleBridge.deviceStatusText.utf8.count)"
        )

        await firmwareUpdate.checkForUpdates(
            accessToken: appState.accessToken,
            deviceStatus: readyStatus
        )
        if isExactTarget(readyStatus) {
            let firmwareReadStartedAt = Date()
            bleBridge.readFirmwareStatus()
            try await wait(seconds: 15, description: "读取已安装目标固件的 108 当前状态") {
                guard
                    let statusAt = bleBridge.lastFirmwareStatusAt,
                    statusAt >= firmwareReadStartedAt
                else { return false }
                return isExactInstalledFirmwareStatus(bleBridge.firmwareStatus)
            }
            firmwareUpdate.synchronize(
                status: bleBridge.firmwareStatus,
                deviceStatus: bleBridge.deviceStatus
            )
            let stage = bleBridge.firmwareStatus?.stage.lowercased() ?? "unknown"
            log("OTA", "already_installed exact_device_and_status_verified stage=\(stage)")
            return
        }
        guard firmwareUpdate.phase == .available, let release = firmwareUpdate.availableRelease else {
            throw AcceptanceError.state("服务器未提供可安装更新：\(firmwareUpdate.detail)")
        }
        guard
            release.manifest.version == targetVersion,
            release.manifest.build == targetBuild,
            release.manifest.securityCounter == targetSecurityCounter
        else {
            throw AcceptanceError.state("服务器目标固件与验收目标不一致")
        }
        log(
            "MANIFEST",
            "verified version=\(release.manifest.version) build=\(release.manifest.build) size=\(release.manifest.size)"
        )

        bleBridge.setFirmwareReconnectTracking(true)
        firmwareUpdate.startUpdate(bleBridge: bleBridge)
        guard firmwareUpdate.phase == .sending else {
            throw AcceptanceError.state("App 未能发送 OTA 控制：\(firmwareUpdate.detail)")
        }
        log("OTA", "command_sent")

        try await monitorOTA(bleBridge: bleBridge, firmwareUpdate: firmwareUpdate)
        try await wait(seconds: 45, description: "确认目标固件及 108 success") {
            let device = bleBridge.deviceStatus
            let ota = bleBridge.firmwareStatus
            return firmwareUpdate.phase == .succeeded
                && device?.firmwareVersion == targetVersion
                && device?.firmwareBuild == targetBuild
                && device?.securityCounter == targetSecurityCounter
                && ota?.stage.lowercased() == "success"
                && ota?.firmwareVersion == targetVersion
                && ota?.build == targetBuild
                && ota?.targetVersion == targetVersion
                && ota?.targetBuild == targetBuild
        }
    }

    private static func recoverAndProvision(
        appState: AppState,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime
    ) async throws {
        let device = try await appState.registerDevice(
            pairingChallenge: bleBridge.pairingChallengeText,
            name: targetRadarName
        )
        let pairingWriteStartedAt = Date()
        guard bleBridge.writePairingResponse(device.pairingResponse) else {
            await appState.cancelRegisteredDevice(device)
            throw AcceptanceError.state("App 无法写入配对响应：\(bleBridge.lastWriteEvent)")
        }
        guard await bleBridge.confirmPairingResponse(
            startedAt: pairingWriteStartedAt,
            timeoutSeconds: 12
        ) else {
            await appState.cancelRegisteredDevice(device)
            throw AcceptanceError.state("ESP 未确认本次配对响应")
        }
        log("PAIRING", "server_challenge_verified")

        let serverConfigWriteStartedAt = Date()
        guard bleBridge.writeServerConfig(
            relayURL: radarRuntime.relayBaseURL,
            roomToken: appState.inviteCode,
            deviceToken: device.deviceToken
        ) else {
            await appState.cancelRegisteredDevice(device)
            throw AcceptanceError.state("App 无法写入服务器配置：\(bleBridge.lastWriteEvent)")
        }
        guard await bleBridge.confirmServerConfig(
            deviceToken: device.deviceToken,
            startedAt: serverConfigWriteStartedAt,
            timeoutSeconds: 12
        ) else {
            throw AcceptanceError.state("ESP 未确认新设备身份，App 未提交该绑定")
        }
        appState.commitRegisteredDevice(device)
        appState.simulatePairingComplete()
        await radarRuntime.provisionESP(deviceName: device.name, roomCode: appState.inviteCode)

        try await wait(seconds: 20, description: "ESP 保存服务器和 OTA 更新源") {
            let status = bleBridge.deviceStatus
            return status?.paired == 1
                && status?.server == 1
                && status?.wifi == "connected"
                && status?.otaOrigin == 1
        }

        if !bleBridge.ownerSessionAuthorized {
            bleBridge.configureOwnerSession(deviceToken: "")
            bleBridge.configureOwnerSession(deviceToken: device.deviceToken)
        }
        try await wait(seconds: 12, description: "ESP 确认所有者会话") {
            bleBridge.ownerSessionAuthorized && bleBridge.deviceStatus?.ownerAuth == 1
        }
        log("PROVISION", "paired=1 server=1 ota_origin=1 owner_auth=1")
    }

    private static func authorizeConfiguredDevice(
        appState: AppState,
        bleBridge: BLEDeviceBridge
    ) async throws {
        if bleBridge.ownerSessionAuthorized, bleBridge.deviceStatus?.ownerAuth == 1 {
            log("OWNER", "active_server_device_authorized")
            return
        }

        let devices = try await appState.devicesRepository.listDevices()
        guard !devices.isEmpty else {
            throw AcceptanceError.state("服务器没有可用于恢复所有者会话的雷达凭据")
        }
        log("OWNER", "checking_server_devices count=\(devices.count)")

        let activeDeviceID = appState.devicesStore.activeDevice?.deviceID
        let orderedDevices = devices.sorted { lhs, rhs in
            lhs.deviceID == activeDeviceID && rhs.deviceID != activeDeviceID
        }
        for device in orderedDevices {
            let firstResult = await attemptOwnerAuthorization(
                deviceToken: device.deviceToken,
                bleBridge: bleBridge
            )
            guard firstResult == .authorized else { continue }

            // Confirm the same credential a second time. This prevents a
            // delayed notification from a previous candidate being associated
            // with the current candidate on a busy CoreBluetooth connection.
            let confirmationResult = await attemptOwnerAuthorization(
                deviceToken: device.deviceToken,
                bleBridge: bleBridge,
                settleBeforeWrite: true
            )
            guard confirmationResult == .authorized else { continue }

            appState.devicesStore.applyServerDevice(device)
            log("OWNER", "matched_server_device_confirmed short_id=\(device.deviceShortID)")
            return
        }

        bleBridge.configureOwnerSession(deviceToken: "")
        throw AcceptanceError.state("现有服务器雷达凭据均无法通过 ESP 所有者鉴权；已停止，未创建新绑定")
    }

    private static func attemptOwnerAuthorization(
        deviceToken: String,
        bleBridge: BLEDeviceBridge,
        settleBeforeWrite: Bool = false
    ) async -> OwnerAuthorizationResult {
        // Emptying the staged token resets the one-attempt-per-challenge guard
        // without emitting a proof. A short drain interval prevents queued 105
        // notifications from the previous candidate contaminating this result.
        bleBridge.configureOwnerSession(deviceToken: "")
        try? await Task.sleep(for: .milliseconds(settleBeforeWrite ? 350 : 200))
        bleBridge.configureOwnerSession(deviceToken: deviceToken)

        // Wait for the write and its notification to settle, then issue an
        // explicit 105 read. Only a response newer than this read is accepted.
        try? await Task.sleep(for: .milliseconds(450))
        let readStartedAt = Date()
        bleBridge.readDeviceStatus()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if
                let statusAt = bleBridge.lastDeviceStatusAt,
                statusAt >= readStartedAt,
                let status = bleBridge.deviceStatus
            {
                if
                    status.paired == 1,
                    status.server == 1,
                    status.ownerAuth == 1,
                    bleBridge.ownerSessionAuthorized
                {
                    return .authorized
                }
                return .rejected
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .timedOut
    }

    private static func monitorOTA(
        bleBridge: BLEDeviceBridge,
        firmwareUpdate: FirmwareUpdateCoordinator
    ) async throws {
        let deadline = Date().addingTimeInterval(600)
        var lastPhase: FirmwareUpdatePhase?
        var lastStage = ""

        while Date() < deadline {
            if bleBridge.isBLEConnected {
                bleBridge.readFirmwareStatus()
                if [.installing, .rebooting].contains(firmwareUpdate.phase) {
                    bleBridge.readDeviceStatus()
                }
            }
            firmwareUpdate.synchronize(
                status: bleBridge.firmwareStatus,
                deviceStatus: bleBridge.deviceStatus
            )

            let stage = bleBridge.firmwareStatus?.stage.lowercased() ?? "unavailable"
            if lastPhase != firmwareUpdate.phase || lastStage != stage {
                lastPhase = firmwareUpdate.phase
                lastStage = stage
                log("OTA", "phase=\(firmwareUpdate.phase.rawValue) stage=\(stage) progress=\(firmwareUpdate.progress)")
            }

            switch firmwareUpdate.phase {
            case .succeeded:
                return
            case .failed, .rolledBack, .canceled, .bootstrapRequired:
                throw AcceptanceError.state(firmwareUpdate.detail)
            default:
                break
            }
            try await Task.sleep(for: .milliseconds(750))
        }
        throw AcceptanceError.timeout("App 等待实体 ESP 完成 OTA")
    }

    private static func isFullyProvisioned(_ bleBridge: BLEDeviceBridge) -> Bool {
        guard let status = bleBridge.deviceStatus else { return false }
        return status.paired == 1
            && status.server == 1
            && status.wifi == "connected"
            && status.otaOrigin == 1
            && status.ownerAuth == 1
            && bleBridge.ownerSessionAuthorized
    }

    private static func isExactTarget(_ status: RadarBLEDeviceStatus) -> Bool {
        status.firmwareVersion == targetVersion
            && status.firmwareBuild == targetBuild
            && status.securityCounter == targetSecurityCounter
    }

    private static func isExactInstalledFirmwareStatus(_ status: RadarBLEFirmwareStatus?) -> Bool {
        guard
            let status,
            status.firmwareVersion == targetVersion,
            status.build == targetBuild
        else { return false }
        switch status.stage.lowercased() {
        case "success":
            return status.targetVersion == targetVersion && status.targetBuild == targetBuild
        case "idle":
            // Success is intentionally terminal only for the boot that performs
            // health confirmation. A later cold App connection reads idle while
            // still reporting the exact installed firmware identity.
            return true
        default:
            return false
        }
    }

    private static func wait(
        seconds: TimeInterval,
        description: String,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AcceptanceError.timeout(description)
    }

    private static func log(_ step: String, _ detail: String) {
        print("DragonRadar PhysicalOTA step=\(step) \(detail)")
    }

    private static func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private enum AcceptanceError: LocalizedError {
        case timeout(String)
        case state(String)

        var errorDescription: String? {
            switch self {
            case .timeout(let detail): "超时：\(detail)"
            case .state(let detail): detail
            }
        }
    }

    private enum OwnerAuthorizationResult: Equatable {
        case authorized
        case rejected
        case timedOut
    }
}
#endif
