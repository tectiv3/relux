# Notty — Decisions & Request History

## 2026-03-05: Spotlight-style App Search + Actions Menu

**Request:** Add app launcher search (like Spotlight/Raycast) and make LLM generation opt-in via Cmd+K actions menu instead of auto-triggering.

**Decisions:**
- Replaced `SourceNote` with generic `SearchItem` type supporting `.note` and `.app` kinds
- App search scans `/Applications`, `~/Applications`, `/System/Applications` at init, caches results, fuzzy matches on query
- Search is now instant and as-you-type (no Enter needed) — keyword matching on VectorStore cache + app name matching
- LLM generation moved behind Cmd+K → "Ask AI" action (opt-in only)
- Actions menu is context-specific: notes get Open/Ask AI/Copy, apps get Launch/Show in Finder
- Actions menu navigable with arrow keys + Enter

## 2026-03-05: Keyboard Layout Forcing

**Request:** Add a setting to force a specific keyboard layout when the panel opens.

**Decision:** Added "General" tab in Settings with picker listing all installed keyboard input sources. On panel open, `TISSelectInputSource` switches to the saved layout. "Don't change" option leaves behavior as-is.

## 2026-03-05: App Management Permission Fix

**Request:** Why does Notty need "App Management" permission?

**Decision:** `Bundle(url:)` was reading inside `.app` bundles for bundle identifiers (unused). Removed those calls — only `FileManager.contentsOfDirectory` and path inspection needed, no special permissions.

## 2026-03-05: Frecency-Based Result Learning

**Request:** App should learn from selections — e.g. typing "text" should rank TextMate above TextEdit if user always picks TextMate.

**Decision:** Frecency system (frequency + recency). Track query→item selections, boost scores based on past behavior.

## 2026-03-05: App Icons

**Request:** Show actual app icons instead of SF Symbol placeholders.

**Decision:** Use `NSWorkspace.shared.icon(forFile:)` to get real app icons. Notes keep `doc.text` SF Symbol.

## 2026-03-05: Window Sizing — Raycast Style

**Request:** Window too big, make it look like Raycast.

**Decision:** Match Raycast layout — compact single-line rows with icon left, title, category tag right-aligned. Panel resizes to content height. No fixed 600pt.

## Layout Rules (DO NOT BREAK)

- Panel width: 750 (Raycast-like)
- Panel height: content-driven, max ~500pt
- Results section: maxHeight 400, compact rows (~36pt each)
- VStack fills available space
- The NSHostingView is pinned to all 4 edges
- **Every time the overlay layout is modified, check that results are visible with at least 8 rows**
