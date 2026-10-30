import AppKit
import ReluxCore
import SwiftUI

struct TranslateView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @State private var selectedIndex: Int = 0
    @State private var menu = ActionSelection()
    @FocusState private var isInputFocused: Bool

    private var service: TranslationService? {
        appState.translationService
    }

    private var entries: [TranslationEntry] {
        service?.entries ?? []
    }

    private var isTranslating: Bool {
        service?.isTranslating ?? false
    }

    private var streamedText: String {
        service?.streamedText ?? ""
    }

    private var languages: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: "translateLanguages") ?? ["English"]
        return stored.isEmpty ? ["English"] : stored
    }

    @State private var selectedLanguage: String = ""

    private var selectedEntry: TranslationEntry? {
        guard selectedIndex >= 0, selectedIndex < entries.count else { return nil }
        return entries[selectedIndex]
    }

    private var currentActions: [Action] {
        guard let entry = selectedEntry else { return [] }
        return PanelActions.translate().map { descriptor in
            Action(descriptor) {
                switch descriptor.kind {
                case .retranslate: retranslate(entry)
                case .copyToClipboard: copyTranslation(entry)
                case .delete: deleteEntry(entry)
                default: break
                }
            }
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

            if entries.isEmpty, !isTranslating, service?.failureMessage == nil {
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
            if menu.isOpen {
                ActionOverlay(
                    actions: currentActions,
                    selectedIndex: menu.index,
                    width: 280,
                    onSelect: runAction,
                    header: { actionMenuHeader }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            }
        }
        .onAppear {
            if selectedLanguage.isEmpty {
                selectedLanguage = languages.first ?? "English"
            }
            service?.reload()
            if let selection = appState.currentSelection, !selection.isEmpty {
                inputText = selection
                appState.currentSelection = nil
                translateCurrent()
            }
            isInputFocused = true
        }
        .onChange(of: appState.selectionCaptureID) { _, _ in
            // Selection captured asynchronously after the view appeared
            if inputText.isEmpty, let selection = appState.currentSelection, !selection.isEmpty {
                inputText = selection
                appState.currentSelection = nil
                translateCurrent()
            }
        }
        .onKeyPress(.escape) {
            if menu.isOpen {
                menu.close()
                return .handled
            }
            return .ignored
        }
        .background(PanelKeyMonitor(handler: handlePanelKey))
        .background {
            Button("") {
                menu.toggle(isAvailable: selectedEntry != nil)
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
                service?.cancel()
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

            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Enter text to translate...")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .focused($isInputFocused)
                    .frame(minHeight: 28, maxHeight: 80)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.return) {
                        translateCurrent()
                        return .handled
                    }
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
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = adjustedIndex
                            }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                let targetId: Int64? = if isTranslating {
                    newIndex == 0 ? nil : (newIndex - 1 < entries.count ? entries[newIndex - 1].id : nil)
                } else {
                    newIndex < entries.count ? entries[newIndex].id : nil
                }
                if let targetId {
                    withAnimation {
                        proxy.scrollTo(targetId, anchor: .center)
                    }
                } else if isTranslating, newIndex == 0 {
                    withAnimation {
                        proxy.scrollTo(-1, anchor: .center)
                    }
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
                if let failure = service?.failureMessage, !isTranslating {
                    Text(failure)
                        .textSelection(.enabled)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().padding(.vertical, 4)
                }

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
                    infoRow(label: "Model", content: service?.model ?? "")
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
            if menu.isOpen {
                KeyboardHint(key: "\u{23CE}", label: "Select")
                KeyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                KeyboardHint(key: "esc", label: "Back")
            } else {
                KeyboardHint(key: "\u{23CE}", label: "Translate")
                KeyboardHint(key: "\u{2318}K", label: "Actions")
                KeyboardHint(key: "\u{2326}", label: "Delete")
                KeyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                KeyboardHint(key: "esc", label: "Close")
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

    // MARK: - Actions Overlay

    @ViewBuilder
    private var actionMenuHeader: some View {
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
    }

    // MARK: - Key Monitor

    /// Only keys this view consumed are swallowed; everything else is passed on.
    private func handlePanelKey(_ event: NSEvent) -> NSEvent? {
        let key = event.specialKey
        if key == .upArrow {
            if menu.isOpen {
                guard menu.moveUp(count: currentActions.count) else { return event }
            } else {
                guard !entries.isEmpty else { return event }
                selectedIndex = ResultSelection.retreated(selectedIndex, count: entries.count)
            }
            return nil
        }
        if key == .downArrow {
            if menu.isOpen {
                guard menu.moveDown(count: currentActions.count) else { return event }
            } else {
                guard !entries.isEmpty else { return event }
                selectedIndex = ResultSelection.advanced(selectedIndex, count: entries.count)
            }
            return nil
        }
        if key == .carriageReturn || key == .newline {
            if menu.isOpen {
                guard let index = menu.activationIndex(count: currentActions.count) else { return event }
                runAction(index)
                return nil
            }
        }
        if key == .deleteForward {
            if !menu.isOpen, let entry = selectedEntry {
                deleteEntry(entry)
                return nil
            }
        }
        return event
    }

    // MARK: - Actions

    private func translateCurrent() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let service else { return }

        selectedIndex = 0
        Task { await service.translate(text, targetLanguage: selectedLanguage) }
    }

    private func retranslate(_ entry: TranslationEntry) {
        menu.close()
        inputText = entry.sourceText
        selectedLanguage = entry.targetLang

        guard let service else { return }
        Task { await service.retranslate(entry) }
    }

    private func copyTranslation(_ entry: TranslationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.translatedText, forType: .string)
        menu.close()
    }

    private func deleteEntry(_ entry: TranslationEntry) {
        service?.delete(entryId: entry.id)
        if selectedIndex >= entries.count {
            selectedIndex = max(0, entries.count - 1)
        }
        menu.close()
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
