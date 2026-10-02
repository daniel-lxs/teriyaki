import AppKit
import Combine

@MainActor
final class ConsoleStore: ObservableObject {
    @Published private(set) var consoles: [Console] = []
    @Published private(set) var activity: ConsoleActivity = .idle
    @Published var errorMessage: String?

    private let prefs = EnginePrefs.shared
    private let discovery = Discovery()
    private var searchTimer: Timer?
    private var engine: NSRunningApplication?
    private var wakeDeadline: Date?
    private var observers: [NSObjectProtocol] = []

    private static let offlineAfter: TimeInterval = 10
    private static let wakeTimeout: TimeInterval = 60

    init(demo: Bool = false) {
        if demo {
            consoles = Self.demoConsoles
            return
        }
        reload()
        discovery.onReply = { [weak self] reply in
            Task { @MainActor in self?.apply(reply) }
        }
        searchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.engineTerminated(app) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        })
    }

    func console(_ id: Console.ID?) -> Console? {
        consoles.first { $0.id == id }
    }

    func reload() {
        let stored = prefs.registeredConsoles()
        consoles = stored.map { fresh in
            guard let current = console(fresh.id) else { return fresh }
            var merged = fresh
            merged.address = current.address ?? fresh.address
            merged.status = current.status
            merged.runningApp = current.runningApp
            merged.lastSeen = current.lastSeen
            return merged
        }
    }

    func connect(_ console: Console) {
        guard activity == .idle else { return }
        switch console.status {
        case .ready:
            launch(console)
        case .standby:
            guard let address = console.address else { return }
            discovery.wake(address: address, registKey: console.registKey, isPS5: console.isPS5)
            wakeDeadline = Date().addingTimeInterval(Self.wakeTimeout)
            activity = .waking(console.id)
        case .offline:
            errorMessage = "\(console.name) isn’t responding. Make sure it’s turned on or in rest mode and on the same network as this Mac."
        }
    }

    func wake(_ console: Console) {
        guard let address = console.address else { return }
        discovery.wake(address: address, registKey: console.registKey, isPS5: console.isPS5)
    }

    func stop() {
        switch activity {
        case .waking:
            wakeDeadline = nil
            activity = .idle
        case .starting, .streaming:
            guard let engine else { activity = .idle; return }
            engine.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !engine.isTerminated { engine.forceTerminate() }
            }
        case .idle:
            break
        }
    }

    func pairNewConsole() {
        guard let url = Engine.appURL else {
            errorMessage = Engine.missingMessage
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func tick() {
        discovery.search(knownAddresses: consoles.compactMap(\.address))
        let cutoff = Date().addingTimeInterval(-Self.offlineAfter)
        for index in consoles.indices where consoles[index].status != .offline {
            if let seen = consoles[index].lastSeen, seen < cutoff {
                consoles[index].status = .offline
                consoles[index].runningApp = nil
            }
        }
        if case .waking(let id) = activity, let deadline = wakeDeadline, Date() > deadline {
            activity = .idle
            wakeDeadline = nil
            errorMessage = "\(console(id)?.name ?? "The console") didn’t wake up. Check that “Enable Turning On PS5 from Network” is on in its rest mode settings."
        }
    }

    private func apply(_ reply: Discovery.Reply) {
        guard let index = consoles.firstIndex(where: { $0.id == reply.hostID }) else { return }
        consoles[index].address = reply.address
        consoles[index].status = reply.status
        consoles[index].runningApp = reply.runningApp
        consoles[index].lastSeen = Date()
        prefs.remember(address: reply.address, for: reply.hostID)
        if case .waking(let id) = activity, id == reply.hostID, reply.status == .ready {
            wakeDeadline = nil
            activity = .idle
            launch(consoles[index])
        }
    }

    private func launch(_ console: Console) {
        guard let url = Engine.appURL else {
            errorMessage = Engine.missingMessage
            return
        }
        guard let address = console.address else { return }
        activity = .starting(console.id)
        let configuration = Engine.configuration(nickname: console.name, address: address, prefs: prefs)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if let app {
                    self.engine = app
                    self.activity = .streaming(console.id)
                } else {
                    self.activity = .idle
                    self.errorMessage = error?.localizedDescription ?? "The stream couldn’t be started."
                }
            }
        }
    }

    private func engineTerminated(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier == engine?.processIdentifier else { return }
        engine = nil
        activity = .idle
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let demoConsoles = [
        Console(id: "A", name: "Living Room PS5", isPS5: true, registKey: "", address: "192.168.1.20", status: .ready, runningApp: "Astro Bot"),
        Console(id: "B", name: "Bedroom PS5", isPS5: true, registKey: "", address: "192.168.1.21", status: .standby),
        Console(id: "C", name: "Office PS4", isPS5: false, registKey: "", status: .offline),
    ]
}
