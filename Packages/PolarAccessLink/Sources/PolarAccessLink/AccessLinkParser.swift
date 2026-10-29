import Foundation

// MARK: - AccessLink JSON → typed models (PURE, network-free, hostile-input safe)
//
// AccessLink responses are UNTRUSTED input (docs/PRIVACY_SECURITY.md §3). Rules, mirroring StrandImport's
// WearableJSON helpers (which are internal to that module, hence this small local twin):
//   • a byte cap before decoding, so a garbled/huge body can't OOM the app;
//   • every number must be finite and inside a physiological range, else it becomes nil;
//   • collections are capped, so a crafted response can't produce millions of rows;
//   • a malformed record is skipped, never fatal — the rest of the response still imports.

public enum AccessLinkParserError: Error, Equatable {
    case tooLarge(bytes: Int)
    case notJSON
}

public enum AccessLinkParser {

    /// Hard ceiling on one response body. A 28-day sleep list with hypnograms is ~100 KB; one day of
    /// continuous HR is ~20 KB. 32 MB leaves two orders of magnitude of headroom and still bounds memory.
    public static let maxResponseBytes = 32 * 1024 * 1024
    /// Cap on records per response (AccessLink windows are ≤ 28–365 days).
    static let maxRecords = 2_000
    /// Cap on samples per map (a night of 30 s epochs is < 2 000; 24 h of 5-min HR is 288, of 1/s is 86 400).
    static let maxSamples = 100_000

    // MARK: Top-level documents

    /// `GET /v3/users/nightly-recharge` → `{"recharges":[…]}`; also accepts a bare array or a single
    /// object (the `/{date}` variant).
    public static func nightlyRecharges(_ data: Data) throws -> [PolarNightlyRecharge] {
        try records(data, wrapperKeys: ["recharges"]).compactMap(nightlyRecharge)
    }

    /// `GET /v3/users/sleep` → `{"nights":[…]}`; also a bare array or the `/{date}` single object.
    public static func sleepNights(_ data: Data) throws -> [PolarSleepNight] {
        try records(data, wrapperKeys: ["nights"]).compactMap(sleepNight)
    }

    /// `GET /v3/users/continuous-heart-rate/{date}` → one day object. The range variant's wrapper key is
    /// undocumented, so any array of day objects (bare, or under any of a few plausible keys) is accepted.
    public static func continuousHeartRate(_ data: Data) throws -> [PolarContinuousHRDay] {
        try records(data, wrapperKeys: ["heart_rates", "continuous_heart_rates", "days", "data"])
            .compactMap(continuousHRDay)
    }

    /// `GET /v3/users/activities` → an array of day objects (or the `/{date}` single object).
    public static func activities(_ data: Data) throws -> [PolarDailyActivity] {
        try records(data, wrapperKeys: ["activities", "data"]).compactMap(dailyActivity)
    }

    /// `GET /v3/users/cardio-load` → an array of day objects.
    public static func cardioLoads(_ data: Data) throws -> [PolarCardioLoad] {
        try records(data, wrapperKeys: ["cardio_loads", "data"]).compactMap(cardioLoad)
    }

    // MARK: Records

    static func nightlyRecharge(_ o: [String: Any]) -> PolarNightlyRecharge? {
        guard let date = dayKey(o["date"]) else { return nil }
        var r = PolarNightlyRecharge(date: date)
        r.heartRateAvg = int(o["heart_rate_avg"], in: 25...200)
        r.beatToBeatAvgMs = dbl(o["beat_to_beat_avg"], in: 250...2_500)
        r.hrvRmssdMs = dbl(o["heart_rate_variability_avg"], in: 1...400)
        r.breathingRateAvg = dbl(o["breathing_rate_avg"], in: 3...60)
        r.nightlyRechargeStatus = int(o["nightly_recharge_status"], in: 1...6)
        r.ansCharge = dbl(o["ans_charge"], in: -10...10)
        r.ansChargeStatus = int(o["ans_charge_status"], in: 1...5)
        r.hrvSamples = timeMap(o["hrv_samples"]) { dbl($0, in: 1...400) }.map { (time: $0.0, ms: $0.1) }
        return r
    }

