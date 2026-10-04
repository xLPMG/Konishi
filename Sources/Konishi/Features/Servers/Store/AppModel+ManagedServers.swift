extension AppModel {
    /// Start a managed server; auto-point the matching endpoint at it by role.
    func startServer(_ server: ManagedServer) {
        Task {
            guard await runtime.ensureRunning(server) else { return }
            switch server.role {
            case .chat: pointChat(at: server)
            case .audio: pointAudio(at: server)
            case .embedding: pointEmbedding(at: server)
            case .none: break
            }
        }
    }

    /// Start every managed server (quick start). Adopts anything already alive instead of
    /// relaunching, so it never spawns a duplicate.
    func startAllServers() {
        Task {
            let servers = runtime.roleServers
            let chatServers = servers.filter { $0.role == .chat }
            let selectedChat = chatServers.first { $0.endpointURL == settings.baseURL }
                ?? chatServers.first { $0.builtInServer == .mlxLMChat }
                ?? chatServers.first
            var serversToStart = servers.filter { $0.role != .chat }
            if let selectedChat { serversToStart.insert(selectedChat, at: 0) }
            for server in serversToStart {
                guard await runtime.ensureRunning(server) else { continue }
                if server.role == .chat {
                    pointChat(at: server)
                } else if server.role == .audio {
                    pointAudio(at: server)
                } else if server.role == .embedding {
                    pointEmbedding(at: server)
                }
            }
        }
    }

    func stopAllServers() {
        runtime.stopAll()
    }

    /// Called at launch: start servers flagged autostart. Reconciles first (so an orphan from a
    /// previous session is adopted, not duplicated), then ensures each is running.
    func autostartServers() {
        Task {
            runtime.rescan()
            let autostartServers = runtime.roleServers.filter { $0.autostart == true }
            let chatServers = autostartServers.filter { $0.role == .chat }
            let selectedChat = chatServers.first { $0.endpointURL == settings.baseURL }
                ?? chatServers.first { $0.builtInServer == .mlxLMChat }
                ?? chatServers.first
            var serversToStart = autostartServers.filter { $0.role != .chat }
            if let selectedChat { serversToStart.insert(selectedChat, at: 0) }
            for server in serversToStart {
                guard await runtime.ensureRunning(server) else { continue }
                if server.role == .chat {
                    pointChat(at: server)
                } else if server.role == .audio {
                    pointAudio(at: server)
                } else if server.role == .embedding {
                    pointEmbedding(at: server)
                }
            }
        }
    }

    private func pointChat(at server: ManagedServer) {
        settings.baseURL = server.endpointURL
        if case .running = runtime.status(server.id), let modelPath = server.modelPath {
            settings.model = modelPath
        }
        refreshServerInfo()
    }

    private func pointAudio(at server: ManagedServer) {
        settings.audioBaseURL = server.endpointURL
        refreshAudioModels()
    }

    private func pointEmbedding(at server: ManagedServer) {
        settings.embeddingBaseURL = server.endpointURL
        if case .running = runtime.status(server.id), let modelPath = server.modelPath {
            settings.embeddingModel = modelPath
        }
    }

    /// Point the chat endpoint at a locally-running managed server.
    func useForChat(_ server: ManagedServer) {
        settings.baseURL = server.endpointURL
        settings.apiToken = ""
        refreshServerInfo()
    }

    /// Point the audio (STT/TTS) endpoint at a locally-running managed server.
    func useForAudio(_ server: ManagedServer) {
        settings.audioBaseURL = server.endpointURL
        refreshAudioModels()
    }

    /// Point the embeddings endpoint at a locally-running managed server.
    func useForEmbeddings(_ server: ManagedServer) {
        settings.embeddingBaseURL = server.endpointURL
    }
}
