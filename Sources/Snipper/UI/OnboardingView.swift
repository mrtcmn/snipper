import AppKit
import Combine
import SwiftUI

/// First-run guide: permissions, the browser extension and on-device search.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var screenAllowed = ScreenCapturePermission.isGranted

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Text("Welcome to ").headline(30, weight: .regular).foregroundStyle(Color(hex: 0xBDBDBD))
                        Wordmark(height: 26).foregroundStyle(Theme.ink)
                    }
                    Text("Save posts, screenshots, notes and links — then find them by meaning, privately on your Mac.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkSecondary)
                }

                step(
                    number: 1,
                    title: "Let Stash capture the screen",
                    detail: "Needed for area, window and text (OCR) captures. Press ⌃⇧4 any time.",
                    done: screenAllowed
                ) {
                    Button(screenAllowed ? "Allowed" : "Allow Screen Recording") {
                        if !ScreenCapturePermission.request() { ScreenCapturePermission.openSystemSettings() }
                        screenAllowed = ScreenCapturePermission.isGranted
                    }
                    .disabled(screenAllowed)
                }

                step(
                    number: 2,
                    title: "Add the browser extension",
                    detail: "In Chrome, Arc, Brave or Edge open the extensions page, enable Developer mode, then Load unpacked → the Stash extension folder. You get a Snip button on every post and one-click bookmark import.",
                    done: model.lastExtensionContact != nil
                ) {
                    Button("Show Extension Folder") { model.revealExtensionFolder() }
                }

                step(
                    number: 3,
                    title: "Help improve Stash (optional)",
                    detail: "Share anonymous usage counts, such as how often you capture. Stash never sends your snips, URLs, titles or searches. Change this any time in Settings.",
                    done: model.settings.shareUsageData
                ) {
                    @Bindable var settings = model.settings
                    Toggle("Share anonymous usage data", isOn: $settings.shareUsageData)
                }

                step(
                    number: 4,
                    title: "Choose how search works",
                    detail: "EmbeddingGemma 2 understands text and images in 100+ languages and runs fully on-device with WebGPU (one-time ≈300 MB download). Apple's built-in model is text-only but needs no download.",
                    done: false
                ) {
                    HStack(spacing: 8) {
                        Button("Use EmbeddingGemma 2") { finish(with: .gemma) }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.accentStrong)
                        Button("Apple built-in") { finish(with: .apple) }
                        Button("Keywords only") { finish(with: .off) }
                    }
                }
            }
            .buttonStyle(.glass)
            .padding(30)
            .frame(width: 620)
            .glassEffect(.regular.tint(Theme.panel.opacity(0.65)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAllowed = ScreenCapturePermission.isGranted
        }
    }

    private func finish(with engine: SearchEngineChoice) {
        model.settings.searchEngine = engine
        withAnimation(.easeOut(duration: 0.25)) { model.finishOnboarding() }
    }

    private func step<Actions: View>(number: Int, title: String, detail: String, done: Bool, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color(hex: 0x7EE0B5) : Theme.accent.opacity(0.18))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                actions().padding(.top, 4)
            }
        }
    }
}
