import Foundation
import Observation
import ReluxCore

/// The clipboard panel's type filter. `matches` is the filtering contract; the labels and
/// icons the UI shows for each case live with the view.
enum ClipboardTypeFilter: String, CaseIterable {
    case text
    case image
    case richText
    case color

    /// The `content_type` values this filter accepts: one source of truth for the in-memory
    /// predicate and the SQL the store runs.
    var contentTypes: [String] {
        switch self {
        case .text: [ContentType.text]
        case .image: [ContentType.image]
        case .richText: [ContentType.rtf, ContentType.html]
        case .color: [ContentType.color]
        }
    }

    /// Plural label the panel shows for the filter; the empty-state copy uses the same words so
    /// the two never disagree about what is being filtered.
    var label: String {
        switch self {
        case .text: "Text"
        case .image: "Images"
        case .richText: "Rich Text"
        case .color: "Colors"
        }
    }

    func matches(_ contentType: String) -> Bool {
        contentTypes.contains(contentType)
    }
}

/// What the list area shows when it has no rows to show. Derived here rather than in the view so
/// the difference between "the history is empty", "the filter has nothing" and "the query did not
/// match" is a value a test can assert on without a SwiftUI host.
enum ClipboardEmptyState: Equatable {
    case noHistory
    case noRowsForFilter(ClipboardTypeFilter)
    case noMatches(ClipboardTypeFilter?)

    var message: String {
        switch self {
        case .noHistory:
            "No clipboard history"
        case let .noRowsForFilter(type):
            "No \(type.label.lowercased()) in history"
        case let .noMatches(type):
            // Images are stored without text, so the index can never match them: naming the
            // reason beats implying the history holds no images.
            type == .image ? "Images have no text to search" : "No matches"
        }
    }
}

/// One heading and its rows in the clipboard panel.
///
/// The id is the calendar day, never the label the heading renders. A label is display data:
/// it repeats across days in some formats, and two headings sharing an id make SwiftUI's
/// `ForEach` undefined (blank bands, rows attached to the wrong heading, stale fills).
struct ClipboardSection: Identifiable {
    enum SectionID: Hashable {
        case pinned
        case day(Date)
    }

    /// A row plus its position in `filteredEntries`, which is the unit the selection uses.
    struct Row: Identifiable {
        let index: Int
        let entry: ClipboardEntry

        var id: ClipboardEntry.ID {
            entry.id
        }
    }

    let id: SectionID
    let label: String
    let rows: [Row]
}

/// Pure derivation behind the panel's search field, kept separate from the model so the
/// matching rules can be exercised without a store.
enum ClipboardFilter {
    /// Trimmed and lowercased once so every match path sees the same query.
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func apply(
        _ entries: [ClipboardEntry],
        query rawQuery: String,
        type: ClipboardTypeFilter?
    ) -> [ClipboardEntry] {
        var result = entries
        if let type {
            result = result.filter { type.matches($0.contentType) }
        }

        let query = normalized(rawQuery)
        guard !query.isEmpty else {
            // Recency ordering only kicks in once the user narrows the list; an unfiltered
            // list keeps the store's pinned-first order.
            return type == nil ? result : byRecency(result)
        }

        let maxSpan = query.count * 2
        return byRecency(result.filter { entry in
            let text = entry.textContent ?? ""
            let firstLine = String(text.split(separator: "\n", maxSplits: 1).first ?? "")
            return text.lowercased().contains(query)
                || FuzzyMatch.matches(query, in: firstLine.lowercased(), maxSpan: maxSpan)
                || FuzzyMatch.matches(query, in: (entry.sourceName ?? "").lowercased(), maxSpan: maxSpan)
        })
    }

    /// Highlight positions for a rendered title; `nil` when the query is empty or does not match.
    static func matchedIndices(of rawQuery: String, in title: String) -> [String.Index]? {
        let query = normalized(rawQuery)
        guard !query.isEmpty else { return nil }
        return FuzzyMatch.matchedIndices(of: query, in: title.lowercased(), maxSpan: query.count * 2)
    }

