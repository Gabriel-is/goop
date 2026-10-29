import XCTest
@testable import PolarAccessLink

final class AccessLinkParserTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testFixturesParse() throws {
        let sleeps = try AccessLinkParser.sleepNights(XCTUnwrap(PolarFixtures.data("sleep")))
        let nr = try AccessLinkParser.nightlyRecharges(XCTUnwrap(PolarFixtures.data("nightly-recharge")))
        let act = try AccessLinkParser.activities(XCTUnwrap(PolarFixtures.data("activities")))
        let cl = try AccessLinkParser.cardioLoads(XCTUnwrap(PolarFixtures.data("cardio-load")))
        let chr = try AccessLinkParser.continuousHeartRate(XCTUnwrap(PolarFixtures.data("continuous-heart-rate")))
        XCTAssertEqual(sleeps.count, 14)
        XCTAssertEqual(nr.count, 14)
        XCTAssertEqual(act.count, 14)
        XCTAssertEqual(cl.count, 14)
        XCTAssertEqual(chr.count, 14)
        XCTAssertEqual(chr.first?.samples.count, 288)
        XCTAssertFalse(sleeps[0].hypnogram.isEmpty)
        XCTAssertFalse(sleeps[0].heartRateSamples.isEmpty)
        XCTAssertNotNil(nr[0].hrvRmssdMs)
    }

    func testNightlyRechargeFieldsAndUnits() throws {
        let r = try AccessLinkParser.nightlyRecharges(json("""
        {"recharges":[{"polar_user":"u","date":"2026-10-28","heart_rate_avg":55,"beat_to_beat_avg":1090,
          "heart_rate_variability_avg":61,"breathing_rate_avg":14.3,"nightly_recharge_status":4,
          "ans_charge":2.5,"ans_charge_status":3,"hrv_samples":{"23:20":60,"23:15":58},"breathing_samples":{}}]}
        """))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].date, "2026-10-28")
        XCTAssertEqual(r[0].heartRateAvg, 55)
        XCTAssertEqual(r[0].beatToBeatAvgMs, 1090)
        XCTAssertEqual(r[0].hrvRmssdMs, 61)
        XCTAssertEqual(r[0].breathingRateAvg, 14.3)
        XCTAssertEqual(r[0].nightlyRechargeStatus, 4)
        XCTAssertEqual(r[0].ansCharge, 2.5)
        XCTAssertEqual(r[0].hrvSamples.map(\.time), ["23:15", "23:20"])   // clock-sorted
    }

    func testSingleObjectAndEmptyBodies() throws {
        // The `/{date}` variants return a bare object; 204 returns no body.
        XCTAssertEqual(try AccessLinkParser.nightlyRecharges(json(#"{"date":"2026-10-28","heart_rate_variability_avg":40}"#)).count, 1)
        XCTAssertEqual(try AccessLinkParser.sleepNights(Data()).count, 0)
        XCTAssertEqual(try AccessLinkParser.sleepNights(json("  \n")).count, 0)
        XCTAssertThrowsError(try AccessLinkParser.sleepNights(json("<html>502</html>")))
    }

    func testHostileValuesBecomeNil() throws {
        let r = try AccessLinkParser.nightlyRecharges(json("""
        [{"date":"2026-10-28","heart_rate_avg":true,"heart_rate_variability_avg":1e300,
          "breathing_rate_avg":"NaN","ans_charge":99,"nightly_recharge_status":0}]
        """))
        XCTAssertEqual(r.count, 1)
        XCTAssertNil(r[0].heartRateAvg, "a JSON boolean must not read as 1 bpm")
        XCTAssertNil(r[0].hrvRmssdMs)
        XCTAssertNil(r[0].breathingRateAvg)
        XCTAssertNil(r[0].ansCharge)
        XCTAssertNil(r[0].nightlyRechargeStatus)
    }

    func testBadDatesAndTimesAreSkipped() throws {
        let s = try AccessLinkParser.sleepNights(json("""
        {"nights":[
          {"date":"2026-02-30","sleep_start_time":"2026-02-29T23:00:00.000-05:00","sleep_end_time":"2026-03-01T07:00:00.000-05:00"},
          {"date":"2026-10-28","sleep_start_time":"2026-10-27T23:00:00","sleep_end_time":"2026-10-28T07:00:00"},
          {"date":"2026-10-28","sleep_start_time":"2026-10-28T07:00:00.000-05:00","sleep_end_time":"2026-10-27T23:00:00.000-05:00"},
          {"date":"2026-10-28","sleep_start_time":"2026-10-27T23:00:00.000-05:00","sleep_end_time":"2026-10-28T07:00:00.000-05:00"}
        ]}
        """))
        // invalid calendar date; no offset (zone would be a guess); end before start; the one good night.
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].utcOffsetSeconds, -5 * 3600)
    }

    func testTooLargeIsRejected() {
        let big = Data(count: AccessLinkParser.maxResponseBytes + 1)
        XCTAssertThrowsError(try AccessLinkParser.sleepNights(big)) { e in
            XCTAssertEqual(e as? AccessLinkParserError, .tooLarge(bytes: AccessLinkParser.maxResponseBytes + 1))
        }
    }

    func testActivityDurationsAndDay() throws {
        let a = try AccessLinkParser.activities(json("""
        [{"start_time":"2026-10-28T00:00:00","end_time":"2026-10-28T23:59:59","active_duration":"PT3H11M",
          "calories":2400,"active_calories":520,"steps":10432,"distance_from_steps":7720.5}]
        """))
        XCTAssertEqual(a.first?.date, "2026-10-28")
        XCTAssertEqual(a.first?.steps, 10432)
        XCTAssertEqual(a.first?.activeDurationSec, 3 * 3600 + 11 * 60)
    }

    func testISODurations() {
        XCTAssertEqual(AccessLinkParser.isoDurationSeconds("PT3H11M"), 11460)
        XCTAssertEqual(AccessLinkParser.isoDurationSeconds("PT45M30.5S"), 2730.5)
        XCTAssertEqual(AccessLinkParser.isoDurationSeconds("P1DT2H"), 93600)
        XCTAssertNil(AccessLinkParser.isoDurationSeconds("P1M"))      // months are ambiguous
        XCTAssertNil(AccessLinkParser.isoDurationSeconds("PT"))
        XCTAssertNil(AccessLinkParser.isoDurationSeconds("3H"))
    }

    func testCardioLoadNotAvailableKeepsDayDropsNumbers() throws {
        let c = try AccessLinkParser.cardioLoads(json(#"[{"date":"2026-10-28","cardio_load_status":"LOAD_STATUS_NOT_AVAILABLE","cardio_load":-1}]"#))
        XCTAssertEqual(c, [PolarCardioLoad(date: "2026-10-28")])
    }

    func testOffsetParsing() {
        XCTAssertEqual(AccessLinkParser.offsetSeconds(of: "2026-10-28T07:00:00.000-05:00"), -18000)
        XCTAssertEqual(AccessLinkParser.offsetSeconds(of: "2026-10-28T07:00:00+0530"), 19800)
        XCTAssertEqual(AccessLinkParser.offsetSeconds(of: "2026-10-28T07:00:00Z"), 0)
    }
}
