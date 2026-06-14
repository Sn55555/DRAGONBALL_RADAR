import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum MangaTheme {
    static let ink = Color.black
    static let reverseText = Color.black
    static let paper = Color.white
    static let paperDeep = Color.white
    static let panel = Color.white.opacity(0.98)
    static let panelDark = Color.white.opacity(0.98)
    static let panelLight = Color.white
    static let chip = Color.white
    static let line = Color.black.opacity(0.88)
    static let subtle = Color.black.opacity(0.72)
    static let warning = Color.black.opacity(0.82)
}

struct MangaBackground: View {
    var body: some View {
        ZStack {
            MangaTheme.paper.ignoresSafeArea()
            MangaHatchTexture(opacity: 0.07)
                .ignoresSafeArea()
            MangaPrintTexture()
                .ignoresSafeArea()
            SpeedLineBurstTexture()
                .ignoresSafeArea()
        }
    }
}

struct MangaPrintTexture: View {
    var body: some View {
        texture
            .opacity(0.70)
    }

    @ViewBuilder
    private var texture: some View {
        #if canImport(UIKit)
        Image(uiImage: Self.textureImage)
            .resizable(resizingMode: .tile)
        #else
        Rectangle()
            .fill(.clear)
        #endif
    }

    #if canImport(UIKit)
    private static let textureImage: UIImage = {
        let size = CGSize(width: 96, height: 96)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(UIColor.black.withAlphaComponent(0.16).cgColor)

            let dotSpacing: CGFloat = 13
            for y in stride(from: 0, through: size.height, by: dotSpacing) {
                for x in stride(from: 0, through: size.width, by: dotSpacing) {
                    let phase = (Int(x / dotSpacing) + Int(y / dotSpacing)) % 4
                    guard phase == 0 || phase == 2 else { continue }
                    let dotSize: CGFloat = phase == 0 ? 1.6 : 1.1
                    cgContext.fillEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
                }
            }

            cgContext.setFillColor(UIColor.black.withAlphaComponent(0.22).cgColor)
            let grainSpacing: CGFloat = 17
            for y in stride(from: 0, through: size.height, by: grainSpacing) {
                for x in stride(from: 0, through: size.width, by: grainSpacing) {
                    let seed = Int(x * 13 + y * 19) % 9
                    guard seed == 0 else { continue }
                    cgContext.fillEllipse(in: CGRect(x: x + CGFloat(seed % 3), y: y, width: 0.8, height: 0.8))
                }
            }
        }
    }()
    #endif
}

struct MangaInkShadow: View {
    var cornerRadius: CGFloat
    var offset = CGSize(width: 5, height: 5)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            shape
                .stroke(MangaTheme.ink.opacity(0.18), lineWidth: 2)
            MangaHatchTexture(opacity: 0.24)
                .clipShape(shape)
        }
        .offset(offset)
        .allowsHitTesting(false)
    }
}

struct MangaHatchTexture: View {
    var opacity: Double

    var body: some View {
        texture
            .opacity(opacity)
    }

    @ViewBuilder
    private var texture: some View {
        #if canImport(UIKit)
        Image(uiImage: Self.textureImage)
            .resizable(resizingMode: .tile)
        #else
        DiagonalHatchPattern(spacing: 12)
            .stroke(MangaTheme.ink, lineWidth: 1)
        #endif
    }

    #if canImport(UIKit)
    private static let textureImage: UIImage = {
        let size = CGSize(width: 80, height: 80)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cgContext = context.cgContext
            cgContext.setStrokeColor(UIColor.black.cgColor)
            cgContext.setLineWidth(1)

            for offset in stride(from: -size.height, through: size.width + size.height, by: CGFloat(12)) {
                cgContext.move(to: CGPoint(x: offset, y: size.height))
                cgContext.addLine(to: CGPoint(x: offset + size.height, y: 0))
            }
            cgContext.strokePath()
        }
    }()
    #endif
}

struct DiagonalHatchPattern: Shape {
    var spacing: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let longSide = rect.width + rect.height
        for offset in stride(from: -rect.height, through: longSide, by: spacing) {
            path.move(to: CGPoint(x: offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
        }
        return path
    }
}

struct SpeedLineBurst: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY * 0.92)
        for index in 0..<54 {
            let angle = Double(index) * (.pi * 2.0 / 54.0)
            let inner = CGFloat(95 + (index % 5) * 18)
            let outer = max(rect.width, rect.height)
            let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
            let end = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }
}

