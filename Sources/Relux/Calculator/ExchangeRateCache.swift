import Foundation
import os

private let log = Logger(subsystem: "com.relux.app", category: "ExchangeRateCache")

struct CachedRates: Sendable {
    let rates: [String: Double]
    let fetchedAt: Date
}

/// Only used from @MainActor via CalculatorService
final class ExchangeRateCache: @unchecked Sendable {
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
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
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
