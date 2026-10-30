# Relux — Decisions & Request History

Only architectural/behavioral decisions with downstream implications. Not bug fixes or cosmetic tweaks.

## Search Architecture

- `SourceNote` replaced with generic `SearchItem` supporting `.note` and `.app` kinds — all future result types extend this *(`.note` removed 2026-10-30 with the notes extension; current kinds are `.app`, `.webSearch`, `.script`, `.translate`, `.calculator`, `.jwt`, `.systemSettings`)*
- Search is instant, as-you-type — keyword matching plus app name fuzzy matching. No embedding needed for basic search. *(Embeddings/vector search removed 2026-10-30: code removed; docs lagged.)*
- LLM generation is opt-in only, behind Cmd+K → "Ask AI" action. Never auto-triggers. *(Removed 2026-10-30 alongside the MLX dependencies below: code removed; docs lagged.)*
- App search uses configurable Spotlight scopes (default includes `/Applications`, Utilities, `/System/Library/CoreServices/Applications`, `~/Applications`); live re-indexes via `NSMetadataQueryDidUpdate`
- Do NOT use `Bundle(url:)` to read app bundles — triggers App Management permission. Only use `FileManager` + path inspection.

## Frecency System

- Tracks query→item selections to rank results; the scoring lives in `ReluxCore/Search/AppRanking.swift` (`AppUsage`, `UsageBoost`) and `FuzzyMatch.score(query:name:)`
- `usage` counts opens per stable identity (the app path for apps, the item id for everything else) — no per-query buckets. The value is `{explicitOpens, ambientOpens, lastUsed}`; panel picks are explicit, launches/activations observed via `NSWorkspace` are ambient (weighted 1/5). Before the ambient unit it was `{opens, lastUsed}`, and before the decay unit a bare `Int` — see *Ambient Usage Signals* below
- `learned` maps folded query → the last pick's identity (now `{path, at}`; `[String: String]` before the same unit, see below) so a pick can expire. Only explicit picks write it — ambient observations never do
- Queries are normalised in exactly one place (`FrecencyTracker.normalizedQuery`: trimmed, case- and diacritic-folded) so recording and lookup cannot disagree
- Web-search and calculator selections are never recorded (no stable identity)
- Legacy `"<query prefix>:<item id>" → {count, lastUsed}` files are migrated once on load by summing counts per identity (app path for apps, item id for non-apps)
- Stores full SearchItem data so recents can be displayed on empty query
- Data persisted atomically in `~/Library/Application Support/Relux/` (frecency.json, recents.json)

## UI Behavior

- Actions menu (Cmd+K) floats as overlay over results (ZStack, bottom-trailing), does NOT replace them
- Empty query shows up to 8 recently used items
- Keyboard layout can be forced on panel open (setting in General tab, uses `TISSelectInputSource`)
- App icons via `NSWorkspace.shared.icon(forFile:)`, funnelled through `AppIconCache` (fetch once per path, 48×48 rasterization, process-lifetime reuse)

## Keyboard Navigation

- Arrow keys MUST wrap around in all navigable lists (results, actions menu)
- Up from first item → last item; Down from last item → first item
- Applies to both the main results list and the Cmd+K actions overlay

## Extension Registry

- `ExtensionRegistry` tracks which extensions (search sources) are enabled/disabled, backed by UserDefaults (key pattern: `extension.<id>.enabled`)
- Registration happens inline in `AppState.setup()` with plain string ids — currently `translate`, `calculator`, `jwt`, `gestures`, `volumeHUD`
- "Models" settings tab renamed to "Notes" — models are an implementation detail of the notes extension *(Notes extension removed 2026-10-30: code removed; docs lagged.)*
- When notes disabled: models fully unloaded (`unloadAll` clears containers + model refs + GPU cache), note search skipped in `performSearch`, `restoreModels` no-ops *(Removed 2026-10-30: notes/MLX code removed; docs lagged.)*
- When notes enabled: models restored via `restoreModels()` (same as app startup) *(Removed 2026-10-30: notes/MLX code removed; docs lagged.)*
- Pattern is general-purpose — scripts, clipboard, apps can register in the same registry for their own toggle

## Model Lifecycle (removed)

> **Removed 2026-10-30**: MLX models and the notes extension were deleted from the codebase; docs lagged. Kept for history only.

