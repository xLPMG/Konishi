import Foundation

extension AppModel {
    func toolCallIsAutoApproved(_ call: ToolCall, mode: AppMode) -> Bool {
        guard let name = call.function.name else { return false }
        guard Tools.spec(name)?.requiresApproval != true else { return false }
        if settings.autoApproveTools(for: mode).contains(name) { return true }
        guard name == "run_shell", let args: ToolArguments.Shell = Self.decodeToolArgs(call) else { return false }
        return settings.shellCommandIsAutoApproved(args.command, for: mode)
    }

    func approveTools() {
        guard let batch = pendingApproval else { return }
        pendingApproval = nil
        executeAndContinue(batch: batch, approved: true)
    }

    func denyTools() {
        guard let batch = pendingApproval else { return }
        pendingApproval = nil
        executeAndContinue(batch: batch, approved: false)
    }

    func routeToolBatch(_ batch: PendingToolBatch) {
        if let session = workSession,
            let reason = session.pauseBeforeToolCalls(batch.calls.count)
        {
            pauseAgentWork(reason: reason, batch: batch)
            return
        }
        if workSession?.autopilot == true {
            executeAndContinue(batch: batch, approved: true, autopilot: true)
            return
        }
        let names = batch.calls.compactMap { $0.function.name }
        if !names.isEmpty && batch.calls.allSatisfy({ toolCallIsAutoApproved($0, mode: mode) }) {
            activity = "Calling \(names.joined(separator: ", "))…"
            executeAndContinue(batch: batch, approved: true)
        } else {
            activity = nil
            isStreaming = false
            streamingConversationID = nil
            pendingApproval = batch
        }
    }

    func executeAndContinue(
        batch: PendingToolBatch, approved: Bool, autopilot: Bool = false
    ) {
        isStreaming = true
        streamingConversationID = batch.conversationID   // protect across the tool loop
        toolExecutionTask?.cancel()
        toolExecutionTask = Task { [weak self] in
            guard let self else { return }
            var forceContinuation = false
            var stopForToolLoop = false
            for (callIndex, call) in batch.calls.enumerated() {
                guard !Task.isCancelled else {
                    self.closePendingToolCalls(
                        batch, message: "Not run: the user stopped this work session.",
                        calls: Array(batch.calls.dropFirst(callIndex)))
                    break
                }
                let name = call.function.name ?? "tool"
                self.activity = "Calling \(name)…"
                let sig = name + ":" + call.function.arguments
                let repeats = self.loopSignatures.reversed().prefix(while: { $0 == sig }).count
                let toolStart = Date()
                let result: String
                if !approved {
                    result = "User denied execution of \(name)."
                } else if autopilot && !self.toolCallIsAutoApproved(call, mode: self.mode) {
                    result = "Unavailable in Autopilot: `\(name)` is not auto-approved. Continue with available tools or tell the user what approval is needed."
                    forceContinuation = true
                } else if repeats >= 2 {
                    // Third identical call in a row — break the loop instead of running it again.
                    result = "You have called `\(name)` with identical arguments \(repeats + 1) times in a row without making progress. Stop repeating it: try different arguments, a different tool, or give the user your answer based on what you already have."
                    forceContinuation = true
                    stopForToolLoop = AgentToolLoopPolicy.shouldStopAutopilotBatch(
                        repeats: repeats, autopilot: autopilot)
                } else if Self.readOnlyTools.contains(name), self.loopSignatures.contains(sig) {
                    result = "[identical `\(name)` call already ran this turn; the result is unchanged — reuse the earlier output instead of calling it again]"
                    forceContinuation = true
                } else {
                    result = await self.executeTool(call, conversationID: batch.conversationID)
                }
                self.loopSignatures.append(sig)
                self.recordAgentToolCalls(1)
                traceStore.trace(
                    conversationID: batch.conversationID, kind: .result,
                    text: "\(name) → \(result.prefix(400))",
                    saveTraces: settings.saveTraces)
                if let i = self.ensureHydratedIndex(batch.conversationID) {
                    self.conversations[i].messages.append(
                        ChatMessage(role: .tool, content: result, toolCallId: call.id, toolName: call.function.name)
                    )
                    if name == "python_exec" {
                        self.attachNewPlots(conversationID: batch.conversationID, since: toolStart)
                    }
                }
                self.activity = "Received result."
                if stopForToolLoop {
                    self.closePendingToolCalls(
                        batch,
                        message: "Not run: Autopilot stopped the batch after a repeated tool call.",
                        calls: AgentToolLoopPolicy.remainingCalls(after: callIndex, in: batch.calls))
                    break
                }
            }
            guard !Task.isCancelled else {
                self.toolExecutionTask = nil
                if let conversationID = self.pendingToolStopNotice {
                    self.pendingToolStopNotice = nil
                    self.appendWorkNotice(
                        "The user manually stopped the previous work session. Do not resume autonomously; wait for the next user message.",
                        conversationID: conversationID)
                }
                    self.isStoppingWork = false
                return
            }
            self.toolExecutionTask = nil
            if let i = self.conversationIndex(batch.conversationID) { self.touch(i) }
            if stopForToolLoop {
                self.stopAutopilot(reason: .repeatedOutput)
                return
            }
            if let note = batch.continuationNote {
                self.appendWorkNotice(note, conversationID: batch.conversationID)
            }
            if approved && !forceContinuation && !batch.continueAfter {
                self.finishToolTurn(conversationID: batch.conversationID)   // fire-and-forget: turn done
            } else {
                self.startTurn(conversationID: batch.conversationID)
            }
        }
    }

