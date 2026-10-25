import SwiftUI

/// Turns decoded Notes spans into an AttributedString that looks like the note in Notes.
enum NoteFormatter {
    private struct Line {
        var spans: [Span] = []
        var para: TextStyle?   // paragraph style comes from the run that owns the line
    }

    /// `skipTitle`: drop the first line when it repeats the title already shown above the preview.
    static func render(_ spans: [Span], highlight terms: [String], skipTitle: String? = nil, limit: Int = 30_000) -> AttributedString {
        var lines = [Line()]
        var used = 0
        for span in spans where used < limit {
            used += span.text.utf16.count
            let parts = span.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (k, part) in parts.enumerated() {
                if k > 0 { lines.append(Line()) }
                let trailingEmpty = k == parts.count - 1 && part.isEmpty && k > 0
                if !trailingEmpty && lines[lines.count - 1].para == nil { lines[lines.count - 1].para = span.style }
                if !part.isEmpty { lines[lines.count - 1].spans.append(Span(text: String(part), style: span.style)) }
            }
        }

        if let skipTitle, lines.count > 1,
           lines[0].spans.map(\.text).joined().trimmingCharacters(in: .whitespaces) == skipTitle {
            lines.removeFirst()
        }
        var out = AttributedString()
        var numbers: [Int: Int] = [:] // indent level → current number in a numbered list
        for (i, line) in lines.enumerated() {
            let p = line.para ?? TextStyle()
            if p.paragraph == 102 {
                numbers = numbers.filter { $0.key <= p.indent }
                numbers[p.indent, default: 0] += 1
            } else {
                numbers = [:]
            }
            var marker = String(repeating: "    ", count: p.indent)
            switch p.paragraph {
            case 100: marker += "•  "
            case 101: marker += "–  "
            case 102: marker += "\(numbers[p.indent]!).  "
            case 103: marker += p.checked ? "◉  " : "○  "
            default: break
            }
            if p.quote { marker = "┃  " + marker }
            var a = AttributedString(marker)
            a.font = font(p, TextStyle())
            a.foregroundColor = p.paragraph == 103 && p.checked ? .accentColor : .secondary
            for s in line.spans {
                var piece = AttributedString(s.text)
                piece.font = font(p, s.style)
                if s.style.underline { piece.underlineStyle = .single }
                if s.style.strike { piece.strikethroughStyle = .single }
                if p.paragraph == 103 && p.checked || s.style.attachment { piece.foregroundColor = .secondary }
                if p.paragraph == 4 { piece.backgroundColor = Color.gray.opacity(0.12) }
                if let link = s.style.link, let url = URL(string: link) {
                    piece.link = url
                    piece.foregroundColor = .accentColor
                }
                a += piece
            }
            if i < lines.count - 1 { a += AttributedString("\n") }
            out += a
        }
        highlight(&out, terms)
        return out
    }

    private static func font(_ p: TextStyle, _ s: TextStyle) -> Font {
        var size: CGFloat = 14, weight: Font.Weight = .regular, design: Font.Design = .default
        switch p.paragraph {
        case 0: size = 24; weight = .bold
        case 1: size = 19; weight = .bold
        case 2: size = 16; weight = .semibold
        case 4: size = 13; design = .monospaced
        default: break
        }
        if s.bold { weight = .bold }
        let f = Font.system(size: size, weight: weight, design: design)
        return s.italic ? f.italic() : f
    }

    private static func highlight(_ out: inout AttributedString, _ terms: [String]) {
        let s = String(out.characters) as NSString
        var marks = 0
        for term in terms where !term.isEmpty {
            var r = NSRange(location: 0, length: s.length)
            while marks < 300 {
                let f = s.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: r)
                if f.location == NSNotFound { break }
                if let range = Range(f, in: out) { out[range].backgroundColor = .yellow.opacity(0.45) }
                marks += 1
                r = NSRange(location: f.upperBound, length: s.length - f.upperBound)
            }
        }
    }
}
