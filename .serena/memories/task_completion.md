# Task Completion Checklist

## Build
- Run `xcodebuild -project Relux.xcodeproj -scheme Relux` after code changes when feasible.

## Lint & Format
- **SwiftLint**: Run `swiftlint lint --quiet` for safety/logic checks.
  - Config: `.swiftlint.yml` — focuses on safety rules (force unwrapping, complexity, etc.); style rules delegated to SwiftFormat.
  - Baseline: `.swiftlint.baseline` — 60 pre-existing violations quarantined. Use `swiftlint lint --baseline .swiftlint.baseline --quiet` to only see new violations.
  - Analyzer: `swiftlint analyze` for unused declaration detection (requires compile commands).
- **SwiftFormat**: Run `swiftformat --dryrun .` to check, or `swiftformat .` to auto-fix formatting.
  - Config: `.swiftformat` — 4-space indent, 120 max width, remove redundant self, alpha-sorted imports, K&R braces.
  - Swift version: `.swift-version` (6.1).
- Run `swiftformat Sources/` then `swiftlint lint --baseline .swiftlint.baseline --quiet` on changed files before committing.
- Verify localized strings keys if UI text changes (en/ja).

## IMPORTANT
- Always run this workflow before declaring a task complete. Never skip any step.
- Never use $() command substitution in git commit commands