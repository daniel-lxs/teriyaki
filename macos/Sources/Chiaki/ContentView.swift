import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ConsoleStore
    @State private var selection: Console.ID?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if store.consoles.isEmpty {
                ContentUnavailableView {
                    Label("No Consoles", systemImage: "gamecontroller")
                } description: {
                    Text("Pair a PlayStation on your network to play it from this Mac.")
                } actions: {
                    Button("Pair Console…") { store.isPairing = true }
                }
            } else {
                List(store.consoles, selection: $selection) { console in
                    ConsoleRow(console: console)
                        .contextMenu { ConsoleMenu(console: console) }
                }
                .contextMenu(forSelectionType: Console.ID.self) { _ in
                } primaryAction: { ids in
                    if let console = store.console(ids.first) { store.connect(console) }
                }
            }
        }
        .navigationTitle("Consoles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.isPairing = true
                } label: {
                    Label("Pair Console", systemImage: "plus")
                }
                .help("Pair a new console")
            }
        }
        .focusedSceneValue(\.selectedConsole, store.console(selection))
        .sheet(isPresented: $store.isPairing) {
            PairingSheet()
        }
        .task {
            if CommandLine.arguments.contains("--show-settings") { openSettings() }
            if CommandLine.arguments.contains("--show-pairing") { store.isPairing = true }
        }
        .alert("Can’t Connect", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct ConsoleRow: View {
    @EnvironmentObject private var store: ConsoleStore
    let console: Console

    private var isActive: Bool { store.activity.consoleID == console.id }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "playstation.logo")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(console.name)
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            Spacer()
            action
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var action: some View {
        switch store.activity {
        case .waking(let id) where id == console.id, .starting(let id) where id == console.id:
            ProgressView()
                .controlSize(.small)
            Button("Cancel") { store.stop() }
        case .streaming(let id) where id == console.id:
            Button("Stop") { store.stop() }
        default:
            Button(console.status == .standby ? "Wake and Connect" : "Connect") { store.connect(console) }
                .buttonStyle(.borderedProminent)
                .disabled(console.status == .offline || store.activity != .idle)
        }
    }

    private var statusText: String {
        switch store.activity {
        case .waking(let id) where id == console.id: return "Waking up…"
        case .starting(let id) where id == console.id: return "Starting stream…"
        case .streaming(let id) where id == console.id: return "Streaming"
        default: break
        }
        switch console.status {
        case .ready:
            if let app = console.runningApp, !app.isEmpty { return "Ready · \(app)" }
            return "Ready"
        case .standby: return "Rest Mode"
        case .offline: return "Not Available"
        }
    }

    private var statusColor: Color {
        if isActive { return .blue }
        switch console.status {
        case .ready: return .green
        case .standby: return .orange
        case .offline: return .secondary.opacity(0.5)
        }
    }
}

struct ConsoleMenu: View {
    @EnvironmentObject private var store: ConsoleStore
    let console: Console

    var body: some View {
        Button("Connect") { store.connect(console) }
            .disabled(console.status == .offline || store.activity != .idle)
        Button("Wake") { store.wake(console) }
            .disabled(console.status != .standby)
        Divider()
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(console.address ?? "", forType: .string)
        }
        .disabled(console.address == nil)
    }
}

struct SelectedConsoleKey: FocusedValueKey {
    typealias Value = Console
}

extension FocusedValues {
    var selectedConsole: Console? {
        get { self[SelectedConsoleKey.self] }
        set { self[SelectedConsoleKey.self] = newValue }
    }
}
