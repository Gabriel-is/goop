import Foundation
import StrandImport

// MARK: - Anchoring Polar's zone-less "HH:MM" maps to real instants
//
// AccessLink's per-night maps (`hypnogram`, `heart_rate_samples`, `hrv_samples`) are keyed by LOCAL
// wall-clock "HH:MM" with no date and no zone, and a night crosses midnight. Each key is anchored to the
// night's `sleep_start_time` (which does carry an offset): the first key at or after onset (allowing a
// few minutes of slack) is on onset's local date, and every time the clock goes backwards we have crossed
// midnight. A JSON object's key order is lost on decode, so the parser hands us keys sorted by clock time;
// we rotate that list so it starts at onset before walking it.

public enum PolarTimeAnchoring {

    /// Slack before `sleep_start_time` for the first key. Polar's maps are minute-truncated, so the first
    /// key can sit up to a minute before the exact onset second; 10 min absorbs any rounding.
    static let onsetSlackSeconds = 10 * 60

    /// Anchor clock-sorted `"HH:MM"` keys to absolute instants for a night that starts at `start`
    /// (local offset `utcOffsetSeconds`). Keys that would land outside `[start − slack, start + 24 h)` are
    /// dropped. Returns pairs in chronological order.
    public static func anchor<T>(_ keyed: [(String, T)], start: Date, utcOffsetSeconds: Int) -> [(Date, T)] {
        guard !keyed.isEmpty else { return [] }
        let startLocalSec = Int(start.timeIntervalSince1970) + utcOffsetSeconds
        let startSecOfDay = ((startLocalSec % 86_400) + 86_400) % 86_400
        let localMidnightUTC = Int(start.timeIntervalSince1970) - startSecOfDay   // onset's local midnight, as UTC
        let threshold = startSecOfDay - onsetSlackSeconds

        // Rotate: keys at/after (onset − slack) come first (same local date), the rest are after midnight.
        let secs = keyed.map { AccessLinkParser.secondsOfDay($0.0) ?? 0 }
        var order = Array(keyed.indices.filter { secs[$0] >= threshold })
        order += keyed.indices.filter { secs[$0] < threshold }

        var out: [(Date, T)] = []
        var dayOffset = 0
        var prev = -1
        for i in order {
            let s = secs[i]
            if prev >= 0 && s < prev { dayOffset += 1 }
            // A threshold below zero (onset just after midnight) means everything is on onset's date.
            if prev < 0 && threshold >= 0 && s < threshold { dayOffset = 1 }
            prev = s
            let ts = localMidnightUTC + dayOffset * 86_400 + s
            let d = Date(timeIntervalSince1970: TimeInterval(ts))
            guard d >= start.addingTimeInterval(-TimeInterval(onsetSlackSeconds)),
                  d < start.addingTimeInterval(24 * 3600) else { continue }
            out.append((d, keyed[i].1))
        }
        return out
    }
}

// MARK: - Hypnogram decode

public enum PolarHypnogram {

    /// Turn a night's stage change-points into contiguous `WearableSleepStageInterval`s.
    ///
    /// - Each point starts a stage that lasts until the next point, or until `sleep_end_time` for the last.
    /// - Adjacent points with the same NOOP stage merge (Polar's two light-NREM codes both become "light").
    /// - `unknown` (code 5) leaves a GAP: NOOP never invents a stage.
    /// - Segments are clamped to `[start, end]`; zero-length segments are dropped.
    public static func decode(_ night: PolarSleepNight) -> [WearableSleepStageInterval] {
        let points = PolarTimeAnchoring.anchor(night.hypnogram.map { ($0.time, $0.stage) },
                                               start: night.start, utcOffsetSeconds: night.utcOffsetSeconds)
        guard !points.isEmpty else { return [] }
        var out: [WearableSleepStageInterval] = []
        for (i, (t, stage)) in points.enumerated() {
            let segStart = max(t, night.start)
            let segEnd = min(i + 1 < points.count ? points[i + 1].0 : night.end, night.end)
            guard segEnd > segStart, let name = stage.noopStage else { continue }
            if var last = out.last, last.stage == name, last.end == segStart {
                last.end = segEnd
                out[out.count - 1] = last
            } else {
                out.append(WearableSleepStageInterval(stage: name, start: segStart, end: segEnd))
            }
        }
        return out
    }
}
