import Foundation
for key in PadQuickKey.allCases {
 var state=KeyRepeatState()
 assert(state.begin(key,at:0),"every quick key must accept a held press: \(key)")
 assert(state.tick(at:0.1)==nil,"short taps must remain single presses")
 var count=0
 for step in 1...500 {
  let now=Double(step)*0.004
  state.heartbeat(key,at:now)
  if state.tick(at:now) != nil,now>=0.5 && now<1.5{count+=1}
 }
 let expected=key == .backspace ? 30:60
 assert((expected-1...expected+1).contains(count),"held \(key) must maintain its constant rate")
 state.end(key);assert(state.tick(at:2.004)==nil,"release stops \(key)")
}
var state=KeyRepeatState()
assert(state.begin(.enter,at:0));assert(state.tick(at:0.51)==nil && state.key==nil,"lost connection must stop Enter too")
assert(state.begin(.backspace,at:2));state.heartbeat(.backspace,at:9.9)
assert(state.tick(at:10) == .backspace);assert(state.tick(at:10.001)==nil,"a delayed timer must not replay queued repetitions")
print("PASS Backspace 30 Hz / other quick keys 60 Hz, immediate release, lost lease, no delayed burst")

var quick=KeyRepeatState()
assert(quick.begin(.backspace,at:0))
assert(quick.tick(at:0.349)==nil)
assert(quick.tick(at:0.35) == .backspace,"Backspace repeat must wait for the hold threshold")

final class OutputTiming {
 let lock=NSLock()
 var first:Double?,times=[Double]()
 func record(_ key:PadQuickKey,_ phase:HeldKeyPhase){
  lock.lock();defer{lock.unlock()}
  let now=ProcessInfo.processInfo.systemUptime
  if phase == .began{first=now}else if phase == .repeated{times.append(now)}
 }
}
let output=OutputTiming(),repeater=MacKeyRepeater(deliver:output.record)
let began=ProcessInfo.processInfo.systemUptime
repeater.handle(.backspace,phase:"began")
for _ in 0..<16{Thread.sleep(forTimeInterval:0.1);repeater.handle(.backspace,phase:"changed")}
repeater.handle(.backspace,phase:"ended")
output.lock.lock();let first=output.first,times=output.times;output.lock.unlock()
assert(first != nil && first!-began<0.01,"first key must be delivered synchronously without the repeat delay")
let steady=times.filter{$0>=began+0.5 && $0<began+1.5}
assert((27...33).contains(steady.count),"actual timer must maintain about 30 repeats per second")
Thread.sleep(forTimeInterval:0.05)
output.lock.lock();assert(output.times.count==times.count,"release must stop the real timer");output.lock.unlock()
print("PASS production key timer: first down <10 ms, steady \(steady.count)/s, release stops")

assert(PadKeyRepeatTuning.delay(nil)==0.35 && PadKeyRepeatTuning.delay(.nan)==0.35)
assert(PadKeyRepeatTuning.delay(0)==0.2 && PadKeyRepeatTuning.delay(9)==1)
assert(PadKeyRepeatTuning.rate(nil)==30 && PadKeyRepeatTuning.rate(.infinity)==30)
assert(PadKeyRepeatTuning.rate(1)==5 && PadKeyRepeatTuning.rate(999)==60)
var configured=KeyRepeatState();configured.delay=0.8;configured.backspaceRate=10
assert(configured.begin(.backspace,at:0));configured.heartbeat(.backspace,at:0.7)
assert(configured.tick(at:0.79)==nil && configured.tick(at:0.8) == .backspace)
assert(configured.tick(at:0.89)==nil && configured.tick(at:0.9) == .backspace)
configured.end();assert(configured.tick(at:1)==nil)
let tapOutput=OutputTiming(),tapRepeater=MacKeyRepeater(deliver:tapOutput.record)
tapRepeater.handle(.backspace,phase:"began")
Thread.sleep(forTimeInterval:0.12)
tapRepeater.handle(.backspace,phase:"ended")
tapOutput.lock.lock();assert(tapOutput.first != nil && tapOutput.times.isEmpty,"a 120 ms tap must send one down without repeated deletion");tapOutput.lock.unlock()
print("PASS short tap once, configurable hold threshold and Backspace rate, safe defaults and bounds")
