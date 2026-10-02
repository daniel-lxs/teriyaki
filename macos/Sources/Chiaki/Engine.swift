import AppKit

/// The streaming engine: the chiaki-ng app that does the actual Remote Play session.
enum Engine {
    static let missingMessage = "The streaming engine is missing. Reinstall Chiaki."

    static var appURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/chiaki-ng.app"),
            URL(fileURLWithPath: "/Applications/chiaki-ng.app"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/chiaki").path)
        }
    }

    static func configuration(nickname: String, address: String, prefs: EnginePrefs) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        var arguments = ["--exit-app-on-stream-exit"]
        if prefs.startFullScreen { arguments.append("--fullscreen") }
        configuration.arguments = arguments + ["stream", nickname, address]
        var environment: [String: String] = [:]
        if prefs.framePacing { environment["CHIAKI_PACE"] = "1" }
        if prefs.logFrameTiming { environment["CHIAKI_LAT_PROBE"] = "1" }
        configuration.environment = environment
        return configuration
    }
}