    private static func byRecency(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// Pasteboard side effects of the list. Injected so the model carries no AppKit and stays
/// testable in the host-free bundle.
struct ClipboardBoard {
    var pasteText: (_ text: String, _ richText: Data?) -> Void
    var pasteImage: (_ imageURL: URL) -> Void
    var copyText: (_ text: String, _ richText: Data?) -> Void
    var dismissPanel: () -> Void

    /// No-op board for previews, tests and the storeless model. Computed because the closure
    /// properties make the struct non-Sendable and a stored static would not be concurrency-safe.
    static var inert: ClipboardBoard {
        ClipboardBoard(
            pasteText: { _, _ in },
            pasteImage: { _ in },
            copyText: { _, _ in },
            dismissPanel: {}
        )
    }
}

/// State and mutations of the clipboard history panel: the store-backed rows, the filter
/// that narrows them, the selection, and every write the panel performs.
@MainActor
@Observable
final class ClipboardListModel {
    /// `AppState.setup()` assigns the store before any panel is built, but it runs inside a
    /// `do/catch` that leaves the app running when it fails, so the store can be nil at
    /// runtime. This is the only place that knows: each mutation tolerates the missing
    /// store instead of force-unwrapping it.
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private var board: ClipboardBoard
    /// Pending debounced search, cancelled by the next keystroke or by an immediate recompute.
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Typing runs one FTS query per keystroke otherwise. The query is sub-millisecond on a
    /// five-figure history, but it is a SQLite round trip on the main actor between the keystroke
    /// and the redraw; 150 ms sits below the latency a user can feel and coalesces a typed word
    /// into one search. Injected as nanoseconds so tests can run the search synchronously.
    private let searchDebounceNanos: UInt64

    /// The debounce the panel runs with; the initialiser defaults to none so tests and previews
    /// see results without waiting.
    static let panelSearchDebounceNanos: UInt64 = 150_000_000

    /// Rows in store order: pinned first by `pinned_at`, then `updated_at` descending.
    private(set) var entries: [ClipboardEntry] = []
    /// `entries` narrowed by `searchText` and `typeFilter`, in the order the list shows.
    private(set) var filteredEntries: [ClipboardEntry] = []
    private(set) var selectedIndex = 0
    private(set) var typeFilter: ClipboardTypeFilter?
    private(set) var selectionOrigin: SelectionOrigin = .immediate

    /// How the selection last moved. The list scrolls the selected row into view on any change and
    /// animates only arrow-key movement: animating while the user types makes a live list crawl.
    enum SelectionOrigin {
        case immediate
        case navigation
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            selectionOrigin = .immediate
            refreshFilteredEntries()
            selectedIndex = 0
        }
    }

    init(
        store: ClipboardStore? = nil,
        board: ClipboardBoard = .inert,
        searchDebounceNanos: UInt64 = 0
    ) {
        self.store = store
        self.board = board
        self.searchDebounceNanos = searchDebounceNanos
    }

    var selectedEntry: ClipboardEntry? {
        guard selectedIndex >= 0, selectedIndex < filteredEntries.count else { return nil }
        return filteredEntries[selectedIndex]
    }

    /// The list groups by date only while it is unfiltered, so the view needs this too.
    var isFiltering: Bool {
        typeFilter != nil || !ClipboardFilter.normalized(searchText).isEmpty
    }

    /// The headings the list renders. Grouping is order-dependent derivation over the whole
    /// result set, so it lives here and not in `body`.
    var sections: [ClipboardSection] {
        Self.sections(for: filteredEntries, isFiltering: isFiltering)
    }

    /// Groups by calendar day whatever order the rows arrive in: one heading per day, newest day
    /// first, each day's rows in their incoming order. Pinned rows get a heading of their own only
    /// while the list is unfiltered, which is also when the panel shows date headings at all.
    nonisolated static func sections(
        for entries: [ClipboardEntry],
        isFiltering: Bool,
        calendar: Calendar = .current
    ) -> [ClipboardSection] {
        var pinnedRows: [ClipboardSection.Row] = []
        var rowsByDay: [Date: [ClipboardSection.Row]] = [:]
        for (index, entry) in entries.enumerated() {
            if !isFiltering, entry.isPinned {
                pinnedRows.append(ClipboardSection.Row(index: index, entry: entry))
                continue
            }
            let day = calendar.startOfDay(for: entry.updatedAt)
            rowsByDay[day, default: []].append(ClipboardSection.Row(index: index, entry: entry))
        }

        var sections: [ClipboardSection] = []
        if !pinnedRows.isEmpty {
            sections.append(ClipboardSection(id: .pinned, label: "Pinned", rows: pinnedRows))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        for day in rowsByDay.keys.sorted(by: >) {
            sections.append(
                ClipboardSection(
                    id: .day(day),
                    label: label(for: day, calendar: calendar, formatter: formatter),
                    rows: rowsByDay[day] ?? []
                )
            )
        }
        return sections
    }

    private nonisolated static func label(for day: Date, calendar: Calendar, formatter: DateFormatter) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }
        return formatter.string(from: day)
    }

