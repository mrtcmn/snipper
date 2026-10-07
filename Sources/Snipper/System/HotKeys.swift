import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// A keyboard shortcut in Carbon terms (virtual key code + Carbon modifier mask).
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    init(keyCode: Int, modifiers: UInt32) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers
    }

    /// Builds a combo from a key press, or nil if it lacks a ⌃, ⌥ or ⌘ modifier
    /// (function keys may stand alone).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= Self.command }
        if flags.contains(.shift) { mods |= Self.shift }
        if flags.contains(.option) { mods |= Self.option }
        if flags.contains(.control) { mods |= Self.control }
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys[code] != nil
        guard isFunctionKey || mods & (Self.command | Self.option | Self.control) != 0 else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + Self.keyName(Int(keyCode))
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]

    static func keyName(_ code: Int) -> String {
        functionKeys[code] ?? names[code] ?? "Key \(code)"
    }
}

enum HotKeyAction: String, CaseIterable, Codable, Identifiable {
    case captureRegion, captureWindow, captureScreen, captureText
    case quickNote, snipBrowserTab, saveClipboard, pickColor, openLibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureRegion: "Capture area"
        case .captureWindow: "Capture window"
        case .captureScreen: "Capture screen"
        case .captureText: "Capture text (OCR)"
        case .quickNote: "Quick note"
        case .snipBrowserTab: "Snip browser tab"
        case .saveClipboard: "Save clipboard"
        case .pickColor: "Pick color"
        case .openLibrary: "Search library"
        }
    }

    var symbol: String {
        switch self {
        case .captureRegion: "rectangle.dashed"
        case .captureWindow: "macwindow"
        case .captureScreen: "display"
        case .captureText: "text.viewfinder"
        case .quickNote: "square.and.pencil"
        case .snipBrowserTab: "safari"
        case .saveClipboard: "doc.on.clipboard"
        case .pickColor: "eyedropper"
        case .openLibrary: "magnifyingglass"
        }
    }

    var defaultCombo: KeyCombo {
        let ctrlShift = KeyCombo.control | KeyCombo.shift
        switch self {
        case .captureRegion: return KeyCombo(keyCode: kVK_ANSI_4, modifiers: ctrlShift)
        case .captureWindow: return KeyCombo(keyCode: kVK_ANSI_5, modifiers: ctrlShift)
        case .captureScreen: return KeyCombo(keyCode: kVK_ANSI_3, modifiers: ctrlShift)
        case .captureText: return KeyCombo(keyCode: kVK_ANSI_2, modifiers: ctrlShift)
        case .quickNote: return KeyCombo(keyCode: kVK_ANSI_N, modifiers: ctrlShift)
        case .snipBrowserTab: return KeyCombo(keyCode: kVK_ANSI_X, modifiers: ctrlShift)
        case .saveClipboard: return KeyCombo(keyCode: kVK_ANSI_V, modifiers: ctrlShift)
        case .pickColor: return KeyCombo(keyCode: kVK_ANSI_C, modifiers: ctrlShift)
        case .openLibrary: return KeyCombo(keyCode: kVK_Space, modifiers: ctrlShift)
        }
    }
}

/// System-wide shortcuts via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    @ObservationIgnored var handler: ((HotKeyAction) -> Void)?
    private(set) var bindings: [HotKeyAction: KeyCombo] = [:]
    /// Actions whose shortcut another app already owns.
    private(set) var conflicts: Set<HotKeyAction> = []

    @ObservationIgnored private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var suspended = false
    private static let signature: OSType = 0x534E_5052 // "SNPR"

    private init() {}

    /// Loads saved bindings (or defaults) and registers them.
    func configure(saved: Data?) {
        var result: [HotKeyAction: KeyCombo] = [:]
        let decoded = saved.flatMap { try? JSONDecoder().decode([String: KeyCombo?].self, from: $0) } ?? [:]
        for action in HotKeyAction.allCases {
            if let entry = decoded[action.rawValue] {
                if let combo = entry { result[action] = combo } // explicit nil = disabled
            } else {
                result[action] = action.defaultCombo
            }
        }
        bindings = result
        registerAll()
    }

    /// Serialized bindings, including disabled ones, for AppSettings.
    var encoded: Data? {
        var dict: [String: KeyCombo?] = [:]
        for action in HotKeyAction.allCases { dict[action.rawValue] = bindings[action] }
        return try? JSONEncoder().encode(dict)
    }

    func setCombo(_ combo: KeyCombo?, for action: HotKeyAction) {
        if let combo {
            // A combo can only drive one action.
            for (other, existing) in bindings where existing == combo && other != action { bindings[other] = nil }
        }
        bindings[action] = combo
        registerAll()
    }

    func resetToDefaults() {
        bindings = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultCombo) })
        registerAll()
    }

    /// Temporarily releases all shortcuts, e.g. while recording a new one.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = HotKeyAction.allCases.first(where: { Self.id(for: $0) == id }) else { return }
        handler?(action)
    }

    private static func id(for action: HotKeyAction) -> UInt32 {
        UInt32(HotKeyAction.allCases.firstIndex(of: action)! + 1)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &eventHandler)
    }

    private func registerAll() {
        unregisterAll()
        guard !suspended else { return }
        installHandlerIfNeeded()
        conflicts = []
        for (action, combo) in bindings {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.id(for: action))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                conflicts.insert(action)
            }
        }
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}

/// Carbon calls this C function on the main thread for every registered hot key.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    Task { @MainActor in HotKeyCenter.shared.fire(id) }
    return noErr
}

/// A button that records a new shortcut when clicked.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    var onChange: (KeyCombo?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        let combo = HotKeyCenter.shared.bindings[action]
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Type shortcut…" : (combo?.display ?? "Record"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 92)
            }
            .buttonStyle(.glass)
            .tint(isRecording ? Theme.accent : nil)

            if combo != nil && !isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
            if HotKeyCenter.shared.conflicts.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Another app already uses this shortcut.")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                onChange(nil)
                stop()
            default:
                guard let combo = KeyCombo(event: event) else { NSSound.beep(); return nil }
                onChange(combo)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { HotKeyCenter.shared.resume() }
        isRecording = false
    }
}
