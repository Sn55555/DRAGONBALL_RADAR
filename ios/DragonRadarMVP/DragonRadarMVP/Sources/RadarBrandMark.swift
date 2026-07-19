import SwiftUI

/// Original, code-rendered radar mark with no third-party character or product imagery.
struct RadarBrandMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(MangaTheme.panelLight)

            Circle()
                .stroke(MangaTheme.ink, lineWidth: 3)

            Circle()
                .stroke(MangaTheme.ink.opacity(0.38), lineWidth: 2)
                .padding(13)

            Circle()
                .stroke(MangaTheme.ink.opacity(0.20), lineWidth: 2)
                .padding(28)

            RadarSweepLine()
                .stroke(MangaTheme.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .padding(8)

            Circle()
                .fill(MangaTheme.ink)
                .frame(width: 9, height: 9)

            Circle()
                .fill(MangaTheme.panelLight)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 3))
                .offset(x: 30, y: -27)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("雷达扫描")
    }
}

private struct RadarSweepLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.82, y: rect.maxY * 0.20))
        return path
    }
}

struct RadarBrandHeroPanel: View {
    var body: some View {
        VStack(spacing: 14) {
            RadarBrandMark()
                .frame(width: 128, height: 128)

            VStack(spacing: 5) {
                Text("Capsule Radar")
                    .font(.title2.weight(.black))
                Text("与房间成员共享相对方位和距离")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MangaTheme.subtle)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(MangaTheme.panelLight, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(MangaTheme.ink, lineWidth: 2.4))
        .shadow(color: .black.opacity(0.12), radius: 0, x: 3, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("login.gate.brand.panel")
    }
}
