import Foundation

/// Persistence preferences live outside `AppConfig` so history storage can be
/// gated at the store boundary without changing any of the existing data keys.
enum RecognitionHistoryPreferences {
    static let savingEnabledKey = "hushtype.recognitionHistory.savingEnabled"

    static func isSavingEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: savingEnabledKey) as? Bool else {
            return true
        }
        return value
    }
}

/// A local-calendar date range. The visible end date is inclusive, so a range
/// ending on September 10 contains every entry through the following local
/// midnight without relying on a fixed 24-hour day.
struct RecognitionHistoryDateRange: Equatable, Sendable {
    var startDate: Date
    var endDate: Date

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let firstDay = calendar.startOfDay(for: min(startDate, endDate))
        let lastDay = calendar.startOfDay(for: max(startDate, endDate))
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: lastDay) else {
            return date >= firstDay && date >= lastDay
        }
        return date >= firstDay && date < endExclusive
    }
}
