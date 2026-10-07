import AppKit
import SnipperCore
import SwiftUI
import UniformTypeIdentifiers

/// A Pinterest-style grid: items flow into the shortest column, each column is lazy.
struct MasonryGrid: View {
    let items: [DisplayItem]
    let isSearching: Bool
    var topInset: CGFloat = 84
    var bottomInset: CGFloat = 130
    var onOpen: (Snip) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 16
            let available = geo.size.width - 48
            let columns = max(1, Int((available + spacing) / (300 + spacing)))
            let width = (available - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let distributed = Self.distribute(items, columns: columns, width: width)

            ScrollView {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(distributed.indices, id: \.self) { column in
                        LazyVStack(spacing: spacing) {
                            ForEach(distributed[column]) { item in
                                SnipCard(item: item, style: .flow, showMatch: isSearching)
                                    .frame(width: width)
                                    .onTapGesture { onOpen(item.snip) }
                                    .contextMenu { SnipContextMenu(snip: item.snip) }
                                    .onDrag { dragProvider(for: item.snip) }
                            }
                        }
                        .frame(width: width)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: items.map(\.id))
            }
            .scrollIndicators(.never)
            .scrollEdgeEffectStyle(.soft, for: .all)
        }
    }

    /// Greedy column balancing by estimated card height.
    static func distribute(_ items: [DisplayItem], columns: Int, width: CGFloat) -> [[DisplayItem]] {
        var result = Array(repeating: [DisplayItem](), count: columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        for item in items {
            let target = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            result[target].append(item)
            heights[target] += SnipCard.estimatedHeight(item.snip, width: width) + 16
        }
        return result
    }

    /// Drag a card out: the image file for screenshots, the link for everything else.
    private func dragProvider(for snip: Snip) -> NSItemProvider {
        if let file = snip.primaryMedia?.localFile, snip.kind == .screenshot || snip.kind == .image,
           let provider = NSItemProvider(contentsOf: model.library.media.url(for: file)) {
            return provider
        }
        if let string = snip.url, let url = URL(string: string) {
            return NSItemProvider(object: url as NSURL)
        }
        return NSItemProvider(object: (snip.body.isEmpty ? snip.displayTitle : snip.body) as NSString)
    }
}
