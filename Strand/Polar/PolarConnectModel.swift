// GOOP: Polar Loop lane. Compiled only with -DPOLAR_ACCESSLINK (on by default in GOOP via the tracked
// Strand/Polar/PolarConfig.xcconfig; delete that line there for a fully offline build).
#if POLAR_ACCESSLINK
import Foundation
import Combine
import AuthenticationServices
import WhoopStore
import PolarAccessLink
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Which band GOOP treats as Gabe's primary wearable. Stored in UserDefaults (`goop.primaryBand`).
///
/// A cloud source can't be the registry's *active* device: `activeDeviceId` drives the live-BLE
/// SourceCoordinator, and an AccessLink source has no radio. Day ownership already does the right thing
/// without a switch: WHOOP owns any day it recorded, and the Loop's `.cloudImport` rows own the days only it
/// covered. So the choice governs what GOOP does for you:
///   • `.polarLoop` — sync AccessLink automatically (at most every 30 min) when the Data Sources screen or the
///     app comes to the foreground (via `PolarAutoSync`), and lead with the Polar card.
///   • `.whoop` — the default. Polar syncs only when you tap.
enum PrimaryBand: String, CaseIterable, Identifiable {
    case whoop, polarLoop
    static let defaultsKey = "goop.primaryBand"
    var id: String { rawValue }
    var label: String { self == .whoop ? "WHOOP" : "Polar Loop" }
    static var current: PrimaryBand {
        PrimaryBand(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .whoop
    }
}

/// One row of the sample-data preview (fixture mode): NOOP Charge next to Polar's own numbers.
struct PolarPreviewRow: Identifiable, Equatable {
    let day: String
    let charge: Double?
    let hrv: Double?
    let rhr: Int?
    let polarAns: Double?
    var id: String { day }
}

/// Drives the Data Sources "Polar Loop" card: connect (OAuth + AccessLink user registration) → sync the last
/// 28 days → honest summary → disconnect; plus a credential-free sample-data preview. Mirrors
/// `OuraConnectModel`, including taking `repo` per call (it is an @EnvironmentObject, unavailable at init).
@MainActor
final class PolarConnectModel: ObservableObject {
    @Published var busy = false
    @Published var statusText: String?
    @Published var isConnected = PolarTokenStore.isConnected
    /// http(s)-redirect fallback: Safari was opened; waiting for the user to paste the address they landed on.
    @Published var awaitingPaste = false
    @Published var preview: [PolarPreviewRow] = []

    private var pendingState: String?
    /// Strong refs for the lifetime of the sign-in sheet (an unretained ASWebAuthenticationSession can vanish).
    private var webSession: ASWebAuthenticationSession?
    private var webContext: PolarWebAuthContext?
    private static let lastSyncKey = "goop.polar.lastSync"
    private static let memberIdKey = "goop.polar.memberId"
    private static let registeredKey = "goop.polar.registered"
    static let autoSyncInterval: TimeInterval = 30 * 60

    var credentials: PolarCredentials? { PolarCredentials.resolved }
    @Published private(set) var isConfigured = PolarCredentials.resolved != nil
    /// True when the client came from the card (so it can be edited/forgotten there); false for xcconfig.
    var credentialsFromKeychain: Bool { PolarCredentials.fromBundle == nil && isConfigured }

    /// Save a client typed into the card. Values are trimmed; nothing is sent anywhere until Connect.
    func saveCredentials(clientId: String, clientSecret: String, redirectURI: String) {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let redirect = t(redirectURI).isEmpty ? PolarCredentials.defaultRedirectURI : t(redirectURI)
        guard !t(clientId).isEmpty, !t(clientSecret).isEmpty, URL(string: redirect)?.scheme != nil else {
            statusText = "Enter the client ID and secret from admin.polaraccesslink.com."; return
        }
        let ok = PolarCredentialStore.save(PolarCredentials(clientId: t(clientId), clientSecret: t(clientSecret), redirectURI: redirect))
        isConfigured = PolarCredentials.resolved != nil
        statusText = ok ? "Polar client saved to the Keychain. Tap Connect Polar." : "Couldn't save to the Keychain."
    }

