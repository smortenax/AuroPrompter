import Foundation

enum PinyinStyle: String, Codable, CaseIterable, Identifiable {
    case toneMarks, toneNumbers
    var id: String { rawValue }
    var label: String { self == .toneMarks ? "Tone marks (nǐ hǎo)" : "Numbers (ni3 hao3)" }
}

enum PinyinScope: String, Codable, CaseIterable, Identifiable {
    case edges, everywhere
    var id: String { rawValue }
    var label: String { self == .edges ? "Start and end of script" : "All Chinese text" }
}

/// On-device Mandarin → pinyin, using the ICU transliterator built into iOS.
enum Pinyin {
    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF, 0x2A700...0x2EBEF:
                return true
            default:
                return false
            }
        }
    }

    /// One syllable (with tone marks) per character of `run`.
    static func syllables(for run: String, sandhi: Bool) -> [String] {
        let characters = Array(run)
        var result = transliterate(run)
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
        if result.count != characters.count {
            // The transliterator merged or split something: fall back to one character at a time.
            result = characters.map { transliterate(String($0)) }
        }
        if sandhi { applySandhi(characters: characters, syllables: &result) }
        return result
    }

    static func transliterate(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tone changes for 不 and 一, which dictionaries list with their citation tone.
    static func applySandhi(characters: [Character], syllables: inout [String]) {
        guard characters.count == syllables.count, characters.count > 1 else { return }
        for i in 0..<(characters.count - 1) {
            let nextTone = tone(of: syllables[i + 1])
            switch characters[i] {
            case "不":
                if nextTone == 4 { syllables[i] = "bú" }
            case "一":
                // Leave numbers such as 一一, 十一 and 第一 alone.
                if i > 0, "第十一二三四五六七八九零".contains(characters[i - 1]) { continue }
                if "一二三四五六七八九十零".contains(characters[i + 1]) { continue }
                if nextTone == 4 { syllables[i] = "yí" }
                else if nextTone != nil { syllables[i] = "yì" }
            default:
                break
            }
        }
    }

    private static let marked: [Character: (Character, Int)] = [
        "ā": ("a", 1), "á": ("a", 2), "ǎ": ("a", 3), "à": ("a", 4),
        "ē": ("e", 1), "é": ("e", 2), "ě": ("e", 3), "è": ("e", 4),
        "ī": ("i", 1), "í": ("i", 2), "ǐ": ("i", 3), "ì": ("i", 4),
        "ō": ("o", 1), "ó": ("o", 2), "ǒ": ("o", 3), "ò": ("o", 4),
        "ū": ("u", 1), "ú": ("u", 2), "ǔ": ("u", 3), "ù": ("u", 4),
        "ǖ": ("ü", 1), "ǘ": ("ü", 2), "ǚ": ("ü", 3), "ǜ": ("ü", 4),
        "ń": ("n", 2), "ň": ("n", 3), "ǹ": ("n", 4), "ḿ": ("m", 2),
    ]

    /// 1–4, or nil for neutral tone / unknown.
    static func tone(of syllable: String) -> Int? {
        for character in syllable.precomposedStringWithCanonicalMapping {
            if let entry = marked[character] { return entry.1 }
        }
        return nil
    }

    /// "hǎo" → "hao3". Neutral tone has no number.
    static func numbered(_ syllable: String) -> String {
        var base = ""
        var toneNumber: Int?
        for character in syllable.precomposedStringWithCanonicalMapping {
            if let entry = marked[character] {
                base.append(entry.0)
                toneNumber = entry.1
            } else {
                base.append(character)
            }
        }
        return base + (toneNumber.map(String.init) ?? "")
    }

    static func display(_ syllable: String, style: PinyinStyle) -> String {
        style == .toneMarks ? syllable : numbered(syllable)
    }
}
