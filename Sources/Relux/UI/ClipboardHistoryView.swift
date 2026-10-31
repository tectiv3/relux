import ReluxCore
import SwiftUI

private extension ClipboardTypeFilter {
    var icon: String {
        switch self {
        case .text: "doc.plaintext"
        case .image: "photo"
        case .richText: "doc.richtext"
        case .color: "paintpalette"
        }
    }
}

struct ClipboardHistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var model = ClipboardListModel(
        searchDebounceNanos: ClipboardListModel.panelSearchDebounceNanos
    )
    @State private var menu = ActionSelection()
    @FocusState private var isFilterFocused: Bool

    private var previousAppName: String {
        appState.previousApp?.localizedName ?? "App"
    }

    private var currentActions: [Action] {
        guard let entry = model.selectedEntry else { return [] }
        let isRichText = entry.contentType == ContentType.rtf || entry.contentType == ContentType.html
        return PanelActions.clipboard(
            previousAppName: previousAppName,
            isRichText: isRichText,
            isPinned: entry.isPinned,
            activeFilter: model.typeFilter?.rawValue,
            filters: filterDescriptors
        ).map { descriptor in
            Action(descriptor) {
                switch descriptor.kind {
                case .paste: model.paste(entry)
                case .copyToClipboard: model.copy(entry)
                case .pasteFormatted: model.paste(entry, formatted: true)
                case .delete: model.delete(entry)
                case .pin, .unpin: model.togglePin(entry)
                case let .filter(rawValue):
                    let filter = ClipboardTypeFilter(rawValue: rawValue)
                    model.setTypeFilter(model.typeFilter == filter ? nil : filter)
                default: break
                }
            }
        }
    }

    private var filterDescriptors: [ClipboardFilterDescriptor] {
        ClipboardTypeFilter.allCases.map {
            ClipboardFilterDescriptor(rawValue: $0.rawValue, label: $0.label, icon: $0.icon)
        }
    }

    /// Runs a menu row and closes the menu, for both the mouse and the Return key.
    private func runAction(_ index: Int) {
        let actions = currentActions
        guard index >= 0, index < actions.count else { return }
        actions[index].handler()
        menu.close()
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

            if let emptyState = model.emptyState {
                Text(emptyState.message)
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
            if menu.isOpen {
                ActionOverlay(
                    actions: currentActions,
                    selectedIndex: menu.index,
                    width: 300,
                    onSelect: runAction,
                    header: { actionMenuHeader }
                )
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
                menu.toggle(isAvailable: model.selectedEntry != nil)
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
                KeyboardHint(key: "⏎", label: "Paste to \(previousAppName)")
                KeyboardHint(key: "⌦", label: "Delete")
            }
            KeyboardHint(key: "⌘K", label: "Actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    // MARK: - Actions Overlay

    @ViewBuilder
    private var actionMenuHeader: some View {
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
    }

    // MARK: - Key Handling

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // Escape — clear filter first, close actions, then let panel dismiss
        if keyPress.key == .escape {
            if menu.isOpen {
                menu.close()
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
        if keyPress.key == .upArrow {
            if menu.isOpen {
                return menu.moveUp(count: currentActions.count) ? .handled : .ignored
            }
            guard model.selectPrevious() else { return .ignored }
            return .handled
        }
        // Arrow down
        if keyPress.key == .downArrow {
            if menu.isOpen {
                return menu.moveDown(count: currentActions.count) ? .handled : .ignored
            }
            guard model.selectNext() else { return .ignored }
            return .handled
        }
        // Enter
        if keyPress.key == .return {
            if menu.isOpen {
                guard let index = menu.activationIndex(count: currentActions.count) else {
                    return .ignored
                }
                runAction(index)
                return .handled
            }
            guard let entry = model.selectedEntry else { return .ignored }
            model.paste(entry)
            return .handled
        }
        // Forward delete — delete selected entry
        if keyPress.key == .deleteForward {
            if !menu.isOpen, let entry = model.selectedEntry {
                model.delete(entry)
                return .handled
            }
            return .ignored
        }

        return .ignored
    }
}
