import Foundation

extension AppModel {
    func setConversationPermissionOverride(
        _ capability: Capability, decision: PermissionDecision?, conversationID: UUID
    ) {
        guard let index = conversationIndex(conversationID) else { return }
        var rules = conversations[index].permissionRules ?? []
        rules.removeAll { $0.capability == capability && $0.scope == .any }
        if let decision {
            rules.append(PermissionRule(capability: capability, decision: decision))
        }
        conversations[index].permissionRules = rules.isEmpty ? nil : rules
        touch(index)
    }

    func allowCapabilityForConversation(_ capability: Capability, conversationID: UUID) {
        setConversationPermissionOverride(capability, decision: .allow, conversationID: conversationID)
    }

    func removePermissionRule(_ id: UUID, inConversation: Bool, mode: AppMode) {
        if inConversation {
            guard let index = selectedConversationID.flatMap(conversationIndex) else { return }
            let oldRules = conversations[index].permissionRules ?? []
            let rules = oldRules.filter { $0.id != id }
            conversations[index].permissionRules = rules.isEmpty ? nil : rules
            touch(index)
        } else {
            var policy = settings.permissionPolicy(for: mode)
            policy.rules.removeAll { $0.id == id }
            settings.setPermissionPolicy(policy, for: mode)
        }
    }

    func canRememberPendingTools() -> Bool {
        guard let batch = pendingApproval else { return false }
        let context = toolPermissionContext(
            conversationID: batch.conversationID, surface: .interactive,
            mode: batch.permissionMode)
        let effects = batch.calls.flatMap { call in
            batch.permissionEvaluations[call.id]?.effects
                .filter { $0.decision == .ask }.map(\.effect) ?? []
        }
        return ToolPermissions.allowRules(
            for: effects, workspace: context.workspace, scopeChoice: .containingFolder) != nil
    }

    func rememberPendingTools(inConversation: Bool, anywhere: Bool) {
        guard let batch = pendingApproval, canRememberPendingTools() else { return }
        let permissionMode = batch.permissionMode ?? mode
        let context = toolPermissionContext(
            conversationID: batch.conversationID, surface: .interactive, mode: permissionMode)
        let effects = batch.calls.flatMap { call in
            batch.permissionEvaluations[call.id]?.effects
                .filter { $0.decision == .ask }.map(\.effect) ?? []
        }
        guard let additions = ToolPermissions.allowRules(
            for: effects, workspace: context.workspace,
            scopeChoice: anywhere ? .anywhere : .containingFolder)
        else { return }

        if inConversation {
            guard let index = conversationIndex(batch.conversationID) else { return }
            var rules = conversations[index].permissionRules ?? []
            for rule in additions {
                rules.removeAll { $0.capability == rule.capability && $0.scope == rule.scope }
                rules.append(rule)
            }
            conversations[index].permissionRules = rules
            touch(index)
        } else {
            var policy = settings.permissionPolicy(for: permissionMode)
            for rule in additions {
                policy.rules.removeAll { $0.capability == rule.capability && $0.scope == rule.scope }
                policy.rules.append(rule)
            }
            settings.setPermissionPolicy(policy, for: permissionMode)
        }

        pendingApproval = nil
        executeAndContinue(batch: batch, approved: true)
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
        let surface: PermissionSurface = workSession?.autopilot == true ? .unattended : .interactive
        let context = toolPermissionContext(conversationID: batch.conversationID, surface: surface)
        let visibleNames = Set(ToolPermissions.visibleTools(context: context).map(\.name))
        var evaluatedBatch = batch
        evaluatedBatch.permissionMode = mode
        evaluatedBatch.permissionEvaluations = Dictionary(uniqueKeysWithValues: batch.calls.map { call in
            let name = call.function.name ?? ""
            let evaluation: ToolPermissionEvaluation
            if Tools.spec(name) != nil, !visibleNames.contains(name) {
                evaluation = ToolPermissionEvaluation(
                    effects: [], verdict: .deny, source: .default,
                    explanation: "Tool `\(name)` is disabled or unavailable in this conversation."
                )
            } else {
                let arguments = (try? JSONDecoder().decode(
                    [String: JSONValue].self, from: Data(call.function.arguments.utf8))) ?? [:]
                evaluation = ToolPermissions.evaluate(
                    toolName: name, arguments: arguments, context: context)
            }
            let effectText = evaluation.effects.isEmpty ? "none" : evaluation.effects.map {
                let location = $0.effect.path.map { " · \($0)" } ?? ""
                return "\($0.effect.capability.rawValue)\(location)=\($0.decision.rawValue)"
            }.joined(separator: ", ")
            traceStore.trace(
                conversationID: batch.conversationID, kind: .tool,
                text: "\(name)(\(call.function.arguments)) | effects: \(effectText) | verdict: \(evaluation.verdict.rawValue) | source: \(evaluation.source.label(for: mode))",
                saveTraces: settings.saveTraces)
            return (call.id, evaluation)
        })

        if let session = workSession,
            let reason = session.pauseBeforeToolCalls(evaluatedBatch.calls.count)
        {
            pauseAgentWork(reason: reason, batch: evaluatedBatch)
            return
        }
        if evaluatedBatch.permissionEvaluations.values.contains(where: { $0.verdict == .ask }) {
            activity = nil
            isStreaming = false
            streamingConversationID = nil
            pendingApproval = evaluatedBatch
        } else {
            executeAndContinue(batch: evaluatedBatch, approved: true)
        }
    }