    func forgetCredentials() {
        PolarCredentialStore.clear()
        isConfigured = PolarCredentials.resolved != nil
        statusText = "Polar client removed from this device."
    }
    var lastSync: Date? {
        let t = UserDefaults.standard.double(forKey: Self.lastSyncKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: Connect

    func connect(repo: Repository) {
        guard let creds = credentials else { statusText = PolarError.notConfigured.errorDescription; return }
        let state = UUID().uuidString
        pendingState = state
        let url = PolarOAuth.authorizeURL(creds, state: state)
        if creds.usesCustomScheme {
            busy = true; statusText = "Opening Polar sign-in…"
            Task {
                do {
                    let callback = try await webAuth(url: url, scheme: URL(string: creds.redirectURI)?.scheme)
                    try await finishConnect(callback: callback.absoluteString, creds: creds, repo: repo)
                } catch { fail(error) }
            }
        } else {
            // iOS can't intercept an http(s) redirect without associated domains, so: open the consent page in
            // the browser; after "Accept", the browser lands on the (unloadable) localhost redirect — the user
            // copies that address and pastes it back here.
            awaitingPaste = true
            statusText = "Sign in to Polar in your browser, tap Accept, then copy the address of the page that fails to load and paste it below."
            #if os(iOS)
            UIApplication.shared.open(url)
            #elseif os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    func completePaste(_ text: String, repo: Repository) {
        guard let creds = credentials else { return }
        busy = true
        Task {
            do { try await finishConnect(callback: text, creds: creds, repo: repo); awaitingPaste = false }
            catch { fail(error) }
        }
    }

    private func finishConnect(callback: String, creds: PolarCredentials, repo: Repository) async throws {
        guard let state = pendingState else { throw PolarError.authFailed("no sign-in in progress") }
        let code = try PolarOAuth.code(fromCallback: callback, expectedState: state)
        pendingState = nil                                   // a code is single-use; never retry it
        statusText = "Finishing sign-in…"
        let tokens = try await exchange(PolarOAuth.tokenRequest(creds, code: code))
        // Store the token BEFORE registering: if registration fails on missing consents (403), the grant is
        // kept, and the next Connect/Sync after accepting consents doesn't need a fresh sign-in.
        guard PolarTokenStore.save(tokens) else { throw PolarError.tokenExchangeFailed("keychain write failed") }
        isConnected = true
        try await register(token: tokens.accessToken)
        await syncNow(repo: repo)
    }

    private func exchange(_ req: URLRequest) async throws -> PolarTokens {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw PolarError.network(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PolarError.tokenExchangeFailed("HTTP \(status)") }
        return try PolarOAuth.parseToken(data, now: Date())
    }

    /// AccessLink requires `POST /v3/users` once; 409 means "already registered" and is fine.
    private func register(token: String) async throws {
        let memberId = UserDefaults.standard.string(forKey: Self.memberIdKey) ?? {
            let id = "goop-" + UUID().uuidString.lowercased()
            UserDefaults.standard.set(id, forKey: Self.memberIdKey)
            return id
        }()
        let (_, resp): (Data, URLResponse)
        do { (_, resp) = try await URLSession.shared.data(for: PolarOAuth.registerUserRequest(token: token, memberId: memberId)) }
        catch { throw PolarError.network(error.localizedDescription) }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300, 409: UserDefaults.standard.set(true, forKey: Self.registeredKey); return
        case 403: throw PolarError.consentsMissing
        case let s: throw PolarError.registrationFailed("HTTP \(s)")
        }
    }

    private func webAuth(url: URL, scheme: String?) async throws -> URL {
        let context = PolarWebAuthContext(anchor: polarPresentationAnchor())
        webContext = context
        defer { webSession = nil; webContext = nil }
        return try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, err in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: PolarError.authFailed(err?.localizedDescription ?? "cancelled")) }
            }
            s.presentationContextProvider = context
            s.prefersEphemeralWebBrowserSession = false
            webSession = s
            if !s.start() { cont.resume(throwing: PolarError.authFailed("couldn't start web session")) }
        }
    }

    // MARK: Sync

    /// Pull the last 28 days from AccessLink and persist them. Idempotent (natural-key upserts).
    func syncNow(repo: Repository) async {
        guard let tokens = PolarTokenStore.load() else { isConnected = false; return }
        busy = true; statusText = "Syncing Polar…"
        defer { busy = false }
        do {
            // A grant stored while consents were missing is registered on the next sync (POST /v3/users).
            if !UserDefaults.standard.bool(forKey: Self.registeredKey) { try await register(token: tokens.accessToken) }
            let pipeline = PolarSyncPipeline(transport: PolarHTTPTransport(token: tokens.accessToken), timeZone: .current)
            let result = try await pipeline.run(today: Self.localDay(Date()))
            guard let store = await repo.storeHandle() else { statusText = "No local store."; return }
            _ = try await PolarSyncWriter.persist(result.normalized, into: store)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncKey)
            await repo.refresh()
            statusText = result.normalized.days.isEmpty
                ? "Connected, but Polar returned no data yet. Sync the Loop in the Polar Flow app, then try again."
                : "Synced \(result.summaryText)."
        } catch PolarSyncError.unauthorized {
            PolarTokenStore.clear(); isConnected = false
            statusText = "Polar access expired or was revoked. Tap Connect to sign in again."
        } catch PolarSyncError.forbidden {
            statusText = PolarError.consentsMissing.errorDescription
        } catch {
            fail(error)
        }
    }

    func syncIfStale(repo: Repository) {
        guard isConnected, !busy else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < Self.autoSyncInterval { return }
        Task { await syncNow(repo: repo) }
    }

    // MARK: Fixture preview (credential-free, never persisted)

    func runPreview() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await PolarFixtures.runDemo()
                preview = PolarRecovery.charge(days: r.normalized.days, extras: r.normalized.extras).map {
                    PolarPreviewRow(day: $0.day, charge: $0.charge, hrv: $0.hrvRmssdMs, rhr: $0.restingHr, polarAns: $0.polarAnsCharge)
                }
                statusText = "Sample data (synthetic, not yours, not saved): \(r.summaryText)."
            } catch { fail(error) }
        }
    }

    // MARK: Disconnect

    func disconnect(repo: Repository) {
        busy = true
        Task {
            if let t = PolarTokenStore.load(), let uid = t.polarUserId {   // best effort: revoke on Polar's side
                _ = try? await URLSession.shared.data(for: PolarOAuth.deregisterRequest(token: t.accessToken, userId: uid))
            }
            PolarTokenStore.clear()
            UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
            UserDefaults.standard.removeObject(forKey: Self.registeredKey)
            if let store = await repo.storeHandle() {
                do {
                    try await store.deleteAllData(deviceId: PolarSyncWriter.deviceId)
                    try DeviceRegistryStore(dbQueue: store.registryWriter).archive(PolarSyncWriter.deviceId)
                    statusText = "Disconnected and removed Polar data from this device."
                } catch {
                    statusText = "Disconnected, but couldn't fully clear local Polar data: \(error.localizedDescription)"
                }
                await repo.refresh()
            }
            isConnected = false; busy = false
        }
    }

    private func fail(_ e: Error) {
        statusText = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        busy = false
    }

    static func localDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// App-wide hook for "Polar Loop is my primary band": call from the app's scene-phase `.active` handler
/// (one line in the app root, owned by the iOS track — see docs/polar-loop-morning-checklist.md).
@MainActor
enum PolarAutoSync {
    static let shared = PolarConnectModel()
    static func appBecameActive(repo: Repository) {
        guard PrimaryBand.current == .polarLoop else { return }
        shared.syncIfStale(repo: repo)
    }
}

/// Presentation context for the sign-in sheet; the anchor is captured on the main actor before `start()`
/// (same approach as OuraOAuthProvider, without needing `MainActor.assumeIsolated`, which is macOS 14+).
final class PolarWebAuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

@MainActor func polarPresentationAnchor() -> ASPresentationAnchor {
    #if os(iOS)
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    #elseif os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
    return ASPresentationAnchor()
    #endif
}
#endif // POLAR_ACCESSLINK