- Models are NOT loaded at startup — only loaded on first use (lazy loading)
- After 10 minutes of inactivity, models are unloaded from memory (set containers to nil)
- On next use, auto-reload from stored model path
- MLXService stores the loaded model's `LocalModel` reference so it knows what to reload
- `isLLMLoaded`/`isEmbedderLoaded` flags update on both load and unload
- UI feedback during auto-reload uses existing `loadingStatus` mechanism

## Layout Rules (DO NOT BREAK)

- Panel width: 750, height: 474
- Results section: maxHeight 400, compact single-line rows
- VStack fills available space with Spacer + maxHeight .infinity
- NSHostingView pinned to all 4 edges of panel contentView
- **Every time the overlay layout is modified, verify results are visible with at least 8 rows**

## Selection Capture

- On hotkey press, selected text is read from the focused app via Accessibility API (`AXUIElement`) BEFORE Relux takes focus
- Stored in `AppState.currentSelection`, cleared on panel close
- Scripts opt in via `inputMode: InputMode` (.none/.stdin/.argument) — stdin pipes to process, argument appends shell-escaped value to command
- Web search uses selection as query when search bar is empty
- Ask AI prepends selection as context to the LLM prompt *(Removed 2026-10-30 with the MLX/LLM code: code removed; docs lagged.)*
- Bottom bar shows truncated selection preview when captured
- Requires Accessibility permission (prompted on first launch)
- Pattern for selection-aware features: any search result item that needs selected text appears only when `currentSelection != nil` (scripts with `inputMode != .none`, translate extension, etc.). The selected text is NOT placed in the search bar — only an indicator is shown. The text is passed to the feature when the user explicitly selects the item.

## Capture Output Scripts

> **Partially superseded** by *Script Output Modes* below: the `capturesOutput: Bool` became `ScriptOutputMode` (`.none` / `.capture` / `.replace`). Read the enabled/disabled wording below as `.capture` / `.none`.

- Scripts can opt into `capturesOutput: Bool` to stream stdout into the panel's answer section
- When enabled, the panel stays open and output streams incrementally (same UX as Ask AI)
- When disabled, existing fire-and-forget behavior with toast is preserved
- Uses `AsyncStream<String>` via `ScriptRunner.stream()` reading `availableData` in a loop
- Backward-compatible: existing scripts.json without the field default to `false`

## Clipboard History

- Integrated as the second panel mode via `PanelMode` on AppState — `.search` / `.clipboard` at the time; the enum now also has `.translate` and `.jwt`
- `PanelRootView` wrapper switches on the mode (`.search` → `OverlayView`, `.clipboard` → `ClipboardHistoryView`, plus the translate and JWT views)
- Clipboard monitoring uses timer-based polling of `NSPasteboard.general.changeCount` every 0.5s
- Storage: SQLite `clipboard_history` table in existing `relux.db`, images saved as PNG files in `~/Library/Application Support/Relux/clipboard/`
- Paste-back: puts content on system clipboard, closes panel, activates previous app, simulates Cmd+V via CGEvent
- `suppressNextCapture` flag prevents self-paste recording
- Hotkey: Opt+Cmd+V (configurable via KeyboardShortcuts)
- Disabled apps list stored in UserDefaults, defaults include Keychain Access and Passwords
- Retention-based cleanup runs once on app launch (configurable: 1/3/6 months)

## 2026-03-06: Remove MLX Dependencies

**Context**: The project initially integrated `mlx-swift` and `mlx-swift-lm` for on-device LLM inference and embeddings.

**Decision**: We have removed all MLX dependencies from `project.yml` and the codebase.

**Rationale**:
- Simplification of the architecture.
- Focus on core utility features (Command Bar, Clipboard, Translation) rather than local LLM hosting.
- Reduction in build complexity and binary size.

## Translation Dedup & History Sorting

- Translation history uses `content_hash` (djb2 hash of source text + target language) to detect duplicate translations
- When a duplicate is requested, the existing entry's `updated_at` is bumped instead of re-translating
- History sorted by `COALESCE(updated_at, created_at) DESC` — most recently used on top
- `created_at` is immutable (original creation time), `updated_at` tracks last access
- This pattern (content hash dedup + updated_at sorting) should be reused for clipboard history if needed

## Recents Dedup in Search Panel

- Search results with fixed ids (e.g., `translate-selection`) are deduped against recents by id
- Selection-aware items (built fresh with preview subtitle) take priority over their stored recents counterpart
- No kind-based filtering needed — id-based dedup handles all cases generically

## Calculator Extension

