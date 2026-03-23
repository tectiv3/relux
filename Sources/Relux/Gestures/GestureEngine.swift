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

    // Tracking state
    private var trackingTouches = false
    private var threeFingersTouching = false
    private var initialPositions: [Int32: (x: Float, y: Float)] = [:]
    private var latestPositions: [Int32: (x: Float, y: Float)] = [:]
    private var trackedFingerIDs: Set<Int32> = []

    // Stability: require N consecutive frames with exactly 3 fingers before tracking
    private var consecutiveThreeFingerFrames = 0
    private let requiredStableFrames = 4

    private let swipeThreshold: Float = 0.15

    func start() {
        guard !isRunning else { return }
        isRunning = true
        log.info("Gesture engine starting")

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
                guard let self, self.threeFingersTouching else { return }
                self.fireGesture(.threeFingerClick)
            }
        }
    }

    private func processTouchFrame(_ touches: [OMSTouchData]) {
        let activeTouches = touches.filter { $0.state == .touching }
        let activeCount = activeTouches.count
        let currentIDs = Set(activeTouches.map(\.id))

        if activeCount == 3 {
            consecutiveThreeFingerFrames += 1

            if !trackingTouches {
                if consecutiveThreeFingerFrames >= requiredStableFrames {
                    // Stable 3-finger contact — start tracking
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
                // Same 3 fingers still touching — update positions
                for touch in activeTouches {
                    latestPositions[touch.id] = (x: touch.position.x, y: touch.position.y)
                }
            } else {
                // Different finger IDs — abort tracking
                resetTracking()
            }
        } else {
            consecutiveThreeFingerFrames = 0
            threeFingersTouching = false

            if trackingTouches {
                evaluateSwipe()
                resetTracking()
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

        let gesture: GestureType
        if absX > absY {
            gesture = avgDX > 0 ? .threeFingerSwipeRight : .threeFingerSwipeLeft
        } else {
            gesture = avgDY > 0 ? .threeFingerSwipeUp : .threeFingerSwipeDown
        }

        fireGesture(gesture)
    }

    private func resetTracking() {
        trackingTouches = false
        consecutiveThreeFingerFrames = 0
        initialPositions = [:]
        latestPositions = [:]
        trackedFingerIDs = []
    }

    private func fireGesture(_ gesture: GestureType) {
        log.debug("Gesture detected: \(gesture.rawValue)")
        onGesture?(gesture)
    }

    deinit {
        touchTask?.cancel()
    }
}
