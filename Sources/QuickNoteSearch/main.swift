import AppKit
import Combine
import SwiftUI

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = NoteIndexStore()
    let user = UserStore.shared
    lazy var model = PopupModel(store: store, user: user)
    private var statusItem: NSStatusItem!
    private var panel: PopupPanel!
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        Pref.registerDefaults()
        setUpStatusItem()
        setUpPanel()
        model.onClose = { [weak self] in self?.hidePopup() }
        model.onOpenSettings = { [weak self] in self?.hidePopup(); self?.showSettings(tab: "index") }

        user.$popupShortcut.combineLatest(user.$noteHotkeys)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadHotkeys() }
            .store(in: &bag)
        ShortcutRecorder.onRecordingChanged = { [weak self] recording in
            recording ? HotKeyCenter.shared.unregisterAll() : self?.reloadHotkeys()
        }

        store.start()
        if !NotesReader.hasAccess { showSettings(tab: "index") }
    }

    // MARK: Hotkeys

    private func reloadHotkeys() {
        guard !ShortcutRecorder.isRecording else { return }
        let hk = HotKeyCenter.shared
        hk.unregisterAll()
        if !hk.register(user.popupShortcut, action: { [weak self] in self?.togglePopup() }) {
            NSLog("QuickNoteSearch: popup hotkey %@ is taken by another app", user.popupShortcut.display)
        }
        for item in user.noteHotkeys {
            hk.register(item.shortcut) { [weak self] in self?.openNote(id: item.noteID) }
        }
        statusItem.menu?.item(withTag: 1)?.title = "Search Notes   \(user.popupShortcut.display)"
    }

    private func openNote(id: String) {
        guard let note = store.index.note(id: id) else { NSSound.beep(); return }
        user.recordOpen(id, tags: [])
        NotesOpener.open(note, storeUUID: store.storeUUID)
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "QuickNoteSearch")
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search Notes", action: #selector(togglePopup), keyEquivalent: "")
        search.tag = 1
        menu.addItem(search)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Rebuild Index", action: #selector(rebuildIndex), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit QuickNoteSearch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    @objc private func openSettings() { showSettings(tab: UserDefaults.standard.string(forKey: "settingsTab") ?? "general") }
    @objc private func rebuildIndex() { store.rebuild() }

    // MARK: Popup

    private func setUpPanel() {
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                           styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let host = NSHostingView(rootView: PopupView(model: model, user: user, store: store))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow, !ShortcutRecorder.isRecording else { return e }
            return self.model.handleKey(e) ? nil : e
        }
    }

    @objc func togglePopup() {
        panel.isVisible ? hidePopup() : showPopup()
    }

    private func showPopup() {
        model.prepareForShow()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .popupDidShow, object: nil)
    }

    private func hidePopup() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Give focus back to the app the user came from (unless Settings is up).
        if settingsWindow?.isVisible != true { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ n: Notification) {
        if (n.object as? NSWindow) === panel, !ShortcutRecorder.isRecording { panel.orderOut(nil) }
    }

    // MARK: Settings

    private func showSettings(tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, user: user)))
            w.title = "QuickNoteSearch Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
