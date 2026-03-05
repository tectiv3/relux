# Selection Capture Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Capture selected text from any app via Accessibility API and pass it to scripts (stdin), web search (query), and Ask AI (context).

**Architecture:** A `SelectionCapture` utility reads `kAXSelectedTextAttribute` from the focused app before Relux takes focus. The result is stored in `AppState.currentSelection` and consumed by existing action handlers. Scripts opt in via a per-script `acceptsSelection` toggle.

**Tech Stack:** Swift, AppKit (AXUIElement), SwiftUI

---

### Task 1: Create SelectionCapture utility

**Files:**
- Create: `Sources/Relux/SelectionCapture.swift`

**Step 1: Create the file**

```swift
import AppKit

enum SelectionCapture {
    /// Reads the selected text from the currently focused app.
    /// Must be called BEFORE Relux's panel takes focus.
    static func captureSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        var selectedText: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success else {
            return nil
        }

        let text = selectedText as? String
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// Prompts for Accessibility permission if not already granted.
    static func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
```

**Step 2: Commit**

```
git add Sources/Relux/SelectionCapture.swift
git commit -m "feat: add SelectionCapture utility for reading selected text via Accessibility API"
```

---

### Task 2: Add currentSelection to AppState and wire up capture in AppDelegate

**Files:**
- Modify: `Sources/Relux/AppState.swift` (add property around line 22)
- Modify: `Sources/Relux/AppDelegate.swift` (modify `togglePanel()` and `applicationDidFinishLaunching`)

**Step 1: Add property to AppState**

Add after line 22 (`var isIndexing = false`):

```swift
    var currentSelection: String?
```

**Step 2: Modify AppDelegate.togglePanel()**

In `togglePanel()`, capture selection before showing the panel. Replace the `else` branch (lines 77-80):

```swift
        } else {
            appState.currentSelection = SelectionCapture.captureSelectedText()
            applyForcedInputSource()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
```

In the close branch, clear selection. Add after line 74 (`UserDefaults.standard.set(frame.origin.y, forKey: "panelY")`):

```swift
            appState.currentSelection = nil
```

**Step 3: Request Accessibility permission on launch**

In `applicationDidFinishLaunching`, add before the `setupPanel()` call (around line 22):

```swift
        SelectionCapture.ensureAccessibilityPermission()
```

**Step 4: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 5: Commit**

```
git add Sources/Relux/AppState.swift Sources/Relux/AppDelegate.swift
git commit -m "feat: capture selected text on panel open, store in AppState"
```

---

### Task 3: Add acceptsSelection to ScriptItem and update ScriptSearcher

**Files:**
- Modify: `Sources/Relux/Search/ScriptSearcher.swift`

**Step 1: Add field to ScriptItem**

Add after `var command: String` (line 7):

```swift
    var acceptsSelection: Bool
```

Update the `init` to include the new field with default `false`:

```swift
    init(title: String, command: String, acceptsSelection: Bool = false) {
        id = UUID().uuidString
        self.title = title
        self.command = command
        self.acceptsSelection = acceptsSelection
    }
```

**Step 2: Update ScriptSearcher.add()**

Change the `add` method signature (line 48):

```swift
    func add(title: String, command: String, acceptsSelection: Bool = false) {
        scripts.append(ScriptItem(title: title, command: command, acceptsSelection: acceptsSelection))
        save()
    }
```

**Step 3: Pass acceptsSelection through search results meta**

In the `search` method, add `acceptsSelection` to the meta dict (around line 119):

```swift
            SearchItem(
                id: "script:\(item.script.id)",
                title: item.script.title,
                subtitle: item.script.command,
                icon: "terminal",
                kind: .script,
                meta: [
                    "command": item.script.command,
                    "acceptsSelection": item.script.acceptsSelection ? "1" : "0",
                ]
            )
```

**Step 4: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 5: Commit**

```
git add Sources/Relux/Search/ScriptSearcher.swift
git commit -m "feat: add acceptsSelection field to ScriptItem"
```

---

### Task 4: Add stdin support to ScriptRunner

**Files:**
- Modify: `Sources/Relux/Search/ScriptRunner.swift`

**Step 1: Add stdin parameter to run()**

Change the method signature (line 10) and add stdin piping:

```swift
    static func run(_ command: String, env: [String: String], stdin: String? = nil) {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            if let stdin {
                let inputPipe = Pipe()
                process.standardInput = inputPipe
                inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            }

            try? process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            await MainActor.run {
                if !output.isEmpty {
                    showToast(output)
                }
            }
        }
    }
```

**Step 2: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 3: Commit**

```
git add Sources/Relux/Search/ScriptRunner.swift
git commit -m "feat: add stdin parameter to ScriptRunner.run()"
```

---

### Task 5: Wire up selection to script execution in OverlayView

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Update the .script case in openSelectedItem()**

Replace the `.script` case (lines 468-472):

