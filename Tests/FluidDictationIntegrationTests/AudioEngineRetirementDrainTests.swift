@testable import FluidVoice_Debug
import Foundation
import XCTest

final class AudioEngineRetirementDrainTests: XCTestCase {
    func testReleaseAndWaitCompletesAfterOffMainDeinit() async throws {
        let drain = AudioEngineRetirementDrain(label: "test.audio-engine-retirement.single")
        let recorder = DeinitRecorder()
        var probe: DeinitProbe? = DeinitProbe(id: 1, recorder: recorder)
        let token = AudioEngineRetirementToken(try XCTUnwrap(probe))
        probe = nil

        await drain.releaseAndWait(token)

        XCTAssertEqual(
            recorder.events,
            [DeinitEvent(id: 1, occurredOnMainThread: false)]
        )
    }

    func testAwaitedReleaseRunsAfterPreviouslyScheduledRelease() async throws {
        let drain = AudioEngineRetirementDrain(label: "test.audio-engine-retirement.serial")
        let recorder = DeinitRecorder()
        var first: DeinitProbe? = DeinitProbe(id: 1, recorder: recorder)
        var second: DeinitProbe? = DeinitProbe(id: 2, recorder: recorder)
        let firstToken = AudioEngineRetirementToken(try XCTUnwrap(first))
        let secondToken = AudioEngineRetirementToken(try XCTUnwrap(second))
        first = nil
        second = nil

        drain.schedule(firstToken)
        await drain.releaseAndWait(secondToken)

        XCTAssertEqual(
            recorder.events,
            [
                DeinitEvent(id: 1, occurredOnMainThread: false),
                DeinitEvent(id: 2, occurredOnMainThread: false),
            ]
        )
    }

    func testWaitForScheduledReleasesCompletesAfterScheduledRelease() async throws {
        let drain = AudioEngineRetirementDrain(label: "test.audio-engine-retirement.barrier")
        let recorder = DeinitRecorder()
        var probe: DeinitProbe? = DeinitProbe(id: 1, recorder: recorder)
        let token = AudioEngineRetirementToken(try XCTUnwrap(probe))
        probe = nil

        drain.schedule(token)
        await drain.waitForScheduledReleases()

        XCTAssertEqual(
            recorder.events,
            [DeinitEvent(id: 1, occurredOnMainThread: false)]
        )
    }
}

