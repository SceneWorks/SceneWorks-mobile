import CryptoKit
import Foundation

/// What went wrong while provisioning a model release.
enum ProvisioningError: Error, Equatable, LocalizedError {
    /// The bytes on disk are not the bytes the manifest promises, by size or by digest.
    case integrityFailed(component: String)
    /// There is not enough free space for the bytes still to download.
    case insufficientStorage(required: Int64, available: Int64)
    /// The transfer answered with a status the provisioner cannot use.
    case transferFailed(component: String, status: Int)
    /// The server answered a resume request in a way that does not continue the file.
    case resumeRejected(component: String, status: Int)
    /// The manifest points at a path outside the version's directory.
    case invalidComponentPath(path: String)
    /// A file operation failed.
    case fileSystemFailed(String)
    /// The transfer itself failed: the connection dropped, or the session gave up.
    case transferError(component: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .integrityFailed(component):
            return "The downloaded \(component) does not match the manifest's size or SHA-256."
        case let .insufficientStorage(required, available):
            return "Not enough storage: \(required) bytes needed, \(available) available."
        case let .transferFailed(component, status):
            return "Downloading \(component) failed with HTTP status \(status)."
        case let .resumeRejected(component, status):
            return "Resuming \(component) was answered with HTTP status \(status)."
        case let .invalidComponentPath(path):
            return "The manifest component path \(path) is outside the models directory."
        case let .fileSystemFailed(detail):
            return "The models directory could not be prepared: \(detail)"
        case let .transferError(component, detail):
            return "Downloading \(component) failed: \(detail)"
        }
    }
}

/// How far a provisioning run has got, in bytes.
struct ProvisioningProgress: Equatable, Sendable {
    /// Bytes already on disk and verified, plus bytes written by this run.
    let completedBytes: Int64
    /// The bytes the whole release weighs.
    let totalBytes: Int64

    var fractionCompleted: Double {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
    }
}