    static func sleepNight(_ o: [String: Any]) -> PolarSleepNight? {
        guard let date = dayKey(o["date"]),
              let (start, startOffset) = isoWithOffset(o["sleep_start_time"]),
              let (end, _) = isoWithOffset(o["sleep_end_time"]),
              end > start, end.timeIntervalSince(start) <= 24 * 3600 else { return nil }
        var n = PolarSleepNight(date: date, start: start, end: end, utcOffsetSeconds: startOffset)
        let day = 86_400
        n.lightSleepSec = int(o["light_sleep"], in: 0...day)
        n.deepSleepSec = int(o["deep_sleep"], in: 0...day)
        n.remSleepSec = int(o["rem_sleep"], in: 0...day)
        n.unrecognizedSleepSec = int(o["unrecognized_sleep_stage"], in: 0...day)
        n.totalInterruptionSec = int(o["total_interruption_duration"], in: 0...day)
        n.continuity = dbl(o["continuity"], in: 0...5)
        n.sleepScore = int(o["sleep_score"], in: 1...100)
        n.sleepCharge = int(o["sleep_charge"], in: 1...5)
        n.sleepCycles = int(o["sleep_cycles"], in: 0...50)
        n.hypnogram = timeMap(o["hypnogram"]) { v in int(v, in: 0...5).flatMap(PolarSleepStage.init(rawValue:)) }
            .map { (time: $0.0, stage: $0.1) }
        n.heartRateSamples = timeMap(o["heart_rate_samples"]) { int($0, in: 25...230) }
            .map { (time: $0.0, bpm: $0.1) }
        return n
    }

    static func continuousHRDay(_ o: [String: Any]) -> PolarContinuousHRDay? {
        guard let date = dayKey(o["date"]), let raw = o["heart_rate_samples"] as? [Any] else { return nil }
        var samples: [PolarContinuousHRDay.Sample] = []
        for item in raw.prefix(maxSamples) {
            guard let s = item as? [String: Any],
                  let bpm = int(s["heart_rate"], in: 25...230),
                  let sec = secondsOfDay(s["sample_time"]) else { continue }
            samples.append(.init(secondsOfDay: sec, bpm: bpm))
        }
        samples.sort { $0.secondsOfDay < $1.secondsOfDay }
        return PolarContinuousHRDay(date: date, samples: samples)
    }

    static func dailyActivity(_ o: [String: Any]) -> PolarDailyActivity? {
        // The day comes from `start_time` ("2026-10-28T00:00:00", local, no zone); fall back to `date`.
        let fromStart = (o["start_time"] as? String).map { String($0.prefix(10)) }
        guard let date = dayKey(fromStart) ?? dayKey(o["date"]) else { return nil }
        var a = PolarDailyActivity(date: date)
        a.steps = int(o["steps"], in: 0...200_000)
        a.calories = dbl(o["calories"], in: 0...20_000)
        a.activeCalories = dbl(o["active_calories"], in: 0...20_000)
        a.distanceM = dbl(o["distance_from_steps"], in: 0...300_000)
        a.activeDurationSec = isoDurationSeconds(o["active_duration"]).flatMap { $0 <= 86_400 ? $0 : nil }
        return a
    }

    static func cardioLoad(_ o: [String: Any]) -> PolarCardioLoad? {
        guard let date = dayKey(o["date"]) else { return nil }
        // `LOAD_STATUS_NOT_AVAILABLE` means Polar couldn't compute it — keep the day, drop the numbers.
        if let status = o["cardio_load_status"] as? String, status.uppercased().contains("NOT_AVAILABLE") {
            return PolarCardioLoad(date: date)
        }
        var c = PolarCardioLoad(date: date)
        c.cardioLoad = dbl(o["cardio_load"], in: 0...2_000)
        c.strain = dbl(o["strain"], in: 0...2_000)
        c.tolerance = dbl(o["tolerance"], in: 0...2_000)
        c.ratio = dbl(o["cardio_load_ratio"], in: 0...20)
        return c
    }

    // MARK: Envelope

