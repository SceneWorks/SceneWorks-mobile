import Foundation

/// A request for a single, square SceneWorks image generation.
struct GenerationRequest: Sendable {
    static let imageSize = 1_024

    let prompt: String
    let seed: UInt64

    let width = imageSize
    let height = imageSize

    init(prompt: String, seed: UInt64) {
        self.prompt = prompt
        self.seed = seed
    }
}

/// Immutable RGBA pixels for an image produced by a generation engine.
struct GeneratedImage: Sendable {
    let pixels: Data
    let width: Int
    let height: Int
}

/// Updates emitted while an image is being generated.
enum GenerationEvent: Sendable {
    case progress(step: Int, total: Int)
    case finished(GeneratedImage)
}

/// The boundary between the app and the image-generation engine.
protocol GenerationEngine: Sendable {
    func generate(request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}

/// An in-process engine for exercising the app while the on-device engine is unavailable.
struct FakeGenerationEngine: GenerationEngine {
    let stepCount: Int
    let stepDelay: Duration

    init(stepCount: Int = 4, stepDelay: Duration = .seconds(1)) {
        precondition(stepCount > 0, "A generation must have at least one step.")
        self.stepCount = stepCount
        self.stepDelay = stepDelay
    }

    func generate(request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    for step in 1...stepCount {
                        try Task.checkCancellation()
                        if stepDelay > .zero {
                            try await Task.sleep(for: stepDelay)
                        }
                        continuation.yield(.progress(step: step, total: stepCount))
                    }

                    try Task.checkCancellation()
                    continuation.yield(.finished(Self.makeImage(seed: request.seed)))
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

    private static func makeImage(seed: UInt64) -> GeneratedImage {
        let width = GenerationRequest.imageSize
        let height = GenerationRequest.imageSize
        var pixels = Data(count: width * height * 4)

        pixels.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let value = mixedValue(seed: seed, x: x, y: y)
                    pixels[offset] = UInt8(truncatingIfNeeded: value)
                    pixels[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    pixels[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
                    pixels[offset + 3] = 255
                }
            }
        }

        return GeneratedImage(pixels: pixels, width: width, height: height)
    }

    private static func mixedValue(seed: UInt64, x: Int, y: Int) -> UInt64 {
        var value = seed
            &+ UInt64(x) &* 0x9E37_79B9_7F4A_7C15
            &+ UInt64(y) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
