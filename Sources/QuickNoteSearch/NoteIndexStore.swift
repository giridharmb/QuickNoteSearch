import Foundation
import CoreServices

/// Keeps an in-memory SearchIndex in sync with Notes. Note contents are never written to disk:
/// a cache file outside Notes' protected container would expose notes to apps without Full Disk Access.
final class NoteIndexStore: ObservableObject {
    struct Status {
        var noteCount = 0
        var tagCount = 0
        var lastSync: Date?
        var lastDuration: TimeInterval = 0
        var error: String?
        var needsAccess = !NotesReader.hasAccess
    }

    @Published private(set) var index = SearchIndex(notes: [])
    @Published private(set) var status = Status()
    @Published private(set) var storeUUID = ""

    private let queue = DispatchQueue(label: "QuickNoteSearch.index", qos: .utility)
    // Queue-confined state.
    private var notes: [Int64: Note] = [:]
    private var stamps: [Int64: NotesReader.Stamp] = [:]
    private var running = false, pending = false, published = false
    private var lastRun = Date.distantPast
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?

    func start() {
        schedule()
        queue.async { [self] in
            if stream == nil { startWatching() }
        }
        restartTimer()
    }

    func rebuild() {
        queue.async { [self] in notes = [:]; stamps = [:]; published = false }
        schedule()
    }

    /// Safety net in case an FSEvent is missed.
    func restartTimer() {
        let minutes = max(1, UserDefaults.standard.integer(forKey: Pref.resyncMinutes))
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(minutes * 60), repeating: .seconds(minutes * 60), leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.schedule() }
        t.resume()
        timer = t
    }

    /// Coalesces bursts: Notes writes its WAL many times while you type.
    func schedule() {
        queue.async { [self] in
            if running { pending = true; return }
            running = true
            let wait = max(0, 2 - Date().timeIntervalSince(lastRun))
            queue.asyncAfter(deadline: .now() + wait) { self.runSync() }
        }
    }

    private func runSync() {
        let start = Date()
        do {
            guard NotesReader.hasAccess else { throw AccessDenied() }
            try sync()
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async { [self] in
                status.lastSync = Date(); status.lastDuration = elapsed
                status.error = nil; status.needsAccess = false
            }
        } catch {
            let denied = error is AccessDenied
            DispatchQueue.main.async { [self] in
                status.needsAccess = denied
                status.error = denied ? nil : error.localizedDescription
            }
        }
        lastRun = Date()
        running = false
        if pending { pending = false; schedule() }
    }

    private struct AccessDenied: Error {}

    private func sync() throws {
        let reader = try NotesReader()
        let uuid = try reader.storeUUID()
        let newStamps = try reader.stamps()
        let tags = try reader.hashtags()

        var dirty = !published
        for pk in stamps.keys where newStamps[pk] == nil { notes[pk] = nil; dirty = true }
        let changed = newStamps.filter { stamps[$0.key] != $0.value }.map(\.key)
        let raws = try reader.notes(changed)

        var decoded = [Note?](repeating: nil, count: raws.count)
        decoded.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: raws.count) { i in
                let r = raws[i]
                guard let stamp = newStamps[r.pk] else { return }
                let text = r.locked ? "" : (r.data.flatMap(NoteDecoder.text) ?? "")
                out[i] = Note(pk: r.pk, id: r.identifier, title: r.title, text: text, folder: stamp.folder,
                              modified: Date(timeIntervalSinceReferenceDate: stamp.modified), locked: r.locked)
            }
        }
        for n in decoded.compactMap({ $0 }) { notes[n.pk] = n; dirty = true }

        for (pk, var n) in notes {
            let t = Array(Set((tags[pk] ?? []) + n.inlineTags)).sorted()
            if n.tags != t { n.tags = t; notes[pk] = n; dirty = true }
        }
        stamps = newStamps
        guard dirty else { return }

        // shortcut: full rebuild on every change (~tens of ms for thousands of notes); go incremental if libraries get huge.
        let built = SearchIndex(notes: Array(notes.values))
        published = true
        DispatchQueue.main.async { [self] in
            index = built
            storeUUID = uuid
            status.noteCount = built.notes.count
            status.tagCount = built.tagCounts.count
        }
    }

    private func startWatching() {
        let dir = (NotesReader.path as NSString).deletingLastPathComponent
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let me = Unmanaged<NoteIndexStore>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: { $0.contains("NoteStore.sqlite") }) { me.schedule() }
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [dir] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }
}
