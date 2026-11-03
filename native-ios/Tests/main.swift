import Foundation
var passed=0,failed=0
func test(_ name:String,_ body:()->Bool) {
    if body() { passed+=1;print("PASS \(name)") } else { failed+=1;print("FAIL \(name)") }
}
func fixture()->(GestureEngine,()->[PadEvent]) {
    let engine=GestureEngine();var events=[PadEvent]()
    engine.emit={ events += $0 };return (engine,{events})
}
func one(_ x:Double=100,_ y:Double=100,_ force:Double=0)->[Int:PadPoint] { [1:PadPoint(x:x,y:y,force:force)] }
func fingers(_ count:Int,dx:Double=0,dy:Double=0)->[Int:PadPoint] { Dictionary(uniqueKeysWithValues:(1...count).map{($0,PadPoint(x:Double($0*40)+dx,y:100+dy))}) }
test("quick tap clicks immediately") { let(e,events)=fixture();e.update(one(),at:0);e.update([:],at:0.08);return events()==[PadEvent(type:"click",count:1)] }
test("double tap has correct click counts") { let(e,events)=fixture();e.update(one(),at:0);e.update([:],at:0.05);e.update(one(),at:0.1);e.update([:],at:0.15);return events().map{$0.count} == [1,2] }
test("two finger tap right clicks") { let(e,events)=fixture();e.update(fingers(2),at:0);e.update([:],at:0.08);return events()==[PadEvent(type:"right")] }
test("moving one finger does not become a press click") { let(e,events)=fixture();e.update(one(),at:0);for i in 1...30 { e.update(one(100+Double(i)*2),at:Double(i)*0.016) };e.update([:],at:0.5);return events().allSatisfy{$0.type=="move"} }
test("press clicks at 160ms and holds") { let(e,events)=fixture();e.update(one(),at:0);e.tick(at:0.159);let early=events().isEmpty;e.tick(at:0.161);return early && e.held && events()==[PadEvent(type:"down")] }
test("press release is a mouse up, not another click") { let(e,events)=fixture();e.update(one(),at:0);e.tick(at:0.17);e.update([:],at:0.2);return events().map{$0.type} == ["down","up"] }
test("press-and-move becomes drag") { let(e,events)=fixture();e.update(one(),at:0);e.tick(at:0.17);e.update(one(120),at:0.2);e.update([:],at:0.25);return events().map{$0.type} == ["down","move","up"] }
test("real hardware force clicks without dwell") { let(e,events)=fixture();e.hardwarePressureAvailable=true;e.update(one(),at:0);e.update(one(100,100,0.7),at:0.02);return e.held && events().first?.type=="down" }
test("unsupported force does not pretend to be a pressure sensor") { let(e,events)=fixture();e.update(one(),at:0);e.update(one(100,100,1),at:0.02);return !e.held && events().isEmpty }
test("pressure click can be disabled") { let(e,events)=fixture();e.pressClickEnabled=false;e.hardwarePressureAvailable=true;e.update(one(),at:0);e.update(one(100,100,1),at:0.2);return !e.held && events().isEmpty }
test("three finger motion streams native system progress until lift") {
 let(e,events)=fixture();e.update(fingers(3),at:0);for i in 1...20 {e.update(fingers(3,dy:Double(i)*(-5)),at:Double(i)*0.016)}
 return events().first?.phase=="began" && events().filter{$0.phase=="changed"}.count>5 && events().allSatisfy{$0.type=="dockSwipe" && $0.name=="vertical"} && !events().contains{$0.phase=="ended"}
}
test("three finger down sends negative native progress") {let(e,events)=fixture();e.update(fingers(3),at:0);e.update(fingers(3,dy:55),at:0.1);return events().last?.name=="vertical" && (events().last?.x ?? 0)<0}
test("three finger right sends horizontal native progress") {let(e,events)=fixture();e.update(fingers(3),at:0);e.update(fingers(3,dx:55),at:0.1);return events().last?.name=="horizontal" && (events().last?.x ?? 0)<0}
test("three finger left sends opposite horizontal native progress") {let(e,events)=fixture();e.update(fingers(3),at:0);e.update(fingers(3,dx:-55),at:0.1);return events().last?.name=="horizontal" && (events().last?.x ?? 0)>0}
test("three finger jitter never clicks or drags") { let(e,events)=fixture();e.update(fingers(3),at:0);e.update(fingers(3,dx:8),at:0.1);e.update([:],at:0.2);return events().isEmpty && !e.held }
test("diagonal swipe waits for a dominant direction") { let(e,events)=fixture();e.update(fingers(3),at:0);e.update(fingers(3,dx:50,dy:-50),at:0.1);return events().isEmpty }
test("swipe survives staggered finger lift without scroll or clicks") {
 let(e,events)=fixture();e.update(fingers(3),at:0);e.update(fingers(3,dy:-55),at:0.1);e.update(fingers(2,dy:-55),at:0.11);e.update([:],at:0.15)
 return events().last?.phase=="ended" && events().allSatisfy{$0.type=="dockSwipe"}
}
test("new three finger gesture has its own begin and end") {
 let(e,events)=fixture();for i in 0...1 {let t=Double(i);e.update(fingers(3),at:t);e.update(fingers(3,dy:-55),at:t+0.1);e.update([:],at:t+0.2)}
 return events().filter{$0.phase=="began"}.count==2 && events().filter{$0.phase=="ended"}.count==2
}
test("lifting a press drag releases exactly once") { let(e,events)=fixture();e.update(one(),at:0);e.tick(at:0.17);e.update([:],at:0.2);e.update([:],at:0.3);return !e.held && events().filter{$0.type=="up"}.count==1 }
test("cancellation releases held press input") { let(e,events)=fixture();e.update(one(),at:0);e.tick(at:0.17);e.cancel();return !e.held && events().last?.type=="up" }
test("adding a third finger releases existing press drag") { let(e,events)=fixture();e.update(one(),at:0);e.tick(at:0.17);e.update(fingers(3),at:0.2);e.update(fingers(3,dy:-55),at:0.3);return events().map{$0.type} == ["down","up","dockSwipe","dockSwipe"] && !e.held }
test("two fingers scroll rather than move the cursor") { let(e,events)=fixture();e.update(fingers(2),at:0);for i in 1...12 { e.update(fingers(2,dy:Double(i)*4),at:Double(i)*0.016) };return events().allSatisfy{$0.type=="scroll"} && events().first?.phase=="began" }
test("horizontal scroll keeps vertical delta zero") { let(e,events)=fixture();e.update(fingers(2),at:0);for i in 1...12 { e.update(fingers(2,dx:Double(i)*4),at:Double(i)*0.016) };return !events().isEmpty && events().allSatisfy{$0.type=="scroll" && $0.y==0} }
test("scroll continues when translation dominates small spacing changes") { let(e,events)=fixture();e.update(fingers(2),at:0);e.update(fingers(2,dy:12),at:0.016);e.update([1:PadPoint(x:50,y:112),2:PadPoint(x:110,y:112)],at:0.032);return events().allSatisfy{$0.type=="scroll"} }
test("scroll inertia decays and terminates") { let(e,events)=fixture();e.update(fingers(2),at:0);for i in 1...12 { e.update(fingers(2,dy:Double(i)*4),at:Double(i)*0.016) };e.update([:],at:0.2);for i in 1...200 { e.tick(at:0.2+Double(i)*0.016) };return events().contains{$0.momentum=="began"} && events().last?.momentum=="ended" }
test("new touch stops momentum") { let(e,events)=fixture();e.update(fingers(2),at:0);e.update(fingers(2,dy:20),at:0.016);e.update([:],at:0.02);e.tick(at:0.036);e.update(one(),at:0.04);return events().last?.momentum=="ended" }
test("two finger cancellation has a cancelled scroll phase") { let(e,events)=fixture();e.update(fingers(2),at:0);e.update(fingers(2,dy:12),at:0.016);e.cancel();return events().last?.phase=="cancelled" }
test("120Hz input never waits for an acknowledgment") { let(e,events)=fixture();e.update(one(),at:0);for i in 1...240 { e.update(one(100+Double(i)),at:Double(i)/120) };return events().filter{$0.type=="move"}.count==240 }
test("staggered two finger lift preserves flick inertia") { let(e,events)=fixture();e.update(fingers(2),at:0);for i in 1...10 { e.update(fingers(2,dy:Double(i)*8),at:Double(i)*0.016) };e.update([1:PadPoint(x:40,y:180)],at:0.17);e.update([:],at:0.19);e.tick(at:0.206);return events().contains{$0.momentum=="began"} }
test("flick continues for more than half a second") { let(e,events)=fixture();e.update(fingers(2),at:0);for i in 1...10 {e.update(fingers(2,dy:Double(i)*8),at:Double(i)*0.016)};e.update([:],at:0.17);for i in 1...40 {e.tick(at:0.17+Double(i)*0.016)};return events().last?.momentum=="changed" }
test("expanded press thresholds work at both endpoints") {
 for delay in [0.05,2.0] {let(e,events)=fixture();e.pressDelay=delay;e.update(one(),at:0);e.tick(at:delay-0.001);if events().contains(where:{$0.type=="down"}){return false};e.tick(at:delay+0.001);if !events().contains(where:{$0.type=="down"}){return false}}
 return true
}
test("expanded cursor speed scales real motion over full range") {
 func movement(_ speed:Double)->Double {let(e,events)=fixture();e.sensitivity=speed;e.update(one(),at:0);e.update(one(110),at:0.016);return events().filter{$0.type=="move"}.compactMap{$0.x}.reduce(0,+)}
 let slow=movement(0.1),fast=movement(12);return slow>0 && abs(fast/slow-120)<0.001
}
test("speed slider reaches both endpoints and preserves fine low speeds") {
 abs(PadTuning.speed(at:0)-0.1)<0.0001 && abs(PadTuning.speed(at:1)-12)<0.0001 && [0.1,0.2,1.6,12].allSatisfy{abs(PadTuning.speed(at:PadTuning.speedPosition($0))-$0)<0.0001}
}
test("saved tuning survives reload and invalid settings are bounded") {
 let suite="PocketTrackpad-test-"+UUID().uuidString
 let store=UserDefaults(suiteName:suite)!
 defer{store.removePersistentDomain(forName:suite)}
 store.set(1.75,forKey:suite);let value=PadTuning.saved(suite,default:0.16,range:PadTuning.pressRange,in:store)
 store.set(99.0,forKey:suite);let upper=PadTuning.saved(suite,default:0.16,range:PadTuning.pressRange,in:store)
 return value==1.75 && upper==2 && PadTuning.saved("missing",default:1.6,range:PadTuning.speedRange,in:store)==1.6
}
test("fast landscape-width movement stays valid without losing distance") {
 let(e,events)=fixture();e.sensitivity=12;e.update(one(),at:0);e.update(one(700),at:0.016)
 let moves=events().filter{$0.type=="move"}
 return moves.count>1 && moves.allSatisfy{abs($0.x ?? 0)<=2000 && abs($0.y ?? 0)<=2000} && abs(moves.compactMap{$0.x}.reduce(0,+)-7920)<0.01
}
test("comfortable double tap interval still produces a double click") {
 let(e,events)=fixture();e.update(one(),at:0);e.update([:],at:0.08);e.update(one(),at:0.4);e.update([:],at:0.48)
 return events().filter{$0.type=="click"}.map{$0.count} == [1,2]
}
test("minimum press delay does not swallow the second tap") {
 let(e,events)=fixture();e.pressDelay=0.05;e.update(one(),at:0);e.tick(at:0.06);e.update([:],at:0.08);e.update(one(),at:0.16);e.tick(at:0.22);e.update([:],at:0.24)
 return events().map{$0.type} == ["down","up","click"] && events().last?.count==2
}
test("second tap moves immediately into drag without waiting for dwell") {
 let(e,events)=fixture();e.pressDelay=2;e.update(one(),at:0);e.update([:],at:0.05);e.update(one(),at:0.15);e.update(one(106),at:0.16)
 let dragging=e.held && events().contains{$0.type=="down"} && events().contains{$0.type=="move"}
 e.update([:],at:0.18)
 return dragging && !e.held && events().last?.type=="up"
}
test("double tap interval setting controls click recognition") {
 for (interval,gap,expected) in [(0.1,0.2,1),(1.0,0.7,2)] {
  let(e,events)=fixture();e.doubleTapInterval=interval;e.update(one(),at:0);e.update([:],at:0.05);e.update(one(),at:gap);e.update([:],at:gap+0.05)
  if events().last?.count != expected{return false}
 }
 return true
}
test("double tap interval also controls immediate tap-drag") {
 for (interval,expected) in [(0.1,false),(1.0,true)] {
  let(e,_)=fixture();e.doubleTapInterval=interval;e.pressDelay=2;e.update(one(),at:0);e.update([:],at:0.05);e.update(one(),at:0.7);e.update(one(106),at:0.71)
  if e.held != expected{return false}
 }
 return true
}
test("pinch emits native magnify phases without right click on staggered lift") {
 let(e,events)=fixture();e.update(fingers(2),at:0)
 e.update([1:PadPoint(x:10,y:100),2:PadPoint(x:110,y:100)],at:0.03)
 e.update([1:PadPoint(x:-10,y:100),2:PadPoint(x:130,y:100)],at:0.06)
 e.update([1:PadPoint(x:-10,y:100)],at:0.08);e.update([:],at:0.1)
 return events().first?.phase=="began" && events().last?.phase=="ended" && events().contains{$0.phase=="changed" && ($0.x ?? 0)>0} && events().allSatisfy{$0.type=="magnify"}
}
test("closing pinch zooms out") {
 let(e,events)=fixture();e.update([1:PadPoint(x:0,y:100),2:PadPoint(x:160,y:100)],at:0)
 e.update([1:PadPoint(x:30,y:100),2:PadPoint(x:130,y:100)],at:0.03)
 return events().contains{$0.type=="magnify" && ($0.x ?? 0)<0}
}
test("pinch cancellation closes the native gesture") {
 let(e,events)=fixture();e.update(fingers(2),at:0);e.update([1:PadPoint(x:0,y:100),2:PadPoint(x:120,y:100)],at:0.03);e.cancel()
 return events().last==PadEvent(type:"magnify",x:0,phase:"cancelled")
}
test("third finger cancels pinch before system gesture") {
 let(e,events)=fixture();e.update(fingers(2),at:0);e.update([1:PadPoint(x:0,y:100),2:PadPoint(x:120,y:100)],at:0.03);e.update(fingers(3),at:0.04)
 return events().last==PadEvent(type:"magnify",x:0,phase:"cancelled")
}
test("replacing a lifted pinch finger closes the old gesture") {
 let(e,events)=fixture();e.update(fingers(2),at:0);e.update([1:PadPoint(x:0,y:100),2:PadPoint(x:120,y:100)],at:0.03)
 e.update([1:PadPoint(x:0,y:100)],at:0.04);e.update([1:PadPoint(x:0,y:100),3:PadPoint(x:90,y:100)],at:0.05)
 return events().last==PadEvent(type:"magnify",x:0,phase:"cancelled")
}
test("haptic kinds separate taps from press, release and system gestures") {
 let(e,_)=fixture();var kinds=[PadHapticKind]();e.haptic={kinds.append($0)}
 e.update(one(),at:0);e.update([:],at:0.05)
 guard kinds == [.tap] else{return false};kinds=[]
 e.update(one(),at:1);e.tick(at:1.2);e.update([:],at:1.3)
 guard kinds == [.press,.release] else{return false};kinds=[]
 e.update(fingers(3),at:2);e.update(fingers(3,dy:-60),at:2.1)
 return kinds.isEmpty
}
test("slow subpoint movement remains precise and never vanishes") {
 let(e,events)=fixture();e.pressClickEnabled=false;e.update(one(),at:0)
 for i in 1...100 {e.update(one(100+Double(i)*0.02),at:Double(i)*0.016)}
 let distance=events().filter{$0.type=="move"}.compactMap{$0.x}.reduce(0,+)
 return distance>0.5 && distance<1.5
}
test("reversing a system swipe back to origin cancels it") {
 let(e,events)=fixture();e.update(fingers(3),at:0);e.update(fingers(3,dy:-80),at:0.1);e.update(fingers(3,dy:-1),at:0.2);e.update([:],at:0.25)
 return events().last?.type=="dockSwipe" && events().last?.phase=="cancelled"
}
test("two finger scroll can transition to pinch without a stuck scroll") {
 let(e,events)=fixture();e.update(fingers(2),at:0);e.update(fingers(2,dy:5),at:0.03)
 e.update([1:PadPoint(x:20,y:105),2:PadPoint(x:100,y:105)],at:0.06)
 let all=events();return all.contains{$0.type=="scroll" && $0.phase=="ended"} && all.contains{$0.type=="magnify" && $0.phase=="began"}
}
test("coalesced samples retain every intermediate position") {
    var frames=PadTouchFrameAssembler();frames.reset(one(0,0),at:0)
    let output=frames.consume([PadTouchSample(id:1,time:0.008,point:PadPoint(x:2,y:0)),PadTouchSample(id:1,time:0.004,point:PadPoint(x:1,y:0))])
    return output.map{$0.points[1]!.x} == [1,2] && output.map{$0.time} == [0.004,0.008]
}
test("same-time fingers form one coherent frame") {
    var frames=PadTouchFrameAssembler();frames.reset(fingers(2),at:0)
    let output=frames.consume([PadTouchSample(id:1,time:0.01,point:PadPoint(x:45,y:100)),PadTouchSample(id:2,time:0.01,point:PadPoint(x:85,y:100))])
    return output.count==1 && output[0].points[1]!.x==45 && output[0].points[2]!.x==85
}
test("old touch histories cannot replay after a finger boundary") {
    var frames=PadTouchFrameAssembler();frames.reset(one(),at:1)
    return frames.consume([PadTouchSample(id:1,time:0.9,point:PadPoint(x:1,y:1)),PadTouchSample(id:2,time:1.1,point:PadPoint(x:1,y:1))]).isEmpty
}
test("press timer does not change movement gain at the next touch sample") {
    let(a,ae)=fixture();let(b,be)=fixture();a.pressClickEnabled=false;b.pressClickEnabled=false
    a.update(one(),at:0);b.update(one(),at:0);a.tick(at:0.015)
    a.update(one(110),at:0.016);b.update(one(110),at:0.016)
    return ae()==be()
}
func edgePair(_ x:Double=375,_ y:Double=180)->[Int:PadPoint] {[1:PadPoint(x:x,y:y),2:PadPoint(x:x+5,y:y+50)]}
func fourPinch(_ radius:Double=100,dx:Double=0)->[Int:PadPoint] {
 [1:PadPoint(x:200-radius+dx,y:300-radius),2:PadPoint(x:200+radius+dx,y:300-radius),3:PadPoint(x:200-radius+dx,y:300+radius),4:PadPoint(x:200+radius+dx,y:300+radius)]
}
test("right-edge two-finger swipe opens notifications once without scrolling") {
 let(e,events)=fixture();e.surfaceWidth=390;e.update(edgePair(),at:0);e.update(edgePair(310),at:0.15);e.update([:],at:0.2)
 return events()==[PadEvent(type:"shortcut",name:"notifications")]
}
test("four-finger pinch opens installed apps without zooming or desktop swipe") {
 let(e,events)=fixture();e.update(fourPinch(),at:0);e.update(fourPinch(55),at:0.15);e.update([:],at:0.2)
 return events()==[PadEvent(type:"shortcut",name:"apps")]
}
test("reversing an edge swipe cancels notifications") {
 let(e,events)=fixture();e.surfaceWidth=390;e.update(edgePair(),at:0);e.update(edgePair(310),at:0.1);e.update(edgePair(),at:0.2);e.update([:],at:0.25);return events().isEmpty
}
test("central horizontal scroll remains page navigation") {
 let(e,events)=fixture();e.surfaceWidth=390;e.update(edgePair(200),at:0);e.update(edgePair(120),at:0.1);e.update([:],at:0.4);return events().contains{$0.type=="scroll"} && !events().contains{$0.type=="shortcut"}
}
test("vertical scroll at edge is not consumed") {
 let(e,events)=fixture();e.surfaceWidth=390;e.update(edgePair(),at:0);e.update(edgePair(375,130),at:0.1);e.update([:],at:0.4);return events().contains{$0.type=="scroll"} && !events().contains{$0.type=="shortcut"}
}
test("edge swipe with staggered finger lifts opens only once") {
 let(e,events)=fixture();e.surfaceWidth=390;e.update(edgePair(),at:0);e.update(edgePair(310),at:0.1);e.update([1:PadPoint(x:310,y:180)],at:0.15);e.update([1:PadPoint(x:375,y:180)],at:0.18);e.update([:],at:0.2);return events()==[PadEvent(type:"shortcut",name:"notifications")]
}
test("spreading back cancels four finger apps pinch") {
 let(e,events)=fixture();e.update(fourPinch(),at:0);e.update(fourPinch(55),at:0.1);e.update(fourPinch(),at:0.2);e.update([:],at:0.3);return events().isEmpty
}
test("cancelled apps pinch never opens apps") {
 let(e,events)=fixture();e.update(fourPinch(),at:0);e.update(fourPinch(55),at:0.1);e.cancel();e.update([:],at:0.3);return events().isEmpty
}
test("natural side-by-side fingers at the right edge open Notification Center") {
 let(e,events)=fixture();e.surfaceWidth=390;var haptics=0;e.haptic={_ in haptics+=1}
 let start=[1:PadPoint(x:325,y:180),2:PadPoint(x:375,y:195)]
 e.update(start,at:0);e.update([1:PadPoint(x:260,y:180),2:PadPoint(x:310,y:195)],at:0.15);e.update([:],at:0.2)
 return events()==[PadEvent(type:"shortcut",name:"notifications")] && haptics==1
}
test("landscape edge swipe allows normal horizontal finger separation") {
 let(e,events)=fixture();e.surfaceWidth=932
 e.update([1:PadPoint(x:850,y:180),2:PadPoint(x:915,y:200)],at:0)
 e.update([1:PadPoint(x:775,y:180),2:PadPoint(x:840,y:200)],at:0.2);e.update([:],at:0.3)
 return events()==[PadEvent(type:"shortcut",name:"notifications")]
}
test("notifications can be disabled without blocking horizontal scroll") {
 let(e,events)=fixture();e.surfaceWidth=390;e.gestures.set(.notifications,false)
 e.update(edgePair(),at:0);e.update(edgePair(310),at:0.1);e.update([:],at:0.2)
 return !events().contains{$0.name=="notifications"} && events().contains{$0.type=="scroll"}
}
test("tap click can be disabled while pointer movement remains available") {
 let(e,events)=fixture();e.gestures.set(.tapToClick,false);e.pressClickEnabled=false
 e.update([1:PadPoint(x:50,y:50)],at:0);e.update([:],at:0.1)
 e.update([1:PadPoint(x:50,y:50)],at:1);e.update([1:PadPoint(x:70,y:50)],at:1.1);e.update([:],at:1.2)
 return !events().contains{$0.type=="click"} && events().contains{$0.type=="move"}
}
test("corner secondary click does not also emit a primary click") {
 let(e,events)=fixture();e.surfaceWidth=390;e.surfaceHeight=800;e.gestures.secondaryClick = .bottomRight
 e.update([1:PadPoint(x:375,y:780)],at:0);e.update([:],at:0.1)
 return events()==[PadEvent(type:"right")]
}
test("three finger lookup is independently switchable") {
 let(e,events)=fixture();e.update([1:PadPoint(x:50,y:50),2:PadPoint(x:80,y:50),3:PadPoint(x:110,y:50)],at:0);e.update([:],at:0.1)
 return events()==[PadEvent(type:"shortcut",name:"lookup")]
}
test("smart zoom consumes two double taps without secondary clicks") {
 let(e,events)=fixture();e.gestures.set(.smartZoom,true)
 e.update(edgePair(150),at:0);e.update([:],at:0.05);e.update(edgePair(150),at:0.15);e.update([:],at:0.2);e.tick(at:0.8)
 return events()==[PadEvent(type:"smartZoom")]
}
test("a lone two-finger tap still right clicks after the smart-zoom interval") {
 let(e,events)=fixture();e.gestures.set(.smartZoom,true)
 e.update(edgePair(150),at:0);e.update([:],at:0.05);e.tick(at:0.8)
 return events()==[PadEvent(type:"right")]
}
test("disabled pinch does not accidentally right click") {
 let(e,events)=fixture();e.gestures.set(.pinchZoom,false)
 e.update([1:PadPoint(x:100,y:100),2:PadPoint(x:200,y:100)],at:0)
 e.update([1:PadPoint(x:70,y:100),2:PadPoint(x:230,y:100)],at:0.1);e.update([:],at:0.2)
 return events().isEmpty
}
test("two finger rotation emits begin, rotation and end") {
 let(e,events)=fixture();e.update([1:PadPoint(x:100,y:100),2:PadPoint(x:200,y:100)],at:0)
 e.update([1:PadPoint(x:105,y:80),2:PadPoint(x:195,y:120)],at:0.1);e.update([:],at:0.2)
 return events().first?.type=="rotate" && events().first?.phase=="began" && events().contains{$0.type=="rotate" && $0.phase=="changed" && abs($0.x ?? 0)>10} && events().last?.phase=="ended"
}
test("four finger spread shows Desktop and reversing cancels it") {
 let(e,events)=fixture();e.update(fourPinch(40),at:0);e.update(fourPinch(75),at:0.1);e.update([:],at:0.2)
 return events()==[PadEvent(type:"shortcut",name:"showDesktop")]
}
test("page-history off preserves horizontal content scrolling without a pan companion") {
 let(e,events)=fixture();e.gestures.set(.pageSwipe,false);e.update(edgePair(150),at:0);e.update(edgePair(100),at:0.1);e.update([:],at:0.2)
 return events().contains{$0.type=="scroll"} && events().filter{$0.type=="scroll"}.allSatisfy{$0.name=="contentOnly"}
}
test("disabled Spaces swipes emit no system action") {
 let(e,events)=fixture();e.gestures.spacesFingers=0
 let start=[1:PadPoint(x:100,y:100),2:PadPoint(x:130,y:100),3:PadPoint(x:160,y:100)]
 e.update(start,at:0);e.update(start.mapValues{PadPoint(x:$0.x-80,y:$0.y)},at:0.1);e.update([:],at:0.2)
 return events().isEmpty
}
test("edge swipe escapes a first-finger dwell click") {
 let(e,events)=fixture();e.surfaceWidth=390
 e.update([1:PadPoint(x:375,y:160)],at:0);e.tick(at:0.18)
 e.update([1:PadPoint(x:375,y:160),2:PadPoint(x:325,y:190)],at:0.2)
 e.update([1:PadPoint(x:300,y:160),2:PadPoint(x:250,y:190)],at:0.3);e.update([:],at:0.4)
 return !e.held && events().contains{$0.name=="notifications"}
}
test("edge swipe accepts a natural wider second finger placement") {
 let(e,events)=fixture();e.surfaceWidth=440
 e.update([1:PadPoint(x:420,y:160),2:PadPoint(x:280,y:190)],at:0)
 e.update([1:PadPoint(x:350,y:160),2:PadPoint(x:210,y:190)],at:0.15);e.update([:],at:0.3)
 return events().contains{$0.name=="notifications"}
}
test("a fourth finger arriving during initial motion can still show desktop") {
 let(e,events)=fixture();let three=Dictionary(uniqueKeysWithValues:fourPinch(50).filter{$0.key != 4})
 e.update(three,at:0);e.update(three.mapValues{PadPoint(x:$0.x,y:$0.y+15)},at:0.03)
 e.update(fourPinch(50),at:0.05);e.update(fourPinch(90),at:0.17);e.update([:],at:0.25)
 return events().contains{$0.name=="showDesktop"} && !events().contains{$0.name=="apps"}
}
test("compact four-finger pinch opens Apps without a large movement") {
 let(e,events)=fixture();e.update(fourPinch(40),at:0);e.update(fourPinch(33),at:0.15);e.update([:],at:0.25)
 return events().contains{$0.name=="apps"}
}
test("compact four-finger spread shows desktop") {
 let(e,events)=fixture();e.update(fourPinch(40),at:0);e.update(fourPinch(47),at:0.15);e.update([:],at:0.25)
 return events().contains{$0.name=="showDesktop"}
}
test("small four-finger contact jitter never triggers a system action") {
 let(e,events)=fixture();e.update(fourPinch(40),at:0);e.update(fourPinch(42),at:0.15);e.update([:],at:0.25)
 return !events().contains{$0.type=="shortcut"}
}
test("completed Mission Control up swipe is followed by a fresh downward stream") {
 let(e,events)=fixture()
 e.update(fingers(3),at:0);e.update(fingers(3,dy: -120),at:0.2);e.update([:],at:0.3)
 let boundary=events().count
 e.update(fingers(3),at:0.6);e.update(fingers(3,dy:120),at:0.8);e.update([:],at:0.9)
 let down=Array(events().dropFirst(boundary))
 return down.first?.phase=="began" && down.last?.phase=="ended" && down.contains{$0.type=="dockSwipe" && ($0.x ?? 0)<0}
}
test("native desktop spread streams progress and finishes without a shortcut") {
 let(e,events)=fixture();e.continuousScaleEnabled=true
 e.update(fourPinch(40),at:0);e.update(fourPinch(44),at:0.1);e.update(fourPinch(50),at:0.2)
 let before=events();e.update([:],at:0.3)
 return before.contains{$0.name=="scale" && $0.phase=="changed"} && events().last?.phase=="ended" && !events().contains{$0.type=="shortcut"}
}
test("reversing a native desktop spread cancels the interaction") {
 let(e,events)=fixture();e.continuousScaleEnabled=true
 e.update(fourPinch(40),at:0);e.update(fourPinch(50),at:0.1);e.update(fourPinch(40),at:0.2);e.update([:],at:0.3)
 return events().last?.name=="scale" && events().last?.phase=="cancelled"
}
test("native notification edge drag streams the panel before fingers lift") {
 let(e,events)=fixture();e.continuousScaleEnabled=true;e.surfaceWidth=390
 e.update(edgePair(),at:0);e.update(edgePair(350),at:0.1);e.update(edgePair(310),at:0.2)
 let before=events();e.update([:],at:0.3)
 return before.contains{$0.name=="notification" && $0.phase=="changed"} && events().last?.phase=="ended" && !events().contains{$0.type=="shortcut"}
}
test("native notification edge reversal closes the partial panel") {
 let(e,events)=fixture();e.continuousScaleEnabled=true;e.surfaceWidth=390
 e.update(edgePair(),at:0);e.update(edgePair(310),at:0.1);e.update(edgePair(),at:0.2);e.update([:],at:0.3)
 return events().last?.name=="notification" && events().last?.phase=="cancelled"
}
test("staggered scale lifts preserve the final progress") {
 let(e,events)=fixture();e.continuousScaleEnabled=true
 e.update(fourPinch(40),at:0);e.update(fourPinch(50),at:0.1)
 let p=events().last?.x
 e.update([1:PadPoint(x:150,y:250)],at:0.15);e.update([:],at:0.2)
 return events().last?.name=="scale" && events().last?.x==p && events().last?.phase=="ended"
}
test("a short inward edge swipe opens Notification Center") {
 let(e,events)=fixture();e.continuousScaleEnabled=true;e.surfaceWidth=390
 e.update(edgePair(340),at:0);e.update(edgePair(314),at:0.12);e.update([:],at:0.2)
 return events().last?.name=="notification" && events().last?.phase=="ended"
}
test("a fresh outward swipe closes an opened Notification Center") {
 let(e,events)=fixture();e.continuousScaleEnabled=true;e.surfaceWidth=390
 e.update(edgePair(),at:0);e.update(edgePair(330),at:0.15);e.update([:],at:0.2)
 let boundary=events().count
 e.update(edgePair(180),at:0.4);e.update(edgePair(215),at:0.55);e.update([:],at:0.6)
 let close=Array(events().dropFirst(boundary))
 return close.contains{$0.name=="notification" && ($0.x ?? 0)<0} && close.last?.phase=="ended" && !close.contains{$0.type=="scroll"}
}
test("cancelled closing keeps the panel available for a later close") {
 let(e,events)=fixture();e.continuousScaleEnabled=true;e.surfaceWidth=390
 e.update(edgePair(),at:0);e.update(edgePair(330),at:0.1);e.update([:],at:0.15)
 e.update(edgePair(180),at:0.3);e.update(edgePair(200),at:0.4);e.update(edgePair(180),at:0.5);e.update([:],at:0.6)
 let boundary=events().count
 e.update(edgePair(180),at:0.8);e.update(edgePair(220),at:0.9);e.update([:],at:1)
 return events().dropFirst(boundary).contains{$0.name=="notification" && ($0.x ?? 0)<0}
}
test("closing Mission Control uses its own finger setting when App Expose is off") {
 let(e,events)=fixture();e.gestures.exposeFingers=0;e.gestures.missionFingers=3
 e.update(fingers(3),at:0);e.update(fingers(3,dy: -160),at:0.2);e.update([:],at:0.3)
 let boundary=events().count
 e.update(fingers(3),at:0.6);e.update(fingers(3,dy:120),at:0.8);e.update([:],at:0.9)
 return events().dropFirst(boundary).contains{$0.name=="vertical" && ($0.x ?? 0)<0}
}
print("Native gesture checks: \(passed) passed, \(failed) failed")
exit(failed==0 ? 0:1)
