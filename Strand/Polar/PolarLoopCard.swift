// GOOP: Polar Loop lane. Compiled ONLY with -DPOLAR_ACCESSLINK (see PolarConfig.xcconfig).
#if POLAR_ACCESSLINK
import SwiftUI
import StrandDesign

/// The Data Sources "Polar Loop" card. It holds the primary-band choice (WHOOP / Polar Loop) and the connect
/// flow (Connect → Sync now → Disconnect), plus a credential-free "Preview with sample data". The card
/// itself makes no network call: every request starts from a tap, or from the opt-in Polar-primary auto-sync.
/// Registered with one line in DataSourcesView. Copy is `Text(verbatim:)` on purpose: this card is a
/// GOOP-fork, compile-flag-gated lane with no translations, so it is kept out of the string catalogs.
struct PolarLoopCard: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var model = PolarAutoSync.shared
    @AppStorage(PrimaryBand.defaultsKey) private var primaryBandRaw = PrimaryBand.whoop.rawValue
    @State private var pasted = ""
    @State private var confirmDisconnect = false

    private var tint: Color { StrandPalette.accent }

    var body: some View {
        NoopCard(padding: 18, tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                header
                Text(verbatim: PolarCopy.intro)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(selection: $primaryBandRaw) {
                    ForEach(PrimaryBand.allCases) { Text(verbatim: $0.label).tag($0.rawValue) }
                } label: { Text(verbatim: PolarCopy.primaryBand) }
                .pickerStyle(.segmented)
                .accessibilityHint(Text(verbatim: PolarCopy.primaryHint))

                actions
                if model.awaitingPaste { pasteBox }
                if let s = model.statusText {
                    Text(s).font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.preview.isEmpty { previewTable }
            }
        }
        .onAppear { if PrimaryBand(rawValue: primaryBandRaw) == .polarLoop { model.syncIfStale(repo: repo) } }
        .confirmationDialog(Text(verbatim: PolarCopy.disconnectTitle), isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(role: .destructive) { model.disconnect(repo: repo) } label: { Text(verbatim: PolarCopy.disconnectConfirm) }
        } message: {
            Text(verbatim: PolarCopy.disconnectMessage)
        }
    }

    private var header: some View {
        HStack(spacing: NoopMetrics.space2 + 2) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text(verbatim: PolarCopy.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            Text(verbatim: model.isConnected ? PolarCopy.connected : (model.isConfigured ? PolarCopy.notConnected : PolarCopy.sampleOnly))
                .font(.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    @ViewBuilder private var actions: some View {
        if model.isConnected {
            HStack {
                Button { Task { await model.syncNow(repo: repo) } } label: {
                    Label { Text(verbatim: model.busy ? PolarCopy.working : PolarCopy.syncNow) } icon: { Image(systemName: "arrow.clockwise") }
                }
                Button(role: .destructive) { confirmDisconnect = true } label: {
                    Label { Text(verbatim: PolarCopy.disconnect) } icon: { Image(systemName: "xmark.circle") }
                }
            }.disabled(model.busy)
            if let last = model.lastSync {
                Text(verbatim: PolarCopy.lastSynced(last.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        } else {
            HStack {
                Button { model.connect(repo: repo) } label: {
                    Label { Text(verbatim: PolarCopy.connect) } icon: { Image(systemName: "link") }
                }
                .disabled(model.busy || !model.isConfigured)
                Button { model.runPreview() } label: {
                    Label { Text(verbatim: PolarCopy.preview) } icon: { Image(systemName: "eye") }
                }
                .disabled(model.busy)
            }
            if !model.isConfigured {
                Text(verbatim: PolarCopy.setupHint)
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pasteBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(text: $pasted) { Text(verbatim: PolarCopy.pastePrompt) }
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Button { model.completePaste(pasted, repo: repo); pasted = "" } label: { Text(verbatim: PolarCopy.finishConnecting) }
                .disabled(pasted.isEmpty || model.busy)
        }
    }

    private var previewTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: PolarCopy.previewHeader).font(.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            ForEach(model.preview) { r in
                HStack {
                    Text(verbatim: r.day).monospacedDigit()
                    Spacer()
                    Text(verbatim: r.charge.map { String(format: "Charge %.0f", $0) } ?? "Calibrating")
                    Text(verbatim: r.hrv.map { String(format: "HRV %.0f", $0) } ?? PolarCopy.noHRV).frame(width: 70, alignment: .trailing)
                    Text(verbatim: r.polarAns.map { String(format: "ANS %+.1f", $0) } ?? "").frame(width: 70, alignment: .trailing)
                }
                .font(.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

/// The card's copy, kept as constants rather than inline literals: this GOOP-fork, compile-flag-gated lane
/// ships no translations, so it stays out of the string catalogs (and the i18n audit's call-site scan).
enum PolarCopy {
    static let intro = "Use a Polar Loop instead of (or alongside) your WHOOP. GOOP pulls your Loop's sleep, Nightly Recharge HRV, heart rate and activity from Polar AccessLink after the Loop syncs to Polar Flow, then scores Charge on this device against your own baseline. Polar's own scores are kept for reference only."
    static let primaryBand = "Primary band"
    static let primaryHint = "Polar Loop syncs Polar automatically when you open the app. WHOOP keeps any day it recorded either way."
    static let disconnectTitle = "Disconnect Polar?"
    static let disconnectConfirm = "Disconnect and remove Polar data"
    static let disconnectMessage = "This revokes GOOP's Polar access and deletes the Polar rows stored on this device. Your data in Polar Flow is not touched."
    static let title = "Polar Loop"
    static let disconnect = "Disconnect"
    static let connect = "Connect Polar"
    static let preview = "Preview with sample data"
    static let setupHint = "To connect your own Loop, add your Polar AccessLink client to Strand/Polar/PolarSecrets.xcconfig (see docs/polar-loop-morning-checklist.md). The preview uses synthetic sample data and saves nothing."
    static let pastePrompt = "Paste the address here (…?code=…&state=…)"
    static let finishConnecting = "Finish connecting"
    static let previewHeader = "Sample nights: NOOP Charge vs Polar ANS charge"
    static let connected = "Connected"
    static let notConnected = "Not connected"
    static let sampleOnly = "Sample data only"
    static let working = "Working…"
    static let syncNow = "Sync now"
    static let noHRV = "HRV –"
    static func lastSynced(_ when: String) -> String {
        "Last synced " + when + ". Polar keeps about 28 days, so sync at least every few weeks."
    }
}
#endif // POLAR_ACCESSLINK
