import Foundation

struct LyricWord: Codable, Hashable {
    /// Includes a trailing space when the word is followed by one.
    var text: String
    var start: Double
    var end: Double
}

struct LyricLine: Codable, Hashable, Identifiable {
    var id: Int
    var start: Double
    var end: Double?
    var text: String
    /// Latin-script reading for lines written in another script.
    var romanized: String?
    var words: [LyricWord] = []
    var isBackground = false
    /// Secondary vocalist (duets): rendered trailing-aligned.
    var isSecondary = false
}

struct Lyrics: Codable {
    var provider: String
    var isSynced: Bool
    var lines: [LyricLine]
    /// User adjustment in seconds; positive values make lyrics appear later.
    var offset: Double = 0
    /// True for lyrics the listener edited; they are kept when providers are searched again.
    var userEdited: Bool?
}

enum LyricsTime {
    /// Parses `1:02:03.456`, `1:02.345`, `9.731` and `12.5s`.
    static func parse(_ value: String?) -> Double? {
        guard var value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasSuffix("ms"), let ms = Double(value.dropLast(2)) { return ms / 1000 }
        if value.hasSuffix("s") { value.removeLast() }
        var total = 0.0
        for part in value.split(separator: ":") {
            guard let number = Double(part) else { return nil }
            total = total * 60 + number
        }
        return total
    }
}

/// Parses Apple-style TTML (as served by BetterLyrics) including word timing, background
/// vocals and duet agents.
final class TTMLParser: NSObject, XMLParserDelegate {
    private var lines: [LyricLine] = []
    private var inBody = false
    private var paragraphDepth = 0

    private var lineStart = 0.0
    private var lineEnd: Double?
    private var lineAgent: String?
    private var mainWords: [LyricWord] = []
    private var backgroundWords: [LyricWord] = []
    private var plainText = ""

    private var agents: [String] = []
    private var spanStack: [SpanKind] = []
    private var currentWord: LyricWord?

    private enum SpanKind { case word, background, ignored, other }

    static func parse(_ ttml: String) -> [LyricLine] {
        let delegate = TTMLParser()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.lines.sorted { $0.start < $1.start }.enumerated().map { index, line in
            var line = line
            line.id = index
            return line
        }
    }

    private var isIgnoring: Bool { spanStack.contains(.ignored) }
    private var isBackground: Bool { spanStack.contains(.background) }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "body":
            inBody = true
        case "p" where inBody:
            paragraphDepth += 1
            lineStart = LyricsTime.parse(attributes["begin"]) ?? 0
            lineEnd = LyricsTime.parse(attributes["end"])
            lineAgent = attributes["ttm:agent"]
            if let agent = lineAgent, !agents.contains(agent) { agents.append(agent) }
            mainWords = []
            backgroundWords = []
            plainText = ""
            spanStack = []
        case "span" where paragraphDepth > 0:
            let role = attributes["ttm:role"] ?? ""
            if role == "x-bg" {
                spanStack.append(.background)
            } else if role.hasPrefix("x-") {
                spanStack.append(.ignored)
            } else if let begin = LyricsTime.parse(attributes["begin"]), !isIgnoring {
                spanStack.append(.word)
                currentWord = LyricWord(text: "", start: begin, end: LyricsTime.parse(attributes["end"]) ?? begin)
            } else {
                spanStack.append(.other)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard paragraphDepth > 0, !isIgnoring else { return }
        if currentWord != nil {
            currentWord?.text += string
            return
        }
        let hasWords = !(mainWords.isEmpty && backgroundWords.isEmpty)
        if string.allSatisfy(\.isWhitespace) {
            // Whitespace between word spans marks a word boundary.
            if isBackground, !backgroundWords.isEmpty {
                if !backgroundWords[backgroundWords.count - 1].text.hasSuffix(" ") { backgroundWords[backgroundWords.count - 1].text += " " }
            } else if !mainWords.isEmpty {
                if !mainWords[mainWords.count - 1].text.hasSuffix(" ") { mainWords[mainWords.count - 1].text += " " }
            } else if !hasWords, !plainText.isEmpty {
                plainText += " "
            }
        } else if !hasWords {
            plainText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "body":
            inBody = false
        case "span" where paragraphDepth > 0:
            guard let kind = spanStack.popLast() else { return }
            if kind == .word, let word = currentWord {
                currentWord = nil
                guard !word.text.isEmpty else { return }
                if isBackground { backgroundWords.append(word) } else { mainWords.append(word) }
            }
        case "p" where paragraphDepth > 0:
            paragraphDepth -= 1
            finishLine()
        default:
            break
        }
    }

