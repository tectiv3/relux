import ReluxCore
import SwiftUI

struct PanelRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch appState.panelMode {
            case .search:
                OverlayView()
            case .clipboard:
                ClipboardHistoryView()
            case .translate:
                TranslateView()
            case .jwt:
                JWTView()
            }
        }
        .background {
            Button("") {
                NSApp.keyWindow?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            .keyboardShortcut(",", modifiers: .command)
            .hidden()

            Button("") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .hidden()
        }
    }
}

struct OverlayView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var results: [SearchItem] = []
    @State private var selectedIndex: Int = 0

    /// Set by an explicit navigation (arrows, Tab, Cmd+1...9, a row click). Until then the
    /// highlight belongs to the ranking and must follow it across refreshes instead of being
    /// restored by identity — see `ResultSelection.indexAfterRefresh`.
    @State private var userMovedSelection = false

    /// The query `results` currently reflect, so a typed change can be told apart from a
    /// selection-capture or panel-open refresh of the same query.
    @State private var resultsQuery: String = ""

    // Script output streaming state
    @State private var rawAnswer: String = ""
    @State private var isGenerating: Bool = false

    @State private var menu = ActionSelection()

    /// Bumped on panel open to force re-search even when query hasn't changed
    @State private var searchTrigger: UUID = .init()

    @State private var streamingTask: Task<Void, Never>?
    @State private var runningAppPaths: Set<String> = []
    @FocusState private var isSearchFocused: Bool

    private var answer: String {
        rawAnswer
    }

    private var hasResults: Bool {
        !results.isEmpty || !answer.isEmpty || isGenerating
    }

    private var currentActions: [Action] {
        guard ResultSelection.isRow(selectedIndex, in: results.count) else { return [] }
        let item = results[selectedIndex]
        let hasCapturedOutput = !answer.isEmpty && item.meta["outputMode"] == "capture"
        return PanelActions.search(kind: item.kind, hasCapturedOutput: hasCapturedOutput).map { descriptor in
            Action(descriptor) {
                // Only search-panel kinds are built above, so the remaining cases are unreachable.
                switch descriptor.kind {
                case .showInFinder: showInFinder()
                case .removeFromHistory: removeFromHistory()
                case .copyOutput: copyOutput()
                case .clearOutput: clearOutput()
                default: openSelectedItem()
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            searchBar
            Divider()

            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    if !results.isEmpty {
                        resultsSection
                    }

                    if !answer.isEmpty || isGenerating {
                        Divider()
                        answerSection
                    }
                }

                if menu.isOpen {
                    ActionOverlay(
                        actions: currentActions,
                        selectedIndex: menu.index,
                        width: 280,
                        placement: .inline,
                        onSelect: runAction,
                        header: { actionMenuHeader }
                    )
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
                }
            }

            Spacer(minLength: 0)

            Divider()
            bottomBar
        }
        .frame(width: 750)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: "\(query)\(searchTrigger)\(appState.selectionCaptureID)") {
            performSearch(query)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard appState.panelMode == .search else { return }
            menu.close()
            streamingTask?.cancel()
            rawAnswer = ""
            isGenerating = false
            if appState.settings.clearQueryOnOpen {
                query = ""
            }
            userMovedSelection = false
            searchTrigger = UUID()
            focusSearchField()
        }
        .onAppear {
            focusSearchField()
        }
        .onKeyPress(.upArrow) {
            if menu.isOpen {
                return menu.moveUp(count: currentActions.count) ? .handled : .ignored
            }
            guard !results.isEmpty else { return .ignored }
            selectedIndex = ResultSelection.retreated(selectedIndex, count: results.count)
            userMovedSelection = true
            return .handled
        }
        .onKeyPress(.downArrow) {
            if menu.isOpen {
                return menu.moveDown(count: currentActions.count) ? .handled : .ignored
            }
            guard !results.isEmpty else { return .ignored }
            selectedIndex = ResultSelection.advanced(selectedIndex, count: results.count)
            userMovedSelection = true
            return .handled
        }
        .onKeyPress(.return) {
            if menu.isOpen {
                guard let index = menu.activationIndex(count: currentActions.count) else { return .ignored }
                runAction(index)
                return .handled
            }
            openSelectedItem()
            return .handled
        }
        .onKeyPress(.escape) {
            if menu.isOpen {
                menu.close()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.tab) {
            // Tab means "next row", not "complete": no result kind carries a completable keyword
            // (the DuckDuckGo hint's query already equals the text field), so completing would be
            // a no-op and stealing Tab for it would break the expected forward-movement behaviour.
            if menu.isOpen {
                return menu.moveDown(count: currentActions.count) ? .handled : .ignored
            }
            guard !results.isEmpty else { return .ignored }
            selectedIndex = ResultSelection.advanced(selectedIndex, count: results.count)
            userMovedSelection = true
            return .handled
        }
        .background {
            Group {
                // Cmd+K to toggle actions menu
                Button("") {
                    menu.toggle(isAvailable: ResultSelection.isRow(selectedIndex, in: results.count))
                }
                .keyboardShortcut("k", modifiers: .command)

                // Cmd+Return: secondary action, reveal the selected result's file in Finder.
                Button("") {
                    revealSelectedInFinder()
                }
                .keyboardShortcut(.return, modifiers: .command)

                // Cmd+1...Cmd+9: open the Nth row directly.
                ForEach(1 ... 9, id: \.self) { number in
                    Button("") {
                        openRow(number)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
            }
            .hidden()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 16))
            TextField("Search apps and scripts...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Results Section

    private var groupedResults: [(label: String, items: [(index: Int, item: SearchItem)])] {
        var sectionOrder: [SearchItemKind] = []
        var sectionItems: [SearchItemKind: [(index: Int, item: SearchItem)]] = [:]

        for (index, item) in results.enumerated() {
            if sectionItems[item.kind] == nil {
                sectionOrder.append(item.kind)
            }
            sectionItems[item.kind, default: []].append((index, item))
        }

        return sectionOrder.compactMap { kind in
            guard let items = sectionItems[kind] else { return nil }
            return (sectionLabel(for: kind), items)
        }
    }

    private func sectionLabel(for kind: SearchItemKind) -> String {
        switch kind {
        case .app: "Applications"
        case .script: "Scripts"
        case .webSearch: "Web Search"
        case .translate: "Translate"
        case .calculator: "Calculator"
        case .jwt: "JWT Tools"
        case .systemSettings: "System Settings"
        }
    }

    private var resultsSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 4)
                    ForEach(Array(groupedResults.enumerated()), id: \.element.label) { _, section in
                        Text(section.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(section.items, id: \.item.id) { index, item in
                            Group {
                                if item.kind == .calculator {
                                    calculatorCard(item: item, isSelected: index == selectedIndex)
                                } else {
                                    resultRow(item: item, isSelected: index == selectedIndex)
                                }
                            }
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                userMovedSelection = true
                                openSelectedItem()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func itemIcon(for item: SearchItem) -> some View {
        if item.kind == .app, let path = item.meta["path"], let nsImage = AppIconCache.icon(forPath: path) {
            let isRunning = runningAppPaths.contains(path)
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottom) {
                    if isRunning {
                        Circle()
                            .fill(.white.opacity(0.5))
                            .frame(width: 6, height: 6)
                            .offset(y: 4)
                    }
                }
        } else {
            Image(systemName: item.icon)
                .foregroundColor(.secondary)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
        }
    }

    private func calculatorCard(item: SearchItem, isSelected: Bool) -> some View {
        let expression = item.meta["expression"] ?? item.title
        let answer = item.meta["answer"] ?? ""
        let isCurrency = item.meta["isCurrency"] == "1"
        let sourceCurrency = item.meta["sourceCurrency"]
        let targetCurrency = item.meta["targetCurrency"]
        let lastUpdated = item.meta["lastUpdated"].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }

        return HStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(expression)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                if isCurrency, let source = sourceCurrency {
                    Text(source)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
                if isCurrency, let updated = lastUpdated {
                    Text(relativeTime(updated))
                        .font(.system(size: 9))
                        .foregroundColor(isSelected ? .white.opacity(0.4) : .secondary.opacity(0.7))
                }
            }
            .frame(width: 80)

            VStack(spacing: 4) {
                Text(answer)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                if isCurrency, let target = targetCurrency {
                    Text(target)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .padding(.horizontal, 4)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 {
            return "Updated just now"
        }
        if seconds < 3600 {
            return "Updated \(seconds / 60)m ago"
        }
        if seconds < 86400 {
            return "Updated \(seconds / 3600)h ago"
        }
        return "Updated \(seconds / 86400)d ago"
    }

    private func resultRow(item: SearchItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            itemIcon(for: item)

            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            if item.isNew {
                Text("NEW")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.blue)
                    )
            }

            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white.opacity(0.5) : .secondary)
                .lineLimit(1)

            Spacer()

            Text(kindLabel(for: item))
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white.opacity(0.5) : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    // MARK: - Actions Menu

    @ViewBuilder
    private var actionMenuHeader: some View {
        if ResultSelection.isRow(selectedIndex, in: results.count) {
            let item = results[selectedIndex]
            HStack(spacing: 6) {
                itemIcon(for: item)
                    .scaleEffect(0.7)
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()
        }
    }

    /// Runs a menu row and closes the menu, for both the mouse and the Return key.
    private func runAction(_ index: Int) {
        let actions = currentActions
        guard index >= 0, index < actions.count else { return }
        actions[index].handler()
        menu.close()
    }

    // MARK: - Answer Section

    private var answerSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if isGenerating, answer.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 4)
                }
                if !answer.isEmpty {
                    Text(answer)
                        .textSelection(.enabled)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .frame(minHeight: 60, maxHeight: 350)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if menu.isOpen {
                KeyboardHint(key: "\u{23CE}", label: "Select")
                KeyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                KeyboardHint(key: "esc", label: "Back")
            } else {
                if ResultSelection.isRow(selectedIndex, in: results.count), results[selectedIndex].kind == .calculator {
                    KeyboardHint(key: "\u{23CE}", label: "Copy Answer")
                } else {
                    KeyboardHint(key: "\u{23CE}", label: "Open")
                }
                KeyboardHint(key: "\u{2318}K", label: "Actions")
                if ResultSelection.isRow(selectedIndex, in: results.count), results[selectedIndex].meta["path"] != nil {
                    KeyboardHint(key: "\u{2318}\u{23CE}", label: "Reveal")
                }
                KeyboardHint(key: "\u{21E5}", label: "Next")
                KeyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                KeyboardHint(key: "esc", label: "Close")
            }
            Spacer()
            if let selection = appState.currentSelection {
                HStack(spacing: 4) {
                    Image(systemName: "text.cursor")
                    Text(String(selection.prefix(30)))
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
                .opacity(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    // MARK: - Actions

    private func performSearch(_ text: String) {
        // Captured before the results array is replaced so the refresh can restore the highlight
        // by identity: every keystroke otherwise snapped the selection back to the first row.
        let previousSelectionID = ResultSelection.isRow(selectedIndex, in: results.count)
            ? results[selectedIndex].id : nil
        runningAppPaths = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
        )
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let selectionItems = selectionQuickActions()
            let selectionIds = Set(selectionItems.map(\.id))
            var recents = appState.recentItems().filter { !selectionIds.contains($0.id) }

            if let selection = appState.currentSelection {
                let scriptsByID = Dictionary(
                    uniqueKeysWithValues: appState.scriptSearcher.scripts.map { ("script:\($0.id)", $0) }
                )

                // 1. Find all scripts that match the current selection
                // We want these at the top, regardless of whether they are in recents or not
                let matching = appState.scriptSearcher.scripts
                    .filter { $0.inputMode.acceptsInput && $0.inputFilter.matches(selection) }
                    .map { script in
                        SearchItem(
                            id: "script:\(script.id)",
                            title: script.title,
                            subtitle: script.command,
                            icon: "terminal",
                            kind: .script,
                            meta: [
                                "command": script.command,
                                "acceptsInput": "1",
                                "inputMode": script.inputMode.rawValue,
                                "outputMode": script.outputMode.rawValue,
                            ]
                        )
                    }

                let matchingIds = Set(matching.map(\.id))

                // 2. Filter recents
                recents.removeAll { item in
                    // Remove if it's already in matching list (to avoid duplicates and ensure promotion)
                    if matchingIds.contains(item.id) {
                        return true
                    }

                    // Remove if it's a script that accepts selection but doesn't match the current one
                    // (Using fresh script definition instead of stale meta)
                    if item.kind == .script,
                       let script = scriptsByID[item.id],
                       script.inputMode.acceptsInput
                    {
                        return !script.inputFilter.matches(selection)
                    }

                    return false
                }

                results = ResultGrouping.groupByKind(matching + selectionItems + recents)
            } else {
                results = ResultGrouping.groupByKind(selectionItems + recents)
            }
        } else {
            results = appState.performSearch(query: trimmed, stdinValue: appState.currentSelection)

            // Deduplicate by id, preserving order
            var seen = Set<String>()
            results = results.filter { seen.insert($0.id).inserted }

            // Group by kind so display order matches navigation order
            results = ResultGrouping.groupByKind(results)
        }
        // Restore against the grouped array, which is what `selectedIndex` indexes into.
        selectedIndex = ResultSelection.indexAfterRefresh(
            of: previousSelectionID,
            userMoved: userMovedSelection,
            in: results,
            previousQuery: resultsQuery,
            newQuery: text
        )
        if resultsQuery != text {
            userMovedSelection = false
            resultsQuery = text
        }
        menu.close()
    }

    private func kindLabel(for item: SearchItem) -> String {
        switch item.kind {
        case .app: "Application"
        case .webSearch: "Web Search"
        case .script: "Script"
        case .translate: "Extension"
        case .calculator: "Extension"
        case .jwt: "Extension"
        case .systemSettings: "System Settings"
        }
    }

    private func selectionQuickActions() -> [SearchItem] {
        guard let selection = appState.currentSelection else { return [] }
        let preview = String(selection.prefix(80))
        var items: [SearchItem] = [
            SearchItem(
                id: "web-search-selection", title: "Search DuckDuckGo", subtitle: preview,
                icon: "magnifyingglass", kind: .webSearch, meta: ["query": selection]
            ),
        ]
        if appState.extensionRegistry.isReady("translate") {
            items.insert(SearchItem(
                id: "translate-selection", title: "Translate", subtitle: preview,
                icon: "character.book.closed", kind: .translate, meta: [:]
            ), at: 0)
        }
        if appState.extensionRegistry.isReady("jwt"), selection.split(separator: ".").count >= 2, selection.count > 20 {
            items.insert(SearchItem(
                id: "jwt-decoder", title: "JWT Decoder", subtitle: preview,
                icon: "key.viewfinder", kind: .jwt, meta: [:]
            ), at: 0)
        }
        return items
    }

    private func openSelectedItem() {
        guard ResultSelection.isRow(selectedIndex, in: results.count) else { return }
        var item = results[selectedIndex]
        // Record for frecency (scripts deferred until stdin is computed)
        if item.kind != .webSearch, item.kind != .calculator, item.kind != .jwt, item.kind != .script {
            appState.recordSelection(query: query, item: item)
        }
        switch item.kind {
        case .app:
            if let path = item.meta["path"] {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: path),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        case .webSearch:
            if let rawURL = item.meta["url"] {
                // Direct URL — open it, prepending https:// if needed
                let urlString = rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://")
                    ? rawURL : "https://\(rawURL)"
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            } else if let query = item.meta["query"],
                      var components = URLComponents(string: "https://duckduckgo.com/")
            {
                components.queryItems = [URLQueryItem(name: "q", value: query)]
                if let url = components.url {
                    NSWorkspace.shared.open(url)
                }
            }
        case .translate:
            if appState.currentSelection == nil, !query.isEmpty {
                appState.currentSelection = query
            }
            appState.panelMode = .translate
        case .script:
            if var command = item.meta["command"] {
                let inputMode = InputMode(rawValue: item.meta["inputMode"] ?? "") ?? .none
                let rawInput: String? = inputMode.acceptsInput
                    ? (query.isEmpty ? (appState.currentSelection ?? item.meta["lastInput"]) : query)
                    : nil
                if let rawInput {
                    item.meta["lastInput"] = rawInput
                }

                // Determine stdin vs argument delivery
                var stdin: String?
                if let rawInput {
                    let sanitized = rawInput.replacingOccurrences(of: "\0", with: "")
                    switch inputMode {
                    case .stdin:
                        stdin = sanitized
                    case .argument:
                        let escaped = sanitized.replacingOccurrences(of: "'", with: "'\\''")
                        command += " '\(escaped)'"
                    case .none:
                        break
                    }
                }

                var recorded = item
                if let rawInput {
                    let cleaned = String(rawInput.prefix(80))
                        .unicodeScalars.filter { CharacterSet.controlCharacters.inverted.contains($0) }
                    recorded.subtitle = String(cleaned)
                }
                appState.recordSelection(query: query, item: recorded)
                let env = appState.scriptSearcher.buildEnvironment()
                let outputMode = ScriptOutputMode(rawValue: item.meta["outputMode"] ?? "") ?? .none

                switch outputMode {
                case .capture:
                    streamingTask?.cancel()
                    menu.close()
                    isGenerating = true
                    rawAnswer = ""
                    streamingTask = Task { @MainActor in
                        for await chunk in ScriptRunner.stream(command, env: env, stdin: stdin) {
                            rawAnswer += chunk
                        }
                        isGenerating = false
                    }
                case .replace:
                    let previousApp = appState.previousApp
                    dismissPanel()
                    if let previousApp {
                        ScriptRunner.runAndReplace(command, env: env, stdin: stdin, in: previousApp)
                    }
                case .none:
                    dismissPanel()
                    ScriptRunner.run(command, env: env, stdin: stdin)
                }
            }
        case .calculator:
            if let answer = item.meta["answer"] {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            }
            dismissPanel()
        case .jwt:
            let token = item.meta["token"] ?? appState.currentSelection
            if let token, !token.isEmpty {
                // Validate before opening — must have decodable parts
                let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
                guard parts.count >= 2 else {
                    Toast.show("Not a valid JWT token")
                    return
                }
                appState.currentSelection = token
            }
            appState.panelMode = .jwt
        case .systemSettings:
            if let urlString = item.meta["url"], let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            dismissPanel()
        }
    }

    private func dismissPanel() {
        appState.currentSelection = nil
        appState.panelClosedAt = Date()
        NSApp.keyWindow?.close()
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        menu.close()
    }

    private func clearOutput() {
        streamingTask?.cancel()
        rawAnswer = ""
        isGenerating = false
        menu.close()
    }

    /// Cmd+Return and the "Show in Finder" action. Only app results carry a file path; hints,
    /// web searches, scripts, calculator and settings rows have nothing to reveal, so they no-op.
    private func revealSelectedInFinder() {
        guard ResultSelection.isRow(selectedIndex, in: results.count),
              let path = results[selectedIndex].meta["path"],
              FileManager.default.fileExists(atPath: path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        dismissPanel()
    }

    private func showInFinder() {
        revealSelectedInFinder()
        menu.close()
    }

    /// Cmd+N: open the Nth row directly. Out-of-range caps are a no-op.
    private func openRow(_ number: Int) {
        guard let index = ResultSelection.rowIndex(forCommandKey: number, rowCount: results.count)
        else { return }
        selectedIndex = index
        userMovedSelection = true
        openSelectedItem()
    }

    /// `@FocusState` written inside the key-change notification lands before the window finishes
    /// activating, so the field editor starts out unfocused. One run-loop turn is enough; the old
    /// 50 ms timer was a guess at the same thing.
    /// Mode swaps need no extra hook: PanelRootView rebuilds this view on the way back to `.search`,
    /// so `onAppear` runs even though the window never stops being key.
    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func removeFromHistory() {
        guard ResultSelection.isRow(selectedIndex, in: results.count) else { return }
        let item = results[selectedIndex]
        appState.frecency.removeItem(id: item.id)
        results.remove(at: selectedIndex)
        // The list can end up empty, where `count - 1` is -1; the highlight has to stay on row 0.
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        menu.close()
    }
}
