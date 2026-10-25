import SwiftUI

struct PopupView: View {
    @ObservedObject var model: PopupModel
    @ObservedObject var user: UserStore
    @ObservedObject var store: NoteIndexStore
    @AppStorage(Pref.showPreview) private var showPreview = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            chips
            Divider()
            if model.query.isEmpty {
                Picker("", selection: $model.tab) {
                    ForEach(PopupModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.vertical, 6)
            }
            HStack(spacing: 0) {
                resultList.frame(width: showPreview ? 420 : nil)
                if showPreview {
                    Divider()
                    NotePreview(note: model.selectedNote, terms: model.parsed.terms, model: model, user: user)
                }
            }
            Divider()
            footer
        }
        .frame(width: showPreview ? 1100 : 680, height: 700)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .popupDidShow)) { _ in searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search notes   #tag   #a|#b   -#exclude", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)
                .accessibilityLabel("Search notes")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                Button { model.saveSearch() } label: { Image(systemName: "bookmark") }
                    .buttonStyle(.borderless).help("Bookmark this search (⌘S)").accessibilityLabel("Bookmark search")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder private var chips: some View {
        let suggestions = model.tagSuggestions
        let recentTags = user.recentTags.filter { tag in store.index.tagCounts.contains { $0.tag == tag } }
        if !suggestions.isEmpty || !user.savedSearches.isEmpty || !recentTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if !suggestions.isEmpty {
                        Text("⇥").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { tag in
                            Chip(text: "#" + tag, systemImage: nil, tint: .orange) { model.acceptSuggestion(tag) }
                        }
                    } else {
                        ForEach(user.savedSearches) { s in
                            Chip(text: s.name, systemImage: "bookmark.fill", tint: .blue) { model.query = s.query + " " }
                        }
                        if !user.savedSearches.isEmpty && !recentTags.isEmpty { Divider().frame(height: 16) }
                        ForEach(recentTags, id: \.self) { tag in
                            Chip(text: "#" + tag, systemImage: nil, tint: .orange,
                                 active: model.parsed.allTags.contains(tag)) { model.toggleTag(tag) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { i, note in
                        ResultRow(note: note, terms: model.parsed.terms, selected: i == model.selection,
                                  favorite: user.isFavorite(note.id), hotkey: user.hotkey(for: note.id)?.display)
                            .id(note.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(note) }
                            .simultaneousGesture(TapGesture().onEnded { model.selection = i })
                    }
                }
                .padding(6)
            }
            .overlay { if model.results.isEmpty { emptyState } }
            .onChange(of: model.selection) { _, i in
                if model.results.indices.contains(i) { proxy.scrollTo(model.results[i].id) }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.status.needsAccess ? "lock.shield" : "note.text").font(.largeTitle).foregroundStyle(.tertiary)
            if store.status.needsAccess {
                Text("Full Disk Access needed to read Notes").font(.headline)
                Button("Open Settings") { model.onOpenSettings() }
            } else if !model.query.isEmpty {
                Text("No matching notes").foregroundStyle(.secondary)
            } else {
                Text(model.tab == .favorites ? "No favourites yet — press ⌘D on a note"
                     : model.tab == .recent ? "Notes you open appear here" : "Indexing…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let flash = model.flash {
                Text(flash).foregroundStyle(.primary)
            } else if let err = store.status.error {
                Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(1)
            } else {
                Text("\(store.status.noteCount) notes · \(store.status.tagCount) tags · \(model.results.count) shown")
            }
            Spacer()
            Group {
                Text("↩ open"); Text("⌘↩ copy"); Text("⌘D favourite"); Text("⌘S bookmark"); Text("⌘1-3 tabs")
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}

struct Chip: View {
    let text: String
    let systemImage: String?
    let tint: Color
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(text).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(active ? 0.45 : 0.15)))
            .overlay(Capsule().strokeBorder(tint.opacity(active ? 0.9 : 0.3)))
        }
        .buttonStyle(.plain)
    }
}

struct ResultRow: View {
    let note: Note
    let terms: [String]
    let selected: Bool
    let favorite: Bool
    let hotkey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.locked { Image(systemName: "lock.fill").imageScale(.small).foregroundStyle(.secondary) }
                Text(note.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let hotkey { Text(hotkey).font(.caption2.monospaced()).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary)) }
                if favorite { Image(systemName: "star.fill").imageScale(.small).foregroundStyle(.yellow) }
            }
            Text(note.snippet(for: terms)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text(note.folder)
                Text("·")
                Text(note.modified, format: .relative(presentation: .named))
                if !note.tags.isEmpty { Text("·"); Text(note.tags.prefix(4).map { "#" + $0 }.joined(separator: " ")).lineLimit(1) }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NotePreview: View {
    let note: Note?
    let terms: [String]
    @ObservedObject var model: PopupModel
    @ObservedObject var user: UserStore

    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.title).font(.title3.bold()).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button { model.toggleFavorite(note) } label: {
                        Image(systemName: user.isFavorite(note.id) ? "star.fill" : "star")
                            .foregroundStyle(user.isFavorite(note.id) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless).help("Favourite (⌘D)").accessibilityLabel("Toggle favourite")
                    ShortcutRecorder(shortcut: Binding(get: { user.hotkey(for: note.id) },
                                                       set: { user.setHotkey($0, for: note) }),
                                     placeholder: "Set Hotkey")
                        .controlSize(.small)
                        .help("Global hotkey that opens this note")
                    Button("Open") { model.open(note) }.controlSize(.small)
                }
                HStack(spacing: 6) {
                    Label(note.folder, systemImage: "folder")
                    Text(note.modified.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption).foregroundStyle(.secondary)
                if !note.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(note.tags, id: \.self) { t in
                                Chip(text: "#" + t, systemImage: nil, tint: .orange) { model.toggleTag(t) }
                            }
                        }
                    }
                }
                Divider()
                ScrollView {
                    Text(note.locked ? AttributedString("🔒 This note is locked. Only its title is searchable.")
                                     : NoteFormatter.render(note.spans, highlight: terms, skipTitle: note.title))
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("No note selected").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension Note {
    /// First body line containing a search term, else the first line after the title.
    func snippet(for terms: [String]) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hit = terms.isEmpty ? nil : lines.first { line in terms.contains { line.range(of: $0, options: opts) != nil } }
        return String((hit ?? lines.first ?? "").prefix(200)).trimmingCharacters(in: .whitespaces)
    }
}

extension Notification.Name {
    static let popupDidShow = Notification.Name("QuickNoteSearch.popupDidShow")
}
