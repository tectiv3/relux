# Instant App Detection Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect newly installed apps instantly via FSEvents and surface them with a score boost and "NEW" badge in search results.

**Architecture:** Add DispatchSource filesystem watchers to AppSearcher for `/Applications` and `~/Applications`. New apps found by FSEvents before Spotlight indexes them are tracked in a `newlyDetected` set, which drains as Spotlight catches up. SearchItem gains an `isNew` flag that drives a UI badge.

**Tech Stack:** Swift 6, DispatchSource, NSMetadataQuery (existing), SwiftUI

**Spec:** `docs/superpowers/specs/2026-03-10-instant-app-detection-design.md`

---

## File Structure

- **Modify:** `Sources/Relux/Extensions/ExtensionProtocol.swift` — add `isNew` to SearchItem
- **Modify:** `Sources/Relux/Search/AppSearcher.swift` — add FSEvents watchers, `newlyDetected` set, score boost, `isNew` flag on results
- **Modify:** `Sources/Relux/UI/OverlayView.swift` — render "NEW" badge in `resultRow`

---

## Chunk 1: Data Model + FSEvents + UI

### Task 1: Add `isNew` flag to SearchItem

**Files:**
- Modify: `Sources/Relux/Extensions/ExtensionProtocol.swift:13-20`

- [ ] **Step 1: Add `isNew` property to SearchItem**

```swift
struct SearchItem: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let kind: SearchItemKind
    let meta: [String: String]
    var isNew: Bool = false
}
```

- [ ] **Step 2: Build to verify no compile errors**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```
git add Sources/Relux/Extensions/ExtensionProtocol.swift
git commit -m "Add isNew flag to SearchItem for new app detection"
```

---

### Task 2: Add DispatchSource watchers and newlyDetected tracking to AppSearcher

**Files:**
- Modify: `Sources/Relux/Search/AppSearcher.swift`

- [ ] **Step 1: Add newlyDetected state and watcher sources**

Add after `private var query: NSMetadataQuery?` (line 21):

```swift
private var newlyDetected: Set<String> = []
private var watchSources: [DispatchSourceFileSystemObject] = []
```

- [ ] **Step 2: Add directory watcher setup method**

Add after `restartSpotlightQuery()` (after line 41):

```swift
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

    let knownPaths = Set(apps.map { $0.path.path })
    for url in contents where url.pathExtension == "app" {
        let path = url.path
        guard !knownPaths.contains(path) else { continue }

        let name = url.deletingPathExtension().lastPathComponent
        apps.append(AppItem(name: name, path: url))
        newlyDetected.insert(path)
    }
}
```

- [ ] **Step 3: Clear newlyDetected in restartSpotlightQuery**

In `restartSpotlightQuery()`, add `newlyDetected.removeAll()` after `apps = []`:

```swift
private func restartSpotlightQuery() {
    query?.stop()
    query = nil
    apps = []
    newlyDetected.removeAll()
    startSpotlightQuery()
}
```

- [ ] **Step 4: Start watchers in init**

Change `init()` (line 30-34) to:

```swift
init() {
    searchPaths = UserDefaults.standard.stringArray(forKey: "appSearchPaths")
        ?? Self.defaultSearchPaths
    startSpotlightQuery()
    startDirectoryWatchers()
}
```

- [ ] **Step 5: Merge FSEvents apps into Spotlight results and drain newlyDetected**

Replace the end of `handleQueryResults()` — from `mdQuery.enableUpdates()` through the `apps = ...` assignment (lines 90-93) — with:

```swift
mdQuery.enableUpdates()

// Drain: any app now in Spotlight is no longer "newly detected"
let spotlightPaths = Set(found.values.map { $0.path.path })
newlyDetected.subtract(spotlightPaths)

// Merge: preserve FSEvents-detected apps that Spotlight hasn't indexed yet
for path in newlyDetected {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    if found[name] == nil {
        found[name] = AppItem(name: name, path: url)
    }
}

apps = Array(found.values).sorted {
    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
}
```

This fixes the critical bug: without the merge, `apps = Array(found.values)...` would overwrite any FSEvents-detected apps that Spotlight hasn't indexed yet.

- [ ] **Step 6: Add score boost and isNew flag in search()**

Replace the `return scored.prefix(limit).map` block (lines 115-124) with:

```swift
return scored.prefix(limit).map { item in
    SearchItem(
        id: "app:\(item.app.path.path)",
        title: item.app.name,
        subtitle: item.app.path.deletingLastPathComponent().path,
        icon: "app.dashed",
        kind: .app,
        meta: ["path": item.app.path.path],
        isNew: newlyDetected.contains(item.app.path.path)
    )
}
```

And in the scoring loop (lines 100-112), change each `scored.append` to add the boost:

```swift
var scored: [(app: AppItem, score: Int)] = []
let boost = 20
for app in apps {
    let name = app.name.lowercased()
    let isNew = newlyDetected.contains(app.path.path)
    let b = isNew ? boost : 0
    if name == q {
        scored.append((app, 100 + b))
    } else if name.hasPrefix(q) {
        scored.append((app, 80 + b))
    } else if name.contains(q) {
        scored.append((app, 60 + b))
    } else if fuzzyMatch(query: q, target: name) {
        scored.append((app, 40 + b))
    }
}
```

- [ ] **Step 7: Build to verify no compile errors**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```
git add Sources/Relux/Search/AppSearcher.swift
git commit -m "Add FSEvents watchers for instant app detection with score boost"
```

---

### Task 3: Render "NEW" badge in search result row

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift:428-456`

- [ ] **Step 1: Add NEW badge to resultRow**

In `resultRow` (line 428), insert after the `Text(item.title)` block (after line 434):

```swift
if item.isNew {
    Text("NEW")
        .font(.system(size: 9, weight: .bold))
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule().fill(Color.blue)
        )
}
```

- [ ] **Step 2: Build to verify no compile errors**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual test**

1. Run the app
2. Drop a new `.app` bundle into `/Applications`
3. Open Relux overlay, type part of the app name
4. Verify: app appears immediately with "NEW" badge
5. Wait ~30s for Spotlight to index
6. Search again — badge should be gone

- [ ] **Step 4: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "Add NEW badge for recently detected apps in search results"
```