    private func finishLine() {
        let secondary = lineAgent.flatMap { agents.firstIndex(of: $0) }.map { $0 % 2 == 1 } ?? false
        if !mainWords.isEmpty {
            lines.append(LyricLine(
                id: 0,
                start: mainWords.first?.start ?? lineStart,
                end: lineEnd ?? mainWords.last?.end,
                text: Self.join(mainWords),
                words: Self.trimmed(mainWords),
                isSecondary: secondary
            ))
        } else {
            let text = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(LyricLine(id: 0, start: lineStart, end: lineEnd, text: text, isSecondary: secondary))
            }
        }
        if !backgroundWords.isEmpty {
            lines.append(LyricLine(
                id: 0,
                start: backgroundWords.first?.start ?? lineStart,
                end: backgroundWords.last?.end,
                text: Self.join(backgroundWords),
                words: Self.trimmed(backgroundWords),
                isBackground: true,
                isSecondary: secondary
            ))
        }
    }

    private static func join(_ words: [LyricWord]) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }

    private static func trimmed(_ words: [LyricWord]) -> [LyricWord] {
        var words = words
        if let last = words.indices.last {
            words[last].text = words[last].text.trimmingCharacters(in: .whitespaces)
        }
        return words
    }
}

/// Parses LRC, including the enhanced `<mm:ss.xx>` per-word variant.
enum LRCParser {
    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(start: Double, text: String, words: [LyricWord])] = []
        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            var stamps: [Double] = []
            while let match = rest.prefixMatch(of: #/\s*\[(\d+):(\d+(?:[.:]\d+)?)\]/#) {
                let seconds = (Double(match.1) ?? 0) * 60 + (Double(match.2.replacingOccurrences(of: ":", with: ".")) ?? 0)
                stamps.append(seconds)
                rest = rest[match.range.upperBound...]
            }
            guard !stamps.isEmpty else { continue }
            let (text, words) = parseWords(String(rest))
            for stamp in stamps { entries.append((stamp, text, words)) }
        }
        entries.sort { $0.start < $1.start }
        return entries.enumerated().map { index, entry in
            let nextStart = index + 1 < entries.count ? entries[index + 1].start : nil
            var words = entry.words
            if let last = words.indices.last, words[last].end <= words[last].start {
                words[last].end = nextStart.map { min($0, words[last].start + 2) } ?? words[last].start + 1
            }
            return LyricLine(id: index, start: entry.start, end: nextStart, text: entry.text, words: words)
        }
    }

    private static func parseWords(_ body: String) -> (String, [LyricWord]) {
        let pattern = #/<(\d+):(\d+(?:\.\d+)?)>/#
        let matches = body.matches(of: pattern)
        guard !matches.isEmpty else { return (body.trimmingCharacters(in: .whitespaces), []) }
        var words: [LyricWord] = []
        for (index, match) in matches.enumerated() {
            let start = (Double(match.1) ?? 0) * 60 + (Double(match.2) ?? 0)
            let textEnd = index + 1 < matches.count ? matches[index + 1].range.lowerBound : body.endIndex
            let text = String(body[match.range.upperBound ..< textEnd])
            if let last = words.indices.last { words[last].end = start }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                words.append(LyricWord(text: text, start: start, end: start))
            }
        }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return (text, words)
    }
}

/// Writes lines back as LRC, with `<mm:ss.xx>` word tags where the line has word timing, so an
/// edited line keeps what the provider knew.
enum LRCWriter {
    static func stamp(_ seconds: Double) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }

    static func write(_ lines: [LyricLine]) -> String {
        lines.map { line in
            let body = line.words.isEmpty ? line.text : line.words.map { "<\(stamp($0.start))>\($0.text)" }.joined()
            return "[\(stamp(line.start))]\(body)"
        }.joined(separator: "\n")
    }
}
