import Foundation
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

        try await wait(for: "the generation to finish") {
            viewModel.state == .finished
        }

        #expect(viewModel.state == .finished)
        #expect(viewModel.progress == 1)
        #expect(viewModel.image != nil)
    }

    @Test @MainActor func cancellingGenerationReachesFakeAndAllowsAnotherGeneration() async throws {
        let control = GenerationCancellationControl()
        let viewModel = GenerateViewModel(engine: ControllableGenerationEngine(control: control))
        viewModel.prompt = "A sunny beach"
        viewModel.generate()

        // The producer has emitted one event and is now blocked at a
        // cancellation-aware suspension. It cannot finish before cancellation.
        try await wait(for: "the first generation producer to suspend") {
            await control.firstRunIsSuspended
        }
        try await wait(for: "the first generation progress update") {
            viewModel.progress > 0
        }

        viewModel.cancelGeneration()
        try await wait(for: "the fake engine to observe cancellation") {
            await control.didObserveCancellation
        }

        let firstRunProgressCount = await control.firstRunProgressCount
        #expect(firstRunProgressCount == 1)
        #expect(viewModel.state == .idle)
        #expect(viewModel.progress == 0)
        #expect(viewModel.image == nil)

        viewModel.generate()
        try await wait(for: "the second generation to finish") {
            viewModel.state == .finished
        }
        #expect(viewModel.image != nil)
    }

    @Test @MainActor func failedGenerationShowsMessageAndRetryRunsAgain() async throws {
        let viewModel = GenerateViewModel(engine: FakeGenerationEngine(
            stepCount: 4,
            stepDelay: .milliseconds(100),
            failAtStep: 2
        ))
        viewModel.prompt = "A stormy sea"
        viewModel.generate()

        try await wait(for: "the failed generation to report its failure") {
            viewModel.state == .failed
        }
        #expect(viewModel.errorMessage == "Generation failed at step 2.")

        viewModel.retry()
        #expect(viewModel.state == .generating)
        #expect(viewModel.errorMessage == nil)
        try await wait(for: "the retried generation to report its failure") {
            viewModel.state == .failed
        }
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

    /// Waits against a wall-clock deadline, so test-executor contention cannot
    /// silently turn an iteration count into an unbounded wait. `file` and
    /// `line` preserve which expectation actually timed out.
    @MainActor
    private func wait(
        for description: String,
        timeout: Duration = .seconds(3),
        file: StaticString = #fileID,
        line: UInt = #line,
        until condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            guard clock.now < deadline else {
                throw WaitTimeout(description: description, file: file, line: line)
            }

            let satisfied = await condition()
            guard clock.now < deadline else {
                throw WaitTimeout(description: description, file: file, line: line)
            }
            if satisfied { return }

            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct WaitTimeout: Error, LocalizedError {
    let description: String
    let file: StaticString
    let line: UInt

    var errorDescription: String? {
        "Timed out at \(file):\(line) while waiting for \(description)."
    }
}

/// A test-only engine controller. Its first run cannot complete after yielding
/// progress: it remains in a cancellation-aware suspension until its stream is
/// terminated. Every later run completes immediately.
private actor GenerationCancellationControl {
    private var runCount = 0
    private var firstRunSuspended = false
    private var cancellationObserved = false
    private var firstRunProgresses = 0
    private var cancellationRequested = false
    private var firstRunWaiter: CheckedContinuation<Void, Error>?

    var firstRunIsSuspended: Bool { firstRunSuspended }
    var didObserveCancellation: Bool { cancellationObserved }
    var firstRunProgressCount: Int { firstRunProgresses }

    func beginRun() -> Int {
        runCount += 1
        return runCount
    }

    func recordFirstRunProgress() {
        firstRunProgresses += 1
    }

    func suspendFirstRunUntilCancelled() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                firstRunSuspended = true
                if cancellationRequested {
                    continuation.resume(throwing: CancellationError())
                } else {
                    firstRunWaiter = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelFirstRunWait() }
        })
    }

    func cancelFirstRunWait() {
        cancellationRequested = true
        guard let firstRunWaiter else { return }
        self.firstRunWaiter = nil
        firstRunWaiter.resume(throwing: CancellationError())
    }

    func recordCancellationObserved() {
        cancellationObserved = true
    }
}

private struct ControllableGenerationEngine: GenerationEngine {
    let control: GenerationCancellationControl

    func generate(request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [control] in
                let run = await control.beginRun()

                if run == 1 {
                    continuation.yield(.progress(step: 1, total: 1))
                    await control.recordFirstRunProgress()

                    do {
                        try await control.suspendFirstRunUntilCancelled()
                        continuation.finish()
                    } catch is CancellationError {
                        await control.recordCancellationObserved()
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                continuation.yield(.progress(step: 1, total: 1))
                continuation.yield(.finished(GeneratedImage(
                    pixels: Data([0, 0, 0, 255]),
                    width: 1,
                    height: 1
                )))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
