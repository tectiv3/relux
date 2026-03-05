# Tabs & Extensions Architecture

## Tab System
- Tabs only exist in **SettingsView.swift** (SwiftUI `TabView` with `.tabItem`)
- 4 fixed tabs: General, Models, Scripts, Clipboard
- Main search panel (OverlayView) has NO tabs — results grouped by `SearchItemKind` sections

## Extension Architecture (as of 2026-03-05)
- **No real extension system exists yet**
- `ExtensionProtocol.swift` contains only data types (`SearchItem`, `ExtensionResult`), not an actual plugin protocol
- All search sources are **hardcoded** in AppState.performSearch()
- `SearchItemKind` enum: `.note`, `.app`, `.webSearch`, `.script`

## Search Sources (Hardcoded)
1. **AppSearcher** — Spotlight-based app discovery
2. **ScriptSearcher** — User-defined shell scripts
3. **QueryEngine** — Apple Notes keyword search + AI generation
4. **Web Search** — Minimal, in enum but barely implemented

## Enable/Disable Patterns Already in Codebase
- Clipboard: `clipboardEnabled` UserDefaults toggle
- Scripts: per-script `acceptsSelection`/`capturesOutput` toggles
- EnvVars: `enabled: Bool` field per variable
- Panel modes: `PanelMode` enum (`.search` vs `.clipboard`)

## Models Tab (Settings > Models)
- Located in SettingsView.swift lines 110-178
- LLM picker, Embedder picker, Re-index button
- Uses `ModelDiscovery.discoverModels()` on tab appear
- Persists selection to UserDefaults (`selectedLLMPath`, `selectedEmbedderPath`)

## Key Files
| File | Role |
|------|------|
| `Sources/Relux/UI/SettingsView.swift` | Settings window, all 4 tabs |
| `Sources/Relux/UI/OverlayView.swift` | Main search panel |
| `Sources/Relux/AppState.swift` | Combined search orchestration |
| `Sources/Relux/Extensions/ExtensionProtocol.swift` | SearchItem/ExtensionResult types |
| `Sources/Relux/Engine/QueryEngine.swift` | Note search & AI |
| `Sources/Relux/MLX/MLXService.swift` | Model loading/inference |
