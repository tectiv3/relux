import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.relux.app", category: "appstate")

enum PanelMode: Sendable {
    case search
    case clipboard
    case translate
    case jwt
}

@MainActor
@Observable
final class AppState {
    let appSearcher = AppSearcher()
    let scriptSearcher = ScriptSearcher()
    let frecency = FrecencyTracker()
    let extensionRegistry = ExtensionRegistry()
    let calculatorService = CalculatorService()

    var clipboardStore: ClipboardStore?
    var clipboardMonitor: ClipboardMonitor?
    var translateStore: TranslateStore?
    let anthropicService = AnthropicService()
    var panelMode: PanelMode = .search
    var panelClosedAt: Date = .distantPast
    var previousApp: NSRunningApplication?

    var currentSelection: String?
    var needsFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: "hasCompletedSetup")
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

        calculatorService.warmUp()

        let anthro = anthropicService
        extensionRegistry.register(
            id: "translate", name: "Translate", icon: "character.book.closed",
            defaultEnabled: true, availabilityCheck: { anthro.hasApiKey }
        )
        extensionRegistry.register(
            id: "calculator", name: "Calculator", icon: "equal.circle", defaultEnabled: true
        )
        extensionRegistry.register(
            id: "jwt", name: "JWT Decoder", icon: "key.viewfinder", defaultEnabled: true
        )
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
