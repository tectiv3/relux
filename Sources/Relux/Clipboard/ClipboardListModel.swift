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

    func matches(_ contentType: String) -> Bool {
        switch self {
        case .text: contentType == ContentType.text
        case .image: contentType == ContentType.image
        case .richText: contentType == ContentType.rtf || contentType == ContentType.html
        case .color: contentType == ContentType.color
        }
    }
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

    /// Rows in store order: pinned first by `pinned_at`, then `updated_at` descending.
    private(set) var entries: [ClipboardEntry] = []
    /// `entries` narrowed by `searchText` and `typeFilter`, in the order the list shows.
    private(set) var filteredEntries: [ClipboardEntry] = []
    private(set) var selectedIndex = 0
    private(set) var typeFilter: ClipboardTypeFilter?

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            recomputeFilteredEntries()
            selectedIndex = 0
        }
    }

    init(store: ClipboardStore? = nil, board: ClipboardBoard = .inert) {
        self.store = store
        self.board = board
    }

    var selectedEntry: ClipboardEntry? {
        guard selectedIndex >= 0, selectedIndex < filteredEntries.count else { return nil }
        return filteredEntries[selectedIndex]
    }

    /// The list groups by date only while it is unfiltered, so the view needs this too.
    var isFiltering: Bool {
        typeFilter != nil || !ClipboardFilter.normalized(searchText).isEmpty
    }

    /// Replaces the store/board references. The panel only reaches `AppState` from
    /// `onAppear`, so dependencies are attached after construction; re-attaching is safe.
    func attach(store: ClipboardStore?, board: ClipboardBoard) {
        self.store = store
        self.board = board
    }

    // MARK: - Selection

    func select(row index: Int) {
        selectedIndex = index
    }

    /// Wrapping navigation; returns false when there is nothing to move through.
    @discardableResult
    func selectNext() -> Bool {
        guard !filteredEntries.isEmpty else { return false }
        selectedIndex = selectedIndex >= filteredEntries.count - 1 ? 0 : selectedIndex + 1
        return true
    }

    @discardableResult
    func selectPrevious() -> Bool {
        guard !filteredEntries.isEmpty else { return false }
        selectedIndex = selectedIndex <= 0 ? filteredEntries.count - 1 : selectedIndex - 1
        return true
    }

    func setTypeFilter(_ filter: ClipboardTypeFilter?) {
        guard typeFilter != filter else { return }
        typeFilter = filter
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
        recomputeFilteredEntries()
    }

    private func recomputeFilteredEntries() {
        filteredEntries = ClipboardFilter.apply(entries, query: searchText, type: typeFilter)
    }
}
