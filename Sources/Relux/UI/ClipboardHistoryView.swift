import ReluxCore
import SwiftUI

private extension ClipboardTypeFilter {
    var label: String {
        switch self {
        case .text: "Text"
        case .image: "Images"
        case .richText: "Rich Text"
        case .color: "Colors"
        }
    }

    var icon: String {
        switch self {
        case .text: "doc.plaintext"
        case .image: "photo"
        case .richText: "doc.richtext"
        case .color: "paintpalette"
        }
    }

    func title(isActive: Bool) -> String {
        isActive ? "Clear Filter" : "Show \(label) Only"
    }
}

struct ClipboardHistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var model = ClipboardListModel()
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0
    @FocusState private var isFilterFocused: Bool

    private var previousAppName: String {
        appState.previousApp?.localizedName ?? "App"
    }

    private var currentActions: [ClipAction] {
        guard let entry = model.selectedEntry else { return [] }
        var actions: [ClipAction] = [
            ClipAction(label: "Paste to \(previousAppName)", icon: "doc.on.clipboard.fill", shortcut: "⏎") {
                model.paste(entry)
            },
            ClipAction(label: "Copy to Clipboard", icon: "doc.on.clipboard", shortcut: "⌘⏎") {
                model.copy(entry)
            },
        ]
        if entry.contentType == ContentType.rtf || entry.contentType == ContentType.html {
            actions.append(ClipAction(
                label: "Paste Formatted to \(previousAppName)",
                icon: "textformat", shortcut: "⌘⇧⏎"
            ) {
                model.paste(entry, formatted: true)
            })
        }
        actions.append(ClipAction(label: "Delete", icon: "trash", shortcut: "⌫") {
            model.delete(entry)
        })
        if entry.isPinned {
            actions.append(ClipAction(label: "Unpin", icon: "pin.slash", shortcut: nil) {
                model.togglePin(entry)
            })
        } else {
            actions.append(ClipAction(label: "Pin", icon: "pin", shortcut: nil) {
                model.togglePin(entry)
            })
        }
        for filterType in ClipboardTypeFilter.allCases {
            let isActive = model.typeFilter == filterType
            actions.append(ClipAction(
                label: filterType.title(isActive: isActive), icon: filterType.icon, shortcut: nil
            ) {
                model.setTypeFilter(isActive ? nil : filterType)
                showActions = false
            })
        }
        return actions
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            topBar
            Divider()

            if let typeFilter = model.typeFilter {
                HStack(spacing: 4) {
                    Image(systemName: typeFilter.icon)
                        .font(.system(size: 11))
                    Text(typeFilter.label)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
                .onTapGesture {
                    model.setTypeFilter(nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            if model.filteredEntries.isEmpty {
                let message = if model.entries.isEmpty {
                    "No clipboard history"
                } else if let typeFilter = model.typeFilter {
                    "No \(typeFilter.label.lowercased()) in history"
                } else {
                    "No matches"
                }
                Text(message)
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
            model.attach(to: appState)
            model.reload()
            isFilterFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFilterFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard appState.panelMode == .clipboard else { return }
            model.reload()
            isFilterFocused = true
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .background {
            // Cmd+K to toggle actions
            Button("") {
                guard model.selectedEntry != nil else { return }
                actionIndex = 0
                showActions.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()

            // Cmd+Enter to copy to clipboard
            Button("") {
                guard let entry = model.selectedEntry else { return }
                model.copy(entry)
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

            TextField("Type to filter entries...", text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .focused($isFilterFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List Panel

    private var groupedEntries: [(label: String, items: [(index: Int, entry: ClipboardEntry)])] {
        let items = model.filteredEntries
        let calendar = Calendar.current
        let isFiltering = model.isFiltering

        var groups: [(label: String, items: [(index: Int, entry: ClipboardEntry)])] = []
        var currentLabel = ""
        var currentItems: [(index: Int, entry: ClipboardEntry)] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        if !isFiltering {
            let pinnedItems = items.enumerated()
                .filter(\.element.isPinned)
                .map { (index: $0.offset, entry: $0.element) }
            if !pinnedItems.isEmpty {
                groups.append(("Pinned", pinnedItems))
            }
        }

        for (index, entry) in items.enumerated() {
            if !isFiltering, entry.isPinned {
                continue
            }

            let label: String = if calendar.isDateInToday(entry.updatedAt) {
                "Today"
            } else if calendar.isDateInYesterday(entry.updatedAt) {
                "Yesterday"
            } else {
                dateFormatter.string(from: entry.updatedAt)
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
                            entryRow(entry: entry, isSelected: index == model.selectedIndex)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.select(row: index)
                                }
                                .onTapGesture(count: 2) {
                                    model.select(row: index)
                                    model.paste(entry)
                                }
                        }
                    }
                }
            }
            .onChange(of: model.selectedIndex) { _, newIndex in
                let items = model.filteredEntries
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

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }
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
        case ContentType.image: "photo"
        case ContentType.rtf, ContentType.html: "doc.richtext"
        default: "doc.text"
        }
    }

    private func entryTitle(for entry: ClipboardEntry) -> String {
        switch entry.contentType {
        case ContentType.image:
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
        guard let matchedIndices = model.matchedIndices(in: title) else {
            return result
        }

        let titleLower = title.lowercased()
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

    // MARK: - Preview Panel

    private var previewPanel: some View {
        VStack(spacing: 0) {
            if let entry = model.selectedEntry {
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
                            if entry.contentType == ContentType.image, let url = model.imageURL(for: entry) {
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

            if entry.contentType == ContentType.image {
                if let width = entry.imageWidth, let height = entry.imageHeight {
                    infoRow(label: "Dimensions") { Text("\(width)×\(height)") }
                }
                if let size = entry.imageSize {
                    infoRow(label: "Image size") { Text(Formatting.bytes(size)) }
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
                Text(Formatting.time(entry.createdAt))
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

            if model.selectedEntry != nil {
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
                    if let entry = model.selectedEntry {
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
            if model.typeFilter != nil {
                model.setTypeFilter(nil)
                return .handled
            }
            if !model.searchText.isEmpty {
                model.resetSearch()
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
                guard model.selectPrevious() else { return .ignored }
            }
            return .handled
        }
        // Arrow down
        if keyPress.key == .downArrow {
            if showActions {
                guard !currentActions.isEmpty else { return .ignored }
                actionIndex = actionIndex >= currentActions.count - 1 ? 0 : actionIndex + 1
            } else {
                guard model.selectNext() else { return .ignored }
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
            guard let entry = model.selectedEntry else { return .ignored }
            model.paste(entry)
            return .handled
        }
        // Forward delete — delete selected entry
        if keyPress.key == .deleteForward {
            if !showActions, let entry = model.selectedEntry {
                model.delete(entry)
                return .handled
            }
            return .ignored
        }

        return .ignored
    }
}

// MARK: - Supporting Types

private struct ClipAction {
    let label: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}
