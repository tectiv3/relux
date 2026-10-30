import Foundation
import Observation

/// Owns the translate panel's `idle → streaming → stored` cycle and every write to
/// `translation_history`, so the view only renders state instead of driving it.
@MainActor
@Observable
final class TranslationService {
    /// Injected so tests can drive chunks without an API key; production passes
    /// `AnthropicService.translate(text:targetLanguage:)`, which yields errors as text
    /// chunks rather than throwing, so the stream itself has no failure channel.
    ///
    /// Typed as `AsyncSequence` rather than `AsyncStream` because nothing here may assume that
    /// cancelling the run ends iteration; only `AsyncStream` promises that.
    typealias StreamProvider = @MainActor (
        _ text: String,
        _ targetLanguage: String
    ) -> any AsyncSequence<String, Never>

    enum State: Equatable {
        case idle
        case streaming(partial: String)
        case stored(entryId: Int64)
        case failed(message: String)
    }

    private let store: TranslateStore
    private let modelProvider: @MainActor () -> String
    private let streamProvider: StreamProvider

    private(set) var state: State = .idle
    /// History as the store last reported it; only the service reloads it.
    private(set) var entries: [TranslationEntry] = []

    private var job: Task<Void, Never>?
    /// A superseded run must not overwrite the state of the run that replaced it.
    private var runID = 0
    /// Highest run that has written each row. A superseded run keeps the chunks its sequence still
    /// delivers, so writes are ordered by run instead of by whichever run happens to finish last.
    private var lastWriteRun: [Int64: Int] = [:]

    init(
        store: TranslateStore,
        model: @escaping @MainActor () -> String,
        stream: @escaping StreamProvider
    ) {
        self.store = store
        modelProvider = model
        streamProvider = stream
        entries = store.fetchAll()
    }

    // MARK: - Derived state

    /// Read live so the panel shows a model changed in Settings without a reload.
    var model: String {
        modelProvider()
    }

    var isTranslating: Bool {
        if case .streaming = state {
            return true
        }
        return false
    }

    var streamedText: String {
        if case let .streaming(partial) = state {
            return partial
        }
        return ""
    }

    var failureMessage: String? {
        if case let .failed(message) = state {
            return message
        }
        return nil
    }

    // MARK: - Commands

    func translate(_ text: String, targetLanguage: String) async {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }

        if let existing = store.findByHash(TranslationEntry.hash(source: source, target: targetLanguage)) {
            store.bumpTimestamp(id: existing.id)
            reload()
            state = .stored(entryId: existing.id)
            return
        }

        let entryId: Int64
        do {
            // Empty row first: the history keeps created_at ordering and an interrupted run
            // still leaves a row behind. It stays out of `entries` until the run ends, so the
            // list shows the streaming placeholder instead of an empty duplicate.
            entryId = try store.insert(
                sourceText: source,
                translatedText: "",
                sourceLang: nil,
                targetLang: targetLanguage,
                model: modelProvider()
            )
        } catch {
            state = .failed(message: Self.message("save the new translation", error))
            return
        }

        await perform(entryId: entryId, text: source, targetLanguage: targetLanguage)
    }

    /// Re-streams into an existing row: no hash lookup, no insert, same row id.
    func retranslate(_ entry: TranslationEntry) async {
        await perform(entryId: entry.id, text: entry.sourceText, targetLanguage: entry.targetLang)
    }

    func cancel() {
        job?.cancel()
        job = nil
    }

    func delete(entryId: Int64) {
        try? store.delete(id: entryId)
        lastWriteRun[entryId] = nil
        reload()
    }

    func reload() {
        entries = store.fetchAll()
    }

    // MARK: - Private

    private func perform(entryId: Int64, text: String, targetLanguage: String) async {
        job?.cancel()
        runID += 1
        let run = runID
        let job = Task { @MainActor in
            await self.consume(entryId: entryId, text: text, targetLanguage: targetLanguage, run: run)
        }
        self.job = job
        await job.value
    }

    private func consume(entryId: Int64, text: String, targetLanguage: String, run: Int) async {
        state = .streaming(partial: "")
        var full = ""
        for await chunk in streamProvider(text, targetLanguage) {
            if Task.isCancelled {
                break
            }
            full += chunk
            state = .streaming(partial: full)
        }

        // Cancellation ends the loop but keeps whatever arrived: the row is written either way,
        // so an aborted run leaves its partial text in history exactly as before.
        //
        // A superseded run may still finish its own row, but never a row a later run has already
        // written: cancellation is advisory, so the older loop can end after the newer run's write.
        // Checked right before the write with no suspension in between, so nothing can write the
        // row between the check and our own write.
        if let newer = lastWriteRun[entryId], newer > run {
            return
        }

        do {
            try store.updateTranslation(id: entryId, translatedText: full)
            lastWriteRun[entryId] = run
        } catch {
            reload()
            guard run == runID else { return }
            state = .failed(message: Self.message("save the translation", error))
            return
        }

        reload()
        guard run == runID else { return }
        state = .stored(entryId: entryId)
    }

    private static func message(_ action: String, _ error: any Error) -> String {
        "Couldn't \(action): \(error)"
    }
}
