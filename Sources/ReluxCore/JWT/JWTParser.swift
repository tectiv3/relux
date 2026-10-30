import CoreFoundation
import Foundation

public struct JWTParts: Sendable {
    public let header: String
    public let payload: String
    public let signature: String
    public let isValid: Bool
}

public enum JWTExpiryState: Equatable, Sendable {
    case valid
    case expired
    case notYetValid
}

/// Semantic weight of an expiry badge; the UI maps this to a colour so
/// `ReluxCore` stays free of SwiftUI types.
public enum JWTExpiryTone: Equatable, Sendable {
    case neutral
    case warning
    case critical
}

public struct JWTExpiryBadge: Equatable, Sendable {
    public let text: String
    /// Long-form instant for the tooltip, matching `timestampTooltip`'s style.
    public let detail: String
    public let tone: JWTExpiryTone

    public init(text: String, detail: String, tone: JWTExpiryTone) {
        self.text = text
        self.detail = detail
        self.tone = tone
    }
}

public struct JWTClaims: Equatable, Sendable {
    public let issuedAt: Date?
    public let notBefore: Date?
    public let expiresAt: Date?

    public init(issuedAt: Date? = nil, notBefore: Date? = nil, expiresAt: Date? = nil) {
        self.issuedAt = issuedAt
        self.notBefore = notBefore
        self.expiresAt = expiresAt
    }

    /// `nbf` is checked first: a token that is both not yet valid and past its
    /// expiry is reported as not yet valid, which is the more actionable state.
    public func expiryState(at date: Date = Date()) -> JWTExpiryState {
        if let notBefore, date < notBefore {
            return .notYetValid
        }
        if let expiresAt, date >= expiresAt {
            return .expired
        }
        return .valid
    }

    /// Returns `nil` when the token carries neither `exp` nor `nbf`, so tokens
    /// without temporal claims render exactly as before.
    public func expiryBadge(
        at date: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> JWTExpiryBadge? {
        guard notBefore != nil || expiresAt != nil else { return nil }

        let compact = Self.badgeFormatter(
            dateStyle: .medium,
            timeStyle: .medium,
            locale: locale,
            timeZone: timeZone
        )
        let long = Self.badgeFormatter(
            dateStyle: .full,
            timeStyle: .long,
            locale: locale,
            timeZone: timeZone
        )

        switch expiryState(at: date) {
        case .expired:
            guard let expiresAt else { return nil }
            return JWTExpiryBadge(
                text: "Expired · \(compact.string(from: expiresAt))",
                detail: "Expired \(long.string(from: expiresAt))",
                tone: .critical
            )
        case .notYetValid:
            guard let notBefore else { return nil }
            return JWTExpiryBadge(
                text: "Not yet valid · \(compact.string(from: notBefore))",
                detail: "Not valid until \(long.string(from: notBefore))",
                tone: .warning
            )
        case .valid:
            if let expiresAt {
                return JWTExpiryBadge(
                    text: "Valid · expires \(compact.string(from: expiresAt))",
                    detail: "Expires \(long.string(from: expiresAt))",
                    tone: .neutral
                )
            }
            guard let notBefore else { return nil }
            return JWTExpiryBadge(
                text: "Valid · since \(compact.string(from: notBefore))",
                detail: "Valid since \(long.string(from: notBefore))",
                tone: .neutral
            )
        }
    }

    /// Built per call: DateFormatter is not Sendable, so it cannot be shared
    /// under Swift 6 strict concurrency.
    private static func badgeFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatter.locale = locale
        formatter.timeZone = timeZone
        return formatter
    }
}

public enum JWTParser {
    public static func parts(of token: String) -> JWTParts {
        let segments = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ".")
        let header = segments.indices.contains(0) ? segments[0] : ""
        let payload = segments.indices.contains(1) ? segments[1] : ""
        let signature = segments.indices.contains(2) ? segments[2] : ""
        return JWTParts(
            header: header,
            payload: payload,
            signature: signature,
            isValid: segments.count >= 2 && !header.isEmpty && !payload.isEmpty
        )
    }

    /// Base64url-decodes one segment and pretty-prints it as sorted-key JSON.
    /// Returns an empty string when the segment is not decodable JSON.
    public static func decodedSegment(_ segment: String) -> String {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let length = Double(base64.lengthOfBytes(using: .utf8))
        let requiredLength = 4 * ceil(length / 4.0)
        let paddingLength = requiredLength - length
        if paddingLength > 0 {
            base64 += "".padding(toLength: Int(paddingLength), withPad: "=", startingAt: 0)
        }

        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: json,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return ""
        }

        return prettyString
    }

    public static func claims(ofToken token: String) -> JWTClaims? {
        claims(inJSON: decodedSegment(parts(of: token).payload))
    }

    public static func claims(inJSON json: String) -> JWTClaims? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any]
        else {
            return nil
        }
        return JWTClaims(
            issuedAt: numericDate(claims["iat"]),
            notBefore: numericDate(claims["nbf"]),
            expiresAt: numericDate(claims["exp"])
        )
    }

    public static func timestampTooltip(forLine line: String) -> String? {
        // Built per call: Regex is not Sendable, so it cannot be a shared static
        // under Swift 6 strict concurrency.
        let pattern = /:\s*(\d{10,13})\b/
        guard let match = line.firstMatch(of: pattern),
              let value = Double(match.1)
        else { return nil }

        // 13-digit values are milliseconds, 10-digit values are seconds
        let seconds = value > 9_999_999_999 ? value / 1000 : value
        guard timestampRange.contains(seconds) else { return nil }

        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter.string(from: date)
    }

    /// Unix timestamps between 2001-01-01 and 2100-01-01
    private static let timestampRange: ClosedRange<Double> = 978_307_200 ... 4_102_444_800

    private static func numericDate(_ value: Any?) -> Date? {
        // JSON booleans bridge to NSNumber, so a typeID check keeps `"exp": true`
        // from being read as a timestamp.
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}
