import Foundation
import Observation

enum SearchEngineChoice: String, CaseIterable, Identifiable {
    /// EmbeddingGemma 2 in a hidden WKWebView (WebGPU). Text and images.
    case gemma
    /// Apple's on-device sentence embeddings. Text only, no download.
    case apple
    /// Keyword search only.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemma: "EmbeddingGemma 2 (on-device, text + images)"
        case .apple: "Apple Natural Language (built-in, text only)"
        case .off: "Keywords only"
        }
    }
}

enum AfterCaptureAction: String, CaseIterable, Identifiable {
    case saveAndCopy, save, copy, annotate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .saveAndCopy: "Save to library and copy"
        case .save: "Save to library"
        case .copy: "Copy to clipboard only"
        case .annotate: "Open the annotation editor"
        }
    }
}

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case atlas, grid
    var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var searchEngine: SearchEngineChoice { didSet { defaults.set(searchEngine.rawValue, forKey: Keys.searchEngine) } }
    var indexPostImages: Bool { didSet { defaults.set(indexPostImages, forKey: Keys.indexPostImages) } }
    var downloadPostMedia: Bool { didSet { defaults.set(downloadPostMedia, forKey: Keys.downloadPostMedia) } }
    var afterCapture: AfterCaptureAction { didSet { defaults.set(afterCapture.rawValue, forKey: Keys.afterCapture) } }
    var showCapturePreview: Bool { didSet { defaults.set(showCapturePreview, forKey: Keys.showCapturePreview) } }
    var playCaptureSound: Bool { didSet { defaults.set(playCaptureSound, forKey: Keys.playCaptureSound) } }
    var saveTextCaptures: Bool { didSet { defaults.set(saveTextCaptures, forKey: Keys.saveTextCaptures) } }
    var viewMode: LibraryViewMode { didSet { defaults.set(viewMode.rawValue, forKey: Keys.viewMode) } }
    var serverPort: Int { didSet { defaults.set(serverPort, forKey: Keys.serverPort) } }
    var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Keys.showInDock) } }
    var didOnboard: Bool { didSet { defaults.set(didOnboard, forKey: Keys.didOnboard) } }
    var hotKeyData: Data? { didSet { defaults.set(hotKeyData, forKey: Keys.hotKeys) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.searchEngine: SearchEngineChoice.gemma.rawValue,
            Keys.indexPostImages: true,
            Keys.downloadPostMedia: true,
            Keys.afterCapture: AfterCaptureAction.saveAndCopy.rawValue,
            Keys.showCapturePreview: true,
            Keys.playCaptureSound: true,
            Keys.saveTextCaptures: true,
            Keys.viewMode: LibraryViewMode.atlas.rawValue,
            Keys.serverPort: 47615,
            Keys.showInDock: true,
            Keys.didOnboard: false,
        ])
        searchEngine = SearchEngineChoice(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .gemma
        indexPostImages = defaults.bool(forKey: Keys.indexPostImages)
        downloadPostMedia = defaults.bool(forKey: Keys.downloadPostMedia)
        afterCapture = AfterCaptureAction(rawValue: defaults.string(forKey: Keys.afterCapture) ?? "") ?? .saveAndCopy
        showCapturePreview = defaults.bool(forKey: Keys.showCapturePreview)
        playCaptureSound = defaults.bool(forKey: Keys.playCaptureSound)
        saveTextCaptures = defaults.bool(forKey: Keys.saveTextCaptures)
        viewMode = LibraryViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .atlas
        let port = defaults.integer(forKey: Keys.serverPort)
        serverPort = (1024...65535).contains(port) ? port : 47615
        showInDock = defaults.bool(forKey: Keys.showInDock)
        didOnboard = defaults.bool(forKey: Keys.didOnboard)
        hotKeyData = defaults.data(forKey: Keys.hotKeys)
    }

    private enum Keys {
        static let searchEngine = "searchEngine"
        static let indexPostImages = "indexPostImages"
        static let downloadPostMedia = "downloadPostMedia"
        static let afterCapture = "afterCapture"
        static let showCapturePreview = "showCapturePreview"
        static let playCaptureSound = "playCaptureSound"
        static let saveTextCaptures = "saveTextCaptures"
        static let viewMode = "viewMode"
        static let serverPort = "serverPort"
        static let showInDock = "showInDock"
        static let didOnboard = "didOnboard"
        static let hotKeys = "hotKeys"
    }
}
