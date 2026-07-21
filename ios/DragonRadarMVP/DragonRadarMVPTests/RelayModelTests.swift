import XCTest
@testable import DragonRadarMVP

final class RelayModelTests: XCTestCase {
    @MainActor
    func testLegacyPlaceholderUsernameIsNormalized() {
        XCTAssertEqual(
            SessionStore.normalizedDisplayName("胶囊用户"),
            "Capsule Radar 用户"
        )
        XCTAssertEqual(
            SessionStore.normalizedDisplayName("apple:internal-identifier"),
            "Capsule Radar 用户"
        )
        XCTAssertEqual(SessionStore.normalizedDisplayName("隼人"), "隼人")
    }

    func testRoomStateDecodesVoiceFloorAndVoiceStatus() throws {
        let json = """
        {
          "type": "room_state",
          "room": "CAPS-UNIT",
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

        XCTAssertEqual(snapshot.room, "CAPS-UNIT")
        XCTAssertEqual(snapshot.maxMembers, 7)
        XCTAssertEqual(snapshot.voiceFloor?.speakerGroupID, "remote")
        XCTAssertEqual(snapshot.voiceFloor?.speakerPeerID, "remote-app")
        XCTAssertEqual(snapshot.members[1].voiceStatus?.lostFrames, 2)
        XCTAssertEqual(snapshot.members[1].voiceStatus?.receivedSequence, 40)
        XCTAssertEqual(snapshot.members[1].location?.sequence, 12)
        XCTAssertEqual(snapshot.members[1].locationStale, true)
        XCTAssertEqual(snapshot.members[1].locationAgeMS, 45_000)
    }

    func testBLEProjectionKeepsRemoteRadarFromSameAccountAndFitsOneWritePerPacket() throws {
        let json = """
        {
          "type": "room_state",
          "room": "KAME-UNIT",
          "server_time": 1784700000,
          "max_members": 7,
          "voice_floor": {
            "active": true,
            "speaker_group_id": "remote-group-abcdef",
            "speaker_peer_id": "app-remote-group-abcdef",
            "expires_in_ms": 900
          },
          "members": [
            {
              "role": "app", "member_id": "local-group-abcdef",
              "peer_id": "app-local-group-abcdef", "name": "隼人 A",
              "online": true, "app_online": true, "age_ms": 0,
              "last_seen_ms": 10, "last_type": "app_location",
              "moderation_ref": "same-account",
              "location": {"lat_e7": 312304160, "lon_e7": 1214737010, "h_acc_cm": 500}
            },
            {
              "role": "app", "member_id": "remote-group-abcdef",
              "peer_id": "app-remote-group-abcdef", "name": "远端雷达 B",
              "online": true, "app_online": true, "age_ms": 0,
              "last_seen_ms": 20, "last_type": "app_location",
              "moderation_ref": "same-account",
              "location_stale": false, "location_age_ms": 120,
              "voice_status": {"ptt": true, "speaker": true},
              "location": {
                "lat_e7": 312304260, "lon_e7": 1214737110,
                "h_acc_cm": 800, "speed_cms": 35,
                "course_deg100": 9000, "unix_time": 1784700000
              }
            }
          ]
        }
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(RelayRoomStateSnapshot.self, from: json)

        let packets = RadarRoomStateBLEPacketEncoder.packets(
            snapshot: snapshot,
            localAppPeerID: "app-local-group-abcdef",
            sequence: 42
        )

        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(Array(packets[0].prefix(5)), [1, 1, 42, 0, 1])
        XCTAssertEqual(Array(packets[1].prefix(5)), [1, 2, 42, 0, 0b0000_0011])
        XCTAssertEqual(String(data: packets[1][5..<17], encoding: .utf8), "remote-group")
        XCTAssertEqual(Array(packets[2]), [1, 3, 42, 0, 1])
        XCTAssertTrue(packets.allSatisfy { $0.count <= 60 })
    }

