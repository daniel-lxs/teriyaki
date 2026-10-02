import AppKit
import CChiaki
import os

/// One Remote Play session: connects to the console and routes video, audio and controller input.
final class StreamSession {
    struct Configuration {
        var host: String
        var isPS5: Bool
        var registKey: Data
        var morning: Data
        var accountID: Data
        var resolution: Int
        var frameRate: Int
        var bitrateKbps: Int
        var codec: Int
        var audioBufferMilliseconds: Int
    }

    var onConnected: (() -> Void)?
    var onQuit: ((_ isError: Bool, _ message: String) -> Void)?
    var onLoginPIN: ((_ incorrect: Bool) -> Void)?

    let renderer: VideoOutput
    let input = ControllerInput()

    private let configuration: Configuration
    private let audio: AudioPlayer
    private let log = SessionLog()
    private var handle: OpaquePointer?
    private var activity: NSObjectProtocol?
    private var statsTimer: Timer?
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    private struct Counters {
        var frames = 0
        var rejected = 0
        var bytes = 0
        var audioFrames = 0
    }

    init(configuration: Configuration) {
        self.configuration = configuration
        let hevc = configuration.codec != 0
        if UserDefaults.standard.string(forKey: "renderer") != "layer", let metal = MetalRenderer(hevc: hevc) {
            renderer = metal
        } else {
            renderer = LayerRenderer(hevc: hevc)
        }
        audio = AudioPlayer(bufferMilliseconds: configuration.audioBufferMilliseconds)
    }

    func start() -> Bool {
        input.onLog = { [log] in log.write(level: 4, $0) }
        input.start()
        var callbacks = ChiakiShimCallbacks()
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        callbacks.video = { user, data, size, _, _ in
            guard let data else { return false }
            let session = StreamSession.from(user)
            let accepted = session.renderer.enqueue(UnsafeBufferPointer(start: data, count: size))
            session.counters.withLock {
                $0.frames += 1
                $0.bytes += size
                if !accepted { $0.rejected += 1 }
            }
            return accepted
        }
        callbacks.audio_format = { user, channels, rate in
            StreamSession.from(user).audio.configure(channels: Int(channels), rate: Double(rate))
        }
        callbacks.audio = { user, samples, frames in
            guard let samples else { return }
            let session = StreamSession.from(user)
            session.audio.push(samples, frames: frames)
            session.counters.withLock { $0.audioFrames += frames }
        }
        callbacks.connected = { user in
            let session = StreamSession.from(user)
            DispatchQueue.main.async { session.onConnected?() }
        }
        callbacks.quit = { user, isError, reason, detail in
            let session = StreamSession.from(user)
            var message = reason.map { String(cString: $0) } ?? "The session ended."
            if let detail, detail.pointee != 0 { message += " (\(String(cString: detail)))" }
            DispatchQueue.main.async { session.onQuit?(isError, message) }
        }
        callbacks.login_pin = { user, incorrect in
            let session = StreamSession.from(user)
            DispatchQueue.main.async { session.onLoginPIN?(incorrect) }
        }
        callbacks.rumble = { _, _, _ in }
        callbacks.log = { user, level, message in
            guard let message else { return }
            StreamSession.from(user).log.write(level: Int(level), String(cString: message))
        }

        let config = configuration
        let dualSense = input.hasDualSense
        handle = config.host.withCString { host in
            config.registKey.withUnsafeBytes { registKey in
                config.morning.withUnsafeBytes { morning in
                    config.accountID.withUnsafeBytes { account in
                        var info = ChiakiShimConnectInfo()
                        info.host = host
                        info.ps5 = config.isPS5
                        info.regist_key = registKey.bindMemory(to: UInt8.self).baseAddress
                        info.morning = morning.bindMemory(to: UInt8.self).baseAddress
                        info.psn_account_id = account.bindMemory(to: UInt8.self).baseAddress
                        info.resolution = Int32(config.resolution)
                        info.fps = Int32(config.frameRate)
                        info.bitrate_kbps = Int32(config.bitrateKbps)
                        info.codec = Int32(config.codec)
                        info.dualsense = dualSense
                        return chiaki_shim_session_start(&info, &callbacks)
                    }
                }
            }
        }
        guard let handle else {
            input.stop()
            return false
        }
        input.onChange = { state in
            var state = state
            chiaki_shim_session_set_controller(handle, &state)
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.logStats() }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "Remote Play")
        return true
    }

    func setLoginPIN(_ pin: String) {
        guard let handle else { return }
        chiaki_shim_session_set_login_pin(handle, pin)
    }

    /// Ends the session. The completion runs on the main queue once the connection has shut down.
    func stop(completion: @escaping () -> Void = {}) {
        statsTimer?.invalidate()
        statsTimer = nil
        input.onChange = nil
        input.stop()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        guard let handle else {
            completion()
            return
        }
        self.handle = nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            chiaki_shim_session_stop(handle)
            audio.stop()
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func logStats() {
        let snapshot = counters.withLock { counters -> Counters in
            defer { counters = Counters() }
            return counters
        }
        log.write(level: 4, "[stats] 5 s: frames=\(snapshot.frames) rejected=\(snapshot.rejected) mbps=\(String(format: "%.1f", Double(snapshot.bytes) * 8 / 5_000_000)) | \(renderer.takeTimings().summary) | audio ms=\(snapshot.audioFrames / 48) controller=\(input.reports)")
    }

    private static func from(_ pointer: UnsafeMutableRawPointer?) -> StreamSession {
        Unmanaged<StreamSession>.fromOpaque(pointer!).takeUnretainedValue()
    }
}

final class SessionLog {
    private let queue = DispatchQueue(label: "session-log")
    private var file: FileHandle?
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Teriyaki")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent("session_\(name.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    func write(level: Int, _ message: String) {
        let tag = level == 1 ? "E" : level == 2 ? "W" : "I"
        let date = Date()
        queue.async { [self] in
            file?.write(Data("[\(stamp.string(from: date))] [\(tag)] \(message)\n".utf8))
        }
    }
}
