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
            let fileDescriptor = open(dirPath, O_EVTONLY)
            guard fileDescriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: .write,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.handleDirectoryChange(at: dirPath)
                }
            }
            source.setCancelHandler {
                close(fileDescriptor)
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
        for index in 0 ..< mdQuery.resultCount {
            guard let item = mdQuery.result(at: index) as? NSMetadataItem,
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
        let lowercasedQuery = query.lowercased()

        var scored: [(app: AppItem, score: Double)] = []
        for app in apps {
            let name = app.name.lowercased()
            let bonus: Double = newlyDetected.contains(app.path.path) ? 50 : 0
            if name == lowercasedQuery {
                scored.append((app, 950 + bonus))
            } else if name.hasPrefix(lowercasedQuery) {
                scored.append((app, 800 + bonus))
            } else if name.contains(lowercasedQuery) {
                scored.append((app, 600 + bonus))
            } else if fuzzyMatch(query: lowercasedQuery, target: name) {
                scored.append((app, 350 + bonus))
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
                isNew: newlyDetected.contains(item.app.path.path),
                score: item.score
            )
        }
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