struct SpeedLineBurstTexture: View {
    var body: some View {
        texture
    }

    @ViewBuilder
    private var texture: some View {
        #if canImport(UIKit)
        Image(uiImage: Self.textureImage)
            .resizable()
            .scaledToFill()
        #else
        SpeedLineBurst()
            .stroke(MangaTheme.ink.opacity(0.16), lineWidth: 1.2)
        #endif
    }

    #if canImport(UIKit)
    private static let textureImage: UIImage = {
        let size = CGSize(width: 430, height: 932)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cgContext = context.cgContext
            let center = CGPoint(x: size.width / 2, y: size.height * 0.46)
            let outer = max(size.width, size.height)

            cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.16).cgColor)
            cgContext.setLineWidth(1.2)
            for index in 0..<54 {
                let angle = Double(index) * (.pi * 2.0 / 54.0)
                let inner = CGFloat(95 + (index % 5) * 18)
                cgContext.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                cgContext.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            }
            cgContext.strokePath()
        }
    }()
    #endif
}

struct MangaPanel<Content: View>: View {
    var title: String?
    var isDark = false
    var content: Content

    init(_ title: String? = nil, isDark: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isDark = isDark
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline.weight(.black))
                    .textCase(.uppercase)
                    .foregroundStyle(MangaTheme.ink)
            }
            content
        }
        .padding(16)
        .background(panelBackground)
        .background {
            MangaInkShadow(cornerRadius: 18)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(MangaTheme.ink, lineWidth: 3)
        }
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .stroke(MangaTheme.ink.opacity(0.10), lineWidth: 5)
                .padding(5)
        }
        .shadow(color: .black.opacity(0.14), radius: 0, x: 2, y: 2)
    }

    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        let base = isDark ? MangaTheme.panelDark : MangaTheme.panel
        let surface = ZStack {
            base
            MangaHatchTexture(opacity: isDark ? 0.035 : 0.025)
        }
        surface
            .clipShape(shape)
    }
}

struct ToyBezel<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Screw()
                Spacer()
                Text("CAPSULE LINK")
                    .font(.caption.weight(.black))
                    .tracking(2)
                Spacer()
                Screw()
            }
            content
            HStack {
                Screw()
                Spacer()
                Capsule()
                    .fill(MangaTheme.ink)
                    .frame(width: 80, height: 8)
                Spacer()
                Screw()
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 30)
                .fill(MangaTheme.panelDark)
                .overlay {
                    MangaHatchTexture(opacity: 0.025)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                }
        }
        .background {
            MangaInkShadow(cornerRadius: 30, offset: CGSize(width: 6, height: 6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30)
                .stroke(MangaTheme.ink, lineWidth: 4)
        }
        .shadow(color: .black.opacity(0.12), radius: 0, x: 2, y: 2)
    }
}

struct Screw: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(MangaTheme.panelLight)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(MangaTheme.ink, lineWidth: 2))
            Rectangle()
                .fill(MangaTheme.ink)
                .frame(width: 13, height: 2)
                .rotationEffect(.degrees(-25))
        }
    }
}

struct StatusChip: View {
    var text: String
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(filled ? MangaTheme.reverseText : MangaTheme.ink)
            .background(filled ? MangaTheme.chip : MangaTheme.panelLight.opacity(0.90), in: Capsule())
            .overlay(Capsule().stroke(MangaTheme.ink, lineWidth: 1.5))
    }
}

struct InkButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.black))
            .foregroundStyle(filled ? MangaTheme.reverseText : MangaTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(filled ? MangaTheme.chip : MangaTheme.panelLight.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MangaTheme.ink, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct InkIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(MangaTheme.ink)
            .frame(width: 38, height: 38)
            .background(MangaTheme.panelLight.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MangaTheme.ink, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

extension View {
    func mangaCard(_ title: String? = nil, isDark: Bool = false) -> some View {
        MangaPanel(title, isDark: isDark) {
            self
        }
    }
}
