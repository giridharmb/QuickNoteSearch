import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: NoteIndexStore
    @ObservedObject var user: UserStore
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(user: user).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            SearchSettings().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag("search")
            HotkeySettings(store: store, user: user).tabItem { Label("Note Hotkeys", systemImage: "keyboard") }.tag("hotkeys")
            LibrarySettings(store: store, user: user).tabItem { Label("Library", systemImage: "star") }.tag("library")
            IndexSettings(store: store).tabItem { Label("Index", systemImage: "externaldrive.badge.checkmark") }.tag("index")
        }
        .frame(width: 600, height: 470)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var user: UserStore
    @AppStorage(Pref.showPreview) private var showPreview = true
    @AppStorage(Pref.clearOnOpen) private var clearOnOpen = true
    @AppStorage(Pref.defaultTab) private var defaultTab = "Recent"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch QuickNoteSearch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Popup") {
                LabeledContent("Show popup hotkey") {
                    ShortcutRecorder(shortcut: Binding(get: { user.popupShortcut },
                                                       set: { user.popupShortcut = $0 ?? .defaultPopup }))
                }
                Toggle("Show preview pane", isOn: $showPreview)
                Toggle("Clear search each time the popup opens", isOn: $clearOnOpen)
                Picker("List shown with an empty search", selection: $defaultTab) {
                    ForEach(PopupModel.Tab.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            Section("Keys in the popup") {
                Text("↑ ↓ / ⌃N ⌃P move · ↩ open in Notes · ⌘↩ copy text · ⇥ complete #tag · ⌘D favourite · ⌘S bookmark search · ⌘1/2/3 Recent/Favourites/All · ⎋ clear/close · ⌘, settings")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SearchSettings: View {
    @AppStorage(Pref.searchBody) private var searchBody = true
    @AppStorage(Pref.typoTolerance) private var typos = true
    @AppStorage(Pref.recencyBoost) private var recency = true
    @AppStorage(Pref.maxResults) private var maxResults = 100

    var body: some View {
        Form {
            Section("Matching") {
                Toggle("Search note contents (not just titles)", isOn: $searchBody)
                Toggle("Tolerate typos (one wrong letter in words of 4+ letters)", isOn: $typos)
                Toggle("Rank recently edited notes higher", isOn: $recency)
                Stepper("Maximum results: \(maxResults)", value: $maxResults, in: 20...1000, step: 20)
            }
            Section("Query syntax") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("`groc lst` — fuzzy words, all must match (title, folder or body)")
                    Text("`#work #urgent` — notes with both tags")
                    Text("`#work|#home` — notes with either tag")
                    Text("`-#archive` — exclude a tag")
                    Text("`#wor` — unknown tags match by prefix; press ⇥ to complete")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeySettings: View {
    @ObservedObject var store: NoteIndexStore
    @ObservedObject var user: UserStore
    @State private var search = ""

    var body: some View {
        Form {
            Section("Assigned") {
                if user.noteHotkeys.isEmpty {
                    Text("No note hotkeys yet. Assign one here or from the popup’s preview pane.").foregroundStyle(.secondary)
                }
                ForEach(user.noteHotkeys) { hk in
                    HStack {
                        Text(store.index.note(id: hk.noteID)?.title ?? hk.title).lineLimit(1)
                        if store.index.note(id: hk.noteID) == nil && store.status.noteCount > 0 {
                            Text("(note missing)").font(.caption).foregroundStyle(.red)
                        }
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(
                            get: { hk.shortcut },
                            set: { s in
                                if let i = user.noteHotkeys.firstIndex(where: { $0.noteID == hk.noteID }) {
                                    if let s { user.noteHotkeys[i].shortcut = s } else { user.noteHotkeys.remove(at: i) }
                                }
                            }))
                    }
                }
            }
            Section("Add") {
                TextField("Find a note…", text: $search)
                let matches = search.isEmpty ? [] : store.index.search(.parse(search), SearchOptions(limit: 6))
                ForEach(matches) { note in
                    HStack {
                        Text(note.title).lineLimit(1)
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(get: { user.hotkey(for: note.id) },
                                                           set: { user.setHotkey($0, for: note) }))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LibrarySettings: View {
    @ObservedObject var store: NoteIndexStore
    @ObservedObject var user: UserStore

    var body: some View {
        Form {
            Section("Favourite notes") {
                if user.favorites.isEmpty { Text("Press ⌘D on a note in the popup.").foregroundStyle(.secondary) }
                ForEach(user.favorites, id: \.self) { id in
                    HStack {
                        Text(store.index.note(id: id)?.title ?? "(not found)").lineLimit(1)
                        Spacer()
                        Button("Remove") { user.toggleFavorite(id) }.buttonStyle(.borderless)
                    }
                }
                .onMove { user.favorites.move(fromOffsets: $0, toOffset: $1) }
            }
            Section("Bookmarked searches") {
                if user.savedSearches.isEmpty { Text("Press ⌘S in the popup to bookmark a search.").foregroundStyle(.secondary) }
                ForEach($user.savedSearches) { $s in
                    HStack {
                        TextField("Name", text: $s.name).frame(maxWidth: 160)
                        Text(s.query).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Remove") { user.savedSearches.removeAll { $0.id == s.id } }.buttonStyle(.borderless)
                    }
                }
                .onMove { user.savedSearches.move(fromOffsets: $0, toOffset: $1) }
            }
            Section("History") {
                HStack {
                    Button("Clear recently opened (\(user.history.count))") { user.history = [] }
                    Button("Clear recent hashtags (\(user.recentTags.count))") { user.recentTags = [] }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct IndexSettings: View {
    @ObservedObject var store: NoteIndexStore
    @AppStorage(Pref.resyncMinutes) private var resync = 15

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    if store.status.needsAccess {
                        Label("Not granted", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    } else {
                        Label("Granted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
                if store.status.needsAccess {
                    Text("Apple Notes keeps its database in a protected folder. Open Privacy & Security → Full Disk Access, add QuickNoteSearch, then press Check Again.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Full Disk Access Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        Button("Check Again") { store.start() }
                    }
                }
                Text("Opening a note asks once for permission to control Notes (Automation).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Index") {
                LabeledContent("Notes indexed", value: "\(store.status.noteCount)")
                LabeledContent("Hashtags", value: "\(store.status.tagCount)")
                LabeledContent("Last sync") {
                    if let d = store.status.lastSync {
                        Text("\(d.formatted(date: .omitted, time: .standard)) (\(Int(store.status.lastDuration * 1000)) ms)")
                    } else { Text("—") }
                }
                if let err = store.status.error { Text(err).foregroundStyle(.red).font(.callout) }
                Picker("Full re-check every", selection: $resync) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .onChange(of: resync) { store.restartTimer() }
                Button("Rebuild Index Now") { store.rebuild() }
                Text("Changes in Notes are picked up within ~2 seconds via file-system events; only changed notes are re-read. The index lives in memory only and is never written to disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
