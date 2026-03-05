# Notes Extension & Extension Registry

## Summary

Rename the "Models" settings tab to "Notes" and make it a disableable extension. Introduce an `ExtensionRegistry` as a simple lookup table so other search sources (scripts, apps) can adopt the same enable/disable pattern later.

## Motivation

Models (LLM, embedder) exist solely to serve note search. Exposing them under a "Models" tab obscures this relationship. Reframing as "Notes" clarifies intent and lets users disable the entire feature — including model loading — when they don't need it.

## Design

### ExtensionRegistry

Simple `ObservableObject` class. Each entry has an id, display name, icon, and enabled state. Enabled state persisted to UserDefaults (key pattern: `extension.<id>.enabled`).

```swift
class ExtensionRegistry: ObservableObject {
    struct Extension: Identifiable {
        let id: String      // "notes", "scripts", "apps"
        let name: String
        let icon: String
        var isEnabled: Bool
    }
    @Published var extensions: [Extension]
}
```

No protocol. Searchers remain concrete classes. The registry is a lookup table consulted by AppState during search.

### Settings Tab Rename

- "Models" tab → "Notes" tab (icon: "note.text" or similar)
- Toggle at top: "Enable Notes" — controls `ExtensionRegistry` entry for "notes"
- Existing model selection UI (LLM picker, embedder picker, re-index) remains below the toggle
- When disabled, model selection UI is dimmed/hidden

### Search Integration

`AppState.performSearch()` checks `extensionRegistry.isEnabled("notes")` before calling QueryEngine. Disabled = skipped entirely.

### Model Lifecycle

- **Disable notes:** Unload LLM and embedder from MLXService, free GPU/memory
- **Enable notes:** Load models (same as app startup flow)
- **App startup:** If notes disabled, skip model loading entirely

### Future Extensions

Scripts, clipboard, and apps can register in the same registry. Each gets an enable/disable toggle in their respective settings tab. No protocol needed — just check the registry before calling the searcher.