final class TranscriptionExecutorCancellationTests: XCTestCase {
    func testCancelAndAwaitPendingCancelsActiveTranscriptionOperation() async {
        let executor = TranscriptionExecutor()
        let operationStarted = expectation(description: "transcription operation started")
        let ownerID = UUID()
        let operation = Task {
            try await executor.run(ownerID: ownerID) {
                operationStarted.fulfill()
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
        }

        await fulfillment(of: [operationStarted])
        await executor.cancelAndAwait(ownerID: ownerID)

        do {
            try await operation.value
            XCTFail("Expected the active transcription operation to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testOwnerCancellationDoesNotCancelOrWaitForIndependentOperation() async {
        let executor = TranscriptionExecutor()
        let independentStarted = expectation(description: "independent operation started")
        let releaseIndependent = AsyncTestGate()
        let independent = Task {
            try await executor.run {
                independentStarted.fulfill()
                await releaseIndependent.wait()
                return "independent"
            }
        }
        await fulfillment(of: [independentStarted])

        let ownerID = UUID()
        let owned = Task {
            try await executor.run(ownerID: ownerID) { "owned" }
        }
        await Task.yield()
        await executor.cancelAndAwait(ownerID: ownerID)

        do {
            _ = try await owned.value
            XCTFail("Expected queued owner operation to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        await releaseIndependent.open()
        do {
            let value = try await independent.value
            XCTAssertEqual(value, "independent")
        } catch {
            XCTFail("Independent operation was cancelled: \(error)")
        }
    }

    func testCancelledOwnerRejectsLateFinalTranscriptionRegistration() async {
        let executor = TranscriptionExecutor()
        let ownerID = UUID()

        await executor.cancelAndAwait(ownerID: ownerID)

        do {
            let _: String = try await executor.run(ownerID: ownerID) { "stale" }
            XCTFail("Expected cancelled owner registration to be rejected")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    @MainActor
    func testAppleSpeechOperationCancellationResumesBeforeRecognitionTaskIsInstalled() async {
        let operation = AppleSpeechRecognitionOperation()
        let cancellationInvoked = expectation(description: "recognition task cancelled")
        let result = Task<ASRTranscriptionResult, Error> {
            try await withCheckedThrowingContinuation { continuation in
                operation.installContinuation(continuation)
            }
        }

        operation.cancel()
        operation.installCancellation {
            cancellationInvoked.fulfill()
        }

        do {
            _ = try await result.value
            XCTFail("Expected Apple speech operation cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        await fulfillment(of: [cancellationInvoked])
    }

    @MainActor
    func testAppleSpeechOperationIgnoresCallbackAfterCancellation() async {
        let operation = AppleSpeechRecognitionOperation()
        let result = Task<ASRTranscriptionResult, Error> {
            try await withCheckedThrowingContinuation { continuation in
                operation.installContinuation(continuation)
            }
        }

        operation.cancel()
        operation.finish(with: ASRTranscriptionResult(text: "stale", confidence: 1))

        do {
            _ = try await result.value
            XCTFail("Expected Apple speech operation cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testAppleSpeechAnalyzerParentCancellationCancelsResultsTaskAndAnalyzer() async {
        let resultsStarted = expectation(description: "analyzer results task started")
        let resultsCancelled = expectation(description: "analyzer results task cancelled")
        let analyzerCancelled = expectation(description: "speech analyzer cancelled")
        analyzerCancelled.assertForOverFulfill = true

        let resultsTask = Task<Void, Error> {
            resultsStarted.fulfill()
            do {
                while true {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch {
                resultsCancelled.fulfill()
                throw error
            }
        }
        let operation = AppleSpeechAnalyzerCancellationOperation(
            resultsTask: resultsTask,
            cancelAnalyzer: {
                analyzerCancelled.fulfill()
            }
        )
        let transcriptionStarted = expectation(description: "analyzer transcription started")
        let transcriptionTask: Task<Void, Error> = Task {
            try await operation.run {
                transcriptionStarted.fulfill()
                while true {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
        }

        await fulfillment(of: [resultsStarted, transcriptionStarted])
        transcriptionTask.cancel()

        do {
            try await transcriptionTask.value
            XCTFail("Expected Apple Speech Analyzer transcription cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        await fulfillment(of: [resultsCancelled, analyzerCancelled])
    }

    func testFluidAudioFinalFallbackSkipsCancellation() {
        XCTAssertFalse(
            FluidAudioFinalTranscriptionFallback.shouldRetry(
                after: CancellationError(),
                isTaskCancelled: false
            )
        )
        XCTAssertFalse(
            FluidAudioFinalTranscriptionFallback.shouldRetry(
                after: NSError(domain: "test", code: 1),
                isTaskCancelled: true
            )
        )
        XCTAssertTrue(
            FluidAudioFinalTranscriptionFallback.shouldRetry(
                after: NSError(domain: "test", code: 2),
                isTaskCancelled: false
            )
        )
    }

    @MainActor
    func testCancellationDrainCancelsExecutorWorkAndResetsProvider() async {
        let executor = TranscriptionExecutor()
        let provider = CancellationResetProvider()
        let operationStarted = expectation(description: "streaming provider operation started")
        let ownerID = UUID()
        let streamingTask: Task<Void, Never> = Task {
            do {
                let _: ASRTranscriptionResult = try await executor.run(ownerID: ownerID) {
                    operationStarted.fulfill()
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    throw CancellationError()
                }
            } catch {
                // Cancellation is the expected completion path.
            }
        }

        await fulfillment(of: [operationStarted])
        await TranscriptionCancellationDrain.cancelAndAwait(
            streamingTask: streamingTask,
            executor: executor,
            ownerID: ownerID,
            provider: provider
        )

        XCTAssertEqual(provider.resetCount, 1)
        XCTAssertTrue(streamingTask.isCancelled)
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class CancellationResetProvider: TranscriptionProvider {
    let name = "Cancellation reset test provider"
    let isAvailable = true
    let isReady = true
    private(set) var resetCount = 0

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        ASRTranscriptionResult(text: "")
    }

    func resetAfterCancellation() async {
        self.resetCount += 1
    }
}

private final class DeinitProbe {
    private let id: Int
    private let recorder: DeinitRecorder

    init(id: Int, recorder: DeinitRecorder) {
        self.id = id
        self.recorder = recorder
    }

    deinit {
        self.recorder.record(
            DeinitEvent(id: self.id, occurredOnMainThread: Thread.isMainThread)
        )
    }
}

private struct DeinitEvent: Equatable {
    let id: Int
    let occurredOnMainThread: Bool
}

private final class DeinitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [DeinitEvent] = []

    var events: [DeinitEvent] {
        self.lock.withLock { self.recordedEvents }
    }

    func record(_ event: DeinitEvent) {
        self.lock.withLock {
            self.recordedEvents.append(event)
        }
    }
}
