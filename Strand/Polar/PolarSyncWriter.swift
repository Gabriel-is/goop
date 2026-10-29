// GOOP: Polar Loop lane. Compiled ONLY with -DPOLAR_ACCESSLINK (see PolarConfig.xcconfig).
#if POLAR_ACCESSLINK
import Foundation
import WhoopStore
import WhoopProtocol
import StrandImport
import PolarAccessLink

/// Persists a normalized AccessLink sync into the on-device store under `deviceId = "polar-api"` — the Polar
/// sibling of `OuraSyncWriter`, using the same upsert APIs and the same honesty rules:
///  • `DailyMetric.recovery` / `.strain` are ALWAYS nil here. Charge is computed downstream by
///    IntelligenceEngine's wearable-import fold ("polar-api" is in `Repository.wearableImportSources`),
///    from HRV + resting HR against the person's own Polar baseline. Polar's ANS charge / Nightly Recharge /
///    cardio load go only to `ref_*` metricSeries keys.
///  • The source registers as `.cloudImport`, which DayOwnerResolver ranks below any live strap, so it never
///    takes a day the WHOOP covered; on Loop-only days it owns the day.
/// Every upsert is keyed by natural key (day / session start / ts), so re-syncing the 28-day window is idempotent.
enum PolarSyncWriter {
    static let deviceId = "polar-api"

    struct Summary: Equatable { var days = 0, sleeps = 0, hrSamples = 0, metricPoints = 0 }

    @discardableResult
    static func persist(_ n: PolarNormalized, into store: WhoopStore) async throws -> Summary {
        var s = Summary()
        let now = Int(Date().timeIntervalSince1970)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: deviceId, brand: "Polar", model: "Polar Loop (AccessLink)",
            sourceKind: .cloudImport, capabilities: [], status: .paired, addedAt: now, lastSeenAt: now))

        let metrics = n.days.map { d in
            DailyMetric(day: d.day, totalSleepMin: d.totalSleepMin, efficiency: d.efficiencyPct,
                        deepMin: d.deepMin, remMin: d.remMin, lightMin: d.lightMin, disturbances: nil,
                        restingHr: d.restingHr, avgHrv: d.avgHrvMs, recovery: nil, strain: nil,
                        exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil,
                        respRateBpm: d.respRateBpm, steps: d.steps, activeKcalEst: d.activeKcal)
        }
        s.days = try await store.upsertDailyMetrics(metrics, deviceId: deviceId)

        let sessions = n.sleepPeriods.map { p in
            CachedSleepSession(startTs: Int(p.session.start.timeIntervalSince1970),
                               endTs: Int(p.session.end.timeIntervalSince1970),
                               efficiency: p.session.efficiencyPct,
                               restingHr: p.session.lowestHr ?? p.session.avgHr,
                               avgHrv: p.session.avgHrvMs,
                               stagesJSON: stagesJSON(p.session.stages))
        }
        s.sleeps = try await store.upsertSleepSessions(sessions, deviceId: deviceId)

        var hr = n.heartRate.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        for p in n.sleepPeriods { hr.append(contentsOf: p.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) }) }
        if !hr.isEmpty { s.hrSamples = try await store.insert(Streams(hr: hr), deviceId: deviceId).hr }

        let points = n.extras.map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
        s.metricPoints = try await store.upsertMetricSeries(points, deviceId: deviceId)
        return s
    }

    /// Same `[{start,end,stage}]` JSON shape WearableImporter / OuraSyncWriter store.
    private static func stagesJSON(_ stages: [WearableSleepStageInterval]) -> String? {
        guard !stages.isEmpty else { return nil }
        let segs = stages.map { ["start": Int($0.start.timeIntervalSince1970),
                                 "end": Int($0.end.timeIntervalSince1970), "stage": $0.stage] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: segs)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
#endif // POLAR_ACCESSLINK
