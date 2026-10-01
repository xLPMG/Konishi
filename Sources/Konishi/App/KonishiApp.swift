import SwiftUI
import AppKit

@main
struct KonishiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .tint(model.currentAccent)
                .frame(minWidth: 820, minHeight: 560)
                .task { model.refreshServerInfo(); model.refreshAudioModels(); model.autostartServers(); model.scheduleSleepPass(after: .seconds(45)) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button(model.voice.isListening ? "Stop Dictation" : "Dictate") { model.toggleDictation() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            SettingsCommand()
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(model)
                .tint(model.currentAccent)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.suppressed)

        Window("Trace", id: "trace") {
            TraceView()
                .environment(model)
                .tint(model.currentAccent)
                .frame(minWidth: 560, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Memory", id: "memory") {
            MemoryView()
                .environment(model)
                .tint(model.currentAccent)
                .frame(minWidth: 520, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 520)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra("Konishi", systemImage: "sparkles") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Restores the standard ⌘, "Settings…" menu item, opening the resizable Settings window.
private struct SettingsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

private struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var quick = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Konishi", systemImage: "sparkles").font(.headline)
                Spacer()
                Circle().fill(statusColor).frame(width: 9, height: 9)
            }
            Text(model.settings.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            HStack {
                TextField("Quick chat…", text: $quick)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startQuick)
                Button(action: startQuick) { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.plain).disabled(quick.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()
            Button("New Chat") { model.newConversation(); openWindow(id: "main") }
            Button("Open Konishi") { openWindow(id: "main") }
            Button("Start Servers") { model.startAllServers() }
            Button("Stop Servers") { model.stopAllServers() }
            Button("Refresh Server") { model.refreshServerInfo() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statusColor: Color {
        switch model.connectionOK {
        case .some(true): .green
        case .some(false): .red
        case .none: .yellow
        }
    }

    private func startQuick() {
        let text = quick.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.newConversation()
        model.draft = text
        model.send()
        quick = ""
        openWindow(id: "main")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
