import Foundation

struct Note: Identifiable, Hashable {
    let id: String          // ZIDENTIFIER: stable across launches and syncs
    let pk: Int64
    let title: String
    let body: String
    let folder: String
    let modified: Date
    let locked: Bool
    let inlineTags: [String] // "#tag" typed as plain text (not converted by Notes)
    var tags: [String] = []

    // Search keys, precomputed once per note version.
    let titleKey: [UInt8]
    let bodyKey: [UInt8]
    let folderKey: [UInt8]
    let words: [String]

    private static let nonWord = CharacterSet.alphanumerics.inverted
    private static let tagRegex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}&])#([\\p{L}\\p{N}_-]+)")

    init(pk: Int64, id: String, title: String?, text: String, folder: String, modified: Date, locked: Bool) {
        let body = text.replacingOccurrences(of: "\u{FFFC}", with: "") // inline-attachment placeholders
        let firstLine = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let title = (title?.isEmpty == false ? title! : firstLine).trimmingCharacters(in: .whitespaces)
        self.id = id
        self.pk = pk
        self.title = title.isEmpty ? "Untitled" : title
        self.body = body
        self.folder = folder
        self.modified = modified
        self.locked = locked
        let foldedBody = body.folded
        titleKey = Array(title.folded.utf8)
        bodyKey = Array(foldedBody.utf8)
        folderKey = Array(folder.folded.utf8)
        words = Array(Set(foldedBody.components(separatedBy: Self.nonWord).filter { $0.count >= 2 }))
        let ns = body as NSString
        inlineTags = Self.tagRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            .map { Tag.normalize(ns.substring(with: $0.range(at: 1))) }
    }

    static func == (a: Note, b: Note) -> Bool { a.id == b.id && a.modified == b.modified && a.tags == b.tags && a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct SearchOptions {
    var searchBody = true
    var typoTolerance = true
    var recencyBoost = true
    var limit = 100
    var favorites: Set<String> = []
    var recent: Set<String> = []
}

/// Query syntax: words are fuzzy-matched (AND); `#a #b` = both tags; `#a|#b` = either; `-#c` = exclude.
struct Query: Equatable {
    var terms: [String] = []
    var tagGroups: [[String]] = []
    var excludedTags: [String] = []

    var isEmpty: Bool { terms.isEmpty && tagGroups.isEmpty && excludedTags.isEmpty }
    var allTags: [String] { tagGroups.flatMap { $0 } }

    static func parse(_ text: String) -> Query {
        var q = Query()
        for token in text.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("-#") {
                q.excludedTags += tags(in: token.dropFirst())
            } else if token.hasPrefix("#") {
                let group = tags(in: token)
                if !group.isEmpty { q.tagGroups.append(group) }
            } else {
                let t = String(token).folded
                if !t.isEmpty { q.terms.append(t) }
            }
        }
        return q
    }

    private static func tags(in s: Substring) -> [String] {
        s.split(separator: "|").map { Tag.normalize(String($0)) }.filter { !$0.isEmpty }
    }
}

/// Immutable snapshot; rebuilt off the main thread on every change, then swapped in.
struct SearchIndex {
    let notes: [Note]                       // newest first
    let tagCounts: [(tag: String, count: Int)]
    private let byID: [String: Int]
    private let vocab: [[UInt8]]
    private let postings: [[Int32]]
    private let tagPostings: [String: [Int32]]

