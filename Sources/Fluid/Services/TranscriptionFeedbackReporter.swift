import Foundation

enum TranscriptionFeedbackReporter {
    struct Payload: Encodable {
        let rawText: String
        let processedText: String
        let processingModel: String
        let comments: String
    }

    enum ReporterError: LocalizedError {
        case unavailable
        case invalidURL
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Feedback submission is not configured yet."
            case .invalidURL:
                return "Invalid report endpoint."
            case .invalidResponse:
                return "Invalid report response."
            case let .httpError(statusCode):
                return "Report failed with HTTP \(statusCode)."
            }
        }
    }

    static func submit(_: Payload) async throws {
        throw ReporterError.unavailable
    }
}
