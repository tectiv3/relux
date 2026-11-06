import ApplicationServices
import XCTest

/// Replays scripted read outcomes and records the bridge calls in order.
@MainActor
final class RecordingAXBridge {
    enum Call: Equatable {
        case read(pid: pid_t)
        case enable(pid: pid_t)
    }

    private(set) var calls: [Call] = []
    private var answers: [SelectionRead]

    init(answers: [SelectionRead]) {
        self.answers = answers
    }

    var bridge: SelectionAXBridge {
        let recorder = self
        return SelectionAXBridge(
            selectedText: { pid in
                await recorder.record(.read(pid: pid))
                return await recorder.nextAnswer()
            },
            enableEnhancedAX: { pid in
                await recorder.record(.enable(pid: pid))
            }
        )
    }

    func record(_ call: Call) {
        calls.append(call)
    }

    /// Once the script runs out every further read reports the tree missing again.
    func nextAnswer() -> SelectionRead {
        answers.isEmpty ? .failed(.noFocusedElement(axError: AXError.noValue.rawValue)) : answers.removeFirst()
    }

    var enables: [pid_t] {
        calls.compactMap { call in
            if case let .enable(pid) = call {
                return pid
            }
            return nil
        }
    }

    var reads: [pid_t] {
        calls.compactMap { call in
            if case let .read(pid) = call {
                return pid
            }
            return nil
        }
    }
}

/// `SelectionCaptureService` is compiled into the test bundle from the app target (see
/// `project.yml`) with its AX bridge injected, so the read → enable-enhanced-AX → backoff-retry
/// policy is covered without an accessibility connection. The real bridge is never constructed here.
///
/// The retry delays are the production ones, so the fully-failing cases below really do wait
/// ~560 ms. That is deliberate: the delay schedule is the thing being bounded, and injecting a
/// clock just to skip the wait would add a test seam to production code that nothing else needs.
final class SelectionCaptureServiceTests: XCTestCase {
    private static let missingTree = SelectionRead.failed(
        .noFocusedElement(axError: AXError.noValue.rawValue)
    )

    @MainActor
    func testReturnsSelectionFromFirstReadWithoutTouchingEnhancedAX() async {
        let recorder = RecordingAXBridge(answers: [.captured("hello")])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let text = await service.capture(from: 1)

        XCTAssertEqual(text, "hello")
        XCTAssertEqual(recorder.calls, [.read(pid: 1)])
    }

    @MainActor
    func testRetriesAfterEnablingEnhancedAX() async {
        let recorder = RecordingAXBridge(answers: [Self.missingTree, .captured("world")])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let text = await service.capture(from: 7)

        XCTAssertEqual(text, "world")
        XCTAssertEqual(recorder.calls, [.read(pid: 7), .enable(pid: 7), .read(pid: 7)])
    }

