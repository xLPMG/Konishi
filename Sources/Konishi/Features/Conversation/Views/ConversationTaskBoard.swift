import SwiftUI

struct ConversationTaskBoard: View {
    @Environment(AppModel.self) private var model
    @State private var newTaskTitle = ""
    @State private var selectedTaskID: UUID?
    @State private var editedTaskTitle = ""
    @State private var editedTaskNotes = ""
    @State private var confirmingClearTasks = false

    private var tasks: [ConversationTask] { model.selectedConversation?.tasks ?? [] }
    private var selectedTask: ConversationTask? {
        tasks.first(where: { $0.id == selectedTaskID })
    }
    private var nextTask: ConversationTask? { tasks.first(where: { $0.status == .pending }) }
    private var canStartTask: Bool {
        !model.isStreaming && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.draftImages.isEmpty && model.draftAttachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            taskList
            addTaskRow
            Divider()
            if let task = selectedTask {
                ConversationTaskEditor(
                    task: task, title: $editedTaskTitle, notes: $editedTaskNotes,
                    canWork: canStartTask,
                    onSave: { saveTaskDraft(task.id) },
                    onDelete: { model.deleteConversationTask(task.id) },
                    onWork: { workOnTask(task.id) })
                    .id(task.id)
            } else {
                ContentUnavailableView("Select a Task", systemImage: "checklist")
                    .frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(KonishiPalette.surface)
        .overlay(alignment: .leading) {
            KonishiPalette.border
                .frame(width: 1)
                .ignoresSafeArea(edges: .vertical)
                .allowsHitTesting(false)
        }
        .confirmationDialog(
            "Remove all tasks?", isPresented: $confirmingClearTasks,
            titleVisibility: .visible
        ) {
            Button("Remove All Tasks", role: .destructive) {
                model.deleteAllConversationTasks()
                selectedTaskID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every task and its notes from this conversation.")
        }
        .onChange(of: model.selectedConversationID) { _, _ in
            selectedTaskID = nil
            editedTaskTitle = ""
            editedTaskNotes = ""
        }
        .onChange(of: selectedTaskID) { oldID, newID in
            if let oldID, oldID != newID { saveTaskDraft(oldID) }
            guard let task = tasks.first(where: { $0.id == newID }) else {
                editedTaskTitle = ""
                editedTaskNotes = ""
                return
            }
            editedTaskTitle = task.title
            editedTaskNotes = task.notes
        }
        .onDisappear {
            if let selectedTaskID { saveTaskDraft(selectedTaskID) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(model.currentAccent)
            Text("Tasks & Notes").font(.headline)
            Spacer()
            Text("\(tasks.filter { $0.status == .done }.count)/\(tasks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !tasks.isEmpty {
                Button(role: .destructive) {
                    confirmingClearTasks = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Remove all tasks")
            }
        }
        .padding(14)
    }

    private var taskList: some View {
        List(selection: $selectedTaskID) {
            ForEach(tasks) { task in
                HStack(spacing: 9) {
                    Button {
                        model.updateConversationTask(
                            task.id, status: task.status == .done ? .pending : .done)
                    } label: {
                        Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.status == .done ? .green : .secondary)
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .lineLimit(2)
                            .strikethrough(task.status == .done)
                        if task.status == .inProgress {
                            Text("In progress").font(.caption2).foregroundStyle(model.currentAccent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedTaskID = task.id }
                .tag(task.id)
                .contextMenu {
                    Button("Delete Task", systemImage: "trash", role: .destructive) {
                        model.deleteConversationTask(task.id)
                        if selectedTaskID == task.id { selectedTaskID = nil }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView("No Tasks Yet", systemImage: "checklist")
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 130)
    }

    private var addTaskRow: some View {
        HStack(spacing: 8) {
            TextField("Add a task", text: $newTaskTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTask)
            Button(action: addTask) {
                Image(systemName: "plus")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || tasks.count >= AppModel.maximumConversationTasks)
            .help("Add task")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            let importable = model.taskTitlesToImport.count
            if importable > 0 {
                Button {
                    model.importTasksFromLatestReply()
                } label: {
                    Label("Import plan (\(importable))", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(tasks.count >= AppModel.maximumConversationTasks)
                .help("Add checklist items from the latest assistant reply")
            }
            if let task = nextTask {
                Button {
                    workOnTask(task.id)
                } label: {
                    Label("Work on next", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartTask)
            }
        }
        .padding(12)
    }

    private func addTask() {
        guard let id = model.addConversationTask(title: newTaskTitle) else { return }
        editedTaskTitle = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editedTaskNotes = ""
        selectedTaskID = id
        newTaskTitle = ""
    }

    private func saveTaskDraft(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }),
            task.title != editedTaskTitle || task.notes != editedTaskNotes
        else { return }
        model.updateConversationTask(id, title: editedTaskTitle, notes: editedTaskNotes)
    }

    private func workOnTask(_ id: UUID) {
        if selectedTaskID == id { saveTaskDraft(id) }
        model.workOnConversationTask(id)
    }
}

private struct ConversationTaskEditor: View {
    let task: ConversationTask
    @Binding var title: String
    @Binding var notes: String
    let canWork: Bool
    let onSave: () -> Void
    let onDelete: () -> Void
    let onWork: () -> Void

    private var hasChanges: Bool { title != task.title || notes != task.notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Task", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("User notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(5)
                .background(KonishiPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Context, constraints, or completion criteria…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 10)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 90, maxHeight: 180)
            HStack {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete task")
                Spacer()
                if task.status != .done {
                    Button(action: onWork) {
                        Label("Work", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canWork)
                }
                Button("Save") {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }
}