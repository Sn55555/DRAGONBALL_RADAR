import SwiftUI

struct RadarOverviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime

    var body: some View {
        @Bindable var state = appState
        let members = appState.members
        let activeSpeakers = appState.activeSpeakers
        let remoteMembers = Array(members.dropFirst()).filter(\.isOnline)
        let targetSnapshot = RadarTargetSnapshot(
            remoteTargetCount: remoteMembers.count,
            roomLatency: appState.roomLatency,
            activeSpeakerCount: activeSpeakers.count,
            voiceQuality: appState.voiceQuality,
            blips: RadarBlipViewModel.make(from: remoteMembers)
        )
        let voiceSnapshot = VoicePanelSnapshot(
            voiceQuality: appState.voiceQuality,
            activeSpeakers: activeSpeakers
        )
        let deviceSnapshot = DeviceStripSnapshot(device: appState.activeDevice)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                RadarTargetPanel(snapshot: targetSnapshot)
                    .overlay(alignment: .topTrailing) {
                        BulmaPeekDecoration()
                    }

                ActiveVoicePanel(snapshot: voiceSnapshot)

                LazyVStack(spacing: 12) {
                    ForEach(members) { member in
                        Button {
                            state.selectedMember = member
                        } label: {
                            MemberRow(member: member)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .mangaCard("实时目标")

                DeviceStrip(snapshot: deviceSnapshot)
            }
            .padding(18)
            .padding(.bottom, 18)
        }
        .background(MangaBackground())
        .navigationTitle("雷达")
        .navigationDestination(item: $state.selectedMember) { member in
            MemberDetailView(member: member)
        }
    }
}

private struct BulmaPeekDecoration: View {
    var body: some View {
        Image("BulmaPeekCutout")
            .resizable()
            .scaledToFit()
            .frame(width: 132)
            .offset(x: -46, y: -118)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct VoicePanelSnapshot: Hashable {
    var voiceQuality: String
    var activeSpeakers: [RoomMember]
}

struct ActiveVoicePanel: View {
    var snapshot: VoicePanelSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("雷达语音状态", systemImage: "waveform")
                    .font(.headline.weight(.black))
                Spacer()
                StatusChip(text: snapshot.voiceQuality, filled: true)
            }

            HStack(spacing: 10) {
                if snapshot.activeSpeakers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("等待雷达麦克风")
                            .font(.headline.weight(.black))
                        Text("iOS 只查看语音状态，不采集或播放语音。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MangaTheme.subtle)
                    }
                } else {
                    ForEach(snapshot.activeSpeakers.prefix(3)) { member in
                        VStack(spacing: 7) {
                            Text(String(member.name.prefix(1)))
                                .font(.title3.weight(.black))
                                .frame(width: 44, height: 44)
                                .background(MangaTheme.chip, in: Circle())
                                .foregroundStyle(MangaTheme.ink)
                                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 2))
                            Text(member.name)
                                .font(.caption.weight(.bold))
                            if !member.voiceCountdownText.isEmpty {
                                Text(member.voiceCountdownText)
                                    .font(.caption2.monospacedDigit().weight(.black))
                            }
                        }
                    }
                    if snapshot.activeSpeakers.count > 3 {
                        StatusChip(text: "+\(snapshot.activeSpeakers.count - 3)")
                    }
                }

                Spacer()
                StatusChip(text: "\(snapshot.activeSpeakers.count) 路", filled: snapshot.activeSpeakers.count > 0)
            }
        }
        .mangaCard("雷达语音")
    }
}

struct DeviceStripSnapshot: Hashable {
    var deviceName: String
    var networkText: String
    var stateText: String

    init(device: RadarDevice?) {
        deviceName = device?.name ?? "未绑定雷达"
        networkText = "\(device?.wifiName ?? "无网络") · \(device?.relayLatency ?? 0)ms"
        stateText = device?.state.rawValue ?? "离线"
    }
}

