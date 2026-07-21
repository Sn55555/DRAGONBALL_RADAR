import CryptoKit
import Foundation
import Observation

enum RuntimePhase: String {
    case idle = "未连接"
    case connecting = "连接中"
    case ready = "已就绪"
    case degraded = "降级"
    case failed = "失败"
}

private enum RelayConnectionError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let detail):
            return detail
        }
    }
}

enum RoomSwitchState: String {
    case idle = "未切房"
    case appSwitching = "App 切房中"
    #if !APP_ONLY
    case notifyingESP = "通知雷达"
    case waitingESPJoin = "等待雷达"
    #endif
    case synced = "已同步"
    case failed = "同步失败"
}

enum DragonRadarProtocol {
    static let appProtocolVersion = 2
    static let minRelayProtocolVersion = 2
    #if !APP_ONLY
    static let minDeviceProtocolVersion = 2
    #endif
    static let locationFrameVersion = 1
    #if !APP_ONLY
    static let voiceProtocolVersion = 1
    #endif

    static var appVersionText: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}

struct LocationSnapshot: Hashable {
    var latE7: Int32
    var lonE7: Int32
    var horizontalAccuracyCM: UInt16
    var speedCMS: UInt16
    var courseDeg100: UInt16?
    var phoneHeading: PhoneHeadingSnapshot?
    var isReducedAccuracy: Bool
    var timestamp: Date

    var coordinateText: String {
        String(format: "%.5f, %.5f", Double(latE7) / 10_000_000, Double(lonE7) / 10_000_000)
    }

    var accuracyText: String {
        "±\(horizontalAccuracyCM / 100)m"
    }

    var frameSummary: String {
        let phoneHeadingSummary = phoneHeading.map {
            "\($0.reference.rawValue)/\($0.quality().rawValue)"
        } ?? "unavailable"
        return "v1 lat_e7=\(latE7) lon_e7=\(lonE7) h_acc_cm=\(horizontalAccuracyCM) "
            + "course_valid=\(courseDeg100 != nil) phone_heading=\(phoneHeadingSummary) radar_heading_valid=false"
    }

    var locationFrameData: Data {
        var data = Data()
        data.appendUInt8(1)
        // LocationFrame v1 bit 2 means the heading belongs to the radar itself.
        // An iPhone carried in a pocket has no verified yaw relationship to the
        // separate radar, so phone compass data must never set that bit.
        let flags: UInt8 = 0b0000_0001 | (isReducedAccuracy ? 0b0000_0010 : 0)
        data.appendUInt8(flags)
        data.appendInt32(latE7)
        data.appendInt32(lonE7)
        data.appendInt32(Int32.min)
        data.appendUInt16(horizontalAccuracyCM)
        data.appendUInt16(0)
        data.appendUInt16(speedCMS)
        data.appendUInt16(courseDeg100 ?? 0)
        data.appendUInt16(0)
        data.appendUInt32(UInt32(timestamp.timeIntervalSince1970))
        return data
    }
}

struct RelayRoomStateSnapshot: Decodable, Hashable {
    var room: String
    var serverTime: Int
    var maxMembers: Int
    #if !APP_ONLY
    var voiceFloor: RelayVoiceFloorSnapshot?
    #endif
    var members: [RelayRoomMemberSnapshot]

    enum CodingKeys: String, CodingKey {
        case room
        case serverTime = "server_time"
        case maxMembers = "max_members"
        #if !APP_ONLY
        case voiceFloor = "voice_floor"
        #endif
        case members
    }
}

struct RelayRoomMemberSnapshot: Decodable, Hashable {
    var role: String
    var memberID: String
    var peerID: String
    var name: String?
    var online: Bool
    var ageMS: Int
    var lastSeenMS: Int
    var lastType: String
    var protocolVersion: Int?
    #if !APP_ONLY
    var firmware: String?
    var deviceStatus: RelayDeviceStatusSnapshot?
    var voiceStatus: RelayVoiceStatusSnapshot?
    #endif
    var location: RelayLocationSnapshot?
    var locationPaused: Bool?
    var locationStale: Bool? = nil
    var locationAgeMS: Int? = nil
    var appOnline: Bool?
    #if !APP_ONLY
    var deviceOnline: Bool?
    #endif
    var moderationRef: String? = nil

    enum CodingKeys: String, CodingKey {
        case role
        case memberID = "member_id"
        case peerID = "peer_id"
        case name
        case online
        case ageMS = "age_ms"
        case lastSeenMS = "last_seen_ms"
        case lastType = "last_type"
        case protocolVersion = "protocol_version"
        #if !APP_ONLY
        case firmware
        case deviceStatus = "device_status"
        case voiceStatus = "voice_status"
        #endif
        case location
        case locationPaused = "location_paused"
        case locationStale = "location_stale"
        case locationAgeMS = "location_age_ms"
        case appOnline = "app_online"
        #if !APP_ONLY
        case deviceOnline = "device_online"
        #endif
        case moderationRef = "moderation_ref"
    }
}

#if !APP_ONLY
struct DeviceBatterySnapshot: Decodable, Hashable {
    var present: Bool?
    var percent: Int?
    var voltageMV: Int?
    var charging: Bool?
    var discharging: Bool?
    var low: Bool?

    enum CodingKeys: String, CodingKey {
        case present
        case percent
        case voltageMV = "voltage_mv"
        case charging
        case discharging
        case low
    }

