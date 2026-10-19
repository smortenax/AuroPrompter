import Foundation

/// Works out where in the script the speaker is from the speech recognizer's running transcript.
/// Only moves forward, and only on a confident match, so a misheard word never jumps the text around.
struct ScriptMatcher {
    let words: [String]
    /// Index of the next word the speaker is expected to say.
    private(set) var position = 0

    private let tailLength = 4
    private let lookBehind = 2
    private let lookAhead = 25

    init(words: [String]) {
        self.words = words
    }

    mutating func jump(to wordIndex: Int) {
        position = max(0, min(wordIndex, words.count))
    }

    /// Feed the whole transcript recognised so far. Returns true when the position moved.
    @discardableResult
    mutating func update(transcript: String) -> Bool {
        let heard = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map { ScriptParser.normalize(String($0)) }
            .filter { !$0.isEmpty }
        guard !heard.isEmpty, !words.isEmpty else { return false }
        let tail = Array(heard.suffix(tailLength))

        let lower = max(0, position - lookBehind)
        let upper = min(words.count - 1, position + lookAhead)
        guard lower <= upper else { return false }

        var best: (end: Int, score: Int)?
        for end in lower...upper {
            var score = 0
            for k in 0..<tail.count {
                let scriptIndex = end - k
                if scriptIndex < 0 { break }
                if similar(words[scriptIndex], tail[tail.count - 1 - k]) { score += 1 }
            }
            // The newest heard word must match the candidate end.
            guard similar(words[end], tail[tail.count - 1]) else { continue }
            // Prefer more agreeing words, then the candidate closest to where we already are.
            if best == nil || score > best!.score ||
                (score == best!.score && abs(end - position) < abs(best!.end - position)) {
                best = (end, score)
            }
        }

        guard let match = best else { return false }
        let required = tail.count >= 2 ? 2 : 1
        let distance = match.end - position
        // A single matching word is only trusted right next to the current position.
        if match.score < required && distance > 2 { return false }
        let newPosition = match.end + 1
        guard newPosition > position else { return false }
        position = newPosition
        return true
    }

    private func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        // Tolerate small recognition differences: "color"/"colour", "organise"/"organize".
        return a.hasPrefix(String(b.prefix(4))) && editDistance(a, b) <= max(1, min(a.count, b.count) / 4)
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }
}