struct DeviceStrip: View {
    var snapshot: DeviceStripSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title2.weight(.black))
                .frame(width: 44, height: 44)
                .background(MangaTheme.chip, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(MangaTheme.ink)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.deviceName)
                    .font(.headline.weight(.black))
                Text(snapshot.networkText)
                    .font(.caption)
                    .foregroundStyle(MangaTheme.subtle)
            }

            Spacer()
            StatusChip(text: snapshot.stateText, filled: true)
        }
        .mangaCard("本机雷达")
    }
}

struct RadarTargetSnapshot: Hashable {
    var remoteTargetCount: Int
    var roomLatency: Int
    var activeSpeakerCount: Int
    var voiceQuality: String
    var blips: [RadarBlipViewModel]
}

struct RadarBlipViewModel: Identifiable, Hashable {
    let id: RoomMember.ID
    var member: RoomMember
    private var offsetX: CGFloat
    private var offsetY: CGFloat

    func point(in size: CGSize) -> CGPoint {
        let side = min(size.width, size.height)
        return CGPoint(
            x: size.width / 2 + side * offsetX,
            y: size.height / 2 + side * offsetY
        )
    }

    static func make(from members: [RoomMember]) -> [RadarBlipViewModel] {
        members.prefix(layouts.count).enumerated().map { index, member in
            let layout = layouts[index]
            return RadarBlipViewModel(
                id: member.id,
                member: member,
                offsetX: layout.offsetX,
                offsetY: layout.offsetY
            )
        }
    }

    private struct Layout {
        var offsetX: CGFloat
        var offsetY: CGFloat
    }

    private static let layouts: [Layout] = {
        let angles: [Double] = [-52, 34, 126, 205, 278, 82]
        let multipliers: [CGFloat] = [0.58, 0.76, 0.92, 0.68, 0.84, 0.48]
        return zip(angles, multipliers).map { angle, multiplier in
            let radians = angle * .pi / 180
            let radius = 0.34 * multiplier
            return Layout(
                offsetX: cos(radians) * radius,
                offsetY: sin(radians) * radius
            )
        }
    }()
}

struct RadarTargetPanel: View {
    var snapshot: RadarTargetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("雷达监视中")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(MangaTheme.ink)
                    Text("目标距离 · 方位同步 · 多人语音")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    StatusChip(text: "\(snapshot.remoteTargetCount) 个目标", filled: snapshot.remoteTargetCount > 0)
                    StatusChip(text: snapshot.voiceQuality)
                }
            }

            HStack(spacing: 10) {
                MetricTile(title: "目标", value: "\(snapshot.remoteTargetCount)", symbol: "scope")
                MetricTile(title: "延迟", value: "\(snapshot.roomLatency)ms", symbol: "bolt.horizontal")
                MetricTile(title: "说话", value: "\(snapshot.activeSpeakerCount)", symbol: "waveform")
            }

            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .stroke(MangaTheme.ink.opacity(index == 3 ? 0.95 : 0.35), lineWidth: index == 3 ? 2.2 : 1.2)
                        .padding(CGFloat(index) * 25)
                }

                CrosshairLine(axis: .horizontal)
                CrosshairLine(axis: .vertical)

                Circle()
                    .fill(MangaTheme.ink)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(MangaTheme.panelLight, lineWidth: 2))

                GeometryReader { proxy in
                    ForEach(snapshot.blips) { blip in
                        RadarBlip(member: blip.member)
                            .position(blip.point(in: proxy.size))
                    }
                }
            }
            .frame(height: 250)
            .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(MangaTheme.ink, lineWidth: 2))
            .accessibilityIdentifier("radar.live.manga.screen")

            Text("这里展示成员相对我的实时方向、距离和说话状态；邀请、创建和成员槽位放到房间页。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MangaTheme.subtle)
        }
        .mangaCard("实时雷达")
    }
}

struct CrosshairLine: View {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis

    var body: some View {
        Rectangle()
            .fill(MangaTheme.ink.opacity(0.28))
            .frame(
                width: axis == .horizontal ? nil : 1,
                height: axis == .horizontal ? 1 : nil
            )
            .padding(axis == .horizontal ? .horizontal : .vertical, 24)
    }
}

