import Foundation

private nonisolated struct SonioxOperationLease: Hashable, Sendable {
    let id = UUID()
}

final class SonioxProvider: TranscriptionProvider {
    static let modelID = "stt-rt-v5"

    let name = "Soniox v5 Realtime"
    let isAvailable = true
    private(set) var isReady = false
    let shouldClearCacheAfterCancellation = false
    let allowsTranscriptLogging = false

    private let apiKey: String
    private let cancellationHandle = SonioxCancellationHandle()
    private let session: SonioxStreamingSession

    init(
        apiKey: String,
        binding: SonioxSessionBinding,
        transportFactory: @escaping SonioxTransportFactory = URLSessionSonioxWebSocketTransport.make,
        sleep: @escaping SonioxSleep = SonioxProvider.productionSleep,
        finalizationTimeout: Duration = .seconds(10)
    ) {
        self.apiKey = apiKey
        self.session = SonioxStreamingSession(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            binding: binding,
            transportFactory: transportFactory,
            sleep: sleep,
            finalizationTimeout: finalizationTimeout,
            cancellationHandle: self.cancellationHandle
        )
    }

    nonisolated static func productionSleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        _ = progressHandler
        let lease = SonioxOperationLease()
        defer { self.cancellationHandle.release(lease) }
        self.isReady = false
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw SonioxError(
                        category: .credential,
                        diagnosticType: "missing_api_key",
                        requestID: nil
                    )
                }
            } onCancel: {
                self.cancellationHandle.cancel(lease)
            }
            try Task.checkCancellation()
            self.isReady = true
        } catch {
            self.isReady = false
            throw error
        }
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let lease = SonioxOperationLease()
        defer { self.cancellationHandle.release(lease) }
        return try await withTaskCancellationHandler {
            try await self.session.preview(cumulativeSamples: samples, lease: lease)
        } onCancel: {
            self.cancellationHandle.cancel(lease)
        }
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let lease = SonioxOperationLease()
        defer { self.cancellationHandle.release(lease) }
        return try await withTaskCancellationHandler {
            try await self.session.finalize(cumulativeSamples: samples, lease: lease)
        } onCancel: {
            self.cancellationHandle.cancel(lease)
        }
    }

    func modelsExistOnDisk() -> Bool {
        true
    }

    func clearCache() async throws {
        await self.resetAfterCancellation()
        self.isReady = false
    }

    func resetAfterCancellation() async {
        await withTaskCancellationHandler {
            await self.session.resetAfterCancellation()
        } onCancel: {
            self.cancellationHandle.cancelTransport()
        }
    }
}

private final nonisolated class SonioxCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: (any SonioxWebSocketTransport)?
    private var activeLease: SonioxOperationLease?
    private var cancelledLeases: Set<SonioxOperationLease> = []

    func admit(_ lease: SonioxOperationLease) {
        let transport = self.lock.withLock { () -> (any SonioxWebSocketTransport)? in
            precondition(self.activeLease == nil)
            self.activeLease = lease
            return self.cancelledLeases.contains(lease) ? self.transport : nil
        }
        transport?.close(.cancelled)
    }

    func install(_ transport: any SonioxWebSocketTransport, for lease: SonioxOperationLease) {
        let shouldClose = self.lock.withLock { () -> Bool in
            guard self.activeLease == lease else { return true }
            self.transport = transport
            return self.cancelledLeases.contains(lease)
        }
        if shouldClose {
            transport.close(.cancelled)
        }
    }

    func cancel(_ lease: SonioxOperationLease) {
        let transport = self.lock.withLock { () -> (any SonioxWebSocketTransport)? in
            let inserted = self.cancelledLeases.insert(lease).inserted
            guard inserted, self.activeLease == lease else { return nil }
            return self.transport
        }
        transport?.close(.cancelled)
    }

    func cancelTransport() {
        let transport = self.lock.withLock { () -> (any SonioxWebSocketTransport)? in
            if let activeLease {
                self.cancelledLeases.insert(activeLease)
            }
            return self.transport
        }
        transport?.close(.cancelled)
    }

    func release(_ lease: SonioxOperationLease) {
        self.lock.withLock {
            if self.activeLease == lease {
                self.activeLease = nil
            }
            self.cancelledLeases.remove(lease)
        }
    }

    func clearTransport() {
        self.lock.withLock {
            self.transport = nil
        }
    }
}

private nonisolated enum SonioxStreamingError: Error, Sendable {
    case shrinkingCumulativeSamples
    case malformedServerMessage
    case unexpectedBinaryResponse
    case finishedBeforeFin
    case finishedBeforeEmptyFrame
}