```swift
        case .script:
            if let command = item.meta["command"] {
                NSApp.keyWindow?.close()
                let stdin = item.meta["acceptsSelection"] == "1" ? appState.currentSelection : nil
                ScriptRunner.run(command, env: appState.scriptSearcher.buildEnvironment(), stdin: stdin)
            }
```

**Step 2: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 3: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "feat: pass selection as stdin when running scripts that accept it"
```

---

### Task 6: Wire up selection to Ask AI

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Update askAIAboutSelected()**

Modify the `engine.query()` call (around line 488) to include selection context:

```swift
    private func askAIAboutSelected() {
        guard selectedIndex < results.count else { return }
        showActions = false
        isGenerating = true
        rawAnswer = ""

        Task { @MainActor in
            guard let engine = appState.queryEngine else {
                rawAnswer = "Not ready — please select a model in Settings."
                isGenerating = false
                return
            }

            var aiQuery = query
            if let selection = appState.currentSelection {
                aiQuery = "Context:\n\(selection)\n\nQuestion: \(query)"
            }

            for await result in engine.query(aiQuery) {
                switch result.kind {
                case let .token(text):
                    rawAnswer += text
                case .sources:
                    break
                case let .error(msg):
                    rawAnswer += "\n[Error: \(msg)]"
                case .done:
                    break
                }
            }
            isGenerating = false
        }
    }
```

**Step 2: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 3: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "feat: prepend selection as context when asking AI"
```

---

### Task 7: Wire up selection to web search

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Update performSearch() to use selection as web search query**

In `performSearch()` (line 413), when query is empty but selection exists, add a web search result for the selection:

```swift
    private func performSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = appState.recentItems()
            if let selection = appState.currentSelection {
                let preview = String(selection.prefix(80))
                results.append(SearchItem(
                    id: "web-search-selection",
                    title: "Search DuckDuckGo",
                    subtitle: preview,
                    icon: "magnifyingglass",
                    kind: .webSearch,
                    meta: ["query": selection]
                ))
            }
        } else {
            results = appState.performSearch(query: trimmed)
            results.append(SearchItem(
                id: "web-search-ddg",
                title: "Search DuckDuckGo",
                subtitle: trimmed,
                icon: "magnifyingglass",
                kind: .webSearch,
                meta: ["query": trimmed]
            ))
        }
        selectedIndex = 0
        showActions = false
    }
```

**Step 2: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 3: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "feat: show web search for selection when query is empty"
```

---

### Task 8: Add selection indicator to bottom bar

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Update bottomBar**

Add a selection indicator to the bottom bar, showing before the Spacer:

```swift
    private var bottomBar: some View {
        HStack(spacing: 16) {
            if showActions {
                keyboardHint(key: "\u{23CE}", label: "Select")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Back")
            } else {
                keyboardHint(key: "\u{23CE}", label: "Open")
                keyboardHint(key: "\u{2318}K", label: "Actions")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Close")
            }
            Spacer()
            if let selection = appState.currentSelection {
                HStack(spacing: 4) {
                    Image(systemName: "text.cursor")
                    Text(String(selection.prefix(30)))
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
                .opacity(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }
```

**Step 2: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 3: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "feat: show selection indicator in bottom bar"
```

---

### Task 9: Add acceptsSelection toggle to Settings scripts tab

**Files:**
- Modify: `Sources/Relux/UI/SettingsView.swift`

**Step 1: Add toggle to script rows**

Update the script row in `scriptsTab` (around line 199-216). Replace the ForEach block:

```swift
                    ForEach(appState.scriptSearcher.scripts) { script in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(script.title).font(.system(size: 13, weight: .medium))
                                Text(script.command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("stdin", isOn: Binding(
                                get: { script.acceptsSelection },
                                set: { newValue in
                                    var updated = script
                                    updated.acceptsSelection = newValue
                                    appState.scriptSearcher.update(updated)
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .help("Pass selected text as stdin")
                            Button(role: .destructive) {
                                appState.scriptSearcher.remove(id: script.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
```

**Step 2: Format and build**

```
swiftformat Sources/
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 3: Commit**

```
git add Sources/Relux/UI/SettingsView.swift
git commit -m "feat: add 'stdin' toggle per script in Settings"
```

---

### Task 10: Update decisions.md

**Files:**
- Modify: `docs/decisions.md`

**Step 1: Add selection capture decision**

Append to the end of `docs/decisions.md`:

```markdown

## Selection Capture

- On hotkey press, selected text is read from the focused app via Accessibility API (`AXUIElement`) BEFORE Relux takes focus
- Stored in `AppState.currentSelection`, cleared on panel close
- Scripts opt in via `acceptsSelection: Bool` — selection is piped as stdin
- Web search uses selection as query when search bar is empty
- Ask AI prepends selection as context to the LLM prompt
- Bottom bar shows truncated selection preview when captured
- Requires Accessibility permission (prompted on first launch)
```

**Step 2: Commit**

```
git add docs/decisions.md
git commit -m "docs: add selection capture decisions"
```
