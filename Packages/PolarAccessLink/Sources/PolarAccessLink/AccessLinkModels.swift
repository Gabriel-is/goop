import Foundation

// MARK: - Typed views of Polar AccessLink v3 responses
//
// Field names, units and scales follow https://www.polar.com/accesslink-api/ (checked 2026-10-29). Every
// numeric field is OPTIONAL: AccessLink omits fields a device didn't measure, and a value that fails
// the range checks in `AccessLinkParser` becomes nil rather than a fabricated number.

/// One night of Polar **Nightly Recharge** (`GET /v3/users/nightly-recharge`).
/// The averages cover a fixed ~4 h window that starts 30 min after sleep onset (Polar's definition), so the
/// HRV is NOT a whole-night value.
public struct PolarNightlyRecharge: Sendable, Equatable {
    /// Polar's `date` (`YYYY-MM-DD`) — the wake day.
    public var date: String
    /// `heart_rate_avg`, bpm, over the 4 h window.
    public var heartRateAvg: Int?
    /// `beat_to_beat_avg`, ms (mean RR interval over the window).
    public var beatToBeatAvgMs: Double?
    /// `heart_rate_variability_avg`, **ms RMSSD** over the window.
    public var hrvRmssdMs: Double?
    /// `breathing_rate_avg`, breaths/min.
    public var breathingRateAvg: Double?
    /// `nightly_recharge_status` 1–6 (Polar's own score — reference only).
    public var nightlyRechargeStatus: Int?
    /// `ans_charge` −10…+10 (Polar's own ANS score — reference only).
    public var ansCharge: Double?
    /// `ans_charge_status` 1–5 (reference only).
    public var ansChargeStatus: Int?
    /// `hrv_samples` — "HH:MM" → 5-min RMSSD averages, kept sorted by key.
    public var hrvSamples: [(time: String, ms: Double)]

    public init(date: String) { self.date = date; self.hrvSamples = [] }

    public static func == (a: Self, b: Self) -> Bool {
        a.date == b.date && a.heartRateAvg == b.heartRateAvg && a.beatToBeatAvgMs == b.beatToBeatAvgMs
            && a.hrvRmssdMs == b.hrvRmssdMs && a.breathingRateAvg == b.breathingRateAvg
            && a.nightlyRechargeStatus == b.nightlyRechargeStatus && a.ansCharge == b.ansCharge
            && a.ansChargeStatus == b.ansChargeStatus
            && a.hrvSamples.map(\.time) == b.hrvSamples.map(\.time) && a.hrvSamples.map(\.ms) == b.hrvSamples.map(\.ms)
    }
}

/// Polar hypnogram stage codes (AccessLink `hypnogram` values).
public enum PolarSleepStage: Int, Sendable, Equatable {
    case wake = 0, rem = 1, lighterNREM = 2, lightNREM = 3, deepNREM = 4, unknown = 5

    /// NOOP's normalized stage string (`WearableSleepStageInterval.stage`), or nil for `unknown` — an
    /// unknown epoch is left as a gap, never guessed.
    public var noopStage: String? {
        switch self {
        case .wake: return "wake"
        case .rem: return "rem"
        // Polar splits light NREM into "lighter" (≈N1) and "light" (≈N2); NOOP has one light bucket.
        case .lighterNREM, .lightNREM: return "light"
        case .deepNREM: return "deep"
        case .unknown: return nil
        }
    }
}

/// One night of Polar **Sleep Plus Stages** (`GET /v3/users/sleep`).
public struct PolarSleepNight: Sendable, Equatable {
    public var date: String
    public var start: Date
    public var end: Date
    /// UTC offset of `sleep_start_time`, seconds — needed to anchor the "HH:MM" maps.
    public var utcOffsetSeconds: Int
    public var lightSleepSec: Int?
    public var deepSleepSec: Int?
    public var remSleepSec: Int?
    public var unrecognizedSleepSec: Int?
    public var totalInterruptionSec: Int?
    public var continuity: Double?
    public var sleepScore: Int?
    public var sleepCharge: Int?
    public var sleepCycles: Int?
    /// `hypnogram` as stage-change points ("HH:MM" → code), in chronological order of appearance.
    public var hypnogram: [(time: String, stage: PolarSleepStage)]
    /// `heart_rate_samples` ("HH:MM" → bpm, 5-min averages), in chronological order of appearance.
    public var heartRateSamples: [(time: String, bpm: Int)]

    public init(date: String, start: Date, end: Date, utcOffsetSeconds: Int) {
        self.date = date; self.start = start; self.end = end; self.utcOffsetSeconds = utcOffsetSeconds
        self.hypnogram = []; self.heartRateSamples = []
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.date == b.date && a.start == b.start && a.end == b.end && a.utcOffsetSeconds == b.utcOffsetSeconds
            && a.lightSleepSec == b.lightSleepSec && a.deepSleepSec == b.deepSleepSec
            && a.remSleepSec == b.remSleepSec && a.unrecognizedSleepSec == b.unrecognizedSleepSec
            && a.totalInterruptionSec == b.totalInterruptionSec && a.continuity == b.continuity
            && a.sleepScore == b.sleepScore && a.sleepCharge == b.sleepCharge && a.sleepCycles == b.sleepCycles
            && a.hypnogram.map(\.time) == b.hypnogram.map(\.time) && a.hypnogram.map(\.stage) == b.hypnogram.map(\.stage)
            && a.heartRateSamples.map(\.time) == b.heartRateSamples.map(\.time)
            && a.heartRateSamples.map(\.bpm) == b.heartRateSamples.map(\.bpm)
    }
}

/// One day of **continuous heart rate** (`GET /v3/users/continuous-heart-rate/{date}`): 5-min samples whose
/// `sample_time` is a LOCAL wall-clock "HH:MM:SS" with no zone (the caller supplies the zone).
public struct PolarContinuousHRDay: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var secondsOfDay: Int
        public var bpm: Int
    }
    public var date: String
    public var samples: [Sample]
    public init(date: String, samples: [Sample]) { self.date = date; self.samples = samples }
}

/// One day of **daily activity** (`GET /v3/users/activities`). `start_time` is local, no zone.
public struct PolarDailyActivity: Sendable, Equatable {
    public var date: String
    public var steps: Int?
    public var calories: Double?
    public var activeCalories: Double?
    public var distanceM: Double?
    public var activeDurationSec: Double?
    public init(date: String) { self.date = date }
}

/// One day of **cardio load** (`GET /v3/users/cardio-load`). Polar's TRIMP-based load — reference only.
public struct PolarCardioLoad: Sendable, Equatable {
    public var date: String
    public var cardioLoad: Double?
    public var strain: Double?
    public var tolerance: Double?
    public var ratio: Double?
    public init(date: String) { self.date = date }
}
