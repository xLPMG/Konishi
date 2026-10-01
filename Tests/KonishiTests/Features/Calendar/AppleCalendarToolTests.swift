import Testing

@testable import Konishi

@Suite("Apple Calendar tools")
struct AppleCalendarToolTests {
    @Test("writes are opt-in and always approval-gated")
    func writesRequireApproval() {
        let writeNames: Set<String> = [
            "calendar_create_event", "calendar_update_event",
            "reminder_create", "reminder_update",
        ]
        let writeSpecs = Tools.calendarSpecs.filter { writeNames.contains($0.name) }

        #expect(writeSpecs.count == writeNames.count)
        #expect(writeSpecs.allSatisfy { $0.mutating })
        #expect(writeSpecs.allSatisfy { $0.requiresApproval })
        #expect(writeSpecs.allSatisfy { !$0.defaultEnabled && !$0.defaultAutoApprove })
        #expect(Tools.modeEnabledDefaults(.chat).isDisjoint(with: writeNames))
        #expect(Tools.modeAutoApproveDefaults(.chat).isDisjoint(with: writeNames))
    }

    @Test("calendar reads are opt-in but safe to auto-approve")
    func readsAreOptInAndNonMutating() {
        let readNames: Set<String> = ["calendar_events", "reminders_list"]
        let readSpecs = Tools.calendarSpecs.filter { readNames.contains($0.name) }

        #expect(readSpecs.count == readNames.count)
        #expect(readSpecs.allSatisfy { !$0.mutating && !$0.requiresApproval })
        #expect(readSpecs.allSatisfy { !$0.defaultEnabled && $0.defaultAutoApprove })
    }
}