import Foundation
import Testing

@testable import Konishi

@Suite("Apple Calendar tools")
struct AppleCalendarToolTests {
    @Test("personal-data writes are opt-in and default to Ask")
    func writesDefaultToAsk() throws {
        let writeNames: Set<String> = [
            "calendar_create_event", "calendar_update_event",
            "reminder_create", "reminder_update",
        ]
        let writeSpecs = Tools.calendarSpecs.filter { writeNames.contains($0.name) }
        let context = ToolPermissionContext(mode: .chat, workspace: URL(fileURLWithPath: "/workspace"))

        #expect(writeSpecs.count == writeNames.count)
        #expect(writeSpecs.allSatisfy { !$0.defaultEnabled })
        for spec in writeSpecs {
            let classified = try ToolPermissions.classify(
                toolName: spec.name, arguments: [:], context: context)
            let effects = try #require(classified)
            #expect(effects == [PermissionEffect(.personalDataWrite)])
            #expect(ToolPermissions.evaluate(effects, context: context).verdict == .ask)
        }
        #expect(Tools.modeEnabledDefaults(.chat).isDisjoint(with: writeNames))
    }

    @Test("personal-data reads are opt-in and default to Allow")
    func readsDefaultToAllow() throws {
        let readNames: Set<String> = ["calendar_events", "reminders_list"]
        let readSpecs = Tools.calendarSpecs.filter { readNames.contains($0.name) }
        let context = ToolPermissionContext(mode: .chat, workspace: URL(fileURLWithPath: "/workspace"))

        #expect(readSpecs.count == readNames.count)
        #expect(readSpecs.allSatisfy { !$0.defaultEnabled })
        for spec in readSpecs {
            let classified = try ToolPermissions.classify(
                toolName: spec.name, arguments: [:], context: context)
            let effects = try #require(classified)
            #expect(effects == [PermissionEffect(.personalDataRead)])
            #expect(ToolPermissions.evaluate(effects, context: context).verdict == .allow)
        }
    }
}