struct RadarBlip: View {
    var member: RoomMember

    var body: some View {
        VStack(spacing: 3) {
            Text(String(member.name.prefix(1)))
                .font(.caption.weight(.black))
                .frame(width: 28, height: 28)
                .background(member.isSpeaking ? MangaTheme.chip : MangaTheme.panelLight, in: Circle())
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 2))
            Text(member.distance)
                .font(.caption2.monospacedDigit().weight(.black))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(MangaTheme.panelLight, in: Capsule())
                .overlay(Capsule().stroke(MangaTheme.ink.opacity(0.65), lineWidth: 1))
        }
    }
}

struct RuntimeRow: View {
    var title: String
    var phase: RuntimePhase
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusChip(text: phase.rawValue, filled: phase == .ready)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.black))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MangaTheme.subtle)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
            Text(value)
                .font(.title2.weight(.black))
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(MangaTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MangaTheme.ink, lineWidth: 1.8))
    }
}

struct MemberRow: View {
    var member: RoomMember

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Text(String(member.name.prefix(1)))
                    .font(.headline.weight(.black))
                    .frame(width: 42, height: 42)
                    .background(member.isOnline ? MangaTheme.panelLight : MangaTheme.chip, in: Circle())
                    .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 2))
                if member.isSpeaking {
                    Image(systemName: "waveform")
                        .font(.caption2.weight(.black))
                        .padding(4)
                        .background(MangaTheme.chip, in: Circle())
                        .foregroundStyle(MangaTheme.ink)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(member.name)
                        .font(.headline.weight(.black))
                    if member.isMuted {
                        Image(systemName: "mic.slash.fill")
                            .font(.caption)
                    }
                }
                Text("\(member.distance) · \(member.bearing) · \(member.accuracy)")
                    .font(.caption)
                    .foregroundStyle(MangaTheme.subtle)
                Text(member.voiceStatusText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                StatusChip(text: member.isOnline ? "在线" : "离线", filled: member.isOnline)
                Text(member.voiceCountdownText.isEmpty ? member.lastUpdate : member.voiceCountdownText)
                    .font(.caption2)
                    .foregroundStyle(MangaTheme.subtle)
            }
        }
        .padding(10)
        .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MangaTheme.ink.opacity(0.7), lineWidth: 1.4))
    }
}

struct MemberDetailView: View {
    @Environment(AppState.self) private var appState
    var member: RoomMember

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ToyBezel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(member.name)
                                .font(.largeTitle.weight(.black))
                            Spacer()
                            StatusChip(text: member.isOnline ? "成员在线" : "成员离线", filled: member.isOnline)
                        }
                        Text(member.distance)
                            .font(.system(size: 48, weight: .black, design: .rounded))
                        Text("\(member.bearing) · \(member.accuracy) · \(member.lastUpdate)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MangaTheme.subtle)
                    }
                }

                VStack(spacing: 10) {
                    InfoRow(label: "雷达电量", value: member.deviceBattery >= 0 ? "\(member.deviceBattery)%" : "未知")
                    InfoRow(label: "Wi-Fi RSSI", value: member.wifiRSSI > -200 ? "\(member.wifiRSSI) dBm" : "未知")
                    InfoRow(label: "固件版本", value: member.firmware)
                    InfoRow(label: "语音", value: member.voiceStatusText)
                    InfoRow(label: "发言权", value: member.voiceCountdownText.isEmpty ? "未占用" : member.voiceCountdownText)
                    InfoRow(label: "音频健康", value: member.voiceHealthText)
                    InfoRow(label: "静音", value: member.isMuted ? "是" : "否")
                }
                .mangaCard("成员状态")

                Text("语音由雷达处理，iOS 只显示当前状态。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            .padding(18)
        }
        .background(MangaBackground())
        .navigationTitle("成员详情")
    }
}

struct InfoRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.bold))
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.black))
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MangaTheme.ink.opacity(0.12))
                .frame(height: 1)
        }
    }
}
