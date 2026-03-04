# Notty

Local-first Apple Notes assistant powered by MLX on Apple Silicon. Ask questions about your notes, get answers with sources — all on-device.

## Requirements

- macOS 14+
- Apple Silicon
- Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Local MLX models (GGUF format) in `~/.swama/models/`, `~/.cache/huggingface/hub/`, or `~/Library/Application Support/Notty/models/`

## Build & Run

```
xcodegen generate
open Notty.xcodeproj
```

Build and run from Xcode (⌘R).

## Usage

- **⌥+Space** opens the search overlay
- Type a question about your notes and press Enter
- Answers stream in with source note references
- **Esc** or click outside to dismiss

On first launch, Settings opens automatically — select an LLM and embedding model from your local models, then hit Re-index.

## Architecture

```
Shell (menu bar, hotkey, overlay)
  → ExtensionProtocol
    → NotesExtension
      → NoteExtractor (AppleScript → Notes.app)
      → VectorStore (SQLite + BLAS cosine similarity)
      → QueryEngine (RAG: embed → retrieve → generate)
  → MLXService (mlx-swift embeddings + LLM)
```

Designed with a generic extension protocol so the overlay can later serve as a full launcher.
