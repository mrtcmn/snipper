import AppKit
import SnipperCore
import SwiftUI

/// The focused view of one snip, over a blurred library.
struct SnipViewer: View {
    let snip: Snip
    var similarity: Float?
    var position: (index: Int, total: Int)?
    var onClose: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void

    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 28)
                    .padding(.top, 46)
                ScrollView {
                    content
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(28)
                        .background(GlassCardBackground(cornerRadius: 30, tint: Theme.tint(for: snip.kind)))
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 110)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
            }

            VStack {
                Spacer()
                HStack {
                    details
                    Spacer()
                }
                .padding(28)
            }
            .allowsHitTesting(false)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.leftArrow) { onPrevious(); return .handled }
        .onKeyPress(.rightArrow) { onNext(); return .handled }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Chrome

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: Theme.symbol(for: snip.kind))
                    .foregroundStyle(Theme.tint(for: snip.kind))
                Text(kindDetail)
                    .font(.system(size: 14))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .glassEffect(.regular.tint(Theme.panel.opacity(0.5)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer()

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 4) {
                    if let position {
                        ToolbarIconButton(symbol: "chevron.left", help: "Previous (←)", action: onPrevious)
                        Text("\(position.index + 1) / \(position.total)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink.opacity(0.7))
                            .frame(minWidth: 50)
                        ToolbarIconButton(symbol: "chevron.right", help: "Next (→)", action: onNext)
                        Divider().frame(height: 18)
                    }
                    ToolbarIconButton(symbol: snip.isFavorite ? "star.fill" : "star", help: "Favorite") { model.toggleFavorite(snip.id) }
                    ToolbarIconButton(symbol: "doc.on.doc", help: "Copy") { model.copy(snip) }
                    if snip.url != nil {
                        ToolbarIconButton(symbol: "safari", help: "Open original") { model.openOriginal(snip) }
                    }
                    if model.index.hasVector(snip.id) {
                        ToolbarIconButton(symbol: "sparkles", help: "Find similar") { model.showSimilar(to: snip.id) }
                    }
                    Menu {
                        Button("Copy as Markdown", systemImage: "doc.richtext") { model.copyMarkdown(snip) }
                        if snip.kind == .screenshot || snip.kind == .image {
                            Button("Annotate", systemImage: "pencil.and.outline") { model.annotate(snip) }
                            Button("Pin to Screen", systemImage: "pin") { model.pin(snip) }
                        }
                        if !snip.media.compactMap(\.localFile).isEmpty {
                            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(snip) }
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.delete([snip.id])
                            onClose()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    ToolbarIconButton(symbol: "xmark", help: "Close (Esc)", action: onClose)
                }
                .padding(4)
                .glassEffect(.regular.tint(Theme.panel.opacity(0.5)), in: Capsule())
            }
        }
    }

    private var kindDetail: String {
        switch snip.kind {
        case .tweet: return "Post on X"
        case .screenshot, .image:
            if let m = snip.primaryMedia, let w = m.width, let h = m.height { return "\(snip.kind.label) · \(w) × \(h)" }
            return snip.kind.label
        case .link: return snip.link?.siteName ?? snip.domain ?? "Link"
        default: return snip.kind.label
        }
    }

    private var details: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snip.displayTitle)
                    .headline(20, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .lineLimit(1)
            }
            if let similarity {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Match").font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.7))
                    Text("\(Int((max(0, similarity) * 100).rounded()))%")
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.15)).frame(width: 1) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.5)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var subtitle: String {
        var parts = ["Saved \(RelativeDate.long(snip.savedAt))"]
        if let source = snip.source { parts.append(Self.describe(source: source)) }
        return parts.joined(separator: " · ")
    }

    static func describe(source: String) -> String {
        switch source {
        case "x-bookmarks", "import:x-bookmarks": return "from X bookmarks"
        case "x-button": return "from X"
        case "capture": return "screen capture"
        case "capture:text": return "text capture"
        case "clipboard": return "from clipboard"
        case "note": return "note"
        case "service": return "Services menu"
        default:
            if source.hasPrefix("browser:") { return "from \(source.dropFirst(8))" }
            if source.hasPrefix("import:") { return "imported" }
            return source
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch snip.kind {
        case .tweet: PostDetail(snip: snip)
        case .screenshot, .image: ImageDetail(snip: snip)
        case .note: NoteDetail(snip: snip).id(snip.id)
        case .link: LinkDetail(snip: snip)
        case .text: ClipDetail(snip: snip)
        }
    }
}

// MARK: - Kinds

private struct PostDetail: View {
    let snip: Snip
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                AvatarView(author: snip.author, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(snip.author?.name ?? "Post").font(.system(size: 17, weight: .semibold))
                        if snip.author?.verified == true {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(hex: 0x8ECBFF))
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    Text("@\(snip.author?.handle ?? "") · \(RelativeDate.long(snip.createdAt))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                if snip.url != nil {
                    Button("Open on X", systemImage: "arrow.up.right") { model.openOriginal(snip) }
                        .buttonStyle(.glass)
                }
            }

            if !snip.body.isEmpty {
                let short = snip.body.count < 160
                Text(LinkedText.attributed(snip.body))
                    .font(.system(size: short ? 26 : 19, weight: short ? .medium : .regular))
                    .tracking(short ? -0.6 : -0.2)
                    .lineSpacing(short ? 4 : 5)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !snip.media.isEmpty { MediaGallery(media: snip.media) }
            if let quoted = snip.tweet?.quoted { QuotedPostView(quoted: quoted, lineLimit: 12) }
            if let card = snip.tweet?.card { LinkPreviewBox(link: card) }

            HStack {
                MetricsRow(info: snip.tweet)
                Spacer()
            }
            TagEditor(snip: snip)
        }
    }
}

