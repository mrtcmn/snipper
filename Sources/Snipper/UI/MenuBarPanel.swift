import AppKit
import SnipperCore
import SwiftUI

/// The glass panel under the menu bar icon: tools, quick search and recent snips.
struct MenuBarPanel: View {
    var dismiss: () -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private let tools: [HotKeyAction] = [
        .captureRegion, .captureWindow, .captureScreen, .captureText,
        .quickNote, .snipBrowserTab, .saveClipboard, .pickColor,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchField
            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(tools) { tool in
                        toolButton(tool)
                    }
                }
            }
            recent
            footer
        }
        .padding(16)
        .frame(width: 360)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .glassEffect(.regular.tint(Theme.accent.opacity(0.2)), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Snipper").headline(15, weight: .semibold)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(extensionConnected ? Color(hex: 0x7EE0B5) : Theme.inkTertiary)
                .frame(width: 7, height: 7)
                .help(extensionConnected ? "Browser extension connected" : "Browser extension not seen yet")
        }
    }

    private var extensionConnected: Bool {
        guard let last = model.lastExtensionContact else { return false }
        return Date().timeIntervalSince(last) < 600
    }

    private var statusText: String {
        let count = model.library.snips.count
        return "\(count.formatted()) snips · \(model.index.isReady ? model.index.engineName : "keyword search")"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSecondary)
            TextField("Search library", text: $query)
                .textFieldStyle(.plain)
                .onSubmit {
                    let q = query
                    query = ""
                    dismiss()
                    model.showLibrary()
                    model.search.text = q
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.4)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toolButton(_ tool: HotKeyAction) -> some View {
        Button {
            dismiss()
            // Let the popover close before capturing, so it isn't in the screenshot.
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                model.perform(tool)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let combo = HotKeyCenter.shared.bindings[tool] {
                        Text(combo.display)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .textCase(.uppercase)
            if model.library.snips.isEmpty {
                Text("Nothing saved yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
            ForEach(model.library.snips.prefix(4)) { snip in
                Button {
                    dismiss()
                    model.reveal(snip.id)
                } label: {
                    HStack(spacing: 10) {
                        thumbnail(snip)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snip.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text("\(snip.kind.label) · \(RelativeDate.short(snip.savedAt))")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ snip: Snip) -> some View {
        if let media = snip.primaryMedia {
            AsyncThumbnail(source: ImageSource.of(media), maxPixels: 120)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if snip.kind == .tweet {
            AvatarView(author: snip.author, size: 34)
        } else {
            Image(systemName: Theme.symbol(for: snip.kind))
                .foregroundStyle(Theme.tint(for: snip.kind))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Library") {
                dismiss()
                model.showLibrary()
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accentStrong)
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.glass)
                .simultaneousGesture(TapGesture().onEnded { dismiss() })
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.glass)
                .help("Quit Snipper")
        }
    }
}

/// The Spotlight-style quick note panel.
struct QuickNoteView: View {
    let initialText: String
    var onClose: () -> Void

    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var text = ""
    @State private var tags = ""
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Quick note", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tint(for: .note))
                Spacer()
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) { text += (text.isEmpty ? "" : "\n") + s }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.plain)
                .headline(18, weight: .semibold)
                .foregroundStyle(Theme.ink)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write something worth finding later…")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                }
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Theme.ink)
                    .focused($bodyFocused)
            }
            .frame(minHeight: 120)
            HStack(spacing: 10) {
                Image(systemName: "number").foregroundStyle(Theme.inkSecondary)
                TextField("tags, separated by spaces", text: $tags)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                Spacer()
                Text("⌘↩ to save · Esc to close")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentStrong)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(Theme.panel.opacity(0.6)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(10)
        .environment(\.colorScheme, .dark)
        .onAppear {
            text = initialText
            bodyFocused = true
        }
        .onExitCommand(perform: onClose)
    }

    private func save() {
        let tagList = tags.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        if model.addNote(title: title, body: text, tags: tagList) != nil {
            HUD.shared.show("Note saved", symbol: "checkmark.circle.fill")
        }
        onClose()
    }
}
