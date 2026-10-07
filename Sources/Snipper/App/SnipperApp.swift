import AppKit
import SnipperCore
import SwiftUI

@main
struct SnipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The library window is managed in AppKit (LibraryWindowController) so it can be
        // reopened from global shortcuts and the menu bar.
        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }
        .commands {
            SnipperCommands(model: AppModel.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await AppModel.shared.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showLibrary()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                Task { await AppModel.shared.importURLs([url]) }
            } else {
                AppModel.shared.handle(url: url)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Let queued database writes finish first.
        Task {
            await AppModel.shared.library.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SnipperCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { model.newNote() }
                .keyboardShortcut("n")
            Button("Show Library") { model.showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Import…") { model.importFiles() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import X Bookmarks…") { model.importXBookmarksInBrowser() }
            Menu("Export") {
                Button("Markdown…") { model.exportMarkdown(model.library.snips) }
                Button("JSON…") { model.exportJSON(model.library.snips) }
            }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Save Clipboard to Snipper") { model.saveClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandMenu("Capture") {
            ForEach([HotKeyAction.captureRegion, .captureWindow, .captureScreen, .captureText, .snipBrowserTab, .pickColor], id: \.self) { action in
                Button(action.title) { model.perform(action) }
            }
        }

        CommandGroup(before: .toolbar) {
            Button("Atlas") { model.settings.viewMode = .atlas }
                .keyboardShortcut("1")
            Button("Grid") { model.settings.viewMode = .grid }
                .keyboardShortcut("2")
            Divider()
            Button("Search") { model.showLibrary(focusSearch: true) }
                .keyboardShortcut("f")
            Divider()
        }
    }
}
