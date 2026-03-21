import SwiftUI

struct ClipboardHistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var filter: String = ""
    @State private var entries: [ClipboardEntry] = []
    @State private var selectedIndex: Int = 0
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0
    @FocusState private var isFilterFocused: Bool

    private var filteredEntries: [ClipboardEntry] {
        if filter.trimmingCharacters(in: .whitespaces).isEmpty {
            return entries
        }
        let query = filter.lowercased()
        return entries.filter { entry in
            let text = entry.textContent ?? ""
            let firstLine = String(text.split(separator: "\n", maxSplits: 1).first ?? "")
            // Exact substring on full text, fuzzy only on first line
            return text.lowercased().contains(query)
                || fuzzyMatch(query: query, target: firstLine)
                || fuzzyMatch(query: query, target: entry.sourceName ?? "")
        }
    }

    private var selectedEntry: ClipboardEntry? {
        let items = filteredEntries
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    private var previousAppName: String {
        appState.previousApp?.localizedName ?? "App"
    }

    private var currentActions: [ClipAction] {
        guard let entry = selectedEntry else { return [] }
        var actions: [ClipAction] = [
            ClipAction(label: "Paste to \(previousAppName)", icon: "doc.on.clipboard.fill", shortcut: "⏎") {
                pasteEntry(entry, formatted: false)
            },
            ClipAction(label: "Copy to Clipboard", icon: "doc.on.clipboard", shortcut: "⌘⏎") {
                copyEntry(entry)
            },
        ]
        if entry.contentType == "rtf" || entry.contentType == "html" {
            actions.append(ClipAction(
                label: "Paste Formatted to \(previousAppName)",
                icon: "textformat", shortcut: "⌘⇧⏎"
            ) {
                pasteEntry(entry, formatted: true)
            })
        }
        actions.append(ClipAction(label: "Delete", icon: "trash", shortcut: "⌫") {
            deleteEntry(entry)
        })
        return actions
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            topBar
            Divider()

            if filteredEntries.isEmpty {
                Text(entries.isEmpty ? "No clipboard history" : "No matches")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    listPanel
                        .frame(minWidth: 280, maxWidth: 320)
                    previewPanel
                }
            }

            Spacer(minLength: 0)
            Divider()
            bottomBar
        }
        .frame(width: 750)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if showActions {
                actionsOverlay
            }
        }
        .onAppear {
            loadEntries()
            isFilterFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFilterFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard appState.panelMode == .clipboard else { return }
            loadEntries()
            isFilterFocused = true
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .background {
            // Cmd+K to toggle actions
            Button("") {
                guard selectedEntry != nil else { return }
                actionIndex = 0
                showActions.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()

            // Cmd+Enter to copy to clipboard
            Button("") {
                guard let entry = selectedEntry else { return }
                copyEntry(entry)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                appState.panelMode = .search
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)

            TextField("Type to filter entries...", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isFilterFocused)
                .onChange(of: filter) { _, _ in
                    selectedIndex = 0
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List Panel

    private var groupedEntries: [(label: String, items: [(index: Int, entry: ClipboardEntry)])] {
        let items = filteredEntries
        let calendar = Calendar.current

        var groups: [(label: String, items: [(index: Int, entry: ClipboardEntry)])] = []
        var currentLabel = ""
        var currentItems: [(index: Int, entry: ClipboardEntry)] = []

        for (index, entry) in items.enumerated() {
            let label: String
            if calendar.isDateInToday(entry.createdAt) {
                label = "Today"
            } else if calendar.isDateInYesterday(entry.createdAt) {
                label = "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                label = formatter.string(from: entry.createdAt)
            }

            if label != currentLabel {
                if !currentItems.isEmpty {
                    groups.append((currentLabel, currentItems))
                }
                currentLabel = label
                currentItems = []
            }
            currentItems.append((index, entry))
        }
        if !currentItems.isEmpty {
            groups.append((currentLabel, currentItems))
        }
        return groups
    }

    private var listPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Spacer().frame(height: 4)
                    ForEach(Array(groupedEntries.enumerated()), id: \.element.label) { _, section in
                        Text(section.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(section.items, id: \.entry.id) { index, entry in
                            entryRow(entry: entry, isSelected: index == selectedIndex)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = index
                                }
                                .onTapGesture(count: 2) {
                                    selectedIndex = index
                                    pasteEntry(entry, formatted: false)
                                }
                        }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                let items = filteredEntries
                if newIndex >= 0, newIndex < items.count {
                    withAnimation {
                        proxy.scrollTo(items[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func entryRow(entry: ClipboardEntry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if let text = entry.textContent, let nsColor = ColorParser.parse(text) {
                Circle()
                    .fill(Color(nsColor: nsColor))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 20)
            } else {
                Image(systemName: entryIcon(for: entry))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .font(.system(size: 13))
                    .frame(width: 20)
            }

            Text(highlightedTitle(for: entry, isSelected: isSelected))
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    private func entryIcon(for entry: ClipboardEntry) -> String {
        switch entry.contentType {
        case "image": "photo"
        case "rtf", "html": "doc.richtext"
        default: "doc.text"
        }
    }

    private func entryTitle(for entry: ClipboardEntry) -> String {
        switch entry.contentType {
        case "image":
            if let width = entry.imageWidth, let height = entry.imageHeight {
                return "Image (\(width)×\(height))"
            }
            return "Image"
        default:
            let text = entry.textContent ?? ""
            let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            return String(firstLine.prefix(80))
        }
    }

    private func highlightedTitle(for entry: ClipboardEntry, isSelected: Bool) -> AttributedString {
        let title = entryTitle(for: entry)
        var result = AttributedString(title)
        let query = filter.lowercased()
        guard !query.isEmpty else { return result }

        let titleLower = title.lowercased()
        guard let matchedIndices = fuzzyMatchIndices(query: query, target: titleLower) else {
            return result
        }

        let highlightColor: Color = isSelected ? .white.opacity(0.5) : .accentColor
        for idx in matchedIndices {
            let offset = titleLower.distance(from: titleLower.startIndex, to: idx)
            let attrStart = result.index(result.startIndex, offsetByCharacters: offset)
            let attrEnd = result.index(attrStart, offsetByCharacters: 1)
            result[attrStart ..< attrEnd].foregroundColor = highlightColor
            result[attrStart ..< attrEnd].underlineStyle = .single
        }

        return result
    }

    /// Returns matched character indices for the tightest fuzzy match, or nil if no match.
    /// Tries exact substring first, then fuzzy with span limit.
    private func fuzzyMatchIndices(query: String, target: String) -> [String.Index]? {
        // Exact substring
        if let range = target.range(of: query) {
            return Array(target[range].indices)
        }
        // Fuzzy: try each occurrence of the first char, pick tightest
        let queryChars = Array(query)
        guard let firstChar = queryChars.first else { return nil }
        let maxSpan = query.count * 2
        var bestIndices: [String.Index]?
        var bestSpan = Int.max

        var startSearch = target.startIndex
        while let anchor = target[startSearch...].firstIndex(of: firstChar) {
            var indices = [anchor]
            var idx = target.index(after: anchor)
            var matched = true
            for char in queryChars.dropFirst() {
                guard let found = target[idx...].firstIndex(of: char) else {
                    matched = false
                    break
                }
                indices.append(found)
                idx = target.index(after: found)
            }
            if matched {
                let span = target.distance(from: anchor, to: indices.last!) + 1
                if span <= maxSpan, span < bestSpan {
                    bestSpan = span
                    bestIndices = indices
                }
            }
            startSearch = target.index(after: anchor)
        }
        return bestIndices
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        VStack(spacing: 0) {
            if let entry = selectedEntry {
                if let text = entry.textContent, let nsColor = ColorParser.parse(text) {
                    let color = Color(nsColor: nsColor)
                    VStack(spacing: 16) {
                        Circle()
                            .fill(color)
                            .frame(width: 120, height: 120)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            .shadow(color: color.opacity(0.4), radius: 12)
                        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading) {
                            if entry.contentType == "image", let imagePath = entry.imagePath {
                                let url = appState.clipboardStore!.imageDir.appendingPathComponent(imagePath)
                                if let nsImage = NSImage(contentsOf: url) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxHeight: 250)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            } else if let text = entry.textContent {
                                Text(text.count > 10000 ? String(text.prefix(10000)) + "\n…" : text)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                }

                Divider()

                infoFooter(entry: entry)
            }
        }
    }

    private func infoFooter(entry: ClipboardEntry) -> some View {
        VStack(spacing: 0) {
            infoRow(label: "Application") {
                HStack(spacing: 4) {
                    if let bundleId = entry.sourceApp,
                       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                    {
                        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Text(entry.sourceName ?? "Unknown")
                }
            }

            infoRow(label: "Content type") {
                if let text = entry.textContent, ColorParser.parse(text) != nil {
                    Text("Color")
                } else {
                    Text(entry.contentType.capitalized)
                }
            }

            if entry.contentType == "image" {
                if let width = entry.imageWidth, let height = entry.imageHeight {
                    infoRow(label: "Dimensions") { Text("\(width)×\(height)") }
                }
                if let size = entry.imageSize {
                    infoRow(label: "Image size") { Text(formatBytes(size)) }
                }
            } else {
                if let count = entry.charCount {
                    infoRow(label: "Characters") { Text("\(count)") }
                }
                if let count = entry.wordCount {
                    infoRow(label: "Words") { Text("\(count)") }
                }
            }

            infoRow(label: "Copied") {
                Text(formatTime(entry.createdAt))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func infoRow(label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            content()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "clipboard")
                    .font(.system(size: 11))
                Text("Clipboard History")
            }
            .foregroundColor(.secondary.opacity(0.7))

            Spacer()

            if selectedEntry != nil {
                keyboardHint(key: "⏎", label: "Paste to \(previousAppName)")
                keyboardHint(key: "⌦", label: "Delete")
            }
            keyboardHint(key: "⌘K", label: "Actions")
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

    // MARK: - Actions Overlay

    private var actionsOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    if let entry = selectedEntry {
                        HStack(spacing: 6) {
                            Image(systemName: entryIcon(for: entry))
                                .font(.system(size: 11))
                            Text(entryTitle(for: entry))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        Divider()
                    }

                    ForEach(Array(currentActions.enumerated()), id: \.offset) { index, action in
                        HStack(spacing: 10) {
                            Image(systemName: action.icon)
                                .foregroundColor(index == actionIndex ? .white.opacity(0.8) : .secondary)
                                .font(.system(size: 13))
                                .frame(width: 20)
                            Text(action.label)
                                .font(.system(size: 13))
                            Spacer()
                            if let shortcut = action.shortcut {
                                Text(shortcut)
                                    .font(.system(size: 11))
                                    .foregroundColor(index == actionIndex ? .white.opacity(0.6) : .secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(index == actionIndex ? Color.accentColor : Color.clear)
                                .padding(.horizontal, 4)
                        )
                        .foregroundColor(index == actionIndex ? .white : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            action.action()
                            showActions = false
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThickMaterial)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(width: 300)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Key Handling

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // Escape — clear filter first, close actions, then let panel dismiss
        if keyPress.key == .escape {
            if showActions {
                showActions = false
                return .handled
            }
            if !filter.isEmpty {
                filter = ""
                selectedIndex = 0
                return .handled
            }
            return .ignored
        }
        // Arrow up — always navigates list (or actions overlay)
        if keyPress.key == .upArrow {
            if showActions {
                guard !currentActions.isEmpty else { return .ignored }
                actionIndex = actionIndex <= 0 ? currentActions.count - 1 : actionIndex - 1
            } else {
                let items = filteredEntries
                guard !items.isEmpty else { return .ignored }
                selectedIndex = selectedIndex <= 0 ? items.count - 1 : selectedIndex - 1
            }
            return .handled
        }
        // Arrow down
        if keyPress.key == .downArrow {
            if showActions {
                guard !currentActions.isEmpty else { return .ignored }
                actionIndex = actionIndex >= currentActions.count - 1 ? 0 : actionIndex + 1
            } else {
                let items = filteredEntries
                guard !items.isEmpty else { return .ignored }
                selectedIndex = selectedIndex >= items.count - 1 ? 0 : selectedIndex + 1
            }
            return .handled
        }
        // Enter
        if keyPress.key == .return {
            if showActions {
                guard actionIndex < currentActions.count else { return .ignored }
                currentActions[actionIndex].action()
                showActions = false
                return .handled
            }
            guard let entry = selectedEntry else { return .ignored }
            pasteEntry(entry, formatted: false)
            return .handled
        }
        // Forward delete — delete selected entry
        if keyPress.key == .deleteForward {
            if !showActions, let entry = selectedEntry {
                deleteEntry(entry)
                return .handled
            }
            return .ignored
        }

        return .ignored
    }

    // MARK: - Actions

    private func pasteEntry(_ entry: ClipboardEntry, formatted: Bool) {
        if entry.contentType == "image", let imagePath = entry.imagePath {
            let url = appState.clipboardStore!.imageDir.appendingPathComponent(imagePath)
            PasteService.pasteImage(at: url, monitor: appState.clipboardMonitor)
        } else if let text = entry.textContent {
            let rtfData = formatted ? appState.clipboardStore?.fetchRawData(id: entry.id) : nil
            PasteService.pasteText(text, asRichText: rtfData, monitor: appState.clipboardMonitor)
        }
    }

    private func copyEntry(_ entry: ClipboardEntry) {
        if let text = entry.textContent {
            let rtfData = appState.clipboardStore?.fetchRawData(id: entry.id)
            PasteService.copyToClipboard(text, asRichText: rtfData, monitor: appState.clipboardMonitor)
        }
        NSApp.keyWindow?.close()
    }

    private func deleteEntry(_ entry: ClipboardEntry) {
        try? appState.clipboardStore?.delete(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        let items = filteredEntries
        selectedIndex = min(selectedIndex, max(0, items.count - 1))
        showActions = false
    }

    private func loadEntries() {
        entries = appState.clipboardStore?.fetchAll() ?? []
        selectedIndex = 0
        filter = ""
    }

    // MARK: - Helpers

    /// Fuzzy subsequence match with span limit.
    /// Tries every occurrence of the first query char as a starting point
    /// and returns true if any produces a tight enough match.
    private func fuzzyMatch(query: String, target: String) -> Bool {
        let target = target.lowercased()
        let queryChars = Array(query)
        guard let firstChar = queryChars.first else { return false }
        let maxSpan = query.count * 2

        var startSearch = target.startIndex
        while let anchor = target[startSearch...].firstIndex(of: firstChar) {
            var idx = target.index(after: anchor)
            var matched = true
            for char in queryChars.dropFirst() {
                guard let found = target[idx...].firstIndex(of: char) else {
                    matched = false
                    break
                }
                idx = target.index(after: found)
            }
            if matched {
                let lastIdx = target.index(before: idx)
                let span = target.distance(from: anchor, to: lastIdx) + 1
                if span <= maxSpan { return true }
            }
            startSearch = target.index(after: anchor)
        }
        return false
    }

    private func formatBytes(_ bytes: Int) -> String {
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 {
            return String(format: "%.0f KB", kilobytes)
        }
        return String(format: "%.1f MB", kilobytes / 1024)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'Today at' HH:mm:ss"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Types

private struct ClipAction {
    let label: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}
