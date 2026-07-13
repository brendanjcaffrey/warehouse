import Foundation
import Testing
@testable import Warehouse

@Suite("JWT")
struct JWTTests {
    /// builds an unsigned token shaped like the server's: exp lives in the header
    /// segment, see shared/jwt.rb. the client never checks the signature
    static func make(exp: Date?, payload: [String: Any] = ["username": "brendan"]) -> String {
        var header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        if let exp {
            header["exp"] = Int(exp.timeIntervalSince1970)
        }
        return [encode(header), encode(payload), "not-a-real-signature"].joined(separator: ".")
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("expiry is read from the header segment")
    func expiryComesFromHeader() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let token = Self.make(exp: expiry)

        let parsed = try #require(JWT.expiry(of: token))
        #expect(Int(parsed.timeIntervalSince1970) == 1_800_000_000)
    }

    @Test("an exp in the payload is ignored, the server puts it in the header")
    func expiryIgnoresPayloadClaim() {
        let token = Self.make(exp: nil, payload: ["username": "brendan", "exp": 1_800_000_000])

        #expect(JWT.expiry(of: token) == nil)
    }

    @Test("a token past its exp is expired")
    func expiredTokenIsExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = Self.make(exp: now.addingTimeInterval(-1))

        #expect(JWT.isExpired(token, now: now))
    }

    @Test("a token with a future exp is not expired")
    func futureTokenIsNotExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // the server issues these with a year of runway
        let token = Self.make(exp: now.addingTimeInterval(365 * 24 * 60 * 60))

        #expect(!JWT.isExpired(token, now: now))
    }

    @Test("a token expiring exactly now is expired")
    func tokenExpiringNowIsExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(JWT.isExpired(Self.make(exp: now), now: now))
    }

    @Test("base64url padding & substitutions decode")
    func decodesBase64URL() throws {
        // pad the username until the header segment needs re-padding & the payload
        // is long enough to turn up - and _ in the encoding
        for length in 1...8 {
            let token = Self.make(
                exp: Date(timeIntervalSince1970: 1_800_000_000),
                payload: ["username": String(repeating: "a\u{00fe}?", count: length)])
            #expect(JWT.expiry(of: token) != nil, "failed to decode with a \(length)-unit username")
        }
    }

    @Test("tokens we can't parse are treated as unexpired")
    func unparseableTokensAreNotExpired() {
        // the server is the judge of validity: we'd rather let the background refresh
        // sort it out than lock the user out over a decode failure
        let garbage = ["", "ui-tests", "not.a.jwt", "only.two", "a.b.c.d", "!!!.???.***"]

        for token in garbage {
            #expect(JWT.expiry(of: token) == nil, "expected no expiry for \(token)")
            #expect(!JWT.isExpired(token), "expected \(token) to be treated as unexpired")
        }
    }

    @Test("a header with no exp has no expiry")
    func headerWithoutExpHasNoExpiry() {
        let token = Self.make(exp: nil)

        #expect(JWT.expiry(of: token) == nil)
        #expect(!JWT.isExpired(token))
    }
}
