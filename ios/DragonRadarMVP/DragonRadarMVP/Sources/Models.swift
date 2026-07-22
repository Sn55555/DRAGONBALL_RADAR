import AuthenticationServices
import Foundation
import Observation

enum AppTab: String, CaseIterable, Identifiable {
    case radar
    case rooms
    #if !APP_ONLY
    case devices
    #endif
    case account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radar: "雷达"
        case .rooms: "房间"
        #if !APP_ONLY
        case .devices: "设备"
        #endif
        case .account: "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .radar: "scope"
        case .rooms: "person.3.sequence.fill"
        #if !APP_ONLY
        case .devices: "dot.radiowaves.left.and.right"
        #endif
        case .account: "person.crop.circle"
        }
    }
}

#if !APP_ONLY
enum DeviceConnectionState: String {
    case cloudConnected = "云端在线"
    case wifiConnected = "Wi-Fi 在线"
    case pairing = "正在绑定"
    case offline = "离线"
}
#endif

struct RoomMember: Identifiable, Hashable {
    let id: UUID
    var name: String
    var distance: String
    var bearing: String
    var accuracy: String
    var locationPaused: Bool
    var isOnline: Bool
    #if !APP_ONLY
    var isSpeaking: Bool
    var isMuted: Bool
    var voiceStatusText: String
    var voiceCountdownText: String
    var voiceHealthText: String
    var deviceBattery: Int
    var wifiRSSI: Int
    var firmware: String
    #endif
    var lastUpdate: String
    var moderationRef: String = ""
    var role: String = "app"
    var isLocal: Bool = false
    var isCurrentUser: Bool = false

    var canUseModerationActions: Bool {
        !isLocal && !isCurrentUser && role == "app" && !moderationRef.isEmpty
    }
}

struct RadarRoom: Identifiable, Hashable {
    let id: UUID
    var name: String
    var inviteCode: String
    var capacity: Int
    var onlineGroups: Int
    var latency: Int
    var roomStatus: String
    var members: [RoomMember]

    var onlineMembers: Int {
        max(onlineGroups, members.filter(\.isOnline).count)
    }
}

struct ServerRoom: Decodable, Hashable {
    var roomID: String
    var roomCode: String
    var name: String
    var maxMembers: Int
    var memberCount: Int
    var onlineGroups: Int? = nil
    var connections: Int? = nil

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomCode = "room_code"
        case name
        case maxMembers = "max_members"
        case memberCount = "member_count"
        case onlineGroups = "online_groups"
        case connections
    }
}

struct ServerRoomEnvelope: Decodable {
    var room: ServerRoom
}

struct ServerRoomsEnvelope: Decodable {
    var rooms: [ServerRoom]
}

struct RadarReminderReceipt: Decodable, Hashable {
    var eventID: String
    var requestID: String
    var roomCode: String
    var recipientCount: Int
    var onlineDelivered: Int
    var pushStatus: String
    var cooldownSeconds: Int
    var serverTime: Int
    var duplicate: Bool?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case requestID = "request_id"
        case roomCode = "room_code"
        case recipientCount = "recipient_count"
        case onlineDelivered = "online_delivered"
        case pushStatus = "push_status"
        case cooldownSeconds = "cooldown_seconds"
        case serverTime = "server_time"
        case duplicate
    }
}

struct RadarReminderEnvelope: Decodable {
    var reminder: RadarReminderReceipt
}

struct RadarReminderEvent: Identifiable, Hashable {
    var id: String { eventID }

    var eventID: String
    var roomCode: String
    var senderName: String
    var action: String
    var serverTime: Int

    var message: String {
        "\(senderName)提醒你查看雷达"
    }

    init?(payload: [AnyHashable: Any]) {
        let nested = Self.dictionary(payload["data"])
        guard Self.string(payload["type"]) == "radar_reminder" else { return nil }
        guard let eventID = Self.string(payload["event_id"]) ?? Self.string(nested["event_id"]), !eventID.isEmpty else {
            return nil
        }
        self.eventID = eventID
        roomCode = Self.string(payload["room_code"])
            ?? Self.string(payload["room"])
            ?? Self.string(nested["room_code"])
            ?? ""
        senderName = Self.string(payload["sender_name"])
            ?? Self.string(nested["sender_name"])
            ?? "房间成员"
        action = Self.string(payload["action"])
            ?? Self.string(nested["action"])
            ?? "open_radar"
        serverTime = Self.integer(payload["server_time"])
            ?? Self.integer(nested["server_time"])
            ?? 0
    }

    private static func dictionary(_ value: Any?) -> [AnyHashable: Any] {
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            var result: [AnyHashable: Any] = [:]
            dictionary.forEach { key, value in
                if let key = key as? AnyHashable {
                    result[key] = value
                }
            }
            return result
        }
        return [:]
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

struct ServerErrorEnvelope: Decodable {
    var code: String
    var detail: String?
    var retryAfter: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case detail
        case retryAfter = "retry_after"
    }
}

#if !APP_ONLY
struct ServerDevice: Decodable, Hashable {
    var deviceID: String
    var deviceShortID: String
    var name: String
    var deviceToken: String
    var pairingResponse: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceShortID = "device_short_id"
        case name
        case deviceToken = "device_token"
        case pairingResponse = "pairing_response"
    }
}

struct ServerDeviceEnvelope: Decodable {
    var device: ServerDevice
}

struct ServerDevicesEnvelope: Decodable {
    var devices: [ServerDevice]
}
#endif

enum RoomRepositoryError: LocalizedError {
    case server(code: String, detail: String?)
    case rateLimited(code: String, detail: String?, retryAfter: Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .server(let code, let detail):
            return RoomError.displayText(for: code, detail: detail)
        case .rateLimited(let code, let detail, _):
            return RoomError.displayText(for: code, detail: detail)
        case .badResponse:
            return "服务暂时不可用。请稍后重试。"
        }
    }

    var retryAfterSeconds: Int? {
        guard case .rateLimited(_, _, let retryAfter) = self else { return nil }
        return max(1, retryAfter)
    }
}

enum RoomError: String, LocalizedError {
    case roomFull = "room_full"
    case invalidRoom = "invalid_room"
    case roomNameRequired = "room_name_required"
    case notRoomMember = "not_room_member"
    case invalidMember = "invalid_member"
    case forbidden
    case unauthorized
    case pairingChallengeRequired = "pairing_challenge_required"
    case radarReminderRateLimited = "radar_reminder_rate_limited"
    case unknown

    init(code: String) {
        self = RoomError(rawValue: code) ?? .unknown
    }

    var errorDescription: String? {
        switch self {
        case .roomFull:
            return "房间已满，最多 7 组。请让房主移除空闲成员，或创建新房间。"
        case .invalidRoom:
            return "房间不存在或邀请码无效。请检查邀请码后重试。"
        case .roomNameRequired:
            return "请输入房间名。"
        case .notRoomMember:
            return "当前账号不在这个房间。请重新加入或切换账号。"
        case .invalidMember:
            return "成员不存在，房间状态可能已更新。请刷新房间列表。"
        case .forbidden:
            return "没有权限执行这个操作。需要房主权限。"
        case .unauthorized:
            return "登录已失效。请到“我的”重新登录。"
        case .pairingChallengeRequired:
            return "请先连接雷达。"
        case .radarReminderRateLimited:
            return "提醒发送太频繁，请稍后再试。"
        case .unknown:
            return "房间服务暂时不可用。请稍后重试。"
        }
    }

    static func displayText(for code: String, detail: String? = nil) -> String {
        let moderationText: String?
        switch code {
        case "invalid_report_type":
            moderationText = "请选择有效的内容类型。"
        case "invalid_report_category":
            moderationText = "请选择有效的举报类别。"
        case "report_details_too_long":
            moderationText = "补充说明不能超过 1000 字。"
        case "cannot_report_self":
            moderationText = "不能举报自己。"
        case "content_report_rate_limited":
            moderationText = "举报提交过于频繁，请稍后再试。"
        case "invalid_moderation_ref", "moderation_target_not_found":
            moderationText = "该成员已离开或状态已更新，请刷新房间后重试。"
        case "cannot_block_self":
            moderationText = "不能屏蔽自己。"
        case "block_not_found":
            moderationText = "这条屏蔽记录已不存在，请刷新列表。"
        case "blocked_relationship":
            moderationText = "你与该成员存在屏蔽关系，不能加入同一房间。"
        default:
            moderationText = nil
        }
        if let moderationText {
            return moderationText
        }
        let base = RoomError(code: code).errorDescription ?? code
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) · \(detail)"
    }
}

enum RelayError: String, LocalizedError {
    case unauthorized
    #if !APP_ONLY
    case deviceRevoked = "device_revoked"
    #endif
    case protocolUnsupported = "protocol_unsupported"
    #if !APP_ONLY
    case voiceBusy = "voice_busy"
    #endif
    case networkUnavailable = "network_unavailable"
    case unknown

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "房间连接鉴权失败。请重新登录并检查当前房间。"
        #if !APP_ONLY
        case .deviceRevoked:
            return "雷达已解绑或授权已撤销。请重新绑定这台雷达。"
        #endif
        case .protocolUnsupported:
            #if APP_ONLY
            return "App 与房间服务版本不兼容。请更新 App 后重试。"
            #else
            return "App、房间服务或雷达版本不兼容。请更新到同一版本。"
            #endif
        #if !APP_ONLY
        case .voiceBusy:
            return "当前已有成员正在说话，请松开后重试。"
        #endif
        case .networkUnavailable:
            return "网络不可用。请检查蜂窝网络、Wi-Fi 或热点。"
        case .unknown:
            return "房间连接状态未知。请稍后重试。"
        }
    }
}

#if !APP_ONLY
enum BLEError: LocalizedError {
    case unauthorized
    case poweredOff
    case deviceNotConnected
    case characteristicMissing(String)
    case writeFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "蓝牙权限未开启。请到系统设置允许蓝牙。"
        case .poweredOff:
            return "蓝牙未开启。请打开蓝牙后重试。"
        case .deviceNotConnected:
            return "雷达未连接。请先连接雷达。"
        case .characteristicMissing:
            return "雷达连接未准备好。请确认固件版本。"
        case .writeFailed(let detail):
            return "写入雷达失败。\(detail)"
        case .unknown(let detail):
            return detail.isEmpty ? "蓝牙状态未知。请重新连接雷达。" : detail
        }
    }
}
#endif

