import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class NotificationPermissionCenter {
    private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var tokenObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var syncedToken = ""

    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var alertSetting: UNNotificationSetting = .notSupported
    var soundSetting: UNNotificationSetting = .notSupported
    var badgeSetting: UNNotificationSetting = .notSupported
    var remoteDeviceToken = ""
    var remoteRegistrationStatus = "远程通知未注册"
    var lastError = ""

    init() {
        tokenObserver = NotificationCenter.default.addObserver(
            forName: .dragonRadarRemotePushToken,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            Task { @MainActor in
                self?.remoteDeviceToken = token
                self?.remoteRegistrationStatus = "APNs token 已获取"
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .dragonRadarRemotePushRegistrationFailed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let message = notification.object as? String else { return }
            Task { @MainActor in
                self?.remoteRegistrationStatus = "APNs 注册失败"
                self?.lastError = message
            }
        }
    }

    deinit {
        if let tokenObserver {
            NotificationCenter.default.removeObserver(tokenObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
    }

    var statusText: String {
        switch authorizationStatus {
        case .authorized:
            return "已允许"
        case .provisional:
            return "临时允许"
        case .ephemeral:
            return "本次允许"
        case .denied:
            return "已拒绝"
        case .notDetermined:
            return "待授权"
        @unknown default:
            return "未知"
        }
    }

    var detailText: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "邀请、离线和抢麦异常提醒可用"
        case .denied:
            return "已关闭，可到系统设置恢复"
        case .notDetermined:
            return "可选，用于房间邀请和雷达离线提醒"
        @unknown default:
            return "系统状态未知"
        }
    }

    var isReady: Bool {
        authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
    }

    var deliveryText: String {
        let alert = settingText(alertSetting)
        let sound = settingText(soundSetting)
        let badge = settingText(badgeSetting)
        return "横幅 \(alert) · 声音 \(sound) · 标记 \(badge) · \(remoteRegistrationStatus)"
    }

    func refresh() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        alertSetting = settings.alertSetting
        soundSetting = settings.soundSetting
        badgeSetting = settings.badgeSetting
    }

    func requestAuthorization() async {
        lastError = ""
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refresh()
            registerRemoteNotificationsIfAuthorized()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerRemoteNotificationsIfAuthorized() {
        guard isReady else { return }
        remoteRegistrationStatus = remoteDeviceToken.isEmpty ? "正在注册 APNs" : remoteRegistrationStatus
        UIApplication.shared.registerForRemoteNotifications()
    }

    func syncRemoteTokenIfPossible(accessToken: String) async {
        let token = remoteDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !token.isEmpty, !accessToken.isEmpty else { return }
        guard syncedToken != token else { return }
        do {
            try await PushRegistrationRepository().register(deviceToken: token, accessToken: accessToken)
            syncedToken = token
            remoteRegistrationStatus = "已同步 \(String(token.suffix(8)))"
            lastError = ""
        } catch {
            remoteRegistrationStatus = "同步失败"
            lastError = AppError.userFacingMessage(for: error)
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func settingText(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .enabled:
            return "开"
        case .disabled:
            return "关"
        case .notSupported:
            return "不支持"
        @unknown default:
            return "未知"
        }
    }
}

struct PushRegistrationRepository {
    var httpBaseURL = AppEnvironment.current.httpAPIBaseURL

    func register(deviceToken: String, accessToken: String) async throws {
        guard let url = URL(string: httpBaseURL + "/v1/push/register") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "device_token": deviceToken,
                "platform": "ios",
                "environment": pushEnvironment,
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            ],
            options: [.sortedKeys]
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RoomRepositoryError.badResponse
        }
    }

    private var pushEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}
