import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandImport

/// #155 — Apple-Health-free export for sideloaded iOS installs. A free (7-day) signing identity
/// can't carry the HealthKit entitlement, so HealthKitBridge never runs for sideloaders. Instead,
/// NOOP drops a plain-text file at Documents/noop_sync.txt (exposed to Files/Shortcuts via
/// UIFileSharingEnabled) and the reporter's pre-built Siri Shortcut reads it and logs the rows into
/// Apple Health. One line per 15-minute window — `HR,HRV,Steps,yyyy-MM-dd HH:mm` — en_US_POSIX,
/// LOCAL time (the Shortcut parses dates in the device zone), empty fields keep their commas so
/// column positions are fixed, NO header.
///
/// Reads ONLY the strap source (`repo.deviceId`) — never `apple-health` (a Shortcut-logged value
/// must not round-trip back in on the next HealthKit/export import) and never the `-noop` computed
/// source.
///
/// Mirrors CsvExport's shape: a platform-neutral enum in Strand/Data/ that compiles into the macOS
/// target too (no UIKit). The iOS-only pieces live in StrandiOS/ — the scenePhase trigger in
/// StrandiOSApp and the opt-in toggle in ShortcutExportSettingsView.
enum ShortcutHealthExport {

    /// Opt-in gate (default OFF — every automation in NOOP is optional).
    static let enabledKey = "noop.shortcutSync.enabled"
    /// Exclusive end of the last successfully written coverage, unix seconds. Advances ONLY after
    /// a successful file write, so a failed export retries the same span next time.
    static let watermarkKey = "noop.shortcutSync.lastExportTs"
    static let fileName = "noop_sync.txt"
    /// Aggregation window: 15 minutes, epoch-aligned — the same boundaries hrBuckets(900) groups by.
    static let windowSeconds = 900
    /// Catch-up bound: never reach further back than 7 days, even on a first run or after a long gap.
    static let lookbackSeconds = 7 * 86_400
    /// Reboot/reset guard for the cumulative u16 step counter — same cap as AnalyticsEngine's
    /// daily-steps math (a reset is byte-indistinguishable from a wrap; a huge corrected delta
    /// is a reset, not steps).
    static let maxStepDelta = 30_000
    /// Row cap for the RR/step reads. 7 days of ~1 Hz RR is ~600k rows; this never truncates a
    /// real window.
    static let readLimit = 2_000_000

    enum Outcome: Equatable {
        case written(lines: Int)
        case nothingNew
        case failure(String)
    }

    /// One 15-minute export window. All three values optional — a window is emitted iff ≥1 is set.
    struct Window: Equatable {
        let start: Int          // unix seconds, windowSeconds-aligned
        var hr: Int? = nil      // mean bpm over the window, rounded
        var hrvMs: Double? = nil // RMSSD over the window's RR intervals (1 decimal at render)
        var steps: Int? = nil   // wrap-corrected positive-delta sum
    }

    // MARK: - Entry points

    /// Background-transition hook (StrandiOSApp scenePhase). No-op until the user opts in.
    @MainActor
    static func writeIfEnabled(repo: Repository) async {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        _ = await writeNow(repo: repo)
    }

