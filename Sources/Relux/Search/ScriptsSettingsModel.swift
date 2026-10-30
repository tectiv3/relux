import Foundation

/// State for the Settings window's Scripts tab: the searcher-backed lists plus the in-flight
/// draft. Lives outside the view so the commit ordering (a pending edit is written before the
/// row switches) is testable without a UI.
@MainActor
@Observable
final class ScriptsSettingsModel {
    private var searcher: ScriptSearcher?

    /// The script being edited.
    var editingScript: ScriptItem?

    private(set) var expandedScriptId: String?

    var scripts: [ScriptItem] {
        searcher?.scripts ?? []
    }

    var envVars: [EnvVar] {
        searcher?.envVars ?? []
    }

    init(searcher: ScriptSearcher? = nil) {
        self.searcher = searcher
    }

    /// The view owns the searcher (`AppState`), not the model, so it is supplied once on appear.
    func attach(_ searcher: ScriptSearcher) {
        self.searcher = searcher
    }

    func isPersisted(_ script: ScriptItem) -> Bool {
        scripts.contains { $0.id == script.id }
    }

    // MARK: - Draft Lifecycle

    /// Starts a new draft row, writing any pending edit first. Appends only on commit.
    func beginAdding() {
        commitEditing()
        let newDraft = ScriptItem(title: "", command: "")
        expandedScriptId = newDraft.id
        editingScript = newDraft
    }

    /// Expands or collapses a row, writing any pending edit first.
    func toggleExpansion(of script: ScriptItem) {
        commitEditing()
        if expandedScriptId == script.id {
            collapse()
        } else {
            expandedScriptId = script.id
            editingScript = script
        }
    }

    func collapse() {
        expandedScriptId = nil
        editingScript = nil
    }

    /// Re-reads both JSON files from disk; the open draft is left untouched, as before.
    func reload() {
        searcher?.load()
    }

    // MARK: - Commit

    /// Writes the draft: an empty title *and* command discards it (or deletes the stored script),
    /// otherwise it is inserted or updated under its existing id. Titles are not constrained —
    /// a script may be saved untitled, and duplicate titles are allowed.
    func commitEditing() {
        guard let editing = editingScript, let searcher else { return }
        let exists = searcher.scripts.contains { $0.id == editing.id }

        if editing.title.isEmpty, editing.command.isEmpty {
            if exists {
                searcher.remove(id: editing.id)
            }
        } else if exists {
            searcher.update(editing)
        } else {
            searcher.insert(editing)
        }
    }

    // MARK: - Script Mutations

    func remove(_ script: ScriptItem) {
        if isPersisted(script) {
            searcher?.remove(id: script.id)
        }
        if expandedScriptId == script.id {
            collapse()
        }
    }

    // MARK: - Env Var Mutations

    func addEnvVar() {
        searcher?.addEnvVar()
    }

    func updateEnvVar(_ envVar: EnvVar) {
        searcher?.updateEnvVar(envVar)
    }

    func removeEnvVar(id: String) {
        searcher?.removeEnvVar(id: id)
    }
}
