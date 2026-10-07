import SnipperCore
import SwiftUI

/// How a card is laid out.
enum CardStyle {
    /// Fixed square tile for the atlas field.
    case tile
    /// Full-width card of natural height for the grid.
    case flow
}

/// A snip as a glass card. Picks a layout per kind: posts, screenshots, notes, links, clips.
struct SnipCard: View {
    let item: DisplayItem
    let style: CardStyle
    var showMatch = false

    @State private var hovering = false

    private var snip: Snip { item.snip }
    private var radius: CGFloat { style == .tile ? 34 : Theme.cardRadius }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: style == .tile ? .infinity : nil, alignment: .topLeading)
            .background(GlassCardBackground(cornerRadius: radius, tint: Theme.tint(for: snip.kind), highlighted: hovering))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if showMatch, let similarity = item.similarity, hovering || style == .flow {
                    MatchChip(similarity: similarity)
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if snip.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFFD68A))
                        .padding(7)
                        .background(Circle().fill(.black.opacity(0.4)))
                        .padding(10)
                }
            }
            .scaleEffect(hovering && style == .tile ? 1.035 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch snip.kind {
        case .tweet: PostCardContent(snip: snip, style: style)
        case .screenshot, .image: ImageCardContent(snip: snip, style: style)
        case .note: NoteCardContent(snip: snip, style: style)
        case .link: LinkCardContent(snip: snip, style: style)
        case .text: ClipCardContent(snip: snip, style: style)
        }
    }

    /// Rough card height for balancing grid columns.
    static func estimatedHeight(_ snip: Snip, width: CGFloat) -> CGFloat {
        let charsPerLine = max(20, width / 7.4)
        let textLines = min(14, ceil(CGFloat(snip.body.count) / charsPerLine) + CGFloat(snip.body.filter(\.isNewline).count))
        switch snip.kind {
        case .tweet:
            var h = 64 + textLines * 19 + 40
            if let m = snip.primaryMedia { h += width / CGFloat(max(0.6, min(2.2, m.aspectRatio ?? 1.6))) }
            if snip.tweet?.quoted != nil { h += 80 }
            return h
        case .screenshot, .image:
            let ratio = snip.primaryMedia?.aspectRatio ?? 1.6
            return width / CGFloat(max(0.55, min(2.4, ratio))) + 58
        case .note, .text:
            return 60 + min(10, textLines) * 22
        case .link:
            return (snip.primaryMedia != nil ? width * 0.5 : 0) + 120
        }
    }
}

// MARK: - Posts

private struct PostCardContent: View {
    let snip: Snip
    let style: CardStyle

    private var heroImage: SnipMedia? {
        guard style == .tile, let media = snip.primaryMedia, snip.body.count < 140, snip.tweet?.quoted == nil else { return nil }
        return media
    }

