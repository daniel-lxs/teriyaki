import CChiaki
import GameController

/// Reads the active game controller and reports its state whenever it changes.
final class ControllerInput {
    var onChange: ((ChiakiShimControllerState) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "controller", qos: .userInteractive)
    private var observers: [NSObjectProtocol] = []
    private var touchIDs: [Int8] = [-1, -1]
    private var nextTouchID: Int8 = 0
    private var psHeld = false
    private(set) var reports = 0

    private enum Button {
        static let cross: UInt32 = 1 << 0
        static let moon: UInt32 = 1 << 1
        static let box: UInt32 = 1 << 2
        static let pyramid: UInt32 = 1 << 3
        static let dpadLeft: UInt32 = 1 << 4
        static let dpadRight: UInt32 = 1 << 5
        static let dpadUp: UInt32 = 1 << 6
        static let dpadDown: UInt32 = 1 << 7
        static let l1: UInt32 = 1 << 8
        static let r1: UInt32 = 1 << 9
        static let l3: UInt32 = 1 << 10
        static let r3: UInt32 = 1 << 11
        static let options: UInt32 = 1 << 12
        static let share: UInt32 = 1 << 13
        static let touchpad: UInt32 = 1 << 14
        static let ps: UInt32 = 1 << 15
    }

    var hasDualSense: Bool {
        GCController.controllers().contains { $0.extendedGamepad is GCDualSenseGamepad }
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.attach(controller) }
        })
        GCController.controllers().forEach(attach)
        onLog?("Controllers at start: \(GCController.controllers().map { $0.vendorName ?? "unknown" })")
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
    }

    /// Holds the PS button for a moment, for when macOS keeps the controller's own button to itself.
    func pressPS() {
        queue.async { [self] in
            psHeld = true
            report()
            queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                psHeld = false
                report()
            }
        }
    }

    private func attach(_ controller: GCController) {
        onLog?("Controller attached: \(controller.vendorName ?? "unknown"), extended gamepad: \(controller.extendedGamepad != nil)")
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = queue
        pad.buttonHome?.preferredSystemGestureState = .disabled
        pad.buttonOptions?.preferredSystemGestureState = .disabled
        pad.buttonMenu.preferredSystemGestureState = .disabled
        pad.valueChangedHandler = { [weak self] _, _ in self?.report() }
        queue.async { [self] in report() }
    }

    private func report() {
        guard let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad else {
            if psHeld {
                var state = ChiakiShimControllerState()
                state.buttons = Button.ps
                state.touch_id = (-1, -1)
                onChange?(state)
            }
            return
        }
        var state = ChiakiShimControllerState()
        var buttons: UInt32 = 0
        func set(_ flag: UInt32, _ pressed: Bool?) { if pressed == true { buttons |= flag } }
        set(Button.cross, pad.buttonA.isPressed)
        set(Button.moon, pad.buttonB.isPressed)
        set(Button.box, pad.buttonX.isPressed)
        set(Button.pyramid, pad.buttonY.isPressed)
        set(Button.dpadLeft, pad.dpad.left.isPressed)
        set(Button.dpadRight, pad.dpad.right.isPressed)
        set(Button.dpadUp, pad.dpad.up.isPressed)
        set(Button.dpadDown, pad.dpad.down.isPressed)
        set(Button.l1, pad.leftShoulder.isPressed)
        set(Button.r1, pad.rightShoulder.isPressed)
        set(Button.l3, pad.leftThumbstickButton?.isPressed)
        set(Button.r3, pad.rightThumbstickButton?.isPressed)
        set(Button.options, pad.buttonMenu.isPressed)
        set(Button.share, pad.buttonOptions?.isPressed)
        set(Button.ps, (pad.buttonHome?.isPressed ?? false) || psHeld)

        state.l2 = UInt8(pad.leftTrigger.value * 255)
        state.r2 = UInt8(pad.rightTrigger.value * 255)
        state.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
        state.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
        state.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
        state.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)
        state.touch_id = (-1, -1)

        if let dualSense = pad as? GCDualSenseGamepad {
            set(Button.touchpad, dualSense.touchpadButton.isPressed)
            let first = touch(0, dualSense.touchpadPrimary)
            let second = touch(1, dualSense.touchpadSecondary)
            state.touch_id = (first.id, second.id)
            state.touch_x = (first.x, second.x)
            state.touch_y = (first.y, second.y)
        } else if let dualShock = pad as? GCDualShockGamepad {
            set(Button.touchpad, dualShock.touchpadButton.isPressed)
        }
        state.buttons = buttons
        reports += 1
        onChange?(state)
    }

    private func touch(_ slot: Int, _ pad: GCControllerDirectionPad) -> (id: Int8, x: UInt16, y: UInt16) {
        let x = pad.xAxis.value
        let y = pad.yAxis.value
        guard x != 0 || y != 0 else {
            touchIDs[slot] = -1
            return (-1, 0, 0)
        }
        if touchIDs[slot] < 0 {
            touchIDs[slot] = nextTouchID
            nextTouchID = nextTouchID == 127 ? 0 : nextTouchID + 1
        }
        return (touchIDs[slot], UInt16((x + 1) / 2 * 1919), UInt16((1 - y) / 2 * 1079))
    }

    private static func axis(_ value: Float) -> Int16 {
        Int16(max(-1, min(1, value)) * 32767)
    }
}
