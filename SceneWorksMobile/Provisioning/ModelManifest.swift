import Foundation

/// One model release: the files it is made of and how to check each of them.
struct ModelManifest: Codable, Equatable, Sendable {
    /// A single downloadable file of the release.
    struct Component: Codable, Equatable, Sendable {
        /// A short identifier, used in errors and progress reporting.
        let name: String
        /// Where the file lives inside the version's directory, e.g. `weights/model.bin`.
        let path: String
        /// Where the bytes are served from.
        let url: URL
        /// The exact size of the file, in bytes.
        let size: Int64
        /// The file's SHA-256 digest, as hex.
        let sha256: String
    }

    /// The release these files belong to; every version gets its own directory.
    let version: String
    let components: [Component]

    /// What the whole release weighs, in bytes.
    var totalSize: Int64 {
        components.reduce(0) { $0 + $1.size }
    }
}