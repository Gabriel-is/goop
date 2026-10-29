import XCTest
@testable import StrandImport

final class ShortcutSleepExportTests: XCTestCase {

    private typealias I = HealthWriteback.StageInterval
    private let utc = TimeZone(identifier: "UTC")!

    private func entry(_ key: Int, _ start: Int, _ end: Int, _ intervals: [I], keys: [Int]? = nil)
        -> HealthWriteback.MergedSleepEntry {
        .init(keyStartTs: key, spanStart: start, spanEnd: end, intervals: intervals, allKeyStartTs: keys ?? [key])
    }

    func testValuesUseShortcutsSpelling() {
        XCTAssertEqual(ShortcutSleepExport.value(.light), "Core")
        XCTAssertEqual(ShortcutSleepExport.value(.deep), "Deep")
        XCTAssertEqual(ShortcutSleepExport.value(.rem), "REM")
        XCTAssertEqual(ShortcutSleepExport.value(.awake), "Awake")
        XCTAssertEqual(ShortcutSleepExport.value(.unspecified), "Asleep")
    }

    func testOneClosedNightIsInBedThenStages() {
        let e = entry(1000, 1000, 4000, [I(start: 1000, end: 2000, kind: .light),
                                         I(start: 2000, end: 3000, kind: .deep),
                                         I(start: 3000, end: 4000, kind: .rem)])
        let p = ShortcutSleepExport.plan(entries: [e], watermark: 0, openKeyStarts: [])
        XCTAssertEqual(p.rows.map(\.value), ["In Bed", "Core", "Deep", "REM"])
        XCTAssertEqual(p.rows.first, .init(value: "In Bed", start: 1000, end: 4000))
        XCTAssertEqual(p.watermark, 4000)
    }

    func testRenderFormat() {
        let rows = [ShortcutSleepExport.Row(value: "In Bed", start: 0, end: 3_661)]
        XCTAssertEqual(ShortcutSleepExport.render(rows, timeZone: utc),
                       "In Bed,1970-01-01 00:00:00,1970-01-01 01:01:01")
        XCTAssertEqual(ShortcutSleepExport.render([], timeZone: utc), "")
    }

    /// Already-exported nights produce nothing: the Shortcut has no dedup.
    func testNothingAtOrBeforeTheWatermarkIsReEmitted() {
        let e = entry(1000, 1000, 4000, [I(start: 1000, end: 4000, kind: .light)])
        let p = ShortcutSleepExport.plan(entries: [e], watermark: 4000, openKeyStarts: [])
        XCTAssertEqual(p.rows, [])
        XCTAssertEqual(p.watermark, 4000)
    }

    /// A night that grew after export (a later fragment bridged on) contributes only its new tail.
    func testAGrownNightEmitsOnlyItsNewTail() {
        let e = entry(1000, 1000, 6000, [I(start: 1000, end: 4000, kind: .light),
                                         I(start: 4000, end: 4500, kind: .awake),
                                         I(start: 4500, end: 6000, kind: .deep)],
                      keys: [1000, 4500])
        let p = ShortcutSleepExport.plan(entries: [e], watermark: 4000, openKeyStarts: [])
        XCTAssertEqual(p.rows, [.init(value: "In Bed", start: 4000, end: 6000),
                                .init(value: "Awake", start: 4000, end: 4500),
                                .init(value: "Deep", start: 4500, end: 6000)])
        XCTAssertEqual(p.watermark, 6000)
    }

    /// An open night is held whole, and nothing after it moves the watermark past it.
    func testAnOpenNightIsHeldAndBlocksTheWatermark() {
        let closed = entry(1000, 1000, 2000, [I(start: 1000, end: 2000, kind: .light)])
        let open = entry(5000, 5000, 6000, [I(start: 5000, end: 6000, kind: .light)])
        let p = ShortcutSleepExport.plan(entries: [open, closed], watermark: 0, openKeyStarts: [5000])
        XCTAssertEqual(p.rows.map(\.start), [1000, 1000])
        XCTAssertEqual(p.watermark, 2000)
        // Once it closes, it goes out exactly once.
        let later = ShortcutSleepExport.plan(entries: [open, closed], watermark: p.watermark, openKeyStarts: [])
        XCTAssertEqual(later.rows.map(\.value), ["In Bed", "Core"])
        XCTAssertEqual(later.watermark, 6000)
    }

    /// The plan feeds straight from the HealthKit write-back's own merged-night plan.
    func testEndToEndFromMergedSleepPlan() {
        let json = #"[{"start":1000,"end":2000,"stage":"light"},{"start":2000,"end":2600,"stage":"rem"}]"#
        let entries = HealthWriteback.mergedSleepPlan(groups: [[
            .init(startTs: 1000, effectiveStartTs: 1000, endTs: 2600, stagesJSON: json)]])
        let p = ShortcutSleepExport.plan(entries: entries, watermark: 0, openKeyStarts: [])
        XCTAssertEqual(ShortcutSleepExport.render(p.rows, timeZone: utc), """
        In Bed,1970-01-01 00:16:40,1970-01-01 00:43:20
        Core,1970-01-01 00:16:40,1970-01-01 00:33:20
        REM,1970-01-01 00:33:20,1970-01-01 00:43:20
        """)
    }
}
