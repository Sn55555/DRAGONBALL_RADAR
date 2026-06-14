import SwiftUI

struct AppRuntimeHost<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppState.self) private var appState
    @Environment(LocationBridge.self) private var locationBridge
    @Environment(RadarRuntime.self) private var radarRuntime
    @Environment(BLEDeviceBridge.self) private var bleBridge
    @Environment(NotificationPermissionCenter.self) private var notificationCenter
    @State private var coordinator = AppRuntimeCoordinator()

    private let content: Content
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("DRAGON_RADAR_UI_TESTING")

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .task {
                guard !isUITesting else { return }
                await appState.restoreSessionIfNeeded()
                guard appState.isSignedIn else { return }
                await syncPushRegistrationIfPossible()
                await appState.refreshRoomsFromServer()
                await appState.refreshDevicesFromServer()
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
                Task {
                    if isSignedIn {
                        await syncPushRegistrationIfPossible()
                        await appState.refreshRoomsFromServer()
                        await appState.refreshDevicesFromServer()
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
                        await coordinator.stop(locationBridge: locationBridge, radarRuntime: radarRuntime)
                    }
                }
            }
            .onChange(of: appState.inviteCode) { _, roomCode in
                guard appState.isSignedIn else { return }
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
                guard let snapshot else {
                    appState.clearRelayRoomMembers()
                    appState.updateActiveDeviceBattery(percent: nil)
                    return
                }
                appState.applyRelayRoomState(snapshot, localAppPeerID: radarRuntime.localAppPeerID)
                appState.updateActiveDeviceBattery(percent: radarRuntime.localRelayDeviceStatus?.batteryPercentValue)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await appState.restoreSessionIfNeeded()
                    guard appState.isSignedIn else { return }
                    await syncPushRegistrationIfPossible()
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
                guard appState.isSignedIn else { return }
                Task {
                    await coordinator.publishLatestLocationIfNeeded(
                        locationBridge: locationBridge,
                        bleBridge: bleBridge,
                        radarRuntime: radarRuntime
                    )
                }
            }
            .onChange(of: notificationCenter.remoteDeviceToken) { _, _ in
                guard appState.isSignedIn else { return }
                Task {
                    await notificationCenter.syncRemoteTokenIfPossible(accessToken: appState.accessToken)
                }
            }
            .task {
                guard !isUITesting else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard appState.isSignedIn else { continue }
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
    }

    private func syncPushRegistrationIfPossible() async {
        await notificationCenter.refresh()
        notificationCenter.registerRemoteNotificationsIfAuthorized()
        await notificationCenter.syncRemoteTokenIfPossible(accessToken: appState.accessToken)
    }
}

@MainActor
private final class AppRuntimeCoordinator {
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
        guard locationBridge.isSharing, locationBridge.snapshot != nil else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedLocationAt) >= 2 else { return }

        lastPublishedLocationAt = now
        await radarRuntime.publishLocation(locationBridge.snapshot)
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
