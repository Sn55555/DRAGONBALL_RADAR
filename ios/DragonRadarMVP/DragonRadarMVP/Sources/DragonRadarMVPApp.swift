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
    #if !APP_ONLY
    @State private var bleBridge = BLEDeviceBridge()
    @State private var firmwareUpdate = FirmwareUpdateCoordinator()
    #endif
    @State private var notificationCenter = NotificationPermissionCenter()

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
                #if !APP_ONLY
                .environment(bleBridge)
                .environment(firmwareUpdate)
                #endif
                .environment(notificationCenter)
        }
    }
}
