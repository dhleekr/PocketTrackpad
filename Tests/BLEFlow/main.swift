import Foundation
var window=BLESendWindow(),sequence=0,pending=0,produced=0,delivered=0,peak=0,maxWait=0.0,nextRadio=0.0
var inflight=[Int:(ack:Double,amount:Int)]()
let dt=1.0/240
for step in 0..<4320 {
 let now=Double(step)*dt
 for (id,item) in inflight where item.ack<=now {delivered+=item.amount;inflight.removeValue(forKey:id)}
 if produced<1200 {produced+=1;pending+=1}
 #if BASELINE
 let allowed=true
 #else
 let allowed=window.canSend(at:now,outstanding:inflight.count,urgent:false)
 #endif
 if pending>0 && allowed {
  sequence+=1;let radio=max(now,nextRadio)+0.01;nextRadio=radio;maxWait=max(maxWait,radio-now)
  inflight[sequence]=(radio+0.04,pending);pending=0;window.didSend(at:now);peak=max(peak,inflight.count)
 }
}
print(String(format:"240 Hz input / 100 frame/s radio: peak %d in flight; max native queue %.1f ms; movement %d/%d",peak,maxWait*1000,delivered,produced))
let bounded=peak<=4 && maxWait<0.1,complete=produced==1200 && delivered==1200 && pending==0
print(bounded ? "PASS transport cannot build an unbounded native queue":"FAIL native queue grows behind accepted notifications")
print(complete ? "PASS coalescing preserves all relative movement":"FAIL lost relative movement")
var urgent=BLESendWindow();urgent.didSend(at:1)
let controls=urgent.canSend(at:1.001,outstanding:4,urgent:true) && !urgent.canSend(at:1.001,outstanding:6,urgent:true) && !urgent.canSend(at:1.001,outstanding:0,urgent:false)
print(controls ? "PASS release/control credits bypass pacing without unbounded sends":"FAIL control boundary pacing")
exit(bounded && complete && controls ? 0:1)
