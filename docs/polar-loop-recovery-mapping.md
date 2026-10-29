# Polar Loop → NOOP Charge, Rest and Effort: what maps, what doesn't

**Scope:** GOOP fork, `feat/polar-loop`.
**Code:**
- `Packages/PolarAccessLink`: `PolarAccessLinkMapper` and `PolarRecovery`.
- `Strand/Polar/PolarSyncWriter.swift`.
- `Strand/Data/Repository.swift` (`wearableImportSources`).

**Engines reused, unchanged:**
- `StrandAnalytics/WatchRecovery.swift` → `RecoveryScorer.recovery(...)`. See [`ANALYTICS.md`](ANALYTICS.md), "Charge".

## The rule

GOOP does **not** invent a Polar recovery formula, and it **never** relabels Polar's numbers as NOOP's. Polar's
**ANS charge**, **Nightly Recharge status**, **sleep score** and **cardio load** are stored only under `ref_*`
metric keys, the same convention upstream uses for Oura's readiness. They are shown next to NOOP's scores, never in
place of them.

Charge for a Loop-only day comes from **raw overnight inputs vs your own Polar baseline**. NOOP already does this for
every import-only wearable source (Oura export, Fitbit, Garmin, Oura API, Health Connect): `IntelligenceEngine`'s
wearable-import fold calls `WatchRecovery.compute` for each id in `Repository.wearableImportSources`. GOOP adds
`"polar-api"` to that list. `PolarRecovery.charge(...)` in the package calls the **same** engine with the **same**
trailing-history rule. A test (`testChargeIsExactlyTheAppsWatchRecoveryEngine`) pins that, so the package tests and
the demo CLI print the number the app will show.

## Input mapping

