import AppKit
import AVFoundation

final class StreamView: NSView {
    private let display: CALayer
    private var hideTimer: Timer?

    init(display: CALayer) {
        self.display = display
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(display)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        if let metal = display as? CAMetalLayer {
            metal.contentsScale = window?.backingScaleFactor ?? 2
            metal.drawableSize = convertToBacking(bounds).size
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    override func keyDown(with event: NSEvent) {}
}

final class StreamWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var window: NSWindow?

    func show(title: String, display: CALayer, fullScreen: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = StreamView(display: display)
        window.delegate = self
        if let main = NSApp.windows.first(where: { $0.isVisible }), let screen = main.screen {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - 640, y: frame.midY - 360))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        NSApp.activate(ignoringOtherApps: true)
        if fullScreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.toggleFullScreen(nil) }
        }
        self.window = window
    }

    /// Debug aid: takes the window off screen for a moment, as when the user switches away.
    func hideBriefly(seconds: Double) {
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.window?.makeKeyAndOrderFront(nil) }
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }
}
