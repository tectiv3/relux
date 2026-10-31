import ReluxCore
import XCTest

/// `ClipboardListModel` is the panel's state: it is compiled into the test bundle through
/// `project.yml` and exercised against a real `:memory:` store, with the pasteboard side
/// effects replaced by a recorder.
final class ClipboardListModelTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> (database: SQLiteDatabase, store: ClipboardStore) {
        let database = try SQLiteDatabase(path: ":memory:")
        try ReluxSchema.migrate(database)
        return try (database, ClipboardStore(db: database))
    }

    @discardableResult
    @MainActor
    private func insertText(
        _ text: String,
        sourceName: String? = nil,
        contentType: String = ContentType.text,
        into store: ClipboardStore
    ) throws -> ClipboardEntry {
        try store.insert(
            contentType: contentType,
            textContent: text,
            rawData: nil,
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
            imageSize: nil,
            sourceApp: nil,
            sourceName: sourceName
        )
        return try XCTUnwrap(store.fetchAll().first { $0.textContent == text })
    }

    @discardableResult
    @MainActor
    private func insertImage(path: String?, into store: ClipboardStore) throws -> ClipboardEntry {
        try store.insert(
            contentType: ContentType.image,
            textContent: nil,
            rawData: nil,
            imagePath: path,
            imageWidth: 4,
            imageHeight: 3,
            imageSize: 12,
            sourceApp: nil,
            sourceName: nil
        )
        return try XCTUnwrap(store.fetchAll().first { $0.contentType == ContentType.image })
    }

    @MainActor
    private final class BoardRecorder {
        var pastedText: [(text: String, richText: Data?)] = []
        var pastedImages: [URL] = []
        var copiedText: [(text: String, richText: Data?)] = []
        var dismissals = 0

        var board: ClipboardBoard {
            ClipboardBoard(
                pasteText: { [self] text, richText in pastedText.append((text, richText)) },
                pasteImage: { [self] url in pastedImages.append(url) },
                copyText: { [self] text, richText in copiedText.append((text, richText)) },
                dismissPanel: { [self] in dismissals += 1 }
            )
        }
    }

    // MARK: - Filtering

    /// Search goes through the trigram FTS index, so any substring of three characters or more
    /// matches across the entire retained history, in the body or in the source app name.
    @MainActor
    func testSearchMatchesSubstringsAnywhereInTheRow() throws {
        let (_, store) = try makeStore()
        let deploy = try insertText("deploy the build\nsecond line", into: store)
        try insertText("unrelated body", into: store)
        let safari = try insertText("x", sourceName: "Safari", into: store)

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.entries.count, 3, "an empty query keeps every row")

        model.searchText = "depl"
        XCTAssertEqual(model.filteredEntries.map(\.id), [deploy.id], "a leading substring matches")

        model.searchText = "eplo"
        XCTAssertEqual(model.filteredEntries.map(\.id), [deploy.id], "a substring from inside a word matches")

        model.searchText = "second"
        XCTAssertEqual(model.filteredEntries.map(\.id), [deploy.id], "the whole body is searchable, not just line one")

        model.searchText = "Saf"
        XCTAssertEqual(model.filteredEntries.map(\.id), [safari.id], "the source app name is indexed too")

        model.searchText = "  DEPL  "
        XCTAssertEqual(model.filteredEntries.map(\.id), [deploy.id], "the query is trimmed and folded")

        model.searchText = "zzzz"
        XCTAssertTrue(model.filteredEntries.isEmpty)
        XCTAssertNil(model.selectedEntry)
    }

    /// A query the trigram index cannot answer — any term below three characters — falls back to
    /// the in-memory page filter, which is the only path that matches a shorter substring.
    @MainActor
    func testShortQueryFallsBackToThePageFilter() throws {
        let (_, store) = try makeStore()
        let row = try insertText("grab the cab", into: store)
        try insertText("unrelated text", into: store)

        XCTAssertNil(store.search(matching: "ab"), "the store cannot answer a two-character query")

        let model = ClipboardListModel(store: store)
        model.reload()
        model.searchText = "ab"
        XCTAssertEqual(model.filteredEntries.map(\.id), [row.id], "the page filter still finds the row")
    }

    /// Images are stored without text, so `type: .image` plus a query legitimately matches nothing.
    /// The copy has to say that instead of implying the history holds no images.
    @MainActor
    func testImageFilterWithAQueryExplainsThatImagesHaveNoText() throws {
        let (_, store) = try makeStore()
        let image = try insertImage(path: "a.png", into: store)
        try insertText("some text", into: store)

        let model = ClipboardListModel(store: store)
        model.reload()
        model.setTypeFilter(.image)
        XCTAssertEqual(model.filteredEntries.map(\.id), [image.id], "the filter alone shows the image")

        model.searchText = "photo"
        XCTAssertTrue(model.filteredEntries.isEmpty, "nothing in an image can be matched by a text query")
        XCTAssertEqual(model.entries.count, 2, "the history is not empty")
        XCTAssertEqual(model.emptyState, ClipboardEmptyState.noMatches(.image))
        XCTAssertEqual(model.emptyState?.message, "Images have no text to search")
        XCTAssertNotEqual(model.emptyState?.message, "No images in history")
    }

    /// The filter on its own, with no query, still means "no images in history".
    @MainActor
    func testFilterWithNoRowsKeepsTheFilterCopy() throws {
        let (_, store) = try makeStore()
        try insertText("only text", into: store)

        let model = ClipboardListModel(store: store)
        model.reload()
        model.setTypeFilter(.image)
        XCTAssertEqual(model.emptyState, ClipboardEmptyState.noRowsForFilter(.image))
        XCTAssertEqual(model.emptyState?.message, "No images in history")
    }

    @MainActor
    func testAbsentWordReadsAsNoMatches() throws {
        let (_, store) = try makeStore()
        try insertText("alpha", into: store)

        let model = ClipboardListModel(store: store)
        model.reload()
        model.searchText = "zzzz"
        XCTAssertTrue(model.filteredEntries.isEmpty)
        XCTAssertEqual(model.emptyState, ClipboardEmptyState.noMatches(nil))
        XCTAssertEqual(model.emptyState?.message, "No matches")
    }

    @MainActor
    func testAnEmptyHistorySaysSo() throws {
        let (_, store) = try makeStore()
        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.emptyState, ClipboardEmptyState.noHistory)
        XCTAssertEqual(model.emptyState?.message, "No clipboard history")
    }

    @MainActor
    func testSearchResetsSelectionToTheTop() throws {
        let (_, store) = try makeStore()
        try insertText("alpha", into: store)
        try insertText("alpine", into: store)

        let model = ClipboardListModel(store: store)
        model.reload()
        model.select(row: 1)
        XCTAssertEqual(model.selectedIndex, 1)

        model.searchText = "al"
        XCTAssertEqual(model.filteredEntries.count, 2)
        XCTAssertEqual(model.selectedIndex, 0, "typing resets the selection, as the panel did before")
        XCTAssertNotNil(model.selectedEntry)
    }

    @MainActor
    func testTypeFilterSelectsOnlyMatchingContentTypes() throws {
        let (_, store) = try makeStore()
        let text = try insertText("plain", into: store)
        let image = try insertImage(path: "a.png", into: store)
        let rtf = try insertText("bold", contentType: ContentType.rtf, into: store)
        let html = try insertText("<b>bold</b>", contentType: ContentType.html, into: store)
        let color = try insertText("#FF0000", contentType: ContentType.color, into: store)

        let model = ClipboardListModel(store: store)
        model.reload()

        model.setTypeFilter(.text)
        XCTAssertEqual(model.filteredEntries.map(\.id), [text.id])
        model.setTypeFilter(.image)
        XCTAssertEqual(model.filteredEntries.map(\.id), [image.id])
        model.setTypeFilter(.richText)
        XCTAssertEqual(Set(model.filteredEntries.map(\.id)), Set([rtf.id, html.id]), "rtf and html share a filter")
        model.setTypeFilter(.color)
        XCTAssertEqual(model.filteredEntries.map(\.id), [color.id])
        model.setTypeFilter(nil)
        XCTAssertEqual(model.filteredEntries.count, 5)
        XCTAssertFalse(model.isFiltering)

        model.setTypeFilter(.image)
        XCTAssertTrue(model.isFiltering, "a type filter counts as filtering for date grouping")
    }

    @MainActor
    func testUnfilteredListKeepsStoreOrder() throws {
        let (database, store) = try makeStore()
        try insertText("newest note", into: store)
        try insertText("oldest note", into: store)
        try insertText("pinned note", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 5000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 2")
        try database.execute("UPDATE clipboard_history SET updated_at = 100, pinned_at = 200 WHERE id = 3")

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["pinned note", "newest note", "oldest note"])

        model.searchText = "note"
        XCTAssertEqual(
            model.filteredEntries.first?.textContent,
            "pinned note",
            "a query keeps the pinned row first; the ordering is pinned, then relevance, then recency"
        )
        XCTAssertEqual(Set(model.filteredEntries.map(\.textContent)), ["pinned note", "newest note", "oldest note"])
    }

    // MARK: - Selection

    @MainActor
    func testDeleteKeepsSelectionOnAValidRow() throws {
        let (database, store) = try makeStore()
        let first = try insertText("first", into: store)
        let second = try insertText("second", into: store)
        let third = try insertText("third", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 3000 WHERE id = \(first.id)")
        try database.execute("UPDATE clipboard_history SET updated_at = 2000 WHERE id = \(second.id)")
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = \(third.id)")

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["first", "second", "third"])

        model.select(row: 1)
        XCTAssertEqual(model.selectedEntry?.id, second.id)
        model.delete(second)

        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["first", "third"])
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(model.selectedEntry?.id, third.id, "the row below takes the freed slot")
        XCTAssertFalse(model.entries.contains { $0.id == second.id })
    }

    @MainActor
    func testDeletingTheLastEntryClearsSelection() throws {
        let (_, store) = try makeStore()
        let only = try insertText("only", into: store)

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.selectedEntry?.id, only.id)

        model.delete(only)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.filteredEntries.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.selectedEntry, "an empty list has no selection")
    }

    @MainActor
    func testSelectNextAndPreviousWrap() throws {
        let (database, store) = try makeStore()
        let first = try insertText("first", into: store)
        let second = try insertText("second", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 2000 WHERE id = \(first.id)")
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = \(second.id)")

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.selectedEntry?.id, first.id)

        XCTAssertTrue(model.selectNext())
        XCTAssertEqual(model.selectedEntry?.id, second.id)
        XCTAssertTrue(model.selectNext())
        XCTAssertEqual(model.selectedEntry?.id, first.id, "wraps to the top")
        XCTAssertTrue(model.selectPrevious())
        XCTAssertEqual(model.selectedEntry?.id, second.id, "wraps to the bottom")

        model.delete(first)
        model.delete(second)
        XCTAssertFalse(model.selectNext(), "nothing to move through once the list is empty")
        XCTAssertFalse(model.selectPrevious())
    }

    @MainActor
    func testTogglePinReloadsOrderAndKeepsTheSelectionOnTheSameEntry() throws {
        let (database, store) = try makeStore()
        let older = try insertText("older", into: store)
        let newer = try insertText("newer", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = \(older.id)")
        try database.execute("UPDATE clipboard_history SET updated_at = 2000 WHERE id = \(newer.id)")

        let model = ClipboardListModel(store: store)
        model.reload()
        model.select(row: 1)
        XCTAssertEqual(model.selectedEntry?.id, older.id)

        model.togglePin(older)
        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["older", "newer"], "pin moves the row to the top")
        XCTAssertEqual(model.filteredEntries.first?.isPinned, true)
        XCTAssertEqual(model.selectedEntry?.id, older.id)

        let pinnedRow = try XCTUnwrap(model.filteredEntries.first)
        model.togglePin(pinnedRow)
        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["newer", "older"])
        XCTAssertEqual(model.filteredEntries.last?.isPinned, false)
        XCTAssertEqual(model.selectedEntry?.id, older.id, "the selection follows the entry, not its index")
    }

    @MainActor
    func testReloadClearsFiltersAndSelectsTheFirstUnpinnedRow() throws {
        let (_, store) = try makeStore()
        let pinned = try insertText("pinned", into: store)
        try insertText("loose", into: store)
        store.pin(id: pinned.id)

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.selectedIndex, 1, "a pinned first row is not the initial selection")
        XCTAssertEqual(model.selectedEntry?.textContent, "loose")

        model.searchText = "pin"
        model.setTypeFilter(.text)
        model.reload()

        XCTAssertEqual(model.searchText, "")
        XCTAssertNil(model.typeFilter)
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.filteredEntries.count, 2)
    }

    // MARK: - Images

    @MainActor
    func testImageURLResolvesInsideTheImageDirectoryAndToleratesMissingFiles() throws {
        let (_, store) = try makeStore()
        let missingName = "missing-\(UUID().uuidString).png"
        let image = try insertImage(path: missingName, into: store)
        let text = try insertText("no image", into: store)

        let model = ClipboardListModel(store: store)
        model.reload()

        let url = try XCTUnwrap(model.imageURL(for: image))
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL.path,
            store.imageDir.standardizedFileURL.path
        )
        XCTAssertEqual(url.lastPathComponent, missingName)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "resolution only builds the path; the view drops the preview when NSImage cannot load it"
        )
        XCTAssertNil(model.imageURL(for: text), "text rows have no image path")

        let storeless = ClipboardListModel()
        XCTAssertNil(storeless.imageURL(for: image), "no store, no image directory, no crash")
    }

    @MainActor
    func testDeleteAllKeepsPinnedRowsAndRefreshesTheList() throws {
        let (_, store) = try makeStore()
        let pinned = try insertText("keep", into: store)
        try insertText("drop one", into: store)
        try insertText("drop two", into: store)
        store.pin(id: pinned.id)

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.entries.count, 3)

        model.deleteAll()

        XCTAssertEqual(model.entries.map(\.textContent), ["keep"])
        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["keep"])
        XCTAssertEqual(model.selectedEntry?.id, pinned.id)
        XCTAssertEqual(store.fetchAll().map(\.textContent), ["keep"], "the store keeps pinned rows")
    }

    // MARK: - Paste / copy

    @MainActor
    func testPasteRoutesTextAndImagesThroughTheBoard() throws {
        let (_, store) = try makeStore()
        let payload = Data([0x7B, 0x5C, 0x72, 0x74, 0x66])
        try store.insert(
            contentType: ContentType.rtf, textContent: "bold", rawData: payload, imagePath: nil,
            imageWidth: nil, imageHeight: nil, imageSize: nil, sourceApp: nil, sourceName: nil
        )
        let rich = try XCTUnwrap(store.fetchAll().first)
        let image = try insertImage(path: "paste-\(UUID().uuidString).png", into: store)
        let blankImage = try insertImage(path: nil, into: store)

        let recorder = BoardRecorder()
        let model = ClipboardListModel(store: store, board: recorder.board)
        model.reload()

        model.paste(rich)
        XCTAssertEqual(recorder.pastedText.count, 1)
        XCTAssertEqual(recorder.pastedText.first?.text, "bold")
        XCTAssertNil(recorder.pastedText.first?.richText, "plain paste drops the rich flavour")

        model.paste(rich, formatted: true)
        XCTAssertEqual(recorder.pastedText.last?.richText, payload, "formatted paste carries the stored RTF")
        XCTAssertTrue(recorder.copiedText.isEmpty)
        XCTAssertEqual(recorder.dismissals, 0, "pasting dismisses through PasteService, not the model")

        model.paste(image)
        let imageName = try XCTUnwrap(model.imageURL(for: image)).lastPathComponent
        XCTAssertEqual(recorder.pastedImages.map(\.lastPathComponent), [imageName])
        XCTAssertEqual(recorder.pastedText.count, 2)

        model.paste(blankImage)
        XCTAssertEqual(recorder.pastedImages.count, 1, "an image row without a path pastes nothing")
        XCTAssertEqual(recorder.pastedText.count, 2)
    }

    @MainActor
    func testCopyDoesNotPasteAndDismissesThePanel() throws {
        let (_, store) = try makeStore()
        let text = try insertText("copy me", into: store)

        let recorder = BoardRecorder()
        let model = ClipboardListModel(store: store, board: recorder.board)
        model.reload()

        model.copy(text)

        XCTAssertEqual(recorder.copiedText.map(\.text), ["copy me"])
        XCTAssertTrue(recorder.pastedText.isEmpty, "copy must not simulate Cmd+V")
        XCTAssertTrue(recorder.pastedImages.isEmpty)
        XCTAssertEqual(recorder.dismissals, 1)
    }

    // MARK: - Store-backed search

    /// The search field reaches rows that are on disk but outside the 500-row page the panel
    /// loads; that is the whole reason the query moved into SQLite.
    @MainActor
    func testSearchReadsTheStoreBeyondTheLoadedPage() throws {
        let (_, store) = try makeStore()
        try insertText("prehistoric needle", into: store)
        for index in 0 ..< 520 {
            try insertText("filler \(index)", into: store)
        }

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.entries.count, 500)
        XCTAssertFalse(model.filteredEntries.contains { $0.textContent == "prehistoric needle" })

        model.searchText = "needle"
        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["prehistoric needle"])
    }

    @MainActor
    func testEmptyQueryKeepsTheLoadedPagePath() throws {
        let (database, store) = try makeStore()
        let older = try insertText("older", into: store)
        let newest = try insertText("newest", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 2000 WHERE id = \(newest.id)")
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = \(older.id)")

        let model = ClipboardListModel(store: store)
        model.reload()
        XCTAssertEqual(model.filteredEntries.map(\.id), [newest.id, older.id], "store order, untouched")

        model.searchText = "old"
        XCTAssertEqual(model.filteredEntries.map(\.id), [older.id])

        model.resetSearch()
        XCTAssertEqual(model.filteredEntries.map(\.id), model.entries.map(\.id), "clearing returns the page")
    }

    /// A database whose FTS table is missing must search the loaded page the way the panel did
    /// before the index existed — including the fuzzy matcher that only survives on that path.
    @MainActor
    func testSearchFallsBackToThePageWhenTheIndexIsMissing() throws {
        let (database, store) = try makeStore()
        let deploy = try insertText("deploy the build", into: store)
        let desktop = try insertText("remote desktop connection notes", into: store)
        try insertText("unrelated", into: store)
        for trigger in ["clipboard_fts_ai", "clipboard_fts_ad", "clipboard_fts_au"] {
            try database.execute("DROP TRIGGER \(trigger)")
        }
        try database.execute("DROP TABLE clipboard_fts")

        let model = ClipboardListModel(store: store)
        model.reload()

        model.searchText = "dpl"
        XCTAssertEqual(
            model.filteredEntries.map(\.id),
            [deploy.id],
            "the page filter's subsequence match is what runs when the index is unusable"
        )

        model.searchText = "esktop"
        XCTAssertEqual(
            model.filteredEntries.map(\.id),
            [desktop.id],
            "the fallback still matches a mid-word substring, as it did before the index existed"
        )

        model.searchText = "🚀"
        XCTAssertTrue(model.filteredEntries.isEmpty, "no row contains the emoji, and none was invented")
        XCTAssertEqual(model.entries.count, 3, "the page itself is untouched")
    }

    @MainActor
    func testSearchIsDebounced() async throws {
        let (_, store) = try makeStore()
        try insertText("alpha", into: store)
        try insertText("beta", into: store)

        let model = ClipboardListModel(store: store, searchDebounceNanos: 60_000_000)
        model.reload()

        model.searchText = "alpha"
        XCTAssertEqual(model.filteredEntries.count, 2, "the query waits out the debounce")

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.filteredEntries.map(\.textContent), ["alpha"])
    }

    // MARK: - Missing store

    @MainActor
    func testMutationsTolerateAMissingStore() {
        let model = ClipboardListModel()
        model.reload()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.selectedEntry)

        model.deleteAll()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.selectNext())
        model.resetSearch()
        model.setTypeFilter(nil)
        XCTAssertNil(model.matchedIndices(in: ""))
    }
}
