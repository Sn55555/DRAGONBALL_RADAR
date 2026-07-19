import Foundation
import SwiftUI

struct RadarOverviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(RadarRuntime.self) private var radarRuntime

    var body: some View {
        @Bindable var state = appState
        let members = appState.members.filter { $0.role == "app" || $0.isLocal }
        let remoteMembers = members.filter { !$0.isCurrentUser && !$0.isLocal && $0.isOnline }
        let blips = RadarBlipViewModel.make(from: remoteMembers)
        let targetSnapshot = RadarTargetSnapshot(
            remoteTargetCount: blips.count,
            roomLatency: appState.roomLatency,
            rangeText: RadarBlipViewModel.rangeText(for: blips),
            blips: blips
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if appState.isReviewExperienceActive {
                    ReviewExperienceBanner {
                        appState.stopReviewExperience()
                    }
                    ReviewExperienceTargetPicker(members: remoteMembers) { member in
                        state.selectedMember = member
                    }
                }

                RadarTargetPanel(snapshot: targetSnapshot)

                LazyVStack(spacing: 12) {
                    ForEach(members) { member in
                        Button {
                            state.selectedMember = member
                        } label: {
                            MemberRow(member: member)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("radar.member.\(member.id.uuidString)")
                    }
                }
                .mangaCard("实时目标")
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

struct RadarTargetSnapshot: Hashable {
    var remoteTargetCount: Int
    var roomLatency: Int
    var rangeText: String
    var blips: [RadarBlipViewModel]
}

struct RadarBlipViewModel: Identifiable, Hashable {
    let id: RoomMember.ID
    var member: RoomMember
    var distanceMeters: Double
    var bearingDegrees: Double
    var rangeMeters: Double
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
        let locatedMembers = members.prefix(6).compactMap { member -> (RoomMember, Double, Double)? in
            guard
                let distance = distanceMeters(from: member.distance),
                let bearing = bearingDegrees(from: member.bearing)
            else { return nil }
            return (member, distance, bearing)
        }
        let range = radarRange(for: locatedMembers.map { $0.1 })
        return locatedMembers.map { member, distance, bearing in
            let radians = bearing * .pi / 180
            let normalizedRadius = min(1, max(0.08, distance / range)) * 0.42
            return RadarBlipViewModel(
                id: member.id,
                member: member,
                distanceMeters: distance,
                bearingDegrees: bearing,
                rangeMeters: range,
                offsetX: CGFloat(sin(radians) * normalizedRadius),
                offsetY: CGFloat(-cos(radians) * normalizedRadius)
            )
        }
    }

    static func rangeText(for blips: [RadarBlipViewModel]) -> String {
        guard let range = blips.first?.rangeMeters else { return "等待定位" }
        if range >= 1_000 {
            return range.truncatingRemainder(dividingBy: 1_000) == 0
                ? "\(Int(range / 1_000))km"
                : String(format: "%.1fkm", range / 1_000)
        }
        return "\(Int(range))m"
    }

    private static func distanceMeters(from text: String) -> Double? {
        let value = text.lowercased().replacingOccurrences(of: " ", with: "")
        if value.hasSuffix("km"), let number = Double(value.dropLast(2)) {
            return max(0, number * 1_000)
        }
        if value.hasSuffix("m"), let number = Double(value.dropLast()) {
            return max(0, number)
        }
        return nil
    }

    private static func bearingDegrees(from text: String) -> Double? {
        guard let prefix = text.split(separator: "°", maxSplits: 1).first else { return nil }
        guard let token = prefix.split(whereSeparator: \.isWhitespace).last,
              let value = Double(token) else { return nil }
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    private static func radarRange(for distances: [Double]) -> Double {
        let maximum = distances.max() ?? 0
        let ranges: [Double] = [25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000]
        return ranges.first(where: { $0 >= maximum }) ?? max(100_000, ceil(maximum / 100_000) * 100_000)
    }
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
                    Text("成员方向 · 距离同步 · 私人房间")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MangaTheme.subtle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    StatusChip(text: "\(snapshot.remoteTargetCount) 个目标", filled: snapshot.remoteTargetCount > 0)
                    StatusChip(text: "量程 \(snapshot.rangeText)")
                }
            }

            HStack(spacing: 10) {
                MetricTile(title: "目标", value: "\(snapshot.remoteTargetCount)", symbol: "scope")
                MetricTile(title: "延迟", value: "\(snapshot.roomLatency)ms", symbol: "bolt.horizontal")
                MetricTile(title: "量程", value: snapshot.rangeText, symbol: "ruler")
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

            Text("0° 朝上；目标按成员相对方位与距离绘制。结果受 GPS 精度和网络时延影响，不用于安全导航。")
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
                .background(blipFill, in: Circle())
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 2))
            Text(member.distance)
                .font(.caption2.monospacedDigit().weight(.black))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(MangaTheme.ink.opacity(0.65), lineWidth: 1))
        }
    }

    private var blipFill: Color {
        #if APP_ONLY
        MangaTheme.panelLight
        #else
        member.isSpeaking ? MangaTheme.chip : MangaTheme.panelLight
        #endif
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
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(member.name)
                        .font(.headline.weight(.black))
                }
                Text("\(member.distance) · \(member.bearing) · \(member.accuracy)")
                    .font(.caption)
                    .foregroundStyle(MangaTheme.subtle)
                Text(member.locationPaused ? "位置共享已暂停" : member.lastUpdate)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(MangaTheme.subtle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                StatusChip(text: member.isOnline ? "在线" : "离线", filled: member.isOnline)
                Text(member.accuracy)
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
                    InfoRow(label: "距离", value: member.distance)
                    InfoRow(label: "方位", value: member.bearing)
                    InfoRow(label: "定位精度", value: member.accuracy)
                    InfoRow(label: "位置共享", value: member.locationPaused ? "已暂停" : "开启")
                    InfoRow(label: "在线状态", value: member.isOnline ? "在线" : "离线")
                    InfoRow(label: "最近更新", value: member.lastUpdate)
                }
                .mangaCard("成员状态")

                Text("距离和方位来自房间成员授权共享的 iPhone 位置，仅用于成员协同与娱乐体验。")
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
