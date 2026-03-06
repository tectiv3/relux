# Relux

Local-first macOS utility (Command Bar / Clipboard History / Translator).

## Screenshots

<table>
  <tr>
    <td><img src="docs/screenshots/main.png" alt="Search overlay (dark)" width="400"></td>
    <td><img src="docs/screenshots/main_white.png" alt="Search overlay (light)" width="400"></td>
  </tr>
  <tr>
    <td align="center"><em>Search overlay — dark</em></td>
    <td align="center"><em>Search overlay — light</em></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/clipboard_history.png" alt="Clipboard history" width="400"></td>
    <td><img src="docs/screenshots/settings.png" alt="Settings" width="400"></td>
  </tr>
  <tr>
    <td align="center"><em>Clipboard history</em></td>
    <td align="center"><em>Settings</em></td>
  </tr>
</table>

## Requirements

- macOS 14+
- Apple Silicon
- Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & Run

```
xcodegen generate
open Relux.xcodeproj
```

Build and run from Xcode (⌘R).

## Usage

- **⌥+Space** opens the search overlay
- Type to search apps, scripts, or clipboard history
- **Esc** or click outside to dismiss

On first launch, Settings opens automatically.

## Architecture

```
Shell (menu bar, hotkey, overlay)
  → ExtensionProtocol
    → AppSearcher
    → ScriptSearcher
    → ClipboardStore (SQLite)
    → TranslateStore (SQLite)
```

Designed with a generic extension protocol so the overlay can later serve as a full launcher.
