import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.relux.app", category: "appstate")

enum PanelMode: Sendable {
    case search
    case clipboard
    case translate
}

@MainActor
@Observable
final class AppState {
    let appSearcher = AppSearcher()
    let scriptSearcher = ScriptSearcher()
    let frecency = FrecencyTracker()
    let extensionRegistry = ExtensionRegistry()

    var clipboardStore: ClipboardStore?
    var clipboardMonitor: ClipboardMonitor?
    var translateStore: TranslateStore?
    let anthropicService = AnthropicService()
    var panelMode: PanelMode = .search
    var previousApp: NSRunningApplication?

    var currentSelection: String?
    var needsFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: "hasCompletedSetup")
    }

    var showMenuBarIcon: Bool = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }

    func setup() throws {
        let clipStore = try ClipboardStore()
        clipboardStore = clipStore
        let monitor = ClipboardMonitor(store: clipStore)
        clipboardMonitor = monitor
        monitor.start()

        let transStore = try TranslateStore()
        translateStore = transStore

        // Clean up expired clipboard entries
        let retentionMonths = UserDefaults.standard.object(forKey: "clipboardRetentionMonths") as? Int ?? 3
        if let cutoffDate = Calendar.current.date(byAdding: .month, value: -retentionMonths, to: Date()) {
            try? clipStore.deleteExpired(before: cutoffDate)
        }
    }

    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
    }

    var maxSearchResults: Int {
        UserDefaults.standard.object(forKey: "maxSearchResults") as? Int ?? 10
    }

    func performSearch(query: String) -> [SearchItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let limit = maxSearchResults
        var appResults = appSearcher.search(query, limit: limit)
        var scriptResults = scriptSearcher.search(query, limit: limit)

        let term = query
        appResults.sort { frecency.boost(query: term, itemId: $0.id) > frecency.boost(query: term, itemId: $1.id) }
        scriptResults.sort { frecency.boost(query: term, itemId: $0.id) > frecency.boost(query: term, itemId: $1.id) }

        return Array((appResults + scriptResults).prefix(limit))
    }

    func recordSelection(query: String, item: SearchItem) {
        frecency.recordSelection(query: query, item: item)
    }

    func recentItems() -> [SearchItem] {
        frecency.recentItems()
    }
}
