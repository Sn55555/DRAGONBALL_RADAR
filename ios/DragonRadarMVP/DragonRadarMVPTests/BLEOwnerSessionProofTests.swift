import XCTest
@testable import DragonRadarMVP

final class BLEOwnerSessionProofTests: XCTestCase {
    func testOwnerSessionProofMatchesFirmwareContract() {
        let response = BLEOwnerSessionProof.make(
            challenge: "CR-A17C-00112233445566778899AABBCCDDEEFF",
            deviceToken: "ddt_owner_secret",
            nonce: "0123456789abcdef0123456789abcdef"
        )

        XCTAssertEqual(
            response,
            "dra-auth:v1:t:0123456789abcdef0123456789abcdef:678b9c7521851c309373db4fab73ce4e5fe6de0e14f04692664cc82abd5b7eee"
        )
    }

    func testOwnerSessionProofRejectsPlaceholderChallengeAndMissingToken() {
        XCTAssertNil(BLEOwnerSessionProof.make(challenge: "未读取", deviceToken: "ddt_owner_secret"))
        XCTAssertNil(BLEOwnerSessionProof.make(challenge: "CR-A17C-0011", deviceToken: ""))
        XCTAssertNil(
            BLEOwnerSessionProof.make(
                challenge: "CR-A17C-0011",
                deviceToken: "ddt_owner_secret",
                nonce: "too-short"
            )
        )
    }

