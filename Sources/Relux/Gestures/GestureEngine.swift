import AppKit
import OpenMultitouchSupport
import os

private let log = Logger(subsystem: "com.relux.app", category: "gesture-engine")

/// State shared between the main actor (where touch frames are processed) and the
/// CGEventTap callback thread (where clicks are intercepted). Guarded by an unfair lock.
private struct TapState {
    var threeFingersTouching = false
    var postingCmdClick = false
    var clickEnabled = true
}

private enum TapDecision {
    case passthrough
    case consume
    case consumeAndTriggerClick
}

@MainActor
final class GestureEngine {
    var onGesture: ((GestureType) -> Void)?

    private var touchTask: Task<Void, Never>?
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private var isRunning = false

    // 3-finger tracking state
    private var trackingTouches = false
    private var initialPositions: [Int32: (x: Float, y: Float)] = [:]
    private var latestPositions: [Int32: (x: Float, y: Float)] = [:]
    private var trackedFingerIDs: Set<Int32> = []
    private var consecutiveThreeFingerFrames = 0

    /// Shared with the CGEventTap callback thread.
    private nonisolated let tapState = OSAllocatedUnfairLock<TapState>(initialState: TapState())

    // 4-finger tracking state
    private var trackingFourFingers = false
    private var fourFingerInitialPositions: [Int32: (x: Float, y: Float)] = [:]
    private var fourFingerLatestPositions: [Int32: (x: Float, y: Float)] = [:]
    private var fourFingerTrackedIDs: Set<Int32> = []
    private var consecutiveFourFingerFrames = 0

    /// Tunable via UserDefaults (gesture.stableFrames, gesture.swipeThreshold, gesture.edgeMargin,
    /// gesture.keystrokeWindowMs, gesture.touchQualityMin, gesture.fingerSpreadMin, gesture.aspectRatioMax).
    /// Cached to avoid hitting UserDefaults on every touch frame; refreshed via NSUserDefaultsDidChange.
    private(set) var requiredStableFrames: Int = 2
    private(set) var swipeThreshold: Float = 0.15
    private(set) var edgeMargin: Float = 0.05
    private(set) var keystrokeWindow: TimeInterval = 0.180
    private(set) var touchQualityMin: Float = 0.125
    private(set) var fingerSpreadMin: Float = 0.15
    private(set) var aspectRatioMax: Float = 2.5

    private var defaultsObserver: NSObjectProtocol?

    private var lastKeystrokeAt: Date = .distantPast
    private var keystrokeMonitor: Any?

