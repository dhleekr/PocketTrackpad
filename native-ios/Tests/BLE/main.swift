import Foundation
var passed=0,failed=0
func test(_ name:String,_ body:()->Bool){if body(){passed+=1;print("PASS \(name)")}else{failed+=1;print("FAIL \(name)")}}
let key=String(repeating:"a",count:32),owner=UUID(),other=UUID()
test("unknown peer cannot input before authentication"){let a=BLEAccess();return !a.accepts(owner)}
test("wrong QR token never authorizes input"){var a=BLEAccess();return a.authorize(owner,supplied:String(repeating:"b",count:32),expected:key)=="pairing" && !a.accepts(owner)}
test("missing or short Mac key is rejected"){var a=BLEAccess();return a.authorize(owner,supplied:key,expected:nil)=="pairing" && a.authorize(owner,supplied:"a",expected:"a")=="pairing"}
test("QR key authorizes exactly one central"){var a=BLEAccess();return a.authorize(owner,supplied:key,expected:key)=="ok" && a.accepts(owner) && !a.accepts(other) && a.authorize(other,supplied:key,expected:key)=="busy"}
test("disconnect revokes authorization"){var a=BLEAccess();_ = a.authorize(owner,supplied:key,expected:key);a.reset();return !a.accepts(owner)}
for size in [1,7,20,64,185,512] {
 test("fragmented frame reassembles with MTU \(size)"){
  let data=Data(("{\"hello\":\""+key+"\"}\n{\"id\":1,\"events\":[{\"type\":\"up\"}]}\n").utf8)
  var buffer=BLEFrames(),frames=[Data]()
  do {for p in stride(from:0,to:data.count,by:size){frames += try buffer.append(data.subdata(in:p..<min(p+size,data.count)))};return frames.count==2 && String(data:frames[1],encoding:.utf8)!.contains("up") }catch{return false}
 }
}
test("oversized unframed data is rejected and cleared"){var b=BLEFrames();do{_ = try b.append(Data(repeating:65,count:16385));return false}catch{do{return try b.append(Data("ok\n".utf8))==[Data("ok".utf8)]}catch{return false}}}
test("partial frame reset does not contaminate next session"){var b=BLEFrames();_ = try? b.append(Data("partial".utf8));b.reset();return (try? b.append(Data("next\n".utf8)))==[Data("next".utf8)]}
test("real gesture event types validate"){BLEWire.valid([["type":"move","x":1.25,"y":-2],["type":"scroll","x":0,"y":-3,"phase":"ended","momentum":"began"],["type":"click","count":1],["type":"shortcut","name":"mission"],["type":"up"]])}
test("invalid values never reach input engine"){
 let bad:[[String:Any]]=[["type":"shell"],["type":"move","x":true],["type":"move","y":Double.infinity],["type":"move","x":2001],["type":"scroll","phase":1],["type":"scroll","momentum":"bad"],["type":"click","count":true],["type":"shortcut","name":"unknown"]]
 return bad.allSatisfy{!BLEWire.valid([$0])} && !BLEWire.valid([])
}
test("RTT comparison retains only sixty finite samples"){var a=LatencySamples();a.add(.nan);for i in 0..<80 {a.add(Double(i))};return a.values.count==60 && a.values.first==20 && a.summary.contains("60")}
test("small-MTU status notifications reassemble before JSON decoding") {
 let payload=Data("{\"status\":\"permission\",\"id\":99999}\n".utf8);var b=BLEFrames(),frames=[Data]()
 for p in stride(from:0,to:payload.count,by:20){frames += (try? b.append(payload.subdata(in:p..<min(p+20,payload.count)))) ?? []}
 guard frames.count==1,let d=(try? JSONSerialization.jsonObject(with:frames[0])) as? [String:Any] else{return false}
 return d["status"] as? String=="permission" && d["id"] as? Int==99999
}
test("pairing alert does not suspend the in-progress connection") {ConnectionLifecycle.effect(for:.inactive ) == .releaseOnly}
test("dismissing pairing alert resumes rather than reconnecting") {
 let effects:[ConnectionEffect]=[.active,.inactive,.active].map{ConnectionLifecycle.effect(for:$0)}
 return effects == [.resumeExisting,.releaseOnly,.resumeExisting]
}
test("real background transition suspends the connection") {ConnectionLifecycle.effect(for:.background ) == .suspend}
test("resume invalidates an older scheduled disconnect") {var epoch=ConnectionEpoch();let before=epoch.value;epoch.advance();return !epoch.matches(before)}
let sessionNonce=String(repeating:"1",count:64)+String(repeating:"2",count:64)
test("reverse transport verifies both directions with different proofs") {
 let host=BLEProof.make(role:"host",nonce:sessionNonce,token:key),phone=BLEProof.make(role:"phone",nonce:sessionNonce,token:key)
 return host != phone && BLEProof.valid(host,role:"host",nonce:sessionNonce,token:key) && BLEProof.valid(phone,role:"phone",nonce:sessionNonce,token:key) && !BLEProof.valid(host,role:"phone",nonce:sessionNonce,token:key)
}
test("captured proof cannot authenticate either endpoint in a new session") {
 let proof=BLEProof.make(role:"host",nonce:sessionNonce,token:key)
 return !BLEProof.valid(proof,role:"host",nonce:String(repeating:"3",count:128),token:key) && !BLEProof.valid(proof,role:"host",nonce:sessionNonce,token:String(repeating:"b",count:32))
}
test("malformed challenge or proof fails closed") {
 !BLEProof.valid("",role:"host",nonce:sessionNonce,token:key) && !BLEProof.valid(String(repeating:"0",count:64),role:"host",nonce:"short",token:key) && !BLEProof.valid(String(repeating:"0",count:64),role:"host",nonce:sessionNonce,token:nil)
}
test("native magnify frames carry bounded deltas and phase") {
 BLEWire.valid([["type":"magnify","x":0.125,"phase":"changed"]]) && !BLEWire.valid([["type":"magnify","x":2,"phase":"changed"]]) && !BLEWire.valid([["type":"magnify","x":0.1]])
}
test("old browser-only zoom shortcuts are rejected") {
 !BLEWire.valid([["type":"shortcut","name":"browserZoomIn"]])
}
test("missing Bluetooth advertisement recovers after publication deadline") {
 BLEDiscoveryRecovery.shouldRestart(enabled:true,hasPeer:false,isAdvertising:false,elapsed:5) && !BLEDiscoveryRecovery.shouldRestart(enabled:true,hasPeer:false,isAdvertising:false,elapsed:4.9)
}
test("discovery recovery preserves connected and background sessions") {
 !BLEDiscoveryRecovery.shouldRestart(enabled:true,hasPeer:true,isAdvertising:false,elapsed:60) && !BLEDiscoveryRecovery.shouldRestart(enabled:false,hasPeer:false,isAdvertising:false,elapsed:60) && !BLEDiscoveryRecovery.shouldRestart(enabled:true,hasPeer:false,isAdvertising:true,elapsed:60)
}
test("continuous system progress requires a valid axis and terminal phase") {
 BLEWire.valid([["type":"dockSwipe","name":"vertical","phase":"changed","x":0.4,"y":0.2]]) && !BLEWire.valid([["type":"dockSwipe","name":"vertical","phase":"changed","x":4,"y":0]]) && !BLEWire.valid([["type":"dockSwipe","name":"other","phase":"ended","x":0,"y":0]])
}
test("input timestamps reject non-finite, boolean and unreasonable values") {
 BLEWire.valid([["type":"move","x":1,"y":0,"t":1234.125]]) && !BLEWire.valid([["type":"move","t":true]]) && !BLEWire.valid([["type":"move","t":Double.infinity]]) && !BLEWire.valid([["type":"move","t":1e100]])
}
test("latency metadata is optional, numeric and bounded") {
 LatencySnapshotReporter.value(in:[:]) == nil && LatencySnapshotReporter.value(in:["rttMS":true]) == nil && LatencySnapshotReporter.value(in:["rttMS":Double.nan]) == nil && LatencySnapshotReporter.value(in:["rttMS":-1]) == nil && LatencySnapshotReporter.value(in:["rttMS":15.5]) == 15.5
}
test("latency metadata is sent no more than once per second") {
 var reporter=LatencySnapshotReporter()
 return reporter.snapshot(milliseconds:0,at:1) == nil && reporter.snapshot(milliseconds:20,at:1) == 20 && reporter.snapshot(milliseconds:21,at:1.1) == nil && reporter.snapshot(milliseconds:21,at:2) == 21
}
test("new system shortcuts pass the authenticated wire validator") {BLEWire.valid([["type":"shortcut","name":"notifications"],["type":"shortcut","name":"apps"]])}
test("dictation validates bounded unicode and an operation identifier") {BLEWire.valid([["type":"text","name":UUID().uuidString,"text":"안녕하세요 Hello 👩🏽‍💻"]])}
test("dictation rejects malformed or oversized input") {
 let invalid:[Any]=["",String(repeating:"가",count:1025),"x\u{0000}",false]
 return invalid.allSatisfy{!BLEWire.valid([["type":"text","name":UUID().uuidString,"text":$0]])} && !BLEWire.valid([["type":"text","text":"hello"]])
}
test("keyboard chunks round-trip unicode without splitting surrogate pairs") {
 let value=String(repeating:"한글 é 👩🏽‍💻 ",count:30),chunks=PadTextInput.keyboardChunks(value)
 return chunks.allSatisfy{$0.count<=20 && String(decoding:$0,as:UTF16.self).utf16.count==$0.count} && chunks.map{String(decoding:$0,as:UTF16.self)}.joined()==value
}
test("default interface is Escape Tab Backspace Enter in order") {
 PadQuickKey.defaults.map(\.rawValue)==["escape","tab","backspace","enter"] && PadQuickKey.allCases.filter{$0.keyCode != nil}.allSatisfy{BLEWire.valid([["type":"shortcut","name":$0.rawValue]])}
}
test("Shift-Tab posts Tab with Shift while plain Tab has no modifier") {
 PadQuickKey.shiftTab.keyCode==48 && PadQuickKey.shiftTab.shift && PadQuickKey.tab.keyCode==48 && !PadQuickKey.tab.shift && !PadQuickKey.enter.shift && !PadQuickKey.escape.shift
}
test("custom arrow quick keys are accepted by the wire") {
 BLEWire.valid([["type":"shortcut","name":"up"]]) && BLEWire.valid([["type":"shortcut","name":"down"]])
}
test("key repeat settings accept the same bounded values on either transport") {
 [0.2,0.35,1].allSatisfy{delay in [5.0,30,60].allSatisfy{rate in BLEWire.valid([["type":"key","phase":"began","name":"backspace","repeatDelay":delay,"repeatRate":rate]])}}
}
test("invalid repeat settings never reach the input engine") {
 let invalid:[Any]=[true,"fast",-1.0,Double.nan,Double.infinity]
 return invalid.allSatisfy{value in
  !BLEWire.valid([["type":"key","phase":"began","name":"backspace","repeatDelay":value]]) && !BLEWire.valid([["type":"key","phase":"began","name":"backspace","repeatRate":value]])
 } && !BLEWire.valid([["type":"key","phase":"began","name":"backspace","repeatRate":61.0]]) && !BLEWire.valid([["type":"key","phase":"began","name":"backspace","repeatDelay":0.05]])
}
test("older phones can omit repeat settings") {BLEWire.valid([["type":"key","phase":"began","name":"backspace"]])}
test("QR discovery is deterministic and isolated between users") {
 let own=BLEDiscovery.service(token:key),other=BLEDiscovery.service(token:String(repeating:"b",count:32))
 return own != nil && own == BLEDiscovery.service(token:key) && own != other && own != BLEWire.reverseService && UUID(uuidString:own!) != nil
}
test("missing and short QR secrets never advertise or scan") {
 BLEDiscovery.service(token:nil) == nil && BLEDiscovery.service(token:"") == nil && BLEDiscovery.service(token:String(repeating:"a",count:31)) == nil
}
test("different QR identities cannot share a discovery service") {
 let ids=(0..<256).compactMap{BLEDiscovery.service(token:String(format:"%064x",$0))}
 return ids.count==256 && Set(ids).count==256
}
print("BLE protocol checks: \(passed) passed, \(failed) failed")
exit(failed==0 ? 0:1)
