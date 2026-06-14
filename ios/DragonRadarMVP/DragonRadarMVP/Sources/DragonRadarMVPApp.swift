import SwiftUI
import UIKit

final class DragonRadarAppDelegate: NSObject, UIApplicationDelegate {
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
}

extension Notification.Name {
    static let dragonRadarRemotePushToken = Notification.Name("dragonRadarRemotePushToken")
    static let dragonRadarRemotePushRegistrationFailed = Notification.Name("dragonRadarRemotePushRegistrationFailed")
}

@main
struct DragonRadarMVPApp: App {
    @UIApplicationDelegateAdaptor(DragonRadarAppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var locationBridge = LocationBridge()
    @State private var radarRuntime = RadarRuntime()
    @State private var bleBridge = BLEDeviceBridge()
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
                .environment(appState)
                .environment(locationBridge)
                .environment(radarRuntime)
                .environment(bleBridge)
                .environment(notificationCenter)
        }
    }
}
