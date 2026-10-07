import SwiftUI
import SnipperCore

/// Visual language: a deep-blue night field with icy, glassy surfaces,
/// after the "Embed Anything" EmbeddingGemma demo.
enum Theme {
    static let ink = Color(hex: 0xF2F5F8)
    static let inkSecondary = Color(hex: 0xA2B4C2)
    static let inkTertiary = Color(hex: 0x7F9BA9)
    static let accent = Color(hex: 0xB7E8F2)
    static let accentStrong = Color(hex: 0x8FD8EA)
    static let danger = Color(hex: 0xFF9BA7)

    static let fieldTop = Color(hex: 0x0A1C3D)
    static let fieldBottom = Color(hex: 0x000000)
    static let surface = Color(hex: 0x10151B)
    static let panel = Color(hex: 0x0B1724)

    /// The window background: navy at the top-left fading to black.
    static var fieldGradient: LinearGradient {
        LinearGradient(
            stops: [.init(color: fieldTop, location: 0), .init(color: fieldBottom, location: 0.74)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let cardRadius: CGFloat = 26
    static let controlRadius: CGFloat = 22

    static func tint(for kind: SnipKind) -> Color {
        switch kind {
        case .tweet: Color(hex: 0x8ECBFF)
        case .screenshot: Color(hex: 0x9FF0D4)
        case .note: Color(hex: 0xFFD68A)
        case .link: Color(hex: 0xC5B8FF)
        case .image: Color(hex: 0xFFB3C7)
        case .text: Color(hex: 0xB7E8F2)
        }
    }

    static func symbol(for kind: SnipKind) -> String {
        switch kind {
        case .tweet: "bubble.left.and.text.bubble.right"
        case .screenshot: "camera.viewfinder"
        case .note: "note.text"
        case .link: "link"
        case .image: "photo"
        case .text: "text.quote"
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The frosted, edge-lit card surface used for snips. Cards are content, so they use a
/// lightweight look rather than real Liquid Glass, which is reserved for controls.
struct GlassCardBackground: View {
    var cornerRadius: CGFloat = Theme.cardRadius
    var tint: Color = .clear
    var highlighted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Theme.surface.opacity(0.72))
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.02), Color.white.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(shape.fill(tint.opacity(0.06)))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(highlighted ? 0.55 : 0.30),
                            Theme.accent.opacity(highlighted ? 0.35 : 0.12),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            // Inner glow along the top-left edge, like light caught in glass.
            .overlay(
                shape
                    .stroke(Color(hex: 0xE3F3FF).opacity(0.22), lineWidth: 6)
                    .blur(radius: 6)
                    .mask(shape.fill(LinearGradient(colors: [.white, .clear], startPoint: .topLeading, endPoint: .center)))
            )
            .shadow(color: .black.opacity(0.38), radius: highlighted ? 26 : 16, y: highlighted ? 16 : 10)
    }
}

/// Small capsule label such as "Screenshot" or "92% match".
struct GlassChip: View {
    var text: String
    var symbol: String?
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.ink.opacity(0.92))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(hex: 0x07161C).opacity(0.55))
                .overlay(Capsule().fill(tint.opacity(0.10)))
                .overlay(Capsule().strokeBorder(Color(hex: 0xE2FAFF).opacity(0.22), lineWidth: 1))
        )
    }
}

extension View {
    /// Liquid Glass for floating controls (search bar, toolbars, panels).
    func glassPanel(cornerRadius: CGFloat = Theme.controlRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
        return glassEffect(interactive ? glass.interactive() : glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The tight letter spacing used for headings.
    func headline(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight)).tracking(-size * 0.035)
    }
}