| NOOP input | Polar source | Notes |
|---|---|---|
| `avgHrv` (Charge's dominant term) | Nightly Recharge `heart_rate_variability_avg` | **RMSSD, ms**, over Polar's fixed window: about 4 h, starting 30 min after sleep onset ([AccessLink](https://www.polar.com/accesslink-api/); [Polar support](https://support.polar.com/en/nightly-recharge-recovery-measurement)). |
| `restingHr` | **Lowest 5-min average** of the night's `sleep.heart_rate_samples` | It needs ≥ 12 samples (1 h). If there are fewer, it falls back to Nightly Recharge `heart_rate_avg`, a 4 h **mean** that reads a few bpm higher. The choice is recorded per night as `polar_rhr_source` (1 = sleep lowest, 2 = NR mean), so a mixed history can be audited. The lowest 5-min average was picked because it is closest to what WHOOP's and Oura's "resting HR" mean. |
| `respRateBpm` | Nightly Recharge `breathing_rate_avg` | Stored and shown. `WatchRecovery` does not feed respiration into Charge (it uses HRV + RHR only), the same as for Oura and Apple Watch days. |
| Sleep minutes, stages, efficiency → **Rest** | `sleep`: `light_sleep` / `deep_sleep` / `rem_sleep` / `unrecognized_sleep_stage` (seconds), `total_interruption_duration`, `hypnogram` | Total sleep = light + deep + REM + unrecognized. Efficiency is a 0–1 fraction of in-bed time. Polar's two light-NREM codes (2 "lighter", 3 "light") both become NOOP `light`. Code 5 (unknown) is a **gap**, never a guessed stage. |
| `steps`, `activeKcal` | `activities`: `steps`, `active_calories` | |
| `hrSample` | `continuous-heart-rate` (5-min) + sleep `heart_rate_samples` | Wall-clock `HH:MM:SS` is anchored in the phone's zone and is correct across DST (tested on 2026-11-01). |
| `ref_polar_ans_charge`, `ref_polar_ans_charge_status`, `ref_polar_nightly_recharge`, `ref_sleep_score`, `ref_polar_sleep_charge`, `ref_polar_cardio_*` | Polar's own scores | **Reference only.** Browseable in Metric Explorer. |

## Where Polar's math differs from WHOOP's (and from NOOP's)

| | WHOOP Recovery | Polar Nightly Recharge / ANS charge | NOOP Charge (what GOOP shows) |
|---|---|---|---|
| HRV window | Whole night, weighted toward slow-wave sleep (WHOOP's description; NOOP's own WHOOP path computes RMSSD from raw R-R) | **First ~4 h** of sleep only | Takes whatever the source gives. For Polar that is the 4 h RMSSD. |
| Drivers | HRV-led, plus RHR, respiration, sleep | ANS charge from **HR (largest weight), HRV, breathing** vs your 28-day usual; status also folds in sleep charge (formula unpublished) ([Polar support](https://support.polar.com/en/nightly-recharge-recovery-measurement)) | HRV-led z-score + logistic vs **your own** baseline. On import-only days this is HRV + RHR, with weights renormalized. |
| Scale | 0–100 % | ANS −10…+10; status 1–6 | 0–100 (bands: red < 34, yellow 34–67, green ≥ 67) |
| Baseline | Proprietary | 28 days | Winsorized EWMA. Needs **7 accepted nights** before it scores; until then it shows "Calibrating". |
| Sampling | 1 Hz HR, beat-to-beat R-R | Optical beat-to-beat on the band, but AccessLink exposes only **averages** (4 h HRV, 5-min HR) | Uses what it's given. No beat-level data is available on this path. |

**How it's normalized:**
1. **Every term is relative to the wearer's own baseline**, so the absolute scale of Polar's 4 h RMSSD versus
   WHOOP's whole-night RMSSD cancels out. This is the argument upstream makes for Apple Watch SDNN in
   `WatchRecovery.swift`.
2. **Baselines are per source.** The import fold builds the baseline from `"polar-api"` rows only, so WHOOP nights
   never feed a Polar baseline, and the reverse is also true.
3. **Days don't blend.** If both bands recorded a night, the WHOOP wins that day: `.cloudImport` ranks below a live
   strap in `DayOwnerResolver`.

## What is *not* honestly comparable

1. **Absolute HRV and RHR across bands.** A 4 h Polar RMSSD of 60 and a WHOOP whole-night RMSSD of 60 are different
   measurements. Compare trends within one band, not values across bands.
2. **Charge right after switching.** The Polar baseline starts empty, so the first **7 Loop nights are
   "Calibrating"**. After that, confidence reads "building" until the baseline matures. With a short baseline, a single
   bad night can swing Charge hard. In the fixtures, the bad night (HRV 34 vs about 58) scores **0**. That is the engine
   being honest about a large deviation from a narrow baseline, not a bug. It will soften as the baseline widens.
3. **NOOP Charge vs Polar ANS charge or Nightly Recharge.** They weight the drivers differently: Polar is HR-led,
   NOOP is HRV-led. They will often agree on direction and sometimes not. The card's sample preview and Metric
   Explorer show them side by side on purpose.
4. **Effort / Strain on Loop-only days.** AccessLink gives **5-minute** HR averages. NOOP's Effort integrates
   per-second HR-reserve zones (TRIMP), and 5-min averages flatten every interval, so **Effort would be
   underestimated**. Polar's own `cardio_load` (TRIMP) is kept as `ref_polar_cardio_load`. **[unverified]** Whether the
   app's raw-HR loop computes an Effort from `polar-api` `hrSample` rows on a day Polar owns. If it does, treat that
   number as a floor, not a score. A follow-up could suppress Effort for sources whose HR cadence is coarser than 60 s.
5. **SpO₂ and skin temperature.** The Loop doesn't surface them (Precision Prime sensor, not Elixir), so Charge's
   skin-temp term simply drops out. GOOP never fabricates them.

## Cross-platform parity (AGENTS.md rule #1)

This lane is **Swift / iOS only**, like upstream's Oura API lane. Upstream's own spec scopes that lane to iOS too. No
Kotlin twin was added, and no stored value, migration, dedup key or `.noopbak` field changed: Polar rows use existing
tables under a new `deviceId`. If the lane is ever upstreamed with an Android twin, the mapper's numbers must be
checked against an oracle on both sides, following the AGENTS.md "verify byte-identical by oracle" recipe.

## Tests (`cd Packages/PolarAccessLink && swift test`; Linux needs the SQLite flags from BUILD.md)

26 XCTest cases, including:
- **Parser:** fixtures, units, wrappers vs single objects, 204/empty, booleans and NaN, oversize, bad dates and
  missing offsets, ISO durations, cardio-load `NOT_AVAILABLE`.
- **Anchoring and hypnogram:** midnight wrap, onset after midnight, light-code merge, unknown gap, fixture stage
  totals matching Polar's seconds.
- **Mapper:** NR join, RHR choice and fallback, efficiency fraction, `ref_*` only, DST.
- **Recovery:** calibrating then scoring, the bad night red, parity with `WatchRecovery`, no HRV → no Charge.
- **Pipeline:** end-to-end fixtures, 401 aborts, 403 consents, 503 honest partial, 404 = no data.
