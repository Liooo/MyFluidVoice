import AVFoundation
import Foundation
import Speech

// MARK: - Apple Speech Provider

/// Owns exactly-once completion for an `SFSpeechRecognitionTask`, including cancellation that
/// arrives before either the continuation or the task has been installed.
final nonisolated class AppleSpeechRecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ASRTranscriptionResult, Error>?
    private var cancelRecognition: (() -> Void)?
    private var isResolved = false
    private var isCancelled = false

    func installContinuation(_ continuation: CheckedContinuation<ASRTranscriptionResult, Error>) {
        var shouldResumeCancellation = false
        self.lock.lock()
        if self.isCancelled {
            self.isResolved = true
            shouldResumeCancellation = true
        } else if !self.isResolved {
            self.continuation = continuation
        }
        self.lock.unlock()

        if shouldResumeCancellation {
            continuation.resume(throwing: CancellationError())
        }
    }

    func installCancellation(_ cancellation: @escaping () -> Void) {
        var shouldCancel = false
        self.lock.lock()
        if self.isCancelled {
            shouldCancel = true
        } else if !self.isResolved {
            self.cancelRecognition = cancellation
        }
        self.lock.unlock()

        if shouldCancel {
            cancellation()
        }
    }

    func finish(with result: ASRTranscriptionResult) {
        let continuation: CheckedContinuation<ASRTranscriptionResult, Error>?
        self.lock.lock()
        guard !self.isResolved else {
            self.lock.unlock()
            return
        }
        self.isResolved = true
        continuation = self.continuation
        self.continuation = nil
        self.cancelRecognition = nil
        self.lock.unlock()

        continuation?.resume(returning: result)
    }

    func cancel() {
        let continuation: CheckedContinuation<ASRTranscriptionResult, Error>?
        let cancelRecognition: (() -> Void)?
        self.lock.lock()
        self.isCancelled = true
        cancelRecognition = self.cancelRecognition
        self.cancelRecognition = nil
        if self.isResolved {
            continuation = nil
        } else if let installedContinuation = self.continuation {
            self.isResolved = true
            continuation = installedContinuation
            self.continuation = nil
        } else {
            continuation = nil
        }
        self.lock.unlock()

        cancelRecognition?()
        continuation?.resume(throwing: CancellationError())
    }
}

/// A TranscriptionProvider that uses Apple's native SFSpeechRecognizer.
/// This uses Apple's system speech path and lets macOS choose local or online recognition.
final class AppleSpeechProvider: TranscriptionProvider {
    var name: String {
        "Apple Speech (Legacy)"
    }

    /// Always available on macOS 10.15+ (Catalina and later)
    var isAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() != .restricted
    }

    /// Apple Speech is "always ready" (no downloads needed),
    /// but we track if we've checked permissions.
    private(set) var isReady: Bool = false

    /// The recognizer instance. We intentionally re-create it if the locale changes,
    /// using the language selected in Voice Engine/onboarding.
    private var recognizer: SFSpeechRecognizer?
    private var recognizerLocaleIdentifier: String?
    private let localeIdentifierOverride: String?

    init(localeIdentifier: String? = nil) {
        self.localeIdentifierOverride = localeIdentifier
        _ = self.updateRecognizerIfNeeded()
    }

    // MARK: - Lifecycle

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        // 1. Request Authorization
        let status = await self.requestAuthorization()

        switch status {
        case .authorized:
            self.isReady = true
            DebugLogger.shared.info("AppleSpeechProvider authorized and ready", source: "AppleSpeechProvider")
        case .denied:
            throw NSError(domain: "AppleSpeechProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied"])
        case .restricted:
            throw NSError(domain: "AppleSpeechProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is restricted on this device"])
        case .notDetermined:
            // Should not happen after requestAuthorization returns, but handled for safety
            self.isReady = false
        @unknown default:
            self.isReady = false
        }
    }

    func clearCache() async throws {
        // No cache to clear for system speech
    }

    func modelsExistOnDisk() -> Bool {
        return true // System models are always "on disk"
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isAvailable else {
            throw NSError(domain: "AppleSpeechProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech recognition unavailable"])
        }

        // 1. Convert [Float] samples to AVAudioPCMBuffer
        guard let buffer = self.createPCMBuffer(from: samples) else {
            throw NSError(domain: "AppleSpeechProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        // 2. Ensure recognizer exists for the selected speech language
        guard let recognizer = self.updateRecognizerIfNeeded() else {
            throw NSError(domain: "AppleSpeechProvider", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize SFSpeechRecognizer"])
        }

        if !recognizer.isAvailable {
            throw NSError(domain: "AppleSpeechProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: "SFSpeechRecognizer is currently unavailable"])
        }

        // 3. Create Request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false // We want the final result for this chunk
        request.requiresOnDeviceRecognition = false // Allow macOS to use the best available Apple speech path.
        request.append(buffer)
        request.endAudio() // Signal that this buffer is the complete utterance for this request

        // 4. Execute Recognition
        let operation = AppleSpeechRecognitionOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.installContinuation(continuation)
                let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        // Ignore "No speech detected" errors often returned for silent chunks.
                        DebugLogger.shared.warning(
                            "Apple transcribed error: \(error.localizedDescription)",
                            source: "AppleSpeechProvider"
                        )
                        operation.finish(with: ASRTranscriptionResult(text: "", confidence: 0.0))
                        return
                    }

                    if let result, result.isFinal {
                        let transcription = result.bestTranscription.formattedString
                        DebugLogger.shared.debug(
                            "AppleSpeechProvider: Got final result: '\(transcription)'",
                            source: "AppleSpeechProvider"
                        )
                        operation.finish(
                            with: ASRTranscriptionResult(text: transcription, confidence: 1.0)
                        )
                    }
                    // Partial results ignored as we requested final only.
                }
                operation.installCancellation {
                    recognitionTask.cancel()
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    // MARK: - Helpers

    private func updateRecognizerIfNeeded() -> SFSpeechRecognizer? {
        let locale = self.localeIdentifierOverride.map(Locale.init(identifier:))
            ?? SettingsStore.shared.selectedAppleSpeechLocale
        let localeIdentifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if self.recognizer == nil || self.recognizerLocaleIdentifier != localeIdentifier {
            self.recognizer = SFSpeechRecognizer(locale: locale)
            self.recognizerLocaleIdentifier = localeIdentifier
        }
        return self.recognizer
    }

    /// Converts raw [Float] samples (16kHz mono) to AVAudioPCMBuffer
    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        // Define format: 16kHz, Mono, Float32 (standard for ML/ASR)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Efficient copy
        guard let channelData = buffer.floatChannelData else { return nil }

        // Use withUnsafeBufferPointer for safe memory access
        samples.withUnsafeBufferPointer { samplePtr in
            guard let baseAddress = samplePtr.baseAddress else { return }
            // Copy memory from array to AVAudioPCMBuffer
            // channelData[0] is UnsafeMutablePointer<Float>
            channelData[0].update(from: baseAddress, count: samples.count)
        }

        return buffer
    }

    /// Structured concurrency wrapper for authorization
    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