private struct ImageDetail: View {
    let snip: Snip
    @Environment(AppModel.self) private var model
    @State private var showText = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let media = snip.primaryMedia {
                AsyncThumbnail(source: ImageSource.of(media), maxPixels: 2400, contentMode: .fit)
                    .aspectRatio(CGFloat(media.aspectRatio ?? 1.6), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 620)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .onTapGesture(count: 2) { open(media) }
            }
            HStack(spacing: 10) {
                Button("Annotate", systemImage: "pencil.and.outline") { model.annotate(snip) }
                Button("Copy Image", systemImage: "doc.on.doc") { model.copy(snip) }
                Button("Pin", systemImage: "pin") { model.pin(snip) }
                Button("Show in Finder", systemImage: "folder") { model.revealInFinder(snip) }
            }
            .buttonStyle(.glass)

            if !snip.body.isEmpty {
                Text(snip.body)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .textSelection(.enabled)
            }

            if let ocr = snip.ocrText, !ocr.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            withAnimation(.snappy) { showText.toggle() }
                        } label: {
                            Label("Text in image", systemImage: showText ? "chevron.down" : "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Copy Text", systemImage: "text.viewfinder") {
                            Pasteboard.copy(text: ocr)
                            HUD.shared.show("Text copied", symbol: "text.viewfinder")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    if showText {
                        Text(ocr)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.25)))
                    }
                }
            } else if snip.kind == .screenshot {
                Text("Recognizing text…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            }
            TagEditor(snip: snip)
        }
    }

    private func open(_ media: SnipMedia) {
        if let file = media.localFile {
            NSWorkspace.shared.open(model.library.media.url(for: file))
        }
    }
}

private struct NoteDetail: View {
    let snip: Snip
    @Environment(AppModel.self) private var model
    @State private var title: String
    @State private var text: String
    @State private var saveTask: Task<Void, Never>?

    init(snip: Snip) {
        self.snip = snip
        _title = State(initialValue: snip.title)
        _text = State(initialValue: snip.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .headline(26, weight: .semibold)
                .foregroundStyle(Theme.ink)
            TextEditor(text: $text)
                .font(.system(size: 17))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 280)
            TagEditor(snip: snip)
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onDisappear(perform: saveNow)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        let title = title, text = text
        model.library.mutate(snip.id) { s in
            s.title = title
            s.body = text
        }
    }
}

private struct LinkDetail: View {
    let snip: Snip
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let media = snip.primaryMedia {
                AsyncThumbnail(source: ImageSource.of(media), maxPixels: 1600)
                    .aspectRatio(1.91, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text(snip.link?.siteName ?? snip.domain ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text(snip.displayTitle)
                .headline(28, weight: .semibold)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            if let summary = snip.link?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .textSelection(.enabled)
            }
            if !snip.body.isEmpty {
                Text(snip.body)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .textSelection(.enabled)
            }
            HStack {
                Button("Open Page", systemImage: "safari") { model.openOriginal(snip) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentStrong)
                if let url = snip.url {
                    Text(url)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            TagEditor(snip: snip)
        }
    }
}

private struct ClipDetail: View {
    let snip: Snip
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "quote.opening")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text(LinkedText.attributed(snip.body))
                .font(.system(size: snip.body.count < 220 ? 24 : 18, weight: .medium))
                .tracking(-0.4)
                .lineSpacing(5)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            if let media = snip.primaryMedia {
                AsyncThumbnail(source: ImageSource.of(media), maxPixels: 1600, contentMode: .fit)
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let url = snip.url {
                Button {
                    model.openOriginal(snip)
                } label: {
                    Label(snip.link?.title ?? url, systemImage: "link")
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
            }
            TagEditor(snip: snip)
        }
    }
}

// MARK: - Pieces

struct MediaGallery: View {
    let media: [SnipMedia]
    @Environment(AppModel.self) private var model

    var body: some View {
        let columns = media.count == 1 ? 1 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(media) { m in
                AsyncThumbnail(source: ImageSource.of(m), maxPixels: 1600)
                    .aspectRatio(columns == 1 ? CGFloat(max(0.6, min(2.2, m.aspectRatio ?? 1.6))) : 1.25, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if m.kind != .image {
                            Image(systemName: "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(16)
                                .background(Circle().fill(.black.opacity(0.5)))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(m) }
                    .help(m.alt ?? "")
            }
        }
    }

    private func open(_ m: SnipMedia) {
        if let video = m.videoURL, let url = URL(string: video) {
            NSWorkspace.shared.open(url)
        } else if let file = m.localFile {
            NSWorkspace.shared.open(model.library.media.url(for: file))
        } else if let remote = m.remoteURL, let url = URL(string: remote) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct LinkPreviewBox: View {
    let link: LinkInfo

    var body: some View {
        HStack(spacing: 12) {
            if let image = link.imageURL {
                AsyncThumbnail(source: .remote(image), maxPixels: 300)
                    .frame(width: 92, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                if let site = link.siteName { Text(site).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary) }
                if let title = link.title { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2) }
                if let summary = link.summary { Text(summary).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.7)).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .onTapGesture {
            if let s = link.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        }
    }
}

/// Tags as removable chips plus a field to add more.
struct TagEditor: View {
    let snip: Snip
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(snip.tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text("#\(tag)")
                    Button {
                        model.setTags(snip.tags.filter { $0 != tag }, for: snip.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink.opacity(0.6))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.5))
            }
            TextField("Add tag", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 110)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().strokeBorder(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .onSubmit {
                    let new = draft.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                    model.setTags(snip.tags + new, for: snip.id)
                    draft = ""
                }
        }
    }
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
