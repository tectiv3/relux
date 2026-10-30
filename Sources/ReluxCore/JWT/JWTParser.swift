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
