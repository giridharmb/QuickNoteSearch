import Foundation
import Carbon.HIToolbox

enum Pref {
    static let searchBody = "searchBody"
    static let typoTolerance = "typoTolerance"
    static let recencyBoost = "recencyBoost"
    static let maxResults = "maxResults"
    static let showPreview = "showPreview"
    static let clearOnOpen = "clearOnOpen"
    static let defaultTab = "defaultTab"
    static let resyncMinutes = "resyncMinutes"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            searchBody: true, typoTolerance: true, recencyBoost: true, maxResults: 100,
            showPreview: true, clearOnOpen: true, defaultTab: "Recent", resyncMinutes: 15,
        ])
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask
    var display: String

    static let defaultPopup = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥Space")
}

struct SavedSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query: String
}

struct NoteHotkey: Codable, Identifiable, Equatable {
    var noteID: String
    var title: String
    var shortcut: Shortcut
    var id: String { noteID }
}

/// Favourites, history, bookmarks and hotkeys; stored in UserDefaults (no note contents).
final class UserStore: ObservableObject {
    static let shared = UserStore()

    @Published var favorites: [String] { didSet { save("favorites", favorites) } }
    @Published var history: [String] { didSet { save("history", history) } }
    @Published var recentTags: [String] { didSet { save("recentTags", recentTags) } }
    @Published var savedSearches: [SavedSearch] { didSet { save("savedSearches", savedSearches) } }
    @Published var noteHotkeys: [NoteHotkey] { didSet { save("noteHotkeys", noteHotkeys) } }
    @Published var popupShortcut: Shortcut { didSet { save("popupShortcut", popupShortcut) } }

    private init() {
        favorites = Self.load("favorites") ?? []
        history = Self.load("history") ?? []
        recentTags = Self.load("recentTags") ?? []
        savedSearches = Self.load("savedSearches") ?? []
        noteHotkeys = Self.load("noteHotkeys") ?? []
        popupShortcut = Self.load("popupShortcut") ?? .defaultPopup
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.insert(id, at: 0) }
    }

    func recordOpen(_ id: String, tags: [String]) {
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        for t in tags.reversed() { useTag(t) }
    }

    func useTag(_ tag: String) {
        recentTags.removeAll { $0 == tag }
        recentTags.insert(tag, at: 0)
        if recentTags.count > 15 { recentTags.removeLast(recentTags.count - 15) }
    }

    func hotkey(for noteID: String) -> Shortcut? { noteHotkeys.first { $0.noteID == noteID }?.shortcut }

    func setHotkey(_ s: Shortcut?, for note: Note) {
        noteHotkeys.removeAll { $0.noteID == note.id }
        guard let s else { return }
        // One shortcut maps to one note.
        noteHotkeys.removeAll { $0.shortcut.keyCode == s.keyCode && $0.shortcut.modifiers == s.modifiers }
        noteHotkeys.append(NoteHotkey(noteID: note.id, title: note.title, shortcut: s))
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
