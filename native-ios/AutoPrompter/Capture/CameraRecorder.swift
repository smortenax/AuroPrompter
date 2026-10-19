import AVFoundation
import SwiftUI

/// Front-camera capture that writes a portrait movie and hands microphone audio to the teleprompter.
final class CameraRecorder: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var isRecording = false
    @Published private(set) var isConfigured = false
    @Published var errorMessage: String?

    /// Called on the capture queue with every microphone buffer while recording.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "autoprompter.session")
    /// Video and audio callbacks share one queue so the writer is only ever touched from here.
    private let captureQueue = DispatchQueue(label: "autoprompter.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // Writer state, capture queue only.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var wantsRecording = false
    private var writerStarted = false
    private var stopCompletion: ((Result<URL, Error>) -> Void)?

    static func requestPermissions() async -> (camera: Bool, microphone: Bool) {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return (camera, microphone)
    }

    func configure(resolution: ExportResolution, mirror: Bool) {
        sessionQueue.async { [self] in
            guard session.inputs.isEmpty else {
                if !session.isRunning { session.startRunning() }
                return
            }
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async { self.isConfigured = true }
            }

            let preset: AVCaptureSession.Preset = resolution == .uhd4K ? .hd4K3840x2160 : .hd1920x1080
            session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .hd1920x1080

            let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            guard let camera = device, let cameraInput = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(cameraInput) else {
                report("The front camera is not available.")
                return
            }
            session.addInput(cameraInput)
            lockFrameRate(camera, fps: 30)

            if let microphone = AVCaptureDevice.default(for: .audio),
               let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
               session.canAddInput(microphoneInput) {
                session.addInput(microphoneInput)
            }

            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirror
                }
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .standard }
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func startRecording() {
        captureQueue.async { [self] in
            writer = nil
            videoInput = nil
            audioInput = nil
            writerStarted = false
            wantsRecording = true
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        captureQueue.async { [self] in
            wantsRecording = false
            DispatchQueue.main.async { self.isRecording = false }
            guard let writer, writerStarted else {
                DispatchQueue.main.async { completion(.failure(RecorderError.nothingRecorded)) }
                return
            }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        completion(.success(writer.outputURL))
                    } else {
                        completion(.failure(writer.error ?? RecorderError.nothingRecorded))
                    }
                }
            }
            self.writer = nil
        }
    }

    // MARK: - Private

    private func lockFrameRate(_ device: AVCaptureDevice, fps: Int32) {
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: fps)
            let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
            }
            if supported {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            // Keep the format's default rate.
        }
    }

    private func startWriter(with sampleBuffer: CMSampleBuffer) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-\(UUID().uuidString).mov")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else { throw RecorderError.writerSetup }
            writer.add(videoInput)

            if let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    self.audioInput = audioInput
                }
            }
            guard writer.startWriting() else { throw writer.error ?? RecorderError.writerSetup }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            self.writer = writer
            self.videoInput = videoInput
            writerStarted = true
        } catch {
            wantsRecording = false
            report("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isRecording = false
        }
    }

    enum RecorderError: LocalizedError {
        case nothingRecorded, writerSetup
        var errorDescription: String? {
            switch self {
            case .nothingRecorded: return "Nothing was recorded."
            case .writerSetup: return "The video writer could not be set up."
            }
        }
    }
}

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard wantsRecording else { return }

        if output === videoOutput {
            if !writerStarted { startWriter(with: sampleBuffer) }
            if let videoInput, videoInput.isReadyForMoreMediaData, writer?.status == .writing {
                videoInput.append(sampleBuffer)
            }
        } else if output === audioOutput {
            onAudioSample?(sampleBuffer)
            if writerStarted, let audioInput, audioInput.isReadyForMoreMediaData, writer?.status == .writing {
                audioInput.append(sampleBuffer)
            }
        }
    }
}
