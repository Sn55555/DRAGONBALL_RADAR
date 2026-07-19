import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class NotificationPermissionCenter {
    private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let remoteDeviceTokenKey = "dragonRadar.notifications.remoteDeviceToken"
    @ObservationIgnored private var tokenObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var reminderObserver: NSObjectProtocol?
    @ObservationIgnored private var signOutObserver: NSObjectProtocol?
    @ObservationIgnored private var syncedRegistrationKey = ""
    @ObservationIgnored private var seenReminderIDs: Set<String> = []
    @ObservationIgnored private var scheduledReminderIDs: Set<String> = []
    @ObservationIgnored private var accountGeneration = 0

    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var alertSetting: UNNotificationSetting = .notSupported
    var soundSetting: UNNotificationSetting = .notSupported
    var badgeSetting: UNNotificationSetting = .notSupported
    var remoteDeviceToken = ""
    var remoteRegistrationStatus = "远程通知未注册"
    var lastError = ""
    var latestRadarReminder: RadarReminderEvent?
    var radarNavigationRequestID = ""

    init() {
        remoteDeviceToken = defaults.string(forKey: Self.remoteDeviceTokenKey) ?? ""
        tokenObserver = NotificationCenter.default.addObserver(
            forName: .dragonRadarRemotePushToken,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.object as? String else { return }
            Task { @MainActor in
                self?.remoteDeviceToken = token
                self?.defaults.set(token, forKey: Self.remoteDeviceTokenKey)
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
        reminderObserver = NotificationCenter.default.addObserver(
            forName: .dragonRadarReminderReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let payload = notification.object as? [AnyHashable: Any],
                let reminder = RadarReminderEvent(payload: payload)
            else { return }
            let opened = notification.userInfo?["opened"] as? Bool == true
            let source = notification.userInfo?["source"] as? String ?? "app"
            Task { @MainActor in
                self?.receiveRadarReminder(reminder, opened: opened, source: source)
            }
        }
        signOutObserver = NotificationCenter.default.addObserver(
            forName: .dragonRadarAccountSignedOut,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.clearReminderAccountState()
                guard let accessToken = notification.object as? String, !accessToken.isEmpty else { return }
                await self?.unregisterRemoteTokenIfPossible(accessToken: accessToken)
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
        if let reminderObserver {
            NotificationCenter.default.removeObserver(reminderObserver)
        }
        if let signOutObserver {
            NotificationCenter.default.removeObserver(signOutObserver)
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
            return "查看雷达和房间邀请提醒可用"
        case .denied:
            return "已关闭，可到系统设置恢复"
        case .notDetermined:
            return "可选，用于查看雷达和房间邀请"
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
        let registrationKey = token + "|" + accessToken
        guard syncedRegistrationKey != registrationKey else { return }
        do {
            try await PushRegistrationRepository().register(deviceToken: token, accessToken: accessToken)
            syncedRegistrationKey = registrationKey
            remoteRegistrationStatus = "已同步 \(String(token.suffix(8)))"
            lastError = ""
        } catch {
            remoteRegistrationStatus = "同步失败"
            lastError = AppError.userFacingMessage(for: error)
        }
    }

    func unregisterRemoteTokenIfPossible(accessToken: String) async {
        let token = remoteDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = accountGeneration
        syncedRegistrationKey = ""
        guard !token.isEmpty, !accessToken.isEmpty else { return }
        var lastFailure: Error?
        for attempt in 0..<3 {
            do {
                try await PushRegistrationRepository().unregister(deviceToken: token, accessToken: accessToken)
                guard generation == accountGeneration, syncedRegistrationKey.isEmpty else { return }
                remoteRegistrationStatus = "已解除账号推送绑定"
                lastError = ""
                return
            } catch {
                lastFailure = error
                guard generation == accountGeneration, syncedRegistrationKey.isEmpty else { return }
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(1 << attempt))
                }
            }
        }
        remoteRegistrationStatus = "推送解绑待重试"
        if let lastFailure {
            lastError = AppError.userFacingMessage(for: lastFailure)
        } else {
            lastError = "推送解绑失败"
        }
    }

    func dismissRadarReminder(eventID: String? = nil) {
        guard eventID == nil || latestRadarReminder?.eventID == eventID else { return }
        latestRadarReminder = nil
    }

    func consumeRadarNavigationRequest(eventID: String? = nil) {
        guard eventID == nil || radarNavigationRequestID == eventID else { return }
        radarNavigationRequestID = ""
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

    private func receiveRadarReminder(_ reminder: RadarReminderEvent, opened: Bool, source: String) {
        let isNew = seenReminderIDs.insert(reminder.eventID).inserted
        if opened {
            latestRadarReminder = reminder
            scheduledReminderIDs.remove(reminder.eventID)
            if reminder.action == "open_radar" {
                radarNavigationRequestID = reminder.eventID
            }
        } else if isNew, source == "websocket", isReady {
            scheduleSystemRadarReminder(reminder)
        } else if isNew {
            latestRadarReminder = reminder
        }
        if seenReminderIDs.count > 128 {
            seenReminderIDs = [reminder.eventID]
        }
    }

    private func scheduleSystemRadarReminder(_ reminder: RadarReminderEvent) {
        let generation = accountGeneration
        let identifier = "radar-reminder-\(reminder.eventID)"
        let content = UNMutableNotificationContent()
        content.title = "Capsule Radar 提醒"
        content.body = reminder.message
        content.sound = .default
        content.categoryIdentifier = "RADAR_REMINDER"
        content.userInfo = [
            "type": "radar_reminder",
            "event_id": reminder.eventID,
            "room_code": reminder.roomCode,
            "sender_name": reminder.senderName,
            "action": reminder.action,
            "server_time": reminder.serverTime
        ]
        scheduledReminderIDs.insert(reminder.eventID)
        Task {
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            } catch {
                guard generation == accountGeneration else { return }
                scheduledReminderIDs.remove(reminder.eventID)
                latestRadarReminder = reminder
                lastError = "系统提醒展示失败 · \(error.localizedDescription)"
            }
        }
    }

    private func clearReminderAccountState() {
        accountGeneration += 1
        let identifiers = scheduledReminderIDs.map { "radar-reminder-\($0)" }
        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        latestRadarReminder = nil
        radarNavigationRequestID = ""
        seenReminderIDs.removeAll()
        scheduledReminderIDs.removeAll()
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

    func unregister(deviceToken: String, accessToken: String) async throws {
        guard let url = URL(string: httpBaseURL + "/v1/push/register") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["device_token": deviceToken],
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
