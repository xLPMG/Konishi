import SwiftUI

struct ModelSelector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Menu {
            if model.models.isEmpty {
                Text("No models found")
            } else if model.hasLoadState {
                Section("Loaded") {
                    ForEach(model.loadedModels) { info in modelButton(info, settings: settings) }
                }
                Section("Not loaded") {
                    ForEach(model.unloadedModels) { info in modelButton(info, settings: settings) }
                }
            } else {
                ForEach(model.models) { info in modelButton(info, settings: settings) }
            }
            Divider()
            Button("Refresh") { model.refreshServerInfo() }
        } label: {
            Label(shortModel, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.currentModelID.isEmpty ? "No model selected" : "Model: \(model.currentModelID)")
    }

    private func modelButton(_ info: ModelInfo, settings: AppSettings) -> some View {
        Button {
            settings.model = info.id
        } label: {
            if info.isLoaded == true {
                Label(info.id, systemImage: "circle.fill")
            } else if info.isLoaded == false {
                Label(info.id, systemImage: "circle")
            } else {
                Text(info.id)
            }
        }
    }

    private var shortModel: String {
        let modelID = model.currentModelID
        guard !modelID.isEmpty else { return "No model" }
        return modelID.count > 20 ? "…" + modelID.suffix(18) : modelID
    }
}