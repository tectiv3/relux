import AppKit
import os
import ReluxCore
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
    let frecency = FrecencyTracker(now: Date())
    /// Teaches `frecency` from launches/activations the panel never saw; created in `setup()`.
    private(set) var activityObserver: AppActivityObserver?
    let extensionRegistry = ExtensionRegistry()
    private let calculatorService = CalculatorService()
    let systemSettingsSearcher = SystemSettingsSearcher()

    let settings: SettingsStore
    let gestureBindingManager: GestureBindingManager

    var volumeHUDController: VolumeHUDController?

    var clipboardStore: ClipboardStore?
    var clipboardMonitor: ClipboardMonitor?
    var translateStore: TranslateStore?
    /// Owns every translate-panel store write; the view only renders it.
    var translationService: TranslationService?
    let anthropicService = AnthropicService()
    var panelMode: PanelMode = .search
    var panelClosedAt: Date = .distantPast
    var previousApp: NSRunningApplication?

    var currentSelection: String?
    /// Bumped when async selection capture completes, so views can refresh derived results.
    var selectionCaptureID = UUID()
    init() {
        let store = SettingsStore()
        settings = store
        gestureBindingManager = GestureBindingManager(settings: store)
    }

    var needsFirstRun: Bool {
        settings.isFirstRun
    }

    func setup() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Relux", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: dir.appendingPathComponent("relux.db").path)
        try ReluxSchema.migrate(database)

        let clipStore = try ClipboardStore(db: database)
        clipboardStore = clipStore
        let monitor = ClipboardMonitor(store: clipStore, settings: settings)
        clipboardMonitor = monitor
        monitor.start()

        let translations = TranslateStore(db: database)
        translateStore = translations
        // Bind the service locally so the closures hold AnthropicService, not AppState.
        let anthropic = anthropicService
        translationService = TranslationService(
            store: translations,
            model: { anthropic.model },
            stream: { text, targetLanguage in
                anthropic.translate(text: text, targetLanguage: targetLanguage)
            }
        )

        // Clean up expired clipboard entries
        let retentionMonths = settings.clipboardRetentionMonths
        if let cutoffDate = Calendar.current.date(byAdding: .month, value: -retentionMonths, to: Date()) {
            try? clipStore.deleteExpired(before: cutoffDate)
        }

        calculatorService.warmUp()

        let observer = AppActivityObserver(tracker: frecency)
        observer.start()
        activityObserver = observer

        extensionRegistry.register(
            id: "translate", name: "Translate", icon: "character.book.closed",
            defaultEnabled: true, availabilityCheck: { anthropic.hasApiKey }
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
        extensionRegistry.register(
            id: "volumeHUD", name: "Volume HUD", icon: "speaker.wave.3", defaultEnabled: false
        )
        gestureBindingManager.startIfEnabled(registry: extensionRegistry)
        if extensionRegistry.isEnabled("volumeHUD") {
            setVolumeHUDEnabled(true)
        }
    }

    func setVolumeHUDEnabled(_ enabled: Bool) {
        if enabled {
            if volumeHUDController == nil {
                volumeHUDController = VolumeHUDController()
            }
            volumeHUDController?.start()
        } else {
            volumeHUDController?.stop()
        }
    }

    func markSetupComplete() {
        settings.hasCompletedSetup = true
    }

    var maxSearchResults: Int {
        settings.maxSearchResults
    }

    func performSearch(query: String, stdinValue: String? = nil) -> [SearchItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let limit = maxSearchResults
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        var all: [SearchItem] = []
        let tracker = frecency
        // One instant for the whole query, so every row decays against the same clock.
        let now = Date()
        all += appSearcher.search(
            trimmed,
            limit: AppSearcher.candidateLimit,
            usage: { path in tracker.appUsage(query: trimmed, path: path, now: now) },
            now: now
        )
        all += scriptSearcher.search(trimmed, limit: limit, stdinValue: stdinValue)
        all += systemSettingsSearcher.search(trimmed, limit: limit)
        all += syntheticItems(query: trimmed, selection: stdinValue)

        // Selection-aware script bonus
        if stdinValue != nil {
            for idx in all.indices where all[idx].kind == .script && all[idx].meta["acceptsInput"] == "1" {
                all[idx].score += 200
            }
        }

        // App rows are already ranked with usage by AppSearcher; other kinds get
        // the usage boost here because they have no fuzzy app ladder.
        for idx in all.indices where all[idx].kind != .app {
            all[idx].score += tracker.usageBoost(query: trimmed, itemId: all[idx].id, now: now)
        }

        all.sort { $0.score > $1.score }
        return Array(all.prefix(limit))
    }

    private func syntheticItems(query: String, selection: String?) -> [SearchItem] {
        var items: [SearchItem] = []

        if let calc = calculatorItem(query: query) {
            items.append(calc)
        }
        if let jwt = jwtItem(query: query, selection: selection) {
            items.append(jwt)
        }
        if let trans = translateItem(query: query, selection: selection) {
            items.append(trans)
        }
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
            score: 100
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
        frecency.recordSelection(query: query, item: item, now: Date())
        // Opening an app from the panel is also a launch + activation the observer will
        // see; it already counted, so the ambient event must not add a second one.
        if item.kind == .app, let path = item.meta["path"] {
            activityObserver?.suppress(path: path)
        }
    }

    /// Persist debounced ambient usage and stop observing. Called on terminate.
    func shutdown() {
        activityObserver?.stop()
        activityObserver = nil
        frecency.flush(now: Date())
    }

    func recentItems() -> [SearchItem] {
        frecency.recentItems()
    }
}
