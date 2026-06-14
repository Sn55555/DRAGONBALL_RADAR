import Foundation

enum DiagnosticPackageFactory {
    @MainActor
    static func makeReport(
        appState: AppState,
        radarRuntime: RadarRuntime,
        locationBridge: LocationBridge,
        bleBridge: BLEDeviceBridge
    ) -> [String: Any] {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let environment = AppEnvironment.current

        return [
            "schema": "dragon-radar-diagnostics-v1",
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "app": [
                "version": appVersion,
                "build": build,
                "environment": environment.name.rawValue,
                "http_api_base_url": environment.httpAPIBaseURL,
                "relay_base_url": environment.relayBaseURL
            ],
            "privacy": [
                "contains_token": false,
                "contains_wifi_password": false,
                "contains_precise_location_history": false,
                "location_coordinates": "omitted"
            ],
            "session": [
                "signed_in": appState.isSignedIn,
                "display_name": appState.displayName,
                "user_id_present": appState.sessionStore.session?.userID.isEmpty == false,
                "access_token": "omitted",
                "refresh_token": "omitted"
            ],
            "room": [
                "room_id": appState.activeRoomID.uuidString,
                "room_name": appState.activeRoomName,
                "room_code": appState.inviteCode,
                "online_members": appState.onlineMembers,
                "capacity": appState.roomCapacity,
                "voice_quality": appState.voiceQuality
            ],
            "relay": [
                "phase": radarRuntime.relayPhase.rawValue,
                "last_event": radarRuntime.lastRelayEvent,
                "room_state": radarRuntime.relayRoomState,
                "latency_ms": radarRuntime.relayLatencyMS,
                "last_location_sequence_sent": radarRuntime.lastLocationSequenceSent,
                "last_location_sequence_acked": radarRuntime.lastLocationSequenceAcked,
                "last_location_ack": radarRuntime.lastLocationAckText,
                "last_location_sent_age": radarRuntime.lastLocationSentText,
                "last_location_acked_age": radarRuntime.lastLocationAckedText,
                "recent_events": Array(radarRuntime.relayEventHistory.prefix(20))
            ],
            "location": [
                "permission": locationBridge.permissionText,
                "precision": locationBridge.precisionText,
                "background": locationBridge.backgroundText,
                "upload_readiness": locationBridge.uploadReadinessText,
                "sharing": locationBridge.sharingText,
                "accuracy": locationBridge.accuracyText,
                "age": locationBridge.locationAgeText,
                "last_update": locationBridge.lastUpdateText,
                "last_error": locationBridge.lastError ?? "",
                "coordinate": "omitted"
            ],
            "ble": [
                "state": bleBridge.stateText,
                "authorization": bleBridge.authorizationText,
                "connected_peripheral": bleBridge.connectedPeripheralName,
                "registration": bleBridge.registrationText,
                "last_event": bleBridge.lastEvent,
                "last_write": bleBridge.lastWriteEvent,
                "available_characteristics": bleBridge.availableCharacteristicNames,
                "recent_events": Array(bleBridge.bleEventHistory.prefix(20))
            ],
            "esp": espStatus(bleBridge.deviceStatus),
            "voice": [
                "phase": radarRuntime.voicePhase.rawValue,
                "last_event": radarRuntime.lastVoiceEvent,
                "recent_events": Array(radarRuntime.voiceEventHistory.prefix(20)),
                "active_speakers": appState.activeSpeakers.map { $0.name }
            ],
            "room_state": roomStateSummary(radarRuntime.roomStateSnapshot),
            "diagnostics": appState.diagnostics.map {
                [
                    "title": $0.title,
                    "detail": $0.detail,
                    "passed": $0.passed
                ]
            },
            "issues": issues(appState: appState, radarRuntime: radarRuntime, locationBridge: locationBridge, bleBridge: bleBridge)
        ]
    }

