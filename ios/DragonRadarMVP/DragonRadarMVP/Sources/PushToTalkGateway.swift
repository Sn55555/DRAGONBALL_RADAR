import AVFAudio
import Foundation
import Observation
import PushToTalk

@MainActor
@Observable
final class PushToTalkGateway: NSObject, @preconcurrency PTChannelManagerDelegate,
    @preconcurrency PTChannelRestorationDelegate {
    @ObservationIgnored private var manager: PTChannelManager?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var roomCode = ""
    @ObservationIgnored private var accessToken = ""
    @ObservationIgnored private var displayName = "Capsule Radar 用户"
    @ObservationIgnored private var pendingJoin = false
    @ObservationIgnored private var incomingWakeHandler: ((String, String) -> Void)?
    @ObservationIgnored private var systemTransmitHandler: ((Bool) -> Void)?
    @ObservationIgnored private var pendingIncomingWake: (requestID: String, speaker: String)?

    var phaseText = "正在初始化系统 PTT"
    var activeChannelUUID: UUID?
    var tokenRegistrationText = "尚未取得 PTT Push Token"
    var lastIncomingSpeaker = ""

    override init() {
        super.init()
        PTChannelManager.channelManager(
            delegate: self,
            restorationDelegate: self
        ) { [weak self] manager, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.phaseText = "系统 PTT 初始化失败：\(error.localizedDescription)"
                    return
                }
                self.manager = manager
                self.activeChannelUUID = manager?.activeChannelUUID
                self.phaseText = manager?.activeChannelUUID == nil ? "系统 PTT 已就绪" : "系统 PTT 房间已恢复"
                if self.pendingJoin {
                    self.joinCurrentRoomIfPossible()
                }
            }
        }
    }

    func configureCallbacks(
        onIncomingWake: @escaping (String, String) -> Void,
        onSystemTransmit: @escaping (Bool) -> Void
    ) {
        incomingWakeHandler = onIncomingWake
        systemTransmitHandler = onSystemTransmit
        if let pendingIncomingWake {
            self.pendingIncomingWake = nil
            onIncomingWake(pendingIncomingWake.requestID, pendingIncomingWake.speaker)
        }
    }

    func prepare(roomCode: String, displayName: String, accessToken: String) {
        self.roomCode = roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessToken = accessToken
        pendingJoin = true
        joinCurrentRoomIfPossible()
    }

    func leave() {
        guard let manager, let channelUUID = manager.activeChannelUUID else { return }
        manager.leaveChannel(channelUUID: channelUUID)
    }

    func beginSystemTransmission() {
        guard let manager, let channelUUID = manager.activeChannelUUID else { return }
        manager.requestBeginTransmitting(channelUUID: channelUUID)
    }

    func endSystemTransmission() {
        guard let manager, let channelUUID = manager.activeChannelUUID else { return }
        manager.stopTransmitting(channelUUID: channelUUID)
    }

    func setRemoteSpeaker(_ name: String?) {
        guard let manager, let channelUUID = manager.activeChannelUUID else { return }
        let participant = name.flatMap { cleanName -> PTParticipant? in
            let clean = cleanName.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : PTParticipant(name: clean, image: nil)
        }
        manager.setActiveRemoteParticipant(participant, channelUUID: channelUUID, completionHandler: nil)
    }

    private func joinCurrentRoomIfPossible() {
        guard let manager, !roomCode.isEmpty else { return }
        let channelUUID = Self.channelUUID(for: roomCode, defaults: defaults)
        if manager.activeChannelUUID == channelUUID {
            pendingJoin = false
            activeChannelUUID = channelUUID
            phaseText = "系统 PTT 已加入房间"
            return
        }
        if let active = manager.activeChannelUUID, active != channelUUID {
            manager.leaveChannel(channelUUID: active)
        }
        pendingJoin = false
        let descriptor = PTChannelDescriptor(name: "Capsule Radar · \(roomCode)", image: nil)
        manager.requestJoinChannel(channelUUID: channelUUID, descriptor: descriptor)
        phaseText = "正在加入系统 PTT 房间"
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        activeChannelUUID = channelUUID
        return PTChannelDescriptor(name: "Capsule Radar", image: nil)
    }

    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID,
                        reason: PTChannelJoinReason) {
        activeChannelUUID = channelUUID
        phaseText = "系统 PTT 已加入房间"
        channelManager.setTransmissionMode(.halfDuplex, channelUUID: channelUUID, completionHandler: nil)
        if #available(iOS 17.0, *) {
            channelManager.setAccessoryButtonEventsEnabled(true, channelUUID: channelUUID, completionHandler: nil)
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID,
                        reason: PTChannelLeaveReason) {
        if activeChannelUUID == channelUUID { activeChannelUUID = nil }
        phaseText = "系统 PTT 已离开房间"
        tokenRegistrationText = "PTT Push Token 已失效"
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID,
                        didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        phaseText = "系统 PTT 正在发言"
        systemTransmitHandler?(true)
    }

    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID,
                        didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        phaseText = "系统 PTT 等待语音"
        systemTransmitHandler?(false)
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        let token = pushToken.map { String(format: "%02x", $0) }.joined()
        tokenRegistrationText = "正在登记 PTT Push Token"
        Task { await register(token: token, channelUUID: channelManager.activeChannelUUID) }
    }

    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID,
                            pushPayload: [String: Any]) -> PTPushResult {
        let requestID = pushPayload["request_id"] as? String ?? UUID().uuidString
        let speaker = pushPayload["speaker_name"] as? String ?? "房间成员"
        lastIncomingSpeaker = speaker
        phaseText = "收到 \(speaker) 的后台语音请求"
        if let incomingWakeHandler {
            incomingWakeHandler(requestID, speaker)
        } else {
            pendingIncomingWake = (requestID, speaker)
        }
        return .activeRemoteParticipant(PTParticipant(name: speaker, image: nil))
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        phaseText = "系统 PTT 音频会话已激活"
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        phaseText = "系统 PTT 音频会话已释放"
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID,
                        error: Error) {
        phaseText = "系统 PTT 加入失败：\(error.localizedDescription)"
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToBeginTransmittingInChannel channelUUID: UUID, error: Error) {
        phaseText = "系统 PTT 发言失败：\(error.localizedDescription)"
    }

    private func register(token: String, channelUUID: UUID?) async {
        guard
            !accessToken.isEmpty,
            !roomCode.isEmpty,
            let channelUUID,
            let url = URL(string: AppEnvironment.current.httpAPIBaseURL + "/v1/push-to-talk/token")
        else {
            tokenRegistrationText = "等待登录房间后登记 PTT Token"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        #if DEBUG
        let apnsEnvironment = "sandbox"
        #else
        let apnsEnvironment = "production"
        #endif
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "room": roomCode,
            "channel_uuid": channelUUID.uuidString,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.sn5.DragonRadarMVP",
            "environment": apnsEnvironment
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                tokenRegistrationText = "PTT Token 登记被服务端拒绝"
                return
            }
            tokenRegistrationText = "PTT Push Token 已登记"
        } catch {
            tokenRegistrationText = "PTT Token 登记失败：\(error.localizedDescription)"
        }
    }

    static func channelUUID(for roomCode: String, defaults: UserDefaults) -> UUID {
        let key = "dragonRadar.ptt.channel." + roomCode.uppercased()
        if let raw = defaults.string(forKey: key), let stored = UUID(uuidString: raw) {
            return stored
        }
        let created = UUID()
        defaults.set(created.uuidString, forKey: key)
        return created
    }
}
