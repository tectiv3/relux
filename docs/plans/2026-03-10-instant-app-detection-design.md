# Instant App Detection

## Problem

Relux uses NSMetadataQuery (Spotlight) to index apps. When a user drops a new app into /Applications, there's a delay before Spotlight indexes it and the app appears in search results. Competitors like Raycast detect new apps instantly.

## Solution

Add DispatchSource filesystem watchers to AppSearcher alongside the existing Spotlight query. FSEvents detects new .app bundles within milliseconds. Newly detected apps get a temporary score boost and "NEW" badge until Spotlight confirms them.

## Design

### Scope

All changes within AppSearcher + minor UI additions. No new extension registration.

### Watched Paths

- `/Applications`
- `~/Applications`

Only these two — they're the standard drop targets. Not the full `searchPaths` list (system directories rarely change).

### New State in AppSearcher

- `newlyDetected: Set<String>` — paths of apps found by FSEvents but not yet in Spotlight
- Two `DispatchSource` file system object sources (one per watched directory)

### Flow

1. On init, start DispatchSource watchers alongside NSMetadataQuery
2. Watcher fires → enumerate `.app` bundles in directory → diff against current `apps` array
3. New bundles added to `apps` (immediately searchable) and `newlyDetected` (for score boost)
4. When `handleQueryResults()` fires from Spotlight → remove confirmed apps from `newlyDetected`
5. `newlyDetected` drains naturally as Spotlight catches up

### Search Scoring

In `search()`, apps in `newlyDetected` get +20 bonus:

| Match type       | Base score | With new bonus |
|------------------|-----------|----------------|
| Exact            | 100       | 120            |
| Prefix           | 80        | 100            |
| Substring        | 60        | 80             |
| Fuzzy            | 40        | 60             |

New apps surface prominently without overriding direct name matches from other apps.

### UI Changes

- `SearchItem` gains `isNew: Bool` (default `false`)
- `AppSearcher.search()` sets `isNew = true` for items in `newlyDetected`
- `SearchResultRow` shows a small "NEW" badge (SF Symbol `sparkles` or text label) when `isNew` is true

### Cleanup

No timers or manual cleanup. `newlyDetected` is cleared by Spotlight's own update cycle. If Spotlight never indexes an app (edge case), entries persist harmlessly — they only affect score boosting.
