import Foundation
import ReluxCore
import XCTest

/// Pinned clock driven by the tests, never by the wall clock.
@MainActor
private final class FakeClock {
    var now: Date
    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
private final class ManualTimer: ActivityTimer {
    private(set) var isCancelled = false
    func cancel() {
        isCancelled = true
    }
}

/// Records scheduled timers and fires them only when the test advances time.
@MainActor
private final class ManualScheduler: ActivityScheduler {
    private final class Entry {
        let due: Date
        let action: @MainActor () -> Void
        let token: ManualTimer
        init(due: Date, action: @escaping @MainActor () -> Void, token: ManualTimer) {
            self.due = due
            self.action = action
            self.token = token
        }
    }

    private let clock: FakeClock
    private var entries: [Entry] = []

    init(clock: FakeClock) {
        self.clock = clock
    }

    var liveTimerCount: Int {
        entries.filter { !$0.token.isCancelled }.count
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any ActivityTimer {
        let token = ManualTimer()
        entries.append(Entry(due: clock.now.addingTimeInterval(delay), action: action, token: token))
        return token
    }

    /// Moves the clock, then runs every timer that came due, earliest first.
    func advance(by interval: TimeInterval) {
        clock.now = clock.now.addingTimeInterval(interval)
        while true {
            entries.sort { $0.due < $1.due }
            guard let index = entries.firstIndex(where: { $0.due <= clock.now }) else { return }
            let entry = entries.remove(at: index)
            guard !entry.token.isCancelled else { continue }
            entry.action()
        }
    }
}

/// Stands in for `NSWorkspace`'s notification center.
@MainActor
private final class FakeActivitySource: AppActivitySource {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(_: @escaping @MainActor (AppActivityObserver.Kind, AppActivityObserver.Signal) -> Void) {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FrontmostProbe {
    /// What `NSWorkspace.shared.frontmostApplication` would answer at commit time.
    var path: String?
}

@MainActor
private final class Harness {
    static let pathA = "/Applications/Alpha.app"
    static let pathB = "/Applications/Beta.app"
    static let bundleA = "com.example.alpha"
    static let bundleB = "com.example.beta"
    static let ownBundle = "com.relux.app"

    let clock: FakeClock
    let scheduler: ManualScheduler
    let source: FakeActivitySource
    let frontmost: FrontmostProbe
    let tracker: FrecencyTracker
    let observer: AppActivityObserver
    private let directory: URL

    init() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = FakeClock(start)
        let scheduler = ManualScheduler(clock: clock)
        let source = FakeActivitySource()
        let frontmost = FrontmostProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReluxActivityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tracker = FrecencyTracker(directory: directory, now: start)
        let observer = AppActivityObserver(
            tracker: tracker,
            ownBundleIdentifier: Self.ownBundle,
            source: source,
            scheduler: scheduler,
            clock: { clock.now },
            frontmostPath: { frontmost.path }
        )

        self.clock = clock
        self.scheduler = scheduler
        self.source = source
        self.frontmost = frontmost
        self.directory = directory
        self.tracker = tracker
        self.observer = observer
    }

    func cleanUp() {
        observer.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Starts the observer and advances past the boot guard, so the test's events
    /// are the only thing the observer reacts to.
    func startPastBootGuard() {
        observer.start()
        scheduler.advance(by: AppActivityObserver.Timing.bootGuard + 1)
    }

    func advance(_ interval: TimeInterval) {
        scheduler.advance(by: interval)
    }

    func signal(_ path: String, bundle: String, isRegular: Bool = true) -> AppActivityObserver.Signal {
        AppActivityObserver.Signal(path: path, bundleIdentifier: bundle, isRegular: isRegular)
    }

    func ambientOpens(_ path: String) -> Int {
        tracker.appUsage(query: "", path: path, now: clock.now).ambientOpens
    }
}

@MainActor
final class AppActivityObserverTests: XCTestCase {
    func testLaunchThenActivationWithinTheCoalesceWindowCountsOnce() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        harness.observer.observe(.launch, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(1)
        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 1)

        // Still the same visit: another activation inside the coalesce window is free.
        harness.advance(2)
        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 1)
        XCTAssertEqual(harness.scheduler.liveTimerCount, 0, "no timer may stay armed after a commit")
    }

