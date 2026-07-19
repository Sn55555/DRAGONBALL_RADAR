import SwiftUI

#if APP_ONLY
struct AppRuntimeHost<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(NotificationPermissionCenter.self) private var notificationCenter
    @State private var coordinator = AppRuntimeCoordinator()

    private let content: Content
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("DRAGON_RADAR_UI_TESTING")

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let lifecycleContent = content
            .task {
                guard !isUITesting else { return }
                await appState.restoreSessionIfNeeded()
                guard appState.isSignedIn, !appState.isReviewExperienceActive else { return }
                radarRuntime.configureUserDisplayName(appState.displayName)
                await syncPushRegistrationIfPossible()
                await appState.refreshRoomsFromServer()
                let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !roomCode.isEmpty else { return }
                await coordinator.bootstrap(
                    roomCode: roomCode,
                    appAccessToken: appState.accessToken,
                    locationBridge: locationBridge,
                    radarRuntime: radarRuntime
                )
            }
            .onChange(of: appState.isSignedIn) { _, isSignedIn in
                guard !isUITesting else { return }
                Task {
                    if isSignedIn {
                        guard !appState.isReviewExperienceActive else { return }
                        radarRuntime.configureUserDisplayName(appState.displayName)
                        await syncPushRegistrationIfPossible()
                        await appState.refreshRoomsFromServer()
                        let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !roomCode.isEmpty else { return }
                        await coordinator.bootstrap(
                            roomCode: roomCode,
                            appAccessToken: appState.accessToken,
                            locationBridge: locationBridge,
                            radarRuntime: radarRuntime
                        )
                    } else {
                        await coordinator.stop(locationBridge: locationBridge, radarRuntime: radarRuntime)
                    }
                }
            }
            .onChange(of: appState.isReviewExperienceActive) { _, isActive in
                guard !isUITesting else { return }
                Task {
                    if isActive {
                        await coordinator.stop(locationBridge: locationBridge, radarRuntime: radarRuntime)
                        return
                    }
                    guard appState.isSignedIn else { return }
                    let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !roomCode.isEmpty else { return }
                    await coordinator.bootstrap(
                        roomCode: roomCode,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        radarRuntime: radarRuntime
                    )
                }
            }
            .onChange(of: appState.displayName) { _, displayName in
                radarRuntime.configureUserDisplayName(displayName)
            }
            .onChange(of: appState.inviteCode) { _, roomCode in
                guard appState.isSignedIn, !appState.isReviewExperienceActive, !isUITesting else { return }
                appState.clearRelayRoomMembers()
                let cleanRoomCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanRoomCode.isEmpty else {
                    radarRuntime.disconnectRelay()
                    return
                }
                Task {
                    await coordinator.reconnectRelay(
                        roomCode: cleanRoomCode,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        radarRuntime: radarRuntime
                    )
                }
            }
            .onChange(of: radarRuntime.roomStateSnapshot) { _, snapshot in
                guard !isUITesting, !appState.isReviewExperienceActive else { return }
                guard let snapshot else {
                    appState.clearRelayRoomMembers()
                    return
                }
                appState.applyRelayRoomState(snapshot, localAppPeerID: radarRuntime.localAppPeerID)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !appState.isReviewExperienceActive, !isUITesting else { return }
                Task {
                    await appState.restoreSessionIfNeeded()
                    guard appState.isSignedIn else { return }
                    await syncPushRegistrationIfPossible()
                    let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !roomCode.isEmpty else { return }
                    await coordinator.maintainRuntime(
                        roomCode: roomCode,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        radarRuntime: radarRuntime,
                        forceLocation: true
                    )
                }
            }
            .onChange(of: locationBridge.latestLocation?.timestamp) { _, _ in
                guard !isUITesting, appState.isSignedIn, !appState.isReviewExperienceActive else { return }
                Task {
                    await coordinator.publishLatestLocationIfNeeded(
                        locationBridge: locationBridge,
                        radarRuntime: radarRuntime
                    )
                }
            }
            .onChange(of: notificationCenter.remoteDeviceToken) { _, _ in
                guard !isUITesting, appState.isSignedIn, !appState.isReviewExperienceActive else { return }
                Task {
                    await notificationCenter.syncRemoteTokenIfPossible(accessToken: appState.accessToken)
                }
            }

        lifecycleContent
            .task {
                guard !isUITesting else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard appState.isSignedIn, !appState.isReviewExperienceActive else { continue }
                    let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !roomCode.isEmpty else { continue }
                    await coordinator.maintainRuntime(
                        roomCode: roomCode,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        radarRuntime: radarRuntime,
                        forceLocation: false
                    )
                }
            }
    }

    private func syncPushRegistrationIfPossible() async {
        await notificationCenter.refresh()
        notificationCenter.registerRemoteNotificationsIfAuthorized()
        await notificationCenter.syncRemoteTokenIfPossible(accessToken: appState.accessToken)
    }
}