enum AppError: LocalizedError {
    case room(RoomError)
    case relay(RelayError)
    #if !APP_ONLY
    case ble(BLEError)
    #endif
    case locationPermissionDenied
    case notSignedIn
    case network(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .room(let error):
            return error.localizedDescription
        case .relay(let error):
            return error.localizedDescription
        #if !APP_ONLY
        case .ble(let error):
            return error.localizedDescription
        #endif
        case .locationPermissionDenied:
            return "定位权限不可用。请到“我的 > 隐私与权限”检查定位授权。"
        case .notSignedIn:
            return "请先到“我的”登录账号。"
        case .network(let detail):
            return detail.isEmpty ? "网络请求失败。请检查网络后重试。" : "网络请求失败。\(detail)"
        case .unknown(let detail):
            return detail.isEmpty ? "操作失败。请稍后重试。" : detail
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return networkMessage(for: urlError)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return networkMessage(for: URLError(URLError.Code(rawValue: nsError.code)))
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return AppError.network(error.localizedDescription).localizedDescription
    }

    private static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return "网络不可用。请检查 iPhone 蜂窝网络、Wi-Fi 或热点。"
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
            return "服务暂时不可用。请检查网络后重试。"
        case .badURL, .unsupportedURL:
            return "服务地址配置错误（\(AppEnvironment.current.httpAPIBaseURL)）。请检查 App 环境配置。"
        default:
            return "网络请求失败。\(error.localizedDescription)"
        }
    }
}

enum AppOperationPhase: Equatable {
    case idle
    case loading
    case success(String)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

struct AppOperationResult {
    var succeeded: Bool
    var message: String
}

struct RadarReminderOperationResult {
    var succeeded: Bool
    var message: String
    var cooldownSeconds: Int
}

enum RadarReminderNavigationResult: Equatable {
    case opened
    case unavailable
    case retryable
}

#if !APP_ONLY
struct RadarDevice: Identifiable, Hashable {
    let id: UUID
    var name: String
    var shortId: String
    var deviceID: String
    var deviceToken: String
    var state: DeviceConnectionState
    var battery: Int
    var wifiName: String
    var relayLatency: Int
}

struct DiagnosticItem: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var passed: Bool
}
#endif

@MainActor
@Observable
final class SessionStore {
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let profileDisplayNameKey = "dragonRadar.profile.displayName"
    private static let profileAvatarDataKey = "dragonRadar.profile.avatarData"

    var session: AuthSession?
    var profileDisplayName: String
    var profileAvatarData: Data?

    init(resetPersistentState: Bool = false) {
        if resetPersistentState {
            KeychainAuthStore.delete()
            defaults.removeObject(forKey: Self.profileDisplayNameKey)
            defaults.removeObject(forKey: Self.profileAvatarDataKey)
        }
        session = KeychainAuthStore.load()
        profileDisplayName = defaults.string(forKey: Self.profileDisplayNameKey) ?? ""
        profileAvatarData = defaults.data(forKey: Self.profileAvatarDataKey)
    }

    var isSignedIn: Bool {
        session != nil
    }

    var accessToken: String {
        session?.accessToken ?? ""
    }

    var displayName: String {
        let cleanName = profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            return Self.normalizedDisplayName(cleanName)
        }
        guard let session else { return "未登录" }
        return Self.normalizedDisplayName(session.displayName)
    }

    static func normalizedDisplayName(_ value: String) -> String {
        let cleanName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty
            || cleanName == "胶囊用户"
            || cleanName == "Dragon Radar User"
            || cleanName.hasPrefix("apple:")
        {
            return "Capsule Radar 用户"
        }
        return cleanName
    }

    var avatarData: Data? {
        profileAvatarData
    }

    func apply(_ session: AuthSession) {
        self.session = session
        KeychainAuthStore.save(session)
    }

    func signOut() {
        session = nil
        KeychainAuthStore.delete()
        profileDisplayName = ""
        profileAvatarData = nil
        defaults.removeObject(forKey: Self.profileDisplayNameKey)
        defaults.removeObject(forKey: Self.profileAvatarDataKey)
    }

    func deleteAccountData() {
        signOut()
    }

    func updateProfile(displayName: String, avatarData: Data?) {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profileDisplayName = cleanName
        profileAvatarData = avatarData
        if cleanName.isEmpty {
            defaults.removeObject(forKey: Self.profileDisplayNameKey)
        } else {
            defaults.set(cleanName, forKey: Self.profileDisplayNameKey)
        }
        if let avatarData {
            defaults.set(avatarData, forKey: Self.profileAvatarDataKey)
        } else {
            defaults.removeObject(forKey: Self.profileAvatarDataKey)
        }
    }
}

struct AuthSession: Codable, Hashable {
    var userID: String
    var displayName: String
    var appleUserID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

@MainActor
@Observable
final class RoomsStore {
    @ObservationIgnored private var relayMemberIDs: [String: UUID] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    private static let activeRoomIDKey = "dragonRadar.rooms.activeRoomID"
    private static let activeRoomNameKey = "dragonRadar.rooms.activeRoomName"
    private static let activeRoomCodeKey = "dragonRadar.rooms.activeRoomCode"

    var activeRoomID: UUID
    var rooms: [RadarRoom] = []

    var activeRoomName: String
    var inviteCode: String
    var roomCapacity = 7
    var roomOnlineGroups = 0
    var roomLatency = 0
    var roomStatus = "等待房间"
    var locationHealth = "定位有效"
    var members: [RoomMember] = []

    init(resetPersistentState: Bool = false) {
        if resetPersistentState {
            Self.clearPersistedState(defaults: defaults)
        }
        let storedRoomID = defaults.string(forKey: Self.activeRoomIDKey).flatMap(UUID.init(uuidString:))
        let storedCode = defaults.string(forKey: Self.activeRoomCodeKey)
        activeRoomID = storedRoomID ?? UUID()
        inviteCode = storedCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? storedCode! : ""
        activeRoomName = defaults.string(forKey: Self.activeRoomNameKey) ?? ""
        if !inviteCode.isEmpty {
            syncActiveRoomSnapshot()
        }
    }

    var onlineMembers: Int {
        max(roomOnlineGroups, members.filter(\.isOnline).count)
    }

    #if !APP_ONLY
    var activeSpeakers: [RoomMember] {
        members.filter { $0.isSpeaking && $0.isOnline }
    }
    #endif

    func createRoom(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        syncActiveRoomSnapshot()
        activeRoomID = UUID()
        activeRoomName = trimmedName
        inviteCode = Self.makeInviteCode()
        roomOnlineGroups = 0
        roomLatency = 0
        roomStatus = "等待房间"
        members = []
        persistActiveRoom()
        syncActiveRoomSnapshot()
    }

    func joinRoom(code: String) {
        let normalizedCode = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalizedCode.isEmpty else { return }
        if let existingRoom = rooms.first(where: { $0.inviteCode == normalizedCode }) {
            switchRoom(to: existingRoom.id)
            return
        }
        syncActiveRoomSnapshot()
        activeRoomID = UUID()
        inviteCode = normalizedCode
        activeRoomName = "房间 \(normalizedCode)"
        roomOnlineGroups = 0
        roomLatency = 0
        roomStatus = "等待房间"
        members = []
        persistActiveRoom()
        syncActiveRoomSnapshot()
    }

    func switchRoom(to roomID: RadarRoom.ID) {
        guard roomID != activeRoomID, let room = rooms.first(where: { $0.id == roomID }) else { return }
        syncActiveRoomSnapshot()
        activeRoomID = room.id
        activeRoomName = room.name
        inviteCode = room.inviteCode
        roomCapacity = room.capacity
        roomOnlineGroups = room.onlineGroups
        roomLatency = room.latency
        roomStatus = "等待房间"
        members = []
        persistActiveRoom()
        syncActiveRoomSnapshot()
    }

    func renameActiveRoom(to name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        activeRoomName = cleanName
        persistActiveRoom()
        syncActiveRoomSnapshot()
    }

    func applyServerRoom(_ room: ServerRoom) {
        let existingID = rooms.first(where: { $0.inviteCode == room.roomCode })?.id
        activeRoomID = existingID ?? (room.roomCode == inviteCode ? activeRoomID : UUID())
        activeRoomName = room.name
        inviteCode = room.roomCode
        roomCapacity = room.maxMembers
        roomOnlineGroups = room.onlineGroups ?? roomOnlineGroups
        roomLatency = 0
        roomStatus = room.memberCount > 0 ? "等待房间" : "等待成员"
        members = []
        persistActiveRoom()
        syncActiveRoomSnapshot()
    }

    func applyServerRooms(_ serverRooms: [ServerRoom]) {
        let visibleServerRooms = Self.deduplicateServerRooms(serverRooms, activeCode: inviteCode)
        guard !visibleServerRooms.isEmpty else {
            clearRooms()
            return
        }
        let existingByCode = Dictionary(uniqueKeysWithValues: rooms.map { ($0.inviteCode, $0) })
        let activeCode = inviteCode
        rooms = visibleServerRooms.map { room in
            let existing = existingByCode[room.roomCode]
            return RadarRoom(
                id: existing?.id ?? UUID(),
                name: room.name,
                inviteCode: room.roomCode,
                capacity: room.maxMembers,
                onlineGroups: room.onlineGroups ?? existing?.onlineGroups ?? 0,
                latency: existing?.latency ?? 0,
                roomStatus: existing?.roomStatus ?? "等待房间",
                members: room.roomCode == activeCode ? members : []
            )
        }

        let selected = rooms.first(where: { $0.inviteCode == activeCode }) ?? rooms[0]
        activeRoomID = selected.id
        activeRoomName = selected.name
        inviteCode = selected.inviteCode
        roomCapacity = selected.capacity
        roomOnlineGroups = selected.onlineGroups
        roomLatency = selected.latency
        roomStatus = selected.roomStatus
        if selected.inviteCode != activeCode {
            members = []
        }
        persistActiveRoom()
        syncActiveRoomSnapshot()
    }

    private static func deduplicateServerRooms(_ serverRooms: [ServerRoom], activeCode: String) -> [ServerRoom] {
        var result: [ServerRoom] = []
        var seenNameKeys = Set<String>()

        if let activeRoom = serverRooms.first(where: { $0.roomCode == activeCode }) {
            result.append(activeRoom)
            seenNameKeys.insert(roomNameKey(activeRoom.name, fallback: activeRoom.roomCode))
        }

        for room in serverRooms {
            if room.roomCode == activeCode {
                continue
            }
            let key = roomNameKey(room.name, fallback: room.roomCode)
            guard !seenNameKeys.contains(key) else {
                continue
            }
            seenNameKeys.insert(key)
            result.append(room)
        }

        return result
    }

