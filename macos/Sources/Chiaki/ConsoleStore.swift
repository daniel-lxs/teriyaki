import AppKit
import CChiaki
import Combine

@MainActor
final class ConsoleStore: ObservableObject {
    @Published private(set) var consoles: [Console] = []
    @Published private(set) var discovered: [DiscoveredConsole] = []
    @Published private(set) var activity: ConsoleActivity = .idle
    @Published var errorMessage: String?
    @Published var isPairing = false

    private let prefs = Prefs.shared
    private let discovery = Discovery()
    private let streamWindow = StreamWindowController()
    private var searchTimer: Timer?
    private var session: StreamSession?
    private var wakeDeadline: Date?
    private var discoveredSeen: [String: Date] = [:]
    private var pairing: Pairing?

    private static let offlineAfter: TimeInterval = 10
    private static let wakeTimeout: TimeInterval = 60

    init(demo: Bool = false) {
        if demo {
            consoles = Self.demoConsoles
            discovered = [DiscoveredConsole(id: "D", name: "PS5-204", address: "192.168.1.22", isPS5: true, systemVersion: "")]
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
        streamWindow.onClose = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
    }

    func console(_ id: Console.ID?) -> Console? {
        consoles.first { $0.id == id }
    }

    func reload() {
        consoles = prefs.registeredConsoles().map { fresh in
            guard let current = console(fresh.id) else { return fresh }
            var merged = fresh
            merged.address = current.address ?? fresh.address
            merged.status = current.status
            merged.runningApp = current.runningApp
            merged.lastSeen = current.lastSeen
            return merged
        }
        discovered.removeAll { candidate in consoles.contains { $0.id == candidate.id } }
    }

    func connect(_ console: Console) {
        guard activity == .idle else { return }
        switch console.status {
        case .ready:
            startStream(console)
        case .standby:
            wake(console)
            wakeDeadline = Date().addingTimeInterval(Self.wakeTimeout)
            activity = .waking(console.id)
        case .offline:
            errorMessage = "\(console.name) isn’t responding. Make sure it’s turned on or in rest mode and on the same network as this Mac."
        }
    }

    func wake(_ console: Console) {
        guard let address = console.address, let credential = console.wakeCredential else { return }
        discovery.wake(address: address, credential: credential, isPS5: console.isPS5)
    }

    func stop() {
        switch activity {
        case .waking:
            wakeDeadline = nil
            activity = .idle
        case .starting, .streaming:
            endStream()
        case .idle:
            break
        }
    }

    func pressPS() {
        session?.input.pressPS()
    }

    func pair(_ target: DiscoveredConsole, pin: String, completion: @escaping (String?) -> Void) {
        guard let accountID = prefs.accountID else {
            completion("Sign in to PlayStation Network first.")
            return
        }
        guard let code = UInt32(pin), pin.count == 8 else {
            completion("Enter the 8-digit code shown on the console.")
            return
        }
        pairing = Pairing(target: target, accountID: accountID, pin: code) { [weak self] host in
            guard let self else { return }
            self.pairing = nil
            guard let host else {
                completion("Pairing failed. Check the code and that the console is still showing the Link Device screen.")
                return
            }
            self.prefs.save(host)
            self.prefs.remember(address: target.address, for: target.id)
            self.reload()
            completion(nil)
        }
        if pairing?.start() != true {
            pairing = nil
            completion("Pairing couldn’t be started.")
        }
    }

    func cancelPairing() {
        pairing?.cancel()
        pairing = nil
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
        discovered.removeAll { (discoveredSeen[$0.id] ?? .distantPast) < cutoff }
        if case .waking(let id) = activity, let deadline = wakeDeadline, Date() > deadline {
            activity = .idle
            wakeDeadline = nil
            errorMessage = "\(console(id)?.name ?? "The console") didn’t wake up. Check that it can be turned on from the network in its rest mode settings."
        }
    }

    private func apply(_ reply: Discovery.Reply) {
        guard let index = consoles.firstIndex(where: { $0.id == reply.hostID }) else {
            let found = DiscoveredConsole(id: reply.hostID, name: reply.name, address: reply.address, isPS5: reply.isPS5, systemVersion: reply.systemVersion)
            discoveredSeen[found.id] = Date()
            if let existing = discovered.firstIndex(where: { $0.id == found.id }) {
                discovered[existing] = found
            } else {
                discovered.append(found)
            }
            return
        }
        consoles[index].address = reply.address
        consoles[index].status = reply.status
        consoles[index].runningApp = reply.runningApp
        consoles[index].lastSeen = Date()
        prefs.remember(address: reply.address, for: reply.hostID)
        if case .waking(let id) = activity, id == reply.hostID, reply.status == .ready {
            wakeDeadline = nil
            activity = .idle
            startStream(consoles[index])
        }
    }

    private func startStream(_ console: Console) {
        guard let address = console.address else { return }
        guard let accountID = prefs.accountID else {
            errorMessage = "Sign in to PlayStation Network before connecting. Choose Pair Console to sign in."
            return
        }
        guard console.registKey.count == 16, console.morning.count == 16 else {
            errorMessage = "The pairing for \(console.name) is incomplete. Pair it again."
            return
        }
        let resolutions = ["360p": 1, "540p": 2, "720p": 3, "1080p": 4]
        let codecs = ["h264": 0, "h265": 1, "h265_hdr": 1]
        let configuration = StreamSession.Configuration(
            host: address, isPS5: console.isPS5, registKey: console.registKey, morning: console.morning,
            accountID: accountID, resolution: resolutions[prefs.resolution] ?? 4, frameRate: prefs.frameRate,
            bitrateKbps: Int(prefs.bitrate * 1000), codec: console.isPS5 ? codecs[prefs.codec] ?? 1 : 0,
            audioBufferMilliseconds: prefs.audioBufferBytes / 192)
        let session = StreamSession(configuration: configuration)
        session.onConnected = { [weak self] in
            guard let self, self.session === session else { return }
            self.activity = .streaming(console.id)
            self.mainWindow?.orderOut(nil)
            self.streamWindow.show(title: console.name, display: session.renderer.layer, fullScreen: self.prefs.startFullScreen)
        }
        session.onQuit = { [weak self] isError, message in
            guard let self, self.session === session else { return }
            self.endStream()
            if isError { self.errorMessage = message }
        }
        session.onLoginPIN = { [weak self] incorrect in
            self?.askLoginPIN(incorrect: incorrect)
        }
        guard session.start() else {
            errorMessage = "The stream couldn’t be started."
            return
        }
        self.session = session
        activity = .starting(console.id)
    }

    private func endStream() {
        streamWindow.close()
        let ending = session
        session = nil
        activity = .idle
        ending?.stop()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    private func askLoginPIN(incorrect: Bool) {
        let alert = NSAlert()
        alert.messageText = incorrect ? "Incorrect Passcode" : "Console Passcode Required"
        alert.informativeText = "Enter the passcode for your PlayStation login."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            session?.setLoginPIN(field.stringValue)
        } else {
            stop()
        }
    }

    private static let demoConsoles = [
        Console(id: "A", name: "Living Room PS5", isPS5: true, registKey: Data(), morning: Data(), address: "192.168.1.20", status: .ready, runningApp: "Astro Bot"),
        Console(id: "B", name: "Bedroom PS5", isPS5: true, registKey: Data(), morning: Data(), address: "192.168.1.21", status: .standby),
        Console(id: "C", name: "Office PS4", isPS5: false, registKey: Data(), morning: Data(), status: .offline),
    ]
}

/// One pairing attempt with a console that is showing its Link Device code.
final class Pairing {
    private let target: DiscoveredConsole
    private let accountID: Data
    private let pin: UInt32
    private var completion: ((PairedHost?) -> Void)?
    private var handle: OpaquePointer?

