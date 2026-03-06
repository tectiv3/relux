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
        }
    }
}

struct OverlayView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var results: [SearchItem] = []
    @State private var selectedIndex: Int = 0

    // Script output streaming state
    @State private var rawAnswer: String = ""
    @State private var isGenerating: Bool = false

    // Actions menu state
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0

    /// Bumped on panel open to force re-search even when query hasn't changed
    @State private var searchTrigger: UUID = .init()

    @State private var streamingTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var answer: String {
        rawAnswer
    }

    private var hasResults: Bool {
        !results.isEmpty || !answer.isEmpty || isGenerating
    }

    private var currentActions: [ItemAction] {
        guard selectedIndex < results.count else { return [] }
        let item = results[selectedIndex]
        switch item.kind {
        case .app:
            return [
                ItemAction(label: "Launch", icon: "arrow.up.forward.app", shortcut: "⏎") {
                    openSelectedItem()
                },
                ItemAction(label: "Show in Finder", icon: "folder", shortcut: nil) {
                    showInFinder()
                },
                ItemAction(label: "Remove from history", icon: "trash", shortcut: nil) {
                    removeFromHistory()
                },
            ]
        case .webSearch:
            return [
                ItemAction(label: "Search", icon: "magnifyingglass", shortcut: "⏎") {
                    openSelectedItem()
                },
            ]
        case .translate:
            return [
                ItemAction(label: "Translate", icon: "character.book.closed", shortcut: "⏎") {
                    openSelectedItem()
                },
            ]
        case .script:
            if !answer.isEmpty, item.meta["outputMode"] == "capture" {
                return [
                    ItemAction(label: "Copy output", icon: "doc.on.clipboard", shortcut: nil) {
                        copyOutput()
                    },
                    ItemAction(label: "Re-run", icon: "arrow.clockwise", shortcut: nil) {
                        openSelectedItem()
                    },
                    ItemAction(label: "Clear", icon: "xmark", shortcut: nil) {
                        clearOutput()
                    },
                ]
            }
            return [
                ItemAction(label: "Run", icon: "play.fill", shortcut: "⏎") {
                    openSelectedItem()
                },
                ItemAction(label: "Remove from history", icon: "trash", shortcut: nil) {
                    removeFromHistory()
                },
            ]
        case .calculator:
            return [
                ItemAction(label: "Copy", icon: "doc.on.clipboard", shortcut: "⏎") {
                    openSelectedItem()
                },
            ]
        case .jwt:
            return [
                ItemAction(label: "Open", icon: "key.viewfinder", shortcut: "⏎") {
                    openSelectedItem()
                },
            ]
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

                if showActions {
                    actionsMenu
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThickMaterial)
                                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(width: 280)
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
        .task(id: "\(query)\(searchTrigger)") {
            performSearch(query)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            showActions = false
            streamingTask?.cancel()
            rawAnswer = ""
            isGenerating = false
            if UserDefaults.standard.bool(forKey: "clearQueryOnOpen") {
                query = ""
            }
            searchTrigger = UUID()
            isSearchFocused = true
        }
        .onAppear {
            isSearchFocused = true
        }
        .onKeyPress(.upArrow) {
            if showActions {
                let actions = currentActions
                guard !actions.isEmpty else { return .ignored }
                actionIndex = actionIndex <= 0 ? actions.count - 1 : actionIndex - 1
                return .handled
            }
            guard !results.isEmpty else { return .ignored }
            selectedIndex = selectedIndex <= 0 ? results.count - 1 : selectedIndex - 1
            return .handled
        }
        .onKeyPress(.downArrow) {
            if showActions {
                let actions = currentActions
                guard !actions.isEmpty else { return .ignored }
                actionIndex = actionIndex >= actions.count - 1 ? 0 : actionIndex + 1
                return .handled
            }
            guard !results.isEmpty else { return .ignored }
            selectedIndex = selectedIndex >= results.count - 1 ? 0 : selectedIndex + 1
            return .handled
        }
        .onKeyPress(.return) {
            if showActions {
                let actions = currentActions
                guard actionIndex < actions.count else { return .ignored }
                actions[actionIndex].action()
                showActions = false
                return .handled
            }
            openSelectedItem()
            return .handled
        }
        .onKeyPress(.escape) {
            if showActions {
                showActions = false
                return .handled
            }
            return .ignored
        }
        .background {
            // Cmd+K to toggle actions menu
            Button("") {
                guard !results.isEmpty, selectedIndex < results.count else { return }
                actionIndex = 0
                showActions.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
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
        let isQueryEmpty = query.trimmingCharacters(in: .whitespaces).isEmpty
        if isQueryEmpty {
            return [("Recent", Array(results.enumerated().map { ($0.offset, $0.element) }))]
        }

        var sections: [(label: String, items: [(index: Int, item: SearchItem)])] = []
        var currentKind: SearchItemKind?
        var currentItems: [(index: Int, item: SearchItem)] = []

        for (index, item) in results.enumerated() {
            if item.kind != currentKind {
                if !currentItems.isEmpty, let kind = currentKind {
                    sections.append((sectionLabel(for: kind), currentItems))
                }
                currentKind = item.kind
                currentItems = []
            }
            currentItems.append((index, item))
        }
        if !currentItems.isEmpty, let kind = currentKind {
            sections.append((sectionLabel(for: kind), currentItems))
        }
        return sections
    }

    private func sectionLabel(for kind: SearchItemKind) -> String {
        switch kind {
        case .app: "Applications"
        case .script: "Scripts"
        case .webSearch: "Web Search"
        case .translate: "Translate"
        case .calculator: "Calculator"
        case .jwt: "JWT Tools"
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
        if item.kind == .app, let path = item.meta["path"] {
            let nsImage = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 24, height: 24)
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
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86400 { return "Updated \(seconds / 3600)h ago" }
        return "Updated \(seconds / 86400)d ago"
    }

    private func resultRow(item: SearchItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            itemIcon(for: item)

            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

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

    private var actionsMenu: some View {
        VStack(spacing: 0) {
            if selectedIndex < results.count {
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

            ForEach(Array(currentActions.enumerated()), id: \.offset) { index, action in
                actionRow(action: action, isSelected: index == actionIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        action.action()
                        showActions = false
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actionRow(action: ItemAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .font(.system(size: 13))
                .frame(width: 20)

            Text(action.label)
                .font(.system(size: 13))

            Spacer()

            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
            }
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
            if showActions {
                keyboardHint(key: "\u{23CE}", label: "Select")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Back")
            } else {
                if selectedIndex < results.count, results[selectedIndex].kind == .calculator {
                    keyboardHint(key: "\u{23CE}", label: "Copy Answer")
                } else {
                    keyboardHint(key: "\u{23CE}", label: "Open")
                }
                keyboardHint(key: "\u{2318}K", label: "Actions")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Close")
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

    private func keyboardHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                )
            Text(label)
        }
    }

    // MARK: - Actions

    private func performSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let selectionItems = selectionQuickActions()
            let selectionIds = Set(selectionItems.map(\.id))
            let recents = appState.recentItems().filter { !selectionIds.contains($0.id) }
            results = selectionItems + recents
        } else {
            var searchResults = appState.performSearch(query: trimmed)
            // Boost selection-aware items to top when selection exists
            if appState.currentSelection != nil {
                let selectionAware = searchResults.filter {
                    $0.kind == .script && $0.meta["acceptsSelection"] == "1"
                }
                let rest = searchResults.filter {
                    !($0.kind == .script && $0.meta["acceptsSelection"] == "1")
                }
                searchResults = selectionAware + rest
            }
            results = searchResults

            // JWT Decoder
            let lower = trimmed.lowercased()
            let isJWTKeyword = lower.contains("jwt")
            let isJWTContent = trimmed.split(separator: ".").count >= 2 && trimmed.count > 20
            let selectionIsJWT = (appState.currentSelection?.split(separator: ".").count ?? 0) >= 2
                && (appState.currentSelection?.count ?? 0) > 20

            if isJWTKeyword || isJWTContent || selectionIsJWT {
                results.insert(SearchItem(
                    id: "jwt-decoder",
                    title: "JWT Decoder",
                    subtitle: "Decode and inspect JSON Web Token",
                    icon: "key.viewfinder",
                    kind: .jwt,
                    meta: [:]
                ), at: 0)
            }

            // Calculator: evaluate math or currency
            if appState.extensionRegistry.isEnabled("calculator"),
               let calcResult = appState.calculatorService.evaluate(trimmed)
            {
                let meta: [String: String] = [
                    "expression": calcResult.expression,
                    "answer": calcResult.answer,
                    "isCurrency": calcResult.isCurrency ? "1" : "0",
                    "sourceCurrency": calcResult.sourceCurrency ?? "",
                    "targetCurrency": calcResult.targetCurrency ?? "",
                    "lastUpdated": calcResult.lastUpdated.map { String($0.timeIntervalSince1970) } ?? "",
                ]
                results.insert(SearchItem(
                    id: "calculator-result",
                    title: calcResult.expression,
                    subtitle: calcResult.answer,
                    icon: "equal.circle",
                    kind: .calculator,
                    meta: meta
                ), at: 0)
            }

            if let selection = appState.currentSelection {
                let preview = String(selection.prefix(80))
                results.insert(SearchItem(
                    id: "translate-selection",
                    title: "Translate",
                    subtitle: preview,
                    icon: "character.book.closed",
                    kind: .translate,
                    meta: [:]
                ), at: 0)
            }
            results.append(SearchItem(
                id: "web-search-ddg",
                title: "Search DuckDuckGo",
                subtitle: trimmed,
                icon: "magnifyingglass",
                kind: .webSearch,
                meta: ["query": trimmed]
            ))
        }
        selectedIndex = 0
        showActions = false
    }

    private func kindLabel(for item: SearchItem) -> String {
        switch item.kind {
        case .app: "Application"
        case .webSearch: "Web Search"
        case .script: "Script"
        case .translate: "Command"
        case .calculator: "Calculator"
        case .jwt: "Extension"
        }
    }

    private func selectionQuickActions() -> [SearchItem] {
        guard let selection = appState.currentSelection else { return [] }
        let preview = String(selection.prefix(80))
        var items: [SearchItem] = [
            SearchItem(
                id: "translate-selection", title: "Translate", subtitle: preview,
                icon: "character.book.closed", kind: .translate, meta: [:]
            ),
            SearchItem(
                id: "web-search-selection", title: "Search DuckDuckGo", subtitle: preview,
                icon: "magnifyingglass", kind: .webSearch, meta: ["query": selection]
            ),
        ]
        if selection.split(separator: ".").count >= 2, selection.count > 20 {
            items.insert(SearchItem(
                id: "jwt-decoder", title: "JWT Decoder", subtitle: preview,
                icon: "key.viewfinder", kind: .jwt, meta: [:]
            ), at: 0)
        }
        return items
    }

    private func openSelectedItem() {
        guard selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        if item.kind != .webSearch, item.kind != .calculator, item.kind != .jwt {
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
            if let q = item.meta["query"],
               var components = URLComponents(string: "https://duckduckgo.com/")
            {
                components.queryItems = [URLQueryItem(name: "q", value: q)]
                if let url = components.url {
                    NSWorkspace.shared.open(url)
                }
            }
        case .translate:
            appState.panelMode = .translate
        case .script:
            if let command = item.meta["command"] {
                let acceptsStdin = item.meta["acceptsSelection"] == "1"
                let stdin: String? = acceptsStdin ? (query.isEmpty ? appState.currentSelection : query) : nil
                let env = appState.scriptSearcher.buildEnvironment()
                let outputMode = ScriptOutputMode(rawValue: item.meta["outputMode"] ?? "") ?? .none

                switch outputMode {
                case .capture:
                    streamingTask?.cancel()
                    showActions = false
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
                    NSApp.keyWindow?.close()
                    if let previousApp {
                        ScriptRunner.runAndReplace(command, env: env, stdin: stdin, in: previousApp)
                    }
                case .none:
                    NSApp.keyWindow?.close()
                    ScriptRunner.run(command, env: env, stdin: stdin)
                }
            }
        case .calculator:
            if let answer = item.meta["answer"] {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            }
            NSApp.keyWindow?.close()
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
        }
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        showActions = false
    }

    private func clearOutput() {
        streamingTask?.cancel()
        rawAnswer = ""
        isGenerating = false
        showActions = false
    }

    private func showInFinder() {
        guard selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        if let path = item.meta["path"] {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
        showActions = false
    }

    private func removeFromHistory() {
        guard selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        appState.frecency.removeItem(id: item.id)
        results.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, results.count - 1)
        showActions = false
    }
}

// MARK: - Supporting Types

private struct ItemAction {
    let label: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}
