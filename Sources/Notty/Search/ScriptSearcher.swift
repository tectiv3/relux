import Foundation

struct ScriptItem: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var command: String
    var acceptsSelection: Bool

    init(title: String, command: String, acceptsSelection: Bool = false) {
        id = UUID().uuidString
        self.title = title
        self.command = command
        self.acceptsSelection = acceptsSelection
    }

    /// Backward-compatible decoding for existing scripts.json lacking acceptsSelection
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decode(String.self, forKey: .command)
        acceptsSelection = try container.decodeIfPresent(Bool.self, forKey: .acceptsSelection) ?? false
    }
}

struct EnvVar: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var value: String
    var enabled: Bool

    init(name: String = "", value: String = "", enabled: Bool = true) {
        id = UUID().uuidString
        self.name = name
        self.value = value
        self.enabled = enabled
    }
}

@MainActor
@Observable
final class ScriptSearcher {
    private(set) var scripts: [ScriptItem] = []
    private(set) var envVars: [EnvVar] = []
    private let storePath: URL
    private let envPath: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Notty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("scripts.json")
        envPath = dir.appendingPathComponent("env.json")
        load()
    }

    // MARK: - Script Mutations

    func add(title: String, command: String, acceptsSelection: Bool = false) {
        scripts.append(ScriptItem(title: title, command: command, acceptsSelection: acceptsSelection))
        save()
    }

    func remove(id: String) {
        scripts.removeAll { $0.id == id }
        save()
    }

    func update(_ item: ScriptItem) {
        guard let idx = scripts.firstIndex(where: { $0.id == item.id }) else { return }
        scripts[idx] = item
        save()
    }

    // MARK: - Env Var Mutations

    func addEnvVar() {
        envVars.append(EnvVar())
        saveEnv()
    }

    func removeEnvVar(id: String) {
        envVars.removeAll { $0.id == id }
        saveEnv()
    }

    func updateEnvVar(_ envVar: EnvVar) {
        guard let idx = envVars.firstIndex(where: { $0.id == envVar.id }) else { return }
        envVars[idx] = envVar
        saveEnv()
    }

    /// Builds environment for script execution: login shell env + enabled custom vars
    func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for v in envVars where v.enabled && !v.name.isEmpty {
            env[v.name] = v.value
        }
        return env
    }

    // MARK: - Search

    func search(_ query: String, limit: Int = 5) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()

        var scored: [(script: ScriptItem, score: Int)] = []
        for script in scripts {
            let name = script.title.lowercased()
            if name == q {
                scored.append((script, 100))
            } else if name.hasPrefix(q) {
                scored.append((script, 80))
            } else if name.contains(q) {
                scored.append((script, 60))
            } else if fuzzyMatch(query: q, target: name) {
                scored.append((script, 40))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { item in
            SearchItem(
                id: "script:\(item.script.id)",
                title: item.script.title,
                subtitle: item.script.command,
                icon: "terminal",
                kind: .script,
                meta: [
                    "command": item.script.command,
                    "acceptsSelection": item.script.acceptsSelection ? "1" : "0",
                ]
            )
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: storePath),
           let decoded = try? JSONDecoder().decode([ScriptItem].self, from: data)
        {
            scripts = decoded
        }
        if let data = try? Data(contentsOf: envPath),
           let decoded = try? JSONDecoder().decode([EnvVar].self, from: data)
        {
            envVars = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        try? data.write(to: storePath, options: .atomic)
    }

    private func saveEnv() {
        guard let data = try? JSONEncoder().encode(envVars) else { return }
        try? data.write(to: envPath, options: .atomic)
    }

    private func fuzzyMatch(query: String, target: String) -> Bool {
        var targetIdx = target.startIndex
        for ch in query {
            guard let found = target[targetIdx...].firstIndex(of: ch) else { return false }
            targetIdx = target.index(after: found)
        }
        return true
    }
}