    /// Decode `data` (after the byte cap) and return the record objects: a bare array, an object holding an
    /// array under one of `wrapperKeys`, or a single record object. An empty body (HTTP 204) → `[]`.
    static func records(_ data: Data, wrapperKeys: [String]) throws -> [[String: Any]] {
        guard data.count <= maxResponseBytes else { throw AccessLinkParserError.tooLarge(bytes: data.count) }
        if data.isEmpty || data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw AccessLinkParserError.notJSON
        }
        let list: [Any]
        if let arr = root as? [Any] {
            list = arr
        } else if let obj = root as? [String: Any] {
            if let key = wrapperKeys.first(where: { obj[$0] is [Any] }), let arr = obj[key] as? [Any] {
                list = arr
            } else {
                list = [obj]
            }
        } else {
            return []
        }
        return list.prefix(maxRecords).compactMap { $0 as? [String: Any] }
    }

    // MARK: Scalar coercion (finite + range-checked; anything else → nil)

    static func dbl(_ any: Any?, in range: ClosedRange<Double>) -> Double? {
        let v: Double?
        switch any {
        case let n as NSNumber where !isBoolean(n): v = n.doubleValue
        case let s as String: v = Double(s.trimmingCharacters(in: .whitespaces))
        default: v = nil
        }
        guard let x = v, x.isFinite, range.contains(x) else { return nil }
        return x
    }

    static func int(_ any: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let d = dbl(any, in: Double(range.lowerBound)...Double(range.upperBound)) else { return nil }
        return Int(d.rounded())
    }

    /// A JSON `true`/`false` must never read as 1/0. JSONSerialization returns booleans as NSNumber whose
    /// `objCType` is "c" (char) on both Darwin and swift-corelibs-foundation; JSON integers and reals never are.
    static func isBoolean(_ n: NSNumber) -> Bool { String(cString: n.objCType) == "c" }

    /// A `YYYY-MM-DD` day key, validated as a real calendar date.
    static func dayKey(_ any: Any?) -> String? {
        guard let s = any as? String, s.count == 10, dayFormatter.date(from: s) != nil else { return nil }
        return s
    }

    /// "HH:MM" or "HH:MM:SS" → seconds since local midnight.
    static func secondsOfDay(_ any: Any?) -> Int? {
        guard let s = any as? String else { return nil }
        let parts = s.split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let h = parts[0]!, m = parts[1]!, sec = parts.count == 3 ? parts[2]! : 0
        guard (0...23).contains(h), (0...59).contains(m), (0...59).contains(sec) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// An "HH:MM" → value map, returned in the order the keys appear in time. JSON objects are unordered once
    /// decoded, so we cannot rely on the response's key order: the caller anchors these to a night, and
    /// `PolarHypnogram` handles the midnight wrap. Here we just sort by clock time and let the caller rotate.
    static func timeMap<T>(_ any: Any?, _ value: (Any) -> T?) -> [(String, T)] {
        guard let obj = any as? [String: Any] else { return [] }
        var out: [(String, T)] = []
        for (k, v) in obj.prefix(maxSamples) {
            guard secondsOfDay(k) != nil, let t = value(v) else { continue }
            out.append((k, t))
        }
        out.sort { secondsOfDay($0.0)! < secondsOfDay($1.0)! }
        return out
    }

    /// ISO-8601 timestamp WITH an offset (AccessLink sleep times: `2026-10-27T22:49:00.000-05:00`) → the instant
    /// and its offset in seconds. A timestamp with no offset is rejected (we would have to guess the zone).
    static func isoWithOffset(_ any: Any?) -> (Date, Int)? {
        guard let s = any as? String else { return nil }
        for f in [isoFractional, isoPlain] {
            if let d = f.date(from: s) {
                guard let off = offsetSeconds(of: s) else { return nil }
                return (d, off)
            }
        }
        return nil
    }

    /// Parse the trailing `Z` / `±HH:MM` / `±HHMM` of an ISO string.
    static func offsetSeconds(of s: String) -> Int? {
        if s.hasSuffix("Z") { return 0 }
        guard s.count > 6 else { return nil }
        let tail = s.suffix(6)
        if let sign = tail.first, sign == "+" || sign == "-", tail.dropFirst(3).first == ":" {
            guard let h = Int(tail.dropFirst().prefix(2)), let m = Int(tail.suffix(2)) else { return nil }
            return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
        }
        let tail5 = s.suffix(5)
        if let sign = tail5.first, sign == "+" || sign == "-",
           let h = Int(tail5.dropFirst().prefix(2)), let m = Int(tail5.suffix(2)) {
            return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
        }
        return nil
    }

    /// ISO-8601 duration ("PT3H11M", "PT45M30.5S", "P1DT2H") → seconds. Years/months are rejected (ambiguous).
    static func isoDurationSeconds(_ any: Any?) -> Double? {
        guard let s = any as? String, s.hasPrefix("P") else { return nil }
        var total = 0.0, num = "", inTime = false, sawUnit = false
        for ch in s.dropFirst() {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let v = Double(num), v.isFinite, v >= 0 else { return nil }
            num = ""
            switch (ch, inTime) {
            case ("D", false): total += v * 86_400
            case ("W", false): total += v * 604_800
            case ("H", true): total += v * 3_600
            case ("M", true): total += v * 60
            case ("S", true): total += v
            default: return nil
            }
            sawUnit = true
        }
        return (sawUnit && num.isEmpty) ? total : nil
    }

    // MARK: Formatters

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