    private static func roomNameKey(_ name: String, fallback: String) -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty {
            return "code:\(fallback)"
        }
        return "name:\(cleanName.lowercased())"
    }

    func syncActiveRoomSnapshot() {
        guard !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            rooms = []
            return
        }
        let snapshot = RadarRoom(
            id: activeRoomID,
            name: activeRoomName,
            inviteCode: inviteCode,
            capacity: roomCapacity,
            onlineGroups: max(roomOnlineGroups, members.filter(\.isOnline).count),
            latency: roomLatency,
            roomStatus: roomStatus,
            members: members
        )
        if let index = rooms.firstIndex(where: { $0.id == activeRoomID }) {
            rooms[index] = snapshot
        } else {
            rooms.insert(snapshot, at: 0)
        }
    }

    func clearRooms() {
        rooms = []
        members = []
        activeRoomID = UUID()
        activeRoomName = ""
        inviteCode = ""
        roomCapacity = 7
        roomOnlineGroups = 0
        roomLatency = 0
        roomStatus = "等待房间"
        locationHealth = "等待房间"
        Self.clearPersistedState(defaults: defaults)
    }

    func clearRelayRoomMembers() {
        members = []
        roomOnlineGroups = 0
        roomStatus = "等待房间"
        syncActiveRoomSnapshot()
    }

    func removeModerationMember(reference: String) {
        guard !reference.isEmpty else { return }
        members.removeAll { $0.moderationRef == reference }
        roomOnlineGroups = min(roomOnlineGroups, members.count)
        syncActiveRoomSnapshot()
    }

    func removeRooms(withCodes codes: Set<String>) {
        guard !codes.isEmpty else { return }
        let normalizedCodes = Set(codes.map { $0.uppercased() })
        rooms.removeAll { normalizedCodes.contains($0.inviteCode.uppercased()) }
        guard !normalizedCodes.contains(inviteCode.uppercased()) else {
            if let nextRoom = rooms.first {
                activeRoomID = nextRoom.id
                activeRoomName = nextRoom.name
                inviteCode = nextRoom.inviteCode
                roomCapacity = nextRoom.capacity
                roomOnlineGroups = nextRoom.onlineGroups
                roomLatency = nextRoom.latency
                roomStatus = nextRoom.roomStatus
                members = nextRoom.members
                persistActiveRoom()
                syncActiveRoomSnapshot()
            } else {
                clearRooms()
            }
            return
        }
        syncActiveRoomSnapshot()
    }

    func applyRelayRoomState(
        _ snapshot: RelayRoomStateSnapshot,
        localAppPeerID: String,
        localDisplayName: String? = nil
    ) {
        roomCapacity = snapshot.maxMembers
        inviteCode = snapshot.room
        roomStatus = roomStatusText(snapshot)
        locationHealth = locationHealthText(snapshot)

        #if APP_ONLY
        let visibleMembers = snapshot.members.filter { $0.role == "app" }
        #else
        let visibleMembers = snapshot.members
        #endif
        roomOnlineGroups = visibleMembers.count
        let localMember = visibleMembers.first(where: { $0.peerID == localAppPeerID })
        let localCoordinate = localMember?.locationStale == true ? nil : localMember?.location
        let localModerationRef = localMember?.moderationRef
        members = visibleMembers.prefix(snapshot.maxMembers).map { member in
            #if APP_ONLY
            makeRoomMember(
                from: member,
                localCoordinate: localCoordinate,
                localAppPeerID: localAppPeerID,
                localModerationRef: localModerationRef,
                localDisplayName: localDisplayName
            )
            #else
            makeRoomMember(
                from: member,
                localCoordinate: localCoordinate,
                localAppPeerID: localAppPeerID,
                localModerationRef: localModerationRef,
                localDisplayName: localDisplayName,
                voiceFloor: snapshot.voiceFloor
            )
            #endif
        }
        persistActiveRoom()
        syncActiveRoomSnapshot()
    }

    private func persistActiveRoom() {
        defaults.set(activeRoomID.uuidString, forKey: Self.activeRoomIDKey)
        defaults.set(activeRoomName, forKey: Self.activeRoomNameKey)
        defaults.set(inviteCode, forKey: Self.activeRoomCodeKey)
    }

    private static func clearPersistedState(defaults: UserDefaults) {
        defaults.removeObject(forKey: activeRoomIDKey)
        defaults.removeObject(forKey: activeRoomNameKey)
        defaults.removeObject(forKey: activeRoomCodeKey)
    }

    #if APP_ONLY
    private func makeRoomMember(
        from relayMember: RelayRoomMemberSnapshot,
        localCoordinate: RelayLocationSnapshot?,
        localAppPeerID: String,
        localModerationRef: String?,
        localDisplayName: String?
    ) -> RoomMember {
        let isLocal = relayMember.peerID == localAppPeerID
        let moderationRef = relayMember.moderationRef ?? ""
        let isCurrentUser = isLocal || (
            !moderationRef.isEmpty
                && localModerationRef?.isEmpty == false
                && moderationRef == localModerationRef
        )
        let relation = relativeLocationText(
            member: relayMember,
            localCoordinate: localCoordinate,
            isLocal: isLocal
        )
        return RoomMember(
            id: stableID(for: relayMember.peerID),
            name: displayName(
                for: relayMember,
                isLocal: isLocal,
                localDisplayName: localDisplayName
            ),
            distance: relation.distance,
            bearing: relation.bearing,
            accuracy: accuracyText(
                for: relayMember.location,
                paused: relayMember.locationPaused == true,
                stale: relayMember.locationStale == true
            ),
            locationPaused: relayMember.locationPaused == true,
            isOnline: relayMember.online,
            lastUpdate: lastUpdateText(milliseconds: relayMember.lastSeenMS),
            moderationRef: moderationRef,
            role: relayMember.role,
            isLocal: isLocal,
            isCurrentUser: isCurrentUser
        )
    }
    #else
    private func makeRoomMember(
        from relayMember: RelayRoomMemberSnapshot,
        localCoordinate: RelayLocationSnapshot?,
        localAppPeerID: String,
        localModerationRef: String?,
        localDisplayName: String?,
        voiceFloor: RelayVoiceFloorSnapshot?
    ) -> RoomMember {
        let isLocal = relayMember.peerID == localAppPeerID
        let moderationRef = relayMember.moderationRef ?? ""
        let isCurrentUser = isLocal || (
            !moderationRef.isEmpty
                && localModerationRef?.isEmpty == false
                && moderationRef == localModerationRef
        )
        let relation = relativeLocationText(
            member: relayMember,
            localCoordinate: localCoordinate,
            isLocal: isLocal
        )
        let rssi = relayMember.deviceStatus?.rssi ?? -999
        return RoomMember(
            id: stableID(for: relayMember.peerID),
            name: displayName(
                for: relayMember,
                isLocal: isLocal,
                localDisplayName: localDisplayName
            ),
            distance: relation.distance,
            bearing: relation.bearing,
            accuracy: accuracyText(
                for: relayMember.location,
                paused: relayMember.locationPaused == true,
                stale: relayMember.locationStale == true
            ),
            locationPaused: relayMember.locationPaused == true,
            isOnline: relayMember.online,
            isSpeaking: isVoiceActive(relayMember, voiceFloor: voiceFloor),
            isMuted: relayMember.voiceStatus?.muted == true,
            voiceStatusText: voiceStatusText(for: relayMember, voiceFloor: voiceFloor),
            voiceCountdownText: voiceCountdownText(for: relayMember, voiceFloor: voiceFloor),
            voiceHealthText: voiceHealthText(for: relayMember.voiceStatus),
            deviceBattery: relayMember.deviceStatus?.batteryPercentValue ?? -1,
            wifiRSSI: rssi,
            firmware: relayMember.firmware ?? relayMember.lastType,
            lastUpdate: lastUpdateText(milliseconds: relayMember.lastSeenMS),
            moderationRef: moderationRef,
            role: relayMember.role,
            isLocal: isLocal,
            isCurrentUser: isCurrentUser
        )
    }
    #endif

    private func roomStatusText(_ snapshot: RelayRoomStateSnapshot) -> String {
        #if APP_ONLY
        let relevantMembers = snapshot.members.filter { $0.role == "app" }
        #else
        let relevantMembers = snapshot.members
        #endif
        guard !relevantMembers.isEmpty else {
            return "等待成员"
        }
        #if APP_ONLY
        return "成员在线"
        #else
        guard snapshot.voiceFloor?.active == true else {
            return "成员在线"
        }
        let speakerGroupID = snapshot.voiceFloor?.speakerGroupID
        let speakerName = snapshot.members.first { member in
            member.memberID == speakerGroupID || member.peerID == snapshot.voiceFloor?.speakerPeerID
        }?.name
        if let speakerName, !speakerName.isEmpty {
            return "\(speakerName) 说话中"
        }
        return "有人说话"
        #endif
    }

    private func locationHealthText(_ snapshot: RelayRoomStateSnapshot) -> String {
        #if APP_ONLY
        let relevantMembers = snapshot.members.filter { $0.role == "app" }
        #else
        let relevantMembers = snapshot.members
        #endif
        guard !relevantMembers.isEmpty else {
            return "等待成员"
        }
        if relevantMembers.contains(where: { $0.locationPaused == true }) {
            return "有成员暂停定位"
        }
        if relevantMembers.contains(where: { $0.locationStale == true }) {
            return "有成员定位过期"
        }
        if relevantMembers.contains(where: { $0.location != nil }) {
            return "定位有效"
        }
        return "等待定位"
    }

    private func stableID(for peerID: String) -> UUID {
        if let existing = relayMemberIDs[peerID] {
            return existing
        }
        let id = UUID()
        relayMemberIDs[peerID] = id
        return id
    }

    private func displayName(
        for member: RelayRoomMemberSnapshot,
        isLocal: Bool,
        localDisplayName: String?
    ) -> String {
        if isLocal,
           let localDisplayName,
           !localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = member.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let suffix = member.peerID.count > 6 ? String(member.peerID.suffix(6)) : member.peerID
        #if APP_ONLY
        return "手机 \(suffix)"
        #else
        return member.role == "device" ? "雷达 \(suffix)" : "手机 \(suffix)"
        #endif
    }

    private func relativeLocationText(
        member: RelayRoomMemberSnapshot,
        localCoordinate: RelayLocationSnapshot?,
        isLocal: Bool
    ) -> (distance: String, bearing: String) {
        if member.locationPaused == true {
            return ("定位已暂停", "隐私")
        }
        if member.locationStale == true {
            return ("定位已过期", staleLocationText(milliseconds: member.locationAgeMS))
        }
        if isLocal {
            return ("本机", "0°")
        }
        guard
            let localLat = localCoordinate?.latE7,
            let localLon = localCoordinate?.lonE7,
            let remoteLat = member.location?.latE7,
            let remoteLon = member.location?.lonE7
        else {
            #if APP_ONLY
            return ("等待定位", "手机")
            #else
            return ("等待定位", member.role == "device" ? "雷达" : "手机")
            #endif
        }

        let distance = haversineMeters(
            lat1: Double(localLat) / 10_000_000,
            lon1: Double(localLon) / 10_000_000,
            lat2: Double(remoteLat) / 10_000_000,
            lon2: Double(remoteLon) / 10_000_000
        )
        let bearing = bearingDegrees(
            lat1: Double(localLat) / 10_000_000,
            lon1: Double(localLon) / 10_000_000,
            lat2: Double(remoteLat) / 10_000_000,
            lon2: Double(remoteLon) / 10_000_000
        )
        return (formatDistance(meters: distance), "\(cardinalDirection(for: bearing)) \(Int(bearing.rounded()))°")
    }

    private func accuracyText(for location: RelayLocationSnapshot?, paused: Bool, stale: Bool) -> String {
        if paused {
            return "已暂停"
        }
        if stale {
            return "过期"
        }
        guard let centimeters = location?.horizontalAccuracyCM else {
            return "未知"
        }
        return "±\(max(1, centimeters / 100))m"
    }

    private func staleLocationText(milliseconds: Int?) -> String {
        guard let milliseconds else {
            return "旧坐标"
        }
        return "旧坐标 \(lastUpdateText(milliseconds: milliseconds))"
    }

    #if !APP_ONLY
    private func isVoiceActive(_ member: RelayRoomMemberSnapshot, voiceFloor: RelayVoiceFloorSnapshot?) -> Bool {
        if member.voiceStatus?.muted == true {
            return false
        }
        if voiceFloor?.active == true {
            return member.memberID == voiceFloor?.speakerGroupID
                || member.peerID == voiceFloor?.speakerPeerID
                || member.voiceStatus?.speaker == true
                || member.voiceStatus?.floorGranted == true
        }
        if member.voiceStatus?.speaker == true || member.voiceStatus?.floorGranted == true {
            return true
        }
        if let ptt = member.voiceStatus?.ptt, ptt {
            return true
        }
        if let vad = member.voiceStatus?.vad {
            return vad
        }
        return member.lastType == "voice_frame" || member.lastType == "audio_frame"
    }

    private func voiceStatusText(
        for member: RelayRoomMemberSnapshot,
        voiceFloor: RelayVoiceFloorSnapshot?
    ) -> String {
        if member.voiceStatus?.muted == true {
            return "已静音"
        }
        if voiceFloor?.active == true {
            if member.memberID == voiceFloor?.speakerGroupID || member.peerID == voiceFloor?.speakerPeerID {
                return "正在说话"
            }
            if member.voiceStatus?.ptt == true {
                return "等待发言权"
            }
        }
        if member.voiceStatus?.speaker == true || member.voiceStatus?.floorGranted == true {
            return "发言权已授予"
        }
        if member.voiceStatus?.ptt == true {
            return "按键中"
        }
        if member.voiceStatus?.vad == true {
            return "检测到语音"
        }
        return "空闲"
    }

    private func voiceCountdownText(
        for member: RelayRoomMemberSnapshot,
        voiceFloor: RelayVoiceFloorSnapshot?
    ) -> String {
        guard
            voiceFloor?.active == true,
            member.memberID == voiceFloor?.speakerGroupID || member.peerID == voiceFloor?.speakerPeerID
        else {
            return ""
        }
        let milliseconds = max(0, voiceFloor?.expiresInMS ?? 0)
        if milliseconds >= 1_000 {
            return String(format: "剩余 %.1fs", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds)ms"
    }

    private func voiceHealthText(for status: RelayVoiceStatusSnapshot?) -> String {
        guard let status else {
            return "等待 voice_status"
        }
        var parts: [String] = []
        if let codec = status.codec, !codec.isEmpty {
            parts.append(codec)
        }
        if let sampleRate = status.sampleRate {
            parts.append("\(sampleRate / 1_000)kHz")
        }
        if let frameMS = status.frameMS {
            parts.append("\(frameMS)ms")
        }
        if let sequence = status.sequence {
            parts.append("上行 #\(sequence)")
        }
        if let receivedSequence = status.receivedSequence {
            parts.append("下行 #\(receivedSequence)")
        }
        if let lostFrames = status.lostFrames, lostFrames > 0 {
            parts.append("丢帧 \(lostFrames)")
        }
        if let rms = status.rms {
            parts.append("RMS \(rms)")
        }
        if let peak = status.peak {
            parts.append("Peak \(peak)")
        }
        return parts.isEmpty ? "voice_status 已收到" : parts.joined(separator: " · ")
    }
    #endif

    private func lastUpdateText(milliseconds: Int) -> String {
        if milliseconds < 2_000 {
            return "刚刚"
        }
        let seconds = milliseconds / 1_000
        if seconds < 60 {
            return "\(seconds) 秒前"
        }
        return "\(seconds / 60) 分钟前"
    }

    private func formatDistance(meters: Double) -> String {
        if meters < 1_000 {
            return "\(Int(meters.rounded()))m"
        }
        return String(format: "%.1fkm", meters / 1_000)
    }

    private func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let radius = 6_371_000.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaPhi = (lat2 - lat1) * .pi / 180
        let deltaLambda = (lon2 - lon1) * .pi / 180
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func bearingDegrees(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaLambda = (lon2 - lon1) * .pi / 180
        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    private func cardinalDirection(for degrees: Double) -> String {
        let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let index = Int(((degrees + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return directions[index]
    }

    private static func makeInviteCode() -> String {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let suffix = String((0..<4).compactMap { _ in letters.randomElement() })
        return "CAPS-\(suffix)"
    }
}

#if !APP_ONLY
@MainActor
@Observable
final class DevicesStore {
    @ObservationIgnored private let defaults = UserDefaults.standard

    private static let activeDeviceShortIDKey = "dragonRadar.devices.activeShortID"
    private static let activeDeviceNameKey = "dragonRadar.devices.activeName"
    private static let activeDeviceWifiKey = "dragonRadar.devices.activeWifi"
    private static let activeDeviceIDKey = "dragonRadar.devices.activeDeviceID"
    private static let activeDeviceTokenKey = "dragonRadar.devices.activeDeviceToken"

    var devices: [RadarDevice]

    init(resetPersistentState: Bool = false) {
        if resetPersistentState {
            Self.clearPersistedState(defaults: defaults)
        }
        let shortID = defaults.string(forKey: Self.activeDeviceShortIDKey) ?? ""
        let wifi = defaults.string(forKey: Self.activeDeviceWifiKey) ?? "未同步"
        let deviceID = defaults.string(forKey: Self.activeDeviceIDKey) ?? ""
        let legacyDeviceToken = defaults.string(forKey: Self.activeDeviceTokenKey) ?? ""
        let keychainDeviceToken = KeychainDeviceCredentialStore.load()
        let deviceToken = keychainDeviceToken.isEmpty ? legacyDeviceToken : keychainDeviceToken
        if keychainDeviceToken.isEmpty, !legacyDeviceToken.isEmpty {
            KeychainDeviceCredentialStore.save(legacyDeviceToken)
        }
        defaults.removeObject(forKey: Self.activeDeviceTokenKey)
        if deviceID.isEmpty && deviceToken.isEmpty && shortID.isEmpty {
            devices = []
        } else {
            let name = defaults.string(forKey: Self.activeDeviceNameKey) ?? "雷达 \(shortID)"
            devices = [
                RadarDevice(
                    id: UUID(),
                    name: name,
                    shortId: shortID,
                    deviceID: deviceID,
                    deviceToken: deviceToken,
                    state: .offline,
                    battery: -1,
                    wifiName: wifi,
                    relayLatency: 0
                )
            ]
        }
    }

    var activeDevice: RadarDevice? {
        devices.first
    }

    var activeDeviceToken: String {
        let token = activeDevice?.deviceToken.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token
    }

    func applyWifiConfig(ssid: String) {
        guard !devices.isEmpty else { return }
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[0].wifiName = cleanSSID.isEmpty ? "未配置" : cleanSSID
        defaults.set(devices[0].wifiName, forKey: Self.activeDeviceWifiKey)
    }

    func markPairingComplete() {
        guard !devices.isEmpty else { return }
        devices[0].state = .cloudConnected
        defaults.set(devices[0].shortId, forKey: Self.activeDeviceShortIDKey)
        defaults.set(devices[0].name, forKey: Self.activeDeviceNameKey)
        defaults.set(devices[0].deviceID, forKey: Self.activeDeviceIDKey)
        KeychainDeviceCredentialStore.save(devices[0].deviceToken)
    }

    func applyServerDevice(_ device: ServerDevice) {
        if devices.isEmpty {
            devices = [
                RadarDevice(
                    id: UUID(),
                    name: "",
                    shortId: "",
                    deviceID: "",
                    deviceToken: "",
                    state: .offline,
                    battery: -1,
                    wifiName: "未同步",
                    relayLatency: 0
                )
            ]
        }
        devices[0].name = device.name.isEmpty ? "CapsuleRadar-\(device.deviceShortID)" : device.name
        devices[0].shortId = device.deviceShortID
        devices[0].deviceID = device.deviceID
        devices[0].deviceToken = device.deviceToken
        devices[0].state = .cloudConnected
        defaults.set(devices[0].name, forKey: Self.activeDeviceNameKey)
        defaults.set(devices[0].shortId, forKey: Self.activeDeviceShortIDKey)
        defaults.set(devices[0].deviceID, forKey: Self.activeDeviceIDKey)
        KeychainDeviceCredentialStore.save(devices[0].deviceToken)
    }

    func updateRelayLatency(_ latency: Int) {
        guard !devices.isEmpty else { return }
        devices[0].relayLatency = latency
        if devices[0].state != .wifiConnected {
            devices[0].state = .cloudConnected
        }
    }

    func updateBattery(percent: Int?) {
        guard !devices.isEmpty else { return }
        devices[0].battery = percent ?? -1
    }

    func clearDevices() {
        devices = []
        Self.clearPersistedState(defaults: defaults)
    }

    private static func clearPersistedState(defaults: UserDefaults) {
        defaults.removeObject(forKey: activeDeviceShortIDKey)
        defaults.removeObject(forKey: activeDeviceNameKey)
        defaults.removeObject(forKey: activeDeviceWifiKey)
        defaults.removeObject(forKey: activeDeviceIDKey)
        defaults.removeObject(forKey: activeDeviceTokenKey)
        KeychainDeviceCredentialStore.delete()
    }
}

@MainActor
@Observable
final class DiagnosticsStore {
    private var diagnosticsRunCount = 0

    var diagnostics: [DiagnosticItem] = [
        DiagnosticItem(title: "连接雷达", detail: "未运行", passed: false),
        DiagnosticItem(title: "Wi-Fi", detail: "未运行", passed: false),
        DiagnosticItem(title: "后端网络", detail: "未运行", passed: false),
        DiagnosticItem(title: "当前房间", detail: "未进入房间", passed: true),
        DiagnosticItem(title: "定位", detail: "未运行", passed: false),
        DiagnosticItem(title: "语音占用", detail: "未运行", passed: false),
        DiagnosticItem(title: "语音接收", detail: "未运行", passed: false)
    ]

    func applyWifiConfig(ssid: String) {
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics[1].detail = "\(cleanSSID.isEmpty ? "未配置" : cleanSSID) · 等待雷达确认"
        diagnostics[1].passed = !cleanSSID.isEmpty
    }

    func run(activeDevice: RadarDevice?, backendReady: Bool, roomCode: String, roomLatency: Int) {
        diagnosticsRunCount += 1
        let cleanRoomCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRoom = !cleanRoomCode.isEmpty
        diagnostics = [
            DiagnosticItem(title: "连接雷达", detail: "\(activeDevice?.name ?? "雷达") · 等待连接状态", passed: activeDevice != nil),
            DiagnosticItem(title: "Wi-Fi", detail: "\(activeDevice?.wifiName ?? "未配置") · 等待雷达确认", passed: activeDevice?.wifiName != "未同步"),
            DiagnosticItem(title: "账号网络", detail: backendReady ? "已连接" : "未登录或登录失效", passed: backendReady),
            DiagnosticItem(
                title: "当前房间",
                detail: hasRoom ? (roomLatency > 0 ? "\(cleanRoomCode) · \(roomLatency)ms" : "\(cleanRoomCode) · 等待成员同步") : "未进入房间 · 网络仍可正常连接",
                passed: hasRoom ? roomLatency > 0 : true
            ),
            DiagnosticItem(title: "定位", detail: "等待 iPhone 定位桥接", passed: false),
            DiagnosticItem(title: "语音占用", detail: "等待房间语音状态", passed: false),
            DiagnosticItem(title: "语音接收", detail: "等待雷达语音状态", passed: false)
        ]
    }
}
#endif

@MainActor
@Observable
final class RoomsRepository {
    var httpBaseURL = AppEnvironment.current.httpAPIBaseURL
    var accessToken = ""
    #if DEBUG
    var uiTestingScenario: RoomsRepositoryUITestingScenario?
    #endif

    func listRooms() async throws -> [ServerRoom] {
        let data = try await request(path: "/v1/rooms", method: "GET")
        return try JSONDecoder().decode(ServerRoomsEnvelope.self, from: data).rooms
    }

    func createRoom(named name: String) async throws -> ServerRoom {
        try await requestRoom(path: "/v1/rooms", method: "POST", payload: ["name": name])
    }

    func joinRoom(code: String) async throws -> ServerRoom {
        #if DEBUG
        if uiTestingScenario == .roomFull {
            throw RoomRepositoryError.server(code: "room_full", detail: nil)
        }
        #endif
        return try await requestRoom(path: "/v1/rooms/join", method: "POST", payload: ["room_code": code])
    }

    func renameRoom(code: String, name: String) async throws -> ServerRoom {
        try await requestRoom(path: "/v1/rooms/\(code)", method: "PATCH", payload: ["name": name])
    }

    func removeMember(roomCode: String, memberID: String) async throws -> ServerRoom {
        try await requestRoom(path: "/v1/rooms/\(roomCode)/members/\(memberID)", method: "DELETE")
    }

    func deleteRoom(code: String) async throws {
        _ = try await request(path: "/v1/rooms/\(code)", method: "DELETE")
    }

    func sendRadarReminder(roomCode: String, requestID: String) async throws -> RadarReminderReceipt {
        let data = try await request(
            path: "/v1/rooms/\(roomCode)/radar-reminders",
            method: "POST",
            payload: ["request_id": requestID]
        )
        return try JSONDecoder().decode(RadarReminderEnvelope.self, from: data).reminder
    }

    private func requestRoom(path: String, method: String, payload: [String: String]? = nil) async throws -> ServerRoom {
        let data = try await request(path: path, method: method, payload: payload)
        return try JSONDecoder().decode(ServerRoomEnvelope.self, from: data).room
    }

    private func request(path: String, method: String, payload: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: httpBaseURL + path) else {
            throw URLError(.badURL)
        }
        guard !accessToken.isEmpty else {
            throw RoomRepositoryError.server(code: "unauthorized", detail: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RoomRepositoryError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                if http.statusCode == 429 {
                    let headerRetryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                    throw RoomRepositoryError.rateLimited(
                        code: error.code,
                        detail: error.detail,
                        retryAfter: error.retryAfter ?? headerRetryAfter ?? 1
                    )
                }
                throw RoomRepositoryError.server(code: error.code, detail: error.detail)
            }
            throw RoomRepositoryError.badResponse
        }
        return data
    }
}

#if DEBUG
enum RoomsRepositoryUITestingScenario {
    case roomFull
}
#endif

#if !APP_ONLY
@MainActor
@Observable
final class DevicesRepository {
    var httpBaseURL = AppEnvironment.current.httpAPIBaseURL
    var accessToken = ""

    func listDevices() async throws -> [ServerDevice] {
        let data = try await request(path: "/v1/devices", method: "GET")
        return try JSONDecoder().decode(ServerDevicesEnvelope.self, from: data).devices
    }

    func registerDevice(pairingChallenge: String, name: String) async throws -> ServerDevice {
        let payload = [
            "pairing_challenge": pairingChallenge,
            "name": name
        ]
        let data = try await request(path: "/v1/devices/register-challenge", method: "POST", payload: payload)
        return try JSONDecoder().decode(ServerDeviceEnvelope.self, from: data).device
    }

    func revokeDevice(deviceID: String) async throws {
        let cleanDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDeviceID.isEmpty else { return }
        _ = try await request(path: "/v1/devices/\(cleanDeviceID)", method: "DELETE")
    }

    private func request(path: String, method: String, payload: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: httpBaseURL + path) else {
            throw URLError(.badURL)
        }
        guard !accessToken.isEmpty else {
            throw RoomRepositoryError.server(code: "unauthorized", detail: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RoomRepositoryError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw RoomRepositoryError.server(code: error.code, detail: error.detail)
            }
            throw RoomRepositoryError.badResponse
        }
        return data
    }
}
#endif

@MainActor
@Observable
final class AppState {
    var sessionStore: SessionStore
    var roomsStore: RoomsStore
    #if !APP_ONLY
    var devicesStore: DevicesStore
    var diagnosticsStore = DiagnosticsStore()
    #endif
    var roomsRepository = RoomsRepository()
    #if !APP_ONLY
    var devicesRepository = DevicesRepository()
    #endif
    var authRepository = AuthRepository()
    var moderationRepository = ModerationRepository()
    var reviewExperience = ReviewExperience()

    var selectedTab: AppTab = .rooms
    var selectedMember: RoomMember?
    #if !APP_ONLY
    var showPairingSheet = false
    var showWifiSheet = false
    #endif
    var showJoinRoomSheet = false
    var showCreateRoomSheet = false
    var focusedMemberID: RoomMember.ID?
    var lastRoomAPIEvent = "房间 API 尚未同步"
    var blockedUsers: [UserBlockRecord] = []
    var sessionRestorationCompleted = false
    @ObservationIgnored private var radarReminderCooldowns: [String: Date] = [:]
    private var stateRevision = 0

    var activeRoomID: UUID { tracked { roomsStore.activeRoomID } }
    var rooms: [RadarRoom] { tracked { roomsStore.rooms } }
    var activeRoomName: String {
        tracked { reviewExperience.isActive ? reviewExperience.room.name : roomsStore.activeRoomName }
    }
    var inviteCode: String { tracked { roomsStore.inviteCode } }
    var displayRoomCode: String {
        tracked { reviewExperience.isActive ? reviewExperience.room.inviteCode : roomsStore.inviteCode }
    }
    var roomCapacity: Int {
        tracked { reviewExperience.isActive ? reviewExperience.room.capacity : roomsStore.roomCapacity }
    }
    var roomLatency: Int {
        tracked { reviewExperience.isActive ? reviewExperience.room.latency : roomsStore.roomLatency }
    }
    var roomStatus: String {
        tracked { reviewExperience.isActive ? reviewExperience.room.roomStatus : roomsStore.roomStatus }
    }
    var locationHealth: String {
        tracked { reviewExperience.isActive ? "本地演示未使用定位" : roomsStore.locationHealth }
    }
    var members: [RoomMember] {
        tracked { reviewExperience.isActive ? reviewExperience.room.members : roomsStore.members }
    }
    var onlineMembers: Int {
        tracked { reviewExperience.isActive ? reviewExperience.room.onlineMembers : roomsStore.onlineMembers }
    }
    #if !APP_ONLY
    var activeSpeakers: [RoomMember] {
        tracked {
            reviewExperience.isActive
                ? reviewExperience.room.members.filter { $0.isSpeaking && $0.isOnline }
                : roomsStore.activeSpeakers
        }
    }
    #endif
    var isReviewExperienceActive: Bool { tracked { reviewExperience.isActive } }
    #if !APP_ONLY
    var devices: [RadarDevice] { tracked { devicesStore.devices } }
    var activeDevice: RadarDevice? { tracked { devicesStore.activeDevice } }
    var activeDeviceToken: String { tracked { devicesStore.activeDeviceToken } }
    var diagnostics: [DiagnosticItem] { tracked { diagnosticsStore.diagnostics } }
    #endif
    var isSignedIn: Bool { tracked { sessionStore.isSignedIn } }
    var displayName: String { tracked { sessionStore.displayName } }
    var profileAvatarData: Data? { tracked { sessionStore.avatarData } }
    var accessToken: String { tracked { sessionStore.accessToken } }

    init(resetPersistentState: Bool = false) {
        if resetPersistentState {
            KeychainPendingSessionRevocationStore.delete()
        }
        sessionStore = SessionStore(resetPersistentState: resetPersistentState)
        roomsStore = RoomsStore(resetPersistentState: resetPersistentState)
        #if !APP_ONLY
        devicesStore = DevicesStore(resetPersistentState: resetPersistentState)
        #endif
        syncAuthenticatedRepositories()
        #if DEBUG
        configureUITestingStateIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("DRAGON_RADAR_UI_TESTING") {
            sessionRestorationCompleted = true
        }
        #endif
    }

    func startReviewExperience() {
        guard isSignedIn, !reviewExperience.isActive else { return }
        reviewExperience.start(displayName: displayName)
        selectedMember = nil
        focusedMemberID = nil
        selectedTab = .radar
        lastRoomAPIEvent = "已进入本地雷达演示 · 未连接服务器"
        bump()
    }

    func stopReviewExperience() {
        guard reviewExperience.isActive else { return }
        reviewExperience.stop()
        selectedMember = nil
        focusedMemberID = nil
        selectedTab = .rooms
        lastRoomAPIEvent = roomsStore.inviteCode.isEmpty ? "已退出本地雷达演示" : "已恢复服务器房间"
        bump()
    }

    func signInForDevelopment() {
        Task { _ = await signInForDevelopmentAndWait() }
    }

    func signInForDevelopmentAndWait() async -> AppOperationResult {
        do {
            let session = try await authRepository.signInForDevelopment()
            await applySignedInSession(session)
            return AppOperationResult(succeeded: true, message: "已登录 · \(session.displayName)")
        } catch {
            let message = "登录失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
    }

    func restoreSessionIfNeeded() async {
        defer {
            sessionRestorationCompleted = true
            bump()
        }
        await retryPendingSessionRevocation()
        guard let session = sessionStore.session else {
            syncAuthenticatedRepositories()
            return
        }
        syncAuthenticatedRepositories()
        if session.appleUserID != "dev-local",
           let credentialIsAuthorized = await appleCredentialIsAuthorized(session.appleUserID),
           !credentialIsAuthorized {
            clearAccountBoundState(accessToken: sessionStore.accessToken)
            lastRoomAPIEvent = "Apple 登录授权已失效，请重新登录"
            selectedTab = .account
            return
        }
        guard session.expiresAt.timeIntervalSinceNow < 10 * 60 else { return }
        do {
            let refreshed = try await authRepository.refresh(session)
            sessionStore.apply(refreshed)
            syncAuthenticatedRepositories()
            lastRoomAPIEvent = "登录态已刷新"
        } catch {
            clearAccountBoundState(accessToken: sessionStore.accessToken)
            lastRoomAPIEvent = "登录已失效，请重新登录"
            selectedTab = .account
        }
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential, rawNonce: String) {
        Task { _ = await signInWithAppleAndWait(credential: credential, rawNonce: rawNonce) }
    }

    func signInWithAppleAndWait(
        credential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async -> AppOperationResult {
        do {
            let session = try await authRepository.signInWithApple(
                credential: credential,
                rawNonce: rawNonce
            )
            await applySignedInSession(session)
            return AppOperationResult(succeeded: true, message: "已登录 · \(session.displayName)")
        } catch {
            let message = "Apple 登录失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
    }

    func signOut() {
        clearAccountBoundState(accessToken: sessionStore.accessToken)
        sessionRestorationCompleted = true
        lastRoomAPIEvent = "已退出登录"
        selectedTab = .account
        bump()
    }

    func signOutAndWait() async -> AppOperationResult {
        let accessToken = sessionStore.accessToken
        guard !accessToken.isEmpty else {
            return AppOperationResult(succeeded: true, message: "已退出登录")
        }
        var message = "已退出登录，服务器会话已撤销"
        do {
            try await authRepository.signOut(accessToken: accessToken)
            KeychainPendingSessionRevocationStore.delete()
        } catch {
            KeychainPendingSessionRevocationStore.save(accessToken)
            message = "已退出本机；联网后将自动撤销服务器会话"
        }
        clearAccountBoundState(accessToken: accessToken)
        sessionRestorationCompleted = true
        lastRoomAPIEvent = message
        selectedTab = .account
        bump()
        return AppOperationResult(succeeded: true, message: message)
    }

    func deleteAccountAndWait() async -> AppOperationResult {
        let accessToken = sessionStore.accessToken
        guard !accessToken.isEmpty else {
            return AppOperationResult(succeeded: false, message: AppError.notSignedIn.localizedDescription)
        }
        do {
            let deletion = try await authRepository.deleteAccount(accessToken: accessToken)
            KeychainPendingSessionRevocationStore.delete()
            clearAccountBoundState(
                accessToken: accessToken,
                deleteLocalData: true,
                notifyPushUnregister: false
            )
            #if !APP_ONLY
            diagnosticsStore = DiagnosticsStore()
            #endif
            sessionRestorationCompleted = true
            selectedTab = .account
            let message: String
            if deletion.requiresManualAppleRevocation {
                message = "账户和数据已删除。请在 Apple 账户设置的“使用 Apple 登录”中停止使用“Capsule Radar”。"
            } else {
                message = "账户、云端数据及 Apple 登录授权已删除"
            }
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: true, message: message)
        } catch {
            let message = "账户删除失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
    }

    func handleAppleCredentialRevoked() {
        guard isSignedIn else { return }
        clearAccountBoundState(accessToken: sessionStore.accessToken)
        sessionRestorationCompleted = true
        lastRoomAPIEvent = "Apple 登录授权已撤销，请重新登录"
        selectedTab = .account
        bump()
    }

    func updateUserProfile(displayName: String, avatarData: Data?) {
        sessionStore.updateProfile(displayName: displayName, avatarData: avatarData)
        bump()
    }

    func createRoom(named name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        Task { _ = await createRoomAndWait(named: cleanName) }
    }

    func createRoomAndWait(named name: String) async -> AppOperationResult {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            return AppOperationResult(succeeded: false, message: RoomError.roomNameRequired.localizedDescription)
        }
        guard isSignedIn else {
            selectedTab = .account
            let message = AppError.notSignedIn.localizedDescription
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
        guard !reviewExperience.isActive else {
            return AppOperationResult(succeeded: false, message: "请先退出本地雷达演示")
        }
        do {
            let room = try await roomsRepository.createRoom(named: cleanName)
            roomsStore.applyServerRoom(room)
            let message = "房间已创建 · \(room.roomCode)"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: true, message: message)
        } catch {
            let message = "房间创建失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
    }

    func refreshRoomsFromServer() async {
        guard isSignedIn else {
            lastRoomAPIEvent = "请先登录后同步房间"
            bump()
            return
        }
        guard !reviewExperience.isActive else {
            lastRoomAPIEvent = "本地雷达演示不会访问服务器"
            bump()
            return
        }
        do {
            let rooms = try await roomsRepository.listRooms()
            roomsStore.applyServerRooms(rooms)
            lastRoomAPIEvent = roomsStore.rooms.isEmpty ? "服务端暂无房间" : "房间列表已同步 · \(roomsStore.rooms.count)"
        } catch {
            lastRoomAPIEvent = "房间列表暂未同步 · \(error.localizedDescription)"
        }
        bump()
    }

    #if !APP_ONLY
    func refreshDevicesFromServer() async {
        guard isSignedIn else { return }
        guard !reviewExperience.isActive else {
            lastRoomAPIEvent = "本地雷达演示不会访问服务器或雷达"
            bump()
            return
        }
        do {
            let devices = try await devicesRepository.listDevices()
            let activeDeviceID = devicesStore.activeDevice?.deviceID
            let preferred = activeDeviceID.flatMap { activeDeviceID in
                devices.first { $0.deviceID == activeDeviceID }
            } ?? devices.first
            if let preferred {
                devicesStore.applyServerDevice(preferred)
                lastRoomAPIEvent = "雷达列表已同步 · \(preferred.deviceShortID)"
            } else {
                devicesStore.clearDevices()
                lastRoomAPIEvent = "暂无已绑定雷达"
            }
            bump()
        } catch {
            lastRoomAPIEvent = "雷达列表暂未同步 · \(error.localizedDescription)"
            bump()
        }
    }
    #endif

    func joinRoom(code: String) {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanCode.isEmpty else { return }
        Task { _ = await joinRoomAndWait(code: cleanCode) }
    }

    func joinRoomAndWait(code: String) async -> AppOperationResult {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanCode.isEmpty else {
            return AppOperationResult(succeeded: false, message: RoomError.invalidRoom.localizedDescription)
        }
        guard isSignedIn else {
            selectedTab = .account
            let message = AppError.notSignedIn.localizedDescription
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
        guard !reviewExperience.isActive else {
            return AppOperationResult(succeeded: false, message: "请先退出本地雷达演示")
        }
        do {
            let room = try await roomsRepository.joinRoom(code: cleanCode)
            roomsStore.applyServerRoom(room)
            let message = "已加入房间 · \(room.roomCode)"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: true, message: message)
        } catch {
            let message = "加入房间失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
    }

    func switchRoom(to roomID: RadarRoom.ID) {
        if reviewExperience.isActive {
            reviewExperience.stop()
            selectedMember = nil
            focusedMemberID = nil
        }
        roomsStore.switchRoom(to: roomID)
        bump()
    }

    func renameActiveRoom(to name: String) {
        guard !reviewExperience.isActive else { return }
        let previousCode = roomsStore.inviteCode
        roomsStore.renameActiveRoom(to: name)
        bump()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await renameRoomOnServer(code: previousCode, name: cleanName) }
    }

    func sendRadarReminderAndWait(
        roomCode requestedRoomCode: String? = nil,
        requestID: String = UUID().uuidString
    ) async -> RadarReminderOperationResult {
        guard !reviewExperience.isActive else {
            let message = "本地演示不会发送提醒或调用服务器"
            lastRoomAPIEvent = message
            bump()
            return RadarReminderOperationResult(succeeded: false, message: message, cooldownSeconds: 0)
        }
        let roomCode = (requestedRoomCode ?? inviteCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !roomCode.isEmpty else {
            return RadarReminderOperationResult(
                succeeded: false,
                message: RoomError.invalidRoom.localizedDescription,
                cooldownSeconds: 0
            )
        }
        guard isSignedIn else {
            selectedTab = .account
            let message = AppError.notSignedIn.localizedDescription
            lastRoomAPIEvent = message
            bump()
            return RadarReminderOperationResult(succeeded: false, message: message, cooldownSeconds: 0)
        }
        do {
            let receipt = try await roomsRepository.sendRadarReminder(roomCode: roomCode, requestID: requestID)
            let delivery = radarReminderDeliveryMessage(receipt)
            setRadarReminderCooldown(roomCode: roomCode, seconds: receipt.cooldownSeconds)
            let message = delivery.message
            lastRoomAPIEvent = message
            bump()
            return RadarReminderOperationResult(
                succeeded: delivery.succeeded,
                message: message,
                cooldownSeconds: receipt.cooldownSeconds
            )
        } catch {
            let retryAfter = (error as? RoomRepositoryError)?.retryAfterSeconds ?? 0
            if retryAfter > 0 {
                setRadarReminderCooldown(roomCode: roomCode, seconds: retryAfter)
            }
            let message = "提醒发送失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return RadarReminderOperationResult(
                succeeded: false,
                message: message,
                cooldownSeconds: retryAfter
            )
        }
    }

    func reportMemberAndWait(
        _ member: RoomMember,
        contentType: ModerationContentType,
        category: ModerationReportCategory,
        details: String
    ) async -> ModerationReportOperationResult {
        guard isSignedIn else {
            selectedTab = .account
            return ModerationReportOperationResult(
                succeeded: false,
                message: AppError.notSignedIn.localizedDescription,
                caseNumber: nil
            )
        }
        guard !reviewExperience.isActive else {
            return ModerationReportOperationResult(
                succeeded: false,
                message: "本地雷达演示没有真实成员可举报",
                caseNumber: nil
            )
        }
        guard member.canUseModerationActions else {
            return ModerationReportOperationResult(
                succeeded: false,
                message: member.isLocal ? "不能举报自己。" : "该槽位不是可举报的 App 成员。",
                caseNumber: nil
            )
        }
        let roomCode = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !roomCode.isEmpty else {
            return ModerationReportOperationResult(
                succeeded: false,
                message: RoomError.invalidRoom.localizedDescription,
                caseNumber: nil
            )
        }
        guard details.count <= 1_000 else {
            return ModerationReportOperationResult(
                succeeded: false,
                message: "补充说明不能超过 1000 字。",
                caseNumber: nil
            )
        }

        do {
            let receipt = try await moderationRepository.submitReport(
                roomCode: roomCode,
                moderationRef: member.moderationRef,
                contentType: contentType,
                category: category,
                details: details
            )
            let message = "举报已提交 · 案件号 \(receipt.caseNumber)"
            lastRoomAPIEvent = message
            bump()
            return ModerationReportOperationResult(
                succeeded: true,
                message: message,
                caseNumber: receipt.caseNumber
            )
        } catch {
            let message = "举报提交失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return ModerationReportOperationResult(succeeded: false, message: message, caseNumber: nil)
        }
    }

    func blockMemberAndWait(_ member: RoomMember) async -> ModerationBlockOperationResult {
        guard isSignedIn else {
            selectedTab = .account
            return ModerationBlockOperationResult(
                succeeded: false,
                message: AppError.notSignedIn.localizedDescription,
                leftCurrentRoom: false
            )
        }
        guard !reviewExperience.isActive else {
            return ModerationBlockOperationResult(
                succeeded: false,
                message: "本地雷达演示没有真实成员可屏蔽",
                leftCurrentRoom: false
            )
        }
        guard member.canUseModerationActions else {
            return ModerationBlockOperationResult(
                succeeded: false,
                message: member.isLocal ? "不能屏蔽自己。" : "该槽位不是可屏蔽的 App 成员。",
                leftCurrentRoom: false
            )
        }
        let originRoomCode = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !originRoomCode.isEmpty else {
            return ModerationBlockOperationResult(
                succeeded: false,
                message: RoomError.invalidRoom.localizedDescription,
                leftCurrentRoom: false
            )
        }

        do {
            let response = try await moderationRepository.block(
                roomCode: originRoomCode,
                moderationRef: member.moderationRef
            )
            blockedUsers.removeAll {
                $0.blockID == response.block.blockID || $0.moderationRef == response.block.moderationRef
            }
            blockedUsers.insert(response.block, at: 0)

            let leftRoomCodes = Set(
                response.effects
                    .filter { $0.action == .blockerLeft }
                    .map { $0.roomCode.uppercased() }
            )
            let removedFromCurrentRoom = response.effects.contains {
                $0.action == .blockedUserRemoved && $0.roomCode.uppercased() == originRoomCode
            }
            if removedFromCurrentRoom {
                roomsStore.removeModerationMember(reference: member.moderationRef)
            }
            roomsStore.removeRooms(withCodes: leftRoomCodes)

            if !moderationRepository.usesInMemoryTestingStore,
               let serverRooms = try? await roomsRepository.listRooms() {
                roomsStore.applyServerRooms(serverRooms)
            }

            let leftCurrentRoom = leftRoomCodes.contains(originRoomCode)
            let message: String
            if leftCurrentRoom {
                message = "已屏蔽 \(member.name) · 你已退出双方共同房间"
            } else if removedFromCurrentRoom {
                message = "已屏蔽 \(member.name) · 对方已从共同房间移除"
            } else {
                message = "已屏蔽 \(member.name) · 双方不能再加入同一房间"
            }
            lastRoomAPIEvent = message
            bump()
            return ModerationBlockOperationResult(
                succeeded: true,
                message: message,
                leftCurrentRoom: leftCurrentRoom
            )
        } catch {
            let message = "屏蔽失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return ModerationBlockOperationResult(succeeded: false, message: message, leftCurrentRoom: false)
        }
    }

    func refreshBlockedUsersFromServer() async -> AppOperationResult {
        guard isSignedIn else {
            blockedUsers = []
            return AppOperationResult(succeeded: false, message: AppError.notSignedIn.localizedDescription)
        }
        guard !reviewExperience.isActive else {
            return AppOperationResult(succeeded: false, message: "本地雷达演示不访问屏蔽列表")
        }
        do {
            blockedUsers = try await moderationRepository.listBlocks()
            bump()
            return AppOperationResult(
                succeeded: true,
                message: blockedUsers.isEmpty ? "暂无已屏蔽成员" : "已同步 \(blockedUsers.count) 条屏蔽记录"
            )
        } catch {
            let message = "屏蔽列表加载失败 · \(userFacingMessage(for: error))"
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
    }

    func unblockAndWait(blockID: String) async -> AppOperationResult {
        guard isSignedIn else {
            return AppOperationResult(succeeded: false, message: AppError.notSignedIn.localizedDescription)
        }
        do {
            let block = try await moderationRepository.unblock(blockID: blockID)
            blockedUsers.removeAll { $0.blockID == block.blockID }
            let message = "已解除屏蔽 · 不会自动恢复原房间关系"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: true, message: message)
        } catch {
            let message = "解除屏蔽失败 · \(userFacingMessage(for: error))"
            lastRoomAPIEvent = message
            bump()
            return AppOperationResult(succeeded: false, message: message)
        }
    }

    func radarReminderCooldownRemaining(roomCode: String, at date: Date = .now) -> Int {
        let key = radarReminderCooldownKey(roomCode: roomCode)
        guard let cooldownUntil = radarReminderCooldowns[key] else { return 0 }
        let remaining = max(0, Int(ceil(cooldownUntil.timeIntervalSince(date))))
        if remaining == 0 {
            radarReminderCooldowns.removeValue(forKey: key)
        }
        return remaining
    }

    func openRadarReminder(roomCode: String) async -> RadarReminderNavigationResult {
        let cleanCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard isSignedIn else { return .retryable }
        guard !reviewExperience.isActive else {
            lastRoomAPIEvent = "请先退出本地演示，再打开服务器房间提醒"
            bump()
            return .retryable
        }
        guard !cleanCode.isEmpty else {
            lastRoomAPIEvent = "提醒中没有有效房间"
            selectedTab = .rooms
            bump()
            return .unavailable
        }

        if rooms.first(where: { $0.inviteCode == cleanCode }) == nil {
            do {
                let serverRooms = try await roomsRepository.listRooms()
                roomsStore.applyServerRooms(serverRooms)
            } catch {
                lastRoomAPIEvent = "暂时无法打开提醒房间 · \(userFacingMessage(for: error))"
                bump()
                return .retryable
            }
        }
        guard let room = rooms.first(where: { $0.inviteCode == cleanCode }) else {
            lastRoomAPIEvent = "你已不在提醒对应的房间"
            selectedTab = .rooms
            bump()
            return .unavailable
        }
        if room.id != activeRoomID {
            roomsStore.switchRoom(to: room.id)
        }
        selectedTab = .radar
        bump()
        return .opened
    }

    func clearRelayRoomMembers() {
        guard !reviewExperience.isActive else { return }
        roomsStore.clearRelayRoomMembers()
        bump()
    }

    func applyRelayRoomState(_ snapshot: RelayRoomStateSnapshot, localAppPeerID: String) {
        guard !reviewExperience.isActive else { return }
        roomsStore.applyRelayRoomState(
            snapshot,
            localAppPeerID: localAppPeerID,
            localDisplayName: displayName
        )
        bump()
    }

    #if !APP_ONLY
    func updateActiveDeviceBattery(percent: Int?) {
        devicesStore.updateBattery(percent: percent)
        bump()
    }

    func applyWifiConfig(ssid: String) {
        guard !reviewExperience.isActive else { return }
        devicesStore.applyWifiConfig(ssid: ssid)
        diagnosticsStore.applyWifiConfig(ssid: ssid)
        bump()
    }

    func runDiagnostics() {
        guard !reviewExperience.isActive else {
            lastRoomAPIEvent = "本地雷达演示不运行真实链路诊断"
            bump()
            return
        }
        let cleanRoomCode = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRoom = !cleanRoomCode.isEmpty
        let nextLatency = hasRoom ? max(24, roomLatency == 0 ? 42 : roomLatency) : 0
        if hasRoom {
            roomsStore.roomLatency = nextLatency
            roomsStore.syncActiveRoomSnapshot()
            devicesStore.updateRelayLatency(nextLatency)
        }
        diagnosticsStore.run(
            activeDevice: activeDevice,
            backendReady: isSignedIn,
            roomCode: cleanRoomCode,
            roomLatency: nextLatency
        )
        bump()
    }

    func simulatePairingComplete() {
        guard !reviewExperience.isActive else { return }
        showPairingSheet = false
        devicesStore.markPairingComplete()
        bump()
    }

    func registerDevice(pairingChallenge: String, name: String) async throws -> ServerDevice {
        guard isSignedIn else {
            selectedTab = .account
            bump()
            throw RoomRepositoryError.server(code: "unauthorized", detail: nil)
        }
        guard !reviewExperience.isActive else {
            throw RoomRepositoryError.server(
                code: "review_experience_active",
                detail: "请先退出本地雷达演示"
            )
        }
        let device = try await devicesRepository.registerDevice(pairingChallenge: pairingChallenge, name: name)
        lastRoomAPIEvent = "等待雷达确认绑定 · \(device.deviceShortID)"
        bump()
        return device
    }

    func commitRegisteredDevice(_ device: ServerDevice) {
        devicesStore.applyServerDevice(device)
        lastRoomAPIEvent = "雷达已绑定 · \(device.deviceShortID)"
        bump()
    }

    func cancelRegisteredDevice(_ device: ServerDevice) async {
        do {
            try await devicesRepository.revokeDevice(deviceID: device.deviceID)
            lastRoomAPIEvent = "雷达未接受绑定，临时凭证已撤销"
        } catch {
            lastRoomAPIEvent = "雷达未接受绑定，临时凭证撤销待重试"
        }
        bump()
    }
    #endif

    private func radarReminderDeliveryMessage(_ receipt: RadarReminderReceipt) -> (succeeded: Bool, message: String) {
        let recipientCount = max(0, receipt.recipientCount)
        let onlineDelivered = min(recipientCount, max(0, receipt.onlineDelivered))
        let pushStatus = receipt.pushStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if recipientCount == 0 {
            return (true, "房间内暂无其他成员可提醒")
        }
        if onlineDelivered == recipientCount {
            return (true, "已提醒 \(recipientCount) 位成员 · 均已在线收到")
        }
        if onlineDelivered > 0 {
            if pushStatus == "sent" {
                return (true, "已提醒 \(recipientCount) 位成员 · \(onlineDelivered) 位在线收到")
            }
            if pushStatus == "partial" {
                return (true, "\(onlineDelivered) 位在线收到 · 其余成员推送部分送达")
            }
            return (true, "\(onlineDelivered) 位在线成员已收到 · 其余成员暂未送达")
        }

        switch pushStatus {
        case "sent":
            return (true, "已向 \(recipientCount) 位成员发出系统提醒")
        case "partial":
            return (true, "提醒已部分送达，请稍后查看成员状态")
        case "dry_run":
            return (true, "提醒链路验证完成（推送演练）")
        case "pending":
            return (false, "上一条提醒仍在处理中")
        case "failed":
            return (false, "成员当前不在线，系统推送发送失败")
        default:
            return (false, "当前没有在线成员，后台系统推送尚未送达")
        }
    }

    private func setRadarReminderCooldown(roomCode: String, seconds: Int) {
        guard seconds > 0 else { return }
        radarReminderCooldowns[radarReminderCooldownKey(roomCode: roomCode)] = Date()
            .addingTimeInterval(TimeInterval(seconds))
    }

    private func radarReminderCooldownKey(roomCode: String) -> String {
        let userID = sessionStore.session?.userID ?? "signed-out"
        let cleanRoomCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return userID + "|" + cleanRoomCode
    }

    private func tracked<T>(_ value: () -> T) -> T {
        _ = stateRevision
        return value()
    }

    private func bump() {
        stateRevision += 1
    }

    private func syncAuthenticatedRepositories() {
        roomsRepository.accessToken = sessionStore.accessToken
        #if !APP_ONLY
        devicesRepository.accessToken = sessionStore.accessToken
        #endif
        moderationRepository.accessToken = sessionStore.accessToken
    }

    #if DEBUG
    private func configureUITestingStateIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("DRAGON_RADAR_UI_TESTING") else { return }

        if arguments.contains("DRAGON_RADAR_UI_TESTING_AUTHENTICATED") {
            let session = AuthSession(
                userID: "ui-test-user",
                displayName: "UI Test User",
                appleUserID: "ui-test-apple-user",
                accessToken: "ui-test-access-token",
                refreshToken: "ui-test-refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 60 * 60)
            )
            sessionStore.apply(session)
            syncAuthenticatedRepositories()
        }

        if arguments.contains("DRAGON_RADAR_UI_TESTING_SEEDED_ROOMS") {
            roomsStore.applyServerRooms([
                ServerRoom(
                    roomID: "room-CAPS-1001",
                    roomCode: "CAPS-1001",
                    name: "周末小队",
                    maxMembers: 7,
                    memberCount: 1
                ),
                ServerRoom(
                    roomID: "room-CAPS-2002",
                    roomCode: "CAPS-2002",
                    name: "城市漫步",
                    maxMembers: 7,
                    memberCount: 2
                )
            ])
        }

        if arguments.contains("DRAGON_RADAR_UI_TESTING_ROOM_FULL") {
            roomsRepository.uiTestingScenario = .roomFull
        }

        if arguments.contains("DRAGON_RADAR_UI_TESTING_MODERATION") {
            moderationRepository.uiTestingEnabled = true
            let snapshotJSON = #"""
            {
              "room": "CAPS-1001",
              "server_time": 1784000000,
              "max_members": 7,
              "members": [
                {
                  "role": "app",
                  "member_id": "ui-local",
                  "peer_id": "ui-local-app",
                  "name": "本机用户",
                  "online": true,
                  "age_ms": 0,
                  "last_seen_ms": 100,
                  "last_type": "app_location",
                  "moderation_ref": "mod_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                  "app_online": true,
                  "device_online": false
                },
                {
                  "role": "app",
                  "member_id": "ui-remote",
                  "peer_id": "ui-remote-app",
                  "name": "测试成员",
                  "online": true,
                  "age_ms": 0,
                  "last_seen_ms": 200,
                  "last_type": "room_state",
                  "moderation_ref": "mod_v1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                  "app_online": true,
                  "device_online": false
                },
                {
                  "role": "device",
                  "member_id": "ui-device",
                  "peer_id": "ui-device-peer",
                  "name": "测试雷达设备",
                  "online": true,
                  "age_ms": 0,
                  "last_seen_ms": 300,
                  "last_type": "device_status",
                  "app_online": false,
                  "device_online": true
                }
              ]
            }
            """#.data(using: .utf8)
            if let snapshotJSON,
               let snapshot = try? JSONDecoder().decode(RelayRoomStateSnapshot.self, from: snapshotJSON) {
                roomsStore.applyRelayRoomState(snapshot, localAppPeerID: "ui-local-app")
            }
            if arguments.contains("DRAGON_RADAR_UI_TESTING_MODERATION_BLOCKED") {
                moderationRepository.seedUITestingBlock(
                    roomCode: "CAPS-1001",
                    moderationRef: "mod_v1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
                )
            }
        }
    }
    #endif

    private func userFacingMessage(for error: Error) -> String {
        AppError.userFacingMessage(for: error)
    }

    private func signInForDevelopmentOnServer() async {
        _ = await signInForDevelopmentAndWait()
    }

    private func signInWithAppleOnServer(
        credential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) async {
        _ = await signInWithAppleAndWait(credential: credential, rawNonce: rawNonce)
    }

    private func retryPendingSessionRevocation() async {
        let accessToken = KeychainPendingSessionRevocationStore.load()
        guard !accessToken.isEmpty else { return }
        do {
            try await authRepository.signOut(accessToken: accessToken)
            KeychainPendingSessionRevocationStore.delete()
        } catch {
            // Keep the token in the device-only Keychain for the next launch.
        }
    }

    private func appleCredentialIsAuthorized(_ appleUserID: String) async -> Bool? {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUserID) { state, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                switch state {
                case .authorized, .transferred:
                    continuation.resume(returning: true)
                case .revoked, .notFound:
                    continuation.resume(returning: false)
                @unknown default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func applySignedInSession(_ session: AuthSession) async {
        sessionStore.apply(session)
        sessionRestorationCompleted = true
        syncAuthenticatedRepositories()
        lastRoomAPIEvent = "已登录 · \(session.displayName)"
        await refreshRoomsFromServer()
        #if !APP_ONLY
        await refreshDevicesFromServer()
        #endif
    }

    private func clearAccountBoundState(
        accessToken: String,
        deleteLocalData: Bool = false,
        notifyPushUnregister: Bool = true
    ) {
        reviewExperience.stop()
        NotificationCenter.default.post(
            name: .dragonRadarAccountSignedOut,
            object: notifyPushUnregister ? accessToken : nil
        )
        if deleteLocalData {
            sessionStore.deleteAccountData()
            #if !APP_ONLY
            devicesStore.clearDevices()
            #endif
        } else {
            sessionStore.signOut()
        }
        syncAuthenticatedRepositories()
        roomsStore.clearRooms()
        radarReminderCooldowns.removeAll()
        blockedUsers = []
        selectedMember = nil
        focusedMemberID = nil
    }

    private func createRoomOnServer(named name: String) async {
        _ = await createRoomAndWait(named: name)
    }

    private func joinRoomOnServer(code: String) async {
        _ = await joinRoomAndWait(code: code)
    }

    private func renameRoomOnServer(code: String, name: String) async {
        guard !name.isEmpty else { return }
        do {
            let room = try await roomsRepository.renameRoom(code: code, name: name)
            roomsStore.applyServerRoom(room)
            lastRoomAPIEvent = "房间名已同步 · \(room.roomCode)"
        } catch {
            lastRoomAPIEvent = "房间名暂未同步 · \(error.localizedDescription)"
        }
        bump()
    }
}
