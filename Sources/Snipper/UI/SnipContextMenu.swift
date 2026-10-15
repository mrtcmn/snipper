import SnipperCore
import SwiftUI

/// Actions available on every card.
struct SnipContextMenu: View {
    let snip: Snip
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { model.viewerID = snip.id }
        Button("Copy", systemImage: "doc.on.doc") { model.copy(snip) }
        Button("Copy as Markdown", systemImage: "doc.richtext") { model.copyMarkdown(snip) }
        if snip.url != nil {
            Button("Open Original", systemImage: "safari") { model.openOriginal(snip) }
        }
        Divider()
        Button(snip.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: snip.isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(snip.id)
        }
        Button("Find Similar", systemImage: "sparkles") { model.showSimilar(to: snip.id) }
            .disabled(!model.index.hasVector(snip.id))
        if snip.kind == .screenshot || snip.kind == .image {
            Button("Annotate", systemImage: "pencil.and.outline") { model.annotate(snip) }
            Button("Pin to Screen", systemImage: "pin") { model.pin(snip) }
        }
        if !snip.media.compactMap(\.localFile).isEmpty {
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(snip) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete([snip.id]) }
    }
}
