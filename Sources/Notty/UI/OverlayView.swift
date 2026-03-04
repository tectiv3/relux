import SwiftUI

struct OverlayView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var answer: String = ""
    @State private var sources: [SourceNote] = []
    @State private var isGenerating: Bool = false

    private var hasContent: Bool {
        !answer.isEmpty || isGenerating
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if hasContent {
                Divider()
                answerSection
                if !sources.isEmpty {
                    Divider()
                    sourcesSection
                }
            }
            Divider()
            bottomBar
        }
        .frame(width: 680)
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

    // MARK: - Answer Section

    private var answerSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if isGenerating && answer.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 4)
                } else {
                    Text(answer)
                        .textSelection(.enabled)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 300)
    }

    // MARK: - Sources Section

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources) { source in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Text(source.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(source.folder)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            keyboardHint(key: "\u{23CE}", label: "Ask")
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
        answer = ""
        sources = []

        Task { @MainActor in
            guard let ext = appState.notesExtension else {
                answer = "Not ready — please select a model in Settings."
                isGenerating = false
                return
            }
            for await result in ext.handle(query: query) {
                switch result.kind {
                case .token(let text):
                    answer += text
                case .sources(let s):
                    sources = s
                case .error(let msg):
                    answer += "\n[Error: \(msg)]"
                case .done:
                    break
                }
            }
            isGenerating = false
        }
    }
}