    var displayText: String {
        if present == false {
            return "未接电池"
        }
        guard let percent, percent >= 0 else {
            return "未上报"
        }
        var text = "\(percent)%"
        if let voltageMV, voltageMV > 0 {
            text += " · \(voltageMV)mV"
        }
        if charging == true {
            text += " · 充电中"
        } else if discharging == true {
            text += " · 电池供电"
        }
        if low == true {
            text += " · 电量不足"
        }
        return text
    }
}

struct RelayDeviceStatusSnapshot: Decodable, Hashable {
    var name: String?
    var wifi: String?
    var rssi: Int?
    var ip: String?
    var relay: String?
    var loc: Int?
    var last: String?
    var battery: DeviceBatterySnapshot?
    var batteryPercent: Int?
    var batteryVoltageMV: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case wifi
        case rssi
        case ip
        case relay
        case loc
        case last
        case battery
        case batteryPercent = "battery_percent"
        case batteryVoltageMV = "battery_voltage_mv"
    }

    var batteryPercentValue: Int? {
        if let percent = battery?.percent, percent >= 0 {
            return percent
        }
        if let batteryPercent, batteryPercent >= 0 {
            return batteryPercent
        }
        return nil
    }

    var batteryDisplayText: String {
        if let battery, battery.displayText != "未上报" {
            return battery.displayText
        }
        guard let percent = batteryPercentValue else {
            return "未上报"
        }
        if let batteryVoltageMV, batteryVoltageMV > 0 {
            return "\(percent)% · \(batteryVoltageMV)mV"
        }
        return "\(percent)%"
    }
}

struct RelayVoiceStatusSnapshot: Decodable, Hashable {
    var muted: Bool?
    var ptt: Bool?
    var vad: Bool?
    var codec: String?
    var sampleRate: Int?
    var frameMS: Int?
    var sequence: Int?
    var receivedSequence: Int?
    var lostFrames: Int?
    var rms: Int?
    var peak: Int?
    var floorGranted: Bool?
    var speaker: Bool?

    enum CodingKeys: String, CodingKey {
        case muted
        case ptt
        case vad
        case codec
        case sampleRate = "sample_rate"
        case frameMS = "frame_ms"
        case sequence
        case receivedSequence = "received_sequence"
        case lostFrames = "lost_frames"
        case rms
        case peak
        case floorGranted = "floor_granted"
        case speaker
    }
}

struct RelayVoiceFloorSnapshot: Decodable, Hashable {
    var active: Bool
    var speakerGroupID: String?
    var speakerPeerID: String?
    var expiresInMS: Int

    enum CodingKeys: String, CodingKey {
        case active
        case speakerGroupID = "speaker_group_id"
        case speakerPeerID = "speaker_peer_id"
        case expiresInMS = "expires_in_ms"
    }
}
#endif

struct RelayLocationSnapshot: Decodable, Hashable {
    var latE7: Int?
    var lonE7: Int?
    var horizontalAccuracyCM: Int?
    var speedCMS: Int?
    var courseDeg100: Int?
    var unixTime: Int?
    var sequence: Int?

    enum CodingKeys: String, CodingKey {
        case latE7 = "lat_e7"
        case lonE7 = "lon_e7"
        case horizontalAccuracyCM = "h_acc_cm"
        case speedCMS = "speed_cms"
        case courseDeg100 = "course_deg100"
        case unixTime = "unix_time"
        case sequence
    }
}

private extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

@MainActor
@Observable
final class RadarRuntime {
    @ObservationIgnored private var relaySocket: URLSessionWebSocketTask?
    @ObservationIgnored private var relayReceiveTask: Task<Void, Never>?
    @ObservationIgnored private var roomStateRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var relayConnectedAt: Date?
    @ObservationIgnored private var nextLocationSequence = 1
    @ObservationIgnored private var currentRelayRoomCode = ""
    @ObservationIgnored private var relayConnectionID = UUID()
    @ObservationIgnored private var localDisplayName = "Capsule Radar 用户"
    @ObservationIgnored private var voiceWakeHandler: ((String, String) -> Void)?
    @ObservationIgnored private var voiceFrameHandler: ((Data) -> Void)?
    @ObservationIgnored private var voiceGrantedHandler: ((String) -> Void)?
    @ObservationIgnored private var voiceEndHandler: (() -> Void)?
    @ObservationIgnored private var activeVoiceRequestID = ""
    @ObservationIgnored private var pendingVoiceReadyRequestID = ""

    var relayPhase: RuntimePhase = .idle
    #if !APP_ONLY
    var espPhase: RuntimePhase = .idle
    var voicePhase: RuntimePhase = .idle
    #endif
    var lastRelayEvent = "尚未连接房间"
    #if !APP_ONLY
    var lastESPEvent = "尚未同步雷达"
    var lastVoiceEvent = "等待雷达语音状态"
    #endif
    var lastLocationFrame = "尚未生成 LocationFrame"
    var appSocketPath = "/v1/radar/app/ws"
    #if !APP_ONLY
    var provisionedServiceUUID = "7d540100-f82d-4b2f-91c6-4f0f88aa5a11"
    var deviceSocketPath = "/v1/radar/device/ws"
    #endif
    var relayBaseURL = AppEnvironment.current.relayBaseURL
    var relayRoomState = "尚未收到房间状态"
    var roomStateSnapshot: RelayRoomStateSnapshot?
    var localAppPeerID = "app-local"
    #if !APP_ONLY
    var pendingServerConfig = false
    var pendingLocationWrite = false
    #endif
    var relayLatencyMS = 0
    var lastLocationSequenceSent = 0
    var lastLocationSequenceAcked = 0
    var lastLocationAckText = "尚未确认定位上传"
    var lastLocationSentAt: Date?
    var lastLocationAckedAt: Date?
    #if !APP_ONLY
    var localDeviceToken = ""
    #endif
    var relayProtocolText = "未确认"
    var compatibilityText = "等待房间"
    var appAccessToken = ""
    var roomSwitchState: RoomSwitchState = .idle
    var roomSwitchDetail = "尚未切换房间"
    var relayEventHistory: [String] = []
    #if !APP_ONLY
    var espEventHistory: [String] = []
    var voiceEventHistory: [String] = []
    private var pendingRoomSwitchRequestID = ""
    private var pendingRoomSwitchRoom = ""
    private var pendingRoomSwitchGroupID = ""
    #endif

