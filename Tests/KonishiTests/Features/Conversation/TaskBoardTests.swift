import Foundation
import Testing

@testable import Konishi

@Suite("Conversation task board")
@MainActor
struct TaskBoardTests {
    @Test("imports bullet and numbered checklist items, not prose")
    func parsesChecklistItems() {
        let text = """
            Here is the plan:
            - [ ] Find primary sources
            - Compare the findings
            3. Write a cited summary
            This sentence is not a task.
            """

        #expect(AppModel.parsePlanTasks(text) == [
            "Find primary sources", "Compare the findings", "Write a cited summary"
        ])
    }

    @Test("omits the notes section when notes are empty")
    func emptyNotesAreOmittedFromTaskPrompt() {
        let prompt = AppModel.conversationTaskPrompt(title: "Write a summary", notes: " \n ")

        #expect(prompt.contains("Task: Write a summary"))
        #expect(!prompt.contains("User notes:"))
        #expect(!prompt.localizedCaseInsensitiveContains("notes"))
        #expect(!prompt.contains("(none)"))
    }

    @Test("includes supplied notes in the task prompt")
    func suppliedNotesAreIncludedInTaskPrompt() {
        let prompt = AppModel.conversationTaskPrompt(title: "Write a summary", notes: "Use primary sources")

        #expect(prompt.contains("User notes:\nUse primary sources"))
    }

    @Test("task notes and status survive encoding")
    func taskRoundTrip() throws {
        let task = ConversationTask(
            title: "Compare sources", notes: "Prefer primary sources", status: .inProgress)
        let conversation = Conversation(title: "Research", tasks: [task])
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))

        #expect(decoded.tasks == [task])
    }

    @Test("older conversations decode without a task field")
    func legacyConversationDecodes() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Conversation(title: "Legacy"))) as? [String: Any])
        object.removeValue(forKey: "tasks")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(decoded.tasks == nil)
    }
}