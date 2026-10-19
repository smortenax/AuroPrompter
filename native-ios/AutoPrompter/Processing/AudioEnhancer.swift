import AVFoundation

/// Moves audio between movie files and the `AudioDSP` chain.
enum AudioEnhancer {
    static let sampleRate = 48_000.0

    struct Decoded {
        var samples: [Float]
        /// Where the first sample sits on the movie's timeline.
        var start: CMTime
    }

    /// Decodes the first audio track to mono 48 kHz floats. Returns nil when there is no audio.
    static func readMono(from asset: AVAsset) async throws -> Decoded? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProcessingError.audioRead }

        var samples: [Float] = []
        var start: CMTime?
        while let buffer = output.copyNextSampleBuffer() {
            if start == nil { start = CMSampleBufferGetPresentationTimeStamp(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var chunk = [Float](repeating: 0, count: count)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
        }
        if reader.status == .failed { throw reader.error ?? ProcessingError.audioRead }
        return Decoded(samples: samples, start: start ?? .zero)
    }

    /// Writes mono floats to a 32-bit float CAF file.
    static func write(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else { throw ProcessingError.audioWrite }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunkSize = 65_536
        var offset = 0
        while offset < samples.count {
            let count = min(chunkSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { throw ProcessingError.audioWrite }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + offset, count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}

enum ProcessingError: LocalizedError {
    case noVideo, audioRead, audioWrite, exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: return "The recording has no video."
        case .audioRead: return "The recording's audio could not be read."
        case .audioWrite: return "The cleaned-up audio could not be saved."
        case .exportFailed: return "The final video could not be exported."
        }
    }
}
