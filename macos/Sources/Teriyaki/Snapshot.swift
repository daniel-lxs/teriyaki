import AppKit
import AVFoundation

/// Debug aids, driven by launch arguments.
/// `--snapshot <path>` writes each visible window to a PNG and quits.
/// `--test-video <annexb file> <hevc|h264> <metal|metal-sync|layer>` plays a raw stream through a renderer and prints its timings.
enum Snapshot {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--test-video"), arguments.count > flag + 3 {
            testVideo(path: arguments[flag + 1], hevc: arguments[flag + 2] == "hevc", output: arguments[flag + 3])
            return
        }
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 else { return }
        let base = arguments[flag + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            for (index, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                guard let view = window.contentView?.superview,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(index).png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static var keep: [Any] = []

    private static func testVideo(path: String, hevc: Bool, output: String) {
        guard let data = FileManager.default.contents(atPath: path) else { exit(2) }
        let delimiter: UInt8 = hevc ? 35 : 9
        var frames: [[UInt8]] = []
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var current: [UInt8] = []
            StreamParser.forEachUnit(in: bytes) { unit in
                let type = hevc ? (unit[unit.startIndex] >> 1) & 0x3f : unit[unit.startIndex] & 0x1f
                if type == delimiter, !current.isEmpty {
                    frames.append(current)
                    current = []
                }
                current.append(contentsOf: [0, 0, 0, 1])
                current.append(contentsOf: unit)
            }
            if !current.isEmpty { frames.append(current) }
        }
        let renderer: VideoOutput
        switch output {
        case "layer": renderer = LayerRenderer(hevc: hevc)
        case "metal-sync": renderer = MetalRenderer(hevc: hevc, displaySync: true)!
        default: renderer = MetalRenderer(hevc: hevc)!
        }
        let window = StreamWindowController()
        window.show(title: "Video Test", display: renderer.layer, fullScreen: CommandLine.arguments.contains("--fullscreen"))
        keep = [renderer, window]
        if let flag = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > flag + 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                (renderer as? MetalRenderer)?.captureURL = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            }
        }
        if CommandLine.arguments.contains("--occlude") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { window.hideBriefly(seconds: 2) }
        }
        var index = 0
        var accepted = 0
        var slowest = 0.0
        let loops = 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                guard index < frames.count * loops else {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        print("\(output): sent=\(index) accepted=\(accepted) slowest enqueue=\(String(format: "%.1f", slowest * 1000)) ms | \(renderer.takeTimings().summary)")
                        exit(0)
                    }
                    return
                }
                let began = CACurrentMediaTime()
                let ok = frames[index % frames.count].withUnsafeBufferPointer { renderer.enqueue($0) }
                slowest = max(slowest, CACurrentMediaTime() - began)
                if ok { accepted += 1 }
                index += 1
            }
        }
    }
}
