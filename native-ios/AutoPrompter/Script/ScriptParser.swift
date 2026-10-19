import Foundation

struct ScriptToken: Identifiable, Hashable {
    enum Kind: Hashable { case word, han, lineBreak }

    let id: Int
    let text: String
    let kind: Kind
    /// Pinyin shown above a Chinese character, already in the chosen display style.
    var pinyin: String?
}

/// A stretch of Chinese characters that gets pinyin, editable on the script screen.
struct ChineseRun: Identifiable, Hashable {
    var id: Int { firstToken }
    let firstToken: Int
    let text: String
    let syllables: [String]
    let autoSyllables: [String]
    var isOverridden: Bool { syllables != autoSyllables }
}

struct SpokenWord: Hashable {
    let normalized: String
    let tokenIndex: Int
}

struct ParsedScript {
    var tokens: [ScriptToken] = []
    var runs: [ChineseRun] = []
    /// Latin-script words in reading order, used to follow the speaker's voice.
    var spokenWords: [SpokenWord] = []
}

enum ScriptParser {
    static func parse(_ text: String,
                      scope: PinyinScope,
                      style: PinyinStyle,
                      sandhi: Bool,
                      overrides: [String: String]) -> ParsedScript {
        var tokens: [ScriptToken] = []

        func add(_ text: String, _ kind: ScriptToken.Kind) {
            tokens.append(ScriptToken(id: tokens.count, text: text, kind: kind))
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            var word = ""
            for character in line {
                if Pinyin.isHan(character) {
                    if !word.isEmpty { add(word, .word); word = "" }
                    add(String(character), .han)
                } else if character.isWhitespace {
                    if !word.isEmpty { add(word, .word); word = "" }
                } else {
                    word.append(character)
                }
            }
            if !word.isEmpty { add(word, .word) }
            if lineIndex < lines.count - 1 { add("\n", .lineBreak) }
        }

        // Which Chinese characters get pinyin: only those before the first / after the last
        // spoken (Latin) word, or all of them.
        var spokenWords: [SpokenWord] = []
        for token in tokens where token.kind == .word {
            let normalized = normalize(token.text)
            if !normalized.isEmpty { spokenWords.append(SpokenWord(normalized: normalized, tokenIndex: token.id)) }
        }
        let firstLatin = spokenWords.first?.tokenIndex ?? Int.max
        let lastLatin = spokenWords.last?.tokenIndex ?? Int.min
        func wantsPinyin(_ index: Int) -> Bool {
            scope == .everywhere || spokenWords.isEmpty || index < firstLatin || index > lastLatin
        }

        // Group consecutive characters into runs so the transliterator sees whole phrases.
        var runs: [ChineseRun] = []
        var index = 0
        while index < tokens.count {
            guard tokens[index].kind == .han, wantsPinyin(index) else { index += 1; continue }
            var end = index
            while end + 1 < tokens.count, tokens[end + 1].kind == .han, wantsPinyin(end + 1) { end += 1 }
            let runText = tokens[index...end].map(\.text).joined()
            let auto = Pinyin.syllables(for: runText, sandhi: sandhi)
            var syllables = auto
            if let override = overrides[runText] {
                let parts = override.split(whereSeparator: \.isWhitespace).map(String.init)
                if parts.count == auto.count { syllables = parts }
            }
            for (offset, syllable) in syllables.enumerated() {
                tokens[index + offset].pinyin = Pinyin.display(syllable, style: style)
            }
            runs.append(ChineseRun(firstToken: index, text: runText, syllables: syllables, autoSyllables: auto))
            index = end + 1
        }

        return ParsedScript(tokens: tokens, runs: runs, spokenWords: spokenWords)
    }

    /// Lowercased letters and digits only, so "Don't," matches the recognizer's "don't".
    static func normalize(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            .lowercased()
    }
}
