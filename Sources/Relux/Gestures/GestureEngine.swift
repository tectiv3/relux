import AppKit
import OpenMultitouchSupport
import os

private let log = Logger(subsystem: "com.relux.app", category: "gesture-engine")

@MainActor
final class GestureEngine {
    var onGesture: ((GestureType) -> Void)?

    private var touchTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var isRunning = false

    // 3-finger tracking state
    private var trackingTouches = false
    private var threeFingersTouching = false
    private var postingCmdClick = false
    private var initialPositions: [Int32: (x: Float, y: Float)] = [:]
    private var latestPositions: [Int32: (x: Float, y: Float)] = [:]
    private var trackedFingerIDs: Set<Int32> = []
    private var consecutiveThreeFingerFrames = 0

    // 4-finger tracking state
    private var trackingFourFingers = false
    private var fourFingerInitialPositions: [Int32: (x: Float, y: Float)] = [:]
    private var fourFingerLatestPositions: [Int32: (x: Float, y: Float)] = [:]
    private var fourFingerTrackedIDs: Set<Int32> = []
    private var consecutiveFourFingerFrames = 0

    /// Tunable via UserDefaults (gesture.stableFrames, gesture.swipeThreshold, gesture.edgeMargin).
    /// Cached to avoid hitting UserDefaults on every touch frame; refreshed via NSUserDefaultsDidChange.
    private(set) var requiredStableFrames: Int = 2
    private(set) var swipeThreshold: Float = 0.15
    private(set) var edgeMargin: Float = 0.05

    private var defaultsObserver: NSObjectProtocol?

    private func reloadTunables() {
        let defaults = UserDefaults.standard
        requiredStableFrames = max(1, defaults.object(forKey: "gesture.stableFrames") as? Int ?? 2)
        swipeThreshold = defaults.object(forKey: "gesture.swipeThreshold") as? Float ?? 0.15
        edgeMargin = defaults.object(forKey: "gesture.edgeMargin") as? Float ?? 0.05
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
            self?.reloadTunables()
        }

        OMSManager.shared.startListening()
        installClickMonitor()

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

        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        OMSManager.shared.stopListening()
        resetTracking()
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.threeFingersTouching, !self.postingCmdClick else { return }
                log.info("3-finger click detected, posting Cmd+Click")
                self.postCmdClick()
            }
        }
    }

    private func postCmdClick() {
        postingCmdClick = true
        threeFingersTouching = false

        guard let event = CGEvent(source: nil) else {
            log.error("Failed to get cursor position — check Accessibility permission")
            postingCmdClick = false
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
            postingCmdClick = false
            return
        }

        down.flags = .maskCommand
        mouseUp.flags = .maskCommand
        down.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            mouseUp.post(tap: .cghidEventTap)
            self?.postingCmdClick = false
            log.debug("Cmd+Click posted at (\(pos.x), \(pos.y))")
        }
    }

    private func isLikelyPalm(_ touch: OMSTouchData) -> Bool {
        let margin = edgeMargin
        return touch.position.y < margin || touch.position.y > (1 - margin)
            || touch.position.x < margin || touch.position.x > (1 - margin)
    }

    private func processTouchFrame(_ touches: [OMSTouchData]) {
        let activeTouches = touches.filter { $0.state == .touching && !isLikelyPalm($0) }
        let activeCount = activeTouches.count
        let currentIDs = Set(activeTouches.map(\.id))

        if activeCount == 4 {
            consecutiveFourFingerFrames += 1
            consecutiveThreeFingerFrames = 0
            threeFingersTouching = false
            if trackingTouches { resetThreeFingerTracking() }

            if !trackingFourFingers {
                if consecutiveFourFingerFrames >= requiredStableFrames {
                    trackingFourFingers = true
                    fourFingerTrackedIDs = currentIDs
                    fourFingerInitialPositions = [:]
                    fourFingerLatestPositions = [:]
                    for touch in activeTouches {
                        fourFingerInitialPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                        fourFingerLatestPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                    }
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
                    trackingTouches = true
                    threeFingersTouching = true
                    trackedFingerIDs = currentIDs
                    initialPositions = [:]
                    latestPositions = [:]
                    for touch in activeTouches {
                        initialPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                        latestPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                    }
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
            threeFingersTouching = false

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
        trackingTouches = false
        threeFingersTouching = false
        postingCmdClick = false
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