    func testPairingTransactionRejectsStaleAlreadyPairedState() throws {
        let startedAt = Date()
        let status = try decodeStatus(
            last: "pairing_response locked",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertFalse(
            BLEPairingTransactionGate.pairingResponseAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
        XCTAssertTrue(
            BLEPairingTransactionGate.pairingResponseRejected(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt
            )
        )
    }

    func testPairingTransactionRequiresExactFreshConfirmation() throws {
        let startedAt = Date()
        let status = try decodeStatus(
            last: "pairing_response_verified",
            paired: 1,
            server: 0,
            ownerAuth: 1
        )

        XCTAssertFalse(
            BLEPairingTransactionGate.pairingResponseAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(-0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
        XCTAssertTrue(
            BLEPairingTransactionGate.pairingResponseAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
    }

    func testServerConfigRequiresFreshOwnerProof() throws {
        let startedAt = Date()
        let status = try decodeStatus(
            last: "owner_session_authorized",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertFalse(
            BLEPairingTransactionGate.serverConfigAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: false
            )
        )
        XCTAssertTrue(
            BLEPairingTransactionGate.serverConfigAccepted(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
    }

    func testWifiConfigUsesRoleSpecificGattConfirmation() throws {
        let startedAt = Date()
        let unrelatedStatus = try decodeStatus(
            last: "room_state_projected",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertTrue(
            BLEWifiConfigTransactionGate.confirmed(
                startedAt: startedAt,
                gattConfirmedAt: startedAt.addingTimeInterval(0.1),
                status: unrelatedStatus,
                statusAt: startedAt.addingTimeInterval(0.2)
            )
        )
        XCTAssertFalse(
            BLEWifiConfigTransactionGate.confirmed(
                startedAt: startedAt,
                gattConfirmedAt: startedAt.addingTimeInterval(-0.1),
                status: unrelatedStatus,
                statusAt: startedAt.addingTimeInterval(0.2)
            )
        )
    }

    func testWifiConfigReportsFreshOwnerRejection() throws {
        let startedAt = Date()
        let rejected = try decodeStatus(
            last: "owner_auth_required",
            paired: 1,
            server: 1,
            ownerAuth: 0
        )

        XCTAssertNotNil(
            BLEWifiConfigTransactionGate.rejected(
                startedAt: startedAt,
                gattErrorAt: nil,
                gattError: nil,
                status: rejected,
                statusAt: startedAt.addingTimeInterval(0.1)
            )
        )
        XCTAssertNil(
            BLEWifiConfigTransactionGate.rejected(
                startedAt: startedAt,
                gattErrorAt: nil,
                gattError: nil,
                status: rejected,
                statusAt: startedAt.addingTimeInterval(-0.1)
            )
        )
    }

    func testWifiConfigReadinessWaitsForChannelStatusAndOwnerAuthorization() throws {
        let authorizedStatus = try decodeStatus(
            last: "owner_session_authorized",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertEqual(
            BLEWifiConfigWriteReadiness.resolve(
                isConnected: false,
                hasWifiConfigCharacteristic: true,
                status: authorizedStatus,
                ownerSessionAuthorized: true
            ),
            .disconnected
        )
        XCTAssertEqual(
            BLEWifiConfigWriteReadiness.resolve(
                isConnected: true,
                hasWifiConfigCharacteristic: false,
                status: authorizedStatus,
                ownerSessionAuthorized: true
            ),
            .channelUnavailable
        )
        XCTAssertEqual(
            BLEWifiConfigWriteReadiness.resolve(
                isConnected: true,
                hasWifiConfigCharacteristic: true,
                status: nil,
                ownerSessionAuthorized: true
            ),
            .statusUnavailable
        )
        XCTAssertEqual(
            BLEWifiConfigWriteReadiness.resolve(
                isConnected: true,
                hasWifiConfigCharacteristic: true,
                status: authorizedStatus,
                ownerSessionAuthorized: false
            ),
            .ownerAuthorizationRequired
        )
        XCTAssertEqual(
            BLEWifiConfigWriteReadiness.resolve(
                isConnected: true,
                hasWifiConfigCharacteristic: true,
                status: authorizedStatus,
                ownerSessionAuthorized: true
            ),
            .ready
        )
    }

    func testOTACapabilityDoesNotTreatTransientCharacteristicDiscoveryAsUnsupported() {
        XCTAssertEqual(
            BLEFirmwareOTACapability.resolve(
                otaCapable: 1,
                hasControlCharacteristic: false,
                hasStatusCharacteristic: false
            ),
            .supported
        )
        XCTAssertEqual(
            BLEFirmwareOTACapability.resolve(
                otaCapable: nil,
                hasControlCharacteristic: true,
                hasStatusCharacteristic: true
            ),
            .supported
        )
        XCTAssertEqual(
            BLEFirmwareOTACapability.resolve(
                otaCapable: nil,
                hasControlCharacteristic: false,
                hasStatusCharacteristic: false
            ),
            .unknown
        )
        XCTAssertEqual(
            BLEFirmwareOTACapability.resolve(
                otaCapable: 0,
                hasControlCharacteristic: true,
                hasStatusCharacteristic: true
            ),
            .unsupported
        )
    }

    func testOwnerReleaseRequiresFreshPreparedStatusAndOwnerProof() throws {
        let startedAt = Date()
        let status = try decodeStatus(
            last: "release_prepared",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertFalse(
            BLEOwnerReleaseTransactionGate.prepared(
                status: status,
                statusAt: startedAt.addingTimeInterval(-0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
        XCTAssertFalse(
            BLEOwnerReleaseTransactionGate.prepared(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: false
            )
        )
        XCTAssertTrue(
            BLEOwnerReleaseTransactionGate.prepared(
                status: status,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt,
                ownerSessionAuthorized: true
            )
        )
    }

    func testOwnerReleaseRecognizesCommitAndFirmwareRejection() throws {
        let startedAt = Date()
        let committed = try decodeStatus(
            last: "release_committed",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )
        let rejected = try decodeStatus(
            last: "release_blocked_ota",
            paired: 1,
            server: 1,
            ownerAuth: 1
        )

        XCTAssertTrue(
            BLEOwnerReleaseTransactionGate.committed(
                status: committed,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt
            )
        )
        XCTAssertTrue(
            BLEOwnerReleaseTransactionGate.rejected(
                status: rejected,
                statusAt: startedAt.addingTimeInterval(0.1),
                startedAt: startedAt
            )
        )
    }

    func testRoomStateProjectionSignatureIgnoresRelayClockAndTelemetryChurn() throws {
        let first = try decodeRoomState(
            serverTime: 1_700_000_000,
            ageMS: 100,
            locationAgeMS: 150,
            latitudeE7: 312_000_000,
            speaking: false,
            voiceSequence: 10
        )
        let replay = try decodeRoomState(
            serverTime: 1_700_000_001,
            ageMS: 1_100,
            locationAgeMS: 1_150,
            latitudeE7: 312_000_000,
            speaking: false,
            voiceSequence: 40
        )

        XCTAssertEqual(
            RadarRoomStateBLEProjectionSignature(
                snapshot: first,
                localAppPeerID: "app-local"
            ),
            RadarRoomStateBLEProjectionSignature(
                snapshot: replay,
                localAppPeerID: "app-local"
            )
        )
    }

    func testRoomStateProjectionSignatureChangesForLocationAndSpeakingState() throws {
        let idle = try decodeRoomState(
            serverTime: 1_700_000_000,
            ageMS: 100,
            locationAgeMS: 150,
            latitudeE7: 312_000_000,
            speaking: false,
            voiceSequence: 10
        )
        let moved = try decodeRoomState(
            serverTime: 1_700_000_001,
            ageMS: 200,
            locationAgeMS: 250,
            latitudeE7: 312_000_100,
            speaking: false,
            voiceSequence: 11
        )
        let speaking = try decodeRoomState(
            serverTime: 1_700_000_001,
            ageMS: 200,
            locationAgeMS: 250,
            latitudeE7: 312_000_000,
            speaking: true,
            voiceSequence: 11
        )
        let idleSignature = RadarRoomStateBLEProjectionSignature(
            snapshot: idle,
            localAppPeerID: "app-local"
        )

        XCTAssertNotEqual(
            idleSignature,
            RadarRoomStateBLEProjectionSignature(
                snapshot: moved,
                localAppPeerID: "app-local"
            )
        )
        XCTAssertNotEqual(
            idleSignature,
            RadarRoomStateBLEProjectionSignature(
                snapshot: speaking,
                localAppPeerID: "app-local"
            )
        )
    }

    func testRoomStateProjectionPolicyThrottlesIdleButRefreshesSpeaking() throws {
        let referenceDate = Date()
        let idle = try decodeRoomState(
            serverTime: 1_700_000_000,
            ageMS: 100,
            locationAgeMS: 150,
            latitudeE7: 312_000_000,
            speaking: false,
            voiceSequence: 10
        )
        let speaking = try decodeRoomState(
            serverTime: 1_700_000_000,
            ageMS: 100,
            locationAgeMS: 150,
            latitudeE7: 312_000_000,
            speaking: true,
            voiceSequence: 10
        )
        let idleSignature = RadarRoomStateBLEProjectionSignature(
            snapshot: idle,
            localAppPeerID: "app-local"
        )
        let speakingSignature = RadarRoomStateBLEProjectionSignature(
            snapshot: speaking,
            localAppPeerID: "app-local"
        )

        XCTAssertFalse(
            RadarRoomStateBLEProjectionPolicy.shouldSchedule(
                signature: idleSignature,
                referenceSignature: idleSignature,
                referenceDate: referenceDate,
                now: referenceDate.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            RadarRoomStateBLEProjectionPolicy.shouldSchedule(
                signature: idleSignature,
                referenceSignature: idleSignature,
                referenceDate: referenceDate,
                now: referenceDate.addingTimeInterval(10)
            )
        )
        XCTAssertTrue(
            RadarRoomStateBLEProjectionPolicy.shouldSchedule(
                signature: speakingSignature,
                referenceSignature: speakingSignature,
                referenceDate: referenceDate,
                now: referenceDate.addingTimeInterval(0.75)
            )
        )
    }

    func testEmptyProjectionAndClearAreEquivalentForScheduling() throws {
        let referenceDate = Date()
        let emptySnapshot = try JSONDecoder().decode(
            RelayRoomStateSnapshot.self,
            from: Data(
                """
                {
                  "room": "KAME-TEST",
                  "server_time": 1700000000,
                  "max_members": 7,
                  "voice_floor": {
                    "active": false,
                    "speaker_group_id": null,
                    "speaker_peer_id": null,
                    "expires_in_ms": 0
                  },
                  "members": []
                }
                """.utf8
            )
        )
        let emptySignature = RadarRoomStateBLEProjectionSignature(
            snapshot: emptySnapshot,
            localAppPeerID: "app-local"
        )

        XCTAssertTrue(emptySignature.isEmpty)
        XCTAssertFalse(
            RadarRoomStateBLEProjectionPolicy.shouldScheduleClear(
                referenceSignature: emptySignature,
                referenceWasClear: false
            )
        )
        XCTAssertFalse(
            RadarRoomStateBLEProjectionPolicy.shouldScheduleProjection(
                signature: emptySignature,
                referenceSignature: nil,
                referenceWasClear: true,
                referenceDate: referenceDate,
                now: referenceDate.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            RadarRoomStateBLEProjectionPolicy.shouldScheduleProjection(
                signature: emptySignature,
                referenceSignature: nil,
                referenceWasClear: true,
                referenceDate: referenceDate,
                now: referenceDate.addingTimeInterval(10)
            )
        )
    }

    private func decodeStatus(
        last: String,
        paired: Int,
        server: Int,
        ownerAuth: Int
    ) throws -> RadarBLEDeviceStatus {
        let json = """
        {
          "v": 2,
          "name": "CapsuleRadar-F2A0",
          "ble": 1,
          "paired": \(paired),
          "wifi": "connected",
          "rssi": -40,
          "ip": "192.0.2.1",
          "server": \(server),
          "loc": 0,
          "last": "\(last)",
          "owner_auth_required": 1,
          "owner_auth": \(ownerAuth)
        }
        """
        return try JSONDecoder().decode(RadarBLEDeviceStatus.self, from: Data(json.utf8))
    }

    private func decodeRoomState(
        serverTime: Int,
        ageMS: Int,
        locationAgeMS: Int,
        latitudeE7: Int,
        speaking: Bool,
        voiceSequence: Int
    ) throws -> RelayRoomStateSnapshot {
        let json = """
        {
          "room": "KAME-TEST",
          "server_time": \(serverTime),
          "max_members": 7,
          "voice_floor": {
            "active": \(speaking),
            "speaker_group_id": \(speaking ? "\"remote\"" : "null"),
            "speaker_peer_id": \(speaking ? "\"app-remote\"" : "null"),
            "expires_in_ms": \(speaking ? 1200 : 0)
          },
          "members": [
            {
              "role": "app",
              "member_id": "remote",
              "peer_id": "app-remote",
              "name": "远端成员",
              "online": true,
              "age_ms": \(ageMS),
              "last_seen_ms": \(ageMS),
              "last_type": "heartbeat",
              "protocol_version": 4,
              "voice_status": {
                "ptt": \(speaking),
                "vad": false,
                "speaker": \(speaking),
                "sequence": \(voiceSequence),
                "rms": \(voiceSequence * 10),
                "peak": \(voiceSequence * 20)
              },
              "location": {
                "lat_e7": \(latitudeE7),
                "lon_e7": 121400000,
                "h_acc_cm": 350,
                "speed_cms": 20,
                "course_deg100": 9000,
                "unix_time": 1700000000,
                "sequence": \(voiceSequence)
              },
              "location_paused": false,
              "location_stale": false,
              "location_age_ms": \(locationAgeMS),
              "app_online": true,
              "device_online": false
            }
          ]
        }
        """
        return try JSONDecoder().decode(RelayRoomStateSnapshot.self, from: Data(json.utf8))
    }
}
