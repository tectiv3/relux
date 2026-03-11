# Unified Search Scoring Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed-concatenation + view-layer-hacks ranking system with a single score-based sort so results rank by relevance across all categories.

**Architecture:** Add `score: Double` to `SearchItem`. Each searcher populates it using a global scoring contract. Synthetic items (calculator, JWT, translate, web search) get scores too. `AppState.performSearch` merges all results, applies frecency additively, sorts by score, and returns. All 6 positional manipulations in `OverlayView` are deleted.

**Tech Stack:** Swift 6, SwiftUI

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Sources/Relux/Extensions/ExtensionProtocol.swift` | Modify | Add `score: Double` to `SearchItem` |
| `Sources/Relux/Search/AppSearcher.swift` | Modify | Produce global-scale scores |
| `Sources/Relux/Search/ScriptSearcher.swift` | Modify | Produce global-scale scores |
| `Sources/Relux/Search/SystemSettingsSearcher.swift` | Modify | Produce global-scale scores |
| `Sources/Relux/Search/FrecencyTracker.swift` | Modify | Apply boost to settings too (no code change needed — caller will apply to all items) |
| `Sources/Relux/AppState.swift` | Modify | Unified merge: all sources + synthetic items + frecency + sort |
| `Sources/Relux/UI/OverlayView.swift` | Modify | Delete all 6 ranking manipulations from `performSearch`, move synthetic item creation to `AppState` |

## Global Scoring Contract

All searchers produce scores on a shared scale. Frecency is applied additively by the caller.

| Category | Match Type | Base Score | Notes |
|---|---|---|---|
| **Calculator** | Expression evaluates | 1050 | Unambiguous intent |
| **JWT Decoder** | Keyword "jwt" | 1000 | Explicit request |
| **Apps** | Exact name | 950 | Primary use case |
| **Scripts** | Exact name | 930 | Close to apps |
| **JWT Decoder** | Content looks like JWT | 900 | High confidence heuristic |
| **Settings** | Exact name | 850 | |
| **Translate** | With selection | 800 | Useful but shouldn't bury exact matches |
| **Apps** | Prefix | 800 | |
| **Scripts** | Prefix | 780 | |
| **Settings** | Prefix name | 750 | |
| **Scripts** | Input filter (specific) | 700 | Strong signal |
| **Settings** | Keyword prefix | 700 | |
| **Apps** | Contains | 600 | |
| **Scripts** | Contains | 580 | |
| **Settings** | Name contains | 550 | |
| **Web Search** | URL detected | 500 | |
| **Settings** | Keyword contains | 450 | |
| **Apps** | Fuzzy | 350 | Low confidence |
| **Scripts** | Fuzzy | 330 | |
| **Web Search** | Fallback | 200 | Always near bottom |
| **Scripts** | Input filter (.any) | 100 | Weak signal |

**Frecency:** additive, applied to ALL item kinds (apps, scripts, settings, extensions). Range ~0-105 for normal usage — nudges within bands, doesn't break cross-category ordering.

**New app bonus:** +50 (within app band, can't promote fuzzy above another category's exact match).

**Selection-aware script bonus:** +200 added to base score when `currentSelection` exists and script accepts input. Exact-match script (930+200=1130) tops the list. `.any` filter (100+200=300) stays below exact matches from other categories.

---

### Task 1: Add `score` field to `SearchItem`

**Files:**
- Modify: `Sources/Relux/Extensions/ExtensionProtocol.swift:13-21`

- [ ] **Step 1: Add score field**

Add `var score: Double = 0` to `SearchItem`:

```swift
struct SearchItem: Identifiable, Sendable {
    let id: String
    let title: String
    var subtitle: String
    let icon: String
    let kind: SearchItemKind
    var meta: [String: String]
    var isNew: Bool = false
    var score: Double = 0
}
```

- [ ] **Step 2: Update FrecencyTracker.recentItems**

`FrecencyTracker.recentItems()` at line 79 constructs `SearchItem` — no change needed since `score` has a default value. Verify no compile error.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (score defaults to 0 everywhere, no callers break)

- [ ] **Step 4: Commit**

```
git commit -m "Add score field to SearchItem"
```

---

### Task 2: Update AppSearcher to produce global-scale scores

**Files:**
- Modify: `Sources/Relux/Search/AppSearcher.swift:172-205`

- [ ] **Step 1: Replace scoring in `search()` method**

Change the scoring block (lines 176-191) to use global-scale scores and populate the `score` field on `SearchItem`:

```swift
func search(_ query: String, limit: Int = 5) -> [SearchItem] {
    guard !query.isEmpty else { return [] }
    let lowercasedQuery = query.lowercased()

    var scored: [(app: AppItem, score: Double, isNew: Bool)] = []
    for app in apps {
        let name = app.name.lowercased()
        let isNew = newlyDetected.contains(app.path.path)
        let bonus: Double = isNew ? 50 : 0
        if name == lowercasedQuery {
            scored.append((app, 950 + bonus, isNew))
        } else if name.hasPrefix(lowercasedQuery) {
            scored.append((app, 800 + bonus, isNew))
        } else if name.contains(lowercasedQuery) {
            scored.append((app, 600 + bonus, isNew))
        } else if fuzzyMatch(query: lowercasedQuery, target: name) {
            scored.append((app, 350 + bonus, isNew))
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
            isNew: item.isNew,
            score: item.score
        )
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```
git commit -m "Update AppSearcher to global score scale"
```

---

### Task 3: Update ScriptSearcher to produce global-scale scores

**Files:**
- Modify: `Sources/Relux/Search/ScriptSearcher.swift:269-311`

- [ ] **Step 1: Replace scoring in `search()` method**

```swift
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
```

- [ ] **Step 2: Build to verify**

- [ ] **Step 3: Commit**

```
git commit -m "Update ScriptSearcher to global score scale"
```

---

### Task 4: Update SystemSettingsSearcher to produce global-scale scores

**Files:**
- Modify: `Sources/Relux/Search/SystemSettingsSearcher.swift:153-184`

- [ ] **Step 1: Replace scoring in `search()` method**

```swift
func search(_ query: String, limit: Int = 5) -> [SearchItem] {
    guard !query.isEmpty else { return [] }
    let lowercasedQuery = query.lowercased()

    var scored: [(pane: SettingsPane, score: Double)] = []
    for pane in Self.panes {
        let name = pane.name.lowercased()
        if name == lowercasedQuery {
            scored.append((pane, 850))
        } else if name.hasPrefix(lowercasedQuery) {
            scored.append((pane, 750))
        } else if name.contains(lowercasedQuery) {
            scored.append((pane, 550))
        } else if pane.keywords.contains(where: { $0.hasPrefix(lowercasedQuery) }) {
            scored.append((pane, 700))
        } else if pane.keywords.contains(where: { $0.contains(lowercasedQuery) }) {
            scored.append((pane, 450))
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
            meta: ["url": item.pane.url],
            score: item.score
        )
    }
}
```

- [ ] **Step 2: Build to verify**

- [ ] **Step 3: Commit**

```
git commit -m "Update SystemSettingsSearcher to global score scale"
```

---

### Task 5: Move synthetic items + unified merge into AppState

This is the core task. Move calculator/JWT/translate/web-search item creation from `OverlayView` into `AppState.performSearch`, apply frecency to ALL items, sort by score.

**Files:**
- Modify: `Sources/Relux/AppState.swift:76-89`

- [ ] **Step 1: Rewrite `performSearch` with unified scoring**

Replace the current `performSearch` method:

```swift
func performSearch(query: String, stdinValue: String? = nil) -> [SearchItem] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

    let limit = maxSearchResults
    let trimmed = query.trimmingCharacters(in: .whitespaces)

    var all: [SearchItem] = []
    all += appSearcher.search(trimmed, limit: limit)
    all += scriptSearcher.search(trimmed, limit: limit, stdinValue: stdinValue)
    all += systemSettingsSearcher.search(trimmed, limit: limit)
    all += syntheticItems(query: trimmed, selection: stdinValue)

    // Selection-aware script bonus
    if stdinValue != nil {
        for i in all.indices where all[i].kind == .script && all[i].meta["acceptsInput"] == "1" {
            all[i].score += 200
        }
    }

    // Frecency boost applied to ALL items
    let term = trimmed
    for i in all.indices {
        all[i].score += frecency.boost(query: term, itemId: all[i].id)
    }

    all.sort { $0.score > $1.score }
    return Array(all.prefix(limit))
}
```

- [ ] **Step 2: Add `syntheticItems` helper method to AppState**

Add this method after `performSearch`:

```swift
private func syntheticItems(query: String, selection: String?) -> [SearchItem] {
    var items: [SearchItem] = []
    let lower = query.lowercased()

    // Calculator
    if extensionRegistry.isReady("calculator"),
       let calcResult = calculatorService.evaluate(query)
    {
        items.append(SearchItem(
            id: "calculator-result",
            title: calcResult.expression,
            subtitle: calcResult.answer,
            icon: "equal.circle",
            kind: .calculator,
            meta: [
                "expression": calcResult.expression,
                "answer": calcResult.answer,
                "isCurrency": calcResult.isCurrency ? "1" : "0",
                "sourceCurrency": calcResult.sourceCurrency ?? "",
                "targetCurrency": calcResult.targetCurrency ?? "",
                "lastUpdated": calcResult.lastUpdated.map { String($0.timeIntervalSince1970) } ?? "",
            ],
            score: 1050
        ))
    }

    // JWT Decoder
    let isJWTKeyword = lower.contains("jwt")
    let isJWTContent = query.split(separator: ".").count >= 2 && query.count > 20
    let selectionIsJWT = (selection?.split(separator: ".").count ?? 0) >= 2
        && (selection?.count ?? 0) > 20
    if extensionRegistry.isReady("jwt"), isJWTKeyword || isJWTContent || selectionIsJWT {
        items.append(SearchItem(
            id: "jwt-decoder",
            title: "JWT Decoder",
            subtitle: "Decode and inspect JSON Web Token",
            icon: "key.viewfinder",
            kind: .jwt,
            meta: [:],
            score: isJWTKeyword ? 1000 : 900
        ))
    }

    // Translate
    if extensionRegistry.isReady("translate"), let sel = selection {
        let preview = String(sel.prefix(80))
        items.append(SearchItem(
            id: "translate-selection",
            title: "Translate",
            subtitle: preview,
            icon: "character.book.closed",
            kind: .translate,
            meta: [:],
            score: 800
        ))
    }

    // Web Search / URL Open
    let isURL = query.hasPrefix("http://") || query.hasPrefix("https://")
        || query.range(of: #"^[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}"#, options: .regularExpression) != nil
    if isURL {
        items.append(SearchItem(
            id: "web-open-url",
            title: "Open URL",
            subtitle: query,
            icon: "link",
            kind: .webSearch,
            meta: ["url": query],
            score: 500
        ))
    } else {
        items.append(SearchItem(
            id: "web-search-ddg",
            title: "Search DuckDuckGo",
            subtitle: query,
            icon: "magnifyingglass",
            kind: .webSearch,
            meta: ["query": query],
            score: 200
        ))
    }

    return items
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`

- [ ] **Step 4: Commit**

```
git commit -m "Move synthetic items and unified merge into AppState.performSearch"
```

---

### Task 6: Strip ranking logic from OverlayView

Remove all 6 positional manipulations from `OverlayView.performSearch`. The view now trusts the pre-sorted list from `AppState`.

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift:612-770`

- [ ] **Step 1: Simplify the non-empty query branch**

Replace the entire non-empty query branch (lines 670-767) with:

```swift
        } else {
            results = appState.performSearch(query: trimmed, stdinValue: appState.currentSelection)

            // Deduplicate by id, preserving order
            var seen = Set<String>()
            results = results.filter { seen.insert($0.id).inserted }
        }
```

The empty-query path (lines 617-669) stays as-is — it handles recents and selection-aware quick actions, which are a separate concern.

- [ ] **Step 2: Verify `selectionQuickActions()` is unchanged**

This method (lines 784-806) is only used in the empty-query path. No changes needed.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`

- [ ] **Step 4: Smoke test**

Run the app and verify:
- Type "afk" → script "afk" should appear above web search
- Type "2+2" → calculator appears first
- Type "jwt" → JWT decoder appears first
- Type "safari" → Safari app appears first
- With text selected, type a query → selection-aware scripts are boosted but don't unconditionally top the list
- Web search always appears near bottom (unless it's a URL)

- [ ] **Step 5: Commit**

```
git commit -m "Remove ranking hacks from OverlayView, rely on score-based sort"
```

---

### Task 7: Lint and format

- [ ] **Step 1: Format**

Run: `swiftformat Sources/`

- [ ] **Step 2: Lint**

Run: `swiftlint lint --baseline .swiftlint.baseline --quiet`

- [ ] **Step 3: Fix any issues and commit**

```
git commit -m "Fix lint and format after scoring refactor"
```