    /// Ends a tool turn that needs no continuation (writes already confirmed, reply already given).
    private func finishToolTurn(conversationID: UUID) {
        activity = nil
        isStreaming = false
        streamingConversationID = nil
        finishAgentWork()
        compressIfNeeded(conversationID: conversationID)
        updateMemoryIfNeeded(conversationID: conversationID)
        maybeRefineTitle(conversationID: conversationID)
        clearWorkNotices(conversationID: conversationID)
    }

    /// Attach images a python_exec run created in the conversation's files folder, so the vision
    /// model sees them next turn and the user sees them inline. Scans the folder (whatever the
    /// model named its file) rather than parsing stdout.
    private func attachNewPlots(conversationID: UUID, since: Date) {
        let dir = Paths.conversationFiles(conversationID)
        let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        let cutoff = since.addingTimeInterval(-1)   // filesystem mtime granularity slack
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let fresh = files
            .filter { imageExt.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      d >= cutoff else { return nil }
                return (url, d)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        var urls: [String] = []
        var seen = Set<Int>()
        for url in fresh.prefix(4) {
            guard let data = try? Data(contentsOf: url), seen.insert(data.hashValue).inserted else { continue }
            let ext = url.pathExtension.lowercased()
            let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg"
                : (ext == "gif" ? "image/gif" : (ext == "webp" ? "image/webp" : "image/png"))
            urls.append("data:\(mime);base64,\(data.base64EncodedString())")
        }
        guard !urls.isEmpty, let i = conversationIndex(conversationID) else { return }
        conversations[i].messages.append(
            ChatMessage(role: .user, content: "Plot(s) generated:", images: urls)
        )
        touch(i)
    }

    /// A tool is runnable when tool calling is on and the tool is enabled.
    private func toolEnabled(_ name: String) -> Bool {
        guard Tools.spec(name) != nil else { return false }
        // Learn mode needs its tools even when the global master switch is off.
        if mode == .language { return settings.enabledTools(for: .language).contains(name) }
        guard settings.toolsEnabled else { return false }
        return settings.enabledTools(for: mode).contains(name)
    }

    private func executeTool(_ call: ToolCall, conversationID: UUID) async -> String {
        let persona = personaStore.persona(for: selectedConversation)
        switch call.function.name {
        case "memory_list":
            let scopes = [MemoryStore.globalScope, persona.memoryScope]
            let list = scopes.flatMap { s in memoryStore.files(in: s).map { "\(s)/\($0.name)" } }
            return list.isEmpty ? "(no memory notes)" : list.joined(separator: "\n")
        case "memory_read":
            guard let args: ToolArguments.MemoryRead = Self.decodeToolArgs(call) else {
                return "Error: missing or invalid name"
            }
            let scope = args.scope ?? persona.memoryScope
            let file = memoryStore.file(scope: scope, name: args.name)
            let content = memoryStore.read(file)
            return content.isEmpty ? "(empty or not found)" : content
        case "memory_write":
            guard let args: ToolArguments.MemoryWrite = Self.decodeToolArgs(call) else {
                return "Error: missing name/content"
            }
            let scope = args.scope ?? persona.memoryScope
            let content = MemoryCategory.isCategoryFile(args.name) ? MemoryProfile.canonical(args.content) : args.content
            memoryStore.write(scope: scope, name: args.name, content: content)
            return "Saved \(scope)/\(args.name)."
        case "memory_append":
            guard let args: ToolArguments.MemoryWrite = Self.decodeToolArgs(call) else {
                return "Error: missing name/content"
            }
            let scope = args.scope ?? persona.memoryScope
            if MemoryCategory.isCategoryFile(args.name) {
                let existing = memoryStore.read(memoryStore.file(scope: scope, name: args.name))
                let merged = existing.isEmpty ? args.content : existing + "\n" + args.content
                memoryStore.write(scope: scope, name: args.name, content: MemoryProfile.canonical(merged))
            } else {
                memoryStore.append(scope: scope, name: args.name, content: args.content)
            }
            return "Appended to \(scope)/\(args.name)."
        case "conversation_search":
            guard toolEnabled("conversation_search"),
                let args: ToolArguments.ConversationSearch = Self.decodeToolArgs(call),
                !args.query.isEmpty
            else { return "Error: conversation_search is disabled or missing query" }
            return await conversationSearchResult(
                query: args.query, limit: args.limit, current: conversationID)
        case "conversation_list":
            guard toolEnabled("conversation_list") else { return "Error: tool disabled" }
            let args: ToolArguments.ConversationList? = Self.decodeToolArgs(call)
            return conversationListResult(days: args?.days, limit: args?.limit, current: conversationID)
        case "conversation_read":
            guard toolEnabled("conversation_read"),
                let args: ToolArguments.ConversationRead = Self.decodeToolArgs(call)
            else { return "Error: conversation_read is disabled or missing id" }
            return conversationReadResult(id: args.id)
        case "file_read":
            guard toolEnabled("file_read"), let args: ToolArguments.FileRead = Self.decodeToolArgs(call) else {
                return "Error: file_read is disabled or missing path"
            }
            let resolved = (args.path as NSString).expandingTildeInPath
            let url: URL
            if (resolved as NSString).isAbsolutePath {
                url = URL(fileURLWithPath: resolved)
            } else {
                do {
                    url = try fileStore.resolveWorkspacePath(
                        resolved, in: Paths.conversationFiles(conversationID))
                } catch {
                    return "Error: \(error.localizedDescription)"
                }
            }
            guard let s = try? String(contentsOf: url, encoding: .utf8) else {
                return "Error: could not read \(args.path)"
            }
            return Self.readSlice(s, offset: args.offset, limit: args.limit)
        case "file_write":
            guard toolEnabled("file_write"),
                  let args: ToolArguments.FileWrite = Self.decodeToolArgs(call) else {
                return "Error: file_write is disabled or arguments are invalid"
            }
            do {
                let url = try fileStore.write(
                    path: args.path, content: args.content,
                    in: Paths.conversationFiles(conversationID))
                return "Saved workspace file: \(url.path)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "web_fetch":
            guard toolEnabled("web_fetch"), let args: ToolArguments.URLValue = Self.decodeToolArgs(call),
                  let url = URL(string: args.url) else {
                return "Error: web_fetch is disabled or bad URL"
            }
            addTurnSource(title: url.host ?? args.url, url: args.url)
            return await WebResearch.fetch(url)
        case "web_search":
            guard toolEnabled("web_search"), let args: ToolArguments.Query = Self.decodeToolArgs(call), !args.query.isEmpty else {
                return "Error: web_search is disabled or missing query"
            }
            let result = await WebResearch.search(args.query)
            for source in result.sources { addTurnSource(title: source.title, url: source.url) }
            return result.text
        case "web_research":
            guard toolEnabled("web_research"), let args: ToolArguments.Research = Self.decodeToolArgs(call),
                  !args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: web_research is disabled or missing query"
            }
            let result = await WebResearch.research(args.query, maxSources: args.maxSources ?? 3)
            for source in result.sources { addTurnSource(title: source.title, url: source.url) }
            return result.text
        case "calculate":
            guard toolEnabled("calculate"), let args: ToolArguments.Calculation = Self.decodeToolArgs(call) else {
                return "Error: calculate is disabled or missing expression"
            }
            do {
                return "\(args.expression) = \(Calculator.format(try Calculator.evaluate(args.expression)))"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "calendar_events":
            guard toolEnabled("calendar_events"),
                let args: ToolArguments.CalendarEvents = Self.decodeToolArgs(call)
            else { return "Error: calendar_events is disabled or arguments are invalid" }
            do {
                return try calendarStore.listEvents(days: args.days, calendarName: args.calendar)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "calendar_create_event":
            guard toolEnabled("calendar_create_event"),
                let args: ToolArguments.CalendarCreateEvent = Self.decodeToolArgs(call)
            else { return "Error: calendar_create_event is disabled or arguments are invalid" }
            do {
                return try calendarStore.createEvent(
                    title: args.title, startDate: args.startDate, endDate: args.endDate,
                    location: args.location, notes: args.notes, calendarName: args.calendar)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "calendar_update_event":
            guard toolEnabled("calendar_update_event"),
                let args: ToolArguments.CalendarUpdateEvent = Self.decodeToolArgs(call)
            else { return "Error: calendar_update_event is disabled or arguments are invalid" }
            do {
                return try calendarStore.updateEvent(
                    identifier: args.eventID, title: args.title, startDate: args.startDate,
                    endDate: args.endDate, location: args.location, notes: args.notes)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "reminders_list":
            guard toolEnabled("reminders_list") else { return "Error: reminders_list is disabled" }
            let args: ToolArguments.RemindersList? = Self.decodeToolArgs(call)
            do {
                return try await calendarStore.listReminders(
                    days: args?.days, includeUndated: args?.includeUndated,
                    query: args?.query, limit: args?.limit)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "reminder_create":
            guard toolEnabled("reminder_create"),
                let args: ToolArguments.ReminderCreate = Self.decodeToolArgs(call)
            else { return "Error: reminder_create is disabled or arguments are invalid" }
            do {
                return try calendarStore.createReminder(
                    title: args.title, dueDate: args.dueDate, notes: args.notes, priority: args.priority)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "reminder_update":
            guard toolEnabled("reminder_update"),
                let args: ToolArguments.ReminderUpdate = Self.decodeToolArgs(call)
            else { return "Error: reminder_update is disabled or arguments are invalid" }
            do {
                return try calendarStore.updateReminder(
                    identifier: args.reminderID, title: args.title, dueDate: args.dueDate,
                    clearDueDate: args.clearDueDate, notes: args.notes,
                    priority: args.priority, completed: args.completed)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "python_exec":
            guard toolEnabled("python_exec") else {
                return "Error: python_exec is disabled (enable it in Settings › Tools)"
            }
            guard let args: ToolArguments.Python = Self.decodeToolArgs(call),
                  !args.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: missing code"
            }
            let workdir = Paths.conversationFiles(conversationID)
            let (status, out) = await runtime.runPythonCapture(args.code, workdir: workdir)
            let body = out.isEmpty ? "(no output — remember to print() results)" : String(out.prefix(12_000))
            return "exit \(status)\n\(body)"
        case "run_shell":
            guard toolEnabled("run_shell") else {
                return "Error: run_shell is disabled (enable it in Settings › Tools)"
            }
            guard let args: ToolArguments.Shell = Self.decodeToolArgs(call),
                  !args.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: missing command"
            }
            let workspace = Paths.conversationFiles(conversationID)
            let requestedDirectory = args.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
            let workingDirectory: String
            if let requestedDirectory, !requestedDirectory.isEmpty {
                workingDirectory = requestedDirectory
            } else {
                workingDirectory = workspace.path
            }
            let (status, output) = await runtime.runShellCapture(
                args.command,
                workingDirectory: workingDirectory,
                timeoutSeconds: args.timeoutSeconds ?? 120
            )
            return "exit \(status)\n\(output.isEmpty ? "(no output)" : output)"
        case "add_vocab", "add_grammar":
            guard toolEnabled(call.function.name ?? "") else { return "Error: tool disabled" }
            guard let profile = activeLanguageProfile else { return "Error: no active language profile" }
            let isGrammar = call.function.name == "add_grammar"
            let kind: LearnKind = isGrammar ? .grammar : .vocab
            let vocab: ToolArguments.AddVocabulary? = isGrammar ? nil : Self.decodeToolArgs(call)
            let grammar: ToolArguments.AddGrammar? = isGrammar ? Self.decodeToolArgs(call) : nil
            guard vocab != nil || grammar != nil else { return "Error: missing or invalid card fields" }
            let term = grammar?.point ?? vocab?.term ?? ""
            let translation = grammar?.explanation ?? vocab?.translation ?? ""
            guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return "Error: missing \(isGrammar ? "point" : "term")" }
            let example = grammar?.example ?? vocab?.example
            let notes = grammar?.notes ?? vocab?.notes
            let tags = grammar?.tags ?? vocab?.tags
            // Dedup: update an existing card of the same kind/term, keeping its schedule + counts.
            if var existing = languageStore.findByTerm(profileID: profile.id, kind: kind, term: term) {
                if !translation.isEmpty { existing.translation = translation }
                if let r = vocab?.reading, !r.isEmpty { existing.reading = r }
                if let pos = vocab?.partOfSpeech, !pos.isEmpty { existing.partOfSpeech = pos }
                if let reg = vocab?.register, !reg.isEmpty { existing.register = reg }
                if let notes, !notes.isEmpty { existing.notes = notes }
                if let ex = example, !ex.isEmpty, !existing.examples.contains(ex) { existing.examples.append(ex) }
                if let tags { existing.tags = Array(Set(existing.tags + tags)) }
                addDeckCard(existing)
                return "Already in deck (updated): \(term)"
            }
            let item = LearnItem(
                profileID: profile.id,
                kind: kind,
                term: term,
                reading: vocab?.reading ?? "",
                translation: translation,
                partOfSpeech: vocab?.partOfSpeech ?? "",
                register: vocab?.register ?? "",
                notes: notes ?? "",
                examples: example.map { [$0] } ?? [],
                tags: tags ?? [],
                sourceConversationID: conversationID
            )
            addDeckCard(item)
            return "Added \(item.kind.rawValue): \(term)\(translation.isEmpty ? "" : " — \(translation)")"
        case "search_deck":
            guard toolEnabled("search_deck") else { return "Error: tool disabled" }
            guard let profile = activeLanguageProfile else { return "Error: no active language profile" }
            guard let args: ToolArguments.Query = Self.decodeToolArgs(call) else { return "Error: missing query" }
            let results = languageStore.search(profileID: profile.id, query: args.query)
            if results.isEmpty { return "No matching cards." }
            return results.map { "\($0.id.uuidString) | \($0.term) — \($0.translation) [box \($0.box)]" }.joined(separator: "\n")
        case "get_due_items":
            guard toolEnabled("get_due_items") else { return "Error: tool disabled" }
            guard let profile = activeLanguageProfile else { return "Error: no active language profile" }
            let args: ToolArguments.DueItems? = Self.decodeToolArgs(call)
            let due = languageStore.dueItems(profileID: profile.id, limit: args?.limit ?? 10)
            if due.isEmpty { return "Nothing is due for review." }
            return due.map { "\($0.id.uuidString) | \($0.kind.rawValue): \($0.term) — \($0.translation)" }.joined(separator: "\n")
        case "record_review":
            guard toolEnabled("record_review") else { return "Error: tool disabled" }
            guard let args: ToolArguments.Review = Self.decodeToolArgs(call) else { return "Error: missing/invalid id or correct" }
            return recordDeckReview(itemID: args.id, correct: args.correct)
        case "ask_multiple_choice":
            guard toolEnabled("ask_multiple_choice") else { return "Error: tool disabled" }
            guard let args: ToolArguments.MultipleChoice = Self.decodeToolArgs(call) else { return "Error: invalid questions" }
            let questions = Self.parseMCQuestions(args.questions)
            guard !questions.isEmpty else { return "Error: no valid questions provided" }
            return await withCheckedContinuation { cont in
                self.interactionContinuation = cont
                self.activity = "Waiting for your answer…"
                self.pendingInteraction = PendingInteraction(conversationID: conversationID, questions: questions)
            }
        case "vault_search":
            guard toolEnabled("vault_search"), persona.vaultAccessEnabled else {
                return "Error: research vault access is off for this persona"
            }
            guard VaultStore.vaultURL(settings.vaultPath) != nil else {
                return "Error: no research vault is configured (set it in Settings › Vault)"
            }
            guard let args: ToolArguments.VaultSearch = Self.decodeToolArgs(call),
                  !args.query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "Error: missing query"
            }
            let result = await vaultStore.context(
                vaultPath: settings.vaultPath, query: args.query, cache: embeddingCache,
                topK: min(max(1, args.maxResults ?? 6), 20),
                requestConfig: settings.requestConfig(modelOverride: nil))
            traceRetrievalFallback(result, source: "Vault search", conversationID: conversationID)
            return result.text.isEmpty ? "No matching notes." : result.text
        case "vault_read":
            guard toolEnabled("vault_read"), persona.vaultAccessEnabled else {
                return "Error: research vault access is off for this persona"
            }
            guard VaultStore.vaultURL(settings.vaultPath) != nil else {
                return "Error: no research vault is configured (set it in Settings › Vault)"
            }
            guard let args: ToolArguments.VaultRead = Self.decodeToolArgs(call) else {
                return "Error: missing note"
            }
            guard let text = vaultStore.read(vaultPath: settings.vaultPath, note: args.note) else {
                return "Error: could not find note \(args.note)"
            }
            return text.count > 16_000 ? String(text.prefix(16_000)) + "\n… (truncated)" : text
        case "vault_list":
            guard toolEnabled("vault_list"), persona.vaultAccessEnabled else {
                return "Error: research vault access is off for this persona"
            }
            guard VaultStore.vaultURL(settings.vaultPath) != nil else {
                return "Error: no research vault is configured (set it in Settings › Vault)"
            }
            let args: ToolArguments.VaultList? = Self.decodeToolArgs(call)
            let notes = vaultStore.list(vaultPath: settings.vaultPath, folder: args?.folder)
            if notes.isEmpty { return "(no notes found)" }
            let capped = notes.prefix(300)
            return capped.joined(separator: "\n") + (notes.count > 300 ? "\n… \(notes.count - 300) more" : "")
        case "vault_write", "vault_append":
            let isAppend = call.function.name == "vault_append"
            guard toolEnabled(call.function.name ?? ""), persona.vaultAccessEnabled else {
                return "Error: research vault access is off for this persona"
            }
            guard VaultStore.vaultURL(settings.vaultPath) != nil else {
                return "Error: no research vault is configured (set it in Settings › Vault)"
            }
            guard let args: ToolArguments.VaultWrite = Self.decodeToolArgs(call),
                  !args.note.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "Error: missing note path"
            }
            guard let written = vaultStore.write(
                vaultPath: settings.vaultPath, note: args.note, content: args.content, append: isAppend)
            else {
                return "Error: could not write \(args.note) (the path must stay inside the vault)"
            }
            return isAppend ? "Appended to \(written)." : "Saved \(written)."
        default:
            return "Unknown tool."
        }
    }

    private static func decodeToolArgs<T: Decodable>(_ call: ToolCall) -> T? {
        guard let data = call.function.arguments.data(using: .utf8) else { return nil }
        return try? Wire.decoder.decode(T.self, from: data)
    }

    static func stubToolResult(_ msg: ChatMessage) -> String {
        let head = msg.content.prefix(100).replacingOccurrences(of: "\n", with: " ")
        return "[earlier \(msg.toolName ?? "tool") result trimmed to save context — \(head)…]"
    }

    /// Returns a line range of a file with a header, so large files don't flood the context.
    private static func readSlice(_ content: String, offset: Int?, limit: Int?) -> String {
        let lines = content.components(separatedBy: "\n")
        let total = lines.count
        let start = max(0, (offset ?? 1) - 1)
        guard start < total else { return "(file has \(total) lines; offset \(offset ?? 1) is past the end)" }
        let count = min(max(1, limit ?? 400), total - start)
        let end = start + count
        var body = lines[start..<end].joined(separator: "\n")
        var truncated = false
        if body.count > 8_000 { body = String(body.prefix(8_000)); truncated = true }
        var out = "// \(total) lines total, showing \(start + 1)–\(end)\n" + body
        if truncated { out += "\n… (truncated at 8000 chars — narrow the range with offset/limit)" }
        else if end < total { out += "\n… \(total - end) more lines (continue with offset=\(end + 1))" }
        return out
    }

    private func addTurnSource(title: String, url: String) {
        guard !url.isEmpty, !turnSources.contains(where: { $0.url == url }) else { return }
        turnSources.append(Source(title: title.isEmpty ? url : title, url: url))
    }
}