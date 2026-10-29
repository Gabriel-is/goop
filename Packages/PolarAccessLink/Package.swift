// swift-tools-version:5.9
import PackageDescription

// Polar AccessLink v3 → NOOP normalization (GOOP fork). PURE and NETWORK-FREE, like every package under
// Packages/: it parses already-fetched AccessLink JSON, maps it onto StrandImport's shared
// `WearableDailyRow` / `WearableSleepSession` import models, and scores Charge through StrandAnalytics'
// existing `WatchRecovery` (the same engine the app's wearable-import fold runs). The HTTP transport,
// OAuth and Keychain live in the app target (`Strand/Polar/`), behind the `PolarAccessLinkTransport`
// protocol defined here — so the whole sync pipeline is testable on Linux against bundled fixtures.
// See docs/polar-loop-data-sources.md and docs/polar-loop-recovery-mapping.md.
let package = Package(
    name: "PolarAccessLink",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PolarAccessLink", targets: ["PolarAccessLink"]),
        .executable(name: "polar-accesslink-demo", targets: ["polar-accesslink-demo"]),
    ],
    dependencies: [
        .package(path: "../StrandImport"),
        .package(path: "../StrandAnalytics"),
    ],
    targets: [
        .target(
            name: "PolarAccessLink",
            dependencies: ["StrandImport", "StrandAnalytics"],
            // Synthetic, AccessLink-shaped fixtures (Scripts/make_fixtures.py) — the credential-free
            // "fixture mode" the app and the demo CLI run end to end.
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(name: "polar-accesslink-demo", dependencies: ["PolarAccessLink"]),
        .testTarget(name: "PolarAccessLinkTests", dependencies: ["PolarAccessLink", "StrandImport", "StrandAnalytics"]),
    ]
)
