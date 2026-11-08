import Foundation
let requested=["mission","scrollUp","scrollDown"]
for name in requested {
 guard let key=PadQuickKey(rawValue:name) else{print("FAIL missing assignable action: \(name)");exit(1)}
 assert(PadQuickKey.restored(["escape",name,"backspace","enter"])[1]==key)
}
print("PASS requested Mac actions can be assigned and restored")

let grouped=PadQuickKey.groups.flatMap(\.keys)
assert(grouped.count==PadQuickKey.allCases.count && Set(grouped)==Set(PadQuickKey.allCases),"each action appears once in a stable category")
assert(!PadQuickKey.mission.repeatable && PadQuickKey.mission.keyCode==nil,"Mission Control must not repeat while held or emit a keyboard key")
assert(PadQuickKey.scrollUp.keyCode==nil && PadQuickKey.scrollDown.keyCode==nil)
assert(BLEWire.valid([["type":"shortcut","name":"mission"]]))
assert(!BLEWire.valid([["type":"key","phase":"began","name":"mission"]]))
for key in [PadQuickKey.scrollUp,.scrollDown] {
 var state=QuickKeyScrollState();let first=state.begin(key,at:0)!
 assert(abs(first)==32)
 var amount=0.0
 for i in 1...120 {amount+=state.tick(at:Double(i)/120)!}
 assert(abs(abs(amount)-480)<0.01,"held scroll distance is independent of timer frequency")
 let stalled=state.tick(at:20)!
 assert(abs(stalled)<=16.001,"timer stalls must not cause catch-up scroll jumps")
 assert(first*amount>0 && amount*stalled>0)
 state.end();assert(state.tick(at:21)==nil,"release stops scrolling immediately")
 assert(BLEWire.valid([["type":"scroll","x":0,"y":first,"phase":"began","name":"contentOnly"],["type":"scroll","x":0,"y":0,"phase":"ended","name":"contentOnly"]]))
}
print("PASS system actions, grouped choices, smooth held scroll, release, and wire validation")
