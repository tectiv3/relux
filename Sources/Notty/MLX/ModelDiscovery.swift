import Foundation

struct LocalModel: Identifiable, Hashable, Sendable {
    let id: String
    let path: URL
    let name: String
    let sizeBytes: UInt64
}

enum ModelDiscovery {
    static let searchPaths: [String] = [
        "~/.swama/models",
        "~/.cache/huggingface/hub",
        "~/Library/Application Support/Notty/models",
    ]

    static func discoverModels() -> [LocalModel] {
        let fm = FileManager.default
        var models: [LocalModel] = []

        for searchPath in searchPaths {
            let expanded = NSString(string: searchPath).expandingTildeInPath
            let baseURL = URL(fileURLWithPath: expanded)

            guard fm.fileExists(atPath: expanded) else { continue }

            let isHuggingFaceCache = searchPath.contains("huggingface/hub")

            if isHuggingFaceCache {
                models.append(contentsOf: discoverHuggingFaceModels(at: baseURL, fm: fm))
            } else {
                models.append(contentsOf: discoverDirectoryModels(at: baseURL, fm: fm))
            }
        }

        return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - HuggingFace Cache

    // HF cache layout: hub/models--org--name/snapshots/<hash>/config.json
    private static func discoverHuggingFaceModels(at baseURL: URL, fm: FileManager) -> [LocalModel] {
        var models: [LocalModel] = []

        guard let contents = try? fm.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for dir in contents {
            let dirName = dir.lastPathComponent
            guard dirName.hasPrefix("models--") else { continue }

            let modelName = String(dirName.dropFirst("models--".count))
                .replacingOccurrences(of: "--", with: "/")

            let snapshotsURL = dir.appendingPathComponent("snapshots")
            guard let snapshots = try? fm.contentsOfDirectory(
                at: snapshotsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            // Pick the first snapshot that has config.json
            for snapshot in snapshots {
                let configURL = snapshot.appendingPathComponent("config.json")
                guard fm.fileExists(atPath: configURL.path) else { continue }

                let size = directorySize(at: snapshot, fm: fm)
                models.append(LocalModel(
                    id: modelName,
                    path: snapshot,
                    name: modelName,
                    sizeBytes: size
                ))
                break
            }
        }

        return models
    }

    // MARK: - Flat Directory Models

    private static func discoverDirectoryModels(at baseURL: URL, fm: FileManager) -> [LocalModel] {
        var models: [LocalModel] = []

        guard let contents = try? fm.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for dir in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let configURL = dir.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configURL.path) else { continue }

            let parent = baseURL.lastPathComponent
            let name = "\(parent)/\(dir.lastPathComponent)"
            let size = directorySize(at: dir, fm: fm)

            models.append(LocalModel(
                id: name,
                path: dir,
                name: name,
                sizeBytes: size
            ))
        }

        return models
    }

    // MARK: - Helpers

    private static func directorySize(at url: URL, fm: FileManager) -> UInt64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize
            {
                total += UInt64(size)
            }
        }
        return total
    }
}
