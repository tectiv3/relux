import ReluxCore
import XCTest

/// `ClipboardStore` lives in the app target but has no AppKit/UI dependency beyond
/// `Foundation`, so it is compiled into the test bundle (see `project.yml`) and exercised
/// host-free here against the real store code and the real schema.
final class ClipboardStoreTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> (database: SQLiteDatabase, store: ClipboardStore) {
        let database = try SQLiteDatabase(path: ":memory:")
        try ReluxSchema.migrate(database)
        return try (database, ClipboardStore(db: database))
    }

    @MainActor
    private func insertText(
        _ text: String,
        into store: ClipboardStore,
        contentType: String = ContentType.text
    ) throws {
        try store.insert(
            contentType: contentType,
            textContent: text,
            rawData: nil,
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
            imageSize: nil,
            sourceApp: nil,
            sourceName: nil
        )
    }

    @MainActor
    private func entries(in store: ClipboardStore) -> [ClipboardEntry] {
        store.fetchAll()
    }

    // MARK: - Insert / read

    @MainActor
    func testInsertRecordsTextEntry() throws {
        let (_, store) = try makeStore()
        try store.insert(
            contentType: ContentType.text,
            textContent: "hello world",
            rawData: nil,
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
            imageSize: nil,
            sourceApp: "Safari",
            sourceName: "Safari"
        )

        let entry = try XCTUnwrap(entries(in: store).first)
        XCTAssertEqual(entry.contentType, "text")
        XCTAssertEqual(entry.textContent, "hello world")
        XCTAssertEqual(entry.charCount, 11)
        XCTAssertEqual(entry.wordCount, 2)
        XCTAssertEqual(entry.sourceApp, "Safari")
        XCTAssertNil(entry.pinnedAt)
        XCTAssertFalse(entry.isPinned)
        XCTAssertEqual(
            entry.createdAt.timeIntervalSince1970,
            entry.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001,
            "created_at and updated_at are written from the same timestamp on insert"
        )
        XCTAssertGreaterThan(
            entry.createdAt.timeIntervalSince1970,
            1_600_000_000,
            "timestamps are stored as REAL epoch seconds, not milliseconds"
        )
    }

    @MainActor
    func testRawDataRoundTrip() throws {
        let (_, store) = try makeStore()
        let payload = Data([0x01, 0x02, 0x03, 0xFF])
        try store.insert(
            contentType: ContentType.image,
            textContent: nil,
            rawData: payload,
            imagePath: "image.png",
            imageWidth: 10,
            imageHeight: 20,
            imageSize: payload.count,
            sourceApp: nil,
            sourceName: nil
        )

        let entry = try XCTUnwrap(entries(in: store).first)
        XCTAssertEqual(entry.imageWidth, 10)
        XCTAssertEqual(entry.imageHeight, 20)
        XCTAssertEqual(entry.imageSize, 4)
        XCTAssertEqual(store.fetchRawData(id: entry.id), payload)
        XCTAssertNil(store.fetchRawData(id: 9999), "missing rows return nil, not an error")
    }

    /// `char_count`/`image_size` are bound as 64-bit integers: the 32-bit conversion trapped above
    /// `Int32.max`, and `columnInt` truncated the value on the way back.
    @MainActor
    func testLargeSizeColumnRoundTripsAboveInt32Max() throws {
        let (_, store) = try makeStore()
        let bigSize = Int(Int32.max) + 1
        try store.insert(
            contentType: ContentType.image,
            textContent: nil,
            rawData: nil,
            imagePath: "huge.png",
            imageWidth: 6000,
            imageHeight: 4000,
            imageSize: bigSize,
            sourceApp: nil,
            sourceName: nil
        )

        let entry = try XCTUnwrap(entries(in: store).first)
        XCTAssertEqual(entry.imageSize, bigSize)
        XCTAssertEqual(entry.imageWidth, 6000)
        XCTAssertEqual(entry.imageHeight, 4000)
    }

    /// A dead database used to read as an empty history with no trace anywhere.
    @MainActor
    func testFetchAllLogsTheCauseWhenTheTableIsMissing() throws {
        let (database, store) = try makeStore()
        let capture: LogCapture
        do {
            capture = try LogCapture()
        } catch {
            throw XCTSkip("the unified log is unavailable to this process: \(error)")
        }
        try database.execute("DROP TABLE clipboard_history")

        XCTAssertTrue(entries(in: store).isEmpty, "the read keeps its empty-history contract")
        XCTAssertTrue(
            capture.waitForError(category: "clipboardstore", containing: "fetchAll"),
            "a failed history read must not be silent"
        )
    }

    // MARK: - Ordering

    @MainActor
    func testFetchAllOrdersPinnedFirstThenByUpdateTime() throws {
        let (database, store) = try makeStore()
        try insertText("newest", into: store)
        try insertText("oldest", into: store)
        try insertText("pinned", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 5000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 2")
        try database.execute("UPDATE clipboard_history SET updated_at = 100, pinned_at = 200 WHERE id = 3")

        XCTAssertEqual(entries(in: store).map(\.textContent), ["pinned", "newest", "oldest"])

        try database.execute("UPDATE clipboard_history SET pinned_at = 50 WHERE id = 2")
        XCTAssertEqual(
            entries(in: store).map(\.textContent),
            ["oldest", "pinned", "newest"],
            "multiple pinned rows order by pinned_at ASC"
        )
    }

    @MainActor
    func testBumpTimestampMovesEntryToTheTop() throws {
        let (database, store) = try makeStore()
        try insertText("first", into: store)
        try insertText("second", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 5000 WHERE id = 2")
        XCTAssertEqual(entries(in: store).map(\.textContent), ["second", "first"])

        store.bumpTimestamp(id: 1)
        XCTAssertEqual(entries(in: store).map(\.textContent), ["first", "second"])

        // The two error policies: bump on a missing id logs and returns instead of throwing.
        store.bumpTimestamp(id: 9999)
    }

    @MainActor
    func testPinAndUnpin() throws {
        let (database, store) = try makeStore()
        try insertText("first", into: store)
        try insertText("second", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 5000 WHERE id = 2")
        XCTAssertEqual(entries(in: store).map(\.textContent), ["second", "first"])

        store.pin(id: 1)
        let pinned = try XCTUnwrap(entries(in: store).first)
        XCTAssertEqual(pinned.id, 1)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertNotNil(pinned.pinnedAt)

        store.unpin(id: 1)
        let unpinned = try XCTUnwrap(entries(in: store).last)
        XCTAssertEqual(unpinned.id, 1)
        XCTAssertFalse(unpinned.isPinned)
        XCTAssertNil(unpinned.pinnedAt)
        XCTAssertEqual(entries(in: store).map(\.textContent), ["second", "first"])

        // pin/unpin on a missing id must not throw.
        store.pin(id: 9999)
        store.unpin(id: 9999)
    }

    @MainActor
    func testIsDuplicateUsesMostRecentAndPinnedEntries() throws {
        let (_, store) = try makeStore()
        try insertText("alpha", into: store)
        XCTAssertTrue(store.isDuplicate(textContent: "alpha"))
        XCTAssertFalse(store.isDuplicate(textContent: "beta"))

        try insertText("gamma", into: store)
        let gamma = try XCTUnwrap(entries(in: store).first { $0.textContent == "gamma" })
        store.pin(id: gamma.id)
        try insertText("delta", into: store)

        XCTAssertTrue(store.isDuplicate(textContent: "gamma"), "pinned entries are matched even when not most recent")
        XCTAssertTrue(store.isDuplicate(textContent: "delta"))
        XCTAssertFalse(store.isDuplicate(textContent: "alpha"))
    }

    // MARK: - Delete / retention

    @MainActor
    func testDeleteRemovesRowAndImageFile() throws {
        let (_, store) = try makeStore()
        let fileName = "delete-\(UUID().uuidString).png"
        let fileURL = store.imageDir.appendingPathComponent(fileName)
        try Data([0x89, 0x50]).write(to: fileURL)

        try store.insert(
            contentType: ContentType.image,
            textContent: nil,
            rawData: nil,
            imagePath: fileName,
            imageWidth: 1,
            imageHeight: 1,
            imageSize: 2,
            sourceApp: nil,
            sourceName: nil
        )
        let id = try XCTUnwrap(entries(in: store).first?.id)

        try store.delete(id: id)
        XCTAssertTrue(entries(in: store).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "image file must be unlinked with the row")
    }

    @MainActor
    func testClearAllKeepsPinnedEntries() throws {
        let (_, store) = try makeStore()
        try insertText("keep", into: store)
        try insertText("drop", into: store)
        let keepID = try XCTUnwrap(entries(in: store).first { $0.textContent == "keep" }?.id)
        store.pin(id: keepID)

        try store.clearAll()
        XCTAssertEqual(entries(in: store).map(\.textContent), ["keep"])
    }

    @MainActor
    func testDeleteExpiredKeepsPinnedEntriesAndTheirImages() throws {
        let (database, store) = try makeStore()
        let expiredImage = "expired-\(UUID().uuidString).png"
        let pinnedImage = "pinned-\(UUID().uuidString).png"
        let expiredURL = store.imageDir.appendingPathComponent(expiredImage)
        let pinnedURL = store.imageDir.appendingPathComponent(pinnedImage)
        try Data([0x01]).write(to: expiredURL)
        try Data([0x02]).write(to: pinnedURL)
        // `imageDir` is the real clipboard image directory, so never leave fixtures behind.
        defer { try? FileManager.default.removeItem(at: pinnedURL) }

        try store.insert(
            contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: expiredImage,
            imageWidth: 1, imageHeight: 1, imageSize: 1, sourceApp: nil, sourceName: nil
        )
        try store.insert(
            contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: pinnedImage,
            imageWidth: 1, imageHeight: 1, imageSize: 1, sourceApp: nil, sourceName: nil
        )
        try insertText("recent", into: store)

        // Everything inserted is "old" on both timestamps except the last row, and the second row
        // is pinned. `updated_at` has to be set too: expiry now keys off the later of the two.
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = 1000 WHERE id IN (1, 2)")
        store.pin(id: 2)

        try store.deleteExpired(before: Date(timeIntervalSince1970: 5000))

        XCTAssertEqual(entries(in: store).map(\.textContent), [nil, "recent"], "the pinned row must survive")
        XCTAssertEqual(entries(in: store).first?.imagePath, pinnedImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
    }

    // MARK: - Expiry

    /// The bug this predicate fixes: a re-copied entry kept the `created_at` of its first sighting,
    /// so it was deleted six months after that even though it was used today.
    @MainActor
    func testDeleteExpiredKeepsARowRecopiedAfterItWasFirstSeen() throws {
        let (database, store) = try makeStore()
        try insertText("recopied today", into: store)
        try insertText("stale on both", into: store)
        try insertText("created today", into: store)
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = 9000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = 1000 WHERE id = 2")
        try database.execute("UPDATE clipboard_history SET created_at = 9000, updated_at = 9000 WHERE id = 3")

        try store.deleteExpired(before: Date(timeIntervalSince1970: 5000))

        XCTAssertEqual(
            Set(entries(in: store).compactMap(\.textContent)),
            ["recopied today", "created today"],
            "only the row that is old on both timestamps may be deleted"
        )
    }

    /// A row from before `updated_at` existed carries NULL there; the COALESCE keeps it expirable.
    @MainActor
    func testDeleteExpiredTreatsAMissingUpdatedAtAsCreatedAt() throws {
        let (database, store) = try makeStore()
        try insertText("legacy old", into: store)
        try insertText("legacy recent", into: store)
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = NULL WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET created_at = 9000, updated_at = NULL WHERE id = 2")

        try store.deleteExpired(before: Date(timeIntervalSince1970: 5000))

        XCTAssertEqual(entries(in: store).compactMap(\.textContent), ["legacy recent"])
    }

    @MainActor
    func testDeleteExpiredNeverDeletesAPinnedRowWhateverItsAge() throws {
        let (database, store) = try makeStore()
        let pinnedImage = "pinned-\(UUID().uuidString).png"
        let pinnedURL = store.imageDir.appendingPathComponent(pinnedImage)
        try Data([0x03]).write(to: pinnedURL)
        defer { try? FileManager.default.removeItem(at: pinnedURL) }

        try store.insert(
            contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: pinnedImage,
            imageWidth: 1, imageHeight: 1, imageSize: 1, sourceApp: nil, sourceName: nil
        )
        try insertText("unpinned ancient", into: store)
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = 1000")
        let pinnedID = try XCTUnwrap(entries(in: store).first { $0.contentType == ContentType.image }?.id)
        store.pin(id: pinnedID)

        try store.deleteExpired(before: Date(timeIntervalSince1970: 5000))

        XCTAssertEqual(entries(in: store).map(\.id), [pinnedID], "the pinned row survives its own timestamps")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path), "and keeps its image")
    }

    /// The unlink must follow the row: an image kept alive by a recent `updated_at` keeps its file.
    @MainActor
    func testDeleteExpiredUnlinksOnlyTheImagesOfDeletedRows() throws {
        let (database, store) = try makeStore()
        let keptImage = "kept-\(UUID().uuidString).png"
        let deletedImage = "deleted-\(UUID().uuidString).png"
        let keptURL = store.imageDir.appendingPathComponent(keptImage)
        let deletedURL = store.imageDir.appendingPathComponent(deletedImage)
        try Data([0x04]).write(to: keptURL)
        try Data([0x05]).write(to: deletedURL)
        defer {
            try? FileManager.default.removeItem(at: keptURL)
            try? FileManager.default.removeItem(at: deletedURL)
        }

        for name in [keptImage, deletedImage] {
            try store.insert(
                contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: name,
                imageWidth: 1, imageHeight: 1, imageSize: 1, sourceApp: nil, sourceName: nil
            )
        }
        // id 1 is old but was re-copied; id 2 is old on both.
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = 9000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = 1000 WHERE id = 2")

        try store.deleteExpired(before: Date(timeIntervalSince1970: 5000))

        XCTAssertEqual(entries(in: store).map(\.imagePath), [keptImage])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path), "a surviving row keeps its image")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedURL.path), "a deleted row loses it")
    }

    // MARK: - FTS search

    @MainActor
    private func searchIDs(
        _ query: String,
        in store: ClipboardStore,
        type: ClipboardTypeFilter? = nil
    ) -> [Int64]? {
        store.search(matching: query, type: type)?.map(\.id)
    }

    /// The whole point of the index: rows that retention keeps on disk but the 500-row page the
    /// panel loads no longer contains.
    @MainActor
    func testSearchReachesRowsOutsideTheLoadedPage() throws {
        let (_, store) = try makeStore()
        try insertText("prehistoric needle", into: store)
        for index in 0 ..< 520 {
            try insertText("filler \(index)", into: store)
        }

        let page = entries(in: store)
        XCTAssertEqual(page.count, 500)
        XCTAssertFalse(page.contains { $0.textContent == "prehistoric needle" }, "the target must be off the page")

        XCTAssertEqual(store.search(matching: "needle")?.map(\.textContent), ["prehistoric needle"])
        XCTAssertEqual(
            store.search(matching: "prehi")?.count, 1,
            "any three-character window matches, not only a prefix"
        )
        XCTAssertEqual(store.search(matching: "zzz")?.count, 0, "no match is an empty result, not the fallback")
    }

    /// Mid-word substrings are what the old `unicode61` index could not match: it tokenized
    /// `desktop` whole, so only a token prefix matched. The row is off the loaded page as well, so
    /// this is the search the panel is supposed to have.
    @MainActor
    func testMidWordSubstringFindsARowOutsideTheLoadedPage() throws {
        let (_, store) = try makeStore()
        try insertText("remote desktop connection notes", into: store)
        for index in 0 ..< 520 {
            try insertText("filler \(index)", into: store)
        }
        XCTAssertFalse(
            entries(in: store).contains { $0.textContent == "remote desktop connection notes" },
            "the target must be off the page"
        )

        XCTAssertEqual(
            store.search(matching: "esktop")?.map(\.textContent),
            ["remote desktop connection notes"],
            "a substring inside a word matches"
        )
        XCTAssertEqual(store.search(matching: "nnectio")?.count, 1, "a window in the middle of a long word")
        XCTAssertEqual(store.search(matching: "DESKTOP")?.count, 1, "trigram folds case")
        XCTAssertEqual(store.search(matching: "ktop conn")?.count, 1)
    }

    /// A contiguous CJK run is a single `unicode61` token, so only a prefix of the whole run could
    /// match. Trigram matches any window inside it.
    @MainActor
    func testCJKSubstringMatchesInsideARun() throws {
        let (_, store) = try makeStore()
        try insertText("日本語のテキストをコピーしました", into: store)
        try insertText("unrelated latin row", into: store)

        XCTAssertEqual(store.search(matching: "語のテ")?.count, 1, "a query drawn from the middle of the run")
        XCTAssertEqual(store.search(matching: "ストをコ")?.count, 1)
        XCTAssertEqual(store.search(matching: "しました")?.count, 1, "the tail of the run")
        XCTAssertEqual(store.search(matching: "本語のテキスト")?.count, 1)
        XCTAssertEqual(store.search(matching: "存在しない")?.count, 0, "a term the run does not contain")
        XCTAssertNil(store.search(matching: "本語"), "a two-character query is below the trigram width")
    }

    /// `source_name` is indexed since schema 3: images carry no text at all, so the app a clip came
    /// from is often the only thing there is to search.
    @MainActor
    func testSourceNameIsSearchable() throws {
        let (_, store) = try makeStore()
        try store.insert(
            contentType: ContentType.text, textContent: "unremarkable body", rawData: nil, imagePath: nil,
            imageWidth: nil, imageHeight: nil, imageSize: nil,
            sourceApp: "com.apple.Safari", sourceName: "Safari"
        )
        try store.insert(
            contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: "shot.png",
            imageWidth: 10, imageHeight: 10, imageSize: 10,
            sourceApp: "com.apple.Preview", sourceName: "Preview"
        )
        try insertText("unrelated filler", into: store)

        XCTAssertEqual(store.search(matching: "Saf")?.map(\.sourceName), ["Safari"])
        XCTAssertEqual(store.search(matching: "afar")?.count, 1, "a window inside the source name matches")
        XCTAssertEqual(store.search(matching: "Previe")?.count, 1, "a text-less image row is reachable this way")
    }

    /// A term below the trigram width cannot be matched by the index at all, and dropping it would
    /// silently search for something other than what was typed: the whole query is unanswerable
    /// and the caller filters the loaded page instead.
    @MainActor
    func testAQueryWithATermShorterThanThreeCharactersIsUnanswerable() throws {
        let (_, store) = try makeStore()
        try insertText("grab the cab", into: store)

        XCTAssertNil(store.search(matching: "ab"), "two characters cannot be indexed by trigram")
        XCTAssertNil(store.search(matching: "grab a"), "a short term next to a long one still makes it unanswerable")
        XCTAssertEqual(store.search(matching: "cab")?.count, 1, "the same text is found at three characters")
        XCTAssertEqual(store.search(matching: " grab ")?.count, 1, "surrounding whitespace is not a term")
    }

    /// An empty result from the index is an answer, not a failure: the text is not in the history,
    /// so the caller must not fall back and search the page for it.
    @MainActor
    func testAnAbsentTermReturnsAnEmptyResultInsteadOfTheFallback() throws {
        let (_, store) = try makeStore()
        try insertText("alpha", into: store)

        let results = store.search(matching: "zzzz")
        XCTAssertNotNil(results, "the index answered")
        XCTAssertEqual(results?.isEmpty, true)
    }

    /// Ordering on the FTS path is the same as the unfiltered page: pinned first, then most
    /// recently used. `MATCH` only filters — a row that matches the term more often is not moved
    /// ahead of a newer one, because the panel groups by date and a relevance order would split
    /// one day across several headings.
    @MainActor
    func testSearchOrdersPinnedFirstThenByRecency() throws {
        let (database, store) = try makeStore()
        try insertText("alpha aaa", into: store)
        try insertText("alpha bbb", into: store)
        // Three more occurrences of the term: a relevance order would rank this row first.
        try insertText("alpha alpha alpha alpha", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 3000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 2000 WHERE id = 2")
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 3")

        XCTAssertEqual(
            searchIDs("alpha", in: store),
            [1, 2, 3],
            "recency decides; the row with the most occurrences of the term does not jump the queue"
        )

        store.pin(id: 3)
        XCTAssertEqual(searchIDs("alpha", in: store), [3, 1, 2], "a pinned row leads regardless of recency")
    }

    /// Equal timestamps must still produce one order on every run: `id DESC` breaks the tie, so the
    /// list cannot reorder itself between two queries.
    @MainActor
    func testSearchBreaksEqualTimestampsByIDDescending() throws {
        let (database, store) = try makeStore()
        try insertText("tie one", into: store)
        try insertText("tie two", into: store)
        try insertText("tie three", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 1000")

        XCTAssertEqual(searchIDs("tie", in: store), [3, 2, 1])
        XCTAssertEqual(searchIDs("tie", in: store), searchIDs("tie", in: store))
    }

    @MainActor
    func testSearchAppliesTheTypeFilterInSQL() throws {
        let (_, store) = try makeStore()
        try insertText("needle in text", into: store)
        try insertText("needle in rtf", into: store, contentType: ContentType.rtf)
        try insertText("needle in html", into: store, contentType: ContentType.html)
        try insertText("needle in color", into: store, contentType: ContentType.color)
        try insertText("unrelated filler", into: store)

        XCTAssertEqual(store.search(matching: "needle")?.count, 4)
        XCTAssertEqual(store.search(matching: "needle", type: .text)?.map(\.contentType), [ContentType.text])
        XCTAssertEqual(
            Set(store.search(matching: "needle", type: .richText)?.map(\.contentType) ?? []),
            [ContentType.rtf, ContentType.html]
        )
        XCTAssertEqual(store.search(matching: "needle", type: .color)?.count, 1)
        XCTAssertEqual(store.search(matching: "needle", type: .image)?.isEmpty, true)
    }

    /// Every one of these would be a `MATCH` syntax error, or an operator, if the input reached
    /// SQLite unquoted.
    @MainActor
    func testSearchEscapesHostileInput() throws {
        let (_, store) = try makeStore()
        try insertText("alpha --beta gamma (delta) OR NEAR \"quoted\"", into: store)
        try insertText("plain row", into: store)

        for input in ["-", "*", "\"", "(", ")", ":", "^", "**", "🚀"] {
            XCTAssertNil(
                store.search(matching: input),
                "\(input) is below the trigram width, so the caller filters the page instead"
            )
        }
        XCTAssertEqual(store.search(matching: "NEAR")?.count, 1, "NEAR is a literal word inside a phrase")
        XCTAssertEqual(store.search(matching: "NOT")?.isEmpty, true, "an operator word no row contains matches nothing")
        XCTAssertEqual(store.search(matching: "zzzz")?.count, 0)
        XCTAssertEqual(
            store.search(matching: "(delta)")?.count, 1,
            "parentheses are literal characters inside a phrase"
        )
        XCTAssertEqual(store.search(matching: "quoted")?.count, 1)
        XCTAssertEqual(store.search(matching: "\"quoted\"")?.count, 1, "an embedded quote is doubled, not opened")
        XCTAssertNil(store.search(matching: "alpha --"), "a two-character term is unanswerable even next to a long one")
        XCTAssertEqual(
            store.search(matching: "plain)")?.isEmpty,
            true,
            "trigram matches literally, punctuation included; the word tokenizer would have dropped the bracket"
        )
    }

    @MainActor
    func testSearchHandlesCJKEmojiAndDiacritics() throws {
        let (_, store) = try makeStore()
        try insertText("中文测试内容", into: store)
        try insertText("café latte", into: store)
        try insertText("ship it 🚀 today", into: store)

        XCTAssertEqual(store.search(matching: "中文测试内容")?.count, 1)
        XCTAssertEqual(store.search(matching: "中文测")?.count, 1, "a window inside the run")
        XCTAssertEqual(store.search(matching: "文测试内")?.count, 1, "a window from the middle of the run")
        XCTAssertEqual(store.search(matching: "cafe")?.count, 1, "remove_diacritics 1 folds café")
        XCTAssertEqual(store.search(matching: "café")?.count, 1)
        XCTAssertEqual(store.search(matching: "ship")?.count, 1)
        XCTAssertNil(
            store.search(matching: "ship 🚀"),
            "the emoji term is below the trigram width, so the query falls back"
        )
        XCTAssertNil(store.search(matching: "🚀"), "an emoji-only query falls back to the page filter")
    }

    @MainActor
    func testTriggersKeepTheIndexInSync() throws {
        let (database, store) = try makeStore()
        try insertText("original word", into: store)
        let id = try XCTUnwrap(entries(in: store).first?.id)
        XCTAssertEqual(searchIDs("original", in: store), [id])

        try database.execute("UPDATE clipboard_history SET text_content = 'replacement' WHERE id = \(id)")
        XCTAssertEqual(searchIDs("original", in: store), [], "the old text must leave the index")
        XCTAssertEqual(searchIDs("replacement", in: store), [id])

        store.bumpTimestamp(id: id)
        store.pin(id: id)
        XCTAssertEqual(searchIDs("replacement", in: store), [id], "updates that leave the text alone keep it indexed")

        try database.execute("UPDATE clipboard_history SET source_name = 'Firefox' WHERE id = \(id)")
        XCTAssertEqual(searchIDs("Firefox", in: store), [id], "a changed source name is indexed")
        try database.execute("UPDATE clipboard_history SET source_name = 'Chromium' WHERE id = \(id)")
        XCTAssertEqual(searchIDs("Firefox", in: store), [], "the old source name leaves the index")
        XCTAssertEqual(searchIDs("Chromium", in: store), [id])

        try store.delete(id: id)
        XCTAssertEqual(searchIDs("replacement", in: store), [], "a deleted row leaves no tokens behind")
        XCTAssertEqual(searchIDs("Chromium", in: store), [])
        try database.execute("INSERT INTO clipboard_fts(clipboard_fts) VALUES('integrity-check')")
    }

    /// R1: `bumpTimestamp` (every paste and every re-copy) and `pin`/`unpin` only touch
    /// `updated_at`/`pinned_at`, so they must not rewrite the inverted index — with an unnarrowed
    /// `AFTER UPDATE` trigger each of them deleted and re-inserted the whole document.
    ///
    /// Observable without reading FTS internals: the row below reaches the table with its insert
    /// trigger missing, so the index does not contain it. Letting an unindexed row be re-indexed is
    /// exactly what an unnarrowed update trigger does, and FTS5 rejects the 'delete' half of that
    /// replay for a document it never had, which aborts the whole `UPDATE`. So an unnarrowed
    /// trigger makes `bumpTimestamp` and `pin` silently stop working (the store logs and returns),
    /// while a narrowed one leaves them alone.
    @MainActor
    func testTimestampAndPinUpdatesDoNotRewriteTheIndex() throws {
        let (database, store) = try makeStore()
        try database.execute("DROP TRIGGER clipboard_fts_ai")
        try insertText("hidden needle", into: store)
        try insertText("second row", into: store)
        let hidden = try XCTUnwrap(entries(in: store).first { $0.textContent == "hidden needle" }?.id)
        let other = try XCTUnwrap(entries(in: store).first { $0.textContent == "second row" }?.id)
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = \(hidden)")
        try database.execute("UPDATE clipboard_history SET updated_at = 2000 WHERE id = \(other)")
        XCTAssertEqual(entries(in: store).map(\.id), [other, hidden], "recency order before the updates")

        store.bumpTimestamp(id: hidden)
        XCTAssertEqual(
            entries(in: store).first?.id,
            hidden,
            "bumpTimestamp applied: the row moved to the top instead of failing on an index write"
        )

        store.pin(id: hidden)
        XCTAssertEqual(entries(in: store).first?.isPinned, true, "pin applied")
        store.unpin(id: hidden)
        XCTAssertEqual(entries(in: store).first?.isPinned, false, "unpin applied")
        XCTAssertEqual(entries(in: store).map(\.id), [hidden, other])
    }

    /// A database whose index is missing — dropped, or never built because the SQLite the app
    /// links is older than 3.34 — must read as "the index could not answer", not as "no matches".
    /// The caller then filters the loaded page, which still holds the row.
    @MainActor
    func testSearchWithoutTheIndexReturnsNilSoTheCallerCanFallBack() throws {
        let (database, store) = try makeStore()
        try insertText("remote desktop connection notes", into: store)
        for trigger in ["clipboard_fts_ai", "clipboard_fts_ad", "clipboard_fts_au"] {
            try database.execute("DROP TRIGGER \(trigger)")
        }
        try database.execute("DROP TABLE clipboard_fts")

        XCTAssertNil(store.search(matching: "esktop"), "a missing index must not read as 'no matches'")
        XCTAssertNil(store.search(matching: "desktop"))
        XCTAssertEqual(
            entries(in: store).map(\.textContent),
            ["remote desktop connection notes"],
            "the row is still on the page for the fallback to find"
        )
    }

    @MainActor
    func testRetentionDeleteKeepsTheIndexInSyncForRowsWithoutText() throws {
        let (database, store) = try makeStore()
        let imageName = "expired-\(UUID().uuidString).png"
        let imageURL = store.imageDir.appendingPathComponent(imageName)
        try Data([0x01]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        try store.insert(
            contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: imageName,
            imageWidth: 1, imageHeight: 1, imageSize: 1, sourceApp: nil, sourceName: nil
        )
        try insertText("survivor text", into: store)
        try database.execute("UPDATE clipboard_history SET created_at = 1000, updated_at = 1000 WHERE id = 1")

        try store.deleteExpired(before: Date(timeIntervalSince1970: 5000))

        XCTAssertEqual(entries(in: store).map(\.textContent), ["survivor text"])
        XCTAssertEqual(store.search(matching: "survivor")?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        // A NULL text_content row is the case the FTS 'delete' command has to tolerate: if the
        // trigger left anything behind, this check reports the index as malformed.
        try database.execute("INSERT INTO clipboard_fts(clipboard_fts) VALUES('integrity-check')")
    }
}
