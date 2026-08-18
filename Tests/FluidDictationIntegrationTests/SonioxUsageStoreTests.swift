@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class SonioxUsageStoreTests: XCTestCase {
    func testRefreshLoadsCurrentMonthUsageAndPersistsSnapshot() async throws {
        let defaults = try self.makeDefaults()
        defer { self.removeDefaults(defaults) }

        let transport = RecordingSonioxUsageTransport(result: .success(Self.usageResponse()))
        let credentials = TestSonioxCredentialStore(value: "  test-key  ")
        let now = Date(timeIntervalSince1970: 1_755_547_200) // 2025-08-18 00:00:00 UTC
        let store = SonioxUsageStore(
            transport: transport,
            credentialStore: credentials,
            defaults: defaults,
            now: { now },
            region: { .global }
        )

        await store.refreshIfNeeded(force: true)

        let snapshot = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(snapshot.totalCostUSD, Decimal(string: "0.1250000000"))
        XCTAssertEqual(snapshot.totalRequests, 3)
        XCTAssertEqual(snapshot.totalInputAudioDurationMilliseconds, 1_234)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(defaults.data(forKey: "SonioxUsageSnapshot"))

        let restoredStore = SonioxUsageStore(
            transport: transport,
            credentialStore: credentials,
            defaults: defaults,
            now: { now },
            region: { .global }
        )
        XCTAssertEqual(restoredStore.snapshot, snapshot)

        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.url?.host, "api.soniox.com")
        XCTAssertEqual(request.url?.path, "/v1/usage/summary")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.count, 2)
    }

    func testUsageSummaryURLUsesConfiguredRegion() {
        XCTAssertEqual(SettingsStore.SonioxRegion.global.usageSummaryURL.absoluteString, "https://api.soniox.com/v1/usage/summary")
        XCTAssertEqual(SettingsStore.SonioxRegion.japan.usageSummaryURL.absoluteString, "https://api.jp.soniox.com/v1/usage/summary")
    }

    func testRefreshUsesRecentSnapshotUntilThrottleExpires() async throws {
        let defaults = try self.makeDefaults()
        defer { self.removeDefaults(defaults) }

        let transport = RecordingSonioxUsageTransport(result: .success(Self.usageResponse()))
        let credentials = TestSonioxCredentialStore(value: "test-key")
        let now = Date(timeIntervalSince1970: 1_755_547_200)
        let store = SonioxUsageStore(
            transport: transport,
            credentialStore: credentials,
            defaults: defaults,
            now: { now },
            region: { .global }
        )

        await store.refreshIfNeeded(force: true)
        await store.refreshIfNeeded()

        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(credentials.fetchCount, 1)
    }

    func testRefreshFailureKeepsSnapshotAndMarksItStale() async throws {
        let defaults = try self.makeDefaults()
        defer { self.removeDefaults(defaults) }

        let transport = RecordingSonioxUsageTransport(results: [
            .success(Self.usageResponse()),
            .success(Self.usageResponse(statusCode: 503)),
        ])
        let store = SonioxUsageStore(
            transport: transport,
            credentialStore: TestSonioxCredentialStore(value: "test-key"),
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_755_547_200) },
            region: { .global }
        )

        await store.refreshIfNeeded(force: true)
        let snapshotBeforeFailure = try XCTUnwrap(store.snapshot)

        await store.refreshIfNeeded(force: true)

        XCTAssertEqual(store.snapshot, snapshotBeforeFailure)
        XCTAssertTrue(store.isStale)
        XCTAssertEqual(store.errorMessage, "Soniox usage request failed (HTTP 503).")
    }

    func testRefreshWithoutAPIKeyDoesNotMakeRequest() async throws {
        let defaults = try self.makeDefaults()
        defer { self.removeDefaults(defaults) }

        let transport = RecordingSonioxUsageTransport(result: .success(Self.usageResponse()))
        let store = SonioxUsageStore(
            transport: transport,
            credentialStore: TestSonioxCredentialStore(value: " \n"),
            defaults: defaults,
            now: Date.init,
            region: { .japan }
        )

        await store.refreshIfNeeded(force: true)

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.errorMessage, "Configure a Soniox API key to load usage.")
        XCTAssertEqual(transport.requestCount, 0)
    }

    private static func usageResponse(statusCode: Int = 200) -> (Data, HTTPURLResponse) {
        let data = Data(
            """
            {
              "total": {
                "total_cost_usd": "0.1250000000",
                "total_num_requests": 3,
                "total_input_audio_duration_ms": 1234
              }
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: URL(string: "https://api.soniox.com/v1/usage/summary")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SonioxUsageStoreTests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func removeDefaults(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: "SonioxUsageSnapshot")
    }
}

private final class TestSonioxCredentialStore: SonioxCredentialStoring {
    var value: String?
    private(set) var fetchCount = 0

    init(value: String?) {
        self.value = value
    }

    func fetchAPIKey() throws -> String? {
        self.fetchCount += 1
        return self.value
    }

    func replaceAPIKey(_ value: String) throws {
        self.value = value
    }

    func removeAPIKey() throws {
        self.value = nil
    }
}

private final class RecordingSonioxUsageTransport: SonioxUsageTransport, @unchecked Sendable {
    enum Result {
        case success((Data, HTTPURLResponse))
        case failure(Error)
    }

    private let lock = NSLock()
    private var results: [Result]
    private var capturedRequest: URLRequest?
    private var requests = 0

    init(result: Result) {
        self.results = [result]
    }

    init(results: [Result]) {
        self.results = results
    }

    var request: URLRequest? {
        self.lock.withLock { self.capturedRequest }
    }

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = self.lock.withLock { () -> Result in
            self.capturedRequest = request
            self.requests += 1
            return self.results.count > 1 ? self.results.removeFirst() : self.results[0]
        }

        switch result {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        }
    }
}
