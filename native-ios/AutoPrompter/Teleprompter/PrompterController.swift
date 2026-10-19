import AVFoundation
import Speech
import SwiftUI

/// Drives the teleprompter position, either from the speaker's voice or at a constant speed.
final class PrompterController: ObservableObject {
    let script: ParsedScript
    /// The token the speaker is about to read.
    @Published private(set) var currentToken: Int = 0
    @Published private(set) var speechStatus: String?

    private var matcher: ScriptMatcher
    private let matcherLock = NSLock()
    private var timer: Timer?
    private var mode: ScrollMode = .voice

    // Speech recognition. `request` is touched from the capture queue, so it is guarded by a lock.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let requestLock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var running = false

    init(script: ParsedScript) {
        self.script = script
        matcher = ScriptMatcher(words: script.spokenWords.map(\.normalized))
        currentToken = script.spokenWords.first?.tokenIndex ?? 0
    }

    static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Start / stop

    func start(mode: ScrollMode, wordsPerMinute: Double, localeIdentifier: String) {
        self.mode = mode
        running = true
        switch mode {
        case .constant:
            let interval = 60.0 / max(40, wordsPerMinute)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.advanceOneWord()
            }
        case .voice:
            let candidate = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) ?? SFSpeechRecognizer()
            guard let recognizer = candidate, recognizer.isAvailable,
                  SFSpeechRecognizer.authorizationStatus() == .authorized else {
                speechStatus = "Voice following is unavailable, scrolling at a constant speed instead."
                start(mode: .constant, wordsPerMinute: wordsPerMinute, localeIdentifier: localeIdentifier)
                return
            }
            self.recognizer = recognizer
            startRecognitionTask()
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        task?.cancel()
        task = nil
    }

    /// Tap on a word to resync the prompter from there.
    func jump(toToken tokenIndex: Int) {
        let wordIndex = script.spokenWords.firstIndex { $0.tokenIndex >= tokenIndex } ?? script.spokenWords.count
        matcherLock.lock()
        matcher.jump(to: wordIndex)
        matcherLock.unlock()
        publish(wordIndex: wordIndex)
    }

    func reset() {
        jump(toToken: 0)
    }

    /// Microphone audio from the camera capture session.
    func append(_ sampleBuffer: CMSampleBuffer) {
        requestLock.lock()
        request?.appendAudioSampleBuffer(sampleBuffer)
        requestLock.unlock()
    }

    // MARK: - Internals

    private func startRecognitionTask() {
        guard running, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = Array(Set(script.spokenWords.map(\.normalized)).prefix(100))
        requestLock.lock()
        self.request = request
        requestLock.unlock()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.handle(transcript: result.bestTranscription.formattedString)
            }
            if error != nil || (result?.isFinal ?? false) {
                // Recognition tasks end on long pauses or time limits: start a new one and keep following.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.running, self.request === request else { return }
                    self.task?.cancel()
                    self.startRecognitionTask()
                }
            }
        }
    }

    private func handle(transcript: String) {
        matcherLock.lock()
        let moved = matcher.update(transcript: transcript)
        let position = matcher.position
        matcherLock.unlock()
        if moved { publish(wordIndex: position) }
    }

    private func advanceOneWord() {
        matcherLock.lock()
        matcher.jump(to: matcher.position + 1)
        let position = matcher.position
        matcherLock.unlock()
        publish(wordIndex: position)
    }

    private func publish(wordIndex: Int) {
        let token: Int
        if wordIndex < script.spokenWords.count {
            token = script.spokenWords[wordIndex].tokenIndex
        } else {
            token = script.tokens.count
        }
        DispatchQueue.main.async { self.currentToken = token }
    }
}
