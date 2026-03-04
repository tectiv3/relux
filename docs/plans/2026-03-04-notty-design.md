# Notty — Local Apple Notes RAG Assistant

## Overview

Pure Swift menu bar app for macOS. Indexes Apple Notes locally, provides a spotlight-style overlay (global hotkey) where users type natural language queries and get streaming AI-powered answers with source note references. All processing on-device via MLX on Apple Silicon.

Designed with a generic shell + extension protocol so the overlay can later become a full launcher (Raycast replacement — see future-launcher notes).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Notty.app                         │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Shell (reusable)                    │ │
│  │  Menu Bar  ·  Global Hotkey  ·  Overlay Panel   │ │
│  │  Settings  ·  Extension Router                  │ │
│  └──────────────────┬──────────────────────────────┘ │
│                     │                                │
│          ┌──────────┴──────────┐                     │
│          │  ExtensionProtocol  │                     │
│          │  handle(query:) →   │                     │
│          │  AsyncStream<Result>│                     │
│          └──────────┬──────────┘                     │
│                     │                                │
│  ┌──────────────────┴──────────────────────────────┐ │
│  │         NotesExtension (v1 — the only one)      │ │
│  │                                                  │ │
│  │  NoteExtractor ──→ VectorStore ──→ QueryEngine  │ │
│  │  (AppleScript)     (SQLite)       (RAG pipeline)│ │
│  └──────────────────────────────────────────────────┘ │
│                                                      │
│  ┌──────────────────────────────────────────────────┐ │
│  │              MLXService (shared)                 │ │
│  │  Embedding model  ·  LLM  ·  Model management   │ │
│  └──────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

## Core Modules

### 1. Shell (UI Layer)

- **Menu bar icon:** NSStatusItem, shows index stats and settings access
- **Global hotkey:** Configurable, default `⌥+Space`. Opens floating overlay panel.
- **Overlay panel:** SwiftUI. Text field at top, streaming answer below, source notes at bottom. Dismisses on Esc or click outside.
- **Extension router:** Dispatches queries to the active extension (v1: only NotesExtension)
- **Settings window:** Model picker, hotkey config, re-index button, index stats

### 2. ExtensionProtocol

```swift
protocol NottyExtension {
    var name: String { get }
    func handle(query: String) -> AsyncStream<ExtensionResult>
}

struct ExtensionResult {
    let token: String?          // streamed LLM token
    let sources: [NoteSource]?  // populated once retrieval completes
    let done: Bool
}
```

Thin boundary between shell and logic. Future extensions (app launcher, clipboard, translation) conform to this same protocol.

### 3. Note Extractor

- `NSAppleScript` calls to Notes.app — enumerates accounts → folders → notes
- Returns `NoteRecord { id, title, htmlBody, folder, account, modifiedDate }`
- HTML → plain text via `NSAttributedString(html:)` (Foundation)
- Password-protected notes handled transparently (Notes.app manages auth)
- Idempotent: compares `modifiedDate` against stored value, skips unchanged notes
- Launches Notes.app silently via `NSWorkspace` if not running

### 4. MLX Service

- Wraps `mlx-swift` for embedding + LLM generation
- **Embedding:** Loads GGUF embedding model (e.g. `bge-small-en-v1.5`, 384 dims). Fallback: `NaturalLanguage.framework` built-in embeddings if no embedding model configured.
- **LLM:** Loads user-selected model. Configurable at runtime.
- **Model discovery:** Scans known local directories for existing MLX models:
  - `~/.swama/models/`
  - `~/.cache/huggingface/hub/`
  - `~/Library/Application Support/Notty/models/`
- **API:**
  - `func embed(_ texts: [String]) -> [[Float]]`
  - `func generate(prompt:) -> AsyncStream<String>`
- Model loaded lazily, stays in memory while app runs

### 5. Vector Store

- SQLite file at `~/Library/Application Support/Notty/notty.db`
- **Schema:**
  ```sql
  CREATE TABLE chunks (
      note_id TEXT,
      chunk_index INTEGER,
      chunk_text TEXT,
      embedding BLOB,
      title TEXT,
      folder TEXT,
      modified_date REAL,
      PRIMARY KEY (note_id, chunk_index)
  );

  CREATE TABLE meta (
      key TEXT PRIMARY KEY,
      value TEXT
  );
  -- meta stores: embedding_model_id, last_index_date, embedding_dimensions
  ```
- Embeddings stored as raw float blobs
- On launch: load all embeddings into contiguous `[Float]` array (~7.5MB for 5K chunks)
- Search: cosine similarity via Accelerate/BLAS, return top-K chunks grouped by note_id

### 6. Query Engine

Orchestrates the RAG pipeline:

1. `MLXService.embed(query)` → query vector
2. `VectorStore.search(queryVector, topK: 5)` → ranked chunks + metadata
3. Build prompt: system instructions + retrieved chunks (with note titles) + user query
4. `MLXService.generate(prompt)` → stream tokens to UI
5. Return source note titles/folders alongside answer

## Data Flow

### Indexing (on launch + manual)

```
Notes.app
  → NSAppleScript: enumerate all notes
  → For each note: extract (id, title, body_html, folder, modified_date)
  → Skip if modified_date unchanged from stored value
  → Strip HTML → plain text
  → Chunk text (~500 tokens per chunk, ~50 token overlap, split at paragraph boundaries)
  → MLXService.embed(chunks) → [Float] vectors
  → Upsert into SQLite
```

### Querying

```
User hits hotkey → overlay appears → types query → presses Enter
  1. MLXService.embed(query) → query vector
  2. VectorStore.search(queryVector, topK: 5) → ranked chunks
  3. Build prompt with retrieved context
  4. MLXService.generate(prompt) → AsyncStream<String>
  5. Stream tokens into overlay + show source note titles below
  → Dismiss with Esc or click outside
```

## Error Handling

- **Notes.app not running:** Launch silently via NSWorkspace before AppleScript calls
- **No notes found:** Show "No notes indexed" in overlay
- **No model selected:** First launch opens settings window. Query disabled until model configured.
- **Embedding model changed:** Invalidate all stored embeddings, warn user, re-index
- **Large notes:** Just produce more chunks, no special handling
- **AppleScript auth for locked notes:** System handles it. If cancelled, skip that note.
- **Model too large for RAM:** Show mlx-swift error as-is. User's responsibility.

## Scope — v1

**In scope:**
- Text-only note indexing (no attachments/images)
- Spotlight-style overlay with streaming answers + source notes
- Configurable model selection from local models
- On-launch + manual re-indexing
- Global hotkey

**Out of scope (future):**
- Image/attachment processing
- Background polling for note changes
- Writing/editing notes from the app
- Launcher/app search extensions (see future-launcher.md)

## Dependencies

- `mlx-swift` — MLX framework for Apple Silicon
- `mlx-swift-examples` (or relevant sub-package) — model loading utilities
- SQLite via Foundation (`sqlite3` C API or Swift wrapper)
- No external vector DB, no Python, no Node
