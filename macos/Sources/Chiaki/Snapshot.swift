import AppKit

/// Debug aid: `--snapshot <path>` writes each visible window to a PNG and quits. `--show-settings` opens Settings first.
enum Snapshot {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
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
}
