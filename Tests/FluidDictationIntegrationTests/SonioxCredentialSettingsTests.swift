@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class SonioxCredentialSettingsTests: XCTestCase {
    func testVerificationUsesRegionModelsEndpointBearerHeaderGETAndTenSecondTimeout() async throws {
        let transport = RecordingTransport(result: .success(modelsResponse()))
        let verifier = SonioxCredentialVerifier(transport: transport, sleep: immediateSleep)

        try await verifier.verify(apiKey: "candidate-value", region: .japan)

        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.url, SettingsStore.SonioxRegion.japan.verificationModelsURL)
        XCTAssertEqual(request.httpMethod, "GET")
        let bearerValue = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(bearerValue.hasPrefix("Bearer "))
        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: String(bearerValue.dropFirst("Bearer ".count))),
            SonioxVerificationReceipt.fingerprint(apiKey: "candidate-value")
        )
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testVerificationRequiresHTTP200AndSttRtV5InResponse() async {
        let cases: [(RecordingTransport.Result, SonioxFailureCategory)] = [
            (.success(modelsResponse(statusCode: 201)), .temporaryService),
            (.success(modelsResponse(modelID: "other-model")), .configuration),
        ]

        for (result, category) in cases {
            let verifier = SonioxCredentialVerifier(
                transport: RecordingTransport(result: result),
                sleep: immediateSleep
            )

            do {
                try await verifier.verify(apiKey: "candidate-value", region: .global)
                XCTFail("Expected verification to fail")
            } catch let error as SonioxCredentialError {
                XCTAssertEqual(error.category, category)
            } catch {
                XCTFail("Expected a sanitized Soniox credential error")
            }
        }
    }

    func testSuccessfulVerificationReplacesPriorKeyExactlyOnce() async throws {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let service = SonioxCredentialService(
            store: store,
            verifier: successfulVerifier()
        )

        let result = try await service.saveAndVerify(
            apiKey: " candidate-value ",
            region: .global,
            commitIfCurrent: { true }
        )

        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "candidate-value")
        )
        XCTAssertEqual(store.replaceCount, 1)
        XCTAssertEqual(result, .verified(.make(apiKey: "candidate-value", region: .global)))
    }

    func test401500TimeoutAndMalformedBodyKeepPriorKeyUnchanged() async {
        let cases: [(RecordingTransport.Result, SonioxFailureCategory)] = [
            (.success(modelsResponse(statusCode: 401)), .credential),
            (.success(modelsResponse(statusCode: 403)), .credential),
            (.success(modelsResponse(statusCode: 402)), .balance),
            (.success(modelsResponse(statusCode: 429)), .limit),
            (.success(modelsResponse(statusCode: 500)), .temporaryService),
            (.failure(URLError(.timedOut)), .temporaryService),
            (.success(HTTPResponse(data: Data("not-json".utf8))), .temporaryService),
        ]

        for (result, category) in cases {
            let store = FakeCredentialStore(initialValue: "prior-value")
            let service = SonioxCredentialService(
                store: store,
                verifier: SonioxCredentialVerifier(
                    transport: RecordingTransport(result: result),
                    sleep: immediateSleep
                )
            )

            do {
                _ = try await service.saveAndVerify(
                    apiKey: "candidate-value",
                    region: .global,
                    commitIfCurrent: { true }
                )
                XCTFail("Expected verification to fail")
            } catch let error as SonioxCredentialError {
                XCTAssertEqual(error.category, category)
            } catch {
                XCTFail("Expected a sanitized Soniox credential error")
            }
            XCTAssertEqual(
                SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
                SonioxVerificationReceipt.fingerprint(apiKey: "prior-value")
            )
            XCTAssertEqual(store.replaceCount, 0)
        }
    }

    func testEmptySaveDeletesWithoutNetworkRequest() async throws {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let transport = RecordingTransport(result: .success(modelsResponse()))
        let service = SonioxCredentialService(
            store: store,
            verifier: SonioxCredentialVerifier(transport: transport, sleep: immediateSleep)
        )

        let result = try await service.saveAndVerify(
            apiKey: " \n ",
            region: .global,
            commitIfCurrent: { true }
        )

        XCTAssertEqual(result, .removed)
        XCTAssertNil(store.value)
        XCTAssertEqual(store.removeCount, 1)
        XCTAssertNil(transport.request)
    }

    func testErrorDescriptionContainsStableCategoryAndRequestIDOnly() async {
        let verifier = SonioxCredentialVerifier(
            transport: RecordingTransport(
                result: .success(modelsResponse(statusCode: 429, requestID: "request_123"))
            ),
            sleep: immediateSleep
        )

        do {
            try await verifier.verify(apiKey: "candidate-value", region: .global)
            XCTFail("Expected verification to fail")
        } catch let error as SonioxCredentialError {
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains(SonioxFailureCategory.limit.rawValue))
            XCTAssertTrue(description.contains("request_123"))
        } catch {
            XCTFail("Expected a sanitized Soniox credential error")
        }
    }

    func testReflectedCandidateRequestIDNeverReachesCredentialError() async {
        let candidate = "candidate-value"
        let verifier = SonioxCredentialVerifier(
            transport: RecordingTransport(
                result: .success(modelsResponse(statusCode: 500, requestID: candidate))
            ),
            sleep: immediateSleep
        )

        do {
            try await verifier.verify(apiKey: candidate, region: .global)
            XCTFail("Expected verification to fail")
        } catch let error as SonioxCredentialError {
            XCTAssertTrue(error.requestID == nil)
            XCTAssertFalse((error.errorDescription ?? "").contains(candidate))
        } catch {
            XCTFail("Expected a sanitized Soniox credential error")
        }
    }

    func testCredentialErrorNeverContainsCandidateKeyResponseBodyOrTranscript() async {
        let candidate = "candidate-value"
        let responseBody = "server-message"
        let transcript = "transcript-value"
        let verifier = SonioxCredentialVerifier(
            transport: RecordingTransport(
                result: .success(HTTPResponse(data: Data(responseBody.utf8), statusCode: 500))
            ),
            sleep: immediateSleep
        )

        do {
            try await verifier.verify(apiKey: candidate, region: .global)
            XCTFail("Expected verification to fail")
        } catch let error as SonioxCredentialError {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.contains(candidate))
            XCTAssertFalse(description.contains(responseBody))
            XCTAssertFalse(description.contains(transcript))
        } catch {
            XCTFail("Expected a sanitized Soniox credential error")
        }
    }

    func testGenerationOrSameRegionRestoreBeforeCommitKeepsPriorKeyAndReceipt() async {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
        var receipt: SonioxVerificationReceipt? = .make(apiKey: "prior-value", region: .global)

        do {
            _ = try await service.saveAndVerify(
                apiKey: "candidate-value",
                region: .global,
                commitIfCurrent: {
                    receipt = nil
                    return false
                }
            )
            XCTFail("Expected stale verification")
        } catch let error as SonioxCredentialError {
            XCTAssertEqual(error, .staleVerification)
        } catch {
            XCTFail("Expected a stale-verification error")
        }

        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "prior-value")
        )
        XCTAssertNil(receipt)
    }

    func testRegionChangeBeforeCommitKeepsPriorKeyButClearsReceipt() async {
        let store = FakeCredentialStore(initialValue: "prior-value")
        let service = SonioxCredentialService(store: store, verifier: successfulVerifier())
        var receipt: SonioxVerificationReceipt? = .make(apiKey: "prior-value", region: .global)

        do {
            _ = try await service.saveAndVerify(
                apiKey: "candidate-value",
                region: .japan,
                commitIfCurrent: {
                    receipt = nil
                    return false
                }
            )
            XCTFail("Expected stale verification")
        } catch let error as SonioxCredentialError {
            XCTAssertEqual(error, .staleVerification)
        } catch {
            XCTFail("Expected a stale-verification error")
        }

        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: store.value ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "prior-value")
        )
        XCTAssertNil(receipt)
    }

    func testExplicitTenSecondRaceTimesOutEvenWhenTransportNeverReturns() async {
        let transport = CancellationResponsiveTransport()
        let verifier = SonioxCredentialVerifier(
            transport: transport,
            sleep: { _ in
                await transport.waitUntilRequestStarts()
            }
        )

        do {
            try await verifier.verify(apiKey: "candidate-value", region: .global)
            XCTFail("Expected explicit timeout")
        } catch let error as SonioxCredentialError {
            XCTAssertEqual(error.category, .temporaryService)
        } catch {
            XCTFail("Expected a sanitized timeout error")
        }
        XCTAssertTrue(transport.wasCancelled)
    }

    func testVerificationReceiptChangesWithRegionOrKeyWithoutContainingEitherSecretValue() {
        let global = SonioxVerificationReceipt.make(apiKey: "candidate-value", region: .global)
        let japan = SonioxVerificationReceipt.make(apiKey: "candidate-value", region: .japan)
        let otherKey = SonioxVerificationReceipt.make(apiKey: "other-value", region: .global)

        XCTAssertNotEqual(global, japan)
        XCTAssertNotEqual(global, otherKey)
        XCTAssertFalse(global.credentialFingerprint.contains("candidate-value"))
        XCTAssertFalse(String(describing: global).contains("candidate-value"))
    }

    func testGenericAIKeyReadsExcludeReservedASRCredentials() {
        let values = KeychainService.unreservedKeys([
            "openai": "generic-value",
            "asr:soniox": "reserved-value",
        ])

        XCTAssertEqual(values.keys.sorted(), ["openai"])
        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: values["openai"] ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "generic-value")
        )
    }

    func testSavingGenericAIKeysAtomicallyPreservesReservedASRCredentials() {
        let existing = [
            "openai": "old-value",
            "groq": "old-groq-value",
            "asr:soniox": "reserved-value",
            "asr:other": "other-reserved-value",
        ]

        func assertReservedKeysAreUnchanged(_ result: [String: String]) {
            for (providerID, value) in existing where providerID.hasPrefix("asr:") {
                XCTAssertTrue(result[providerID] == value)
            }
        }

        let added = KeychainService.replacingUnreservedKeys(
            existing: existing,
            replacements: ["anthropic": "added-value"]
        )
        XCTAssertEqual(added.keys.sorted(), ["anthropic", "asr:other", "asr:soniox"])
        assertReservedKeysAreUnchanged(added)

        let updated = KeychainService.replacingUnreservedKeys(
            existing: existing,
            replacements: ["groq": "updated-value"]
        )
        XCTAssertEqual(updated.keys.sorted(), ["asr:other", "asr:soniox", "groq"])
        XCTAssertEqual(
            SonioxVerificationReceipt.fingerprint(apiKey: updated["groq"] ?? ""),
            SonioxVerificationReceipt.fingerprint(apiKey: "updated-value")
        )
        assertReservedKeysAreUnchanged(updated)

        let deleted = KeychainService.replacingUnreservedKeys(existing: existing, replacements: [:])
        XCTAssertEqual(deleted.keys.sorted(), ["asr:other", "asr:soniox"])
        assertReservedKeysAreUnchanged(deleted)
    }
}

