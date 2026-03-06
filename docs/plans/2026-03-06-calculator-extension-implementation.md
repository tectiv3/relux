# Calculator Extension Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an inline calculator extension to the overlay that evaluates math expressions and converts currencies using ECB rates.

**Architecture:** Single `CalculatorService` class handles both math (NSExpression) and currency (ECB XML feed with disk cache). Results appear as a special two-column card at position 0 in search results. Integrated inline in `performSearch()` following the existing translate/web-search pattern.

**Tech Stack:** Swift 6, Foundation (NSExpression, XMLParser, JSONSerialization), SwiftUI

---

### Task 1: Add `.calculator` to SearchItemKind and update all switches

**Files:**
- Modify: `Sources/Relux/Extensions/ExtensionProtocol.swift:2-7`
- Modify: `Sources/Relux/UI/OverlayView.swift:268-274` (sectionLabel)
- Modify: `Sources/Relux/UI/OverlayView.swift:548-554` (kindLabel)

**Step 1: Add the enum case**

In `Sources/Relux/Extensions/ExtensionProtocol.swift`, add `.calculator` to `SearchItemKind`:

```swift
enum SearchItemKind: Sendable {
    case app
    case webSearch
    case script
    case translate
    case calculator
}
```

**Step 2: Update sectionLabel in OverlayView**

In `Sources/Relux/UI/OverlayView.swift`, update `sectionLabel(for:)`:

```swift
private func sectionLabel(for kind: SearchItemKind) -> String {
    switch kind {
    case .app: "Applications"
    case .script: "Scripts"
    case .webSearch: "Web Search"
    case .translate: "Translate"
    case .calculator: "Calculator"
    }
}
```

**Step 3: Update kindLabel in OverlayView**

In `Sources/Relux/UI/OverlayView.swift`, update `kindLabel(for:)`:

```swift
private func kindLabel(for item: SearchItem) -> String {
    switch item.kind {
    case .app: "Application"
    case .webSearch: "Web Search"
    case .script: "Script"
    case .translate: "Command"
    case .calculator: "Calculator"
    }
}
```

**Step 4: Build to verify no missing switch cases**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```
git add Sources/Relux/Extensions/ExtensionProtocol.swift Sources/Relux/UI/OverlayView.swift
git commit -m "Add .calculator case to SearchItemKind"
```

---

### Task 2: Create ExchangeRateCache

**Files:**
- Create: `Sources/Relux/Calculator/ExchangeRateCache.swift`

This class fetches ECB daily XML, parses it, and caches rates to disk.

**Step 1: Create the file**

Create `Sources/Relux/Calculator/ExchangeRateCache.swift`:

```swift
import Foundation
import os

private let log = Logger(subsystem: "com.relux.app", category: "ExchangeRateCache")

struct CachedRates: Sendable {
    let rates: [String: Double]
    let fetchedAt: Date
}

final class ExchangeRateCache: Sendable {
    private let cacheURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let reluxDir = appSupport.appendingPathComponent("Relux", isDirectory: true)
        try? FileManager.default.createDirectory(at: reluxDir, withIntermediateDirectories: true)
        cacheURL = reluxDir.appendingPathComponent("exchange-rates.json")
    }

    func loadCached() -> CachedRates? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ratesDict = json["rates"] as? [String: Double],
              let timestamp = json["fetchedAt"] as? Double
        else { return nil }
        return CachedRates(rates: ratesDict, fetchedAt: Date(timeIntervalSince1970: timestamp))
    }

    func saveToDisk(_ cached: CachedRates) {
        let json: [String: Any] = [
            "rates": cached.rates,
            "fetchedAt": cached.fetchedAt.timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    func fetchFresh() async -> CachedRates? {
        let urlString = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parser = ECBXMLParser(data: data)
            let rates = parser.parse()
            guard !rates.isEmpty else { return nil }
            let cached = CachedRates(rates: rates, fetchedAt: Date())
            saveToDisk(cached)
            log.info("Fetched \(rates.count) exchange rates from ECB")
            return cached
        } catch {
            log.error("Failed to fetch ECB rates: \(error.localizedDescription)")
            return nil
        }
    }

    func isStale(_ cached: CachedRates) -> Bool {
        abs(cached.fetchedAt.timeIntervalSinceNow) > 86400
    }
}

// MARK: - ECB XML Parser

private final class ECBXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var rates: [String: Double] = [:]

    init(data: Data) {
        self.data = data
    }

    func parse() -> [String: Double] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        // EUR is the base currency (rate = 1.0)
        rates["EUR"] = 1.0
        return rates
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard elementName == "Cube",
              let currency = attributes["currency"],
              let rateStr = attributes["rate"],
              let rate = Double(rateStr)
        else { return }
        rates[currency] = rate
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Sources/Relux/Calculator/ExchangeRateCache.swift
git commit -m "Add ExchangeRateCache with ECB XML fetching and disk cache"
```