    init(notes unsorted: [Note]) {
        notes = unsorted.sorted { $0.modified > $1.modified }
        var wordIDs: [String: Int32] = [:]
        var vocab: [[UInt8]] = [], postings: [[Int32]] = []
        var tagPostings: [String: [Int32]] = [:]
        for (i, n) in notes.enumerated() {
            for w in n.words {
                if let id = wordIDs[w] { postings[Int(id)].append(Int32(i)) }
                else { wordIDs[w] = Int32(vocab.count); vocab.append(Array(w.utf8)); postings.append([Int32(i)]) }
            }
            for t in n.tags { tagPostings[t, default: []].append(Int32(i)) }
        }
        self.vocab = vocab
        self.postings = postings
        self.tagPostings = tagPostings
        tagCounts = tagPostings.map { ($0.key, $0.value.count) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
        byID = Dictionary(notes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func note(id: String) -> Note? { byID[id].map { notes[$0] } }

    func search(_ q: Query, _ o: SearchOptions) -> [Note] {
        let n = notes.count
        guard n > 0 else { return [] }
        var allowed = [Bool](repeating: true, count: n)
        for group in q.tagGroups {
            let m = tagMask(group)
            for i in 0..<n where !m[i] { allowed[i] = false }
        }
        if !q.excludedTags.isEmpty {
            let m = tagMask(q.excludedTags)
            for i in 0..<n where m[i] { allowed[i] = false }
        }

        let terms = q.terms.map { Array($0.utf8) }
        let wordHits = o.searchBody ? terms.map { wordScores($0, typos: o.typoTolerance) } : []
        let now = Date()
        var scores = [Float](repeating: -1, count: n)
        let chunk = 256
        scores.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: (n + chunk - 1) / chunk) { c in
                for i in (c * chunk)..<min(n, (c + 1) * chunk) where allowed[i] {
                    out[i] = score(i, terms, wordHits, o, now)
                }
            }
        }
        return scores.indices.filter { scores[$0] >= 0 }
            .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
            .prefix(o.limit).map { notes[$0] }
    }

    private func score(_ i: Int, _ terms: [[UInt8]], _ wordHits: [[Float]], _ o: SearchOptions, _ now: Date) -> Float {
        let note = notes[i]
        var total: Float = 0
        for (t, term) in terms.enumerated() {
            var best: Float = o.searchBody ? wordHits[t][i] : 0
            if Self.contains(note.titleKey, term) {
                best = max(best, note.titleKey.starts(with: term) ? 3.5 : 3)
            } else if let q = Self.subsequence(term, in: note.titleKey), q > 0.45 {
                best = max(best, 1.5 * q)
            }
            if best == 0, Self.contains(note.folderKey, term) { best = 1 }
            if best == 0, o.searchBody, Self.contains(note.bodyKey, term) { best = 1 } // mid-word / punctuation
            if best == 0 { return -1 }
            total += best
        }
        if o.recencyBoost { total += 0.6 * Float(exp(-now.timeIntervalSince(note.modified) / (30 * 86400))) }
        if o.favorites.contains(note.id) { total += 1 }
        if o.recent.contains(note.id) { total += 0.5 }
        return total
    }

    /// Best whole-word score per note: exact 2, prefix 1.6, one typo 1.2.
    private func wordScores(_ term: [UInt8], typos: Bool) -> [Float] {
        var s = [Float](repeating: 0, count: notes.count)
        let fuzzy = typos && term.count >= 4
        for (w, word) in vocab.enumerated() {
            let v: Float
            if word == term { v = 2 }
            else if word.starts(with: term) { v = 1.6 }
            else if fuzzy && abs(word.count - term.count) <= 1 && Self.withinOneEdit(word, term) { v = 1.2 }
            else { continue }
            for p in postings[w] where s[Int(p)] < v { s[Int(p)] = v }
        }
        return s
    }

    /// Exact tag match; a tag nobody has falls back to prefix so `#wor` works while typing.
    private func tagMask(_ tags: [String]) -> [Bool] {
        var m = [Bool](repeating: false, count: notes.count)
        for tag in tags {
            let keys = tagPostings[tag] != nil ? [tag] : tagPostings.keys.filter { $0.hasPrefix(tag) }
            for k in keys { for p in tagPostings[k]! { m[Int(p)] = true } }
        }
        return m
    }

    static func contains(_ h: [UInt8], _ n: [UInt8]) -> Bool {
        guard !n.isEmpty, h.count >= n.count else { return false }
        return h.withUnsafeBytes { hb in n.withUnsafeBytes { nb in
            memmem(hb.baseAddress, hb.count, nb.baseAddress, nb.count) != nil
        } }
    }

    /// Characters of `p` in order inside `s`; quality = len(p) / span matched.
    static func subsequence(_ p: [UInt8], in s: [UInt8]) -> Float? {
        guard !p.isEmpty, p.count <= s.count else { return nil }
        var j = 0, first = -1
        for (i, c) in s.enumerated() where c == p[j] {
            if first < 0 { first = i }
            j += 1
            if j == p.count { return Float(p.count) / Float(i - first + 1) }
        }
        return nil
    }

    /// Levenshtein distance <= 1, plus adjacent transposition.
    static func withinOneEdit(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let (s, l) = a.count <= b.count ? (a, b) : (b, a)
        if l.count - s.count > 1 { return false }
        var i = 0
        while i < s.count && s[i] == l[i] { i += 1 }
        if i == s.count { return true }
        if s.count == l.count {
            if s[(i + 1)...] == l[(i + 1)...] { return true }
            return i + 1 < s.count && s[i] == l[i + 1] && s[i + 1] == l[i] && s[(i + 2)...] == l[(i + 2)...]
        }
        return s[i...] == l[(i + 1)...]
    }
}
