import XCTest
import StrandImport
@testable import PolarAccessLink

final class MapperAndHypnogramTests: XCTestCase {

    private let cdt = -5 * 3600
    private func iso(_ s: String) -> Date { AccessLinkParser.isoWithOffset(s)!.0 }

    private func night(start: String, end: String, hyp: [(String, Int)], hr: [(String, Int)] = []) -> PolarSleepNight {
        var n = PolarSleepNight(date: String(end.prefix(10)), start: iso(start), end: iso(end), utcOffsetSeconds: cdt)
        n.hypnogram = hyp.sorted { AccessLinkParser.secondsOfDay($0.0)! < AccessLinkParser.secondsOfDay($1.0)! }
            .map { (time: $0.0, stage: PolarSleepStage(rawValue: $0.1)!) }
        n.heartRateSamples = hr.sorted { AccessLinkParser.secondsOfDay($0.0)! < AccessLinkParser.secondsOfDay($1.0)! }
            .map { (time: $0.0, bpm: $0.1) }
        return n
    }

    // MARK: anchoring

    func testAnchoringWrapsMidnight() {
        let start = iso("2026-10-27T22:50:00.000-05:00")
        // Clock-sorted input: post-midnight keys sort FIRST and must be moved after the pre-midnight ones.
        let anchored = PolarTimeAnchoring.anchor([("00:10", 1), ("06:00", 2), ("22:50", 3), ("23:30", 4)],
                                                 start: start, utcOffsetSeconds: cdt)
        XCTAssertEqual(anchored.map(\.1), [3, 4, 1, 2])
        XCTAssertEqual(anchored[0].0, start)
        XCTAssertEqual(anchored[2].0, iso("2026-10-28T00:10:00.000-05:00"))
        XCTAssertEqual(anchored[3].0, iso("2026-10-28T06:00:00.000-05:00"))
    }

    func testAnchoringOnsetAfterMidnight() {
        let start = iso("2026-10-24T01:12:00.000-05:00")
        let anchored = PolarTimeAnchoring.anchor([("01:12", 1), ("03:00", 2), ("06:29", 3)], start: start, utcOffsetSeconds: cdt)
        XCTAssertEqual(anchored.map(\.0), [start, iso("2026-10-24T03:00:00.000-05:00"), iso("2026-10-24T06:29:00.000-05:00")])
    }

    // MARK: hypnogram

    func testHypnogramMergesLightCodesAndLeavesUnknownGap() {
        let n = night(start: "2026-10-27T23:00:00.000-05:00", end: "2026-10-28T01:00:00.000-05:00",
                      hyp: [("23:00", 2), ("23:10", 3), ("23:30", 4), ("00:10", 5), ("00:20", 1), ("00:50", 0)])
        let s = PolarHypnogram.decode(n)
        XCTAssertEqual(s.map(\.stage), ["light", "deep", "rem", "wake"])
        XCTAssertEqual(s[0].start, n.start)
        XCTAssertEqual(s[0].end, iso("2026-10-27T23:30:00.000-05:00"), "lighter+light NREM merge into one light segment")
        XCTAssertEqual(s[1].end, iso("2026-10-28T00:10:00.000-05:00"))
        XCTAssertEqual(s[2].start, iso("2026-10-28T00:20:00.000-05:00"), "unknown epoch is a gap, not a guessed stage")
        XCTAssertEqual(s[3].end, n.end, "last stage runs to sleep_end_time")
    }

