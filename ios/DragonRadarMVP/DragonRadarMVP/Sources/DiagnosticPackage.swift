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
                "voice_quality": appState.roomStatus
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
                "recent_events": redactedLocationEvents(radarRuntime.relayEventHistory)
            ],
            "location": [
                "permission": locationBridge.permissionText,
                "precision": locationBridge.precisionText,
                "background": locationBridge.backgroundText,
                "upload_readiness": locationBridge.uploadReadinessText,
                "sharing": locationBridge.sharingText,
                "accuracy": locationBridge.accuracyText,
                "age": locationBridge.locationAgeText,
                "course": locationBridge.courseText,
                "phone_heading_reference": locationBridge.phoneHeadingReferenceText,
                "phone_heading_quality": locationBridge.phoneHeadingQuality.rawValue,
                "phone_heading_accuracy": locationBridge.phoneHeadingAccuracyText,
                "phone_heading_age": locationBridge.phoneHeadingAgeText,
                "phone_heading_forwarded_as_radar_heading": false,
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
                "recent_events": redactedLocationEvents(bleBridge.bleEventHistory)
            ],
            "esp": espStatus(bleBridge.deviceStatus),
            "ota": otaStatus(bleBridge: bleBridge),
            "voice": [
                "phase": radarRuntime.voicePhase.rawValue,
                "last_event": radarRuntime.lastVoiceEvent,
                "recent_events": redactedLocationEvents(radarRuntime.voiceEventHistory),
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
            "last": status.last,
            "firmware_version": status.firmwareVersion ?? "",
            "firmware_build": status.firmwareBuild ?? 0,
            "hardware": status.hardware ?? "",
            "security_counter": status.securityCounter ?? -1,
            "ota_origin": status.otaOrigin ?? 0,
            "ota_capable": status.supportsOTA
        ]
    }

    @MainActor
    private static func otaStatus(bleBridge: BLEDeviceBridge) -> [String: Any] {
        guard let status = bleBridge.firmwareStatus else {
            return [
                "available": false,
                "control_characteristic": bleBridge.hasCharacteristic(.firmwareControl),
                "status_characteristic": bleBridge.hasCharacteristic(.firmwareStatus),
                "supported": bleBridge.supportsFirmwareOTA,
                "raw_status": bleBridge.firmwareStatusText
            ]
        }
        return [
            "available": true,
            "supported": bleBridge.supportsFirmwareOTA,
            "firmware_version": status.firmwareVersion ?? "",
            "build": status.build ?? 0,
            "hardware": status.hardware ?? "",
            "stage": status.stage,
            "progress": status.progress,
            "received_bytes": status.receivedBytes ?? 0,
            "total_bytes": status.totalBytes ?? 0,
            "target_version": status.targetVersion ?? "",
            "target_build": status.targetBuild ?? 0,
            "error": status.errorCode ?? "",
            "raw_status": bleBridge.firmwareStatusText
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

    private static func redactedLocationEvents(_ events: [String]) -> [String] {
        let coordinatePattern = #"[-+]?\d{1,3}\.\d{4,}\s*,\s*[-+]?\d{1,3}\.\d{4,}"#
        guard let regex = try? NSRegularExpression(pattern: coordinatePattern) else {
            return Array(events.prefix(20))
        }
        return events.prefix(20).map { event in
            let range = NSRange(event.startIndex..<event.endIndex, in: event)
            return regex.stringByReplacingMatches(
                in: event,
                range: range,
                withTemplate: "<location omitted>"
            )
        }
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
            "ota": bleBridge.firmwareStatus?.stage == "error" ? (bleBridge.firmwareStatus?.errorCode ?? "firmware_update_error") : "ok",
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
