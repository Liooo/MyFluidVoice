import Foundation

nonisolated struct SonioxServerMessage: Decodable, Sendable {
    let tokens: [SonioxToken]
    let finished: Bool
    let errorType: String?
    let requestID: String?

    init(
        tokens: [SonioxToken] = [],
        finished: Bool = false,
        errorType: String? = nil,
        requestID: String? = nil
    ) {
        self.tokens = tokens
        self.finished = finished
        self.errorType = errorType
        self.requestID = requestID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokens = try container.decodeIfPresent([SonioxToken].self, forKey: .tokens) ?? []
        self.finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        self.errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        self.requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorType = "error_type"
        case requestID = "request_id"
    }
}

nonisolated struct SonioxToken: Decodable, Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Float?

    private enum CodingKeys: String, CodingKey {
        case text, confidence
        case isFinal = "is_final"
    }
}

nonisolated struct SonioxTranscriptSnapshot: Equatable, Sendable {
    let completeText: String
    let finalText: String
    let confidence: Float
    let sawFin: Bool
    let sawEnd: Bool
    let finished: Bool
}

nonisolated struct SonioxTokenReducer: Sendable {
    private var finalText = ""
    private var provisionalText = ""
    private var finalConfidenceSum: Float = 0
    private var finalConfidenceCount = 0
    private var provisionalConfidenceSum: Float = 0
    private var provisionalConfidenceCount = 0
    private var sawFin = false
    private var sawEnd = false

    mutating func reduce(_ message: SonioxServerMessage) throws -> SonioxTranscriptSnapshot {
        if message.errorType != nil {
            throw SonioxErrorMapper.error(errorType: message.errorType, requestID: message.requestID)
        }

        self.provisionalText = ""
        self.provisionalConfidenceSum = 0
        self.provisionalConfidenceCount = 0

        for token in message.tokens {
            switch token.text {
            case "<fin>":
                self.sawFin = true
            case "<end>":
                self.sawEnd = true
            default:
                if token.isFinal {
                    self.finalText += token.text
                    self.addFinalConfidence(token.confidence)
                } else {
                    self.provisionalText += token.text
                    self.addProvisionalConfidence(token.confidence)
                }
            }
        }

        let confidenceCount = self.finalConfidenceCount + self.provisionalConfidenceCount
        let confidence = confidenceCount == 0
            ? 0
            : (self.finalConfidenceSum + self.provisionalConfidenceSum) / Float(confidenceCount)
        return SonioxTranscriptSnapshot(
            completeText: self.finalText + self.provisionalText,
            finalText: self.finalText,
            confidence: confidence,
            sawFin: self.sawFin,
            sawEnd: self.sawEnd,
            finished: message.finished
        )
    }

    mutating func reset() {
        self = SonioxTokenReducer()
    }

    private mutating func addFinalConfidence(_ confidence: Float?) {
        guard let confidence else { return }
        self.finalConfidenceSum += confidence
        self.finalConfidenceCount += 1
    }

    private mutating func addProvisionalConfidence(_ confidence: Float?) {
        guard let confidence else { return }
        self.provisionalConfidenceSum += confidence
        self.provisionalConfidenceCount += 1
    }
}
