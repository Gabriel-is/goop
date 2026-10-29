# Polar Loop: data sources and the path GOOP uses

**Status:** research for the GOOP fork (`Gabriel-is/goop`, branch `feat/polar-loop`), checked 2026-10-29.
**Device:** the 2025 **Polar Loop**, the screenless band that shipped in September 2025. Polar's SDK staff
call it **"Polar Loop Gen 2"** to tell it apart from the 2013 Loop. This is *not* the old Loop / Loop 2.
**Companion docs:**
- [`polar-loop-recovery-mapping.md`](polar-loop-recovery-mapping.md): how Polar's numbers become NOOP Charge.
- [`polar-loop-morning-checklist.md`](polar-loop-morning-checklist.md): what Gabe has to do by hand.
- [`DEVICE_DRIVER_ARCHITECTURE.md`](DEVICE_DRIVER_ARCHITECTURE.md) and [`DEVICE_SUPPORT_ROADMAP.md`](DEVICE_SUPPORT_ROADMAP.md): upstream's device model.

Every claim below links to its source. **[unverified]** marks anything I could not confirm from a primary source.

---

## TL;DR: the decision

| Path | Works with Loop? | What you get | Verdict |
|---|---|---|---|
| **(a) Polar AccessLink v3** (cloud, OAuth2) | Yes. Loop syncs to Polar Flow, and AccessLink reads Flow. | Nightly Recharge (HRV RMSSD, sleep HR, breathing), Sleep Plus Stages hypnogram, 24/7 HR at 5-min resolution, daily activity and steps, cardio load. | **Primary path. Built in this branch.** |
| **(b) Polar BLE SDK / PMD direct** | Partly. The SDK lists "Polar 360 / Polar Loop", but Loop has **one** BLE bond and it is reserved for Flow. | Live HR and PPI, offline recordings, 24/7 PPI, sleep and Nightly Recharge read off the band. | **Not built.** Pairing GOOP takes the band away from Flow, which breaks path (a) and Polar's own app. Recorded as a possible later "exclusive band" mode. |
| **(c) Standard BLE HR service `0x180D`** | **No.** Loop cannot act as an HR sensor for other devices. | — | Not possible. |
| **(d) Upstream `Packages/PolarProtocol`** | Not as it stands. | It decodes PMD PPI frames for H10, OH1 and Verity, but has no Loop catalog entry and no live source. It also cannot get past the single-bond limit. | Leave it unchanged. Reuse it if (b) is ever built. |

**Why (a):**
1. It is the only path that keeps the band paired to Polar Flow. Gabe keeps Polar's app, firmware updates and Polar's own Nightly Recharge.
2. It gives exactly the overnight inputs NOOP's Charge needs: RMSSD HRV, sleeping HR, breathing rate and sleep stages.
3. It is the same shape as upstream's existing **Oura live API import** lane (`Strand/Oura/*` + `OuraApiParser`, spec in
   [`superpowers/specs/2026-06-27-oura-live-api-import-design.md`](superpowers/specs/2026-06-27-oura-live-api-import-design.md)).
   So the Polar lane is a sibling of a design that already shipped, not a new architecture.

**The cost of (a):**
1. It is a **cloud** dependency, and upstream NOOP's [`AGENTS.md`](../AGENTS.md) scope bars that by default.
   GOOP handles it the way upstream handled Oura:
   - It is compiled out unless an untracked xcconfig opts in.
   - It is user-initiated and inbound only.
   - Tokens live in the Keychain.
   - There is no GOOP server.
2. **Data lags reality.** The Loop syncs to Flow about every 30 minutes when the phone is near. AccessLink then
   serves it, and keeps only about the **last 28 days** for most endpoints.
3. **5-minute HR is too coarse** to score strain the way WHOOP's 1 Hz stream does. See the recovery-mapping doc.

---

## (a) Polar AccessLink API v3

Primary reference: <https://www.polar.com/accesslink-api/>. All facts in this section come from that page unless another
link is given. Polar's example client: <https://github.com/polarofficial/accesslink-example-python>.

### Auth: OAuth2 authorization code

