import CryptoKit
import Foundation

nonisolated enum SonioxFailureCategory: String, Equatable, Sendable {
    case credential
    case configuration
    case balance
    case limit
    case temporaryService
    case finalizationTimeout
}

nonisolated struct SonioxCredentialError: Error, Equatable, LocalizedError, Sendable {
    let category: SonioxFailureCategory
    let diagnosticType: String
    let requestID: String?

    var errorDescription: String? {
        let requestIDDescription = self.requestID.map { ", request_id=\($0)" } ?? ""
        return "Soniox credential verification failed: \(self.category.rawValue), \(self.diagnosticType)\(requestIDDescription)"
    }

    static let staleVerification = SonioxCredentialError(
        category: .credential,
        diagnosticType: "stale_verification",
        requestID: nil
    )

    static let apiKeyRequired = SonioxCredentialError(
        category: .credential,
        diagnosticType: "api_key_required",
        requestID: nil
    )

    static func notVerifiedForRegion(
        _ region: SettingsStore.SonioxRegion
    ) -> SonioxCredentialError {
        _ = region
        return SonioxCredentialError(
            category: .credential,
            diagnosticType: "credential_not_verified_for_region",
            requestID: nil
        )
    }
}

protocol SonioxCredentialStoring {
    func fetchAPIKey() throws -> String?
    func replaceAPIKey(_ value: String) throws
    func removeAPIKey() throws
}

struct KeychainSonioxCredentialStore: SonioxCredentialStoring {
    static let providerID = "asr:soniox"

    private let keychain: KeychainService

    init(keychain: KeychainService = .shared) {
        self.keychain = keychain
    }

    func fetchAPIKey() throws -> String? {
        try self.keychain.fetchKey(for: Self.providerID)
    }

    func replaceAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try self.removeAPIKey()
            return
        }
        try self.keychain.storeKey(trimmed, for: Self.providerID)
    }

    func removeAPIKey() throws {
        try self.keychain.deleteKey(for: Self.providerID)
    }
}

nonisolated protocol SonioxModelsTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

typealias SonioxCredentialSleep = @Sendable (Duration) async throws -> Void

protocol SonioxCredentialVerifying {
    func verify(apiKey: String, region: SettingsStore.SonioxRegion) async throws
}

nonisolated struct SonioxVerificationReceipt: Codable, Equatable, Sendable {
    let region: SettingsStore.SonioxRegion
    let credentialFingerprint: String

    static func make(
        apiKey: String,
        region: SettingsStore.SonioxRegion
    ) -> SonioxVerificationReceipt {
        SonioxVerificationReceipt(
            region: region,
            credentialFingerprint: self.fingerprint(apiKey: apiKey)
        )
    }

    static func fingerprint(apiKey: String) -> String {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum SonioxCredentialMutationResult: Equatable, Sendable {
    case removed
    case verified(SonioxVerificationReceipt)
}

nonisolated struct SonioxCredentialVerifier: SonioxCredentialVerifying, Sendable {
    private let transport: any SonioxModelsTransport
    private let sleep: SonioxCredentialSleep

    init(
        transport: any SonioxModelsTransport = URLSessionSonioxModelsTransport(),
        sleep: @escaping SonioxCredentialSleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.transport = transport
        self.sleep = sleep
    }

    func verify(apiKey: String, region: SettingsStore.SonioxRegion) async throws {
        var request = URLRequest(url: region.verificationModelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let result = await withTaskGroup(of: VerificationResult.self, returning: VerificationResult.self) { group in
            group.addTask {
                do {
                    let response = try await self.transport.data(for: request)
                    return .response(response.0, response.1)
                } catch {
                    return .transportFailure
                }
            }
            group.addTask {
                do {
                    try await self.sleep(.seconds(10))
                    return .timeout
                } catch {
                    return .sleepCancelled
                }
            }

            while let result = await group.next() {
                switch result {
                case .sleepCancelled:
                    continue
                case .response, .transportFailure, .timeout:
                    group.cancelAll()
                    while await group.next() != nil {}
                    return result
                }
            }
            return .transportFailure
        }

        switch result {
        case let .response(data, response):
            try self.validate(data: data, response: response)
        case .timeout:
            throw SonioxCredentialError(
                category: .temporaryService,
                diagnosticType: "verification_timeout",
                requestID: nil
            )
        case .transportFailure, .sleepCancelled:
            throw SonioxCredentialError(
                category: .temporaryService,
                diagnosticType: "transport_failure",
                requestID: nil
            )
        }
    }

    private func validate(data: Data, response: HTTPURLResponse) throws {
        let requestID = Self.sanitizedRequestID(response.value(forHTTPHeaderField: "X-Request-ID"))
        guard response.statusCode == 200 else {
            throw SonioxCredentialError(
                category: Self.category(for: response.statusCode),
                diagnosticType: Self.diagnosticType(for: response.statusCode),
                requestID: requestID
            )
        }

        guard let models = try? JSONDecoder().decode(ModelsResponse.self, from: data)
        else {
            throw SonioxCredentialError(
                category: .temporaryService,
                diagnosticType: "malformed_models_response",
                requestID: requestID
            )
        }

        guard models.models.contains(where: { $0.id == "stt-rt-v5" }) else {
            throw SonioxCredentialError(
                category: .configuration,
                diagnosticType: "required_model_unavailable",
                requestID: requestID
            )
        }
    }

    private static func category(for statusCode: Int) -> SonioxFailureCategory {
        switch statusCode {
        case 401, 403: .credential
        case 402: .balance
        case 429: .limit
        default: .temporaryService
        }
    }

    private static func diagnosticType(for statusCode: Int) -> String {
        switch statusCode {
        case 401, 403: "authentication_rejected"
        case 402: "insufficient_balance"
        case 429: "request_limited"
        default: "unexpected_http_status"
        }
    }

    private static func sanitizedRequestID(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(value.unicodeScalars.filter(allowed.contains).prefix(128))
        return sanitized.isEmpty ? nil : sanitized
    }

    private enum VerificationResult: Sendable {
        case response(Data, HTTPURLResponse)
        case transportFailure
        case timeout
        case sleepCancelled
    }

    private struct ModelsResponse: Decodable {
        let models: [Model]
    }

    private struct Model: Decodable {
        let id: String
    }
}

nonisolated struct URLSessionSonioxModelsTransport: SonioxModelsTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

@MainActor
final class SonioxCredentialService {
    private let store: any SonioxCredentialStoring
    private let verifier: any SonioxCredentialVerifying

    init(
        store: (any SonioxCredentialStoring)? = nil,
        verifier: any SonioxCredentialVerifying = SonioxCredentialVerifier()
    ) {
        self.store = store ?? KeychainSonioxCredentialStore()
        self.verifier = verifier
    }

    func saveAndVerify(
        apiKey: String,
        region: SettingsStore.SonioxRegion,
        commitIfCurrent: @escaping @MainActor () -> Bool
    ) async throws -> SonioxCredentialMutationResult {
        let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else {
            try self.store.removeAPIKey()
            return .removed
        }
        try await self.verifier.verify(apiKey: candidate, region: region)
        guard commitIfCurrent() else {
            throw SonioxCredentialError.staleVerification
        }
        try self.store.replaceAPIKey(candidate)
        return .verified(.make(apiKey: candidate, region: region))
    }

    func remove() throws {
        try self.store.removeAPIKey()
    }

    func storedCredentialFingerprint() throws -> String? {
        let value = try self.store.fetchAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, value.isEmpty == false else { return nil }
        return SonioxVerificationReceipt.fingerprint(apiKey: value)
    }
}