@MainActor
private final class AppRuntimeCoordinator {
    private static let locationPublishInterval: TimeInterval = 3

    private var didBootstrap = false
    private var activeRoomCode = ""
    private var lastPublishedLocationAt = Date.distantPast

    func bootstrap(
        roomCode: String,
        appAccessToken: String,
        locationBridge: LocationBridge,
        radarRuntime: RadarRuntime
    ) async {
        guard !didBootstrap else { return }
        didBootstrap = true
        activeRoomCode = roomCode
        radarRuntime.roomSwitchState = .appSwitching
        radarRuntime.roomSwitchDetail = "App 启动进入 \(roomCode)"

        await radarRuntime.connectRelay(roomCode: roomCode, deviceToken: "", appAccessToken: appAccessToken)
        if radarRuntime.relayPhase == .ready {
            radarRuntime.roomSwitchState = .synced
            radarRuntime.roomSwitchDetail = "App 已进入 \(roomCode)"
        } else {
            radarRuntime.roomSwitchState = .failed
            radarRuntime.roomSwitchDetail = radarRuntime.lastRelayEvent
        }

        if !locationBridge.isUserPaused {
            locationBridge.startSharing()
        }
        await publishLatestLocationIfNeeded(
            force: true,
            locationBridge: locationBridge,
            radarRuntime: radarRuntime
        )
    }

    func reconnectRelay(
        roomCode: String,
        appAccessToken: String,
        locationBridge: LocationBridge,
        radarRuntime: RadarRuntime
    ) async {
        if !didBootstrap {
            await bootstrap(
                roomCode: roomCode,
                appAccessToken: appAccessToken,
                locationBridge: locationBridge,
                radarRuntime: radarRuntime
            )
            return
        }
        guard roomCode != activeRoomCode else { return }
        activeRoomCode = roomCode
        radarRuntime.roomSwitchState = .appSwitching
        radarRuntime.roomSwitchDetail = "App 正在进入 \(roomCode)"

        await radarRuntime.connectRelay(roomCode: roomCode, deviceToken: "", appAccessToken: appAccessToken)
        if radarRuntime.relayPhase == .ready {
            radarRuntime.roomSwitchState = .synced
            radarRuntime.roomSwitchDetail = "App 已进入 \(roomCode)"
        } else {
            radarRuntime.roomSwitchState = .failed
            radarRuntime.roomSwitchDetail = radarRuntime.lastRelayEvent
        }
        await publishLatestLocationIfNeeded(
            force: true,
            locationBridge: locationBridge,
            radarRuntime: radarRuntime
        )
    }

