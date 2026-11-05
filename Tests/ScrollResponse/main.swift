import Cocoa
var failures=0
func check(_ ok:Bool,_ name:String){print("\(ok ? "PASS":"FAIL") \(name)");if !ok{failures+=1}}
func replay(rate:Double,speed:Double,momentum:Bool=false)->(Double,Double){
 #if !BASELINE
 var response=VerticalScrollResponse()
 #endif
 var total=0.0,last=1.0
 for i in 0..<Int(rate) {
  let y=speed/rate
  #if BASELINE
  let value=y
  #else
  let value=response.apply(x:0,y:y,phase:i==0 ? "began":"changed",momentum:"none",time:Double(i)/rate).y
  last=response.currentGain
  #endif
  total+=value
 }
 return(total,last)
}
let slow=replay(rate:120,speed:24),normal=replay(rate:120,speed:240),fast=replay(rate:120,speed:900)
check(slow.0>=24 && slow.0<=48,"fine scrolling stays controllable")
check(normal.0>=430 && normal.0<=650,"ordinary vertical scrolling covers a useful distance")
check(fast.1>normal.1 && normal.1>slow.1,"gain grows smoothly with speed")
let sixty=replay(rate:60,speed:240),twoForty=replay(rate:240,speed:240)
check(abs(sixty.0-twoForty.0)/twoForty.0<0.02,"gain is stable across 60/120/240 Hz input")
#if !BASELINE
var horizontal=VerticalScrollResponse()
let page=horizontal.apply(x:12,y:0.1,phase:"began",momentum:"none",time:1)
check(page.x==12 && page.y==0.1,"horizontal page gesture remains unchanged")
var vertical=VerticalScrollResponse()
_ = vertical.apply(x:0,y:8,phase:"began",momentum:"none",time:1)
let stopped=vertical.apply(x:0,y:0,phase:"ended",momentum:"none",time:1.1)
let gain=vertical.currentGain
let inertia=vertical.apply(x:0,y:3,phase:"ended",momentum:"began",time:1.11)
check(stopped.y==0 && abs(inertia.y-3*gain)<1e-10,"finger lift adds no motion and momentum preserves gain")
let reversed=vertical.apply(x:0,y:-2,phase:"changed",momentum:"none",time:1.12)
check(reversed.y<0,"reversing fingers reverses output immediately")
#endif
exit(failures==0 ? 0:1)
