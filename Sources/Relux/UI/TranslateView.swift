import AppKit
import SwiftUI

struct TranslateView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @State private var entries: [TranslationEntry] = []
    @State private var selectedIndex: Int = 0
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0
    @State private var isTranslating: Bool = false
    @State private var streamedText: String = ""
    @State private var streamingTask: Task<Void, Never>?
    @State private var activeEntryId: Int64?
    @State private var keyMonitor: Any?
    @FocusState private var isInputFocused: Bool

    private var languages: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: "translateLanguages") ?? ["English"]
        return stored.isEmpty ? ["English"] : stored
    }

    @State private var selectedLanguage: String = ""

    private var selectedEntry: TranslationEntry? {
        guard selectedIndex >= 0, selectedIndex < entries.count else { return nil }
        return entries[selectedIndex]
    }

    private var currentActions: [TranslateAction] {
        guard let entry = selectedEntry else { return [] }
        return [
            TranslateAction(label: "Re-translate", icon: "arrow.clockwise", shortcut: "⌘R") {
                retranslate(entry)
            },
            TranslateAction(label: "Copy to Clipboard", icon: "doc.on.clipboard", shortcut: "⌘⏎") {
                copyTranslation(entry)
            },
            TranslateAction(label: "Delete", icon: "trash", shortcut: "⌫") {
                deleteEntry(entry)
            },
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            topBar
            Divider()

            if entries.isEmpty, !isTranslating {
                Text("No translation history")
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
            if selectedLanguage.isEmpty {
                selectedLanguage = languages.first ?? "English"
            }
            loadEntries()
            if let selection = appState.currentSelection, !selection.isEmpty {
                inputText = selection
                appState.currentSelection = nil
                translateCurrent()
            }
            isInputFocused = true
        }
        .onKeyPress(.escape) {
            if showActions {
                showActions = false
                return .handled
            }
            return .ignored
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .background {
            Button("") {
                guard selectedEntry != nil else { return }
                actionIndex = 0
                showActions.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()

            Button("") {
                guard let entry = selectedEntry else { return }
                copyTranslation(entry)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()

            Button("") {
                guard let entry = selectedEntry else { return }
                retranslate(entry)
            }
            .keyboardShortcut("r", modifiers: .command)
            .hidden()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                streamingTask?.cancel()
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

            TextField("Enter text to translate...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isInputFocused)
                .onSubmit {
                    translateCurrent()
                }

            Picker("", selection: $selectedLanguage) {
                ForEach(languages, id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List Panel

    private var listPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isTranslating {
                        streamingRow()
                            .id(-1)
                    }

                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let adjustedIndex = isTranslating ? index + 1 : index
                        entryRow(entry: entry, isSelected: adjustedIndex == selectedIndex)
                            .id(adjustedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = adjustedIndex
                            }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func streamingRow() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(inputText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Translating...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedIndex == 0 && isTranslating ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(selectedIndex == 0 && isTranslating ? .white : .primary)
    }

    private func entryRow(entry: TranslationEntry, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sourceText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(entry.translatedText)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatTime(entry.createdAt))
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .white.opacity(0.5) : .secondary)
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

    // MARK: - Preview Panel

    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isTranslating, selectedIndex == 0 {
                    if streamedText.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Translating...")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(streamedText)
                            .textSelection(.enabled)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider().padding(.vertical, 4)
                    infoRow(label: "Source", content: inputText)
                    infoRow(label: "To", content: selectedLanguage)
                    infoRow(label: "Model", content: appState.anthropicService.model)
                } else if let entry = selectedEntry {
                    Text(entry.translatedText)
                        .textSelection(.enabled)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().padding(.vertical, 4)
                    infoRow(label: "Source", content: entry.sourceText)
                    if let lang = entry.sourceLang {
                        infoRow(label: "From", content: lang)
                    }
                    infoRow(label: "To", content: entry.targetLang)
                    infoRow(label: "Model", content: entry.model)
                    infoRow(label: "Created", content: formatDateTime(entry.createdAt))
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func infoRow(label: String, content: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(content)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if showActions {
                keyboardHint(key: "\u{23CE}", label: "Select")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Back")
            } else {
                keyboardHint(key: "\u{23CE}", label: "Translate")
                keyboardHint(key: "\u{2318}K", label: "Actions")
                keyboardHint(key: "\u{2326}", label: "Delete")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Close")
            }
            Spacer()
            if !entries.isEmpty {
                Text("History \(entries.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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

    // MARK: - Actions Overlay

    private var actionsOverlay: some View {
        VStack(spacing: 0) {
            if let entry = selectedEntry {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 11))
                    Text(String(entry.sourceText.prefix(40)))
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
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
    }

    private func actionRow(action: TranslateAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .font(.system(size: 13))
                .frame(width: 20)
            Text(action.label)
                .font(.system(size: 13))
            Spacer()
            Text(action.shortcut)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
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

    // MARK: - Key Monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = event.specialKey
            if key == .upArrow {
                if showActions {
                    guard !currentActions.isEmpty else { return event }
                    actionIndex = actionIndex <= 0 ? currentActions.count - 1 : actionIndex - 1
                } else {
                    guard !entries.isEmpty else { return event }
                    selectedIndex = selectedIndex <= 0 ? entries.count - 1 : selectedIndex - 1
                }
                return nil
            }
            if key == .downArrow {
                if showActions {
                    guard !currentActions.isEmpty else { return event }
                    actionIndex = actionIndex >= currentActions.count - 1 ? 0 : actionIndex + 1
                } else {
                    guard !entries.isEmpty else { return event }
                    selectedIndex = selectedIndex >= entries.count - 1 ? 0 : selectedIndex + 1
                }
                return nil
            }
            if key == .carriageReturn || key == .newline {
                if showActions {
                    guard actionIndex < currentActions.count else { return event }
                    currentActions[actionIndex].action()
                    showActions = false
                    return nil
                }
            }
            if key == .deleteForward {
                if !showActions, let entry = selectedEntry {
                    deleteEntry(entry)
                    return nil
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Actions

    private func translateCurrent() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let lang = selectedLanguage
        let hash = TranslationEntry.hash(source: text, target: lang)

        // Reuse existing translation if available
        if let store = appState.translateStore,
           let existing = store.findByHash(hash)
        {
            store.bumpTimestamp(id: existing.id)
            loadEntries()
            selectedIndex = 0
            return
        }

        streamingTask?.cancel()
        isTranslating = true
        streamedText = ""
        selectedIndex = 0

        let model = appState.anthropicService.model

        if let store = appState.translateStore,
           let id = try? store.insert(sourceText: text, translatedText: "", sourceLang: nil, targetLang: lang, model: model)
        {
            activeEntryId = id
        }

        streamingTask = Task { @MainActor in
            var full = ""
            for await chunk in appState.anthropicService.translate(text: text, targetLanguage: lang) {
                full += chunk
                streamedText = full
            }

            if let id = activeEntryId, let store = appState.translateStore {
                try? store.updateTranslation(id: id, translatedText: full)
            }

            isTranslating = false
            activeEntryId = nil
            loadEntries()
        }
    }

    private func retranslate(_ entry: TranslationEntry) {
        showActions = false
        inputText = entry.sourceText
        selectedLanguage = entry.targetLang

        streamingTask?.cancel()
        isTranslating = true
        streamedText = ""
        activeEntryId = entry.id

        streamingTask = Task { @MainActor in
            var full = ""
            for await chunk in appState.anthropicService.translate(text: entry.sourceText, targetLanguage: entry.targetLang) {
                full += chunk
                streamedText = full
            }

            if let store = appState.translateStore {
                try? store.updateTranslation(id: entry.id, translatedText: full)
            }

            isTranslating = false
            activeEntryId = nil
            loadEntries()
        }
    }

    private func copyTranslation(_ entry: TranslationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.translatedText, forType: .string)
        showActions = false
    }

    private func deleteEntry(_ entry: TranslationEntry) {
        try? appState.translateStore?.delete(id: entry.id)
        loadEntries()
        if selectedIndex >= entries.count {
            selectedIndex = max(0, entries.count - 1)
        }
        showActions = false
    }

    private func loadEntries() {
        entries = appState.translateStore?.fetchAll() ?? []
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Types

private struct TranslateAction {
    let label: String
    let icon: String
    let shortcut: String
    let action: () -> Void
}
