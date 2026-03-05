# Notty — Decisions & Request History

Only architectural/behavioral decisions with downstream implications. Not bug fixes or cosmetic tweaks.

## Search Architecture

- `SourceNote` replaced with generic `SearchItem` supporting `.note` and `.app` kinds — all future result types extend this
- Search is instant, as-you-type — keyword matching on VectorStore cache + app name fuzzy matching. No embedding needed for basic search.
- LLM generation is opt-in only, behind Cmd+K → "Ask AI" action. Never auto-triggers.
- App search scans `/Applications`, `~/Applications`, `/System/Applications`, caches at init
- Do NOT use `Bundle(url:)` to read app bundles — triggers App Management permission. Only use `FileManager` + path inspection.

## Frecency System

- Tracks query→item selections (frequency + recency) to rank results
- Query normalized to first 4 chars for grouping similar queries
- Stores full SearchItem data so recents can be displayed on empty query
- Data persisted in `~/Library/Application Support/Notty/` (frecency.json, recents.json)

## UI Behavior

- Actions menu (Cmd+K) floats as overlay over results (ZStack, bottom-trailing), does NOT replace them
- Empty query shows up to 8 recently used items
- Keyboard layout can be forced on panel open (setting in General tab, uses `TISSelectInputSource`)
- App icons via `NSWorkspace.shared.icon(forFile:)`, notes use SF Symbol `doc.text`

## Layout Rules (DO NOT BREAK)

- Panel width: 750, height: 474
- Results section: maxHeight 400, compact single-line rows
- VStack fills available space with Spacer + maxHeight .infinity
- NSHostingView pinned to all 4 edges of panel contentView
- **Every time the overlay layout is modified, verify results are visible with at least 8 rows**
