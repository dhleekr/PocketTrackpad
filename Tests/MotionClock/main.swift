import Foundation
let lock=NSLock();var times=[Double]()
let clock=MotionDisplayClock{lock.lock();times.append(ProcessInfo.processInfo.systemUptime);lock.unlock()}
guard clock.start() else{print("FAIL display clock unavailable");exit(1)}
Thread.sleep(forTimeInterval:1.2)
lock.lock();let captured=times;lock.unlock()
let gaps=zip(captured.dropFirst(),captured).map{($0-$1)*1000}.sorted()
let p95=gaps.isEmpty ? 0:gaps[Int(Double(gaps.count-1)*0.95)]
print(String(format:"Output callbacks: %d; p95 interval: %.2f ms",captured.count,p95))
let passed=captured.count>=30 && p95<50
print(passed ? "PASS native display clock runs independently of packet arrivals":"FAIL native display clock cadence")
exit(passed ? 0:1)
