import Foundation

// MARK: - The sync pipeline, over an abstract transport (PURE: this package never opens a socket)
//
// The app target supplies a URLSession-backed `PolarAccessLinkTransport` (Strand/Polar/); tests, the demo CLI
// and the app's credential-free preview supply `PolarFixtureTransport`. Everything between "bytes came back"
// and "normalized rows" lives here, so it is covered by `swift test` on Linux.

/// One HTTP exchange's result, as the pipeline needs it.
public struct PolarHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

/// `GET https://www.polaraccesslink.com/v3/<path>?<query>` with the user's bearer token. Implementations
/// own auth headers, timeouts, byte caps and 429 back-off; the pipeline owns interpretation.
public protocol PolarAccessLinkTransport: Sendable {
    func get(_ path: String, query: [String: String]) async throws -> PolarHTTPResponse
}

public enum PolarSyncError: Error, Equatable {
    /// 401: token revoked/expired. AccessLink has no refresh tokens — the user must reconnect.
    case unauthorized
    /// 403: the user hasn't accepted Polar's mandatory consents (account.polar.com), or isn't registered.
    case forbidden
}

/// What a sync did, honestly: every endpoint that failed is named, never silently skipped.
public struct PolarSyncResult: Sendable, Equatable {
    public var normalized: PolarNormalized
    public var raw: [PolarRawPage]
    public var failures: [String]
    public var requestCount: Int
    public var window: (from: String, to: String)

    public static func == (a: Self, b: Self) -> Bool {
        a.normalized == b.normalized && a.raw == b.raw && a.failures == b.failures
            && a.requestCount == b.requestCount && a.window.from == b.window.from && a.window.to == b.window.to
    }

    /// One-line summary for the UI ("14 nights · 14 HRV · 4032 HR samples · 14 activity days").
    public var summaryText: String {
        let n = normalized
        var parts = ["\(n.sleepPeriods.count) nights",
                     "\(n.days.filter { $0.avgHrvMs != nil }.count) HRV",
                     "\(n.heartRate.count) HR samples",
                     "\(n.days.filter { $0.steps != nil }.count) activity days"]
        if !failures.isEmpty { parts.append("skipped: " + failures.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// A verbatim response body, kept so a later mapping change can re-derive without re-fetching (and so the
/// first real sync can be diffed against the fixtures).
public struct PolarRawPage: Sendable, Equatable {
    public var endpoint: String
    public var key: String
    public var body: Data
}

public struct PolarSyncPipeline: Sendable {
    public let transport: any PolarAccessLinkTransport
    public let timeZone: TimeZone
    /// AccessLink keeps ~28 days for sleep / Nightly Recharge / activity; asking for more is pointless.
    public static let maxWindowDays = 28

    public init(transport: any PolarAccessLinkTransport, timeZone: TimeZone) {
        self.transport = transport
        self.timeZone = timeZone
    }

    /// Pull the last `days` days (≤ 28) ending on `today` (a local `YYYY-MM-DD`), parse and normalize.
    /// A 401/403 aborts (nothing else can succeed); any other per-endpoint failure is recorded and skipped.
    public func run(today: String, days: Int = PolarSyncPipeline.maxWindowDays) async throws -> PolarSyncResult {
        let n = max(1, min(days, Self.maxWindowDays))
        let dayList = Self.dayKeys(endingOn: today, count: n, timeZone: timeZone)
        guard let from = dayList.first, let to = dayList.last else {
            return PolarSyncResult(normalized: PolarNormalized(), raw: [], failures: ["bad date \(today)"],
                                   requestCount: 0, window: (today, today))
        }
        var raw: [PolarRawPage] = []
        var failures: [String] = []
        var requests = 0

        func fetch(_ endpoint: String, _ path: String, _ query: [String: String] = [:], key: String) async throws -> Data? {
            requests += 1
            let resp: PolarHTTPResponse
            do { resp = try await transport.get(path, query: query) } catch {
                failures.append("\(endpoint) (\(error))"); return nil
            }
            switch resp.status {
            case 200..<300:
                if resp.status != 204 && !resp.body.isEmpty { raw.append(PolarRawPage(endpoint: endpoint, key: key, body: resp.body)) }
                return resp.status == 204 ? Data() : resp.body
            case 404: return Data()                     // no data for that day/feature: not a failure
            case 401: throw PolarSyncError.unauthorized
            case 403: throw PolarSyncError.forbidden
            default: failures.append("\(endpoint) (HTTP \(resp.status))"); return nil
            }
        }
        func parse<T>(_ endpoint: String, _ data: Data?, _ f: (Data) throws -> [T]) -> [T] {
            guard let data else { return [] }
            do { return try f(data) } catch { failures.append("\(endpoint) (\(error))"); return [] }
        }

        // The 28-day list endpoints default to "last 28 days"; filter to the window afterwards.
        let inWindow: (String) -> Bool = { $0 >= from && $0 <= to }
        let sleeps = parse("sleep", try await fetch("sleep", "users/sleep", key: "list"), AccessLinkParser.sleepNights)
            .filter { inWindow($0.date) }
        let recharges = parse("nightly-recharge", try await fetch("nightly-recharge", "users/nightly-recharge", key: "list"),
                              AccessLinkParser.nightlyRecharges).filter { inWindow($0.date) }
        let activities = parse("activities", try await fetch("activities", "users/activities", ["from": from, "to": to],
                                                             key: "\(from)_\(to)"), AccessLinkParser.activities)
            .filter { inWindow($0.date) }
        let cardio = parse("cardio-load", try await fetch("cardio-load", "users/cardio-load", key: "list"),
                           AccessLinkParser.cardioLoads).filter { inWindow($0.date) }
        // Continuous HR: one documented per-date call per day (~28 requests; the limit is 520 / 15 min).
        var chr: [PolarContinuousHRDay] = []
        for d in dayList {
            chr += parse("continuous-heart-rate", try await fetch("continuous-heart-rate", "users/continuous-heart-rate/\(d)", key: d),
                         AccessLinkParser.continuousHeartRate).filter { $0.date == d }
        }

        let normalized = PolarAccessLinkMapper.normalize(sleeps: sleeps, recharges: recharges, activities: activities,
                                                         continuousHR: chr, cardioLoads: cardio, timeZone: timeZone)
        return PolarSyncResult(normalized: normalized, raw: raw, failures: failures, requestCount: requests, window: (from, to))
    }

    /// `count` consecutive local day keys ending on `today`, oldest first.
    static func dayKeys(endingOn today: String, count: Int, timeZone: TimeZone) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let end = PolarAccessLinkMapper.localMidnight(today, calendar: cal) else { return [] }
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return (0..<count).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: end).map(f.string(from:)) }
    }
}
