import AppKit
import Foundation

struct AppItem {
    let name: String
    let path: URL
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
    }

    private func restartSpotlightQuery() {
        query?.stop()
        query = nil
        apps = []
        startSpotlightQuery()
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
                found[name] = AppItem(name: name, path: url)
            }
        }

        mdQuery.enableUpdates()
        apps = Array(found.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func search(_ query: String, limit: Int = 5) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()

        var scored: [(app: AppItem, score: Int)] = []
        for app in apps {
            let name = app.name.lowercased()
            if name == q {
                scored.append((app, 100))
            } else if name.hasPrefix(q) {
                scored.append((app, 80))
            } else if name.contains(q) {
                scored.append((app, 60))
            } else if fuzzyMatch(query: q, target: name) {
                scored.append((app, 40))
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
                meta: ["path": item.app.path.path]
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
