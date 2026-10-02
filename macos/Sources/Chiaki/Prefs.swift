import Foundation

/// Pairings and stream settings. Stored in the domain chiaki-ng uses, so existing pairings carry over.
final class Prefs: ObservableObject {
    static let shared = Prefs()

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
            return Console(
                id: id,
                name: engine.string(forKey: prefix + "server_nickname") ?? "PlayStation",
                isPS5: engine.integer(forKey: prefix + "target") >= 1_000_000,
                registKey: engine.data(forKey: prefix + "rp_regist_key") ?? Data(),
                morning: engine.data(forKey: prefix + "rp_key") ?? Data(),
                address: addresses[id]
            )
        }
    }

    func save(_ host: PairedHost) {
        let count = engine.integer(forKey: "registered_hosts.size")
        let existing = (1...max(count, 1)).first { engine.data(forKey: "registered_hosts.\($0).server_mac") == host.mac && count > 0 }
        let index = existing ?? count + 1
        let prefix = "registered_hosts.\(index)."
        engine.set(host.target, forKey: prefix + "target")
        engine.set(host.name, forKey: prefix + "server_nickname")
        engine.set(host.mac, forKey: prefix + "server_mac")
        engine.set(host.registKey, forKey: prefix + "rp_regist_key")
        engine.set(host.keyType, forKey: prefix + "rp_key_type")
        engine.set(host.key, forKey: prefix + "rp_key")
        engine.set(host.accessPointSSID, forKey: prefix + "ap_ssid")
        engine.set(host.accessPointBSSID, forKey: prefix + "ap_bssid")
        engine.set(host.accessPointKey, forKey: prefix + "ap_key")
        engine.set(host.accessPointName, forKey: prefix + "ap_name")
        engine.set(host.consolePIN, forKey: prefix + "console_pin")
        if existing == nil { engine.set(index, forKey: "registered_hosts.size") }
    }

    /// The 8-byte PSN account ID that pairing and connecting need.
    var accountID: Data? {
        get {
            guard let text = engine.string(forKey: "settings.psn_account_id"), let data = Data(base64Encoded: text), data.count == 8 else { return nil }
            return data
        }
        set {
            objectWillChange.send()
            engine.set(newValue?.base64EncodedString(), forKey: "settings.psn_account_id")
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

    var audioBufferBytes: Int {
        get { int("audio_buffer_size", default: 9600) }
        set { set(newValue, "audio_buffer_size") }
    }

    var startFullScreen: Bool {
        get { local.object(forKey: "startFullScreen") == nil ? true : local.bool(forKey: "startFullScreen") }
        set { objectWillChange.send(); local.set(newValue, forKey: "startFullScreen") }
    }

}
