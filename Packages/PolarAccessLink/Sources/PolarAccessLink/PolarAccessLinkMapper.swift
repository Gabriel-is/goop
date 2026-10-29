import Foundation
import StrandImport

// MARK: - Neutral output models (the app-target writer maps these into WhoopStore)

/// One heart-rate sample (→ `hrSample`). `ts` is unix seconds.
public struct PolarHRPoint: Sendable, Equatable {
    public let ts: Int
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

/// One extra daily scalar the wide `dailyMetric` columns don't hold (→ `metricSeries`). Polar's OWN scores
/// use a `ref_` prefix and Polar-specific measurements a `polar_` prefix, the same convention the Oura
/// lanes use, so they are browseable in Metric Explorer but never mistaken for a NOOP score.
public struct PolarDailyExtra: Sendable, Equatable {
    public let day: String
    public let key: String
    public let value: Double
    public init(day: String, key: String, value: Double) { self.day = day; self.key = key; self.value = value }
}

/// One Polar night: the shared session (with decoded stages) plus its in-sleep HR samples.
public struct PolarSleepPeriod: Sendable, Equatable {
    public var session: WearableSleepSession
    public var hr: [PolarHRPoint]
    public init(session: WearableSleepSession, hr: [PolarHRPoint]) { self.session = session; self.hr = hr }
}

/// Where a night's resting HR came from (stored as `polar_rhr_source` so a mixed history is auditable).
public enum PolarRestingHRSource: Int, Sendable, Equatable {
    /// Lowest 5-min average of the night's `sleep.heart_rate_samples` (the default; closest to WHOOP/Oura RHR).
    case sleepLowest5Min = 1
    /// Fallback: Nightly Recharge `heart_rate_avg` (a 4 h-window MEAN, reads a few bpm higher).
    case nightlyRechargeAverage = 2
}

/// Everything one sync produced, normalized. `days` are keyed by Polar's `date` (the wake day).
public struct PolarNormalized: Sendable, Equatable {
    public var days: [WearableDailyRow] = []
    public var sleepPeriods: [PolarSleepPeriod] = []
    public var heartRate: [PolarHRPoint] = []
    public var extras: [PolarDailyExtra] = []
    public init() {}
}

// MARK: - Mapper

public enum PolarAccessLinkMapper {

    /// A night needs at least this many 5-min HR samples (1 h) before its minimum is trusted as resting HR;
    /// fewer than that and one artefact could be the minimum.
    public static let minSleepHRSamplesForRHR = 12

    /// Map parsed AccessLink records onto NOOP's shared import models.
    ///
    /// - Parameter timeZone: the zone the user's continuous-HR "HH:MM:SS" and activity days are local to.
    ///   AccessLink does not say; the app passes the phone's current zone (the same zone Polar Flow uses).
    public static func normalize(sleeps: [PolarSleepNight],
                                 recharges: [PolarNightlyRecharge],
                                 activities: [PolarDailyActivity],
                                 continuousHR: [PolarContinuousHRDay],
                                 cardioLoads: [PolarCardioLoad],
                                 timeZone: TimeZone) -> PolarNormalized {
        var out = PolarNormalized()
        var byDay: [String: WearableDailyRow] = [:]
        func row(_ day: String) -> WearableDailyRow { byDay[day] ?? WearableDailyRow(day: day) }

        // Nightly Recharge, indexed by wake day so the sleep pass can join it.
        var nr: [String: PolarNightlyRecharge] = [:]
        for r in recharges { nr[r.date] = r }

        // 1. Sleep. Polar reports one main sleep per `date`; if a duplicate day arrives, the longer night
        //    wins (a whole-unit choice, never a field-by-field blend of two nights).
        var bestNight: [String: PolarSleepNight] = [:]
        for n in sleeps {
            if let cur = bestNight[n.date], cur.end.timeIntervalSince(cur.start) >= n.end.timeIntervalSince(n.start) { continue }
            bestNight[n.date] = n
        }
        for n in bestNight.values.sorted(by: { $0.start < $1.start }) {
            let recharge = nr[n.date]
            let hr = PolarTimeAnchoring.anchor(n.heartRateSamples.map { ($0.time, $0.bpm) },
                                              start: n.start, utcOffsetSeconds: n.utcOffsetSeconds)
                .map { PolarHRPoint(ts: Int($0.0.timeIntervalSince1970), bpm: $0.1) }
            let bpms = hr.map(\.bpm)

            func minutes(_ s: Int?) -> Double? { s.map { Double($0) / 60.0 } }
            // Total sleep = every classified-or-not SLEEP epoch: light + deep + REM + unrecognized.
            // Interruptions are wake; they are not sleep.
            let parts = [n.lightSleepSec, n.deepSleepSec, n.remSleepSec, n.unrecognizedSleepSec]
            let totalSec: Int? = parts.allSatisfy({ $0 == nil }) ? nil : parts.reduce(0) { $0 + ($1 ?? 0) }
            let inBedSec = n.end.timeIntervalSince(n.start)
            // Efficiency as a 0–1 FRACTION (NOOP's convention everywhere, see OuraApiParser).
            let efficiency = totalSec.flatMap { t in inBedSec > 0 ? min(1.0, Double(t) / inBedSec) : nil }

            let lowest: Int? = bpms.count >= minSleepHRSamplesForRHR ? bpms.min() : nil
            let restingHr: Int?
            let rhrSource: PolarRestingHRSource?
            if let l = lowest { restingHr = l; rhrSource = .sleepLowest5Min }
            else if let a = recharge?.heartRateAvg { restingHr = a; rhrSource = .nightlyRechargeAverage }
            else { restingHr = nil; rhrSource = nil }

            let session = WearableSleepSession(
                start: n.start, end: n.end,
                deepMin: minutes(n.deepSleepSec),
                lightMin: minutes(n.lightSleepSec),
                remMin: minutes(n.remSleepSec),
                awakeMin: minutes(n.totalInterruptionSec),
                totalSleepMin: minutes(totalSec),
                efficiencyPct: efficiency,
                avgHr: bpms.isEmpty ? nil : Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded()),
                lowestHr: lowest,
                avgHrvMs: recharge?.hrvRmssdMs,
                respRateBpm: recharge?.breathingRateAvg,
                sleepScore: n.sleepScore,                  // Polar's own score — reference only
                stages: PolarHypnogram.decode(n))
            out.sleepPeriods.append(PolarSleepPeriod(session: session, hr: hr))

            var r = row(n.date)
            r.totalSleepMin = session.totalSleepMin
            r.deepMin = session.deepMin
            r.lightMin = session.lightMin
            r.remMin = session.remMin
            r.awakeMin = session.awakeMin
            r.efficiencyPct = session.efficiencyPct
            r.restingHr = restingHr
            r.avgHrvMs = recharge?.hrvRmssdMs
            r.respRateBpm = recharge?.breathingRateAvg
            r.sleepScore = n.sleepScore
            byDay[n.date] = r

            if let s = rhrSource { out.extras.append(.init(day: n.date, key: "polar_rhr_source", value: Double(s.rawValue))) }
            if let v = n.sleepScore { out.extras.append(.init(day: n.date, key: "ref_sleep_score", value: Double(v))) }
            if let v = n.sleepCharge { out.extras.append(.init(day: n.date, key: "ref_polar_sleep_charge", value: Double(v))) }
            if let v = n.continuity { out.extras.append(.init(day: n.date, key: "polar_sleep_continuity", value: v)) }
            if let v = n.sleepCycles { out.extras.append(.init(day: n.date, key: "polar_sleep_cycles", value: Double(v))) }
        }

