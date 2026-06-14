import AuthenticationServices
import Foundation
import Observation

enum AppTab: String, CaseIterable, Identifiable {
    case radar
    case rooms
    case devices
    case account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radar: "雷达"
        case .rooms: "房间"
        case .devices: "设备"
        case .account: "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .radar: "scope"
        case .rooms: "person.3.sequence.fill"
        case .devices: "dot.radiowaves.left.and.right"
        case .account: "person.crop.circle"
        }
    }
}

enum DeviceConnectionState: String {
    case cloudConnected = "云端在线"
    case wifiConnected = "Wi-Fi 在线"
    case pairing = "正在绑定"
    case offline = "离线"
}

struct RoomMember: Identifiable, Hashable {
    let id: UUID
    var name: String
    var distance: String
    var bearing: String
    var accuracy: String
    var locationPaused: Bool
    var isOnline: Bool
    var isSpeaking: Bool
    var isMuted: Bool
    var voiceStatusText: String
    var voiceCountdownText: String
    var voiceHealthText: String
    var deviceBattery: Int
    var wifiRSSI: Int
    var firmware: String
    var lastUpdate: String
}

struct RadarRoom: Identifiable, Hashable {
    let id: UUID
    var name: String
    var inviteCode: String
    var capacity: Int
    var onlineGroups: Int
    var latency: Int
    var voiceQuality: String
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

struct ServerErrorEnvelope: Decodable {
    var code: String
    var detail: String?
}

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

enum RoomRepositoryError: LocalizedError {
    case server(code: String, detail: String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .server(let code, let detail):
            return RoomError.displayText(for: code, detail: detail)
        case .badResponse:
            return "服务暂时不可用。请稍后重试。"
        }
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
        case .unknown:
            return "房间服务暂时不可用。请稍后重试。"
        }
    }

    static func displayText(for code: String, detail: String? = nil) -> String {
        let base = RoomError(code: code).errorDescription ?? code
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) · \(detail)"
    }
}

enum RelayError: String, LocalizedError {
    case unauthorized
    case deviceRevoked = "device_revoked"
    case protocolUnsupported = "protocol_unsupported"
    case voiceBusy = "voice_busy"
    case networkUnavailable = "network_unavailable"
    case unknown

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "房间连接鉴权失败。请重新登录并检查当前房间。"
        case .deviceRevoked:
            return "雷达已解绑或授权已撤销。请重新绑定这台雷达。"
        case .protocolUnsupported:
            return "App、房间服务或雷达版本不兼容。请更新到同一版本。"
        case .voiceBusy:
            return "当前已有成员正在说话，请松开后重试。"
        case .networkUnavailable:
            return "网络不可用。请检查蜂窝网络、Wi-Fi 或热点。"
        case .unknown:
            return "房间连接状态未知。请稍后重试。"
        }
    }
}

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