---

### Task 3: Create CalculatorService

**Files:**
- Create: `Sources/Relux/Calculator/CalculatorService.swift`

**Step 1: Create the file**

Create `Sources/Relux/Calculator/CalculatorService.swift`:

```swift
import Foundation
import os

private let log = Logger(subsystem: "com.relux.app", category: "CalculatorService")

struct CalculatorResult: Sendable {
    let expression: String
    let answer: String
    let isCurrency: Bool
    let sourceCurrency: String?
    let targetCurrency: String?
    let lastUpdated: Date?
}

@MainActor @Observable
final class CalculatorService {
    private let cache = ExchangeRateCache()
    private var cachedRates: CachedRates?
    private var isFetching = false

    // Default target currency for each source
    private let defaultPairs: [String: String] = [
        "JPY": "USD",
        "EUR": "USD",
        "USD": "JPY",
        "GBP": "EUR",
    ]

    func warmUp() {
        if let loaded = cache.loadCached() {
            cachedRates = loaded
            if cache.isStale(loaded) {
                refreshRates()
            }
        } else {
            refreshRates()
        }
    }

    func evaluate(_ query: String) -> CalculatorResult? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let currencyResult = evaluateCurrency(trimmed) {
            return currencyResult
        }
        return evaluateMath(trimmed)
    }

    // MARK: - Math

    private func evaluateMath(_ query: String) -> CalculatorResult? {
        guard isMathExpression(query) else { return nil }

        // Sanitize: replace × with *, ÷ with /
        var expr = query
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "^", with: "**")

        // Remove trailing operators so partial input doesn't crash
        while let last = expr.last, "+-*/".contains(last) {
            expr.removeLast()
        }
        guard !expr.isEmpty else { return nil }

        let nsExpr: NSExpression
        do {
            nsExpr = try NSExpression(format: expr)
        } catch {
            return nil
        }

        guard let result = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }

        let answer = formatNumber(result.doubleValue)
        return CalculatorResult(
            expression: query,
            answer: answer,
            isCurrency: false,
            sourceCurrency: nil,
            targetCurrency: nil,
            lastUpdated: nil
        )
    }

    private func isMathExpression(_ query: String) -> Bool {
        let hasDigit = query.contains(where: \.isNumber)
        let operators: CharacterSet = CharacterSet(charactersIn: "+-*/^×÷()")
        let hasOperator = query.unicodeScalars.contains(where: { operators.contains($0) })
        guard hasDigit && hasOperator else { return false }

        // Reject if it contains alphabetic words (e.g. "7zip", "mp3")
        let words = query.components(separatedBy: .whitespaces)
        for word in words {
            let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: "+-*/^×÷().0123456789 "))
            if !stripped.isEmpty { return false }
        }
        return true
    }

    // MARK: - Currency

    // Pattern: "400 usd to jpy", "400 usd in jpy", "400 usd jpy", "400 usd"
    private static let currencyPattern: NSRegularExpression = {
        let codes = CurrencyInfo.allCodes.joined(separator: "|")
        let pattern = #"^(\d+\.?\d*)\s*("# + codes + #")\s*(?:to|in)?\s*("# + codes + #")?\s*$"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private func evaluateCurrency(_ query: String) -> CalculatorResult? {
        let range = NSRange(query.startIndex..., in: query)
        guard let match = Self.currencyPattern.firstMatch(in: query, range: range) else { return nil }

        guard let amountRange = Range(match.range(at: 1), in: query),
              let amount = Double(query[amountRange]),
              let sourceRange = Range(match.range(at: 2), in: query)
        else { return nil }

        let source = String(query[sourceRange]).uppercased()

        let target: String
        if match.range(at: 3).location != NSNotFound,
           let targetRange = Range(match.range(at: 3), in: query)
        {
            target = String(query[targetRange]).uppercased()
        } else {
            guard let defaultTarget = defaultPairs[source] else { return nil }
            target = defaultTarget
        }

        guard source != target else { return nil }

        guard let rates = cachedRates?.rates,
              let sourceRate = rates[source],
              let targetRate = rates[target]
        else { return nil }

        // Convert: amount in source → EUR → target
        let amountInEUR = amount / sourceRate
        let converted = amountInEUR * targetRate

        let answer = formatCurrency(converted, code: target)
        let sourceName = CurrencyInfo.name(for: source)
        let targetName = CurrencyInfo.name(for: target)

        return CalculatorResult(
            expression: "\(formatNumber(amount)) \(source)",
            answer: answer,
            isCurrency: true,
            sourceCurrency: sourceName ?? source,
            targetCurrency: targetName ?? target,
            lastUpdated: cachedRates?.fetchedAt
        )
    }

    // MARK: - Formatting

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formatCurrency(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = CurrencyInfo.isZeroDecimal(code) ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? formatNumber(value)
    }

    // MARK: - Rate Refresh

    private func refreshRates() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            if let fresh = await cache.fetchFresh() {
                cachedRates = fresh
            }
            isFetching = false
        }
    }
}

// MARK: - Currency Info

enum CurrencyInfo {
    static let allCodes: [String] = Array(names.keys).sorted()

    private static let names: [String: String] = [
        "USD": "US Dollar",
        "EUR": "Euro",
        "JPY": "Japanese Yen",
        "GBP": "British Pound",
        "AUD": "Australian Dollar",
        "CAD": "Canadian Dollar",
        "CHF": "Swiss Franc",
        "CNY": "Chinese Yuan",
        "SEK": "Swedish Krona",
        "NZD": "New Zealand Dollar",
        "KRW": "South Korean Won",
        "SGD": "Singapore Dollar",
        "NOK": "Norwegian Krone",
        "MXN": "Mexican Peso",
        "INR": "Indian Rupee",
        "RUB": "Russian Ruble",
        "ZAR": "South African Rand",
        "TRY": "Turkish Lira",
        "BRL": "Brazilian Real",
        "TWD": "Taiwan Dollar",
        "DKK": "Danish Krone",
        "PLN": "Polish Zloty",
        "THB": "Thai Baht",
        "IDR": "Indonesian Rupiah",
        "HUF": "Hungarian Forint",
        "CZK": "Czech Koruna",
        "ILS": "Israeli Shekel",
        "CLP": "Chilean Peso",
        "PHP": "Philippine Peso",
        "AED": "UAE Dirham",
        "COP": "Colombian Peso",
        "SAR": "Saudi Riyal",
        "MYR": "Malaysian Ringgit",
        "RON": "Romanian Leu",
        "BGN": "Bulgarian Lev",
        "HKD": "Hong Kong Dollar",
        "ISK": "Icelandic Krona",
        "HRK": "Croatian Kuna",
    ]

    private static let zeroDecimalCurrencies: Set<String> = [
        "JPY", "KRW", "IDR", "HUF", "CLP", "ISK",
    ]

    static func name(for code: String) -> String? {
        names[code.uppercased()]
    }

    static func isZeroDecimal(_ code: String) -> Bool {
        zeroDecimalCurrencies.contains(code.uppercased())
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Sources/Relux/Calculator/CalculatorService.swift
git commit -m "Add CalculatorService with math eval and currency conversion"
```

