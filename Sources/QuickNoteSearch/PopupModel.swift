import AppKit
import Combine
import Carbon.HIToolbox

final class PopupModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case recent = "Recent", favorites = "Favourites", all = "All Notes"
        var id: String { rawValue }
    }

    @Published var query = "" { didSet { refresh() } }
    @Published var tab: Tab = .recent { didSet { refresh() } }
    @Published private(set) var results: [Note] = []
    @Published var selection = 0
    @Published private(set) var tagSuggestions: [String] = []
    @Published var flash: String?

    let store: NoteIndexStore
    let user: UserStore
    var onClose: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    private var generation = 0
    private var bag: Set<AnyCancellable> = []

    init(store: NoteIndexStore, user: UserStore) {
        self.store = store
        self.user = user
        store.$index.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        user.$favorites.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            if self?.tab == .favorites { self?.refresh() }
        }.store(in: &bag)
    }

    var parsed: Query { Query.parse(query) }
    var selectedNote: Note? { results.indices.contains(selection) ? results[selection] : nil }

    func prepareForShow() {
        let d = UserDefaults.standard
        if d.bool(forKey: Pref.clearOnOpen) { query = "" }
        tab = Tab(rawValue: d.string(forKey: Pref.defaultTab) ?? "") ?? .recent
        refresh()
    }

    func refresh() {
        let index = store.index
        let q = parsed
        tagSuggestions = suggestions(index)
        let keepID = selectedNote?.id
        if q.isEmpty {
            let limit = UserDefaults.standard.integer(forKey: Pref.maxResults)
            switch tab {
            case .recent: results = user.history.compactMap(index.note(id:))
            case .favorites: results = user.favorites.compactMap(index.note(id:))
            case .all: results = Array(index.notes.prefix(max(limit, 20)))
            }
            restoreSelection(keepID)
            return
        }
        let d = UserDefaults.standard
        let opts = SearchOptions(searchBody: d.bool(forKey: Pref.searchBody), typoTolerance: d.bool(forKey: Pref.typoTolerance),
                                 recencyBoost: d.bool(forKey: Pref.recencyBoost), limit: max(10, d.integer(forKey: Pref.maxResults)),
                                 favorites: Set(user.favorites), recent: Set(user.history.prefix(20)))
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .userInteractive).async {
            let found = index.search(q, opts)
            DispatchQueue.main.async {
                guard gen == self.generation else { return } // a newer keystroke won
                self.results = found
                self.restoreSelection(keepID)
            }
        }
    }

    private func restoreSelection(_ id: String?) {
        selection = id.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    }

    // MARK: Tag autocomplete

    /// The `#fragment` being typed at the end of the query, if any.
    private var tagFragment: String? {
        guard let last = query.split(separator: " ", omittingEmptySubsequences: false).last,
              last.hasPrefix("#") || last.hasPrefix("-#") else { return nil }
        let part = last.split(separator: "|", omittingEmptySubsequences: false).last ?? ""
        return Tag.normalize(String(part.drop(while: { $0 == "-" })))
    }

    private func suggestions(_ index: SearchIndex) -> [String] {
        guard let frag = tagFragment else { return [] }
        let known = Set(index.tagCounts.map(\.tag))
        let recent = user.recentTags.filter { known.contains($0) && $0.hasPrefix(frag) }
        let popular = index.tagCounts.map(\.tag).filter { $0.hasPrefix(frag) && !recent.contains($0) }
        return Array((recent + popular).filter { $0 != frag }.prefix(10))
    }

    func acceptSuggestion(_ tag: String) {
        guard let range = query.range(of: "[^#|]*$", options: .regularExpression) else { return }
        query.replaceSubrange(range, with: tag + " ")
        user.useTag(tag)
    }

    /// Chip click: add `#tag`, or remove it if already present.
    func toggleTag(_ tag: String) {
        let token = "#" + tag
        var parts = query.split(separator: " ").map(String.init)
        if parts.contains(token) { parts.removeAll { $0 == token } } else { parts.append(token); user.useTag(tag) }
        query = parts.joined(separator: " ") + (parts.isEmpty ? "" : " ")
    }

    // MARK: Actions

    func open(_ note: Note? = nil) {
        guard let note = note ?? selectedNote else { return }
        user.recordOpen(note.id, tags: parsed.allTags)
        NotesOpener.open(note, storeUUID: store.storeUUID)
        onClose()
    }

    func copy(_ note: Note? = nil) {
        guard let note = note ?? selectedNote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.body, forType: .string)
        show("Copied “\(note.title)”")
    }

    func toggleFavorite(_ note: Note? = nil) {
        guard let note = note ?? selectedNote else { return }
        user.toggleFavorite(note.id)
        show(user.isFavorite(note.id) ? "★ Added to favourites" : "Removed from favourites")
    }

    func saveSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !user.savedSearches.contains(where: { $0.query == q }) else { return }
        user.savedSearches.append(SavedSearch(name: q, query: q))
        show("Bookmarked search “\(q)”")
    }

    private func show(_ message: String) {
        flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.flash == message { self?.flash = nil }
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(0, selection + delta), results.count - 1)
    }

    /// Returns true when the key was consumed.
    func handleKey(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f.contains(.command)
        switch Int(e.keyCode) {
        case kVK_DownArrow: move(1); return true
        case kVK_UpArrow: move(-1); return true
        case kVK_PageDown: move(10); return true
        case kVK_PageUp: move(-10); return true
        case kVK_Return, kVK_ANSI_KeypadEnter: cmd ? copy() : open(); return true
        case kVK_Escape:
            if query.isEmpty { onClose() } else { query = "" }
            return true
        case kVK_Tab:
            guard let s = tagSuggestions.first else { return false }
            acceptSuggestion(s)
            return true
        default: break
        }
        if f.contains(.control), let c = e.charactersIgnoringModifiers {
            if c == "n" { move(1); return true }
            if c == "p" { move(-1); return true }
        }
        guard cmd, let c = e.charactersIgnoringModifiers else { return false }
        switch c {
        case "d": toggleFavorite()
        case "s": saveSearch()
        case "1": tab = .recent; query = ""
        case "2": tab = .favorites; query = ""
        case "3": tab = .all; query = ""
        case ",": onOpenSettings()
        default: return false
        }
        return true
    }
}

enum NotesOpener {
    static func open(_ note: Note, storeUUID: String) {
        // The UUID ends up inside AppleScript source, so only allow UUID characters.
        guard storeUUID.allSatisfy({ $0.isHexDigit || $0 == "-" }), !storeUUID.isEmpty else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
            return
        }
        let script = """
            tell application "Notes"
                show note id "x-coredata://\(storeUUID)/ICNote/p\(note.pk)"
                activate
            end tell
            """
        // Off the main thread: the first call waits on the Automation permission prompt.
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app")) }
            }
        }
    }
}
