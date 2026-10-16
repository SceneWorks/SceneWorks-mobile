import Foundation

/// How much room is left for the model bytes about to be written.
protocol StorageInspector: Sendable {
    /// The bytes the system considers free for important usage on the models' volume.
    func availableCapacity() async throws -> Int64
}

/// The production inspector: the volume that holds the app's Application Support directory.
struct VolumeStorageInspector: StorageInspector {
    /// Any path on the volume to measure.
    let volume: URL

    /// The volume the app's Application Support directory lives on.
    static func applicationSupportVolume() throws -> VolumeStorageInspector {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return VolumeStorageInspector(volume: support)
    }

    func availableCapacity() async throws -> Int64 {
        let values = try volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw ProvisioningError.fileSystemFailed("No free-space figure for \(volume.path).")
        }
        return capacity
    }
}