    func executeAndContinue(batch: PendingToolBatch, approved: Bool) {
        isStreaming = true
        streamingConversationID = batch.conversationID   // protect across the tool loop
        toolExecutionTask?.cancel()
        toolExecutionTask = Task { [weak self] in
            guard let self else { return }
            var forceContinuation = false
            var stopForToolLoop = false
            let autopilot = self.workSession?.autopilot == true
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
                let evaluation = batch.permissionEvaluations[call.id]
                if repeats >= 2 {
                    result = "You have called `\(name)` with identical arguments \(repeats + 1) times in a row without making progress. Stop repeating it: try different arguments, a different tool, or give the user your answer based on what you already have."
                    forceContinuation = true
                    stopForToolLoop = AgentToolLoopPolicy.shouldStopAutopilotBatch(
                        repeats: repeats, autopilot: autopilot)
                } else if let evaluation, evaluation.verdict == .deny {
                    result = self.permissionDenialMessage(evaluation, toolName: name)
                    forceContinuation = true
                } else if let evaluation, evaluation.verdict == .ask, !approved {
                    result = "The user denied permission for `\(name)`. Do not retry this call."
                    forceContinuation = true
                } else if evaluation == nil {
                    result = "Denied: no permission evaluation was stored for `\(name)`. Do not retry this call."
                    forceContinuation = true
                } else if Self.readOnlyTools.contains(name), self.loopSignatures.contains(sig) {
                    result = "[identical `\(name)` call already ran this turn; the result is unchanged — reuse the earlier output instead of calling it again]"
                    forceContinuation = true
                } else {
                    result = await self.executeTool(
                        call, conversationID: batch.conversationID, permissionEvaluation: evaluation)
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
                if let queued = self.queuedTextInterrupt,
                    queued.conversationID == batch.conversationID
                {
                    self.closePendingToolCalls(
                        batch,
                        message: "Not run: the user interrupted the tool batch with a queued message.",
                        calls: Array(batch.calls.dropFirst(callIndex + 1)))
                    self.queuedTextInterrupt = nil
                    self.toolExecutionTask = nil
                    self.stop()
                    self.isStoppingWork = false
                    self.submitUserMessage(
                        text: queued.content, images: queued.images,
                        attachments: queued.attachments, conversationID: queued.conversationID)
                    return
                }
                if autopilot, evaluation?.verdict == .deny {
                    let capability = evaluation?.effects.first?.effect.capability.label ?? name
                    self.autopilotPermissionDenials += 1
                    self.autopilotBlockedCapabilities.append(capability)
                    if AgentToolLoopPolicy.shouldStopForPermissionDenials(
                        count: self.autopilotPermissionDenials, autopilot: true)
                    {
                        self.closePendingToolCalls(
                            batch, message: "Not run: Autopilot stopped after repeated permission denials.",
                            calls: AgentToolLoopPolicy.remainingCalls(after: callIndex, in: batch.calls))
                        self.stopAutopilotForPermissionDenials(capability: capability)
                        return
                    }
                }
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

    func toolPermissionContext(
        conversationID: UUID, surface: PermissionSurface, mode permissionMode: AppMode? = nil
    ) -> ToolPermissionContext {
        let permissionMode = permissionMode ?? mode
        let conversation = conversationIndex(conversationID).map { conversations[$0] }
        let persona = personaStore.persona(for: conversation)
        let shellAllowlist = Set(settings.shellAllowlist(for: permissionMode)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        return ToolPermissionContext(
            mode: permissionMode,
            workspace: Paths.conversationFiles(conversationID),
            toolsEnabled: settings.toolsEnabled(for: permissionMode),
            enabledTools: settings.enabledTools(for: permissionMode),
            vaultAccessEnabled: persona.vaultAccessEnabled,
            shellAllowlist: shellAllowlist,
            surface: surface,
            modePolicy: settings.permissionPolicy(for: permissionMode),
            conversationRules: conversation?.permissionRules ?? [])
    }

    private func permissionDenialMessage(
        _ evaluation: ToolPermissionEvaluation, toolName: String
    ) -> String {
        if let explanation = evaluation.explanation { return explanation }
        let capabilities = evaluation.effects.map { $0.effect.capability.label }
        let affected = capabilities.isEmpty ? "the requested action" : capabilities.joined(separator: ", ")
        return "Denied: `\(toolName)` requires \(affected), which is not allowed. Do not retry this call."
    }

    private func executeTool(
        _ call: ToolCall, conversationID: UUID, permissionEvaluation: ToolPermissionEvaluation?
    ) async -> String {
        let conversation = conversationIndex(conversationID).map { conversations[$0] }
        let persona = personaStore.persona(for: conversation)
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
            guard let args: ToolArguments.ConversationSearch = Self.decodeToolArgs(call),
                !args.query.isEmpty
            else { return "Error: conversation_search requires a query" }
            return await conversationSearchResult(
                query: args.query, limit: args.limit, current: conversationID)
        case "conversation_list":
            let args: ToolArguments.ConversationList? = Self.decodeToolArgs(call)
            return conversationListResult(days: args?.days, limit: args?.limit, current: conversationID)
        case "conversation_read":
            guard let args: ToolArguments.ConversationRead = Self.decodeToolArgs(call)
            else { return "Error: conversation_read requires an id" }
            return conversationReadResult(id: args.id)
        case "file_read":
            guard let args: ToolArguments.FileRead = Self.decodeToolArgs(call) else {
                return "Error: file_read requires a path"
            }
            do {
                let content = try fileStore.read(
                    path: args.path, in: Paths.conversationFiles(conversationID),
                    expectedResolvedPath: permissionEvaluation?.effects.first?.effect.path)
                return Self.readSlice(content, offset: args.offset, limit: args.limit)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "file_write":
                        guard let args: ToolArguments.FileWrite = Self.decodeToolArgs(call) else {
                                return "Error: file_write requires a path and content"
            }
            do {
                let url = try fileStore.write(
                    path: args.path, content: args.content,
                    in: Paths.conversationFiles(conversationID),
                    expectedResolvedPath: permissionEvaluation?.effects.first?.effect.path)
                return "Saved file: \(url.path)"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "web_fetch":
                        guard let args: ToolArguments.URLValue = Self.decodeToolArgs(call),
                  let url = URL(string: args.url) else {
                                return "Error: web_fetch requires a valid URL"
            }
            addTurnSource(title: url.host ?? args.url, url: args.url)
            return await WebResearch.fetch(url)
        case "web_search":
            guard let args: ToolArguments.Query = Self.decodeToolArgs(call), !args.query.isEmpty else {
                return "Error: web_search requires a query"
            }
            let result = await WebResearch.search(args.query)
            for source in result.sources { addTurnSource(title: source.title, url: source.url) }
            return result.text
        case "web_research":
                        guard let args: ToolArguments.Research = Self.decodeToolArgs(call),
                  !args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                return "Error: web_research requires a query"
            }
            let result = await WebResearch.research(args.query, maxSources: args.maxSources ?? 3)
            for source in result.sources { addTurnSource(title: source.title, url: source.url) }
            return result.text
        case "finance_lookup":
            guard let args: ToolArguments.FinanceLookup = Self.decodeToolArgs(call) else {
                return "Error: finance_lookup requires an identifier"
            }
            do {
                let result = try await FinanceData.lookup(
                    identifier: args.identifier, identifierType: args.identifierType)
                addFinanceSources(result)
                return FinanceData.encode(result)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "finance_quote":
            guard let args: ToolArguments.FinanceQuote = Self.decodeToolArgs(call) else {
                return "Error: finance_quote requires an identifier"
            }
            do {
                let result = try await FinanceData.quote(
                    identifier: args.identifier, identifierType: args.identifierType,
                    exchange: args.exchange)
                addFinanceSources(result)
                return FinanceData.encode(result)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "finance_history":
            guard let args: ToolArguments.FinanceHistory = Self.decodeToolArgs(call) else {
                return "Error: finance_history requires an identifier"
            }
            do {
                let result = try await FinanceData.history(identifier: args.identifier, days: args.days ?? 365)
                addFinanceSources(result)
                return FinanceData.encode(result)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "finance_series":
            guard let args: ToolArguments.FinanceSeries = Self.decodeToolArgs(call) else {
                return "Error: finance_series requires a FRED series_id"
            }
            do {
                let result = try await FinanceData.economicSeries(
                    seriesID: args.seriesId, days: args.days ?? 365)
                addFinanceSources(result)
                return FinanceData.encode(result)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "finance_portfolio":
            guard let args: ToolArguments.FinancePortfolio = Self.decodeToolArgs(call) else {
                return "Error: finance_portfolio requires currency and holdings"
            }
            do {
                let input = FinanceData.PortfolioInput(currency: args.currency, holdings: args.holdings)
                return FinanceData.encode(try FinanceData.analyzePortfolio(input))
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "finance_scenario":
            guard let args: ToolArguments.FinanceScenario = Self.decodeToolArgs(call) else {
                return "Error: finance_scenario arguments are invalid"
            }
            do {
                let input = FinanceData.ScenarioInput(
                    currency: args.currency, initialAmount: args.initialAmount,
                    monthlyContribution: args.monthlyContribution, years: args.years,
                    annualReturnPercent: args.annualReturnPercent,
                    annualFeePercent: args.annualFeePercent,
                    inflationPercent: args.inflationPercent)
                return FinanceData.encode(try FinanceData.project(input))
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "calculate":
            guard let args: ToolArguments.Calculation = Self.decodeToolArgs(call) else {
                return "Error: calculate requires an expression"
            }
            do {
                return "\(args.expression) = \(Calculator.format(try Calculator.evaluate(args.expression)))"
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "calendar_events":
            guard let args: ToolArguments.CalendarEvents = Self.decodeToolArgs(call)
            else { return "Error: calendar_events arguments are invalid" }
            do {
                return try calendarStore.listEvents(days: args.days, calendarName: args.calendar)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "calendar_create_event":
            guard let args: ToolArguments.CalendarCreateEvent = Self.decodeToolArgs(call)
            else { return "Error: calendar_create_event arguments are invalid" }
            do {
                return try calendarStore.createEvent(
                    title: args.title, startDate: args.startDate, endDate: args.endDate,
                    location: args.location, notes: args.notes, calendarName: args.calendar)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "calendar_update_event":
            guard let args: ToolArguments.CalendarUpdateEvent = Self.decodeToolArgs(call)
            else { return "Error: calendar_update_event arguments are invalid" }
            do {
                return try calendarStore.updateEvent(
                    identifier: args.eventID, title: args.title, startDate: args.startDate,
                    endDate: args.endDate, location: args.location, notes: args.notes)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "reminders_list":
            let args: ToolArguments.RemindersList? = Self.decodeToolArgs(call)
            do {
                return try await calendarStore.listReminders(
                    days: args?.days, includeUndated: args?.includeUndated,
                    query: args?.query, limit: args?.limit)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "reminder_create":
            guard let args: ToolArguments.ReminderCreate = Self.decodeToolArgs(call)
            else { return "Error: reminder_create arguments are invalid" }
            do {
                return try calendarStore.createReminder(
                    title: args.title, dueDate: args.dueDate, notes: args.notes, priority: args.priority)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "reminder_update":
            guard let args: ToolArguments.ReminderUpdate = Self.decodeToolArgs(call)
            else { return "Error: reminder_update arguments are invalid" }
            do {
                return try calendarStore.updateReminder(
                    identifier: args.reminderID, title: args.title, dueDate: args.dueDate,
                    clearDueDate: args.clearDueDate, notes: args.notes,
                    priority: args.priority, completed: args.completed)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        case "python_exec":
            guard let args: ToolArguments.Python = Self.decodeToolArgs(call),
                  !args.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: missing code"
            }
            let workdir = Paths.conversationFiles(conversationID)
            let (status, out) = await runtime.runPythonCapture(args.code, workdir: workdir)
            let body = out.isEmpty ? "(no output — remember to print() results)" : String(out.prefix(12_000))
            return "exit \(status)\n\(body)"
        case "run_shell":
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
        case "vault_search":
            guard persona.vaultAccessEnabled else {
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
            guard persona.vaultAccessEnabled else {
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
            guard persona.vaultAccessEnabled else {
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
            guard persona.vaultAccessEnabled else {
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

    private func addFinanceSources(_ result: FinanceData.Result) {
        if let matches = result.matches, !matches.isEmpty {
            for match in matches {
                addTurnSource(title: match.name, url: match.url)
            }
        } else if let url = result.sourceURL {
            addTurnSource(title: result.source, url: url)
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