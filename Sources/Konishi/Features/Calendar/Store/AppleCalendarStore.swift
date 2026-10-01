import Foundation
@preconcurrency import EventKit
import Observation

private struct CalendarReminderSnapshot: Sendable {
    let identifier: String
    let title: String
    let calendarTitle: String
    let dueDate: Date?
}

@MainActor
@Observable
final class AppleCalendarStore {
    enum AccessState: Equatable, Sendable {
        case notDetermined
        case fullAccess
        case writeOnly
        case denied
        case restricted

        var label: String {
            switch self {
            case .notDetermined: "Not connected"
            case .fullAccess: "Full access"
            case .writeOnly: "Write-only access"
            case .denied: "Denied in macOS Settings"
            case .restricted: "Restricted"
            }
        }

        var canRead: Bool { self == .fullAccess }
    }

    private let eventStore = EKEventStore()
    private let localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter
    }()

    private(set) var calendarAccess: AccessState = .notDetermined
    private(set) var remindersAccess: AccessState = .notDetermined
    private(set) var requestingCalendarAccess = false
    private(set) var requestingRemindersAccess = false
    private(set) var accessError: String?

    init() {
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        calendarAccess = Self.accessState(for: .event)
        remindersAccess = Self.accessState(for: .reminder)
    }

    func requestCalendarAccess() async {
        requestingCalendarAccess = true
        accessError = nil
        defer { requestingCalendarAccess = false }
        do {
            _ = try await eventStore.requestFullAccessToEvents()
            refreshAuthorizationStatus()
        } catch {
            refreshAuthorizationStatus()
            accessError = error.localizedDescription
        }
    }

    func requestRemindersAccess() async {
        requestingRemindersAccess = true
        accessError = nil
        defer { requestingRemindersAccess = false }
        do {
            _ = try await eventStore.requestFullAccessToReminders()
            refreshAuthorizationStatus()
        } catch {
            refreshAuthorizationStatus()
            accessError = error.localizedDescription
        }
    }

    func listEvents(days: Int?, calendarName: String?) throws -> String {
        try requireReadAccess(.event)
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let dayCount = min(max(days ?? 1, 1), 30)
        guard let end = calendar.date(byAdding: .day, value: dayCount, to: start) else {
            throw CalendarStoreError.invalidDateRange
        }

        let calendars: [EKCalendar]?
        if let name = calendarName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard let match = eventStore.calendars(for: .event).first(where: {
                $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CalendarStoreError.calendarNotFound(name)
            }
            calendars = [match]
        } else {
            calendars = nil
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "No calendar events in the next \(dayCount) day(s)." }
        let lines = events.prefix(100).map { event in
            var line = "\(localDateFormatter.string(from: event.startDate)) - \(localDateFormatter.string(from: event.endDate)) | \(event.title ?? "Untitled") [\(event.calendar.title)]"
            if event.isAllDay { line += " [all day]" }
            if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                line += "\n  Location: \(location)"
            }
            line += "\n  Event ID: \(event.eventIdentifier ?? "unavailable")"
            return line
        }
        return lines.joined(separator: "\n") + (events.count > 100 ? "\n… showing the first 100 events" : "")
    }

    func createEvent(
        title: String, startDate: String, endDate: String, location: String?, notes: String?,
        calendarName: String?
    ) throws -> String {
        try requireReadAccess(.event)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CalendarStoreError.emptyTitle }
        let start = try parseDate(startDate, allowDateOnly: false)
        let end = try parseDate(endDate, allowDateOnly: false)
        guard end > start else { throw CalendarStoreError.invalidDateRange }

        let targetCalendar: EKCalendar
        if let name = calendarName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard let match = eventStore.calendars(for: .event).first(where: {
                $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw CalendarStoreError.calendarNotFound(name)
            }
            targetCalendar = match
        } else if let defaultCalendar = eventStore.defaultCalendarForNewEvents {
            targetCalendar = defaultCalendar
        } else {
            throw CalendarStoreError.noWritableCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = targetCalendar
        try eventStore.save(event, span: .thisEvent, commit: true)
        return "Created event \"\(title)\" in \(targetCalendar.title): \(localDateFormatter.string(from: start)) - \(localDateFormatter.string(from: end)). Event ID: \(event.eventIdentifier ?? "unavailable")"
    }

    func updateEvent(
        identifier: String, title: String?, startDate: String?, endDate: String?,
        location: String?, notes: String?
    ) throws -> String {
        try requireReadAccess(.event)
        guard let event = eventStore.event(withIdentifier: identifier) else {
            throw CalendarStoreError.itemNotFound("event", identifier)
        }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CalendarStoreError.emptyTitle }
            event.title = trimmed
        }
        if let startDate { event.startDate = try parseDate(startDate, allowDateOnly: false) }
        if let endDate { event.endDate = try parseDate(endDate, allowDateOnly: false) }
        guard event.endDate > event.startDate else { throw CalendarStoreError.invalidDateRange }
        if let location { event.location = location.isEmpty ? nil : location }
        if let notes { event.notes = notes.isEmpty ? nil : notes }
        try eventStore.save(event, span: .thisEvent, commit: true)
        return "Updated event \"\(event.title ?? "Untitled")\". Event ID: \(event.eventIdentifier ?? identifier)"
    }

    func listReminders(days: Int?, includeUndated: Bool?, query: String?, limit: Int?) async throws -> String {
        try requireReadAccess(.reminder)
        let dayCount = min(max(days ?? 7, 1), 90)
        let start = Calendar.current.startOfDay(for: .now)
        guard let end = Calendar.current.date(byAdding: .day, value: dayCount + 1, to: start) else {
            throw CalendarStoreError.invalidDateRange
        }
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders = await fetchReminders(matching: predicate)
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let filtered = reminders.filter { reminder in
            guard reminder.dueDate.map({ $0 < end }) ?? (includeUndated ?? false) else { return false }
            guard needle.isEmpty || reminder.title.localizedCaseInsensitiveContains(needle) else {
                return false
            }
            return true
        }.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?): left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.title < rhs.title
            }
        }
        guard !filtered.isEmpty else { return "No incomplete reminders due in the next \(dayCount) day(s) matched." }
        let maximum = min(max(limit ?? 50, 1), 100)
        let lines = filtered.prefix(maximum).map { reminder in
            let dueText = reminder.dueDate.map { localDateFormatter.string(from: $0) } ?? "No due date"
            return "\(dueText) | \(reminder.title) [\(reminder.calendarTitle)]\n  Reminder ID: \(reminder.identifier)"
        }
        return lines.joined(separator: "\n") + (filtered.count > maximum ? "\n… showing \(maximum) of \(filtered.count) reminders" : "")
    }

    func createReminder(title: String, dueDate: String?, notes: String?, priority: Int?) throws -> String {
        try requireReadAccess(.reminder)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CalendarStoreError.emptyTitle }
        let targetCalendar = eventStore.defaultCalendarForNewReminders()
        guard let targetCalendar else { throw CalendarStoreError.noWritableCalendar }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = targetCalendar
        if let dueDate { reminder.dueDateComponents = dueComponents(from: try parseDate(dueDate)) }
        if let priority { reminder.priority = try checkedPriority(priority) }
        try eventStore.save(reminder, commit: true)
        return "Created reminder \"\(title)\" in \(targetCalendar.title)\(dueDate.map { " due \($0)" } ?? ""). Reminder ID: \(reminder.calendarItemIdentifier)"
    }

    func updateReminder(
        identifier: String, title: String?, dueDate: String?, clearDueDate: Bool?,
        notes: String?, priority: Int?, completed: Bool?
    ) throws -> String {
        try requireReadAccess(.reminder)
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw CalendarStoreError.itemNotFound("reminder", identifier)
        }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CalendarStoreError.emptyTitle }
            reminder.title = trimmed
        }
        if let dueDate { reminder.dueDateComponents = dueComponents(from: try parseDate(dueDate)) }
        else if clearDueDate == true { reminder.dueDateComponents = nil }
        if let notes { reminder.notes = notes.isEmpty ? nil : notes }
        if let priority { reminder.priority = try checkedPriority(priority) }
        if let completed {
            reminder.isCompleted = completed
            reminder.completionDate = completed ? .now : nil
        }
        try eventStore.save(reminder, commit: true)
        return "Updated reminder \"\(reminder.title ?? "Untitled")\". Reminder ID: \(reminder.calendarItemIdentifier)"
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [CalendarReminderSnapshot] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map { reminder in
                    CalendarReminderSnapshot(
                        identifier: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Untitled",
                        calendarTitle: reminder.calendar.title,
                        dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    private func requireReadAccess(_ entity: EKEntityType) throws {
        let state = Self.accessState(for: entity)
        guard state.canRead else {
            let name = entity == .event ? "Calendar" : "Reminders"
            throw CalendarStoreError.accessRequired(name, state.label)
        }
    }

    private static func accessState(for entity: EKEntityType) -> AccessState {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    private func parseDate(_ value: String, allowDateOnly: Bool = true) throws -> Date {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = .current
        if let date = iso.date(from: input) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: input) { return date }
        if allowDateOnly {
            let dateOnly = DateFormatter()
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.timeZone = .current
            dateOnly.dateFormat = "yyyy-MM-dd"
            dateOnly.isLenient = false
            if let date = dateOnly.date(from: input) { return date }
        }
        throw CalendarStoreError.invalidDate(input)
    }

    private func dueComponents(from date: Date) -> DateComponents {
        var components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = .current
        return components
    }

    private func checkedPriority(_ priority: Int) throws -> Int {
        guard (0...9).contains(priority) else { throw CalendarStoreError.invalidPriority }
        return priority
    }
}

private enum CalendarStoreError: LocalizedError {
    case accessRequired(String, String)
    case calendarNotFound(String)
    case emptyTitle
    case invalidDate(String)
    case invalidDateRange
    case invalidPriority
    case itemNotFound(String, String)
    case noWritableCalendar

    var errorDescription: String? {
        switch self {
        case let .accessRequired(name, state):
            "\(name) access is \(state.lowercased()). Connect it in Settings > Tools."
        case let .calendarNotFound(name): "No calendar named \"\(name)\" was found. Check the calendar name in calendar_events."
        case .emptyTitle: "A non-empty title is required."
        case let .invalidDate(value): "Invalid date \"\(value)\". Use ISO 8601 with a timezone offset, or YYYY-MM-DD for a reminder due date."
        case .invalidDateRange: "The end date must be after the start date, and the date range must be valid."
        case .invalidPriority: "Reminder priority must be from 0 (none) to 9 (lowest)."
        case let .itemNotFound(kind, identifier): "Could not find this \(kind) (\(identifier)). Refresh the list and retry."
        case .noWritableCalendar: "No writable default calendar is available."
        }
    }
}