import XCTest

/// `ScriptSearcher` writes `scripts.json` and `env.json` under Application Support by default, so
/// every test here injects a fresh temporary directory and never touches the real store.
final class ScriptsSettingsModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("relux-scripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    @MainActor
    private func makeModel() -> (searcher: ScriptSearcher, model: ScriptsSettingsModel) {
        let searcher = ScriptSearcher(directory: directory)
        return (searcher, ScriptsSettingsModel(searcher: searcher))
    }

    /// A second searcher over the same directory sees only what was actually written to disk.
    @MainActor
    private func reloadedSearcher() -> ScriptSearcher {
        ScriptSearcher(directory: directory)
    }

    // MARK: - Commit

    @MainActor
    func testCommitInsertsDraftUnderItsOwnId() throws {
        let (searcher, model) = makeModel()
        model.beginAdding()
        let draftId = try XCTUnwrap(model.editingScript?.id)
        model.editingScript?.title = "List files"
        model.editingScript?.command = "ls -la"

        model.commitEditing()
        XCTAssertEqual(searcher.scripts.count, 1)
        XCTAssertEqual(searcher.scripts.first?.id, draftId)
        XCTAssertEqual(searcher.scripts.first?.command, "ls -la")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("scripts.json").path))
    }

    @MainActor
    func testCommitUpdatesExistingScriptInPlace() throws {
        let (searcher, model) = makeModel()
        searcher.add(title: "First", command: "echo 1")
        searcher.add(title: "Second", command: "echo 2")
        let originalIds = searcher.scripts.map(\.id)
        let secondId = try XCTUnwrap(originalIds.last)

        model.toggleExpansion(of: searcher.scripts[1])
        model.editingScript?.command = "echo 3"
        model.commitEditing()

        XCTAssertEqual(searcher.scripts.map(\.id), originalIds)
        XCTAssertEqual(searcher.scripts[1].id, secondId)
        XCTAssertEqual(searcher.scripts[1].command, "echo 3")
        XCTAssertEqual(searcher.scripts.count, 2)
    }

    @MainActor
    func testCommitDiscardsFullyEmptyDraft() {
        let (searcher, model) = makeModel()
        model.beginAdding()
        model.commitEditing()
        XCTAssertTrue(searcher.scripts.isEmpty)
    }

    @MainActor
    func testCommitDeletesScriptEmptiedInTheForm() {
        let (searcher, model) = makeModel()
        searcher.add(title: "Gone", command: "rm -rf ./tmp")
        model.toggleExpansion(of: searcher.scripts[0])
        model.editingScript?.title = ""
        model.editingScript?.command = ""

        model.commitEditing()
        XCTAssertTrue(searcher.scripts.isEmpty)
        XCTAssertTrue(reloadedSearcher().scripts.isEmpty)
    }

    // MARK: - Titles Are Unconstrained

    @MainActor
    func testEmptyTitleSaves() throws {
        let (searcher, model) = makeModel()
        model.beginAdding()
        model.editingScript?.command = "ls"

        model.commitEditing()

        XCTAssertEqual(searcher.scripts.count, 1)
        XCTAssertEqual(searcher.scripts.first?.title, "")
        XCTAssertEqual(searcher.scripts.first?.command, "ls")
        XCTAssertEqual(try XCTUnwrap(reloadedSearcher().scripts.first).command, "ls")
    }

    @MainActor
    func testWhitespaceOnlyTitleSaves() {
        let (searcher, model) = makeModel()
        model.beginAdding()
        model.editingScript?.title = "   "
        model.editingScript?.command = "ls"

        model.commitEditing()

        XCTAssertEqual(searcher.scripts.count, 1)
        XCTAssertEqual(searcher.scripts.first?.title, "   ")
    }

    @MainActor
    func testEmptyTitleAndCommandOnANewDraftIsNotInserted() {
        let (searcher, model) = makeModel()
        model.beginAdding()
        model.editingScript?.title = ""
        model.editingScript?.command = ""

        model.commitEditing()

        XCTAssertTrue(searcher.scripts.isEmpty)
    }

    @MainActor
    func testDuplicateTitlesAreBothSaved() {
        let (searcher, model) = makeModel()
        searcher.add(title: "Hash", command: "echo 1")

        model.beginAdding()
        model.editingScript?.title = "hash"
        model.editingScript?.command = "echo 2"
        model.commitEditing()

        XCTAssertEqual(searcher.scripts.map(\.title), ["Hash", "hash"])
        XCTAssertEqual(reloadedSearcher().scripts.count, 2)
    }

    @MainActor
    func testSwitchingRowsCommitsThePendingEditThenExpandsTheOther() throws {
        let (searcher, model) = makeModel()
        searcher.add(title: "Alpha", command: "echo a")

        model.beginAdding()
        model.editingScript?.command = "echo b"
        let draftId = try XCTUnwrap(model.editingScript?.id)

        model.toggleExpansion(of: searcher.scripts[0])

        XCTAssertEqual(searcher.scripts.count, 2, "the pending draft is written first")
        XCTAssertEqual(searcher.scripts.last?.id, draftId)
        XCTAssertEqual(model.editingScript?.id, searcher.scripts[0].id)
        XCTAssertEqual(model.expandedScriptId, searcher.scripts[0].id)
    }

    // MARK: - Ordering

    @MainActor
    func testAddAppendsToTheEndOfTheList() {
        let (searcher, model) = makeModel()
        for title in ["alpha", "beta"] {
            model.beginAdding()
            model.editingScript?.title = title
            model.editingScript?.command = "echo \(title)"
            model.commitEditing()
        }
        XCTAssertEqual(searcher.scripts.map(\.title), ["alpha", "beta"])
    }

    @MainActor
    func testBeginAddingCommitsThePendingEditFirst() {
        let (searcher, model) = makeModel()
        model.beginAdding()
        model.editingScript?.title = "Committed"
        model.editingScript?.command = "true"

        model.beginAdding()

        XCTAssertEqual(searcher.scripts.map(\.title), ["Committed"])
        XCTAssertNotEqual(model.editingScript?.id, searcher.scripts.first?.id)
        XCTAssertEqual(model.expandedScriptId, model.editingScript?.id)
    }

    // MARK: - Removal

    @MainActor
    func testRemoveDropsPersistedScriptAndCollapsesTheRow() {
        let (searcher, model) = makeModel()
        searcher.add(title: "A", command: "echo a")
        searcher.add(title: "B", command: "echo b")

        model.toggleExpansion(of: searcher.scripts[0])
        model.remove(searcher.scripts[0])

        XCTAssertEqual(searcher.scripts.map(\.title), ["B"])
        XCTAssertNil(model.expandedScriptId)
        XCTAssertNil(model.editingScript)
    }

    @MainActor
    func testRemoveOfAnUnpersistedDraftLeavesTheListIntact() throws {
        let (searcher, model) = makeModel()
        searcher.add(title: "A", command: "echo a")
        model.beginAdding()

        try model.remove(XCTUnwrap(model.editingScript))

        XCTAssertEqual(searcher.scripts.map(\.title), ["A"])
        XCTAssertNil(model.editingScript)
    }

    // MARK: - Persistence

    @MainActor
    func testFlagsPersistAcrossReload() throws {
        let (_, model) = makeModel()
        model.beginAdding()
        model.editingScript?.title = "Flags"
        model.editingScript?.command = "cat"
        model.editingScript?.inputMode = .stdin
        model.editingScript?.inputFilter = .integer
        model.editingScript?.outputMode = .capture
        model.commitEditing()

        let saved = try XCTUnwrap(reloadedSearcher().scripts.first)
        XCTAssertEqual(saved.title, "Flags")
        XCTAssertEqual(saved.command, "cat")
        XCTAssertEqual(saved.inputMode, .stdin)
        XCTAssertEqual(saved.inputFilter, .integer)
        XCTAssertEqual(saved.outputMode, .capture)
    }

    @MainActor
    func testReloadReplacesTheListFromDiskAndKeepsTheDraft() throws {
        let (searcher, model) = makeModel()
        searcher.add(title: "Local", command: "echo local")

        model.beginAdding()
        model.editingScript?.title = "Draft in progress"

        let writer = reloadedSearcher()
        try writer.remove(id: XCTUnwrap(writer.scripts.first?.id))
        XCTAssertEqual(searcher.scripts.count, 1, "in-memory list is untouched until reload")

        model.reload()

        XCTAssertTrue(searcher.scripts.isEmpty)
        XCTAssertEqual(model.editingScript?.title, "Draft in progress")
    }

    // MARK: - Environment Variables

    @MainActor
    func testEnvVarCRUD() throws {
        let (searcher, model) = makeModel()
        model.addEnvVar()
        XCTAssertEqual(searcher.envVars.count, 1)
        XCTAssertEqual(searcher.envVars[0].name, "")
        XCTAssertTrue(searcher.envVars[0].enabled)

        var updated = searcher.envVars[0]
        updated.name = "API_HOST"
        updated.value = "localhost"
        model.updateEnvVar(updated)

        XCTAssertEqual(searcher.envVars[0].name, "API_HOST")
        XCTAssertEqual(searcher.envVars[0].value, "localhost")

        let saved = try XCTUnwrap(reloadedSearcher().envVars.first)
        XCTAssertEqual(saved.name, "API_HOST")
        XCTAssertEqual(saved.value, "localhost")

        model.removeEnvVar(id: saved.id)
        XCTAssertTrue(searcher.envVars.isEmpty)
        XCTAssertTrue(reloadedSearcher().envVars.isEmpty)
    }

    @MainActor
    func testEnvVarEnabledTogglePersists() throws {
        let (searcher, model) = makeModel()
        model.addEnvVar()

        var envVar = searcher.envVars[0]
        envVar.name = "TOKEN"
        envVar.enabled = false
        model.updateEnvVar(envVar)

        let saved = try XCTUnwrap(reloadedSearcher().envVars.first)
        XCTAssertEqual(saved.name, "TOKEN")
        XCTAssertFalse(saved.enabled)
    }
}
