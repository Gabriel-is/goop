# GOOP on Gabe's iPhone: setup

The quickest way to get NOOP running on an iPhone with a **WHOOP 4.0**, using a **Windows PC**, a **free
Apple ID**, and no Mac. It also covers the paid-account and build-on-a-Mac paths for later.

> GOOP is Gabe's personal fork of [NOOP](https://github.com/ryanbr/noop). The app, bundle and package
> names are unchanged. License: PolyForm Noncommercial 1.0.0 (see `LICENSE`, `NOTICE`, `ATTRIBUTION.md`).
> NOOP is independent and has no affiliation with WHOOP. It is not a medical device.

Written 2026-10-29 against upstream `main` at `2a1de760`. At that point the stable release was **v12.0.0**
(2026-10-04) and the pre-release was `testing-latest` (12.1.0 staging, 2026-10-25).

---

## TL;DR (about 45 to 60 minutes the first time)

1. On the PC, install **iTunes** (Apple's download, not the Store version) and **iloader**, then use
   iloader to put **SideStore** on the iPhone with your Apple ID. (20 to 30 min)
2. On the iPhone, install **LocalDevVPN** from the App Store, turn on **Developer Mode**, and trust your
   Apple ID under VPN & Device Management. (5 min)
3. In SideStore, add the NOOP source
   `https://raw.githubusercontent.com/ryanbr/noop/main/altstore-source.json` and install **NOOP**.
   When asked, **keep the widget extension**. (5 min)
4. Free the strap from the official WHOOP app: force-quit it and **turn off its Bluetooth permission**.
   Don't delete the WHOOP account and don't factory-reset the strap. (2 min)
5. In NOOP, go to Add device → **WHOOP 4.0** → Scan & Connect, with the strap on your wrist. (5 min)
6. Wear it overnight. Sleep and recovery need one night of history before they show anything, and HRV
   and recovery need several nights to calibrate.
7. Every few days, open SideStore with LocalDevVPN connected so it can refresh the 7-day signature. Free
   Apple IDs **can't** write to Apple Health directly; the workaround is in §5.

---

## 1. What upstream already gives you (audit summary)

| Need | Upstream status (v12.0.0) | Notes |
|---|---|---|
| WHOOP 4.0 BLE pairing and history sync | ✅ The project's most-tested path ("the full experience" in the README) | Pairing wizard: `Strand/Screens/AddDeviceWizard.swift`. Engine: `Strand/BLE/BLEManager.swift`. |
| Recovery / Strain / Sleep / HRV | ✅ Computed on-device by `Packages/StrandAnalytics`, the same code used on macOS | NOOP names them **Charge** (recovery), **Effort** (strain) and **Rest** (sleep). They're approximations, and none is WHOOP's own algorithm. |
| Live HR | ✅ Live tab, HR widget, Live Activity | |
| Background BLE | ✅ `bluetooth-central` background mode plus CoreBluetooth state restoration (`CBCentralManagerOptionRestoreIdentifierKey`) | iOS limits are covered below. |
| Background tasks (re-score, Health write-back, stale battery) | ⚠️ **Broken on SideStore/AltStore installs before this PR** | SideStore rewrites the bundle id, which stopped every `BGTaskScheduler` id from registering. **Fixed in GOOP** (see §8). |
| Apple Health write-back (sleep, HR, HRV, workouts) | ✅ Built (`StrandiOS/Health/HealthKitBridge.swift`). It's opt-in: nothing is written until you tap **Enable Apple Health**, and iOS's Health permission sheet gives per-type control. | ❌ **Not possible with a free Apple ID**: free signing can't carry the HealthKit entitlement, and NOOP detects this and says so. Upstream #2862 confirms it on SideStore. Workaround in §5. |
| Widgets | ✅ Recovery/HR/stress/coach widgets, a Live Activity, and a sync Live Activity (`StrandiOSWidgets/`) | You must keep the widget extension when SideStore asks. |
| iCloud/backup | ⚠️ Local `.noopbak` backup only. Upstream #52 and #2356 track backup issues. | Make a backup before reinstalling or switching accounts. |

### Honest iOS background limits

- iOS keeps a BLE connection alive in the background and **relaunches NOOP for BLE events** when state
  restoration is used. It **won't** relaunch an app you swiped away in the app switcher. **Don't
  force-quit NOOP.**
- After a reboot, nothing syncs until you **unlock the phone once**, because Data Protection keeps the
  database locked.
- Low Power Mode throttles background BLE.
- `BGAppRefresh`/`BGProcessing` tasks run when *iOS* chooses, typically overnight on the charger. They're
  best-effort, with no schedule you can rely on.
- In practice, live HR and history offload keep flowing while NOOP is backgrounded and not force-quit.
  Heavy re-scoring may wait until you open the app. Opening NOOP once in the morning is the reliable way
  to get the night's sleep and recovery scored right away.

---

## 2. Install SideStore from Windows (once, about 30 min)

SideStore signs apps **on the iPhone itself** after the first install, so the PC is only needed today.
If anything below differs from what you see, follow <https://docs.sidestore.io> (written 2026-10-29).

**Prerequisites:** a passcode on the iPhone, iOS 15 or later, 64-bit x86 Windows 8 or later (not Windows
on Arm), a USB cable, Wi-Fi, and your Apple ID. A **throwaway Apple ID** works, and is a reasonable
choice to keep sideload signing apart from your main account. The sign-in is case-sensitive.

1. **iTunes for Windows.** Install it from Apple's site (Apple recommends this over the Microsoft Store
   version). If that fails, try the **Apple Devices** app.
