import SwiftUI

struct OverlayView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var results: [SearchItem] = []
    @State private var selectedIndex: Int = 0

    // LLM generation state
    @State private var rawAnswer: String = ""
    @State private var isGenerating: Bool = false

    // Actions menu state
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0

    /// Display-ready answer with thinking blocks stripped
    private var answer: String {
        Self.stripThinkingBlocks(rawAnswer)
    }

    private var isThinking: Bool {
        rawAnswer.contains("<think>") && !rawAnswer.contains("</think>")
    }

    private var statusMessage: String? {
        if appState.isIndexing {
            if let p = appState.indexProgress {
                return "Indexing notes (\(p.current)/\(p.total))..."
            }
            return "Indexing notes..."
        }
        return nil
    }

    private var hasResults: Bool {
        !results.isEmpty || !answer.isEmpty || isGenerating
    }

    private var currentActions: [ItemAction] {
        guard selectedIndex < results.count else { return [] }
        let item = results[selectedIndex]
        switch item.kind {
        case .note:
            return [
                ItemAction(label: "Open in Notes", icon: "arrow.up.forward.app", shortcut: "⏎") {
                    openSelectedItem()
                },
                ItemAction(label: "Ask AI about this", icon: "sparkles", shortcut: nil) {
                    askAIAboutSelected()
                },
                ItemAction(label: "Copy snippet", icon: "doc.on.clipboard", shortcut: nil) {
                    copySnippet()
                },
            ]
        case .app:
            return [
                ItemAction(label: "Launch", icon: "arrow.up.forward.app", shortcut: "⏎") {
                    openSelectedItem()
                },
                ItemAction(label: "Show in Finder", icon: "folder", shortcut: nil) {
                    showInFinder()
                },
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            searchBar
            Divider()

            if let status = statusMessage, !hasResults {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(16)
            }

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
        .task(id: query) {
            performSearch(query)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            showActions = false
            if UserDefaults.standard.bool(forKey: "clearQueryOnOpen") {
                query = ""
            }
        }
        .onKeyPress(.upArrow) {
            if showActions {
                actionIndex = max(0, actionIndex - 1)
                return .handled
            }
            guard !results.isEmpty else { return .ignored }
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            if showActions {
                actionIndex = min(currentActions.count - 1, actionIndex + 1)
                return .handled
            }
            guard !results.isEmpty else { return .ignored }
            selectedIndex = min(results.count - 1, selectedIndex + 1)
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
            TextField("Search notes and apps...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 4)
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        resultRow(item: item, isSelected: index == selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                openSelectedItem()
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

            Text(item.kind == .app ? "Application" : item.meta["folder"] ?? "Notes")
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
                if isThinking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking...")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else if isGenerating && answer.isEmpty {
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
                keyboardHint(key: "\u{23CE}", label: "Open")
                keyboardHint(key: "\u{2318}K", label: "Actions")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Close")
            }
            Spacer()
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
            results = appState.recentItems()
        } else {
            results = appState.performSearch(query: trimmed)
        }
        selectedIndex = 0
        showActions = false
    }

    private func openSelectedItem() {
        guard selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        appState.recordSelection(query: query, item: item)
        switch item.kind {
        case .note:
            if let noteId = item.meta["noteId"] {
                NoteExtractor.openNote(id: noteId)
            }
        case .app:
            if let path = item.meta["path"] {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    private func askAIAboutSelected() {
        guard selectedIndex < results.count else { return }
        showActions = false
        isGenerating = true
        rawAnswer = ""

        Task { @MainActor in
            guard let ext = appState.notesExtension else {
                rawAnswer = "Not ready — please select a model in Settings."
                isGenerating = false
                return
            }
            for await result in await ext.handle(query: query) {
                switch result.kind {
                case .token(let text):
                    rawAnswer += text
                case .sources:
                    break
                case .error(let msg):
                    rawAnswer += "\n[Error: \(msg)]"
                case .done:
                    break
                }
            }
            isGenerating = false
        }
    }

    private func copySnippet() {
        guard selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        let text = item.meta["snippet"] ?? item.title
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private static func stripThinkingBlocks(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>"),
              let end = result.range(of: "</think>") {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let start = result.range(of: "<think>") {
            result = String(result[..<start.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Supporting Types

private struct ItemAction {
    let label: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}