- Inline calculator triggered by math expressions or currency patterns in the search query
- Math eval uses `NSExpression` with a hardened input whitelist (digits, operators, parens, decimal points only)
- Currency conversion via ECB daily reference rates, parsed from XML with `ECBXMLParser`
- `ExchangeRateCache` persists rates as JSON in app support dir; stale after 24h, fetched fresh on next use
- Results shown in a two-column card UI (Raycast-style), copied to clipboard on selection
- Excluded from frecency tracking — calculator results are ephemeral, not worth recording as recents
- Registered in `ExtensionRegistry` with a readiness gate (`extensionReady`) so search skips it until rates are loaded

## JWT Extension

- Decodes JWT tokens pasted or captured via selection — displays header and payload in a two-panel view
- Pure client-side base64 decoding, no signature verification
- Frecency integration persists the last decoded token in `meta["token"]` inside recents.json
- Excluded from generic `recordSelection` in `openSelectedItem` to prevent overwriting stored token with empty dict
- Actions overlay (Cmd+K) for copying header/payload/full token
- Lives in `Sources/Relux/JWT/JWTView.swift` as a self-contained view; panel key handling is attached through the shared `PanelKeyMonitor`

## System Settings Search

- Hardcoded list of macOS 13+ System Settings categories with `x-apple.systempreferences:` deep-link URLs
- `SystemSettingsSearcher` matches by pane name and keyword synonyms (e.g. "wifi" → Wi-Fi, "keychain" → Passwords)
- Results shown as `.systemSettings` kind with gear icon, opened via `NSWorkspace.shared.open(url)`
- List is static — may need updating across macOS versions

## Configurable Search Paths

- `AppSearcher` search scopes are user-configurable via Settings → General → Search Paths
- Persisted in UserDefaults key `appSearchPaths`
- Defaults include `/Applications`, `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`, `/System/Library/CoreServices/Applications`, `~/Applications`
- Scopes converted to `URL` objects for reliable `NSMetadataQuery` recursion
- Changing paths restarts the Spotlight query immediately
- Live re-indexing via `NSMetadataQueryDidUpdate` observer — newly installed apps appear without restart

## Script Output Modes

- `ScriptOutputMode` enum replaces the previous `capturesOutput: Bool` on scripts
- Three modes: `.none` (fire-and-forget with toast), `.capture` (stream stdout into panel), `.replace` (replace active selection with stdout)
- `.replace` checks script exit code before replacing — on non-zero exit, shows error toast instead
- Backward-compatible: existing scripts.json entries without the field default to `.none`

## Shared Toast Utility

- `Toast` enum in `Sources/Relux/UI/Toast.swift` provides app-wide floating toast notifications
- Extracted from ScriptRunner's private implementation so other features (JWT validation, script errors) can reuse it
- Static `show(_:icon:)` method creates a borderless `NSPanel` positioned at top-center of the active screen

## Unified Score-Based Search Ranking

- `SearchItem` carries a `score: Double` field populated by every searcher and synthetic item generator
- All searchers (AppSearcher, ScriptSearcher, SystemSettingsSearcher) produce *base* scores on a shared 0–1050 scale; the usage boost (up to +500) is added afterwards in `AppState`, so a final score can exceed 1050
- Synthetic items (calculator, JWT, translate, web search) are created in `AppState.syntheticItems()` with explicit scores
- `AppState.performSearch` merges all sources, sorts by score descending, then truncates
- No positional manipulation in OverlayView — the view receives a pre-ranked list and renders it
- App rows are ranked by `AppSearcher` through the pure `AppRanking.score`: fuzzy tier + newly-detected bonus + usage boost. `AppSearcher` returns up to 50 candidates so usage can promote an app below the visible cut; `AppState` applies the final `prefix(maxSearchResults)`. Both the model and the tracker take an injected `now: Date`; `AppState.performSearch` captures one `Date()` per query so every row ranks against the same instant
- Non-app rows keep their searcher score and receive the same usage boost in `AppState`; frecency therefore still applies to apps, scripts, AND settings
- Selection-aware script bonus: +200 to base score (replaces unconditional prepend)
- App fuzzy tiers (higher is better): exact 1000, name prefix 900, initials prefix 800, word prefix 700, substring 500, in-order subsequence `max(1, 300 - gaps * 8)`. Tiers subtract a length penalty `min(name.count, 60)`; the subsequence tier does not
- App usage boost, evaluated at read time: `min(200, 20 * explicitOpens + 4 * ambientOpens) * 0.5^(age / 30 days)` plus 300 when the app was the last pick for that exact folded query **and** that pick is at most 90 days old. 300 > the widest adjacent tier gap (200), so learning can override the name ladder
- Score bands (base score, before the +up to 500 usage boost): calculator 1050, JWT keyword 1000 / JWT-shaped content 900, apps 1000 (exact) down to 1 (the subsequence tier is `max(1, 300 - gaps * 8)`, so 500 is a tier value, not a floor) plus +50 newly detected, scripts exact 930, settings exact 850, web search URL open 500 / DuckDuckGo fallback 200, translate 100
- See `docs/plans/2026-03-11-unified-search-scoring.md` for full scoring contract

