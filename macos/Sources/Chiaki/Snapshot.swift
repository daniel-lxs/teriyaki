import AppKit
import AVFoundation
import VideoToolbox

/// Debug aids, driven by launch arguments.
/// `--snapshot <path>` writes each visible window to a PNG and quits.
/// `--test-video <annexb file> <hevc|h264> <png>` plays a raw stream through the renderer and saves one decoded frame.
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
            VideoRenderer.forEachUnit(in: bytes) { unit in
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
        let renderer = VideoRenderer(hevc: hevc)
        let window = StreamWindowController()
        window.show(title: "Video Test", display: renderer.layer, fullScreen: false)
        keep = [renderer, window]
        var index = 0
        var accepted = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            guard index < frames.count else {
                timer.invalidate()
                let status = renderer.layer.sampleBufferRenderer.status
                let error = renderer.layer.sampleBufferRenderer.error.map { "\($0)" } ?? "none"
                let decoded = renderer.decodeForTest(frames.first ?? [], output: output)
                print("frames=\(frames.count) accepted=\(accepted) status=\(status.rawValue) error=\(error) decoded=\(decoded)")
                exit(0)
            }
            let ok = frames[index].withUnsafeBufferPointer { renderer.enqueue($0) }
            if ok { accepted += 1 }
            index += 1
        }
    }
}

extension VideoRenderer {
    /// Decodes one access unit with the format this renderer built and writes it as a PNG.
    func decodeForTest(_ frame: [UInt8], output: String) -> Bool {
        guard let sample = frame.withUnsafeBufferPointer({ testSample($0) }),
              let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session else { return false }
        var written = false
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, image, _, _ in
            guard let image else { return }
            let bitmap = NSBitmapImageRep(ciImage: CIImage(cvPixelBuffer: image))
            written = (try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))) != nil
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return written
    }
}