/// Downloads a model release into Application Support, resuming interrupted
/// transfers and verifying every component before it is moved into place.
///
/// The session, the storage inspector and the models directory are injected, so
/// tests drive it with a fake `URLProtocol`, a fake inspector and a temp directory.
actor ModelProvisioner {
    /// The extension a component carries while it is still being written.
    static let partialExtension = "partial"
    /// How many bytes are buffered before they hit the partial file.
    private static let writeChunkBytes = 4_096

    private let manifest: ModelManifest
    private let session: URLSession
    private let storage: any StorageInspector
    private let modelsDirectory: URL
    private let fileManager: FileManager

    init(
        manifest: ModelManifest,
        session: URLSession,
        storage: any StorageInspector,
        modelsDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.manifest = manifest
        self.session = session
        self.storage = storage
        self.modelsDirectory = modelsDirectory
        self.fileManager = fileManager
    }

    /// The production wiring: Application Support's `Models` directory and the free space of
    /// the volume it sits on. The session stays injected, so the source is one seam (E2).
    static func live(manifest: ModelManifest, session: URLSession) throws -> ModelProvisioner {
        ModelProvisioner(
            manifest: manifest,
            session: session,
            storage: try VolumeStorageInspector.applicationSupportVolume(),
            modelsDirectory: try applicationSupportModelsDirectory()
        )
    }

    /// `Application Support/Models` — never Documents, so the models are not user-visible.
    static func applicationSupportModelsDirectory() throws -> URL {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return support.appendingPathComponent("Models", isDirectory: true)
        } catch {
            throw ProvisioningError.fileSystemFailed((error as NSError).localizedDescription)
        }
    }

    /// The directory this release's components live in: `<models>/<version>`.
    var versionDirectory: URL {
        modelsDirectory.appendingPathComponent(manifest.version, isDirectory: true)
    }

    /// Whether every component of this release is on disk and verified (size and
    /// SHA-256), so no download is needed. Owned here, where the verification
    /// logic lives, so the "ready" determination cannot drift from what
    /// `provision()` considers usable. A manifest pointing outside the models
    /// directory is not a verified release.
    func isReleaseVerified() -> Bool {
        let directory = versionDirectory
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        for component in manifest.components {
            guard let destination = try? destinationURL(for: component),
                  (try? verifiedSize(of: component, at: destination)) != nil else { return false }
        }
        return true
    }

    /// Brings every component of the manifest onto disk, verified.
    ///
    /// Yields progress as bytes land and finishes when the release is complete.
    /// Cancelling the consuming task stops the transfer in flight (E6).
    func provision() -> AsyncThrowingStream<ProvisioningProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(reportingTo: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func run(
        reportingTo continuation: AsyncThrowingStream<ProvisioningProgress, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        try prepareDirectories()

        let total = manifest.totalSize
        var completed: Int64 = 0
        var pending: [ModelManifest.Component] = []

        // What is already here, and what is still missing.
        for component in manifest.components {
            try Task.checkCancellation()
            do {
                let destination = try destinationURL(for: component)
                if let verified = try verifiedSize(of: component, at: destination) {
                    // Already present and verified: never downloaded again.
                    completed += verified
                    continuation.yield(ProvisioningProgress(completedBytes: completed, totalBytes: total))
                } else {
                    pending.append(component)
                }
            } catch {
                throw typed(error)
            }
        }

        // Before any request: is there room for everything still to download?
        let required: Int64
        do {
            required = try pending.reduce(Int64(0)) { sum, component in
                let partial = partialURL(for: try destinationURL(for: component))
                return sum + max(0, Int64(component.size) - sizeIfPresent(at: partial))
            }
        } catch {
            throw typed(error)
        }
        if required > 0 {
            let available: Int64
            do {
                available = try await storage.availableCapacity()
            } catch {
                throw typed(error)
            }
            guard available >= required else {
                throw ProvisioningError.insufficientStorage(required: required, available: available)
            }
        }

        for component in pending {
            try Task.checkCancellation()
            do {
                completed += try await download(
                    component,
                    to: try destinationURL(for: component),
                    alreadyComplete: completed,
                    totalBytes: total,
                    reportingTo: continuation
                )
            } catch {
                throw typedTransfer(error, component: component)
            }
        }
    }

    // MARK: - Typed failures

    /// Wraps an underlying error in `ProvisioningError`, so nothing escapes the provisioning
    /// error type. Cancellation keeps its own identity (E6).
    private func typed(_ error: Error) -> Error {
        if error is CancellationError || error is ProvisioningError { return error }
        return ProvisioningError.fileSystemFailed(describe(error))
    }

    /// The same, for a failure of the transfer itself rather than of the file system.
    private func typedTransfer(_ error: Error, component: ModelManifest.Component) -> Error {
        if error is CancellationError || error is ProvisioningError { return error }
        return ProvisioningError.transferError(component: component.name, detail: describe(error))
    }

    private func describe(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }

    // MARK: - Directories

    /// Creates the models directory and excludes it, and everything under it, from backup (E7).
    private func prepareDirectories() throws {
        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            try modelsDirectory.excludeFromBackup()
        } catch {
            throw typed(error)
        }
    }

    private func destinationURL(for component: ModelManifest.Component) throws -> URL {
        let destination = versionDirectory.appendingPathComponent(component.path)
        let root = versionDirectory.standardizedFileURL.path
        let path = destination.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else {
            throw ProvisioningError.invalidComponentPath(path: component.path)
        }
        return destination
    }

    private func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension(Self.partialExtension)
    }

    // MARK: - Verification

    /// The component's size when it is already on disk and matches the manifest, else `nil`.
    private func verifiedSize(of component: ModelManifest.Component, at destination: URL) throws -> Int64? {
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        let size = try fileSize(at: destination)
        guard size == component.size else { return nil }
        guard try sha256(ofFileAt: destination) == component.sha256.lowercased() else { return nil }
        return size
    }

    private func sizeIfPresent(at url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        return (try? fileSize(at: url)) ?? 0
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw ProvisioningError.fileSystemFailed("No size for \(url.path).")
        }
        return size.int64Value
    }

    /// Streams the file through SHA-256, so a large component is never held in memory.
    private func sha256(ofFileAt url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", Int($0)) }.joined()
    }

    // MARK: - Transfer

    /// Writes the component to its `.partial` file, resuming after an interrupted transfer,
    /// then verifies it and moves it into place. Returns the bytes it added.
    private func download(
        _ component: ModelManifest.Component,
        to destination: URL,
        alreadyComplete: Int64,
        totalBytes: Int64,
        reportingTo continuation: AsyncThrowingStream<ProvisioningProgress, Error>.Continuation
    ) async throws -> Int64 {
        let partial = partialURL(for: destination)
        do {
            if sizeIfPresent(at: partial) > Int64(component.size) {
                // A partial left over from another release: start over.
                try? fileManager.removeItem(at: partial)
            }
            try fileManager.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: partial.path),
               !fileManager.createFile(atPath: partial.path, contents: nil) {
                throw ProvisioningError.fileSystemFailed("Could not create \(partial.path).")
            }
        } catch {
            throw typed(error)
        }

        // Keep asking for the rest until the file is the size the manifest promises.
        while sizeIfPresent(at: partial) < Int64(component.size) {
            try Task.checkCancellation()
            let before = sizeIfPresent(at: partial)
            do {
                try await transferBody(
                    component,
                    to: partial,
                    alreadyComplete: alreadyComplete,
                    totalBytes: totalBytes,
                    reportingTo: continuation
                )
                // The server answered in full but the file is still short: nothing left to ask for.
                if sizeIfPresent(at: partial) <= before { break }
            } catch let error as CancellationError {
                throw error
            } catch let error as ProvisioningError {
                throw error
            } catch {
                // The connection dropped. Keep what landed and resume from it, but only
                // while this attempt actually moved the file forward.
                if sizeIfPresent(at: partial) <= before { throw typedTransfer(error, component: component) }
            }
        }

        let size: Int64
        let digest: String
        do {
            size = try fileSize(at: partial)
            digest = try sha256(ofFileAt: partial)
        } catch {
            throw typed(error)
        }
        guard size == component.size, digest == component.sha256.lowercased() else {
            // An untrustworthy partial must not survive to poison the next attempt.
            try? fileManager.removeItem(at: partial)
            throw ProvisioningError.integrityFailed(component: component.name)
        }

        // Only a fully verified component is moved into place (E7).
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            throw typed(error)
        }
        return size
    }

    /// One attempt at the transfer. A transport failure is left as it is: `download` decides
    /// whether it is a drop to resume from or a terminal failure to report as a typed error.
    private func transferBody(
        _ component: ModelManifest.Component,
        to partial: URL,
        alreadyComplete: Int64,
        totalBytes: Int64,
        reportingTo continuation: AsyncThrowingStream<ProvisioningProgress, Error>.Continuation
    ) async throws {
        let requestedOffset = sizeIfPresent(at: partial)

        var request = URLRequest(url: component.url)
        if requestedOffset > 0 {
            // Range, not URLSession resume data: a fake URLProtocol cannot produce the latter.
            request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProvisioningError.transferFailed(component: component.name, status: 0)
        }

        let start: Int64
        switch http.statusCode {
        case 200:
            start = 0 // the whole file, from the top
        case 206 where requestedOffset > 0:
            start = requestedOffset
        case 206:
            throw ProvisioningError.resumeRejected(component: component.name, status: http.statusCode)
        default:
            throw ProvisioningError.transferFailed(component: component.name, status: http.statusCode)
        }

        let handle = try FileHandle(forWritingTo: partial)
        var written = start
        var buffer = Data()
        buffer.reserveCapacity(Self.writeChunkBytes)
        do {
            if start == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                _ = try handle.seekToEnd()
            }

            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                written += 1
                if buffer.count >= Self.writeChunkBytes {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    continuation.yield(
                        ProvisioningProgress(completedBytes: alreadyComplete + written, totalBytes: totalBytes)
                    )
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            try handle.synchronize()
        } catch {
            // Land what we have, so the next attempt can resume from it.
            if !buffer.isEmpty { try? handle.write(contentsOf: buffer) }
            try? handle.close()
            throw error
        }
        try handle.close()

        continuation.yield(ProvisioningProgress(completedBytes: alreadyComplete + written, totalBytes: totalBytes))
    }
}

private extension URL {
    /// Marks a directory, and everything under it, as excluded from iCloud backup.
    func excludeFromBackup() throws {
        var url = self
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}