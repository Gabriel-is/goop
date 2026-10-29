import XCTest
import StrandImport
import StrandAnalytics
@testable import PolarAccessLink

final class RecoveryAndPipelineTests: XCTestCase {

    // MARK: recovery mapping

    func testFixtureChargeCalibratesThenScores() async throws {
        let result = try await PolarFixtures.runDemo()
        let charge = PolarRecovery.charge(days: result.normalized.days, extras: result.normalized.extras)
        XCTAssertEqual(charge.count, 14)
        // WatchRecovery needs ≥ 7 accepted PRIOR nights: the first 7 days are honestly "calibrating".
        for c in charge.prefix(WatchRecovery.minBaselineNights) {
            XCTAssertNil(c.charge, c.day)
            XCTAssertEqual(c.confidence, .calibrating, c.day)
        }
        let scored = charge.dropFirst(WatchRecovery.minBaselineNights)
        XCTAssertTrue(scored.allSatisfy { $0.charge != nil })
        for c in scored { XCTAssertTrue((0...100).contains(c.charge!), c.day) }
        // The fixture's bad night (2026-10-24: HRV 34, high HR) scores red; the good last night scores higher.
        let bad = try XCTUnwrap(charge.first { $0.day == "2026-10-24" }?.charge)
        let good = try XCTUnwrap(charge.first { $0.day == "2026-10-28" }?.charge)
        XCTAssertLessThan(bad, 34, "bad night lands in the red band")
        XCTAssertGreaterThan(good, bad + 30)
        // Polar's own numbers ride along for side-by-side display only.
        XCTAssertNotNil(charge.last?.polarAnsCharge)
    }

    func testChargeIsExactlyTheAppsWatchRecoveryEngine() {
        // Parity guard: PolarRecovery must produce what IntelligenceEngine's import fold produces, i.e.
        // WatchRecovery.compute over the prior rows' HRV/RHR. Rebuild that by hand and compare.
        var rows: [WearableDailyRow] = []
        for (i, hrv) in [55.0, 60, 52, 58, 61, 57, 54, 59, 40, 66].enumerated() {
            var r = WearableDailyRow(day: String(format: "2026-10-%02d", 10 + i))
            r.avgHrvMs = hrv; r.restingHr = 50 + (i % 3)
            rows.append(r)
        }
        let ours = PolarRecovery.charge(days: rows.shuffled())
        for (i, row) in rows.enumerated() {
            let expect = WatchRecovery.compute(todaySDNN: row.avgHrvMs, todayRHR: row.restingHr,
                                               sdnnHistory: rows[..<i].compactMap(\.avgHrvMs),
                                               rhrHistory: rows[..<i].compactMap { $0.restingHr.map(Double.init) })
            XCTAssertEqual(ours[i].day, row.day)
            XCTAssertEqual(ours[i].charge, expect.recovery, row.day)
            XCTAssertEqual(ours[i].confidence, expect.confidence, row.day)
        }
    }

    func testMissingHRVNeverFabricatesCharge() {
        var rows: [WearableDailyRow] = (0..<10).map { i in
            var r = WearableDailyRow(day: String(format: "2026-10-%02d", 10 + i)); r.avgHrvMs = 55; r.restingHr = 50; return r
        }
        rows[9].avgHrvMs = nil
        XCTAssertNil(PolarRecovery.charge(days: rows).last?.charge)
    }

    // MARK: pipeline

    func testFixturePipelineEndToEnd() async throws {
        let r = try await PolarFixtures.runDemo()
        XCTAssertEqual(r.window.from, "2026-10-15")
        XCTAssertEqual(r.window.to, "2026-10-28")
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.requestCount, 4 + 14)
        XCTAssertEqual(r.normalized.sleepPeriods.count, 14)
        XCTAssertEqual(r.normalized.days.count, 14)
        XCTAssertEqual(r.normalized.heartRate.count, 14 * 288)
        XCTAssertTrue(r.normalized.days.allSatisfy { $0.avgHrvMs != nil && $0.restingHr != nil && $0.steps != nil })
        XCTAssertTrue(r.normalized.sleepPeriods.allSatisfy { !$0.session.stages.isEmpty })
        XCTAssertEqual(r.raw.count, 4 + 14, "every 200 body is archived verbatim")
        XCTAssertTrue(r.summaryText.hasPrefix("14 nights"))
    }

    private struct StubTransport: PolarAccessLinkTransport {
        let status: [String: Int]
        func get(_ path: String, query: [String: String]) async throws -> PolarHTTPResponse {
            let key = path.hasPrefix("users/continuous-heart-rate/") ? "chr" : path
            if let s = status[key] { return PolarHTTPResponse(status: s, body: Data()) }
            return try await PolarFixtureTransport().get(path, query: query)
        }
    }

    func testUnauthorizedAbortsTheSync() async {
        let p = PolarSyncPipeline(transport: StubTransport(status: ["users/sleep": 401]), timeZone: PolarFixtures.timeZone)
        do { _ = try await p.run(today: PolarFixtures.lastDay, days: 14); XCTFail("expected 401 to throw") }
        catch { XCTAssertEqual(error as? PolarSyncError, .unauthorized) }
    }

    func testForbiddenMeansConsentsMissing() async {
        let p = PolarSyncPipeline(transport: StubTransport(status: ["users/nightly-recharge": 403]), timeZone: PolarFixtures.timeZone)
        do { _ = try await p.run(today: PolarFixtures.lastDay, days: 14); XCTFail("expected 403 to throw") }
        catch { XCTAssertEqual(error as? PolarSyncError, .forbidden) }
    }

    func testServerErrorIsAnHonestPartial() async throws {
        let p = PolarSyncPipeline(transport: StubTransport(status: ["users/cardio-load": 503, "chr": 404]),
                                  timeZone: PolarFixtures.timeZone)
        let r = try await p.run(today: PolarFixtures.lastDay, days: 14)
        XCTAssertEqual(r.failures, ["cardio-load (HTTP 503)"])     // 404 = "no data", not a failure
        XCTAssertEqual(r.normalized.heartRate.count, 0)
        XCTAssertEqual(r.normalized.sleepPeriods.count, 14)
        XCTAssertTrue(r.summaryText.contains("skipped: cardio-load"))
    }

    func testWindowIsClampedTo28Days() {
        let keys = PolarSyncPipeline.dayKeys(endingOn: "2026-03-01", count: 3, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(keys, ["2026-02-27", "2026-02-28", "2026-03-01"])
    }
}