    func publishLatestLocationIfNeeded(
        force: Bool = false,
        locationBridge: LocationBridge,
        radarRuntime: RadarRuntime
    ) async {
        guard locationBridge.isSharing else {
            print(
                "DragonRadar location publish skipped sharing=0 "
                    + "userPaused=\(locationBridge.isUserPaused ? 1 : 0)"
            )
            return
        }
        locationBridge.requestLocationRefreshIfNeeded()
        guard let snapshot = locationBridge.snapshot else {
            print(
                "DragonRadar location publish skipped sharing=1 "
                    + "authorized=\(locationBridge.isAuthorized ? 1 : 0) "
                    + "permission=\(locationBridge.permissionText) "
                    + "sample=\(locationBridge.latestLocation == nil ? 0 : 1) "
                    + "state=\(locationBridge.lastUpdateText) "
                    + "error=\(locationBridge.lastError ?? "-")"
            )
            return
        }
        guard radarRuntime.relayPhase == .ready else {
            print(
                "DragonRadar location publish deferred "
                    + "relay=\(radarRuntime.relayPhase.rawValue)"
            )
            return
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedLocationAt) >= Self.locationPublishInterval else { return }

        lastPublishedLocationAt = now
        await radarRuntime.publishLocation(snapshot)
    }

    func maintainRuntime(
        roomCode: String,
        appAccessToken: String,
        locationBridge: LocationBridge,
        radarRuntime: RadarRuntime,
        forceLocation: Bool
    ) async {
        if !locationBridge.isSharing && !locationBridge.isUserPaused {
            locationBridge.startSharing()
        }

        let effectiveRoomCode = activeRoomCode.isEmpty ? roomCode : activeRoomCode
        if radarRuntime.relayPhase == .idle || radarRuntime.relayPhase == .failed || radarRuntime.relayPhase == .degraded {
            await radarRuntime.connectRelay(roomCode: effectiveRoomCode, deviceToken: "", appAccessToken: appAccessToken)
        }

        await publishLatestLocationIfNeeded(
            force: forceLocation,
            locationBridge: locationBridge,
            radarRuntime: radarRuntime
        )
    }

