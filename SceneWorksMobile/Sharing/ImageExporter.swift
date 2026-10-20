import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A failure from encoding or writing the exported image.
struct ImageExportError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// Encodes a generated image as a PNG file.
///
/// The exporter owns the file name (`SceneWorks-<seed>.png`) and the PNG
/// encoding. PNG is a lossless encoding, so the decoded pixels are the source
/// pixels exactly.
struct ImageExporter: Sendable {
    /// The file name for an image with a given seed.
    static func fileName(seed: UInt64) -> String {
        "SceneWorks-\(seed).png"
    }

    /// Encodes the image to PNG and returns the encoded bytes.
    func pngData(image: GeneratedImage) throws -> Data {
        guard let data = try ImageEncoder.pngData(from: image) else {
            throw ImageExportError(message: "PNG encoding failed.")
        }
        return data
    }

    /// Encodes the image to PNG and writes it into `directory` under the
    /// `SceneWorks-<seed>.png` file name, returning the file's URL.
    @discardableResult
    func writePNG(image: GeneratedImage, seed: UInt64, to directory: URL) throws -> URL {
        let data = try pngData(image: image)
        let url = directory.appendingPathComponent(Self.fileName(seed: seed))
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// The image helpers shared by the exporter and the generated-image rendering.
enum ImageEncoder {
    /// The `CGImage` backing a `GeneratedImage`.
    static func cgImage(from image: GeneratedImage) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let provider = CGDataProvider(data: image.pixels as CFData)!
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// The `UIImage` backing a `GeneratedImage`, for the result screen.
    static func uiImage(from image: GeneratedImage) -> UIImage {
        UIImage(cgImage: cgImage(from: image))
    }

    /// Encodes a `GeneratedImage` as lossless PNG, or `nil` if the encode fails.
    static func pngData(from image: GeneratedImage) throws -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage(from: image), nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
