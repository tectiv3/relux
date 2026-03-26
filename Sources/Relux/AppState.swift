import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.relux.app", category: "appstate")

enum PanelMode {
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
    let systemSettingsSearcher = SystemSettingsSearcher()

    let gestureBindingManager = GestureBindingManager()

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
        extensionRegistry.register(
            id: "gestures", name: "Gesture Shortcuts", icon: "hand.draw", defaultEnabled: true
        )
        gestureBindingManager.startIfEnabled(registry: extensionRegistry)
    }

    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
    }

    var maxSearchResults: Int {
        UserDefaults.standard.object(forKey: "maxSearchResults") as? Int ?? 10
    }

    func performSearch(query: String, stdinValue: String? = nil) -> [SearchItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let limit = maxSearchResults
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        var all: [SearchItem] = []
        all += appSearcher.search(trimmed, limit: limit)
        all += scriptSearcher.search(trimmed, limit: limit, stdinValue: stdinValue)
        all += systemSettingsSearcher.search(trimmed, limit: limit)
        all += syntheticItems(query: trimmed, selection: stdinValue)

        // Selection-aware script bonus
        if stdinValue != nil {
            for idx in all.indices where all[idx].kind == .script && all[idx].meta["acceptsInput"] == "1" {
                all[idx].score += 200
            }
        }

        // Frecency boost applied to ALL items
        for idx in all.indices {
            all[idx].score += frecency.boost(query: trimmed, itemId: all[idx].id)
        }

        all.sort { $0.score > $1.score }
        return Array(all.prefix(limit))
    }

    private func syntheticItems(query: String, selection: String?) -> [SearchItem] {
        var items: [SearchItem] = []

        if let calc = calculatorItem(query: query) { items.append(calc) }
        if let jwt = jwtItem(query: query, selection: selection) { items.append(jwt) }
        if let trans = translateItem(query: query, selection: selection) { items.append(trans) }
        items.append(webSearchItem(query: query))

        return items
    }

    private func calculatorItem(query: String) -> SearchItem? {
        guard extensionRegistry.isReady("calculator"),
              let calcResult = calculatorService.evaluate(query) else { return nil }
        return SearchItem(
            id: "calculator-result",
            title: calcResult.expression,
            subtitle: calcResult.answer,
            icon: "equal.circle",
            kind: .calculator,
            meta: [
                "expression": calcResult.expression,
                "answer": calcResult.answer,
                "isCurrency": calcResult.isCurrency ? "1" : "0",
                "sourceCurrency": calcResult.sourceCurrency ?? "",
                "targetCurrency": calcResult.targetCurrency ?? "",
                "lastUpdated": calcResult.lastUpdated.map { String($0.timeIntervalSince1970) } ?? "",
            ],
            score: 1050
        )
    }

    private func jwtItem(query: String, selection: String?) -> SearchItem? {
        guard extensionRegistry.isReady("jwt") else { return nil }
        let isJWTKeyword = query.lowercased().contains("jwt")
        let isJWTContent = query.split(separator: ".").count >= 2 && query.count > 20
        let selectionIsJWT = (selection?.split(separator: ".").count ?? 0) >= 2
            && (selection?.count ?? 0) > 20
        guard isJWTKeyword || isJWTContent || selectionIsJWT else { return nil }
        return SearchItem(
            id: "jwt-decoder",
            title: "JWT Decoder",
            subtitle: "Decode and inspect JSON Web Token",
            icon: "key.viewfinder",
            kind: .jwt,
            meta: [:],
            score: isJWTKeyword ? 1000 : 900
        )
    }

    private func translateItem(query: String, selection: String?) -> SearchItem? {
        guard extensionRegistry.isReady("translate") else { return nil }
        let text = selection ?? query
        guard !text.isEmpty else { return nil }
        return SearchItem(
            id: "translate-selection",
            title: "Translate",
            subtitle: String(text.prefix(80)),
            icon: "character.book.closed",
            kind: .translate,
            meta: [:],
            score: 800
        )
    }

    private func webSearchItem(query: String) -> SearchItem {
        let isURL = query.hasPrefix("http://") || query.hasPrefix("https://")
            || query.range(of: #"^[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}"#, options: .regularExpression) != nil
        if isURL {
            return SearchItem(
                id: "web-open-url", title: "Open URL", subtitle: query,
                icon: "link", kind: .webSearch, meta: ["url": query], score: 500
            )
        }
        return SearchItem(
            id: "web-search-ddg", title: "Search DuckDuckGo", subtitle: query,
            icon: "magnifyingglass", kind: .webSearch, meta: ["query": query], score: 200
        )
    }

    func recordSelection(query: String, item: SearchItem) {
        frecency.recordSelection(query: query, item: item)
    }

    func recentItems() -> [SearchItem] {
        frecency.recentItems()
    }
}