    func stop(locationBridge: LocationBridge, radarRuntime: RadarRuntime) async {
        didBootstrap = false
        activeRoomCode = ""
        locationBridge.stopSharing()
        radarRuntime.disconnectRelay()
    }
}
#else
struct AppRuntimeHost<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(FirmwareUpdateCoordinator.self) private var firmwareUpdate
    @Environment(NotificationPermissionCenter.self) private var notificationCenter
    @State private var coordinator = AppRuntimeCoordinator()

    private let content: Content
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("DRAGON_RADAR_UI_TESTING")
    private let isPhysicalOTAAcceptance = ProcessInfo.processInfo.arguments.contains(
        "DRAGON_RADAR_PHYSICAL_OTA_ACCEPTANCE"
    )

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let lifecycleContent = content
            .task {
                guard !isUITesting, !isPhysicalOTAAcceptance else { return }
                await appState.restoreSessionIfNeeded()
                guard appState.isSignedIn, !appState.isReviewExperienceActive else { return }
                radarRuntime.configureUserDisplayName(appState.displayName)
                await syncPushRegistrationIfPossible()
                await appState.refreshRoomsFromServer()
                await appState.refreshDevicesFromServer()
                bleBridge.configureOwnerSession(deviceToken: appState.activeDeviceToken)
                firmwareUpdate.refreshFromDevice(bleBridge: bleBridge)
                guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                await coordinator.bootstrap(
                    roomCode: appState.inviteCode,
                    deviceToken: appState.activeDeviceToken,
                    appAccessToken: appState.accessToken,
                    locationBridge: locationBridge,
                    bleBridge: bleBridge,
                    radarRuntime: radarRuntime
                )
            }
            .onChange(of: appState.isSignedIn) { _, isSignedIn in
                guard !isUITesting, !isPhysicalOTAAcceptance else { return }
                Task {
                    if isSignedIn {
                        guard !appState.isReviewExperienceActive else { return }
                        radarRuntime.configureUserDisplayName(appState.displayName)
                        await syncPushRegistrationIfPossible()
                        await appState.refreshRoomsFromServer()
                        await appState.refreshDevicesFromServer()
                        bleBridge.configureOwnerSession(deviceToken: appState.activeDeviceToken)
                        firmwareUpdate.refreshFromDevice(bleBridge: bleBridge)
                        guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        await coordinator.bootstrap(
                            roomCode: appState.inviteCode,
                            deviceToken: appState.activeDeviceToken,
                            appAccessToken: appState.accessToken,
                            locationBridge: locationBridge,
                            bleBridge: bleBridge,
                            radarRuntime: radarRuntime
                        )
                    } else {
                        bleBridge.configureOwnerSession(deviceToken: "")
                        await coordinator.stop(locationBridge: locationBridge, radarRuntime: radarRuntime)
                    }
                }
            }
            .onChange(of: appState.isReviewExperienceActive) { _, isActive in
                guard !isUITesting else { return }
                Task {
                    if isActive {
                        bleBridge.stopScan()
                        await coordinator.stop(locationBridge: locationBridge, radarRuntime: radarRuntime)
                        return
                    }
                    guard appState.isSignedIn else { return }
                    let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !roomCode.isEmpty else { return }
                    await coordinator.bootstrap(
                        roomCode: roomCode,
                        deviceToken: appState.activeDeviceToken,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        bleBridge: bleBridge,
                        radarRuntime: radarRuntime
                    )
                }
            }
            .onChange(of: appState.displayName) { _, displayName in
                radarRuntime.configureUserDisplayName(displayName)
            }
            .onChange(of: appState.inviteCode) { _, roomCode in
                guard
                    appState.isSignedIn,
                    !appState.isReviewExperienceActive,
                    !isUITesting,
                    !isPhysicalOTAAcceptance
                else { return }
                appState.clearRelayRoomMembers()
                guard !roomCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    radarRuntime.disconnectRelay()
                    return
                }
                Task {
                    await coordinator.reconnectRelay(
                        roomCode: roomCode,
                        deviceToken: appState.activeDeviceToken,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        bleBridge: bleBridge,
                        radarRuntime: radarRuntime
                    )
                }
            }
            .onChange(of: radarRuntime.roomStateSnapshot) { _, snapshot in
                guard !isUITesting, !appState.isReviewExperienceActive else { return }
                guard let snapshot else {
                    appState.clearRelayRoomMembers()
                    appState.updateActiveDeviceBattery(percent: nil)
                    return
                }
                appState.applyRelayRoomState(snapshot, localAppPeerID: radarRuntime.localAppPeerID)
                appState.updateActiveDeviceBattery(percent: radarRuntime.localRelayDeviceStatus?.batteryPercentValue)
            }
            .onChange(of: scenePhase) { _, phase in
                guard
                    phase == .active,
                    !appState.isReviewExperienceActive,
                    !isUITesting,
                    !isPhysicalOTAAcceptance
                else { return }
                Task {
                    await appState.restoreSessionIfNeeded()
                    guard appState.isSignedIn else { return }
                    await syncPushRegistrationIfPossible()
                    bleBridge.configureOwnerSession(deviceToken: appState.activeDeviceToken)
                    firmwareUpdate.refreshFromDevice(bleBridge: bleBridge)
                    guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    await coordinator.maintainRuntime(
                        roomCode: appState.inviteCode,
                        deviceToken: appState.activeDeviceToken,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        bleBridge: bleBridge,
                        radarRuntime: radarRuntime,
                        forceLocation: true
                    )
                }
            }
            .onChange(of: locationBridge.latestLocation?.timestamp) { _, _ in
                guard !isUITesting, appState.isSignedIn, !appState.isReviewExperienceActive else { return }
                Task {
                    await coordinator.publishLatestLocationIfNeeded(
                        locationBridge: locationBridge,
                        bleBridge: bleBridge,
                        radarRuntime: radarRuntime
                    )
                }
            }
            .onChange(of: bleBridge.firmwareStatus) { _, status in
                firmwareUpdate.synchronize(status: status, deviceStatus: bleBridge.deviceStatus)
            }
            .onChange(of: bleBridge.deviceStatus) { previousStatus, status in
                firmwareUpdate.synchronize(status: bleBridge.firmwareStatus, deviceStatus: status)
                if !isPhysicalOTAAcceptance, previousStatus == nil, status != nil {
                    syncCurrentRoomToESPIfOwnerReady(reason: "设备状态确认")
                }
            }
            .onChange(of: bleBridge.ownerSessionAuthorized) { _, authorized in
                guard authorized, !isUITesting, !isPhysicalOTAAcceptance else { return }
                syncCurrentRoomToESPIfOwnerReady(reason: "所有者会话确认")
            }
            .onChange(of: bleBridge.firmwareControlWriteError) { _, message in
                guard let message else { return }
                firmwareUpdate.handleFirmwareControlWriteFailure(message)
            }
            .onChange(of: bleBridge.availableCharacteristicNames) { _, _ in
                guard
                    appState.isSignedIn,
                    !appState.isReviewExperienceActive,
                    !isPhysicalOTAAcceptance
                else { return }
                let deviceToken = appState.activeDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
                bleBridge.configureOwnerSession(deviceToken: deviceToken)
                syncCurrentRoomToESPIfOwnerReady(reason: "配置连接")
            }
            .onChange(of: notificationCenter.remoteDeviceToken) { _, _ in
                guard !isUITesting, appState.isSignedIn, !appState.isReviewExperienceActive else { return }
                Task {
                    await notificationCenter.syncRemoteTokenIfPossible(accessToken: appState.accessToken)
                }
            }

        lifecycleContent
            .task {
                guard !isUITesting, !isPhysicalOTAAcceptance else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard appState.isSignedIn, !appState.isReviewExperienceActive else { continue }
                    guard !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    await coordinator.maintainRuntime(
                        roomCode: appState.inviteCode,
                        deviceToken: appState.activeDeviceToken,
                        appAccessToken: appState.accessToken,
                        locationBridge: locationBridge,
                        bleBridge: bleBridge,
                        radarRuntime: radarRuntime,
                        forceLocation: false
                    )
                }
            }
            .task {
                guard !isUITesting else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard firmwareUpdate.phase.isBusy, bleBridge.isBLEConnected else { continue }
                    bleBridge.readFirmwareStatus()
                    switch firmwareUpdate.phase {
                    case .installing, .rebooting:
                        bleBridge.readDeviceStatus()
                    default:
                        break
                    }
                }
            }
            .task(id: firmwareUpdate.phase) {
                guard !isUITesting else { return }
                let shouldTrack = FirmwareReconnectPolicy.shouldTrack(firmwareUpdate.phase)
                bleBridge.setFirmwareReconnectTracking(shouldTrack)
                if shouldTrack, bleBridge.isBLEConnected {
                    bleBridge.readDeviceStatus()
                    bleBridge.readFirmwareStatus()
                }
            }
            .task {
                #if DEBUG
                guard ProcessInfo.processInfo.arguments.contains("DRAGON_RADAR_PHYSICAL_OTA_ACCEPTANCE") else {
                    return
                }
                await PhysicalOTAAcceptanceCoordinator.run(
                    appState: appState,
                    bleBridge: bleBridge,
                    radarRuntime: radarRuntime,
                    firmwareUpdate: firmwareUpdate
                )
                #endif
            }
    }

    private func syncCurrentRoomToESPIfOwnerReady(reason: String) {
        guard
            appState.isSignedIn,
            !appState.isReviewExperienceActive,
            let deviceStatus = bleBridge.deviceStatus
        else { return }
        if deviceStatus.ownerAuthRequired == 1, !bleBridge.ownerSessionAuthorized {
            return
        }
        let roomCode = appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceToken = appState.activeDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomCode.isEmpty, !deviceToken.isEmpty, bleBridge.hasCharacteristic(.serverConfig) else { return }
        Task {
            _ = await coordinator.syncCurrentRoomToESPIfPossible(
                roomCode: roomCode,
                deviceToken: deviceToken,
                bleBridge: bleBridge,
                radarRuntime: radarRuntime,
                force: true,
                reason: reason
            )
        }
    }

    private func syncPushRegistrationIfPossible() async {
        await notificationCenter.refresh()
        notificationCenter.registerRemoteNotificationsIfAuthorized()
        await notificationCenter.syncRemoteTokenIfPossible(accessToken: appState.accessToken)
    }
}

