# Polar Loop: morning checklist for Gabe

Everything in here is a step only you can do: signing up, accepting Polar's terms, holding the secret, and wearing the
band. Total time is about **45 min**, plus however long the build takes. Background:
[`polar-loop-data-sources.md`](polar-loop-data-sources.md) and
[`polar-loop-recovery-mapping.md`](polar-loop-recovery-mapping.md).

> **Never commit, paste into chat, or put into a CI build the client secret.** `Gabriel-is/goop` is **public**, and its
> "Testing build" releases are public too. Anything inside an `.ipa`'s Info.plist can be read by anyone who downloads
> it. For a CI-built install, type the client into the app, where it goes to the Keychain.
> `Strand/Polar/PolarSecrets.xcconfig` (gitignored) is only for a local Xcode build.

## 0. Before you start (2 min)

- The Loop is paired with **Polar Flow** on your iPhone and has synced at least once. Open Flow and pull to sync.
- In Flow, make sure **continuous heart rate tracking** is on. Without it, GOOP gets sleep and Nightly Recharge but no daytime HR curve.
- Nightly Recharge needs about **3 nights** of wear before Polar shows a status. GOOP's own Charge needs **7 Polar nights** of
  baseline. Both start counting the first night you wear the Loop.

## 1. Register an AccessLink client (10 min)

1. Go to **<https://admin.polaraccesslink.com>** and sign in with the **same Polar Flow account** your Loop syncs to.
2. Accept the AccessLink terms if asked. That is your decision; I didn't accept anything.
3. Create a new client. The exact form wasn't visible to me (it sits behind login), so match these by meaning:

   | Field (approx.) | Value |
   |---|---|
   | Application / client name | `GOOP personal` |
   | Description | `Personal single-user import of my own Polar Loop data into my own iPhone app` |
   | Website / organization | `https://github.com/Gabriel-is/goop` (or leave blank if optional) |
   | Contact email | your email |
   | **Redirect URL(s)** | **`noop://polar/callback`** |

4. **If the portal rejects `noop://…`** (it may only accept http(s)), use **`http://localhost/polar/callback`**. GOOP handles both.
   You can register both URLs on one client.
5. Copy the **client ID** and **client secret** into your password manager now. Assume the secret is shown only once.

## 2. Polar consents (2 min, only if needed)

If Connect later says *"Polar needs you to accept its data-sharing consents"* (that is an HTTP 403 from `POST /v3/users`),
open **<https://account.polar.com>**, accept the mandatory consents, then tap Connect again.

## 3. Get a build that includes this branch (time depends on CI)

The PR is **Gabriel-is/goop#3** (`feat/polar-loop`).
1. Review it and merge it into `main` (or into whatever branch your Testing build uses; see `docs/GABE_IOS_SETUP.md` on `feat/gabe-ios`).
2. Watch for **`app-build.yml`**. It is the **first compile** of the app-side Polar files, since there was no Xcode overnight.
   If it fails, the errors will be in `Strand/Polar/*.swift`. Paste the log to me; fixes should be small.
3. Run Actions → **Testing build (fork)** as usual, then install the `.ipa` with SideStore.

The lane is compiled in by default (`Strand/Polar/PolarConfig.xcconfig`). It makes no network calls unless you act.

## 4. Connect in the app (5 min)

1. Open GOOP → **Data Sources** → **Polar Loop** card.
2. *(Optional sanity check)* Tap **Preview with sample data**. You should see 14 synthetic nights: 7 "Calibrating", then
   Charge values, with a very low one on 2026-10-24 (the deliberately bad sample night). Nothing is saved.
3. Enter the **client ID**, the **client secret**, and the **redirect URL exactly as registered**. Then tap **Save Polar client**.
4. Tap **Connect Polar**:
   - **`noop://` redirect:** a Polar sign-in sheet opens. Sign in, tap **Accept**, and you return to GOOP automatically.
   - **`http://localhost` redirect:** Safari opens. Sign in, tap **Accept**, and Safari lands on a page that **fails to load**.
     That's expected. Copy that page's **full address** (it contains `code=…&state=…`), switch back to GOOP, paste it into
     the box, and tap **Finish connecting**. Do this within 10 minutes, because the code expires. Use it once; Polar
     revokes everything if a code is reused.
5. The first sync runs automatically. The status line should read something like
   `Synced 3 nights · 3 HRV · 860 HR samples · 3 activity days.`
6. Set **Primary band → Polar Loop**. GOOP then re-syncs Polar at most every 30 minutes whenever you open Data Sources.

## 5. Check the first real sync (10 min)

- [ ] **Nights:** the count matches the nights you wore the Loop (up to 28; AccessLink keeps about 28 days).
- [ ] **HRV:** the "N HRV" count is non-zero once Polar shows Nightly Recharge in Flow. If it's 0 but nights > 0, Polar
      hasn't produced Nightly Recharge yet (it needs about 3 nights).
- [ ] **One night against Flow:** in GOOP's Sleep view, sleep start and end should match Flow to the minute, and the stage
      minutes should be close. HRV should equal Flow's Nightly Recharge "HRV" (ms).
- [ ] **Charge:** Today shows **Calibrating** until you have 7 Polar nights. That's expected and honest.
- [ ] **Anything unexpected:** send me the status line text. **Not** the secret, and not the token.

What is **unverified** until this sync works: that AccessLink returns Loop data for every endpoint (Polar's docs never name
the Loop), whether the portal accepts the `noop://` redirect, and the exact create-client form.

## 6. Small follow-ups (for me or Track B)

1. **App-foreground auto-sync (5 min, Track B owns the file).** Add one line to the iOS app root's
   `scenePhase == .active` handler:
   `#if POLAR_ACCESSLINK` / `PolarAutoSync.appBecameActive(repo: repo)` / `#endif`.
   Until then, auto-sync happens when Data Sources opens.
2. **Effort on Loop-only days.** AccessLink HR is 5-minute averages, so Effort would be underestimated. Decide whether to
   hide Effort for coarse-cadence sources (see the recovery-mapping doc, "not comparable" #4).
3. **If the secret ever leaks**, rotate it in admin.polaraccesslink.com and re-enter it in the card.
   **Disconnect** in the card revokes GOOP's token on Polar's side (`DELETE /v3/users/{id}`) and deletes the Polar rows
   stored on the phone.

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| Polar's page says the redirect URI is invalid | The URL in the card must **exactly** match one registered on the client (scheme, host, path; no trailing slash). |
| "access expired or was revoked" | 401. AccessLink has no refresh tokens, so tap Connect again. |
| "returned no data yet" | Sync the Loop in the Flow app first, wait a minute, then tap **Sync now**. |
| Nights present, HR samples 0 | Turn on continuous HR in Flow's device settings. |
| `skipped: …` in the status | One endpoint failed (shown by name). The rest imported. Tap **Sync now** to retry; re-syncing is idempotent. |
