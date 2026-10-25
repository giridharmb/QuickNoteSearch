import Foundation
import SQLite3

enum NotesError: LocalizedError {
    case database(String)
    var errorDescription: String? {
        switch self { case .database(let m): return "Notes database: \(m)" }
    }
}

/// Minimal read-only SQLite wrapper.
final class SQLiteDB {
    private var handle: OpaquePointer?

    init(readOnly path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw NotesError.database(msg)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String, _ each: (Row) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NotesError.database(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw NotesError.database(String(cString: sqlite3_errmsg(handle))) }
            each(Row(stmt: stmt))
        }
    }

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func string(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func data(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}

/// Reads Apple Notes' NoteStore.sqlite (undocumented Core Data schema; columns are probed so
/// a missing one degrades a feature instead of failing the whole read).
final class NotesReader {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite").path

    /// Opening the file is the only reliable Full Disk Access check (TCC denies open, not stat).
    static var hasAccess: Bool { FileHandle(forReadingAtPath: path) != nil }

    struct Stamp: Equatable { let modified: Double; let folder: String }

    struct RawNote {
        let pk: Int64
        let identifier: String
        let title: String?
        let locked: Bool
        let data: Data?
    }

    private let db: SQLiteDB
    private var noteEntity: Int64 = -1
    private var columns: Set<String> = []

    init(path: String = NotesReader.path) throws {
        db = try SQLiteDB(readOnly: path)
        try db.rows("SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote'") { noteEntity = $0.int(0) }
        try db.rows("PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)") { if let n = $0.string(1) { columns.insert(n) } }
        guard noteEntity >= 0, columns.contains("ZTITLE1") else {
            throw NotesError.database("unrecognised schema (Notes may have changed its format)")
        }
    }

    private func col(_ name: String) -> String { columns.contains(name) ? name : "NULL" }

    func storeUUID() throws -> String {
        var uuid = ""
        try db.rows("SELECT Z_UUID FROM Z_METADATA LIMIT 1") { uuid = $0.string(0) ?? "" }
        return uuid
    }

    /// Cheap pass over every live note: modification date + folder, used to diff for changes.
    func stamps() throws -> [Int64: Stamp] {
        var out: [Int64: Stamp] = [:]
        let sql = """
            SELECT n.Z_PK, n.\(col("ZMODIFICATIONDATE1")), f.\(col("ZTITLE2"))
            FROM ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.\(col("ZFOLDER"))
            WHERE n.Z_ENT = \(noteEntity)
              AND IFNULL(n.\(col("ZMARKEDFORDELETION")), 0) = 0
              AND IFNULL(f.\(col("ZFOLDERTYPE")), 0) != 1
            """ // ZFOLDERTYPE 1 = "Recently Deleted"
        try db.rows(sql) { out[$0.int(0)] = Stamp(modified: $0.double(1), folder: $0.string(2) ?? "Notes") }
        return out
    }

    func notes(_ pks: [Int64]) throws -> [RawNote] {
        var out: [RawNote] = []
        for start in stride(from: 0, to: pks.count, by: 500) {
            let ids = pks[start..<min(pks.count, start + 500)].map(String.init).joined(separator: ",")
            let sql = """
                SELECT n.Z_PK, n.\(col("ZIDENTIFIER")), n.ZTITLE1, n.\(col("ZISPASSWORDPROTECTED")), d.ZDATA
                FROM ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
                WHERE n.Z_PK IN (\(ids))
                """
            try db.rows(sql) {
                out.append(RawNote(pk: $0.int(0), identifier: $0.string(1) ?? "pk\($0.int(0))",
                                   title: $0.string(2), locked: $0.int(3) != 0, data: $0.data(4)))
            }
        }
        return out
    }

    /// Visible text of inline attachments (hashtags, mentions), keyed by attachment identifier.
    func inlineAltText() throws -> [String: String] {
        guard ["ZIDENTIFIER", "ZALTTEXT"].allSatisfy(columns.contains) else { return [:] }
        var out: [String: String] = [:]
        try db.rows("SELECT ZIDENTIFIER, ZALTTEXT FROM ZICCLOUDSYNCINGOBJECT WHERE ZALTTEXT IS NOT NULL AND ZIDENTIFIER IS NOT NULL") {
            if let id = $0.string(0), let alt = $0.string(1) { out[id] = alt }
        }
        return out
    }

    /// Hashtags are inline attachments: their text lives in ZALTTEXT, not in the note body.
    func hashtags() throws -> [Int64: [String]] {
        guard ["ZTYPEUTI1", "ZALTTEXT", "ZNOTE1"].allSatisfy(columns.contains) else { return [:] }
        var out: [Int64: [String]] = [:]
        try db.rows("""
            SELECT ZNOTE1, ZALTTEXT FROM ZICCLOUDSYNCINGOBJECT
            WHERE ZTYPEUTI1 = 'com.apple.notes.inlinetextattachment.hashtag' AND ZNOTE1 IS NOT NULL
            """) { row in
            if let t = row.string(1).map(Tag.normalize), !t.isEmpty { out[row.int(0), default: []].append(t) }
        }
        return out
    }
}

/// Formatting of one stretch of note text (subset of Notes' AttributeRun / ParagraphStyle).
struct TextStyle: Equatable {
    var paragraph = -1          // 0 title, 1 heading, 2 subheading, 4 monospaced, 100 •, 101 –, 102 1., 103 checklist
    var indent = 0
    var checked = false
    var quote = false
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var link: String?
    var attachment = false      // placeholder for an image/table/etc.
}

struct Span: Equatable {
    var text: String
    var style = TextStyle()
}

/// Decodes ZICNOTEDATA.ZDATA: gzip → protobuf NoteStoreProto(2) → Document(3) → Note(2 text, 5 attribute runs).
enum NoteDecoder {
    static func text(from data: Data) -> String? {
        spans(from: data, altText: [:]).map { $0.map(\.text).joined() }
    }

    /// `altText` maps inline-attachment identifiers (hashtags, mentions) to their visible text.
    static func spans(from data: Data, altText: [String: String]) -> [Span]? {
        let bytes = [UInt8](data)
        guard let raw = bytes.starts(with: [0x1f, 0x8b]) ? gunzip(bytes) : bytes,
              let note = Proto(raw)?.message(2)?.message(3), let textBytes = note.bytes[2]?.first
        else { return nil }
        let text = String(decoding: textBytes, as: UTF8.self) as NSString
        var spans: [Span] = []
        var pos = 0 // run lengths are UTF-16 units, like NSString
        for run in (note.bytes[5] ?? []).compactMap(Proto.init) {
            let len = min(run.varints[1] ?? 0, text.length - pos)
            guard len > 0 else { continue }
            var piece = text.substring(with: NSRange(location: pos, length: len))
            pos += len
            var style = TextStyle()
            if let ps = run.message(2) {
                style.paragraph = ps.varints[1] ?? -1
                style.indent = ps.varints[4] ?? 0
                style.checked = ps.message(5)?.varints[2] == 1
                style.quote = (ps.varints[8] ?? 0) != 0
            }
            let weight = run.varints[5] ?? 0 // 1 bold, 2 italic, 3 both
            style.bold = weight == 1 || weight == 3
            style.italic = weight == 2 || weight == 3
            style.underline = (run.varints[6] ?? 0) != 0
            style.strike = (run.varints[7] ?? 0) != 0
            style.link = run.string(9)
            if let info = run.message(12), piece.contains("\u{FFFC}") {
                let uti = info.string(2) ?? ""
                if let alt = info.string(1).flatMap({ altText[$0] }) {
                    piece = piece.replacingOccurrences(of: "\u{FFFC}", with: alt)
                } else if !uti.contains("inlinetextattachment") {
                    piece = piece.replacingOccurrences(of: "\u{FFFC}", with: placeholder(uti))
                    style.attachment = true
                }
            }
            spans.append(Span(text: piece, style: style))
        }
        if pos < text.length { spans.append(Span(text: text.substring(from: pos))) }
        for i in spans.indices { spans[i].text = spans[i].text.replacingOccurrences(of: "\u{FFFC}", with: "") }
        return spans
    }

    private static func placeholder(_ uti: String) -> String {
        switch uti {
        case let u where u.contains("table"): return "[▦ Table]"
        case let u where u.contains("drawing") || u.contains("paper") || u.contains("sketch"): return "[✏️ Drawing]"
        case let u where u.contains("pdf"): return "[📄 PDF]"
        case let u where u.contains("url"): return "[🔗 Link]"
        case let u where u.contains("image") || u.contains("jpeg") || u.contains("png") || u.contains("heic") || u.contains("gif"): return "[🖼 Image]"
        case let u where u.contains("audio") || u.contains("movie") || u.contains("video"): return "[🎞 Media]"
        default: return "[📎 Attachment]"
        }
    }

    static func gunzip(_ b: [UInt8]) -> [UInt8]? {
        guard b.count > 18, b[2] == 8 else { return nil } // 8 = deflate
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        // NSData's .zlib is raw deflate, so strip the gzip header and 8-byte trailer.
        guard let out = try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) else { return nil }
        return [UInt8](out as Data)
    }
}

/// Just enough protobuf: varints (last value wins) and length-delimited fields (all values).
struct Proto {
    var varints: [Int: Int] = [:]
    var bytes: [Int: [[UInt8]]] = [:]

    init?(_ b: [UInt8]) {
        var i = 0
        func varint() -> Int? {
            var v = 0, shift = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                v |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: guard let v = varint() else { return nil }; varints[key >> 3] = v
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let len = varint(), len >= 0, i + len <= b.count else { return nil }
                bytes[key >> 3, default: []].append(Array(b[i..<(i + len)]))
                i += len
            default: return nil
            }
        }
    }

    func message(_ n: Int) -> Proto? { bytes[n]?.first.flatMap(Proto.init) }
    func string(_ n: Int) -> String? { bytes[n]?.first.map { String(decoding: $0, as: UTF8.self) } }
}

enum Tag {
    static func normalize(_ s: String) -> String {
        String(s.drop(while: { $0 == "#" })).folded
    }
}

extension String {
    /// Case/diacritic/width-insensitive form used for every comparison.
    var folded: String { folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
}
