import SwiftUI

struct ReviewExperience: Equatable {
    static let roomID = UUID(uuidString: "A11E0000-0000-4000-8000-000000000001")!
    static let localMemberID = UUID(uuidString: "A11E0000-0000-4000-8000-000000000101")!
    static let eastMemberID = UUID(uuidString: "A11E0000-0000-4000-8000-000000000102")!
    static let southwestMemberID = UUID(uuidString: "A11E0000-0000-4000-8000-000000000103")!
    static let offlineMemberID = UUID(uuidString: "A11E0000-0000-4000-8000-000000000104")!

    private(set) var isActive = false
    private(set) var room = Self.makeRoom(displayName: "演示用户")

    mutating func start(displayName: String) {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        room = Self.makeRoom(displayName: cleanName.isEmpty ? "演示用户" : cleanName)
        isActive = true
    }

    mutating func stop() {
        isActive = false
    }

    private static func makeRoom(displayName: String) -> RadarRoom {
        RadarRoom(
            id: roomID,
            name: "本地雷达体验房",
            inviteCode: "LOCAL-DEMO",
            capacity: 7,
            onlineGroups: 3,
            latency: 32,
            roomStatus: "定位演示",
            members: [
                makeMember(
                    id: localMemberID,
                    name: "\(displayName)（本机）",
                    distance: "本机",
                    bearing: "0°",
                    accuracy: "本地演示",
                    locationPaused: true,
                    isOnline: true,
                    lastUpdate: "刚刚",
                    isLocal: true,
                    isCurrentUser: true
                ),
                makeMember(
                    id: eastMemberID,
                    name: "东侧观察员",
                    distance: "120m",
                    bearing: "东北 68°",
                    accuracy: "演示精度 ±8m",
                    locationPaused: false,
                    isOnline: true,
                    lastUpdate: "刚刚"
                ),
                makeMember(
                    id: southwestMemberID,
                    name: "西南观察员",
                    distance: "860m",
                    bearing: "西南 224°",
                    accuracy: "演示精度 ±16m",
                    locationPaused: false,
                    isOnline: true,
                    lastUpdate: "3 秒前"
                ),
                makeMember(
                    id: offlineMemberID,
                    name: "离线观察员",
                    distance: "2.4km",
                    bearing: "西北 315°",
                    accuracy: "演示历史位置",
                    locationPaused: true,
                    isOnline: false,
                    lastUpdate: "12 分钟前"
                )
            ]
        )
    }

    private static func makeMember(
        id: UUID,
        name: String,
        distance: String,
        bearing: String,
        accuracy: String,
        locationPaused: Bool,
        isOnline: Bool,
        lastUpdate: String,
        isLocal: Bool = false,
        isCurrentUser: Bool = false
    ) -> RoomMember {
        #if APP_ONLY
        return RoomMember(
            id: id,
            name: name,
            distance: distance,
            bearing: bearing,
            accuracy: accuracy,
            locationPaused: locationPaused,
            isOnline: isOnline,
            lastUpdate: lastUpdate,
            isLocal: isLocal,
            isCurrentUser: isCurrentUser
        )
        #else
        return RoomMember(
            id: id,
            name: name,
            distance: distance,
            bearing: bearing,
            accuracy: accuracy,
            locationPaused: locationPaused,
            isOnline: isOnline,
            isSpeaking: false,
            isMuted: true,
            voiceStatusText: "",
            voiceCountdownText: "",
            voiceHealthText: "",
            deviceBattery: -1,
            wifiRSSI: -999,
            firmware: "",
            lastUpdate: lastUpdate,
            isLocal: isLocal,
            isCurrentUser: isCurrentUser
        )
        #endif
    }
}

struct ReviewExperienceEntryCard: View {
    var startAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("本地雷达演示", systemImage: "sparkles.rectangle.stack")
                .font(.headline.weight(.black))
            Text("无需创建房间，可直接查看本地生成的多人雷达效果。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MangaTheme.subtle)
            Label("不上传真实位置 · 不调用服务器或发送通知", systemImage: "lock.shield.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(MangaTheme.ink)

            Button(action: startAction) {
                Label("体验雷达演示", systemImage: "scope")
            }
            .buttonStyle(InkButtonStyle())
            .accessibilityIdentifier("rooms.reviewExperience.start")
        }
        .padding(.top, 8)
    }
}

struct ReviewExperienceBanner: View {
    var stopAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本地雷达演示", systemImage: "checkmark.shield.fill")
                    .font(.headline.weight(.black))
                Spacer()
                StatusChip(text: "演示数据", filled: true)
            }
            Text("当前目标全部由本机生成；不会共享真实位置、访问服务器或发送提醒。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MangaTheme.subtle)
            Button("退出演示并恢复房间", action: stopAction)
                .buttonStyle(InkButtonStyle(filled: false))
                .accessibilityIdentifier("radar.reviewExperience.stop")
        }
        .mangaCard("本地演示")
        .accessibilityIdentifier("radar.reviewExperience.banner")
    }
}

struct ReviewExperienceTargetPicker: View {
    var members: [RoomMember]
    var selectAction: (RoomMember) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("切换演示目标")
                .font(.headline.weight(.black))
            Text("点击成员即可核对不同距离和方位。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MangaTheme.subtle)

            HStack(spacing: 10) {
                ForEach(members.prefix(2)) { member in
                    Button {
                        selectAction(member)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.name)
                                .font(.subheadline.weight(.black))
                            Text("\(member.distance) · \(member.bearing)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                    .accessibilityIdentifier("radar.reviewExperience.target.\(member.id.uuidString)")
                }
            }
        }
        .mangaCard("目标切换")
    }
}

struct ReviewExperienceSafetyNotice: View {
    var body: some View {
        Label("本地演示不上传位置、不访问服务器，也不会发送提醒。", systemImage: "lock.shield.fill")
            .font(.caption.weight(.black))
            .foregroundStyle(MangaTheme.ink)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MangaTheme.ink, lineWidth: 1.4))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("本地演示不上传位置、不访问服务器，也不会发送提醒。")
            .accessibilityIdentifier("rooms.reviewExperience.safety")
    }
}
