import AVKit
import SwiftUI

/// Camera with the teleprompter pinned under the lens. Record → stop → processed video.
struct RecordView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraRecorder()
    @StateObject private var prompter: PrompterController

    @State private var phase: Phase = .ready
    @State private var notice: String?
    @State private var showTextControls = false
    @State private var countdownTask: Task<Void, Never>?
    @State private var recordingStart = Date()
    @State private var savedToPhotos = false

    enum Phase {
        case ready
        case countdown(Int)
        case recording
        case processing(Double)
        case finished(RenderResult)
        case failed(String)
    }

    init(script: ParsedScript) {
        _prompter = StateObject(wrappedValue: PrompterController(script: script))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .processing(let progress):
                ProcessingView(progress: progress)
            case .finished(let result):
                ResultView(result: result, savedToPhotos: savedToPhotos, onRetake: retake, onDone: { dismiss() })
            default:
                recordingScreen
            }
        }
        .statusBarHidden()
        .task { await setUp() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            countdownTask?.cancel()
            prompter.stop()
            camera.stopSession()
        }
        .onChange(of: camera.errorMessage) { _, message in
            if let message { phase = .failed(message) }
        }
    }

    // MARK: - Screens

    private var recordingScreen: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    TeleprompterView(controller: prompter, template: store.template)
                        .frame(height: geometry.size.height * store.template.panelHeight)
                        .background(Color.black.opacity(store.template.panelOpacity))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 6)

                    if let notice = notice ?? prompter.speechStatus {
                        Text(notice)
                            .font(.footnote)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.horizontal)
                    }
                    Spacer()
                    if showTextControls && !isRecording {
                        TextControls(template: $store.template)
                            .padding(.horizontal)
                    }
                    controlBar
                }

                if let count = countdownValue {
                    Text("\(count)")
                        .font(.system(size: 140, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 12)
                }

                if let message = failureMessage {
                    VStack(spacing: 12) {
                        Text(message).multilineTextAlignment(.center)
                        Button("OK") { phase = .ready }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding()
                }
            }
        }
    }

    private var controlBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.title2.bold()).frame(width: 56, height: 56)
            }
            .disabled(isRecording)
            .opacity(isRecording ? 0 : 1)

            Spacer()

            Button(action: recordTapped) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 32, height: 32)
                    } else {
                        Circle().fill(.red).frame(width: 64, height: 64)
                    }
                }
            }
            .disabled(!camera.isConfigured)

            Spacer()

            if isRecording {
                TimelineView(.periodic(from: recordingStart, by: 1)) { context in
                    Text(elapsed(since: recordingStart, now: context.date))
                        .font(.headline.monospacedDigit())
                        .frame(width: 56, height: 56)
                }
            } else {
                Button {
                    withAnimation { showTextControls.toggle() }
                } label: {
                    Image(systemName: "textformat.size").font(.title2).frame(width: 56, height: 56)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Flow

    private var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    private var countdownValue: Int? {
        if case .countdown(let value) = phase { return value }
        return nil
    }

    private func setUp() async {
        let permissions = await CameraRecorder.requestPermissions()
        guard permissions.camera else {
            phase = .failed("AutoPrompter needs the camera. Turn it on in Settings → AutoPrompter.")
            return
        }
        if !permissions.microphone {
            notice = "Microphone is off: the video will be silent and the prompter can't follow your voice."
        }
        if store.template.scrollMode == .voice, permissions.microphone {
            let allowed = await PrompterController.requestSpeechPermission()
            if !allowed { notice = "Speech recognition is off, so the prompter will scroll at a constant speed." }
        }
        camera.configure(resolution: store.template.resolution, mirror: store.template.mirrorVideo)
    }

    private func recordTapped() {
        switch phase {
        case .recording:
            stopRecording()
        case .countdown:
            countdownTask?.cancel()
            phase = .ready
        default:
            showTextControls = false
            startCountdown()
        }
    }

    private func startCountdown() {
        countdownTask = Task { @MainActor in
            for count in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(count)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            let follower = self.prompter
            follower.reset()
            camera.onAudioSample = { buffer in follower.append(buffer) }
            camera.startRecording()
            follower.start(mode: store.template.scrollMode,
                           wordsPerMinute: store.template.wordsPerMinute,
                           localeIdentifier: store.template.speechLocale)
            recordingStart = Date()
            phase = .recording
        }
    }

    private func stopRecording() {
        prompter.stop()
        camera.stopRecording { result in
            switch result {
            case .success(let url):
                process(url)
            case .failure(let error):
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func process(_ url: URL) {
        phase = .processing(0)
        camera.stopSession()
        savedToPhotos = false
        let template = store.template
        let processor = VideoProcessor(template: template, backgroundImage: store.backgroundImage)
        Task { @MainActor in
            do {
                let result = try await processor.render(source: url) { value in
                    DispatchQueue.main.async {
                        if case .processing = phase { phase = .processing(value) }
                    }
                }
                if template.autoSaveToPhotos {
                    savedToPhotos = (try? await PhotoLibrary.saveVideo(at: result.url)) != nil
                }
                phase = .finished(result)
            } catch {
                phase = .failed("Processing failed: \(error.localizedDescription)")
                camera.configure(resolution: template.resolution, mirror: template.mirrorVideo)
            }
        }
    }

    private func retake() {
        prompter.reset()
        phase = .ready
        camera.configure(resolution: store.template.resolution, mirror: store.template.mirrorVideo)
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Live text adjustments while framing the shot. Changes are saved to the template.
struct TextControls: View {
    @Binding var template: Template

    var body: some View {
        VStack(spacing: 8) {
            slider("Size", value: $template.fontSize, range: 18...72)
            slider("Margins", value: $template.margin, range: 0...80)
            slider("Text", value: $template.textOpacity, range: 0.3...1)
            slider("Shade", value: $template.panelOpacity, range: 0...0.9)
            slider("Height", value: $template.panelHeight, range: 0.2...0.8)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}

struct ProcessingView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            Text(progress < 0.2 ? "Cleaning up the audio…" : "Replacing the background… \(Int(progress * 100))%")
                .font(.headline)
            Text("Keep the app open until this finishes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

struct ResultView: View {
    let result: RenderResult
    let onRetake: () -> Void
    let onDone: () -> Void
    @State private var player: AVPlayer
    @State private var saveMessage: String?
    @State private var saving = false

    init(result: RenderResult, savedToPhotos: Bool, onRetake: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.result = result
        self.onRetake = onRetake
        self.onDone = onDone
        _player = State(initialValue: AVPlayer(url: result.url))
        _saveMessage = State(initialValue: savedToPhotos ? "Saved to Photos" : nil)
    }

    var body: some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player)
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onAppear { player.play() }

            if let loudness = result.loudness {
                Text(String(format: "Audio normalised to %.1f LUFS", loudness))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await save() }
                } label: {
                    Label(saveMessage ?? "Save to Photos", systemImage: saveMessage == nil ? "square.and.arrow.down" : "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || saveMessage == "Saved to Photos")

                ShareLink(item: result.url) {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                Button("Record again", action: onRetake).buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Done", action: onDone).buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .onDisappear { player.pause() }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await PhotoLibrary.saveVideo(at: result.url)
            saveMessage = "Saved to Photos"
        } catch {
            saveMessage = error.localizedDescription
        }
    }
}
