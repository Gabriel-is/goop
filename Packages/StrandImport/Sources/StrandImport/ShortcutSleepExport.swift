import Foundation

/// GOOP: sleep for the HealthKit-free Shortcuts export.
///
/// A free (7-day) sideload can't carry the HealthKit entitlement, so `HealthKitBridge` never writes sleep.
/// The existing Shortcuts export (`ShortcutHealthExport`, `noop_sync.txt`) covers HR, HRV and steps only.
/// This is the sleep half: the SAME merged-night plan the HealthKit write-back uses
/// (`HealthWriteback.mergedSleepPlan`), rendered as plain text that a Siri Shortcut can feed to
/// "Log Health Sample → Sleep Analysis" line by line.
///
/// Line format (no header, no trailing newline, en_US_POSIX, device-local time):
///
///     <Value>,<yyyy-MM-dd HH:mm:ss start>,<yyyy-MM-dd HH:mm:ss end>
///
/// `<Value>` is spelled as Shortcuts lists the Sleep Analysis values: `In Bed`, `Asleep`, `Awake`, `Core`,
/// `Deep`, `REM`. Each night is one `In Bed` row followed by its stage rows in time order.
///
/// The Shortcut has no dedup, so every interval is emitted exactly once, behind a watermark: only
/// intervals that START at or after the watermark are written. A night that grows after it was exported
/// (a later fragment bridged onto it) therefore contributes only its new tail, never a second copy of the
/// part already in Health. A night that may still be recording is held back whole, and the watermark
/// never passes it, so it is exported once it closes.
public enum ShortcutSleepExport {

    public struct Row: Equatable {
        public let value: String
        public let start: Int
        public let end: Int
        public init(value: String, start: Int, end: Int) {
            self.value = value; self.start = start; self.end = end
        }
    }

    public static let inBed = "In Bed"

    /// The Shortcuts spelling of each stage.
    public static func value(_ kind: HealthWriteback.StageKind) -> String {
        switch kind {
        case .awake:       return "Awake"
        case .light:       return "Core"
        case .deep:        return "Deep"
        case .rem:         return "REM"
        case .unspecified: return "Asleep"
        }
    }

    /// Choose what to write and where the watermark moves.
    ///
    /// - Parameters:
    ///   - entries: `HealthWriteback.mergedSleepPlan` output.
    ///   - watermark: unix seconds; intervals starting before it were already exported.
    ///   - openKeyStarts: immutable `startTs` of every fragment that may still be recording. An entry
    ///     containing any of them is held back.
    /// - Returns: the rows in time order, and the new watermark (never lower than the old one, and
    ///   never past the start of a held night).
    public static func plan(entries: [HealthWriteback.MergedSleepEntry], watermark: Int,
                            openKeyStarts: Set<Int>) -> (rows: [Row], watermark: Int) {
        var rows: [Row] = []
        var newMark = watermark
        for e in entries.sorted(by: { $0.spanStart < $1.spanStart }) {
            // Stop at the first open night. Emitting anything after it would move the watermark past
            // it, and it could then never be exported without duplicating what came after.
            if e.allKeyStartTs.contains(where: openKeyStarts.contains) { break }
            guard e.spanEnd > watermark else { continue }
            let bedStart = max(e.spanStart, watermark)
            var nightRows: [Row] = []
            for i in e.intervals where i.start >= watermark && i.end > i.start {
                nightRows.append(Row(value: value(i.kind), start: i.start, end: i.end))
            }
            // A night whose new part is only a sliver with no stage intervals has nothing to say.
            guard !nightRows.isEmpty, e.spanEnd > bedStart else { continue }
            rows.append(Row(value: inBed, start: bedStart, end: e.spanEnd))
            rows.append(contentsOf: nightRows)
            newMark = max(newMark, e.spanEnd)
        }
        return (rows, newMark)
    }

    /// Render rows as described above. Uses its own en_US_POSIX formatter (zone injected for tests).
    public static func render(_ rows: [Row], timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func ts(_ t: Int) -> String { f.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }
        return rows.map { "\($0.value),\(ts($0.start)),\(ts($0.end))" }.joined(separator: "\n")
    }
}