| Item | Value |
|---|---|
| Authorize | `GET https://flow.polar.com/oauth2/authorization?response_type=code&client_id=…[&redirect_uri=…][&scope=accesslink.read_all][&state=…]` |
| Token | `POST https://polarremote.com/v2/oauth2/token`. **HTTP Basic** `base64(client_id:client_secret)` header, form body `grant_type=authorization_code&code=…[&redirect_uri=…]` |
| Token response | `access_token`, `token_type: "bearer"`, `expires_in`, `x_user_id` (the Polar user id, a long) |
| Code | Single use, lives 10 min. **Re-using a code revokes every token issued from it.** |
| Scope | `accesslink.read_all` is the only documented scope. |
| PKCE | Not documented anywhere on the page. Assume **no PKCE**. |
| Refresh tokens | **None documented.** The docs say tokens "will not expire unless explicitly revoked", but the example `expires_in` is about one year. GOOP treats a 401 as "re-connect". |
| User registration | Required before any data read: `POST /v3/users` with `{"member-id": "<any stable id>"}`. Returns 200 on success, 409 if the user is already registered (GOOP treats that as success), 403 if mandatory consents at account.polar.com are not accepted. `DELETE /v3/users/{user-id}` de-registers the user and revokes the token. |
| API base | `https://www.polaraccesslink.com/v3/…` with `Authorization: Bearer <token>`. |

**Redirect URIs:**
- The `redirect_uri` must be *identical* to a URL registered on the client. A client can hold several URLs, and one
  is the default.
- Polar's example uses `http://localhost:5000/oauth2_callback`.
- **[unverified]** Whether admin.polaraccesslink.com accepts a custom scheme such as `noop://polar/callback`. The form
  sits behind a login, so I could not check.
- GOOP's flow therefore supports both cases:
  1. If the custom scheme is accepted, `ASWebAuthenticationSession` catches `noop://polar/callback` directly.
  2. If only http(s) is accepted, register `http://localhost/polar/callback`. The browser fails to load that page,
     Gabe copies the URL from the address bar, and pastes it into GOOP. GOOP pulls out the `code` and checks `state`.

### The client secret in a native app

The token call needs `client_secret` over HTTP Basic, and Polar documents no PKCE or public-client mode. A secret
inside an iOS binary can be extracted by anyone who has the binary. The options:

| Option | Security | Fits NOOP/GOOP scope? |
|---|---|---|
| **1. BYO client, secret in an untracked xcconfig, single-user build** (what upstream does for Oura) | The secret is only in Gabe's own sideloaded binary. Anyone holding that binary could pull Gabe's Polar *client* secret, but they would still need a user's OAuth grant to read data. Rotate it in the admin portal if the phone or IPA leaks. | Yes. **Chosen.** |
| 2. Small token-exchange proxy (a serverless function holds the secret) | Best practice for multi-user apps. | No. Upstream forbids a NOOP-operated server, and it is overkill for one user. |
| 3. Paste the secret at runtime and store it in the Keychain | Same exposure as 1, but avoids rebuilding. | Possible later. Not built. |

### Endpoints GOOP reads

All of these default to the **last 28 days** and cap a range at 28 days, unless noted.

