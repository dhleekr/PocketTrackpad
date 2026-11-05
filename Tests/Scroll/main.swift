import Cocoa
var failed=0
func check(_ value:Bool,_ label:String){print("\(value ? "PASS":"FAIL") \(label)");if !value{failed+=1}}
var stream=NativeScrollStream()
check(stream.event(x:0.2,y:0,phase:"began",momentum:"none")==nil,"fractional zero-pixel start is deferred")
let event=stream.event(x:0.9,y:0,phase:"changed",momentum:"none")
let decoded=event.flatMap{NSEvent(cgEvent:$0)}
check(decoded?.phase == .began && decoded?.hasPreciseScrollingDeltas == true && decoded?.scrollingDeltaX==1,"AppKit sees precise horizontal movement on the began event")
let next=stream.event(x:1,y:0,phase:"changed",momentum:"none").flatMap{NSEvent(cgEvent:$0)}
check(next?.phase == .changed,"subsequent movement stays changed")
let end=stream.event(x:0,y:0,phase:"ended",momentum:"none").flatMap{NSEvent(cgEvent:$0)}
check(end?.phase == .ended,"zero-delta terminal phase is preserved")
check(stream.event(x:Double.nan,y:0,phase:"began",momentum:"none")==nil,"malformed deltas rejected")
var vertical=NativeScrollStream();let v=vertical.event(x:0,y:2,phase:"began",momentum:"none").flatMap{NSEvent(cgEvent:$0)}
check(v?.scrollingDeltaX==0 && v?.scrollingDeltaY==2,"vertical scroll remains a vertical scroll")
var disconnect=NativeScrollStream();_ = disconnect.event(x:3,y:0,phase:"began",momentum:"none")
let cancelled=disconnect.cancel().flatMap{NSEvent(cgEvent:$0)}
check(cancelled?.phase == .cancelled && disconnect.cancel()==nil,"disconnect cancels a tracked page swipe once")
let pan=event.flatMap{NativeScrollStream.companion(for:$0)}
check(pan?.type.rawValue==29 && pan?.getIntegerValueField(CGEventField(rawValue:110)!)==6,"pixel scroll has a separate two-finger pan companion")
check(pan?.getIntegerValueField(CGEventField(rawValue:132)!)==1 && abs((pan?.getDoubleValueField(CGEventField(rawValue:116)!) ?? 0)-5.0/3.0)<0.00001,"pan carries its own phase and displacement")
var inertia=NativeScrollStream();let inertial=inertia.event(x:5,y:0,phase:"ended",momentum:"began")
check(inertial.flatMap{NativeScrollStream.companion(for:$0)}==nil,"momentum never creates another finger gesture")
var fine=NativeScrollStream()
let fineStart=fine.event(x:0,y:0.6,phase:"began",momentum:"none").flatMap{NSEvent(cgEvent:$0)}
check(fineStart?.scrollingDeltaY==1 && fineStart?.phase == .began,"fine scrolling responds at half a point instead of waiting for a full point")
let fineReverse=fine.event(x:0,y:-0.6,phase:"changed",momentum:"none").flatMap{NSEvent(cgEvent:$0)}
check(fineReverse?.scrollingDeltaY == -1,"fractional reversal returns exactly to its starting position")
var accumulated=NativeScrollStream();var distance:CGFloat=0
for i in 0..<120 {distance += accumulated.event(x:0,y:0.2,phase:i==0 ? "began":"changed",momentum:"none").flatMap{NSEvent(cgEvent:$0)}?.scrollingDeltaY ?? 0}
check(abs(distance-24)<0.00001,"fine scrolling preserves total distance without drift")
exit(failed==0 ? 0:1)
