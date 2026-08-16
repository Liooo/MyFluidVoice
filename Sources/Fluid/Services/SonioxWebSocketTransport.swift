import Foundation

nonisolated enum SonioxWebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

nonisolated enum SonioxTransportCloseDisposition: Sendable {
    case normal
    case cancelled
}

nonisolated protocol SonioxWebSocketTransport: AnyObject, Sendable {
    func start() async throws
    func send(_ frame: SonioxWebSocketFrame) async throws
    func receive() async throws -> SonioxWebSocketFrame
    func close(_ disposition: SonioxTransportCloseDisposition)
}

typealias SonioxTransportFactory = @Sendable (URL) -> any SonioxWebSocketTransport
typealias SonioxSleep = @Sendable (Duration) async throws -> Void

final nonisolated class URLSessionSonioxWebSocketTransport: SonioxWebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var didStart = false
    private var didClose = false

    init(endpoint: URL, session: URLSession = .shared) {
        self.task = session.webSocketTask(with: endpoint)
    }

    nonisolated static func make(_ endpoint: URL) -> any SonioxWebSocketTransport {
        URLSessionSonioxWebSocketTransport(endpoint: endpoint)
    }

    func start() async throws {
        guard self.markStarted() else { return }
        self.task.resume()
    }

    func send(_ frame: SonioxWebSocketFrame) async throws {
        let message: URLSessionWebSocketTask.Message = switch frame {
        case let .text(value): .string(value)
        case let .binary(value): .data(value)
        }
        try await self.task.send(message)
    }

    func receive() async throws -> SonioxWebSocketFrame {
        switch try await self.task.receive() {
        case let .string(value): .text(value)
        case let .data(value): .binary(value)
        @unknown default: throw URLError(.badServerResponse)
        }
    }

    func close(_ disposition: SonioxTransportCloseDisposition) {
        _ = disposition
        guard self.markClosed() else { return }
        self.task.cancel(with: .normalClosure, reason: nil)
    }

    private func markStarted() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.didStart == false, self.didClose == false else { return false }
        self.didStart = true
        return true
    }

    private func markClosed() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.didClose == false else { return false }
        self.didClose = true
        return true
    }
}

nonisolated struct SonioxStartMessage: Encodable, Sendable {
    let apiKey: String
    let model = "stt-rt-v5"
    let audioFormat = "pcm_f32le"
    let sampleRate = 16_000
    let numChannels = 1
    // swiftlint:disable:next discouraged_optional_collection
    let languageHints: [String]?
    let languageHintsStrict: Bool
    let enableEndpointDetection = false

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case languageHints = "language_hints"
        case languageHintsStrict = "language_hints_strict"
        case enableEndpointDetection = "enable_endpoint_detection"
    }
}

nonisolated struct SonioxError: Error, Equatable, Sendable {
    let category: SonioxFailureCategory
    let diagnosticType: String
    let requestID: String?
}

nonisolated struct SonioxUserFacingErrorCopy: Equatable, Sendable {
    let title: String
    let message: String
}

nonisolated enum SonioxErrorMapper {
    static func category(for errorType: String) -> SonioxFailureCategory {
        switch errorType {
        case "unauthenticated", "temp_api_key_session_expired": .credential
        case "invalid_request", "model_not_available": .configuration
        case "organization_balance_exhausted", "organization_monthly_budget_exhausted",
             "project_monthly_budget_exhausted": .balance
        case "limit_exceeded": .limit
        case "request_timeout", "max_duration_reached", "internal_error", "service_unavailable":
            .temporaryService
        default: .temporaryService
        }
    }

    static func error(errorType: String?, requestID: String?) -> SonioxError {
        let diagnosticType = self.sanitizedErrorType(errorType)
        return SonioxError(
            category: self.category(for: diagnosticType),
            diagnosticType: diagnosticType,
            requestID: self.sanitizedRequestID(requestID)
        )
    }

    static func sanitizedRequestID(_ value: String?) -> String? {
        guard let value,
              value.utf8.count <= 128,
              value.unicodeScalars.isEmpty == false
        else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }

    static func userFacingCopy(for category: SonioxFailureCategory) -> SonioxUserFacingErrorCopy {
        switch category {
        case .credential:
            .init(
                title: "Soniox API Key Required",
                message: "Check or re-verify the Soniox API key for the selected region in Voice Engine settings."
            )
        case .configuration:
            .init(
                title: "Soniox Configuration Error",
                message: "The selected Soniox model or audio configuration is unavailable."
            )
        case .balance:
            .init(
                title: "Soniox Balance Exhausted",
                message: "Add balance or increase the project budget in Soniox, then try again."
            )
        case .limit:
            .init(
                title: "Soniox Usage Limit Reached",
                message: "The Soniox concurrency or rate limit was reached. Try again shortly."
            )
        case .temporaryService:
            .init(
                title: "Soniox Temporarily Unavailable",
                message: "Check the network connection and try again."
            )
        case .finalizationTimeout:
            .init(
                title: "Soniox Finalization Timed Out",
                message: "Soniox did not finish the transcription in time. Try again."
            )
        }
    }

    private static func sanitizedErrorType(_ value: String?) -> String {
        guard let value,
              value.utf8.count <= 64,
              value.unicodeScalars.isEmpty == false
        else {
            return "unknown_error_type"
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : "unknown_error_type"
    }
}

nonisolated enum SonioxPCMEncoder {
    static func float32LittleEndian(_ samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<UInt32>.size)
        for sample in samples {
            var bitPattern = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bitPattern) { data.append(contentsOf: $0) }
        }
        return data
    }
}
