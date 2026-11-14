import Foundation
import NaturalLanguage

/// Produces Latin-script readings for lyrics written in other scripts.
enum Romanizer {
    /// True when the text contains letters outside the Latin script.
    static func needsRomanization(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value > 0x24F && $0.properties.isAlphabetic }
    }

    /// Adds a romanised reading to each line that needs one. The language is judged once for
    /// the whole song so a line of kanji in a Japanese song isn't read as Chinese.
    static func annotate(_ lyrics: inout Lyrics) {
        let sample = lyrics.lines.map(\.text).filter(needsRomanization).joined(separator: "\n")
        guard !sample.isEmpty else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        var language = recognizer.dominantLanguage
        // Any kana means Japanese, whatever the statistics say.
        if sample.unicodeScalars.contains(where: { (0x3040 ... 0x30FF).contains($0.value) }) { language = .japanese }

        for index in lyrics.lines.indices where needsRomanization(lyrics.lines[index].text) {
            lyrics.lines[index].romanized = romanize(lyrics.lines[index].text, language: language)
        }
    }

    static func romanize(_ text: String, language: NLLanguage?) -> String? {
        let result: String
        if language == .japanese {
            result = japanese(text)
        } else if language == .korean || text.unicodeScalars.contains(where: { (0xAC00 ... 0xD7A3).contains($0.value) }) {
            let korean = Self.korean(text)
            result = needsRomanization(korean) ? (korean.applyingTransform(.toLatin, reverse: false) ?? korean) : korean
        } else {
            // Covers Korean (Revised-style), Chinese (pinyin), Cyrillic, Greek, Thai and others.
            result = text.applyingTransform(.toLatin, reverse: false) ?? text
        }
        let cleaned = tidy(result)
        return cleaned.isEmpty || cleaned == text ? nil : cleaned
    }

    /// Japanese needs word segmentation with dictionary readings: kanji have no fixed sound.
    private static func japanese(_ text: String) -> String {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil, string, CFRangeMake(0, string.length), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale
        )
        var output = ""
        var cursor = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > cursor {
                output += string.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let original = string.substring(with: NSRange(location: range.location, length: range.length))
            if needsRomanization(original),
               let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
               !reading.isEmpty {
                output += reading + " "
            } else {
                output += original
            }
            cursor = range.location + range.length
        }
        if cursor < string.length { output += string.substring(from: cursor) }
        // The tokenizer writes a doubled consonant (small tsu) as "~tsu": fold it into the next sound.
        output = output.replacingOccurrences(of: #"~tsu\s*([a-z])"#, with: "$1$1", options: .regularExpression)
        output = output.replacingOccurrences(of: "~tsu", with: "")
        // Anything the dictionary missed still gets a best-effort reading.
        return needsRomanization(output) ? (output.applyingTransform(.toLatin, reverse: false) ?? output) : output
    }

    // MARK: Korean (Revised Romanisation)

    private static let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    private static let medials = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
    /// How each final consonant sounds at the end of a syllable.
    private static let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
    /// (what stays, what moves) when the next syllable starts with a vowel.
    private static let linked: [(String, String)] = [
        ("", ""), ("", "g"), ("", "kk"), ("k", "s"), ("", "n"), ("n", "j"), ("", "n"), ("", "d"), ("", "r"), ("l", "g"),
        ("l", "m"), ("l", "b"), ("l", "s"), ("l", "t"), ("l", "p"), ("", "r"), ("", "m"), ("", "b"), ("p", "s"), ("", "s"),
        ("", "ss"), ("ng", ""), ("", "j"), ("", "ch"), ("", "k"), ("", "t"), ("", "p"), ("", ""),
    ]

    private static func korean(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        func parts(_ scalar: Unicode.Scalar) -> (Int, Int, Int)? {
            guard (0xAC00 ... 0xD7A3).contains(scalar.value) else { return nil }
            let index = Int(scalar.value - 0xAC00)
            return (index / 588, (index % 588) / 28, index % 28)
        }
        var output = ""
        var carried = ""
        for (position, scalar) in scalars.enumerated() {
            guard let (initial, medial, final) = parts(scalar) else {
                output.unicodeScalars.append(scalar)
                carried = ""
                continue
            }
            var onset = initials[initial]
            if !carried.isEmpty, initial == 11 { onset = carried }
            // l + r is pronounced and written "ll".
            if onset == "r", output.hasSuffix("l") { onset = "l" }
            output += onset + medials[medial]
            carried = ""

            let next = position + 1 < scalars.count ? parts(scalars[position + 1]) : nil
            if final != 0, let next, next.0 == 11 {
                let (stays, moves) = linked[final]
                output += stays
                carried = moves
            } else {
                output += finals[final]
            }
        }
        return output
    }

    private static func tidy(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "、", with: ", ")
            .replacingOccurrences(of: "。", with: ". ")
            .replacingOccurrences(of: "　", with: " ")
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.!?)\]」』])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([(\[「『])\s+"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}