        // 2. Nightly Recharge on days WITHOUT a sleep record still carries HRV/RHR/resp: keep them, honestly
        //    labelled (RHR from the 4 h mean). Polar's own scores always go to ref_* keys only.
        for r in recharges {
            var d = row(r.date)
            if bestNight[r.date] == nil {
                d.avgHrvMs = r.hrvRmssdMs
                d.respRateBpm = r.breathingRateAvg
                if let a = r.heartRateAvg {
                    d.restingHr = a
                    out.extras.append(.init(day: r.date, key: "polar_rhr_source",
                                            value: Double(PolarRestingHRSource.nightlyRechargeAverage.rawValue)))
                }
                byDay[r.date] = d
            }
            if let v = r.ansCharge { out.extras.append(.init(day: r.date, key: "ref_polar_ans_charge", value: v)) }
            if let v = r.ansChargeStatus { out.extras.append(.init(day: r.date, key: "ref_polar_ans_charge_status", value: Double(v))) }
            if let v = r.nightlyRechargeStatus { out.extras.append(.init(day: r.date, key: "ref_polar_nightly_recharge", value: Double(v))) }
            if let v = r.heartRateAvg { out.extras.append(.init(day: r.date, key: "polar_nr_hr_avg", value: Double(v))) }
            if let v = r.beatToBeatAvgMs { out.extras.append(.init(day: r.date, key: "polar_nr_rr_avg_ms", value: v)) }
        }

        // 3. Activity → steps / kcal / distance on the activity's own day.
        for a in activities {
            var d = row(a.date)
            d.steps = a.steps
            d.activeKcal = a.activeCalories
            d.totalKcal = a.calories
            d.distanceM = a.distanceM
            byDay[a.date] = d
            if let s = a.activeDurationSec { out.extras.append(.init(day: a.date, key: "polar_active_min", value: s / 60.0)) }
        }

        // 4. Continuous HR → hrSample. "HH:MM:SS" is local to `date` in `timeZone` (DST-correct via Calendar).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        for day in continuousHR {
            let p = day.date.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { continue }
            for s in day.samples {
                // Wall-clock components, NOT "midnight + N seconds": on a DST day those differ by an hour.
                let c = DateComponents(year: p[0], month: p[1], day: p[2], hour: s.secondsOfDay / 3600,
                                       minute: (s.secondsOfDay % 3600) / 60, second: s.secondsOfDay % 60)
                guard let t = cal.date(from: c) else { continue }
                out.heartRate.append(PolarHRPoint(ts: Int(t.timeIntervalSince1970), bpm: s.bpm))
            }
        }
        out.heartRate.sort { $0.ts < $1.ts }

        // 5. Cardio load — Polar's TRIMP model. Reference only; never NOOP Effort.
        for c in cardioLoads {
            if let v = c.cardioLoad { out.extras.append(.init(day: c.date, key: "ref_polar_cardio_load", value: v)) }
            if let v = c.strain { out.extras.append(.init(day: c.date, key: "ref_polar_cardio_strain", value: v)) }
            if let v = c.tolerance { out.extras.append(.init(day: c.date, key: "ref_polar_cardio_tolerance", value: v)) }
            if let v = c.ratio { out.extras.append(.init(day: c.date, key: "ref_polar_cardio_load_ratio", value: v)) }
        }

        out.days = byDay.values.sorted { $0.day < $1.day }
        out.extras.sort { ($0.day, $0.key) < ($1.day, $1.key) }
        return out
    }

    static func localMidnight(_ day: String, calendar: Calendar) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