private let immediateSleep: SonioxCredentialSleep = { _ in
    try await Task.sleep(for: .seconds(3600))
}

private func successfulVerifier() -> SonioxCredentialVerifier {
    SonioxCredentialVerifier(
        transport: RecordingTransport(result: .success(modelsResponse())),
        sleep: immediateSleep
    )
}

private func modelsResponse(
    statusCode: Int = 200,
    modelID: String = "stt-rt-v5",
    requestID: String? = nil
) -> HTTPResponse {
    let data = Data("{\"models\":[{\"id\":\"\(modelID)\"}]}".utf8)
    return HTTPResponse(data: data, statusCode: statusCode, requestID: requestID)
}

private struct HTTPResponse {
    let data: Data
    let statusCode: Int
    let requestID: String?

    init(data: Data, statusCode: Int = 200, requestID: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.requestID = requestID
    }

    func asURLResponse() -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: URL(fileURLWithPath: "/v1/models"),
            statusCode: self.statusCode,
            httpVersion: nil,
            headerFields: self.requestID.map { ["X-Request-ID": $0] }
        ) else {
            preconditionFailure("The static test response URL must be valid")
        }
        return response
    }
}

private final class FakeCredentialStore: SonioxCredentialStoring {
    var value: String?
    private(set) var replaceCount = 0
    private(set) var removeCount = 0