    var lastLocationSentText: String {
        guard let lastLocationSentAt else { return "尚未上传" }
        return Self.relativeText(since: lastLocationSentAt)
    }

    var lastLocationAckedText: String {
        guard let lastLocationAckedAt else { return "尚未确认" }
        return Self.relativeText(since: lastLocationAckedAt)
    }

    func configureUserDisplayName(_ value: String) {
        let cleanName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        localDisplayName = cleanName.isEmpty || cleanName == "未登录"
            ? "Capsule Radar 用户"
            : cleanName
    }

    #if !APP_ONLY
    func configureVoiceGateway(
        onWake: @escaping (String, String) -> Void,
        onFrame: @escaping (Data) -> Void,
        onGranted: @escaping (String) -> Void,
        onEnd: @escaping () -> Void
    ) {
        voiceWakeHandler = onWake
        voiceFrameHandler = onFrame
        voiceGrantedHandler = onGranted
        voiceEndHandler = onEnd
    }

    func requestVoiceFloor(requestID: String) async {
        guard relayPhase == .ready else {
            voicePhase = .failed
            noteVoiceEvent("房间未连接，无法发起语音")
            return
        }
        activeVoiceRequestID = requestID
        do {
            try await sendRelayJSON([
                "type": "gateway_voice_request",
                "request_id": requestID,
                "codec": "ima_adpcm",
                "sample_rate": 16_000,
                "frame_ms": 20
            ])
            voicePhase = .connecting
            noteVoiceEvent("正在申请房间语音权")
        } catch {
            voicePhase = .failed
            noteVoiceEvent("语音申请失败：\(error.localizedDescription)")
        }
    }

    func confirmRemoteVoiceReady(requestID: String) async {
        guard relayPhase == .ready, relaySocket != nil else {
            pendingVoiceReadyRequestID = requestID
            noteVoiceEvent("雷达已唤醒，等待房间链路恢复后确认")
            return
        }
        do {
            try await sendRelayJSON([
                "type": "gateway_voice_ready",
                "request_id": requestID
            ])
            noteVoiceEvent("雷达已被 BLE 唤醒，等待远端语音")
            pendingVoiceReadyRequestID = ""
        } catch {
            noteVoiceEvent("远端唤醒确认失败：\(error.localizedDescription)")
        }
    }

    func releaseVoiceFloor(requestID: String? = nil) async {
        let effectiveID = requestID ?? activeVoiceRequestID
        do {
            try await sendRelayJSON([
                "type": "gateway_voice_release",
                "request_id": effectiveID
            ])
        } catch {
            noteVoiceEvent("语音释放失败：\(error.localizedDescription)")
        }
        activeVoiceRequestID = ""
        voicePhase = .idle
    }

    func sendVoiceFrame(_ frame: Data) async {
        guard relayPhase == .ready, !frame.isEmpty else { return }
        let sequence: UInt32 = frame.count >= 8
            ? frame[4..<8].enumerated().reduce(0) { partial, item in
                partial | (UInt32(item.element) << UInt32(item.offset * 8))
            }
            : 0
        do {
            try await sendRelayJSON([
                "type": "gateway_voice_frame",
                "request_id": activeVoiceRequestID,
                "sequence": Int(sequence),
                "codec": "ima_adpcm",
                "audio_b64": frame.base64EncodedString()
            ])
        } catch {
            voicePhase = .degraded
            noteVoiceEvent("语音帧上传失败：\(error.localizedDescription)")
        }
    }
    #endif

    #if !APP_ONLY
    var localDeviceMember: RelayRoomMemberSnapshot? {
        guard let snapshot = roomStateSnapshot else { return nil }
        let ids = localDeviceLookupIDs
        return snapshot.members.first { member in
            ids.contains(member.memberID) || ids.contains(member.peerID)
        }
    }

    var localDeviceOnline: Bool {
        guard let member = localDeviceMember else { return false }
        return member.deviceOnline == true || member.deviceStatus != nil
    }

    var localRelayDeviceStatus: RelayDeviceStatusSnapshot? {
        localDeviceMember?.deviceStatus
    }

    private var localDeviceLookupIDs: Set<String> {
        var ids = Set<String>()
        let appGroupID = localAppPeerID.hasPrefix("app-") ? String(localAppPeerID.dropFirst(4)) : localAppPeerID
        if !appGroupID.isEmpty { ids.insert(appGroupID) }
        return ids
    }
    #endif

