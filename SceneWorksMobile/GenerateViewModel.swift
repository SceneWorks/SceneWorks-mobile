import CoreGraphics
import Observation
import UIKit

@MainActor
@Observable
final class GenerateViewModel {
    enum State: Equatable {
        case idle
        case generating
        case finished
        case failed
    }

    var prompt = ""
    private(set) var state: State = .idle
    private(set) var progress = 0.0
    private(set) var image: UIImage?
    /// A user-readable description of the last failure, present only while `state` is `.failed`.
    private(set) var errorMessage: String?

    var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .generating
    }

    private let engine: any GenerationEngine
    private var generationTask: Task<Void, Never>?

    init(engine: any GenerationEngine) {
        self.engine = engine
    }

    func generate() {
        guard canGenerate else { return }
        startGeneration()
    }

    /// Runs the generation again after a failure.
    func retry() {
        guard state == .failed, canGenerate else { return }
        startGeneration()
    }

    private func startGeneration() {
        state = .generating
        progress = 0
        image = nil
        errorMessage = nil

        let request = GenerationRequest(prompt: prompt, seed: 0)
        let engine = engine
        generationTask = Task { [weak self] in
            do {
                for try await event in engine.generate(request: request) {
                    guard !Task.isCancelled else { return }

                    switch event {
                    case let .progress(step, total):
                        self?.progress = Double(step) / Double(total)
                    case let .finished(generatedImage):
                        self?.image = generatedImage.uiImage()
                        self?.state = .finished
                        return
                    }
                }

                guard !Task.isCancelled else { return }
                self?.state = .idle
            } catch is CancellationError {
                // cancelGeneration() has already put the view model back to idle.
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        if state == .generating {
            state = .idle
            progress = 0
        }
    }
}

private extension GeneratedImage {
    func uiImage() -> UIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: image)
    }
}