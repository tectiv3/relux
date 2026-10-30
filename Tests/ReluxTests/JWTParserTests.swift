import ReluxCore
import XCTest

final class JWTParserTests: XCTestCase {
    private func base64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func token(
        payload: String,
        header: String = #"{"alg":"HS256","typ":"JWT"}"#,
        signature: String = "signature"
    ) -> String {
        "\(base64url(header)).\(base64url(payload)).\(signature)"
    }

    private func jsonObject(_ pretty: String) throws -> NSDictionary {
        let data = try XCTUnwrap(pretty.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func referenceTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter
    }

    private let badgeLocale = Locale(identifier: "en_US_POSIX")
    private let badgeTimeZone = TimeZone(secondsFromGMT: 0)!

    private func badgeFormatter(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatter.locale = badgeLocale
        formatter.timeZone = badgeTimeZone
        return formatter
    }

    private func compactInstant(_ date: Date) -> String {
        badgeFormatter(dateStyle: .medium, timeStyle: .medium).string(from: date)
    }

    private func longInstant(_ date: Date) -> String {
        badgeFormatter(dateStyle: .full, timeStyle: .long).string(from: date)
    }

    private func badge(
        _ claims: JWTClaims,
        at date: Date
    ) -> JWTExpiryBadge? {
        claims.expiryBadge(at: date, locale: badgeLocale, timeZone: badgeTimeZone)
    }

    // MARK: - Parts

    func testPartsOfThreeSegmentToken() {
        let parts = JWTParser.parts(of: "header.payload.signature")
        XCTAssertEqual(parts.header, "header")
        XCTAssertEqual(parts.payload, "payload")
        XCTAssertEqual(parts.signature, "signature")
        XCTAssertTrue(parts.isValid)
    }

    func testPartsOfTwoSegmentTokenHasEmptySignature() {
        let parts = JWTParser.parts(of: "header.payload")
        XCTAssertEqual(parts.signature, "")
        XCTAssertTrue(parts.isValid)
    }

    func testPartsRejectsMissingOrEmptyHeaderAndPayload() {
        XCTAssertFalse(JWTParser.parts(of: "").isValid)
        XCTAssertFalse(JWTParser.parts(of: "header").isValid)
        XCTAssertFalse(JWTParser.parts(of: ".payload").isValid)
        XCTAssertFalse(JWTParser.parts(of: "header.").isValid)
    }

    func testPartsDoesNotValidateSegmentEncoding() {
        XCTAssertTrue(JWTParser.parts(of: "not.base64").isValid)
    }

    func testPartsTrimSurroundingWhitespace() {
        let token = "header.payload.signature"
        let padded = JWTParser.parts(of: "  \(token) \n")
        XCTAssertEqual(padded.header, "header")
        XCTAssertEqual(padded.payload, "payload")
        XCTAssertEqual(padded.signature, "signature")
        XCTAssertTrue(padded.isValid)
    }

    // MARK: - Segment decoding

    func testDecodedSegmentPadsOmittedBase64URL() throws {
        let segment = base64url(#"{"sub":"1234567890","name":"John Doe","admin":true}"#)
        XCTAssertFalse(segment.contains("="))

        let decoded = JWTParser.decodedSegment(segment)
        XCTAssertTrue(decoded.contains("\n"), "expected pretty-printed JSON, got \(decoded)")
        XCTAssertEqual(
            try jsonObject(decoded),
            ["sub": "1234567890", "name": "John Doe", "admin": true] as NSDictionary
        )
    }

    func testDecodedSegmentSortsKeys() throws {
        let decoded = JWTParser.decodedSegment(base64url(#"{"typ":"JWT","alg":"HS256"}"#))
        let algorithm = try XCTUnwrap(decoded.range(of: "\"alg\""))
        let type = try XCTUnwrap(decoded.range(of: "\"typ\""))
        XCTAssertLessThan(algorithm.lowerBound, type.lowerBound)
    }

    func testDecodedSegmentHandlesUnicodeClaims() throws {
        let payload = #"{"name":"こんにちは","emoji":"🔑","greeting":"héllo"}"#
        let decoded = JWTParser.decodedSegment(base64url(payload))
        XCTAssertEqual(
            try jsonObject(decoded),
            ["name": "こんにちは", "emoji": "🔑", "greeting": "héllo"] as NSDictionary
        )
    }

    func testDecodedSegmentRejectsMalformedAndNonJSON() {
        XCTAssertEqual(JWTParser.decodedSegment(""), "")
        XCTAssertEqual(JWTParser.decodedSegment("!!!not-base64!!!"), "")
        XCTAssertEqual(JWTParser.decodedSegment(base64url("this is not json")), "")
        // A bare JSON string fragment is rejected because fragments are not allowed
        XCTAssertEqual(JWTParser.decodedSegment(base64url(#""just a string""#)), "")
    }

    func testDecodedSegmentRejectsNonObjectJSON() {
        // Top-level arrays decode (JSONSerialization accepts them without fragments),
        // top-level scalars do not.
        XCTAssertEqual(JWTParser.decodedSegment(base64url("[1,2,3]")).isEmpty, false)
        XCTAssertEqual(JWTParser.decodedSegment(base64url("42")), "")
    }

    // MARK: - Claims

    func testClaimsParsesNumericDates() throws {
        let payload = #"{"sub":"1234567890","iat":1516239022,"exp":1516242622}"#
        let claims = try XCTUnwrap(JWTParser.claims(ofToken: token(payload: payload)))

        XCTAssertEqual(claims.issuedAt, Date(timeIntervalSince1970: 1_516_239_022))
        XCTAssertEqual(claims.expiresAt, Date(timeIntervalSince1970: 1_516_242_622))
        XCTAssertNil(claims.notBefore)
        XCTAssertEqual(claims.expiryState(at: Date(timeIntervalSince1970: 1_516_240_000)), .valid)
    }

    func testClaimsAcceptsFractionalNumericDate() throws {
        let claims = try XCTUnwrap(JWTParser.claims(ofToken: token(payload: #"{"exp":1516242622.5}"#)))
        XCTAssertEqual(claims.expiresAt, Date(timeIntervalSince1970: 1_516_242_622.5))
    }

    func testClaimsIgnoresNonNumericClaimValues() throws {
        let payload = #"{"iat":"1516239022","nbf":true,"exp":false}"#
        let claims = try XCTUnwrap(JWTParser.claims(ofToken: token(payload: payload)))
        XCTAssertNil(claims.issuedAt)
        XCTAssertNil(claims.notBefore)
        XCTAssertNil(claims.expiresAt)
    }

    func testClaimsIsNilForUndecodablePayload() {
        XCTAssertNil(JWTParser.claims(ofToken: token(payload: "not json")))
        XCTAssertNil(JWTParser.claims(ofToken: "header"))
        XCTAssertNil(JWTParser.claims(inJSON: ""))
    }

    // MARK: - Expiry state

    func testExpiryStateBoundaries() {
        let claims = JWTClaims(
            notBefore: Date(timeIntervalSince1970: 500),
            expiresAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(claims.expiryState(at: Date(timeIntervalSince1970: 499)), .notYetValid)
        XCTAssertEqual(claims.expiryState(at: Date(timeIntervalSince1970: 500)), .valid)
        XCTAssertEqual(claims.expiryState(at: Date(timeIntervalSince1970: 999)), .valid)
        XCTAssertEqual(claims.expiryState(at: Date(timeIntervalSince1970: 1000)), .expired)
    }

    func testNotYetValidTakesPrecedenceOverExpired() {
        let claims = JWTClaims(
            notBefore: Date(timeIntervalSince1970: 2000),
            expiresAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(claims.expiryState(at: Date(timeIntervalSince1970: 1500)), .notYetValid)
    }

    func testClaimsWithoutExpiryOrNotBeforeAreValid() {
        XCTAssertEqual(JWTClaims().expiryState(at: Date(timeIntervalSince1970: 0)), .valid)
    }

    // MARK: - Expiry badge

    func testBadgeExpiredExactlyOneSecondAfterExpiry() {
        let expiry = Date(timeIntervalSince1970: 1_516_242_622)
        let result = badge(JWTClaims(expiresAt: expiry), at: expiry.addingTimeInterval(1))

        XCTAssertEqual(result?.text, "Expired · \(compactInstant(expiry))")
        XCTAssertEqual(result?.detail, "Expired \(longInstant(expiry))")
        XCTAssertEqual(result?.tone, .critical)
    }

    func testBadgeExpiredAtExactExpiryBoundary() {
        let expiry = Date(timeIntervalSince1970: 1_516_242_622)

        XCTAssertEqual(badge(JWTClaims(expiresAt: expiry), at: expiry.addingTimeInterval(-1))?.text,
                       "Valid · expires \(compactInstant(expiry))")
        XCTAssertEqual(badge(JWTClaims(expiresAt: expiry), at: expiry)?.text,
                       "Expired · \(compactInstant(expiry))")
    }

    func testBadgeNotYetValid() {
        let notBefore = Date(timeIntervalSince1970: 1_516_242_622)
        let result = badge(JWTClaims(notBefore: notBefore), at: notBefore.addingTimeInterval(-1))

        XCTAssertEqual(result?.text, "Not yet valid · \(compactInstant(notBefore))")
        XCTAssertEqual(result?.detail, "Not valid until \(longInstant(notBefore))")
        XCTAssertEqual(result?.tone, .warning)
    }

    func testBadgeValidWithExpiryOnly() {
        let expiry = Date(timeIntervalSince1970: 1_516_242_622)
        let result = badge(JWTClaims(expiresAt: expiry), at: expiry.addingTimeInterval(-3600))

        XCTAssertEqual(result?.text, "Valid · expires \(compactInstant(expiry))")
        XCTAssertEqual(result?.tone, .neutral)
    }

    func testBadgeValidWithNotBeforeOnly() {
        let notBefore = Date(timeIntervalSince1970: 1_516_242_622)
        let result = badge(JWTClaims(notBefore: notBefore), at: notBefore.addingTimeInterval(3600))

        XCTAssertEqual(result?.text, "Valid · since \(compactInstant(notBefore))")
        XCTAssertEqual(result?.detail, "Valid since \(longInstant(notBefore))")
        XCTAssertEqual(result?.tone, .neutral)
    }

    func testBadgePrefersNotBeforeWhenBothClaimsPresent() {
        let claims = JWTClaims(
            notBefore: Date(timeIntervalSince1970: 2000),
            expiresAt: Date(timeIntervalSince1970: 1000)
        )
        let result = badge(claims, at: Date(timeIntervalSince1970: 1500))

        XCTAssertEqual(result?.text, "Not yet valid · \(compactInstant(Date(timeIntervalSince1970: 2000)))")
        XCTAssertEqual(result?.tone, .warning)
    }

    func testBadgeIsNilWithoutTemporalClaims() {
        let claims = JWTClaims(issuedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertNil(badge(claims, at: Date(timeIntervalSince1970: 1500)))
        XCTAssertNil(badge(JWTClaims(), at: Date(timeIntervalSince1970: 1500)))
        XCTAssertEqual(claims.expiryState(at: Date(timeIntervalSince1970: 1500)), .valid)
    }

    func testBadgeIgnoresNonNumericExpiryClaim() throws {
        let payload = #"{"sub":"1234567890","exp":"1516242622"}"#
        let claims = try XCTUnwrap(JWTParser.claims(ofToken: token(payload: payload)))

        XCTAssertNil(claims.expiresAt)
        XCTAssertNil(badge(claims, at: Date(timeIntervalSince1970: 1_516_240_000)))
    }

    func testBadgeForFractionalExpiry() throws {
        let payload = #"{"exp":1516242622.5}"#
        let claims = try XCTUnwrap(JWTParser.claims(ofToken: token(payload: payload)))
        let expiry = Date(timeIntervalSince1970: 1_516_242_622.5)

        XCTAssertEqual(badge(claims, at: Date(timeIntervalSince1970: 1_516_242_000))?.text,
                       "Valid · expires \(compactInstant(expiry))")
        XCTAssertEqual(badge(claims, at: Date(timeIntervalSince1970: 1_516_242_623))?.text,
                       "Expired · \(compactInstant(expiry))")
    }

    // MARK: - Badge refresh schedule

    func testNoTransitionWithoutTemporalClaims() {
        let claims = JWTClaims(issuedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertNil(claims.nextStateTransition(after: Date(timeIntervalSince1970: 2000)))
        XCTAssertNil(claims.badgeRefreshDelay(after: Date(timeIntervalSince1970: 2000)))
        XCTAssertNil(JWTClaims().badgeRefreshDelay(after: Date(timeIntervalSince1970: 2000)))
    }

    func testNoTransitionOnceExpired() {
        let claims = JWTClaims(expiresAt: Date(timeIntervalSince1970: 1000))
        XCTAssertNil(claims.nextStateTransition(after: Date(timeIntervalSince1970: 1000)))
        XCTAssertNil(claims.badgeRefreshDelay(after: Date(timeIntervalSince1970: 1500)))
    }

    func testNoTransitionOnceNotBeforePassed() {
        let claims = JWTClaims(notBefore: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(claims.nextStateTransition(after: Date(timeIntervalSince1970: 999)),
                       Date(timeIntervalSince1970: 1000))
        XCTAssertNil(claims.badgeRefreshDelay(after: Date(timeIntervalSince1970: 1001)))
    }

    func testTransitionDelayToExpiry() {
        let claims = JWTClaims(expiresAt: Date(timeIntervalSince1970: 1060))
        XCTAssertEqual(claims.badgeRefreshDelay(after: Date(timeIntervalSince1970: 1000)), 60)
    }

    func testTransitionSchedulesNotBeforeFirst() {
        let claims = JWTClaims(
            notBefore: Date(timeIntervalSince1970: 1030),
            expiresAt: Date(timeIntervalSince1970: 1060)
        )
        XCTAssertEqual(claims.badgeRefreshDelay(after: Date(timeIntervalSince1970: 1000)), 30)
        // After `nbf` passes the only boundary left is `exp`.
        XCTAssertEqual(claims.badgeRefreshDelay(after: Date(timeIntervalSince1970: 1031)), 29)
        XCTAssertNil(claims.badgeRefreshDelay(after: Date(timeIntervalSince1970: 1060)))
    }

    func testTransitionSchedulesNotBeforeEvenWhenExpiryAlreadyPassed() {
        let claims = JWTClaims(
            notBefore: Date(timeIntervalSince1970: 2000),
            expiresAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(claims.nextStateTransition(after: Date(timeIntervalSince1970: 1500)),
                       Date(timeIntervalSince1970: 2000))
    }

    /// The state flip the panel relies on: the badge says `Valid` before the
    /// scheduled wake and `Expired` at it, with no user interaction in between.
    func testBadgeFlipsFromValidToExpiredAtScheduledTransition() throws {
        let expiry = Date(timeIntervalSince1970: 1_516_242_622)
        let claims = JWTClaims(expiresAt: expiry)
        let openedAt = expiry.addingTimeInterval(-60)

        let delay = try XCTUnwrap(claims.badgeRefreshDelay(after: openedAt))
        XCTAssertEqual(delay, 60)
        XCTAssertEqual(badge(claims, at: openedAt)?.text,
                       "Valid · expires \(compactInstant(expiry))")

        let wake = expiry
        XCTAssertEqual(badge(claims, at: wake)?.text, "Expired · \(compactInstant(expiry))")
        XCTAssertEqual(badge(claims, at: wake)?.tone, .critical)
        XCTAssertNil(claims.badgeRefreshDelay(after: wake))
    }

    /// A token that is not yet valid schedules its own transition and then
    /// keeps only the `exp` boundary.
    func testBadgeFlipsFromNotYetValidToValidAtScheduledTransition() throws {
        let notBefore = Date(timeIntervalSince1970: 1_516_242_622)
        let claims = JWTClaims(
            notBefore: notBefore,
            expiresAt: notBefore.addingTimeInterval(3600)
        )
        let openedAt = notBefore.addingTimeInterval(-30)

        let delay = try XCTUnwrap(claims.badgeRefreshDelay(after: openedAt))
        XCTAssertEqual(delay, 30)
        let wake = notBefore
        XCTAssertEqual(badge(claims, at: openedAt)?.tone, .warning)
        XCTAssertEqual(badge(claims, at: wake)?.text,
                       "Valid · expires \(compactInstant(notBefore.addingTimeInterval(3600)))")
        XCTAssertEqual(claims.badgeRefreshDelay(after: wake), 3600)
    }

    // MARK: - Timestamp tooltips

    func testTimestampTooltipForIntegerSeconds() {
        let expected = referenceTimestampFormatter()
            .string(from: Date(timeIntervalSince1970: 1_516_239_022))
        XCTAssertEqual(JWTParser.timestampTooltip(forLine: #"  "iat": 1516239022,"#), expected)
    }

    func testTimestampTooltipTreatsThirteenDigitsAsMilliseconds() {
        XCTAssertEqual(
            JWTParser.timestampTooltip(forLine: #"  "exp": 1516239022000"#),
            JWTParser.timestampTooltip(forLine: #"  "exp": 1516239022"#)
        )
    }

    func testTimestampTooltipRangeBoundaries() {
        // The regex requires 10-13 digits, so the 9-digit 2001 lower bound is unreachable;
        // the smallest annotatable timestamp is 1000000000 (2001-09-09).
        XCTAssertNil(JWTParser.timestampTooltip(forLine: #"  "iat": 978307200"#))
        XCTAssertNil(JWTParser.timestampTooltip(forLine: #"  "iat": 4102444801"#))
        XCTAssertNotNil(JWTParser.timestampTooltip(forLine: #"  "iat": 1000000000"#))
        XCTAssertNotNil(JWTParser.timestampTooltip(forLine: #"  "iat": 4102444800"#))
    }

    func testTimestampTooltipRejectsLinesWithoutTimestamp() {
        XCTAssertNil(JWTParser.timestampTooltip(forLine: #"  "name": "John Doe""#))
        XCTAssertNil(JWTParser.timestampTooltip(forLine: "1516239022"))
        XCTAssertNil(JWTParser.timestampTooltip(forLine: #"  "iat" 1516239022"#))
        XCTAssertNil(JWTParser.timestampTooltip(forLine: ""))
    }
}
