import Foundation

/// How the fake photo library answers a save, chosen from the launch
/// environment's `SCENEWORKS_FAKE_PHOTOS` value so UI tests need no system
/// permission prompt.
enum FakePhotoAuthorization: Sendable {
    case authorized
    case denied
    case restricted

    /// Read the value from a launch environment. Anything that is not `denied`
    /// or `restricted` is treated as `authorized`.
    init(environment: [String: String]) {
        switch environment["SCENEWORKS_FAKE_PHOTOS"] {
        case "denied": self = .denied
        case "restricted": self = .restricted
        default: self = .authorized
        }
    }
}

/// A `PhotoLibrarySaving` that never touches the real photo library. It reports
/// the result `FakePhotoAuthorization` dictates and counts saves so tests can
/// assert that a denied save did not actually save.
final class FakePhotoLibrarySaver: PhotoLibrarySaving, @unchecked Sendable {
    let authorization: FakePhotoAuthorization
    /// When non-nil, `save(png:)` throws this error instead of returning a
    /// result — the "a save that throws" case.
    let failure: Error?
    /// How many saves reached the library, for test assertions.
    private(set) var saveCount = 0

    init(authorization: FakePhotoAuthorization, failure: Error? = nil) {
        self.authorization = authorization
        self.failure = failure
    }

    /// The production-shaped initializer the composition point uses: it reads
    /// the launch environment directly.
    static func fromLaunchEnvironment(_ environment: [String: String]) -> FakePhotoLibrarySaver {
        FakePhotoLibrarySaver(authorization: FakePhotoAuthorization(environment: environment))
    }

    func save(png: Data) async throws -> SaveResult {
        if let failure {
            throw failure
        }
        switch authorization {
        case .authorized:
            saveCount += 1
            return .saved
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        }
    }
}
