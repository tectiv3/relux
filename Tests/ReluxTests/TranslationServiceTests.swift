import ReluxCore
import XCTest

/// `TranslationService` is compiled into the test bundle from the app target (see `project.yml`),
/// so these tests drive the real store against `:memory:` with an injected chunk stream —
/// no API key, no network, no view.
final class TranslationServiceTests: XCTestCase {
    /// Hands out one `AsyncStream` the test drives chunk by chunk.
    @MainActor
    private final class ControlledStream {
        let stream: AsyncStream<String>
        let continuation: AsyncStream<String>.Continuation
        private(set) var requests: [(text: String, language: String)] = []

        init() {
            (stream, continuation) = AsyncStream<String>.makeStream()
        }

        func provider() -> TranslationService.StreamProvider {
            { [self] text, language in
                requests.append((text, language))
                return stream
            }
        }
    }

    @MainActor
    private func makeService(
        stream: @escaping TranslationService.StreamProvider
    ) throws -> (database: SQLiteDatabase, store: TranslateStore, service: TranslationService) {
        let database = try SQLiteDatabase(path: ":memory:")
        try ReluxSchema.migrate(database)
        let store = TranslateStore(db: database)
        let service = TranslationService(store: store, model: { "test-model" }, stream: stream)
        return (database, store, service)
    }

    @MainActor
    private func insert(
        _ source: String,
        _ translated: String,
        into store: TranslateStore
    ) throws -> Int64 {
        try store.insert(
            sourceText: source,
            translatedText: translated,
            sourceLang: nil,
            targetLang: "ja",
            model: "test-model"
        )
    }

