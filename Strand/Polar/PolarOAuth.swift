// GOOP: Polar Loop lane. Compiled ONLY with -DPOLAR_ACCESSLINK (set by the untracked
// Strand/Polar/PolarSecrets.xcconfig — see PolarConfig.xcconfig). A default build contains none of it.
#if POLAR_ACCESSLINK
import Foundation

/// The user's own AccessLink client, injected at build time (untracked xcconfig → Info.plist).
/// nil credentials = fixture mode only (the card still offers "Preview with sample data").
struct PolarCredentials: Equatable {
    let clientId: String
    let clientSecret: String
    let redirectURI: String

    static func from(_ info: [String: Any]) -> PolarCredentials? {
        func nonBlank(_ k: String) -> String? {
            guard let s = (info[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  !s.hasPrefix("$(") else { return nil }     // an unexpanded build setting is "absent"
            return s
        }
        guard let id = nonBlank("POLAR_CLIENT_ID"), let secret = nonBlank("POLAR_CLIENT_SECRET"),
              let redirect = nonBlank("POLAR_REDIRECT_URI") else { return nil }
        return PolarCredentials(clientId: id, clientSecret: secret, redirectURI: redirect)
    }

    static var fromBundle: PolarCredentials? { from(Bundle.main.infoDictionary ?? [:]) }

    /// A custom-scheme redirect (noop://…) can be caught by ASWebAuthenticationSession. An http(s) one
    /// (e.g. http://localhost/…) cannot on iOS without associated domains, so the flow falls back to
    /// "open Safari, paste the address you land on".
    var usesCustomScheme: Bool {
        guard let scheme = URL(string: redirectURI)?.scheme?.lowercased() else { return false }
        return scheme != "http" && scheme != "https"
    }
}

struct PolarTokens: Equatable, Codable {
    let accessToken: String
    /// AccessLink's `x_user_id` — needed for `DELETE /v3/users/{id}` on disconnect.
    let polarUserId: Int64?
    /// From `expires_in` (docs show ~1 year; also say "won't expire unless revoked"). No refresh tokens exist,
    /// so expiry or any 401 means "reconnect".
    let expiresAt: Date?
    var isExpired: Bool { expiresAt.map { Date() >= $0 } ?? false }
}

enum PolarError: LocalizedError, Equatable {
    case notConfigured, notConnected, authFailed(String), tokenExchangeFailed(String),
         registrationFailed(String), consentsMissing, network(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Polar AccessLink client to PolarSecrets.xcconfig to connect. Sample-data preview still works."
        case .notConnected: return "Not connected to Polar."
        case .authFailed(let m): return "Polar sign-in didn't complete (\(m))."
        case .tokenExchangeFailed(let m): return "Polar sign-in failed at the token step (\(m))."
        case .registrationFailed(let m): return "Polar accepted the sign-in but registering for data failed (\(m))."
        case .consentsMissing: return "Polar needs you to accept its data-sharing consents first: open account.polar.com, accept, then Connect again."
        case .network(let m): return "Couldn't reach Polar (\(m))."
        }
    }
}

/// Pure request builders + response parsing for AccessLink's OAuth2 authorization-code flow
/// (https://www.polar.com/accesslink-api/ — "Authentication"). No PKCE exists, so the code exchange
/// carries the client secret via HTTP Basic, exactly as Polar documents.
enum PolarOAuth {
    static let authorizeEndpoint = URL(string: "https://flow.polar.com/oauth2/authorization")!
    static let tokenEndpoint = URL(string: "https://polarremote.com/v2/oauth2/token")!
    static let apiBase = URL(string: "https://www.polaraccesslink.com/v3/")!
    static let scope = "accesslink.read_all"

    static func authorizeURL(_ c: PolarCredentials, state: String) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: c.clientId),
            .init(name: "redirect_uri", value: c.redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
        ]
        return comps.url!
    }

    static func tokenRequest(_ c: PolarCredentials, code: String) -> URLRequest {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        let basic = Data("\(c.clientId):\(c.clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", c.redirectURI)]
        req.httpBody = fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&").data(using: .utf8)
        return req
    }

    static func parseToken(_ data: Data, now: Date) throws -> PolarTokens {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String, !access.isEmpty else {
            throw PolarError.tokenExchangeFailed("unexpected token response")
        }
        let uid = (o["x_user_id"] as? NSNumber)?.int64Value ?? (o["x_user_id"] as? String).flatMap(Int64.init)
        let expires = (o["expires_in"] as? NSNumber)?.doubleValue
        return PolarTokens(accessToken: access, polarUserId: uid,
                           expiresAt: expires.flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil })
    }

    /// Pull `code` out of the redirect (caught by ASWebAuthenticationSession, or pasted by the user), after
    /// checking `state`. Accepts a full URL or just its query string.
    static func code(fromCallback text: String, expectedState: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let comps = URLComponents(string: trimmed) ?? URLComponents(string: "x://x?" + trimmed)
        let items = comps?.queryItems ?? URLComponents(string: "x://x?" + trimmed)?.queryItems ?? []
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let err = q["error"] { throw PolarError.authFailed(err) }
        guard q["state"] == expectedState else { throw PolarError.authFailed("state mismatch — start Connect again") }
        guard let code = q["code"], !code.isEmpty else { throw PolarError.authFailed("no code in that address") }
        return code
    }

    /// `POST /v3/users` — mandatory once per user before any data read. 200 = registered, 409 = already
    /// registered (fine), 403 = mandatory consents not accepted at account.polar.com.
    static func registerUserRequest(token: String, memberId: String) -> URLRequest {
        var req = URLRequest(url: apiBase.appendingPathComponent("users"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["member-id": memberId])
        return req
    }

    /// `DELETE /v3/users/{user-id}` — de-registers and revokes the token (Polar side of "Disconnect").
    static func deregisterRequest(token: String, userId: Int64) -> URLRequest {
        var req = URLRequest(url: apiBase.appendingPathComponent("users/\(userId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}
#endif // POLAR_ACCESSLINK