    @MainActor
    @discardableResult
    static func writeNow(repo: Repository) async -> Outcome {
        guard let store = await repo.storeHandle() else {
            return .failure("Couldn't open the local store.")
        }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return .failure("No Documents directory.")
        }
        let outcome = await export(source: store, deviceId: repo.deviceId, now: Date(),
                                   defaults: .standard, directory: docs, timeZone: .current)
        // GOOP: the sleep half rides the same opt-in and the same trigger, in its own file, so the
        // existing HR/HRV/steps file and the Shortcut that reads it are untouched. Its outcome is not
        // folded into the return value, which keeps this function's contract as it was.
        _ = await exportSleep(store: store, deviceId: repo.deviceId, now: Date(),
                              defaults: .standard, directory: docs, timeZone: .current)
        return outcome
    }

    // MARK: - GOOP: sleep (noop_sleep.txt)

    /// The sleep file the companion Shortcut reads. One line per Sleep Analysis sample; format in
    /// `ShortcutSleepExport` (StrandImport), where the selection and rendering are unit-tested.
    static let sleepFileName = "noop_sleep.txt"
    /// Unix seconds: sleep intervals starting before this were already exported. Advances only after a
    /// successful write, and never past a night that may still be recording.
    static let sleepWatermarkKey = "noop.shortcutSync.lastSleepTs"

    /// Write the closed nights that are new since the watermark, built from the same merged-night plan
    /// the HealthKit write-back uses (`HealthKitBridge.writeSleep`): computed sessions first, imported
    /// rows overriding on a `startTs` collision, bridged with `SleepStageTotals.bridgedNightGroups`, and
    /// a night still being recorded held back by `HealthWriteback.nightIsStillOpen`. The file is fully
    /// replaced on every run, empty when nothing is new, because the Shortcut has no dedup.
    @discardableResult
    static func exportSleep(store: WhoopStore, deviceId: String, now: Date,
                            defaults: UserDefaults, directory: URL, timeZone: TimeZone) async -> Outcome {
        let nowTs = Int(now.timeIntervalSince1970)
        let mark = max(defaults.integer(forKey: sleepWatermarkKey), nowTs - lookbackSeconds)
        // Read back two extra days so a night that straddles the watermark still merges whole; the
        // watermark, not the read window, decides what is written.
        let fromTs = mark - 2 * 86_400
        let url = directory.appendingPathComponent(sleepFileName)
        do {
            let computed = try await store.sleepSessions(deviceId: deviceId + "-noop", from: fromTs, to: nowTs, limit: 200)
            let imported = try await store.sleepSessions(deviceId: deviceId, from: fromTs, to: nowTs, limit: 200)
            var byStart: [Int: CachedSleepSession] = [:]
            for s in computed { byStart[s.startTs] = s }
            for s in imported { byStart[s.startTs] = s }
            let sessions = byStart.keys.sorted().compactMap { byStart[$0] }
            let newestHeartRateTs = (try? await store.hrFingerprint(deviceId: deviceId, from: nowTs - 2 * 86_400,
                                                                    to: nowTs).maxTs) ?? 0
            let open = Set(computed.filter {
                HealthWriteback.nightIsStillOpen(endTs: $0.endTs, newestHeartRateTs: newestHeartRateTs, now: nowTs)
            }.map(\.startTs))
            let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
            let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: timeZone.secondsFromGMT(for: now))
                .map { g in
                    g.indices.map { i -> HealthWriteback.SleepFragment in
                        let s = sessions[i]
                        return .init(startTs: s.startTs, effectiveStartTs: s.effectiveStartTs,
                                     endTs: s.endTs, stagesJSON: s.stagesJSON)
                    }
                }
            let plan = ShortcutSleepExport.plan(entries: HealthWriteback.mergedSleepPlan(groups: groups),
                                                watermark: mark, openKeyStarts: open)
            try Data(ShortcutSleepExport.render(plan.rows, timeZone: timeZone).utf8).write(to: url, options: .atomic)
            defaults.set(plan.watermark, forKey: sleepWatermarkKey)   // only after the write landed
            return plan.rows.isEmpty ? .nothingNew : .written(lines: plan.rows.count)
        } catch {
            return .failure("Shortcut sleep export failed: \(error.localizedDescription)")
        }
    }

    /// Injectable core — store reads behind ShortcutExportReads, clock/defaults/destination/zone as
    /// parameters — so the watermark and file semantics are unit-testable without a live DB.
    @discardableResult
    static func export(source: ShortcutExportReads, deviceId: String, now: Date,
                       defaults: UserDefaults, directory: URL, timeZone: TimeZone) async -> Outcome {
        let nowTs = Int(now.timeIntervalSince1970)
        let span = coverageSpan(nowTs: nowTs, watermark: defaults.integer(forKey: watermarkKey))
        guard span.from < span.end else {
            // Nothing new — TRUNCATE the file rather than leaving the previous rows behind. The
            // Shortcut has no dedup and its automation fires on every app close, while most closes
            // complete no new 15-min window: a stale file would be re-imported into Apple Health on
            // every run (#167). An empty file imports nothing. (Trade-off, by design: rows the
            // Shortcut never read before the next truncate are skipped — strictly-differential
            // beats duplicating; resetWatermark() re-emits the 7-day window as the escape hatch.)
            try? Data().write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return .nothingNew
        }
        do {
            let hr = try await source.hrBuckets(deviceId: deviceId, from: span.from,
                                                to: span.end - 1, bucketSeconds: windowSeconds)
            let rr = try await source.rrIntervals(deviceId: deviceId, from: span.from,
                                                  to: span.end - 1, limit: readLimit)
            let steps = try await source.stepSamples(deviceId: deviceId, from: span.from,
                                                     to: span.end - 1, limit: readLimit)
            let windows = aggregate(hr: hr, rr: rr, steps: steps, end: span.end)
            // Full-file replace even when 0 windows: the Shortcut has no dedup, so stale lines left
            // behind would be double-logged on its next run.
            try Data(render(windows, timeZone: timeZone).utf8)
                .write(to: directory.appendingPathComponent(fileName), options: .atomic)
            defaults.set(span.end, forKey: watermarkKey)   // only after the write landed
            return .written(lines: windows.count)
        } catch {
            return .failure("Shortcut export failed: \(error.localizedDescription)")
        }
    }

    /// Drop the watermark so the next export re-emits the full 7-day window (e.g. after the user
    /// rebuilds their Shortcut or clears its Health entries).
    static func resetWatermark(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: watermarkKey)
    }

    // MARK: - Pure logic

    /// Coverage `[from, end)`: `from` = watermark clamped to the 7-day lookback; `end` = the start
    /// of the still-open 15-minute window. The open window is EXCLUDED — exporting it would freeze
    /// a partial value (the watermark advances past it and the window is never revisited).
    static func coverageSpan(nowTs: Int, watermark: Int) -> (from: Int, end: Int) {
        ((max(watermark, nowTs - lookbackSeconds)), (nowTs / windowSeconds) * windowSeconds)
    }

    /// Fold the three streams into windowSeconds-aligned windows below `end`, ascending. Only
    /// windows holding ≥1 value are returned. Callers bound the lower edge at the store query.
    static func aggregate(hr: [HRBucket], rr: [RRInterval], steps: [StepSample], end: Int) -> [Window] {
        var byStart: [Int: Window] = [:]
        func update(_ start: Int, _ mutate: (inout Window) -> Void) {
            var w = byStart[start] ?? Window(start: start)
            mutate(&w)
            byStart[start] = w
        }
        func windowStart(_ ts: Int) -> Int { (ts / windowSeconds) * windowSeconds }

        // HR — hrBuckets(900) already keys by floor(ts/900)*900, i.e. exactly our window starts.
        for b in hr where b.ts < end {
            update(b.ts) { $0.hr = Int(b.bpm.rounded()) }
        }

        // HRV — rolling RMSSD per window via the shared analyzer (Task Force RMSSD over Malik-cleaned
        // NN intervals). nil rmssd (< 20 clean beats in the window) leaves the field empty.
        var rrByWindow: [Int: [Double]] = [:]
        for s in rr.sortedByTsStable() where s.ts < end {
            rrByWindow[windowStart(s.ts), default: []].append(Double(s.rrMs))
        }
        for (start, values) in rrByWindow {
            if let rmssd = HRVAnalyzer.analyze(rawRR: values).rmssd {
                update(start) { $0.hrvMs = rmssd }
            }
        }

        // Steps — the established cumulative-u16 delta math (AnalyticsEngine's @57 daily total):
        // negative delta = u16 wrap → +65536; corrected deltas > maxStepDelta are firmware-reset
        // artifacts → dropped. Each delta lands in the window of the LATER sample (where the
        // increment was observed).
        let sorted = steps.sorted { $0.ts < $1.ts }
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                var delta = sorted[i].counter - sorted[i - 1].counter
                if delta < 0 { delta += 65_536 }  // u16 wraparound
                guard delta >= 1 && delta <= maxStepDelta else { continue }  // drop resets
                let start = windowStart(sorted[i].ts)
                guard start < end else { continue }
                update(start) { $0.steps = ($0.steps ?? 0) + delta }
            }
        }

        return byStart.values.sorted { $0.start < $1.start }
    }

    /// `HR,HRV,Steps,yyyy-MM-dd HH:mm` — empty fields keep their commas; HRV to 1 decimal; the
    /// timestamp is the window START in the given (device-local) zone.
    static func line(_ w: Window, timeZone: TimeZone) -> String {
        let hr = w.hr.map(String.init) ?? ""
        let hrv = w.hrvMs.map { String(format: "%.1f", $0) } ?? ""
        let steps = w.steps.map(String.init) ?? ""
        return "\(hr),\(hrv),\(steps),\(timestamp(w.start, timeZone: timeZone))"
    }

    /// No header, no trailing newline — a trailing "\n" would give the Shortcut's split-by-newline
    /// an empty last row.
    static func render(_ windows: [Window], timeZone: TimeZone) -> String {
        windows.map { line($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    // en_US_POSIX per the project's date contract; the zone is set per call (LOCAL in production,
    // injected in tests). Single shared instance — only ever used from one task at a time.
    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func timestamp(_ ts: Int, timeZone: TimeZone) -> String {
        lineFormatter.timeZone = timeZone
        return lineFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// The three store reads the export needs — a seam so the watermark/windowing logic is testable
/// without a live DB. WhoopStore's own methods match the signatures exactly.
protocol ShortcutExportReads {
    func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket]
    func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval]
    func stepSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [StepSample]
}

extension WhoopStore: ShortcutExportReads {}