    @MainActor
    static func makeJSONString(
        appState: AppState,
        radarRuntime: RadarRuntime,
        locationBridge: LocationBridge,
        bleBridge: BLEDeviceBridge
    ) -> String {
        let report = makeReport(
            appState: appState,
            radarRuntime: radarRuntime,
            locationBridge: locationBridge,
            bleBridge: bleBridge
        )
        guard
            JSONSerialization.isValidJSONObject(report),
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return #"{"schema":"dragon-radar-diagnostics-v1","error":"encode_failed"}"#
        }
        return string
    }

    private static func espStatus(_ status: RadarBLEDeviceStatus?) -> [String: Any] {
        guard let status else {
            return ["available": false]
        }
        return [
            "available": true,
            "name": status.name,
            "ble": status.ble,
            "paired": status.paired,
            "wifi": status.wifi,
            "server": status.server,
            "relay": status.relay ?? "",
            "loc": status.loc,
            "rssi": status.rssi,
            "ip": status.ip,
            "last": status.last
        ]
    }

    private static func roomStateSummary(_ snapshot: RelayRoomStateSnapshot?) -> [String: Any] {
        guard let snapshot else {
            return ["available": false]
        }
        return [
            "available": true,
            "room": snapshot.room,
            "server_time": snapshot.serverTime,
            "max_members": snapshot.maxMembers,
            "voice_floor_active": snapshot.voiceFloor?.active ?? false,
            "voice_floor_speaker_group_id": snapshot.voiceFloor?.speakerGroupID ?? "",
            "members": snapshot.members.map {
                [
                    "member_id": $0.memberID,
                    "name": $0.name ?? "",
                    "online": $0.online,
                    "app_online": $0.appOnline ?? false,
                    "device_online": $0.deviceOnline ?? false,
                    "last_type": $0.lastType,
                    "has_location": $0.location != nil,
                    "location_paused": $0.locationPaused ?? false,
                    "voice_status": voiceStatusSummary($0.voiceStatus)
                ] as [String: Any]
            }
        ]
    }

    private static func voiceStatusSummary(_ status: RelayVoiceStatusSnapshot?) -> [String: Any] {
        guard let status else {
            return ["available": false]
        }
        return [
            "available": true,
            "muted": status.muted ?? false,
            "ptt": status.ptt ?? false,
            "vad": status.vad ?? false,
            "speaker": status.speaker ?? false,
            "floor_granted": status.floorGranted ?? false,
            "codec": status.codec ?? "",
            "sample_rate": status.sampleRate ?? 0,
            "frame_ms": status.frameMS ?? 0,
            "sequence": status.sequence ?? 0,
            "received_sequence": status.receivedSequence ?? 0,
            "lost_frames": status.lostFrames ?? 0,
            "rms": status.rms ?? 0,
            "peak": status.peak ?? 0
        ]
    }

    @MainActor
    private static func issues(
        appState: AppState,
        radarRuntime: RadarRuntime,
        locationBridge: LocationBridge,
        bleBridge: BLEDeviceBridge
    ) -> [String: String] {
        [
            "permission": locationBridge.permissionText == "不可用" ? "定位权限不可用" : "ok",
            "location_precision": locationBridge.isReducedAccuracy ? "精确定位未开启" : "ok",
            "network": radarRuntime.relayPhase == .failed ? radarRuntime.lastRelayEvent : "ok",
            "server": radarRuntime.lastLocationSequenceSent > radarRuntime.lastLocationSequenceAcked ? "定位上传未确认" : "ok",
            "device": bleBridge.isRegistrationComplete ? "ok" : bleBridge.registrationText,
            "room": appState.inviteCode.isEmpty ? "未进入房间" : "ok",
            "voice": (radarRuntime.voicePhase == .failed || radarRuntime.voicePhase == .degraded) ? radarRuntime.lastVoiceEvent : "ok"
        ]
    }
}

struct DiagnosticsRepository {
    var httpBaseURL = AppEnvironment.current.httpAPIBaseURL
    var accessToken = ""

    func submit(report: [String: Any]) async throws -> String {
        guard let url = URL(string: httpBaseURL + "/v1/diagnostics") else {
            throw URLError(.badURL)
        }
        guard !accessToken.isEmpty else {
            throw RoomRepositoryError.server(code: "unauthorized", detail: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["report": report], options: [.sortedKeys])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data) {
                throw RoomRepositoryError.server(code: error.code, detail: error.detail)
            }
            throw RoomRepositoryError.badResponse
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let diagnostics = object?["diagnostics"] as? [String: Any]
        return diagnostics?["report_id"] as? String ?? "已上传"
    }
}
