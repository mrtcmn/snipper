import Foundation

/// Anonymous usage events for PostHog (EU Cloud), sent only when the user opts in.
///
/// Privacy rules: events carry an event name, enum values and counts only — never a URL,
/// title, note text, search query or file name. The ID is a random UUID that is not tied
/// to the user, the Mac or an account, and turning sharing off deletes it.
@MainActor
enum Analytics {
    private static let endpoint = URL(string: "https://eu.i.posthog.com/i/v0/e/")!
    // Project API keys are public by design (write-only, used in every PostHog client).
    private static let apiKey = "phc_Bik6QbJiEZmpXCnwfuSw9UReCqb5Y7KfYtbzAZjZfEEP"
    private static let idKey = "analyticsID"

    static var isEnabled: Bool { AppModel.shared.settings.shareUsageData }

    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        #if DEBUG
        return
        #else
        guard isEnabled else { return }
        var props = properties
        props["$geoip_disable"] = true
        props["$lib"] = "stash-macos"
        props["$os"] = "macOS"
        props["$os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        props["$app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let body: [String: Any] = [
            "api_key": apiKey,
            "event": event,
            "distinct_id": distinctID,
            "properties": props,
            "timestamp": ISO8601DateFormatter().string(from: .now),
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // ponytail: fire and forget, an event lost while offline is acceptable for usage stats.
        URLSession.shared.dataTask(with: request).resume()
        #endif
    }

    /// Called when the user turns sharing off, so a later opt-in starts as a new anonymous user.
    static func forgetID() {
        UserDefaults.standard.removeObject(forKey: idKey)
    }

    private static var distinctID: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }
}
