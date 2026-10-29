#!/usr/bin/env python3
"""Regenerate the synthetic Polar AccessLink fixtures.

The output is deterministic: the RNG is seeded and the dates are fixed. Every file follows the
response shapes documented at https://www.polar.com/accesslink-api/ (field names, units, and the
"HH:MM" sample maps). The values are SYNTHETIC. They describe a plausible adult on a Polar Loop in
America/Chicago (CDT, -05:00), not anyone's real data.

The story the fixtures tell:
  - 14 nights ending on the wake day 2026-10-28.
  - HRV around 58 ms and lowest sleeping HR around 52 bpm, with ordinary night-to-night noise.
  - Night 10 (2026-10-24) is a bad night: late, short, HRV low and HR high. Recovery should dip there.
  - The last night is a good one.

Usage: python3 make_fixtures.py   (writes into ../Sources/PolarAccessLink/Fixtures)
"""
import json
import os
import random
from datetime import datetime, timedelta, timezone

random.seed(20261028)
TZ = timezone(timedelta(hours=-5))
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "PolarAccessLink", "Fixtures")
END_DAY = datetime(2026, 10, 28, tzinfo=TZ)
NIGHTS = 14
USER = "https://www.polaraccesslink.com/v3/users/12345678"
BAD = 9  # index of the bad night (0-based) -> wake day 2026-10-24


def day_str(d):
    return d.strftime("%Y-%m-%d")


def hhmm(dt):
    return dt.strftime("%H:%M")


def iso(dt):
    # AccessLink style: local time with offset, millisecond precision.
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000") + "-05:00"


sleeps, recharges, activities, chr_days, cardio = [], [], [], [], []

