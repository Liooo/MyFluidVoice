import Combine
import Foundation

nonisolated protocol SonioxUsageTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionSonioxUsageTransport: SonioxUsageTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SonioxUsageStoreError.invalidResponse
        }
        return (data, httpResponse)
    }
}

struct SonioxUsageSnapshot: Codable, Equatable, Sendable {
    let periodStart: Date
    let periodEnd: Date
    let totalCostUSD: Decimal
    let totalRequests: Int
    let totalInputAudioDurationMilliseconds: Int64
    let fetchedAt: Date
}

enum SonioxUsageStoreError: LocalizedError, Equatable, Sendable {
    case apiKeyMissing
    case invalidResponse
    case requestFailed(statusCode: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "Configure a Soniox API key to load usage."
        case .invalidResponse:
            return "Soniox returned an invalid response."
        case let .requestFailed(statusCode):
            return "Soniox usage request failed (HTTP \(statusCode))."
        case .malformedResponse:
            return "Soniox usage response could not be read."
        }
    }
}

@MainActor
final class SonioxUsageStore: ObservableObject {
    static let shared = SonioxUsageStore()

    private static let snapshotDefaultsKey = "SonioxUsageSnapshot"
    private static let refreshInterval: TimeInterval = 5 * 60

    @Published private(set) var snapshot: SonioxUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let transport: any SonioxUsageTransport
    private let credentialStore: any SonioxCredentialStoring
    private let defaults: UserDefaults
    private let now: () -> Date
    private let region: @MainActor () -> SettingsStore.SonioxRegion

    init(
        transport: any SonioxUsageTransport = URLSessionSonioxUsageTransport(),
        credentialStore: (any SonioxCredentialStoring)? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        region: (@MainActor () -> SettingsStore.SonioxRegion)? = nil
    ) {
        self.transport = transport
        self.credentialStore = credentialStore ?? KeychainSonioxCredentialStore()
        self.defaults = defaults
        self.now = now
        self.region = region ?? { SettingsStore.shared.sonioxRegion }
        self.snapshot = Self.loadSnapshot(from: defaults)
    }

    var isStale: Bool {
        self.snapshot != nil && self.errorMessage != nil
    }

    func refreshIfNeeded(force: Bool = false) async {
        let currentDate = self.now()
        if !force,
           let snapshot = self.snapshot,
           snapshot.periodStart == Self.currentPeriod(for: currentDate).start,
           currentDate.timeIntervalSince(snapshot.fetchedAt) < Self.refreshInterval
        {
            return
        }

        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        do {
            let apiKey = try self.apiKey()
            let period = Self.currentPeriod(for: currentDate)
            let request = try self.makeRequest(apiKey: apiKey, period: period)
            let (data, response) = try await self.transport.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw SonioxUsageStoreError.requestFailed(statusCode: response.statusCode)
            }

            let total = try JSONDecoder().decode(SonioxUsageResponse.self, from: data).total
            let snapshot = SonioxUsageSnapshot(
                periodStart: period.start,
                periodEnd: period.end,
                totalCostUSD: total.totalCostUSD.value,
                totalRequests: total.totalRequests,
                totalInputAudioDurationMilliseconds: total.totalInputAudioDurationMilliseconds,
                fetchedAt: currentDate
            )
            self.snapshot = snapshot
            self.persist(snapshot)
            self.errorMessage = nil
        } catch {
            self.errorMessage = Self.userFacingError(for: error)
        }
    }

    private func apiKey() throws -> String {
        let key = try self.credentialStore.fetchAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw SonioxUsageStoreError.apiKeyMissing }
        return key
    }

    private func makeRequest(apiKey: String, period: UsagePeriod) throws -> URLRequest {
        guard var components = URLComponents(url: self.region().usageSummaryURL, resolvingAgainstBaseURL: false) else {
            throw SonioxUsageStoreError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "start_time", value: Self.iso8601String(period.start)),
            URLQueryItem(name: "end_time", value: Self.iso8601String(period.end)),
        ]
        guard let url = components.url else { throw SonioxUsageStoreError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func persist(_ snapshot: SonioxUsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        self.defaults.set(data, forKey: Self.snapshotDefaultsKey)
    }

    private static func loadSnapshot(from defaults: UserDefaults) -> SonioxUsageSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SonioxUsageSnapshot.self, from: data)
    }

    private static func userFacingError(for error: Error) -> String {
        if let usageError = error as? SonioxUsageStoreError {
            return usageError.localizedDescription
        }
        return "Unable to load Soniox usage."
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func currentPeriod(for date: Date) -> UsagePeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return UsagePeriod(start: start, end: end)
    }

    private struct UsagePeriod: Sendable {
        let start: Date
        let end: Date
    }

    private struct SonioxUsageResponse: Decodable {
        let total: Total

        struct Total: Decodable {
            let totalCostUSD: DecimalValue
            let totalRequests: Int
            let totalInputAudioDurationMilliseconds: Int64

            enum CodingKeys: String, CodingKey {
                case totalCostUSD = "total_cost_usd"
                case totalRequests = "total_num_requests"
                case totalInputAudioDurationMilliseconds = "total_input_audio_duration_ms"
            }
        }
    }

    private struct DecimalValue: Decodable {
        let value: Decimal

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let stringValue = try? container.decode(String.self),
               let decimalValue = Decimal(string: stringValue, locale: Locale(identifier: "en_US_POSIX"))
            {
                self.value = decimalValue
                return
            }
            if let decimalValue = try? container.decode(Decimal.self) {
                self.value = decimalValue
                return
            }
            throw SonioxUsageStoreError.malformedResponse
        }
    }
}
