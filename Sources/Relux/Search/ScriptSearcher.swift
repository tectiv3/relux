import Foundation

enum ScriptOutputMode: String, Codable, CaseIterable, Sendable {
    case none
    case capture
    case replace

    var label: String {
        switch self {
        case .none: "None"
        case .capture: "Capture"
        case .replace: "Replace"
        }
    }
}

enum InputFilter: Codable, Sendable, Equatable {
    case any
    case integer
    case number
    case url
    case json
    case datetime
    case regex(String)

    var label: String {
        switch self {
        case .any: "Any"
        case .integer: "Integer"
        case .number: "Number"
        case .url: "URL"
        case .json: "JSON"
        case .datetime: "Date/Time"
        case .regex: "Regex"
        }
    }

    var regexPattern: String? {
        if case let .regex(pattern) = self { return pattern }
        return nil
    }

    func matches(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch self {
        case .any:
            return true
        case .integer:
            return trimmed.range(of: #"^\d+$"#, options: .regularExpression) != nil
        case .number:
            return trimmed.range(of: #"^-?\d+\.?\d*$"#, options: .regularExpression) != nil
        case .url:
            return trimmed.range(of: #"^https?://"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}"#, options: .regularExpression) != nil
        case .json:
            return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        case .datetime:
            return trimmed.range(of: #"^\d{4}-\d{2}-\d{2}(\s\d{2}:\d{2}(:\d{2})?)?$"#, options: .regularExpression) != nil
        case let .regex(pattern):
            guard !pattern.isEmpty,
                  let re = try? NSRegularExpression(pattern: pattern) else { return false }
            return re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
        }
    }

    /// Tag string for use in SwiftUI Picker bindings
    var tag: String {
        switch self {
        case .any: "any"
        case .integer: "integer"
        case .number: "number"
        case .url: "url"
        case .json: "json"
        case .datetime: "datetime"
        case .regex: "regex"
        }
    }

    static func fromTag(_ tag: String, existingPattern: String? = nil) -> InputFilter {
        switch tag {
        case "integer": .integer
        case "number": .number
        case "url": .url
        case "json": .json
        case "datetime": .datetime
        case "regex": .regex(existingPattern ?? "")
        default: .any
        }
    }
}

struct ScriptItem: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var command: String
    var acceptsSelection: Bool
    var outputMode: ScriptOutputMode
    var inputFilter: InputFilter

    init(title: String, command: String, acceptsSelection: Bool = false, outputMode: ScriptOutputMode = .none, inputFilter: InputFilter = .any) {
        id = UUID().uuidString
        self.title = title
        self.command = command
        self.acceptsSelection = acceptsSelection
        self.outputMode = outputMode
        self.inputFilter = inputFilter
    }

    /// Backward-compatible decoding for existing scripts.json lacking new fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decode(String.self, forKey: .command)
        acceptsSelection = try container.decodeIfPresent(Bool.self, forKey: .acceptsSelection) ?? false
        // Migrate old capturesOutput bool to new outputMode enum
        if let mode = try container.decodeIfPresent(ScriptOutputMode.self, forKey: .outputMode) {
            outputMode = mode
        } else {
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .capturesOutput) ?? false
            outputMode = legacy ? .capture : .none
        }
        inputFilter = try container.decodeIfPresent(InputFilter.self, forKey: .inputFilter) ?? .any
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, command, acceptsSelection, outputMode, capturesOutput, inputFilter
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(command, forKey: .command)
        try container.encode(acceptsSelection, forKey: .acceptsSelection)
        try container.encode(outputMode, forKey: .outputMode)
        try container.encode(inputFilter, forKey: .inputFilter)
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
        let dir = support.appendingPathComponent("Relux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("scripts.json")
        envPath = dir.appendingPathComponent("env.json")
        load()
    }

    // MARK: - Script Mutations

    func add(title: String, command: String, acceptsSelection: Bool = false, outputMode: ScriptOutputMode = .none) {
        scripts.append(ScriptItem(title: title, command: command, acceptsSelection: acceptsSelection, outputMode: outputMode))
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

    func search(_ query: String, limit: Int = 5, stdinValue: String? = nil) -> [SearchItem] {
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
            } else if script.acceptsSelection {
                let effective = stdinValue ?? query
                if script.inputFilter.matches(effective) {
                    scored.append((script, 10))
                }
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
                    "outputMode": item.script.outputMode.rawValue,
                ]
            )
        }
    }

    // MARK: - Persistence

    func load() {
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
