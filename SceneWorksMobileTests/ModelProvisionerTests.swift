import CryptoKit
import Foundation
import Testing
@testable import SceneWorksMobile

/// An in-process "server" for one test, found by `FakeModelProtocol` through the request's host.
private final class FakeModelServer: @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [String: FakeModelServer] = [:]

    let host = "fake-\(UUID().uuidString.lowercased()).example.invalid"
    private let stateLock = NSLock()
    private var bodies: [String: Data] = [:]
    private var cutOffAfter: [String: Int] = [:]
    private var recorded: [URLRequest] = []
    private var servedBytes: [String: Int] = [:]

    init() {
        Self.lock.lock()
        Self.servers[host] = self
        Self.lock.unlock()
    }

    deinit {
        Self.lock.lock()
        Self.servers[host] = nil
        Self.lock.unlock()
    }

    static func server(for request: URLRequest) -> FakeModelServer? {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host.flatMap { servers[$0] }
    }

    func url(_ name: String) -> URL { URL(string: "https://\(host)/\(name)")! }

    func serve(_ name: String, body: Data, cutOffFirstResponseAfter: Int? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        bodies[name] = body
        cutOffAfter[name] = cutOffFirstResponseAfter
    }

    var requests: [URLRequest] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recorded
    }

    func totalServed(_ name: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return servedBytes[name, default: 0]
    }

    /// The status, the bytes to send and whether to drop the connection after them.
    func answer(_ request: URLRequest) -> (status: Int, body: Data, dropAfterBody: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        recorded.append(request)

        let name = String(request.url?.path.dropFirst() ?? "")
        guard let full = bodies[name] else { return (404, Data(), false) }

        var status = 200
        var body = full
        if let range = request.value(forHTTPHeaderField: "Range"),
           let offset = Int(range.dropFirst("bytes=".count).dropLast()) {
            status = 206
            body = full.dropFirst(offset)
        }

        var drop = false
        if let limit = cutOffAfter[name] {
            cutOffAfter[name] = nil
            body = body.prefix(limit)
            drop = true
        }
        servedBytes[name, default: 0] += body.count
        return (status, Data(body), drop)
    }
}

private final class FakeModelProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let server = FakeModelServer.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let answer = server.answer(request)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        // A cut-off ends the body early, short of what was promised.
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FakeStorageInspector: StorageInspector {
    let available: Int64
    func availableCapacity() async throws -> Int64 { available }
}

struct ModelProvisionerTests {
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }

    private func bytes(count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeModelProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provisioner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func provisioner(
        _ manifest: ModelManifest,
        in directory: URL,
        available: Int64 = .max
    ) -> ModelProvisioner {
        ModelProvisioner(
            manifest: manifest,
            session: makeSession(),
            storage: FakeStorageInspector(available: available),
            modelsDirectory: directory.appendingPathComponent("Models", isDirectory: true)
        )
    }

    private func run(_ provisioner: ModelProvisioner) async throws -> [ProvisioningProgress] {
        var updates: [ProvisioningProgress] = []
        for try await update in await provisioner.provision() {
            updates.append(update)
        }
        return updates
    }

    @Test func interruptedTransferResumesWithRangeAndDoesNotRestart() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeModelServer()
        let body = bytes(count: 20_000, seed: 1)
        let cutoff = 7_500
        server.serve("weights.bin", body: body, cutOffFirstResponseAfter: cutoff)
        let manifest = ModelManifest(version: "1", components: [
            .init(name: "weights", path: "weights.bin", url: server.url("weights.bin"), size: Int64(body.count), sha256: sha256(body)),
        ])
        let provisioner = provisioner(manifest, in: directory)

        let updates = try await run(provisioner)

        #expect(server.requests.count == 2)
        #expect(server.requests[0].value(forHTTPHeaderField: "Range") == nil)
        #expect(server.requests[1].value(forHTTPHeaderField: "Range") == "bytes=\(cutoff)-")
        #expect(server.totalServed("weights.bin") == body.count)
        let final = await provisioner.versionDirectory.appendingPathComponent("weights.bin")
        #expect(try Data(contentsOf: final) == body)
        #expect(updates.last == ProvisioningProgress(completedBytes: Int64(body.count), totalBytes: Int64(body.count)))
    }

    @Test func mismatchingBytesFailIntegrityAndNeverReachTheFinalPath() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeModelServer()
        let truncated = bytes(count: 4_000, seed: 2)
        let wrong = bytes(count: 5_000, seed: 3)
        let expectedFull = bytes(count: 5_000, seed: 4)
        server.serve("short.bin", body: truncated)
        server.serve("wrong.bin", body: wrong)
        let makeManifest = { (name: String, size: Int) in
            ModelManifest(version: "1", components: [
                .init(name: name, path: "\(name).bin", url: server.url("\(name).bin"), size: Int64(size), sha256: self.sha256(expectedFull)),
            ])
        }

        for (name, size) in [("short", 5_000), ("wrong", 5_000)] {
            let provisioner = provisioner(makeManifest(name, size), in: directory)
            await #expect(throws: ProvisioningError.integrityFailed(component: name)) {
                _ = try await run(provisioner)
            }
            let final = await provisioner.versionDirectory.appendingPathComponent("\(name).bin")
            #expect(!FileManager.default.fileExists(atPath: final.path))
        }
    }

    @Test func verifiedComponentsAreKeptAndBackupExclusionReadsBack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeModelServer()
        let first = bytes(count: 3_000, seed: 5)
        let second = bytes(count: 6_000, seed: 6)
        server.serve("a.bin", body: first)
        server.serve("b.bin", body: second)
        let manifest = ModelManifest(version: "2", components: [
            .init(name: "a", path: "a.bin", url: server.url("a.bin"), size: Int64(first.count), sha256: sha256(first)),
            .init(name: "b", path: "sub/b.bin", url: server.url("b.bin"), size: Int64(second.count), sha256: sha256(second)),
        ])

        _ = try await run(provisioner(manifest, in: directory))
        #expect(server.requests.count == 2)

        // A second run finds both verified and sends no request.
        _ = try await run(provisioner(manifest, in: directory))
        #expect(server.requests.count == 2)

        let models = directory.appendingPathComponent("Models", isDirectory: true)
        let values = try models.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(FileManager.default.fileExists(atPath: models.appendingPathComponent("2/sub/b.bin").path))
    }

    @Test func insufficientStorageFailsBeforeAnyRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeModelServer()
        let body = bytes(count: 10_000, seed: 7)
        server.serve("big.bin", body: body)
        let manifest = ModelManifest(version: "1", components: [
            .init(name: "big", path: "big.bin", url: server.url("big.bin"), size: Int64(body.count), sha256: sha256(body)),
        ])
        let provisioner = provisioner(manifest, in: directory, available: 9_999)

        await #expect(throws: ProvisioningError.insufficientStorage(required: 10_000, available: 9_999)) {
            _ = try await run(provisioner)
        }
        #expect(server.requests.isEmpty)
    }
}
