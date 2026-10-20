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
///
/// Save state is keyed by the identity of the result being saved, so a save
/// that finishes after a new generation has appeared never overwrites the
/// confirmation of the newer result.
@MainActor
@Observable
final class SaveViewModel {
    /// A marker for each distinct generated result. It carries a unique
    /// identity so two results are never equated — a stale completion is
    /// matched against the result it belongs to, and nothing else.
    struct ResultToken: Hashable, Sendable {
        private let identity = UUID()
    }

    private(set) var message: SaveMessage?
    /// The result the current `message` belongs to, so a stale completion is
    /// never shown against a different result.
    private(set) var messageResult: ResultToken?

    private let exporter: ImageExporter
    private let saver: any PhotoLibrarySaving

    init(exporter: ImageExporter = ImageExporter(), saver: any PhotoLibrarySaving) {
        self.exporter = exporter
        self.saver = saver
    }

    /// Clears any save outcome from a previous result. Called at the start of
    /// each new generation so a stale confirmation never shows under the new
    /// result.
    func reset() {
        message = nil
        messageResult = nil
    }

    /// The outcome, if any, belonging to `result`.
    func message(for result: ResultToken) -> SaveMessage? {
        messageResult == result ? message : nil
    }

    /// Encodes the result to PNG and adds it to the photo library. The PNG
    /// encoding and save run off the main actor; only the resulting message
    /// lands back here.
    func save(image: GeneratedImage, seed: UInt64, result: ResultToken) async {
        message = nil
        messageResult = result
        let exporter = self.exporter
        let saver = self.saver
        do {
            let png = try await Task.detached(priority: .userInitiated) {
                try exporter.pngData(image: image)
            }.value

            let outcome = try await saver.save(png: png)
            // The result may have been replaced while the save was in flight;
            // publish the outcome only if it still refers to the current result.
            guard messageResult == result else { return }
            switch outcome {
            case .saved:
                message = .saved
            case .denied, .restricted:
                message = .photosAccessDenied
            }
        } catch {
            guard messageResult == result else { return }
            message = .saveFailed(error.localizedDescription)
        }
    }
}