    @MainActor
    func testRoomStoreProjectsDistanceBearingAndSpeakingState() {
        let store = RoomsStore()
        let snapshot = RelayRoomStateSnapshot(
            room: "CAPS-UNIT",
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

        store.applyRelayRoomState(
            snapshot,
            localAppPeerID: "local-app",
            localDisplayName: "隼人"
        )

        XCTAssertEqual(store.inviteCode, "CAPS-UNIT")
        XCTAssertEqual(store.roomCapacity, 7)
        XCTAssertEqual(store.roomStatus, "Remote 说话中")
        XCTAssertEqual(store.members.count, 2)

        let local = store.members[0]
        XCTAssertEqual(local.name, "隼人")
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
            room: "CAPS-STALE",
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

    func testRadarReminderDecodesRealtimePayload() throws {
        let payload: [AnyHashable: Any] = [
            "type": "radar_reminder",
            "event_id": "rr_realtime_1",
            "room": "CAPS-1001",
            "sender_name": "成员甲",
            "action": "open_radar",
            "server_time": 1_784_000_000
        ]

        let reminder = try XCTUnwrap(RadarReminderEvent(payload: payload))

        XCTAssertEqual(reminder.eventID, "rr_realtime_1")
        XCTAssertEqual(reminder.roomCode, "CAPS-1001")
        XCTAssertEqual(reminder.senderName, "成员甲")
        XCTAssertEqual(reminder.action, "open_radar")
        XCTAssertEqual(reminder.message, "成员甲提醒你查看雷达")
    }

    func testRadarReminderDecodesAPNsNestedPayload() throws {
        let payload: [AnyHashable: Any] = [
            "type": "radar_reminder",
            "room_code": "CAPS-2002",
            "data": [
                "event_id": "rr_push_1",
                "sender_name": "成员乙",
                "action": "open_radar",
                "server_time": 1_784_000_001
            ]
        ]

        let reminder = try XCTUnwrap(RadarReminderEvent(payload: payload))

        XCTAssertEqual(reminder.eventID, "rr_push_1")
        XCTAssertEqual(reminder.roomCode, "CAPS-2002")
        XCTAssertEqual(reminder.senderName, "成员乙")
        XCTAssertEqual(reminder.serverTime, 1_784_000_001)
    }

    func testRadarReminderRejectsMalformedOrWrongTypePayload() {
        XCTAssertNil(RadarReminderEvent(payload: ["type": "room_invite", "event_id": "rr_1"]))
        XCTAssertNil(RadarReminderEvent(payload: ["type": "radar_reminder"]))
    }

    func testRadarReminderRateLimitUsesStableUserFacingText() {
        let error = RoomRepositoryError.rateLimited(
            code: "radar_reminder_rate_limited",
            detail: nil,
            retryAfter: 17
        )

        XCTAssertEqual(error.errorDescription, "提醒发送太频繁，请稍后再试。")
        XCTAssertEqual(error.retryAfterSeconds, 17)
    }

    @MainActor
    func testNotificationCenterDeduplicatesReminderAndRoutesOpenedNotification() async throws {
        let center = NotificationPermissionCenter()
        let payload: [AnyHashable: Any] = [
            "type": "radar_reminder",
            "event_id": "rr_center_1",
            "room_code": "CAPS-3003",
            "sender_name": "成员丙",
            "action": "open_radar",
            "server_time": 1_784_000_002
        ]

        NotificationCenter.default.post(name: .dragonRadarReminderReceived, object: payload)
        await Task.yield()
        XCTAssertEqual(center.latestRadarReminder?.senderName, "成员丙")
        XCTAssertTrue(center.radarNavigationRequestID.isEmpty)

        let duplicatePayload: [AnyHashable: Any] = [
            "type": "radar_reminder",
            "event_id": "rr_center_1",
            "room_code": "CAPS-3003",
            "sender_name": "不应覆盖",
            "action": "open_radar"
        ]
        NotificationCenter.default.post(name: .dragonRadarReminderReceived, object: duplicatePayload)
        await Task.yield()
        XCTAssertEqual(center.latestRadarReminder?.senderName, "成员丙")

        NotificationCenter.default.post(
            name: .dragonRadarReminderReceived,
            object: payload,
            userInfo: ["opened": true]
        )
        await Task.yield()
        XCTAssertEqual(center.radarNavigationRequestID, "rr_center_1")

        center.consumeRadarNavigationRequest()
        center.dismissRadarReminder(eventID: "rr_center_1")
        XCTAssertTrue(center.radarNavigationRequestID.isEmpty)
        XCTAssertNil(center.latestRadarReminder)

        NotificationCenter.default.post(name: .dragonRadarReminderReceived, object: payload)
        await Task.yield()
        NotificationCenter.default.post(name: .dragonRadarAccountSignedOut, object: "")
        await Task.yield()
        XCTAssertNil(center.latestRadarReminder)
        XCTAssertTrue(center.radarNavigationRequestID.isEmpty)

        NotificationCenter.default.post(name: .dragonRadarReminderReceived, object: payload)
        await Task.yield()
        XCTAssertEqual(center.latestRadarReminder?.eventID, "rr_center_1")
    }

    @MainActor
    func testReviewExperienceUsesLocalScenarioAndRestoresServerRoom() async {
        let state = AppState(resetPersistentState: true)
        state.sessionStore.apply(
            AuthSession(
                userID: "review-user",
                displayName: "审核员",
                appleUserID: "review-apple-user",
                accessToken: "review-access-token",
                refreshToken: "review-refresh-token",
                expiresAt: Date(timeIntervalSinceNow: 3_600)
            )
        )
        state.roomsStore.applyServerRoom(
            ServerRoom(
                roomID: "server-room-id",
                roomCode: "REAL-1001",
                name: "真实服务器房间",
                maxMembers: 7,
                memberCount: 1
            )
        )

        state.startReviewExperience()

        XCTAssertTrue(state.isReviewExperienceActive)
        XCTAssertEqual(state.selectedTab, .radar)
        XCTAssertEqual(state.displayRoomCode, "LOCAL-DEMO")
        XCTAssertEqual(state.inviteCode, "REAL-1001", "演示房间不得覆盖持久化的真实房间码")
        XCTAssertEqual(state.activeRoomName, "本地雷达体验房")
        XCTAssertEqual(state.members.count, 4)
        XCTAssertEqual(state.members.filter(\.isOnline).count, 3)
        XCTAssertEqual(Set(state.members.map(\.distance)).count, 4)
        XCTAssertEqual(Set(state.members.map(\.bearing)).count, 4)
        XCTAssertTrue(state.activeSpeakers.isEmpty)

        let reminder = await state.sendRadarReminderAndWait(roomCode: state.displayRoomCode)
        XCTAssertFalse(reminder.succeeded)
        XCTAssertEqual(reminder.message, "本地演示不会发送提醒或调用服务器")

        state.stopReviewExperience()

        XCTAssertFalse(state.isReviewExperienceActive)
        XCTAssertEqual(state.selectedTab, .rooms)
        XCTAssertEqual(state.displayRoomCode, "REAL-1001")
        XCTAssertEqual(state.activeRoomName, "真实服务器房间")

        state.roomsStore.clearRooms()
        state.sessionStore.signOut()
    }

    func testRadarBlipsUseMemberBearingAndDistance() throws {
        let north = makeRadarMember(name: "北侧", distance: "100m", bearing: "北 0°")
        let east = makeRadarMember(name: "东侧", distance: "200m", bearing: "东 90°")

        let blips = RadarBlipViewModel.make(from: [north, east])
        let northPoint = try XCTUnwrap(blips.first { $0.id == north.id }).point(in: CGSize(width: 200, height: 200))
        let eastPoint = try XCTUnwrap(blips.first { $0.id == east.id }).point(in: CGSize(width: 200, height: 200))

        XCTAssertEqual(blips.count, 2)
        XCTAssertEqual(RadarBlipViewModel.rangeText(for: blips), "250m")
        XCTAssertEqual(northPoint.x, 100, accuracy: 0.01)
        XCTAssertLessThan(northPoint.y, 100)
        XCTAssertGreaterThan(eastPoint.x, 100)
        XCTAssertEqual(eastPoint.y, 100, accuracy: 0.01)
    }

    func testRadarBlipsSkipMembersWithoutUsableLocation() {
        let waiting = makeRadarMember(name: "等待", distance: "等待定位", bearing: "手机")
        let paused = makeRadarMember(name: "暂停", distance: "定位已暂停", bearing: "隐私")

        XCTAssertTrue(RadarBlipViewModel.make(from: [waiting, paused]).isEmpty)
    }

    func testRadarKeepsAnotherOnlineRadarFromSameAccountVisible() {
        var local = makeRadarMember(name: "本机", distance: "0m", bearing: "本机")
        local.isLocal = true
        local.isCurrentUser = true
        var sameAccountRadar = makeRadarMember(name: "另一台雷达", distance: "5m", bearing: "东 90°")
        sameAccountRadar.isCurrentUser = true
        var offlineRadar = makeRadarMember(name: "离线雷达", distance: "5m", bearing: "西 270°")
        offlineRadar.isOnline = false

        let visible = RadarOverviewView.remoteMembers(
            from: [local, sameAccountRadar, offlineRadar]
        )

        XCTAssertEqual(visible.map(\.name), ["另一台雷达"])
    }

    private func makeRadarMember(name: String, distance: String, bearing: String) -> RoomMember {
        RoomMember(
            id: UUID(),
            name: name,
            distance: distance,
            bearing: bearing,
            accuracy: "±8m",
            locationPaused: false,
            isOnline: true,
            isSpeaking: false,
            isMuted: false,
            voiceStatusText: "",
            voiceCountdownText: "",
            voiceHealthText: "",
            deviceBattery: -1,
            wifiRSSI: -999,
            firmware: "",
            lastUpdate: "刚刚",
            role: "app"
        )
    }
}
