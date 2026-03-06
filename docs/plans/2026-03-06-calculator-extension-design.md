# Calculator Extension Design

## Overview

Single "Calculator" extension handling both math evaluation and currency conversion, displayed as a special inline card in the overlay search results.

## Decisions

- **Parser:** NSExpression (built-in Apple API)
- **Currency rates:** ECB daily XML feed, free, no API key
- **Rate cache:** Daily disk cache at `~/Library/Application Support/Relux/exchange-rates.json`
- **Trigger:** Inline detection — math expressions and natural language currency patterns
- **UI:** Special two-column card (expression → result), not a standard SearchItem row
- **Enter action:** Copy answer to clipboard
- **Labels:** No word descriptions or operation labels. Currency cards show full currency names (hardcoded lookup).
- **Structure:** One combined extension registered as "calculator" in ExtensionRegistry

## Architecture

### CalculatorService

New file: `Sources/Relux/Services/CalculatorService.swift`

`@MainActor @Observable` class on AppState. Two detection paths:

**Math detection:**
- Query contains digits and at least one operator (`+`, `-`, `*`, `/`, `^`, `(`, `)`)
- Must not contain alphabetic words (avoids matching app names like "7zip")
- Evaluate via `NSExpression(format:)`

**Currency detection:**
- Regex: `(\d+\.?\d*)\s*(usd|eur|jpy|gbp|...)\s*(to|in)?\s*(usd|eur|jpy|gbp|...)?`
- Eager matching with default pairs:
  - JPY → USD
  - JPY → EUR
  - EUR → USD
  - USD → JPY
- If user types `400 usd` (no target), auto-show default pair result (USD → JPY)
- If user types `400 jpy to` — show USD result, update when target is completed
- Full explicit pair (`400 usd to eur`) always overrides defaults
- Conservative: only trigger on clear `number + recognized currency code` patterns

**Result type:**
```swift
struct CalculatorResult: Sendable {
    let expression: String    // "2+2" or "400 USD"
    let answer: String        // "4" or "¥63,130"
    let isCurrency: Bool
    let sourceCurrency: String?  // "USD"
    let targetCurrency: String?  // "JPY"
    let lastUpdated: Date?       // rate fetch time, nil for math
}
```

### ExchangeRateCache

New file: `Sources/Relux/Services/ExchangeRateCache.swift`

- Fetches `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`
- Parses XML into `[String: Double]` (currency code → rate vs EUR)
- Disk cache at `~/Library/Application Support/Relux/exchange-rates.json` with timestamp
- If cache < 24h old, use cached. Otherwise fetch fresh in background, return stale immediately.
- Hardcoded currency name lookup for display (~30 common currencies)

### UI — Calculator Card

When `item.kind == .calculator`, render a special card in OverlayView instead of `resultRow`:

**Math card:**
```
┌────────────────────┬───┬──────────────────────┐
│       2+2          │ → │         4             │
└────────────────────┴───┴──────────────────────┘
```

**Currency card:**
```
┌────────────────────┬─────────────┬──────────────────────┐
│     400 USD        │      →      │      ¥63,130         │
│  American Dollars  │ Updated 2m  │   Japanese Yen       │
└────────────────────┴─────────────┴──────────────────────┘
```

### Integration Points

1. **SearchItemKind** — Add `.calculator` case
2. **OverlayView.performSearch()** — Call `calculatorService.evaluate(trimmed)`, insert result at position 0 as SearchItem with `.calculator` kind. Meta dict carries expression/answer data.
3. **OverlayView results rendering** — Check `item.kind == .calculator`, render `calculatorCard` view
4. **OverlayView.openSelectedItem()** — For `.calculator`, copy answer to clipboard
5. **AppState** — Add `let calculatorService = CalculatorService()`, register in ExtensionRegistry during `setup()`
6. **ExtensionRegistry** — Gated behind `isEnabled("calculator")`
7. **sectionLabel/kindLabel** — Add `.calculator` cases

### New Files

| File | Purpose |
|------|---------|
| `Sources/Relux/Services/CalculatorService.swift` | Math eval, currency parsing, result generation |
| `Sources/Relux/Services/ExchangeRateCache.swift` | ECB fetch, XML parse, disk cache |

### Modified Files

| File | Changes |
|------|---------|
| `Sources/Relux/Extensions/ExtensionProtocol.swift` | Add `.calculator` to SearchItemKind |
| `Sources/Relux/AppState.swift` | Add calculatorService property, register extension |
| `Sources/Relux/UI/OverlayView.swift` | Calculator card view, integration in performSearch/openSelectedItem/sectionLabel/kindLabel |
