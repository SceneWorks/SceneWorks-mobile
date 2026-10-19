import Foundation
import Observation

/// The outcome of a save attempt, driving the result-area message.
enum SaveMessage: Equatable {
    /// The image is in the photo library.
    case saved
    /// Photos access is not allowed; the text says how to allow it.
    case photosAccessDenied
    /// The save itself threw.
    case saveFailed(String)
}

/// The view model behind the save/share controls that appear once a generation
/// has produced an image. It encodes the result to PNG, saves it to the photo
/// library through a `PhotoLibrarySaving`, and reports the outcome so the
/// screen shows either the confirmation or an actionable message.
@MainActor
@Observable
final class SaveViewModel {
    private(set) var message: SaveMessage?

    private let exporter: ImageExporter
    private let saver: any PhotoLibrarySaving

    init(exporter: ImageExporter = ImageExporter(), saver: any PhotoLibrarySaving) {
        self.exporter = exporter
        self.saver = saver
    }

    /// Encodes the result to PNG and adds it to the photo library. The PNG
    /// encoding and save run off the main actor; only the resulting message
    /// lands back here.
    func save(image: GeneratedImage, seed: UInt64) async {
        message = nil
        let exporter = self.exporter
        let saver = self.saver
        do {
            let png = try await Task.detached(priority: .userInitiated) {
                try exporter.pngData(image: image)
            }.value

            let result = try await saver.save(png: png)
            switch result {
            case .saved:
                message = .saved
            case .denied, .restricted:
                message = .photosAccessDenied
            }
        } catch {
            message = .saveFailed(error.localizedDescription)
        }
    }
}
