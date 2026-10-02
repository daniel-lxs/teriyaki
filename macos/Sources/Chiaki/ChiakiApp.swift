import SwiftUI

@main
struct ChiakiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ConsoleStore(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        Window("Chiaki", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 460, minHeight: 300)
        }
        .defaultSize(width: 540, height: 380)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Pair Console…") { store.isPairing = true }
                    .keyboardShortcut("n")
            }
            ConsoleCommands(store: store)
        }

        Settings {
            SettingsView()
        }
    }
}

struct ConsoleCommands: Commands {
    @ObservedObject var store: ConsoleStore
    @FocusedValue(\.selectedConsole) private var selected

    var body: some Commands {
        CommandMenu("Console") {
            Button("Connect") {
                if let selected { store.connect(selected) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(selected == nil || selected?.status == .offline || store.activity != .idle)

            Button("Wake") {
                if let selected { store.wake(selected) }
            }
            .disabled(selected?.status != .standby)

            Divider()

            Button("Press PS Button") { store.pressPS() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.activity.consoleID == nil)

            Button("Stop Streaming") { store.stop() }
                .keyboardShortcut(".")
                .disabled(store.activity == .idle)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshot.runIfRequested()
    }
}
