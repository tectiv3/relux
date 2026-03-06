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

    /// Default target currency for each source
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

        var expr = query
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "^", with: "**")
            .replacingOccurrences(of: "=", with: "")

        // Strip trailing operators so partial input doesn't crash
        while let last = expr.last, "+-*/".contains(last) {
            expr.removeLast()
        }
        guard !expr.isEmpty else { return nil }

        // NSExpression(format:) raises ObjC exceptions on bad input (uncatchable in Swift)
        // Validation in isMathExpression should prevent this, but guard with NSExpression.init(expressionType:)
        let nsExpr = NSExpression(format: expr)

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
        let cleaned = query.replacingOccurrences(of: "=", with: "")
        guard !cleaned.isEmpty else { return false }

        // Strict whitelist to prevent NSExpression format string injection
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^()×÷ ")
        guard CharacterSet(charactersIn: cleaned).isSubset(of: allowed) else { return false }

        let hasDigit = cleaned.contains(where: \.isNumber)
        let arithmeticOps = CharacterSet(charactersIn: "+-*/^×÷")
        let hasArithmeticOp = cleaned.unicodeScalars.contains(where: { arithmeticOps.contains($0) })
        guard hasDigit, hasArithmeticOp else { return false }

        // Balanced parentheses
        var depth = 0
        for ch in cleaned {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if depth < 0 { return false }
        }
        if depth != 0 { return false }

        return true
    }

    // MARK: - Currency

    // Pattern: "400 usd to jpy", "400 usd in jpy", "400 usd jpy", "400 usd"
    private static let currencyPattern: NSRegularExpression = {
        let codes = CurrencyInfo.allCodes.joined(separator: "|")
        let pattern = #"^(\d+\.?\d*)\s*("# + codes + #")\s*(?:to|in)?\s*("# + codes + #")?\s*$"#
        // swiftlint:disable:next force_try
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

        // Convert: amount in source -> EUR -> target
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
        if value == value.rounded(), abs(value) < 1e15 {
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
