import Foundation

/// Resolves the `BGTaskScheduler` identifier for one background task, so a re-signed sideload still
/// registers the identifiers its Info.plist actually permits.
///
/// `BGTaskSchedulerPermittedIdentifiers` is expanded at BUILD time to `$(PRODUCT_BUNDLE_IDENTIFIER).<suffix>`.
/// Every scheduler used to derive its identifier at RUNTIME as `Bundle.main.bundleIdentifier + ".<suffix>"`.
/// Those agree in an Xcode build, but AltStore / SideStore make the bundle id unique to the signing team
/// (`com.noopapp.noop` -> `com.noopapp.noop.<TEAMID>`) without rewriting the permitted list, so the derived
/// identifier was never in the list and every background task (re-score, Health write-back, Coach brief,
/// scheduled export, stale-battery check) went inert. `IOSDiagnostics.backgroundTaskIdentityFault` reports
/// exactly that state (#2553); this is the repair for it.
///
/// The move is the same one `WidgetSnapshot.resolveSuiteName` makes for the App Group: read what the
/// signed bundle declares instead of reconstructing it. iOS matches a registration against the permitted
/// list; it does not document any requirement that the identifier start with the running bundle id, so
/// the plist's own `com.noopapp.noop.rescore` should register in a bundle that now runs as
/// `com.noopapp.noop.ABCDE12345`. (GOOP: reasoned from Apple's documented contract; not yet observed on a
/// device. If a device shows otherwise, the fallback below is exactly the previous behaviour.)
///
/// Resolution order, most specific first:
/// 1. `runtimeID.<suffix>` when the plist permits it: an untouched build behaves exactly as before.
/// 2. The single permitted identifier ending in `.<suffix>`: the re-signed case.
/// 3. `runtimeID.<suffix>`, as before: nothing better is known, and the existing diagnostic names it.
enum BackgroundTaskID {

    /// Every suffix the iOS target registers. Must match `BGTaskSchedulerPermittedIdentifiers` in project.yml.
    static let knownSuffixes = ["debugexport", "coachbrief", "healthwriteback", "rescore", "stalebattery"]

    /// The pure decision, testable without a re-signed bundle.
    static func resolve(suffix: String, runtimeID: String?, permitted: [String]) -> String {
        let derived = (runtimeID ?? "com.noopapp.noop") + "." + suffix
        if permitted.contains(derived) { return derived }
        // Dot-anchored so `.rescore` never matches `.prescore`. More than one candidate is ambiguous, and
        // guessing wrong is worse than the old (diagnosed) behaviour, so that falls back too.
        let candidates = permitted.filter { $0.hasSuffix("." + suffix) }
        if candidates.count == 1, let only = candidates.first { return only }
        return derived
    }

    /// The identifier for `suffix` in the running bundle.
    static func identifier(suffix: String, bundle: Bundle = .main) -> String {
        resolve(suffix: suffix,
                runtimeID: bundle.bundleIdentifier,
                permitted: bundle.infoDictionary?["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? [])
    }

    /// Whether every one of `suffixes` resolves to a permitted identifier, so the diagnostics line can tell
    /// "bundle id rewritten but repaired" apart from "will not register".
    static func allPermitted(suffixes: [String], runtimeID: String?, permitted: [String]) -> Bool {
        !permitted.isEmpty && suffixes.allSatisfy {
            permitted.contains(resolve(suffix: $0, runtimeID: runtimeID, permitted: permitted))
        }
    }
}
