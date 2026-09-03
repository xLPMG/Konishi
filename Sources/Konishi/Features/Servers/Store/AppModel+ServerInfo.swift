extension AppModel {
    func refreshServerInfo() {
        let config = settings.requestConfig(modelOverride: nil)
        Task { [weak self] in
            do {
                let list = try await ChatService.fetchModels(config: config)
                self?.models = list
                self?.connectionOK = true
            } catch {
                self?.connectionOK = false
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
}
