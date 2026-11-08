import CoreGraphics
import Foundation
var failures=0
func check(_ ok:Bool,_ name:String){print("\(ok ? "PASS":"FAIL") \(name)");if !ok{failures+=1}}
let shifted=MacQuickKeys.events(for:.shiftTab)
check(shifted.map(\.type)==[.flagsChanged,.keyDown,.keyUp,.flagsChanged],"Shift-Tab presses and releases the modifier around the Tab key")
check(shifted.count==4 && shifted[1].getIntegerValueField(.keyboardEventKeycode)==48 && shifted[2].getIntegerValueField(.keyboardEventKeycode)==48,"Shift-Tab sends real Tab down and up")
check(shifted.count==4 && shifted.prefix(3).allSatisfy{$0.flags == .maskShift} && shifted.last?.flags==[],"Shift is released so the next input is not modified")
for key in [PadQuickKey.escape,.tab,.enter] {
 let events=MacQuickKeys.events(for:key)
 check(events.map(\.type)==[.keyDown,.keyUp] && events.allSatisfy{$0.flags==[] && $0.getIntegerValueField(.keyboardEventKeycode)==key.keyCode!},"\(key.title) sends an unmodified key pair")
}
for key in PadQuickKey.allCases where key.keyCode != nil {
 let events=MacQuickKeys.events(for:key),downs=events.filter{$0.type == .keyDown},ups=events.filter{$0.type == .keyUp}
 var flags=CGEventFlags();if key.shift{flags.insert(.maskShift)};if key.command{flags.insert(.maskCommand)};if key.control{flags.insert(.maskControl)}
 check(downs.count==1 && ups.count==1 && downs[0].flags==flags && ups[0].flags==flags && downs[0].getIntegerValueField(.keyboardEventKeycode)==key.keyCode! && events.last?.flags==[],"\(key.accessibilityTitle) has the correct key, modifiers, and balanced release")
}
let heldSource=CGEventSource(stateID:.privateState)
for key in PadQuickKey.allCases where key.keyCode != nil {
 let began=MacQuickKeys.heldEvents(for:key,phase:.began,source:heldSource)
 let repeated=MacQuickKeys.heldEvents(for:key,phase:.repeated,source:heldSource)
 let ended=MacQuickKeys.heldEvents(for:key,phase:.ended,source:heldSource)
 check(began.filter{$0.type == .keyDown}.count==1 && !began.contains{$0.type == .keyUp},"held \(key) begins without releasing")
 check(repeated.count==1 && repeated[0].type == .keyDown && repeated[0].getIntegerValueField(.keyboardEventAutorepeat)==1,"held \(key) repeats down only")
 check(ended.filter{$0.type == .keyUp}.count==1 && ended.last?.flags==[],"held \(key) releases key and modifiers once")
}
exit(failures==0 ? 0:1)
