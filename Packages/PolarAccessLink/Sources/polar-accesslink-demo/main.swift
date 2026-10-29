import Foundation
import PolarAccessLink

// End-to-end, credential-free run of the Polar AccessLink lane over the bundled synthetic fixtures:
// fixture transport → parser → mapper → NOOP Charge (WatchRecovery). `swift run polar-accesslink-demo`.

let result = try await PolarFixtures.runDemo()
print("Polar AccessLink fixture sync \(result.window.from) … \(result.window.to): \(result.requestCount) requests")
print(result.summaryText)
print("")
print("wake day    sleep deep rem  HRV  RHR  | NOOP Charge  confidence   | Polar ANS  NR status")
let periods = Dictionary(result.normalized.sleepPeriods.map { (PolarFixtures.dayKey($0.session.end), $0) },
                         uniquingKeysWith: { a, _ in a })
func col(_ s: String, _ w: Int) -> String { s.count >= w ? s + " " : s.padding(toLength: w, withPad: " ", startingAt: 0) }
func num(_ v: Double?, _ w: Int = 5, _ fmt: String = "%.0f") -> String { col(v.map { String(format: fmt, $0) } ?? "-", w) }
for c in PolarRecovery.charge(days: result.normalized.days, extras: result.normalized.extras) {
    let s = periods[c.day]?.session
    let charge = c.charge.map { String(format: "%.0f", $0) } ?? "calibrating"
    print(col(c.day, 12) + num(s?.totalSleepMin, 6) + num(s?.deepMin) + num(s?.remMin) + num(c.hrvRmssdMs)
          + num(c.restingHr.map(Double.init)) + "| " + col(charge, 13) + col("\(c.confidence)", 13)
          + "| " + num(c.polarAnsCharge, 11, "%.1f") + (c.polarNightlyRechargeStatus.map(String.init) ?? "-"))
}