## Instant Space Switching (4-Finger Swipes)

- Vendored Space-switching code lives in `Sources/Relux/SpaceSwitch/SpaceSwitch.m|.h` (originally `Sources/ISS/ISS.c|.h` from github.com/jurplel/InstantSpaceSwitcher, MIT)
- Swift mixed-language support via `Relux-Bridging-Header.h` and `SWIFT_OBJC_BRIDGING_HEADER` setting in project.yml
- `ReluxSwitchSpace(int delta)` requests the switch; the current implementation drives SkyLight's WMBridge sequence instead of synthetic dock-swipe events
- Uses private SkyLight symbols (`CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `SLSBridgedShowSpacesOperation`/`HideSpaces`/`ManagedDisplaySetCurrentSpaceOperation`) resolved with `dlsym` for bounds checking
- 4-finger horizontal swipes added to `GestureEngine` alongside existing 3-finger tracking, with separate state machines
- Default bindings: 4-finger swipe left → `switchSpaceLeft`, right → `switchSpaceRight` (via `SystemAction` enum)

## Calculator Integer Division Crash

- `NSExpression(format:)` integer division by zero throws an uncatchable ObjC exception that kills the SwiftUI `.task` context, breaking all subsequent reactive updates (typing, clipboard, results)
- Fix: `intToDouble()` regex converts bare integer literals to `N.0` before NSExpression evaluation, forcing floating-point arithmetic
- Float division by zero returns `inf` which is caught by `.isFinite` guard
- Also fixes the correctness bug where `800/500` evaluated to `1` instead of `1.6`

## Usage Recency Decay and Learned-Pick TTL

> **Status 2026-10-30**: implemented — `Sources/ReluxCore/Search/AppRanking.swift` (`UsageBoost`), `Sources/Relux/Search/FrecencyTracker.swift`.

**Context**: the previous unit stored bare open counts, so usage saturated and never forgot: an app opened 10 times stayed at the full `+200` forever, and a learned pick stayed authoritative forever.

**Decision**:
- `usage` is `[identity: { opens: Int, lastUsed: Date }]`; `opens += 1` and `lastUsed = now` on every recorded selection.
- The bonus is computed at read time, the whole bonus decaying as one unit: `min(200, 20 * opens) * 0.5^((now - lastUsed) / 30 days)`. Only the opens bonus decays; the learned pick is binary (`+300` while live).
- Half-life is **30 days**, a single named constant (`UsageBoost.halfLifeDays`). Rationale: because the whole bonus decays rather than a per-event counter, a 14-day half-life halves everything every fortnight, which forgets a weekly-used app too eagerly; 30 days keeps a weekly app near full weight while letting an abandoned app fade over a quarter.
- `learned` is `[foldedQuery: { path: String, at: Date }]` with a **hard 90-day TTL**: a pick older than 90 days is ignored at read time and pruned from the file on load and on every write. The boundary is inclusive — exactly 90 days old still applies.
- Every scoring function (`UsageBoost.value`, `UsageBoost.decay`, `UsageBoost.isLive`, `AppRanking.score`) and every tracker read/write that feeds it (`appUsage`, `usageBoost`, `recordSelection`) takes an injected `now: Date`, so the ranking arithmetic is exactly testable. The rule is about the scoring path only, not "only `AppState` calls `Date()`" — two non-scoring call sites default it: `FrecencyTracker.removeItem(id:now: Date = Date())` (called from `OverlayView`) and `JWTView`'s badge instant.

**Migration** (all three on-disk shapes load):
- **Legacy** `["<query prefix>:<itemId>": { count, lastUsed }]` -> group by item id, `opens = sum(count)`, `lastUsed = max(lastUsed)` per identity. The reference-date timestamps are real, so they are preserved rather than replaced with `now`. `learned` starts empty: a 4-character query prefix is not a full folded query, so a prefix -> path record could never match. Non-app ids (`script:`, `settings:`, `translate-selection`) are kept under their item id instead of being dropped.
- **Previous unit** `{ usage: [identity: Int], learned: [query: String] }` -> `opens` carried over, `lastUsed = now`, each learned pick gets `at = now` (no timestamp was ever stored).
- **Current shape** loads directly.
- Written atomically; a migration rewrites only after `recents.json` has been read, so it does not clobber recents.

## 2026-10-06: Volume HUD

> **Status 2026-10-30**: implemented — `Sources/Relux/VolumeHUD/` (`VolumeMonitor`, `VolumeHUDController`, `VolumeHUDView`), registered as `volumeHUD` in `ExtensionRegistry`.

**Context**: macOS 26 moved the volume indicator to a small top-right popover. Hudlum/volumeHUD restore a large overlay; Relux should offer the same.

**Decision**: Add an opt-in Volume HUD — a Relux-styled pill, centered on the display under the mouse (leading bar partially filled in quarter steps so 1/64 hardware increments are visible).

**Rationale / constraints**:
- Detection is **CoreAudio property listening** (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` + `kAudioDevicePropertyMute`, with a `kAudioHardwarePropertyDefaultOutputDevice` listener for device switches). No polling. No private APIs.
- The native macOS indicator is left untouched. No key interception, no suppression — the feature stays additive and permission-free.
- HUD defaults **OFF**; enabled via a General-tab toggle backed by `ExtensionRegistry` (`extension.volumeHUD.enabled`).
- `AppState` owns the controller. Feature code lives in `Sources/Relux/VolumeHUD/`; display selection is factored into `Sources/Relux/Util/DisplaySelection.swift`, extracted from `AppDelegate.movePanelToActiveDisplay()` so the panel and HUD share it. New directories are auto-globbed by XcodeGen (no `project.yml` change).
- Brightness, retro style, native HUD suppression, and configurable position/duration are explicit non-goals.
- Full spec: `docs/plans/2026-10-06-volume-hud-design.md`

