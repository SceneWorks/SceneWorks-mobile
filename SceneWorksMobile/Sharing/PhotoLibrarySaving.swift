import Foundation
import Photos
import UIKit

/// The outcomes a Photos save can produce, so the caller can surface the right
/// message. `denied` and `restricted` are the authorization states under which
/// the caller explains how to allow Photos access; `saved` is success.
enum SaveResult: Sendable {
    case saved
    case denied
    case restricted
}

/// The seam for adding an image to the user's photo library. Production is
/// `PHPhotoLibraryPhotoSaver`; tests substitute a fake that reports the launch
/// environment's chosen authorization without touching the real library.
protocol PhotoLibrarySaving: Sendable {
    /// Saves the PNG to the photo library. `.saved` on success; `.denied` or
    /// `.restricted` when authorization blocks the add; otherwise throws.
    func save(png: Data) async throws -> SaveResult
}

/// The production saver: `PHPhotoLibrary` with add-only authorization, so the
/// system never asks to *read* the user's existing photos — only to add.
struct PHPhotoLibraryPhotoSaver: PhotoLibrarySaving {
    func save(png: Data) async throws -> SaveResult {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                switch status {
                case .authorized, .limited:
                    saveImage(data: png) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if success {
                            continuation.resume(returning: .saved)
                        } else {
                            continuation.resume(throwing: SaveError.photosAddFailed)
                        }
                    }
                case .denied, .restricted, .notDetermined:
                    // Not authorized to add (denied, restricted, or never asked yet):
                    // surface it so the caller explains how to allow Photos access.
                    continuation.resume(returning: status == .restricted ? .restricted : .denied)
                @unknown default:
                    continuation.resume(returning: .denied)
                }
            }
        }
    }

    private func saveImage(data: Data, completion: @escaping (Bool, Error?) -> Void) {
        guard let uiImage = UIImage(data: data) else {
            completion(false, SaveError(message: "Could not decode the image to save."))
            return
        }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
        } completionHandler: { success, error in
            completion(success, error)
        }
    }
}

/// A failure adding to Photos that is not a plain authorization denial.
struct SaveError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }

    static let photosAddFailed = SaveError(message: "The image could not be added to Photos.")
}
