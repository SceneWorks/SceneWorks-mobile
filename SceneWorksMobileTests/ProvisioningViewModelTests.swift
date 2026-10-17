import Foundation
import Testing
@testable import SceneWorksMobile

/// A no-op `ModelProvisioner` the view model tests construct: the tests drive
/// `apply` directly and never start a run, so nothing is provisioned.
private let unreadyManifest = ModelManifest(version: "test", components: [])
private func idleProvisioner() -> ModelProvisioner {
    ModelProvisioner(
        manifest: unreadyManifest,
        session: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = []
            return URLSession(configuration: configuration)
        }(),
        storage: FakeStorageInspectorStub(),
        modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("vm-\(UUID().uuidString)", isDirectory: true)
    )
}

private struct FakeStorageInspectorStub: StorageInspector {
    func availableCapacity() async throws -> Int64 { 0 }
}

struct ProvisioningViewModelTests {
    @Test @MainActor func overallFractionIsMonotonicFromZeroToOne() async throws {
        let viewModel = ProvisioningViewModel(provisioner: idleProvisioner(), manifest: unreadyManifest, storage: FakeStorageInspectorStub())
        #expect(viewModel.fraction == 0)

        // A run that lands a series of byte counts, including one that retreats
        // (a re-read of an earlier offset): the fraction must only climb, from 0 to 1.
        let total: Int64 = 10_000
        let completedSeries: [Int64] = [0, 2_500, 2_500, 6_000, 4_000, 9_000, 10_000]
        for completed in completedSeries {
            viewModel.apply(update: ProvisioningProgress(completedBytes: completed, totalBytes: total), totalBytes: total)
        }

        #expect(viewModel.fraction == 1)
    }

    @Test @MainActor func fractionNeverDecreasesAsUpdatesArrive() async throws {
        let viewModel = ProvisioningViewModel(provisioner: idleProvisioner(), manifest: unreadyManifest, storage: FakeStorageInspectorStub())
        let total: Int64 = 1_000

        var previous = viewModel.fraction
        for completed in [100, 500, 300, 700, 900, 1_000] {
            viewModel.apply(update: ProvisioningProgress(completedBytes: Int64(completed), totalBytes: total), totalBytes: total)
            #expect(viewModel.fraction >= previous)
            previous = viewModel.fraction
        }
        #expect(viewModel.fraction == 1)
    }

    @Test @MainActor func fractionIsClampedToUnitInterval() async throws {
        let viewModel = ProvisioningViewModel(provisioner: idleProvisioner(), manifest: unreadyManifest, storage: FakeStorageInspectorStub())
        let total: Int64 = 1_000

        // A byte count above the total clamps to 1, never past it.
        viewModel.apply(update: ProvisioningProgress(completedBytes: 5_000, totalBytes: total), totalBytes: total)
        #expect(viewModel.fraction == 1)

        // A fresh view model maps zero to zero.
        let fresh = ProvisioningViewModel(provisioner: idleProvisioner(), manifest: unreadyManifest, storage: FakeStorageInspectorStub())
        #expect(fresh.fraction == 0)
        fresh.apply(update: ProvisioningProgress(completedBytes: 0, totalBytes: total), totalBytes: total)
        #expect(fresh.fraction == 0)
    }
}
