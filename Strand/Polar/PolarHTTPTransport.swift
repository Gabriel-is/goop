// GOOP: Polar Loop lane. Compiled only with -DPOLAR_ACCESSLINK (on by default in GOOP via the tracked
// Strand/Polar/PolarConfig.xcconfig; delete that line there for a fully offline build).
// The ONE place the Polar lane touches the network for data. The pure pipeline in Packages/PolarAccessLink
// only sees this through `PolarAccessLinkTransport`.
#if POLAR_ACCESSLINK
import Foundation
import PolarAccessLink

/// URLSession-backed AccessLink transport: bearer auth, bounded reads, and polite 429/5xx back-off.
/// Never logs the token, the URL query, or a response body.
struct PolarHTTPTransport: PolarAccessLinkTransport {
    let token: String
    var session: URLSession = .shared
    var base: URL = PolarOAuth.apiBase

    func get(_ path: String, query: [String: String]) async throws -> PolarHTTPResponse {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        var attempt = 0
        while true {
            attempt += 1
            let (data, resp): (Data, URLResponse)
            do { (data, resp) = try await session.data(for: req) }
            catch {
                if attempt < 3 { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000); continue }
                throw PolarError.network(error.localizedDescription)
            }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            // 429: AccessLink reports the window reset in seconds in `RateLimit-Reset`. One user's sync is ~32
            // requests against a 520/15 min budget, so this should never fire; if it does, wait (capped) once.
            if status == 429 && attempt < 2 {
                let reset = http?.value(forHTTPHeaderField: "RateLimit-Reset")
                    .flatMap { $0.split(separator: ",").first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } } ?? 60
                try await Task.sleep(nanoseconds: UInt64(min(max(reset, 5), 120) * 1_000_000_000))
                continue
            }
            if (500..<600).contains(status) && attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                continue
            }
            guard data.count <= AccessLinkParser.maxResponseBytes else { return PolarHTTPResponse(status: 413, body: Data()) }
            return PolarHTTPResponse(status: status, body: data)
        }
    }
}
#endif // POLAR_ACCESSLINK
