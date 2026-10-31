import XCTest

/// Replays scripted answers per read and records the bridge calls in order.
@MainActor
final class RecordingAXBridge {
    enum Call: Equatable {
        case read(pid: pid_t)
        case enable(pid: pid_t)
    }

    private(set) var calls: [Call] = []
    private var answers: [String?]

    init(answers: [String?]) {
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

    /// Once the script runs out every further read reports "no selection".
    func nextAnswer() -> String? {
        answers.isEmpty ? nil : answers.removeFirst()
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
/// `project.yml`) with its AX bridge injected, so the read → enable-enhanced-AX → retry policy is
/// covered without an accessibility connection. The real bridge is never constructed here.
final class SelectionCaptureServiceTests: XCTestCase {
    @MainActor
    func testReturnsSelectionFromFirstReadWithoutTouchingEnhancedAX() async {
        let recorder = RecordingAXBridge(answers: ["hello"])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let text = await service.capture(from: 1)

        XCTAssertEqual(text, "hello")
        XCTAssertEqual(recorder.calls, [.read(pid: 1)])
    }

    @MainActor
    func testRetriesOnceAfterEnablingEnhancedAX() async {
        let recorder = RecordingAXBridge(answers: [nil, "world"])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let text = await service.capture(from: 7)

        XCTAssertEqual(text, "world")
        XCTAssertEqual(recorder.calls, [.read(pid: 7), .enable(pid: 7), .read(pid: 7)])
    }

    @MainActor
    func testReturnsNilWhenTheRetryFindsNothing() async {
        let recorder = RecordingAXBridge(answers: [nil, nil])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        let text = await service.capture(from: 2)

        XCTAssertNil(text)
        XCTAssertEqual(recorder.calls, [.read(pid: 2), .enable(pid: 2), .read(pid: 2)])
    }

    /// The enhanced-AX switch rebuilds the target's tree, so it must happen once per app, not on
    /// every panel open — the second capture only reads.
    @MainActor
    func testEnablesEnhancedAXOnlyOncePerApp() async {
        let recorder = RecordingAXBridge(answers: [nil, nil])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        _ = await service.capture(from: 3)
        _ = await service.capture(from: 3)

        XCTAssertEqual(
            recorder.calls,
            [.read(pid: 3), .enable(pid: 3), .read(pid: 3), .read(pid: 3)]
        )
        XCTAssertEqual(recorder.enables, [3])
    }

    @MainActor
    func testTracksEachAppIndependently() async {
        let recorder = RecordingAXBridge(answers: [nil, nil, nil, nil])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        _ = await service.capture(from: 4)
        _ = await service.capture(from: 5)

        XCTAssertEqual(
            recorder.calls,
            [
                .read(pid: 4), .enable(pid: 4), .read(pid: 4),
                .read(pid: 5), .enable(pid: 5), .read(pid: 5),
            ]
        )
        XCTAssertEqual(recorder.enables, [4, 5])
    }

    /// Two panel opens racing for the same app must still switch enhanced AX on exactly once —
    /// this is the property the old lock on the static pid set provided.
    @MainActor
    func testConcurrentCapturesEnableEnhancedAXOnce() async {
        let recorder = RecordingAXBridge(answers: [nil, nil, nil])
        let service = SelectionCaptureService(bridge: recorder.bridge)

        async let first = service.capture(from: 11)
        async let second = service.capture(from: 11)
        let results = await [first, second]

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertEqual(recorder.enables, [11])
        XCTAssertEqual(recorder.reads, [11, 11, 11])
    }

    // MARK: - Route selection

    /// Which apps take the synthesized-⌘C route is the routing decision `AppDelegate` makes before
    /// the panel is shown.
    func testClipboardOnlyBundleIDs() {
        XCTAssertTrue(SelectionCapture.isClipboardOnly("com.google.Chrome"))
        XCTAssertTrue(SelectionCapture.isClipboardOnly("com.brave.Browser"))
        XCTAssertTrue(SelectionCapture.isClipboardOnly("ru.keepcoder.Telegram"))
        XCTAssertFalse(SelectionCapture.isClipboardOnly("com.apple.Safari"))
        XCTAssertFalse(SelectionCapture.isClipboardOnly("com.apple.TextEdit"))
        XCTAssertFalse(SelectionCapture.isClipboardOnly(nil))
    }
}