@MainActor
private final class AppRuntimeCoordinator {
    private static let locationPublishInterval: TimeInterval = 3

    private var didBootstrap = false
    private var activeRoomCode = ""
    private var lastSyncedESPConfigRoom = ""
    private var pendingESPConfigRoom = ""
    private var lastPublishedLocationAt = Date.distantPast
    private var lastWroteLocationToESPAt = Date.distantPast

    func bootstrap(
        roomCode: String,
        deviceToken: String,
        appAccessToken: String,
        locationBridge: LocationBridge,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime
    ) async {
        guard !didBootstrap else { return }
        didBootstrap = true
        activeRoomCode = roomCode
        radarRuntime.roomSwitchState = .appSwitching
        radarRuntime.roomSwitchDetail = "App 启动进入 \(roomCode)"

        await radarRuntime.connectRelay(roomCode: roomCode, deviceToken: deviceToken, appAccessToken: appAccessToken)
        let didNotifyESP = await radarRuntime.sendRoomSwitchToESP(
            roomCode: roomCode,
            deviceToken: deviceToken
        )
        if didNotifyESP {
            radarRuntime.noteESPEvent("云端启动切房通知已发送 · \(roomCode)")
        }
        _ = await syncCurrentRoomToESPIfPossible(
            roomCode: roomCode,
            deviceToken: deviceToken,
            bleBridge: bleBridge,
            radarRuntime: radarRuntime,
            reason: "启动"
        )

        if !locationBridge.isUserPaused {
            locationBridge.startSharing()
        }
        await publishLatestLocationIfNeeded(
            force: true,
            locationBridge: locationBridge,
            bleBridge: bleBridge,
            radarRuntime: radarRuntime
        )
        await observeVoiceIfRelayReady(radarRuntime: radarRuntime)
    }

