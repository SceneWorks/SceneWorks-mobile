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
    /// The raw generated image and its seed, present once a generation has
    /// finished — the source for exporting, saving and sharing.
    private(set) var generatedImage: GeneratedImage?
    private(set) var seed: UInt64 = 0
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
        generatedImage = nil
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
                        self?.image = ImageEncoder.uiImage(from: generatedImage)
                        self?.generatedImage = generatedImage
                        self?.seed = request.seed
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