| Endpoint | Shape (key fields) | Used for |
|---|---|---|
| `GET /v3/users/nightly-recharge` → `{"recharges":[…]}` | `date`, `heart_rate_avg` (bpm), `beat_to_beat_avg` (ms), `heart_rate_variability_avg` (**ms RMSSD**), `breathing_rate_avg` (br/min), `nightly_recharge_status` (1–6), `ans_charge` (−10…+10), `ans_charge_status` (1–5), `hrv_samples` / `breathing_samples` (`"HH:MM"` → 5-min averages). The averages cover a **4 h window starting 30 min after sleep onset**. | Charge inputs: HRV, RHR, respiration. Polar's own scores are kept for reference only. |
| `GET /v3/users/sleep` → `{"nights":[…]}` | `date`, `sleep_start_time` / `sleep_end_time` (ISO-8601 with offset), `light_sleep` / `deep_sleep` / `rem_sleep` / `unrecognized_sleep_stage` / `total_interruption_duration` (**int seconds**), `continuity`, `sleep_score` (1–100), `sleep_charge`, `sleep_cycles`, `hypnogram` (`"HH:MM"` → stage: 0 wake, 1 REM, 2 lighter NREM, 3 light NREM, 4 deep NREM, 5 unknown), `heart_rate_samples` (`"HH:MM"` → bpm, 5-min averages). | Sleep sessions, stage timeline, Rest. |
| `GET /v3/users/continuous-heart-rate?from=&to=` | `{polar_user, date, heart_rate_samples:[{heart_rate, sample_time:"HH:MM:SS"}]}`, **5-min** cadence. Training sessions are not included. Continuous HR support lists Polar Loop: <https://support.polar.com/en/support/the_what_and_how_of_polars_continuous_heart_rate>. | `hrSample` rows (daytime HR curve). |
| `GET /v3/users/activities?from=&to=` (non-transactional; `from` at most 365 days back) | `start_time` / `end_time` (local time, no timezone), `active_duration` / `inactive_duration` (**ISO-8601 durations**), `calories`, `active_calories`, `steps`, `distance_from_steps` (m). | Steps, active and total kcal. |
| `GET /v3/users/cardio-load` | `date`, `cardio_load_status`, `cardio_load` (TRIMP), `strain` (7-day), `tolerance` (28-day), `cardio_load_ratio`, `cardio_load_level`. | Kept for reference only. Never used as Effort. |
| Not used: `/v3/exercises` (30 days, needs per-exercise samples), `/v3/users/sleepwise/*` (Loop is listed as supported: <https://support.polar.com/en/polar-sleepwise>), `/v3/users/biosensing/*` (Elixir-sensor features: skin temp, SpO2, ECG). | | Loop uses the Precision Prime sensor, not Elixir. Polar says skin temperature is "not supported on Polar Loop" (<https://www.polar.com/en/loop>), so biosensing should be empty. **[unverified]** live. |

The older transaction APIs (`/v3/users/{id}/activity-transactions` and friends) are **deprecated**. GOOP does not use them.

### Limits, latency, webhooks

- **Rate limits:** 15 min allows `500 + users×20` requests; 24 h allows `5000 + users×100`. A breach returns 429. The
  `RateLimit-Usage`, `RateLimit-Limit` and `RateLimit-Reset` headers report usage. For one user that is 520 per
  15 min, far above one sync, which is about 6 requests.
- **Latency:** Loop → Flow runs "automatically… every half hour" when the phone is in range
  (<https://www.polar.com/en/sync-polar-loop-with-flow-app>). Then Flow → AccessLink. Last night's sleep and
  Nightly Recharge appear after the first morning sync.
- **Retention:** about 28 days (30 for exercises). **GOOP must sync at least every few weeks or lose history.** The
  local store keeps everything it has already pulled.
- **Webhooks** (`POST /v3/webhooks`: SLEEP, CONTINUOUS_HEART_RATE, ACTIVITY_SUMMARY…; no Nightly Recharge event) need a
  public HTTPS receiver. GOOP does not use them, since there is no server, and polls on user action instead.
- **Accounts:** a free Polar Flow account. Loop is subscription-free; the paid Polar Fitness Program covers training plans and
  is not required (press release:
  <https://polar.com/en/media-room/polar-launches-polar-loop-first-screen-free-subscription-free-wearable>;
  <https://support.polar.com/us-en/fitness-program-faqs>). No source ties AccessLink to a subscription.
- **[unverified]** That AccessLink actually returns Loop data for **every** endpoint above. "Loop" never appears in the
  AccessLink docs. Polar support pages list Loop for continuous HR and SleepWise, and the Loop product page lists
  Nightly Recharge and Sleep Plus Stages. **The first real sync is the test.** See the checklist.

---

## (b) Polar BLE SDK (`polarofficial/polar-ble-sdk`)

- **README:** the supported-products table has a row **"Polar 360 / Polar Loop"** → `documentation/products/Polar360.md`
  (<https://github.com/polarofficial/polar-ble-sdk>). Releases: 8.3.0 (2026-09-09), 8.4.0 (2026-10-01), 8.5.0 (2026-10-23)
  (<https://github.com/polarofficial/polar-ble-sdk/releases>). 8.0.0 moved iOS from RxSwift to Combine and async/await.
- **Features listed for 360 / Loop**
  (<https://raw.githubusercontent.com/polarofficial/polar-ble-sdk/master/documentation/products/Polar360.md>):
  - Online streams and offline recording: HR, **PPI**, ACC (50 Hz ±8 g), PPG (22/50/100 Hz, firmware 2.0.8 or later), skin temperature.
  - Data export: sleep, Nightly Recharge, `get247HrSamples` (5 min, or 1/s at high activity), `get247PPiSamples`, steps,
    activity samples, calories.
  - No gyroscope.
- Polar staff say Loop Gen 2 is read "in the same way as for Polar 360"
  (<https://github.com/polarofficial/polar-ble-sdk/issues/771>).
- **Blockers for GOOP:**
  - **Single peer.** A paired device is invisible to others, a re-pair needs a factory reset, and pairing overwrite
    is refused (Polar360.md, "BLE functionality").
  - The Loop FAQ: it "supports one Bluetooth Low Energy (BLE) connection", reserved for Flow
    (<https://www.polar.com/en/loop>).
  - So GOOP over BLE and Flow (and with it AccessLink) are **mutually exclusive**.
  - **[unverified]** Whether two apps on the *same* iPhone can share the bond: one bond per phone, but the two apps would
    fight over the connection.
  - Known Loop SDK issues:
    - reset/pairing-loss loop: [#836](https://github.com/polarofficial/polar-ble-sdk/issues/836)
    - bad walking HR on firmware 6.2.26: [#880](https://github.com/polarofficial/polar-ble-sdk/issues/880)
    - SDK mode pauses 24/7 collection: [#885](https://github.com/polarofficial/polar-ble-sdk/issues/885)
    - battery drain with heavy offline recording: [#813](https://github.com/polarofficial/polar-ble-sdk/issues/813)
- Using the SDK would also mean adding a **third-party dependency** (`PolarBleSdk` via SwiftPM) to an app whose supply-chain
  rule pins every dependency exactly. That is a bigger change than this branch should make overnight.
- **When (b) would make sense:** an "exclusive band" mode where Gabe gives up the Flow app. GOOP would then get
  beat-to-beat PPI all night (true NOOP-computed RMSSD, like WHOOP) and higher-resolution HR, at the cost of Polar's
  apps and firmware-update convenience. Upstream `PolarProtocol` (PMD PPI decode) is the reusable piece. The 24/7
  "data export" calls use Polar's proprietary file protocol, which NOOP does not implement. Clean-room re-derivation
  would be a project of its own.

## (c) Standard BLE Heart Rate Service

**Not supported.** The Loop FAQ says it "cannot be used as a heart rate sensor for other devices" and has no broadcast to
external devices (<https://www.polar.com/en/loop>). The same page's spec table lists a "broadcast range", which reads like
boilerplate and contradicts the FAQ. Upstream's generic `0x180D` strap path (`StandardHRSource`), which works for the H10,
H9 and Verity, therefore **does not** apply to the Loop.

## (d) Does upstream `PolarProtocol` already cover the Loop?

No:
- `Packages/PolarProtocol` is pure decoding only: the PMD frame header, PPI samples, the control-point builder, and an
  advertised-name → model catalog for **H10 / H9 / OH1 / Verity Sense**. There is no Loop or 360 entry, and there is no
  live `PolarPMDSource` in any app target (see [`DEVICE_SUPPORT_ROADMAP.md`](DEVICE_SUPPORT_ROADMAP.md), "Polar PMD").
- Even with a catalog entry, the single-bond limit in (b) means the Loop would never be discoverable while it is paired
  with Flow.
- This branch therefore **leaves `PolarProtocol` unchanged**, which avoids a Swift/Kotlin parity change for no user gain.

---

## What was built (and where it sits in upstream's architecture)

Upstream already has two device abstractions:
1. `LiveHRSource` for **live BLE** sources (`DEVICE_DRIVER_ARCHITECTURE.md`).
2. The **import lane** (`WearableDailyRow` / `WearableSleepSession` → `WhoopStore`, registered as `PairedDevice(sourceKind: .cloudImport)`).

The Loop has no usable live BLE stream, so it belongs in the **import lane**, exactly like the Oura API lane. GOOP extends
that abstraction and adds no new `DataSource` layer (the overnight plan asked for one; it isn't needed because upstream
already has it).

| Piece | Location | Network? |
|---|---|---|
| Pure AccessLink models, parser, hypnogram, mapper, sync pipeline (over a `PolarAccessLinkTransport` protocol), fixture transport, recovery mapping | `Packages/PolarAccessLink` (new) | **No.** The package is network-free, like every NOOP package. |
| Realistic fixture JSON (14 nights, AccessLink shapes) | `Packages/PolarAccessLink/Sources/PolarAccessLink/Fixtures/` | — |
| `polar-accesslink-demo` CLI: runs the fixture pipeline end to end and prints nights and Charge | `Packages/PolarAccessLink/Sources/polar-accesslink-demo` | No |
| OAuth (ASWebAuthenticationSession + paste-URL fallback), Keychain token store, URLSession transport, store writer, connect model, Data Sources card with the WHOOP/Polar choice | `Strand/Polar/` (app target, gated by `POLAR_ACCESSLINK`) | Yes (app target only) |
| One-line registrations | `Strand/Screens/DataSourcesView.swift` (card), `Strand/Data/Repository.swift` (`"polar-api"` in `wearableImportSources`, so the existing import fold computes Charge), `project.yml`, `.gitignore`, `Strand/Oura/OuraConfig.xcconfig` (optional include) | — |

Data lands under `deviceId = "polar-api"`, registered as `.cloudImport`. The import-source priority in
`DayOwnerResolver` means it **never takes a day from WHOOP**. On days only the Loop covers, which is the "wearing the
Loop instead" case, it owns the day, and `IntelligenceEngine`'s wearable-import fold scores Charge from it.