    private func reloadTunables() {
        let defaults = UserDefaults.standard
        requiredStableFrames = max(1, defaults.object(forKey: "gesture.stableFrames") as? Int ?? 2)
        swipeThreshold = defaults.object(forKey: "gesture.swipeThreshold") as? Float ?? 0.15
        edgeMargin = defaults.object(forKey: "gesture.edgeMargin") as? Float ?? 0.05
        keystrokeWindow = TimeInterval(max(0, defaults.object(forKey: "gesture.keystrokeWindowMs") as? Int ?? 180)) / 1000.0
        touchQualityMin = defaults.object(forKey: "gesture.touchQualityMin") as? Float ?? 0.125
        fingerSpreadMin = defaults.object(forKey: "gesture.fingerSpreadMin") as? Float ?? 0.15
        aspectRatioMax = defaults.object(forKey: "gesture.aspectRatioMax") as? Float ?? 2.5

        let clickEnabled = defaults.object(forKey: "gesture.threeFingerClickEnabled") as? Bool ?? true
        tapState.withLock { $0.clickEnabled = clickEnabled }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        log.info("Gesture engine starting")

        reloadTunables()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadTunables()
            }
        }

        keystrokeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] _ in
            Task { @MainActor in
                self?.lastKeystrokeAt = Date()
            }
        }

        OMSManager.shared.startListening()
        installClickTap()

        touchTask = Task { [weak self] in
            let stream = OMSManager.shared.touchDataStream
            for await touches in stream {
                guard !Task.isCancelled else { break }
                self?.processTouchFrame(touches)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        log.info("Gesture engine stopping")

        touchTask?.cancel()
        touchTask = nil

        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }

        if let monitor = keystrokeMonitor {
            NSEvent.removeMonitor(monitor)
            keystrokeMonitor = nil
        }

        uninstallClickTap()

        OMSManager.shared.stopListening()
        resetTracking()
        tapState.withLock { $0.threeFingersTouching = false }
    }

    private func installClickTap() {
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<GestureEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handleTappedEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            log.error("Failed to create CGEventTap — check Accessibility permission")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    private func uninstallClickTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called from the event tap's run-loop source, which we attach to the main run loop.
    /// Nonisolated because CGEventTapCallBack is a plain C function — touches only thread-safe state.
    private nonisolated func handleTappedEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the system disabled it (e.g. due to timeout).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let hasCmd = event.flags.contains(.maskCommand)

        let decision: TapDecision = tapState.withLock { state in
            // While posting our synthesized Cmd+Click, pass our own events through but
            // swallow any residual real click events (they have no .maskCommand).
            if state.postingCmdClick {
                return hasCmd ? .passthrough : .consume
            }
            guard state.clickEnabled, state.threeFingersTouching else {
                return .passthrough
            }
            // Ignore clicks that already carry Cmd (user holding Cmd themselves).
            if hasCmd {
                return .passthrough
            }
            if type == .leftMouseDown {
                state.postingCmdClick = true
                state.threeFingersTouching = false
                return .consumeAndTriggerClick
            }
            return .passthrough
        }

        switch decision {
        case .passthrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case .consumeAndTriggerClick:
            Task { @MainActor [weak self] in
                self?.postCmdClick()
            }
            return nil
        }
    }

    private func postCmdClick() {
        guard let event = CGEvent(source: nil) else {
            log.error("Failed to get cursor position — check Accessibility permission")
            tapState.withLock { $0.postingCmdClick = false }
            return
        }
        let pos = event.location

        guard
            let down = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: pos, mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: pos, mouseButton: .left
            )
        else {
            log.error("Failed to create CGEvent for Cmd+Click")
            tapState.withLock { $0.postingCmdClick = false }
            return
        }

        down.flags = .maskCommand
        mouseUp.flags = .maskCommand
        down.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            mouseUp.post(tap: .cghidEventTap)
            self?.tapState.withLock { $0.postingCmdClick = false }
            log.debug("Cmd+Click posted at (\(pos.x), \(pos.y))")
        }
    }

    private func isLikelyPalm(_ touch: OMSTouchData) -> Bool {
        let margin = edgeMargin
        return touch.position.y < margin || touch.position.y > (1 - margin)
            || touch.position.x < margin || touch.position.x > (1 - margin)
    }

    private func processTouchFrame(_ touches: [OMSTouchData]) {
        // Don't try to interpret gestures while the user is actively typing;
        // palms land on the trackpad between keystrokes and look like multi-finger contacts.
        if keystrokeWindow > 0, Date().timeIntervalSince(lastKeystrokeAt) < keystrokeWindow {
            tapState.withLock { $0.threeFingersTouching = false }
            if trackingTouches { resetThreeFingerTracking() }
            if trackingFourFingers { resetFourFingerTracking() }
            return
        }

        // Click arming runs on a looser predicate than swipe tracking: we want "3 fingers physically
        // down right now" for the 3-finger-click feature, independent of quality/aspect/spread gates
        // that exist to reject noisy swipes. Otherwise tuning swipe filters silently disables clicks.
        let looseClickCount = touches.count(where: { $0.state == .touching && !isLikelyPalm($0) })
        tapState.withLock { $0.threeFingersTouching = (looseClickCount == 3) }

        let activeTouches = touches.filter { touch in
            guard touch.state == .touching else { return false }
            guard touch.total >= touchQualityMin else { return false }
            guard touch.axis.minor > 0.001 else { return false }
            guard (touch.axis.major / touch.axis.minor) <= aspectRatioMax else { return false }
            return !isLikelyPalm(touch)
        }
        let activeCount = activeTouches.count
        let currentIDs = Set(activeTouches.map(\.id))

        if activeCount == 4 {
            consecutiveFourFingerFrames += 1
            consecutiveThreeFingerFrames = 0
            if trackingTouches { resetThreeFingerTracking() }

            if !trackingFourFingers {
                if consecutiveFourFingerFrames >= requiredStableFrames {
                    // Palms plus an adjacent finger cluster tightly; genuine 4-finger gestures spread across X.
                    if fingerSpreadMin > 0 {
                        let xs = activeTouches.map(\.position.x)
                        let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
                        if spread < fingerSpreadMin {
                            consecutiveFourFingerFrames = 0
                            return
                        }
                    }
                    trackingFourFingers = true
                    fourFingerTrackedIDs = currentIDs
                    fourFingerInitialPositions = [:]
                    fourFingerLatestPositions = [:]
                    for touch in activeTouches {
                        fourFingerInitialPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                        fourFingerLatestPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                    }
                    logArmingCharacteristics("4-finger", touches: activeTouches)
                }
            } else if currentIDs == fourFingerTrackedIDs {
                for touch in activeTouches {
                    fourFingerLatestPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                }
            } else {
                resetFourFingerTracking()
            }
        } else if activeCount == 3 {
            consecutiveThreeFingerFrames += 1
            consecutiveFourFingerFrames = 0
            if trackingFourFingers {
                evaluateFourFingerSwipe()
                resetFourFingerTracking()
            }

            if !trackingTouches {
                if consecutiveThreeFingerFrames >= requiredStableFrames {
                    // Palms plus an adjacent finger cluster tightly; genuine 3-finger gestures spread across X.
                    if fingerSpreadMin > 0 {
                        let xs = activeTouches.map(\.position.x)
                        let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
                        if spread < fingerSpreadMin {
                            consecutiveThreeFingerFrames = 0
                            return
                        }
                    }
                    trackingTouches = true
                    trackedFingerIDs = currentIDs
                    initialPositions = [:]
                    latestPositions = [:]
                    for touch in activeTouches {
                        initialPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                        latestPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                    }
                    logArmingCharacteristics("3-finger", touches: activeTouches)
                }
            } else if currentIDs == trackedFingerIDs {
                for touch in activeTouches {
                    latestPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                }
            } else {
                resetThreeFingerTracking()
            }
        } else {
            consecutiveThreeFingerFrames = 0
            consecutiveFourFingerFrames = 0

            if trackingTouches {
                evaluateSwipe()
                resetThreeFingerTracking()
            }
            if trackingFourFingers {
                evaluateFourFingerSwipe()
                resetFourFingerTracking()
            }
        }
    }

    /// Emits one log line per swipe arming with per-touch `total` and aspect ratio.
    /// Use this to calibrate `touchQualityMin` / `aspectRatioMax` against real hardware —
    /// the OMS `total` field has no documented scale so defaults are provisional.
    private func logArmingCharacteristics(_ label: String, touches: [OMSTouchData]) {
        let details = touches.map { touch -> String in
            let aspect = touch.axis.major / max(touch.axis.minor, 0.001)
            return String(format: "total=%.3f aspect=%.2f", touch.total, aspect)
        }.joined(separator: " | ")
        log.info("\(label) armed: \(details)")
    }

    private func evaluateSwipe() {
        guard !initialPositions.isEmpty else { return }

        var totalDX: Float = 0
        var totalDY: Float = 0
        var count: Float = 0

        for (id, initial) in initialPositions {
            guard let latest = latestPositions[id] else { continue }
            totalDX += latest.x - initial.x
            totalDY += latest.y - initial.y
            count += 1
        }

        guard count > 0 else { return }
        let avgDX = totalDX / count
        let avgDY = totalDY / count

        let absX = abs(avgDX)
        let absY = abs(avgDY)

        guard max(absX, absY) >= swipeThreshold else { return }

        let gesture: GestureType = if absX > absY {
            avgDX > 0 ? .threeFingerSwipeRight : .threeFingerSwipeLeft
        } else {
            avgDY > 0 ? .threeFingerSwipeUp : .threeFingerSwipeDown
        }

        fireGesture(gesture)
    }

    private func evaluateFourFingerSwipe() {
        guard !fourFingerInitialPositions.isEmpty else { return }

        var totalDX: Float = 0
        var count: Float = 0

        for (id, initial) in fourFingerInitialPositions {
            guard let latest = fourFingerLatestPositions[id] else { continue }
            totalDX += latest.x - initial.x
            count += 1
        }

        guard count > 0 else { return }
        let avgDX = totalDX / count

        // Only horizontal swipes for space switching
        guard abs(avgDX) >= swipeThreshold else { return }

        let gesture: GestureType = avgDX > 0 ? .fourFingerSwipeRight : .fourFingerSwipeLeft
        fireGesture(gesture)
    }

    private func resetThreeFingerTracking() {
        // Resets swipe tracking only. Click-arming state lives in tapState and is driven by
        // the per-frame loose predicate at the top of processTouchFrame, not by this reset.
        trackingTouches = false
        consecutiveThreeFingerFrames = 0
        initialPositions = [:]
        latestPositions = [:]
        trackedFingerIDs = []
    }

    private func resetFourFingerTracking() {
        trackingFourFingers = false
        consecutiveFourFingerFrames = 0
        fourFingerInitialPositions = [:]
        fourFingerLatestPositions = [:]
        fourFingerTrackedIDs = []
    }

    private func resetTracking() {
        resetThreeFingerTracking()
        resetFourFingerTracking()
    }

    private func fireGesture(_ gesture: GestureType) {
        log.debug("Gesture detected: \(gesture.rawValue)")
        onGesture?(gesture)
    }

    deinit {
        touchTask?.cancel()
    }
}
