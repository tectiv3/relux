# Relux

Local-first macOS utility (Command Bar / Clipboard History / Translator).

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
