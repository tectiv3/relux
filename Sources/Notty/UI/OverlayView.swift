import SwiftUI

struct OverlayView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var rawAnswer: String = ""
    @State private var sources: [SourceNote] = []
    @State private var isGenerating: Bool = false
    @State private var selectedIndex: Int = 0

    /// Display-ready answer with thinking blocks stripped
    private var answer: String {
        Self.stripThinkingBlocks(rawAnswer)
    }

    /// True when model is inside <think>...</think> (hasn't closed yet)
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
        if !appState.mlx.isLLMLoaded {
            return "No model loaded — open Settings to select one."
        }
        return nil
    }

    private var hasResults: Bool {
        !answer.isEmpty || isGenerating || !sources.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if let status = statusMessage, !hasResults {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(16)
            }

            if !sources.isEmpty {
                sourcesSection
            }

            if !answer.isEmpty || isGenerating {
                Divider()
                answerSection
            }

            Divider()
            bottomBar
        }
        .frame(width: 680)
        .onKeyPress(.upArrow) {
            guard !sources.isEmpty else { return .ignored }
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !sources.isEmpty else { return .ignored }
            selectedIndex = min(sources.count - 1, selectedIndex + 1)
            return .handled
        }
        .background {
            Button("") { openSelectedNote() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 16))
            TextField("Ask your notes...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .onSubmit { submitQuery() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Sources Section

    private var sourcesSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                sourceRow(source: source, isSelected: index == selectedIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedIndex = index
                        openSelectedNote()
                    }
            }
        }
    }

    private func sourceRow(source: SourceNote, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .font(.system(size: 12))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(source.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(source.folder)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
                }
                if !source.snippet.isEmpty {
                    Text(source.snippet)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
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
        .frame(maxHeight: 200)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            keyboardHint(key: "\u{23CE}", label: "Ask")
            keyboardHint(key: "\u{2318}\u{23CE}", label: "Open")
            keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
            keyboardHint(key: "esc", label: "Close")
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

    private func submitQuery() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isGenerating = true
        rawAnswer = ""
        sources = []
        selectedIndex = 0

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
                case .sources(let s):
                    sources = s
                case .error(let msg):
                    rawAnswer += "\n[Error: \(msg)]"
                case .done:
                    break
                }
            }
            isGenerating = false
        }
    }

    /// Strip <think>...</think> blocks. Operates on full accumulated raw text.
    private static func stripThinkingBlocks(_ text: String) -> String {
        var result = text
        // Remove complete <think>...</think> blocks
        while let start = result.range(of: "<think>"),
              let end = result.range(of: "</think>") {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // Hide incomplete <think> block (still streaming)
        if let start = result.range(of: "<think>") {
            result = String(result[..<start.lowerBound])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openSelectedNote() {
        guard selectedIndex < sources.count else { return }
        let note = sources[selectedIndex]
        NoteExtractor.openNote(id: note.id)
    }
}
