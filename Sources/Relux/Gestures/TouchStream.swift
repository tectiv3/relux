import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.relux.app", category: "touch-stream")

struct TouchPosition: Sendable {
    var x: Float
    var y: Float
}

struct TouchAxis: Sendable {
    var major: Float
    var minor: Float
}

enum TouchState: Sendable, Equatable {
    case notTouching
    case starting
    case hovering
    case making
    case touching
    case breaking
    case lingering
    case leaving

    /// Maps the private MultitouchSupport state integer (0...7) to a Swift case.
    init?(_ rawState: Int32) {
        switch rawState {
        case 0: self = .notTouching
        case 1: self = .starting
        case 2: self = .hovering
        case 3: self = .making
        case 4: self = .touching
        case 5: self = .breaking
        case 6: self = .lingering
        case 7: self = .leaving
        default: return nil
        }
    }
}

struct TouchData: Sendable {
    var id: Int32
    var position: TouchPosition
    var total: Float
    var pressure: Float
    var axis: TouchAxis
    var state: TouchState
}

/// Receives contact frames from the private MultitouchSupport.framework through
/// the C bridge and republishes them as an AsyncStream of Swift value types.
///
/// `@unchecked Sendable`: frame callbacks run on the MultitouchSupport device
/// thread while start/stop run on the main actor. All shared state is guarded by
/// locks; the frame path never touches actor-isolated state.
final class TouchStream: @unchecked Sendable {
    private let continuationLock = OSAllocatedUnfairLock(
        initialState: [UUID: AsyncStream<[TouchData]>.Continuation]()
    )
    private let wasRunningBeforeSleep = OSAllocatedUnfairLock(initialState: false)
    private nonisolated(unsafe) var sleepObservers: [NSObjectProtocol] = []

    /// Same shape as the old OMSManager.touchDataStream: a fresh stream per
    /// subscriber, fed by the shared C callback.
    var stream: AsyncStream<[TouchData]> {
        AsyncStream { continuation in
            let id = UUID()
            continuationLock.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.continuationLock.withLock { $0[id] = nil }
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        installSleepObserversIfNeeded()
        let started = startDevice()
        if started {
            log.info("Touch stream started")
        } else {
            log.error("Touch stream unavailable — MultitouchSupport.framework not usable")
        }
        return started
    }

    func stop() {
        guard ReluxTouchIsRunning() else { return }
        ReluxTouchStop()
        log.info("Touch stream stopped")
    }

    @discardableResult
    private func startDevice() -> Bool {
        guard !ReluxTouchIsRunning() else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        return ReluxTouchStart(reluxTouchFrameHandler, context)
    }

    /// The trackpad device handle is invalidated across sleep/wake, so mirror
    /// the old OMS behavior: tear down on sleep, rebuild on wake if we were live.
    private func installSleepObserversIfNeeded() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let running = ReluxTouchIsRunning()
            wasRunningBeforeSleep.withLock { $0 = running }
            if running {
                ReluxTouchStop()
            }
        }
        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let shouldRestart = wasRunningBeforeSleep.withLock { $0 }
            wasRunningBeforeSleep.withLock { $0 = false }
            if shouldRestart {
                _ = startDevice()
            }
        }
        sleepObservers = [willSleep, didWake]
    }

    /// Runs on the MultitouchSupport device thread. Must not touch actor-isolated state.
    fileprivate func handleFrame(touches: UnsafePointer<ReluxTouch>?, count: Int32) {
        var frame: [TouchData] = []
        if let touches, count > 0 {
            frame.reserveCapacity(Int(count))
            for index in 0 ..< Int(count) {
                let touch = touches[index]
                guard let state = TouchState(touch.state) else { continue }
                frame.append(
                    TouchData(
                        id: touch.identifier,
                        position: TouchPosition(x: touch.x, y: touch.y),
                        total: touch.total,
                        pressure: touch.pressure,
                        axis: TouchAxis(major: touch.majorAxis, minor: touch.minorAxis),
                        state: state
                    )
                )
            }
        }
        let continuations = continuationLock.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(frame)
        }
    }

    deinit {
        ReluxTouchStop()
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            center.removeObserver(observer)
        }
    }
}

/// Stable single C function pointer shared by start and stop. It captures no
/// state; the owning TouchStream is carried through the opaque context pointer.
private nonisolated(unsafe) let reluxTouchFrameHandler: ReluxTouchFrameHandler = { context, touches, count, _ in
    guard let context else { return }
    let stream = Unmanaged<TouchStream>.fromOpaque(context).takeUnretainedValue()
    stream.handleFrame(touches: touches, count: count)
}
