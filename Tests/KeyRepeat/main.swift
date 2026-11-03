import Foundation
var state=KeyRepeatState()
assert(state.begin(.backspace,at:0))
assert(state.tick(at:0.2)==nil)
state.heartbeat(.backspace,at:0.3)
assert(state.tick(at:0.4) == .backspace)
assert(state.tick(at:0.41)==nil)
state.end(.backspace);assert(state.tick(at:0.5)==nil)
assert(!state.begin(.enter,at:1))
assert(state.begin(.left,at:1));assert(state.tick(at:1.6)==nil && state.key==nil)
assert(state.begin(.backspace,at:2));state.heartbeat(.backspace,at:9.9)
assert(state.tick(at:10) == .backspace);assert(state.tick(at:10.001)==nil)
print("PASS key repeat: initial delay, cadence, immediate release, lease expiry, no Enter repeat, no delayed burst")

var fast=KeyRepeatState(),lateDeletes=0
assert(fast.begin(.backspace,at:0))
for step in 1...350 {
 let now=Double(step)*0.008
 fast.heartbeat(.backspace,at:now)
 if fast.tick(at:now) != nil,now>1.8{lateDeletes+=1}
}
assert(lateDeletes>=50,"held Backspace should reach at least 50 deletions per second")
fast.end();assert(fast.tick(at:2.81)==nil,"release must cancel accelerated deletion immediately")
print("PASS accelerated Backspace and immediate stop")