## 2026-10-30: Scripts settings logic moved out of `SettingsView`

**Context**: the Scripts tab did its CRUD directly against `AppState.scriptSearcher` across ~11 call sites, interleaved with the draft state, so the commit ordering was untestable.

**Decision**: `Sources/Relux/Search/ScriptsSettingsModel.swift` (`@MainActor @Observable`) owns the draft (`editingScript`), the expanded row, the env-var mutations and the commit rule; `SettingsView` keeps only the form bindings and calls the model. The model was added to the `ReluxTests` sources in `project.yml`, so it had to stay SwiftUI-free.

- `ScriptSearcher.init(directory: URL? = nil)` — the default is still `~/Library/Application Support/Relux`, but tests inject a temp directory instead of writing to the real store.
- Behaviour preserved exactly, including the one rule (`commitEditing`): empty title **and** empty command discards the draft, or deletes the script if it was already persisted. Titles stay unconstrained (an empty title renders as "Untitled") and duplicates stay allowed. An earlier draft of this unit added title/duplicate validation; it was reverted because it changed behaviour and would have stopped an existing "Untitled" script from being re-saved.
- No reorder and no per-script enabled toggle were added: the view has neither, and adding them was out of scope.

## 2026-10-30: App display name is normalised where a name is stored and where recents are read

**Context**: `AppSearcher` ranked and displayed Spotlight's `kMDItemDisplayName`, which keeps the extension (`"Microsoft Remote Desktop.app"`). Rows disagreed depending on which source found the app, and the ranker scored a 4-character-longer string than the user sees, which shifts the `min(name.count, 60)` length penalty and puts the exact-name tier out of reach for every app. Live `recents.json` also held the old titles, so the recents list kept showing `.app` after the scan was fixed.

**Decision**:
- `ReluxCore` `AppDisplayName.from(bundleName:)` is the single implementation: it strips one trailing `.app` case-insensitively and passes everything else through. `AppItem.init` applies it, and so does `FrecencyTracker` on both sides of its snapshot store.
- Values that are *identities*, not names, keep the extension: `SearchItem.id` (`app:<path>`), `usage` keys and `learned` paths are bundle paths, so matching a rescan keeps working. Only `title` is normalised.
- Recents are normalised on **read**, not migrated: `FrecencyTracker.displayTitle(kind:id:title:)` applies the helper in `recentItems()` (and when a pick is recorded), so `recents.json` is left byte-identical by a pure read. Rewriting 123 user entries to fix a cosmetic string was not worth an atomic write on launch, and the stale titles disappear as entries are re-picked.
- The discriminator is `StoredItem.kind == "app"` **and** an `app:`-prefixed id, because both are stored on every entry. `kind` alone is not sufficient evidence — a script legitimately named `deploy.app` must keep its name — and the id prefix corroborates that the snapshot really came from the app searcher. No path-shape guessing (`/Applications` …) is used.

