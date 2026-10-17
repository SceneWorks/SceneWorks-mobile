import Foundation
import Observation

/// The view model behind the first-run provisioning screen. It drives a
/// `ModelProvisioner` run and reduces its byte-level progress to one overall
/// fraction, and keeps the states the screen renders.
@MainActor
@Observable
final class ProvisioningViewModel {
    enum State: Equatable {
        /// The release is fully present and verified; the generate screen shows.
        case ready
        /// Nothing has started, or a run just ended and can be started.
        case notReady
        /// A download is in flight.
        case downloading
        /// A run failed with a message and a Retry is offered.
        case failed
        /// There is not enough space; the required and available figures are shown.
        case noSpace
    }

    var state: State = .notReady
    /// The release's bytes so far, from the manifest — what the download fills in.
    private(set) var components: [ModelManifest.Component]
    /// The overall fraction downloaded, clamped and only ever increasing.
    private(set) var fraction: Double = 0
    /// A user-readable description of the last failure, present only while `state` is `.failed`.
    private(set) var errorMessage: String?
    /// What the failed precheck said it needed, in bytes, present while `state` is `.noSpace`.
    private(set) var requiredBytes: Int64?
    /// What the failed precheck found free, in bytes, present while `state` is `.noSpace`.
    private(set) var availableBytes: Int64?

    private let provisioner: ModelProvisioner
    private let manifest: ModelManifest
    private let storage: any StorageInspector
    private var provisionTask: Task<Void, Never>?

    init(provisioner: ModelProvisioner, manifest: ModelManifest, storage: any StorageInspector) {
        self.provisioner = provisioner
        self.manifest = manifest
        self.storage = storage
        self.components = manifest.components
    }

    /// Starts a provisioning run: `.ready` once the stream ends, `.failed` or
    /// `.noSpace` on a typed error.
    func start() {
        guard state != .downloading else { return }
        run()
    }

    /// Runs again after a failure.
    func retry() {
        guard state == .failed || state == .noSpace else { return }
        run()
    }

    /// The whole release is on disk and verified; no download needed. The
    /// determination is made by the provisioner, which owns the size and
    /// SHA-256 checks, so "ready" means usable — not merely present.
    func isReady() async -> Bool {
        await provisioner.isReleaseVerified()
    }

    /// Asks the storage inspector whether there is room for the whole release.
    /// When there is not, the state becomes `.noSpace` with the required and
    /// available figures, and no Download is offered.
    func checkStorage() async {
        let required = manifest.totalSize
        guard required > 0 else { return }
        let available = (try? await storage.availableCapacity()) ?? 0
        if available < required {
            state = .noSpace
            requiredBytes = required
            availableBytes = available
        }
    }

    private func run() {
        provisionTask?.cancel()
        state = .downloading
        errorMessage = nil
        requiredBytes = nil
        availableBytes = nil

        let provisioner = self.provisioner
        let total = manifest.totalSize
        provisionTask = Task { [weak self] in
            do {
                for try await update in await provisioner.provision() {
                    guard !Task.isCancelled else { return }
                    self?.apply(update: update, totalBytes: total)
                }
                guard !Task.isCancelled else { return }
                self?.state = .ready
                self?.fraction = 1
            } catch let error as ProvisioningError {
                guard !Task.isCancelled else { return }
                self?.settle(from: error)
            } catch is CancellationError {
                // start()/retry() replaced this run; the new one owns the state.
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Maps the provisioner's byte count to the overall fraction, clamped and
    /// never decreasing, so the progress bar only moves forward. Unit-tested.
    func apply(update: ProvisioningProgress, totalBytes: Int64) {
        guard totalBytes > 0 else {
            fraction = 1
            return
        }
        let next = min(1.0, max(0.0, Double(update.completedBytes) / Double(totalBytes)))
        fraction = max(fraction, next)
    }

    /// The overall fraction as a unit in [0, 1].
    ///
    /// Pure: given the manifest's sizes, this is what the screen shows. It is the
    /// unit-tested mapping from the provisioner's byte progress to a monotonic
    /// overall fraction.
    private func settle(from error: ProvisioningError) {
        switch error {
        case let .insufficientStorage(required, available):
            state = .noSpace
            requiredBytes = required
            availableBytes = available
            errorMessage = nil
        default:
            state = .failed
            errorMessage = error.localizedDescription
            requiredBytes = nil
            availableBytes = nil
        }
    }

    /// Stops an in-flight run and leaves the screen able to start again.
    func cancel() {
        provisionTask?.cancel()
        provisionTask = nil
        if state == .downloading {
            state = .notReady
        }
    }
}
