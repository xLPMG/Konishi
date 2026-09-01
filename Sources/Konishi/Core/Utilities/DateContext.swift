import Foundation

enum DateContext {
    /// A rough, cache-friendly "now" for background awareness: weekday, date, and part of day.
    /// Deliberately day/part-of-day granular (not exact clock time) so the system prompt stays
    /// stable within a session and doesn't invalidate the server's prefix cache every turn.
    static func current(_ date: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part: String
        // The small hours (past midnight, before dawn) are still colloquially the PREVIOUS
        // day's night — at 00:30 on Friday it's "Thursday night", not "Friday night".
        var dayDate = date
        switch hour {
        case 5..<12: part = "morning"
        case 12..<17: part = "afternoon"
        case 17..<21: part = "evening"
        case 21...23: part = "night"
        default:
            part = "night"
            dayDate = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return "\(dateContextFormatter.string(from: dayDate)) (\(part))"
    }

    private static let dateContextFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()
}
