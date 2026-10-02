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

        #expect(AppModel.parsePlanTasks(text).map(\.title) == [
            "Find primary sources", "Compare the findings", "Write a cited summary"
        ])
    }

    @Test("imports indented checklist items as subtasks")
    func parsesSubtasks() {
        let tasks = AppModel.parsePlanTasks("""
            - [ ] Review the sources
              - [ ] Find primary sources
              - Compare publication dates
            - Write a summary
            """)

        #expect(tasks.map(\.title) == ["Review the sources", "Write a summary"])
        #expect(tasks[0].subtasks.map(\.title) == ["Find primary sources", "Compare publication dates"])
        #expect(tasks[1].subtasks.isEmpty)
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

    @Test("work prompt includes subtask titles and completion state")
    func subtasksAreIncludedInTaskPrompt() {
        let prompt = AppModel.conversationTaskPrompt(
            title: "Review sources", notes: "",
            subtasks: [
                ConversationSubtask(title: "Find primary sources"),
                ConversationSubtask(title: "Compare dates", status: .done)
            ])

        #expect(prompt.contains("Subtasks:\n- [ ] Find primary sources\n- [x] Compare dates"))
    }

    @Test("task notes and status survive encoding")
    func taskRoundTrip() throws {
        let task = ConversationTask(
            title: "Compare sources", notes: "Prefer primary sources", status: .inProgress,
            subtasks: [ConversationSubtask(title: "Verify dates", status: .done)])
        let conversation = Conversation(title: "Research", tasks: [task])
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))

        #expect(decoded.tasks == [task])
    }

    @Test("older task records decode without subtasks")
    func legacyTaskDecodes() throws {
        let task = ConversationTask(title: "Legacy task", notes: "Keep this note")
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(task)) as? [String: Any])
        object.removeValue(forKey: "subtasks")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ConversationTask.self, from: data)

        #expect(decoded.title == task.title)
        #expect(decoded.notes == task.notes)
        #expect(decoded.subtasks.isEmpty)
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