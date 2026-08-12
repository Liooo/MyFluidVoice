import Foundation

/// Compatibility facade for existing local instrumentation.
///
/// The fork deliberately does not configure an analytics transport. Keeping this
/// type preserves the app's lightweight event call sites without collecting or
/// transmitting any data.
final class AnalyticsService {
    static let shared = AnalyticsService()

    private init() {}

    func bootstrap() {}

    func setEnabled(_: Bool) {}

    func capture(_: AnalyticsEvent, properties _: [String: Any] = [:]) {}
}