2. **iloader.** Download the MSI from the iloader GitHub releases page that SideStore's docs link to,
   then install it.
3. Plug the iPhone in over USB, unlock it, and tap **Trust This Computer**, then enter your passcode.
4. Open iloader, **sign in with the Apple ID**, select the iPhone, and choose **Install SideStore
   (Stable)**. iloader also creates the *pairing file* SideStore needs to sign apps on-device.
5. On the iPhone:
   - **Settings → Privacy & Security → Developer Mode → On.** The phone restarts; confirm after the
     reboot.
   - **Settings → General → VPN & Device Management →** (your Apple ID under *Developer App*) **→ Trust.**
   - Install **LocalDevVPN** from the App Store, open it, tap **Connect**, and allow the VPN
     configuration. SideStore needs this VPN active **whenever it installs or refreshes** an app. You
     can leave it off the rest of the time.
6. Open **SideStore** and sign in with the **same Apple ID**. In **My Apps**, tap the **7 DAYS** counter
   next to SideStore to do its first refresh. If it asks to revoke or create a certificate, tap
   **Yes/Refresh**.

> Why SideStore and not AltStore: upstream `docs/IOS.md` documents a current AltServer Apple-ID sign-in bug
> (`NSCocoaErrorDomain 3840`, AltStore issues #1695 and #1699) and recommends SideStore while it's open.
> SideStore also needs no PC or AltServer running on the network to refresh.

## 3. Install NOOP (about 5 min)

1. Connect LocalDevVPN.
2. In SideStore, go to **Sources → + →** paste exactly
   `https://raw.githubusercontent.com/ryanbr/noop/main/altstore-source.json`
   It must be the **raw** URL; a github.com page URL gives a "not valid JSON" error.
3. Install **NOOP** (v12.0.0 stable). When SideStore offers to remove app extensions, choose **Keep**,
   because the widgets and Live Activities live in `NOOPWidgets.appex`.
4. Launch NOOP and accept the Bluetooth prompt. Also accept **Notifications**: NOOP's strap alerts,
   such as the stale-battery warning, use them.

> **Using the GOOP fix before upstream ships it:** the background-task fix in this PR is not in upstream's
> `.ipa`. Until upstream merges an equivalent, you need a GOOP-built `.ipa` to get it, and building one
> needs macOS (CI or a Mac; see §7). Everything else works on the upstream `.ipa`.

**Free-account quotas:** a free Apple ID can have **3 sideloaded apps active** (SideStore counts as one)
and register **10 App IDs per rolling 7 days**. NOOP uses two (the app plus the widget extension). Don't
install and reinstall over and over on day one, or you'll hit the 10-ID limit and have to wait a week.

## 4. First WHOOP 4.0 pairing (about 5 min)

**Does the official WHOOP app have to let go?** Yes. A WHOOP strap holds **one bonded Bluetooth link at a
time**, and both apps would share the iPhone's single OS-level bond. If the WHOOP app is running, it grabs
the strap, and NOOP's scan either finds nothing or connects without the encrypted bond. When that
happens, live HR still flows (it uses the bond-free standard HR profile), but **history offload, buzz,
alarm and double-tap don't work**. That combination is the tell.

Do this, all of it **reversible**:

1. *(Optional, before you cancel the WHOOP membership)* Request your **data export** from the WHOOP app
   or web account. NOOP can import the WHOOP CSV export (Data Sources → WHOOP Export), so your past
   recovery, strain and sleep history carries over.
2. **Force-quit the WHOOP app**, then go to **Settings → WHOOP → Bluetooth → Off**. That stops it
   reconnecting in the background. Deleting the WHOOP app works too, but isn't required.
3. Don't **"forget/unpair" the strap inside the WHOOP app** and don't **factory-reset** it. Upstream
   #2815 reports a *never-provisioned* WHOOP 4.0 that bonds but produces zero HR. A strap that has been
   set up in the WHOOP app once (yours has) is the known-good state, so leave it that way.
4. In **Settings → Bluetooth**, if a "WHOOP…" device is listed *and* NOOP later fails to bond, tap ⓘ →
   **Forget This Device**, then retry. Skip this step if pairing simply works.
5. Charge the strap, put it **on your wrist**, and make sure it's awake.
6. In NOOP, go to **Add device → WHOOP 4.0 → Scan & Connect**, and accept the iOS **pairing request**
   if one pops up. The pairing wizard shows "Not showing up? The official WHOOP app may still be
   holding it" if the scan stalls.
7. Success looks like a connected state with battery and live HR, followed by a **history offload**,
   which can take a while the first time.

**Risk to the strap firmware or WHOOP account:** NOOP's command set is a deliberate *safe subset*.
Firmware/DFU load, force-trim, ship-mode and fuel-gauge reset are **excluded from the code entirely**
(`Strand/BLE/Commands.swift`), and NOOP never contacts WHOOP's servers. The only firmware risk comes from
the **official app**: if you let it update the strap later, the Bluetooth bond may reset, and NOOP then
asks you to re-pair (it detects this). Upstream has handled every 4.0 layout change so far (v25), but
staying off WHOOP app updates avoids surprises. Account-wise, NOOP reads a device you own, offline. WHOOP's
terms are between you and WHOOP; nothing NOOP does is visible to them.

**Switching back to the WHOOP app** (for example, for a firmware update): quit NOOP, turn the WHOOP app's
Bluetooth permission back on, and re-pair there. To return, reverse the steps.

## 5. Apple Health (sleep / HR / HRV)

| Signing | HealthKit write-back | What to do |
|---|---|---|
| **Free Apple ID (SideStore)** | ❌ No HealthKit entitlement. NOOP shows "This install can't connect to Apple Health directly." | Use **More → Shortcuts Export**: a toggle, **off by default**. On each app close it writes `On My iPhone › NOOP › noop_sync.txt` with one line per 15 min of `HR,HRV,Steps,time`, and a Siri Shortcut (linked from the upstream wiki) logs those lines into Health. That covers **HR, HRV and steps only, not sleep**. Health-zip *import* still works. |
| **Paid Apple Developer ($99/yr)** | ✅ Full two-way: sleep with stages, continuous HR, nightly HRV/RHR/SpO₂/resp, workouts | Sign NOOP with the paid account (SideStore accepts paid accounts, or build in Xcode). Then use Apple Health → **Enable Apple Health** and choose types on the iOS permission sheet. The toggle you asked for is that opt-in button plus iOS's per-type switches (Settings → Health → Data Access & Devices → NOOP). |

## 6. The 7-day re-sign, and free vs paid

- **Free Apple ID:** signatures last **7 days**. SideStore refreshes on-device. Open SideStore with
  **LocalDevVPN connected** and it refreshes all apps, or let its background refresh do it (less
  reliable). NOOP shows *Sideload expiry: N days remaining* in Settings/diagnostics. **If it lapses,
  NOOP won't launch, but your data isn't lost**: refresh in SideStore and it opens again with
  everything intact. Your data survives refreshes, though **not** deleting the app, so make a
  `.noopbak` backup now and then.
- **The pairing file** SideStore uses can break after an iOS update or a "Reset Network Settings". Fix
  it by re-running iloader from the PC.

| | Free Apple ID | Paid Developer Program ($99/yr) |
|---|---|---|
| Signature life | 7 days (auto-refresh via SideStore) | 1 year |
| Active sideloaded apps | 3 (SideStore counts) | effectively unlimited |
| App IDs | 10 per 7 days | effectively unlimited |
| HealthKit write-back | ❌ | ✅ |
| Widgets / App Group / Live Activities | ✅ (SideStore provisions the App Group) | ✅ |
| Background BLE + background tasks | ✅ (background tasks need this PR's fix) | ✅ |
| Needs a Mac | No | No (SideStore accepts paid accounts), but a Mac makes source builds easy |

**Recommendation:** start free tonight. Pay the $99 only if you want sleep in Apple Health or get tired of
the 7-day refresh.

## 7. Later: build from source on a Mac (about 30 min plus build time)

Needs a Mac with current **Xcode** (the iOS leg of CI uses the iOS 26 SDK) and Homebrew.

```bash
brew install xcodegen
git clone git@github.com:Gabriel-is/goop.git && cd goop
cp Config/BundleIdSecrets.example.xcconfig Config/BundleIdSecrets.xcconfig
#   set BUNDLE_ID_PREFIX = com.<something-yours>   (avoids colliding with the SideStore install)
xcodegen generate
open Strand.xcodeproj
```

In Xcode: Signing & Capabilities → choose your **Team** for **NOOPiOS** and **NOOPiOSWidgets**. Select the
iPhone (Developer Mode on) and choose the **NOOPiOS** scheme → Run. With a paid team, HealthKit
provisions automatically. With a free *Personal Team*, expect the same 7-day and HealthKit limits as
SideStore. Note that a different `BUNDLE_ID_PREFIX` is a **separate app with separate data**, so back up
in the SideStore copy and restore in the new one.

Keeping the fork current:

```bash
git fetch upstream && git checkout main && git merge --ff-only upstream/main && git push origin main
```

`--ff-only` stays clean as long as GOOP's `main` carries no fork-only commits. Once it does, use
`git merge upstream/main` and resolve conflicts. Never force-push.

## 8. What GOOP changes (this branch)

- **Background tasks on sideloads (`Strand/System/BackgroundTaskID.swift`).** SideStore/AltStore append
  your team id to the bundle id (`com.noopapp.noop` → `com.noopapp.noop.<TEAMID>`), but the
  `BGTaskSchedulerPermittedIdentifiers` in Info.plist stay as built. Upstream derived each identifier
  from the runtime bundle id, so on a sideload **none of the five background tasks could register**:
  re-score, Health write-back, Coach brief, scheduled export and stale-battery. The upstream diagnostic
  (#2553) reported this but didn't fix it. GOOP now registers the plist's own identifier, the same
  approach upstream already uses for the App Group (`WidgetSnapshot.resolveSuiteName`). Untouched
  builds behave exactly as before. **Not yet verified on a device**: it was checked by a standalone
  Linux oracle and by new `StrandTests`, which only CI on macOS can run.
- **Linux build fix (`Packages/StrandImport/Sources/StrandImport/XlsxSheet.swift`).** A missing
  conditional `import FoundationXML` broke `swift build` of StrandImport on Linux. It's a shared
  package, a one-line pattern copied from sibling files, and changes nothing on Apple platforms.

## 9. Troubleshooting quick list

| Symptom | Likely cause / fix |
|---|---|
| Scan finds nothing | The WHOOP app is still holding the strap: force-quit it and turn off its Bluetooth permission, or the strap is asleep or off-wrist. |
| Live HR works, but no history, buzz or alarm | No encrypted bond. Free the strap (§4), forget it in iOS Bluetooth, and reconnect. |
| Keeps connecting and dropping | A stale bond after a firmware update or the WHOOP app re-bonding it. NOOP shows re-pair steps. |
| NOOP won't open | The 7-day signature expired. Connect LocalDevVPN, then refresh in SideStore. |
| SideStore refresh fails | LocalDevVPN is off, or the pairing file is stale (re-run iloader from the PC). |
| No HRV after the first night | Calibration needs several nights. Upstream #2335 (11.8) was reportedly fixed in 12.0.0. |
| Nothing synced overnight after a reboot | Unlock the phone once. Data Protection blocks writes until you do. |
