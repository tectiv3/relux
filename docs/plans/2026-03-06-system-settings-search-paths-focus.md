# System Settings Search + Configurable Paths + Focus Fix

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add system settings categories to search results, make search index paths editable in Settings, and fix focus loss after clipboard history.

**Architecture:** New `SystemSettingsSearcher` with hardcoded macOS settings deep-links. `AppSearcher` refactored to use a configurable list of search scope paths (persisted in UserDefaults). Focus fix via `NSApp.activate` in `togglePanel` and consistent `panelClosedAt` tracking.

**Tech Stack:** Swift 6, SwiftUI, NSMetadataQuery, UserDefaults

---

### Task 1: Fix focus loss after clipboard history

**Files:**
- Modify: `Sources/Relux/AppDelegate.swift:76-95` (togglePanel)
- Modify: `Sources/Relux/AppDelegate.swift:97-115` (toggleClipboardHistory)

**Step 1: Fix togglePanel — add NSApp.activate after makeKeyAndOrderFront**

In `togglePanel()`, after `panel.makeKeyAndOrderFront(nil)` (line 93), add:

```swift
func togglePanel() {
    guard let panel else { return }
    if panel.isVisible {
        let frame = panel.frame
        UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
        UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
        appState.currentSelection = nil
        appState.panelClosedAt = Date()
        panel.close()
    } else {
        appState.previousApp = NSWorkspace.shared.frontmostApplication
        appState.currentSelection = SelectionCapture.captureSelectedText()
        // Keep last panel mode if closed within 60s
        if Date().timeIntervalSince(appState.panelClosedAt) > 60 {
            appState.panelMode = .search
        }
        applyForcedInputSource()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

**Step 2: Fix toggleClipboardHistory — set panelClosedAt on close**

In `toggleClipboardHistory()`, add `appState.panelClosedAt = Date()` in the close branch:

```swift
func toggleClipboardHistory() {
    guard let panel else { return }
    if panel.isVisible, appState.panelMode == .clipboard {
        let frame = panel.frame
        UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
        UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
        appState.panelClosedAt = Date()
        panel.close()
        return
    }

    if !panel.isVisible {
        appState.previousApp = NSWorkspace.shared.frontmostApplication
    }

    appState.panelMode = .clipboard
    if !panel.isVisible {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

**Step 3: Build and verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/Relux/AppDelegate.swift
git commit -m "Fix focus loss after clipboard history by activating app on panel open"
```

---

### Task 2: Fix Keychain / Utilities search + configurable search paths

**Files:**
- Modify: `Sources/Relux/Search/AppSearcher.swift`
- Modify: `Sources/Relux/UI/SettingsView.swift`

**Step 1: Refactor AppSearcher to use configurable search paths**

Replace `AppSearcher` with configurable paths stored in UserDefaults:

```swift
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
```

**Step 2: Add Search Paths section to SettingsView general tab**

Add state variables at the top of `SettingsView`:

```swift
@State private var searchPaths: [String] = []
@State private var newSearchPath: String = ""
```

Add a new section to `generalTab` (after the "Behavior" section, before "Keyboard Layout"):

```swift
Section {
    ForEach(Array(searchPaths.enumerated()), id: \.offset) { index, path in
        HStack {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Button(role: .destructive) {
                searchPaths.remove(at: index)
                appState.appSearcher.searchPaths = searchPaths
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    HStack {
        TextField("/path/to/directory", text: $newSearchPath)
            .font(.system(size: 12, design: .monospaced))
        Button("Add") {
            let trimmed = newSearchPath.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !searchPaths.contains(trimmed) else { return }
            searchPaths.append(trimmed)
            appState.appSearcher.searchPaths = searchPaths
            newSearchPath = ""
        }
        .disabled(newSearchPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    Button("Reset to Defaults") {
        searchPaths = AppSearcher.defaultSearchPaths
        appState.appSearcher.searchPaths = searchPaths
    }
    .font(.system(size: 12))
} header: {
    Text("Search Paths")
} footer: {
    Text("Directories indexed for application search.")
        .font(.caption)
}
```

In the `onAppear` of `SettingsView.body`, add:

```swift
searchPaths = appState.appSearcher.searchPaths
```

**Step 3: Build and verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/Relux/Search/AppSearcher.swift Sources/Relux/UI/SettingsView.swift
git commit -m "Add configurable search paths with Utilities dirs, editable in Settings"
```

---

### Task 3: Add SystemSettingsSearcher

**Files:**
- Create: `Sources/Relux/Search/SystemSettingsSearcher.swift`
- Modify: `Sources/Relux/Extensions/ExtensionProtocol.swift` (add `.systemSettings` kind)
- Modify: `Sources/Relux/AppState.swift` (add searcher + include in performSearch)
- Modify: `Sources/Relux/UI/OverlayView.swift` (handle `.systemSettings` kind in all switch statements)

**Step 1: Add `.systemSettings` to SearchItemKind**

```swift
enum SearchItemKind: Sendable {
    case app
    case webSearch
    case script
    case translate
    case calculator
    case jwt
    case systemSettings
}
```

**Step 2: Create SystemSettingsSearcher**

```swift
import AppKit
import Foundation

@MainActor
final class SystemSettingsSearcher {
    struct SettingsPane: Sendable {
        let name: String
        let keywords: [String]
        let url: String
    }

    // macOS 13+ deep links
    static let defaultPanes: [SettingsPane] = [
        SettingsPane(name: "Wi-Fi", keywords: ["wifi", "wireless", "network"], url: "x-apple.systempreferences:com.apple.wifi-settings-extension"),
        SettingsPane(name: "Bluetooth", keywords: ["bluetooth", "bt"], url: "x-apple.systempreferences:com.apple.BluetoothSettings"),
        SettingsPane(name: "Network", keywords: ["network", "ethernet", "vpn", "dns"], url: "x-apple.systempreferences:com.apple.Network-Settings.extension"),
        SettingsPane(name: "Sound", keywords: ["sound", "audio", "volume", "speaker", "microphone"], url: "x-apple.systempreferences:com.apple.Sound-Settings.extension"),
        SettingsPane(name: "Displays", keywords: ["display", "monitor", "screen", "resolution", "brightness"], url: "x-apple.systempreferences:com.apple.Displays-Settings.extension"),
        SettingsPane(name: "Keyboard", keywords: ["keyboard", "keys", "input", "typing", "shortcuts"], url: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"),
        SettingsPane(name: "Trackpad", keywords: ["trackpad", "touchpad", "gesture"], url: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"),
        SettingsPane(name: "Mouse", keywords: ["mouse", "cursor", "pointer"], url: "x-apple.systempreferences:com.apple.Mouse-Settings.extension"),
        SettingsPane(name: "Printers & Scanners", keywords: ["printer", "scanner", "print"], url: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension"),
        SettingsPane(name: "Battery", keywords: ["battery", "power", "energy", "charging"], url: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
        SettingsPane(name: "Appearance", keywords: ["appearance", "theme", "dark", "light", "accent"], url: "x-apple.systempreferences:com.apple.Appearance-Settings.extension"),
        SettingsPane(name: "Accessibility", keywords: ["accessibility", "voiceover", "zoom", "a11y"], url: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"),
        SettingsPane(name: "Privacy & Security", keywords: ["privacy", "security", "permissions", "firewall"], url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
        SettingsPane(name: "General", keywords: ["general", "about", "software update", "storage", "airdrop", "login"], url: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings"),
        SettingsPane(name: "Desktop & Dock", keywords: ["desktop", "dock", "stage manager", "wallpaper", "mission control"], url: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"),
        SettingsPane(name: "Notifications", keywords: ["notifications", "alerts", "banners", "focus"], url: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
        SettingsPane(name: "Focus", keywords: ["focus", "do not disturb", "dnd"], url: "x-apple.systempreferences:com.apple.Focus-Settings.extension"),
        SettingsPane(name: "Screen Time", keywords: ["screen time", "usage", "limits"], url: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension"),
        SettingsPane(name: "Lock Screen", keywords: ["lock screen", "screensaver", "screen saver", "password"], url: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"),
        SettingsPane(name: "Users & Groups", keywords: ["users", "groups", "account", "login"], url: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"),
        SettingsPane(name: "Passwords", keywords: ["passwords", "keychain", "passkey"], url: "x-apple.systempreferences:com.apple.Passwords-Settings.extension"),
        SettingsPane(name: "Internet Accounts", keywords: ["internet", "accounts", "icloud", "mail", "google"], url: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"),
        SettingsPane(name: "Wallet & Apple Pay", keywords: ["wallet", "apple pay", "payment"], url: "x-apple.systempreferences:com.apple.WalletSettingsExtension"),
        SettingsPane(name: "Siri", keywords: ["siri", "assistant", "voice"], url: "x-apple.systempreferences:com.apple.Siri-Settings.extension"),
        SettingsPane(name: "Sharing", keywords: ["sharing", "airdrop", "airplay", "remote"], url: "x-apple.systempreferences:com.apple.Sharing-Settings.extension"),
        SettingsPane(name: "Time Machine", keywords: ["time machine", "backup"], url: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"),
        SettingsPane(name: "Startup Disk", keywords: ["startup", "boot", "disk"], url: "x-apple.systempreferences:com.apple.Startup-Disk-Settings.extension"),
    ]

    private let panes: [SettingsPane] = defaultPanes

    func search(_ query: String, limit: Int = 5) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()

        var scored: [(pane: SettingsPane, score: Int)] = []
        for pane in panes {
            let name = pane.name.lowercased()
            if name == q {
                scored.append((pane, 100))
            } else if name.hasPrefix(q) {
                scored.append((pane, 80))
            } else if name.contains(q) {
                scored.append((pane, 60))
            } else if pane.keywords.contains(where: { $0.hasPrefix(q) }) {
                scored.append((pane, 70))
            } else if pane.keywords.contains(where: { $0.contains(q) }) {
                scored.append((pane, 50))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { item in
            SearchItem(
                id: "settings:\(item.pane.url)",
                title: item.pane.name,
                subtitle: "System Settings",
                icon: "gear",
                kind: .systemSettings,
                meta: ["url": item.pane.url]
            )
        }
    }
}
```

**Step 3: Add systemSettingsSearcher to AppState**

Add property:

```swift
let systemSettingsSearcher = SystemSettingsSearcher()
```

Update `performSearch` to include system settings results:

```swift
func performSearch(query: String) -> [SearchItem] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

    let limit = maxSearchResults
    var appResults = appSearcher.search(query, limit: limit)
    var scriptResults = scriptSearcher.search(query, limit: limit)
    let settingsResults = systemSettingsSearcher.search(query, limit: limit)

    let term = query
    appResults.sort { frecency.boost(query: term, itemId: $0.id) > frecency.boost(query: term, itemId: $1.id) }
    scriptResults.sort { frecency.boost(query: term, itemId: $0.id) > frecency.boost(query: term, itemId: $1.id) }

    return Array((appResults + settingsResults + scriptResults).prefix(limit))
}
```

**Step 4: Handle `.systemSettings` in OverlayView**

Add to ALL switch statements in OverlayView:

In `currentActions`:
```swift
case .systemSettings:
    return [
        ItemAction(label: "Open", icon: "gear", shortcut: "\u{23CE}") {
            openSelectedItem()
        },
    ]
```

In `sectionLabel(for:)`:
```swift
case .systemSettings: "System Settings"
```

In `kindLabel(for:)`:
```swift
case .systemSettings: "System Settings"
```

In `openSelectedItem()`:
```swift
case .systemSettings:
    if let urlString = item.meta["url"], let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
```

In `itemIcon(for:)` — the existing else branch handles SF Symbol icons (gear), so no change needed.

**Step 5: Build and verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Format and lint**

Run: `swiftformat Sources/`
Run: `swiftlint lint --baseline .swiftlint.baseline --quiet`
Expected: No new violations

**Step 7: Update decisions.md**

Append entry about system settings search and configurable search paths.

**Step 8: Commit**

```bash
git add Sources/Relux/Search/SystemSettingsSearcher.swift Sources/Relux/Extensions/ExtensionProtocol.swift Sources/Relux/AppState.swift Sources/Relux/UI/OverlayView.swift docs/decisions.md
git commit -m "Add system settings search and configurable index paths"
```
