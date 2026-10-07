import AppKit
import SnipperCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettings().tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }
            SearchSettings().tabItem { Label("Search", systemImage: "sparkle.magnifyingglass") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 600)
        .frame(minHeight: 440)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Open Snipper at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
                Toggle("Show in Dock", isOn: $settings.showInDock)
                    .onChange(of: settings.showInDock) { _, _ in model.applyDockPolicy() }
                Picker("Library layout", selection: $settings.viewMode) {
                    Text("Atlas").tag(LibraryViewMode.atlas)
                    Text("Grid").tag(LibraryViewMode.grid)
                }
            }
            Section("Library") {
                LabeledContent("Snips", value: model.library.snips.count.formatted())
                LabeledContent("Location") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.root]) }
                }
                Toggle("Keep copies of post images for offline use", isOn: $settings.downloadPostMedia)
                HStack {
                    Button("Import…") { model.importFiles() }
                    Button("Export as Markdown…") { model.exportMarkdown(model.library.snips) }
                    Button("Export as JSON…") { model.exportJSON(model.library.snips) }
                }
            }
            Section {
                Button("Show Welcome Guide") {
                    model.showLibrary()
                    model.showOnboarding = true
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptureSettings: View {
    @Environment(AppModel.self) private var model
    @State private var permission = ScreenCapturePermission.isGranted

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("After capturing an area", selection: $settings.afterCapture) {
                    ForEach(AfterCaptureAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show a preview with quick actions", isOn: $settings.showCapturePreview)
                Toggle("Play a sound", isOn: $settings.playCaptureSound)
                Toggle("Save text captures (OCR) to the library", isOn: $settings.saveTextCaptures)
            }
            Section("Permission") {
                HStack {
                    Image(systemName: permission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permission ? .green : .yellow)
                    Text(permission ? "Screen Recording is allowed." : "Screen Recording is needed for screenshots.")
                    Spacer()
                    if !permission {
                        Button("Allow…") {
                            ScreenCapturePermission.request()
                            ScreenCapturePermission.openSystemSettings()
                        }
                    }
                }
            }
            Section("While selecting") {
                Text("Drag to select · click a window to select it · Space toggles window mode · Shift keeps a square · arrow keys nudge (⌥ resizes) · Return saves · S save · C copy · A annotate · T copy text · P pin · Esc cancels")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permission = ScreenCapturePermission.isGranted }
    }
}

private struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action) { combo in
                            HotKeyCenter.shared.setCombo(combo, for: action)
                            model.settings.hotKeyData = HotKeyCenter.shared.encoded
                        }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            } footer: {
                Text("Shortcuts work everywhere. Click one, then press the new keys; Delete removes it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") {
                    HotKeyCenter.shared.resetToDefaults()
                    model.settings.hotKeyData = HotKeyCenter.shared.encoded
                }
            }
            Section("Services") {
                Text("Select text, a link or an image in any app and choose Services › Save to Snipper. Assign it a key in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SearchSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Semantic search", selection: $settings.searchEngine) {
                    ForEach(SearchEngineChoice.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.searchEngine) { _, _ in model.searchEngineChanged() }
                Toggle("Include post images in the index", isOn: $settings.indexPostImages)
                    .onChange(of: settings.indexPostImages) { _, _ in model.index.scheduleIndexing(after: 0) }
                    .disabled(settings.searchEngine != .gemma)
            } footer: {
                Text("EmbeddingGemma 2 runs entirely on this Mac with WebGPU. It understands text and images in 100+ languages, so you can search screenshots by what they show. The first start downloads about 300 MB from Hugging Face.")
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Engine", value: model.index.engineName)
                LabeledContent("State", value: stateText)
                LabeledContent("Indexed", value: "\(model.index.embeddedCount.formatted()) of \(model.library.snips.count.formatted())")
                if let notice = model.index.notice {
                    Text(notice).font(.callout).foregroundStyle(.yellow)
                }
                HStack {
                    Button("Rebuild Index") { Task { await model.index.rebuild() } }
                        .disabled(!model.index.isReady)
                    Button("Retry") { model.searchEngineChanged() }
                    Spacer()
                    Button("Delete Downloaded Model…", role: .destructive) { confirmClear = true }
                }
            }
            Section("Search tips") {
                Text("Type naturally: “a chart about revenue”, “cat videos”, “that thread about SwiftUI performance”. Drop an image on the search bar to find similar things. Filters: from:handle  tag:name  type:post|screenshot|note|link|image|clip  is:fav  \"exact phrase\"")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the downloaded EmbeddingGemma files?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) { Task { await model.index.clearDownloadedModel() } }
        } message: {
            Text("They will be downloaded again the next time semantic search starts.")
        }
    }

    private var stateText: String {
        switch model.index.state {
        case .off: "Off"
        case .ready: model.index.isIndexing ? "Indexing (\(model.index.pendingCount) left)" : "Ready"
        case .preparing(let label, let progress): progress.map { "\(label) \(Int($0 * 100))%" } ?? label
        case .failed(let message): "Unavailable: \(message)"
        }
    }
}

private struct BrowserSettings: View {
    @Environment(AppModel.self) private var model
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install the extension in Chrome, Arc, Brave, Edge, Vivaldi or any Chromium browser:")
                    Text("1. Open chrome://extensions (or arc://extensions, brave://extensions…)\n2. Turn on Developer mode\n3. Click Load unpacked and choose the extension folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Show Extension Folder") { model.revealExtensionFolder() }
                        Button("Copy chrome://extensions") { Pasteboard.copy(text: "chrome://extensions") }
                    }
                }
            } header: {
                Text("Browser extension")
            } footer: {
                Text("The extension adds a Snip button to every post on X, imports all your bookmarks, and saves pages, selections and images from the right-click menu.")
                    .foregroundStyle(.secondary)
            }
            Section("Connection") {
                LabeledContent("Local server", value: serverText)
                LabeledContent("Last contact", value: model.lastExtensionContact.map { RelativeDate.short($0) } ?? "never")
                HStack {
                    TextField("Port", text: $portText)
                        .frame(width: 90)
                    Button("Apply") {
                        if let port = Int(portText), (1024...65535).contains(port) {
                            model.settings.serverPort = port
                            model.restartServer()
                        }
                    }
                    Spacer()
                    Text("Change it in the extension's popup too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Without the extension") {
                Text("Press ⌃⇧X in any browser to save the current tab. Posts on X are saved with their text, images and author. The first time, macOS asks to let Snipper control the browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Import X Bookmarks…") { model.importXBookmarksInBrowser() }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(model.settings.serverPort) }
    }

    private var serverText: String {
        switch model.serverState {
        case .running(let port): "Listening on 127.0.0.1:\(port)"
        case .stopped: "Stopped"
        case .failed(let message): "Error: \(message)"
        }
    }
}
