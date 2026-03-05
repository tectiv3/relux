# Notes Extension & Extension Registry Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename "Models" tab to "Notes", add enable/disable toggle, and introduce an ExtensionRegistry for future extension toggleability.

**Architecture:** Simple registry class (`ExtensionRegistry`) backed by UserDefaults tracks extension enabled state. AppState consults it during search. Notes extension controls MLX model lifecycle on toggle.

**Tech Stack:** Swift, SwiftUI, UserDefaults

---

### Task 1: Create ExtensionRegistry

**Files:**
- Create: `Sources/Relux/Extensions/ExtensionRegistry.swift`

**Step 1: Write ExtensionRegistry class**

```swift
import Foundation

@MainActor
@Observable
final class ExtensionRegistry {
    struct Extension: Identifiable, Sendable {
        let id: String
        let name: String
        let icon: String
        var isEnabled: Bool
    }

    private(set) var extensions: [Extension]

    init() {
        extensions = [
            Extension(
                id: "notes",
                name: "Notes",
                icon: "note.text",
                isEnabled: UserDefaults.standard.object(forKey: "extension.notes.enabled") as? Bool ?? true
            ),
        ]
    }

    func isEnabled(_ id: String) -> Bool {
        extensions.first { $0.id == id }?.isEnabled ?? false
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[index].isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "extension.\(id).enabled")
    }
}
```

**Step 2: Commit**

```bash
git add Sources/Relux/Extensions/ExtensionRegistry.swift
git commit -m "feat: add ExtensionRegistry for extension enable/disable tracking"
```

---

### Task 2: Wire ExtensionRegistry into AppState

**Files:**
- Modify: `Sources/Relux/AppState.swift`

**Step 1: Add registry property to AppState**

Add after `let frecency = FrecencyTracker()` (line 21):

```swift
let extensionRegistry = ExtensionRegistry()
```

**Step 2: Guard performSearch with registry check**

In `performSearch(query:)`, change:

```swift
var noteResults = queryEngine?.searchOnly(query, topK: limit) ?? []
```

to:

```swift
var noteResults: [SearchItem] = []
if extensionRegistry.isEnabled("notes") {
    noteResults = queryEngine?.searchOnly(query, topK: limit) ?? []
}
```

**Step 3: Guard restoreModels with registry check**

Wrap the body of `restoreModels()` in:

```swift
guard extensionRegistry.isEnabled("notes") else { return }
```

**Step 4: Add method to toggle notes extension**

Add a new method:

```swift
func setNotesEnabled(_ enabled: Bool) {
    extensionRegistry.setEnabled("notes", enabled: enabled)
    if enabled {
        restoreModels()
    } else {
        mlx.unloadAll()
    }
}
```

**Step 5: Commit**

```bash
git add Sources/Relux/AppState.swift
git commit -m "feat: wire ExtensionRegistry into AppState search and model lifecycle"
```

---

### Task 3: Make MLXService.unloadModels public and add unloadAll

**Files:**
- Modify: `Sources/Relux/MLX/MLXService.swift`

**Step 1: Add public unloadAll method**

The existing `unloadModels()` is private (used by idle timer). Add a public method that also clears model references:

```swift
func unloadAll() {
    idleTask?.cancel()
    llmContainer = nil
    embedContainer = nil
    llmModel = nil
    embedderModel = nil
    isLLMLoaded = false
    isEmbedderLoaded = false
    loadingStatus = ""
    MLX.GPU.clearCache()
}
```

This differs from the private `unloadModels()` because it also clears `llmModel`/`embedderModel` references (preventing lazy reload) and cancels the idle timer.

**Step 2: Commit**

```bash
git add Sources/Relux/MLX/MLXService.swift
git commit -m "feat: add MLXService.unloadAll for complete model teardown"
```

---

### Task 4: Rename Models tab to Notes and add enable toggle

**Files:**
- Modify: `Sources/Relux/UI/SettingsView.swift`

**Step 1: Rename tab in body**

Change:

```swift
modelsTab.tabItem { Label("Models", systemImage: "cpu") }
```

to:

```swift
notesTab.tabItem { Label("Notes", systemImage: "note.text") }
```

**Step 2: Rename modelsTab property to notesTab and add toggle**

Rename the `modelsTab` computed property to `notesTab`. Add an enable/disable toggle at the top of the form, and wrap the model config sections in a conditional:

```swift
private var notesTab: some View {
    Form {
        Section {
            Toggle("Enable Notes", isOn: Binding(
                get: { appState.extensionRegistry.isEnabled("notes") },
                set: { appState.setNotesEnabled($0) }
            ))
        }

        if appState.extensionRegistry.isEnabled("notes") {
            Section("LLM Model") {
                // ... existing LLM picker (unchanged)
            }

            Section("Embedder Model") {
                // ... existing Embedder picker (unchanged)
            }

            Section("Indexing") {
                // ... existing indexing UI (unchanged)
            }
        }
    }
    .formStyle(.grouped)
    .padding()
}
```

**Step 3: Update onAppear**

Wrap the model discovery in `body`'s `.onAppear` with a guard:

```swift
if appState.extensionRegistry.isEnabled("notes") {
    discoveredModels = ModelDiscovery.discoverModels()
    // ... existing model matching
}
```

**Step 4: Commit**

```bash
git add Sources/Relux/UI/SettingsView.swift
git commit -m "feat: rename Models tab to Notes with enable/disable toggle"
```

---

### Task 5: Update isReady to respect notes disabled state

**Files:**
- Modify: `Sources/Relux/AppState.swift`

**Step 1: Fix isReady**

Current `isReady` requires `mlx.hasLLMModel && store != nil`. When notes are disabled, this would be false (no LLM loaded), which may block other functionality. Change to:

```swift
var isReady: Bool {
    if extensionRegistry.isEnabled("notes") {
        return mlx.hasLLMModel && store != nil
    }
    return store != nil
}
```

Or if `isReady` only gates notes functionality, consider whether it's still needed at all. Check call sites.

**Step 2: Commit**

```bash
git add Sources/Relux/AppState.swift
git commit -m "fix: isReady accounts for notes being disabled"
```

---

### Task 6: Format and build verification

**Step 1: Format**

```bash
swiftformat Sources/
```

**Step 2: Build**

```bash
xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build
```

**Step 3: Fix any compilation errors**

**Step 4: Final commit if needed**

```bash
git add -A
git commit -m "chore: format and fix build issues"
```

---

### Task 7: Update decisions.md

**Files:**
- Modify: `docs/decisions.md`

Add entry documenting:
- Models tab renamed to Notes (models are implementation detail of notes)
- ExtensionRegistry introduced for extension enable/disable
- Notes disable unloads all MLX models from memory
- Pattern available for scripts/clipboard/apps to adopt later