    func reconnectRelay(
        roomCode: String,
        deviceToken: String,
        appAccessToken: String,
        locationBridge: LocationBridge,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime
    ) async {
        if !didBootstrap {
            await bootstrap(
                roomCode: roomCode,
                deviceToken: deviceToken,
                appAccessToken: appAccessToken,
                locationBridge: locationBridge,
                bleBridge: bleBridge,
                radarRuntime: radarRuntime
            )
            return
        }
        guard roomCode != activeRoomCode else { return }
        activeRoomCode = roomCode
        radarRuntime.roomSwitchState = .appSwitching
        radarRuntime.roomSwitchDetail = "App 正在进入 \(roomCode)"
        await radarRuntime.stopObservingVoiceRoom()

        let didNotifyESP = await radarRuntime.sendRoomSwitchToESP(
            roomCode: roomCode,
            deviceToken: deviceToken
        )
        if didNotifyESP {
            radarRuntime.noteESPEvent("云端切房通知已发送 · \(roomCode)")
        }

        await radarRuntime.connectRelay(roomCode: roomCode, deviceToken: deviceToken, appAccessToken: appAccessToken)
        _ = await syncCurrentRoomToESPIfPossible(
            roomCode: roomCode,
            deviceToken: deviceToken,
            bleBridge: bleBridge,
            radarRuntime: radarRuntime,
            force: true,
            reason: "切房"
        )
        await publishLatestLocationIfNeeded(
            force: true,
            locationBridge: locationBridge,
            bleBridge: bleBridge,
            radarRuntime: radarRuntime
        )
        await observeVoiceIfRelayReady(radarRuntime: radarRuntime)
    }

    @discardableResult
    func syncCurrentRoomToESPIfPossible(
        roomCode: String,
        deviceToken: String,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime,
        force: Bool = false,
        reason: String
    ) async -> Bool {
        let cleanRoomCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRoomCode.isEmpty else { return false }
        guard !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            radarRuntime.roomSwitchState = .waitingESPJoin
            radarRuntime.roomSwitchDetail = "没有已绑定雷达，暂不写入房间配置"
            return false
        }
        guard force || pendingESPConfigRoom == cleanRoomCode || lastSyncedESPConfigRoom != cleanRoomCode else {
            return true
        }

