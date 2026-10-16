import SnipperCore
import SwiftUI

/// Brand on the left, filters in the middle, actions on the right — all floating glass.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var glass

    private let filters: [LibraryFilter] = [.all, .kind(.tweet), .kind(.screenshot), .kind(.note), .kind(.link), .favorites]

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            brand
                .padding(.leading, 82) // traffic lights
            Spacer(minLength: 12)
            filterPills
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .frame(height: 64)
        .background(
            // Drag the window by the empty parts of the bar.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        )
    }

    // MARK: Brand

    private var brand: some View {
        HStack(alignment: .center, spacing: 10) {
            Wordmark(height: 15)
                .foregroundStyle(Theme.ink)
            Text("\(model.library.snips.count.formatted()) stashed")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
                .contentTransition(.numericText())
                .help("Snips in your library")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.35)), in: Capsule())
        .fixedSize()
    }

    // MARK: Filters

    private var filterPills: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(filters) { filter in
                    pill(filter)
                }
                tagMenu
            }
            .padding(4)
            .glassEffect(.regular.tint(Theme.panel.opacity(0.35)), in: Capsule())
        }
    }

    private func pill(_ filter: LibraryFilter) -> some View {
        let selected = model.search.filter == filter
        return Button {
            withAnimation(.snappy(duration: 0.25)) { model.search.filter = filter }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.symbol).font(.system(size: 11, weight: .semibold))
                Text(filter.title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Theme.ink : Theme.ink.opacity(0.75))
            .background {
                if selected {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.tint(.white.opacity(0.14)).interactive(), in: Capsule())
                        .matchedGeometryEffect(id: "filter", in: glass)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var tagMenu: some View {
        let tags = model.library.tagCounts
        let current: String? = {
            if case .tag(let t) = model.search.filter { return t }
            if model.search.filter == .bookmarks { return "X Bookmarks" }
            return nil
        }()
        return Menu {
            Button("X Bookmarks", systemImage: "bookmark") { model.search.filter = .bookmarks }
            Button("Clips", systemImage: "text.quote") { model.search.filter = .kind(.text) }
            Button("Images", systemImage: "photo") { model.search.filter = .kind(.image) }
            if !tags.isEmpty {
                Divider()
                ForEach(tags.prefix(30)) { entry in
                    Button("#\(entry.tag)  \(entry.count)") { model.search.filter = .tag(entry.tag) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: current == nil ? "number" : "line.3.horizontal.decrease")
                Text(current.map { $0 == "X Bookmarks" ? $0 : "#\($0)" } ?? "More")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(current == nil ? Theme.ink.opacity(0.75) : Theme.ink)
            .background {
                if current != nil {
                    Capsule().fill(.clear).glassEffect(.regular.tint(.white.opacity(0.14)), in: Capsule())
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Actions

    private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                viewModeToggle

                Menu {
                    ForEach([HotKeyAction.captureRegion, .captureWindow, .captureScreen, .captureText], id: \.self) { action in
                        Button(menuTitle(action), systemImage: action.symbol) { model.perform(action) }
                    }
                    Divider()
                    Button(menuTitle(.snipBrowserTab), systemImage: HotKeyAction.snipBrowserTab.symbol) { model.perform(.snipBrowserTab) }
                    Button(menuTitle(.saveClipboard), systemImage: HotKeyAction.saveClipboard.symbol) { model.perform(.saveClipboard) }
                    Button(menuTitle(.pickColor), systemImage: HotKeyAction.pickColor.symbol) { model.perform(.pickColor) }
                } label: {
                    Image(systemName: "camera.viewfinder")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("Capture")

                Button { model.newNote() } label: { Image(systemName: "square.and.pencil") }
                    .help("New note (⌘N)")

                Menu {
                    Button("Import X Bookmarks…", systemImage: "bookmark") { model.importXBookmarksInBrowser() }
                    Button("Import Files…", systemImage: "tray.and.arrow.down") { model.importFiles() }
                    Divider()
                    Button("Export as Markdown…", systemImage: "doc.richtext") { model.exportMarkdown(visibleSnips) }
                    Button("Export as JSON…", systemImage: "curlybraces") { model.exportJSON(visibleSnips) }
                } label: {
                    Image(systemName: "tray.full")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("Import and export")

                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
    }

    private var visibleSnips: [Snip] {
        (model.search.isQueryActive ? model.search.relevantItems : model.search.items).map(\.snip)
    }

    private var viewModeToggle: some View {
        HStack(spacing: 0) {
            ForEach(LibraryViewMode.allCases) { mode in
                Button {
                    withAnimation(.snappy) { model.settings.viewMode = mode }
                } label: {
                    Image(systemName: mode == .atlas ? "circle.hexagongrid" : "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 30)
                        .foregroundStyle(model.settings.viewMode == mode ? Theme.ink : Theme.ink.opacity(0.7))
                        .background {
                            if model.settings.viewMode == mode {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(.regular.tint(.white.opacity(0.14)).interactive(), in: Capsule())
                                    .matchedGeometryEffect(id: "mode", in: glass)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(mode == .atlas ? "Atlas (⌘1)" : "Grid (⌘2)")
            }
        }
        .padding(3)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.35)), in: Capsule())
    }

    private func menuTitle(_ action: HotKeyAction) -> String {
        guard let combo = HotKeyCenter.shared.bindings[action] else { return action.title }
        return "\(action.title)    \(combo.display)"
    }
}