## 2026-10-30: Ambient Usage Signals

> **Status 2026-10-30**: implemented — `Sources/Relux/Search/AppActivityObserver.swift`, `Sources/ReluxCore/Search/AppRanking.swift` (`AppUsage`, `UsageBoost`), `Sources/Relux/Search/FrecencyTracker.swift`.

**Context**: only panel picks taught the ranking (`FrecencyTracker.recordSelection`), so an app opened from the Dock, Finder or Spotlight — the majority of opens — taught nothing. Recording was also query-coupled: a pick both bumped a counter and taught a query, so there was no way to express "the app was used" without inventing a query.

**Decision**:
- `usage` is `[identity: { explicitOpens, ambientOpens, lastUsed }]`. `explicitOpens` counts panel picks, `ambientOpens` counts observed launches/activations, `lastUsed` is the single recency anchor for both.
- Bonus: `min(200, 20 * explicitOpens + 4 * ambientOpens) * 0.5^((now - lastUsed) / 30 days)`. Ambient is exactly **1/5** of an explicit open (`UsageBoost.perAmbientOpen = 4`): an observation says the app was used, not that it beat the alternative the panel offered. The weights are summed **before** the shared 200 cap, so mixed usage saturates without either counter drowning the other (5 explicit + 25 ambient = 200). Half-life stays 30 days.
- **`learned` stays explicit-only.** An ambient event carries no query; inferring one ("the app is named `rem`") would let a background launch outvote a real pick. `recordAmbient` cannot write `learned`, and a test pins that.
- `Sources/Relux/Search/AppActivityObserver.swift` watches `NSWorkspace.didLaunchApplicationNotification` and `didActivateApplicationNotification`. Filters, all required:
  1. `bundleURL == nil`, `activationPolicy != .regular`, and Relux's own bundle id are ignored (Spotlight/Dock-launched helpers and the panel itself are not usage).
  2. **Coalescing** (10 s): a launch followed by the same app activating is one visit. `lastCommitAt[path]` plus a single pending event per path.
  3. **Dwell** (3 s): an activation commits only if the app is still `NSWorkspace.shared.frontmostApplication` when the timer fires; an activation superseded by another app's activation inside the window has its timer cancelled.
  4. **Self-suppression** (5 s): `AppState.recordSelection` calls `suppress(path:)` for app rows, cancelling the pending event and ignoring ambient events for that path — the panel already counted it.
  5. **Boot guard** (60 s): nothing observed in the first minute after start counts; login-item auto-launches are system startup, not usage.
- All timing is injected: `clock`, `ActivityScheduler` (a one-shot timer seam), `AppActivitySource` (the `NSWorkspace` notification center) and `frontmostPath`. No `Date()` or `Task.sleep` in the decision path, so the tests drive every window. `stop()` unregisters both notification observers and cancels pending timers.
- Persistence: ambient commits are debounced to **one `frecency.json` write per 60 s** (`FrecencyTracker.ambientSaveInterval`), decided from the injected `now`; ambient writes never touch `recents.json`. `flush(now:)` forces the pending write and runs on terminate (`AppDelegate.applicationWillTerminate` → `AppState.shutdown()`), and an explicit pick writes immediately anyway.
- **Migration**: the pre-ambient `{opens, lastUsed}` entry decodes as `explicitOpens = opens, ambientOpens = 0` inside `UsageEntry.init(from:)`, so nothing is lost and no file is rewritten just to rename a key. The old `PreviousUsage` and legacy prefix shapes migrate as before. A file that matches no schema is still never rewritten.

**Verification**: 124 entries of the live `frecency.json`, migrated on a copy — 0 mismatches, explicit sum preserved (1506), 5 learned picks preserved, file byte-identical on load, new shape on the first ambient write. The `NSWorkspace` plumbing was exercised by posting real notifications: a non-regular app counted 0, a regular app counted 1 after the 3 s dwell through the real `RunLoopActivityScheduler`, and a back-to-back launch was coalesced. No real app launch was observed.