for i in range(NIGHTS):
    wake_day = END_DAY - timedelta(days=NIGHTS - 1 - i)
    bad = i == BAD
    good = i == NIGHTS - 1
    onset = (wake_day - timedelta(days=1)).replace(hour=22, minute=40) + timedelta(minutes=random.randint(-25, 35))
    if bad:
        onset = wake_day.replace(hour=1, minute=12)
    dur_min = random.randint(415, 480) if not bad else 318
    if good:
        dur_min = 492
    wake = onset + timedelta(minutes=dur_min)

    # Hypnogram as stage change points ("HH:MM" -> code). Polar codes: 0 wake, 1 REM,
    # 2 lighter NREM, 3 light NREM, 4 deep NREM, 5 unknown.
    hyp = {}
    t = onset
    stage_secs = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
    cycle = 0
    while t < wake:
        cycle += 1
        plan = [(2, 8), (3, random.randint(18, 28)), (4, max(5, random.randint(30, 50) - cycle * 7)),
                (3, random.randint(10, 20)), (1, min(45, 8 + cycle * 7 + random.randint(0, 6)))]
        if random.random() < (0.55 if bad else 0.3):
            plan.append((0, random.randint(2, 6)))
        if cycle == 3 and random.random() < 0.5:
            plan.append((5, 3))
        for code, mins in plan:
            if t >= wake:
                break
            seg_end = min(wake, t + timedelta(minutes=mins))
            if not hyp or list(hyp.values())[-1] != code:
                hyp[hhmm(t)] = code
            stage_secs[code] += int((seg_end - t).total_seconds())
            t = seg_end
    interruptions = stage_secs[0]

    # Sleep HR samples: 5-min averages that dip mid-night.
    base_low = 51 + random.randint(-2, 2) + (9 if bad else 0) - (2 if good else 0)
    hr_samples = {}
    n5 = dur_min // 5
    for k in range(n5):
        ts = onset + timedelta(minutes=5 * k)
        frac = k / max(1, n5 - 1)
        shape = 10 * (1 - 4 * frac * (1 - frac))  # high at both ends, low in the middle
        hr_samples[hhmm(ts)] = int(round(base_low + shape + random.uniform(0, 2.2)))
    low = min(hr_samples.values())

    hrv = round(random.gauss(58, 6)) if not (bad or good) else (34 if bad else 71)
    rr = round(60000 / (low + 4))
    br = round(random.gauss(14.2, 0.4) + (1.1 if bad else 0), 1)
    ans = round((hrv - 58) / 6 * 3 + random.uniform(-0.8, 0.8), 1)
    ans = max(-10.0, min(10.0, ans))
    ans_status = 1 if ans < -6 else 2 if ans < -2 else 3 if ans <= 2 else 4 if ans <= 6 else 5
    sleep_score = max(1, min(100, int(round(78 + (dur_min - 450) / 4 + random.uniform(-4, 4)))))
    if bad:
        sleep_score = 52
    sleep_charge = 1 if sleep_score < 55 else 2 if sleep_score < 65 else 3 if sleep_score < 78 else 4 if sleep_score < 88 else 5
    nr_status = max(1, min(6, ans_status + (sleep_charge - 3)))

    sleeps.append({
        "polar_user": USER,
        "date": day_str(wake_day),
        "sleep_start_time": iso(onset),
        "sleep_end_time": iso(wake),
        "device_id": "C2A7B1E9",
        "continuity": round(3.6 - (1.1 if bad else 0) + random.uniform(-0.3, 0.3), 1),
        "continuity_class": 2 if bad else 3,
        "light_sleep": stage_secs[2] + stage_secs[3],
        "deep_sleep": stage_secs[4],
        "rem_sleep": stage_secs[1],
        "unrecognized_sleep_stage": stage_secs[5],
        "sleep_score": sleep_score,
        "total_interruption_duration": interruptions,
        "sleep_charge": sleep_charge,
        "sleep_goal": 28800,
        "sleep_rating": 0,
        "short_interruption_duration": int(interruptions * 0.4),
        "long_interruption_duration": int(interruptions * 0.6),
        "sleep_cycles": cycle,
        "group_duration_score": max(1, min(100, int(dur_min / 4.8))),
        "group_solidity_score": 60 if bad else 82,
        "group_regeneration_score": 55 if bad else 79,
        "hypnogram": hyp,
        "heart_rate_samples": hr_samples,
    })

    # Nightly Recharge: averages over the 4 h window starting 30 min after sleep onset.
    hrv_samples, br_samples = {}, {}
    for k in range(48):
        ts = onset + timedelta(minutes=30 + 5 * k)
        hrv_samples[hhmm(ts)] = max(8, int(round(hrv + random.gauss(0, 7))))
        br_samples[hhmm(ts)] = round(br + random.gauss(0, 0.5), 1)
    window_hr = [v for kk, v in hr_samples.items()][6:54]
    recharges.append({
        "polar_user": USER,
        "date": day_str(wake_day),
        "heart_rate_avg": int(round(sum(window_hr) / len(window_hr))),
        "beat_to_beat_avg": rr,
        "heart_rate_variability_avg": hrv,
        "breathing_rate_avg": br,
        "nightly_recharge_status": nr_status,
        "ans_charge": ans,
        "ans_charge_status": ans_status,
        "hrv_samples": hrv_samples,
        "breathing_samples": br_samples,
    })

    # Daily activity for the wake day.
    steps = random.randint(6500, 13500) if not bad else 4100
    act_min = steps // 55
    activities.append({
        "start_time": day_str(wake_day) + "T00:00:00",
        "end_time": day_str(wake_day) + "T23:59:59",
        "active_duration": "PT%dH%dM" % (act_min // 60, act_min % 60),
        "inactive_duration": "PT%dH%dM" % ((900 - act_min) // 60, (900 - act_min) % 60),
        "daily_activity": round(min(200.0, steps / 100.0), 1),
        "calories": 2150 + steps // 20,
        "active_calories": steps // 20,
        "steps": steps,
        "inactivity_alert_count": random.randint(0, 3),
        "distance_from_steps": round(steps * 0.74, 1),
    })

    # Continuous HR: 5-min samples across the whole calendar day (local time).
    samples = []
    for k in range(288):
        ts = wake_day.replace(hour=0, minute=0) + timedelta(minutes=5 * k)
        h = ts.hour + ts.minute / 60
        asleep = ts < wake or ts >= (wake_day.replace(hour=22, minute=40))
        if asleep:
            bpm = base_low + 6 + random.randint(0, 4)
        else:
            bpm = 66 + random.randint(-4, 9)
            if 17.5 <= h < 18.25 and not bad:  # an evening run
                bpm = 138 + random.randint(-8, 14)
        samples.append({"heart_rate": bpm, "sample_time": ts.strftime("%H:%M:%S")})
    chr_days.append({"polar_user": USER, "date": day_str(wake_day), "heart_rate_samples": samples})

    trimp = round(random.uniform(55, 95) if not bad else 18.0, 1)
    cardio.append({
        "date": day_str(wake_day),
        "cardio_load_status": "LOAD_STATUS_OK",
        "cardio_load": trimp,
        "strain": round(65 + random.uniform(-6, 6), 1),
        "tolerance": round(62 + random.uniform(-3, 3), 1),
        "cardio_load_ratio": round(1.05 + random.uniform(-0.15, 0.15), 2),
        "cardio_load_level": {"very_low": 0, "low": 0, "medium": 1, "high": 0, "very_high": 0},
    })

os.makedirs(OUT, exist_ok=True)


def dump(name, obj):
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(obj, f, indent=1, sort_keys=False)
        f.write("\n")


dump("sleep.json", {"nights": sleeps})
dump("nightly-recharge.json", {"recharges": recharges})
dump("activities.json", activities)
dump("continuous-heart-rate.json", chr_days)
dump("cardio-load.json", cardio)
print("wrote fixtures for", day_str(END_DAY - timedelta(days=NIGHTS - 1)), "..", day_str(END_DAY))
