import Foundation
var failures=0
func check(_ condition:Bool,_ name:String){print("\(condition ? "PASS":"FAIL") \(name)");if !condition{failures+=1}}
// Uniform 120 Hz input, delivered in recurring bursts with 0–16.7 ms jitter.
let period=1.0/120.0
var packets=[(source:Double,arrival:Double,value:Double)]()
for i in 0..<120 {let source=Double(i)*period;let arrival=Double((i/3)*3+2)*period;packets.append((source,arrival,Double(i+1)))}
var next=0,last=0.0,steps=[Double]()
#if BASELINE
var target=0.0
#else
var timeline=MotionTimeline()
#endif
for frame in 0..<128 {
    let now=Double(frame)*period
    while next<packets.count,packets[next].arrival<=now+1e-8 {
        let p=packets[next]
        #if BASELINE
        target=p.value
        #else
        timeline.append(x:p.value,y:0,sourceTime:p.source,arrival:now)
        #endif
        next+=1
    }
    #if BASELINE
    let value=target
    #else
    let value=timeline.sample(at:now).x
    #endif
    if frame>8 && frame<116 {steps.append(value-last)}
    last=value
}
let mean=steps.reduce(0,+)/Double(steps.count)
let variance=steps.map{pow($0-mean,2)}.reduce(0,+)/Double(steps.count)
let cv=sqrt(variance)/mean
print(String(format:"burst replay frame-step variation: %.3f",cv))
check(cv<0.1,"uniform input stays uniform despite packet bursts")
check(abs(last-120)<0.00001,"total movement is preserved")
#if !BASELINE
var stop=MotionTimeline();stop.append(x:5,y:2,sourceTime:1,arrival:1)
let end=stop.finish();check(end.x==5 && end.y==2 && stop.sample(at:2)==end,"release drains the real endpoint without extrapolation")
var fine=MotionTimeline();for i in 0..<20{fine.append(x:Double(i+1)*0.001,y:0,sourceTime:Double(i)*period,arrival:Double(i)*period)}
check(abs(fine.finish().x-0.02)<1e-10,"subpixel movements survive pacing")
var reverse=MotionTimeline();reverse.append(x:0.5,y:0,sourceTime:1,arrival:1);reverse.append(x:0,y:0,sourceTime:1.01,arrival:1.01)
check(reverse.finish().x==0,"reversal ends exactly at the latest real progress")
var stalled=MotionTimeline();for i in 0..<500{stalled.append(x:Double(i),y:0,sourceTime:Double(i)/1000,arrival:1)}
check(stalled.bufferedCount<=64,"queue stays bounded under a stalled display")
#endif
#if !BASELINE
var delivered=[[String:Any]]();let playback=MotionPlayback()
playback.enqueue(["type":"move","x":10.0,"y":0.0,"t":1.0],at:1){delivered.append($0)}
playback.enqueue(["type":"move","x":20.0,"y":0.0,"t":1.01],at:1.01){delivered.append($0)}
playback.flush{delivered.append($0)}
check(delivered.reduce(0){$0+($1["x"] as? Double ?? 0)}==30,"click boundary can flush all movement before mouse down")
let stopRouter=MotionPlayback();var stopped=[[String:Any]]()
_ = stopRouter.accept(["type":"move","x":7.0,"y":0.0],at:1){stopped.append($0)}
let boundaryHandled=stopRouter.accept(["type":"status","name":"motionEnd"],at:1.001){stopped.append($0)}
check(!boundaryHandled && stopped.reduce(0){$0+($1["x"] as? Double ?? 0)}==7 && !stopRouter.active,"finger-lift marker drains pending pointer motion immediately")
let before=delivered.count;playback.frame(at:2){delivered.append($0)}
check(delivered.count==before,"no delayed pointer movement after release")
let dock=MotionPlayback();var progress=[Double]()
dock.enqueue(["type":"dockSwipe","name":"horizontal","x":0.4,"y":1.0,"phase":"changed","t":1.0],at:1){_ in}
dock.enqueue(["type":"dockSwipe","name":"horizontal","x":0.1,"y":-1.0,"phase":"changed","t":1.01],at:1.01){_ in}
dock.flush{progress.append($0["x"] as? Double ?? -1)}
check(progress.last==0.1,"system gestures keep absolute progress during reversal")
#endif
#if !BASELINE
let router=MotionPlayback();var routed=[[String:Any]]()
for event:[String:Any] in [["type":"scroll","x":1.0,"y":2.0,"phase":"began"],["type":"scroll","x":3.0,"y":4.0,"phase":"changed"],["type":"scroll","x":0.0,"y":0.0,"phase":"ended"]] {
 if !router.accept(event,at:1,apply:{routed.append($0)}){routed.append(event)}
}
let history=MotionPlayback();var historyEvents=[[String:Any]]()
_ = history.accept(["type":"scroll","x":6.0,"y":0.0,"phase":"began"],at:1){historyEvents.append($0)}
history.frame(at:1.01){historyEvents.append($0)}
history.flush{historyEvents.append($0)}
check(historyEvents.first?["phase"] as? String=="began" && abs(historyEvents.first?["x"] as? Double ?? 0)>0,"page swipe starts with directional nonzero began, not an empty began")
check(routed.first?["phase"] as? String=="began" && routed.last?["phase"] as? String=="ended" && routed.reduce(0){$0+($1["y"] as? Double ?? 0)}==6,"actual event router preserves scroll phases and distance")
let momentum=MotionPlayback();var moment=[[String:Any]]()
_ = momentum.accept(["type":"scroll","x":0.0,"y":4.0,"phase":"ended","momentum":"began"],at:1){moment.append($0)}
momentum.frame(at:1.01){moment.append($0)}
_ = momentum.accept(["type":"scroll","x":0.0,"y":4.0,"phase":"ended","momentum":"changed"],at:1.01){moment.append($0)}
momentum.flush{moment.append($0)}
check(moment.first?["momentum"] as? String=="began" && moment.last?["momentum"] as? String=="changed" && moment.reduce(0){$0+($1["y"] as? Double ?? 0)}==8,"inertial scrolling uses the same paced path")
var clockJump=MotionTimeline();clockJump.append(x:1,y:0,sourceTime:1,arrival:1);clockJump.append(x:2,y:0,sourceTime:1e6,arrival:1.01)
check(clockJump.sample(at:1.1).x==2,"source-clock discontinuity cannot freeze playback")
#endif
exit(failures==0 ? 0:1)
