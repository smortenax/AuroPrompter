import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

struct RenderResult {
    let url: URL
    /// Integrated loudness of the final audio, when it was processed.
    let loudness: Double?
}

/// Turns the raw recording into the finished video: background replaced on every frame,
/// audio cleaned up and normalised, scaled to the chosen resolution at 30 fps.
final class VideoProcessor {
    private let template: Template
    private let customBackground: CIImage?
    private let context = CIContext(options: [.cacheIntermediates: false])

    // Vision state is reused across frames (smoother masks); frames arrive one at a time but guard anyway.
    private let visionLock = NSLock()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var cachedBackground: (size: CGSize, image: CIImage)?

    init(template: Template, backgroundImage: UIImage?) {
        self.template = template
        if let backgroundImage {
            let oriented = CIImage(image: backgroundImage, options: [.applyOrientationProperty: true])
            customBackground = oriented
        } else {
            customBackground = nil
        }
    }

    func render(source: URL, progress: @escaping (Double) -> Void) async throws -> RenderResult {
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ProcessingError.noVideo }
        let duration = try await asset.load(.duration)
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        progress(0.02)

        // Audio
        var loudness: Double?
        if template.enhanceAudio, let decoded = try await AudioEnhancer.readMono(from: asset), !decoded.samples.isEmpty {
            let settings = AudioDSP.Settings(noiseReductionDB: template.noiseReductionDB,
                                             voiceEQ: template.voiceEQ,
                                             targetLUFS: template.targetLUFS)
            let samples = decoded.samples
            let result = await Task.detached(priority: .userInitiated) {
                AudioDSP.enhance(samples, sampleRate: AudioEnhancer.sampleRate, settings: settings)
            }.value
            let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).caf")
            try AudioEnhancer.write(result.samples, to: audioURL)
            let enhanced = AVURLAsset(url: audioURL)
            if let track = try await enhanced.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioDuration = try await enhanced.load(.duration)
                let start = CMTimeMaximum(decoded.start, .zero)
                let length = CMTimeMinimum(audioDuration, CMTimeSubtract(duration, start))
                if CMTimeCompare(length, .zero) > 0 {
                    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: start)
                }
            }
            loudness = result.outputLUFS.isFinite ? result.outputLUFS : nil
        } else if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = try await sourceAudio.load(.timeRange)
            try audioTrack.insertTimeRange(range, of: sourceAudio, at: range.start)
        }
        progress(0.2)

        // Video: background replacement per frame
        let renderSize = template.resolution.renderSize
        let videoComposition = try await AVMutableVideoComposition.videoComposition(
            with: composition,
            applyingCIFiltersWithHandler: { [self] request in
                let frame = composite(request.sourceImage, renderSize: renderSize)
                request.finish(with: frame, context: context)
            })
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        // Export
        let fileType: AVFileType = template.fileFormat == .mp4 ? .mp4 : .mov
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoPrompter-\(Self.timestamp()).\(template.fileFormat.rawValue)")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProcessingError.exportFailed
        }
        export.videoComposition = videoComposition
        export.outputFileType = fileType
        export.outputURL = outputURL
        export.shouldOptimizeForNetworkUse = true

        let monitor = Task {
            while !Task.isCancelled {
                progress(0.2 + 0.8 * Double(export.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        monitor.cancel()
        guard export.status == .completed else { throw export.error ?? ProcessingError.exportFailed }
        progress(1)
        try? FileManager.default.removeItem(at: source)
        return RenderResult(url: outputURL, loudness: loudness)
    }

    // MARK: - Per-frame compositing

    private func composite(_ source: CIImage, renderSize: CGSize) -> CIImage {
        let extent = source.extent
        var image = source
        if template.backgroundMode != .original, let mask = personMask(for: source) {
            let blend = CIFilter.blendWithMask()
            blend.inputImage = source
            blend.backgroundImage = background(for: source)
            blend.maskImage = mask
            image = blend.outputImage?.cropped(to: extent) ?? source
        }
        return aspectFill(image, into: renderSize)
    }

    private func personMask(for image: CIImage) -> CIImage? {
        visionLock.lock()
        defer { visionLock.unlock() }
        do {
            try sequenceHandler.perform([segmentation], on: image)
        } catch {
            return nil
        }
        guard let buffer = segmentation.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width,
                                                            y: image.extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
        // Soften the edge a touch so hair does not look cut out.
        return scaled.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: image.extent)
    }

    private func background(for source: CIImage) -> CIImage {
        let extent = source.extent
        switch template.backgroundMode {
        case .original:
            return source
        case .blur:
            return source.clampedToExtent().applyingGaussianBlur(sigma: template.blurRadius).cropped(to: extent)
        case .color:
            let c = template.backgroundColor
            return CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue)).cropped(to: extent)
        case .image:
            guard let customBackground else {
                return source.clampedToExtent().applyingGaussianBlur(sigma: template.blurRadius).cropped(to: extent)
            }
            visionLock.lock()
            defer { visionLock.unlock() }
            if let cached = cachedBackground, cached.size == extent.size {
                return cached.image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            }
            let filled = aspectFill(customBackground, into: extent.size)
            cachedBackground = (extent.size, filled)
            return filled.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        }
    }

    /// Scales and centre-crops `image` to exactly `size`, with its origin at zero.
    private func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        let scale = max(size.width / extent.width, size.height / extent.height)
        let dx = (size.width - extent.width * scale) / 2
        let dy = (size.height - extent.height * scale) / 2
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        return image.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