    /// Polls rather than sleeping a fixed interval, so the assertion is on state, not timing.
    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1000 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("condition never became true", file: file, line: line)
    }

    // MARK: - Streaming lifecycle

    @MainActor
    func testStreamsChunksIntoStoredEntry() async throws {
        let control = ControlledStream()
        let (_, store, service) = try makeService(stream: control.provider())
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(service.entries.isEmpty)

        let run = Task { await service.translate("  hello  ", targetLanguage: "ja") }

        await waitUntil { service.isTranslating }
        XCTAssertEqual(service.state, .streaming(partial: ""))
        XCTAssertTrue(service.streamedText.isEmpty)
        XCTAssertEqual(control.requests.first?.text, "hello")
        XCTAssertEqual(control.requests.first?.language, "ja")

        // Optimistic row: inserted empty, kept out of the list until the run ends, and invisible
        // to dedup while its translation is still empty.
        let rowId = try XCTUnwrap(store.fetchAll().first?.id)
        XCTAssertEqual(store.fetchAll().first?.translatedText, "")
        XCTAssertEqual(service.entries.count, 0)
        XCTAssertNil(store.findByHash(TranslationEntry.hash(source: "hello", target: "ja")))

        control.continuation.yield("Bon")
        await waitUntil { service.state == .streaming(partial: "Bon") }
        control.continuation.yield("jour")
        await waitUntil { service.state == .streaming(partial: "Bonjour") }
        XCTAssertEqual(service.streamedText, "Bonjour")

        control.continuation.finish()
        await run.value

        XCTAssertEqual(service.state, .stored(entryId: rowId))
        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(service.entries.first?.translatedText, "Bonjour")
        XCTAssertEqual(service.entries.first?.model, "test-model")
        XCTAssertEqual(store.fetchAll().first?.translatedText, "Bonjour")
    }

    @MainActor
    func testDedupHitReusesExistingEntryWithoutStreaming() async throws {
        let control = ControlledStream()
        let (database, store, service) = try makeService(stream: control.provider())
        let existing = try insert("hello", "bonjour", into: store)
        _ = try insert("other", "autre", into: store)
        try database.execute("UPDATE translation_history SET updated_at = 1000 WHERE id = \(existing)")
        XCTAssertEqual(store.fetchAll().map(\.sourceText), ["other", "hello"])

        service.reload()
        await service.translate("hello", targetLanguage: "ja")

        XCTAssertEqual(service.state, .stored(entryId: existing))
        XCTAssertTrue(control.requests.isEmpty)
        XCTAssertEqual(store.fetchAll().count, 2)
        // The bump puts the reused entry back on top of the history.
        XCTAssertEqual(service.entries.map(\.sourceText), ["hello", "other"])
    }

    @MainActor
    func testRetranslateRewritesTheSameRowWithoutInserting() async throws {
        let control = ControlledStream()
        let (_, store, service) = try makeService(stream: control.provider())
        let id = try store.insert(
            sourceText: "hello",
            translatedText: "old",
            sourceLang: "en",
            targetLang: "ja",
            model: "test-model"
        )
        service.reload()
        let entry = try XCTUnwrap(service.entries.first)

        let run = Task { await service.retranslate(entry) }
        await waitUntil { service.isTranslating }
        control.continuation.yield("new")
        await waitUntil { service.state == .streaming(partial: "new") }
        control.continuation.finish()
        await run.value

        XCTAssertEqual(service.state, .stored(entryId: id))
        let rows = store.fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.translatedText, "new")
        XCTAssertEqual(rows.first?.sourceLang, "en")
        XCTAssertEqual(control.requests.first?.text, "hello")
        XCTAssertEqual(control.requests.first?.language, "ja")
    }

    // MARK: - Cancellation

    @MainActor
    func testCancelMidStreamKeepsThePartialRow() async throws {
        let control = ControlledStream()
        let (_, store, service) = try makeService(stream: control.provider())

        let run = Task { await service.translate("hello", targetLanguage: "ja") }
        await waitUntil { service.isTranslating }
        let rowId = try XCTUnwrap(store.fetchAll().first?.id)

        control.continuation.yield("par")
        await waitUntil { service.state == .streaming(partial: "par") }

        service.cancel()
        await waitUntil { !service.isTranslating }
        await run.value

        // Cancelling keeps the partial row (the old behaviour) instead of deleting it.
        XCTAssertEqual(service.state, .stored(entryId: rowId))
        XCTAssertEqual(service.entries.first?.translatedText, "par")
        XCTAssertEqual(store.fetchAll().first?.translatedText, "par")
        // The consumer's cancellation terminated the stream, so nothing can arrive later.
        guard case .terminated = control.continuation.yield("tial") else {
            return XCTFail("cancelling the consumer should terminate the stream")
        }
        XCTAssertEqual(store.fetchAll().first?.translatedText, "par")
    }

    @MainActor
    func testStartingASecondTranslationSupersedesTheFirst() async throws {
        let first = ControlledStream()
        let second = ControlledStream()
        var requested: [String] = []
        let (_, store, service) = try makeService { text, _ in
            requested.append(text)
            return text == "first" ? first.stream : second.stream
        }

        let runOne = Task { await service.translate("first", targetLanguage: "ja") }
        await waitUntil { requested == ["first"] && service.isTranslating }
        first.continuation.yield("one")
        await waitUntil { service.state == .streaming(partial: "one") }

        let runTwo = Task { await service.translate("second", targetLanguage: "ja") }
        await waitUntil { requested.count == 2 && service.isTranslating }
        second.continuation.yield("two")
        await waitUntil { service.state == .streaming(partial: "two") }

        // The superseded run finishes its own row but must not clear the live run's state.
        await runOne.value
        XCTAssertEqual(service.state, .streaming(partial: "two"))
        XCTAssertEqual(store.fetchAll().count, 2)

        second.continuation.finish()
        await runTwo.value

        XCTAssertEqual(service.entries.map(\.sourceText), ["second", "first"])
        XCTAssertEqual(service.entries.first?.translatedText, "two")
        XCTAssertEqual(store.fetchAll().first(where: { $0.sourceText == "first" })?.translatedText, "one")
    }

    // MARK: - Failures

    @MainActor
    func testStoreFailureSurfacesAsFailedState() async throws {
        let control = ControlledStream()
        let (database, store, service) = try makeService(stream: control.provider())
        try database.execute("DROP TABLE translation_history")

        await service.translate("hello", targetLanguage: "ja")

        guard case let .failed(message) = service.state else {
            return XCTFail("expected a failed state, got \(service.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(control.requests.isEmpty)
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertTrue(store.fetchAll().isEmpty)
    }

    // MARK: - Delete

    @MainActor
    func testDeleteRemovesRowAndReloadsEntries() throws {
        let control = ControlledStream()
        let (_, store, service) = try makeService(stream: control.provider())
        let id = try insert("hello", "bonjour", into: store)
        service.reload()
        XCTAssertEqual(service.entries.count, 1)

        service.delete(entryId: id)

        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertTrue(store.fetchAll().isEmpty)
        // A missing id stays a silent no-op, as the view's `try?` was.
        service.delete(entryId: 9999)
        XCTAssertTrue(service.entries.isEmpty)
    }
}
