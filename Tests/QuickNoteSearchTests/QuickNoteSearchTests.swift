import XCTest
@testable import QuickNoteSearch

final class QuickNoteSearchTests: XCTestCase {
    // MARK: Fixtures

    private func ld(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8(field << 3 | 2)]
        var n = payload.count
        repeat { var b = UInt8(n & 0x7f); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        return out + payload
    }

    /// NoteStoreProto(2) → Document(3) → Note(2) text, with a varint field in front to exercise skipping.
    private func noteBlob(_ text: String) throws -> Data {
        let proto = [0x08, 0x01] + ld(2, [0x08, 0x00] + ld(3, ld(2, Array(text.utf8))))
        return try gzip(Data(proto))
    }

    private func gzip(_ d: Data) throws -> Data {
        let p = Process(), inPipe = Pipe(), outPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c", "-n"]
        p.standardInput = inPipe
        p.standardOutput = outPipe
        try p.run()
        inPipe.fileHandleForWriting.write(d)
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }

    private func note(_ title: String, _ body: String, tags: [String] = [], daysAgo: Double = 1, folder: String = "Notes") -> Note {
        var n = Note(pk: Int64(title.hashValue & 0xffff), id: UUID().uuidString, title: title, text: title + "\n" + body,
                     folder: folder, modified: Date().addingTimeInterval(-daysAgo * 86400), locked: false)
        n.tags = tags
        return n
    }

    // MARK: Decoder

    func testDecodesGzippedProtobuf() throws {
        let text = "Grocery list\nmilk, eggs, café ☕️ \u{FFFC}"
        XCTAssertEqual(NoteDecoder.text(from: try noteBlob(text)), "Grocery list\nmilk, eggs, café ☕️ ") // placeholder dropped
        XCTAssertNil(NoteDecoder.text(from: Data([0x1f, 0x8b, 1, 2, 3])))
        XCTAssertNil(NoteDecoder.text(from: Data()))
    }

