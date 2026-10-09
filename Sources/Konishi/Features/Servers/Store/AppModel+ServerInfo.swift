extension AppModel {
    func refreshServerInfo() {
        serverInfoRequestGeneration += 1
        let requestGeneration = serverInfoRequestGeneration
        connectionOK = nil
        models = []
        let config = settings.requestConfig(modelOverride: nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await ChatService.fetchModels(config: config)
                guard self.serverInfoRequestGeneration == requestGeneration else { return }
                self.models = list
                self.settings.reconcileModelSelection(availableModelIDs: list.map(\.id))
                self.connectionOK = true
            } catch {
                guard self.serverInfoRequestGeneration == requestGeneration else { return }
                self.models = []
                self.settings.reconcileModelSelection(availableModelIDs: [])
                self.connectionOK = false
            }
        }
    }

    func refreshAudioModels() {
        let config = settings.requestConfig(modelOverride: nil)
        Task { [weak self] in
            if let list = try? await ChatService.fetchAudioModels(config: config) {
                self?.audioModels = list
            }
        }
        refreshVoices()
    }

    /// Ask the audio server which voices the current TTS model ships.
    func refreshVoices() {
        let config = settings.requestConfig(modelOverride: nil)
        let model = settings.ttsModel
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { [weak self] in
            if let v = try? await ChatService.fetchVoices(config: config, model: model), !v.isEmpty
            {
                self?.audioVoices = v
            }
        }
    }

    func scanLocalModels() {
        Task { [weak self] in
            let found = await Task.detached { LocalModels.discover() }.value
            self?.discoveredModels = found
        }
    }

    func scanLocalEndpoints() {
        Task { [weak self] in
            let found = await LocalEndpointDiscovery.scan()
            self?.discoveredEndpoints = found
        }
    }

    func useDetectedEndpoint(_ endpoint: DetectedEndpoint, for role: ManagedServer.Role) {
        switch role {
        case .chat:
            settings.baseURL = endpoint.baseURL
            if let id = endpoint.modelIDs.first { settings.model = id }
            refreshServerInfo()
        case .embedding:
            settings.embeddingBaseURL = endpoint.baseURL
            if let id = endpoint.modelIDs.first { settings.embeddingModel = id }
        case .audio:
            settings.audioBaseURL = endpoint.baseURL
            refreshAudioModels()
        case .none:
            break
        }
    }
}