    init(initialValue: String?) {
        self.value = initialValue
    }

    func fetchAPIKey() throws -> String? {
        self.value
    }

    func replaceAPIKey(_ value: String) throws {
        self.value = value
        self.replaceCount += 1
    }

    func removeAPIKey() throws {
        self.value = nil
        self.removeCount += 1
    }
}

private final class RecordingTransport: SonioxModelsTransport, @unchecked Sendable {
    enum Result {
        case success(HTTPResponse)
        case failure(Error)
    }

    private let result: Result
    private let lock = NSLock()
    private var capturedRequest: URLRequest?

    init(result: Result) {
        self.result = result
    }

    var request: URLRequest? {
        self.lock.withLock { self.capturedRequest }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.lock.withLock { self.capturedRequest = request }
        switch self.result {
        case let .success(response):
            return (response.data, response.asURLResponse())
        case let .failure(error):
            throw error
        }
    }
}

private final class CancellationResponsiveTransport: SonioxModelsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var requestContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var hasStarted = false
    private var cancellationObserved = false

    var wasCancelled: Bool {
        self.lock.withLock { self.cancellationObserved }
    }

    func waitUntilRequestStarts() async {
        if self.lock.withLock({ self.hasStarted }) {
            return
        }
        await withCheckedContinuation { continuation in
            self.lock.withLock {
                if self.hasStarted {
                    continuation.resume()
                } else {
                    self.startedContinuation = continuation
                }
            }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let startedContinuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    self.requestContinuation = continuation
                    self.hasStarted = true
                    defer { self.startedContinuation = nil }
                    return self.startedContinuation
                }
                startedContinuation?.resume()
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
                self.cancellationObserved = true
                defer { self.requestContinuation = nil }
                return self.requestContinuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
