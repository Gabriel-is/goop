import Foundation
import StrandImport
import StrandAnalytics

// MARK: - Polar overnight inputs → NOOP Charge (recovery 0–100)
//
// We do NOT invent a Polar-specific recovery formula and we do NOT relabel Polar's own ANS charge or
// Nightly Recharge status as Charge. NOOP's Charge is "HRV and RHR against your OWN baseline", and for a
// source that only gives nightly aggregates the app already has an engine for that: `WatchRecovery`, run by
// `IntelligenceEngine`'s wearable-import fold for every id in `Repository.wearableImportSources` (where
// "polar-api" is registered). This type calls that same engine, with the same trailing-history rule, so the
// number the package tests and the demo CLI print is the number the app will show.
//
// Full reasoning, including what is and isn't comparable with WHOOP: docs/polar-loop-recovery-mapping.md.

public struct PolarChargeDay: Sendable, Equatable {
    public let day: String
    /// NOOP Charge 0–100, or nil while calibrating (fewer than `WatchRecovery.minBaselineNights` usable
    /// prior nights, or no HRV tonight).
    public let charge: Double?
    public let confidence: ScoreConfidence
    /// The inputs that produced it, for display/debugging.
    public let hrvRmssdMs: Double?
    public let restingHr: Int?
    /// Polar's own numbers for the same night — REFERENCE ONLY, shown side by side, never blended.
    public let polarAnsCharge: Double?
    public let polarNightlyRechargeStatus: Int?
}

public enum PolarRecovery {

    /// Score every day in `days` (any order) exactly as the app's import fold does: each day is scored against
    /// the baseline folded from the EARLIER days' HRV and RHR only, so a day never sees its own value.
    ///
    /// Mirrors `IntelligenceEngine.watchRecoveries(appleRows:)` (app target), which builds the history with
    /// `compactMap` over prior rows. Keep the two in step.
    public static func charge(days: [WearableDailyRow], extras: [PolarDailyExtra] = []) -> [PolarChargeDay] {
        let rows = days.sorted { $0.day < $1.day }
        var ans: [String: Double] = [:], nrs: [String: Int] = [:]
        for e in extras {
            if e.key == "ref_polar_ans_charge" { ans[e.day] = e.value }
            if e.key == "ref_polar_nightly_recharge" { nrs[e.day] = Int(e.value) }
        }
        var out: [PolarChargeDay] = []
        for (i, row) in rows.enumerated() {
            let prior = rows[..<i]
            let res = WatchRecovery.compute(todaySDNN: row.avgHrvMs,
                                            todayRHR: row.restingHr,
                                            sdnnHistory: prior.compactMap { $0.avgHrvMs },
                                            rhrHistory: prior.compactMap { $0.restingHr.map(Double.init) })
            out.append(PolarChargeDay(day: row.day, charge: res.recovery, confidence: res.confidence,
                                      hrvRmssdMs: row.avgHrvMs, restingHr: row.restingHr,
                                      polarAnsCharge: ans[row.day], polarNightlyRechargeStatus: nrs[row.day]))
        }
        return out
    }
}