    /// The message the list area shows instead of rows, or `nil` when it has rows to show.
    var emptyState: ClipboardEmptyState? {
        guard filteredEntries.isEmpty else { return nil }
        guard !entries.isEmpty else { return .noHistory }
        if let typeFilter, ClipboardFilter.normalized(searchText).isEmpty {
            return .noRowsForFilter(typeFilter)
        }
        return .noMatches(typeFilter)
    }

    /// Replaces the store/board references. The panel only reaches `AppState` from
    /// `onAppear`, so dependencies are attached after construction; re-attaching is safe.
    func attach(store: ClipboardStore?, board: ClipboardBoard) {
        self.store = store
        self.board = board
    }

    // MARK: - Selection

    func select(row index: Int) {
        selectionOrigin = .immediate
        selectedIndex = index
    }

    /// Wrapping navigation; returns false when there is nothing to move through.
    @discardableResult
    func selectNext() -> Bool {
        guard !filteredEntries.isEmpty else { return false }
        selectionOrigin = .navigation
        selectedIndex = selectedIndex >= filteredEntries.count - 1 ? 0 : selectedIndex + 1
        return true
    }

    @discardableResult
    func selectPrevious() -> Bool {
        guard !filteredEntries.isEmpty else { return false }
        selectionOrigin = .navigation
        selectedIndex = selectedIndex <= 0 ? filteredEntries.count - 1 : selectedIndex - 1
        return true
    }

    func setTypeFilter(_ filter: ClipboardTypeFilter?) {
        guard typeFilter != filter else { return }
        typeFilter = filter
        selectionOrigin = .immediate
        cancelPendingSearch()
        recomputeFilteredEntries()
        selectedIndex = 0
    }

    func resetSearch() {
        searchText = ""
    }

    // MARK: - Loading

    /// Re-reads the store and clears both filters, selecting the first unpinned row. The
    /// panel calls this on every appearance, so edits made elsewhere (settings, monitor)
    /// show up without the list keeping its own copy of the truth.
    func reload() {
        setEntries(store?.fetchAll() ?? [])
        searchText = ""
        typeFilter = nil
        recomputeFilteredEntries()
        selectedIndex = filteredEntries.firstIndex(where: { !$0.isPinned }) ?? 0
    }

    /// Re-reads the rows without touching the query, the type filter or the selection, for a
    /// store that gained a row while the panel stayed open. The selected entry stays selected
    /// even when a new copy lands above it; an entry that is gone leaves the selection clamped
    /// into range rather than pointing past the end of the list.
    func refreshEntries() {
        setEntries(store?.fetchAll() ?? [])
    }

