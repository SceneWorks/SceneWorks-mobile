import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import SceneWorksMobile

/// Decodes a PNG back into its RGBA pixel buffer (premultipliedLast, 32-bit big,
/// device RGB), mirroring the way `GeneratedImage` pixels are laid out, so a
/// lossless round trip compares equal byte for byte.
private func decodedRGBA(png: Data, expectedSize: Int) throws -> Data {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw ImageExportError(message: "Could not decode the PNG for testing.")
    }
    #expect(image.width == expectedSize)
    #expect(image.height == expectedSize)

    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: &buffer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    )
    else {
        throw ImageExportError(message: "Could not create a decode context.")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Data(buffer)
}

/// Produces the same `GeneratedImage` the fake engine would emit for a seed.
private func fakeImage(seed: UInt64) async throws -> GeneratedImage {
    let engine = FakeGenerationEngine(stepCount: 1, stepDelay: .zero)
    var image: GeneratedImage?
    for try await event in engine.generate(request: GenerationRequest(prompt: "t", seed: seed)) {
        if case let .finished(generated) = event {
            image = generated
        }
    }
    return try #require(image)
}

struct ImageExportTests {
    @Test func fileNameCarriesTheSeed() {
        #expect(ImageExporter.fileName(seed: 0) == "SceneWorks-0.png")
        #expect(ImageExporter.fileName(seed: 42) == "SceneWorks-42.png")
        #expect(ImageExporter.fileName(seed: 9_876_543_210) == "SceneWorks-9876543210.png")
    }

    @Test func roundTripDecodesBackToIdenticalPixelsAndSize() async throws {
        let seed: UInt64 = 7
        let original = try await fakeImage(seed: seed)
        let png = try ImageExporter().pngData(image: original)

        // The exported PNG decodes back to 1024x1024 with the same pixels.
        let decoded = try decodedRGBA(png: png, expectedSize: original.width)
        #expect(decoded.count == original.pixels.count)
        #expect(decoded == original.pixels)
    }

    @Test func writePNGProducesAFileNamedAfterTheSeed() async throws {
        let seed: UInt64 = 1234
        let original = try await fakeImage(seed: seed)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ImageExporter().writePNG(image: original, seed: seed, to: directory)

        #expect(url.lastPathComponent == "SceneWorks-1234.png")
        let data = try Data(contentsOf: url)
        let decoded = try decodedRGBA(png: data, expectedSize: original.width)
        #expect(decoded == original.pixels)
    }
}

/// A saver that never saves and never denies: it just records the attempt.
private final class RecordingSaver: PhotoLibrarySaving, @unchecked Sendable {
    let result: SaveResult
    let failure: Error?
    private(set) var calls = 0

    init(result: SaveResult, failure: Error?) {
        self.result = result
        self.failure = failure
    }

    func save(png: Data) async throws -> SaveResult {
        calls += 1
        if let failure { throw failure }
        return result
    }
}

@MainActor
struct PhotoSavingTests {
    @Test func authorizedSavesAndShowsConfirmation() async throws {
        let image = try await fakeImage(seed: 1)
        let saver = RecordingSaver(result: .saved, failure: nil)
        let viewModel = SaveViewModel(saver: saver)

        await viewModel.save(image: image, seed: 1, result: SaveViewModel.ResultToken())

        #expect(viewModel.message == .saved)
        #expect(saver.calls == 1)
    }

    @Test func deniedShowsAccessDeniedMessageAndSavesNothing() async throws {
        let image = try await fakeImage(seed: 2)
        let saver = FakePhotoLibrarySaver(authorization: .denied)
        let viewModel = SaveViewModel(saver: saver)

        await viewModel.save(image: image, seed: 2, result: SaveViewModel.ResultToken())

        #expect(viewModel.message == .photosAccessDenied)
        #expect(saver.saveCount == 0)
    }

    @Test func restrictedShowsAccessDeniedMessageAndSavesNothing() async throws {
        let image = try await fakeImage(seed: 3)
        let saver = FakePhotoLibrarySaver(authorization: .restricted)
        let viewModel = SaveViewModel(saver: saver)

        await viewModel.save(image: image, seed: 3, result: SaveViewModel.ResultToken())

        #expect(viewModel.message == .photosAccessDenied)
        #expect(saver.saveCount == 0)
    }

    @Test func aSaveThatThrowsShowsAnErrorMessage() async throws {
        let image = try await fakeImage(seed: 4)
        let boom = SaveError(message: "the library blew up")
        let saver = RecordingSaver(result: .saved, failure: boom)
        let viewModel = SaveViewModel(saver: saver)

        await viewModel.save(image: image, seed: 4, result: SaveViewModel.ResultToken())

        guard case let .saveFailed(detail)? = viewModel.message else {
            Issue.record("Expected .saveFailed, got \(String(describing: viewModel.message))")
            return
        }
        #expect(!detail.isEmpty)
    }

    @Test func fakeAuthorizationReadsTheLaunchEnvironment() {
        #expect(FakePhotoAuthorization(environment: ["SCENEWORKS_FAKE_PHOTOS": "authorized"]) == .authorized)
        #expect(FakePhotoAuthorization(environment: ["SCENEWORKS_FAKE_PHOTOS": "denied"]) == .denied)
        #expect(FakePhotoAuthorization(environment: ["SCENEWORKS_FAKE_PHOTOS": "restricted"]) == .restricted)
        #expect(FakePhotoAuthorization(environment: [:]) == .authorized)
    }

    @Test func fakeSaverAuthorizedSavesDeniedDoesNotSave() async throws {
        let image = try await fakeImage(seed: 5)

        let authorized = FakePhotoLibrarySaver(authorization: .authorized)
        let viewModel = SaveViewModel(saver: authorized)
        await viewModel.save(image: image, seed: 5, result: SaveViewModel.ResultToken())
        #expect(authorized.saveCount == 1)
        #expect(viewModel.message == .saved)

        let denied = FakePhotoLibrarySaver(authorization: .denied)
        let deniedVM = SaveViewModel(saver: denied)
        await deniedVM.save(image: image, seed: 5, result: SaveViewModel.ResultToken())
        #expect(deniedVM.message == .photosAccessDenied)
        #expect(denied.saveCount == 0)
    }
}
