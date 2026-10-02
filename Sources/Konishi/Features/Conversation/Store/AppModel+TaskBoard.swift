import Foundation

extension AppModel {
    static let maximumConversationTasks = 20
    static let maximumConversationSubtasks = 20

    var taskTitlesFromLatestReply: [ConversationTask] {
        guard let content = selectedConversation?.messages.last(where: {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content else { return [] }
        return Self.parsePlanTasks(content)
    }

    var taskTitlesToImport: [ConversationTask] {
        let existing = Set((selectedConversation?.tasks ?? []).map { $0.title.lowercased() })
        let remaining = max(0, Self.maximumConversationTasks - (selectedConversation?.tasks?.count ?? 0))
        return Array(taskTitlesFromLatestReply.filter { !existing.contains($0.title.lowercased()) }.prefix(remaining))
    }

    @discardableResult
    func addConversationTask(title: String) -> UUID? {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !title.isEmpty, let id = selectedConversationID,
            let index = ensureHydratedIndex(id)
        else { return nil }
        var tasks = conversations[index].tasks ?? []
        guard tasks.count < Self.maximumConversationTasks else { return nil }
        let task = ConversationTask(title: title)
        tasks.append(task)
        conversations[index].tasks = tasks
        touch(index)
        return task.id
    }

    func updateConversationTask(
        _ taskID: UUID,
        title: String? = nil,
        notes: String? = nil,
        status: ConversationTask.Status? = nil
    ) {
        guard let id = selectedConversationID, let index = ensureHydratedIndex(id),
            var tasks = conversations[index].tasks,
            let taskIndex = tasks.firstIndex(where: { $0.id == taskID })
        else { return }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { tasks[taskIndex].title = String(trimmed.prefix(240)) }
        }
        if let notes { tasks[taskIndex].notes = notes }
        if let status { tasks[taskIndex].status = status }
        conversations[index].tasks = tasks
        touch(index)
    }

    @discardableResult
    func addConversationSubtask(to taskID: UUID, title: String) -> UUID? {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !title.isEmpty, let id = selectedConversationID,
            let index = ensureHydratedIndex(id), var tasks = conversations[index].tasks,
            let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
            tasks[taskIndex].subtasks.count < Self.maximumConversationSubtasks
        else { return nil }
        let subtask = ConversationSubtask(title: title)
        tasks[taskIndex].subtasks.append(subtask)
        conversations[index].tasks = tasks
        touch(index)
        return subtask.id
    }

    func updateConversationSubtask(
        _ subtaskID: UUID,
        in taskID: UUID,
        title: String? = nil,
        status: ConversationTask.Status? = nil
    ) {
        guard let id = selectedConversationID, let index = ensureHydratedIndex(id),
            var tasks = conversations[index].tasks,
            let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
            let subtaskIndex = tasks[taskIndex].subtasks.firstIndex(where: { $0.id == subtaskID })
        else { return }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                tasks[taskIndex].subtasks[subtaskIndex].title = String(trimmed.prefix(240))
            }
        }
        if let status { tasks[taskIndex].subtasks[subtaskIndex].status = status }
        conversations[index].tasks = tasks
        touch(index)
    }

    func deleteConversationSubtask(_ subtaskID: UUID, from taskID: UUID) {
        guard let id = selectedConversationID, let index = ensureHydratedIndex(id),
            var tasks = conversations[index].tasks,
            let taskIndex = tasks.firstIndex(where: { $0.id == taskID })
        else { return }
        tasks[taskIndex].subtasks.removeAll { $0.id == subtaskID }
        conversations[index].tasks = tasks
        touch(index)
    }

    func deleteConversationTask(_ taskID: UUID) {
        guard let id = selectedConversationID, let index = ensureHydratedIndex(id) else { return }
        conversations[index].tasks?.removeAll { $0.id == taskID }
        touch(index)
    }

    func deleteAllConversationTasks() {
        guard let id = selectedConversationID, let index = ensureHydratedIndex(id),
            !(conversations[index].tasks ?? []).isEmpty
        else { return }
        conversations[index].tasks = nil
        touch(index)
    }

    @discardableResult
    func importTasksFromLatestReply() -> Int {
        let additions = taskTitlesToImport
        guard !additions.isEmpty, let id = selectedConversationID,
            let index = ensureHydratedIndex(id)
        else { return 0 }
        var tasks = conversations[index].tasks ?? []
        tasks.append(contentsOf: additions)
        conversations[index].tasks = tasks
        touch(index)
        return additions.count
    }

    func workOnConversationTask(_ taskID: UUID) {
        guard !isStreaming, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            draftImages.isEmpty, draftAttachments.isEmpty,
            let id = selectedConversationID, let index = ensureHydratedIndex(id),
            let task = conversations[index].tasks?.first(where: { $0.id == taskID }),
            task.status != .done
        else { return }

        updateConversationTask(taskID, status: .inProgress)
        draft = Self.conversationTaskPrompt(
            title: task.title, notes: task.notes, subtasks: task.subtasks)
        send()
    }

    static func conversationTaskPrompt(
        title: String, notes: String, subtasks: [ConversationSubtask] = []
    ) -> String {
        var prompt = """
            Work on this conversation task as the next step. Focus only on this task. Use available tools where they materially help. Do not mark the task complete; report what you completed and anything blocked.

            Task: \(title)
            """
        if !subtasks.isEmpty {
            let checklist = subtasks.map { subtask in
                "- [\(subtask.status == .done ? "x" : " ")] \(subtask.title)"
            }.joined(separator: "\n")
            prompt += "\n\nSubtasks:\n\(checklist)\nWork through these items as the task breakdown and report their progress."
        }
        let notes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        if !notes.isEmpty { prompt += "\n\nUser notes:\n\(notes)" }
        return prompt
    }

    static func parsePlanTasks(_ text: String) -> [ConversationTask] {
        var tasks: [ConversationTask] = []
        var taskIndicesByTitle: [String: Int] = [:]
        var rootIndent: Int?
        var currentRootIndex: Int?
        for line in text.components(separatedBy: .newlines) {
            guard let item = parsePlanItem(line) else { continue }
            if let rootIndent, item.indent > rootIndent, let currentRootIndex {
                if tasks[currentRootIndex].subtasks.count < Self.maximumConversationSubtasks {
                    tasks[currentRootIndex].subtasks.append(ConversationSubtask(title: item.title))
                }
                continue
            }
            let key = item.title.lowercased()
            rootIndent = item.indent
            if let existingIndex = taskIndicesByTitle[key] {
                currentRootIndex = existingIndex
                continue
            }
            taskIndicesByTitle[key] = tasks.count
            tasks.append(ConversationTask(title: item.title))
            currentRootIndex = tasks.count - 1
            if tasks.count == Self.maximumConversationTasks { break }
        }
        return tasks
    }

    private static func parsePlanItem(_ line: String) -> (indent: Int, title: String)? {
        let whitespace = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = whitespace.reduce(into: 0) { count, character in
            count += character == "\t" ? 4 : 1
        }
        var candidate = String(line.dropFirst(whitespace.count))
        guard !candidate.isEmpty else { return nil }

        if let first = candidate.first, "-*+".contains(first), candidate.count > 1,
            candidate[candidate.index(after: candidate.startIndex)].isWhitespace
        {
            candidate = String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if let separator = candidate.firstIndex(where: { $0 == "." || $0 == ")" }),
            candidate[..<separator].allSatisfy(\.isNumber),
            candidate.index(after: separator) < candidate.endIndex,
            candidate[candidate.index(after: separator)].isWhitespace
        {
            candidate = String(candidate[candidate.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        if candidate.hasPrefix("[ ] ") || candidate.hasPrefix("[x] ") || candidate.hasPrefix("[X] ") {
            candidate = String(candidate.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        guard !candidate.isEmpty else { return nil }
        return (indent, candidate)
    }
}