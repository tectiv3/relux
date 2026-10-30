import AppKit
import os

private let log = Logger(subsystem: "com.relux.app", category: "AppActivity")

/// One-shot timer seam. The real implementation is a main-run-loop timer; tests
/// drive time by hand, so every window below is exercised deterministically.
@MainActor
protocol ActivityTimer {
    func cancel()
}

@MainActor
protocol ActivityScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any ActivityTimer
}

@MainActor
final class RunLoopActivityScheduler: ActivityScheduler {
    private final class Token: ActivityTimer {
        private var timer: Timer?
        init(timer: Timer) {
            self.timer = timer
        }

        func cancel() {
            timer?.invalidate()
            timer = nil
        }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any ActivityTimer {
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        return Token(timer: timer)
    }
}

/// Where ambient events come from. Exists so the observer's decisions can be tested
/// without a running workspace, and so `NSWorkspace` observers are held by exactly
/// one object that can unregister them.
@MainActor
protocol AppActivitySource: AnyObject {
    func start(_ handler: @escaping @MainActor (AppActivityObserver.Kind, AppActivityObserver.Signal) -> Void)
    func stop()
}

/// Translates the two `NSWorkspace` notifications into plain values.
@MainActor
final class WorkspaceActivitySource: AppActivitySource {
    private var tokens: [NSObjectProtocol] = []

    func start(_ handler: @escaping @MainActor (AppActivityObserver.Kind, AppActivityObserver.Signal) -> Void) {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, AppActivityObserver.Kind)] = [
            (NSWorkspace.didLaunchApplicationNotification, .launch),
            (NSWorkspace.didActivateApplicationNotification, .activate),
        ]
        for (name, kind) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                let signal = AppActivityObserver.Signal(
                    path: app.bundleURL?.path,
                    bundleIdentifier: app.bundleIdentifier,
                    isRegular: app.activationPolicy == .regular
                )
                MainActor.assumeIsolated { handler(kind, signal) }
            }
            tokens.append(token)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }
}

/// Learns from app activity the panel never saw.
///
/// A raw launch/activation stream is a poor usage signal: login items launch
/// everything at once, `open -a` can launch without the user ever looking, and a
/// launch is immediately followed by the same app activating. The rules below turn
/// the stream into at most one ambient open per app per visit, with the panel's own
/// picks excluded. Only `FrecencyTracker.recordAmbient` is called — this type never
/// touches `learned`.
@MainActor
final class AppActivityObserver {
    enum Kind: Sendable {
        case launch
        case activate
    }

    /// One workspace event, decoded to plain values.
    struct Signal: Sendable, Equatable {
        /// `bundleURL?.path`; also the tracker's identity for apps.
        var path: String?
        var bundleIdentifier: String?
        var isRegular: Bool

        init(path: String?, bundleIdentifier: String? = nil, isRegular: Bool = true) {
            self.path = path
            self.bundleIdentifier = bundleIdentifier
            self.isRegular = isRegular
        }
    }

    enum Timing {
        /// A launch followed by the app activating is one visit, not two.
        static let coalesceWindow: TimeInterval = 10
        /// An activation counts only if the app is still frontmost this much later.
        static let dwellWindow: TimeInterval = 3
        /// The panel already counted the app it just opened.
        static let selfSuppressionWindow: TimeInterval = 5
        /// Login-time auto-launches are the system starting up, not usage.
        static let bootGuard: TimeInterval = 60
    }

    private struct Pending {
        let timer: any ActivityTimer
    }

    private let tracker: FrecencyTracker
    private let ownBundleIdentifier: String
    private let source: any AppActivitySource
    private let clock: @MainActor () -> Date
    private let scheduler: any ActivityScheduler
    private let frontmostPath: @MainActor () -> String?

    private var startedAt: Date?
    private var pending: [String: Pending] = [:]
    private var lastCommitAt: [String: Date] = [:]
    private var suppressedAt: [String: Date] = [:]