    /// The whole point of round 2: a failed first attempt must not be answered by one immediate
    /// re-read that races the renderer, and it must not run forever either.
    @MainActor
    func testExhaustsEveryRetryAndStaysInsideTheAnnouncedBudget() async {
        let recorder = RecordingAXBridge(answers: [])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let started = Date()
        let text = await service.capture(from: 2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(text)
        XCTAssertEqual(
            recorder.calls,
            [.read(pid: 2), .enable(pid: 2), .read(pid: 2), .read(pid: 2), .read(pid: 2)]
        )

        let budget = SelectionCaptureService.retryDelaysMilliseconds.reduce(0, +)
        XCTAssertGreaterThanOrEqual(elapsed, Double(budget) / 1000)
        XCTAssertLessThan(elapsed, 1.2, "retry budget must stay bounded")
    }

    /// The schedule itself: three re-reads, strictly increasing, under 600 ms in total.
    func testRetryScheduleIsAscendingAndBounded() {
        let delays = SelectionCaptureService.retryDelaysMilliseconds

        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(Set(delays).count, delays.count)
        XCTAssertLessThan(delays.reduce(0, +), 600)
    }

    /// A focused element that answered with nothing selected is not a missing tree — switching
    /// enhanced AX on would rebuild the app's tree and still capture nothing.
    @MainActor
    func testEmptySelectionDoesNotEnableEnhancedAXOrRetry() async {
        let recorder = RecordingAXBridge(answers: [.failed(.emptySelection)])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let text = await service.capture(from: 6)

        XCTAssertNil(text)
        XCTAssertEqual(recorder.calls, [.read(pid: 6)])
    }

    /// A WebKit element that reports `kAXErrorNoValue` for both selection attributes is the case the
    /// flags exist for, so it must take the enable path even though the element itself answered.
    @MainActor
    func testNoSelectionValueEnablesEnhancedAX() async {
        let recorder = RecordingAXBridge(
            answers: [
                .failed(.noSelectionValue(
                    textError: AXError.noValue.rawValue,
                    markerError: AXError.noValue.rawValue
                )),
                .captured("marked"),
            ]
        )
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let text = await service.capture(from: 8)

        XCTAssertEqual(text, "marked")
        XCTAssertEqual(recorder.calls, [.read(pid: 8), .enable(pid: 8), .read(pid: 8)])
    }

    /// Chromium drops accessibility mode again when it idles, so a later capture that still finds no
    /// focused element must re-run the enable path instead of reporting both-failed for the rest of
    /// the process's lifetime.
    @MainActor
    func testReenablesWhenALaterCaptureStillFindsNoFocusedElement() async {
        let recorder = RecordingAXBridge(answers: [])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        _ = await service.capture(from: 3)
        _ = await service.capture(from: 3)

        XCTAssertEqual(recorder.reads, Array(repeating: 3, count: 8))
        XCTAssertEqual(recorder.enables, [3, 3])
    }

    @MainActor
    func testTracksEachAppIndependently() async {
        let recorder = RecordingAXBridge(
            answers: [Self.missingTree, .captured("four"), Self.missingTree, .captured("five")]
        )
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let four = await service.capture(from: 4)
        let five = await service.capture(from: 5)

        XCTAssertEqual(four, "four")
        XCTAssertEqual(five, "five")
        XCTAssertEqual(
            recorder.calls,
            [
                .read(pid: 4), .enable(pid: 4), .read(pid: 4),
                .read(pid: 5), .enable(pid: 5), .read(pid: 5),
            ]
        )
    }

    /// Two panel opens racing for the same app each run the full retry: the old once-per-lifetime
    /// suppression is gone, so the cost is that the opt-in is written twice, not that one of the two
    /// captures silently gives up.
    @MainActor
    func testConcurrentCapturesForTheSameAppBothRetry() async {
        let recorder = RecordingAXBridge(answers: [])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        async let first = service.capture(from: 11)
        async let second = service.capture(from: 11)
        let results = await [first, second]

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertEqual(recorder.enables, [11, 11])
        XCTAssertEqual(recorder.reads.count, 8)
    }

    // MARK: - Route selection

    /// Which apps take the synthesized-⌘C route is the routing decision `AppDelegate` makes before
    /// the panel is shown. The list is now a user setting, so the predicate is exercised against
    /// explicit sets.
    func testClipboardOnlyBundleIDs() {
        let apps: Set = ["com.google.Chrome", "com.brave.Browser", "ru.keepcoder.Telegram"]

        XCTAssertTrue(SelectionCapture.isClipboardOnly("com.google.Chrome", in: apps))
        XCTAssertTrue(SelectionCapture.isClipboardOnly("com.brave.Browser", in: apps))
        XCTAssertTrue(SelectionCapture.isClipboardOnly("ru.keepcoder.Telegram", in: apps))
        XCTAssertFalse(SelectionCapture.isClipboardOnly("com.apple.Safari", in: apps))
        XCTAssertFalse(SelectionCapture.isClipboardOnly(nil, in: apps))

        // A list the user emptied routes nothing through ⌘C.
        XCTAssertFalse(SelectionCapture.isClipboardOnly("com.google.Chrome", in: []))
        XCTAssertFalse(SelectionCapture.isClipboardOnly(nil, in: []))

        // A user-added app is honoured without any built-in knowledge of it.
        XCTAssertTrue(SelectionCapture.isClipboardOnly("com.example.editor", in: ["com.example.editor"]))
    }

    /// The upgrade contract: a user who never opened settings has no stored list, so the seeded
    /// default must keep routing the apps that always took the ⌘C route.
    func testSeededDefaultStillRoutesTheChromiumAndTelegramApps() {
        let seeded = Set(SettingsStore.defaultClipboardOnlySelectionApps)

        XCTAssertTrue(SelectionCapture.isClipboardOnly("com.google.Chrome", in: seeded))
        XCTAssertTrue(SelectionCapture.isClipboardOnly("ru.keepcoder.Telegram", in: seeded))
        XCTAssertFalse(SelectionCapture.isClipboardOnly("com.apple.Safari", in: seeded))
    }
}
