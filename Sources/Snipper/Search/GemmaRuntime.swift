import Foundation
import SnipperCore
import WebKit

/// Hosts `gemma-runtime.html` (Transformers.js + EmbeddingGemma 2) in a hidden WKWebView.
///
/// The page is loaded with an https base URL so it is a secure context, which WebGPU and
/// the Cache API (where Transformers.js keeps the model files) require. Model weights are
/// downloaded once from Hugging Face and then served from that cache.
@MainActor
final class GemmaRuntime {
    enum Event {
        case progress(label: String, fraction: Double?)
        case ready(device: String, dtype: String)
        case failed(String)
    }

    enum RuntimeError: LocalizedError {
        case missingPage
        case bootTimeout
        case badResponse
        case script(String)

        var errorDescription: String? {
            switch self {
            case .missingPage: "The embedding runtime page is missing from the app bundle."
            case .bootTimeout: "The embedding runtime did not start. Check your internet connection for the first download."
            case .badResponse: "The embedding runtime returned an unexpected result."
            case .script(let message): message
            }
        }
    }

    struct Status {
        var device: String
        var dtype: String
        var vision: Bool
    }

    /// A dedicated, persistent website data store, so the model cache survives relaunches
    /// and can be cleared without touching anything else.
    static let dataStoreID = UUID(uuidString: "5E1F7A4C-2B8D-4C61-9A0E-6B3D2F1C8E57")!
    private static let baseURL = URL(string: "https://localhost/snipper-gemma/")!

    var onEvent: ((Event) -> Void)?
    private(set) var status: Status?

    private var webView: WKWebView?
    private var messageProxy: MessageProxy?
    private var booted = false
    private var bootWaiters: [CheckedContinuation<Void, Error>] = []

    // MARK: Lifecycle

    /// Loads the model. Safe to call repeatedly; later calls return the cached status.
    @discardableResult
    func start(vision: Bool, preferGPU: Bool) async throws -> Status {
        if let status { return status }
        try await boot()
        let result = try await call(
            "return await window.snipperGemma.init(options);",
            ["options": ["vision": vision, "preferGPU": preferGPU]]
        )
        guard let dict = result as? [String: Any], let device = dict["device"] as? String else {
            throw RuntimeError.badResponse
        }
        let status = Status(device: device, dtype: dict["dtype"] as? String ?? "q4", vision: dict["vision"] as? Bool ?? vision)
        self.status = status
        return status
    }

    func stop() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "snipper")
        webView?.stopLoading()
        webView = nil
        messageProxy = nil
        booted = false
        status = nil
        failBootWaiters(RuntimeError.bootTimeout)
    }

    /// Removes downloaded model files.
    static func clearCache() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: dataStoreID) { _ in continuation.resume() }
        }
    }

    // MARK: Embedding

    /// Embeds texts that already carry their task prefix.
    func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let result = try await call("return await window.snipperGemma.embedTexts(texts);", ["texts": texts])
        guard let encoded = result as? [String], encoded.count == texts.count else { throw RuntimeError.badResponse }
        return try encoded.map(Self.decode)
    }

    /// Embeds one input of text with `<|image|>` placeholders plus JPEG images.
    func embed(text: String?, images: [Data], visionBudget: Int = 280) async throws -> [Float] {
        let result = try await call(
            "return await window.snipperGemma.embedMixed(input);",
            ["input": [
                "text": text ?? "",
                "images": images.map { $0.base64EncodedString() },
                "budget": visionBudget,
            ] as [String: Any]]
        )
        guard let encoded = result as? String else { throw RuntimeError.badResponse }
        return try Self.decode(encoded)
    }

    // MARK: Internals

    private func boot() async throws {
        if booted { return }
        if webView == nil { try createWebView() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bootWaiters.append(continuation)
        }
    }

    private func createWebView() throws {
        guard let html = AppResources.string("gemma-runtime", "html") else { throw RuntimeError.missingPage }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        // Keep running at full speed while hidden.
        config.preferences.inactiveSchedulingPolicy = .none
        let proxy = MessageProxy { [weak self] body in self?.handle(body) }
        config.userContentController.add(proxy, name: "snipper")

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: config)
        #if DEBUG
        view.isInspectable = true
        #endif
        webView = view
        messageProxy = proxy
        view.loadHTMLString(html, baseURL: Self.baseURL)

        // The page posts "boot" as soon as its module runs; give up if it never does.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !self.booted else { return }
            self.failBootWaiters(RuntimeError.bootTimeout)
        }
    }

    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        guard let webView else { throw RuntimeError.bootTimeout }
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            let nsError = error as NSError
            let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? nsError.localizedDescription
            throw RuntimeError.script(message)
        }
    }

    private func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "boot":
            booted = true
            let waiters = bootWaiters
            bootWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case "progress":
            let label = message["label"] as? String ?? "Loading"
            var fraction = message["fraction"] as? Double
            // Transformers.js reports totals only for files it has started; stay monotonic.
            if let loaded = message["loaded"] as? Double, loaded > 0 {
                let expected = max(message["total"] as? Double ?? 0, 316_000_000)
                fraction = min(1, loaded / expected)
            }
            onEvent?(.progress(label: label, fraction: fraction))
        case "ready":
            onEvent?(.ready(device: message["device"] as? String ?? "webgpu", dtype: message["dtype"] as? String ?? "q4"))
        case "failed":
            onEvent?(.failed(message["message"] as? String ?? "Unknown error"))
        case "log":
            logger.debug("Gemma runtime: \(message["message"] as? String ?? "", privacy: .public)")
        default:
            break
        }
    }

    private func failBootWaiters(_ error: Error) {
        let waiters = bootWaiters
        bootWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private static func decode(_ base64: String) throws -> [Float] {
        guard let data = Data(base64Encoded: base64), data.count % 4 == 0, !data.isEmpty else {
            throw RuntimeError.badResponse
        }
        return VectorMath.decode(data)
    }
}

/// Receives script messages without the web view retaining the runtime.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    private let handler: @MainActor (Any) -> Void

    init(handler: @escaping @MainActor (Any) -> Void) {
        self.handler = handler
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers script messages on the main thread.
        MainActor.assumeIsolated { handler(message.body) }
    }
}
