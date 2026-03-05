import Foundation

struct LocalModel: Identifiable, Hashable, Sendable {
    let id: String
    let path: URL
    let name: String
    let sizeBytes: UInt64

    var standardizedPath: String {
        path.standardizedFileURL.path
    }

    static func matching(path: String, in models: [LocalModel]) -> LocalModel? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return models.first { $0.standardizedPath == standardized }
    }
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
                // Swama and similar: org/model nested structure
                models.append(contentsOf: discoverNestedModels(at: baseURL, fm: fm))
            }
        }

        return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - HuggingFace Cache

    // HF cache layout: hub/models--org--name/snapshots/<hash>/ (files are symlinks to ../../blobs/)
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

            for snapshot in snapshots {
                let configURL = snapshot.appendingPathComponent("config.json")
                guard fm.fileExists(atPath: configURL.path) else { continue }

                // HF uses blobs dir for actual file sizes (snapshots contain symlinks)
                let blobsURL = dir.appendingPathComponent("blobs")
                let size = directorySize(at: blobsURL, fm: fm)

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

    // MARK: - Nested Directory Models (org/model structure)

    private static func discoverNestedModels(at baseURL: URL, fm: FileManager) -> [LocalModel] {
        var models: [LocalModel] = []

        guard let orgDirs = try? fm.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for orgDir in orgDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: orgDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Check if this directory itself is a model (config.json at top level)
            let directConfig = orgDir.appendingPathComponent("config.json")
            if fm.fileExists(atPath: directConfig.path) {
                let name = orgDir.lastPathComponent
                let size = directorySize(at: orgDir, fm: fm)
                models.append(LocalModel(id: name, path: orgDir, name: name, sizeBytes: size))
                continue
            }

            // Otherwise treat as org directory, scan children
            guard let modelDirs = try? fm.contentsOfDirectory(
                at: orgDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for modelDir in modelDirs {
                var isModelDir: ObjCBool = false
                guard fm.fileExists(atPath: modelDir.path, isDirectory: &isModelDir), isModelDir.boolValue else { continue }

                let configURL = modelDir.appendingPathComponent("config.json")
                guard fm.fileExists(atPath: configURL.path) else { continue }

                let orgName = orgDir.lastPathComponent
                let modelName = modelDir.lastPathComponent
                let name = "\(orgName)/\(modelName)"
                let size = directorySize(at: modelDir, fm: fm)

                models.append(LocalModel(id: name, path: modelDir, name: name, sizeBytes: size))
            }
        }

        return models
    }

    // MARK: - Helpers

    private static func directorySize(at url: URL, fm: FileManager) -> UInt64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            // Resolve symlinks to get actual file size
            let resolved = fileURL.resolvingSymlinksInPath()
            if let values = try? resolved.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize
            {
                total += UInt64(size)
            }
        }
        return total
    }
}