    private func vi(_ field: Int, _ v: Int) -> [UInt8] {
        var out = [UInt8(field << 3)], n = v
        repeat { var b = UInt8(n & 0x7f); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        return out
    }

    func testDecodesFormattingRuns() throws {
        // "Plan\nBuy \u{FFFC} milk\nDone\nStep\nPic \u{FFFC}" with title, bold, hashtag, checklist, numbered list, image.
        let text = "Plan\nBuy \u{FFFC} milk\nDone\nStep\nPic \u{FFFC}"
        func run(_ len: Int, para: Int? = nil, checked: Bool = false, weight: Int? = nil, attach: (String, String)? = nil) -> [UInt8] {
            var r = vi(1, len)
            if let para { r += ld(2, vi(1, para) + (checked ? ld(5, ld(1, [1]) + vi(2, 1)) : [])) }
            if let weight { r += vi(5, weight) }
            if let attach { r += ld(12, ld(1, Array(attach.0.utf8)) + ld(2, Array(attach.1.utf8))) }
            return ld(5, r)
        }
        let runs = run(5, para: 0) + run(4, weight: 1) + run(1, attach: ("TAG1", "com.apple.notes.inlinetextattachment.hashtag"))
            + run(6) + run(5, para: 103, checked: true) + run(5, para: 102) + run(4) + run(1, attach: ("IMG1", "public.jpeg"))
        let proto = ld(2, ld(3, ld(2, Array(text.utf8)) + runs))
        let spans = try XCTUnwrap(NoteDecoder.spans(from: try gzip(Data(proto)), altText: ["TAG1": "#groceries"]))
        XCTAssertEqual(spans.map(\.text).joined(), "Plan\nBuy #groceries milk\nDone\nStep\nPic [🖼 Image]")
        XCTAssertEqual(spans[0].style.paragraph, 0)
        XCTAssertTrue(spans[1].style.bold)
        XCTAssertTrue(spans[4].style.checked)
        XCTAssertEqual(spans[5].style.paragraph, 102)
        XCTAssertTrue(spans[7].style.attachment)

        let rendered = String(NoteFormatter.render(spans, highlight: ["milk"], skipTitle: "Plan").characters)
        XCTAssertEqual(rendered, "Buy #groceries milk\n◉  Done\n1.  Step\nPic [🖼 Image]")
    }

    // MARK: Query

    func testQueryParsing() {
        let q = Query.parse("  groc #Work|#home -#Archive #urgent Café ")
        XCTAssertEqual(q.terms, ["groc", "cafe"])
        XCTAssertEqual(q.tagGroups, [["work", "home"], ["urgent"]])
        XCTAssertEqual(q.excludedTags, ["archive"])
        XCTAssertTrue(Query.parse("  # ").isEmpty)
    }

    func testEditDistance() {
        XCTAssertTrue(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("grocrey".utf8))) // transposition
        XCTAssertTrue(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("grocey".utf8)))  // deletion
        XCTAssertTrue(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("grocary".utf8))) // substitution
        XCTAssertFalse(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("gracary".utf8)))
    }

    // MARK: Search

    func testSearchRankingTagsAndTypos() {
        let idx = SearchIndex(notes: [
            note("Grocery list", "milk eggs bread", tags: ["home"]),
            note("Meeting notes", "discuss grocery budget", tags: ["work", "urgent"]),
            note("Trip plan", "flights hotel", tags: ["travel"], daysAgo: 300),
            note("Old work", "archive me", tags: ["work", "archive"]),
        ])
        let o = SearchOptions()
        XCTAssertEqual(idx.search(.parse("grocery"), o).map(\.title), ["Grocery list", "Meeting notes"]) // title beats body
        XCTAssertEqual(idx.search(.parse("grcry"), o).first?.title, "Grocery list")                     // fuzzy title
        XCTAssertEqual(idx.search(.parse("hotle"), o).map(\.title), ["Trip plan"])                       // typo in body
        XCTAssertEqual(idx.search(.parse("brea"), o).map(\.title), ["Grocery list"])                     // prefix
        XCTAssertEqual(Set(idx.search(.parse("#work"), o).map(\.title)), ["Meeting notes", "Old work"])
        XCTAssertEqual(idx.search(.parse("#work -#archive"), o).map(\.title), ["Meeting notes"])
        XCTAssertEqual(Set(idx.search(.parse("#home|#travel"), o).map(\.title)), ["Grocery list", "Trip plan"])
        XCTAssertEqual(idx.search(.parse("#work #urgent"), o).map(\.title), ["Meeting notes"])
        XCTAssertEqual(idx.search(.parse("#trav"), o).map(\.title), ["Trip plan"])                       // tag prefix
        XCTAssertTrue(idx.search(.parse("zzzz"), o).isEmpty)
        XCTAssertEqual(idx.search(.parse("hotle"), SearchOptions(typoTolerance: false)).count, 0)
        XCTAssertEqual(idx.search(.parse("milk"), SearchOptions(searchBody: false)).count, 0)
    }

    func testSearchIsFastOnLargeLibrary() {
        let words = ["alpha", "beta", "gamma", "delta", "project", "meeting", "budget", "travel", "recipe", "code"]
        let notes = (0..<10_000).map { i in
            note("Note \(i) \(words[i % 10])", (0..<200).map { words[($0 * 7 + i) % 10] + "\($0 % 50)" }.joined(separator: " "),
                 tags: [words[i % 7]])
        }
        let idx = SearchIndex(notes: notes)
        measure { _ = idx.search(.parse("projet budg #gamma"), SearchOptions()) }
    }

    // MARK: Database

    func testReadsNotesDatabaseSchema() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("NoteStore.sqlite").path
        let blob = try noteBlob("Hello world\nsecond line").map { String(format: "%02x", $0) }.joined()
        let sql = """
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME TEXT);
            INSERT INTO Z_PRIMARYKEY VALUES (12, 'ICNote'), (15, 'ICFolder');
            CREATE TABLE Z_METADATA (Z_UUID TEXT);
            INSERT INTO Z_METADATA VALUES ('1A2B3C4D-0000-1111-2222-333344445555');
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZTITLE1 TEXT, ZTITLE2 TEXT,
              ZIDENTIFIER TEXT, ZMODIFICATIONDATE1 REAL, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER, ZMARKEDFORDELETION INTEGER,
              ZISPASSWORDPROTECTED INTEGER, ZTYPEUTI1 TEXT, ZALTTEXT TEXT, ZNOTE1 INTEGER);
            CREATE TABLE ZICNOTEDATA (ZNOTE INTEGER, ZDATA BLOB);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE2, ZFOLDERTYPE) VALUES (1, 15, 'Work', 0), (2, 15, 'Recently Deleted', 1);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE1, ZIDENTIFIER, ZMODIFICATIONDATE1, ZFOLDER, ZMARKEDFORDELETION, ZISPASSWORDPROTECTED)
              VALUES (10, 12, 'Hello world', 'UUID-10', 700000000, 1, 0, 0),
                     (11, 12, 'Trashed', 'UUID-11', 700000000, 2, 0, 0),
                     (12, 12, 'Gone', 'UUID-12', 700000000, 1, 1, 0),
                     (13, 12, 'Secret', 'UUID-13', 700000000, 1, 0, 1);
            INSERT INTO ZICNOTEDATA VALUES (10, X'\(blob)'), (13, X'deadbeef');
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTYPEUTI1, ZALTTEXT, ZNOTE1)
              VALUES (20, 30, 'com.apple.notes.inlinetextattachment.hashtag', '#ProjectX', 10);
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, sql]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let reader = try NotesReader(path: db)
        XCTAssertEqual(try reader.storeUUID(), "1A2B3C4D-0000-1111-2222-333344445555")
        let stamps = try reader.stamps()
        XCTAssertEqual(Set(stamps.keys), [10, 13]) // trash folder and deleted notes excluded
        XCTAssertEqual(stamps[10]?.folder, "Work")
        XCTAssertEqual(try reader.hashtags()[10], ["projectx"])
        let raws = try reader.notes([10, 13]).sorted { $0.pk < $1.pk }
        XCTAssertEqual(raws.map(\.identifier), ["UUID-10", "UUID-13"])
        XCTAssertEqual(raws[0].data.flatMap(NoteDecoder.text), "Hello world\nsecond line")
        XCTAssertTrue(raws[1].locked)
    }
}
