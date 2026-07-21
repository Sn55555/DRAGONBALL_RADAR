import AuthenticationServices
import SwiftUI
import UIKit
import UserNotifications

final class DragonRadarAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let openRadarAction = UNNotificationAction(
            identifier: "OPEN_RADAR",
            title: "查看雷达",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "RADAR_REMINDER",
                actions: [openRadarAction],
                intentIdentifiers: [],
                options: []
            )
        ])
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .dragonRadarRemotePushToken, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCenter.default.post(name: .dragonRadarRemotePushRegistrationFailed, object: error.localizedDescription)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let payload = notification.request.content.userInfo
        if RadarReminderEvent(payload: payload) != nil {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = response.notification.request.content.userInfo
        if RadarReminderEvent(payload: payload) != nil {
            NotificationCenter.default.post(
                name: .dragonRadarReminderReceived,
                object: payload,
                userInfo: ["opened": true, "source": "system_notification"]
            )
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let dragonRadarRemotePushToken = Notification.Name("dragonRadarRemotePushToken")
    static let dragonRadarRemotePushRegistrationFailed = Notification.Name("dragonRadarRemotePushRegistrationFailed")
    static let dragonRadarReminderReceived = Notification.Name("dragonRadarReminderReceived")
    static let dragonRadarAccountSignedOut = Notification.Name("dragonRadarAccountSignedOut")
}

@main
struct DragonRadarMVPApp: App {
    @UIApplicationDelegateAdaptor(DragonRadarAppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var locationBridge = LocationBridge()
    @State private var radarRuntime = RadarRuntime()
    @State private var pushToTalkGateway = PushToTalkGateway()
    #if !APP_ONLY
    @State private var bleBridge = BLEDeviceBridge()
    @State private var firmwareUpdate = FirmwareUpdateCoordinator()
    #endif
    @State private var notificationCenter = NotificationPermissionCenter()
    @State private var accessorySetup = CapsuleAccessorySetupCoordinator()
    #if !APP_ONLY
    @State private var showAccessoryConnectionSheet = false
    @State private var handledAccessorySelectionID: UUID?
    @State private var pendingAuthorizedConnectionAnimation = false
    #endif

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("DRAGON_RADAR_UI_TESTING")
        _appState = State(initialValue: AppState(resetPersistentState: isUITesting))
    }

    var body: some Scene {
        WindowGroup {
            AppRuntimeHost {
                AppShellView()
            }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: ASAuthorizationAppleIDProvider.credentialRevokedNotification
                    )
                ) { _ in
                    appState.handleAppleCredentialRevoked()
                }
                .environment(appState)
                .environment(locationBridge)
                .environment(radarRuntime)
                .environment(pushToTalkGateway)
                #if !APP_ONLY
                .environment(bleBridge)
                .environment(firmwareUpdate)
                #endif
                .environment(notificationCenter)
                .environment(accessorySetup)
                #if !APP_ONLY
                .sheet(isPresented: $showAccessoryConnectionSheet) {
                    CapsuleRadarPairingSheet(continueAfterSystemPicker: true)
                        .environment(appState)
                        .environment(radarRuntime)
                        .environment(bleBridge)
                }
                .alert(
                    "无法设置 Capsule Radar",
                    isPresented: Binding(
                        get: { accessorySetup.errorMessage != nil },
                        set: { isPresented in
                            if !isPresented {
                                accessorySetup.clearError()
                            }
                        }
                    )
                ) {
                    Button("好") {
                        accessorySetup.clearError()
                    }
                } message: {
                    Text(accessorySetup.errorMessage ?? "请稍后重试")
                }
                .onAppear {
                    handleCurrentAuthorizedAccessory()
                    presentAccessoryPickerAutomaticallyIfEligible()
                    handlePairingRequestIfNeeded()
                }
                .onChange(of: appState.showPairingSheet) { _, requested in
                    guard requested else { return }
                    handlePairingRequestIfNeeded()
                }
                .onChange(of: automaticPairingEligibility) { _, isEligible in
                    guard isEligible else { return }
                    presentAccessoryPickerAutomaticallyIfEligible()
                }
                .onChange(of: accessorySetup.completedSelection?.eventID) { _, _ in
                    handleCurrentAuthorizedAccessory()
                }
                .onChange(of: accessorySetup.phase) { _, phase in
                    switch phase {
                    case .idle, .failed:
                        bleBridge.resumeAfterAccessorySetup()
                    default:
                        break
                    }
                }
                .onChange(of: bleBridge.isBLEConnected) { _, isConnected in
                    guard isConnected, pendingAuthorizedConnectionAnimation else { return }
                    pendingAuthorizedConnectionAnimation = false
                    showAccessoryConnectionSheet = true
                }
                #endif
        }
    }

    #if !APP_ONLY
    private var automaticPairingEligibility: Bool {
        !appState.isReviewExperienceActive
            && appState.isSignedIn
            && !appState.inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bleBridge.hasSavedRegistration
            && accessorySetup.completedSelection == nil
    }

    private func presentAccessoryPickerAutomaticallyIfEligible() {
        guard automaticPairingEligibility else { return }
        Task {
            await bleBridge.prepareForAccessorySetup()
            guard automaticPairingEligibility else {
                bleBridge.resumeAfterAccessorySetup()
                return
            }
            accessorySetup.presentPickerAutomatically()
        }
    }

    private func handlePairingRequestIfNeeded() {
        guard appState.showPairingSheet else { return }
        appState.showPairingSheet = false
        if accessorySetup.completedSelection != nil {
            accessorySetup.reconnectAuthorizedAccessory()
        } else {
            Task {
                await bleBridge.prepareForAccessorySetup()
                accessorySetup.presentPicker()
            }
        }
    }

    private func handleCurrentAuthorizedAccessory() {
        guard let selection = accessorySetup.completedSelection else { return }
        guard handledAccessorySelectionID != selection.eventID else { return }
        handledAccessorySelectionID = selection.eventID
        bleBridge.connectAuthorizedAccessory(
            identifier: selection.bluetoothIdentifier,
            name: selection.displayName
        )
        if bleBridge.hasSavedRegistration {
            if bleBridge.isBLEConnected {
                showAccessoryConnectionSheet = true
            } else {
                pendingAuthorizedConnectionAnimation = true
            }
        } else {
            pendingAuthorizedConnectionAnimation = false
            showAccessoryConnectionSheet = true
        }
    }
    #endif
}