    init(target: DiscoveredConsole, accountID: Data, pin: UInt32, completion: @escaping (PairedHost?) -> Void) {
        self.target = target
        self.accountID = accountID
        self.pin = pin
        self.completion = completion
    }

    func start() -> Bool {
        let user = Unmanaged.passUnretained(self).toOpaque()
        handle = accountID.withUnsafeBytes { account in
            chiaki_shim_regist_start(target.address, target.isPS5, target.systemVersion,
                                     account.bindMemory(to: UInt8.self).baseAddress, pin, { user, success, host in
                let pairing = Unmanaged<Pairing>.fromOpaque(user!).takeUnretainedValue()
                let result = success ? host.map { Pairing.convert($0.pointee) } : nil
                DispatchQueue.main.async { pairing.finish(result) }
            }, user)
        }
        return handle != nil
    }

    func cancel() {
        completion = nil
        release()
    }

    private func finish(_ host: PairedHost?) {
        let completion = self.completion
        self.completion = nil
        release()
        completion?(host)
    }

    private func release() {
        guard let handle else { return }
        self.handle = nil
        DispatchQueue.global().async { chiaki_shim_regist_free(handle) }
    }

    private static func convert(_ host: ChiakiShimRegisteredHost) -> PairedHost {
        var host = host
        func text<T>(_ value: inout T) -> String {
            withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        func bytes<T>(_ value: inout T) -> Data {
            withUnsafeBytes(of: &value) { Data($0) }
        }
        return PairedHost(
            target: Int(host.target), name: text(&host.server_nickname), mac: bytes(&host.server_mac),
            registKey: bytes(&host.rp_regist_key), keyType: Int(host.rp_key_type), key: bytes(&host.rp_key),
            accessPointSSID: text(&host.ap_ssid), accessPointBSSID: text(&host.ap_bssid),
            accessPointKey: text(&host.ap_key), accessPointName: text(&host.ap_name),
            consolePIN: host.console_pin == 0 ? "" : String(host.console_pin))
    }
}
