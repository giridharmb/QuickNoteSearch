import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide hotkeys via Carbon (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeyCenter.shared.actions[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
        actions = [:]
    }

    /// Returns false when another app already owns the combination.
    @discardableResult
    func register(_ s: Shortcut, action: @escaping () -> Void) -> Bool {
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: OSType(0x514E_5348), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }
}

/// Click, then press a key combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var placeholder = "Record Hotkey"
    @State private var recording = false
    @State private var monitor: Any?

    /// Global hotkeys are suspended while recording so the combo reaches us.
    static var isRecording = false
    static var onRecordingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Type shortcut…" : (shortcut?.display ?? placeholder))
                    .frame(minWidth: 90)
                    .foregroundStyle(recording ? Color.accentColor : (shortcut == nil ? .secondary : .primary))
            }
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(shortcut?.display ?? "none")")
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove hotkey").accessibilityLabel("Remove hotkey")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        Self.isRecording = true
        Self.onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete, kVK_ForwardDelete: shortcut = nil; stop()
            default:
                guard let s = Self.shortcut(from: e) else { NSSound.beep(); return nil }
                shortcut = s
                stop()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        Self.isRecording = false
        Self.onRecordingChanged(false)
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    static func shortcut(from e: NSEvent) -> Shortcut? {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(e.keyCode)
        let isFn = functionKeys[code] != nil
        // Without ⌘/⌥/⌃ a global hotkey would swallow normal typing.
        guard isFn || !f.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var carbon = 0, text = ""
        if f.contains(.control) { carbon |= controlKey; text += "⌃" }
        if f.contains(.option) { carbon |= optionKey; text += "⌥" }
        if f.contains(.shift) { carbon |= shiftKey; text += "⇧" }
        if f.contains(.command) { carbon |= cmdKey; text += "⌘" }
        let key = functionKeys[code] ?? namedKeys[code] ?? e.charactersIgnoringModifiers?.uppercased() ?? "?"
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(carbon), display: text + key)
    }
}
