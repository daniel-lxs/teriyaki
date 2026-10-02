import Foundation

/// Settings and pairings shared with the streaming engine, which stores them under its own domain.
final class EnginePrefs: ObservableObject {
    static let shared = EnginePrefs()

    private let engine = UserDefaults(suiteName: "com.chiaki.Chiaki") ?? .standard
    private let local = UserDefaults.standard

    func registeredConsoles() -> [Console] {
        let count = engine.integer(forKey: "registered_hosts.size")
        guard count > 0 else { return [] }
        let addresses = local.dictionary(forKey: "knownAddresses") as? [String: String] ?? [:]
        return (1...count).compactMap { index in
            let prefix = "registered_hosts.\(index)."
            guard let mac = engine.data(forKey: prefix + "server_mac"), !mac.isEmpty else { return nil }
            let id = mac.map { String(format: "%02X", $0) }.joined()
            let key = engine.data(forKey: prefix + "rp_regist_key") ?? Data()
            let registKey = String(decoding: key.prefix { $0 != 0 }, as: UTF8.self)
            return Console(
                id: id,
                name: engine.string(forKey: prefix + "server_nickname") ?? "PlayStation",
                isPS5: engine.integer(forKey: prefix + "target") >= 1_000_000,
                registKey: registKey,
                address: addresses[id]
            )
        }
    }

    func remember(address: String, for id: Console.ID) {
        var addresses = local.dictionary(forKey: "knownAddresses") as? [String: String] ?? [:]
        guard addresses[id] != address else { return }
        addresses[id] = address
        local.set(addresses, forKey: "knownAddresses")
    }

    private func string(_ key: String, default value: String) -> String {
        engine.string(forKey: "settings." + key) ?? value
    }

    private func int(_ key: String, default value: Int) -> Int {
        engine.object(forKey: "settings." + key) == nil ? value : engine.integer(forKey: "settings." + key)
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        engine.object(forKey: "settings." + key) == nil ? value : engine.bool(forKey: "settings." + key)
    }

    private func set(_ value: Any, _ key: String) {
        objectWillChange.send()
        engine.set(value, forKey: "settings." + key)
    }

    var resolution: String {
        get { string("resolution_local_ps5", default: "1080p") }
        set { set(newValue, "resolution_local_ps5") }
    }

    var frameRate: Int {
        get { int("fps_local_ps5", default: 60) }
        set { set(newValue, "fps_local_ps5") }
    }

    var codec: String {
        get { string("codec_local_ps5", default: "h265") }
        set { set(newValue, "codec_local_ps5") }
    }

    /// Mbps. The engine stores kbps and treats 0 as "use the default for this resolution".
    var bitrate: Double {
        get {
            let stored = int("bitrate_local_ps5", default: 0)
            return stored > 0 ? Double(stored) / 1000 : 15
        }
        set { set(Int(newValue.rounded()) * 1000, "bitrate_local_ps5") }
    }

    var scalingQuality: String {
        get { string("placebo_preset", default: "high_quality") }
        set { set(newValue, "placebo_preset") }
    }

    var showStatistics: Bool {
        get { bool("show_stream_stats", default: false) }
        set { set(newValue, "show_stream_stats") }
    }

    var audioBufferBytes: Int {
        get { int("audio_buffer_size", default: 9600) }
        set { set(newValue, "audio_buffer_size") }
    }

    var renderer: String {
        get { string("render_backend", default: "vulkan") }
        set { set(newValue, "render_backend") }
    }

    var startFullScreen: Bool {
        get { local.object(forKey: "startFullScreen") == nil ? true : local.bool(forKey: "startFullScreen") }
        set { objectWillChange.send(); local.set(newValue, forKey: "startFullScreen") }
    }

    var framePacing: Bool {
        get { local.bool(forKey: "framePacing") }
        set { objectWillChange.send(); local.set(newValue, forKey: "framePacing") }
    }

    var logFrameTiming: Bool {
        get { local.bool(forKey: "logFrameTiming") }
        set { objectWillChange.send(); local.set(newValue, forKey: "logFrameTiming") }
    }
}