    var body: some View {
        if let hero = heroImage {
            ZStack(alignment: .bottomLeading) {
                AsyncThumbnail(source: ImageSource.of(hero), maxPixels: 640)
                LinearGradient(colors: [.clear, Color(hex: 0x09111A).opacity(0.86)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    header(onImage: true)
                    if !snip.body.isEmpty {
                        Text(snip.body)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(3)
                            .shadow(color: .black.opacity(0.5), radius: 8)
                    }
                }
                .padding(16)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header(onImage: false)
                if !snip.body.isEmpty {
                    Text(style == .flow ? LinkedText.attributed(snip.body) : AttributedString(snip.body))
                        .font(.system(size: style == .tile ? 13.5 : 14))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.ink.opacity(0.94))
                        .lineLimit(style == .tile ? (snip.primaryMedia == nil ? 8 : 3) : 14)
                        .fixedSize(horizontal: false, vertical: style == .flow)
                }
                if let media = snip.primaryMedia {
                    mediaPreview(media)
                }
                if let quoted = snip.tweet?.quoted {
                    QuotedPostView(quoted: quoted, lineLimit: style == .tile ? 2 : 4)
                }
                if style == .tile { Spacer(minLength: 0) }
                HStack {
                    MetricsRow(info: snip.tweet, compact: true)
                    Spacer()
                    if snip.media.count > 1 {
                        Label("\(snip.media.count)", systemImage: "photo.on.rectangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .padding(16)
        }
    }

    private func header(onImage: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(author: snip.author, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(snip.author?.name ?? "Post")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if snip.author?.verified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0x8ECBFF))
                    }
                }
                .foregroundStyle(Theme.ink)
                Text("@\(snip.author?.handle ?? "x") · \(RelativeDate.short(snip.createdAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(onImage ? .white.opacity(0.75) : Theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            XGlyph(size: 12)
        }
    }

    @ViewBuilder
    private func mediaPreview(_ media: SnipMedia) -> some View {
        let ratio = CGFloat(max(0.7, min(2.0, media.aspectRatio ?? 1.6)))
        AsyncThumbnail(source: ImageSource.of(media), maxPixels: style == .flow ? 900 : 480)
            .aspectRatio(style == .flow ? ratio : 2.2, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .center) {
                if media.kind != .image {
                    Image(systemName: media.kind == .gif ? "play.square" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

struct QuotedPostView: View {
    let quoted: QuotedPost
    var lineLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AvatarView(author: quoted.author, size: 16)
                Text(quoted.author.map { "\($0.name) @\($0.handle)" } ?? "Quoted post")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .lineLimit(1)
            }
            Text(quoted.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .lineLimit(lineLimit)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - Screenshots and images

private struct ImageCardContent: View {
    let snip: Snip
    let style: CardStyle

    var body: some View {
        switch style {
        case .tile:
            ZStack(alignment: .bottomLeading) {
                AsyncThumbnail(source: snip.primaryMedia.flatMap(ImageSource.of), maxPixels: 640, placeholderTint: Theme.tint(for: snip.kind))
                LinearGradient(colors: [.clear, Color(hex: 0x09111A).opacity(0.78)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snip.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(RelativeDate.short(snip.savedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(16)
            }
            .overlay(alignment: .topLeading) {
                KindChip(kind: snip.kind).padding(12)
            }
        case .flow:
            VStack(alignment: .leading, spacing: 0) {
                AsyncThumbnail(source: snip.primaryMedia.flatMap(ImageSource.of), maxPixels: 900, placeholderTint: Theme.tint(for: snip.kind))
                    .aspectRatio(CGFloat(max(0.55, min(2.4, snip.primaryMedia?.aspectRatio ?? 1.6))), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    Image(systemName: Theme.symbol(for: snip.kind))
                        .foregroundStyle(Theme.tint(for: snip.kind))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snip.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(14)
            }
        }
    }

    private var subtitle: String {
        var parts = [RelativeDate.short(snip.savedAt)]
        if let m = snip.primaryMedia, let w = m.width, let h = m.height { parts.append("\(w)×\(h)") }
        if let ocr = snip.ocrText, !ocr.isEmpty { parts.append("text recognized") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Notes, clips, links

private struct NoteCardContent: View {
    let snip: Snip
    let style: CardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                Text(snip.title.isEmpty ? "Note" : snip.title)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.tint(for: .note))

            Text(snip.body)
                .font(.system(size: style == .tile ? 17 : 15, weight: .medium))
                .tracking(-0.3)
                .lineSpacing(3)
                .foregroundStyle(Theme.ink)
                .lineLimit(style == .tile ? 7 : 12)
            if style == .tile { Spacer(minLength: 0) }
            footer
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(RelativeDate.short(snip.savedAt))
            ForEach(snip.tags.prefix(3), id: \.self) { Text("#\($0)") }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.inkSecondary)
        .lineLimit(1)
    }
}

private struct ClipCardContent: View {
    let snip: Snip
    let style: CardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text(snip.body)
                .font(.system(size: style == .tile ? 15 : 14))
                .italic()
                .lineSpacing(2)
                .foregroundStyle(Theme.ink.opacity(0.92))
                .lineLimit(style == .tile ? 7 : 12)
            if style == .tile { Spacer(minLength: 0) }
            HStack(spacing: 6) {
                if let favicon = snip.link?.faviconURL {
                    AsyncThumbnail(source: .remote(favicon), maxPixels: 48)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text([snip.domain ?? snip.appName ?? "Clip", RelativeDate.short(snip.savedAt)].joined(separator: " · "))
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.inkSecondary)
        }
        .padding(18)
    }
}

private struct LinkCardContent: View {
    let snip: Snip
    let style: CardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let media = snip.primaryMedia {
                AsyncThumbnail(source: ImageSource.of(media), maxPixels: 700, placeholderTint: Theme.tint(for: .link))
                    .frame(height: style == .tile ? 110 : nil)
                    .aspectRatio(style == .flow ? 1.91 : nil, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let favicon = snip.link?.faviconURL {
                        AsyncThumbnail(source: .remote(favicon), maxPixels: 48)
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        Image(systemName: "link").font(.system(size: 10, weight: .bold))
                    }
                    Text(snip.link?.siteName ?? snip.domain ?? "Link")
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)

                Text(snip.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(style == .tile ? 3 : 3)
                if let summary = snip.link?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                        .lineLimit(style == .tile ? 2 : 4)
                }
                if style == .tile { Spacer(minLength: 0) }
            }
            .padding(16)
        }
    }
}