---

### Task 4: Register calculator in AppState and ExtensionRegistry

**Files:**
- Modify: `Sources/Relux/AppState.swift:15-48`
- Modify: `Sources/Relux/Extensions/ExtensionRegistry.swift:13-15`

Note: `ExtensionRegistry.register()` is `private`, so extensions must be registered inside `ExtensionRegistry.init()`.

**Step 1: Add calculatorService property to AppState**

In `Sources/Relux/AppState.swift`, add after the `extensionRegistry` property (line 18):

```swift
let calculatorService = CalculatorService()
```

**Step 2: Call warmUp in setup()**

In `AppState.setup()`, add at the end (before the closing brace at line 48):

```swift
calculatorService.warmUp()
```

**Step 3: Register calculator extension in ExtensionRegistry.init()**

In `Sources/Relux/Extensions/ExtensionRegistry.swift`, inside `init()` (line 13-15), add after the translate registration:

```swift
register(id: "calculator", name: "Calculator", icon: "equal.circle", defaultEnabled: true)
```

**Step 4: Build to verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```
git add Sources/Relux/AppState.swift Sources/Relux/Extensions/ExtensionRegistry.swift
git commit -m "Register calculator extension in AppState and ExtensionRegistry"
```

---

### Task 5: Add calculator card UI to OverlayView

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift`

This task adds the special calculator card view and hooks it into the results rendering.

**Step 1: Add the calculatorCard view**

Insert a new private method in OverlayView, after `resultRow(item:isSelected:)` (after line 355). This renders the two-column Raycast-style card:

```swift
private func calculatorCard(item: SearchItem, isSelected: Bool) -> some View {
    let expression = item.meta["expression"] ?? item.title
    let answer = item.meta["answer"] ?? ""
    let isCurrency = item.meta["isCurrency"] == "1"
    let sourceCurrency = item.meta["sourceCurrency"]
    let targetCurrency = item.meta["targetCurrency"]
    let lastUpdated = item.meta["lastUpdated"].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }

    return HStack(spacing: 0) {
        // Left: expression
        VStack(spacing: 4) {
            Text(expression)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            if isCurrency, let source = sourceCurrency {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
            }
        }
        .frame(maxWidth: .infinity)

        // Center: arrow
        VStack(spacing: 2) {
            Image(systemName: "arrow.right")
                .font(.system(size: 16))
                .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
            if isCurrency, let updated = lastUpdated {
                Text(relativeTime(updated))
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .white.opacity(0.4) : .secondary.opacity(0.7))
            }
        }
        .frame(width: 80)

        // Right: answer
        VStack(spacing: 4) {
            Text(answer)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            if isCurrency, let target = targetCurrency {
                Text(target)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 12)
    .background(
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            .padding(.horizontal, 4)
    )
    .foregroundColor(isSelected ? .white : .primary)
}

