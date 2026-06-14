import XCTest
@testable import DragonRadarMVP

final class RelayModelTests: XCTestCase {
    func testRoomStateDecodesVoiceFloorAndVoiceStatus() throws {
        let json = """
        {
          "type": "room_state",
          "room": "KAME-UNIT",
          "server_time": 1781172600,
          "max_members": 7,
          "voice_floor": {
            "active": true,
            "speaker_group_id": "remote",
            "speaker_peer_id": "remote-app",
            "expires_in_ms": 1200
          },
          "members": [
            {
              "role": "app",
              "member_id": "local",
              "peer_id": "local-app",
              "name": "Local",
              "online": true,
              "age_ms": 0,
              "last_seen_ms": 100,
              "last_type": "app_location",
              "protocol_version": 2,
              "location": {
                "lat_e7": 0,
                "lon_e7": 0,
                "h_acc_cm": 500,
                "sequence": 11
              }
            },
            {
              "role": "app",
              "member_id": "remote",
              "peer_id": "remote-app",
              "name": "Remote",
              "online": true,
              "age_ms": 0,
              "last_seen_ms": 250,
              "last_type": "voice_frame",
              "protocol_version": 2,
              "voice_status": {
                "ptt": true,
                "floor_granted": true,
                "speaker": true,
                "codec": "pcm16le",
                "sample_rate": 16000,
                "frame_ms": 20,
                "sequence": 41,
                "received_sequence": 40,
                "lost_frames": 2,
                "rms": 22,
                "peak": 88
              },
              "location": {
                "lat_e7": 0,
                "lon_e7": 269490,
                "h_acc_cm": 800,
                "sequence": 12
              },
              "location_stale": true,
              "location_age_ms": 45000
            }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(RelayRoomStateSnapshot.self, from: json)

        XCTAssertEqual(snapshot.room, "KAME-UNIT")
        XCTAssertEqual(snapshot.maxMembers, 7)
        XCTAssertEqual(snapshot.voiceFloor?.speakerGroupID, "remote")
        XCTAssertEqual(snapshot.voiceFloor?.speakerPeerID, "remote-app")
        XCTAssertEqual(snapshot.members[1].voiceStatus?.lostFrames, 2)
        XCTAssertEqual(snapshot.members[1].voiceStatus?.receivedSequence, 40)
        XCTAssertEqual(snapshot.members[1].location?.sequence, 12)
        XCTAssertEqual(snapshot.members[1].locationStale, true)
        XCTAssertEqual(snapshot.members[1].locationAgeMS, 45_000)
    }

    @MainActor
    func testRoomStoreProjectsDistanceBearingAndSpeakingState() {
        let store = RoomsStore()
        let snapshot = RelayRoomStateSnapshot(
            room: "KAME-UNIT",
            serverTime: 1_781_172_600,
            maxMembers: 7,
            voiceFloor: RelayVoiceFloorSnapshot(
                active: true,
                speakerGroupID: "remote",
                speakerPeerID: "remote-app",
                expiresInMS: 1_200
            ),
            members: [
                RelayRoomMemberSnapshot(
                    role: "app",
                    memberID: "local",
                    peerID: "local-app",
                    name: "Local",
                    online: true,
                    ageMS: 0,
                    lastSeenMS: 100,
                    lastType: "app_location",
                    protocolVersion: 2,
                    firmware: nil,
                    deviceStatus: nil,
                    voiceStatus: nil,
                    location: RelayLocationSnapshot(
                        latE7: 0,
                        lonE7: 0,
                        horizontalAccuracyCM: 500,
                        speedCMS: nil,
                        courseDeg100: nil,
                        unixTime: nil,
                        sequence: 11
                    ),
                    locationPaused: false,
                    appOnline: true,
                    deviceOnline: false
                ),
                RelayRoomMemberSnapshot(
                    role: "app",
                    memberID: "remote",
                    peerID: "remote-app",
                    name: "Remote",
                    online: true,
                    ageMS: 0,
                    lastSeenMS: 250,
                    lastType: "voice_frame",
                    protocolVersion: 2,
                    firmware: nil,
                    deviceStatus: nil,
                    voiceStatus: RelayVoiceStatusSnapshot(
                        muted: false,
                        ptt: true,
                        vad: true,
                        codec: "pcm16le",
                        sampleRate: 16_000,
                        frameMS: 20,
                        sequence: 41,
                        receivedSequence: 40,
                        lostFrames: 2,
                        rms: 22,
                        peak: 88,
                        floorGranted: true,
                        speaker: true
                    ),
                    location: RelayLocationSnapshot(
                        latE7: 0,
                        lonE7: 269_490,
                        horizontalAccuracyCM: 800,
                        speedCMS: nil,
                        courseDeg100: nil,
                        unixTime: nil,
                        sequence: 12
                    ),
                    locationPaused: false,
                    appOnline: true,
                    deviceOnline: false
                )
            ]
        )

        store.applyRelayRoomState(snapshot, localAppPeerID: "local-app")

        XCTAssertEqual(store.inviteCode, "KAME-UNIT")
        XCTAssertEqual(store.roomCapacity, 7)
        XCTAssertEqual(store.voiceQuality, "Remote 说话中")
        XCTAssertEqual(store.members.count, 2)

        let local = store.members[0]
        XCTAssertEqual(local.name, "隼人 iPhone")
        XCTAssertEqual(local.distance, "本机")
        XCTAssertEqual(local.bearing, "0°")

        let remote = store.members[1]
        XCTAssertEqual(remote.name, "Remote")
        XCTAssertEqual(remote.distance, "3.0km")
        XCTAssertEqual(remote.bearing, "东 90°")
        XCTAssertEqual(remote.accuracy, "±8m")
        XCTAssertTrue(remote.isSpeaking)
        XCTAssertEqual(remote.voiceStatusText, "正在说话")
        XCTAssertEqual(remote.voiceCountdownText, "剩余 1.2s")
        XCTAssertTrue(remote.voiceHealthText.contains("丢帧 2"))
    }

    @MainActor
    func testRoomStoreMarksStaleLocationInsteadOfProjectingFreshDistance() {
        let store = RoomsStore()
        let snapshot = RelayRoomStateSnapshot(
            room: "KAME-STALE",
            serverTime: 1_781_172_600,
            maxMembers: 7,
            voiceFloor: nil,
            members: [
                RelayRoomMemberSnapshot(
                    role: "app",
                    memberID: "local",
                    peerID: "local-app",
                    name: "Local",
                    online: true,
                    ageMS: 0,
                    lastSeenMS: 100,
                    lastType: "app_location",
                    protocolVersion: 2,
                    firmware: nil,
                    deviceStatus: nil,
                    voiceStatus: nil,
                    location: RelayLocationSnapshot(
                        latE7: 0,
                        lonE7: 0,
                        horizontalAccuracyCM: 500,
                        speedCMS: nil,
                        courseDeg100: nil,
                        unixTime: nil,
                        sequence: 11
                    ),
                    locationPaused: false,
                    locationStale: false,
                    locationAgeMS: 100,
                    appOnline: true,
                    deviceOnline: false
                ),
                RelayRoomMemberSnapshot(
                    role: "app",
                    memberID: "remote",
                    peerID: "remote-app",
                    name: "Remote",
                    online: true,
                    ageMS: 0,
                    lastSeenMS: 250,
                    lastType: "app_location",
                    protocolVersion: 2,
                    firmware: nil,
                    deviceStatus: nil,
                    voiceStatus: nil,
                    location: RelayLocationSnapshot(
                        latE7: 0,
                        lonE7: 269_490,
                        horizontalAccuracyCM: 800,
                        speedCMS: nil,
                        courseDeg100: nil,
                        unixTime: nil,
                        sequence: 12
                    ),
                    locationPaused: false,
                    locationStale: true,
                    locationAgeMS: 45_000,
                    appOnline: true,
                    deviceOnline: false
                )
            ]
        )

        store.applyRelayRoomState(snapshot, localAppPeerID: "local-app")

        XCTAssertEqual(store.locationHealth, "有成员定位过期")
        XCTAssertEqual(store.members[1].distance, "定位已过期")
        XCTAssertEqual(store.members[1].bearing, "旧坐标 45 秒前")
        XCTAssertEqual(store.members[1].accuracy, "过期")
    }

    func testRoomFullErrorUsesStableUserFacingText() {
        let error = RoomRepositoryError.server(code: "room_full", detail: nil)

        XCTAssertEqual(
            error.errorDescription,
            "房间已满，最多 7 组。请让房主移除空闲成员，或创建新房间。"
        )
    }
}
