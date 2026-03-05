import Foundation

struct AppItem {
    let name: String
    let path: URL
}

@MainActor
final class AppSearcher {
    private var apps: [AppItem] = []

    init() { refresh() }

    func refresh() {
        var found: [String: AppItem] = [:]
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        let fm = FileManager.default
        for dir in dirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                if found[name] == nil {
                    found[name] = AppItem(name: name, path: url)
                }
            }
            for url in contents where url.hasDirectoryPath && url.pathExtension != "app" {
                guard let sub = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for subUrl in sub where subUrl.pathExtension == "app" {
                    let name = subUrl.deletingPathExtension().lastPathComponent
                    if found[name] == nil {
                        found[name] = AppItem(name: name, path: subUrl)
                    }
                }
            }
        }
        apps = Array(found.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