private func relativeTime(_ date: Date) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 60 { return "Updated just now" }
    if seconds < 3600 { return "Updated \(seconds / 60)m ago" }
    if seconds < 86400 { return "Updated \(seconds / 3600)h ago" }
    return "Updated \(seconds / 86400)d ago"
}
```

**Step 2: Update resultsSection to use calculatorCard**

In `resultsSection` (line 291-293), replace the `resultRow` call with a conditional:

Change:
```swift
ForEach(section.items, id: \.item.id) { index, item in
    resultRow(item: item, isSelected: index == selectedIndex)
        .id(index)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = index
            openSelectedItem()
        }
}
```

To:
```swift
ForEach(section.items, id: \.item.id) { index, item in
    Group {
        if item.kind == .calculator {
            calculatorCard(item: item, isSelected: index == selectedIndex)
        } else {
            resultRow(item: item, isSelected: index == selectedIndex)
        }
    }
    .id(index)
    .contentShape(Rectangle())
    .onTapGesture {
        selectedIndex = index
        openSelectedItem()
    }
}
```

**Step 3: Update bottomBar for calculator items**

In `bottomBar` (line 448), update the label for Enter when a calculator item is selected. Replace:

```swift
keyboardHint(key: "\u{23CE}", label: "Open")
```

With:
```swift
if selectedIndex < results.count, results[selectedIndex].kind == .calculator {
    keyboardHint(key: "\u{23CE}", label: "Copy Answer")
} else {
    keyboardHint(key: "\u{23CE}", label: "Open")
}
```

**Step 4: Build to verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "Add calculator card UI with Raycast-style two-column layout"
```

