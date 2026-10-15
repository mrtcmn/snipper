import AppKit
import SnipperCore
import SwiftUI

struct AvatarView: View {
    let author: SnipAuthor?
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.accent.opacity(0.35), Color(hex: 0x3A3A3A)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.9))
            if let url = author?.avatarURL {
                AsyncThumbnail(source: .remote(url), maxPixels: Int(size * 3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    private var initials: String {
        let name = author?.name ?? author?.handle ?? "?"
        return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// The X logo, drawn as text so it needs no asset.
struct XGlyph: View {
    var size: CGFloat = 12
    var body: some View {
        Text("𝕏")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Theme.ink.opacity(0.7))
    }
}

struct KindChip: View {
    let kind: SnipKind
    var detail: String?

    var body: some View {
        GlassChip(text: detail.map { "\(kind.label) · \($0)" } ?? kind.label, symbol: Theme.symbol(for: kind), tint: Theme.tint(for: kind))
    }
}

/// "92% match", shown on hover while searching.
struct MatchChip: View {
    let similarity: Float

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(Int((max(0, similarity) * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Text("match")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.72))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

struct MetricsRow: View {
    let info: TweetInfo?
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 16) {
            metric("bubble.left", info?.replies)
            metric("arrow.2.squarepath", info?.reposts)
            metric("heart", info?.likes)
            if !compact { metric("chart.bar", info?.views) }
        }
        .font(.system(size: compact ? 11 : 12))
        .foregroundStyle(Theme.inkSecondary)
    }

    @ViewBuilder
    private func metric(_ symbol: String, _ value: Int?) -> some View {
        if let value, value > 0 {
            Label(CompactNumber.format(value), systemImage: symbol)
                .labelStyle(MetricLabelStyle())
        }
    }
}

private struct MetricLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title.monospacedDigit()
        }
    }
}

enum RelativeDate {
    /// "now", "5m", "3h", "2d", or "Mar 4" / "Mar 4, 2023".
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        let style: Date.FormatStyle = sameYear
            ? Date.FormatStyle.dateTime.month(.abbreviated).day()
            : Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return date.formatted(style)
    }

    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
    }
}

/// Text with clickable links, for post bodies.
enum LinkedText {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].foregroundColor = Theme.accent
        }
        return result
    }
}

struct EmptyLibraryView: View {
    var isSearching: Bool
    var onCapture: () -> Void
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isSearching ? "sparkle.magnifyingglass" : "scissors")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.inkSecondary)
            Text(isSearching ? "Nothing matches yet" : "Your library is empty")
                .headline(22, weight: .medium)
                .foregroundStyle(Theme.ink)
            Text(isSearching
                 ? "Try different words — search understands meaning, not just keywords."
                 : "Snip posts from X with the browser extension, capture your screen with ⌃⇧4, or import your X bookmarks.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if !isSearching {
                HStack(spacing: 10) {
                    Button("Capture screen", systemImage: "rectangle.dashed", action: onCapture)
                        .buttonStyle(.glass)
                    Button("Import…", systemImage: "tray.and.arrow.down", action: onImport)
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accentStrong)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 30)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.55)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Soft light behind the field. Static: an endless drift redrew three large blurs on every frame.
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Theme.fieldGradient
            Circle()
                .fill(Color(hex: 0x3A3A3C).opacity(0.35))
                .frame(width: 720, height: 720)
                .blur(radius: 140)
                .offset(x: -190, y: -180)
            Circle()
                .fill(Color(hex: 0x5A5A5C).opacity(0.14))
                .frame(width: 560, height: 560)
                .blur(radius: 150)
                .offset(x: 280, y: 290)
            Circle()
                .fill(Color(hex: 0x2C2C2E).opacity(0.10))
                .frame(width: 480, height: 480)
                .blur(radius: 160)
                .offset(x: 190, y: -250)
            // Darken toward the bottom so the search bar sits on calm ground.
            LinearGradient(stops: [.init(color: .clear, location: 0.7), .init(color: .black.opacity(0.35), location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// A small circular progress indicator for the indexing status.
struct ProgressRing: View {
    var progress: Double?
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .modifier(Spinning())
            }
        }
        .frame(width: size, height: size)
    }
}

private struct Spinning: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(on ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// The "STASH" wordmark from Resources, tinted like text.
struct Wordmark: View {
    var height: CGFloat
    private static let image = Bundle.main.image(forResource: "Wordmark")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .accessibilityLabel("Stash")
        } else {
            Text("Stash").headline(height, weight: .semibold)
        }
    }
}
