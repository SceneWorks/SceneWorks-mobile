import Testing
@testable import SceneWorksMobile

struct SceneWorksMobileTests {
    @Test func fakeEngineEmitsOrderedProgressAndDeterministicImage() async throws {
        let request = GenerationRequest(prompt: "A bright mountain", seed: 42)
        let events = try await events(from: FakeGenerationEngine(stepCount: 4, stepDelay: .zero), request: request)

        // The whole sequence: every progress event in order, then the finished image last.
        #expect(events.count == 5)
        for (index, event) in events.enumerated() {
            if index < 4 {
                guard case let .progress(step, total) = event else {
                    Issue.record("Expected progress \(index + 1)/4 at index \(index), got \(event)")
                    continue
                }
                #expect(step == index + 1)
                #expect(total == 4)
            } else {
                guard case .finished = event else {
                    Issue.record("Expected the finished event last, got \(event)")
                    continue
                }
            }
        }

        let image = try #require(events.last.flatMap { event -> GeneratedImage? in
            guard case let .finished(image) = event else { return nil }
            return image
        })
        #expect(image.width == 1_024)
        #expect(image.height == 1_024)

        let sameSeedImage = try await finishedImage(from: FakeGenerationEngine(stepCount: 1, stepDelay: .zero), seed: 42)
        let differentSeedImage = try await finishedImage(from: FakeGenerationEngine(stepCount: 1, stepDelay: .zero), seed: 43)
        #expect(image.pixels == sameSeedImage.pixels)
        #expect(image.pixels != differentSeedImage.pixels)
    }

    @Test @MainActor func viewModelCompletesAGeneration() async throws {
        let viewModel = GenerateViewModel(engine: FakeGenerationEngine(stepCount: 4, stepDelay: .zero))
        viewModel.prompt = "A sunny beach"

        #expect(viewModel.state == .idle)
        viewModel.generate()
        #expect(viewModel.state == .generating)

        for _ in 0..<100 where viewModel.state != .finished {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.state == .finished)
        #expect(viewModel.progress == 1)
        #expect(viewModel.image != nil)
    }

    @Test @MainActor func whitespacePromptCannotStartGeneration() {
        let viewModel = GenerateViewModel(engine: FakeGenerationEngine(stepCount: 1, stepDelay: .zero))
        viewModel.prompt = " \n\t "

        #expect(!viewModel.canGenerate)
        viewModel.generate()

        #expect(viewModel.state == .idle)
        #expect(viewModel.progress == 0)
        #expect(viewModel.image == nil)
    }

    private func events(
        from engine: some GenerationEngine,
        request: GenerationRequest
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in engine.generate(request: request) {
            events.append(event)
        }
        return events
    }

    private func finishedImage(from engine: some GenerationEngine, seed: UInt64) async throws -> GeneratedImage {
        let result = try await events(from: engine, request: GenerationRequest(prompt: "Test", seed: seed))
        return try #require(result.compactMap { event -> GeneratedImage? in
            guard case let .finished(image) = event else { return nil }
            return image
        }.first)
    }
}