---

### Task 6: Integrate calculator into performSearch and openSelectedItem

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Add calculator result injection in performSearch**

In `performSearch(_:)` (line 485-546), after the `trimmed.isEmpty` check and before setting `selectedIndex = 0`, inject calculator results.

In the `else` branch (when query is not empty), after `results = searchResults` (around line 523) and before the translate-selection insert, add:

```swift
// Calculator: evaluate math or currency
if appState.extensionRegistry.isEnabled("calculator"),
   let calcResult = appState.calculatorService.evaluate(trimmed)
{
    let meta: [String: String] = [
        "expression": calcResult.expression,
        "answer": calcResult.answer,
        "isCurrency": calcResult.isCurrency ? "1" : "0",
        "sourceCurrency": calcResult.sourceCurrency ?? "",
        "targetCurrency": calcResult.targetCurrency ?? "",
        "lastUpdated": calcResult.lastUpdated.map { String($0.timeIntervalSince1970) } ?? "",
    ]
    results.insert(SearchItem(
        id: "calculator-result",
        title: calcResult.expression,
        subtitle: calcResult.answer,
        icon: "equal.circle",
        kind: .calculator,
        meta: meta
    ), at: 0)
}
```

This should go right after `results = searchResults` and before the `if appState.currentSelection != nil` block that inserts translate-selection. The calculator result should be at index 0, before everything else.

**Step 2: Handle calculator in openSelectedItem**

In `openSelectedItem()` (line 557-605), add a `.calculator` case in the switch:

```swift
case .calculator:
    if let answer = item.meta["answer"] {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }
    NSApp.keyWindow?.close()
```

**Step 3: Build to verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Manual test**

Run the app (`open Relux.xcodeproj`, Cmd+R), trigger the overlay hotkey, and type:
- `2+2` → should show calculator card with "2+2 → 4"
- `100*3+50` → should show "100*3+50 → 350"
- `400 usd` → should show "400 USD → ¥..." (after rates load)
- `100 eur to gbp` → should show conversion
- Enter on any result → copies answer to clipboard

**Step 5: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "Integrate calculator into search results and clipboard copy"
```

---

### Task 7: Final polish — handle edge cases

**Files:**
- Modify: `Sources/Relux/Calculator/CalculatorService.swift`
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Don't record calculator selections in frecency**

In `openSelectedItem()`, the existing code at line 560-562 records selections. Calculator results should be excluded. Change:

```swift
if item.kind != .webSearch {
    appState.recordSelection(query: query, item: item)
}
```

To:

```swift
if item.kind != .webSearch && item.kind != .calculator {
    appState.recordSelection(query: query, item: item)
}
```

**Step 2: Build and verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Sources/Relux/UI/OverlayView.swift Sources/Relux/Calculator/CalculatorService.swift
git commit -m "Polish calculator: exclude from frecency tracking"
```