    func connectRelay(roomCode: String, deviceToken: String, appAccessToken: String) async {
        disconnectRelay()
        let connectionID = UUID()
        relayConnectionID = connectionID
        self.appAccessToken = appAccessToken
        #if !APP_ONLY
        localDeviceToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        localAppPeerID = Self.appPeerID(deviceToken: deviceToken, appAccessToken: appAccessToken)
        currentRelayRoomCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
        roomStateSnapshot = nil
        relayRoomState = "等待 \(roomCode) 的房间状态"
        relayPhase = .connecting
        noteRelayEvent("正在建立 App WS · \(appSocketPath) · room \(roomCode) · \(localAppPeerID)")
        print("DragonRadar Relay connect start base=\(relayBaseURL) room=\(roomCode) appPeer=\(localAppPeerID)")

        let webSocketTicket: String
        do {
            webSocketTicket = try await requestWebSocketTicket(accessToken: appAccessToken)
        } catch {
            guard relayConnectionID == connectionID else { return }
            relayPhase = .failed
            noteRelayEvent("房间认证失败：\(error.localizedDescription)")
            print("DragonRadar Relay ticket failed error=\(error.localizedDescription)")
            return
        }

        guard relayConnectionID == connectionID else { return }
        guard let url = appSocketURL(roomCode: roomCode, webSocketTicket: webSocketTicket) else {
            relayPhase = .failed
            noteRelayEvent("房间服务地址无效")
            print("DragonRadar Relay connect failed invalid URL base=\(relayBaseURL)")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(appAccessToken)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        relaySocket = socket
        socket.resume()

        do {
            #if APP_ONLY
            let capabilities = ["location", "room_admin"]
            #else
            let capabilities = ["location", "device_config", "room_admin", "ble_voice_gateway", "ptt_push"]
            #endif
            try await sendRelayJSON([
                "type": "hello",
                "app": "DragonRadarMVP",
                "app_version": DragonRadarProtocol.appVersionText,
                "protocol_version": DragonRadarProtocol.appProtocolVersion,
                "min_relay_protocol_version": DragonRadarProtocol.minRelayProtocolVersion,
                "name": localDisplayName,
                "room": roomCode,
                "capabilities": capabilities
            ], over: socket)
            guard relayConnectionID == connectionID, relaySocket === socket else {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
            let firstMessage = try await socket.receive()
            guard relayConnectionID == connectionID, relaySocket === socket else {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
            handleRelayMessage(firstMessage)
            guard relayPhase != .failed else {
                throw RelayConnectionError.rejected(lastRelayEvent)
            }
            relayConnectedAt = Date()
            relayReceiveTask = Task { [weak self] in
                await self?.receiveRelayLoop(socket: socket, connectionID: connectionID)
            }
            startRoomStateRefresh(
                roomCode: roomCode,
                socket: socket,
                connectionID: connectionID
            )
            relayPhase = .ready
            relayLatencyMS = 0
            noteRelayEvent("房间已连接")
            if !pendingVoiceReadyRequestID.isEmpty {
                let pendingRequestID = pendingVoiceReadyRequestID
                Task { await self.confirmRemoteVoiceReady(requestID: pendingRequestID) }
            }
            print("DragonRadar Relay connected path=\(appSocketPath) room=\(roomCode)")
        } catch {
            guard relayConnectionID == connectionID, relaySocket === socket else {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
            tearDownRelayConnection()
            relayPhase = .failed
            noteRelayEvent("房间连接失败：\(error.localizedDescription)")
            print("DragonRadar Relay connect failed error=\(error.localizedDescription)")
        }
    }

    func publishLocation(_ snapshot: LocationSnapshot?) async {
        guard let snapshot else {
            relayPhase = .degraded
            noteRelayEvent("定位无效，未上传")
            return
        }
        guard relayPhase == .ready, relaySocket != nil else {
            noteRelayEvent("房间连接未就绪，定位等待上传")
            print("DragonRadar location send deferred relay=\(relayPhase.rawValue)")
            return
        }

        lastLocationFrame = snapshot.frameSummary
        noteRelayEvent("上传定位中 · \(snapshot.accuracyText)")
        let sequence = nextLocationSequence
        nextLocationSequence += 1
        lastLocationSequenceSent = sequence
        lastLocationSentAt = Date()
        var locationPayload: [String: Any] = [
            "lat_e7": Int(snapshot.latE7),
            "lon_e7": Int(snapshot.lonE7),
            "h_acc_cm": Int(snapshot.horizontalAccuracyCM),
            "speed_cms": Int(snapshot.speedCMS),
            "unix_time": Int(snapshot.timestamp.timeIntervalSince1970),
            "sequence": sequence
        ]
        if let courseDeg100 = snapshot.courseDeg100 {
            locationPayload["course_deg100"] = Int(courseDeg100)
        }
        do {
            try await sendRelayJSON([
                "type": "app_location",
                "sequence": sequence,
                "location": locationPayload
            ])
            relayPhase = .ready
            relayLatencyMS = relayConnectedAt.map { max(1, Int(Date().timeIntervalSince($0) * 1000)) } ?? relayLatencyMS
            noteRelayEvent("定位已上传 · seq \(sequence) · \(snapshot.accuracyText)")
            print("DragonRadar location sent sequence=\(sequence)")
        } catch {
            relayPhase = .failed
            noteRelayEvent("定位上传失败：\(error.localizedDescription)")
            let nsError = error as NSError
            print(
                "DragonRadar location send failed "
                    + "domain=\(nsError.domain) "
                    + "code=\(nsError.code)"
            )
        }
    }

    func pauseLocationSharing() async {
        do {
            try await sendRelayJSON([
                "type": "location_paused",
                "reason": "user_paused"
            ])
            lastLocationAckText = "定位共享已暂停"
            noteRelayEvent("定位共享已暂停")
        } catch {
            noteRelayEvent("定位暂停同步失败：\(error.localizedDescription)")
        }
    }

    #if !APP_ONLY
    func sendRoomSwitchToESP(roomCode: String, deviceToken: String) async -> Bool {
        guard !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            roomSwitchState = .waitingESPJoin
            roomSwitchDetail = "没有已绑定雷达，跳过切房通知"
            return false
        }
        let requestID = UUID().uuidString
        pendingRoomSwitchRequestID = requestID
        pendingRoomSwitchRoom = roomCode
        pendingRoomSwitchGroupID = Self.groupID(for: deviceToken)
        roomSwitchState = .notifyingESP
        roomSwitchDetail = "正在通知雷达进入 \(roomCode)"
        do {
            try await sendRelayJSON([
                "type": "room_switch",
                "request_id": requestID,
                "relay_url": relayBaseURL,
                "room_token": roomCode
            ])
            noteRelayEvent("已通知雷达切换房间 · \(roomCode)")
            return true
        } catch {
            roomSwitchState = .failed
            roomSwitchDetail = "切房通知发送失败 · \(error.localizedDescription)"
            noteRelayEvent("通知雷达切房失败：\(error.localizedDescription)")
            return false
        }
    }

    func writeLocationToESP(_ snapshot: LocationSnapshot?) async {
        guard let snapshot else {
            espPhase = .degraded
            noteESPEvent("定位无效，未写入雷达")
            return
        }

        pendingLocationWrite = true
        espPhase = .connecting
        noteESPEvent("定位已写入雷达 · \(snapshot.accuracyText)")
        try? await Task.sleep(for: .milliseconds(260))
        pendingLocationWrite = false
        espPhase = .ready
        lastLocationFrame = snapshot.frameSummary
        noteESPEvent("雷达已收到本机定位摘要")
    }

    func provisionESP(deviceName: String, roomCode: String) async {
        pendingServerConfig = true
        espPhase = .connecting
        noteESPEvent("写入房间配置 · \(deviceName)")
        try? await Task.sleep(for: .milliseconds(520))
        pendingServerConfig = false
        espPhase = .ready
        noteESPEvent("房间配置已写入 · \(roomCode)")
    }

    func noteESPServerConfigPending(roomCode: String, reason: String) {
        pendingServerConfig = true
        espPhase = .degraded
        noteESPEvent("等待同步 room \(roomCode) · \(reason)")
    }

    func observeVoiceRoom() async {
        voicePhase = .connecting
        noteVoiceEvent("等待房间下发雷达语音状态")
        try? await Task.sleep(for: .milliseconds(360))
        voicePhase = .ready
        noteVoiceEvent("正在观察雷达语音状态")
    }

    func stopObservingVoiceRoom() async {
        voicePhase = .idle
        noteVoiceEvent("已停止观察语音状态")
    }
    #endif

    func disconnectRelay() {
        let shouldReportDisconnect = relayPhase != .idle
        relayConnectionID = UUID()
        tearDownRelayConnection()
        if shouldReportDisconnect {
            relayPhase = .idle
            noteRelayEvent("房间已断开")
        }
    }

    private func tearDownRelayConnection() {
        relayReceiveTask?.cancel()
        relayReceiveTask = nil
        roomStateRefreshTask?.cancel()
        roomStateRefreshTask = nil
        relaySocket?.cancel(with: .goingAway, reason: nil)
        relaySocket = nil
        relayConnectedAt = nil
        currentRelayRoomCode = ""
    }

    private func appSocketURL(roomCode: String, webSocketTicket: String) -> URL? {
        var components = URLComponents(string: relayBaseURL + appSocketPath)
        components?.queryItems = [
            URLQueryItem(name: "room", value: roomCode),
            URLQueryItem(name: "app_id", value: localAppPeerID),
            URLQueryItem(name: "ticket", value: webSocketTicket),
        ]
        return components?.url
    }

    private func requestWebSocketTicket(accessToken: String) async throws -> String {
        guard
            !accessToken.isEmpty,
            let url = URL(string: AppEnvironment.current.httpAPIBaseURL + "/v1/auth/ws-ticket")
        else {
            throw RelayConnectionError.rejected("登录会话无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let code = (
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            ) ?? "HTTP \(httpResponse.statusCode)"
            throw RelayConnectionError.rejected(code)
        }
        guard
            let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ticket = envelope["ticket"] as? String,
            !ticket.isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }
        return ticket
    }

    private static func appPeerID(deviceToken: String, appAccessToken: String) -> String {
        let trimmed = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return "app-\(stableIdentifier(for: trimmed, fallback: "local"))"
        }
        return "app-\(stableIdentifier(for: appAccessToken, fallback: "local"))"
    }

    #if !APP_ONLY
    private static func groupID(for deviceToken: String) -> String {
        let trimmed = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return stableIdentifier(for: trimmed, fallback: "app-only")
    }
    #endif

    private static func stableIdentifier(for token: String, fallback: String) -> String {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else { return fallback }
        let digest = SHA256.hash(data: Data(cleanToken.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func sendRelayJSON(_ payload: [String: Any]) async throws {
        guard let relaySocket else {
            throw URLError(.notConnectedToInternet)
        }
        try await sendRelayJSON(payload, over: relaySocket)
    }

    private func sendRelayJSON(
        _ payload: [String: Any],
        over socket: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        try await socket.send(.string(text))
    }

    private func startRoomStateRefresh(
        roomCode: String,
        socket: URLSessionWebSocketTask,
        connectionID: UUID
    ) {
        roomStateRefreshTask?.cancel()
        roomStateRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.requestRoomStateRefresh(
                    roomCode: roomCode,
                    socket: socket,
                    connectionID: connectionID
                )
            }
        }
    }

    private func requestRoomStateRefresh(
        roomCode: String,
        socket: URLSessionWebSocketTask,
        connectionID: UUID
    ) async {
        guard relayConnectionID == connectionID, relaySocket === socket else { return }
        do {
            try await sendRelayJSON([
                "type": "heartbeat",
                "app": "DragonRadarMVP",
                "name": localDisplayName,
                "room": roomCode,
                "wants": ["room_state"]
            ], over: socket)
        } catch {
            guard relayConnectionID == connectionID, relaySocket === socket else { return }
            relayPhase = .failed
            noteRelayEvent("房间状态刷新失败：\(error.localizedDescription)")
        }
    }

    private func receiveRelayLoop(
        socket: URLSessionWebSocketTask,
        connectionID: UUID
    ) async {
        while !Task.isCancelled {
            guard relayConnectionID == connectionID, relaySocket === socket else { return }
            do {
                let message = try await socket.receive()
                guard relayConnectionID == connectionID, relaySocket === socket else { return }
                handleRelayMessage(message)
            } catch {
                if !Task.isCancelled,
                   relayConnectionID == connectionID,
                   relaySocket === socket
                {
                    relayPhase = .failed
                    noteRelayEvent("房间接收失败：\(error.localizedDescription)")
                    print("DragonRadar Relay receive failed error=\(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func handleRelayMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
        @unknown default:
            text = "未知消息"
        }

        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            noteRelayEvent("房间消息无法解析")
            return
        }

        switch type {
        case "hello_ack":
            handleRelayHelloAck(object)
        case "app_location_ack":
            let sequence = intValue(object["sequence"]) ?? 0
            lastLocationSequenceAcked = max(lastLocationSequenceAcked, sequence)
            lastLocationAckedAt = Date()
            lastLocationAckText = sequence > 0 ? "服务端已确认定位 · seq \(sequence)" : "服务端已确认定位"
            noteRelayEvent(lastLocationAckText)
        #if !APP_ONLY
        case "room_switch_ack":
            handleRoomSwitchAck(object)
        case "voice_busy":
            handleVoiceBusy(object)
        case "gateway_voice_wake":
            let requestID = object["request_id"] as? String ?? UUID().uuidString
            let speaker = object["speaker_name"] as? String ?? "房间成员"
            voicePhase = .connecting
            noteVoiceEvent("收到 \(speaker) 的远端语音唤醒")
            voiceWakeHandler?(requestID, speaker)
        case "gateway_voice_granted":
            let requestID = object["request_id"] as? String ?? activeVoiceRequestID
            voicePhase = .ready
            noteVoiceEvent("房间语音权已授予")
            voiceGrantedHandler?(requestID)
        case "gateway_voice_frame":
            if let encoded = object["audio_b64"] as? String,
               let frame = Data(base64Encoded: encoded) {
                voiceFrameHandler?(frame)
            }
        case "gateway_voice_end":
            voicePhase = .idle
            noteVoiceEvent("远端语音已结束")
            voiceEndHandler?()
        #endif
        case "radar_reminder":
            NotificationCenter.default.post(
                name: .dragonRadarReminderReceived,
                object: object,
                userInfo: ["source": "websocket"]
            )
            let sender = object["sender_name"] as? String ?? "房间成员"
            noteRelayEvent("\(sender) 提醒查看雷达")
        case "room_state":
            decodeRoomState(from: data, fallback: object)
        case "relay_event":
            let event = object["event"] as? String ?? "event"
            let from = object["from"] as? String ?? "peer"
            noteRelayEvent("房间事件 \(event) · \(from)")
        case "error":
            relayPhase = .failed
            let code = object["code"] as? String ?? "unknown"
            if code == "protocol_unsupported" {
                let required = intValue(object["required_protocol"]) ?? DragonRadarProtocol.minRelayProtocolVersion
                let client = intValue(object["client_protocol"]) ?? DragonRadarProtocol.appProtocolVersion
                compatibilityText = "不兼容 · App v\(client)，要求 v\(required)"
            }
            let relayError = RelayError(rawValue: code) ?? .unknown
            noteRelayEvent(relayError.localizedDescription)
        default:
            noteRelayEvent("房间事件 \(type)")
        }
    }

    #if !APP_ONLY
    private func handleVoiceBusy(_ object: [String: Any]) {
        voicePhase = .degraded
        let speakerGroupID = object["speaker_group_id"] as? String
        let speakerPeerID = object["speaker_peer_id"] as? String
        let speaker = speakerGroupID ?? speakerPeerID ?? "其他成员"
        noteVoiceEvent("抢麦失败，\(speaker) 正在说话")
        noteRelayEvent("当前有人正在说话 · \(speaker)")
    }
    #endif

    private func handleRelayHelloAck(_ object: [String: Any]) {
        let peerID = object["peer_id"] as? String ?? "app"
        if !peerID.isEmpty, peerID != "app" {
            // The relay may reject a stale device-derived app id and substitute
            // the access-token identity. Always use its authoritative id when
            // identifying our own member in subsequent room-state snapshots.
            localAppPeerID = peerID
        }
        let relayVersion = relayProtocolVersion(from: object)
        let minAppVersion = intValue(object["min_app_protocol_version"])
            ?? intValue((object["protocol"] as? [String: Any])?["min_app"])
        if let relayVersion {
            relayProtocolText = "Relay v\(relayVersion)"
            if relayVersion < DragonRadarProtocol.minRelayProtocolVersion {
                relayPhase = .failed
                compatibilityText = "不兼容 · 房间服务版本过低"
                noteRelayEvent("房间服务版本过低 · \(peerID)")
                relaySocket?.cancel(with: .goingAway, reason: nil)
                return
            }
            compatibilityText = "兼容"
        } else {
            relayProtocolText = "房间服务"
            compatibilityText = "等待版本确认"
        }
        if let minAppVersion, DragonRadarProtocol.appProtocolVersion < minAppVersion {
            relayPhase = .failed
            compatibilityText = "不兼容 · App v\(DragonRadarProtocol.appProtocolVersion)，要求 v\(minAppVersion)+"
            noteRelayEvent("App 版本过低 · \(peerID)")
            relaySocket?.cancel(with: .goingAway, reason: nil)
            return
        }
        noteRelayEvent("房间已确认 · \(peerID)")
    }

    private func decodeRoomState(from data: Data, fallback object: [String: Any]) {
        do {
            let envelope = try JSONDecoder().decode(RelayRoomStateSnapshot.self, from: data)
            guard shouldAcceptRoomState(envelope.room) else {
                noteRelayEvent("忽略旧房间状态 · \(envelope.room)")
                return
            }
            #if APP_ONLY
            let acceptedEnvelope = RelayRoomStateSnapshot(
                room: envelope.room,
                serverTime: envelope.serverTime,
                maxMembers: envelope.maxMembers,
                members: envelope.members.filter { $0.role == "app" }
            )
            #else
            let acceptedEnvelope = envelope
            #endif
            roomStateSnapshot = acceptedEnvelope
            relayRoomState = "room \(acceptedEnvelope.room) · \(acceptedEnvelope.members.count)/\(acceptedEnvelope.maxMembers) online"
            noteRelayEvent("房间状态已同步 · \(acceptedEnvelope.members.count) 在线")
            #if !APP_ONLY
            updateRoomSwitchState(from: acceptedEnvelope)
            updateDeviceProtocolState(from: acceptedEnvelope)
            #endif
        } catch {
            let room = object["room"] as? String ?? "-"
            guard shouldAcceptRoomState(room) else {
                noteRelayEvent("忽略旧房间状态 · \(room)")
                return
            }
            let members = object["members"] as? [[String: Any]] ?? []
            relayRoomState = "room \(room) · \(members.count)/7 online"
            if let fallback = fallbackRoomStateSnapshot(from: object) {
                roomStateSnapshot = fallback
                noteRelayEvent("房间状态已同步 · \(fallback.members.count) 在线")
                #if !APP_ONLY
                updateRoomSwitchState(from: fallback)
                updateDeviceProtocolState(from: fallback)
                #endif
            } else {
                noteRelayEvent("房间状态解析失败：\(error.localizedDescription)")
            }
        }
    }

    private func shouldAcceptRoomState(_ room: String) -> Bool {
        let expected = currentRelayRoomCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return true }
        return room.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    #if !APP_ONLY
    private func handleRoomSwitchAck(_ object: [String: Any]) {
        let requestID = stringValue(object["request_id"]) ?? ""
        guard requestID.isEmpty || requestID == pendingRoomSwitchRequestID else {
            noteRelayEvent("忽略旧切房确认 · \(requestID)")
            return
        }
        let delivered = intValue(object["delivered_devices"]) ?? 0
        let room = stringValue(object["room"]) ?? pendingRoomSwitchRoom
        roomSwitchState = .waitingESPJoin
        roomSwitchDetail = delivered > 0
            ? "雷达已收到切房通知 · 等待加入 \(room)"
            : "已记录切房 · 等待雷达在线后加入 \(room)"
        noteRelayEvent("切房确认 · delivered \(delivered)")
    }

    private func updateRoomSwitchState(from snapshot: RelayRoomStateSnapshot) {
        guard !pendingRoomSwitchRoom.isEmpty, snapshot.room == pendingRoomSwitchRoom else { return }
        let appGroupID = localAppPeerID.hasPrefix("app-") ? String(localAppPeerID.dropFirst(4)) : localAppPeerID
        let localGroup = pendingRoomSwitchGroupID.isEmpty ? appGroupID : pendingRoomSwitchGroupID
        guard let localMember = snapshot.members.first(where: { $0.memberID == localGroup || $0.peerID == localGroup }) else {
            return
        }
        if localMember.deviceOnline == true || localMember.deviceStatus != nil {
            roomSwitchState = .synced
            roomSwitchDetail = "雷达已进入 \(snapshot.room)"
            pendingRoomSwitchRequestID = ""
            pendingRoomSwitchRoom = ""
            pendingRoomSwitchGroupID = ""
        } else if roomSwitchState != .synced {
            roomSwitchState = .waitingESPJoin
            roomSwitchDetail = "App 已在 \(snapshot.room) · 等待本机雷达加入"
        }
    }

    private func updateDeviceProtocolState(from snapshot: RelayRoomStateSnapshot) {
        let outdatedDevice = snapshot.members.first { member in
            member.deviceOnline == true
                && (member.protocolVersion ?? DragonRadarProtocol.minDeviceProtocolVersion) < DragonRadarProtocol.minDeviceProtocolVersion
        }
        guard let outdatedDevice else {
            if compatibilityText.hasPrefix("不兼容 · 雷达") {
                relayPhase = .ready
                compatibilityText = "兼容 · App v\(DragonRadarProtocol.appProtocolVersion) / \(relayProtocolText)"
            }
            return
        }
        relayPhase = .degraded
        compatibilityText = "不兼容 · 雷达版本过低"
        noteRelayEvent("雷达版本过低 · \(outdatedDevice.memberID)")
    }
    #endif

    private func fallbackRoomStateSnapshot(from object: [String: Any]) -> RelayRoomStateSnapshot? {
        guard let rawMembers = object["members"] as? [[String: Any]] else { return nil }
        #if APP_ONLY
        let acceptedRawMembers = rawMembers.filter { stringValue($0["role"]) == "app" }
        #else
        let acceptedRawMembers = rawMembers
        #endif
        let members = acceptedRawMembers.map { rawMember in
            #if APP_ONLY
            let peerID = stringValue(rawMember["peer_id"])
                ?? stringValue(rawMember["app_peer_id"])
                ?? stringValue(rawMember["member_id"])
                ?? UUID().uuidString
            #else
            let peerID = stringValue(rawMember["peer_id"])
                ?? stringValue(rawMember["app_peer_id"])
                ?? stringValue(rawMember["device_peer_id"])
                ?? stringValue(rawMember["member_id"])
                ?? UUID().uuidString
            #endif
            let memberID = stringValue(rawMember["member_id"]) ?? peerID
            #if APP_ONLY
            return RelayRoomMemberSnapshot(
                role: stringValue(rawMember["role"]) ?? "member",
                memberID: memberID,
                peerID: peerID,
                name: stringValue(rawMember["name"]),
                online: boolValue(rawMember["online"]) ?? true,
                ageMS: intValue(rawMember["age_ms"]) ?? 0,
                lastSeenMS: intValue(rawMember["last_seen_ms"]) ?? 0,
                lastType: stringValue(rawMember["last_type"]) ?? "room_state",
                protocolVersion: intValue(rawMember["protocol_version"]),
                location: decodeNested(rawMember["location"], as: RelayLocationSnapshot.self),
                locationPaused: boolValue(rawMember["location_paused"]),
                appOnline: boolValue(rawMember["app_online"]),
                moderationRef: stringValue(rawMember["moderation_ref"])
            )
            #else
            return RelayRoomMemberSnapshot(
                role: stringValue(rawMember["role"]) ?? "member",
                memberID: memberID,
                peerID: peerID,
                name: stringValue(rawMember["name"]),
                online: boolValue(rawMember["online"]) ?? true,
                ageMS: intValue(rawMember["age_ms"]) ?? 0,
                lastSeenMS: intValue(rawMember["last_seen_ms"]) ?? 0,
                lastType: stringValue(rawMember["last_type"]) ?? "room_state",
                protocolVersion: intValue(rawMember["protocol_version"]),
                firmware: stringValue(rawMember["firmware"]),
                deviceStatus: decodeNested(rawMember["device_status"], as: RelayDeviceStatusSnapshot.self),
                voiceStatus: decodeNested(rawMember["voice_status"], as: RelayVoiceStatusSnapshot.self),
                location: decodeNested(rawMember["location"], as: RelayLocationSnapshot.self),
                locationPaused: boolValue(rawMember["location_paused"]),
                appOnline: boolValue(rawMember["app_online"]),
                deviceOnline: boolValue(rawMember["device_online"]),
                moderationRef: stringValue(rawMember["moderation_ref"])
            )
            #endif
        }
        #if APP_ONLY
        return RelayRoomStateSnapshot(
            room: stringValue(object["room"]) ?? "-",
            serverTime: intValue(object["server_time"]) ?? Int(Date().timeIntervalSince1970),
            maxMembers: intValue(object["max_members"]) ?? 7,
            members: members
        )
        #else
        return RelayRoomStateSnapshot(
            room: stringValue(object["room"]) ?? "-",
            serverTime: intValue(object["server_time"]) ?? Int(Date().timeIntervalSince1970),
            maxMembers: intValue(object["max_members"]) ?? 7,
            voiceFloor: decodeNested(object["voice_floor"], as: RelayVoiceFloorSnapshot.self),
            members: members
        )
        #endif
    }

    private func decodeNested<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String where !string.isEmpty:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func relayProtocolVersion(from object: [String: Any]) -> Int? {
        if let value = intValue(object["relay_protocol_version"]) {
            return value
        }
        if let protocolObject = object["protocol"] as? [String: Any] {
            return intValue(protocolObject["relay"])
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["true", "1", "yes"].contains(string.lowercased())
        default:
            return nil
        }
    }

    func noteRelayEvent(_ value: String) {
        lastRelayEvent = value
        relayEventHistory = Self.append(value, to: relayEventHistory)
    }

    #if !APP_ONLY
    func noteESPEvent(_ value: String) {
        lastESPEvent = value
        espEventHistory = Self.append(value, to: espEventHistory)
    }

    func noteVoiceEvent(_ value: String) {
        lastVoiceEvent = value
        voiceEventHistory = Self.append(value, to: voiceEventHistory)
    }
    #endif

    private static func append(_ value: String, to history: [String]) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return Array(([ "\(stamp) \(trimmed)" ] + history).prefix(20))
    }

    private static func relativeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds)秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        return "\(hours)小时前"
    }
}
