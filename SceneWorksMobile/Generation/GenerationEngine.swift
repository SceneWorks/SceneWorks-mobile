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

/// The failure `FakeGenerationEngine` raises when it is configured to fail at a step.
struct FakeGenerationError: Error, LocalizedError {
    let step: Int

    var errorDescription: String? {
        "Generation failed at step \(step)."
    }
}

/// What the runs of a `FakeGenerationEngine` saw, so tests can assert on cancellation.
final class FakeGenerationObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationObserved = false
    private var emittedProgress = 0

    /// True once the engine checked for cancellation between steps and found it.
    var didObserveCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationObserved
    }

    /// How many progress events the engine has emitted across its runs.
    var progressCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emittedProgress
    }

    fileprivate func recordCancellationObserved() {
        lock.lock()
        defer { lock.unlock() }
        cancellationObserved = true
    }

    fileprivate func recordProgress() {
        lock.lock()
        defer { lock.unlock() }
        emittedProgress += 1
    }
}

/// An in-process engine for exercising the app while the on-device engine is unavailable.
struct FakeGenerationEngine: GenerationEngine {
    /// How the fake behaves, chosen at the composition point from the launch environment.
    enum Mode: Sendable {
        case standard
        case slow
        case fail
    }

    let stepCount: Int
    let stepDelay: Duration
    /// The step at which `generate` throws instead of emitting progress.
    let failAtStep: Int?
    /// What this engine's runs observed, for tests.
    let observations: FakeGenerationObservations

    init(
        stepCount: Int = 4,
        stepDelay: Duration = .seconds(1),
        failAtStep: Int? = nil,
        observations: FakeGenerationObservations = FakeGenerationObservations()
    ) {
        precondition(stepCount > 0, "A generation must have at least one step.")
        self.stepCount = stepCount
        self.stepDelay = stepDelay
        self.failAtStep = failAtStep
        self.observations = observations
    }

    init(mode: Mode) {
        switch mode {
        case .standard:
            self.init(stepCount: 4, stepDelay: .seconds(1))
        case .slow:
            self.init(stepCount: 4, stepDelay: .seconds(5))
        case .fail:
            self.init(stepCount: 4, stepDelay: .milliseconds(200), failAtStep: 2)
        }
    }

    func generate(request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    for step in 1...stepCount {
                        // Cooperative cancellation is checked between steps and recorded for tests.
                        try Task.checkCancellation()
                        if stepDelay > .zero {
                            try await Task.sleep(for: stepDelay)
                        }
                        if failAtStep == step {
                            throw FakeGenerationError(step: step)
                        }
                        continuation.yield(.progress(step: step, total: stepCount))
                        observations.recordProgress()
                    }

                    try Task.checkCancellation()
                    continuation.yield(.finished(Self.makeImage(seed: request.seed)))
                    continuation.finish()
                } catch is CancellationError {
                    observations.recordCancellationObserved()
                    continuation.finish(throwing: CancellationError())
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