enum AppError: LocalizedError {
    case room(RoomError)
    case relay(RelayError)
    case ble(BLEError)
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
        case .ble(let error):
            return error.localizedDescription
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
            return cleanName
        }
        return session?.displayName ?? "未登录"
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
    var voiceQuality = "等待房间"
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

    var activeSpeakers: [RoomMember] {
        members.filter { $0.isSpeaking && $0.isOnline }
    }

    func createRoom(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        syncActiveRoomSnapshot()
        activeRoomID = UUID()
        activeRoomName = trimmedName
        inviteCode = Self.makeInviteCode()
        roomOnlineGroups = 0
        roomLatency = 0
        voiceQuality = "等待房间"
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
        voiceQuality = "等待房间"
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
        voiceQuality = "等待房间"
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
        voiceQuality = room.memberCount > 0 ? "等待房间" : "等待成员"
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
                voiceQuality: existing?.voiceQuality ?? "等待房间",
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
        voiceQuality = selected.voiceQuality
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
            voiceQuality: voiceQuality,
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
        voiceQuality = "等待房间"
        locationHealth = "等待房间"
        Self.clearPersistedState(defaults: defaults)
    }

    func clearRelayRoomMembers() {
        members = []
        roomOnlineGroups = 0
        voiceQuality = "等待房间"
        syncActiveRoomSnapshot()
    }

    func applyRelayRoomState(_ snapshot: RelayRoomStateSnapshot, localAppPeerID: String) {
        roomCapacity = snapshot.maxMembers
        roomOnlineGroups = snapshot.members.count
        inviteCode = snapshot.room
        voiceQuality = voiceQualityText(snapshot)
        locationHealth = locationHealthText(snapshot)

        let localMember = snapshot.members.first(where: { $0.peerID == localAppPeerID })
        let localCoordinate = localMember?.locationStale == true ? nil : localMember?.location
        members = snapshot.members.prefix(snapshot.maxMembers).map { member in
            makeRoomMember(
                from: member,
                localCoordinate: localCoordinate,
                localAppPeerID: localAppPeerID,
                voiceFloor: snapshot.voiceFloor
            )
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

    private func makeRoomMember(
        from relayMember: RelayRoomMemberSnapshot,
        localCoordinate: RelayLocationSnapshot?,
        localAppPeerID: String,
        voiceFloor: RelayVoiceFloorSnapshot?
    ) -> RoomMember {
        let isLocal = relayMember.peerID == localAppPeerID
        let relation = relativeLocationText(
            member: relayMember,
            localCoordinate: localCoordinate,
            isLocal: isLocal
        )
        let rssi = relayMember.deviceStatus?.rssi ?? -999
        return RoomMember(
            id: stableID(for: relayMember.peerID),
            name: displayName(for: relayMember, isLocal: isLocal),
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
            lastUpdate: lastUpdateText(milliseconds: relayMember.lastSeenMS)
        )
    }

    private func voiceQualityText(_ snapshot: RelayRoomStateSnapshot) -> String {
        guard !snapshot.members.isEmpty else {
            return "等待成员"
        }
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
    }

    private func locationHealthText(_ snapshot: RelayRoomStateSnapshot) -> String {
        guard !snapshot.members.isEmpty else {
            return "等待成员"
        }
        if snapshot.members.contains(where: { $0.locationPaused == true }) {
            return "有成员暂停定位"
        }
        if snapshot.members.contains(where: { $0.locationStale == true }) {
            return "有成员定位过期"
        }
        if snapshot.members.contains(where: { $0.location != nil }) {
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

    private func displayName(for member: RelayRoomMemberSnapshot, isLocal: Bool) -> String {
        if isLocal {
            return "隼人 iPhone"
        }
        if let name = member.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let suffix = member.peerID.count > 6 ? String(member.peerID.suffix(6)) : member.peerID
        return member.role == "device" ? "雷达 \(suffix)" : "手机 \(suffix)"
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
            return ("等待定位", member.role == "device" ? "雷达" : "手机")
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
        return "KAME-\(suffix)"
    }
}

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
        let deviceToken = defaults.string(forKey: Self.activeDeviceTokenKey) ?? ""
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
        devices[0].state = .wifiConnected
        defaults.set(devices[0].wifiName, forKey: Self.activeDeviceWifiKey)
    }

    func markPairingComplete() {
        guard !devices.isEmpty else { return }
        devices[0].state = .cloudConnected
        defaults.set(devices[0].shortId, forKey: Self.activeDeviceShortIDKey)
        defaults.set(devices[0].name, forKey: Self.activeDeviceNameKey)
        defaults.set(devices[0].deviceID, forKey: Self.activeDeviceIDKey)
        defaults.set(devices[0].deviceToken, forKey: Self.activeDeviceTokenKey)
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
        defaults.set(devices[0].deviceToken, forKey: Self.activeDeviceTokenKey)
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

@MainActor
@Observable
final class AppState {
    var sessionStore: SessionStore
    var roomsStore: RoomsStore
    var devicesStore: DevicesStore
    var diagnosticsStore = DiagnosticsStore()
    var roomsRepository = RoomsRepository()
    var devicesRepository = DevicesRepository()
    var authRepository = AuthRepository()

    var selectedTab: AppTab = .rooms
    var selectedMember: RoomMember?
    var showPairingSheet = false
    var showWifiSheet = false
    var showJoinRoomSheet = false
    var showCreateRoomSheet = false
    var focusedMemberID: RoomMember.ID?
    var lastRoomAPIEvent = "房间 API 尚未同步"
    private var stateRevision = 0

    var activeRoomID: UUID { tracked { roomsStore.activeRoomID } }
    var rooms: [RadarRoom] { tracked { roomsStore.rooms } }
    var activeRoomName: String { tracked { roomsStore.activeRoomName } }
    var inviteCode: String { tracked { roomsStore.inviteCode } }
    var roomCapacity: Int { tracked { roomsStore.roomCapacity } }
    var roomLatency: Int { tracked { roomsStore.roomLatency } }
    var voiceQuality: String { tracked { roomsStore.voiceQuality } }
    var locationHealth: String { tracked { roomsStore.locationHealth } }
    var members: [RoomMember] { tracked { roomsStore.members } }
    var onlineMembers: Int { tracked { roomsStore.onlineMembers } }
    var activeSpeakers: [RoomMember] { tracked { roomsStore.activeSpeakers } }
    var devices: [RadarDevice] { tracked { devicesStore.devices } }
    var activeDevice: RadarDevice? { tracked { devicesStore.activeDevice } }
    var activeDeviceToken: String { tracked { devicesStore.activeDeviceToken } }
    var diagnostics: [DiagnosticItem] { tracked { diagnosticsStore.diagnostics } }
    var isSignedIn: Bool { tracked { sessionStore.isSignedIn } }
    var displayName: String { tracked { sessionStore.displayName } }
    var profileAvatarData: Data? { tracked { sessionStore.avatarData } }
    var accessToken: String { tracked { sessionStore.accessToken } }

    init(resetPersistentState: Bool = false) {
        sessionStore = SessionStore(resetPersistentState: resetPersistentState)
        roomsStore = RoomsStore(resetPersistentState: resetPersistentState)
        devicesStore = DevicesStore(resetPersistentState: resetPersistentState)
        syncAuthenticatedRepositories()
        #if DEBUG
        configureUITestingStateIfNeeded()
        #endif
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
        guard let session = sessionStore.session else {
            syncAuthenticatedRepositories()
            return
        }
        syncAuthenticatedRepositories()
        guard session.expiresAt.timeIntervalSinceNow < 10 * 60 else { return }
        do {
            let refreshed = try await authRepository.refresh(session)
            sessionStore.apply(refreshed)
            syncAuthenticatedRepositories()
            lastRoomAPIEvent = "登录态已刷新"
        } catch {
            sessionStore.signOut()
            syncAuthenticatedRepositories()
            lastRoomAPIEvent = "登录已失效，请重新登录"
            selectedTab = .account
        }
        bump()
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) {
        Task { _ = await signInWithAppleAndWait(credential: credential) }
    }

    func signInWithAppleAndWait(credential: ASAuthorizationAppleIDCredential) async -> AppOperationResult {
        do {
            let session = try await authRepository.signInWithApple(credential: credential)
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
        sessionStore.signOut()
        syncAuthenticatedRepositories()
        clearRelayRoomMembers()
        lastRoomAPIEvent = "已退出登录"
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
        do {
            let rooms = try await roomsRepository.listRooms()
            roomsStore.applyServerRooms(rooms)
            lastRoomAPIEvent = roomsStore.rooms.isEmpty ? "服务端暂无房间" : "房间列表已同步 · \(roomsStore.rooms.count)"
        } catch {
            lastRoomAPIEvent = "房间列表暂未同步 · \(error.localizedDescription)"
        }
        bump()
    }

    func refreshDevicesFromServer() async {
        guard isSignedIn else { return }
        do {
            let devices = try await devicesRepository.listDevices()
            if let newest = devices.first {
                devicesStore.applyServerDevice(newest)
                lastRoomAPIEvent = "雷达列表已同步 · \(newest.deviceShortID)"
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
        roomsStore.switchRoom(to: roomID)
        bump()
    }

    func renameActiveRoom(to name: String) {
        let previousCode = roomsStore.inviteCode
        roomsStore.renameActiveRoom(to: name)
        bump()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await renameRoomOnServer(code: previousCode, name: cleanName) }
    }

    func clearRelayRoomMembers() {
        roomsStore.clearRelayRoomMembers()
        bump()
    }

    func applyRelayRoomState(_ snapshot: RelayRoomStateSnapshot, localAppPeerID: String) {
        roomsStore.applyRelayRoomState(snapshot, localAppPeerID: localAppPeerID)
        bump()
    }

    func updateActiveDeviceBattery(percent: Int?) {
        devicesStore.updateBattery(percent: percent)
        bump()
    }

    func applyWifiConfig(ssid: String) {
        devicesStore.applyWifiConfig(ssid: ssid)
        diagnosticsStore.applyWifiConfig(ssid: ssid)
        bump()
    }

    func runDiagnostics() {
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
        let device = try await devicesRepository.registerDevice(pairingChallenge: pairingChallenge, name: name)
        devicesStore.applyServerDevice(device)
        lastRoomAPIEvent = "雷达已绑定 · \(device.deviceShortID)"
        bump()
        return device
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
        devicesRepository.accessToken = sessionStore.accessToken
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
                    roomID: "room-KAME-1001",
                    roomCode: "KAME-1001",
                    name: "西都小队",
                    maxMembers: 7,
                    memberCount: 1
                ),
                ServerRoom(
                    roomID: "room-KAME-2002",
                    roomCode: "KAME-2002",
                    name: "龟屋频道",
                    maxMembers: 7,
                    memberCount: 2
                )
            ])
        }

        if arguments.contains("DRAGON_RADAR_UI_TESTING_ROOM_FULL") {
            roomsRepository.uiTestingScenario = .roomFull
        }
    }
    #endif

    private func userFacingMessage(for error: Error) -> String {
        AppError.userFacingMessage(for: error)
    }

    private func signInForDevelopmentOnServer() async {
        _ = await signInForDevelopmentAndWait()
    }

    private func signInWithAppleOnServer(credential: ASAuthorizationAppleIDCredential) async {
        _ = await signInWithAppleAndWait(credential: credential)
    }

    private func applySignedInSession(_ session: AuthSession) async {
        sessionStore.apply(session)
        syncAuthenticatedRepositories()
        lastRoomAPIEvent = "已登录 · \(session.displayName)"
        await refreshRoomsFromServer()
        await refreshDevicesFromServer()
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
