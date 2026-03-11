import Foundation
import os

private let logger = Logger(subsystem: "com.relux.app", category: "ScriptSearcher")

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

enum InputMode: String, Codable, CaseIterable, Sendable {
    case none
    case stdin
    case argument

    var label: String {
        switch self {
        case .none: "None"
        case .stdin: "Stdin"
        case .argument: "Argument"
        }
    }

    var acceptsInput: Bool {
        self != .none
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
        var trimmed = input.trimmingCharacters(in: .controlCharacters)
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return false }
        switch self {
        case .any:
            return true
        case .integer:
            return Int(trimmed) != nil
        case .number:
            guard let val = Double(trimmed), val.isFinite else { return false }
            return true
        case .url:
            // Basic URL detection
            if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
                return true
            }
            // Fallback to regex for things that look like URLs but might lack scheme
            return trimmed.range(of: #"^https?://"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}"#, options: .regularExpression) != nil
        case .json:
            return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        case .datetime:
            let pattern = #"^\d{4}-\d{2}-\d{2}(\s\d{2}:\d{2}(:\d{2})?)?$"#
            return trimmed.range(of: pattern, options: .regularExpression) != nil
        case let .regex(pattern):
            guard !pattern.isEmpty,
                  let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            // Limit to first 4 KB to guard against pathological patterns on large input
            let safe = trimmed.count > 4096 ? String(trimmed.prefix(4096)) : trimmed
            return regex.firstMatch(
                in: safe,
                options: .withoutAnchoringBounds,
                range: NSRange(safe.startIndex..., in: safe)
            ) != nil
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
    var inputMode: InputMode
    var outputMode: ScriptOutputMode
    var inputFilter: InputFilter

    init(
        title: String, command: String, inputMode: InputMode = .none,
        outputMode: ScriptOutputMode = .none, inputFilter: InputFilter = .any
    ) {
        id = UUID().uuidString
        self.title = title
        self.command = command
        self.inputMode = inputMode
        self.outputMode = outputMode
        self.inputFilter = inputFilter
    }

    /// Backward-compatible decoding for existing scripts.json
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decode(String.self, forKey: .command)
        // Migrate legacy acceptsSelection bool → inputMode enum
        if let mode = try container.decodeIfPresent(InputMode.self, forKey: .inputMode) {
            inputMode = mode
        } else {
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .acceptsSelection) ?? false
            inputMode = legacy ? .stdin : .none
        }
        if let mode = try container.decodeIfPresent(ScriptOutputMode.self, forKey: .outputMode) {
            outputMode = mode
        } else {
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .capturesOutput) ?? false
            outputMode = legacy ? .capture : .none
        }
        inputFilter = try container.decodeIfPresent(InputFilter.self, forKey: .inputFilter) ?? .any
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, command, inputMode, acceptsSelection, outputMode, capturesOutput, inputFilter
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(command, forKey: .command)
        try container.encode(inputMode, forKey: .inputMode)
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

    func add(title: String, command: String, inputMode: InputMode = .none, outputMode: ScriptOutputMode = .none) {
        scripts.append(ScriptItem(title: title, command: command, inputMode: inputMode, outputMode: outputMode))
        save()
    }

    func insert(_ item: ScriptItem) {
        scripts.append(item)
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
        for envVar in envVars where envVar.enabled && !envVar.name.isEmpty {
            env[envVar.name] = envVar.value
        }
        return env
    }

    // MARK: - Search

    func search(_ query: String, limit: Int = 5, stdinValue: String? = nil) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let lowercasedQuery = query.lowercased()

        var scored: [(script: ScriptItem, score: Double)] = []
        for script in scripts {
            let name = script.title.lowercased()
            if name == lowercasedQuery {
                scored.append((script, 930))
            } else if name.hasPrefix(lowercasedQuery) {
                scored.append((script, 780))
            } else if name.contains(lowercasedQuery) {
                scored.append((script, 580))
            } else if fuzzyMatch(query: lowercasedQuery, target: name) {
                scored.append((script, 330))
            } else if script.inputMode.acceptsInput {
                let effective = stdinValue ?? query
                if script.inputFilter.matches(effective) {
                    let filterScore: Double = script.inputFilter == .any ? 100 : 700
                    scored.append((script, filterScore))
                }
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { item in
            let acceptsInput = item.script.inputMode.acceptsInput
                && stdinValue.map { item.script.inputFilter.matches($0) } ?? true
            return SearchItem(
                id: "script:\(item.script.id)",
                title: item.script.title,
                subtitle: item.script.command,
                icon: "terminal",
                kind: .script,
                meta: [
                    "command": item.script.command,
                    "acceptsInput": acceptsInput ? "1" : "0",
                    "inputMode": item.script.inputMode.rawValue,
                    "outputMode": item.script.outputMode.rawValue,
                ],
                score: item.score
            )
        }
    }

    // MARK: - Persistence

    func load() {
        do {
            if FileManager.default.fileExists(atPath: storePath.path) {
                let data = try Data(contentsOf: storePath)
                scripts = try JSONDecoder().decode([ScriptItem].self, from: data)
            }
        } catch {
            logger.error("Failed to load scripts: \(error)")
        }

        do {
            if FileManager.default.fileExists(atPath: envPath.path) {
                let data = try Data(contentsOf: envPath)
                envVars = try JSONDecoder().decode([EnvVar].self, from: data)
            }
        } catch {
            logger.error("Failed to load env vars: \(error)")
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
        for char in query {
            guard let found = target[targetIdx...].firstIndex(of: char) else { return false }
            targetIdx = target.index(after: found)
        }
        return true
    }
}