nonisolated struct SonioxFinalizationArbiter: Sendable {
    private enum Winner: Sendable {
        case finished
        case timeout
    }

    private var winner: Winner?

    init() {}

    var hasAcceptedFinished: Bool {
        self.winner == .finished
    }

    mutating func claimFinished() -> Bool {
        guard self.winner == nil else { return false }
        self.winner = .finished
        return true
    }

    mutating func claimTimeout() -> Bool {
        guard self.winner == nil else { return false }
        self.winner = .timeout
        return true
    }

    mutating func reset() {
        self.winner = nil
    }
}

private actor SonioxStreamingSession {
    private enum EmptyFramePhase {
        case notStarted
        case sending
        case sent
    }

    private static let audioFrameSampleCount = 960
    private static let trailingSilenceSampleCount = 3200
    private static let finalizeFrame = SonioxWebSocketFrame.text("{\"type\":\"finalize\"}")

    private let apiKey: String
    private let binding: SonioxSessionBinding
    private let transportFactory: SonioxTransportFactory
    private let sleep: SonioxSleep
    private let finalizationTimeout: Duration
    private let cancellationHandle: SonioxCancellationHandle

    private var transport: (any SonioxWebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var reducer = SonioxTokenReducer()
    private var snapshot = SonioxTranscriptSnapshot(
        completeText: "",
        finalText: "",
        confidence: 0,
        sawFin: false,
        sawEnd: false,
        finished: false
    )
    private var sentSampleCount = 0
    private var emptyFramePhase = EmptyFramePhase.notStarted
    private var generation = 0
    private var terminalError: Error?
    private var isOperationInProgress = false
    private var activeOperationLease: SonioxOperationLease?
    private var finalizationArbiter = SonioxFinalizationArbiter()
    private var finWaiters: [CheckedContinuation<Void, Error>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Error>] = []

    init(
        apiKey: String,
        binding: SonioxSessionBinding,
        transportFactory: @escaping SonioxTransportFactory,
        sleep: @escaping SonioxSleep,
        finalizationTimeout: Duration,
        cancellationHandle: SonioxCancellationHandle
    ) {
        self.apiKey = apiKey
        self.binding = binding
        self.transportFactory = transportFactory
        self.sleep = sleep
        self.finalizationTimeout = finalizationTimeout
        self.cancellationHandle = cancellationHandle
    }

    func preview(cumulativeSamples: [Float], lease: SonioxOperationLease) async throws -> ASRTranscriptionResult {
        try self.beginOperation(lease)
        defer { self.endOperation(lease) }
        do {
            try Task.checkCancellation()
            try self.throwTerminalError()
            guard cumulativeSamples.count >= self.sentSampleCount else {
                throw SonioxStreamingError.shrinkingCumulativeSamples
            }
            guard cumulativeSamples.count > self.sentSampleCount else {
                return self.previewResult
            }

            try await self.sendCapturedSuffix(cumulativeSamples)
            try self.throwTerminalError()
            return self.previewResult
        } catch {
            let error = self.normalized(error)
            await self.failAndCleanup(error)
            throw error
        }
    }

    func finalize(cumulativeSamples: [Float], lease: SonioxOperationLease) async throws -> ASRTranscriptionResult {
        try self.beginOperation(lease)
        defer { self.endOperation(lease) }
        do {
            await DebugLogger.shared.debug(
                "Soniox finalization begin samples=\(cumulativeSamples.count) sentSamples=\(self.sentSampleCount)",
                source: "SonioxProvider"
            )
            try Task.checkCancellation()
            try self.throwTerminalError()
            guard cumulativeSamples.count >= self.sentSampleCount else {
                throw SonioxStreamingError.shrinkingCumulativeSamples
            }

            if cumulativeSamples.count > self.sentSampleCount {
                try await self.sendCapturedSuffix(cumulativeSamples)
            } else {
                try await self.ensureConnected()
            }
            try await self.sendTrailingSilence()
            // Treat the end-of-audio phase as in-flight before sending the
            // finalize control. A fast server can deliver `finished` between
            // those two sends; that response is valid for this stop request.
            self.emptyFramePhase = .sending
            try await self.send(Self.finalizeFrame)
            try Task.checkCancellation()
            await DebugLogger.shared.debug("Soniox finalization control sent; sending end-of-audio", source: "SonioxProvider")
            self.armTimeout()
            try await self.send(.binary(Data()))
            self.emptyFramePhase = .sent
            await DebugLogger.shared.debug("Soniox finalization end-of-audio sent; waiting for finished", source: "SonioxProvider")
            if self.snapshot.finished {
                try self.acceptFinished()
            }
            try await self.waitForFinished()
            try Task.checkCancellation()
            try self.throwTerminalError()

            let result = ASRTranscriptionResult(
                text: self.snapshot.finalText,
                confidence: self.snapshot.confidence
            )
            await DebugLogger.shared.debug(
                "Soniox finalization finished textChars=\(result.text.trimmingCharacters(in: .whitespacesAndNewlines).count)",
                source: "SonioxProvider"
            )
            await self.finishNormally()
            return result
        } catch {
            let error = self.normalized(error)
            await self.failAndCleanup(error)
            throw error
        }
    }

    func resetAfterCancellation() async {
        guard self.transport != nil || self.receiveTask != nil || self.timeoutTask != nil else {
            self.cancellationHandle.clearTransport()
            return
        }
        await self.failAndCleanup(CancellationError())
    }

    private var previewResult: ASRTranscriptionResult {
        ASRTranscriptionResult(text: self.snapshot.completeText, confidence: self.snapshot.confidence)
    }

    private func beginOperation(_ lease: SonioxOperationLease) throws {
        guard self.isOperationInProgress == false else {
            throw SonioxError(
                category: .configuration,
                diagnosticType: "operation_in_progress",
                requestID: nil
            )
        }
        self.isOperationInProgress = true
        self.activeOperationLease = lease
        self.cancellationHandle.admit(lease)
    }

    private func endOperation(_ lease: SonioxOperationLease) {
        guard self.activeOperationLease == lease else { return }
        self.cancellationHandle.release(lease)
        self.activeOperationLease = nil
        self.isOperationInProgress = false
    }

    private func throwTerminalError() throws {
        if let terminalError {
            throw terminalError
        }
    }

    private func ensureConnected() async throws {
        try self.throwTerminalError()
        guard self.transport == nil else { return }

        let transport = self.transportFactory(self.binding.region.webSocketURL)
        guard let activeOperationLease else {
            throw SonioxStreamingError.malformedServerMessage
        }
        self.cancellationHandle.install(transport, for: activeOperationLease)
        self.transport = transport
        let activeGeneration = self.generation
        try Task.checkCancellation()
        try await transport.start()
        try Task.checkCancellation()
        try self.throwTerminalError()

        let message = SonioxStartMessage(
            apiKey: self.apiKey,
            languageHints: self.binding.languageCode.map { [$0] },
            languageHintsStrict: self.binding.isStrict
        )
        let data = try JSONEncoder().encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SonioxStreamingError.malformedServerMessage
        }
        try Task.checkCancellation()
        try await transport.send(.text(text))
        try Task.checkCancellation()
        try self.throwTerminalError()
        self.receiveTask = Task { [weak self] in
            do {
                while Task.isCancelled == false {
                    let frame = try await transport.receive()
                    guard let shouldContinue = try await self?.consume(frame, generation: activeGeneration),
                          shouldContinue
                    else {
                        return
                    }
                }
            } catch {
                await self?.receiveFailed(error, generation: activeGeneration)
            }
        }
    }

    private func sendCapturedSuffix(_ samples: [Float]) async throws {
        try await self.ensureConnected()
        while self.sentSampleCount < samples.count {
            let end = min(self.sentSampleCount + Self.audioFrameSampleCount, samples.count)
            let frameSamples = Array(samples[self.sentSampleCount..<end])
            try await self.send(.binary(SonioxPCMEncoder.float32LittleEndian(frameSamples)))
            try self.throwTerminalError()
            self.sentSampleCount = end
        }
    }

    private func sendTrailingSilence() async throws {
        var remaining = Self.trailingSilenceSampleCount
        while remaining > 0 {
            let count = min(Self.audioFrameSampleCount, remaining)
            try await self.send(.binary(SonioxPCMEncoder.float32LittleEndian(Array(repeating: 0, count: count))))
            remaining -= count
        }
    }

    private func send(_ frame: SonioxWebSocketFrame) async throws {
        try self.throwTerminalError()
        guard let transport else {
            throw SonioxStreamingError.malformedServerMessage
        }
        try Task.checkCancellation()
        try await transport.send(frame)
        try Task.checkCancellation()
        try self.throwTerminalError()
    }

    private func consume(_ frame: SonioxWebSocketFrame, generation: Int) throws -> Bool {
        guard generation == self.generation, self.terminalError == nil, self.transport != nil else {
            return false
        }
        guard case let .text(text) = frame else {
            throw SonioxStreamingError.unexpectedBinaryResponse
        }
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(SonioxServerMessage.self, from: data)
        else {
            throw SonioxStreamingError.malformedServerMessage
        }

        self.snapshot = try self.reducer.reduce(message)
        if self.snapshot.finished {
            guard self.emptyFramePhase != .notStarted else {
                throw SonioxStreamingError.finishedBeforeEmptyFrame
            }
        }
        if self.snapshot.sawFin {
            self.resume(&self.finWaiters)
        }
        if self.snapshot.finished {
            if self.emptyFramePhase == .sent {
                try self.acceptFinished()
                return false
            }
            // The server may deliver the finished response while the empty
            // end-of-audio send is still suspended. Keep the receiver alive;
            // finalize() claims completion immediately after that send
            // resumes, and finishNormally() then closes this receive loop.
            return true
        }
        return true
    }

    private func receiveFailed(_ error: Error, generation: Int) {
        guard generation == self.generation, self.terminalError == nil else { return }
        self.beginFailure(self.normalized(error))
        self.cancellationHandle.clearTransport()
    }

    private func armTimeout() {
        let generation = self.generation
        let sleep = self.sleep
        let duration = self.finalizationTimeout
        self.timeoutTask = Task { [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            await self?.timeoutExpired(generation: generation)
        }
    }

    private func timeoutExpired(generation: Int) async {
        guard generation == self.generation,
              self.terminalError == nil,
              self.finalizationArbiter.claimTimeout()
        else { return }
        let phase: String
        phase = self.emptyFramePhase == .sent ? "waiting_for_finished" : "sending_empty_frame"
        await DebugLogger.shared.error(
            "Soniox finalization timeout phase=\(phase)",
            source: "SonioxProvider"
        )
        let error = SonioxError(
            category: .finalizationTimeout,
            diagnosticType: "finalization_timeout",
            requestID: nil
        )
        let receiveTask = self.beginFailure(error)
        await receiveTask?.value
        self.cancellationHandle.clearTransport()
    }

    private func waitForFin() async throws {
        try self.throwTerminalError()
        guard self.snapshot.sawFin == false else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.finWaiters.append(continuation)
        }
    }

    private func waitForFinished() async throws {
        try self.throwTerminalError()
        guard self.finalizationArbiter.hasAcceptedFinished == false else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.finishedWaiters.append(continuation)
        }
    }

    private func acceptFinished() throws {
        try self.throwTerminalError()
        guard self.finalizationArbiter.hasAcceptedFinished == false else { return }
        guard self.finalizationArbiter.claimFinished() else {
            try self.throwTerminalError()
            return
        }
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.resume(&self.finishedWaiters)
    }

    private func finishNormally() async {
        let transport = self.transport
        let receiveTask = self.receiveTask
        transport?.close(.normal)
        self.timeoutTask?.cancel()
        self.generation += 1
        self.resume(&self.finWaiters)
        self.resume(&self.finishedWaiters)
        self.clearVolatileState()
        await receiveTask?.value
        self.cancellationHandle.clearTransport()
    }

    private func failAndCleanup(_ error: Error) async {
        if self.terminalError != nil {
            return
        }
        let receiveTask = self.beginFailure(error)
        await receiveTask?.value
        self.cancellationHandle.clearTransport()
    }

    @discardableResult
    private func beginFailure(_ error: Error) -> Task<Void, Never>? {
        guard self.terminalError == nil else { return nil }
        self.terminalError = error
        self.generation += 1
        self.cancellationHandle.cancelTransport()
        let receiveTask = self.receiveTask
        receiveTask?.cancel()
        self.timeoutTask?.cancel()
        self.fail(&self.finWaiters, with: error)
        self.fail(&self.finishedWaiters, with: error)
        self.clearVolatileState()
        return receiveTask
    }

    private func clearVolatileState() {
        self.transport = nil
        self.receiveTask = nil
        self.timeoutTask = nil
        self.reducer.reset()
        self.snapshot = SonioxTranscriptSnapshot(
            completeText: "",
            finalText: "",
            confidence: 0,
            sawFin: false,
            sawEnd: false,
            finished: false
        )
        self.sentSampleCount = 0
        self.emptyFramePhase = .notStarted
        self.finalizationArbiter.reset()
        self.finWaiters.removeAll()
        self.finishedWaiters.removeAll()
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Error>]) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func fail(_ waiters: inout [CheckedContinuation<Void, Error>], with error: Error) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }

    private func normalized(_ error: Error) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? SonioxError {
            return error
        }
        if let error = error as? SonioxStreamingError {
            return switch error {
            case .shrinkingCumulativeSamples:
                SonioxError(category: .configuration, diagnosticType: "invalid_cumulative_audio", requestID: nil)
            case .malformedServerMessage:
                SonioxError(category: .temporaryService, diagnosticType: "malformed_response", requestID: nil)
            case .unexpectedBinaryResponse:
                SonioxError(category: .temporaryService, diagnosticType: "unexpected_binary_response", requestID: nil)
            case .finishedBeforeFin:
                SonioxError(category: .temporaryService, diagnosticType: "finished_before_fin", requestID: nil)
            case .finishedBeforeEmptyFrame:
                SonioxError(category: .temporaryService, diagnosticType: "finished_before_empty_frame", requestID: nil)
            }
        }
        return SonioxErrorMapper.error(errorType: nil, requestID: nil)
    }
}