    /// Production wiring: `NSWorkspace` notifications, a main-run-loop timer, the
    /// wall clock and the real frontmost app.
    convenience init(
        tracker: FrecencyTracker,
        ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.relux.app"
    ) {
        self.init(
            tracker: tracker,
            ownBundleIdentifier: ownBundleIdentifier,
            source: WorkspaceActivitySource(),
            scheduler: RunLoopActivityScheduler(),
            clock: { Date() },
            frontmostPath: { NSWorkspace.shared.frontmostApplication?.bundleURL?.path }
        )
    }

    /// Every source of time and workspace truth is a seam: the tests drive them.
    init(
        tracker: FrecencyTracker,
        ownBundleIdentifier: String,
        source: any AppActivitySource,
        scheduler: any ActivityScheduler,
        clock: @escaping @MainActor () -> Date,
        frontmostPath: @escaping @MainActor () -> String?
    ) {
        self.tracker = tracker
        self.ownBundleIdentifier = ownBundleIdentifier
        self.source = source
        self.scheduler = scheduler
        self.clock = clock
        self.frontmostPath = frontmostPath
    }

    var isRunning: Bool {
        startedAt != nil
    }

    func start() {
        guard startedAt == nil else { return }
        startedAt = clock()
        source.start { [weak self] kind, signal in
            self?.observe(kind, signal)
        }
        log.debug("ambient app activity observer started")
    }

    func stop() {
        source.stop()
        for event in pending.values {
            event.timer.cancel()
        }
        pending.removeAll()
        startedAt = nil
        log.debug("ambient app activity observer stopped")
    }

    /// Apply the filters and arm a dwell timer. Public so tests can feed signals
    /// without a workspace.
    func observe(_ kind: Kind, _ signal: Signal) {
        let now = clock()
        guard let startedAt else { return }
        guard now.timeIntervalSince(startedAt) >= Timing.bootGuard else { return }
        guard let path = signal.path, !path.isEmpty else { return }
        guard signal.isRegular else { return }
        guard signal.bundleIdentifier != ownBundleIdentifier else { return }
        guard !isSuppressed(path, now: now) else { return }
        // Coalescing: the visit already counted (or is already counting).
        if let lastCommit = lastCommitAt[path], now.timeIntervalSince(lastCommit) < Timing.coalesceWindow {
            return
        }
        // Switching to another app within the dwell window means the previous app was
        // never used; its pending event is dropped rather than committed as frontmost.
        if kind == .activate {
            dropPending(except: path)
        }
        guard pending[path] == nil else { return }

        let timer = scheduler.schedule(after: Timing.dwellWindow) { [weak self] in
            self?.commit(path)
        }
        pending[path] = Pending(timer: timer)
    }

    /// The panel just recorded this app explicitly; background events for it in the
    /// next few seconds are the same usage counted twice.
    func suppress(path: String) {
        guard startedAt != nil else { return }
        let now = clock()
        suppressedAt[path] = now
        if let event = pending.removeValue(forKey: path) {
            event.timer.cancel()
        }
        prune(now: now)
    }

    private func commit(_ path: String) {
        guard pending.removeValue(forKey: path) != nil else { return }
        let now = clock()
        guard frontmostPath() == path else { return }
        guard !isSuppressed(path, now: now) else { return }
        lastCommitAt[path] = now
        tracker.recordAmbient(path: path, now: now)
        prune(now: now)
    }

    private func dropPending(except path: String) {
        let superseded = pending.keys.filter { $0 != path }
        for other in superseded {
            pending.removeValue(forKey: other)?.timer.cancel()
        }
    }

    private func isSuppressed(_ path: String, now: Date) -> Bool {
        guard let suppressed = suppressedAt[path] else { return false }
        return now.timeIntervalSince(suppressed) < Timing.selfSuppressionWindow
    }

    /// Keeps both maps bounded: an entry older than its window can no longer match.
    private func prune(now: Date) {
        lastCommitAt = lastCommitAt.filter { now.timeIntervalSince($0.value) < Timing.coalesceWindow }
        suppressedAt = suppressedAt.filter { now.timeIntervalSince($0.value) < Timing.selfSuppressionWindow }
    }
}
