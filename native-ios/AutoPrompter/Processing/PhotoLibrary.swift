import Photos

enum PhotoLibrary {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "AutoPrompter is not allowed to add videos to Photos. You can allow it in Settings." }
    }

    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
