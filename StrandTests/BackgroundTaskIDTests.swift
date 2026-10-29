import XCTest
@testable import Strand

/// A re-signed sideload registers the background-task identifiers its Info.plist actually permits.
///
/// AltStore / SideStore append the signing team to the bundle id (`com.noopapp.noop.ABCDE12345`) and leave
/// `BGTaskSchedulerPermittedIdentifiers` as built (`com.noopapp.noop.<suffix>`). Deriving the identifier from
/// the runtime bundle id therefore named something iOS never permitted. `BackgroundTaskID` reads the plist's
/// own entry instead; these pin each branch of that decision. (GOOP, follows #2553)
final class BackgroundTaskIDTests: XCTestCase {

    private let permitted = [
        "com.noopapp.noop.debugexport",
        "com.noopapp.noop.coachbrief",
        "com.noopapp.noop.healthwriteback",
        "com.noopapp.noop.rescore",
        "com.noopapp.noop.stalebattery",
    ]

    func testAnUntouchedBuildKeepsTheDerivedIdentifier() {
        XCTAssertEqual(BackgroundTaskID.resolve(suffix: "rescore", runtimeID: "com.noopapp.noop", permitted: permitted),
                       "com.noopapp.noop.rescore")
    }

    func testATeamSuffixedBundleIdUsesThePlistIdentifier() {
        XCTAssertEqual(BackgroundTaskID.resolve(suffix: "rescore", runtimeID: "com.noopapp.noop.ABCDE12345",
                                                permitted: permitted),
                       "com.noopapp.noop.rescore")
    }

    func testAForkPrefixThatMatchesItsPlistIsUnchanged() {
        XCTAssertEqual(BackgroundTaskID.resolve(suffix: "coachbrief", runtimeID: "com.mine.noop",
                                                permitted: ["com.mine.noop.coachbrief"]),
                       "com.mine.noop.coachbrief")
    }

    /// Dot-anchored: `.rescore` must not match `.prescore`.
    func testASuffixCollisionIsNotAMatch() {
        XCTAssertEqual(BackgroundTaskID.resolve(suffix: "rescore", runtimeID: "x.y",
                                                permitted: ["com.noopapp.noop.prescore"]),
                       "x.y.rescore")
    }

    /// Two candidates are ambiguous; falling back to the old behaviour keeps the existing diagnostic honest.
    func testAmbiguousCandidatesFallBack() {
        XCTAssertEqual(BackgroundTaskID.resolve(suffix: "rescore", runtimeID: "x.y",
                                                permitted: ["a.b.rescore", "c.d.rescore"]),
                       "x.y.rescore")
    }

    func testNoPermittedListFallsBack() {
        XCTAssertEqual(BackgroundTaskID.resolve(suffix: "rescore", runtimeID: nil, permitted: []),
                       "com.noopapp.noop.rescore")
    }

    func testAllPermittedSeparatesRepairedFromBroken() {
        XCTAssertTrue(BackgroundTaskID.allPermitted(suffixes: BackgroundTaskID.knownSuffixes,
                                                    runtimeID: "com.noopapp.noop.ABCDE12345", permitted: permitted))
        XCTAssertFalse(BackgroundTaskID.allPermitted(suffixes: BackgroundTaskID.knownSuffixes,
                                                     runtimeID: "com.noopapp.noop.ABCDE12345",
                                                     permitted: Array(permitted.dropLast())))
        XCTAssertFalse(BackgroundTaskID.allPermitted(suffixes: BackgroundTaskID.knownSuffixes,
                                                     runtimeID: "com.noopapp.noop", permitted: []))
    }
}