        guard bleBridge.writeServerConfig(
            relayURL: radarRuntime.relayBaseURL,
            roomToken: cleanRoomCode,
            deviceToken: deviceToken
        ) else {
            pendingESPConfigRoom = cleanRoomCode
            radarRuntime.roomSwitchState = .waitingESPJoin
            radarRuntime.roomSwitchDetail = "配置连接暂不可写 · 等待雷达进入 \(cleanRoomCode)"
            radarRuntime.noteESPServerConfigPending(roomCode: cleanRoomCode, reason: bleBridge.lastWriteEvent)
            return false
        }

        pendingESPConfigRoom = ""
        lastSyncedESPConfigRoom = cleanRoomCode
        await radarRuntime.provisionESP(
            deviceName: bleBridge.connectedPeripheralName,
            roomCode: cleanRoomCode
        )
        radarRuntime.noteESPEvent("雷达已同步当前房间 · \(cleanRoomCode) · \(reason)")
        radarRuntime.roomSwitchState = .waitingESPJoin
        radarRuntime.roomSwitchDetail = "房间配置已写入 · 等待雷达加入 \(cleanRoomCode)"
        return true
    }

    func publishLatestLocationIfNeeded(
        force: Bool = false,
        locationBridge: LocationBridge,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime
    ) async {
        guard locationBridge.isSharing else {
            print(
                "DragonRadar location publish skipped sharing=0 "
                    + "userPaused=\(locationBridge.isUserPaused ? 1 : 0)"
            )
            return
        }
        locationBridge.requestLocationRefreshIfNeeded()
        guard let snapshot = locationBridge.snapshot else {
            print(
                "DragonRadar location publish skipped sharing=1 "
                    + "authorized=\(locationBridge.isAuthorized ? 1 : 0) "
                    + "permission=\(locationBridge.permissionText) "
                    + "sample=\(locationBridge.latestLocation == nil ? 0 : 1) "
                    + "state=\(locationBridge.lastUpdateText) "
                    + "error=\(locationBridge.lastError ?? "-")"
            )
            return
        }
        guard radarRuntime.relayPhase == .ready else {
            print(
                "DragonRadar location publish deferred "
                    + "relay=\(radarRuntime.relayPhase.rawValue)"
            )
            return
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedLocationAt) >= Self.locationPublishInterval else { return }

        lastPublishedLocationAt = now
        await radarRuntime.publishLocation(snapshot)
    }

    func maintainRuntime(
        roomCode: String,
        deviceToken: String,
        appAccessToken: String,
        locationBridge: LocationBridge,
        bleBridge: BLEDeviceBridge,
        radarRuntime: RadarRuntime,
        forceLocation: Bool
    ) async {
        if !locationBridge.isSharing && !locationBridge.isUserPaused {
            locationBridge.startSharing()
        }

        let effectiveRoomCode = activeRoomCode.isEmpty ? roomCode : activeRoomCode
        if radarRuntime.relayPhase == .idle || radarRuntime.relayPhase == .failed || radarRuntime.relayPhase == .degraded {
            await radarRuntime.connectRelay(roomCode: effectiveRoomCode, deviceToken: deviceToken, appAccessToken: appAccessToken)
            await observeVoiceIfRelayReady(radarRuntime: radarRuntime)
        }

        await publishLatestLocationIfNeeded(
            force: forceLocation,
            locationBridge: locationBridge,
            bleBridge: bleBridge,
            radarRuntime: radarRuntime
        )
    }

    private func observeVoiceIfRelayReady(radarRuntime: RadarRuntime) async {
        guard radarRuntime.relayPhase == .ready else {
            await radarRuntime.stopObservingVoiceRoom()
            return
        }
        await radarRuntime.observeVoiceRoom()
    }

    func stop(locationBridge: LocationBridge, radarRuntime: RadarRuntime) async {
        didBootstrap = false
        activeRoomCode = ""
        locationBridge.stopSharing()
        await radarRuntime.stopObservingVoiceRoom()
        radarRuntime.disconnectRelay()
    }
}
#endif