    func testFixtureHypnogramsCoverTheNight() throws {
        let sleeps = try AccessLinkParser.sleepNights(XCTUnwrap(PolarFixtures.data("sleep")))
        for n in sleeps {
            let s = PolarHypnogram.decode(n)
            XCTAssertFalse(s.isEmpty, n.date)
            XCTAssertEqual(s.first?.start, n.start, n.date)
            XCTAssertEqual(s.last?.end, n.end, n.date)
            for (a, b) in zip(s, s.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start, "segments ordered, non-overlapping") }
            // Stage totals from the hypnogram agree with Polar's own second counts (within a minute per segment).
            let deep = s.filter { $0.stage == "deep" }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            XCTAssertEqual(deep, Double(n.deepSleepSec ?? 0), accuracy: 60, n.date)
        }
    }

    // MARK: mapper

    func testMapperJoinsRechargeAndPicksSleepLowestAsRHR() {
        let hr = (0..<24).map { i -> (String, Int) in
            let t = 23 * 60 + i * 5
            return (String(format: "%02d:%02d", (t / 60) % 24, t % 60), i == 10 ? 48 : 55)
        }
        let n = night(start: "2026-10-27T23:00:00.000-05:00", end: "2026-10-28T07:00:00.000-05:00",
                      hyp: [("23:00", 3)], hr: hr)
        var withStages = n
        withStages.lightSleepSec = 4 * 3600; withStages.deepSleepSec = 3600; withStages.remSleepSec = 5400
        withStages.unrecognizedSleepSec = 0; withStages.totalInterruptionSec = 1800; withStages.sleepScore = 81
        var r = PolarNightlyRecharge(date: "2026-10-28")
        r.hrvRmssdMs = 62; r.heartRateAvg = 57; r.breathingRateAvg = 14.1; r.ansCharge = 3.2; r.nightlyRechargeStatus = 5

        let out = PolarAccessLinkMapper.normalize(sleeps: [withStages], recharges: [r], activities: [], continuousHR: [],
                                                  cardioLoads: [], timeZone: TimeZone(secondsFromGMT: cdt)!)
        let day = out.days.first { $0.day == "2026-10-28" }!
        XCTAssertEqual(day.avgHrvMs, 62)
        XCTAssertEqual(day.restingHr, 48, "lowest 5-min sleep average, not the 4 h NR mean")
        XCTAssertEqual(day.respRateBpm, 14.1)
        XCTAssertEqual(day.totalSleepMin, 390)
        XCTAssertEqual(day.efficiencyPct!, 390.0 / 480.0, accuracy: 1e-9, "efficiency is a 0–1 fraction")
        XCTAssertEqual(day.awakeMin, 30)
        XCTAssertEqual(out.sleepPeriods.first?.hr.count, 24)
        // Polar's own scores land ONLY on ref_* keys.
        let keys = Set(out.extras.map(\.key))
        XCTAssertTrue(keys.contains("ref_polar_ans_charge"))
        XCTAssertTrue(keys.contains("ref_polar_nightly_recharge"))
        XCTAssertTrue(keys.contains("ref_sleep_score"))
        XCTAssertEqual(out.extras.first { $0.key == "polar_rhr_source" }?.value, 1)
        XCTAssertFalse(keys.contains("recovery"))
        XCTAssertFalse(keys.contains("strain"))
    }

    func testRHRFallsBackToNightlyRechargeWhenTooFewSamples() {
        let n = night(start: "2026-10-27T23:00:00.000-05:00", end: "2026-10-28T07:00:00.000-05:00",
                      hyp: [("23:00", 3)], hr: [("23:00", 40), ("23:05", 41)])
        var r = PolarNightlyRecharge(date: "2026-10-28"); r.heartRateAvg = 57; r.hrvRmssdMs = 50
        let out = PolarAccessLinkMapper.normalize(sleeps: [n], recharges: [r], activities: [], continuousHR: [],
                                                  cardioLoads: [], timeZone: TimeZone(secondsFromGMT: cdt)!)
        XCTAssertEqual(out.days.first?.restingHr, 57)
        XCTAssertEqual(out.extras.first { $0.key == "polar_rhr_source" }?.value, 2)
    }

    func testRechargeWithoutSleepStillCarriesHRV() {
        var r = PolarNightlyRecharge(date: "2026-10-28"); r.hrvRmssdMs = 44
        let out = PolarAccessLinkMapper.normalize(sleeps: [], recharges: [r], activities: [], continuousHR: [],
                                                  cardioLoads: [], timeZone: .current)
        XCTAssertEqual(out.days.first?.avgHrvMs, 44)
        XCTAssertNil(out.days.first?.restingHr)
    }

    func testContinuousHRUsesLocalZoneAcrossDST() {
        // 2026-11-01 is the US DST fall-back day in America/Chicago: 01:30 happens twice; the day has 25 h.
        let chicago = TimeZone(identifier: "America/Chicago")!
        let day = PolarContinuousHRDay(date: "2026-11-01", samples: [.init(secondsOfDay: 0, bpm: 60),
                                                                     .init(secondsOfDay: 12 * 3600, bpm: 70)])
        let out = PolarAccessLinkMapper.normalize(sleeps: [], recharges: [], activities: [], continuousHR: [day],
                                                  cardioLoads: [], timeZone: chicago)
        XCTAssertEqual(out.heartRate.map(\.ts), [1_793_509_200, 1_793_509_200 + 12 * 3600 + 3600])
    }
}