    func testActivationThatIsNotFrontmostAfterTheDwellWindowDoesNotCount() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        // The user switched away before the dwell window elapsed.
        harness.frontmost.path = Harness.pathB
        harness.advance(AppActivityObserver.Timing.dwellWindow)

        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)
    }

    func testActivationThatStaysFrontmostThroughTheDwellWindowCountsOnce() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow - 1)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0, "commit happens at the window, not before")
        harness.advance(1)

        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 1)
        // Ambient observations must never look like a panel pick.
        let state = harness.tracker.appUsage(query: "alp", path: Harness.pathA, now: harness.clock.now)
        XCTAssertEqual(state.explicitOpens, 0)
        XCTAssertFalse(state.lastPick)
    }

    func testPendingActivationSupersededByAnotherAppIsDropped() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()

        harness.frontmost.path = Harness.pathA
        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(1)

        harness.frontmost.path = Harness.pathB
        harness.observer.observe(.activate, harness.signal(Harness.pathB, bundle: Harness.bundleB))
        // Only B's dwell timer may remain armed; A's was dropped, not left to fire.
        XCTAssertEqual(harness.scheduler.liveTimerCount, 1)
        harness.advance(AppActivityObserver.Timing.dwellWindow - 1)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0, "A never became the visit")
        harness.advance(1)

        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)
        XCTAssertEqual(harness.ambientOpens(Harness.pathB), 1)
    }

    func testSelfSuppressionWindowIgnoresTheAppThePanelJustOpened() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        // The panel recorded the pick, so it is suppressed from this instant.
        harness.observer.suppress(path: Harness.pathA)
        harness.advance(1)
        harness.observer.observe(.launch, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow + 1)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)

        // Once the window passes, real activity counts again.
        harness.advance(AppActivityObserver.Timing.selfSuppressionWindow)
        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 1)
    }

    func testSuppressionCancelsAnAlreadyPendingEvent() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        // Launch observed first (Dock double-click), then the panel pick it caused
        // arrives before the dwell window closes.
        harness.observer.observe(.launch, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(1)
        harness.observer.suppress(path: Harness.pathA)
        harness.advance(AppActivityObserver.Timing.dwellWindow)

        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)
        XCTAssertEqual(harness.scheduler.liveTimerCount, 0, "the cancelled dwell timer must be gone")
    }

    func testBootGuardIgnoresLoginTimeLaunches() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.observer.start()
        harness.frontmost.path = Harness.pathA

        harness.advance(AppActivityObserver.Timing.bootGuard - 1)
        harness.observer.observe(.launch, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)

        harness.advance(1) // now past the guard
        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 1)
    }

    func testNonRegularAppIsIgnored() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        harness.observer.observe(
            .activate,
            harness.signal(Harness.pathA, bundle: Harness.bundleA, isRegular: false)
        )
        harness.advance(AppActivityObserver.Timing.dwellWindow)

        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)
        XCTAssertEqual(harness.scheduler.liveTimerCount, 0)
    }

    func testAppWithoutABundleURLIsIgnored() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()

        harness.observer.observe(.activate, .init(path: nil, bundleIdentifier: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow)

        XCTAssertEqual(harness.scheduler.liveTimerCount, 0)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)
    }

    func testReluxItselfIsIgnored() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.ownBundle))
        harness.advance(AppActivityObserver.Timing.dwellWindow)

        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)
        XCTAssertEqual(harness.scheduler.liveTimerCount, 0)
    }

    func testStopUnregistersTheSourceAndDropsPendingWork() {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.startPastBootGuard()
        harness.frontmost.path = Harness.pathA

        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.observer.stop()

        XCTAssertEqual(harness.source.stopCount, 1)
        XCTAssertFalse(harness.observer.isRunning)
        XCTAssertEqual(harness.scheduler.liveTimerCount, 0)

        harness.advance(AppActivityObserver.Timing.dwellWindow)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)

        // Events arriving after teardown are no-ops, not crashes.
        harness.observer.observe(.activate, harness.signal(Harness.pathA, bundle: Harness.bundleA))
        harness.advance(AppActivityObserver.Timing.dwellWindow)
        XCTAssertEqual(harness.ambientOpens(Harness.pathA), 0)
    }
}
