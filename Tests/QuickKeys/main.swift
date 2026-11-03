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
 check(events.map(\.type)==[.keyDown,.keyUp] && events.allSatisfy{$0.flags==[] && $0.getIntegerValueField(.keyboardEventKeycode)==key.keyCode},"\(key.title) sends an unmodified key pair")
}
exit(failures==0 ? 0:1)