    // MARK: - Mutations

    func paste(_ entry: ClipboardEntry, formatted: Bool = false) {
        store?.bumpTimestamp(id: entry.id)
        if entry.contentType == ContentType.image, let url = imageURL(for: entry) {
            board.pasteImage(url)
        } else if let text = entry.textContent {
            let richText = formatted ? store?.fetchRawData(id: entry.id) : nil
            board.pasteText(text, richText)
        }
    }

    /// Copy never pastes, so it dismisses the panel itself rather than through `PasteService`.
    func copy(_ entry: ClipboardEntry) {
        store?.bumpTimestamp(id: entry.id)
        if let text = entry.textContent {
            board.copyText(text, store?.fetchRawData(id: entry.id))
        }
        board.dismissPanel()
    }

    func togglePin(_ entry: ClipboardEntry) {
        if entry.isPinned {
            store?.unpin(id: entry.id)
        } else {
            store?.pin(id: entry.id)
        }
        let entryID = entry.id
        setEntries(store?.fetchAll() ?? [])
        if let newIndex = filteredEntries.firstIndex(where: { $0.id == entryID }) {
            selectedIndex = newIndex
        } else {
            selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
        }
    }

    func delete(_ entry: ClipboardEntry) {
        try? store?.delete(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        recomputeFilteredEntries()
        selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
    }

    /// Clears unpinned rows (the store keeps pinned ones and their image files).
    func deleteAll() {
        try? store?.clearAll()
        reload()
    }

    /// Absolute path of an entry's image, or nil when the entry has no image path or no
    /// store is available. The file itself may be gone: the view loads it with `NSImage`
    /// and renders nothing when that fails, which is the existing broken-image handling.
    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let store, let imagePath = entry.imagePath, !imagePath.isEmpty else { return nil }
        return store.imageDir.appendingPathComponent(imagePath)
    }

    /// Index positions to underline in a rendered title for the current search text.
    func matchedIndices(in title: String) -> [String.Index]? {
        ClipboardFilter.matchedIndices(of: searchText, in: title)
    }

    // MARK: - Private

    private func setEntries(_ newEntries: [ClipboardEntry]) {
        entries = newEntries
        cancelPendingSearch()
        recomputeFilteredEntries()
    }

    /// Cancels a pending debounced search and recomputes now, for mutations (type filter, pin,
    /// delete) that must not wait out the debounce.
    private func cancelPendingSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func refreshFilteredEntries() {
        cancelPendingSearch()
        // An empty query keeps the page path synchronous: there is nothing to wait for and the
        // panel must show the loaded rows as soon as it opens.
        guard searchDebounceNanos > 0, !ClipboardFilter.normalized(searchText).isEmpty else {
            recomputeFilteredEntries()
            return
        }
        let delay = searchDebounceNanos
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            searchTask = nil
            recomputeFilteredEntries()
        }
    }

    private func recomputeFilteredEntries() {
        let previousSelection = selectedEntry?.id
        if let results = storeSearchResults() {
            filteredEntries = results
        } else {
            // Fallback paths: an empty query, input the index cannot tokenize (emoji or
            // punctuation only), or an unusable/missing FTS table. All three keep the
            // pre-index behaviour of filtering the loaded page instead of showing nothing.
            filteredEntries = ClipboardFilter.apply(entries, query: searchText, type: typeFilter)
        }
        // The replacement list can be shorter (a narrower query, a row deleted elsewhere), so the
        // selection is re-anchored on the entry it pointed at and clamped into range.
        selectedIndex = filteredEntries.firstIndex { $0.id == previousSelection }
            ?? min(max(selectedIndex, 0), max(0, filteredEntries.count - 1))
    }

    private func storeSearchResults() -> [ClipboardEntry]? {
        guard let store, !ClipboardFilter.normalized(searchText).isEmpty else { return nil }
        return store.search(matching: searchText, type: typeFilter)
    }
}
