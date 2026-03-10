import AppKit
import Foundation

struct AppItem {
    let name: String
    let path: URL
    let bundleID: String?
}

@MainActor
final class AppSearcher {
    static let defaultSearchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    private var apps: [AppItem] = []
    private var query: NSMetadataQuery?
    private var newlyDetected: Set<String> = []
    private var watchSources: [DispatchSourceFileSystemObject] = []

    var searchPaths: [String] {
        didSet {
            UserDefaults.standard.set(searchPaths, forKey: "appSearchPaths")
            restartSpotlightQuery()
        }
    }

    init() {
        searchPaths = UserDefaults.standard.stringArray(forKey: "appSearchPaths")
            ?? Self.defaultSearchPaths
        startSpotlightQuery()
        startDirectoryWatchers()
    }

    private func restartSpotlightQuery() {
        query?.stop()
        query = nil
        apps = []
        newlyDetected.removeAll()
        startSpotlightQuery()
    }

    /// Only watch the two main install targets, not all searchPaths
    /// (system dirs rarely change, and /Applications/Utilities is flat inside /Applications)
    private func startDirectoryWatchers() {
        stopDirectoryWatchers()

        let watchPaths = ["/Applications", NSHomeDirectory() + "/Applications"]
        for dirPath in watchPaths {
            let fd = open(dirPath, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.handleDirectoryChange(at: dirPath)
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            watchSources.append(source)
        }
    }

    private func stopDirectoryWatchers() {
        for source in watchSources {
            source.cancel()
        }
        watchSources = []
    }

    private func handleDirectoryChange(at dirPath: String) {
        let dirURL = URL(fileURLWithPath: dirPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let knownPaths = Set(apps.map(\.path.path))
        for url in contents where url.pathExtension == "app" {
            let path = url.path
            guard !knownPaths.contains(path) else { continue }

            let name = url.deletingPathExtension().lastPathComponent
            let bundleID = Bundle(url: url)?.bundleIdentifier
            apps.append(AppItem(name: name, path: url, bundleID: bundleID))
            newlyDetected.insert(path)
        }
    }

    private func startSpotlightQuery() {
        let mdQuery = NSMetadataQuery()
        mdQuery.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        mdQuery.searchScopes = searchPaths.map { URL(fileURLWithPath: $0) }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: mdQuery,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleQueryResults()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: mdQuery,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleQueryResults()
            }
        }

        query = mdQuery
        mdQuery.start()
    }

    private func handleQueryResults() {
        guard let mdQuery = query else { return }
        mdQuery.disableUpdates()

        var found: [String: AppItem] = [:]
        for i in 0 ..< mdQuery.resultCount {
            guard let item = mdQuery.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String
            else { continue }

            let url = URL(fileURLWithPath: path)
            let name = item.value(forAttribute: kMDItemDisplayName as String) as? String
                ?? url.deletingPathExtension().lastPathComponent
            if found[name] == nil {
                let bundleID = item.value(forAttribute: kMDItemCFBundleIdentifier as String) as? String
                found[name] = AppItem(name: name, path: url, bundleID: bundleID)
            }
        }

        mdQuery.enableUpdates()

        // Drain: any app now in Spotlight is no longer "newly detected"
        let spotlightPaths = Set(found.values.map(\.path.path))
        newlyDetected.subtract(spotlightPaths)

        // Merge: preserve FSEvents-detected apps that Spotlight hasn't indexed yet
        for path in newlyDetected {
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            if found[name] == nil {
                let bundleID = Bundle(url: url)?.bundleIdentifier
                found[name] = AppItem(name: name, path: url, bundleID: bundleID)
            }
        }

        apps = Array(found.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func search(_ query: String, limit: Int = 5) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()

        var scored: [(app: AppItem, score: Int, isNew: Bool)] = []
        let boost = 20
        for app in apps {
            let name = app.name.lowercased()
            let isNew = newlyDetected.contains(app.path.path)
            let b = isNew ? boost : 0
            if name == q {
                scored.append((app, 100 + b, isNew))
            } else if name.hasPrefix(q) {
                scored.append((app, 80 + b, isNew))
            } else if name.contains(q) {
                scored.append((app, 60 + b, isNew))
            } else if fuzzyMatch(query: q, target: name) {
                scored.append((app, 40 + b, isNew))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { item in
            SearchItem(
                id: "app:\(item.app.path.path)",
                title: item.app.name,
                subtitle: item.app.path.deletingLastPathComponent().path,
                icon: "app.dashed",
                kind: .app,
                meta: ["path": item.app.path.path, "bundleID": item.app.bundleID ?? ""],
                isNew: item.isNew
            )
        }
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
